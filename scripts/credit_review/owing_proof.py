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


# r5 signing rule: the list header carries THIS exact, runnable SQL (and its sha256) - one string, the one replica_rows
# runs at build and verify_facts re-runs at signing
REPLICA_SQL = ("SELECT CAST(cr.userid AS varchar), lower(CAST(cr.id AS varchar)), cr.status, CAST(cr.createdat AS varchar), "
               f"CAST(CASE WHEN cr.workspaceid IN {PAID_WS} THEN 1 ELSE 0 END AS varchar), "
               f"CAST(CASE WHEN {REVIEW_FIRED} THEN 1 ELSE 0 END AS varchar), "
               "CAST(CASE WHEN json_extract(cr.metadata, '$.proofRequest') IS NOT NULL THEN 1 ELSE 0 END AS varchar), "
               f"CAST(CASE WHEN {PROOF_REQUIRED} THEN 1 ELSE 0 END AS varchar) "
               "FROM postgresql_core.public.credit_requests cr WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL "
               "AND cr.status NOT IN ('approved', 'rejected')")


def replica_rows(query: Query) -> list[list[str]]:
    rows = query(REPLICA_SQL)
    if any(len(r) != 8 or not str(r[0]).isdigit() or r[4] not in ("0", "1") or r[5] not in ("0", "1")
           or r[6] not in ("0", "1") or r[7] not in ("0", "1") for r in rows):
        raise OwingProofError("unexpected replica row shape")
    return rows


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
            "sha256": hashlib.sha256(blob.encode()).hexdigest()}


def verify_facts(lst: dict[str, Any], query: Query, *, holds_path: str = ACCOUNT_HOLDS,
                 ledger_path: str = LEDGER) -> list[str]:
    """Re-read the replica for a built list (r5 signing rule); every listed user whose OWED set changed since the build
    (empty = the list still says what the replica says). QA #1565: the owed set is RECOMPUTED with build's own rule
    (owed()), so a request that became owed after the build - one the signed ask would omit, while the one-ask lock
    then blocks a follow-up - is a change, exactly like a row that moved or cleared; request_ids must equal the owed
    ids; and the list's header digest must still match its facts (a list edited after the build is refused).
    A user whose facts changed is OUT of the signed batch."""
    diffs = []
    head = (lst.get("replica_facts") or {}).get("sha256")
    if head != facts_header(lst.get("users") or [])["sha256"]:
        diffs.append(f"header: replica_facts.sha256 {head} does not match the listed facts (the list changed after its build)")
    now: dict[str, list[list[str]]] = {}
    for r in replica_rows(query):
        now.setdefault(r[0], []).append(r)
    held = held_accounts(holds_path, ledger_path)
    for u in lst.get("users") or []:
        owe, _ = owed(now.get(str(u["user_id"]), []), int(u["user_id"]) in held)
        cur = _facts_of(owe)
        if cur != u.get("facts") or sorted(owe) != sorted(u.get("request_ids") or []):
            diffs.append(f"{u['user_id']}: listed {u.get('facts')} ids {sorted(u.get('request_ids') or [])} -> now {cur}")
    return diffs


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="S1 credit-hold-status audience (read-only)")
    ap.add_argument("--out", default="")
    ap.add_argument("--verify-facts", default="", help="a built list: re-read the replica and print the users whose "
                    "facts changed since it was built (r5 signing rule); exit 1 when any did")
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
    try:
        res = build(ledger_path=a.ledger, holds_path=a.account_holds, at_risk_path=a.at_risk)
    except (OwingProofError, RuntimeError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"generated_at": res["generated_at"], "replica_facts": res["replica_facts"], "users": res["users"]},
                  fh, indent=1)
    os.replace(tmp, a.out)
    print(json.dumps({"generated_at": res["generated_at"], "counts": res["counts"]}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
