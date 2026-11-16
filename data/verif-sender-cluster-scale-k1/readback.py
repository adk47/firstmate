"""The read-back for the capped run (lane verif-sender-cluster-scale-k1).

Statement 1 counts asks per UTC hour. Statement 2 is the cap invariant, and it asks the rule itself: for every
identity pair in the window it calls `verify_ledger.capped()`, the function the senders are refused by, and reports
the rows that answer it. A pair can combine one row's email with another row's user id, so each entry says whether
its candidate identity comes from a single row (`cross_identity: false`, a real duplicate) or is such a combination
(`cross_identity: true`, an over-report). There is deliberately no second definition of "one note per person per UTC
day" in SQL:
`verify_ledger._same_user()` is a predicate against a candidate pair (`user_key` OR `account_id`, plus the decider's
`user_id` for rows with no `account_id`), not an equivalence relation over rows, so any pairwise token grouping can
report "no duplicates" for two rows a candidate matches while sharing no token with each other. The whole UTC day is
cap history (the cap is per day), but an entry is reported against `--since` only when one of the rows it names was
written at or after it: a pair from earlier the same day was already there before the run and is not a duplicate the
run produced.

Read-only: it opens the ledger through `verify_ledger.connect_ro` and writes nothing.

Its output names no person: an entry carries the day, the `verify_messages` row ids it matched and whether a single
row supplies the candidate identity. Emails and user ids are used to build the candidates and never printed.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import verify_ledger  # noqa: E402

ASK_CAMPAIGNS = ("proof-need-ask", "claim-proof-ask")


def hourly_asks(db: Any, since: str) -> list[dict[str, Any]]:
    q = ("SELECT substr(sent_at, 1, 13) AS utc_hour, campaign, COUNT(*) AS sent FROM verify_messages "
         f"WHERE status = 'sent' AND campaign IN ({','.join('?' * len(ASK_CAMPAIGNS))}) AND sent_at >= ? "
         "GROUP BY 1, 2 ORDER BY 1, 2")
    return [dict(r) for r in db.execute(q, (*ASK_CAMPAIGNS, since))]


def _has_decisions(db: Any) -> bool:
    return bool(db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'decisions'").fetchone())


def _decision_uids(db: Any, row_id: int) -> list[str]:
    if not _has_decisions(db):
        return []
    q = ("SELECT DISTINCT CAST(d.user_id AS TEXT) AS uid FROM verify_messages m "
         "JOIN json_each(m.request_ids_json) j JOIN decisions d ON d.request_id = j.value "
         "WHERE m.id = ? AND m.account_id IS NULL AND d.user_id IS NOT NULL")
    return [r["uid"] for r in db.execute(q, (row_id,)) if r["uid"] not in (None, "")]


def identity_pairs(db: Any, day: str) -> list[tuple[str, str]]:
    rows = db.execute("SELECT id, user_key, account_id FROM verify_messages "
                      "WHERE day = ? AND status IN ('attempted', 'sent')", (day,)).fetchall()
    emails = {r["user_key"] for r in rows if r["user_key"]}
    uids: set[str] = set()
    for r in rows:
        if r["account_id"] not in (None, ""):
            uids.add(str(r["account_id"]))
        for uid in _decision_uids(db, int(r["id"])):
            uids.add(str(uid))
    return [(email, uid) for email in sorted(emails) for uid in ("", *sorted(uids))]


def row_identities(db: Any, day: str) -> dict[int, tuple[str, set[str]]]:
    """What each row on `day` says about the person it went to: its email, and the user id it carries (its own
    account id, or for a row with no account id the decider's user id for a request the note covered)."""
    out: dict[int, tuple[str, set[str]]] = {}
    for r in db.execute("SELECT id, user_key, account_id FROM verify_messages "
                        "WHERE day = ? AND status IN ('attempted', 'sent')", (day,)):
        uids: set[str] = set()
        if r["account_id"] not in (None, ""):
            uids.add(str(r["account_id"]))
        else:
            uids.update(_decision_uids(db, int(r["id"])))
        out[int(r["id"])] = (str(r["user_key"] or ""), uids)
    return out


def _at_or_after(ts: Any, since: str) -> bool:
    """Whether a row's own timestamp falls in the requested window (`--since` included)."""
    text = str(ts or "")
    if not text:
        return False
    try:
        return _ts(text) >= _ts(since)
    except ValueError:            # a timestamp this parser cannot read is compared as it is written
        return text >= since


def _ts(text: str) -> datetime:
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def capped_users(db: Any, day: str, since: str) -> list[dict[str, Any]]:
    """The day's rows a capped pair matched. The whole day is cap history, but an entry is reported against the
    window only when one of its rows was written at or after `since`: a pair from before the run was already
    there and is not a duplicate this run produced."""
    out: list[dict[str, Any]] = []
    identities = row_identities(db, day)
    for user_key, user_id in identity_pairs(db, day):
        if not verify_ledger.capped(db, user_key=user_key, day=day, user_id=user_id):
            continue
        cond, params = verify_ledger._same_user(db, user_key, user_id)
        matched = db.execute(
            f"SELECT m.id, COALESCE(m.sent_at, m.created_at) AS at FROM verify_messages m WHERE ({cond}) "
            "AND m.day = ? AND m.status IN ('attempted', 'sent') ORDER BY m.id", (*params, day)).fetchall()
        ids = [int(r["id"]) for r in matched]
        if len(ids) > 1 and any(_at_or_after(r["at"], since) for r in matched):
            uid = str(user_id or "")
            same_row = False if uid else True
            for row_id in ids:
                email, uids = identities.get(row_id, ("", set()))
                if email == user_key and (not uid or uid in uids):
                    same_row = True
            out.append({"day": day, "rows": ids, "cross_identity": not same_row})
    return out


def _collapse(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """One entry per (day, rows, cross_identity): several candidate identities can match the same set of rows."""
    seen: dict[tuple[Any, ...], dict[str, Any]] = {}
    for entry in entries:
        key = (entry["day"], tuple(entry["rows"]), entry["cross_identity"])
        seen.setdefault(key, entry)
    return sorted(seen.values(), key=lambda e: (e["day"], e["rows"], e["cross_identity"]))


def _counts(days: list[str], duplicates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{"day": day,
             "real": sum(1 for d in duplicates if d["day"] == day and not d["cross_identity"]),
             "cross_identity": sum(1 for d in duplicates if d["day"] == day and d["cross_identity"])}
            for day in days]


def readback(path: str, since: str) -> dict[str, Any]:
    db = verify_ledger.connect_ro(path, must_exist=True)
    try:
        days = [r["day"] for r in db.execute(
            "SELECT DISTINCT day FROM verify_messages WHERE day >= ? AND status IN ('attempted', 'sent') "
            "ORDER BY day", (since[:10],))]
        duplicates = _collapse([d for day in days for d in capped_users(db, day, since)])
        return {"ledger": path, "since": since, "hourly_asks": hourly_asks(db, since), "duplicates": duplicates,
                "duplicate_counts": _counts(days, duplicates)}
    finally:
        db.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", default=verify_ledger.PRODUCTION_PATH)
    ap.add_argument("--since", required=True, help="UTC timestamp, e.g. 2026-11-13T22:00:00Z")
    a = ap.parse_args(argv)
    print(json.dumps(readback(a.db, a.since), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
