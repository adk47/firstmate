#!/usr/bin/env python3
"""claim-list-build: rebuild, sign and install the claim list. Run by claim-list-build.timer (every 2 h at :20,
odd hours, so it is ahead of the even-hour outbound tick only - see docs/credit-verification/claim-list-build.md)
and by claim-list-build.path (every deploy), not by hand.

    claim-list-build.py            build on the deployed head, sign, install
    claim-list-build.py --dry-run  build and sign into the run dir; the live list is not touched
    claim-list-build.py --json     print the outcome as one JSON object instead of one line

READ-ONLY against prod data: the core decider runs as a dry run, the replica / ledger / catalog are read, and the
only writes are this job's own state (/var/lib/hydra/claim-list-build) and ONE atomic rename of
/var/lib/hydra/credit-verify-outbound/claim-list.json. Nothing is sent here; credit-verify-outbound's claim
families send from the list, through their own checks and gate.

Exit 0: installed, or deliberately nothing to do (kill file /etc/hydra/claim-list-build.disabled, another build
running). Exit 1: a read or a check did not answer - NOTHING is installed, the live list is byte-for-byte what it
was, and the unit's OnFailure pages #clio_devops. An unmeasured input is never an empty one.

The rules and every refusal: scripts/credit_review/claim_list.py. Operator doc: docs/credit-verification/claim-list-build.md.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from credit_review import claim_list  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true", help="build and sign, but do not replace the live list")
    ap.add_argument("--json", action="store_true", help="print the outcome as JSON")
    args = ap.parse_args(argv)
    outcome = claim_list.run(dry_run=args.dry_run)
    print(json.dumps(outcome.__dict__, sort_keys=True) if args.json else claim_list.render(outcome), flush=True)
    return outcome.rc


if __name__ == "__main__":
    sys.exit(main())
