#!/usr/bin/env python3
"""Prompt-injection watch CLI (caroline-guard-g1). Detection only: nothing here acts on the text it reads.

  injection-watch.py scan --source support_email|proof_extract --ref ID [--email ADDR] < text
      scan stdin, append a ledger row on a hit, print the hits as JSON (exit 0 either way)
  injection-watch.py digest [--hours 24] [--write-candidates]
      summarise the shared ledger (Intercom inbound, support@, proof extracts, output-guard verdicts) as JSON;
      --write-candidates refreshes the fraud-lens watch CANDIDATES file (review list, never the watchlist)
  injection-watch.py hits [--hours 24] [--severity high]
      print the recent inbound hits WITH their masked context (the after-the-fact review surface: the ledger
      stores a rule name, a text hash and, for HIGH hits, a short PII-redacted window - never the raw text)
  injection-watch.py prune [--days N]
      enforce the retention window (default RETENTION_DAYS; run daily): seal the live file, then delete sealed
      generations whose newest row is older than N days. Never rewrites a file a writer can append to.
      Prints a small JSON report.
  injection-watch.py rules
      print the rule table (used by scripts/tests/injection-watch-parity.bats)

Ledger: /var/lib/hydra/injection-watch/ledger.jsonl plus its `ledger.jsonl.sealed-*` generations
(lib/injection_watch.py LEDGER_PATH + ledger_files()). Every reader reads both.
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
    pr = sub.add_parser("prune")
    pr.add_argument("--days", type=int, default=iw.RETENTION_DAYS)
    pr.add_argument("--ledger", default=str(iw.LEDGER_PATH), help=argparse.SUPPRESS)
    h = sub.add_parser("hits")
    h.add_argument("--hours", type=int, default=24)
    h.add_argument("--severity", choices=["high", "medium", "low"])
    h.add_argument("--ledger", default=str(iw.LEDGER_PATH), help=argparse.SUPPRESS)
    sub.add_parser("rules")
    a = ap.parse_args(argv)

    if a.cmd == "scan":
        hits = iw.record(a.source, a.ref, sys.stdin.read(), email=a.email, ledger=Path(a.ledger))
        print(json.dumps({"ref": a.ref, "severity": iw.top_severity(hits), "hits": hits}))
        return 0
    if a.cmd == "digest":
        out = iw.digest(Path(a.ledger), hours=a.hours)
        if a.write_candidates and out.get("watch_candidates") is not None:
            err = iw.write_candidates(out["watch_candidates"], Path(a.candidates))
            out["candidates_written"] = err is None
            if err:
                out["candidates_error"] = err
        print(json.dumps(out, indent=1))
        # A candidates file that could not be refreshed is stale, and a ledger that cannot be read is an UNKNOWN day:
        # both make the daily run non-green.
        if out.get("ledger_error"):
            print(f"injection-watch: cannot read the ledger {a.ledger}: {out['ledger_error']}", file=sys.stderr)
            return 1
        return 1 if a.write_candidates and not out.get("candidates_written") else 0
    if a.cmd == "prune":
        try:
            pr = iw.prune_ledger(Path(a.ledger), days=a.days)
        except Exception as e:  # noqa: BLE001
            print(f"injection-watch: prune FAILED on {a.ledger}: {type(e).__name__}: {e}", file=sys.stderr)
            return 3
        print(json.dumps(pr))
        # Could not determine who holds an inode (no readable /proc): every candidate was KEPT, so the retention bound
        # was NOT enforced and this must page rather than read as a successful prune.
        if pr.get("unverified_files"):
            print(f"injection-watch: prune could not verify {pr['unverified_files']} generation(s) are unreferenced "
                  f"(no readable /proc): they were kept, retention NOT enforced", file=sys.stderr)
            return 3
        return 0
    if a.cmd == "hits":
        # Read-only. HIGH hits carry a masked context; medium/low rows keep their rule names only.
        # A ledger that cannot be read is NOT an empty day: exit 2 so a reviewer never reads silence as safety.
        try:
            rows = iw.recent_hits(Path(a.ledger), hours=a.hours, severity=a.severity, on_error="raise")
        except Exception as e:  # noqa: BLE001
            print(f"injection-watch: cannot read the ledger {a.ledger}: {type(e).__name__}: {e}", file=sys.stderr)
            return 2
        print(json.dumps(rows, indent=1))
        return 0
    print(json.dumps(iw.dump_rules()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
