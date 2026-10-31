"""Re-evaluate the `stale-velocity` class under the CURRENT rules (Fable [key=held-velocity-revalidate], f1 040).

These are user_verification_needed rows whose only standing verdict is `reject_high_velocity_profile` = 100. That rule
was retired as a hold (H-DevOps #4411 / IDP #1777). The pass is no-notify and writes no credit status. Per request it
writes one decider row (evidence_kind 'revalidate', reason_code revalidate_*, rule_version, mode shadow|apply) with
one of these outcomes:

  release_anchored  V9's latest verdict is APPROVE (same-run Spotify+Tidal), pop 1..59, no CURRENT rule fires
                    -> eligible for the ANCHORED path only (anchor upload + the executor's approve tray)
  blocked_stale_rule  as release_anchored, but core's stored verdict still carries the retired rule at 100, and
                    core's ANCHORED predicate refuses ANY firing reject_* (agentApprovalGuard anchorAllowedSql,
                    person path). Needs either a validator re-run that clears it (core no-notify re-validate:
                    the paused sweep path) or a core change that ignores retired rules. NOT approvable today.
  ask               the user owes proof: the standard ask by comm_state class on the outbound timer (no special note)
  hold              a CURRENT hard signal (account gate not allow, watchlisted, R8 account hold, another rule firing,
                    a big or unknown popularity; NOT a claim on the credited profile, the owner's normal state)
                    or an unreadable input (V9 unread, gate unknown); the current reason is written

Nothing is deleted; the stored verdict is untouched. The 7 users must still be green at run time: account gate allow,
not watchlisted, no R8 account hold.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

RULE_ID = "C:stale-velocity-revalidate/v1"
RETIRED_RULES = frozenset({"reject_high_velocity_profile"})     # IDP #1777 / H-DevOps #4411
BIG_POPULARITY = 60
#: The IDP validator's hold rules (processors/raw/validation/user_credit_validator.py). A stored verdict is a COMPLETE
#: current-rule evaluation only when every one of them was scored (QA #1539): velocity short-circuited the POSITIVE
#: score rules (approve_*, profile/track credit), which no approval here uses (approvals are ANCHORED only), but a
#: row whose map lacks any hold rule - or has no map at all - was never cleared and holds 'incomplete_rule_scores'.
REQUIRED_HOLD_RULES = ("reject_artist_credit", "reject_deleted_catalog_track", "reject_high_risk_profile",
                       "reject_individual_org_credit", "reject_publisher_label_credit")
EVIDENCE_KIND = "revalidate"
#: V9 WAIT classes that mean "the user owes proof" (a link / the other DSP / their own profile): only these become the
#: standard ask. Every other WAIT class (a contradiction such as dsp_conflict / others_only / one_*_conflict, a pending
#: or unknown read, an org role on a person profile, anchored_but_blocked) and DUPLICATE HOLD (doc-verify 154: the
#: paid user's 33 dsp_conflict rows are a hold signal, not an ask). A whitelist: a new class holds until listed.
OWES_PROOF_CLASSES = ("person_not_linked", "needs_profile_link", "single_dsp_anchor", "absent_on_spotify",
                      "absent_on_tidal")
DECISION_FOR = {"release_anchored": "approve", "blocked_stale_rule": "hold", "ask": "defer", "hold": "hold"}


def rule_version() -> str:
    return RULE_ID + "+" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]


@dataclass
class Out:
    request_id: str
    user_id: int
    outcome: str                      # release_anchored | blocked_stale_rule | ask | hold
    reason: str
    popularity: int | None
    paid: bool | None
    gate_state: str
    v9: str
    evidence: dict[str, Any] = field(default_factory=dict)


def user_green(uid: int, gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]]) -> tuple[str, str]:
    """(gate_state, why-not-green or '') for one user, read at run time. Never raises."""
    try:
        g = gate_fn(uid)
    except Exception as exc:  # noqa: BLE001
        return "unknown", f"account_gate_unknown:{str(exc)[:60]}"
    state = "allow" if g.allowed else str(g.decision)
    if not g.allowed:
        return state, f"account_gate_{state}"
    if (isinstance(g.payload, dict) and g.payload.get("watch")) or any(
            "watchlist" in r.lower() or "deny" in r.lower() for r in g.reasons):
        return state, "watchlisted_account"
    try:
        held = hold_fn(uid)
    except Exception as exc:  # noqa: BLE001
        return state, f"account_hold_unknown:{str(exc)[:60]}"
    if held:
        return state, "R8_account_hold"
    return state, ""


def evaluate(scope: list[tuple[str, int]], facts: dict[str, Any], v9: dict[str, str],
             gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]],
             paid_ids: frozenset[int] | None, v9_class: dict[str, str] | None = None,
             ) -> tuple[list[Out], dict[str, int]]:
    """One Out per in-scope request still pending in user_verification_needed; the rest are counted only.
    v9 = {request id: latest V9 verdict ('APPROVE' | 'WAIT' | ... | '' = unread)}."""
    rows: list[Out] = []
    skipped: dict[str, int] = {}
    green: dict[int, tuple[str, str]] = {}
    v9_class = v9_class or {}
    for rid, uid in scope:
        rid = rid.lower()
        f = facts.get(rid)
        if f is None or f.deleted or f.status != "user_verification_needed":
            k = "not_pending:" + ("missing" if f is None else "deleted" if f.deleted else str(f.status))
            skipped[k] = skipped.get(k, 0) + 1
            continue
        if uid not in green:
            green[uid] = user_green(uid, gate_fn, hold_fn)
        gate_state, not_green = green[uid]
        firing = sorted(k for k, v in f.rules.items() if v >= 100 and k.startswith(("reject_", "review_")))
        current = [k for k in firing if k not in RETIRED_RULES]
        stale = [k for k in firing if k in RETIRED_RULES]
        missing = [k for k in REQUIRED_HOLD_RULES if k not in (f.rules or {})]
        verdict = v9.get(rid, "")
        pop = f.popularity
        ev = {"stored_firing": firing, "retired_firing": stale, "v9_verdict": verdict or None,
              "v9_class": v9_class.get(rid) or None,
              "unscored_hold_rules": missing}
        if f.user_id != uid:
            outcome, why = "hold", "user_mismatch"
        elif not_green:
            outcome, why = "hold", not_green
        elif current:
            outcome, why = "hold", "current_rule:" + ",".join(current)
        elif missing:
            outcome, why = "hold", "incomplete_rule_scores:" + ",".join(missing)
        # hard signals hold BEFORE any V9 branch (QA #1539): a held row never reaches an ask either. A claim by the
        # submitter on the credited profile is NOT one: owning your own artist/producer profile is the normal state,
        # core's ANCHORED person path does not require its absence, and an ask to the profile owner is the right ask
        # (that guard is the executor's CLOSE rail, batch0: a reject must never hit a label/org owner).
        elif f.metadata_source == "client" or pop is None or not 1 <= pop < BIG_POPULARITY:
            outcome, why = "hold", f"big_or_unknown_popularity:{pop}"
        elif not verdict:
            outcome, why = "hold", "v9_unread"
        elif verdict == "APPROVE":
            if stale:
                outcome, why = "blocked_stale_rule", ("V9 APPROVE (same-run Spotify+Tidal), but core's stored verdict "
                                                      "still fires " + ",".join(stale) + "; core's ANCHORED predicate "
                                                      "refuses any firing reject_*")
            else:
                outcome, why = "release_anchored", "V9 APPROVE (same-run Spotify+Tidal), no current rule fires"
        elif verdict == "WAIT" and v9_class.get(rid, "") in OWES_PROOF_CLASSES:
            outcome, why = "ask", f"owes proof (V9 WAIT {v9_class[rid]}); the standard ask by comm_state class"
        else:
            outcome, why = "hold", f"v9:{verdict}:{v9_class.get(rid, '') or 'unknown'}"
        rows.append(Out(rid, uid, outcome, why, pop, None if paid_ids is None else uid in paid_ids, gate_state,
                        verdict or "unread", ev))
    rows.sort(key=lambda o: (o.paid is not True, o.user_id, o.request_id))
    return rows, skipped


def recheck_before_write(rows: list[Out], gate_fn: Callable[[int], Any],
                         hold_fn: Callable[[int], list[str]]) -> dict[int, str]:
    """f1 contract: every user is green at run start AND immediately before any write. Re-reads each user once; a user
    who is no longer green turns every one of their rows into a hold with the current reason. Returns
    {user id: why} for the users downgraded."""
    changed: dict[int, str] = {}
    for uid in sorted({o.user_id for o in rows}):
        state, why = user_green(uid, gate_fn, hold_fn)
        if why:
            changed[uid] = why
            for o in rows:
                if o.user_id == uid and o.outcome != "hold":
                    o.outcome, o.reason, o.gate_state = "hold", "not_green_before_write:" + why, state
    return changed


def summary(rows: list[Out]) -> dict[str, Any]:
    """would-release / would-ask / would-hold counts by user (Fable's shadow report shape)."""
    by_user: dict[int, dict[str, int]] = {}
    totals: dict[str, int] = {}
    holds: dict[str, int] = {}
    for o in rows:
        by_user.setdefault(o.user_id, {})
        by_user[o.user_id][o.outcome] = by_user[o.user_id].get(o.outcome, 0) + 1
        totals[o.outcome] = totals.get(o.outcome, 0) + 1
        if o.outcome == "hold":
            k = o.reason.split(":")[0]
            holds[k] = holds.get(k, 0) + 1
    return {"totals": totals, "hold_reasons": holds,
            "by_user": {str(u): {**c, "paid": any(o.paid for o in rows if o.user_id == u)}
                        for u, c in sorted(by_user.items())}}


def record(db: sqlite3.Connection, run_id: str, mode: str, rows: list[Out], now: datetime) -> int:
    """Append one decider row per request (shadow or apply). The stored verdict is never touched."""
    from credit_review import coded_close
    coded_close.ensure_columns(db)
    ver = rule_version()
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    for o in rows:
        db.execute(
            "INSERT INTO decisions (run_id, decided_at, request_id, user_id, popularity, big_track, decision, reason,"
            " evidence_kind, paid_priority, mode, reason_code, rule_version, expected_status, gate_state, v9_anchor,"
            " intake_ids, evidence_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (run_id, at, o.request_id, o.user_id, o.popularity, 1 if (o.popularity or 0) >= BIG_POPULARITY else 0,
             DECISION_FOR[o.outcome], o.reason[:600], EVIDENCE_KIND, None if o.paid is None else int(o.paid), mode,
             "revalidate_" + o.outcome, ver, "user_verification_needed", o.gate_state, o.v9, "[]",
             json.dumps(o.evidence)))
    db.commit()
    return len(rows)


def v9_latest(ids: list[str], path: str, version: str | None = None) -> dict[str, str]:
    return {rid: v for rid, (v, _c) in v9_read(ids, path, version).items()}


def v9_read(ids: list[str], path: str, version: str | None = None) -> dict[str, tuple[str, str]]:
    """{request id: the latest V9 verdict THIS verifier produced from its OWN capture} - the same provenance the
    anchor builder demands (dspverify Store.latest_captured_for, QA #1539): current verifier version, a `verify`
    run, and a packet naming a capture request this store filed for this credit request. Eval / caller-supplied
    packet verdicts and older versions never count. Read-only; missing = absent (= v9_unread). Raises when the store
    cannot be read."""
    if version is None:
        from credit_verify.dspverify import VERSION as version
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
    try:
        caps: dict[str, set[str]] = {}
        for cap_id, ids_json in con.execute("SELECT capture_request_id, request_ids_json FROM dsp_captures"):
            try:
                caps[str(cap_id)] = {str(x).lower() for x in json.loads(ids_json or "[]")}
            except ValueError:
                continue
        out: dict[str, tuple[str, str]] = {}
        for rid in (x.lower() for x in ids):
            for verdict, cls, cap_id, packet_json in con.execute(
                    "SELECT v.verdict, v.reason_class, v.capture_request_id, v.packet_json FROM dsp_verdicts v JOIN dsp_runs r "
                    "ON r.run_id = v.run_id WHERE lower(v.request_id) = ? AND v.version = ? AND r.kind = 'verify' "
                    "ORDER BY v.id DESC LIMIT 1", (rid, version)):
                try:
                    packet_cap = (json.loads(packet_json or "{}").get("capture") or {}).get("request_id")
                except ValueError:
                    packet_cap = None
                if cap_id and rid in caps.get(str(cap_id), set()) and packet_cap == cap_id:
                    out[rid] = (str(verdict or ""), str(cls or ""))
        return out
    finally:
        con.close()
