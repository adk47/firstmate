---
name: muso-stripe-payout-report
description: |
  Generate the standard formatted Excel payout workbook from Stripe for any payout ID — grouped product sections, green subtotals, reconciliation summary, and a hard $0.00 reconciliation gate. CSV export available on explicit request.
  Use when: someone asks for a "payout report" or "payout breakdown" for a Stripe payout ID (format: po_*). Triggered by phrases like "payout report for po_...", "breakdown of payout", "export payout", "payout workbook".
  Requires: Stripe CLI with rak_balance_read and rak_charge_read permissions.
compatibility: |
  Requires Stripe CLI with rak_balance_read and rak_charge_read. Python 3 with openpyxl for the workbook script.
metadata:
  version: "2.0"
  source-repo: "Muso-AI/muso-skills"
---

# Stripe Payout Report

Generate the standard payout deliverable: a formatted Excel workbook (Liza's approved
2026-07-20 format) with per-charge enrichment (`product_name`, `business_line`, `tier`),
grouped product sections, subtotals, and an independent reconciliation that must come out
to exactly $0.00.

## Usage

**Default — Excel workbook** (what Liza and #finance_muso get for every payout request):

```bash
python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-stripe-payout-report/scripts/payout_workbook.py <PAYOUT_ID> ~/.openclaw/workspace/payout-report-<PAYOUT_ID>.xlsx
```

⚠️ ALWAYS save to `~/.openclaw/workspace/` — never `/tmp/`. The gateway cannot attach files from `/tmp/` to Slack.

Then upload the workbook you just created to the requester's Slack thread:

```
message(action=send, channel=slack, target=<channel_id>, threadId=<thread_ts>,
        message="<summary>", filePath=~/.openclaw/workspace/payout-report-<PAYOUT_ID>.xlsx)
```

**CSV only** (only when the requester explicitly asks for raw CSV):

```bash
python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-stripe-payout-report/scripts/payout_report.py <PAYOUT_ID> ~/.openclaw/workspace/payout-report-<PAYOUT_ID>.csv
```

Then upload it the same way, but attach the `.csv` you just created:

```
message(action=send, channel=slack, target=<channel_id>, threadId=<thread_ts>,
        message="<summary>", filePath=~/.openclaw/workspace/payout-report-<PAYOUT_ID>.csv)
```

## Workbook format (the standard)

- Reconciliation summary in rows 2–12: per-section gross/refund/adjustment/reversal grid,
  fee + Stripe-loan lines, payout amount (green, K12) and difference (cyan, M12)
- Yellow bold 27-column header in row 22; transaction data from row 23
- Freeze panes at A23; autofilter across A–AA
- Charges grouped into sections: Business, Plaque, Individual/Pro, Muso Ads,
  Kali Audio Speaker; Refunds, Adjustments, Reversals, Stripe Fees, and Stripe Loan
  paydowns as separate sections; empty sections omitted
- Each non-empty section ends with green formula subtotals (Converted Amount, Fees, Net)
- Column D shows the actual product name for every charge (e.g. `Business Plan`,
  `Pro Plan`, `Plaque - Regular`) — never generic "Subscription update/creation"

## Reconciliation gate — fail loud, never deliver on mismatch

`payout_workbook.py` independently verifies gross charges − refunds − Stripe fees −
loan paydowns = the Stripe payout amount, and exits non-zero on ANY of:

- reconciliation variance ≠ $0.00 exactly
- a transaction type it doesn't recognize
- a charge whose product can't be mapped to a section

If it exits non-zero: do NOT deliver a report, do NOT fall back to CSV — post the
script's diagnostic in the thread and investigate first.

## How It Works

- `payout_report.py` (engine): paginates all balance transactions for the payout via
  Stripe CLI, enriches each charge with expanded customer + invoice data (5 parallel
  workers), maps invoice line products to product_name/business_line/tier
- `payout_workbook.py`: fetches the payout amount/date, runs the engine (or takes an
  existing CSV via `--csv`), verifies reconciliation, then writes the formatted workbook

## Notes

- ~600 charges takes ~3-5 min with parallel enrichment. Warn the user.
- Run with timeout >= 600s.
- Amounts in dollars. Stripe fees included as separate rows.
