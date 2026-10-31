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
Query = Callable[[str], "list[list[str]]"]


class OwingProofError(RuntimeError):
    pass


def replica_rows(query: Query) -> list[list[str]]:
    rows = query("SELECT CAST(cr.userid AS varchar), lower(CAST(cr.id AS varchar)), cr.status, CAST(cr.createdat AS varchar), "
                 f"CAST(CASE WHEN cr.workspaceid IN {PAID_WS} THEN 1 ELSE 0 END AS varchar), "
                 f"CAST(CASE WHEN {REVIEW_FIRED} THEN 1 ELSE 0 END AS varchar), "
                 "CAST(CASE WHEN json_extract(cr.metadata, '$.proofRequest') IS NOT NULL THEN 1 ELSE 0 END AS varchar) "
                 "FROM postgresql_core.public.credit_requests cr WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL "
                 "AND cr.status NOT IN ('approved', 'rejected')")
    if any(len(r) != 7 or not str(r[0]).isdigit() or r[4] not in ("0", "1") or r[5] not in ("0", "1")
           or r[6] not in ("0", "1") for r in rows):
        raise OwingProofError("unexpected replica row shape")
    return rows


def told_users(ledger_path: str) -> set[int]:
    try:
        db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
        return {int(a) for (a,) in db.execute("SELECT DISTINCT account_id FROM verify_messages WHERE status='sent'")
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
        uvn = [r for r in rs if r[2] == "user_verification_needed"]
        h2 = [r for r in rs if r[2] == "unverified" and r[5] == "1"]
        h1 = [r for r in rs if r[2] == "unverified"] if uid in held else []
        owe = {r[1]: r for r in uvn + h2 + h1}
        if not owe:
            continue
        cls = "uvn" if uvn else "review_hold" if h2 else "account_hold"
        if uid in told or any(r[6] == "1" for r in rs):
            counts[f"skip_already_told_{cls}"] += 1
            continue
        paid = any(r[4] == "1" for r in rs)
        tier = 0 if (paid and uid in risky) else 1 if paid else 2
        oldest = min(r[3] for r in owe.values())
        users.append({"user_id": str(uid), "paid": paid, "skip": None, "at_risk": uid in risky,
                      "request_ids": sorted(owe), "class": cls, "oldest": oldest, "_tier": tier})
        counts[f"list_{cls}_{'paid' if paid else 'free'}"] += 1
        if tier == 0:
            counts["list_paid_at_risk"] += 1
    users.sort(key=lambda u: (u.pop("_tier"), u["oldest"]))
    counts["at_risk_source"] = risk_src  # type: ignore[assignment]
    return {"generated_at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"), "users": users,
            "counts": dict(counts)}


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="S1 credit-hold-status audience (read-only)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--at-risk", default=AT_RISK)
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--account-holds", default=ACCOUNT_HOLDS)
    a = ap.parse_args(argv)
    try:
        res = build(ledger_path=a.ledger, holds_path=a.account_holds, at_risk_path=a.at_risk)
    except (OwingProofError, RuntimeError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"generated_at": res["generated_at"], "users": res["users"]}, fh, indent=1)
    os.replace(tmp, a.out)
    print(json.dumps({"generated_at": res["generated_at"], "counts": res["counts"]}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
