#!/usr/bin/env python3
"""Read-only dry run: what the decider's ask filter does with the requests parked on the support@ hold.

Run on node-8 as a file. It opens the ledger and every proof source read-only, asks the core replica one
question, writes nothing and prints counts only (no request id, user id or title).

The population is every request whose NEWEST decider row is the support@ hold. For each one still
`unverified` in core (the only status the decider lists), it rebuilds the ladder verdict that hold replaced,
an ask, and runs the DEPLOYED `filter_support` twice: as deployed (control), and with
`ProofOnFile.contacted_support` answering False, which is what removing that branch does.

What it does not do: re-run the ladder. A request whose evidence changed since its last row may get another
ladder verdict on the next run. The replay also holds only these rows, so the 100 users/run and 400
users/day ask caps are theirs alone here; in a real run they share them with every other ask.
"""
from __future__ import annotations

import csv
import hashlib
import inspect
import io
import re
import sqlite3
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import decide  # noqa: E402

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
TRINO = "/opt/hydra/scripts/trino-query.sh"
MARK = "emailed support@ in the last 90 days"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def core_rows(ids: list[str]) -> dict[str, tuple[str, str, bool]]:
    """request id -> (status, createdAt, deleted), from the core replica."""
    out: dict[str, tuple[str, str, bool]] = {}
    for i in range(0, len(ids), 500):
        chunk = [x for x in ids[i:i + 500] if UUID.match(x)]
        if not chunk:
            continue
        sql = ("SELECT lower(CAST(cr.id AS varchar)), cr.status, to_iso8601(cr.createdat), "
               "CAST(cr.deletedat IS NOT NULL AS varchar) FROM postgresql_core.public.credit_requests cr "
               "WHERE lower(CAST(cr.id AS varchar)) IN (" + ",".join(f"'{x}'" for x in chunk) + ")")
        p = subprocess.run([TRINO, sql], capture_output=True, text=True, timeout=180)
        if p.returncode != 0:
            raise SystemExit(f"replica read failed rc={p.returncode}: {p.stderr[-300:]}")
        for row in csv.reader(io.StringIO(p.stdout)):
            if len(row) >= 4 and UUID.match(row[0]):
                out[row[0]] = (row[1], row[2], row[3].lower() == "true")
    return out


def prefix(reason: str) -> str:
    for marker in decide.ASK_HOLD_MARKERS:
        if reason.startswith(marker):
            return marker
    return reason.split(":")[0][:70]


def replay(db, rows, core, proof, why, policy, now, *, lifted: bool) -> Counter:
    stubs = []
    for r in rows:
        rid = r["request_id"].lower()
        stubs.append(decide.Decision(
            request_id=rid, profile_id=r["profile_id"], user_id=r["user_id"], track_id=r["track_id"],
            track_title=r["track_title"] or "", claimed_roles=[x for x in (r["claimed_roles"] or "").split(",") if x],
            popularity=r["popularity"], big_track=bool(r["big_track"]), decision="support", reason="replayed ask",
            paid_priority=None if r["paid_priority"] is None else bool(r["paid_priority"]),
            request_created_at=core[rid][1]))
    stubs.sort(key=lambda d: (d.paid_priority is not True, d.request_id))
    original = decide.ProofOnFile.contacted_support
    if lifted:
        decide.ProofOnFile.contacted_support = lambda self, d: False
    try:
        decide.filter_support(db, stubs, decide.RunResult(run_id="dry-run", mode="judge"), proof, why, now,
                              policy.max_ask_users_per_day, policy.max_ask_users_per_run)
    finally:
        decide.ProofOnFile.contacted_support = original
    users: dict[tuple[str, str], set] = defaultdict(set)
    count: Counter = Counter()
    for d in stubs:
        key = (d.decision, prefix(d.reason) if d.decision != "support" else "ask stands")
        count[key] += 1
        users[key].add(d.user_id)
    return Counter({(k[0], k[1], len(users[k])): n for k, n in count.items()})


def main() -> int:
    now = datetime.now(timezone.utc)
    src = inspect.getsource(decide.filter_support)
    if "elif proof.contacted_support(d):" not in src:
        raise SystemExit("the deployed filter_support has no contacted_support branch: nothing to replay")
    print(f"at {now:%Y-%m-%dT%H:%M:%SZ} deployed {open('/opt/hydra/.deployed-sha').read().strip()[:12]} "
          f"filter_support sha256 {hashlib.sha256(src.encode()).hexdigest()[:12]}")
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True, timeout=60)
    db.row_factory = sqlite3.Row
    newest = db.execute(
        "WITH held AS (SELECT DISTINCT request_id FROM decisions WHERE instr(reason, ?) > 0), "
        "last AS (SELECT request_id, max(id) AS id FROM decisions WHERE request_id IN "
        "(SELECT request_id FROM held) GROUP BY request_id) "
        "SELECT d.* FROM decisions d JOIN last ON last.id = d.id", (MARK,)).fetchall()
    parked = [r for r in newest if r["reason"].startswith(MARK)]
    print(f"requests ever held on the reason: {len(newest)}; newest row is still that hold: {len(parked)} "
          f"({len({r['user_id'] for r in parked})} users)")
    core = core_rows([r["request_id"].lower() for r in parked])
    status = Counter("missing" if r["request_id"].lower() not in core else
                     "deleted" if core[r["request_id"].lower()][2] else core[r["request_id"].lower()][0]
                     for r in parked)
    print("core status today:", dict(status.most_common()))
    listed = [r for r in parked if core.get(r["request_id"].lower(), ("", "", True))[0] == "unverified"
              and not core[r["request_id"].lower()][2]]
    print(f"still listed by the decider (unverified): {len(listed)} ({len({r['user_id'] for r in listed})} users)")
    proof, why = decide.proof_on_file(now=now)
    proof = decide.with_intake(decide.with_stage2(proof))
    print("proof status:", "readable" if proof is not None else f"UNKNOWN ({why})")
    policy = decide.Policy.load()
    print(f"caps: {policy.max_ask_users_per_run} users/run, {policy.max_ask_users_per_day} users/day")
    for label, lifted in (("as deployed (control)", False), ("with the support@ hold removed", True)):
        print(f"-- {label}")
        for (decision, why_, users), n in sorted(replay(db, listed, core, proof, why, policy, now,
                                                        lifted=lifted).items(), key=lambda kv: -kv[1]):
            print(f"   {n:5d} requests / {users:3d} users  {decision:8s} {why_}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
