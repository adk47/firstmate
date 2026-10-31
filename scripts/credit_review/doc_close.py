"""C3 `junk_proof` and C8 `fraud_document`: document-based coded closes (captain 10-30 rules-to-code; Fable
[key=coded-close-store]). They are deterministic, use no model and make no per-item ruling (CAPTAIN 16:0xZ).

Both write decider rows in the coded-close shape (data/doc-verify-build-b1/coded-close-row-shape.md,
credit_review/coded_close.py) to the ledger's append-only `decisions`. This module writes SHADOW only. Apply is
refused until a shadow day and r5's GO, then a policy flip in a later PR. t01b's executor consumes the apply rows.

C3 `junk_proof`: a request closes only when ALL of the following hold.
  - EVERY filed document on the request is junk by `artifacts.classify` (`artifacts.junk_list`: a request with any
    non-junk document is never proposed). Every one of them was read under the current reader (`read`).
  - The request is TIED to a junk document: the document names its track, or its filing had <= SMALL_FILING open
    requests. The fan-out alone never ties (10-28: 162 of 198 were tied only that way and are held).
  - The common rails (below), with a watchlisted account held.

C8 `fraud_document`: a request closes only when ALL of the following hold.
  - Its standing doc-verify outcome is `forged_positive` (tray.forged_tray), and the stored pair still passes the
    rule: two families, not one edit, the tamper half on a LOCATED claim field (gate.positive_pair, #1489). Both
    pair signals are among the document's own signals.
  - The document covers EVERY request on the row. A request is covered when the document names it (title/ISRC read
    at >= 0.6) or its extracted credit supports it (`covers`). The <= 5-filing tie never counts for a deny.
  - The proof id maps to ONE document (no ruling-id collision).
  - The outcome has stood `forged_positive` for >= 24 h WITHOUT a break (the 24 h hold-silent; captain-1028-213x).
    Any other outcome on that claim since then restarts the clock.
  - The common rails. A watchlisted or gate-held account does NOT hold a fraud close (fraud accounts are the watched
    ones); a gate that cannot be read, or answers `unknown`, still does (QA #1571).
  - The entrypoint REQUIRES the rulings file (`--rulings`) so a document labelled `not` (a known false forgery)
    reaches this rule and holds; without the file the fraud rule refuses to run (QA #1571).

Common rails (any unreadable input = hold, never a close):
  - the request is open (unverified / user_verification_needed) and not deleted;
  - popularity 1..59, from the server and not client-sourced (a big track is a human's);
  - the account gate is readable, and allows (C3) or is any readable state (C8);
  - no R8 account hold;
  - V9 shows no DSP anchor (an anchored credit is the approve path's, never a close), and V9 was read.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

CLOSABLE_FROM = ("unverified", "user_verification_needed")
BIG_POPULARITY = 60
FRAUD_HOLD = timedelta(hours=24)
JUNK = "junk_proof"
FRAUD = "fraud_document"
RULE_IDS = {JUNK: "C3:junk_proof/v1", FRAUD: "C8:fraud_document/v1"}


def rule_version(kind: str) -> str:
    return RULE_IDS[kind] + "+" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]


@dataclass
class Row:
    request_id: str
    user_id: int | None
    decision: str                 # close | hold
    reason_code: str              # junk_proof / fraud_document for a close; the hold reason's head otherwise
    reason: str
    expected_status: str | None
    popularity: int | None
    paid: bool | None
    gate_state: str
    v9: str
    intake_ids: list[str] = field(default_factory=list)
    evidence: dict[str, Any] = field(default_factory=dict)


def _user_state(uid: Any, gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]],
                watch_blocks: bool) -> tuple[str, str]:
    if not isinstance(uid, int):
        return "unknown", "user_unknown"
    try:
        g = gate_fn(uid)
    except Exception as exc:  # noqa: BLE001
        return "unknown", f"account_gate_unknown:{str(exc)[:60]}"
    state = "allow" if g.allowed else str(g.decision)
    if state not in ("allow", "hold"):
        # QA #1571: a gate that ANSWERS unknown (its timeout / provider-error path) is unreadable for BOTH rules -
        # only a readable allow or hold is a state; anything else holds, watch_blocks or not
        return "unknown", f"account_gate_unknown:{state}"
    watched = (isinstance(g.payload, dict) and bool(g.payload.get("watch"))) or any(
        "watchlist" in r.lower() or "deny" in r.lower() for r in g.reasons)
    if watch_blocks:
        if not g.allowed:
            return state, f"account_gate_{state}"
        if watched:
            return state, "watchlisted_account"
    try:
        if hold_fn(uid):
            return state, "R8_account_hold"
    except Exception as exc:  # noqa: BLE001
        return state, f"account_hold_unknown:{str(exc)[:60]}"
    return state, ""


def _rails(f: Any, v9: str, user_why: str) -> str | None:
    pop = f.popularity
    if f.metadata_source == "client" or pop is None or not 1 <= pop < BIG_POPULARITY:
        return f"big_or_unknown_popularity:{pop}"
    if user_why:
        return user_why
    if v9 == "anchor":
        return "dsp_anchor"
    if v9 != "no_anchor":
        return "v9_unread"
    return None


def _open(f: Any) -> str | None:
    if f is None:
        return "not_open:missing"
    if f.deleted:
        return "not_open:deleted"
    if f.status not in CLOSABLE_FROM:
        return f"not_open:{f.status}"
    return None


def evaluate_junk(junk: dict[str, Any], doc_rows: list[dict[str, Any]], facts: dict[str, Any],
                  anchors: dict[str, str], gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]],
                  paid_ids: frozenset[int] | None) -> tuple[list[Row], dict[str, int]]:
    """C3 from `artifacts.junk_list(...)`: its tied decline proposals are the close candidates, its untied ones are
    held. `doc_rows` is the junk_list input (every filed document), for the `read` check."""
    read = {r["intake_id"]: bool(r.get("read")) for r in doc_rows}
    rows: list[Row] = []
    skipped: dict[str, int] = {}
    users: dict[Any, tuple[str, str]] = {}
    cands = [(p, True) for p in junk.get("decline_requests") or []] + \
        [(p, False) for p in junk.get("held_untied") or []]
    for p, tied in cands:
        rid = str(p["request_id"]).lower()
        f = facts.get(rid)
        why_open = _open(f)
        if why_open:
            skipped[why_open] = skipped.get(why_open, 0) + 1
            continue
        uid = f.user_id
        if uid not in users:
            users[uid] = _user_state(uid, gate_fn, hold_fn, watch_blocks=True)
        gate_state, user_why = users[uid]
        v9 = anchors.get(rid, "unknown")
        docs = [str(d) for d in p.get("documents") or []]
        why = None
        if not tied:
            why = "not_tied:only the fan-out links this request to a junk document"
        elif not docs or not all(read.get(d) for d in docs):
            why = "document_not_read"
        else:
            why = _rails(f, v9, user_why)
        rows.append(Row(rid, uid, "hold" if why else "close", why.split(":")[0] if why else JUNK,
                        why or f"every filed document is junk ({','.join(p.get('kinds') or [])}); {p.get('link')}",
                        f.status, f.popularity, None if paid_ids is None or uid is None else uid in paid_ids,
                        gate_state, v9, docs,
                        {"kinds": p.get("kinds"), "link": p.get("link"), "sys_001_only": p.get("sys_001_only"),
                         "documents": docs}))
    rows.sort(key=lambda r: (r.decision != "close", r.paid is not True, r.user_id or 0, r.request_id))
    return rows, skipped


def forged_since(db: sqlite3.Connection, version: str, outcome_id: int) -> str | None:
    """When the claim of this standing outcome row became `forged_positive` WITHOUT a break (current version): the
    first forged_positive row after the last other outcome on the same (filing, document, request, role)."""
    r = db.execute("SELECT coalesce(intake_id, ''), proof_id, request_id, role FROM dv_outcomes WHERE id=?",
                   (outcome_id,)).fetchone()
    if r is None:
        return None
    key = (version, *r)
    last_other = db.execute(
        "SELECT max(id) FROM dv_outcomes WHERE version=? AND coalesce(intake_id, '')=? AND proof_id=? AND "
        "request_id=? AND role=? AND outcome <> 'forged_positive' AND id <= ?", (*key, outcome_id)).fetchone()[0] or 0
    row = db.execute(
        "SELECT min(at) FROM dv_outcomes WHERE version=? AND coalesce(intake_id, '')=? AND proof_id=? AND "
        "request_id=? AND role=? AND outcome = 'forged_positive' AND id > ? AND id <= ?",
        (*key, last_other, outcome_id)).fetchone()
    return row[0] if row else None


def _ts(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def evaluate_fraud(deny: list[dict[str, Any]], since_fn: Callable[[int], str | None], facts: dict[str, Any],
                   anchors: dict[str, str], gate_fn: Callable[[int], Any], hold_fn: Callable[[int], list[str]],
                   paid_ids: frozenset[int] | None, now: datetime) -> tuple[list[Row], dict[str, int]]:
    """C8 from `tray.forged_tray(...)` deny rows. The Fable ruling field is NOT consulted (captain 16:0xZ: no
    per-item ruling from a Fable seat); the 24 h unbroken standing replaces it."""
    from credit_verify.docverify.gate import CLAIM_FIELDS, positive_pair
    rows: list[Row] = []
    skipped: dict[str, int] = {}
    users: dict[Any, tuple[str, str]] = {}
    proofs_of: dict[str, set[str]] = {}
    for d in deny:
        proofs_of.setdefault(d["ruling_id"], set()).add(d["proof_id"])
    for d in deny:
        sigs = d.get("fraud_signals") if isinstance(d.get("fraud_signals"), list) else []
        pair = d.get("fraud_pair") if isinstance(d.get("fraud_pair"), list) else []
        pair_ok = len(pair) == 2 and all(e in sigs for e in pair) and \
            positive_pair(pair, d.get("claim_fields") or CLAIM_FIELDS) is not None
        unique = len(proofs_of[d["ruling_id"]]) == 1
        covered = bool(d.get("requests")) and all(q.get("covers") for q in d["requests"])
        for q in d.get("requests") or []:
            rid = str(q["request_id"]).lower()
            f = facts.get(rid)
            why_open = _open(f)
            if why_open:
                skipped[why_open] = skipped.get(why_open, 0) + 1
                continue
            uid = f.user_id
            if uid not in users:
                users[uid] = _user_state(uid, gate_fn, hold_fn, watch_blocks=False)
            gate_state, user_why = users[uid]
            v9 = anchors.get(rid, "unknown")
            since = since_fn(int(q["outcome_id"]))
            st = _ts(since)
            why = None
            if d.get("ruling") == "not":
                why = "ruled_not_forged"           # a labelled false-forged document is never closed as fraud
            elif not pair_ok:
                why = "pair_no_longer_positive"
            elif not covered:
                why = "not_covered:the document must name each request (title/ISRC >= 0.6) or its credit support it"
            elif not unique:
                why = "proof_id_ambiguous"
            elif st is None:
                why = "forged_since_unknown"
            elif now - st < FRAUD_HOLD:
                why = f"within_24h_hold:since {since}"
            else:
                why = _rails(f, v9, user_why)
            rows.append(Row(rid, uid, "hold" if why else "close", why.split(":")[0] if why else FRAUD,
                            why or f"forged document: positive pair {[e.get('id') for e in pair]}, standing since "
                                   f"{since}", f.status, f.popularity,
                            None if paid_ids is None or uid is None else uid in paid_ids, gate_state, v9,
                            [d["intake_id"]] if d.get("intake_id") else [],
                            {"fraud_pair": pair, "signal_ids": [e.get("id") for e in pair],
                             "outcome_id": q["outcome_id"], "proof_id": d["proof_id"], "forged_since": since,
                             "role": q.get("role")}))
    rows.sort(key=lambda r: (r.decision != "close", r.paid is not True, r.user_id or 0, r.request_id))
    return rows, skipped


def record(db: sqlite3.Connection, run_id: str, kind: str, rows: list[Row], now: datetime,
           mode: str = "shadow") -> dict[str, Any]:
    """Append every row (one transaction) in the coded-close shape; a shadow close also gets a decision_outcomes
    'shadow' line. A request with a close row of this rule in this mode is never decided twice. SHADOW only here."""
    if mode != "shadow":
        raise ValueError("doc_close writes shadow rows only; apply comes after the shadow read and r5's GO")
    from credit_review import coded_close
    coded_close.ensure_columns(db)
    ver = rule_version(kind)
    at = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out: dict[str, Any] = {"close": 0, "hold": {}, "duplicate": 0}
    db.commit()
    db.execute("BEGIN IMMEDIATE")
    try:
        done = {str(r).lower() for (r,) in db.execute(
            "SELECT request_id FROM decisions WHERE decision = 'close' AND evidence_kind = ? AND mode = ?",
            (kind, mode))}
        for r in rows:
            if r.decision == "close" and r.request_id in done:
                out["duplicate"] += 1
                continue
            db.execute(
                "INSERT INTO decisions (run_id, decided_at, request_id, user_id, popularity, big_track, decision, "
                "reason, evidence_kind, paid_priority, mode, reason_code, rule_version, expected_status, gate_state, "
                "v9_anchor, intake_ids, evidence_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, at, r.request_id, r.user_id, r.popularity, 1 if (r.popularity or 0) >= BIG_POPULARITY else 0,
                 r.decision, r.reason[:600], kind, None if r.paid is None else int(r.paid), mode,
                 r.reason_code, ver, r.expected_status, r.gate_state, r.v9, json.dumps(r.intake_ids),
                 json.dumps(r.evidence, default=str)))
            if r.decision == "close":
                out["close"] += 1
                done.add(r.request_id)
                db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                           "VALUES (?,?,?,?,?)", (run_id, at, r.request_id, "close", "shadow"))
            else:
                out["hold"][r.reason_code] = out["hold"].get(r.reason_code, 0) + 1
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return out


def summary(rows: Iterable[Row]) -> dict[str, Any]:
    rows = list(rows)
    holds: dict[str, int] = {}
    by_user: dict[str, dict[str, int]] = {}
    for r in rows:
        u = by_user.setdefault(str(r.user_id), {})
        u[r.decision] = u.get(r.decision, 0) + 1
        if r.decision == "hold":
            holds[r.reason_code] = holds.get(r.reason_code, 0) + 1
    return {"evaluated": len(rows), "close": sum(r.decision == "close" for r in rows),
            "close_users": len({r.user_id for r in rows if r.decision == "close"}),
            "close_paid": sum(1 for r in rows if r.decision == "close" and r.paid), "hold": holds,
            "by_user": by_user}
