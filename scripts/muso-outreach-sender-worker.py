#!/usr/bin/env python3
"""Outreach Sender Worker — the ONLY code path that sends B2B outreach email.

Usage:
  muso-outreach-sender-worker.py --label "B2B - Ads/auto-fu-approved" \\
                                  --account a@muso.ai

  muso-outreach-sender-worker.py --draft-id r1234 --account a@muso.ai

  muso-outreach-sender-worker.py --dry-run --meta-labels "muso-meta/kind-new,..."
      Parse the labels and look the contact up. Sends, logs and alerts
      nothing; never prints the contact's email.

The worker reads drafts, validates recipient against original thread
(for follow-ups) or against the contacts sheet (for new outreach),
verifies no contact/human-teammate reply has landed, then sends and
logs atomically. See docs/runbooks/RUNBOOK-outreach-sender-worker.md.
"""
from __future__ import annotations

import argparse
import sys

# Make the lib importable whether we're run from /opt/hydra/scripts/
# or the repo root.
import os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lib.muso_outreach import (
    gmail_client, ghl_client, nocodb_client, sheets_client, slack_client,
)
from lib.muso_outreach.worker import dry_run, process_batch, process_draft


class RealAdapters:
    gmail = gmail_client
    sheets = sheets_client
    nocodb = nocodb_client
    slack = slack_client
    ghl = ghl_client


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--account", default=None,
                   help="Sending Gmail account, e.g. a@muso.ai")
    p.add_argument("--dry-run", action="store_true",
                   help="Check draft metadata + contact lookup only (needs --meta-labels)")
    p.add_argument("--meta-labels",
                   help="Comma-separated draft labels, for --dry-run")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--draft-id",
                       help="Process exactly one draft by ID")
    group.add_argument("--label",
                       help="Process every draft with this label")
    args = p.parse_args(argv)

    a = RealAdapters()
    if args.dry_run:
        if not args.meta_labels or args.draft_id or args.label:
            p.error("--dry-run takes --meta-labels and no --draft-id/--label")
        lines, rc = dry_run(tuple(x.strip() for x in args.meta_labels.split(",")
                                  if x.strip()), a)
        print("\n".join(lines))
        return rc
    if args.meta_labels:
        p.error("--meta-labels is only valid with --dry-run")
    if not args.account or not (args.draft_id or args.label):
        p.error("--account and one of --draft-id/--label are required")
    if args.draft_id:
        result = process_draft(args.draft_id, args.account, a)
        print(result)
        if result.sent:
            return 0  # sent (possibly with post-send degradation logged)
        return 1  # blocked by gate or metadata — not an error, but not sent

    draft_ids = gmail_client.list_drafts_with_label(args.label, args.account)
    if not draft_ids:
        slack_client.post_sales_alert(
            f":information_source: No drafts under label `{args.label}`."
        )
        return 0
    report = process_batch(draft_ids, args.account, a)
    print(report)
    return 0 if not report.batch_halted else 2


if __name__ == "__main__":
    sys.exit(main())
