#!/usr/bin/env python3
"""The established-claimant rule's scheduled pass (established-claimant.timer, once a day).
It reads the core replica and records a decision per established request. It approves
nothing, asks nobody and calls no API.

    established-claimant.py                 one pass, published under
                                            /var/lib/hydra/established-claimant
    established-claimant.py run --out DIR   one pass into DIR, nothing published

docs/credit-verification/established-claimant.md
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import established_claimant  # noqa: E402

if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    if argv and argv[0] == "run":
        sys.exit(established_claimant._main(argv))  # noqa: SLF001
    if argv:
        print(f"established-claimant.py: unknown argument {argv[0]!r}", file=sys.stderr)
        sys.exit(2)
    sys.exit(established_claimant._main(["tick"]))  # noqa: SLF001
