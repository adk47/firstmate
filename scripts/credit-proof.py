#!/usr/bin/env python3
"""Supporting-document forensics for credit proofs - SHADOW ONLY.

Design and operator view: docs/credit-verification/proof-forensics.md.

Subcommands:
  analyze FILE  Analyse one file (sandboxed) and print its signals + verdict.
  intercom      Analyse new customer attachments of proof conversations in the
                Intercom attachment cache Caroline's edge plugin keeps on
                node-8 (one read-only Intercom GET per conversation).
  file          FILE ONLY (no judgement): record every attachment of a LIST of
                conversations with the account it belongs to, the conversation
                and the account's candidate credit requests. This is what catches
                a document sent as a reply to our email (a new thread: no
                in-thread ask) and conversations the edge cache never kept.
                Dry run unless --apply.
  email         Analyse attachments mailed to the inbound verification address
                (Maildir; dark until the address exists).
  stage2        SHADOW stage 2: judge the documents already on file for the
                decider's "proof on file" holds and record what the decider
                would do (stage2_shadow table). Changes nothing.
  stage2-sample Print a stratified sample of stage-2 shadow verdicts (markdown)
                for Fable's review, or --summary for the outcome counts.

Writes only its own store (/var/lib/hydra-credit-verify/proof.sqlite): no
credit request is changed and nothing is sent. Kill switch:
/etc/hydra/credit-verify.disabled.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import admin as admin_api  # noqa: E402

KILL_SWITCH = os.environ.get("CREDIT_VERIFY_KILL_SWITCH", "/etc/hydra/credit-verify.disabled")


def log(msg: str) -> None:
    print(f"[credit-proof] {msg}", file=sys.stderr)


def _guard(what: str) -> bool:
    if Path(KILL_SWITCH).exists():
        log(f"kill switch present at {KILL_SWITCH}; no {what}")
        print("NO_REPLY")
        return True
    return False


def cmd_analyze(args: argparse.Namespace) -> int:
    from credit_verify.proof.pipeline import analyze_proof
    from credit_verify.proof.signals import ClaimContext
    from credit_verify.proof.store import ProofStore
    ctx = ClaimContext.from_dict(json.loads(Path(args.context).read_text()) if args.context else None)
    results = analyze_proof(ProofStore(args.store), args.file, contact_h=args.contact, source="manual",
                            source_ref=os.path.basename(args.file), ctx=ctx)
    print(json.dumps([r.as_dict() for r in results], indent=1, default=str))
    return 0


def cmd_intercom(args: argparse.Namespace) -> int:
    from credit_verify.proof import intercom
    from credit_verify.proof.store import ProofStore
    if _guard("proof analysis"):
        return 0
    tok = intercom.intercom_token()
    if not tok:
        log("no MUSOAI_INTERCOM_TOKEN: cannot classify conversations")
        print("NO_REPLY")
        return 1
    stats = intercom.run(ProofStore(args.store), days=args.days, fetch=intercom.make_fetch(tok),
                         workers=args.workers, max_files=args.max_files)
    log("intercom " + json.dumps({k: stats[k] for k in ("proof_conversations", "files_analysed",
                                                         "files_skipped_done", "classify_errors", "verdicts")}))
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        (Path(args.out) / "proof-intercom.json").write_text(json.dumps(stats, indent=1, default=str))
        (Path(args.out) / "proof-intercom.md").write_text(intercom.to_markdown(stats) + "\n")
    print("NO_REPLY")
    return 0


def cmd_file_gmail(args: argparse.Namespace) -> int:
    """`file --source gmail`: support@ messages by id (read-only gog), same proof_intake contract."""
    from credit_verify.proof import email_in, gmail_intake, intake
    from credit_verify.proof.store import ProofStore
    if not args.message_ids:
        log("--source gmail needs --message-ids FILE")
        print("NO_REPLY")
        return 2
    ids, bad = gmail_intake.read_message_ids(args.message_ids)
    if bad:
        log(f"{len(bad)} token(s) in {args.message_ids} are not Gmail message ids: {bad[:5]}")
    ids = ids[: args.limit or None]
    stats = gmail_intake.run(ProofStore.for_run(args.store, args.apply), message_ids=ids, fetch=gmail_intake.gog_raw,
                             lookup=email_in.admin_user_lookup(admin_api.AdminClient()),
                             open_rows=intake.open_rows_trino, apply=args.apply, log=log)
    stats["not_message_ids"] = bad
    log("file gmail " + json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in stats.items()}))
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        (Path(args.out) / "proof-intake-gmail.json").write_text(json.dumps(stats, indent=1, default=str))
    print("NO_REPLY")
    return 0


def cmd_file(args: argparse.Namespace) -> int:
    from credit_verify.proof import intake
    if args.source == "gmail":
        return cmd_file_gmail(args)
    if not args.conversations:
        log("--source intercom needs --conversations FILE")
        print("NO_REPLY")
        return 2
    from credit_verify.proof.intercom import intercom_token, make_fetch
    from credit_verify.proof.stage2 import held_rows
    from credit_verify.proof.store import ProofStore
    tok = intercom_token()
    if not tok:
        log("no MUSOAI_INTERCOM_TOKEN: cannot read the conversations")
        print("NO_REPLY")
        return 1
    convs = intake.read_conversations(args.conversations)
    open_rows: dict[int, list[dict]] = {}
    if args.open_rows:
        open_rows = intake.open_rows_json(args.open_rows)
    held: dict[int, list[dict]] = {}
    if args.held_from_ledger:
        for h in held_rows():
            held.setdefault(h.user_id, []).append({"request_id": h.request_id, "paid": h.paid,
                                                  "decided_at": h.decided_at})
    stats = intake.run(ProofStore.for_run(args.store, args.apply), conversations=convs, fetch=make_fetch(tok),
                       lookup=intake.professional_lookup, open_rows=open_rows, held=held,
                       export_path=args.proof_on_file or intake.PROOF_ON_FILE,
                       cache_root=args.cache_root or intake.CACHE_ROOT, apply=args.apply,
                       limit=args.limit, workers=args.workers, max_fetches=args.max_fetches,
                       open_rows_fn=None if args.open_rows else intake.open_rows_trino, log=log)
    log("file " + json.dumps({k: v for k, v in stats.items() if not isinstance(v, list)}))
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        (Path(args.out) / "proof-intake.json").write_text(json.dumps(stats, indent=1, default=str))
    print("NO_REPLY")
    return 0


def cmd_email(args: argparse.Namespace) -> int:
    from credit_verify.proof import email_in
    from credit_verify.proof.store import ProofStore
    if _guard("email intake"):
        return 0
    stats = email_in.run(ProofStore(args.store), email_in.admin_user_lookup(admin_api.AdminClient()),
                         maildir=args.maildir or email_in.MAILDIR)
    log(f"email {stats.__dict__}")
    print("NO_REPLY")
    return 0


def cmd_stage2(args: argparse.Namespace) -> int:
    from credit_verify.proof import intercom, stage2
    from credit_verify.proof.store import ProofStore
    if _guard("stage-2 shadow"):
        return 0
    tok = intercom.intercom_token()
    if not tok:
        log("no MUSOAI_INTERCOM_TOKEN: cannot read the documents on file")
        print("NO_REPLY")
        return 1
    stats = stage2.run(ProofStore(args.store), fetch=intercom.make_fetch(tok), max_users=args.max_users,
                       workers=args.workers, log=log)
    log("stage2 " + json.dumps({k: stats[k] for k in ("run_id", "held_unjudged", "users", "rows", "documents",
                                                       "skipped_not_held", "retry_users", "outcomes")}))
    for e in stats["errors"][:10]:
        log(f"stage2 error: {e}")
    print("NO_REPLY")
    return 1 if stats["intercom_unavailable"] else 0


def cmd_stage2_sample(args: argparse.Namespace) -> int:
    from credit_verify.proof import stage2
    from credit_verify.proof.store import ProofStore
    store = ProofStore(args.store)
    stage2.ensure_schema(store.db)
    if args.summary:
        print(json.dumps(stage2.summary(store.db), indent=1))
    else:
        print(stage2.sample_markdown(stage2.sample(store.db, n=args.n)), end="")
    return 0


def intake_max_fetches() -> int:
    from credit_verify.proof.intake import MAX_FETCHES
    return MAX_FETCHES


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--store", default=None, help="proof store (default /var/lib/hydra-credit-verify/proof.sqlite)")
    sub = p.add_subparsers(dest="cmd", required=True)
    pa = sub.add_parser("analyze", help="analyse one file and print the signals and verdict")
    pa.add_argument("file")
    pa.add_argument("--context", default=None, help="JSON file with the claim context")
    pa.add_argument("--contact", default="manual")
    pa.set_defaults(fn=cmd_analyze)
    pi = sub.add_parser("intercom", help="analyse new attachments of proof conversations in the Intercom cache")
    pi.add_argument("--days", type=int, default=2)
    pi.add_argument("--workers", type=int, default=3)
    pi.add_argument("--max-files", type=int, default=300)
    pi.add_argument("--out", default=None)
    pi.set_defaults(fn=cmd_intercom)
    pf = sub.add_parser("file", help="FILE ONLY: record a conversation list's attachments with account + candidate requests")
    pf.add_argument("--source", choices=("intercom", "gmail"), default="intercom",
                    help="intercom: --conversations; gmail: support@ messages by --message-ids (read-only gog)")
    pf.add_argument("--conversations", default=None, help="file of Intercom conversation ids (one per line)")
    pf.add_argument("--message-ids", default=None, help="--source gmail: file of support@ Gmail message ids")
    pf.add_argument("--apply", action="store_true", help="write the filings (default: count only, write nothing)")
    pf.add_argument("--open-rows", default=None,
                    help="JSON {user_id: [{request_id,status}]} of the accounts' open credit requests "
                         "(default: one read-only Trino SELECT for the resolved accounts)")
    pf.add_argument("--held-from-ledger", action="store_true",
                    help="also treat the decider's current proof-on-file holds as candidate requests")
    pf.add_argument("--proof-on-file", default=None, help="proof-on-file export (account fallback)")
    pf.add_argument("--cache-root", default=None, help="Intercom attachment cache")
    pf.add_argument("--limit", type=int, default=None, help="first N conversations only")
    pf.add_argument("--workers", type=int, default=3)
    pf.add_argument("--max-fetches", type=int, default=intake_max_fetches(),
                    help="Intercom attachment downloads per run (conversations beyond it wait for the next run)")
    pf.add_argument("--out", default=None)
    pf.set_defaults(fn=cmd_file)
    pe = sub.add_parser("email", help="analyse attachments mailed to the inbound verification address")
    pe.add_argument("--maildir", default=None)
    pe.set_defaults(fn=cmd_email)
    ps = sub.add_parser("stage2", help="SHADOW: judge documents on file for the decider's proof-on-file holds")
    ps.add_argument("--max-users", type=int, default=60)
    ps.add_argument("--workers", type=int, default=3, help="sandboxed analyses in parallel")
    ps.set_defaults(fn=cmd_stage2)
    pss = sub.add_parser("stage2-sample", help="stratified sample (markdown) or --summary of stage-2 shadow verdicts")
    pss.add_argument("--n", type=int, default=50)
    pss.add_argument("--summary", action="store_true")
    pss.set_defaults(fn=cmd_stage2_sample)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.fn(args)
    except admin_api.AdminError as exc:
        log(f"admin API unavailable: {exc}")
        print("NO_REPLY")
        return 1


if __name__ == "__main__":
    sys.exit(main())
