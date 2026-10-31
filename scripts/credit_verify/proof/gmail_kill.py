"""One kill file for every support@ Gmail reader (firstmate 10-31).

Deploy 22 re-imported cron-jobs.json and re-enabled the two support@ Gmail crons firstmate had disabled during
the 429 storm (credit-verify-proof-file, support-email-triage-hourly). Disabling a cron does not survive a
deploy; this file does, because it lives in /etc. While it exists:
- `credit-proof.py file-recent` runs Intercom only. Gmail is off exactly as with --no-gmail: no search, no fetch,
  and the queued support@ ids are kept for a later run.
- `credit-proof.py file --source gmail` and `credit-doc-verify.py blob-backfill` refuse.
- The muso-support-email-triage skill's preflight stops with `preflight failed: ...` (scripts/preflight.sh).
- The proof-on-file scan (`cs_proof_feed/gmail_scan.sh`, hourly via cs-proof-feed.sh) exits 4 before any gog call;
  no DONE line is written, so cs-gmail stays stale and its freshness gate holds (QA #1569).
- `paid-status/support7d.py` (twice daily via paid-status/daily.sh) exits non-zero before any gog call, failing
  closed exactly like an unreadable mailbox (QA #1569).
Every one of them names the same constant path; test_gmail_kill.py asserts that.
"""

from __future__ import annotations

import os

# A constant, never an env var (r5 [key=unattended]: a kill path the environment can move is a bypass). Tests
# monkeypatch this module attribute.
GMAIL_READERS_KILL = "/etc/hydra/gmail-readers.disabled"


def gmail_readers_disabled(path: str | None = None) -> bool:
    return os.path.exists(path or GMAIL_READERS_KILL)
