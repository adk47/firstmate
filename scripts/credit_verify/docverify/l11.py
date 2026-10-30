"""L11 '24 h clean read' monitor (proof-loop lead 086; captain 2026-10-28 21:4xZ, captain-1028-214x).

L11 lets a doc-verify `verified` document approve through the account gate, but only after Fable
confirms a 24 h clean read on the new forgery rule (dv-2: #1452/#1457/#1466/#1470), counted from the
deploy that carried dv-2. This module only COUNTS, read-only, per hour since that deploy:

  forged            documents whose standing dv-2 outcome is `forged` (one signal: a hold)
  forged_positive   documents whose standing dv-2 outcome is `forged_positive` (two families)
  false_forged      of those, the documents Jan or fraud-lens flagged as NOT forged (ruling ids or sha
                    prefixes in a plain file, one per line - e.g. `false-forged: forged-1a2b3c4d`)
  verified          documents with a standing `verified`
  verified_anchored of those, the ones with a same-run Spotify AND Tidal anchor (D5b; 0 until it is live)

`clean` is true only when at least 24 h have passed, false_forged is KNOWN to be 0 (the reviewed flag file
was supplied - an omitted file is UNKNOWN, never zero), and D5b is live (at least one same-run anchor exists
since the deploy). A document counts once however many claims or proofs it has. It never approves, holds or
writes anything.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from typing import Any

from . import VERSION

WINDOW_H = 24
_FLAG = re.compile(r"^(?:false-forged:\s*(?:forged-)?([0-9a-f]{8,64})|ruling:\s*forged-([0-9a-f]{8,64})\s+not)\b", re.I)


def _ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def parse_false_forged(text: str) -> set[str]:
    """sha prefixes (>= 8 hex) ruled NOT forged: `false-forged: <prefix>` lines (Jan / f1) or the tray's own
    `ruling: forged-<prefix> not` lines (Fable). A `confirm` ruling or any other line never counts."""
    out = set()
    for line in (text or "").splitlines():
        line = line.split("#", 1)[0].strip()
        m = _FLAG.match(line)
        if m:
            out.add((m.group(1) or m.group(2)).lower())
    return out


def _anchored(db: Any, proof_id: str, key: str, run_id: str, version: str) -> bool:
    # the xc_dsp step of the SAME run and version as the standing outcome (QA #1471): an anchor an earlier run
    # logged never makes a later run's verified anchored
    row = db.execute("SELECT status, detail_json FROM dv_steps WHERE proof_id=? AND request_id=? AND step='xc_dsp' "
                     "AND run_id=? AND version=? ORDER BY id DESC LIMIT 1",
                     (proof_id, key, run_id, version)).fetchone()
    if not row or row[0] != "positive":
        return False
    try:
        d = json.loads(row[1] or "{}")
    except ValueError:
        return False
    a = d.get("fresh_anchor") or {}
    return bool(d.get("fresh_since")) and a.get("spotify") is True and a.get("tidal") is True


def dsp_anchors(path: str | None) -> dict[str, list[tuple[datetime, set[str]]]]:
    """D5b: request -> [(capture time, roles)] of every BUILT dsp_anchor record in the DSP verifier's store
    (read-only). No path / no store = no anchors (the line then says D5b is not live)."""
    out: dict[str, list[tuple[datetime, set[str]]]] = {}
    if not path:
        return out
    import os
    import sqlite3
    if not os.path.exists(path):
        return out
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        for rid, rec in db.execute("SELECT lower(request_id), record_json FROM dsp_anchors WHERE outcome='built' AND "
                                   "kind='dsp_anchor' AND record_json IS NOT NULL"):
            try:
                r = json.loads(rec)
                at = _ts(r.get("captured_at") or r.get("capture_read_at") or "")
                at = at if at.tzinfo else at.replace(tzinfo=timezone.utc)
            except (ValueError, TypeError, AttributeError):
                continue
            out.setdefault(rid, []).append((at, {str(x) for x in r.get("roles") or []}))
    finally:
        db.close()
    return out


def _d5b_anchored(anchors: dict[str, list[tuple[datetime, set[str]]]], rid: str, role: str, at: str) -> bool:
    """A verified claim is anchored by D5b when a built dsp_anchor for its request covers its role and was captured
    no more than 24 h from the verified read (either side: the capture follows the read it was filed for)."""
    when = _ts(at)
    return any(role in roles and abs((cap - when).total_seconds()) <= 24 * 3600
               for cap, roles in anchors.get((rid or "").lower(), []))


def watch(store: Any, *, since: str, false_forged: set[str] | None = None,
          now: datetime | None = None, dsp_store: str | None = None) -> dict[str, Any]:
    """`false_forged=None` means the reviewed flag file was not supplied: UNKNOWN, so never clean (QA #1471)."""
    now = now or datetime.now(timezone.utc)
    db = store.db
    rows = db.execute(
        "SELECT o.proof_id, o.request_id, o.role, o.outcome, coalesce(o.intake_id, o.proof_id), o.at, o.run_id, "
        "o.version FROM dv_outcomes o JOIN (SELECT MAX(id) id FROM dv_outcomes WHERE version=? GROUP BY "
        "coalesce(intake_id, ''), proof_id, request_id, role) l USING(id) WHERE o.at >= ?", (VERSION, since)).fetchall()
    first: dict[str, dict[str, Any]] = {}
    anchors = dsp_anchors(dsp_store)
    for pid, rid, role, outcome, doc, at, run_id, version in rows:
        d = first.setdefault(doc, {"proof_ids": set(), "forged_ids": set(), "at": at, "outcomes": set(),
                                   "anchored": False})
        d["at"] = min(d["at"], at)
        d["outcomes"].add(outcome)
        d["proof_ids"].add(pid)
        if outcome in ("forged", "forged_positive"):
            d["forged_ids"].add(pid)            # every proof id with a forged outcome (QA #1471), matched below
        if outcome == "verified" and not d["anchored"]:
            d["anchored"] = _anchored(db, pid, f"{rid}#{role}", run_id, version) or _d5b_anchored(anchors, rid, role, at)
    flags = false_forged or set()

    def flagged(d: dict[str, Any]) -> bool:
        return any(p.lower().startswith(f) for p in d["forged_ids"] for f in flags)

    start = _ts(since)
    hours = max(1, int((now - start).total_seconds() // 3600) + 1)
    per_hour = []
    for h in range(hours):
        lo, hi = start + timedelta(hours=h), start + timedelta(hours=h + 1)
        docs = [d for d in first.values() if lo <= _ts(d["at"]) < hi]
        per_hour.append(_counts(docs, flagged) | {"hour": lo.strftime("%Y-%m-%dT%H:%MZ")})
    total = _counts(list(first.values()), flagged)
    elapsed_h = (now - start).total_seconds() / 3600
    d5b = total["verified_anchored"] > 0
    why = []
    if elapsed_h < WINDOW_H:
        why.append(f"{elapsed_h:.1f} h of {WINDOW_H} h")
    if false_forged is None:
        why.append("false forged UNKNOWN: no reviewed flag file (--false-forged) was given")
    elif total["false_forged"]:
        why.append(f"{total['false_forged']} false forged")
    if not d5b:
        why.append("D5b not live: no verified document has a same-run Spotify+Tidal anchor")
    return {"version": VERSION, "since": since, "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "elapsed_h": round(elapsed_h, 1),
            "flags_known": false_forged is not None, "total": total, "per_hour": per_hour, "clean": not why,
            "not_clean_because": why}


def _counts(docs: list[dict[str, Any]], flagged: Any) -> dict[str, int]:
    forged = [d for d in docs if "forged" in d["outcomes"]]
    positive = [d for d in docs if "forged_positive" in d["outcomes"]]
    # one document with `forged` on one claim and `forged_positive` on another is ONE false forged (QA #1471)
    return {"documents": len(docs), "forged": len(forged), "forged_positive": len(positive),
            "false_forged": sum(1 for d in docs if d["forged_ids"] and flagged(d)),
            "verified": sum(1 for d in docs if "verified" in d["outcomes"]),
            "verified_anchored": sum(1 for d in docs if d["anchored"])}


def line(w: dict[str, Any]) -> str:
    t = w["total"]
    return (f"L11 clean-read ({w['version']}, since {w['since']}, {w['elapsed_h']} h): {t['documents']} documents read; "
            f"forged {t['forged']}, forged_positive {t['forged_positive']}, false forged {t['false_forged']}; "
            f"verified {t['verified']}, with a same-run Spotify+Tidal anchor {t['verified_anchored']}. "
            + ("CLEAN" if w["clean"] else "not clean: " + "; ".join(w["not_clean_because"])))
