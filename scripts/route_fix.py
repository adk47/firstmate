#!/usr/bin/env python3
"""route_fix.py — put every churned user's stuck request at the HEAD of the lane that owns it.

Stage 1 of 3 for winsback campaign wb_fix_1 (data/support-churn-winback-fable-c1/report.md,
ruling R2 and R4). It answers one question per churned paying user: *what were they actually
waiting on, and which existing intake owns that fix?* Then it writes one ticket there, tagged
``churned:<date>`` and marked paid priority (R4), and records it in the campaign ledger.

It does NOT: decide a credit, refund anything, message anyone, or invent a queue. Every ticket
lands where its lane's OWNER already reads (scripts/churn/lanes.py): the credit/proof lanes add
the user to the churn priority list that scripts/credit_review/decide.py reads, and every lane a
person works gets a task on the support board. A lane whose intake cannot be reached is reported
as UNROUTED and left for the next run - never recorded against a reference nobody can read.

Ordering is R4: highest list MRR first, longest wait next, so the head of each lane is the
person who has waited longest among those who paid most.

Idempotent by ``sha256(user_id | primary class)``: a second run finds its own tickets and writes
nothing. That is what lets this be a daily cron without a de-duplication conversation every day.

    ./scripts/route_fix.py --dry-run                      # count + preview, write nothing
    ./scripts/route_fix.py                                # route (default)
    ./scripts/route_fix.py --source json                 # rehearse on the measured baseline artifact
    ./scripts/route_fix.py --limit 25 --dry-run           # rehearse on the top of the list
    ./scripts/route_fix.py --lane credit-review --preview 3

Exit codes: 0 routed (or dry run), 1 the store/policy could not be read, 2 a lane intake failed or
was unavailable (the rows already written are kept, and every unrouted ticket stays unrouted, so
the next run resumes where this one stopped).
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from churn import cli, lanes, model, state, tickets  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = cli.add_common(
        argparse.ArgumentParser(description="Route churned users' stuck requests into the owning lanes."),
        source=True,
    )
    ap.add_argument("--dry-run", action="store_true", help="report what would be written; write nothing")
    ap.add_argument("--limit", type=int, default=0, help="route only the top N users (rehearsal)")
    ap.add_argument("--lane", default=None, choices=model.LANES, help="route only this lane")
    ap.add_argument("--preview", type=int, default=0, help="print the first N rendered intake tickets")
    ap.add_argument("--no-clickup", action="store_true",
                    help="skip the support-board lanes (claim/merge/analytics/refund/thread): report them as un-written")
    args = ap.parse_args(argv)

    policy = cli.load_policy(args.policy)
    state_dir = cli.state_dir(policy, args.state_dir)
    window = cli.churn_days(policy, args.churn_days)
    now = time.time()

    try:
        snapshot = state.load(
            source=args.source,
            state=args.state or cli.path_from(policy, "support_state_sqlite"),
            candidates=args.candidates or (
                cli.path_from(policy, "measured_candidates") if args.source == "json" else None),
            churn_days=window,
            as_of=args.as_of,
        )
    except state.StateUnreadable as exc:
        cli.log(f"cannot read the audience: {exc}")
        return 1

    candidates = snapshot.candidates
    if args.limit:
        candidates = candidates[: args.limit]
    buckets = model.in_lane(candidates)
    if args.lane:
        buckets = {k: v for k, v in buckets.items() if k == args.lane}

    clickup = None
    if not args.no_clickup:
        token = lanes.clickup_token()
        if token:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            from lib import clickup_client  # noqa: PLC0415 - optional dependency at runtime

            clickup = clickup_client.shared(token)
        else:
            cli.log("no CLICKUP_API_KEY / MUSOAI_CLICKUP_API_KEY: the support-board lanes (claim, merge, "
                    "analytics, refund, thread answer) will be reported as unrouted and left for the next run "
                    "(they are NOT silently dropped, and they are NOT recorded as routed)")

    db_path = state_dir / "tickets.sqlite"
    # A dry run must not create state: read the real ledger if it exists, else use a scratch one.
    readonly = bool(args.dry_run and db_path.exists())
    store = tickets.TicketStore(str(db_path) if (not args.dry_run or db_path.exists()) else ":memory:",
                                readonly=readonly)
    routed: dict[str, int] = {}
    already: dict[str, int] = {}
    skipped: dict[str, int] = {}
    unrouted: dict[str, int] = {}
    failed: dict[str, str] = {}
    previews: list[str] = []
    try:
        for lane_name, rows in buckets.items():
            for cand in rows:
                row = tickets.draft(cand, lane=lane_name, now=now,
                                    paid_priority_days=int((policy.get("windows") or {}).get("paid_priority_days") or 30),
                                    churn_window_start=snapshot.anchor - float(window) * 86400.0)
                existing = store.get(row["ticket_id"])
                if existing is not None and existing.lane_ref:
                    already[lane_name] = already.get(lane_name, 0) + 1
                    continue
                if args.no_clickup and lane_name in lanes.BOARD_LANES:
                    skipped[lane_name] = skipped.get(lane_name, 0) + 1
                    continue
                payload = lanes.build(row, policy=policy, lane=lane_name)
                if args.preview and len(previews) < args.preview:
                    previews.append(f"--- {lane_name} / user {row['user_id']} ---\n"
                                    + lanes.render_preview(payload, policy=policy))
                try:
                    lane_ref = lanes.write(payload, state_dir=state_dir, policy=policy,
                                           apply=not args.dry_run, client=clickup)
                except lanes.LaneUnavailable as exc:
                    # Nothing was written, so the ticket must stay unrouted: recording a ref here
                    # is how a user ends up "routed" forever and never fixed, never messaged.
                    unrouted[lane_name] = unrouted.get(lane_name, 0) + 1
                    failed.setdefault(lane_name, str(exc))
                    continue
                except Exception as exc:  # noqa: BLE001 - one lane failing must not abort the rest
                    failed[lane_name] = f"{type(exc).__name__}: {exc}"
                    cli.log(f"lane {lane_name} failed for user {row['user_id']}: {failed[lane_name]}")
                    continue
                if not args.dry_run:
                    store.route(row, now=now)
                    if lane_ref:
                        store.set_lane_ref(row["ticket_id"], lane_ref)
                routed[lane_name] = routed.get(lane_name, 0) + 1
    finally:
        store.close()

    doc = {
        "stage": "route",
        "at": now,
        "dry_run": bool(args.dry_run),
        "audience": snapshot.counts(),
        "window_days": window,
        "routed": dict(sorted(routed.items())),
        "already_routed": dict(sorted(already.items())),
        "skipped": dict(sorted(skipped.items())),
        "unrouted": dict(sorted(unrouted.items())),
        "failed": failed,
        "users_seen": len(candidates),
        "policy": str(args.policy or cli.POLICY_DEFAULT),
        "state_dir": str(state_dir),
    }
    if not args.dry_run:
        doc["ledger"] = str(db_path)
        with tickets.TicketStore(db_path) as after:
            doc["ledger_counts"] = tickets.lane_report(after)
        cli.write_report(doc, state=state_dir, name="route")
    cli.emit(doc)
    for text in previews:
        print(text, file=sys.stderr)
    cli.log(f"{'would route' if args.dry_run else 'routed'} {sum(routed.values())} tickets "
            f"across {len(routed)} lanes; {sum(already.values())} already present; "
            f"{sum(unrouted.values())} unrouted, {sum(skipped.values())} skipped")
    return 2 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
