#!/usr/bin/env python3
"""Supporting-document forensics for credit proofs - SHADOW ONLY.

Design and operator view: docs/credit-verification/proof-forensics.md.

Subcommands:
  analyze FILE  Analyse one file (sandboxed) and print its signals + verdict.
  intercom      Analyse new customer attachments of proof conversations in the
                Intercom attachment cache Caroline's edge plugin keeps on
                node-8 (one read-only Intercom GET per conversation).
  email         Analyse attachments mailed to the inbound verification address
                (Maildir; dark until the address exists).

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
    pe = sub.add_parser("email", help="analyse attachments mailed to the inbound verification address")
    pe.add_argument("--maildir", default=None)
    pe.set_defaults(fn=cmd_email)
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
