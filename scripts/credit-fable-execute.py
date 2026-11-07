#!/usr/bin/env python3
"""credit-fable-execute.py: run ONE Fable-ruled close tray through the L12 executor (fable-decider).

  credit-fable-execute.py <tray.json>                 dry run (default): fresh facts + guards, writes nothing
  credit-fable-execute.py <tray.json> --apply --limit 1   the ONE-row end-to-end check before a tray
  credit-fable-execute.py <tray.json> --apply         the tray, paid first, capped, stopping on the first surprise

Never scheduled (scripts/check-credit-approval-automation.sh NEVER_SCHEDULED). Kill file:
/etc/hydra/fable-decider.disabled. Audit: /var/lib/hydra/credit-review/fable-decider-audit.jsonl.
Prints one JSON summary line on stdout. Exit 0 = ran to the end, 1 = stopped on a surprise, 2 = tray refused.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import claim_executor as cx  # noqa: E402
from credit_review import decline_close as dc  # noqa: E402
from credit_review import fable_executor as fx  # noqa: E402

FANOUT_WAIT_S = int(os.environ.get("FABLE_DECIDER_FANOUT_WAIT_S", "90"))
MESSAGING_PG = os.environ.get(
    "FABLE_DECIDER_MESSAGING_PG",
    "kubectl -n messaging exec -i messaging-pg-pgha-6c8n-0 -c database -- psql -U postgres -d preferences -At '-F|'")


def fanout_check(rows: list[tuple[str, int, str | None]], since: datetime,
                 template: str = "credits_rejected") -> str | None:
    """credits_rejected notes since the batch started, per user (send-gateway ledger, read-only). Core emits one
    rejection event per (user, profile) group per call, so more notes than that for a user is a surprise."""
    time.sleep(FANOUT_WAIT_S)
    users = sorted({u for _, u, _ in rows})
    groups: dict[int, set] = {}
    for _, u, pid in rows:
        groups.setdefault(u, set()).add(pid)
    sql = (f"select user_id, count(*) from send.messages where template_key = '{template}' "
           f"and created_at >= '{since.strftime('%Y-%m-%dT%H:%M:%SZ')}' "
           f"and user_id in ({','.join(repr(str(u)) for u in users)}) group by 1;")
    p = subprocess.run(shlex.split(MESSAGING_PG), input=sql, capture_output=True, text=True, timeout=120,
                       check=False)
    if p.returncode != 0:
        return f"send ledger unreadable rc={p.returncode}: {p.stderr.strip()[:160]}"
    counts = {}
    for line in p.stdout.splitlines():
        parts = line.split("|")
        if len(parts) == 2 and parts[1].isdigit():
            counts[parts[0]] = int(parts[1])
    over = {u: n for u, n in counts.items() if u.isdigit() and n > len(groups.get(int(u), ()))}
    print(json.dumps({"fanout": {"since": since.isoformat(), "users": len(users), "notes": sum(counts.values()),
                                 "users_noted": len(counts), "over": over}}), file=sys.stderr)
    if over:
        return f"more {template} notes than (user, profile) groups for {sorted(over)[:10]}"
    return None


def decline_plan(rows: list[tuple[str, int, str | None]], since: datetime) -> str | None:
    """After a rejected batch was written: who tells each user, core's own email or hydra's `decline` campaign
    (decline_close: the measured send-gateway ledger plus the configured route map, READ, never guessed).

    This never sends: the plan is printed for the operator, and the campaign gate owns every send rule. The one
    forbidden outcome is two decline messages for one request (core email + hydra campaign), so a user the ledger
    cannot be read for is HELD, not sent. Returning a surprise stops the run (a person looks before anything else)."""
    users = sorted({u for _, u, _ in rows})
    result = dc.plan(users, since.strftime("%Y-%m-%dT%H:%M:%SZ"))
    print(json.dumps({"declines": {k: v for k, v in result.items() if k != "users"},
                      "declines_by_user": result["users"]}), file=sys.stderr)
    held = [u for u, row in result["users"].items() if row["decision"] == dc.HOLD]
    if held:
        return (f"{len(held)} user(s) cannot be told whether core's email already went out ({held[:10]}); "
                "nothing else is sent to them")
    return None


def claim_fanout_check(rows: list[tuple[int, int]], since: datetime) -> str | None:
    """profile_claim_rejected notes since the batch started, per user (send-gateway ledger, read-only). Core sends
    one per rejected claim, so more notes than claims declined for a user, or any OTHER claim template to these
    users in the window, is a surprise."""
    time.sleep(FANOUT_WAIT_S)
    per_user: dict[int, int] = {}
    for _, u in rows:
        per_user[u] = per_user.get(u, 0) + 1
    sql = ("select user_id, template_key, count(*) from send.messages where template_key ilike '%claim%' "
           f"and created_at >= '{since.strftime('%Y-%m-%dT%H:%M:%SZ')}' "
           f"and user_id in ({','.join(repr(str(u)) for u in sorted(per_user))}) group by 1, 2;")
    p = subprocess.run(shlex.split(MESSAGING_PG), input=sql, capture_output=True, text=True, timeout=120,
                       check=False)
    if p.returncode != 0:
        return f"send ledger unreadable rc={p.returncode}: {p.stderr.strip()[:160]}"
    over, other = {}, []
    seen: dict[str, int] = {}
    for line in p.stdout.splitlines():
        parts = line.split("|")
        if len(parts) != 3 or not parts[2].isdigit():
            continue
        uid, key, n = parts[0], parts[1], int(parts[2])
        if key != "profile_claim_rejected":
            other.append(f"{uid}:{key}")
            continue
        seen[uid] = n
        if uid.isdigit() and n > per_user.get(int(uid), 0):
            over[uid] = n
    print(json.dumps({"fanout": {"since": since.isoformat(), "users": len(per_user), "rejected_notes": seen,
                                 "over": over, "other_templates": other}}), file=sys.stderr)
    if over or other:
        return f"unexpected claim notes: over={over} other={other[:10]}"
    return None


def _positive(v: str) -> int:
    n = int(v)
    if n < 1:
        raise argparse.ArgumentTypeError("--limit must be >= 1")
    return n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tray", nargs="?")
    ap.add_argument("--tray", dest="tray_opt", help="tray path (the wrapper boundary passes it this way)")
    ap.add_argument("--apply", action="store_true", help="write (default: dry run)")
    ap.add_argument("--limit", type=_positive, default=None, help="only the first N rows (N >= 1)")
    ap.add_argument("--no-fanout-check", action="store_true", help="skip the between-batch send-ledger read")
    ap.add_argument("--decline-plan", action="store_true",
                    help="after each rejected batch, print who tells each user (core's email or hydra's decline); "
                         "reads only, never sends")
    ap.add_argument("--verify-batch", action="store_true",
                    help="(wrapper boundary) re-check one batch: --tray --ruling --run-id --expected --ids")
    ap.add_argument("--ruling")
    ap.add_argument("--run-id")
    ap.add_argument("--expected")
    ap.add_argument("--status", default="rejected", help="(wrapper boundary) the body's target status")
    ap.add_argument("--ids", help="comma-separated request ids")
    ap.add_argument("--claims", action="store_true",
                    help="the tray is a claim-decline tray (action reject_claim; Fable claim-route-zero)")
    a = ap.parse_args()
    if a.tray_opt:
        if a.tray and a.tray != a.tray_opt:
            ap.error("tray given twice with different values")
        a.tray = a.tray_opt
    if a.verify_batch:
        if not all([a.tray, a.ruling, a.run_id, a.expected, a.ids]):
            print("verify-batch: --tray, --ruling, --run-id, --expected and --ids are all required", file=sys.stderr)
            return 3
        why = fx.verify_batch(a.tray, a.ruling, a.run_id, [i for i in a.ids.split(",") if i], a.expected,
                              status=a.status)
        if why:
            print(f"fable_decider boundary: {why}", file=sys.stderr)
            return 3
        return 0
    if not a.tray:
        ap.error("tray is required")
    if a.claims:
        try:
            ctray = cx.load_claim_tray(a.tray)
        except (cx.TrayError, OSError) as exc:
            print(json.dumps({"tray": a.tray, "refused": str(exc)}))
            return 2
        cres = cx.run(ctray, apply=a.apply, limit=a.limit,
                      after_batch=None if (a.no_fanout_check or not a.apply) else claim_fanout_check)
        print(json.dumps({**cres.as_dict(), "tray_sha256": ctray.sha256, "daily_cap": ctray.daily_cap}))
        return 1 if cres.stopped else 0
    try:
        tray = fx.load_tray(a.tray)
    except (fx.TrayError, OSError) as exc:
        print(json.dumps({"tray": a.tray, "refused": str(exc)}))
        return 2
    template = fx.TEMPLATE[tray.action]

    def between(rows: list[tuple[str, int, str | None]], since: datetime) -> str | None:
        surprise = fanout_check(rows, since, template)
        if surprise or tray.action != "reject":
            return surprise
        # a close: core's own credits_rejected email may already be the decline (decline-copy-ruling.md §3.2)
        return decline_plan(rows, since) if a.decline_plan else None

    res = fx.run(tray, apply=a.apply, limit=a.limit,
                 between_batches=None if (a.no_fanout_check or not a.apply) else between)
    print(json.dumps({**res.as_dict(), "tray_sha256": tray.sha256, "daily_cap": tray.daily_cap,
                      "cap_ruling_id": tray.cap_ruling_id}))
    return 1 if res.stopped else 0


if __name__ == "__main__":
    sys.exit(main())
