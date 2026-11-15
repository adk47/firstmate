"""The paid-band ask lane (captain r4 GO 3, firstmate 413 2026-11-11): the never-told PAID users whose band rows the
ask lane has never reached.

Why this exists (measured 2026-11-11 on the core replica + node-8's verify ledger):
  - every row in the score-approve band is `user_verification_needed` (5,782 rows; zero `unverified`), and the
    decider's candidate source only lists `unverified` rows (`decide.held_rows`), so the decider's support/ask
    lane structurally cannot reach a band row;
  - of the 1,655 paid band rows with NO core proofRequest marker (476 users), 288 users have never received any
    Intercom message and only ~70 were ever asked for proof, so "every request ends approved or the user is told"
    fails for them in both directions.

What this does: takes `owing_proof`'s signed build (the never-told + owes-proof audience, the same rule the
`uvn-status` campaign consumes) and keeps only the users who have band rows, then caps the list. It names USERS,
not rows: one ask per user, ever (the gate's shared ask lock), so the note names the user's owed rows - the
scope decides WHO is asked, never which of their rows the note may mention.

Bounds, all enforced here, none of them a new switch:
  - the row predicate (BAND_SQL): status user_verification_needed, deletedat null, is_approved, total_risk < 30,
    band_hint A/B, spotifypopularity 1-59, metadata.proofRequest IS NULL;
  - `max_ask_users_per_day` from policies/credit-trust-decide.json (400): DISTINCT USERS, in the shared send
    order (`audience_order`): paid before free, oldest request first, the user id last. Unreadable policy =
    REFUSAL (nothing listed), never a silent 0;
  - paid only when --paid-only (the default): the captain's cohort is paying customers.
A user already told (a sent `uvn-status` ask) or holding a core proofRequest marker is already out of the
owing_proof build, so this lane can never re-ask them.

"No core proofRequest marker" is not "owes proof". The send gate also drops a user whose documents are already
on file (unless a stage-2 verdict released the credits) and a user whose listed rows are all on the approval
path or already on the profile, so `candidates` used to be measured one filter before the gate: on 2026-11-13
it said 213 and the gate's dry run would message 15 (68 had documents on file and 127 had nothing to ask about,
which leaves 18), and the apply sent 3. `candidates` now counts only the users `uvn_status.still_owing` keeps -
the gate's own functions, never a copy of them - and `not_owed` says how many each gate rule dropped (a
`stage2_unreadable` key, at 0, says the verdict store could not be read, so nobody was released from the
documents hold).

`candidates` is therefore an UPPER BOUND on what the gate sends, not the sendable number. The gate also holds a
user per send, and those holds stay in the gate: the fraud lens, the 7-day message window and the Intercom-side
deferrals. Measured pairs: on node-8 at 2026-11-13T15:08Z, `candidates` 16 vs 13 would be messaged (3 deferred by
the 7-day window); on the earlier list that day, 213 listed, 15 would be messaged and 3 actually sent.

READ-ONLY: this writes one runner list. Sending stays with `credit-review.py uvn-status --campaign uvn-status
--list FILE` (its approved copy, its gate, its ledger, its own daily cap); nothing here approves, arms or sends.

CLI:  paid_band_ask.py --out FILE [--max-users N] [--policy PATH] [--at-risk CSV] [--ledger PATH]
                         [--account-holds PATH] [--proof-on-file PATH] [--proof-store PATH] [--dry-run]
      paid_band_ask.py --filter-built LIST --out FILE      (re-scope an existing owing_proof build: one replica
                                                           read for the listed users' pending rows)
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import audience_order, owing_proof, uvn_status, verify_ledger, verify_notify  # noqa: E402

POLICY = os.environ.get("CREDIT_TRUST_DECIDE_POLICY", "/opt/hydra/policies/credit-trust-decide.json")
CAP_KEY = "max_ask_users_per_day"

#: the band rows, per user. Deliberately the same predicate as score_approve.replica_candidates() minus the
#: band-hint stamp (these rows carry NO proofRequest at all: that is the cohort).
BAND_SQL = (
    "SELECT CAST(cr.userid AS varchar) || '|' || lower(CAST(cr.id AS varchar)) "
    "FROM postgresql_core.public.credit_requests cr "
    "WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL "
    "AND cr.status = 'user_verification_needed' "
    "AND json_extract_scalar(cr.verificationdata, '$.is_approved') = 'true' "
    "AND CAST(json_extract_scalar(cr.verificationdata, '$.total_risk_percent') AS double) < 30 "
    "AND json_extract_scalar(cr.verificationdata, '$.band_hint') IN ('A','B') "
    "AND json_extract(cr.metadata, '$.proofRequest') IS NULL "
    "AND cr.spotifypopularity BETWEEN 1 AND 59"
)
Query = Callable[[str], "list[list[str]]"]

#: users per replica read (see narrowed_query: the cluster times out on one big IN list)
BATCH = 100


class BandAskError(RuntimeError):
    pass


def ask_cap(policy_path: str = POLICY) -> int:
    """The captain's cap (400 users/day), read from the decider policy so there is ONE knob. Unreadable,
    malformed or non-positive = REFUSAL: nothing is listed rather than an uncapped wave."""
    try:
        with open(policy_path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise BandAskError(f"policy unreadable ({policy_path}): {exc}") from exc
    v = doc.get(CAP_KEY) if isinstance(doc, dict) else None
    if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
        raise BandAskError(f"policy {CAP_KEY} is {v!r}: a cap of 0 or less is a refusal, not a licence")
    return v


def band_users(query: Query) -> dict[int, set[str]]:
    """{user: the user's band request ids} from the core replica. A row of an unexpected shape is a refusal:
    a half-read cohort would list the wrong users."""
    rows = query(BAND_SQL)
    out: dict[int, set[str]] = {}
    for r in rows:
        if len(r) != 1 or "|" not in str(r[0]):
            raise BandAskError("unexpected replica row shape (want one 'user|request' column)")
        uid, _, rid = str(r[0]).partition("|")
        if not uid.isdigit() or not rid:
            raise BandAskError(f"unexpected replica row {r[0]!r}")
        out.setdefault(int(uid), set()).add(rid)
    return out


def asked_recently(ledger_path: str, day: str, days: int = verify_ledger.REASK_LOCK_DAYS):
    """The sender's OWN 90-day ask lock (`verify_ledger.asked_within`), so a slot is never spent on a user
    uvn-status would drop as `recently_asked` - the cap is the captain's whole bound, so it must be reachable
    users, not names the sender refuses. One function, one rule: this never re-implements the lock."""
    db = verify_ledger.connect_ro(ledger_path, must_exist=True)

    def fn(user_id: str) -> bool:
        return verify_ledger.asked_within(db, user_key="", day=day, days=days, user_id=str(user_id))

    return fn


def narrowed_query(user_ids: Any):
    """`owing_proof.build`'s replica read, restricted to the users this lane can possibly list.

    REPLICA_SQL streams EVERY non-terminal credit request (77k+ rows and growing) and the cluster kills it at the
    statement timeout, which made the whole builder unusable. Only the band users can appear in this lane, and
    `owing_proof.verify_facts` compares per LISTED user (it recomputes each listed user's owed set; it makes no
    claim about users who are not listed), so reading just those users yields the same list - as the test that
    re-signs and re-verifies through verify_facts pins."""
    ids = sorted({int(u) for u in user_ids})
    def q(sql: str) -> "list[list[str]]":
        if sql != owing_proof.REPLICA_SQL:
            return verify_notify.trino(sql)
        rows: "list[list[str]]" = []
        # 100 users per read: 50 ids answer in ~5s, the whole cohort in one IN list blows the cluster's statement
        # timeout (486s, killed), so the read is chunked rather than raced
        for i in range(0, len(ids), BATCH):
            chunk = ",".join(str(u) for u in ids[i:i + BATCH]) or "NULL"
            rows.extend(verify_notify.trino(sql + f" AND cr.userid IN ({chunk})"))
        return rows
    return q


#: users -> (the ones the send gate's list-side rules would still ask, {the gate's reason: users dropped})
Owes = Callable[["list[dict[str, Any]]"], "tuple[list[dict[str, Any]], dict[str, int]]"]


def still_owing(ledger_path: str, proof_path: str | None = None, stage2_path: str | None = None) -> Owes:
    """The send gate's own answer to "does this user still owe proof" (`uvn_status.still_owing`: documents on
    file, the stage-2 release, the approval path). One rule, the gate's: this never re-implements it."""
    def fn(users: "list[dict[str, Any]]") -> "tuple[list[dict[str, Any]], dict[str, int]]":
        return uvn_status.still_owing(users, campaign=uvn_status.CAMPAIGN, query=verify_notify.trino,
                                      ledger_path=ledger_path, proof_path=proof_path, stage2_path=stage2_path)
    return fn


def scope(build: dict[str, Any], band: dict[int, set[str]], cap: int, *, paid_only: bool = True,
          asked_recently: Callable[[str], bool] | None = None, owes: Owes | None = None) -> dict[str, Any]:
    """The capped runner list: owing_proof's NEVER-TOLD (`class == uvn`) users that carry band rows AND still owe
    proof by the send gate's rules (`owes`), paid first, oldest first.

    `owes` runs before the cap, so `candidates` is people the gate would still ask FROM THE LIST - an upper bound,
    since its per-send holds (fraud lens, 7-day window, Intercom-side deferrals) stay in the gate - and a slot is
    never spent on a user it drops for documents on file or for having nothing to ask about.

    `class == "uvn"` is load-bearing (QA 1886): `owing_proof` also lists a `uvn_new_rows` follow-up class - users
    who were already asked, but whose new rows no ask named - and uvn-status drops those as `already_sent` before
    it spends budget, so counting them here would spend the cap on messages that never leave.

    The list keeps each user's FULL owed request_ids (that is what the one note names), and re-signs the facts
    header for exactly the users kept, so `owing_proof.verify_facts` still passes at signing time."""
    users = [u for u in build.get("users") or []
             if str(u.get("user_id")) in {str(k) for k in band} and u.get("class") == "uvn"]
    if paid_only:
        users = [u for u in users if u.get("paid")]
    locked = 0
    if asked_recently is not None:
        fresh = []
        for u in users:
            if asked_recently(str(u.get("user_id"))):
                locked += 1
            else:
                fresh.append(u)
        users = fresh
    not_owed: dict[str, int] = {}
    if owes is not None:
        users, not_owed = owes(users)
    # THE send order (audience_order): paying at-risk, paying, free; the oldest owed request first; the user id last
    users.sort(key=lambda u: audience_order.key(paid=u.get("paid"), at_risk=u.get("at_risk"),
                                                waiting_since=u.get("oldest") or "", user_id=u.get("user_id")))
    kept, dropped = users[:cap], users[cap:]
    doc = {
        "generated_at": build.get("generated_at"),
        "replica_facts": owing_proof.facts_header(kept),
        "users": kept,
        "ask_lane": {
            "scope": "paid band, never told",
            "predicate": BAND_SQL,
            "max_users_per_day": cap,
            "candidates": len(users),
            "listed": len(kept),
            "deferred_to_later_day": len(dropped),
            "recently_asked_inside_90d": locked,
            "not_owed": dict(sorted(not_owed.items())),
            "paid_only": paid_only,
        },
    }
    return doc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="the paid-band ask lane audience (read-only)")
    ap.add_argument("--out", default="")
    ap.add_argument("--filter-built", default="",
                    help="an owing_proof build to re-scope instead of building it from the band read "
                    "(still one replica read for the listed users' pending rows)")
    ap.add_argument("--max-users", type=int, default=None, help="override the policy cap (never above it)")
    ap.add_argument("--policy", default=POLICY)
    ap.add_argument("--at-risk", default=owing_proof.AT_RISK)
    ap.add_argument("--ledger", default=owing_proof.LEDGER)
    ap.add_argument("--account-holds", default=owing_proof.ACCOUNT_HOLDS)
    ap.add_argument("--proof-on-file", default=None, help="the documents-on-file snapshot (default: the gate's)")
    ap.add_argument("--proof-store", default=None, help="the stage-2 verdict store (default: the gate's)")
    ap.add_argument("--dry-run", action="store_true", help="report the counts, write nothing")
    a = ap.parse_args(argv)
    try:
        cap = ask_cap(a.policy)
        if a.max_users is not None:
            if a.max_users <= 0:
                raise BandAskError("--max-users must be positive")
            cap = min(cap, a.max_users)          # an override may lower the cap, never raise it
        if a.filter_built:
            with open(a.filter_built, encoding="utf-8") as fh:
                build = json.load(fh)
            band = band_users(verify_notify.trino)
        else:
            band = band_users(verify_notify.trino)          # cheap (~5s); it also NARROWS the build below
            build = owing_proof.build(query=narrowed_query(band), ledger_path=a.ledger,
                                      holds_path=a.account_holds, at_risk_path=a.at_risk)
        day = str(build.get("generated_at") or "")[:10] or verify_ledger.utcnow().date().isoformat()
        doc = scope(build, band, cap, asked_recently=asked_recently(a.ledger, day),
                    owes=still_owing(a.ledger, a.proof_on_file, a.proof_store))
    except (BandAskError, owing_proof.OwingProofError, OSError, ValueError, RuntimeError, sqlite3.Error) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    lane = doc["ask_lane"]
    summary = {"candidates": lane["candidates"], "listed": lane["listed"],
               "deferred_to_later_day": lane["deferred_to_later_day"], "max_users_per_day": cap,
               "recently_asked_inside_90d": lane["recently_asked_inside_90d"],
               "users_with_band_rows": len(band), "not_owed": lane["not_owed"]}
    if a.dry_run:
        print(json.dumps({**summary, "dry_run": True}))
        return 0
    if not a.out:
        ap.error("--out is required (or --dry-run)")
    owing_proof._write(a.out, doc)
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
