#!/usr/bin/env python3
"""The established-claimant rule, in shadow: it reads, decides and records. It writes nothing.

The rule (firstmate 2026-11-14, ruled 2026-11-15):

  A pending credit request is ESTABLISHED when the same user already holds at least one
  approved credit in every role it claims, each with an artist of the same track, and
  the request sits on a profile with 100 or more approved requests of which 1% or fewer
  were rejected.

  An established request is APPROVED only when the validator itself approved it and
  nothing holds it. A hold is honoured for every person, whatever their record. A request
  the validator declined is never approved here (captain 2026-10-26: "do not approve
  validator-declined rows"): it is an ASK, the specific one, and an ask is not sent by
  this module either.

  An approval is the ACCOUNT's too. A request the row rule would approve is barred when
  its user or profile is on the decider's deny lists, or its user is held:

  * the deny lists are ``decide.Policy``'s, read the way the decider reads them: the
    policy file's two lists with the fraud watchlist unioned into both, two files.
  * held is ``comm_state.held_user_ids``, the one reader of the fraud lens's hold
    ledger: a user whose latest ledger row is a hold, or a release the lens's current
    scan does not confirm.

  Either read that fails stops the pass; a pass given neither, or the deny lists without
  the hold ledger, bars every approve as unmeasured.

  The account gate (``account_gate.py``, the one every approver calls before a write) is
  NOT asked here, and ``approve`` therefore means "before the account gate". Asking it is
  not a read: for an account it holds, the gate appends a hold line to its own ledger
  and, for an account new to it, adds the account to the fraud watch and queues a proof
  ask. That is right for a job about to approve and wrong for one that only counts. So the
  gate's BAND is not read: an approve on an amber (fraud watch) account stays an approve
  here, and the gate would refuse it. Measured 2026-11-16 09:45Z on the 2,115 rows the row
  rule approved: 27 on the deny lists (every watchlisted one among them), 348 more of held
  users, and 376 of the 1,740 left on an amber account (doc: "The account stage").

What this module is, and is not:

  * It has NO writer. There is no admin API call, no customer message and no ledger of
    record in it. A pass reads the core replica and writes two files: the decisions
    (canonical JSONL, one row per established request) and the funnel (counts per step
    and per bar). Turning any row of that file into an approval is a new approval
    automation: a ``policies/credit-approval-automation.json`` row and a recorded captain
    decision, in another change.
  * It runs by itself. ``established-claimant.timer`` runs ``tick`` once a day; nobody
    has to start it, and nothing has to be removed first. A pass whose reads all finished
    is published under ``STATE_DIR/runs/<UTC time>/`` and ``STATE_DIR/latest`` points at
    it. A pass that could not finish publishes nothing and fails, so ``latest`` is always
    the last complete answer and never a partial one.
  * It is not a rung of ``scale_drain.py`` yet. It is measured here first.
  * Every read is bounded: profiles in one grouped statement, then pending rows, held
    credits and verdicts by id list, ``CHUNK`` ids a statement. No statement joins the
    table to itself (2026-11-13: one did, and took node-8 into a global OOM).

Unmeasured is never a pass. A verdict that cannot be read, a hold table that cannot be
read and a request whose status changed between two reads are each counted under their
own name and approve nothing.

CLI (``scripts/established-claimant.py``, what the timer runs, or from ``scripts/``):
  python3 -m credit_review.established_claimant tick            the scheduled pass
  python3 -m credit_review.established_claimant run --out DIR   one pass into DIR
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

from . import verify_anchor as va
from .policy import SERVER_PROOF_REQUEST_MARKER, hold_causes, never_ask, server_approval_refusal

Query = Callable[[str], list[list[Any]]]
#: (user id, profile id) -> the bar that stops this account's approvals, or None.
#: Must be a pure read: the pass asks it about every request the row rule would approve.
#: A lookup also carries ``deny_lists_read`` and ``hold_ledger_read`` (``account_reader``
#: sets both), and ``run`` reports them in the funnel; a callable without them reports both
#: false, which is honest for a caller that supplied no reads.
Account = Callable[[str, str], "str | None"]

POLICY_PATH = Path(__file__).resolve().parents[2] / "policies" / "established-claimant.json"

#: The only mode this module has. The policy file says it too, and a file that says
#: anything else is refused: there is no code here for another mode to switch on.
SHADOW = "shadow"

PENDING_STATUSES: tuple[str, ...] = ("user_verification_needed", "unverified")

#: Ids per statement. 200 ids is ~4 s on the replica; 500 was 68 s (no pushdown).
CHUNK = 200

OUTCOMES: tuple[str, ...] = ("approve", "ask", "barred")

TABLE = "postgresql_core.public.credit_requests"

#: The track's artist ids, '|'-joined. Artists are matched by id only, so the same artist
#: under two id schemes does not match: the rule's count is a floor.
ARTIST_IDS = ("array_join(TRY(transform(CAST(CAST(spotifytrackartists AS json) AS array(json)),"
              " x -> json_extract_scalar(x, '$.id'))), '|')")

_PENDING_IN = ", ".join(f"'{s}'" for s in PENDING_STATUSES)

COUNT_SQL = f"""
SELECT status, count(*)
FROM {TABLE}
WHERE status IN ({_PENDING_IN}) AND deletedat IS NULL
GROUP BY 1
"""

#: Every profile with enough approved requests and something pending. The rejected share
#: is checked in code (``profile_passes``), so the bar is stated once.
PROFILE_SQL = f"""
SELECT CAST(profileid AS varchar), count_if(status = 'approved'), count_if(status = 'rejected')
FROM {TABLE}
WHERE deletedat IS NULL AND status IN ('approved', 'rejected', {_PENDING_IN})
GROUP BY 1
HAVING count_if(status = 'approved') >= {{min_approved}}
   AND count_if(status IN ({_PENDING_IN})) > 0
"""

PENDING_SQL = f"""
SELECT CAST(id AS varchar), CAST(userid AS varchar), CAST(profileid AS varchar), status,
       credits, {ARTIST_IDS}
FROM {TABLE}
WHERE status IN ({_PENDING_IN}) AND deletedat IS NULL AND profileid IN ({{ids}})
"""

#: A user's approved requests, grouped: the role list, the artists, who approved and the
#: lowest request id of the group (the one a reader can look up).
HELD_SQL = f"""
SELECT CAST(userid AS varchar), credits, {ARTIST_IDS},
       coalesce(json_extract_scalar(metadata, '$.approval.via'), ''),
       min(CAST(id AS varchar))
FROM {TABLE}
WHERE status = 'approved' AND deletedat IS NULL AND userid IN ({{ids}})
GROUP BY 1, 2, 3, 4
"""

#: The verdict, part by part. The whole ``verificationdata`` of one request can pass the
#: CSV reader's field limit, so only the parts read here are extracted, on the server: the
#: ones the hold reading uses, and the two more core's approval guard reads
#: (``policy.server_proof_reasons``). Column order is ``VERDICT_PARTS``.
VERDICT_PARTS: tuple[str, ...] = ("rule_risk_percent", "rule_errors", "fraud_hold",
                                  "hold_reason_codes", "is_approved", "total_risk_percent",
                                  "band_hint", "profile_risk_level")
VERDICT_SQL = (
    "\nSELECT CAST(id AS varchar), status, deletedat IS NOT NULL, verificationdata IS NULL,\n"
    + "".join(f"       json_format(json_extract(verificationdata, '$.{part}')),\n"
              for part in VERDICT_PARTS)
    + "       json_format(json_extract(metadata, '$.fraudRemoval')),\n"
    + "       json_format(json_extract(metadata, '$.precedentRevert')),\n"
    + f"       json_extract(metadata, '$.{SERVER_PROOF_REQUEST_MARKER}') IS NOT NULL,\n"
    + "       CAST(spotifypopularity AS varchar)\n"
    + f"FROM {TABLE}\nWHERE id IN ({{ids}})\n"
)

_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class EstablishedClaimantError(RuntimeError):
    pass


# ── policy ──────────────────────────────────────────────────────────────────

def load_policy(path: Path | str | None = None) -> dict[str, Any]:
    """The thresholds. A file that cannot be read, or asks for another mode, is an error."""
    try:
        raw = json.loads(Path(path or POLICY_PATH).read_text())
    except (OSError, ValueError) as exc:
        raise EstablishedClaimantError(f"policy unreadable: {exc}") from exc
    if not isinstance(raw, dict) or raw.get("mode") != SHADOW:
        raise EstablishedClaimantError(
            f"policy mode must be {SHADOW!r}: this module has no writer, and arming the rule "
            "is a new approval automation, not a mode")
    out: dict[str, Any] = {"mode": SHADOW}
    for key, kind in (("min_profile_approved", int), ("max_profile_rejected_share", float)):
        value = raw.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
            raise EstablishedClaimantError(f"policy {key} must be a number, not {value!r}")
        out[key] = kind(value)
    if out["min_profile_approved"] < 1 or out["max_profile_rejected_share"] > 1:
        raise EstablishedClaimantError("policy thresholds out of range")
    return out


def profile_passes(approved: int, rejected: int, policy: dict[str, Any]) -> bool:
    """100 or more approved, and rejected / (approved + rejected) at or under the share."""
    if approved < policy["min_profile_approved"]:
        return False
    return rejected <= policy["max_profile_rejected_share"] * (approved + rejected)


# ── the facts ───────────────────────────────────────────────────────────────

def _roles(credits: Any) -> list[str]:
    """``credits`` as a role list, read the way the drain reads it (one reader, not two)."""
    from .scale_drain import _roles as drain_roles  # noqa: PLC0415 - imports the admin client

    return drain_roles(credits)


def _artists(raw: Any) -> list[str]:
    return sorted({a for a in str(raw or "").split("|") if a})


def _uuids(ids: Iterable[str]) -> str:
    out = []
    for value in ids:
        text = str(value).strip().lower()
        if not _UUID_RE.match(text):
            raise EstablishedClaimantError(f"not a UUID, refusing to build a statement: {value!r}")
        out.append(f"UUID '{text}'")
    return ", ".join(out)


def _ints(ids: Iterable[str]) -> str:
    out = []
    for value in ids:
        text = str(value).strip()
        if not text.isdigit():
            raise EstablishedClaimantError(f"not a user id, refusing to build a statement: {value!r}")
        out.append(text)
    return ", ".join(out)


def _chunks(ids: Sequence[str]) -> Iterable[Sequence[str]]:
    for at in range(0, len(ids), CHUNK):
        yield ids[at:at + CHUNK]


def _count(value: Any, what: str) -> int:
    text = str(value).strip()
    if not text.isdigit():
        raise EstablishedClaimantError(f"{what}: not a count: {value!r}")
    return int(text)


def held_credit(held: dict[tuple[str, str, str], dict[str, Any]], user: str,
                artists: Sequence[str], role: str) -> dict[str, Any] | None:
    """The user's approved credit in ``role`` with one of ``artists``; the lowest anchor wins."""
    found = [held[(user, a, role)] for a in artists if (user, a, role) in held]
    if not found:
        return None
    return min(found, key=lambda h: h["anchor"])


def established(row: dict[str, Any], held: dict[tuple[str, str, str], dict[str, Any]]
                ) -> dict[str, dict[str, Any]] | None:
    """role -> the held credit that covers it, or ``None`` when any claimed role is uncovered.

    Every claimed role needs its own approved credit with an artist of this track. A
    request with no user, no roles or no artist ids cannot be matched at all.
    """
    if not row["user_id"] or not row["roles"] or not row["artists"]:
        return None
    cover = {}
    for role in row["roles"]:
        credit = held_credit(held, row["user_id"], row["artists"], role)
        if credit is None:
            return None
        cover[role] = credit
    return cover


def read_verdict(parts: Sequence[Any]) -> Any:
    """``verificationData`` rebuilt from the extracted parts; ``None`` when core holds none.

    A part that is absent stays absent, and a JSON ``null`` stays ``None``: the hold
    reading tells the two apart. A part that does not parse makes the verdict unreadable
    (returned as a string, which every reader below treats as not measured).
    """
    absent, *values = parts
    if str(absent).strip().lower() == "true":
        return None
    vd: dict[str, Any] = {}
    for key, raw in zip(VERDICT_PARTS, values):
        if raw is None or raw == "":
            continue
        try:
            vd[key] = json.loads(raw)
        except ValueError:
            return f"unreadable:{key}"
    return vd


#: Why an established request is not approved. ``bars`` on a row lists every one that
#: applies; ``reason`` is the first, in the order they are tested below.
BAR_NO_VERDICT = "no_verdict"
BAR_UNMEASURED = "verdict_unmeasured"
BAR_REMOVED = "removed_or_reverted_before"
BAR_UNCOVERED = "uncovered_hold"
BAR_ASKABLE = "askable_hold"
BAR_DECLINED = "validator_declined"
BAR_UNDECIDED = "validator_decision_unmeasured"
#: Prefix of a hold no document clears; the class follows (``hold:fraud``, ``hold:band_c``).
BAR_HOLD = "hold:"

APPROVE_REASON = "established_claimant"

#: The account stage, applied to a request the row rule would approve. Each one bars.
BAR_ACCOUNT_DENY = "account:deny_list"            # decide.Policy: the deny lists + the fraud watchlist
BAR_ACCOUNT_HELD = "account:held"                 # comm_state.held_user_ids: the fraud lens's hold ledger
BAR_ACCOUNT_UNMEASURED = "account:unmeasured"     # the pass was given no account reads


def account_reader(lists: Any, held: Iterable[str] | None) -> Account:
    """The account stage: the decider's deny lists, then the hold ledger. A pure lookup: no call
    leaves the process.

    ``lists`` is a loaded ``decide.Policy`` (or anything with its two sets), and its sets are
    used as loaded: ``Policy.load`` is what normalises them, and the match is the decider's
    own (``decide.py``: ``uid in deny_user_ids``, ``profile_id.lower() in deny_profile_ids``).
    A second normalisation here would make this stage a different predicate from the one
    that decides. ``held`` is ``comm_state.held_user_ids()``: user ids as strings, or ``None``
    when the ledger was not read, which bars every request the deny lists do not already bar
    as unmeasured rather than reading as "nobody is held".

    The returned lookup carries ``deny_lists_read`` and ``hold_ledger_read``, so a pass can
    report which reads it actually made."""
    denied_users, denied_profiles = lists.deny_user_ids, lists.deny_profile_ids
    held_users = None if held is None else {str(u) for u in held}

    def bar(user_id: str, profile_id: str) -> str | None:
        user = str(user_id)
        if user.isdigit() and int(user) in denied_users:
            return BAR_ACCOUNT_DENY
        if str(profile_id).lower() in denied_profiles:
            return BAR_ACCOUNT_DENY
        if held_users is None:
            return BAR_ACCOUNT_UNMEASURED
        if user in held_users:
            return BAR_ACCOUNT_HELD
        return None

    bar.deny_lists_read = True
    bar.hold_ledger_read = held_users is not None
    return bar


def decide(verdict: Any, removed: bool, roles: Sequence[str]) -> tuple[str, str, list[str]]:
    """(outcome, reason, every bar that applies) for an established request.

    ``approve`` needs all of: a readable verdict, the validator's own approval
    (``is_approved`` is the JSON ``true``), no hold cause of any kind, no hold code on the
    verdict that core's guard would not stop, and no earlier removal or revert.

    ``barred`` asks nobody: the verdict is missing or cannot be read, the request was
    removed or reverted before, or it carries a hold no document clears (fraud,
    impersonation, band C, a legal hold, a credit the profile already has, an evaluation
    error: ``policy.never_ask``). So does a request the validator APPROVED that still
    carries a hold code core's guard does not act on: the drain counts that row and never
    asks it (``held_by_validator``), and this rule reads it the same way.

    ``ask`` is everything else: the validator declined it, or did not record a decision,
    or holds it for a cause a document can clear. The established record does not
    outrank any of the three.
    """
    if verdict is None:
        return "barred", BAR_NO_VERDICT, [BAR_NO_VERDICT]
    causes = hold_causes(verdict) if isinstance(verdict, dict) else None
    if causes is None:
        bars = [BAR_UNMEASURED] + ([BAR_REMOVED] if removed else [])
        return "barred", BAR_UNMEASURED, bars
    hard: list[str] = [BAR_REMOVED] if removed else []
    never = never_ask(verdict, roles)
    if never:
        hard.append(BAR_HOLD + never.split(":", 1)[0])
    approved = verdict.get("is_approved")
    uncovered = bool(va.uncovered_holds(verdict))
    if approved is True and uncovered:
        hard.append(BAR_UNCOVERED)
    soft: list[str] = []
    if approved is False:
        soft.append(BAR_DECLINED)
    elif approved is not True:
        soft.append(BAR_UNDECIDED)
    if causes and not never:
        soft.append(BAR_ASKABLE)
    if hard:
        return "barred", hard[0], hard + soft
    if soft:
        return "ask", soft[0], soft
    return "approve", APPROVE_REASON, []


def core_guard(verdict: Any, proof_requested: bool) -> list[str]:
    """What core's approval guard would answer to an approve of this request ([] = allowed).

    ``policy.server_approval_refusal`` on the row as the server stores it: the reading the
    decider already uses before it sends an approval. It is recorded on every ``approve``
    row and decides nothing here. A request the validator scored as approved can still sit
    pending because core asked the claimant for proof (band hint B, or a proof request on
    file); the rule approves such a row on the claimant's record, and core would refuse
    that write as ``proof_required`` until the automation is registered there for it.
    """
    meta = {SERVER_PROOF_REQUEST_MARKER: True} if proof_requested else {}
    return server_approval_refusal({"verificationData": verdict, "metadata": meta})


# ── the run ─────────────────────────────────────────────────────────────────

def run(query: Query, policy: dict[str, Any] | None = None,
        account: Account | None = None) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """(decision rows sorted by request id, funnel). Read-only: ``query`` is the only I/O.
    ``account`` is asked only about a request the row rule would approve; with no ``account``
    every such request is barred as unmeasured. The account gate is never asked (module doc)."""
    policy = policy or load_policy()
    funnel: dict[str, Any] = {"mode": SHADOW, "policy": {k: policy[k] for k in sorted(policy)},
                              "deny_lists_read": bool(getattr(account, "deny_lists_read", False)),
                              "hold_ledger_read": bool(getattr(account, "hold_ledger_read", False)),
                              "account_gate_read": False}

    by_status = {str(s): _count(n, "pending count") for s, n in query(COUNT_SQL)}
    funnel["pending"] = sum(by_status.values())
    funnel["pending_by_status"] = dict(sorted(by_status.items()))

    profiles = sorted(
        str(pid).strip().lower() for pid, approved, rejected in
        query(PROFILE_SQL.format(min_approved=int(policy["min_profile_approved"])))
        if profile_passes(_count(approved, "approved"), _count(rejected, "rejected"), policy))
    funnel["eligible_profiles"] = len(profiles)

    pending: dict[str, dict[str, Any]] = {}
    for chunk in _chunks(profiles):
        for rid, uid, pid, status, credits, artists in query(PENDING_SQL.format(ids=_uuids(chunk))):
            user = str(uid or "").strip()
            pending[str(rid).strip().lower()] = {
                "request_id": str(rid).strip().lower(),
                "user_id": user if user.isdigit() else "",
                "profile_id": str(pid or "").strip().lower(),
                "status": str(status or ""),
                "roles": _roles(credits),
                "artists": _artists(artists),
            }
    funnel["on_eligible_profile"] = len(pending)
    funnel["no_user"] = sum(1 for r in pending.values() if not r["user_id"])
    funnel["no_roles"] = sum(1 for r in pending.values() if not r["roles"])
    funnel["no_artist_ids"] = sum(1 for r in pending.values() if not r["artists"])

    # only the (user, artist, role) triples a pending row could match are kept
    wanted = {(r["user_id"], a, role) for r in pending.values() if r["user_id"]
              for a in r["artists"] for role in r["roles"]}
    held: dict[tuple[str, str, str], dict[str, Any]] = {}
    users = sorted({u for u, _a, _r in wanted}, key=int)
    for chunk in _chunks(users):
        for uid, credits, artists, via, anchor in query(HELD_SQL.format(ids=_ints(chunk))):
            for artist in _artists(artists):
                for role in _roles(credits):
                    key = (str(uid).strip(), artist, role)
                    if key not in wanted:
                        continue
                    h = held.setdefault(key, {"anchor": str(anchor), "via": set()})
                    h["anchor"] = min(h["anchor"], str(anchor))
                    h["via"].add(str(via or ""))

    matched = {rid: cover for rid, cover in
               ((rid, established(r, held)) for rid, r in pending.items()) if cover}
    funnel["established"] = len(matched)

    rows: list[dict[str, Any]] = []
    bars: Counter[str] = Counter()
    outcomes: Counter[str] = Counter()
    reasons: Counter[str] = Counter()
    guards: Counter[str] = Counter()
    left = unread = row_rule_approves = 0
    for chunk in _chunks(sorted(matched)):
        seen = set()
        for rid, status, deleted, *rest in query(VERDICT_SQL.format(ids=_uuids(chunk))):
            rid = str(rid).strip().lower()
            if rid not in matched or rid in seen:
                continue
            seen.add(rid)
            if (str(status or "") not in PENDING_STATUSES
                    or str(deleted or "").strip().lower() == "true"):
                left += 1       # decided or deleted between the two reads: no longer ours to decide
                continue
            row, cover = pending[rid], matched[rid]
            *parts, fraud_removal, precedent_revert, proof_request, popularity = rest
            verdict = read_verdict(parts)
            removed = any(str(x or "").strip() not in ("", "null") for x in (fraud_removal, precedent_revert))
            outcome, reason, row_bars = decide(verdict, removed, row["roles"])
            if outcome == "approve":
                row_rule_approves += 1
                stop = (BAR_ACCOUNT_UNMEASURED if account is None
                        else account(row["user_id"], row["profile_id"]))
                if stop:
                    outcome, reason, row_bars = "barred", stop, [stop]
            outcomes[outcome] += 1
            reasons[f"{outcome}:{reason}"] += 1
            bars.update(row_bars)
            vias = {v for credit in cover.values() for v in credit["via"]}
            guard = (core_guard(verdict, str(proof_request).strip().lower() == "true")
                     if outcome == "approve" else None)
            if guard is not None:
                guards.update(guard or ["allowed"])
            pop = str(popularity or "").strip()
            rows.append({
                "anchors": {role: cover[role]["anchor"] for role in sorted(cover)},
                "bars": row_bars,
                "basis_via": sorted(vias),
                "core_guard": guard,
                "outcome": outcome,
                "popularity": int(pop) if pop.isdigit() else None,
                "profile_id": row["profile_id"],
                "reason": reason,
                "request_id": rid,
                "roles": row["roles"],
                "status": str(status),
                "user_id": row["user_id"],
                "validator_approved": verdict.get("is_approved") if isinstance(verdict, dict) else None,
            })
        unread += len(set(chunk) - seen)
    rows.sort(key=lambda r: r["request_id"])
    funnel["left_pending_between_reads"] = left
    funnel["verdict_row_not_returned"] = unread
    funnel["decided"] = len(rows)
    funnel["outcomes"] = {o: outcomes.get(o, 0) for o in OUTCOMES}
    funnel["reasons"] = dict(sorted(reasons.items()))
    funnel["bars"] = dict(sorted(bars.items()))
    funnel["approve_before_deny_lists"] = row_rule_approves
    approve = [r for r in rows if r["outcome"] == "approve"]
    per_user = Counter(r["user_id"] for r in approve)
    funnel["approve_users"] = len(per_user)
    funnel["approve_profiles"] = len({r["profile_id"] for r in approve})
    funnel["approve_largest_user"] = max(per_user.values(), default=0)
    funnel["approve_basis_only_precedent_v1"] = sum(
        1 for r in approve if r["basis_via"] == ["precedent_v1"])
    # what core's guard would answer to each approve: a row can carry several reasons
    funnel["approve_core_guard"] = dict(sorted(guards.items()))
    funnel["approve_core_would_refuse"] = sum(1 for r in approve if r["core_guard"])
    funnel["approve_popularity"] = dict(sorted(Counter(
        "unknown" if r["popularity"] is None else "0" if r["popularity"] == 0
        else "1-29" if r["popularity"] < 30 else "30-59" if r["popularity"] < 60 else "60+"
        for r in approve).items()))
    return rows, funnel


def serialize(rows: Sequence[dict[str, Any]]) -> bytes:
    """Canonical JSONL: sorted by request id, sorted keys, no clock and no run id."""
    return b"".join(json.dumps(r, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
                    for r in sorted(rows, key=lambda r: r["request_id"]))


# ── CLI ─────────────────────────────────────────────────────────────────────

# ── the scheduled pass ──────────────────────────────────────────────────────

#: Where the scheduled pass publishes. Under /var/lib, not /opt/hydra: the deploy rsync
#: overwrites the tree.
STATE_DIR = "/var/lib/hydra/established-claimant"
#: The stop switch. Absent unless someone places it; present, a pass reads nothing.
KILL_FILE = "/etc/hydra/established-claimant.disabled"
#: Published passes kept. One a day, about 7 MB each.
KEEP_RUNS = 14

_RUN_NAME = re.compile(r"^\d{8}T\d{6}Z$")


def _stamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def published(state_dir: Path | str | None = None) -> list[str]:
    """The published passes, oldest first."""
    runs = Path(state_dir or STATE_DIR) / "runs"
    if not runs.is_dir():
        return []
    return sorted(p.name for p in runs.iterdir() if p.is_dir() and _RUN_NAME.match(p.name))


def tick(query: Query, policy: dict[str, Any], account: Account | None = None) -> tuple[int, dict[str, Any]]:
    """One scheduled pass. Returns (exit code, what to print).

    0: published, or the stop switch is present and nothing was read.
    1: a read did not finish. Nothing is published and ``latest`` stays where it was.
    A replica error is not caught: it ends the pass with nothing published either.
    """
    if os.path.exists(KILL_FILE):
        return 0, {"skipped": f"{KILL_FILE} is present", "published": None}
    rows, funnel = run(query, policy, account)
    if funnel["verdict_row_not_returned"]:
        return 1, {"published": None, "funnel": funnel,
                   "error": "the verdict read did not return every row it asked for"}
    state = Path(STATE_DIR)
    runs = state / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    for stale in runs.glob(".tmp-*"):          # a pass killed before it published
        shutil.rmtree(stale, ignore_errors=True)
    name = _stamp()
    if (runs / name).exists():
        raise EstablishedClaimantError(f"a pass named {name} is already published")
    tmp = runs / f".tmp-{name}"
    tmp.mkdir()
    (tmp / "decisions.jsonl").write_bytes(serialize(rows))
    (tmp / "funnel.json").write_text(json.dumps(funnel, indent=1, sort_keys=True) + "\n")
    os.rename(tmp, runs / name)                # the pass exists whole, or not at all
    link = state / ".latest.tmp"
    if link.is_symlink() or link.exists():
        link.unlink()
    os.symlink(os.path.join("runs", name), link)
    os.replace(link, state / "latest")
    for old in published(state)[:-KEEP_RUNS]:
        shutil.rmtree(runs / old, ignore_errors=True)
    return 0, {"published": name, "funnel": funnel}


def _live_account() -> Account:
    """The deployed deny lists and hold ledger. Either that cannot be read stops the pass: an
    unread list must never read as "nobody is denied", nor an unread ledger as "nobody is held"."""
    from . import comm_state, decide as decider  # noqa: PLC0415 - only for a real run

    try:
        lists = decider.Policy.load()
    except (OSError, ValueError) as exc:
        raise EstablishedClaimantError(f"the decider's deny lists cannot be read: {exc}") from exc
    try:
        held = comm_state.held_user_ids()
    except comm_state.Unknown as exc:
        raise EstablishedClaimantError(f"the hold ledger cannot be read: {exc}") from exc
    return account_reader(lists, held)


def _cmd_tick(args: argparse.Namespace) -> int:
    from . import verify_notify  # noqa: PLC0415 - the replica client, only for a real run

    if os.path.exists(KILL_FILE):              # before the policy: a stopped pass reads nothing
        print(f"established_claimant: {KILL_FILE} is present; nothing read", file=sys.stderr)
        return 0
    policy = load_policy(args.policy)
    code, out = tick(verify_notify.trino, policy, _live_account())
    print(json.dumps(out, sort_keys=True))
    if code:
        print(f"established_claimant: {out['error']}; nothing published", file=sys.stderr)
    return code


def _cmd_run(args: argparse.Namespace) -> int:
    from . import verify_notify  # noqa: PLC0415 - the replica client, only for a real run

    policy = load_policy(args.policy)
    rows, funnel = run(verify_notify.trino, policy, _live_account())
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "decisions.jsonl").write_bytes(serialize(rows))
    (out / "funnel.json").write_text(json.dumps(funnel, indent=1, sort_keys=True) + "\n")
    print(json.dumps(funnel, sort_keys=True))
    # a row core did not return is a read that did not finish: say so in the exit code
    return 1 if funnel["verdict_row_not_returned"] else 0


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run", help="read the replica, decide, write decisions.jsonl and funnel.json")
    p.add_argument("--out", required=True, help="directory for the two files (created if absent)")
    p.add_argument("--policy", default=None, help="policy file (default: policies/established-claimant.json)")
    p.set_defaults(fn=_cmd_run)
    p = sub.add_parser("tick", help="the scheduled pass: publish under STATE_DIR, move `latest`")
    p.add_argument("--policy", default=None, help=argparse.SUPPRESS)
    p.set_defaults(fn=_cmd_tick)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except EstablishedClaimantError as exc:
        print(f"established_claimant: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(_main())
