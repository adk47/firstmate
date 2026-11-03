"""D5b (Fable 171, 2026-10-29): a same-run Spotify + Tidal capture for every request doc-verify reads `verified`.

Wiring only - no new capture or rule code:
  1. enqueue  every request whose STANDING doc-verify outcome is `verified` (doc-verify's store, opened read-only)
              goes to this verifier's submit (only=those ids; submit skips an open capture or a final verdict
              newer than runner.REVERIFY_AFTER);
  2. read     verify reads every open capture (as `run` does);
  3. anchor   a request whose latest OWN verdict is APPROVE gets its dsp-anchor/1 record built (anchor.build via
              runner.build_anchors: recomputed from the packet, capture <= 24 h old); never for WAIT/UNKNOWN.

RULING (Fable 171): D5b means no more than that. A document never upgrades a V9 WAIT to an approval - the document
is corroboration, the DSP anchor is the approve-grade fact. Roles DSPs never show (A&R, most label/admin roles)
are never anchored here; they approve only via F9 (dashboard code) or option A (label line).

Writes only this verifier's store (dsp-verify.sqlite). Nothing goes to core: anchor upload is credit-anchors-push.py
(manual, per approve tray).
"""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from typing import Any, Callable

from . import runner

DOC_VERIFY_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"


def verified_requests(dv_path: str = DOC_VERIFY_STORE) -> list[str]:
    """Request ids whose standing doc-verify outcome (the latest per document, request and role, current doc-verify
    VERSION) is `verified`. Read-only; a missing store is an error (never 'none verified')."""
    from credit_verify.docverify import VERSION as DV_VERSION
    db = sqlite3.connect(f"file:{dv_path}?mode=ro", uri=True)
    try:
        rows = db.execute(
            "SELECT DISTINCT lower(o.request_id) FROM dv_outcomes o JOIN (SELECT MAX(id) id FROM dv_outcomes WHERE "
            "version=? GROUP BY coalesce(intake_id, ''), proof_id, request_id, role) l USING(id) "
            "WHERE o.outcome='verified'", (DV_VERSION,)).fetchall()
    finally:
        db.close()
    return sorted(r[0] for r in rows if r[0])


def run(store: Any, deps: Any, *, dv_path: str = DOC_VERIFY_STORE, max_groups: int = 200, max_requests: int = 300,
        now: datetime | None = None, verified: list[str] | None = None, pending_max: int = 300,
        log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    ids = verified if verified is not None else verified_requests(dv_path)
    out: dict[str, Any] = {"verified": len(ids), "submitted": 0, "submitted_pending": 0,
                           "submitted_verified": 0, "anchors_built": 0, "anchors_refused": 0}
    runner.verify(store, deps, max_groups=max_groups)                   # read what earlier runs filed
    # [key=verifier-fed-its-own-output] (l1 re-ruling-throughput-fixed-point-1102.md): submitting ONLY the ids
    # doc-verify already calls `verified` makes the verifier's input set its own output - an idle loop that
    # reports throughput (16-17 distinct ids re-read daily while 10,210 unverified requests were never
    # submitted). So the pending population comes FIRST and unconditionally: submit(only=None) walks the
    # selector's own window. d5b's verified-only pass is ADDITIVE on top of it, not the only submit.
    if pending_max:
        out["submitted_pending"] = runner.submit(store, deps, max_requests=pending_max).requests
        out["submitted"] = out["submitted_pending"]
    if not ids:
        # the pending pass above already filed captures; an empty doc-verify set no longer means 'no work'
        log(f"d5b: no doc-verify verified request ({out})")
        return out
    # runner.submit itself skips a request with an open capture or a final verdict newer than REVERIFY_AFTER
    out["submitted_verified"] = runner.submit(store, deps, max_requests=max_requests, only=set(ids)).requests
    out["submitted"] = out["submitted_pending"] + out["submitted_verified"]
    built = store.built_anchor_verdict_ids()
    rows = []
    for rid in ids:
        latest = store.latest_captured_for(rid)
        if latest and latest.get("verdict") == "APPROVE" and latest.get("id") not in built:
            rows.append({"request_id": rid})
    if rows:
        _, res = runner.build_anchors(store, {"action": "approve", "rows": rows}, now=now, log=log)
        out["anchors_built"] = sum(1 for r in res if r.get("outcome") == "built")
        out["anchors_refused"] = sum(1 for r in res if r.get("outcome") == "refused")
    log(f"d5b: {out}")
    return out
