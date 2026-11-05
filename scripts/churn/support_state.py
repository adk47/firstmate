#!/usr/bin/env python3
"""support_state.py: who is waiting on us, measured, in one store.

Generalises the 60-day measurement (firstmate data dir, NOT in this repo:
firstmate/data/support-churn-winback-fable-c1/measure/
churn-support-join.py) into a nightly sweep with three modes:

    --paying                  every user in /var/lib/credit-trust/paying-users.json
                              (the PREVENT signal: who is waiting on us NOW)
    --churned-since 60d       everyone who cancelled in the window (the report's
                              baseline; T1/T2/T3 as the report defines them)
    --user <id>               one user, on demand (console answer; no store write
                              unless --write)

Sources, all read-only: Intercom conversation search + GET, the core replica
through trino-query.sh (users, subscriptions, credit_requests, claiming), the
hydra verify ledger and proof store opened mode=ro, and ClickUp list
901000600160. The only write is /var/lib/hydra/churn/support-state.sqlite.

Nightly cost is bounded and incremental:
  - a conversation SEARCH row already carries who spoke last and when, so the
    enumeration is ~90 requests for a 120-day window;
  - a /conversations/{id} GET (needed only for OUR last message and the
    customer's LAST message) is paid once per conversation and stored in
    conv_state, so an unchanged thread is never re-read;
  - --conv-budget / --max-seconds cap the GET stage; an unread conversation
    keeps its previous facts, so a user is never downgraded to "clean" on
    missing evidence.

Definition of done it serves: `--churned-since 60d` reproduces the report's
T1 86 / T2 81 / T3 184 and $5,371 within 5%, because the stage rules here ARE the
report's (scripts/churn/stages.py, same regex tables, same courtesy/promise/ask
filters).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from churn import intercom as ic_mod          # noqa: E402
from churn import sources as src_mod         # noqa: E402
from churn import stages                     # noqa: E402
from churn.store import Store, utcnow        # noqa: E402

PAYING_FILE = os.environ.get("CREDIT_TRUST_PAYING_USERS_FILE", "/var/lib/credit-trust/paying-users.json")
POLICY = str(Path(__file__).resolve().parents[2] / "policies" / "churn-risk.json")
CLOSED_TASK_STATUSES = {"resolved", "closed", "complete", "completed", "done", "cancelled",
                        "canceled", "deferred", "duplicate"}


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%SZ')}] {msg}", file=sys.stderr, flush=True)


def load_policy(path: str = POLICY) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError) as exc:
        log(f"policy {path} unreadable ({exc}); built-in thresholds used")
        return {}


def paying_ids(path: str = PAYING_FILE) -> list[int]:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    ids = doc.get("ids") if isinstance(doc, dict) else doc
    if not isinstance(ids, list):
        raise SystemExit(f"{path}: no ids list")
    return sorted({int(i) for i in ids if str(i).isdigit()})


def parse_window(text: str) -> float:
    """'60d' / '7d' / '36h' -> seconds."""
    t = (text or "").strip().lower()
    unit = t[-1:] if t[-1:].isalpha() else "d"
    num = t[:-1] if t[-1:].isalpha() else t
    try:
        n = float(num)
    except ValueError:
        raise SystemExit(f"cannot read the window {text!r} (use 7d, 36h, 60d)")
    return n * (86400.0 if unit == "d" else 3600.0 if unit == "h" else 86400.0)


def plan_prices(policy: dict[str, Any]) -> dict[str, float]:
    """List MRR per plan, from the policy (report section 0's table is the default)."""
    table = ((policy.get("mrr") or {}).get("plan_list_usd")) or {}
    out = {str(k).lower(): float(v) for k, v in table.items() if isinstance(v, (int, float))}
    return out


DEFAULT_PRICE = 12.50


def default_price(policy: dict[str, Any]) -> float:
    """The price of a plan the table does not name: policy `mrr.default_usd`."""
    try:
        return float((policy.get("mrr") or {}).get("default_usd", DEFAULT_PRICE))
    except (TypeError, ValueError):
        return DEFAULT_PRICE


def list_mrr(plan: str | None, prices: dict[str, float], default: float = DEFAULT_PRICE) -> float:
    return prices.get(str(plan or "").lower(), default)


def renewal_iso(sub: dict[str, Any], plan: str | None = None) -> str | None:
    """The renewal date: details.expiresAt, else periodStart + the plan's interval."""
    expires = stages.iso_to_ts(sub.get("expires_at"))
    if expires:
        return stages.ts_to_iso(expires)
    start = stages.iso_to_ts(sub.get("period_start"))
    if not start:
        return None
    interval = 365 * stages.DAY if "annual" in str(plan or "").lower() else 30 * stages.DAY
    return stages.ts_to_iso(start + interval)


def churn_anchor(churn_row: dict[str, Any] | None, now: float) -> float:
    """The moment the state is measured at: the cancel time for a churned user, now otherwise."""
    if churn_row:
        at = stages.iso_to_ts(churn_row.get("cancelled_at"))
        if at:
            return at
    return now


# -- one user's row --------------------------------------------------------
def build_row(*, uid: int, mode: str, anchor: float, facts: dict[str, Any],
              threads: list[dict[str, Any]], t: stages.Thresholds,
              require_no_note: bool, run_id: str,
              churn: dict[str, Any] | None = None) -> dict[str, Any]:
    """Classify one user and shape the store row."""
    cls = stages.classify_user(
        anchor=anchor, threads=threads,
        open_requests=facts.get("open_requests") or [],
        pending_claims=facts.get("pending_claims") or [],
        tasks=facts.get("tasks") or [],
        tells=facts.get("tells") or [], proof_filed=facts.get("proof") or [],
        t=t, require_no_note=require_no_note)
    sub = facts.get("sub") or {}
    plan = (churn or {}).get("plan") or sub.get("plan")
    return {
        "user_id": uid,
        "mode": mode,
        "tier": cls.tier,
        "cause_class": cls.cause_class,
        "kinds": stages.risk_kinds(cls, t),
        "evidence": [i.as_dict() for i in cls.issues],
        "anchor": stages.ts_to_iso(anchor),
        "ball_days": round(cls.ball_days, 2),
        "mrr_list": facts.get("mrr_list"),
        "renews_at": facts.get("renews_at"),
        "intercom_conv_ids": cls.conv_ids,
        "open_request_ids": cls.open_request_ids,
        "paying": int(mode == "paying" or bool(sub)),
        "churned_at": (churn or {}).get("cancelled_at"),
        "plan": plan,
        "cancel_reason": (churn or {}).get("reason") or sub.get("cancel_reason"),
        "service": (churn or {}).get("service") or sub.get("service"),
        "checked_at": utcnow(),
        "run_id": run_id,
    }


# -- conversations ---------------------------------------------------------
def thread_facts(conv: dict[str, Any]) -> dict[str, Any]:
    """A stored (or freshly read) conversation as the stage's thread dict.

    Reconstructed from the four facts a GET buys (the opening body, our last
    body, the customer's last body, who spoke last) instead of the transcript:
    stages.classify_thread reads exactly the last event, our last event, and the
    customer's words, so this is faithful and survives a store round-trip. The
    customer's last body is carried even when WE spoke last: it is the text the
    cause class is read from.
    """
    last_who = conv.get("last_who") or "contact"
    opening_at = float(conv.get("created_at") or 0)
    last_at = float(conv.get("last_at") or 0)
    admin_at = float(conv.get("admin_at") or 0)
    events = [{"at": opening_at, "who": "contact", "body": conv.get("opening_body") or ""}]
    if last_who == "contact":
        if admin_at:
            events.append({"at": admin_at, "who": "us", "body": conv.get("our_last_body") or ""})
        events.append({"at": last_at, "who": "contact", "body": conv.get("last_body") or ""})
    else:
        if conv.get("last_body"):
            events.append({"at": admin_at or opening_at, "who": "contact",
                           "body": conv.get("last_body") or ""})
        events.append({"at": last_at, "who": "us", "body": conv.get("our_last_body") or ""})
    events.sort(key=lambda e: e["at"] or 0)
    return {"id": conv.get("conv_id"), "created_at": opening_at,
            "updated_at": float(conv.get("updated_at") or 0),
            "state": conv.get("state") or "", "events": events,
            "rating": conv.get("rating")}


def read_conversations(*, store: Store, ic: ic_mod.Intercom, since: float,
                       id_map: dict[str, int], uids: set[int], t: stages.Thresholds,
                       now: float) -> tuple[dict[int, list[dict[str, Any]]], dict[str, Any]]:
    """Enumerate the window, keep OUR users' threads, GET the ones we must read.

    A thread is read when the search row cannot decide it:
      - the customer spoke last past the threshold (risk class a; and the cause
        class needs their LAST message, not just the opening one), or
      - the thread is open with our last word past the promise threshold
        (risk class c: was that word a promise?).
    Everything else is decided from the search row and stored without a GET, and a
    row that was stored that way is re-asked on every later sweep: once it crosses a
    threshold it is read for real, or its last_body would stay empty forever.
    """
    stored = store.convs()
    by_user: dict[int, list[dict[str, Any]]] = {}
    # `with_ext` / `unmapped` are the COVERAGE numbers: a conversation whose contact
    # carries no external_id (or one we cannot map to a core user) is invisible to this
    # signal, and a silent drop there would look exactly like "nobody is waiting".
    stats = {"rows": 0, "ours": 0, "reused": 0, "to_read": 0, "read": 0,
             "with_ext": 0, "unmapped": 0}
    pending_read: list[tuple[str, dict[str, Any]]] = []
    for row in ic.search_conversations(since):
        stats["rows"] += 1
        th = ic_mod.thread_from_row(row)
        cid = th["id"]
        prev = stored.get(cid)
        fresh = prev is not None and float(prev.get("updated_at") or 0) >= th["updated_at"]
        if fresh:
            conv = dict(prev)
            stats["reused"] += 1
        else:
            conv = {"conv_id": cid, "updated_at": th["updated_at"], "created_at": th["created_at"],
                    "state": th["state"], "last_at": th["last_at"], "last_who": th["last_who"],
                    "admin_at": th["stats"]["last_admin_reply_at"],
                    "opening_body": next((e["body"] for e in th["events"] if e["who"] == "contact"), ""),
                    "last_body": th["events"][-1]["body"] if th["last_who"] == "contact" else "",
                    "our_last_body": th["events"][-1]["body"] if th["last_who"] == "us" else "",
                    "external_ids": th["external_ids"], "read_full": 0, "rating": th.get("rating")}
        exts = [str(x).lower() for x in (conv.get("external_ids") or []) if x]
        if exts:
            stats["with_ext"] += 1
        owners = {u for u in ({id_map.get(x) for x in exts}) if u and u in uids}
        if not owners:
            if exts:
                stats["unmapped"] += 1
            continue
        stats["ours"] += 1
        # a reused row that was never read full was decided from a search row: the GET
        # is still owed once it qualifies, or its last_body stays empty forever and the
        # cause class falls back to the opening message
        if not fresh or not conv.get("read_full"):
            age_last_h = (now - float(conv.get("last_at") or 0)) / 3600.0
            want = (conv.get("last_who") == "contact" and age_last_h >= t.customer_last_hours) or \
                   (conv.get("state") == "open" and conv.get("last_who") == "us"
                    and age_last_h >= t.promise_no_followup_hours)
            if want:
                pending_read.append((cid, conv))
            elif not fresh:
                store.put_conv(conv)          # the search row decided it; no GET paid
        for uid in owners:
            by_user.setdefault(uid, []).append(conv)

    pending_read.sort(key=lambda cv: float(cv[1].get("last_at") or 0))   # longest wait first
    stats["to_read"] = len(pending_read)
    if pending_read:
        fulls = ic.conversations([cid for cid, _ in pending_read])
        stats["read"] = len(fulls)
        index = {cid: conv for cid, conv in pending_read}
        for cid, doc in fulls.items():
            conv = index.get(cid)
            if conv is None:
                continue
            events = doc.get("events") or []
            us_last = next((e for e in reversed(events) if e["who"] == "us"), None)
            contact_last = next((e for e in reversed(events) if e["who"] == "contact"), None)
            conv["read_full"] = 1
            conv["our_last_body"] = (us_last or {}).get("body") or ""
            conv["last_body"] = (contact_last or {}).get("body") or ""
            conv["admin_at"] = float((us_last or {}).get("at") or conv.get("admin_at") or 0)
            if events:
                conv["last_at"] = float(events[-1].get("at") or conv.get("last_at") or 0)
                conv["last_who"] = events[-1]["who"]
            if not conv.get("opening_body"):
                conv["opening_body"] = (contact_last or {}).get("body") or ""
            conv["promise"] = int(bool(us_last) and stages.is_promise((us_last or {}).get("body") or ""))
            conv["ask"] = int(bool(us_last) and stages.is_ask((us_last or {}).get("body") or ""))
            conv["courtesy"] = int(bool(contact_last)
                                   and stages.is_courtesy((contact_last or {}).get("body") or ""))
            conv["rating"] = doc.get("rating") or conv.get("rating")
            store.put_conv(conv)
    return by_user, stats


# -- the sweep -------------------------------------------------------------
def identity_map(identities: dict[str, dict[str, Any]]) -> dict[str, int]:
    """Every key an Intercom contact's external_id might be -> the core user id."""
    out: dict[str, int] = {}
    for uid_s, ident in identities.items():
        uid = int(uid_s)
        for key in (ident.get("auth0"), ident.get("profile"), ident.get("email")):
            if key:
                out[str(key).lower()] = uid
    return out


def clickup_by_user(tasks: list[dict[str, Any]],
                    identities: dict[str, dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    """Open ClickUp intake tasks per user, matched on the task's User Email / Muso URL."""
    email_to_uid: dict[str, int] = {}
    profile_to_uid: dict[str, int] = {}
    for uid_s, ident in identities.items():
        uid = int(uid_s)
        if ident.get("email"):
            email_to_uid[ident["email"].lower()] = uid
        for key in (ident.get("profile"), ident.get("auth0")):
            if key:
                profile_to_uid.setdefault(str(key).lower(), uid)
    out: dict[int, list[dict[str, Any]]] = {}
    for task in tasks:
        if (task.get("status") or "").lower() in CLOSED_TASK_STATUSES:
            continue
        fields = {str(k).lower(): v for k, v in (task.get("fields") or {}).items()}
        uid = email_to_uid.get(str(fields.get("user email") or "").strip().lower())
        if uid is None:
            tail = str(fields.get("muso url") or "").rstrip("/").rsplit("/", 1)[-1].lower()
            uid = profile_to_uid.get(tail)
        if uid is None:
            continue
        out.setdefault(uid, []).append(task)
    return out


def sweep(*, mode: str, store: Store, sources: src_mod.Sources, ic: ic_mod.Intercom | None,
          t: stages.Thresholds, now: float, policy: dict[str, Any], ids: list[int] | None = None,
          window_s: float | None = None, dry_run: bool = False, no_clickup: bool = False,
          run_id: str | None = None, limit: int = 0) -> dict[str, Any]:
    run_id = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    # only a FULL sweep may satisfy risk.py/weekly_line.py's last_run(mode) guards, so a
    # canary records its run under its own mode and can never pass for the real thing
    limited = limit > 0
    run_mode = f"{mode}-canary" if limited else mode
    if not dry_run:
        store.start_run(run_id, run_mode)
    prices = plan_prices(policy)
    price_default = default_price(policy)

    churn_rows: dict[int, dict[str, Any]] = {}
    if mode == "churned":
        since = now - (window_s or 60 * 86400)
        cancelled = sources.cancelled_since(since)
        for c in cancelled:                        # one row per user: the newest cancel wins
            uid = c["user_id"]
            if uid not in churn_rows or c.get("cancelled_at", "") >= churn_rows[uid].get("cancelled_at", ""):
                churn_rows[uid] = c
        ids = sorted(churn_rows)
        log(f"churned since {stages.ts_to_iso(since)}: {len(cancelled)} subscription rows, {len(ids)} users")
        if limited:
            ids = ids[:limit]
        live = sources.subscriptions(ids)
        ids = [u for u in ids if str(u) not in live]      # cancelled, then came back
        log(f"{len(ids)} still churned (re-subscribers excluded)")
    elif mode == "paying":
        ids = ids if ids is not None else paying_ids()
        log(f"paying set: {len(ids)} users")
    ids = ids or []
    if limited:
        # --limit bounds the WORK, on both modes: a capped set still costs every GET and
        # replica query it did not skip, so the cap has to reach the churned branch too
        ids = ids[:limit]
        log(f"limited run: {len(ids)} users")

    identities = sources.users(ids)
    subs = sources.subscriptions(ids)
    reqs = sources.open_credit_requests(ids)
    claims = sources.pending_claims(ids)
    tells = sources.tells()
    proof = sources.proof_intake()
    log(f"replica+ledger: {len(identities)} identities, {len(subs)} live subs, "
        f"{sum(len(v) for v in reqs.values())} open credit requests, "
        f"{sum(len(v) for v in claims.values())} pending claims")

    tasks_by_uid: dict[int, list[dict[str, Any]]] = {}
    if not no_clickup:
        try:
            tasks = sources.clickup_tasks()
        except src_mod.SourceError as exc:
            sources.errors.append(str(exc))
            tasks = []
        tasks_by_uid = clickup_by_user(tasks, identities)
        log(f"clickup: {len(tasks)} tasks, {sum(len(v) for v in tasks_by_uid.values())} open "
            f"tasks on {len(tasks_by_uid)} users")

    id_map = identity_map(identities)
    by_user: dict[int, list[dict[str, Any]]] = {}
    ic_stats: dict[str, Any] = {}
    if ic is not None:
        by_user, ic_stats = read_conversations(store=store, ic=ic,
                                               since=now - t.thread_lookback_days * 86400,
                                               id_map=id_map, uids=set(ids), t=t, now=now)
        log(f"intercom: {ic_stats}")

    tiers: dict[str, int] = {}
    mrr_by_tier: dict[str, float] = {}
    kind_counts: dict[str, int] = {}
    for uid in ids:
        sub = subs.get(str(uid)) or {}
        email = (identities.get(str(uid)) or {}).get("email", "").lower()
        tell_rows = list(tells.get(str(uid)) or []) + list(tells.get(email) or [])
        facts = {
            "sub": sub,
            "open_requests": reqs.get(str(uid)) or [],
            "pending_claims": claims.get(str(uid)) or [],
            "tasks": tasks_by_uid.get(uid) or [],
            "tells": [stages.iso_to_ts(x.get("at")) for x in tell_rows],
            "proof": [stages.iso_to_ts(x.get("at")) for x in (proof.get(str(uid)) or [])],
            "renews_at": renewal_iso(sub, sub.get("plan")),
            "mrr_list": list_mrr((churn_rows.get(uid) or {}).get("plan") or sub.get("plan"), prices,
                                    price_default),
        }
        # the stage reads thread_facts' shape (id/created_at/state/events); passing the raw
        # conv rows here classified every thread as "no events" and silently lost T1/T2
        # (found by the 2026-11-04 node-8 canary: T1 24 / T2 0 against the report's 86 / 81)
        threads = [thread_facts(c) for c in (by_user.get(uid) or [])]
        row = build_row(uid=uid, mode=mode, anchor=churn_anchor(churn_rows.get(uid), now),
                        facts=facts, threads=threads, t=t,
                        require_no_note=(mode == "paying"), run_id=run_id,
                        churn=churn_rows.get(uid))
        if row["tier"]:
            tiers[row["tier"]] = tiers.get(row["tier"], 0) + 1
            mrr_by_tier[row["tier"]] = mrr_by_tier.get(row["tier"], 0.0) + float(row["mrr_list"] or 0)
        for k in row["kinds"]:
            kind_counts[k] = kind_counts.get(k, 0) + 1
        if not dry_run:
            store.put_user(row)

    if not dry_run and mode == "paying" and not limited:
        dropped = store.delete_mode_users("paying", ids)
        if dropped:
            log(f"dropped {dropped} paying rows the sweep no longer sees")

    errors = len(sources.errors) + (len(ic.errors) if ic else 0)
    note = "; ".join((sources.errors + (ic.errors if ic else []))[:6])
    summary = {"run_id": run_id, "mode": mode, "users": len(ids), "tiers": tiers,
               "mrr_by_tier": {k: round(v, 2) for k, v in mrr_by_tier.items()},
               "mrr_total": round(sum(mrr_by_tier.values()), 2),
               "with_issue": sum(tiers.values()), "kinds": kind_counts,
               "intercom": ic_stats, "errors": errors, "error_notes": note, "dry_run": dry_run}
    if not dry_run:
        store.finish_run(run_id, users=len(ids), errors=errors, tiers=tiers, note=note)
    return summary


# The only case that may pay for a window walk, and never unbounded: an Intercom
# failure to read one contact's threads. ~90 pages x 25 cancellers an hour is what
# made the per-canceller path amplification, so both caps are enforced and logged.
FALLBACK_MAX_PAGES = 8
FALLBACK_MAX_SECONDS = 20.0


def user_threads(*, store: Store, ic: ic_mod.Intercom, ident: dict[str, Any],
                 since: float | None = None) -> tuple[list[dict[str, Any]], str]:
    """One user's threads without walking the fleet.

    The contact's own conversations are a few cheap per-contact calls (one per identity
    we hold, see `_contact_threads`) and the outcome is typed
    (`intercom.ContactThreads`): NO_IDENTITY / NOT_FOUND / NONE classify directly -
    that is the normal case for the ~84% of churners who never wrote in - and only
    ERROR falls back to a BOUNDED window walk (page + time cap, logged), because a
    failed read must not be reported as "no open issue".

    The nightly sweep already stored every thread it could attribute to our users,
    which is what covers a duplicate contact carrying the same auth0 id.
    """
    threads: list[dict[str, Any]] = []
    seen: set[str] = set()
    found = _contact_threads(ic=ic, ident=ident)
    rows = list(found.rows)
    if found.kind == ic_mod.ERROR:
        rows.extend(_window_fallback(ic=ic, ident=ident, since=since))
    if rows:
        fulls = ic.conversations([str(r.get("id")) for r in rows][:20])
        for r in rows:
            th = ic_mod.thread_from_row(r, full=fulls.get(str(r.get("id"))))
            seen.add(str(th["id"]))
            threads.append(th)
    stored = [c for c in store.convs_for_external_ids(
        [ident.get("auth0"), ident.get("profile"), ident.get("email")])
        if str(c.get("conv_id")) not in seen]

    if stored:
        fulls = ic.conversations([str(c["conv_id"]) for c in stored])
        for c in stored:
            doc = fulls.get(str(c["conv_id"])) or {}
            if not doc.get("events"):
                threads.append(thread_facts(c))
                continue
            row = {"id": c["conv_id"], "created_at": c["created_at"],
                   "updated_at": c["updated_at"], "state": c["state"],
                   "statistics": {"last_contact_reply_at": 0,
                                  "last_admin_reply_at": c["admin_at"]},
                   "contacts": {"contacts": [{"external_id": x}
                                             for x in (c.get("external_ids") or [])]}}
            threads.append(ic_mod.thread_from_row(row, full=doc))
    # the kind rides along so a caller can tell "nothing waiting" from "could not read"
    return threads, found.kind


def _contact_threads(*, ic: ic_mod.Intercom, ident: dict[str, Any]) -> ic_mod.ContactThreads:
    """The contact's conversations, asking EVERY identity we hold and merging the answers.

    Intercom keys a contact by ONE external_id, and the mobile app may have created it
    with the profile id while we ask by the auth0 subject first (or with the email
    alone). So neither a NOT_FOUND nor a contact with zero conversations on the first
    identity is evidence the person never wrote in: a second contact under another
    identity can carry the unanswered thread. Every identity is probed and the rows are
    deduped by conversation id, so the on-demand path cannot answer "no open issue"
    and let the watermark advance past a real cancellation.
    """
    probes: list[tuple[str, str]] = []
    for ext in (ident.get("auth0"), ident.get("profile")):
        if ext and str(ext) not in {v for _, v in probes}:
            probes.append(("external_id", str(ext)))
    email = ident.get("email")
    if email:
        probes.append(("email", str(email)))
    if not probes:
        return ic_mod.ContactThreads(ic_mod.NO_IDENTITY)
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    kinds: set[str] = set()
    why = ""
    for field, value in probes:
        found = ic.search_by_contact(**{field: value})
        kinds.add(found.kind)
        if found.kind == ic_mod.ERROR and not why:
            why = found.why
        for r in found.rows:
            cid = str(r.get("id"))
            if cid in seen:
                continue
            seen.add(cid)
            rows.append(r)
    if ic_mod.ERROR in kinds:
        return ic_mod.ContactThreads(ic_mod.ERROR, rows, why)
    if rows:
        return ic_mod.ContactThreads(ic_mod.FOUND, rows)
    if ic_mod.NONE in kinds:
        return ic_mod.ContactThreads(ic_mod.NONE)
    return ic_mod.ContactThreads(ic_mod.NOT_FOUND)


def _window_fallback(*, ic: ic_mod.Intercom, ident: dict[str, Any],
                     since: float | None) -> list[dict[str, Any]]:
    """Bounded, logged window walk for the ERROR case only.

    `since` is the sweep window (120 d default). The walk stops at FALLBACK_MAX_PAGES
    or FALLBACK_MAX_SECONDS, whichever comes first, and says which in `ic.errors`, so a
    broken lookup that we papered over is visible instead of silent.
    """
    now = time.time()
    want = {str(x).lower() for x in (ident.get("auth0"), ident.get("profile")) if x}
    email = str(ident.get("email") or "").lower()
    out: list[dict[str, Any]] = []
    progress: dict[str, int] = {}
    started = now
    errors_before = len(ic.errors)
    for row in ic.search_conversations(float(since if since is not None else now - 120 * 86400),
                                       max_pages=FALLBACK_MAX_PAGES, progress=progress):
        th = ic_mod.thread_from_row(row)
        exts = {str(x).lower() for x in (th.get("external_ids") or []) if x}
        if (want & exts) or (email and email in exts):
            out.append(row)
        if time.time() - started > FALLBACK_MAX_SECONDS:
            ic.errors.append(f"window fallback stopped on the time cap ({FALLBACK_MAX_SECONDS:.0f}s)")
            break
    # `progress["pages"]` counts SEARCH PAGES. Counting yielded rows instead (the first
    # cut did) reported a cap that never happened for any walk that merely saw 8
    # conversations, which is the message an operator reads to tell a papered-over
    # broken lookup from a real read (firstmate 2026-11-04, key
    # nm-review5-fallback-page-count). Only add it when the generator did not already
    # record its own page stop, so one cap is one line.
    capped = progress.get("pages", 0) >= FALLBACK_MAX_PAGES
    already = any("stopped at" in e and "page" in e for e in ic.errors[errors_before:])
    if capped and not already:
        ic.errors.append(f"window fallback stopped on the page cap ({FALLBACK_MAX_PAGES} pages)")
    return out


def user_open_tasks(uid: int, ident: dict[str, Any], *,
                    tick_tasks: dict[str, Any] | None,
                    sources: src_mod.Sources) -> tuple[list[dict[str, Any]], str]:
    """The open ClickUp intake tasks for ONE user, and how we know.

    ClickUp is the intake list for credit/claim/merge asks, and ~134 of the measured
    churned-with-issue users are carried ONLY by it, so the on-demand path cannot
    honestly answer "no open issue" without looking. It cannot look per canceller
    either: the list is ~14,100 tasks / ~141 pages, and the hourly alert may classify
    up to 25 cancellers, which is exactly the per-canceller fleet walk two review
    rounds removed. So the caller reads the list ONCE PER TICK (`tick_tasks`, either
    `{"ok": True, "tasks": [...]}` or `{"ok": False, "why": "..."}`) and every
    canceller in that tick is matched against it.

    The returned marker is recorded on the row: "read" means the whole open list was
    consulted, "not-read" means no list was supplied (a caller that opted out), and
    anything else is the reason it FAILED. A failed read must never render as the
    clean "no open issue" answer.
    """
    if tick_tasks is None:
        return [], "not-read"
    if not tick_tasks.get("ok"):
        return [], f"clickup read failed ({tick_tasks.get('why') or 'unknown'})"
    tasks = tick_tasks.get("tasks") or []
    hit = clickup_by_user(tasks, {str(uid): ident}).get(int(uid)) or []
    return hit, "read"


def sweep_user(*, uid: int, store: Store, sources: src_mod.Sources,
               ic: ic_mod.Intercom | None, t: stages.Thresholds, now: float,
               policy: dict[str, Any], write: bool = False,
               tick_tasks: dict[str, Any] | None = None,
               plan: str | None = None) -> dict[str, Any]:
    """One user, on demand. Same rules, no enumeration: their contact plus stored threads."""
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-user")
    identities = sources.users([uid])
    ident = identities.get(str(uid)) or {}
    subs = sources.subscriptions([uid])
    reqs = sources.open_credit_requests([uid])
    claims = sources.pending_claims([uid])
    tells = sources.tells()
    proof = sources.proof_intake()
    threads: list[dict[str, Any]] = []
    contact_kind = ""
    if ic is not None:
        threads, contact_kind = user_threads(store=store, ic=ic, ident=ident,
                                             since=now - 120 * 86400)
    sub = subs.get(str(uid)) or {}
    tasks, clickup_read = user_open_tasks(uid, ident, tick_tasks=tick_tasks, sources=sources)
    facts = {
        "sub": sub,
        "open_requests": reqs.get(str(uid)) or [],
        "pending_claims": claims.get(str(uid)) or [],
        "tasks": tasks,
        "tells": [stages.iso_to_ts(x.get("at")) for x in
                  (list(tells.get(str(uid)) or []) + list(tells.get(ident.get("email", "").lower()) or []))],
        "proof": [stages.iso_to_ts(x.get("at")) for x in (proof.get(str(uid)) or [])],
        "renews_at": renewal_iso(sub, sub.get("plan")),
        # a canceller has no live subscription row left, so the event's plan is the only
        # truthful price (the nightly churned sweep prices from its churn row the same way)
        "mrr_list": list_mrr(plan or sub.get("plan"), plan_prices(policy), default_price(policy)),
    }
    row = build_row(uid=uid, mode="paying" if sub else "churned", anchor=now, facts=facts,
                    threads=threads, t=t, require_no_note=True, run_id=run_id)
    # the read outcome, so a caller can tell "nothing is waiting" from "we read nothing":
    # intercom.py records transport failures on the client instead of raising them
    row["intercom"] = {"threads": len(threads), "contact": contact_kind or "no-intercom",
                      "errors": list(getattr(ic, "errors", []) or [])}
    # "read" / "not-read" / why it failed - see user_open_tasks()
    row["clickup"] = clickup_read
    if write:
        # one user is not a sweep: its run row must never stand in for the nightly one
        store.start_run(run_id, f"{row['mode']}-user")
        store.put_user(row)
        store.finish_run(run_id, users=1, errors=0, tiers={row["tier"]: 1} if row["tier"] else {},
                         note="on demand")
    return row


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="measure who is waiting on us")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--paying", action="store_true", help="the whole paying set (the PREVENT signal)")
    mode.add_argument("--churned-since", metavar="Nd", help="users cancelled in the window (60d, 7d)")
    mode.add_argument("--user", type=int, help="one user, on demand")
    ap.add_argument("--write", action="store_true", help="write the store (default for the two sweeps)")
    ap.add_argument("--dry-run", action="store_true", help="read everything, write nothing")
    ap.add_argument("--limit", type=int, default=0, help="cap the user set (a canary run)")
    ap.add_argument("--max-seconds", type=float, default=2400.0)
    ap.add_argument("--conv-budget", type=int, default=8000)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--no-intercom", action="store_true")
    ap.add_argument("--no-clickup", action="store_true")
    ap.add_argument("--policy", default=POLICY)
    ap.add_argument("--store", default=None)
    ap.add_argument("--json", action="store_true", help="the summary (or the one user's row) as JSON")
    args = ap.parse_args(argv)

    started = time.time()
    policy = load_policy(args.policy)
    t = stages.Thresholds.from_policy(policy)
    store_path = args.store or ((policy.get("store") or {}).get("support_state"))
    now = time.time()
    dry = args.dry_run or (args.user is not None and not args.write)
    store = Store(store_path, readonly=dry)
    sources = src_mod.Sources()
    ic = None if args.no_intercom else ic_mod.Intercom(workers=args.workers,
                                                      max_seconds=args.max_seconds,
                                                      conv_budget=args.conv_budget)
    try:
        if args.user is not None:
            row = sweep_user(uid=args.user, store=store, sources=sources, ic=ic, t=t, now=now,
                             policy=policy, write=args.write and not args.dry_run)
            print(json.dumps(row, indent=1, sort_keys=True))
            return 0
        ids = None
        window_s = None
        if args.paying:
            mode_s = "paying"
            ids = paying_ids()
        else:
            mode_s = "churned"
            window_s = parse_window(args.churned_since)
        summary = sweep(mode=mode_s, store=store, sources=sources, ic=ic, t=t, now=now,
                        policy=policy, ids=ids, window_s=window_s,
                        dry_run=dry, no_clickup=args.no_clickup, limit=args.limit)
    finally:
        store.close()
    summary["elapsed_s"] = round(time.time() - started, 1)
    if args.json:
        print(json.dumps(summary, sort_keys=True))
    else:
        print(f"mode={summary['mode']} users={summary['users']} with_issue={summary['with_issue']} "
              f"tiers={summary['tiers']} mrr_total=${summary['mrr_total']} "
              f"errors={summary['errors']} elapsed={summary['elapsed_s']}s"
              + (" (dry-run: nothing written)" if summary["dry_run"] else ""))
        if summary.get("error_notes"):
            print(f"notes: {summary['error_notes']}")
    return 0 if summary["errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
