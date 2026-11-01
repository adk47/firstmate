#!/usr/bin/env python3
"""Prompt-injection watch CLI (caroline-guard-g1). Detection only: nothing here acts on the text it reads.

  injection-watch.py scan --source support_email|proof_extract --ref ID [--email ADDR] < text
      scan stdin, append a ledger row on a hit, print the hits as JSON (exit 0 either way)
  injection-watch.py digest [--hours 24] [--write-candidates]
      summarise the shared ledger (Intercom inbound, support@, proof extracts, output-guard verdicts) as JSON;
      --write-candidates refreshes the fraud-lens watch CANDIDATES file (review list, never the watchlist)
  injection-watch.py rules
      print the rule table (used by scripts/tests/injection-watch-parity.bats)

Ledger: /var/lib/hydra/injection-watch/ledger.jsonl (lib/injection_watch.py LEDGER_PATH).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib import injection_watch as iw  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--source", required=True, choices=["support_email", "proof_extract"])
    s.add_argument("--ref", required=True)
    s.add_argument("--email")
    s.add_argument("--ledger", default=str(iw.LEDGER_PATH), help=argparse.SUPPRESS)
    d = sub.add_parser("digest")
    d.add_argument("--hours", type=int, default=24)
    d.add_argument("--write-candidates", action="store_true")
    d.add_argument("--ledger", default=str(iw.LEDGER_PATH), help=argparse.SUPPRESS)
    d.add_argument("--candidates", default=str(iw.CANDIDATES_PATH), help=argparse.SUPPRESS)
    sub.add_parser("rules")
    a = ap.parse_args(argv)

    if a.cmd == "scan":
        hits = iw.record(a.source, a.ref, sys.stdin.read(), email=a.email, ledger=Path(a.ledger))
        print(json.dumps({"ref": a.ref, "severity": iw.top_severity(hits), "hits": hits}))
        return 0
    if a.cmd == "digest":
        out = iw.digest(Path(a.ledger), hours=a.hours)
        if a.write_candidates:
            err = iw.write_candidates(out["watch_candidates"], Path(a.candidates))
            out["candidates_written"] = err is None
            if err:
                out["candidates_error"] = err
        print(json.dumps(out, indent=1))
        # A candidates file that could not be refreshed is stale: the daily run must not report green.
        return 1 if a.write_candidates and not out["candidates_written"] else 0
    print(json.dumps(iw.dump_rules()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
