#!/usr/bin/env python3
"""AI credit review: approval auditor + pre-approval reviewer (read-only).

Subcommands:
  audit    Re-check credit requests APPROVED in the last --window-min minutes,
           or since the previous successful run (minus 15 min) if earlier.
           Every big track (catalog pop >= 60, any track artist >= 90, or
           either unknown) gets the model + web check; other approvals are model-checked at
           --sample-rate (catalog evidence runs for all of them). Prints one
           alert line per CONTRADICTED big-track credit and per approver-
           identity problem, else NO_REPLY (cron announce contract).
  review   Review HELD (status=unverified) requests and recommend
           APPROVE-RECOMMENDED / NEEDS-HUMAN / REJECT-RECOMMENDED.
           --phase shadow records only; --phase advise also prints cards.
           Never writes a credit-request status (Phase 2 is not implemented).
  digest   Daily digest of SUSPECT / CONTRADICTED audits (or NO_REPLY).
  metrics  Weekly verdict counts, cost, and lower-bound precision.
  eval     Labelled-set precision run (stillfloo = known bad, trusted-source
           confirmed = known good), per model, full and blind arms.

Read-only on credits: the admin client issues GETs only.
Kill switch: /etc/hydra/credit-review.disabled -> NO_REPLY, nothing runs.
Design: docs/credit-verification/ai-credit-reviewer.md
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import admin as admin_api  # noqa: E402
from credit_review import evaluate  # noqa: E402
from credit_review.evidence import EvidenceBuilder  # noqa: E402
from credit_review.judge import DEFAULT_MIN_BALANCE_USD, Judge, account_balance_usd  # noqa: E402
from credit_review.ledger import Ledger  # noqa: E402
from credit_review.runner import Config, log, render_digest, render_metrics, run_audit, run_review  # noqa: E402

KILL_SWITCH = Path(os.environ.get("CREDIT_REVIEW_KILL_SWITCH", "/etc/hydra/credit-review.disabled"))
# The model + web-search judge is OFF unless this file exists (captain decision
# 2026-10-11: no OpenRouter spend until the account is topped up). Presence of
# the file is the switch, so it is a deliberate node-8 act that no deploy
# overwrites; the low-balance guard below still applies once it is on.
MODEL_ENABLE_FILE = Path(os.environ.get("CREDIT_REVIEW_MODEL_ENABLE_FILE", "/etc/hydra/credit-review-model.enabled"))


def make_judge(args: argparse.Namespace, notes: list[str] | None = None) -> Judge | None:
    """The judge, or None (catalog-only) when the model is off.

    Off when: --no-model; or (for the scheduled audit/review) the enable file
    is absent; or the shared OpenRouter balance is unreadable or below
    --min-balance-usd. The last case also produces a one-line note for Slack,
    because it means the model was meant to run and did not.
    """
    if getattr(args, "no_model", False):
        return None
    if args.cmd in ("audit", "review") and not MODEL_ENABLE_FILE.exists():
        log(f"model judge disabled ({MODEL_ENABLE_FILE} absent): catalog-only run")
        return None
    floor = getattr(args, "min_balance_usd", DEFAULT_MIN_BALANCE_USD)
    balance = account_balance_usd()
    if balance is None or balance < floor:
        shown = "unreadable" if balance is None else f"${balance:.2f}"
        msg = (f"CREDIT-AUDIT NOTE: model checks skipped - shared OpenRouter balance {shown} is below the "
               f"${floor:.0f} floor (a stop against a runaway; auto top-up should refill it); this run is catalog-only.")
        log(msg)
        if notes is not None:
            notes.append(msg)
        return None
    return Judge(args.model, web=not args.no_web, web_engine=args.web_engine)


def cmd_audit(args: argparse.Namespace) -> int:
    cfg = Config(mode="audit", phase="live", sample_rate=args.sample_rate, max_model_calls=args.max_model_calls,
                 budget_usd=args.budget_usd, web=not args.no_web, model=args.model, web_engine=args.web_engine)
    ledger = Ledger(args.ledger)
    notes: list[str] = []
    judge = make_judge(args, notes)
    if notes and ledger.get_state("low_balance_note_day") == datetime.now(timezone.utc).strftime("%Y-%m-%d"):
        notes = []  # once per UTC day is enough
    elif notes:
        ledger.set_state("low_balance_note_day", datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    alerts, stats = run_audit(admin_api.AdminClient(), ledger, judge, cfg,
                              window_min=args.window_min,
                              daily_budget_usd=args.daily_budget_usd)
    log("audit " + stats.line())
    alerts = notes + alerts
    print("\n".join(alerts) if alerts else "NO_REPLY")
    return 0


def cmd_review(args: argparse.Namespace) -> int:
    cfg = Config(mode="review", phase=args.phase, sample_rate=1.0, max_model_calls=args.max_model_calls,
                 budget_usd=args.budget_usd, web=not args.no_web, model=args.model, web_engine=args.web_engine)
    ledger = Ledger(args.ledger)
    cards, stats = run_review(admin_api.AdminClient(), ledger, make_judge(args), cfg,
                              limit=args.limit, sample_approved=args.sample_approved)
    log("review " + stats.line())
    if args.phase == "advise" and cards:
        print("\n".join(cards[:30]))
    else:
        print("NO_REPLY")
    return 0


def cmd_digest(args: argparse.Namespace) -> int:
    print(render_digest(Ledger(args.ledger), hours=args.hours))
    return 0


def cmd_metrics(args: argparse.Namespace) -> int:
    admin = None if args.offline else admin_api.AdminClient()
    print(render_metrics(admin, Ledger(args.ledger), days=args.days))
    return 0


def cmd_eval(args: argparse.Namespace) -> int:
    if not args.no_model:
        bal = account_balance_usd()
        if bal is None or bal < args.min_balance_usd:
            log(f"refusing a model eval: shared OpenRouter balance {bal} is below ${args.min_balance_usd:.0f} (pass --no-model for catalog-only)")
            return 2
    admin = admin_api.AdminClient()
    ledger = Ledger(args.ledger)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.items:
        items = [(r["label"], r["request"]) for r in json.loads(Path(args.items).read_text())]
        bad = [r for l, r in items if l == "known_bad"]
        good = [r for l, r in items if l == "known_good"]
    else:
        bad_src = json.loads(Path(args.bad_requests).read_text()) if args.bad_requests else [
            r for p in range(1, 9)
            for r in admin_api.list_requests(admin, status="approved", limit=500, page=p, profile_ids=[args.bad_profile])]
        bad = evaluate.stratified_bad(bad_src, args.n_bad)
        # Known good: recent approvals from other profiles that the catalog confirms.
        builder = EvidenceBuilder(admin)
        candidates = []
        for page in range(1, args.good_pages + 1):
            candidates += [r for r in admin_api.list_requests(admin, status="approved", limit=200, page=page)
                           if r.get("profileId") != args.bad_profile and r.get("credits")]
        candidates = evaluate.pick(candidates, args.good_scan)

        def confirmed(r):
            try:
                return builder.build(r).all_confirmed
            except admin_api.AdminError:
                return False

        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=8) as pool:
            flags = list(pool.map(confirmed, candidates))
        good = [r for r, ok in zip(candidates, flags) if ok][:args.n_good]
        log(f"known_good: {len(good)} confirmed of {len(candidates)} scanned approvals")
        items = [("known_bad", r) for r in bad] + [("known_good", r) for r in good]
        evaluate.dump(str(out / "labelled-items.json"), [{"label": l, "request": r} for l, r in items])
    evaluate.dump(str(out / "labelled-set.json"), [{"label": l, "id": r.get("id"), "profileId": r.get("profileId"),
                                                     "title": r.get("spotifyTrackTitle"), "pop": r.get("spotifyPopularity"),
                                                     "credits": r.get("credits")} for l, r in items])
    log(f"labelled set: {len(bad)} known_bad, {len(good)} known_good")
    metrics = []
    for model in args.models.split(","):
        for arm in args.arms.split(","):
            res = evaluate.run_arm(admin, ledger, items, model.strip(), arm.strip(), args.mode,
                                   web=not args.no_web, web_engine=args.web_engine, budget_usd=args.budget_usd,
                                   use_model=not args.no_model)
            m = res.metrics()
            metrics.append(m)
            evaluate.dump(str(out / f"eval-{args.mode}-{model.strip().replace('/', '_').replace(':', '_')}-{arm.strip()}.json"),
                          {"metrics": m, "rows": res.rows})
            log(json.dumps(m))
    tag = args.models.replace("/", "_").replace(",", "+").replace(":", "_")
    evaluate.dump(str(out / f"eval-{args.mode}-{tag}-summary.json"), metrics)
    (out / f"eval-{args.mode}-{tag}-summary.md").write_text(evaluate.to_markdown(metrics) + "\n")
    print(evaluate.to_markdown(metrics))
    return 0


def cmd_rescore(args: argparse.Namespace) -> int:
    metrics = []
    for path in args.ledgers:
        for arm, res in evaluate.rescore(path, args.mode).items():
            metrics.append(res.metrics())
    if args.out:
        evaluate.dump(args.out, metrics)
    print(evaluate.to_markdown(metrics))
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ledger", default=None, help="SQLite ledger path (default /var/lib/hydra/credit-review/ledger.sqlite3)")
    sub = p.add_subparsers(dest="cmd", required=True)

    def model_flags(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--model", default=None, help="OpenRouter model id (default $CREDIT_REVIEW_MODEL or x-ai/grok-4.3)")
        sp.add_argument("--no-web", action="store_true", help="disable the web-search plugin")
        sp.add_argument("--web-engine", default=None, help="OpenRouter web engine (native|exa); default provider choice")
        sp.add_argument("--max-model-calls", type=int, default=300)
        sp.add_argument("--budget-usd", type=float, default=3.0, help="per-run model spend cap")
        sp.add_argument("--no-model", action="store_true", help="catalog evidence only")
        sp.add_argument("--min-balance-usd", type=float, default=DEFAULT_MIN_BALANCE_USD,
                        help="skip model calls when the shared OpenRouter balance is below this")

    a = sub.add_parser("audit")
    a.add_argument("--window-min", type=int, default=90)
    a.add_argument("--sample-rate", type=float, default=0.10)
    a.add_argument("--daily-budget-usd", type=float, default=8.0, help="model spend cap per UTC day across runs")
    model_flags(a)
    a.set_defaults(fn=cmd_audit)

    r = sub.add_parser("review")
    r.add_argument("--phase", choices=["shadow", "advise"], default="shadow")
    r.add_argument("--limit", type=int, default=50)
    r.add_argument("--sample-approved", type=int, default=10)
    model_flags(r)
    r.set_defaults(fn=cmd_review)

    d = sub.add_parser("digest")
    d.add_argument("--hours", type=int, default=24)
    d.set_defaults(fn=cmd_digest)

    m = sub.add_parser("metrics")
    m.add_argument("--days", type=int, default=7)
    m.add_argument("--offline", action="store_true")
    m.set_defaults(fn=cmd_metrics)

    e = sub.add_parser("eval")
    e.add_argument("--mode", choices=["audit", "review"], default="audit")
    e.add_argument("--bad-profile", default="94ad2ad2-0be9-4b8e-94a6-dc85eb100310")
    e.add_argument("--bad-requests", default=None, help="JSON snapshot of the bad profile's requests")
    e.add_argument("--items", default=None, help="reuse a labelled-items.json from a previous eval")
    e.add_argument("--n-bad", type=int, default=60)
    e.add_argument("--n-good", type=int, default=60)
    e.add_argument("--good-pages", type=int, default=5)
    e.add_argument("--good-scan", type=int, default=400, help="approved requests sampled to find trusted-confirmed ones")
    e.add_argument("--models", default="openai/gpt-6-luna")
    e.add_argument("--arms", default="full,blind")
    e.add_argument("--out", required=True)
    model_flags(e)
    e.set_defaults(fn=cmd_eval)

    rs = sub.add_parser("rescore", help="re-apply the current policy to stored eval ledgers (no API or model calls)")
    rs.add_argument("ledgers", nargs="+")
    rs.add_argument("--mode", choices=["audit", "review"], default="audit")
    rs.add_argument("--out", default=None)
    rs.set_defaults(fn=cmd_rescore)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.cmd in ("audit", "review", "digest", "metrics") and KILL_SWITCH.exists():
        log(f"kill switch present at {KILL_SWITCH}; nothing reviewed")
        print("NO_REPLY")
        return 0
    try:
        return args.fn(args)
    except admin_api.AdminError as exc:
        log(f"admin API unavailable: {exc}")
        print(f"Credit review could not run: the admin API is unavailable ({str(exc)[:200]}). No credits were changed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
