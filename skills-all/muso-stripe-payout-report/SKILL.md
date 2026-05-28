---
name: muso-stripe-payout-report
description: |
  Generate a CSV payout report from Stripe for any payout ID. Returns a downloadable CSV with per-charge breakdown including customer email, product name, business line, and tier.
  Use when: someone asks for a "payout report" or "payout breakdown" for a Stripe payout ID (format: po_*). Triggered by phrases like "payout report for po_...", "breakdown of payout", "export payout", "payout CSV".
  Requires: Stripe CLI with rak_balance_read and rak_charge_read permissions.
compatibility: |
  Requires Stripe CLI with rak_balance_read and rak_charge_read. Python 3 for the report script.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Stripe Payout Report

Generate per-charge CSV report for any Stripe payout, matching the standard Stripe Dashboard export format with 3 enrichment columns: `product_name`, `business_line`, `tier`.

## Usage

1. Run the report script:
   ```bash
   python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-stripe-payout-report/scripts/payout_report.py <PAYOUT_ID> ~/.openclaw/workspace/payout-report-<PAYOUT_ID>.csv
   ```
   ⚠️ ALWAYS save to `~/.openclaw/workspace/` — never `/tmp/`. The gateway cannot attach files from `/tmp/` to Slack.

2. Upload the CSV to the requester's Slack thread:
   ```
   message(action=send, channel=slack, target=<channel_id>, threadId=<thread_ts>,
           message="<summary>", filePath=~/.openclaw/workspace/payout-report-<PAYOUT_ID>.csv)
   ```

## How It Works

- Paginates all balance transactions for the payout via Stripe CLI
- Enriches each charge with expanded customer + invoice data (5 parallel workers)
- Maps invoice line item product IDs to product_name/business_line/tier
- Includes charges, refunds, and Stripe fee rows
- Output matches the standard Stripe Dashboard CSV export format

## Notes

- ~600 charges takes ~3-5 min with parallel enrichment. Warn the user.
- Run with timeout >= 600s.
- Amounts in dollars. Stripe fees included as separate rows.
