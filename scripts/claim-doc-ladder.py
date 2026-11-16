#!/usr/bin/env python3
"""The claim document ladder's scheduled pass: every open claim with a document or a supplied form on
file gets one recorded decision (claim-doc-ladder.timer). It records; it changes no claim and sends
nothing.

    claim-doc-ladder.py                 one pass (what the timer runs)
    claim-doc-ladder.py list            the standing refusals, each with the ask its claimant is owed
                                        and the form it is asked in (--outcome resend |
                                        awaiting_read | approved for the others)
    claim-doc-ladder.py supply          accept one form a claimant supplied (an email address, a phone
                                        number, a collaborator's profile); it decides nothing
    claim-doc-ladder.py report|verify|release ...   the store (claim_verify/doc_ladder.py)

docs/credit-verification/claim-doc-ladder.md
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from claim_verify import doc_ladder, doc_sources  # noqa: E402

if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv and argv[0] in ("plan", "run", "list", "report", "verify", "release", "supply"):
        sys.exit(doc_ladder.main(argv))
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    sys.exit(doc_sources.main(["--tick"] + argv))
