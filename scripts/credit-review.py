#!/usr/bin/env python3
"""AI credit review: approval auditor + pre-approval reviewer (read-only).

Subcommands:
  audit    Re-check credit requests APPROVED in the last --window-min minutes,
           or since the previous successful run (minus 15 min) if earlier.
           Every big track (catalog pop >= 60, any track artist >= 90, or
           either unknown) gets the model + web check; other approvals are model-checked at
           --sample-rate (catalog evidence runs for all of them). Prints one
           alert line per CONTRADICTED big-track credit, per approver-
           identity problem and per profile burst, else NO_REPLY (cron
           announce contract; logs go to $CREDIT_REVIEW_LOG, never stderr).
  review   Review HELD (status=unverified) requests and recommend
           APPROVE-RECOMMENDED / NEEDS-HUMAN / REJECT-RECOMMENDED.
           --phase shadow records only; --phase advise also prints cards.
           Never writes a credit-request status (Phase 2 is not implemented).
  digest   Daily digest of SUSPECT / CONTRADICTED audits (or NO_REPLY).
  metrics  Weekly verdict counts, cost, and lower-bound precision.
  eval     Labelled-set precision run (stillfloo = known bad, trusted-source
           confirmed = known good), per model, full and blind arms.

  decide   credit-trust-decide (trust-yet-verify, captain 2026-10-15 ~22:12Z):
           decide the HELD queue - provisional approval on catalog / footprint /
           verified-web evidence for non-big rows without a validator conflict,
           a support request (user_verification_needed) for the rest. --mode
           shadow records only; --mode apply writes, and only when
           policies/credit-approval-automation.json approves credit-trust-decide.
           Exit code = run status (command-shaped cron).
  explain <request-id>        every decision + server outcome for one row.
  export-decisions --since T  JSON lines for the board / digest.
  revert --run <id> [--apply] take a run's provisional approvals back.

Read-only on credits EXCEPT `decide --mode apply` and `revert --apply`, which
write only through muso-admin-api.sh's conditional endpoint.
Kill switch: /etc/hydra/credit-review.disabled -> NO_REPLY, nothing runs.
Design: docs/credit-verification/ai-credit-reviewer.md
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
import os
import sys
import warnings
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import admin as admin_api  # noqa: E402
from credit_review import evaluate  # noqa: E402
from credit_review.evidence import EvidenceBuilder, parse_ts  # noqa: E402
from credit_review.judge import DEFAULT_MIN_BALANCE_USD, Judge, account_balance_usd  # noqa: E402
from credit_review.ledger import Ledger  # noqa: E402
from credit_review.runner import (  # noqa: E402
    LOG_PATH, Config, log, profile_burst_alerts, render_digest, render_metrics, run_audit, run_review)

KILL_SWITCH = Path(os.environ.get("CREDIT_REVIEW_KILL_SWITCH", "/etc/hydra/credit-review.disabled"))
# The model + web-search judge is OFF unless this file exists (captain decision
# 2026-10-11: no OpenRouter spend until the account is topped up). Presence of
# the file is the switch, so it is a deliberate node-8 act that no deploy
# overwrites; the low-balance guard below still applies once it is on.
MODEL_ENABLE_FILE = Path(os.environ.get("CREDIT_REVIEW_MODEL_ENABLE_FILE", "/etc/hydra/credit-review-model.enabled"))


_SEARCHER = None


def codex_judge(args: argparse.Namespace, model: str | None = None, fallback=None):
    """credit-trust T01: the server fetches free sources (MusicBrainz,
    Wikipedia, ...) and Codex judges them tool-less on the subscription ($0).
    Every call is a row in the credit-trust llm_calls ledger. One Searcher per
    process, so an eval's two arms fetch each track once."""
    global _SEARCHER
    from credit_trust.credibility import FetchedSourcesJudge
    from credit_trust.ledger import Ledger as TrustLedger
    from credit_trust.llm import Provider
    from credit_trust.websearch import Searcher
    if _SEARCHER is None:
        _SEARCHER = Searcher(max_docs=4)
    ledger = TrustLedger(args.trust_ledger)
    provider = Provider(ledger, ladder=("codex",), codex_model=model)
    decide = args.cmd == "decide"
    return FetchedSourcesJudge(provider, _SEARCHER, fallback=fallback, step=f"credit_review_{args.cmd}",
                               skip_model_without_sources=decide,
                               combiner=Provider(ledger, ladder=("jev",)) if decide else None)


def make_judge(args: argparse.Namespace, notes: list[str] | None = None) -> Judge | None:
    """The judge, or None (catalog-only) when the model is off.

    Off when: --no-model; or (for the scheduled audit/review) the enable file
    is absent; or the shared OpenRouter balance is unreadable or below
    --min-balance-usd. The last case also produces a one-line note for Slack,
    because it means the model was meant to run and did not.
    """
    if getattr(args, "no_model", False):
        return None
    if getattr(args, "provider", "openrouter") == "codex":
        # $0 first: Codex on fetched sources; the OpenRouter judge (with every
        # guard below) is only the fallback when nothing could be fetched or
        # Codex is unavailable.
        args_or = argparse.Namespace(**{**vars(args), "provider": "openrouter"})
        return codex_judge(args, fallback=make_judge(args_or, notes))
    if args.cmd in ("audit", "review", "decide") and not MODEL_ENABLE_FILE.exists():
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
    recorded_to = parse_ts(ledger.get_state("audit_last_run"))
    alerts = notes + alerts + (profile_burst_alerts(ledger, now=recorded_to) if recorded_to else [])
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
    codex = args.provider == "codex"
    if not args.no_model and not codex:
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
                                   use_model=not args.no_model, batch=args.batch,
                                   # the eval measures Codex alone: no OpenRouter fallback
                                   judge_factory=(lambda m: codex_judge(args, m)) if codex else None)
            m = res.metrics()
            m["batch"] = bool(args.batch)
            metrics.append(m)
            evaluate.dump(str(out / f"eval-{args.mode}-{model.strip().replace('/', '_').replace(':', '_')}-{arm.strip()}"
                              f"{'-batch' if args.batch else ''}.json"),
                          {"metrics": m, "rows": res.rows})
            log(json.dumps(m))
    tag = args.models.replace("/", "_").replace(",", "+").replace(":", "_")
    tag += "-batch" if args.batch else ""
    evaluate.dump(str(out / f"eval-{args.mode}-{tag}-summary.json"), metrics)
    (out / f"eval-{args.mode}-{tag}-summary.md").write_text(evaluate.to_markdown(metrics) + "\n")
    print(evaluate.to_markdown(metrics))
    return 0


def cmd_decide(args: argparse.Namespace) -> int:
    from credit_review import decide
    if decide.KILL_SWITCH.exists():
        log(f"decide: kill switch present at {decide.KILL_SWITCH}; nothing decided")
        print("NO_REPLY")
        return 0
    if args.provider != "codex":
        log("decide: refused --provider openrouter (the metered judge runs only as the capped --paid-fallback)")
        print("credit-trust-decide refused: --provider openrouter is not allowed; decide runs Codex, and the "
              "metered OpenRouter judge only as the capped --paid-fallback. No credits were changed.")
        return 2
    os.environ["MUSO_ADMIN_IDENTITY"] = decide.ADMIN_IDENTITY
    policy = decide.Policy.load()
    if args.max_rows:
        policy.max_rows_per_run = args.max_rows
    ledger = Ledger(args.ledger)
    judge = make_judge(args)
    fb = getattr(judge, "fallback", None)
    if fb is not None and not args.paid_fallback:
        # $0 by default (measured 2026-10-15 on 60 held rows: free sources covered none,
        # the grok fallback cost $1.86 for ONE approval; 55 rows got the same support
        # request they get without it).
        judge.fallback = fb = None
    if fb is not None:
        # The paid fallback is capped per run and by the shared $25/day verifier budget.
        day = datetime.now(timezone.utc).strftime("%Y-%m-%dT00:00:00Z")
        judge.fallback = decide.CappedJudge(fb, run_cap_usd=args.budget_usd, daily_cap_usd=args.daily_budget_usd,
                                            spent_today_usd=decide.spent_today_usd(ledger.db, day))
    res = decide.run(admin_api.AdminClient(), ledger.db, judge, mode=args.mode, policy=policy,
                     max_model_calls=args.max_model_calls, workers=args.workers, budget_s=args.budget_s)
    log("decide " + res.line())
    if res.write_errors:
        print(res.line())
        return 1
    if res.scanned == 0:
        print("NO_REPLY")
        return 0
    decided = res.approved + res.support + sum(res.skipped_by_server.values())
    if res.mode == "apply" and decided == 0 and res.deferred == res.scanned and res.errors:
        # zero processed while work existed = a failed run, not a quiet one
        print(res.line())
        return 1
    print(res.line() if (res.approved or res.support or res.note) else "NO_REPLY")
    return 0


def cmd_explain(args: argparse.Namespace) -> int:
    from credit_review import decide
    print(json.dumps(decide.explain(Ledger(args.ledger).db, args.request_id), indent=1, ensure_ascii=False, default=str))
    return 0


def cmd_export_decisions(args: argparse.Namespace) -> int:
    from credit_review import decide
    for row in decide.export(Ledger(args.ledger).db, args.since):
        print(json.dumps(row, ensure_ascii=False, default=str))
    return 0


def cmd_revert(args: argparse.Namespace) -> int:
    from credit_review import decide
    os.environ["MUSO_ADMIN_IDENTITY"] = decide.ADMIN_IDENTITY
    out = decide.revert(Ledger(args.ledger).db, args.run, apply=args.apply)
    print(json.dumps(out, indent=1, default=str))
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
        sp.add_argument("--provider", choices=["openrouter", "codex"], default="openrouter",
                        help="codex = server-fetched sources judged by tool-less Codex on the subscription "
                             "($0; credit-trust T01); openrouter = the web-plugin judge")
        sp.add_argument("--trust-ledger", default=None,
                        help="credit-trust llm_calls ledger (default /var/lib/hydra/credit-trust/ledger.sqlite3)")

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
    e.add_argument("--batch", action="store_true",
                   help="judge the way the crons do: one model call per profile unit (judge_grouped)")
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

    dc = sub.add_parser("decide", help="trust-yet-verify decisions on the held queue (credit-trust-decide)")
    dc.add_argument("--mode", choices=["shadow", "apply"], default="shadow")
    dc.add_argument("--max-rows", type=int, default=None, help="held rows per run (default: policy, 500)")
    dc.add_argument("--workers", type=int, default=6)
    dc.add_argument("--budget-s", type=int, default=720, help="stop building evidence after this many seconds")
    dc.add_argument("--paid-fallback", action="store_true",
                    help="let rows no free source covers fall back to the OpenRouter web judge (metered, capped)")
    dc.add_argument("--daily-budget-usd", type=float, default=25.0,
                    help="shared per-UTC-day cap on metered model spend (audit + decide; captain: $25/day)")
    model_flags(dc)
    dc.set_defaults(fn=cmd_decide, provider="codex", max_model_calls=120, budget_usd=2.0)

    ex = sub.add_parser("explain", help="every decision + server outcome for one credit request")
    ex.add_argument("request_id")
    ex.set_defaults(fn=cmd_explain)

    xd = sub.add_parser("export-decisions", help="decisions as JSON lines (board / digest)")
    xd.add_argument("--since", required=True, help="ISO time, e.g. 2026-10-15T00:00:00Z")
    xd.set_defaults(fn=cmd_export_decisions)

    rv = sub.add_parser("revert", help="take a decide run's provisional approvals back (named human path)")
    rv.add_argument("--run", required=True)
    rv.add_argument("--apply", action="store_true", help="attempt the write (the server allows a named human only)")
    rv.set_defaults(fn=cmd_revert)

    rs = sub.add_parser("rescore", help="re-apply the current policy to stored eval ledgers (no API or model calls)")
    rs.add_argument("ledgers", nargs="+")
    rs.add_argument("--mode", choices=["audit", "review"], default="audit")
    rs.add_argument("--out", default=None)
    rs.set_defaults(fn=cmd_rescore)
    return p


def _warning_to_log(message, category, filename, lineno, file=None, line=None) -> None:
    log(f"warning: {category.__name__}: {message} ({filename}:{lineno})")


def main(argv: list[str] | None = None) -> int:
    # Python warnings go to the run log, never to stderr: openclaw posts a command
    # cron's stderr to Slack next to its stdout.
    warnings.showwarning = _warning_to_log
    args = parser().parse_args(argv)
    if args.cmd in ("audit", "review", "digest", "metrics", "decide") and KILL_SWITCH.exists():
        log(f"kill switch present at {KILL_SWITCH}; nothing reviewed")
        print("NO_REPLY")
        return 0
    try:
        return args.fn(args)
    except admin_api.AdminError as exc:
        kept = log(f"admin API unavailable: {exc}")
        print(f"Credit review could not run: the admin API is unavailable. No credits were changed. "
              f"{_details(kept)}")
        return 1
    except Exception as exc:  # noqa: BLE001 - a crash is one plain line in Slack, the traceback goes to the log
        import traceback
        kept = log("crash: " + "".join(traceback.format_exception(exc)))
        print(f"Credit review {args.cmd} failed with an internal error ({type(exc).__name__}). "
              f"No credits were changed. {_details(kept)}")
        return 1


def _details(kept: bool) -> str:
    if kept:
        return f"Details: {LOG_PATH} on node-8."
    return f"The run log {LOG_PATH} on node-8 could not be written, so no details were kept."


if __name__ == "__main__":
    sys.exit(main())
