#!/usr/bin/env python3
"""credit-empty-track-approve: the coded ET1 rule `empty_track_approve` (captain 2026-11-16 02:1xZ).

  credit-empty-track-approve.py measure [--status S] [--limit N] [--max-tracks N] [--out FILE] [--sql]
  credit-empty-track-approve.py decide  [--limit N] [--max-requests N] [--ledger PATH] [--sample N] [--out FILE]
  credit-empty-track-approve.py apply

`measure` answers "how big is this?" with two kinds of read: ONE replica statement for the open queue (status, user,
profile, track, the claim's roles and the validator's own verificationdata), and then core's own admin track document
for the candidate tracks (paced, at most --max-tracks) - which is where condition 1 (a real ISRC or Spotify id under
this id) and condition 2 (ZERO credits) are read, because every analytics replica tried says "zero credits" for
tracks core credits. Candidates are the rows passing conditions 3-4, which are local: no role conflict, no
fraud-watchlist hit. It also splits them by the decider's own human bucket (its newest ledger row per user,
read-only). It reads NO account gate and NO R8 hold set: those are one paced question per user, so `measure` counts
a POPULATION and says which stages it did not read. It never claims an approval.

Both commands FAIL CLOSED: a fraud watchlist that cannot be read is not a watchlist that says nobody is on it, so
`measure` prints nothing but the reason and `decide` records nothing (and the failure is paged).

`decide` runs the rule: fresh facts, the track documents, the account gate, the R8 hold set and the paid list, then
one row per request (approve | hold, with the reason), recorded in its OWN ledger table `empty_track_decisions`. It
writes no credit status - this rule has NO approve writer at all.

`apply` always refuses (see `empty_track_approve.NO_WRITER`): the policy switch is only the first of two stops.

Every statement is printed with --sql, so any number here can be re-derived from the query that produced it.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

try:
    from credit_review import empty_track_approve as et  # noqa: E402
except ImportError:  # a worktree copy beside the deployed package: load THIS file, keep the package's siblings
    import importlib.util

    import credit_review  # noqa: F401  (its `policy`/`watchlist` siblings are what the rule imports)

    _spec = importlib.util.spec_from_file_location(
        "credit_review.empty_track_approve", HERE / "credit_review" / "empty_track_approve.py")
    et = importlib.util.module_from_spec(_spec)
    sys.modules["credit_review.empty_track_approve"] = et
    _spec.loader.exec_module(et)

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
WATCHLIST = Path(__file__).resolve().parents[1] / "policies" / "fraud-watchlist.json"


def _watch():
    """The watchlist, or (None, why). None is NEVER "nobody is watchlisted": every read of it fails closed and both
    commands refuse to record a decision without it, and the failure is paged - a watchlist that stops watching the
    moment it cannot read itself is worse than no watchlist at all."""
    try:
        return et.watchlist.load(str(WATCHLIST)), ""
    except ValueError as exc:
        why = str(exc)
        et.page_critical(f":no_entry: empty-track approve rule is HOLDING every row: the fraud watchlist could not "
                         f"be read ({why[:200]}). Nothing is approved until that file reads again "
                         f"({WATCHLIST}).")
        return None, why


def _human_bucket(ledger: str, user_ids) -> dict:
    """How many of these users sit in the decider's human bucket, by the machine-readable half of its classifier -
    a floor: Intercom replies, flagged conversations and the support@ contact list are not read here."""
    try:
        from credit_review import verify_ledger
        db = verify_ledger.connect_ro(ledger, must_exist=True)
    except Exception as exc:  # noqa: BLE001
        return {"read": f"NOT READ: {str(exc)[:120]}"}
    try:
        try:
            latest = et.newest_ledger_rows(db, user_ids)
        except sqlite3.Error as exc:
            return {"read": f"NOT READ: {str(exc)[:120]}"}
    finally:
        db.close()
    out: dict[str, int] = {}
    for uid in user_ids:
        why = et.human_bucket(latest.get(int(uid)) if uid is not None else None)
        if why:
            out[why] = out.get(why, 0) + 1
    return {"read": "ok", "users": len({u for u in user_ids if u is not None}), "by_reason": out,
            "total": sum(out.values()), "note": "a floor: Intercom replies, flagged and support@ contacts not read"}


def _local_clean(facts: dict, watch) -> list[str]:
    """The requests that pass every condition a LOCAL read can settle - no watchlist hit, no role conflict - and so
    are the only ones worth a track document. The rule (et.local_clean) supplies the predicate: whether the track
    carries a real ISRC or a real Spotify id is condition 1's business, read from core's own track document, so a
    request with no ISRC is not filtered out before its document is fetched."""
    return list(et.local_clean(facts, watch))


def _measure(a) -> dict:
    watch, watch_why = _watch() if a.watchlist else (None, "not read (--no-watchlist)")
    if watch is None:
        # Fail closed before any number is printed: a population counted with an unreadable watchlist would excuse
        # a watchlisted claimant for the same reason a decision would approve one.
        return {"rule": et.RULE_ID, "stopped": f"watchlist_unread: {watch_why}",
                "note": "the fraud watchlist could not be read, so no claimant can be excused a hit; nothing is "
                        "measured or decided until it reads (and the failure was paged)"}
    facts = et.scan_facts(limit=a.limit, statuses=a.status_list())
    tracks = sorted({f.track_id for f in facts.values() if f.track_id})
    role_holds: dict[str, int] = {}
    for f in facts.values():
        why = et.role_conflict(f.roles, f.verdict)
        if why:
            key = why.split(":")[0]
            role_holds[key] = role_holds.get(key, 0) + 1
    watch_hits = sum(1 for f in facts.values() if et.watch_hit(f.user_id, f.profile_id, watch)) if watch else None
    clean = _local_clean(facts, watch)
    if a.tracks_out:
        Path(a.tracks_out).write_text(
            "\n".join(sorted({facts[r].track_id for r in clean if facts[r].track_id})) + "\n", encoding="utf-8")
    clean_tracks = sorted({facts[r].track_id for r in clean})
    covered = clean_tracks[:max(a.max_tracks, 0)]
    docs: dict = {}
    if covered:
        from credit_review import admin as admin_api
        docs = et.track_docs(admin_api.AdminClient(), covered)
    why_of = {t: ("track_unread" if d is None else et.empty_track(d)) for t, d in docs.items()}
    empty = {t for t, why in why_of.items() if why == ""}
    clean_rows = [r for r in clean if why_of.get(facts[r].track_id) == ""]
    out = {
        "rule": et.RULE_ID,
        "candidate_filter": "conditions 3-4 locally; condition 1-2 read from core's track document",
        "rule_version": et.rule_version(),
        "open_requests_read": len(facts),
        "distinct_tracks": len(tracks),
        "requests_with_role_conflict": sum(role_holds.values()),
        "role_conflict_by_reason": role_holds,
        "requests_without_a_real_isrc": sum(1 for f in facts.values() if not et.real_isrc(f.isrc)),
        "watchlist_read": "ok" if watch is not None else f"NOT READ: {watch_why}",
        "watchlist_hits": watch_hits if watch is not None else None,
        "requests_passing_local_conditions": len(clean),
        "tracks_passing_local_conditions": len(clean_tracks),
        "track_documents_read": len(docs),
        "track_refusals": {why: sum(1 for w in why_of.values() if w == why)
                           for why in sorted({w for w in why_of.values() if w})},
        "tracks_empty_in_core": len(empty),
        "requests_on_an_empty_track_in_core": len(clean_rows),
        "users_on_an_empty_track_in_core": len({facts[r].user_id for r in clean_rows}),
        "NOT_READ_HERE": ["account_gate", "R8_account_hold", "paid list"],
        "human_bucket": _human_bucket(a.ledger, sorted({facts[r].user_id for r in clean_rows}))
        if a.human_bucket else {"read": "skipped (--no-human-bucket)"},
        "sql": et.last_queries() if a.sql else "run with --sql to print every statement",
    }
    out["note"] = ("measure reads no account gate and no R8 hold set, so it counts a population, not an approval; "
                   "run `decide` for rows. Condition 2 (zero credits) and condition 1 (a real track) come from "
                   "core's own track document, one paced GET each - the analytics replicas disagree with it "
                   "badly - so track documents cover only the first --max-tracks candidate tracks "
                   f"({len(covered)} of {len(clean_tracks)}); the rest are uncounted, not empty.")
    return out


def _decide(a) -> dict:
    from credit_review import account_gate, comm_state, decide as decider
    watch, watch_why = _watch()
    if watch is None:
        return {"rule": et.RULE_ID, "refused": f"watchlist_unread: {watch_why}",
                "note": "the fraud watchlist could not be read: every row would hold, and a row decided without "
                        "the watchlist is exactly the fail-open this rule refuses. Nothing recorded."}
    facts = et.scan_facts(limit=a.limit, statuses=a.status_list())
    paid, paid_why = decider.paying_users()
    clean = _local_clean(facts, watch)
    clean.sort(key=lambda r: (facts[r].track_id, r))
    wanted = clean[:max(a.max_requests, 0)]
    if not wanted:
        return {"rule": et.RULE_ID, "candidates": 0, "note": "no open request passes the local conditions"}
    from credit_review import admin as admin_api
    docs = et.track_docs(admin_api.AdminClient(), sorted({facts[r].track_id for r in wanted}))
    rows, skipped = et.evaluate(wanted, {r: facts[r] for r in wanted}, docs,
                                account_gate.check, comm_state.account_hold_facts, paid, watch)
    for r in rows[:max(a.sample, 0)]:
        print(json.dumps(r.__dict__, default=str))
    holds: dict[str, int] = {}
    for r in rows:
        if r.decision != "approve":
            holds[r.reason_code] = holds.get(r.reason_code, 0) + 1
    out = {"rule": et.RULE_ID, "rule_version": et.rule_version(), "candidates": len(wanted),
           "evaluated": len(rows), "approve": sum(r.decision == "approve" for r in rows),
           "approve_users": len({r.user_id for r in rows if r.decision == "approve"}), "hold": holds,
           "skipped": skipped, "paid_list": "read" if paid is not None else f"NOT READ: {paid_why}",
           "watchlist": "read" if watch is not None else f"NOT READ: {watch_why}"}
    db = sqlite3.connect(a.ledger, timeout=30)
    run_id = "empty-track-shadow-" + uuid.uuid4().hex[:10]
    rec = et.record(db, run_id, "shadow", rows, datetime.now(timezone.utc))
    out.update(mode="shadow", run_id=run_id, written_approve=rec["approve"], written_hold=rec["hold"],
               duplicate=rec["duplicate"])
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("measure", "decide", "apply"))
    ap.add_argument("--status", action="append", default=None,
                    help="held status to read (repeatable); default: unverified + user_verification_needed")
    ap.add_argument("--limit", type=int, default=0, help="read at most N open requests (0 = no limit)")
    ap.add_argument("--max-tracks", type=int, default=200, help="measure: track documents to read (paced)")
    ap.add_argument("--max-requests", type=int, default=1000, help="decide: requests to decide")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--no-watchlist", dest="watchlist", action="store_false",
                    help="do not read the fraud watchlist; with it unread this rule measures and decides NOTHING "
                         "(an unreadable watchlist is a hold, never a pass)")
    ap.add_argument("--no-human-bucket", dest="human_bucket", action="store_false")
    ap.add_argument("--sample", type=int, default=0)
    ap.add_argument("--out")
    ap.add_argument("--tracks-out", dest="tracks_out",
                    help="measure: write the candidate track ids (one per line) so a census can be re-run on them")
    ap.add_argument("--sql", action="store_true")
    a = ap.parse_args(argv)
    a.status_list = (lambda: tuple(a.status)) if a.status else (lambda: et.OPEN_FROM)
    if a.command == "apply":
        print(json.dumps({"refused": et.apply_refusal(et.policy())}))
        return 2
    out = _measure(a) if a.command == "measure" else _decide(a)
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=2, default=str), encoding="utf-8")
    print(json.dumps(out, default=str))
    return 2 if ("stopped" in out or "refused" in out) else 0


if __name__ == "__main__":
    sys.exit(main())
