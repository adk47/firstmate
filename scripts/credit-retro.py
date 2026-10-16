#!/usr/bin/env python3
"""credit-retro r1: role-scoped take-back of proven batch-approved credits,
plus the prepared (never sent) proof-request waves.

Runbook: docs/credit-verification/credit-retro-r1.md. Package: scripts/credit_retro.

  plan           dry-run: re-prove every take-back row live, write nothing to Muso
  stage          stage the plan's rows as credit-removal approval sets, as few as the
                 untruncated evidence URLs allow (core-backend #10597)
  apply          remove the proven roles (named human's own session only; --approval <id>
                 is required: only the pairs Nick/Jan approved are removed)
  readback       confirm the roles are gone and the trusted holders are still live
  revert         re-add exactly the roles one apply run removed
  report         counts, refused/errored rows, the revert command
  prepare-waves  build the verify-with-documents payloads, one per user (NOT sent)
  restore        re-add one request's removed roles when valid proof arrives later

Transports: reads use the agent's GET-only wrapper (``--admin-script``) unless
``--login`` or ``--session-file`` is given. apply, revert and restore need ``--login``
(prompts the human for email + password, nothing stored) or
``--session-file PATH`` (0600 file holding the human's own session token).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_retro import takeback, waves  # noqa: E402
from credit_retro.api import ApiError, SessionApi, WrapperReadApi, read_token_file  # noqa: E402
from credit_retro.ledger import DEFAULT_DIR, Ledger  # noqa: E402

MANIFEST_DIR = Path(__file__).resolve().parent / "credit_retro" / "manifests"
DEFAULT_TAKEBACK = MANIFEST_DIR / "takeback-r1.jsonl"
DEFAULT_POPULATION = MANIFEST_DIR / "population-r1.jsonl.gz"
DEFAULT_WATCH = MANIFEST_DIR / "watch-velocity-r1.jsonl"
DEFAULT_EDITING_ASK = MANIFEST_DIR / "editing-ask-r1.json"


def session_api(args) -> SessionApi:
    if args.login:
        return SessionApi.login(email=args.email)
    if args.session_file:
        return SessionApi(read_token_file(args.session_file))
    raise SystemExit("this command writes to Muso: pass --login or --session-file (nick@ / jan@ only, "
                     "core-backend #10310 refuses every agent token)")


def read_api(args):
    if args.login or args.session_file:
        return session_api(args)
    return WrapperReadApi(args.admin_script)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state-dir", default=DEFAULT_DIR, help=f"ledger + wave files (default {DEFAULT_DIR})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def auth(p):
        p.add_argument("--login", action="store_true", help="sign in interactively (nick@ / jan@)")
        p.add_argument("--email", help="with --login: the email to sign in as")
        p.add_argument("--session-file", help="0600 file with the human's own session token")
        p.add_argument("--admin-script", help="reads only: muso-admin-api.sh path (agent token, GET only)")

    p = sub.add_parser("plan", help="dry-run: live gate per row, no writes")
    p.add_argument("--manifest", default=str(DEFAULT_TAKEBACK))
    auth(p)
    p = sub.add_parser("stage", help="stage the plan's rows as approval sets for Nick/Jan (#10597)")
    p.add_argument("--manifest", default=str(DEFAULT_TAKEBACK))
    p.add_argument("--plan", required=True, help="the plan run id whose would-remove rows are staged")
    auth(p)
    p = sub.add_parser("approval-status", help="show an approval set (status, pairs, consumed)")
    p.add_argument("--id", required=True)
    auth(p)
    p = sub.add_parser("apply", help="remove the proven roles (named human only)")
    p.add_argument("--manifest", default=str(DEFAULT_TAKEBACK))
    p.add_argument("--plan", required=True, help="the plan run id this executes (same manifest, < 24h)")
    p.add_argument("--only", action="append", help="row_id to apply (repeatable): canary one row first")
    p.add_argument("--approval", action="append", required=True,
                   help="required, repeatable: credit-removal approval id; only the pairs these approved are removed")
    p.add_argument("--yes-remove", action="store_true", required=True,
                   help="required: you read the plan output and every row is yours to remove")
    auth(p)
    p = sub.add_parser("readback", help="verify an apply (or revert) run against live data")
    p.add_argument("--run", required=True)
    auth(p)
    p = sub.add_parser("revert", help="re-add exactly the roles one apply run removed")
    p.add_argument("--run", required=True)
    auth(p)
    p = sub.add_parser("report", help="counts, refused rows and the revert command for a run")
    p.add_argument("--run", required=True)
    p = sub.add_parser("prepare-waves", help="build the verify-with-documents payloads (never sends)")
    p.add_argument("--population", default=str(DEFAULT_POPULATION))
    p.add_argument("--watch", default=str(DEFAULT_WATCH))
    p.add_argument("--takeback", default=str(DEFAULT_TAKEBACK),
                   help="take-back manifest; rows no apply run on it removed join the verify waves")
    p.add_argument("--per-day", type=int, default=waves.PER_DAY, help="users per daily wave")
    p.add_argument("--editing-ask", default=str(DEFAULT_EDITING_ASK),
                   help="editing burst accounts (whole-profile review) + checked editing rows")
    p.add_argument("--editing-min-pop", type=int, default=waves.EDITING_MIN_POP,
                   help="ask unverifiable editing claims only on tracks at or above this popularity")
    p.add_argument("--verify-ledger", default=waves.VERIFY_LEDGER,
                   help="Caroline send ledger: never re-ask proof senders, one past-credit message per user")
    p.add_argument("--apply-run", help="use this apply run's manifest; the take-back wave covers every apply "
                                        "run on it (canary included)")
    p.add_argument("--offline", action="store_true", help="do not read Muso (no emails, no live filter)")
    auth(p)
    p = sub.add_parser("restore", help="re-add a request's roles removed by an apply run")
    p.add_argument("--run", required=True, help="the apply run that removed them")
    p.add_argument("--request", action="append", required=True, help="credit request id (repeatable)")
    p.add_argument("--proof-ref", required=True, help="why: the valid proof (conversation / review id)")
    auth(p)

    args = ap.parse_args(argv)
    ledger = Ledger(args.state_dir)
    try:
        if args.cmd == "plan":
            manifest = str(Path(args.manifest).resolve())
            run_id, counts = takeback.plan(read_api(args), ledger, takeback.load_manifest(manifest),
                                           manifest=manifest, argv=argv)
            print(json.dumps({"plan_run": run_id, "counts": counts}, indent=1, sort_keys=True))
            print(f"next: python3 {Path(__file__).resolve()} stage --plan {run_id}")
        elif args.cmd == "stage":
            manifest = str(Path(args.manifest).resolve())
            api = read_api(args)  # the agent may stage: staging grants nothing
            run_id, out = takeback.stage(api, ledger, takeback.load_manifest(manifest), manifest=manifest,
                                         plan_run=args.plan, argv=argv)
            print(json.dumps({"stage_run": run_id, **out}, indent=1, sort_keys=True))
            if out["approval_ids"]:
                ids = " ".join(f"--approval {a}" for a in out["approval_ids"])
                print(f"next: Nick or Jan approves {', '.join(out['approval_ids'])} (POST /admin/credit-removals/"
                      f"<id>/approve from their own session), then: python3 {Path(__file__).resolve()} apply "
                      f"--plan {args.plan} {ids} --login --yes-remove")
        elif args.cmd == "approval-status":
            print(json.dumps(read_api(args).get(f"/admin/credit-removals/{args.id}"), indent=1, sort_keys=True))
        elif args.cmd == "apply":
            manifest = str(Path(args.manifest).resolve())
            api = session_api(args)
            run_id, _ = takeback.apply(api, ledger, takeback.load_manifest(manifest), manifest=manifest,
                                       plan_run=args.plan, argv=argv, only=set(args.only or []) or None,
                                       approvals=args.approval)
            print(json.dumps(takeback.report(ledger, run_id, script=str(Path(__file__).resolve())),
                             indent=1, sort_keys=True))
        elif args.cmd == "readback":
            run_id, counts = takeback.readback(read_api(args), ledger, args.run, argv=argv)
            print(json.dumps({"readback_run": run_id, "counts": counts}, indent=1, sort_keys=True))
        elif args.cmd == "revert":
            run_id, counts = takeback.revert(session_api(args), ledger, args.run, argv=argv)
            print(json.dumps({"revert_run": run_id, "counts": counts}, indent=1, sort_keys=True))
            print(f"verify: python3 {Path(__file__).resolve()} readback --run {run_id}")
        elif args.cmd == "report":
            print(json.dumps(takeback.report(ledger, args.run, script=str(Path(__file__).resolve())),
                             indent=1, sort_keys=True))
        elif args.cmd == "prepare-waves":
            api = None if args.offline else read_api(args)
            actor = getattr(api, "actor", "offline")
            waves.prepare(ledger, population_path=str(Path(args.population).resolve()), watch_path=str(Path(args.watch).resolve()),
                          takeback_path=str(Path(args.takeback).resolve()), apply_run=args.apply_run, out_root=Path(args.state_dir) / "waves", argv=argv,
                          actor=actor, api=api, per_day=args.per_day, editing_ask_path=args.editing_ask,
                          editing_min_pop=args.editing_min_pop, verify_db=args.verify_ledger)
        elif args.cmd == "restore":
            run_id, counts = takeback.revert(session_api(args), ledger, args.run, argv=argv,
                                             requests=set(args.request),
                                             ref=f"restore: valid proof {args.proof_ref} (credit-retro-r1)")
            print(json.dumps({"restore_run": run_id, "counts": counts}, indent=1, sort_keys=True))
    except ApiError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    finally:
        ledger.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
