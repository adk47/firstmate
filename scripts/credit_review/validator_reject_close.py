"""C5 coded rule `validator_reject` (conversion item 2; firstmate 174): close a request the IDP validator declined.

Deterministic, no model. A request in unverified / user_verification_needed gets a decider row decision='close',
reason_code 'reject_<rule>', only when ALL hold (any unreadable input = hold, never close):
  - a CURRENT reject_* validator rule fires at 100 (retired rules never count: reject_high_velocity_profile);
  - no review_* hold fires at the server's hold threshold (>= 30, policy.HOLD_RULE_MIN_SCORE; a hold is a human's);
  - the submitter holds NO claim of any type on the credited profile (batch0: a profile owner is never rejected);
  - popularity 1..59 from the server, not client-sourced;
  - the account gate allows, the account is not watchlisted and holds no R8 account hold;
  - V9 shows no DSP anchor on the request (an anchored credit is the approve path's, never a close).
Rows go to the decider ledger's append-only `decisions` in the coded-close shape (credit_review/coded_close.py),
mode shadow (default) or apply. Apply additionally needs policies/credit-validator-reject-close.json apply_enabled with approved_by / approval_ref (its own policy switch, currently off, plus the recorded approval, both fields unset; the r5 go-ahead it once waited on is retired), no kill file, and emits executor reject trays citing
decisions:<id> - the L12 executor then closes ONE PUT per user per day, paid first (#1553), re-checking every rail.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterable

RULE_NAME = "validator_reject"
RULE_ID = "C5:validator_reject/v1"
EVIDENCE_KIND = RULE_NAME
CLOSABLE_FROM = ("unverified", "user_verification_needed")
RETIRED_RULES = frozenset({"reject_high_velocity_profile"})
BIG_POPULARITY = 60
#: a review_* validator HOLD counts from the server's own threshold (policy.HOLD_RULE_MIN_SCORE = 30, the mirror of
#: core's validatorConflict), not from 100 (QA #1559): reject_x=100 + review_y=40 is a human's, never a close
REVIEW_HOLD_MIN = 30
POLICY = os.environ.get("VALIDATOR_REJECT_CLOSE_POLICY",
                        str(Path(__file__).resolve().parents[2] / "policies" / "credit-validator-reject-close.json"))
KILL_FILES = ("/etc/hydra/validator-reject-close.disabled", "/etc/hydra/fable-decider.disabled")


def rule_version() -> str:
    return RULE_ID + "+" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]


@dataclass
class Row:
    request_id: str
    user_id: int | None
    decision: str                 # close | hold
    reason_code: str              # reject_<rule> for a close; the hold reason's head otherwise
    reason: str
    expected_status: str | None
    popularity: int | None
    paid: bool | None
    gate_state: str
    v9: str
    evidence: dict[str, Any] = field(default_factory=dict)


def evaluate(scope: Iterable[str], facts: dict[str, Any], anchors: dict[str, str], gate_fn: Callable[[int], Any],
             hold_fn: Callable[[int], list[str]], paid_ids: frozenset[int] | None) -> tuple[list[Row], dict[str, int]]:
    """One Row per in-scope request still open; the rest are counted only."""
    rows: list[Row] = []
    skipped: dict[str, int] = {}
    users: dict[int, tuple[str, str]] = {}
    for rid in scope:
        rid = rid.lower()
        f = facts.get(rid)
        if f is None or f.deleted or f.status not in CLOSABLE_FROM:
            k = "not_open:" + ("missing" if f is None else "deleted" if f.deleted else str(f.status))
            skipped[k] = skipped.get(k, 0) + 1
            continue
        uid = f.user_id
        if uid not in users:
            users[uid] = _user_state(uid, gate_fn, hold_fn)
        gate_state, user_why = users[uid]
        fired = sorted(k for k, v in (f.rules or {}).items() if v >= 100 and k.startswith("reject_")
                       and k not in RETIRED_RULES)
        review = sorted(k for k, v in (f.rules or {}).items() if v >= REVIEW_HOLD_MIN and k.startswith("review_"))
        v9 = anchors.get(rid, "unknown")
        pop = f.popularity
        why = None
        if not fired:
            why = "no_current_reject_rule"
        elif review:
            why = "review_hold:" + ",".join(review)
        elif f.owns_profile is not False:
            why = "submitter_has_claim_on_profile" if f.owns_profile else "profile_claim_unknown"
        elif f.metadata_source == "client" or pop is None or not 1 <= pop < BIG_POPULARITY:
            why = f"big_or_unknown_popularity:{pop}"
        elif user_why:
            why = user_why
        elif v9 == "anchor":
            why = "dsp_anchor"
        elif v9 != "no_anchor":
            why = "v9_unread"
        ev = {"fired": fired, "review": review, "v9": v9, "rules": {k: v for k, v in (f.rules or {}).items()
                                                                    if k.startswith(("reject_", "review_"))}}
        rows.append(Row(rid, uid, "hold" if why else "close", why.split(":")[0] if why else fired[0],
                        why or f"the validator declined it: {','.join(fired)} fired; no claim on the profile",
                        f.status, pop, None if paid_ids is None or uid is None else uid in paid_ids, gate_state, v9,
                        ev))
    rows.sort(key=lambda r: (r.decision != "close", r.paid is not True, r.user_id or 0, r.request_id))
    return rows, skipped


def _user_state(uid: int | None, gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]]) -> tuple[str, str]:
    if not isinstance(uid, int):
        return "unknown", "user_unknown"
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
        if hold_fn(uid):
            return state, "R8_account_hold"
    except Exception as exc:  # noqa: BLE001
        return state, f"account_hold_unknown:{str(exc)[:60]}"
    return state, ""


def record(db: sqlite3.Connection, run_id: str, mode: str, rows: list[Row], now: datetime) -> dict[str, Any]:
    """Append every row (one transaction); a shadow close also gets a decision_outcomes 'shadow' line. A request with
    a live close row of this rule in this mode is never decided twice."""
    from credit_review import coded_close
    coded_close.ensure_columns(db)
    ver = rule_version()
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    out: dict[str, Any] = {"close": 0, "hold": {}, "duplicate": 0, "close_ids": []}
    db.commit()
    db.execute("BEGIN IMMEDIATE")
    try:
        done = {str(r).lower() for (r,) in db.execute(
            "SELECT request_id FROM decisions WHERE decision = 'close' AND evidence_kind = ? AND mode = ?",
            (EVIDENCE_KIND, mode))}
        for r in rows:
            if r.decision == "close" and r.request_id in done:
                out["duplicate"] += 1
                continue
            cur = db.execute(
                "INSERT INTO decisions (run_id, decided_at, request_id, user_id, popularity, big_track, decision, "
                "reason, evidence_kind, paid_priority, mode, reason_code, rule_version, expected_status, gate_state, "
                "v9_anchor, intake_ids, evidence_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, at, r.request_id, r.user_id, r.popularity, 1 if (r.popularity or 0) >= BIG_POPULARITY else 0,
                 r.decision, r.reason[:600], EVIDENCE_KIND, None if r.paid is None else int(r.paid), mode,
                 r.reason_code, ver, r.expected_status, r.gate_state, r.v9, "[]", json.dumps(r.evidence)))
            if r.decision == "close":
                out["close"] += 1
                out["close_ids"].append((cur.lastrowid, r))
                done.add(r.request_id)
                if mode == "shadow":
                    db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                               "VALUES (?,?,?,?,?)", (run_id, at, r.request_id, "close", "shadow"))
            else:
                out["hold"][r.reason_code] = out["hold"].get(r.reason_code, 0) + 1
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return out


def recheck_rows(rows: list[Any], facts_fn: Callable[[list[str]], dict[str, Any]] | None = None,
                 hold_fn: Callable[[int], list[str]] | None = None) -> dict[str, str]:
    """The executor's write-time re-check for these trays (QA #1559): {request id: '' | why} - the row's cited
    reject rule still fires at 100 and is current, no review_* hold appeared, no R8 account hold appeared. Fresh
    facts; any unreadable input refuses."""
    if facts_fn is None or hold_fn is None:
        from credit_review import comm_state
        from credit_review import fable_executor as fx
        facts_fn = facts_fn or fx.fetch_facts
        hold_fn = hold_fn or comm_state.account_hold_facts
    facts = facts_fn([r.request_id for r in rows])
    out: dict[str, str] = {}
    held: dict[int, str] = {}
    for r in rows:
        rid = r.request_id.lower()
        f = facts.get(rid)
        if f is None:
            out[rid] = "unknown:row_not_found"
            continue
        rule = str(r.rule)
        review = sorted(k for k, v in (f.rules or {}).items() if v >= REVIEW_HOLD_MIN and k.startswith("review_"))
        if rule in RETIRED_RULES or not rule.startswith("reject_") or (f.rules or {}).get(rule, 0) < 100:
            out[rid] = f"rule_no_longer_at_100:{rule}"
            continue
        if review:
            out[rid] = "review_hold:" + ",".join(review)
            continue
        uid = r.user_id
        if uid not in held:
            try:
                held[uid] = "R8_account_hold" if hold_fn(uid) else ""
            except Exception as exc:  # noqa: BLE001
                held[uid] = f"unknown:account_hold:{str(exc)[:60]}"
        out[rid] = held[uid]
    return out


def unpublished(db: sqlite3.Connection) -> list[tuple[int, Row]]:
    """Committed APPLY close rows of this rule with no 'published' tray mark (recovered by the next run)."""
    marks = {str(o) for (o,) in db.execute("SELECT outcome FROM decision_outcomes WHERE action = 'tray'")}
    out = []
    for did, rid, uid, status, paid, code, reason in db.execute(
            "SELECT id, request_id, user_id, expected_status, paid_priority, reason_code, reason FROM decisions "
            "WHERE mode = 'apply' AND decision = 'close' AND evidence_kind = ? ORDER BY id", (EVIDENCE_KIND,)):
        if not any(m.startswith(f"published:decisions:{did}:") for m in marks):
            out.append((did, Row(rid, uid, "close", code, reason, status, None, bool(paid), "", "")))
    return out


def tray_name(status: str, ids: list[int]) -> str:
    return f"validator-reject-{status}-" + hashlib.sha256(",".join(map(str, sorted(ids))).encode()).hexdigest()[:16] \
        + ".json"


def publish(db: sqlite3.Connection, run_id: str, tray_dir: str, now: datetime) -> list[str]:
    """Exactly-once tray publication (QA #1559): reconcile a staged .tmp whose marks committed, then stage each new
    tray as .tmp, commit its 'published' marks, THEN rename. Re-run after any failure; never two trays per row."""
    outdir = Path(tray_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    for (o,) in db.execute("SELECT DISTINCT outcome FROM decision_outcomes WHERE action = 'tray' "
                           "AND outcome LIKE 'published:%'"):
        name = str(o).partition(":decisions:")[2].partition(":")[2]
        if name and not (outdir / name).exists() and (outdir / (name + ".tmp")).exists():
            os.replace(outdir / (name + ".tmp"), outdir / name)
    staged = []
    # selection, staging and marking under ONE write lock (QA #1559): a concurrent publisher waits, then sees these
    # rows marked and publishes nothing for them
    db.commit()
    db.execute("BEGIN IMMEDIATE")
    try:
        for status, doc in tray_docs(unpublished(db)).items():
            name = tray_name(status, [int(x["coded_outcome"].split(":")[1]) for x in doc["rows"]])
            tmp = outdir / (name + ".tmp")
            tmp.write_text(json.dumps(doc, indent=1), encoding="utf-8")
            staged.append((name, tmp, doc))
        for name, _tmp, doc in staged:
            for x in doc["rows"]:
                db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES (?,?,?,?,?)",
                           (run_id, at, x["request_id"], "tray", f"published:{x['coded_outcome']}:{name}"))
        db.commit()
    except BaseException:
        db.rollback()
        raise
    paths = []
    for name, tmp, _doc in staged:
        os.replace(tmp, outdir / name)
        paths.append(str(outdir / name))
    return paths


def paid_refusal(paid_ids: frozenset[int] | None, why: str | None) -> str | None:
    """Apply needs a KNOWN paying list (paid-first under the cap, QA #1559); unknown = refused."""
    return None if paid_ids is not None else f"paying-user status unknown ({why}): apply refused"


def policy(path: str | None = None) -> dict[str, Any]:
    try:
        return json.loads(Path(path or POLICY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def apply_refusal(pol: dict[str, Any], kill_files: Iterable[str] = KILL_FILES) -> str | None:
    for k in kill_files:
        if os.path.exists(k):
            return f"kill file {k}"
    if pol.get("apply_enabled") is not True:
        return "policy apply_enabled is not true; apply is decided by this rule's policy switch"
    if not pol.get("approved_by") or not pol.get("approval_ref"):
        return "policy has no approved_by / approval_ref"
    return None


def tray_docs(close_ids: list[tuple[int, Row]]) -> dict[str, dict[str, Any]]:
    """One executor reject tray per expected status from APPLY close rows (the executor folds a user's rows into ONE
    PUT per day and re-checks every rail, V9 included)."""
    trays: dict[str, dict[str, Any]] = {}
    for did, r in close_ids:
        t = trays.setdefault(r.expected_status or "", {
            "action": "reject", "expected_status": r.expected_status, "refuse_if_dsp_anchor": True,
            "recheck_evidence": "validator_reject",
            "note": f"coded rule {RULE_ID}; rows from the decider ledger, never a hand list", "rows": []})
        t["rows"].append({"request_id": r.request_id, "user_id": r.user_id, "ruling_id": f"decisions-{did}",
                          "rule": r.reason_code, "paid": bool(r.paid), "coded_outcome": f"decisions:{did}",
                          "evidence": r.reason})
    return trays
