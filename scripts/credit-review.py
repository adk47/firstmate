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
  verify-notify
           Trust yet verify (captain 2026-10-15 22:12Z): after `decide`
           approves provisional rows, tell each user which credits were added
           and ask for supporting documents, one Intercom note per user per
           day via scripts/intercom-verify-request.sh (the only sender), then
           tag proof replies `credit-proof`. Re-reads every row first and
           announces only rows the server says are approved now. Never writes
           a credit-request status. --removal-due FILE writes the NEW credits
           whose note's reply-by date has passed with no valid document (the
           removal step's input; nothing is removed here), and FILE.held the
           ones held for a human (awaiting review, replied). Kill switch:
           /etc/hydra/credit-verify-notify.disabled.
  verify-wave
           Past-credit documentation waves (captain 2026-10-15 23:35Z, narrowed
           2026-10-16 00:35Z): the agent-batch approvals (09-01 -> 10-11) get one
           friendly note per user listing their credits (paid users first, big
           tracks first), no deadline, no removal, no follow-up, never to a
           user who already sent proof.
           Same gate (--campaign retro-past, send-locked until its copy is
           approved). --unverified FILE writes the past credits with no
           documents 30+ days after the ask (they stay; flagged for the board).
  uvn-status
           Ops takeover section 2 class 2 (firstmate 060): one status + reminder
           message per user to requesters whose credit requests wait on them
           (user_verification_needed), from credit-trust-llm-t01's list, through
           the gate's uvn-status campaign. Re-checks proof-on-file, the replica
           (still waiting), Intercom (documents / messaged in 7 days) and the
           ledger before each send. --segment paid|free, --max-users (canary 3),
           at most 400 per UTC day. Kill switch:
           /etc/hydra/credit-ops-notes.disabled (not verify-notify's). Goes
           in the user's most recent open conversation (14 days) if any, else email.
           --campaign status-doc-received|status-team-review sends the no-ask
           status notes instead (rules: verify-request-notes.md).
           --from-stage2 builds the population from the stage-2 verdicts
           (Fable 2026-10-26 13:23Z): uvn-status reaches no_document users,
           --campaign gap-ask sends Fable's gap paragraph to need_more users.
  intercom-reconcile
           Fable ruling-intercom-external-id-1026 Ruling A: for users the gate refused on
           identity (external_id mismatch / empty / several contacts) classify the Intercom
           contact A1-A5 and, for A1/A2/A4 rows meeting every write condition, set its
           external_id to the account's professional id (ledger row with the old id first;
           --revert <run_id>; 50 writes on the first run). Dry run by default; apply needs
           --approved <dry-run json>. Never messages anyone. Kill switch:
           /etc/hydra/intercom-identity-reconcile.disabled.
  fraud-lens
           Fable Ruling B: build the paid never-contacted population and split it into
           fraud-held / ask-only (uvn-status only) / clean, before the census lists (read-only).
  withdrawal-confirm
           Firstmate 061: confirm requester-withdrawn credit requests through the
           gate's withdrawal-confirm campaign. --request-ids id[:conversation],...
           (with a conversation: in that thread; without: email). Kill switch:
           /etc/hydra/credit-ops-notes.disabled.
  email-changed
           Firstmate 073: the threaded "sign-in email updated" reply in the
           ticket's own conversation, once per ticket, through the same gate.
           Kill switch: /etc/hydra/credit-ops-notes.disabled.
  removal-notice
           Tell owners of credits WE removed (non-self; fraud removals are
           silent by captain order) which credit and role, why, and how to
           dispute, one batched note per owner, through the same gate
           (--campaign removal-notice, send-locked until Fable's GO). Reads a
           removal-events JSON-lines file (the ongoing feed or the one-time
           backfill); --list FILE writes the owner list for firstmate's
           approval before anything is sent.
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
write only through muso-admin-api.sh's conditional endpoint (verify-notify
sends user notes through its gate script; it changes no credit).
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
from credit_review import fraud_lens  # noqa: E402
from credit_review import intercom_reconcile  # noqa: E402
from credit_review import verify_ledger  # noqa: E402
from credit_review import uvn_status  # noqa: E402
from credit_review import withdrawal_confirm  # noqa: E402
from credit_review import claim_proof_ask  # noqa: E402
from credit_review import verify_notify  # noqa: E402
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
VERIFY_NOTIFY_KILL_SWITCH = Path(os.environ.get("CREDIT_VERIFY_NOTIFY_KILL_SWITCH",
                                                "/etc/hydra/credit-verify-notify.disabled"))
# uvn-status (and the status notes), withdrawal-confirm and email-changed have their own switch
# (firstmate 117): verify-live's switch never stops them, and this one never stops verify-live.
CREDIT_OPS_NOTES_KILL_SWITCH = Path(os.environ.get("CREDIT_OPS_NOTES_KILL_SWITCH",
                                                   "/etc/hydra/credit-ops-notes.disabled"))
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
    if args.cmd in ("audit", "review") and not MODEL_ENABLE_FILE.exists():
        # The operator's switch for the scheduled read-only judges covers EVERY
        # provider: with the file absent the audit and shadow review are
        # catalog-only, Codex included (QA on hydra#1279). decide keeps its own
        # Codex path; its OpenRouter fallback is still gated below.
        log(f"model judge disabled ({MODEL_ENABLE_FILE} absent): catalog-only run")
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
    # Fable [key=switch-on-plan] item 3: the WRITER kill file stops shadow and apply; --mode judge (decider rows only:
    # no core write, no ask, no notify) is stopped by its OWN kill file, so judging can run while the writer stays off.
    if args.mode == "judge":
        if decide.JUDGE_KILL_SWITCH.exists():
            log(f"decide: judge kill switch present at {decide.JUDGE_KILL_SWITCH}; nothing judged")
            print("NO_REPLY")
            return 0
        if decide.KILL_SWITCH.exists():
            log(f"decide: writer kill switch {decide.KILL_SWITCH} present; running JUDGE-ONLY (decider rows only)")
    elif decide.KILL_SWITCH.exists():
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
    prod_ledger = "/var/lib/hydra/credit-review/ledger.sqlite3"
    if res.mode == "apply" and os.path.realpath(args.ledger or prod_ledger) == prod_ledger:
        # Best effort: ask for a full org-affiliation check of the next verify-notify
        # recipients (firstmate 054). Production ledger only (a test run on node-8 must
        # never overwrite the live input). A failure never fails the decider run.
        try:
            from credit_review import verify_ledger, verify_notify
            vdb = verify_ledger.connect(prod_ledger)
            try:
                path, n = verify_notify.write_affiliation_priority(vdb)
            finally:
                vdb.close()
            log(f"decide: org-affiliation priority list {path}: {n} user(s)")
        except Exception as exc:  # noqa: BLE001 - never fail the decider for this
            log(f"decide: org-affiliation priority list not written: {exc}"[:300])
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


def cmd_provisional_review(args: argparse.Namespace) -> int:
    """Fable ruling 4 as amended (firstmate 073): no day-30 auto-removal; unconfirmed paid
    provisional approvals are listed for Ops (JSON lines), still live. Never writes."""
    from credit_review import decide
    proof, why = decide.proof_on_file()
    if why:
        log(f"provisional-review: proof-on-file unknown ({why}); every eligible row is listed")
    for row in decide.provisional_review(Ledger(args.ledger).db, proof, days=args.days):
        print(json.dumps(row, ensure_ascii=False, default=str))
    return 0


def cmd_provisional_tracker(args: argparse.Namespace) -> int:
    """Daily: every provisional credit's backup clock (7 days from the delivered ask), due/overdue,
    the day-N route, and the backup_ask_undelivered watchdog (credit_review/provisional_tracker.py;
    captain 2026-10-23 20:03Z/20:04Z/20:07Z, Fable backup-threshold-ruling-1023.md). Read-only."""
    import sqlite3 as _sq
    from credit_review import decide, provisional_tracker as pt
    from credit_review import ledger as _ledger
    db = _sq.connect(f"file:{args.ledger or _ledger.DEFAULT_PATH}?mode=ro", uri=True)
    paying, _ = decide.paying_users(now=datetime.now(timezone.utc))
    t = pt.run(ledger=db, proof_path=args.proof_on_file, paying=set(paying or ()), window_days=args.window_days)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump({"at": t.at, "window_days": t.window_days, "counts": t.counts(), "error": t.error,
                       "findings": t.findings(), "rows": t.rows}, fh, indent=1, default=str)
    lines = t.findings()
    if args.post_board and not t.error:
        tok = pt.board_token()
        if not tok:
            lines.append(f"board not updated: no INGEST_TOKEN in {pt.BOARD_ENV}")
        else:
            ok, why = pt.post_board(pt.board_payload(t, datetime.now(timezone.utc)), tok,
                                    gate_token=pt.board_token(key="CREDIT_TRUST_BOARD_AGENT_TOKEN"))
            if not ok:
                lines.append(f"board not updated: ingest answered {why}")
    log("provisional-tracker " + json.dumps({"counts": t.counts(), "error": t.error}))
    print("\n".join(lines) if lines else "NO_REPLY")
    return 1 if (t.error or t.undelivered()) else 0


def cmd_score_approve(args: argparse.Namespace) -> int:
    """Captain 2026-10-20 ~11:30Z "approve low risk credits": execute the validator's own
    approve verdict (total risk < 30) on held user_verification_needed rows, every guard intact
    (credit_review/score_approve.py)."""
    from credit_review import decide, score_approve
    if args.pause or args.resume:
        if args.pause:
            score_approve.PAUSE_FILE.parent.mkdir(parents=True, exist_ok=True)
            score_approve.PAUSE_FILE.write_text(f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} {args.pause}\n")
            log(f"score-approve PAUSED: {args.pause}")
            print(f"score-approve paused: {args.pause}. Every run is shadow until --resume.")
        else:
            score_approve.PAUSE_FILE.unlink(missing_ok=True)
            log("score-approve resumed")
            print("score-approve resumed.")
        return 0
    if score_approve.KILL_SWITCH.exists() or decide.KILL_SWITCH.exists():
        log("score-approve: kill switch present; nothing decided")
        print("NO_REPLY")
        return 0
    os.environ["MUSO_ADMIN_IDENTITY"] = decide.ADMIN_IDENTITY
    policy = decide.Policy.load()
    sp = score_approve.ScorePolicy.load()
    if args.max_per_run is not None:
        sp.max_per_run = min(sp.max_per_run, args.max_per_run)
    ledger = Ledger(args.ledger)
    res = score_approve.run(admin_api.AdminClient(), ledger.db, mode=args.mode, policy=policy, sp=sp)
    log(res.line())
    # QA @6c2a51b4 (2): reads cut short by core's rate limit are a failure, never a quiet no-op.
    if res.mode == "apply" and not (res.approved or res.write_errors or res.skipped_by_server
                                    or res.read_exhausted or res.paused_mid_run or res.audit_failed):
        print("NO_REPLY")
    else:
        print(res.line())
    return 1 if (res.write_errors or res.read_exhausted or res.audit_failed) else 0


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


def _export(path: str, rows: list[dict]) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def cmd_verify_notify(args: argparse.Namespace) -> int:
    if args.proof_review:
        ids = [x.strip() for x in (args.request_ids or "").split(",") if x.strip()]
        if not args.outcome or not args.reviewer or not ids:
            print("--proof-review needs --request-ids r1,r2 (the credits this verdict covers), --outcome "
                  "accepted|rejected and --reviewer <who reviewed the document>.")
            return 2
        db = verify_ledger.connect(args.ledger or verify_ledger.DEFAULT_PATH)
        try:
            res = verify_ledger.record_proof_review(db, message_id=args.proof_review, request_ids=ids,
                                                    outcome=args.outcome, reviewer=args.reviewer,
                                                    reason=args.reason or "")
        except ValueError as exc:
            print(f"--proof-review refused: {exc}. Nothing was recorded.")
            return 2
        finally:
            db.close()
        print(json.dumps(res))
        return 0 if res.get("result") == "ok" else 1
    if args.removal_due:
        try:
            documented = verify_notify.load_proof_on_file(args.proof_on_file)
        except verify_notify.ProofFileError as exc:
            log(f"verify-notify --removal-due halted: {exc}")
            print(f"Removal-due export halted: {exc}. Nothing was exported (when in doubt, nothing is removal-due).")
            return 1
        db = verify_ledger.connect(args.ledger or verify_ledger.DEFAULT_PATH)
        try:
            rows, held = verify_notify.removal_due(db, admin_api.AdminClient(), documented, day=_today())
        finally:
            db.close()
        held_path = args.removal_due + ".held"
        _export(args.removal_due, rows)
        _export(held_path, held)
        print(f"{len(rows)} new credit(s) past the reply-by date their note named, with no valid document, no document "
              f"on file and no human approval, written to {args.removal_due}. {len(held)} more held for a human (document "
              f"awaiting review, a user reply, or a rejection not yet explained to the user), written to {held_path} (never removed by this export). Nothing was "
              "removed; the removal step re-checks each one.")
        return 0
    if args.check_recipients and args.mode != "dry-run":
        print("--check-recipients is for --mode dry-run only.")
        return 2
    # The kill switch stops SENDS. A dry run sends nothing and writes nothing, so it still runs
    # under the switch (QA @052f737: the pre-enable --check-recipients dry run must not
    # silently check zero recipients while the switch is set).
    if VERIFY_NOTIFY_KILL_SWITCH.exists() and args.mode == "apply":
        log(f"verify-notify kill switch present at {VERIFY_NOTIFY_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    if VERIFY_NOTIFY_KILL_SWITCH.exists():
        log(f"verify-notify kill switch present at {VERIFY_NOTIFY_KILL_SWITCH}; dry run only (read only)")
    try:
        report = verify_notify.run(admin_api.AdminClient(), ledger_path=args.ledger, mode=args.mode,
                                   run_id=args.run, since_hours=args.since_hours, max_users=args.max_users,
                                   proof_path=args.proof_on_file, sweep=not args.no_proof_sweep,
                                   check_recipients=args.check_recipients)
    except verify_notify.ContractError as exc:
        log(f"verify-notify contract error: {exc}")
        print(f"Verify notes could not run: {exc}. Nothing was sent.")
        return 2
    log("verify-notify " + json.dumps({k: v for k, v in vars(report).items() if not isinstance(v, list)}))
    print(report.render(args.mode))
    return 1 if report.failed else 0


def write_outcomes(args: argparse.Namespace, report: object) -> str:
    """C11: --outcomes-json PATH - every per-user gate answer that was not a send ({user, result, reason}), the gate's
    ACCEPTED set ({user, campaign, request_ids, gate}) and the pre-gate drops, so a dry run and the send can be compared
    user by user. Written 0600; ids and gate reasons only (no message text)."""
    path = getattr(args, "outcomes_json", None)
    if not path:
        return ""
    # QA #1515 / b1: a NEW 0600 temp file in the same directory, then an atomic replace - never an old file's mode,
    # never a half-written file. A write failure is reported and returned, never raised past the send summary.
    import tempfile  # noqa: PLC0415
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(prefix=".outcomes-", dir=os.path.dirname(os.path.abspath(path)))
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            # h2 10-31 / 11-01 01:0xZ: the gate's ACCEPTED set rides with the non-sends (the signers' would-send set is the
            # runner's accepted list, never list - outcomes), plus the pre-gate drops - one file accounts for every user
            json.dump({"mode": args.mode, "segment": args.segment, "outcomes": list(getattr(report, "outcomes", [])),
                       "accepted": list(getattr(report, "accepted", [])), "filtered": list(getattr(report, "filtered", [])),
                       "sent": list(getattr(report, "sent", [])),
                       "recipient_ok": getattr(report, "recipient_ok", 0),
                       "page": getattr(report, "page", None) or None,     # QA #1612: the entries walked
                       # p1 579: every tick artefact names the deploy head it ran on and the head its list was signed on
                       "deployed": verify_notify.deployed_head() or None,
                       "signed_on": verify_notify.LIST_SIGNED_ON or None,
                       "max_users": getattr(args, "max_users", None)}, fh, indent=1)    # the attempt cap of this run
        os.replace(tmp, path)
        return ""
    except OSError as exc:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return f"the outcomes file {path} could not be written ({exc}); the run above is complete"


def preflight_outcomes(args: argparse.Namespace) -> str:
    """Before ANY send: the --outcomes-json directory must exist and be writable (a probe temp file), so a send is never
    followed by a lost comparison file. '' when fine (or no path)."""
    path = getattr(args, "outcomes_json", None)
    if not path:
        return ""
    import tempfile  # noqa: PLC0415
    if os.path.isdir(path):                  # QA #1515: the replace would fail on a directory, after the sends
        return f"--outcomes-json {path} is a directory; nothing was sent"
    try:
        with tempfile.NamedTemporaryFile(prefix=".outcomes-probe-", dir=os.path.dirname(os.path.abspath(path))):
            pass
    except OSError as exc:
        return f"--outcomes-json {path} is not writable ({exc}); nothing was sent"
    return ""


def cmd_uvn_status(args: argparse.Namespace) -> int:
    # r5 (10-31 05:19Z, h2 06Z deadlock): the kill stops SENDS. --mode apply refuses under it; a dry run / preview /
    # --check-recipients still runs - strictly read-only (the gate writes nothing on --dry-run / --check-recipient, and
    # the runner writes nothing outside apply) - so the dry run a lift is conditional on can be produced and signed
    killed = CREDIT_OPS_NOTES_KILL_SWITCH.exists()
    if killed and args.mode == "apply":
        log(f"credit-ops-notes kill switch present at {CREDIT_OPS_NOTES_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    if killed:
        # QA #1564: read-only for REAL - a missing or pre-migration ledger refuses (connect() would create or ALTER it);
        # a current one is only ever read here (the row-count tests fail on any write), and the gate reads it mode=ro
        src = args.ledger or verify_ledger.DEFAULT_PATH
        try:
            verify_ledger.connect_ro(src, must_exist=True).close()
        except verify_ledger.ReadOnlyLedgerError as exc:
            print(f"KILL SWITCH PRESENT ({CREDIT_OPS_NOTES_KILL_SWITCH}): dry run refused - {exc}")
            return 2
        verify_ledger.READ_ONLY_PROCESS = True     # every later open in this run is mode=ro (QA #1564 round 3)
        log(f"credit-ops-notes kill switch present at {CREDIT_OPS_NOTES_KILL_SWITCH}: dry run only (read-only)")
        print(f"KILL SWITCH PRESENT ({CREDIT_OPS_NOTES_KILL_SWITCH}): dry run only - no messages are sent and no "
              "verify-ledger entries are recorded")
    return _uvn_status(args)


def _uvn_status(args: argparse.Namespace) -> int:
    if args.preview:
        Path(args.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.wording and (args.campaign, args.wording) not in uvn_status.WORDINGS:
        print("--wording queued|received applies to status-doc-received, --wording no-ask to status-team-review", file=sys.stderr)
        return 2
    if args.campaign == "gap-ask" and not args.from_stage2:
        print("gap-ask reaches only users stage 2 judged: add --from-stage2", file=sys.stderr)
        return 2
    if not args.from_stage2 and not args.list:
        print("--list is required unless --from-stage2", file=sys.stderr)
        return 2
    exclude: set[str] = set()
    if args.exclude_users:
        exclude = {ln.strip() for ln in Path(args.exclude_users).read_text().splitlines()
                   if ln.strip() and not ln.startswith("#")}
    why = preflight_outcomes(args)
    if why:
        print(f"UVN STATUS: {why}.")
        return 2
    report = uvn_status.run(list_path=args.list, segment=args.segment, mode=args.mode, max_users=args.max_users,
                            campaign=args.campaign, wording=args.wording or "",
                            ledger_path=args.ledger, proof_path=args.proof_on_file, preview_dir=args.preview,
                            from_stage2=args.from_stage2, stage2_path=args.proof_store, exclude_users=exclude,
                            check_recipients=args.check_recipients, segment_daily_cap=args.segment_daily_cap,
                            gmail_fallback_o=args.gmail_fallback_o,
                            no_correction=args.no_correction, max_entries=args.max_entries,
                            start_entry=args.start_entry)
    log("uvn-status " + json.dumps({k: v for k, v in vars(report).items() if not isinstance(v, (list, dict))}))
    werr = write_outcomes(args, report)
    print(uvn_status.render(report, args.mode, args.segment) + (f" OUTCOMES NOT WRITTEN: {werr}." if werr else ""))
    if getattr(report, "policy_error", False):
        return 2                                   # QA #1617: an unreadable cap policy is an operational failure
    if getattr(report, "cap_short", False):
        return 3                                   # [key=uvn-daily-cap-400]: refused whole before the first send
    return 1 if report.failed or werr else 0


def cmd_claim_proof_ask(args: argparse.Namespace) -> int:
    if CREDIT_OPS_NOTES_KILL_SWITCH.exists():
        log(f"credit-ops-notes kill switch present at {CREDIT_OPS_NOTES_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    if args.preview:
        Path(args.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.check_recipients and args.reminders:
        # QA #1516: a reminder's claim path differs; its recipient check would silently fall back to offline validation
        print("--check-recipients applies to first notes only, not --reminders.")
        return 2
    why = preflight_outcomes(args)
    if why:
        print(f"CLAIM PROOF ASK: {why}.")
        return 2
    report = claim_proof_ask.run(list_path=args.list, segment=args.segment, mode=args.mode,
                                 max_users=args.max_users, reminders=args.reminders, preview_dir=args.preview,
                                 check_recipients=args.check_recipients)
    werr = write_outcomes(args, report)
    print(claim_proof_ask.render(report, args.mode, args.segment, reminders=args.reminders)
          + (f" OUTCOMES NOT WRITTEN: {werr}." if werr else ""))
    return 1 if report.failed or werr else 0


def cmd_claim_status(args: argparse.Namespace) -> int:
    if CREDIT_OPS_NOTES_KILL_SWITCH.exists():
        log(f"credit-ops-notes kill switch present at {CREDIT_OPS_NOTES_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    if args.preview:
        Path(args.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.check_recipients and args.mode != "dry-run":
        print("--check-recipients is for --mode dry-run only.")
        return 2
    why = preflight_outcomes(args)
    if why:
        print(f"CLAIM STATUS NOTE: {why}.")
        return 2
    report = claim_proof_ask.run_status(list_path=args.list, segment=args.segment, mode=args.mode,
                                        max_users=args.max_users, preview_dir=args.preview,
                                        check_recipients=args.check_recipients)
    werr = write_outcomes(args, report)
    print(claim_proof_ask.render(report, args.mode, args.segment, status=True)
          + (f" OUTCOMES NOT WRITTEN: {werr}." if werr else ""))
    return 1 if report.failed or werr else 0


def cmd_intercom_reconcile(args: argparse.Namespace) -> int:
    if intercom_reconcile.KILL_SWITCH.exists():
        log(f"intercom-reconcile kill switch present at {intercom_reconcile.KILL_SWITCH}; nothing run")
        print("NO_REPLY")
        return 0
    if args.revert:
        rv = intercom_reconcile.revert(args.revert, mode=args.mode, ledger_path=args.ledger)
        log("intercom-reconcile revert " + json.dumps({k: v for k, v in vars(rv).items() if k != "rows"}))
        if rv.halted:
            print(f"INTERCOM RECONCILE REVERT: nothing done: {rv.halted}.")
            return 1
        if args.out:
            Path(args.out).mkdir(mode=0o700, parents=True, exist_ok=True)
            Path(args.out, f"{rv.run_id}.json").write_text(json.dumps(vars(rv), indent=1))
        verb = "reverted" if args.mode == "apply" else "would revert"
        print(f"INTERCOM RECONCILE REVERT ({args.mode}, run {rv.run_id}, of {args.revert}): {verb} {rv.reverted}, "
              f"failed {rv.failed}, refused (changed since) {rv.refused}, refusal holds restored {rv.holds_restored}.")
        return 1 if rv.failed else 0
    classes = tuple(c.strip() for c in args.classes.split(",") if c.strip())
    bad = [c for c in classes if c not in ("A1", "A2", "A4")]
    if bad or not classes:
        print(f"--classes takes A1, A2 and/or A4 (the only writable classes); got {args.classes!r}", file=sys.stderr)
        return 2
    res = intercom_reconcile.run(mode=args.mode, ledger_path=args.ledger, max_users=args.max_users,
                                 approved=args.approved, classes=classes, segment=args.segment)
    log("intercom-reconcile " + json.dumps(intercom_reconcile.summary(res)))
    if not res.halted:
        files = intercom_reconcile.write_outputs(res, args.out)
        print(intercom_reconcile.render(res) + " Files: " + ", ".join(files))
    else:
        print(intercom_reconcile.render(res))
    return 1 if res.halted or res.failed or res.unverified else 0


def cmd_fraud_lens(args: argparse.Namespace) -> int:
    query = verify_notify.trino
    lens = fraud_lens.default_lens(query)
    if args.users:
        ids = [int(x) for x in Path(args.users).read_text().split() if x.strip().isdigit()]
        counts: dict = {"input_users": len(ids)}
    else:
        ids, counts = fraud_lens.paid_never_contacted(query, args.ledger or verify_ledger.DEFAULT_PATH, since=args.since)
    out = fraud_lens.split(ids, lens)
    d = Path(args.out)
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    (d / "never.txt").write_text("".join(f"{u}\n" for u in ids))
    (d / "clean.txt").write_text("".join(f"{u}\n" for u in out["clean"]))
    (d / "ask-only.txt").write_text("".join(f"{u}\n" for u in out["ask_only"]))
    (d / "fraud-held.json").write_text(json.dumps(out["held"], indent=1))
    (d / "watchlisted.txt").write_text("".join(f"{u}\n" for u in out["watchlisted_messageable"]))
    summ = {**counts, **out["counts"], "single_signal_hold_min": fraud_lens.SINGLE_SIGNAL_HOLD_MIN}
    (d / "lens-summary.json").write_text(json.dumps(summ, indent=1))
    print("FRAUD LENS: " + json.dumps(summ) + f" Files in {d} (ask-only.txt users go to the uvn-status list only).")
    return 0


def cmd_withdrawal_confirm(args: argparse.Namespace) -> int:
    if CREDIT_OPS_NOTES_KILL_SWITCH.exists():
        log(f"credit-ops-notes kill switch present at {CREDIT_OPS_NOTES_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    report, refused, held, deferred = withdrawal_confirm.run([x for x in args.request_ids.split(",") if x.strip()],
                                                             mode=args.mode)
    verb = "sent" if args.mode == "apply" else "would send"
    held_lines = [f"{rid}: held, no professional id on the account" for rid in held]
    held_lines += [f"{rid}: deferred, daily cap: retry tomorrow" for rid in deferred]
    detail = refused + held_lines + report.refusals + report.failures
    print(f"WITHDRAWAL CONFIRM: {verb} {report.sent_notes if args.mode == 'apply' else report.users}, "
          f"skipped {report.skipped}, deferred {report.deferred_users}, refused {report.refused_users + len(refused)}, "
          f"held (no professional id) {report.no_professional_id}, "
          f"failed {report.failed_users}" + ("; " + "; ".join(detail)[:600] if detail else ""))
    if report.failed or refused or report.refused_users:
        return 1
    return 3 if held or deferred else 0


def cmd_email_changed(args: argparse.Namespace) -> int:
    if CREDIT_OPS_NOTES_KILL_SWITCH.exists():
        log(f"credit-ops-notes kill switch present at {CREDIT_OPS_NOTES_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    report, refused = withdrawal_confirm.email_changed(user_id=args.user_id, conversation=args.conversation,
                                                       ticket=args.ticket, dup=args.dup, mode=args.mode)
    verb = "sent" if args.mode == "apply" else "would send"
    print(f"EMAIL CHANGED ({'dup' if args.dup else 'plain'}): {verb} {report.sent_notes if args.mode == 'apply' else (0 if refused else 1)}, "
          f"skipped {report.skipped}, deferred {report.deferred_users}, refused {report.refused_users + len(refused)}, "
          f"failed {report.failed_users}"
          + (f", flagged {report.flagged}" if report.flagged else "")
          + ("; " + "; ".join(refused + report.refusals + report.failures + report.flag_failures)[:600]
             if refused or report.refusals or report.failures or report.flag_failures else ""))
    if report.failed or refused or report.refused_users:
        return 1
    return 3 if report.deferred_users else 0


def cmd_verify_wave(args: argparse.Namespace) -> int:
    if VERIFY_NOTIFY_KILL_SWITCH.exists():
        log(f"verify-notify kill switch present at {VERIFY_NOTIFY_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    if args.unverified:
        db = verify_ledger.connect(args.ledger or verify_ledger.DEFAULT_PATH)
        try:
            rows = verify_ledger.unverified_past(db, day=_today())
        finally:
            db.close()
        _export(args.unverified, rows)
        print(f"{len(rows)} past credit(s) with no documents 30+ days after the ask written to {args.unverified} "
              "(flag: unverified). They stay on the profiles; nothing was changed.")
        return 0
    if args.audit_docs and args.mode == "apply":
        print("--audit-docs is read-only; use it with --mode dry-run.")
        return 2
    if not args.wave_file:
        print("verify-wave needs --wave-file (or --unverified FILE).")
        return 2
    if not Path(args.wave_file).exists():
        log(f"verify-wave: no wave file at {args.wave_file}; nothing to do")
        print("NO_REPLY")
        return 0
    if args.preview:
        Path(args.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        report = verify_notify.run_wave(
            admin_api.AdminClient(), wave_path=args.wave_file, ledger_path=args.ledger, mode=args.mode,
            exclude=verify_notify.load_exclusions(args.exclude_users), max_users=args.max_users,
            daily_max_notes=args.daily_max_notes, pace_seconds=args.pace_seconds,
            preview_dir=args.preview if args.mode != "apply" else None, audit_docs=args.audit_docs,
            proof_path=args.proof_on_file)
    except verify_notify.ContractError as exc:
        log(f"verify-wave contract error: {exc}")
        print(f"Retro verify wave could not run: {exc}. Nothing was sent.")
        return 2
    log("verify-wave " + json.dumps({k: v for k, v in vars(report).items() if not isinstance(v, list)}))
    print(report.render(args.mode, title="RETRO VERIFY WAVE"))
    return 1 if report.failed else 0


def cmd_removal_notice(args: argparse.Namespace) -> int:
    if VERIFY_NOTIFY_KILL_SWITCH.exists():
        log(f"verify-notify kill switch present at {VERIFY_NOTIFY_KILL_SWITCH}; nothing sent")
        print("NO_REPLY")
        return 0
    if args.preview:
        Path(args.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        report = verify_notify.run_removal_notices(
            admin_api.AdminClient(), events_path=args.events, ledger_path=args.ledger, mode=args.mode,
            max_users=args.max_users, pace_seconds=args.pace_seconds,
            preview_dir=args.preview if args.mode != "apply" else None, list_path=args.list)
    except verify_notify.ContractError as exc:
        log(f"removal-notice contract error: {exc}")
        print(f"Removal notices could not run: {exc}. Nothing was sent.")
        return 2
    log("removal-notice " + json.dumps({k: v for k, v in vars(report).items() if not isinstance(v, list)}))
    print(report.render(args.mode))
    return 1 if report.failed else 0


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
    dc.add_argument("--mode", choices=["shadow", "apply", "judge"], default="shadow",
                    help="judge: decide and record (ledger mode='judge', read by stage 2) but write nothing")
    dc.add_argument("--max-rows", type=int, default=None, help="held rows per run (default: policy, 500)")
    dc.add_argument("--workers", type=int, default=6)
    dc.add_argument("--budget-s", type=int, default=720, help="stop building evidence after this many seconds")
    dc.add_argument("--paid-fallback", action="store_true",
                    help="let rows no free source covers fall back to the OpenRouter web judge (metered, capped)")
    dc.add_argument("--daily-budget-usd", type=float, default=25.0,
                    help="shared per-UTC-day cap on metered model spend (audit + decide; captain: $25/day)")
    model_flags(dc)
    dc.set_defaults(fn=cmd_decide, provider="codex", max_model_calls=120, budget_usd=2.0)

    sa = sub.add_parser("score-approve", help="execute the validator's approve verdict on held low-risk rows "
                                            "(captain 2026-10-20; credit-trust-score-approve)")
    sa.add_argument("--mode", choices=["shadow", "apply"], default="shadow")
    sa.add_argument("--max-per-run", type=int, default=None, help="lower the policy's per-run pace")
    sa.add_argument("--pause", default=None, metavar="REASON",
                    help="stop every write now (Fable condition 10: audit precision < 95 %%), e.g. the audit id")
    sa.add_argument("--resume", action="store_true", help="lift a --pause (after Fable's review)")
    sa.set_defaults(fn=cmd_score_approve)

    ex = sub.add_parser("explain", help="every decision + server outcome for one credit request")
    ex.add_argument("request_id")
    ex.set_defaults(fn=cmd_explain)

    pr = sub.add_parser("provisional-review",
                        help="Ops review list: paid provisional approvals unconfirmed after N days (read-only)")
    pr.add_argument("--days", type=int, default=30)
    pr.set_defaults(fn=cmd_provisional_review)

    xd = sub.add_parser("export-decisions", help="decisions as JSON lines (board / digest)")
    xd.add_argument("--since", required=True, help="ISO time, e.g. 2026-10-15T00:00:00Z")
    xd.set_defaults(fn=cmd_export_decisions)

    rv = sub.add_parser("revert", help="take a decide run's provisional approvals back (named human path)")
    rv.add_argument("--run", required=True)
    rv.add_argument("--apply", action="store_true", help="attempt the write (the server allows a named human only)")
    rv.set_defaults(fn=cmd_revert)

    vn = sub.add_parser("verify-notify", help="tell users which credits were provisionally approved; ask for support")
    vn.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run",
                    help="apply sends through intercom-verify-request.sh; dry-run only validates (default)")
    vn.add_argument("--run", default=None, help="only the decider run with this run_id")
    vn.add_argument("--since-hours", type=int, default=168, help="decisions newer than this (when decided_at exists)")
    vn.add_argument("--max-users", type=int, default=150, help="accounts messaged per run")
    vn.add_argument("--no-proof-sweep", action="store_true", help="skip tagging proof replies")
    vn.add_argument("--check-recipients", action="store_true",
                    help="dry-run only: run the real gate's read-only recipient check (Intercom contact search + "
                         "external_id) for every note instead of input validation alone")
    vn.add_argument("--proof-on-file", default=None, metavar="FILE",
                    help="documents-on-file exclusion list (default /var/lib/credit-trust/proof-on-file.json); "
                         "missing or older than 3h = no asks this run")
    vn.add_argument("--proof-review", default=None, metavar="MESSAGE_ID",
                    help="record the document review of a note's proof, per credit (with --request-ids, --outcome "
                         "and --reviewer) and exit; only an accepted document clears a credit from removal")
    vn.add_argument("--request-ids", default=None, help="--proof-review: comma list of the credits the verdict covers")
    vn.add_argument("--outcome", choices=["accepted", "rejected"], default=None)
    vn.add_argument("--reason", default=None,
                    choices=verify_ledger.REJECTION_REASONS,
                    help="--proof-review rejected: why the document did not verify the credits (required when a document "
                         "was received on the note; none after a reply with no document)")
    vn.add_argument("--reviewer", default=None, help="who reviewed the document (Slack UID or the review step's name)")
    vn.add_argument("--removal-due", default=None, metavar="FILE",
                    help="write the new credits past the reply-by date their note named, with no proof (JSON lines), "
                         "and the ones held for a human (awaiting review, user reply, unexplained rejection) to FILE.held, and exit")
    vn.set_defaults(fn=cmd_verify_notify)

    us = sub.add_parser("uvn-status", help="UVN status + reminder: one message per waiting requester (firstmate 060)")
    us.add_argument("--check-recipients", action="store_true", help="C11: the dry run runs every send-time check read-only "
                    "(the gate's --check-recipient), so it reports the same deferrals as the send")
    us.add_argument("--outcomes-json", default=None, help="C11: write every per-user deferral/refusal/skip with the gate's reason")
    us.add_argument("--list", default=None, help="credit-trust-llm-t01's uvn-reminder-list.json (<= 30 h old); "
                                                  "required unless --from-stage2")
    us.add_argument("--segment", choices=["paid", "free"], required=True)
    us.add_argument("--campaign", choices=list(uvn_status.CAMPAIGNS), default="uvn-status",
                    help="uvn-status (the ask, t01's uvn-reminder list) or a no-ask status note: "
                         "status-doc-received (status-A list) / status-team-review (status-B list); "
                         "gap-ask: Fable's gap ask for stage-2 need_more credits (with --from-stage2)")
    us.add_argument("--gmail-fallback-o", action="store_true",
                    help="[key=gmail-o-forward] the /o batch: the frozen did-vouch set ONLY, the ask + /o; only while cs-gmail is stale")
    us.add_argument("--start-entry", type=int, default=0, metavar="K",
                    help="QA #1612: the page starts at this segment's list entry K (the outbound tick's cursor)")
    us.add_argument("--max-entries", type=int, default=None, metavar="N",
                    help="walk at most N list entries this run (the page; p1 599: a check costs per entry walked, and "
                         "--max-users caps accepts only)")
    us.add_argument("--no-correction", action="store_true",
                    help="[key=scale-now] defer any ask that would carry the /c2 correction (class C stays signed-only)")
    us.add_argument("--wording", choices=["queued", "received", "queued-neutral", "no-ask"], default=None,
                    help="queued: status-doc-received's 'in our review queue' wording (firstmate 092); "
                         "received: the receipt R1 for a user who still owes proof (send-locked in the gate); "
                         "no-ask: status-team-review's Copy B0, without the proof sentence (firstmate 106)")
    us.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    us.add_argument("--max-users", type=int, default=None, help="messages this run (default 50; canary: 3); "
                    "with --signed-accepted: the signed check's attempt cap")
    us.set_defaults(max_users_default=50)
    us.add_argument("--segment-daily-cap", type=int, default=None,
                    help="QA #1541: the policy's per-campaign+segment daily cap, enforced under the run lock")
    us.add_argument("--preview", default=None, help="dry-run: write each user's rendered note to this dir as <user id>.txt (0700)")
    us.add_argument("--signed-accepted", default="", metavar="CHECK_JSON",
                    help="apply: send exactly the users this signed --check-recipients outcomes file accepted, sized "
                         "from its attempt cap; the sent set must equal it or the run exits 3 ([key=apply-sized-to-list])")
    us.add_argument("--page", action="store_true",
                    help="with --signed-accepted: the run may send a subset (the outbound tick pages by design)")
    us.add_argument("--preview-accepted", default="", metavar="CHECK_JSON",
                    help="with --preview: render exactly the users this --check-recipients outcomes file accepted "
                         "(t01b 584: a deferred user takes no render and no slot)")
    us.add_argument("--proof-on-file", default=None, metavar="FILE")
    us.add_argument("--from-stage2", action="store_true",
                    help="build the population live from the stage-2 verdicts (uvn-status: no_document; gap-ask: "
                         "need_more) instead of a list")
    us.add_argument("--proof-store", default=None, metavar="FILE",
                    help="the stage-2 proof store (default /var/lib/hydra-credit-verify/proof.sqlite)")
    us.add_argument("--exclude-users", default=None, metavar="FILE",
                    help="user ids (one per line) another lane messages today: left for a later run")
    us.set_defaults(fn=cmd_uvn_status)

    cp = sub.add_parser("claim-proof-ask", help="dated code ask to band B/C claimants + its day-7 reminder "
                                                "(steers-1830 #5; send-locked in the gate until Fable + firstmate)")
    cp.add_argument("--list", required=True, help="claim-flow-fix-fable-c1's claim list (<= 30 h old, names the daily code check)")
    cp.add_argument("--segment", choices=["paid", "free"], required=True)
    cp.add_argument("--check-recipients", action="store_true", help="C11: the dry run runs every send-time check read-only "
                    "(the gate's --check-recipient), so it reports the same deferrals as the send")
    cp.add_argument("--outcomes-json", default=None, help="C11: write every per-user deferral/refusal/skip with the gate's reason")
    cp.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    cp.add_argument("--max-users", type=int, default=None, help="messages this run (default 20; canary: 3); "
                    "with --signed-accepted: the signed check's attempt cap")
    cp.set_defaults(max_users_default=20)
    cp.add_argument("--reminders", action="store_true", help="send the due day-7 reminders instead of first asks")
    cp.add_argument("--preview", default="", help="dry-run: write each rendered note to this dir (0700)")
    cp.add_argument("--signed-accepted", default="", metavar="CHECK_JSON",
                    help="apply: send exactly the users this signed --check-recipients outcomes file accepted, sized "
                         "from its attempt cap; the sent set must equal it or the run exits 3 ([key=apply-sized-to-list])")
    cp.add_argument("--page", action="store_true",
                    help="with --signed-accepted: the run may send a subset (the outbound tick pages by design)")
    cp.add_argument("--preview-accepted", default="", metavar="CHECK_JSON",
                    help="with --preview: render exactly the users this --check-recipients outcomes file accepted "
                         "(t01b 584: a deferred user takes no render and no slot)")
    cp.set_defaults(fn=cmd_claim_proof_ask)

    cs = sub.add_parser("claim-status", help="no-ask status note to pending claimants who get no proof ask "
                                             "(Fable 1023 ruling 3; send-locked in the gate until firstmate's GO)")
    cs.add_argument("--list", required=True, help="the claim list (<= 30 h old); rows with audience 'status', or not B/C / no readable surface")
    cs.add_argument("--segment", choices=["paid", "free"], required=True)
    cs.add_argument("--check-recipients", action="store_true", help="C11: the dry run runs every send-time check read-only "
                    "(the gate's --check-recipient), so it reports the same deferrals as the send")
    cs.add_argument("--outcomes-json", default=None, help="C11: write every per-user deferral/refusal/skip with the gate's reason")
    cs.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    cs.add_argument("--max-users", type=int, default=None, help="messages this run (default 50; canary: 3); "
                    "with --signed-accepted: the signed check's attempt cap")
    cs.set_defaults(max_users_default=50)
    cs.add_argument("--preview", default="", help="dry-run: write each rendered note to this dir (0700)")
    cs.add_argument("--signed-accepted", default="", metavar="CHECK_JSON",
                    help="apply: send exactly the users this signed --check-recipients outcomes file accepted, sized "
                         "from its attempt cap; the sent set must equal it or the run exits 3 ([key=apply-sized-to-list])")
    cs.add_argument("--page", action="store_true",
                    help="with --signed-accepted: the run may send a subset (the outbound tick pages by design)")
    cs.add_argument("--preview-accepted", default="", metavar="CHECK_JSON",
                    help="with --preview: render exactly the users this --check-recipients outcomes file accepted "
                         "(t01b 584: a deferred user takes no render and no slot)")
    cs.set_defaults(fn=cmd_claim_status)

    ir = sub.add_parser("intercom-reconcile", help="Fable ruling A: reconcile Intercom external_id for identity-refused "
                                                    "users (dry run by default; never messages)")
    ir.add_argument("--segment", choices=["paid"], default="paid")
    ir.add_argument("--mode", choices=["dry-run", "apply"], default="dry-run")
    ir.add_argument("--max-users", type=int, default=intercom_reconcile.FIRST_RUN_CAP,
                    help=f"writes this run (the first apply run ever is capped at {intercom_reconcile.FIRST_RUN_CAP})")
    ir.add_argument("--approved", default=None, metavar="DRY_RUN_JSON",
                    help="apply: the dry-run file firstmate approved; only its `fix` rows, still `fix` now, are written")
    ir.add_argument("--classes", default="A1,A2,A4", help="apply: which writable classes to write (default A1,A2,A4)")
    ir.add_argument("--revert", default=None, metavar="RUN_ID", help="restore the old external_id of every contact "
                                                                    "that run changed (with --mode apply)")
    ir.add_argument("--out", default="/var/lib/hydra/credit-review/intercom-reconcile",
                    help="directory for the table, rows and cs list (0700; ids only, no emails)")
    ir.set_defaults(fn=cmd_intercom_reconcile)

    fl = sub.add_parser("fraud-lens", help="Fable ruling B: split the paid never-contacted population into "
                                           "fraud-held / ask-only / clean (read-only)")
    fl.add_argument("--users", default=None, help="user ids, one per line (default: build the paid never-contacted set)")
    fl.add_argument("--since", default="2026-10-20", help="ledger `sent` rows since this date count as contacted")
    fl.add_argument("--out", required=True, help="output directory (0700)")
    fl.set_defaults(fn=cmd_fraud_lens)

    wc = sub.add_parser("withdrawal-confirm", help="confirm requester-withdrawn credit requests (firstmate 061)",
                        description="Exit status: 0 = every requested confirmation was sent or already sent; "
                                    "3 = at least one is held or deferred (listed by request id with the "
                                    "reason: no professional id on the account, or the daily cap); "
                                    "1 = a refusal or failure.")
    wc.add_argument("--request-ids", required=True,
                    help="comma-separated id[:conversation] items (verified withdrawals only); with a conversation "
                         "the note is a reply in that Intercom conversation, without one it goes by email")
    wc.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    wc.set_defaults(fn=cmd_withdrawal_confirm)

    ec = sub.add_parser("email-changed", help="threaded 'sign-in email updated' reply (firstmate 073)")
    ec.add_argument("--user-id", type=int, required=True)
    ec.add_argument("--conversation", required=True, help="the requester's own Intercom conversation id")
    ec.add_argument("--ticket", required=True, help="ticket key (once per ticket)")
    ec.add_argument("--dup", action="store_true", help="variant: the extra account was set aside")
    ec.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    ec.set_defaults(fn=cmd_email_changed)

    vw = sub.add_parser("verify-wave", help="retro 30-day documentation waves (initial notes, reminders, proof sweep)")
    vw.add_argument("--wave-file", default=None, help="CSV: credit_request_id,user_id,profile_id[,track_id,tier,pop_now,paid,claim_date]")
    vw.add_argument("--exclude-users", default=None, metavar="FILE",
                    help="user ids (one per line) whose existing credits are handled elsewhere; never asked")
    vw.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    vw.add_argument("--max-users", type=int, default=100, help="notes per run")
    vw.add_argument("--daily-max-notes", type=int, default=600, help="initial notes per UTC day")
    vw.add_argument("--pace-seconds", type=float, default=1.0, help="pause between sends")
    vw.add_argument("--preview", default=None, help="dry-run: write each rendered note to this dir (0700)")
    vw.add_argument("--proof-on-file", default=None, metavar="FILE",
                    help="documents-on-file exclusion list (default /var/lib/credit-trust/proof-on-file.json); "
                         "missing or older than 3h = no asks this run")
    vw.add_argument("--audit-docs", default=None, metavar="FILE",
                    help="dry-run: check (read-only) which accounts already sent documents; write user_id,credits,result")
    vw.add_argument("--unverified", default=None, metavar="FILE",
                    help="write the past credits with no documents 30+ days after the ask (JSON lines) and exit")
    vw.set_defaults(fn=cmd_verify_wave)

    rn = sub.add_parser("removal-notice", help="tell owners of credits we removed (non-self, non-fraud)")
    rn.add_argument("--events", required=True, help="removal events, JSON lines (see credit_review/verify_notify.py)")
    rn.add_argument("--mode", choices=["apply", "dry-run"], default="dry-run")
    rn.add_argument("--max-users", type=int, default=100)
    rn.add_argument("--pace-seconds", type=float, default=1.0)
    rn.add_argument("--preview", default=None, help="dry-run: write each rendered note to this dir (0700)")
    rn.add_argument("--list", default=None, metavar="FILE", help="write the owner list (profile ids, counts, reasons; no emails)")
    rn.set_defaults(fn=cmd_removal_notice)

    pt = sub.add_parser("provisional-tracker", help="daily: provisional credits' backup clock, due/overdue, "
                                                    "day-N route, backup_ask_undelivered (read-only)")
    pt.add_argument("--window-days", type=int, default=7)
    pt.add_argument("--proof-on-file", default="/var/lib/credit-trust/proof-on-file.json")
    pt.add_argument("--out", default=None, help="write the full tracker JSON here")
    pt.add_argument("--post-board", action="store_true",
                    help="POST the per-user list to the credit-trust board (/api/ingest/provisional)")
    pt.set_defaults(fn=cmd_provisional_tracker)

    rs = sub.add_parser("rescore", help="re-apply the current policy to stored eval ledgers (no API or model calls)")
    rs.add_argument("ledgers", nargs="+")
    rs.add_argument("--mode", choices=["audit", "review"], default="audit")
    rs.add_argument("--out", default=None)
    rs.set_defaults(fn=cmd_rescore)
    return p


def _warning_to_log(message, category, filename, lineno, file=None, line=None) -> None:
    log(f"warning: {category.__name__}: {message} ({filename}:{lineno})")


def preview_accepted(args: argparse.Namespace) -> str:
    """--preview-accepted: load the check's accepted ids into verify_notify.PREVIEW_ONLY and walk the whole list (the
    run size becomes the list's entry count, so no accepted user is past the cap). '' = go, else the refusal."""
    path = getattr(args, "preview_accepted", "")
    if not path:
        return ""
    if not args.preview or args.mode != "dry-run" or getattr(args, "check_recipients", False):
        return "--preview-accepted goes with --preview on a plain --mode dry-run"
    try:
        verify_notify.PREVIEW_ONLY = verify_notify.load_preview_accepted(path)
        with open(args.list, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError, TypeError) as exc:
        return f"--preview-accepted: {exc}"
    rows = (doc.get("users") or doc.get("claims") or []) if isinstance(doc, dict) else []
    args.max_users = max(int(args.max_users or 0), len(rows), 1)
    return ""


def outside_signed(list_path: str | None, segment: str, acc: frozenset[str]) -> str:
    """'' when every user (or claimant) of this segment of the list is in the signed accepted set; else the refusal."""
    if not list_path:
        return "--signed-accepted needs the --list it signed (a subset list holding exactly the signed rows)"
    try:
        with open(list_path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        return f"--signed-accepted: the list {list_path} is unreadable ({exc})"
    rows = (doc.get("users") or doc.get("claims") or []) if isinstance(doc, dict) else []
    want = segment == "paid"
    ids = {str(r.get("user_id")) for r in rows if isinstance(r, dict) and bool(r.get("paid")) is want}
    extra = sorted(ids - acc)
    if extra:
        return (f"signed-subset-list: the list holds {len(extra)} {segment} user(s) outside the signed accepted set "
                f"({', '.join(extra[:10])}); apply a signed subset from a NEW list of exactly the signed rows")
    return ""


def signed_accepted(args: argparse.Namespace) -> tuple[str, frozenset[str] | None]:
    """Fable [key=apply-sized-to-list] (amended 586): --signed-accepted CHECK_JSON on an apply - the run's size is the
    signed dry run's ATTEMPT cap (its max_users), never a default; a smaller --max-users refuses unless --page; and
    send_all sends only users in the check's accepted set. Returns (refusal or '', the accepted set or None)."""
    path = getattr(args, "signed_accepted", "")
    if not path:
        return "", None
    if args.mode != "apply":
        return "--signed-accepted is for --mode apply", None
    try:
        acc = verify_notify.load_preview_accepted(path)
        cap = json.load(open(path, encoding="utf-8")).get("max_users")
    except (OSError, ValueError, TypeError) as exc:
        return f"--signed-accepted: {exc}", None
    if not isinstance(cap, int) or cap < 1:
        return f"--signed-accepted: {path} records no attempt cap (max_users); re-run the check on this head", None
    if args.max_users is not None and args.max_users < cap and not getattr(args, "page", False):
        return (f"apply-sized-to-list: the signed check ran at --max-users {cap}; --max-users {args.max_users} would "
                f"cut the signed set - apply it whole (omit --max-users)"), None
    if not getattr(args, "page", False):
        # Fable rule (r5, E page 2): a signed SUBSET is applied from a NEW list holding exactly the signed rows - the
        # runner refuses a list (this segment) with any user outside the signed accepted set
        why = outside_signed(getattr(args, "list", None), getattr(args, "segment", ""), acc)
        if why:
            return why, None
    if args.max_users is None or not getattr(args, "page", False):
        args.max_users = cap
    verify_notify.APPLY_ONLY = acc
    verify_notify.APPLY_PAGE = bool(getattr(args, "page", False))
    return "", acc


def main(argv: list[str] | None = None) -> int:
    # Python warnings go to the run log, never to stderr: openclaw posts a command
    # cron's stderr to Slack next to its stdout.
    warnings.showwarning = _warning_to_log
    args = parser().parse_args(argv)
    if args.cmd in ("audit", "review", "digest", "metrics", "decide") and KILL_SWITCH.exists():
        log(f"kill switch present at {KILL_SWITCH}; nothing reviewed")
        print("NO_REPLY")
        return 0
    why = preview_accepted(args)
    if why:
        print(f"Credit review {args.cmd}: {why}; nothing rendered")
        return 2
    why, signed = signed_accepted(args)
    if why:
        print(f"Credit review {args.cmd}: {why}; nothing sent")
        return 2
    if getattr(args, "max_users", 0) is None:
        args.max_users = args.max_users_default
    try:
        if getattr(args, "mode", "") == "apply":
            # QA #1604: ONE apply lock for the whole run (every user), taken before the first send
            try:
                with verify_notify.apply_session():
                    rc = args.fn(args)
            except verify_notify.ApplyLockError as exc:
                print(f"Credit review {args.cmd}: {exc}")
                return 3
        else:
            rc = args.fn(args)
        if signed is not None:
            # [key=apply-sized-to-list]: the sent set IS the signed accepted set (paged: a subset), or the run exits 3
            bad = verify_notify.signed_set_mismatch(verify_notify.APPLY_REPORTS, signed, page=getattr(args, "page", False))
            if bad:
                print(f"Credit review {args.cmd}: {bad}")
                return 3
        # [key=signed-on-sha]: a user deferred on the sha rail makes the apply exit 3 (nothing sent to them)
        return 3 if verify_notify.HEAD_REFUSED and rc == 0 else rc
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
