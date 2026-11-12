#!/usr/bin/env python3
"""`request-comms tick`: one pass of the status feed. Ship-dark, per-line-approved, capped.

For every open request the user hears from us when the state changes and, if nothing changes,
at least every 48 h — on the best channel we can actually reach them on (bell -> Intercom ->
email, the last one only when there is no Intercom identity, resolved by the r5 rules).

Three switches, all file-based so a deploy cannot flip copy on by itself:

  /etc/hydra/request-comms.disabled   kill: the tick returns 0 and does nothing at all
  policies/request-status-lines.json  `enabled` (the driver) + per-line `enabled` + `approval_ref`
  /etc/hydra/request-comms.live       absent = DRY RUN: every decision is recorded as `would_send`
                                      and nothing is sent (this is the default, and --dry-run is
                                      the default too)

Safety, in the order it bites:

  * a policy that does not validate refuses the run (exit 2) — a half-edited copy file is how a
    broken line reaches a customer;
  * an unreadable ban list sends NOTHING at all (exit 2): no ban list is not "nobody banned";
  * an unreadable source is UNKNOWN, not empty (exit 3): that type gets no messages this tick and
    the summary names the reader — a silent empty read would tell a user "nothing is happening"
    while we are blind to their request;
  * `max_per_run` is a per-tick BUDGET, not a refusal: a tick sends the oldest due messages up to
    the cap and COUNTS the remainder as `deferred` in the summary. The backlog is real (thousands of
    users), and a whole-tick refusal would mean no backlog is ever cleared — the queue only shrinks
    by sending. One message per user per day bounds the blast radius of the first live tick;
  * one message per user per UTC day across every request, counting an `uncertain` send (it may
    have arrived); several due requests collapse into ONE digest line;
  * a (request, state) pair is claimed in the ledger BEFORE the network call and is never
    re-offered afterwards, so a crash, a timeout or a rerun cannot double-send. Only a clean
    `rejected` may be retried on the next tick.

usage: request-comms tick [--dry-run|--live] [--only credit,claim] [--limit N] [--json]
       request-comms report [--days 7] [--json]
       request-comms check
       request-comms stop --request-ref REF --state STATE
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from request_comms import audit, channels as channels_mod, guard, lines, routing  # noqa: E402
from request_comms import sources as sources_mod  # noqa: E402
from request_comms.sources import Request  # noqa: E402
from request_comms.store import Store, iso, stamp  # noqa: E402

KILL = "/etc/hydra/request-comms.disabled"
LIVE = "/etc/hydra/request-comms.live"
STORE = "/var/lib/hydra/request-comms/state.sqlite"
REPORT_DIR = "/var/lib/hydra/request-comms/reports"
POLICY = lines.default_policy_path()
MAX_PER_RUN = 50
OBSERVE_EVERY_H = 24.0
HELD_REPEAT_H = 24.0
# Lanes the fraud lens does not govern: a data-removal acknowledgement is a legal obligation and a
# refund already on a ticket is a commercial one. Credit, claim and merge sends stay lensable.
LENS_EXEMPT_TYPES = frozenset({"erasure", "refund"})


@dataclass
class Cfg:
    store_path: str = STORE
    policy_path: str = field(default_factory=lines.default_policy_path)
    kill_file: str = KILL
    live_file: str = LIVE
    report_dir: str = REPORT_DIR
    audit_spool: str = audit.PENDING
    only: tuple[str, ...] = ()
    limit: int = 0
    max_per_run: int = MAX_PER_RUN
    dry_run: bool = True
    now: float | None = None
    # test seams (all optional; production uses the defaults)
    sources: Any = None
    channels: Any = None
    bans: Any = None
    identity: Callable[[str, str, dict[str, Any]], str] = lambda email, uid, detail: ""
    admin_id: Callable[[], str] = lambda: ""
    # The promise ledger's answer to "which conversation is this contact waiting on us in, for
    # this kind of request?" ('' = none). See `_waiting_thread`.
    thread_for: Callable[[str, str], str] = lambda contact_id, request_type: ""


def _admin_id() -> str:
    """Caroline's Intercom admin id — a constant in code, never an env var (tests/test_intercom_identity.py)."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
    try:
        from intercom_identity import ADMIN_ID  # noqa: PLC0415

        return str(ADMIN_ID)
    except Exception:  # noqa: BLE001
        return ""


def _default_thread_for(contact_id: str, request_type: str) -> str:
    """The open commitment's conversation, from the promise ledger the Caroline monitor keeps
    (scripts/caroline_monitor/commitments.py). Read-only, and '' on any failure."""
    try:
        from caroline_monitor import commitments  # noqa: PLC0415

        return commitments.thread_for(contact_id, request_type)
    except Exception:  # noqa: BLE001 - an unreadable ledger must never stop a status line
        return ""


def _waiting_thread(cfg: "Cfg", contact_id: str, request_type: str) -> str:
    """Where Caroline told this contact that we would come back about this kind of request.

    A status line sent anywhere else leaves that conversation exactly as it was: the customer is
    told in one place and still waiting in the other, and the promise stays open because a
    promise is only closed by a message on its own thread. '' when there is no such thread, when
    the ledger cannot be read, or when the seam raises: the line then goes out the way it always
    did, which is never worse than not sending it.
    """
    if not contact_id:
        return ""
    try:
        return str(cfg.thread_for(contact_id, request_type) or "")
    except Exception:  # noqa: BLE001
        return ""


def _hours_since(ts: str, now: float) -> float:
    at = iso(ts)
    return (now - at.timestamp()) / 3600.0 if at else 1e9


def _default_sources(policy: dict[str, Any]) -> sources_mod.Sources:
    """Production readers. The ticket-backed types (merge, refund) stay `unconfigured` until a
    ticket->account identity resolver exists: a ticket carries no Muso user id, and guessing one
    from a name or an email string is exactly what the identity gate forbids."""
    refund_tags, list_id = sources_mod.load_policy_sources(policy)
    window = ((policy.get("sources") or {}).get("window") or {})
    return sources_mod.Sources(
        refund_tags=refund_tags, clickup_list=list_id,
        open_days=int(window.get("open_active_days") or 30),
        decided_days=int(window.get("decided_days") or 14))


def _identity_cache(cfg: "Cfg", problems: list[str]):
    """Resolve an Intercom contact at most once per account per tick.

    Identity is resolved LAZILY, only when it can change the outcome: the bell is the first rung
    and needs no identity, so a 50,000-row tick must not perform 8,000 Intercom searches before
    deciding anything. It is used for the states with no bell kind (an erasure ack) and when the
    ladder actually reaches the Intercom rung.
    """
    memo: dict[str, tuple[str, str]] = {}

    def resolve(email: str, user_id: str, detail: dict[str, Any],
                hint: str = "") -> tuple[str, str]:
        """`(contact_id, lookup_error)`. A non-empty `lookup_error` means we could not find out
        whether this account has an Intercom contact — NOT that it has none. The email rung is
        reserved for the latter, so the caller must hold it when this is set."""
        if hint:
            return hint, ""
        key = f"{user_id}|{email}"
        if key not in memo:
            try:
                got = cfg.identity(email, user_id, detail) if (email or user_id) else ""
            except Exception as exc:                       # never let identity break a tick
                got = ""
                problems.append(f"identity lookup failed for {key}: {type(exc).__name__}")
                memo[key] = ("", f"identity lookup failed: {type(exc).__name__}")
                return memo[key]
            # The seam may answer a bare contact id (tests, older callers) or a `Contact` that
            # knows whether the lookup actually completed.
            if isinstance(got, str):
                memo[key] = (got, "")
            else:
                memo[key] = (str(getattr(got, "contact_id", "") or ""),
                             str(getattr(got, "lookup_error", "") or ""))
        return memo[key]

    return resolve


def _default_identity(email: str, user_id: str, detail: dict[str, Any]) -> Any:
    """The Intercom contact for this account, or a `Contact` saying why there is none.

    Returns the whole `Contact` (not just the id) so a lookup that FAILED stays distinguishable
    from one that completed and found no contact: only the second may fall to the email rung.
    """
    from request_comms import identity as identity_mod  # noqa: PLC0415

    return identity_mod.contact_for(email, user_id, query=sources_mod.trino_query)


@dataclass
class Plan:
    primary: Request
    decision: routing.Decision
    facts: dict[str, Any]
    members: list[Request] = field(default_factory=list)


def _tick_lock(store_path: str, *, blocking: bool = False):
    """One tick at a time, across processes.

    The ledger is append-only, so a `sending` claim is not a constraint: two ticks can both read an
    empty `blocking_map`, both append their claim, and both call the provider for the same
    (request, state) — two status lines, and an interleaved hash chain. An exclusive lock on the
    store's own lockfile makes the claim atomic by making the SECOND tick not exist.

    `stop` takes the SAME lock, blocking. A tick reads `store.stopped()` once, before it plans, so a
    stop that landed mid-tick would print "stopped for good" while the tick went on to send the very
    message it was told to suppress. Waiting for the in-flight tick makes that sentence true: either
    the tick has not started (it will see the stop) or it has finished.
    """
    import fcntl  # noqa: PLC0415 — POSIX only, and only the live driver needs it

    # The lock is taken BEFORE the store is opened, so on a first run the directory may not exist
    # yet. `Store` creates it too; doing it here keeps the lock from being the thing that fails.
    Path(store_path).parent.mkdir(parents=True, exist_ok=True)
    fh = open(store_path + ".lock", "a+")          # noqa: SIM115 - held for the whole tick
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
    except OSError:
        fh.close()
        return None
    return fh


def _drop_stopped(requests: list[Request], stopped: dict[str, set[str]],
                  summary: dict[str, Any]) -> tuple[list[Request], set[str]]:
    """Remove the requests a human stopped (empty state set = the whole request).

    Returns the survivors and the refs it took out, so the other ways a request can enter the plan
    (the kept-in-scope lookup) can be held without counting the same stop twice.
    """
    if not stopped:
        return requests, set()
    kept: list[Request] = []
    held: set[str] = set()
    for r in requests:
        states = stopped.get(r.ref)
        if states is None or not ("" in states or r.state in states):
            kept.append(r)
            continue
        held.add(r.ref)
        summary["held"].append({"request": r.ref, "reason": "stopped:manual"})
        summary["counts"]["stopped"] = summary["counts"].get("stopped", 0) + 1
    return kept, held


def tick(cfg: Cfg | None = None) -> dict[str, Any]:
    cfg = cfg or Cfg()
    now = cfg.now if cfg.now is not None else time.time()
    now_ts = stamp(now)
    summary: dict[str, Any] = {"at": now_ts, "mode": "", "sources": [], "counts": {}, "would_send": [],
                               "sent": [], "held": [], "problems": [], "exit": 0}

    if os.path.exists(cfg.kill_file):
        summary["mode"] = "killed"
        summary["problems"].append(f"kill file present: {cfg.kill_file}")
        return summary

    policy = lines.load(cfg.policy_path)
    problems = lines.validate(policy)
    if problems:
        summary.update(mode="refused", exit=2)
        summary["problems"].extend(problems)
        return summary

    live = (not cfg.dry_run) and os.path.exists(cfg.live_file) and lines.driver_enabled(policy)
    summary["mode"] = "live" if live else "dry-run"

    lock = _tick_lock(cfg.store_path)
    if lock is None:
        summary["mode"] = "busy"
        summary["problems"].append("another tick holds the store lock: this run sent nothing")
        return summary
    try:
        return _tick_locked(cfg, now, now_ts, policy, live, summary)
    finally:
        lock.close()


def _tick_locked(cfg: Cfg, now: float, now_ts: str, policy: dict[str, Any], live: bool,
                 summary: dict[str, Any]) -> dict[str, Any]:
    try:
        bans = cfg.bans if cfg.bans is not None else guard.load(now=now)
    except guard.BansUnreadable as exc:
        summary.update(mode="refused", exit=2)
        summary["problems"].append(f"ban list unreadable: {exc}")
        return summary
    if getattr(bans, "lens_unknown", ""):
        # The HOLD is right (a lens we cannot read means we cannot prove anyone is clear), but a
        # green tick is not: every credit, claim and merge request is suppressed, and the unit has
        # no `SuccessExitStatus=`, so exit 0 would leave a sustained lens outage looking healthy
        # while the feed is off. Same signal as an unreadable ban source, which is what this is.
        summary["exit"] = 3
        summary["problems"].append(f"fraud lens unreadable -> NOTHING is sent: {bans.lens_unknown}")

    src: Any = cfg.sources if cfg.sources is not None else _default_sources(policy)
    requests, reports = src.collect(now=now)
    summary["sources"] = [{"name": r.name, "status": r.status, "count": r.count, "error": r.error,
                           "stale_open": r.stale_open} for r in reports]
    summary["open_days"] = int(((policy.get("sources") or {}).get("window") or {}).get("open_active_days") or 30)
    # A lane with no reader yet is NOT a failure. `merge` and `refund` have no ticket->account
    # identity resolver, so they are `disabled` on every tick by design; failing the unit for them
    # left the hourly service permanently red and made a real outage in an enabled source
    # indistinguishable from the expected gap. They stay visible in the summary.
    off = [r for r in reports if r.status == "disabled"]
    if off:
        summary["disabled_sources"] = [{"name": r.name, "reason": r.error} for r in off]
    bad = [r for r in reports if r.status in ("unreadable", "unconfigured")]
    if bad:
        summary["exit"] = 3
        summary["problems"].append("unreadable/unconfigured sources (no messages for them): "
                                   + ", ".join(f"{r.name}={r.status}" for r in bad))
    usable = {r.name for r in reports if r.status == "ok"}
    if cfg.only:
        usable &= set(cfg.only)
    requests = [r for r in requests if r.type in usable]
    requests.sort(key=lambda r: (r.created_at or "", r.type, r.id))
    if cfg.limit:
        requests = requests[: cfg.limit]

    store = Store(cfg.store_path, now=now)
    try:
        latest = store.latest_per_ref()
        told = store.told_per_ref()
        attempted = store.attempted_per_ref()
        blocking = store.blocking_map()
        sent_today = store.sent_today(now_ts[:10])
        # A human `stop` is a STANDING instruction: it is read before planning and it does not expire
        # at the 48 h floor. Before this, `stop` wrote a synthetic `sent` row, so the request came
        # due again 48 h later (and if it had already been messaged, the command did nothing at all).
        stopped = store.stopped()
        requests, held_stopped = _drop_stopped(requests, stopped, summary)

        # Requests we have already messaged stay in scope after the update window closes on them.
        # Otherwise the 48 h floor silently ends for exactly the people we are mid-conversation
        # with: a request last touched 31 days ago and still open would never be measured again.
        # A stopped ref is never asked for: it would be re-added without the filter above (that path
        # does not come from the source read, so it is not a candidate for the stop check).
        seen = {r.ref for r in requests}
        keep = [ref for ref in told
                if ref not in seen and ref.split(":", 1)[0] in usable]
        # Only a WHOLE-request stop can be decided here: a state-specific stop cannot, because the
        # request's current state is unknown until the lookup answers and a stop on `verifying` says
        # nothing about `decided`. Excluding it here silenced every later state's reminder. The
        # lookup's own rows go through `_drop_stopped`, which knows the state.
        whole_stop = {ref for ref, states in stopped.items() if "" in states}
        for ref in [k for k in keep if k in whole_stop and k not in held_stopped]:
            summary["held"].append({"request": ref, "reason": "stopped:manual"})
            summary["counts"]["stopped"] = summary["counts"].get("stopped", 0) + 1
        keep = [k for k in keep if k not in whole_stop]
        if keep:
            reader = getattr(src, "already_told", None)
            if reader is not None:
                extra, failed = reader(keep)
                if failed:
                    # Their reminder is UNMEASURED, not met: say so and fail the tick, never let a
                    # timed-out id read look like "nothing left to tell".
                    summary["exit"] = 3
                    summary["counts"]["scope_unmeasured"] = len(failed)
                    summary["problems"].append(
                        f"kept-in-scope lookup failed for {len(failed)} request(s): their 48 h "
                        f"reminders are unmeasured this tick ({', '.join(failed[:5])})")
                # The kept-in-scope path is a SECOND way in, so the stop filter runs again on what
                # it returns: a previously sent request that a human stopped came straight back
                # through `already_told()` and the next floor tick messaged it anyway. This time it
                # can see the state, which is what makes a partial stop precise.
                extra, _ = _drop_stopped(list(extra or []), stopped, summary)
                if extra:
                    requests.extend(extra)
                    requests.sort(key=lambda r: (r.created_at or "", r.type, r.id))
                    summary["counts"]["kept_in_scope"] = len(extra)

        identify = _identity_cache(cfg, summary["problems"])
        emails: dict[str, str] = {}
        numeric = [r.user_id for r in requests if str(r.user_id).isdigit()]
        # The bulk email read is one replica query over thousands of ids: skip it while BOTH the
        # email rung and Intercom are switched off, which is the current state of the world.
        # Intercom is not independent of it: resolving an Intercom contact starts from the
        # confirmed email, so an Intercom-only configuration that skipped this read resolved an
        # empty address and held every line as `no_route`.
        if numeric and (lines.channel_conf(policy, "email").get("enabled")
                        or lines.channel_conf(policy, "intercom").get("enabled")):
            try:
                emails = sources_mod.account_emails(numeric, src.query)
            except RuntimeError as exc:
                summary["problems"].append(f"email lookup failed (no email route this tick): {str(exc)[:140]}")
        for r in requests:
            if not r.email and str(r.user_id).isdigit():
                r.email = emails.get(str(r.user_id), "")
        # An erasure request is keyed by its requester's email (or a contact id), so the daily cap
        # would treat that person as somebody else. Resolve the account id for the handful of those
        # rows - bounded by the erasure register, never a bulk scan.
        resolve = [r for r in requests if r.type == "erasure" and not str(r.user_id).isdigit() and r.email]
        if resolve:
            try:
                by_email: dict[str, str] | None = sources_mod.account_by_email(
                    [r.email for r in resolve], src.query)
            except RuntimeError as exc:
                # The cap cannot prove these are new people, and an erasure ack plus a credit
                # status on one day is exactly what the cap exists to prevent. Hold, do not guess.
                by_email = None
                summary["exit"] = 3
                summary["problems"].append(
                    f"erasure account lookup failed: {len(resolve)} erasure row(s) held because the "
                    f"daily cap cannot identify them ({str(exc)[:120]})")
            for r in resolve:
                uid = (by_email or {}).get(str(r.email).strip().lower(), "")
                if by_email is None:
                    r.detail["cap_identity_unresolved"] = True
                if uid:
                    r.detail["register_user_id"] = r.user_id
                    r.user_id = uid

        decisions: list[Plan] = []
        observed_new = held_new = 0
        for r in requests:
            # The fraud lens is a CREDIT/CLAIM construct (`policies/credit-trust-decide.json` +
            # the fraud-lens holds): it exists to stop us telling someone under a credit-fraud
            # investigation about their credits. It is not a licence to drop a legal obligation,
            # so the erasure and refund lanes are exempt by design - an acknowledgement of a data
            # removal request (or a refund already on a ticket) goes out whatever the lens says,
            # and the send is audited like any other. This also matches what happened before the
            # daily cap started resolving an erasure's email to its account id: the numeric deny
            # list never matched the register's email-shaped key.
            held_reason = "" if r.type in LENS_EXEMPT_TYPES else bans.held(r.user_id)
            told_row = told.get(r.ref)
            waiting_hint = bool(told_row) and str(told_row["state"]) == r.state
            # The register's own contact_id is the identity the intake already verified (r5);
            # an erasure request is not an account match problem.
            hint = str((r.detail or {}).get("contact_id") or "")
            if hint or routing.bell_key(policy, r, waiting=waiting_hint):
                contact, identity_unknown = hint, ""   # the bell can carry it: identity is not needed yet
            else:
                contact, identity_unknown = identify(r.email, r.user_id, r.detail or {}, hint)
            has_email = bool(r.email) and "@" in r.email
            d = routing.decide(r, policy=policy, now=now, held_reason=held_reason,
                               has_intercom_identity=bool(contact), has_email=has_email,
                               identity_unknown=bool(identity_unknown),
                               already_messaged_today=sent_today.get(r.cap_key, 0) >= 1,
                               core_delivered=str((r.detail or {}).get("notice_sent_at") or ""),
                               last_told_state=str(told_row["state"]) if told_row else "",
                               last_told_at=str(told_row["at"]) if told_row else "",
                               blocking=blocking.get(r.ref, set()),
                               render_facts={"slot": str((r.detail or {}).get("slot") or ""),
                                             "date": str((r.detail or {}).get("date") or "")})
            facts = {"email": r.email, "contact_id": contact, "waiting_on": r.waiting_on,
                     "identity_unknown": identity_unknown,
                     "conversation_id": str((r.detail or {}).get("conversation_id") or "")}
            decisions.append(Plan(r, d, facts))

            prev = latest.get(r.ref)
            # Observed rows exist so the report can measure silence while the driver is still dark:
            # one when we first see the request, one when its state changes, then a heartbeat every
            # 24 h — but never a heartbeat for a decided request (it can never become due again).
            if (prev is None or str(prev["state"]) != r.state
                    or (not r.terminal and _hours_since(str(prev["at"]), now) >= OBSERVE_EVERY_H)):
                store.append(request_type=r.type, request_id=r.id, user_id=r.user_id, outcome="observed",
                             at=now_ts, state=r.state, waiting_on=r.waiting_on,
                             last_told_state=str(told_row["state"]) if told_row else "",
                             last_told_at=str(told_row["at"]) if told_row else "",
                             next_due_at=routing.next_due(r.state, str(told_row["at"]) if told_row else "", r.terminal),
                             detail={"source": (r.detail or {}).get("source", ""), "created_at": r.created_at,
                                     "waiting_on_source": (r.detail or {}).get("waiting_on_source", "owning-table")})
                observed_new += 1

        breaches = {"target": 0, "floor": 0}
        for p in decisions:
            told_row = told.get(p.primary.ref)
            kind = routing.breach(p.primary, last_told_at=str(told_row["at"]) if told_row else "", now=now)
            if kind:
                breaches[kind] += 1
        summary["counts"]["breaches"] = breaches

        due = [p for p in decisions if p.decision.action == "send"]
        # Grouped by `cap_key`, the same normalised identity the cap counts with: `A@Example.com`
        # and `a@example.com` are one person, and grouping on the raw `user_id` built two plans and
        # sent them two messages in one day.
        by_user: dict[str, list[Plan]] = {}
        for p in due:
            by_user.setdefault(p.primary.cap_key, []).append(p)
        plan: list[Plan] = []
        digests = 0
        for uid, group in by_user.items():
            if len(group) == 1:
                plan.append(group[0])
                continue
            first = group[0]
            digest = routing.digest_for([g.primary for g in group], policy=policy,
                                        has_intercom_identity=bool(first.facts["contact_id"]),
                                        has_email=bool(first.facts["email"]),
                                        identity_unknown=bool(first.facts.get("identity_unknown")))
            if digest.action == "send":
                digests += 1
                plan.append(Plan(first.primary, digest, first.facts, [g.primary for g in group]))
            else:
                # The digest cannot go: our letter is unapproved and the members are not all one
                # kind, so there is no single bell that would be TRUE about all of them. Send the
                # OLDEST on its own instead of nothing (the daily cap still holds the user to one
                # message today) and let the rest wait their turn.
                plan.append(group[0])
                for g in group[1:]:
                    summary["held"].append({"request": g.primary.ref, "reason": f"{digest.reason}:digest_waiting"})
        summary["counts"]["digests"] = digests

        # `max_per_run` is a per-tick BUDGET, not a refusal. The backlog is real and known (7,869
        # users have an open credit or claim request that moved in the last 30 days), so refusing
        # the whole tick would mean no backlog is ever cleared — and the queue only shrinks by
        # sending. Oldest-due first, one message per user per day, and the remainder is COUNTED.
        deferred = 0
        if len(plan) > cfg.max_per_run:
            plan.sort(key=lambda p: (p.primary.created_at or "", p.primary.ref))
            deferred = len(plan) - cfg.max_per_run
            summary["problems"].append(
                f"{deferred} due message(s) deferred to the next tick (max_per_run={cfg.max_per_run}): "
                "the backlog is worked oldest-first, one message per user per day")
            plan = plan[:cfg.max_per_run]
        summary["counts"]["deferred"] = deferred

        allowed_rungs = routing.enabled_rungs(policy)
        chan = cfg.channels if cfg.channels is not None else channels_mod.Channels(policy=policy)
        audit_ok = True
        if live and plan:
            ok, why = audit.preflight(pending_path=cfg.audit_spool)
            if not ok:
                # Nothing has gone out yet and nothing will: a message nobody can audit should not
                # be sent, and finding that out AFTER the first one is one message too late.
                summary["exit"] = 5
                summary["problems"].append(f"audit surface unusable, nothing sent: {why}")
                summary["counts"]["deferred"] = len(plan)
                return summary
        for p in plan:
            assert p.decision.kind == "bell_only" or (p.decision.line is not None and p.decision.text)
            text = p.decision.text
            members = p.members or [p.primary]
            line_key = (p.decision.line.key if p.decision.line is not None
                        else f"bell:{p.decision.bell_key}")
            entry = {"request": p.primary.ref, "user": p.primary.user_id, "line": line_key,
                     "channel": p.decision.channel, "requests": [m.ref for m in members]}
            if not live:
                for m in members:
                    store.append(request_type=m.type, request_id=m.id, user_id=m.user_id, outcome="would_send",
                                 at=now_ts, state=m.state, channel_pref=p.decision.channel, waiting_on=m.waiting_on,
                                 line_key=line_key,
                                 detail={"channel": p.decision.channel, "line": line_key,
                                         "kind": p.decision.kind, "email": p.facts["email"],
                                         "contact_id": p.facts["contact_id"],
                                         "body_sha256": channels_mod.body_sha(text)})
                summary["would_send"].append(entry)
                continue
            # Claim every member of the line BEFORE the call: a crash can never double-send.
            for m in members:
                store.append(request_type=m.type, request_id=m.id, user_id=m.user_id, outcome="sending",
                             at=now_ts, state=m.state, channel_pref=p.decision.channel, waiting_on=m.waiting_on,
                             line_key=line_key,
                             detail={"channel": p.decision.channel, "kind": p.decision.kind,
                                     "body_sha256": channels_mod.body_sha(text)})
            # The idempotency epoch is the last ATTEMPT, not the last confirmed send. A reminder
            # whose reply was lost still consumed a key at the provider; reusing it at the next
            # boundary would let the gateway dedupe a message the user never got while the ledger
            # recorded a send. `told` stays the confirmed-send view for `last_told_*` below.
            attempt = attempted.get(p.primary.ref)    # sqlite3.Row: index, never .get()
            result, attempts, event_id = _deliver(chan, p, text, cfg, identify,
                                                  epoch=str(attempt["at"]) if attempt is not None else "",
                                                  allowed=allowed_rungs)
            # `unconfirmed` is a DEFINITE non-delivery (an all-false `visibility` means the item
            # reached nobody), so it is re-offerable — unlike `uncertain`, which is never repeated.
            outcome = {"sent": "sent", "rejected": "rejected", "unconfirmed": "rejected"}.get(
                result.status, "uncertain")
            audit_state, why = audit.record(audit.AuditRow(
                actor="request-comms", request_ref=p.primary.ref, state=p.primary.state,
                channel=result.channel, user_id=p.primary.user_id, message_ref=result.ref,
                body_sha=result.body_sha), pending_path=cfg.audit_spool, at=now_ts)
            if audit_state != "recorded":
                summary["problems"].append(f"audit row {audit_state}: {why}")
            stop_after = False
            if audit_state == "unavailable":
                audit_ok = False
                stop_after = True
            for m in members:
                store.append(request_type=m.type, request_id=m.id, user_id=m.user_id, outcome=outcome,
                             at=now_ts, state=m.state, channel_pref=result.channel, waiting_on=m.waiting_on,
                             line_key=line_key,
                             last_told_state=str(told[m.ref]["state"]) if m.ref in told else "",
                             last_told_at=str(told[m.ref]["at"]) if m.ref in told else "",
                             next_due_at=routing.next_due(m.state, now_ts, m.terminal),
                             detail={"channel": result.channel, "kind": p.decision.kind,
                                     "attempts": attempts, "provider_ref": result.ref, "reason": result.reason,
                                     "body_sha256": result.body_sha,
                                     # The MESSAGE EVENT, shared by every member of one digest. A
                                     # provider timeout answers `uncertain` with no message id, so
                                     # without this the report's cap proof fell back to the row id
                                     # and read one two-request digest as two messages.
                                     "event_id": event_id,
                                     "audit": audit_state})
            # The plan's channel is the INTENT (the first rung); the entry reports what actually
            # carried it, so a bell that fell through to Intercom is not logged as a bell.
            entry.update({"status": result.status, "provider_ref": result.ref, "reason": result.reason,
                          "channel": result.channel or entry["channel"]})
            summary["sent"].append(entry)
            if result.status in ("sent", "uncertain"):
                # `uncertain` means the provider may have delivered and we cannot prove either way.
                # Counting it keeps the 1/user/day promise; the alternative is a second message to
                # someone who already got the first, which is the failure this cap exists for.
                sent_today[p.primary.cap_key] = sent_today.get(p.primary.cap_key, 0) + 1
            elif result.status == "rejected":
                summary["problems"].append(f"{p.primary.ref}: not delivered ({result.reason})")
            if stop_after:
                rest = plan[plan.index(p) + 1:]
                summary["counts"]["deferred"] = len(rest)
                summary["problems"].append(
                    f"stopped {len(rest)} further send(s): the audit row could be neither recorded nor "
                    "spooled, and an unauditable message must not go out")
                break

        if not audit_ok and live:
            summary["exit"] = summary.get("exit") or 5
            summary["problems"].append("the audit row could neither be recorded nor spooled in LIVE mode: a message "
                                       "nobody can audit should not have gone out — stop the driver")

        for p in decisions:
            d = p.decision
            if d.action != "hold":
                continue
            r = p.primary
            prev = latest.get(r.ref)
            if (prev is not None and str(prev["outcome"]) == "held"
                    and str(prev["line_key"]) == d.reason and _hours_since(str(prev["at"]), now) < HELD_REPEAT_H):
                continue
            told_row = told.get(r.ref)
            store.append(request_type=r.type, request_id=r.id, user_id=r.user_id, outcome="held",
                         at=now_ts, state=r.state, waiting_on=r.waiting_on, line_key=d.reason,
                         last_told_state=str(told_row["state"]) if told_row else "",
                         last_told_at=str(told_row["at"]) if told_row else "",
                         detail={"reason": d.reason, "kind": d.kind})
            held_new += 1
            summary["held"].append({"request": r.ref, "reason": d.reason})

        summary["counts"].update({"requests": len(requests), "observed_new": observed_new,
                                  "held_new": held_new, "due": len(due), "planned": len(plan),
                                  "sent": sum(1 for e in summary["sent"] if e.get("status") == "sent"),
                                  "would_send": len(summary["would_send"]),
                                  "bans_held_ids": len(getattr(bans, "ids", set())),
                                  "lens_unknown": bool(getattr(bans, "lens_unknown", ""))})
    finally:
        store.close()
    return summary


def _deliver(chan: Any, p: Plan, text: str, cfg: Cfg, identify=None,
             epoch: str = "", allowed: set[str] | None = None) -> tuple[Any, list[dict[str, Any]], str]:
    """Climb the ladder — bell (when the state has a kind) -> Intercom -> email.

    The first UNCONFIRMED rung falls through (an all-false bell `visibility` means it reached
    nobody); an UNCERTAIN one stops the ladder, because a second copy of a status line is worse
    than none. A `bell_only` plan never climbs: it carries no text of ours, so there is nothing
    else to send.
    """
    attempts: list[dict[str, Any]] = []
    r, facts = p.primary, p.facts
    members = p.members or [p.primary]
    count = len(members)
    # The key identifies the MESSAGE EVENT, not the attempt: (request, state, cycle). Without the
    # cycle a 48 h reminder for a state we already told them reuses the first key, notify-gateway
    # answers its idempotent skip, and the ledger records a delivery that never happened. `epoch` is
    # the last time we told them anything about this request, so it is stable across a retry inside
    # one tick and distinct per reminder cycle.
    idem = f"request-status:{r.ref}:{r.state}:{epoch or 'first'}"
    if p.decision.kind == "bell_only":
        # No copy of OURS is approved for this state: the bell stands alone. Its words are the
        # catalog's (approved upstream), we only choose the kind and the moment.
        data = routing.bell_data(r, count=count, request_ids=[m.id for m in members])
        res = chan.bell(p.decision.bell_key, user_id=r.user_id, data=data, idempotency_key=idem)
        attempts.append({"channel": "bell", "status": res.status, "reason": res.reason, "ref": res.ref})
        return res, attempts, idem
    # A bell rung exists only for the states the catalog has a kind for (an erasure has none).
    # `allowed` is the policy's own switches: the ladder chooses the first rung, and the fallback
    # may only climb rungs that are switched on — otherwise a bell that reached nobody falls
    # through to Intercom on a host where Intercom is deliberately off.
    order = [c for c in routing.LADDER if allowed is None or c in allowed]
    contact = ""            # resolved at most once; the email rung needs the same answer
    unknown = str(facts.get("identity_unknown") or "")   # a lookup that FAILED, not one that found nothing
    last = None
    # A request that already names its thread (an erasure) keeps it. Otherwise ask the promise
    # ledger whether this contact is waiting on us in a conversation, and if so answer THERE
    # first: the bell would tell them in the app and leave the promise on the thread unkept.
    thread = str(facts.get("conversation_id") or "")
    if not thread and "intercom" in order:
        contact = str(facts.get("contact_id") or "")
        if not contact and identify is not None:
            contact, _ = identify(str(facts.get("email") or ""), r.user_id, r.detail or {}, "")
        thread = _waiting_thread(cfg, contact, r.type)
        if thread:
            order = ["intercom"] + [c for c in order if c != "intercom"]
    for channel in order:
        if channel == "bell":
            if not p.decision.bell_key:
                continue
            res = chan.bell(p.decision.bell_key, user_id=r.user_id, idempotency_key=idem,
                            data=routing.bell_data(r, count=count, request_ids=[m.id for m in members]))
        elif channel == "intercom":
            contact = contact or str(facts.get("contact_id") or "")
            if not contact and identify is not None:
                contact, _ = identify(str(facts.get("email") or ""), r.user_id, r.detail or {}, "")
            if not contact:
                continue
            res = chan.intercom(text, contact, admin_id=cfg.admin_id(), conversation_id=thread)
        elif channel == "email":
            email = str(facts.get("email") or "")
            if not email or "@" not in email:
                continue
            # Email is the NO-INTERCOM-IDENTITY rung (`routing.channels_for`). A fallback from a
            # rejected Intercom send must not quietly post to the same person's mailbox: an
            # Intercom refusal can be a channel-specific opt-out, and the identity that had the
            # contact is exactly the one this rung is not for. Resolved only while the Intercom
            # rung is live; with Intercom switched off there is no identity to consult.
            #
            # The same rule covers a lookup that FAILED. `routing.channels_for` already refuses
            # this rung for `identity_unknown` at planning time, but the ladder can reach email
            # later (a bell that reached nobody, an Intercom refusal) and resolve identity HERE,
            # where the planner never did. Discarding the error there sent the email anyway, which
            # is the whole finding: a timeout is not "this account has no Intercom contact".
            if "intercom" in order:
                contact = contact or str(facts.get("contact_id") or "")
                if not contact and identify is not None:
                    contact, unknown = identify(str(facts.get("email") or ""), r.user_id,
                                                r.detail or {}, "")
                if contact or unknown:
                    # A contact means this is not the email rung's user; an unknown lookup means we
                    # cannot tell, so we wait for the next tick rather than route around a
                    # preference we could not read.
                    continue
            res = chan.email(text, email=email, user_id=r.user_id, typ=r.type, request_ref=r.ref,
                             idempotency_key=idem, state=r.state)
        else:  # pragma: no cover
            continue
        attempts.append({"channel": channel, "status": res.status, "reason": res.reason, "ref": res.ref})
        last = res
        if res.status in ("sent", "uncertain"):
            return res, attempts, idem
    if last is None:
        why = ("identity_unknown: the Intercom lookup failed, so the email rung is held"
               if unknown else "no channel could carry it")
        return channels_mod.SendResult("rejected", "none", why), attempts, idem
    return last, attempts, idem


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="automatic request status updates")
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tick", help="one pass")
    t.add_argument("--live", action="store_true", help="send for real (also needs the live file and policy.enabled)")
    t.add_argument("--dry-run", action="store_true", help="record would_send rows; send nothing (default)")
    t.add_argument("--only", default="", help="comma list of request types")
    t.add_argument("--limit", type=int, default=0)
    t.add_argument("--max-per-run", type=int, default=MAX_PER_RUN)
    t.add_argument("--json", action="store_true")
    t.add_argument("--store", default=STORE)
    t.add_argument("--policy", default="")
    rp = sub.add_parser("report", help="time-to-first-message and the gap between messages")
    rp.add_argument("--days", type=int, default=7)
    rp.add_argument("--json", action="store_true")
    rp.add_argument("--store", default=STORE)
    ck = sub.add_parser("check", help="validate policies/request-status-lines.json")
    ck.add_argument("--policy", default="")
    sp = sub.add_parser("stop", help="the audited inverse of message.send")
    sp.add_argument("--request-ref", required=True)
    # Optional on purpose: omitting it stops the WHOLE request, which is the documented way to
    # silence somebody for good. `required=True` made that command exit 2 before writing anything,
    # so an operator following the runbook believed a request was stopped while the next live tick
    # could still message them.
    sp.add_argument("--state", default="",
                    help="silence this state only; omit to stop the whole request")
    sp.add_argument("--store", default=STORE)
    a = ap.parse_args(argv)

    if a.cmd == "tick":
        from request_comms import report as report_mod  # noqa: PLC0415

        if a.live and a.dry_run:
            # Two switches that disagree, and the dangerous one silently won: a cron line edited to
            # "add --dry-run" would have called providers for real. Refuse instead of guessing.
            ap.error("--live and --dry-run contradict each other: pass one")

        cfg = Cfg(store_path=a.store, policy_path=a.policy or lines.default_policy_path(),
                  only=tuple(x.strip() for x in a.only.split(",") if x.strip()),
                  limit=a.limit, max_per_run=a.max_per_run,
                  dry_run=not a.live, admin_id=_admin_id, identity=_default_identity,
                  thread_for=_default_thread_for)
        summary = tick(cfg)
        report_mod.write_snapshot(summary, cfg.report_dir)
        print(json.dumps(summary, indent=2, sort_keys=True) if a.json else report_mod.render_tick(summary))
        return int(summary.get("exit") or 0)
    if a.cmd == "report":
        from request_comms import report as report_mod  # noqa: PLC0415

        got = report_mod.build(a.store, days=a.days)
        print(json.dumps(got, indent=2, sort_keys=True) if a.json else report_mod.render(got))
        return 0 if not got.get("problems") else 3
    if a.cmd == "check":
        policy = lines.load(a.policy)
        problems = lines.validate(policy)
        for p in problems:
            print(f"PROBLEM: {p}")
        print("copy policy OK" if not problems else f"{len(problems)} problem(s)")
        return 0 if not problems else 1
    if a.cmd == "stop":
        typ, _, rid = a.request_ref.partition(":")
        # Serialize with the tick: see `_tick_lock`. Blocking, because a human asking for a stop
        # should wait out the tick in flight rather than be told "busy" and have to retry.
        lock = _tick_lock(a.store, blocking=True)
        store = Store(a.store)
        try:
            rows = [r for r in store.rows() if str(r["request_ref"]) == a.request_ref]
            already = store.stopped().get(a.request_ref, set())
            if "" in already or (a.state and a.state in already):
                print(f"{a.request_ref}{'@' + a.state if a.state else ''}: already stopped")
                return 0
            store.append(request_type=typ, request_id=rid,
                         user_id=str(rows[-1]["user_id"]) if rows else "",
                         outcome="stopped", state=a.state or "", line_key="stop:manual",
                         detail={"reason": "manual stop (the audited inverse of message.send)"})
            print(f"{a.request_ref}{'@' + a.state if a.state else ''}: stopped for good "
                  f"(a standing instruction the driver reads before planning, not a 48 h delay)")
        finally:
            store.close()
            if lock is not None:
                lock.close()
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
