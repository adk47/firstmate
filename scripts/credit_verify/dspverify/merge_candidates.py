"""Duplicate-profile MERGE CANDIDATES from the DSP verifier's standing verdicts (Fable 178 / p1 179, 2026-10-30).

A standing `needs_profile_link` verdict (the claimant's name is credited, the presented profile has no contributor
id on that DSP) whose same-run capture credits, under the claimant's EXACT normalized name (credit_review.roles.fold),
a raw contributor id that ANOTHER Muso catalog profile already holds = the claimant presents an unlinked copy while
the linked profile exists. Each becomes one `proposals` row (kind merge_candidate, shadow) per
(verdict, contributor id):

  class candidate   the linked profile has no live claim, or only claims by the SAME account: an owner-confirmed
                    merge candidate (surviving profile = the linked one, which carries the DSP id; the
                    presented-primary switch first; credits move with it; no delete) - for the core merge verifier;
  class contested   any live claim on the linked profile by ANOTHER account -> tray, never automatic.

Claims are read from core with one read-only Trino SELECT (postgresql_core.public.claiming). A claim is live when it
is not deleted and not rejected. An unreadable claim table writes NOTHING (unknown never proposes).

Reads dsp-verify.sqlite read-only; writes only the decider ledger's `proposals` table, and only with apply=True.
"""
from __future__ import annotations

import json
import re
import sqlite3
import uuid
from datetime import datetime, timezone
from typing import Any, Callable

from credit_review import proposals
from credit_review.roles import fold

from . import VERSION as DSP_VERSION

RULE_VERSION = f"merge-candidate/1+{DSP_VERSION}"
KIND = "merge_candidate"
DEAD_CLAIM = ("rejected",)
_UUID = re.compile(r"^[0-9a-fA-F-]{36}$")


def standing_link_verdicts(dsp_path: str) -> list[dict[str, Any]]:
    db = sqlite3.connect(f"file:{dsp_path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        rows = db.execute(
            "SELECT v.* FROM dsp_verdicts v JOIN dsp_runs r ON r.run_id = v.run_id AND r.kind = 'verify' "
            "WHERE v.id IN (SELECT MAX(id) FROM dsp_verdicts WHERE version=? GROUP BY request_id) "
            "AND v.reason_class = 'needs_profile_link' AND v.packet_json IS NOT NULL ORDER BY v.id",
            (DSP_VERSION,)).fetchall()
        return [dict(r) for r in rows]
    finally:
        db.close()


def candidates(verdicts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """One row per (verdict, contributor id): exact-name credit, a raw id, held by a DIFFERENT catalog profile, in a
    CAPTURED same-run reading (captured after the capture request)."""
    out: list[dict[str, Any]] = []
    for v in verdicts:
        p = json.loads(v["packet_json"] or "{}")
        cap = p.get("capture") or {}
        name = fold(str(cap.get("person_name") or p.get("profile_name") or ""))
        me = str(p.get("profile_id") or v.get("profile_id") or "").lower()
        req_at = str(cap.get("requested_at") or "")
        if not name or not me or not req_at:
            continue
        found: dict[tuple[str, str], dict[str, Any]] = {}
        for role, rr in (cap.get("roles") or {}).items():
            for dsp, rd in ((rr or {}).get("sources") or {}).items():
                if not isinstance(rd, dict) or rd.get("state") != "CAPTURED" or str(rd.get("captured_at") or "") <= req_at:
                    continue
                for e in rd.get("credited_in_family") or []:
                    if not (isinstance(e, (list, tuple)) and len(e) >= 5 and e[3] and e[4]):
                        continue
                    holder = str(e[4]).lower()
                    if fold(str(e[0])) != name or holder == me or not _UUID.match(holder):
                        continue
                    f = found.setdefault((str(e[3]), holder), {"dsp": dsp, "contributor_name": str(e[0]),
                                                              "roles": set(), "capture_ids": set()})
                    f["roles"].add(role)
                    f["capture_ids"].update(rd.get("capture_ids") or [])
                    f["captured_at"] = rd.get("captured_at")
        for (cid, holder), f in sorted(found.items()):
            out.append({"request_id": v["request_id"], "user_id": v.get("user_id"), "profile_presented": me,
                        "profile_linked": holder, "dsp": f["dsp"], "contributor_id": cid,
                        "contributor_name": f["contributor_name"], "source_ref": f"dsp_verdicts:{v['id']}",
                        "evidence": {"track_id": p.get("track_id"), "track_title": p.get("track_title"),
                                     "isrcs": p.get("isrcs") or [], "roles": sorted(f["roles"]),
                                     "capture_request_id": cap.get("request_id"), "capture_requested_at": req_at,
                                     "captured_at": f.get("captured_at"), "capture_ids": sorted(f["capture_ids"])[:6],
                                     "verdict_id": v["id"], "packet_sha256": v.get("packet_sha256"),
                                     "popularity": p.get("popularity"), "name_collisions": p.get("name_collisions"),
                                     "flags": p.get("flags"), "gate": (p.get("gate") or {}).get("decision")}})
    return out


def claims_sql(profile_ids: list[str]) -> str:
    ids = ",".join(f"'{x}'" for x in sorted(set(profile_ids)) if _UUID.match(x))
    return ("SELECT lower(cast(profileid AS varchar)), cast(userid AS varchar), status FROM postgresql_core.public.claiming "
            f"WHERE deletedat IS NULL AND lower(cast(profileid AS varchar)) IN ({ids})")


def read_claims(query: Callable[[str], str], profile_ids: list[str]) -> dict[str, list[dict[str, Any]]]:
    """profile -> [{user_id, status}] of live claims. Raises on an unreadable answer (never 'unclaimed').

    FAIL CLOSED ON A MALFORMED ROW (QA #1520 r2). A nonblank row that does not parse is not "a claim we can ignore":
    dropping it makes a profile look unclaimed, so `classify()` reads `candidate` - an owner-confirmed merge - when
    in fact another account may hold a live claim. So every nonblank row must be a 3-field CSV with a UUID profile id
    we asked for, a numeric user id and a nonempty status; anything else is an unreadable claim table and the run
    writes nothing. The only row that is legitimately skipped is a LIVE-vs-DEAD distinction, which needs a parse
    first."""
    out: dict[str, list[dict[str, Any]]] = {p: [] for p in profile_ids}
    if not profile_ids:
        return out
    by_lower = {p.lower(): p for p in profile_ids}          # SQL answers lowercase; a packet may not be
    text = query(claims_sql(profile_ids))
    if text is None:
        raise RuntimeError("claiming unreadable")
    for ln in text.splitlines():
        if not ln.strip():
            continue                                        # a blank line is not a claim and not an error
        parts = [x.strip().strip('"') for x in ln.split(",")]
        if len(parts) != 3:
            raise RuntimeError(f"claiming unreadable: {ln!r} is not a 3-field row")
        profile, user, status = parts[0].lower(), parts[1], parts[2]
        if not _UUID.match(profile):
            raise RuntimeError(f"claiming unreadable: {ln!r} has no profile id")
        if profile not in by_lower:
            raise RuntimeError(f"claiming unreadable: {ln!r} names profile {profile[:8]} that was not asked")
        if not user.isdigit():
            raise RuntimeError(f"claiming unreadable: {ln!r} has no numeric user id")
        if not status:
            raise RuntimeError(f"claiming unreadable: {ln!r} has no claim status")
        if status.lower() in DEAD_CLAIM:
            continue                                        # rejected: not a live claim
        out[by_lower[profile]].append({"user_id": int(user), "status": status})
    return out


def classify(row: dict[str, Any], claims: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    linked = claims.get(row["profile_linked"], [])
    others = sorted({str(c["user_id"]) for c in linked} - {str(row.get("user_id"))})
    cls = "contested" if others else "candidate"
    why = (f"the contributor id credited under the claimant's exact name is held by profile {row['profile_linked'][:8]}, "
           + ("claimed by another account (" + ",".join(others) + "): contested, tray" if others else
              "unclaimed or claimed by the same account: owner-confirmed merge candidate (the linked profile survives)"))
    return {**row, "kind": KIND, "class": cls, "rule_version": RULE_VERSION, "reason": why,
            "claimed_by": {"presented": claims.get(row["profile_presented"], []), "linked": linked}}


def run(*, dsp_path: str, ledger_path: str, query: Callable[[str], str], apply: bool = False,
        now: datetime | None = None) -> dict[str, Any]:
    rows = candidates(standing_link_verdicts(dsp_path))
    claims = read_claims(query, sorted({r["profile_presented"] for r in rows} | {r["profile_linked"] for r in rows}))
    rows = [classify(r, claims) for r in rows]
    report: dict[str, Any] = {"rule_version": RULE_VERSION, "candidates": sum(1 for r in rows if r["class"] == "candidate"),
                              "contested": sum(1 for r in rows if r["class"] == "contested"),
                              "requests": len({r["request_id"] for r in rows}), "written": 0, "apply": apply,
                              "rows": rows}
    if not apply:
        return report
    # ONE row per proposed fact, even when two --apply runs overlap (QA #1520 r2). The pre-read is an optimisation,
    # so it must happen INSIDE the write transaction (BEGIN IMMEDIATE takes the writer lock up front, so the read is
    # serialized with every other writer) and the uniqueness is enforced by the ledger's own index with a
    # conflict-safe insert. Counting rows we did not inspect would report writes that never landed.
    db = sqlite3.connect(ledger_path, timeout=30)
    try:
        proposals.ensure(db)
        run_id = f"merge-{(now or datetime.now(timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ')}-{uuid.uuid4().hex[:8]}"
        at = proposals.utc(now)
        db.execute("BEGIN IMMEDIATE")
        try:
            seen = proposals.written_sources(db, KIND)
            for r in rows:
                if (r["source_ref"], r["contributor_id"]) in seen:
                    continue
                report["written"] += proposals.add(db, run_id, r, decided_at=at)
            db.execute("COMMIT")
        except BaseException:
            db.execute("ROLLBACK")
            raise
        report["run_id"] = run_id
    finally:
        db.close()
    return report
