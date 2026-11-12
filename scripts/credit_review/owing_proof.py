"""The audience for Fable's S1 line `credit-hold-status` (card L14a): credit requesters who OWE PROOF and were never
told anything (Fable copy-owing-proof-1027 "Durable process" step 2; captain 01:5xZ delegated the copy yes to Fable,
firstmate verify-ask-wiring-h2 inbox 063). READ-ONLY: writes one runner list for
`credit-review.py uvn-status --campaign credit-hold-status`; the gate (send-locked until the yes), its ledger (one per
user, ever), the 7-day core-notice gate and the caps decide every send.

A user is on the list when, on the core replica and the verify ledger:
  - they owe proof by the steward's CLASS_SQL classes on at least one pending request: a user_verification_needed
    row (U), an unverified row whose IDP review_* rule fired (H2), or unverified rows on a held account (H1:
    fraud-lens account_holds.jsonl / hold-silent account-hold; Fable: "S1 goes to held accounts too");
  - and they were NEVER TOLD: no proofRequest marker on any of their requests and no sent verify-ledger note of any
    campaign ("no ask/notice in the ledger or core markers").
The note names the rows they owe on (U rows, H2 rows; for H1 every unverified row). Order (Fable [key=pro-at-risk]):
paid at-risk first (Stripe past_due / cancel scheduled, pro-at-risk-1028.csv), then paid, then free; oldest request
first inside each tier.

  python3 owing_proof.py --out FILE [--at-risk CSV]
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import verify_notify  # noqa: E402

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
ACCOUNT_HOLDS = "/opt/firstmate/fraud-lens/out/account_holds.jsonl"
AT_RISK = "/var/lib/hydra/paid-status/pro-at-risk.csv"
PAID_WS = "(SELECT DISTINCT s.teamid FROM postgresql_core.public.subscriptions s WHERE s.status IN ('active','trialing'))"
REVIEW_FIRED = ("regexp_like(coalesce(json_format(json_extract(cr.verificationdata, '$.rule_risk_percent')), ''), "
                "'\"review_[a-z_]+\":\\s*[1-9]')")
# v1 / r5 / p1 [key=k-proof-required]: core's validator says the row needs proof and core has set no review-stage mark
PROOF_REQUIRED = ("coalesce(CAST(json_extract(cr.verificationdata, '$.proof_required') AS boolean), false) "
                  "AND json_extract(cr.metadata, '$.reviewStage') IS NULL")
Query = Callable[[str], "list[list[str]]"]


class OwingProofError(RuntimeError):
    pass


# The open statuses are listed POSITIVELY, and that is the whole scale fix (measured on the live replica 2026-11-12,
# 5.65M rows / 76 GB, 96.6k of them open):
#   - `status NOT IN ('approved', 'rejected')` is NOT pushed to Postgres by the Trino connector (EXPLAIN: a Trino-side
#     `filterPredicate = $not(status IN ...)` over a scan constrained on deletedAt/userId only), so every row - both
#     JSON columns included - crossed the wire to be filtered afterwards. It could not finish inside the replica's
#     statement timeout, the census read `UNMEASURED`, and the uvn-status family was skipped for hours.
#   - `status IN (<open>)` IS pushed (`constraint on [deletedAt, status, userId]`), Postgres answers it from core's own
#     status index, and the same rows come back in ~10 s. Core's index is the owing index: transactionally current,
#     nothing to backfill, no copy that can go stale and ask a user whose request was decided a minute ago.
# The two forms are equal only while every status in the table is one this module knows, so that is CHECKED on every
# read (STATUS_GUARD_SQL / check_statuses) and an unknown status refuses the read: a positive list must never narrow
# the audience silently. Adding a status here is a decision about who is asked - classify it, never just append it.
CLOSED_STATUSES = ("approved", "rejected")
OPEN_STATUSES = ("unverified", "processing", "user_verification_needed")
# Every distinct status in the table, by a loose index scan on core's status index (milliseconds in Postgres, and it
# stays that way as the table grows; `SELECT status ... GROUP BY status` through Trino scans the column instead). The
# statement goes to Postgres verbatim through the connector's read-only passthrough (precedent: cs_proof_feed/replica).
STATUS_GUARD_SQL = ("SELECT status FROM TABLE(postgresql_core.system.query(query => '"
                    "WITH RECURSIVE t AS ((SELECT status FROM public.credit_requests ORDER BY status LIMIT 1) "
                    "UNION ALL SELECT (SELECT status FROM public.credit_requests WHERE status > t.status "
                    "ORDER BY status LIMIT 1) FROM t WHERE t.status IS NOT NULL) "
                    "SELECT status FROM t WHERE status IS NOT NULL'))")

# r5 signing rule: the list header carries THIS exact, runnable SQL (and its sha256) - one string, the one replica_rows
# runs at build and verify_facts re-runs at signing
REPLICA_SQL = ("SELECT CAST(cr.userid AS varchar), lower(CAST(cr.id AS varchar)), cr.status, CAST(cr.createdat AS varchar), "
               f"CAST(CASE WHEN cr.workspaceid IN {PAID_WS} THEN 1 ELSE 0 END AS varchar), "
               f"CAST(CASE WHEN {REVIEW_FIRED} THEN 1 ELSE 0 END AS varchar), "
               "CAST(CASE WHEN json_extract(cr.metadata, '$.proofRequest') IS NOT NULL THEN 1 ELSE 0 END AS varchar), "
               f"CAST(CASE WHEN {PROOF_REQUIRED} THEN 1 ELSE 0 END AS varchar) "
               "FROM postgresql_core.public.credit_requests cr WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL "
               "AND cr.status IN (" + ", ".join(f"'{s}'" for s in OPEN_STATUSES) + ")")


def check_statuses(query: Query) -> list[str]:
    """The statuses in the table right now; raises unless every one is known. Unreadable, empty or misshapen is a
    refusal too - 'I could not read the statuses' must never pass as 'there are no unknown statuses'."""
    rows = query(STATUS_GUARD_SQL)
    if not rows or any(len(r) != 1 or not str(r[0]).strip() for r in rows):
        raise OwingProofError("status guard unreadable: expected one status per row, got "
                              f"{len(rows)} row(s) of shape {sorted({len(r) for r in rows})}")
    seen = sorted({str(r[0]) for r in rows})
    unknown = [s for s in seen if s not in CLOSED_STATUSES + OPEN_STATUSES]
    if unknown:
        raise OwingProofError(f"unknown credit_requests status {unknown}: the open-status list would silently leave "
                              "those rows out, so the read is refused. Classify each as open or closed in "
                              "owing_proof.OPEN_STATUSES / CLOSED_STATUSES")
    return seen


def replica_sql(user_ids: "list[int] | tuple[int, ...] | None" = None) -> str:
    """The EXACT SQL this module runs. Without `user_ids` it is the whole open-request table (REPLICA_SQL, the header's
    pinned string); with them it is THE SAME QUERY restricted to those users.

    [key=facts-scope] (firstmate 2026-11-11, Fable ruling): verify_facts re-ran REPLICA_SQL over the ENTIRE open
    credit_requests table to check the facts of the (at most a few hundred) users on THIS tick's page. On 2026-11-11 the
    replica could not finish it: every tick from 09:2xZ ended `reply-due-paid check (rc=1): UVN STATUS (paid): NOTHING
    sent: the replica facts re-read failed (Command '[/opt/hydra/scripts/trino-query.sh]' timed out after 900 seconds)`,
    and no family behind it sent either. The re-read exists to compare ONE page's facts with the replica, so it only
    ever needs those users' rows: the same SELECT, the same columns, `AND cr.userid IN (...)`.

    The header's `query`/`query_sha256` stay pinned to REPLICA_SQL - the scope is a WHERE clause over the same shape,
    not a different question - and the builder still reads the whole table, because THAT is how the tick learns who
    owes. Only the re-read is scoped."""
    if not user_ids:
        return REPLICA_SQL
    ids = ",".join(str(int(u)) for u in sorted({int(u) for u in user_ids}))
    return f"{REPLICA_SQL} AND cr.userid IN ({ids})"


def _check_shape(rows: list[list[str]]) -> list[list[str]]:
    if any(len(r) != 8 or not str(r[0]).isdigit() or r[4] not in ("0", "1") or r[5] not in ("0", "1")
           or r[6] not in ("0", "1") or r[7] not in ("0", "1") for r in rows):
        raise OwingProofError("unexpected replica row shape")
    return rows


def replica_rows(query: Query) -> list[list[str]]:
    """The whole open-request table (the builder's read). The status guard runs first on every read."""
    check_statuses(query)
    return _check_shape(query(REPLICA_SQL))


# A page is a few hundred users; the read-only replica takes an IN list of this size comfortably. Chunked anyway, because
# a caller with no cap (a hand-run --verify-facts on a full list) must not build one enormous SQL string.
FACTS_SCOPE_CHUNK = 500


def replica_rows_for(query: Query, user_ids: "list[int] | list[str] | None") -> list[list[str]]:
    """The replica's rows for EXACTLY these users (the scoped half of the r5 signing rule). No users = no query at all:
    an empty page has nothing to verify, and asking the replica about the whole table was the 2026-11-11 timeout."""
    ids = sorted({int(u) for u in user_ids or [] if str(u).isdigit()})
    if not ids:
        return []
    rows: list[list[str]] = []
    check_statuses(query)  # the same guard the whole-table read runs: an unknown status refuses BEFORE any audience read
    for i in range(0, len(ids), FACTS_SCOPE_CHUNK):
        rows += query(replica_sql(ids[i:i + FACTS_SCOPE_CHUNK]))
    return _check_shape(rows)


def told_users(ledger_path: str) -> set[int]:
    """Users the uvn-status ASK already went to (r5 / p1 rulings 10-30 18:3xZ + [key=k-proof-required]): one ask per
    user, ever. Any OTHER note (a status line, a receipt) never blocks the ask - the gate opens the ask with the /c2
    correction when that note named the same requests."""
    try:
        db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
        return {int(a) for (a,) in db.execute("SELECT DISTINCT account_id FROM verify_messages WHERE status='sent' "
                                              "AND campaign='uvn-status'")
                if str(a or "").isdigit()}
    except sqlite3.Error as exc:
        raise OwingProofError(f"verify ledger unreadable: {exc}") from exc


NEW_ROWS = "uvn_new_rows"   # Fable 590 (b): owed rows the user's earlier ask never named (the follow-up class)


def asked_rows(ledger_path: str) -> dict[int, set[str]]:
    """{user: request ids named by a SENT uvn-status ask} - the rows an earlier ask already covered."""
    out: dict[int, set[str]] = defaultdict(set)
    try:
        db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
        for a, ids in db.execute("SELECT account_id, request_ids_json FROM verify_messages WHERE status='sent' "
                                 "AND campaign='uvn-status'"):
            if str(a or "").isdigit():
                out[int(a)].update(str(i).lower() for i in json.loads(ids or "[]"))
    except (sqlite3.Error, ValueError) as exc:
        raise OwingProofError(f"verify ledger unreadable: {exc}") from exc
    return out


def new_rows(owe: dict[str, list[str]], asked: set[str]) -> dict[str, list[str]]:
    """Fable 590 (b): the owed rows of an already-told user that no sent ask named AND that carry no core proofRequest
    marker of their own (core already asked about those) - what a follow-up would ask about, and nothing else."""
    return {rid: r for rid, r in owe.items() if rid not in asked and r[6] != "1"}


def held_accounts(holds_path: str, ledger_path: str) -> set[int]:
    held: set[int] = set()
    try:
        # [key=r8-release-row]: the ONE reader (latest row by at; a release only with the lens's current scan agreeing)
        from credit_review import comm_state  # noqa: PLC0415
        held |= {int(u) for u in comm_state.held_user_ids(holds_path=holds_path) if str(u).isdigit()}
        db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
        held |= {int(u) for (u,) in db.execute(
            "SELECT DISTINCT user_id FROM verify_refusal_holds WHERE flagged_at IS NOT NULL AND reason='account-hold' "
            "AND user_id IS NOT NULL") if str(u).isdigit()}
    except (OSError, ValueError, KeyError, sqlite3.Error, RuntimeError) as exc:
        if isinstance(exc, OwingProofError):
            raise
        raise OwingProofError(f"account holds unreadable: {exc}") from exc
    return held


def at_risk_users(path: str) -> tuple[set[int], str]:
    """Paying users with a churn signal (pro-at-risk CSV). Missing file -> no at-risk tier (said in the counts)."""
    if not os.path.exists(path):
        return set(), "missing"
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            return {int(r["userid"]) for r in csv.DictReader(fh) if (r.get("churn_signal") or "").strip()
                    and str(r.get("userid", "")).isdigit()}, "read"
    except (OSError, KeyError, ValueError) as exc:
        raise OwingProofError(f"at-risk file unreadable: {exc}") from exc


def build(*, query: Query | None = None, ledger_path: str = LEDGER, holds_path: str = ACCOUNT_HOLDS,
          at_risk_path: str = AT_RISK, now: datetime | None = None) -> dict[str, Any]:
    rows = replica_rows(query or verify_notify.trino)
    told = told_users(ledger_path)
    asked = asked_rows(ledger_path)
    held = held_accounts(holds_path, ledger_path)
    risky, risk_src = at_risk_users(at_risk_path)
    by_user: dict[int, list[list[str]]] = defaultdict(list)
    for r in rows:
        by_user[int(r[0])].append(r)
    counts: Counter = Counter({"at_risk_file": 0})
    counts["at_risk_file"] = len(risky)
    users = []
    for uid, rs in by_user.items():
        owe, cls = owed(rs, uid in held)
        if not owe:
            continue
        if uid in told or any(r[6] == "1" for r in rs):
            counts[f"skip_already_told_{cls}"] += 1
            # Fable 590 (b): told (by our ask or core's marker), yet owing rows nobody asked about - the follow-up
            # class, listed with ONLY those rows (its copy is r5's to approve; nothing sends it until then)
            fresh = new_rows(owe, asked.get(uid, set())) if cls == "uvn" else {}
            if fresh:
                paid = any(r[4] == "1" for r in rs)
                users.append({"user_id": str(uid), "paid": paid, "skip": None, "at_risk": uid in risky,
                              "request_ids": sorted(fresh), "class": NEW_ROWS, "oldest": min(r[3] for r in fresh.values()),
                              "_tier": 0 if (paid and uid in risky) else 1 if paid else 2, "facts": _facts_of(fresh)})
                counts[f"list_{NEW_ROWS}_{'paid' if paid else 'free'}"] += 1
            continue
        paid = any(r[4] == "1" for r in rs)
        tier = 0 if (paid and uid in risky) else 1 if paid else 2
        oldest = min(r[3] for r in owe.values())
        users.append({"user_id": str(uid), "paid": paid, "skip": None, "at_risk": uid in risky,
                      "request_ids": sorted(owe), "class": cls, "oldest": oldest, "_tier": tier,
                      # r5 signing rule: what the replica said for each named row at list-build time
                      "facts": _facts_of(owe)})
        counts[f"list_{cls}_{'paid' if paid else 'free'}"] += 1
        if tier == 0:
            counts["list_paid_at_risk"] += 1
    users.sort(key=lambda u: (u.pop("_tier"), u["oldest"]))
    counts["at_risk_source"] = risk_src  # type: ignore[assignment]
    return {"generated_at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"), "users": users,
            "counts": dict(counts), "replica_facts": facts_header(users)}


def owed(rs: list[list[str]], held: bool) -> tuple[dict[str, list[str]], str]:
    """THE owed rule (build and verify_facts share it): the user's rows that owe proof, by request id, and the class."""
    uvn = [r for r in rs if r[2] == "user_verification_needed"]
    prq = [r for r in rs if r[2] in ("unverified", "processing") and r[7] == "1"]   # owed per core's verdict
    h2 = [r for r in rs if r[2] == "unverified" and r[5] == "1"]
    h1 = [r for r in rs if r[2] == "unverified"] if held else []
    owe = {r[1]: r for r in uvn + prq + h2 + h1}
    return owe, ("uvn" if (uvn or prq) else "review_hold" if h2 else "account_hold")


def _facts_of(owe: dict[str, list[str]]) -> list[list[Any]]:
    return sorted([r[1], r[2], r[7] == "1"] for r in owe.values())


def facts_header(users: list[dict[str, Any]]) -> dict[str, Any]:
    """r5 signing rule [key=k-proof-required]: the query and a hash of every listed user's per-row facts (request id,
    core status, proof_required) as read at list-build time. `verify_facts` re-runs the same query at signing."""
    blob = json.dumps(sorted([u["user_id"], u["facts"]] for u in users), separators=(",", ":"))
    return {"query": REPLICA_SQL, "query_sha256": hashlib.sha256(REPLICA_SQL.encode()).hexdigest(),
            # the header describes what actually ran: the positive status list is sound only with this guard, which
            # replica_rows runs before the query at build and again at signing
            "guard_query": STATUS_GUARD_SQL, "guard_query_sha256": hashlib.sha256(STATUS_GUARD_SQL.encode()).hexdigest(),
            "sha256": hashlib.sha256(blob.encode()).hexdigest()}


def class_list(res: dict[str, Any], cls: str) -> dict[str, Any]:
    """r5 776 / p1 581 (the 08:00Z dry tick stopped: the tick's own split kept the FULL list's facts sha, so the uvn
    check rightly refused a list changed after its build): the builder emits a one-class list ITSELF, from the same
    build, with the header re-derived over exactly the users it lists, and the parent's digest named in split_of."""
    users = [u for u in res["users"] if u.get("class") == cls]
    return {"generated_at": res["generated_at"], "replica_facts": facts_header(users), "users": users,
            "split_of": {"class": cls, "users": len(res["users"]), "sha256": res["replica_facts"]["sha256"]}}


def _write(path: str, doc: dict[str, Any]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({**doc, "signed_on": verify_notify.deployed_head()}, fh, indent=1)     # [key=signed-on-sha]
    os.replace(tmp, path)


def local_diffs(lst: dict[str, Any], held: set[int], asked: dict[int, set[str]]) -> list[str]:
    """The replica-INDEPENDENT half of verify_facts: the header digest, the account holds and the sent asks. A replica
    re-read that times out may fall back to the list's own facts, but never past these.

    Only a hold RELEASE is locally observable: a class-account_hold entry was built because that account was held, so a
    release since the build shrinks its owed set. A hold that STARTED since the build cannot be seen without the
    replica's rows (the h1 class adds every unverified row), so it is not claimed here."""
    diffs = []
    head = (lst.get("replica_facts") or {}).get("sha256")
    if head != facts_header(lst.get("users") or [])["sha256"]:
        diffs.append(f"header: replica_facts.sha256 {head} does not match the listed facts (the list changed after its build)")
    for u in lst.get("users") or []:
        uid = int(u["user_id"])
        if u.get("class") == "account_hold" and uid not in held:
            diffs.append(f"{uid}: the account hold was released since the build")
        named = {str(i).lower() for i in u.get("request_ids") or []}
        if (named & asked.get(uid, set())) if u.get("class") == NEW_ROWS else (uid in asked):
            diffs.append(f"{uid}: an ask was sent since the build")
    return diffs


def verify_facts(lst: dict[str, Any], query: Query, *, holds_path: str = ACCOUNT_HOLDS,
                 ledger_path: str = LEDGER) -> list[str]:
    """Re-read the replica for a built list (r5 signing rule); every listed user whose OWED set changed since the build
    (empty = the list still says what the replica says). QA #1565: the owed set is RECOMPUTED with build's own rule
    (owed()), so a request that became owed after the build - one the signed ask would omit, while the one-ask lock
    then blocks a follow-up - is a change, exactly like a row that moved or cleared; request_ids must equal the owed
    ids; and the list's header digest must still match its facts (a list edited after the build is refused).
    A user whose facts changed is OUT of the signed batch."""
    held = held_accounts(holds_path, ledger_path)
    asked = asked_rows(ledger_path)
    diffs = local_diffs(lst, held, asked)
    now: dict[str, list[str]] = {}
    # [key=facts-scope]: the re-read asks the replica about THIS page's users, never the whole table
    for r in replica_rows_for(query, [u.get("user_id") for u in lst.get("users") or []]):
        now.setdefault(r[0], []).append(r)
    for u in lst.get("users") or []:
        owe, _ = owed(now.get(str(u["user_id"]), []), int(u["user_id"]) in held)
        if u.get("class") == NEW_ROWS:          # the follow-up class: only the rows no ask named (as build lists them)
            owe = new_rows(owe, asked.get(int(u["user_id"]), set()))
        cur = _facts_of(owe)
        if cur != u.get("facts") or sorted(owe) != sorted(u.get("request_ids") or []):
            diffs.append(f"{u['user_id']}: listed {u.get('facts')} ids {sorted(u.get('request_ids') or [])} -> now {cur}")
    return diffs


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="S1 credit-hold-status audience (read-only)")
    ap.add_argument("--out", default="")
    ap.add_argument("--verify-facts", default="", help="a built list: re-read the replica and print the users whose "
                    "facts changed since it was built (r5 signing rule); exit 1 when any did")
    ap.add_argument("--class-out", action="append", default=[], metavar="CLASS=PATH",
                    help="also write the one-class list (uvn / review_hold / account_hold) from this build, with its own "
                         "facts header (r5 776: the tick never edits a built list)")
    ap.add_argument("--at-risk", default=AT_RISK)
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--account-holds", default=ACCOUNT_HOLDS)
    a = ap.parse_args(argv)
    if a.verify_facts:
        try:
            with open(a.verify_facts, encoding="utf-8") as fh:
                lst = json.load(fh)
            diffs = verify_facts(lst, verify_notify.trino, holds_path=a.account_holds, ledger_path=a.ledger)
        except (OSError, ValueError, OwingProofError, RuntimeError) as exc:
            print(json.dumps({"error": str(exc)}))
            return 2
        print(json.dumps({"users": len(lst.get("users") or []), "changed": diffs, "header": lst.get("replica_facts")}))
        return 1 if diffs else 0
    if not a.out:
        ap.error("--out is required")
    outs = []
    for spec in a.class_out:
        cls, _, path = spec.partition("=")
        if cls not in ("uvn", "review_hold", "account_hold", NEW_ROWS) or not path:
            ap.error(f"--class-out {spec!r}: want CLASS=PATH with CLASS uvn / review_hold / account_hold / {NEW_ROWS}")
        outs.append((cls, path))
    try:
        res = build(ledger_path=a.ledger, holds_path=a.account_holds, at_risk_path=a.at_risk)
    except (OwingProofError, RuntimeError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    _write(a.out, {"generated_at": res["generated_at"], "replica_facts": res["replica_facts"], "users": res["users"]})
    for cls, path in outs:
        _write(path, class_list(res, cls))
    classes = dict(Counter(u.get("class") for u in res["users"]))
    print(json.dumps({"generated_at": res["generated_at"], "counts": res["counts"], "classes": classes}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
