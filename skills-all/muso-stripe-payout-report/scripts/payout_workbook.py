#!/usr/bin/env python3
"""Build the standard formatted payout workbook (Liza's approved 2026-07-20 format).

Fetches the payout + enriched transaction rows (via payout_report.py), verifies the
report reconciles to the Stripe payout amount to exactly $0.00, then writes the
grouped/subtotaled Excel workbook. Fails loud (non-zero exit) on any unrecognized
transaction type, any charge whose product cannot be grouped, or any reconciliation
variance — never deliver a workbook that doesn't reconcile.

Usage: python3 payout_workbook.py <payout_id> <output.xlsx> [--csv <existing_csv>]
       --csv skips the Stripe fetch and formats an already-generated report CSV.
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

FIELDS = [
    "Type", "ID", "Created", "Description", "Amount", "Currency",
    "Converted Amount", "Fees", "Net", "Converted Currency", "Details",
    "Customer ID", "Customer Email", "Customer Name",
    "Address_Validation_Status (metadata)", "Coupon (metadata)",
    "Referral deactivated (metadata)", "referral (metadata)",
    "Campaign (metadata)", "View in Rewardful (metadata)",
    "Affiliate (metadata)", "Link (metadata)",
    "userId (metadata)", "teamId (metadata)",
    "product_name", "business_line", "tier",
]
MONEY = '"$"#,##0.00;[Red]-"$"#,##0.00'


def money(row, key):
    raw = row.get(key) or "0"
    try:
        return Decimal(raw)
    except InvalidOperation:
        raise SystemExit(f"Invalid {key} value {raw!r} in row {row.get('ID', '?')} — cannot reconcile.")


def product_group(row):
    value = (row.get("product_name") or "").lower()
    if "business" in value:
        return "Business"
    if "plaque" in value:
        return "Plaque"
    if "pro" in value:
        return "Individual"
    if "muso ads" in value or value == "ads":
        return "Muso Ads"
    if "kali" in value and "speaker" in value:
        return "Kali Audio Speaker"
    return ""


def stripe_json(*args):
    r = subprocess.run(["stripe"] + list(args), capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise SystemExit(f"stripe error: {r.stderr[:300]}")
    return json.loads(r.stdout)


def safe_text(value):
    """Neutralize spreadsheet formula injection in customer/Stripe-controlled text.

    openpyxl stores a string beginning with =, +, -, or @ as a live formula, so a
    hostile customer name/description/metadata value would execute when Finance opens
    the workbook. Prefixing an apostrophe forces text (and is hidden by Excel/Sheets).
    """
    if isinstance(value, str) and value[:1] in ("=", "+", "-", "@"):
        return "'" + value
    return value


def add_table_row(ws, excel_row, row):
    values = []
    for field in FIELDS:
        value = row.get(field, "")
        if field == "Description" and row.get("Type") == "Charge":
            value = row.get("product_name") or value
        elif field == "Created" and value:
            value = datetime.strptime(value, "%Y-%m-%d %H:%M")
        elif field in {"Amount", "Converted Amount", "Fees", "Net"} and value != "":
            value = float(Decimal(value))
        values.append(safe_text(value))
    ws.append(values)
    ws.cell(excel_row, 3).number_format = "yyyy-mm-dd h:mm"
    for col in (5, 7, 8, 9):
        ws.cell(excel_row, col).number_format = MONEY


def add_subtotal(ws, start, end):
    ws.append([None] * len(FIELDS))
    row = ws.max_row
    for col in (7, 8, 9):
        letter = get_column_letter(col)
        ws.cell(row, col, f"={letter}{start}" if start == end else f"=SUM({letter}{start}:{letter}{end})")
        ws.cell(row, col).number_format = MONEY
        ws.cell(row, col).font = Font(bold=True)
        ws.cell(row, col).fill = PatternFill("solid", fgColor="D9EAD3")
        ws.cell(row, col).border = Border(top=Side(style="thin", color="808080"))
    return row


def classify_rows(rows):
    charges = [row for row in rows if row["Type"] == "Charge"]
    refunds = [row for row in rows if row["Type"] == "Refund"]
    stripe_fees = [row for row in rows if row["Type"] in {"Stripe Fee", "Network Cost", "Network Risk Fee"}]
    loans = [row for row in rows if row["Type"] == "Financing Paydown"]
    adjustments = [row for row in rows if row["Type"] in {"Adjustment", "Dispute", "Chargeback"}]
    reversals = [row for row in rows if row["Type"] == "Reversal"]
    recognized = charges + refunds + stripe_fees + loans + adjustments + reversals
    if len(recognized) != len(rows):
        known = {id(row) for row in recognized}
        raise SystemExit(f"Unrecognized transaction types: {sorted({row['Type'] for row in rows if id(row) not in known})}")
    if any(not product_group(row) for row in charges):
        missing = sorted({row.get("product_name", "") for row in charges if not product_group(row)})
        raise SystemExit(f"Unrecognized charge products (fix Column D mapping before delivery): {missing}")
    return charges, refunds, stripe_fees, loans, adjustments, reversals


def reconcile_or_die(rows, payout_amount):
    net_total = sum((money(row, "Net") for row in rows), Decimal("0"))
    variance = net_total - payout_amount
    if variance != 0:
        raise SystemExit(
            f"RECONCILIATION FAILURE: report net total ${net_total:,.2f} vs Stripe payout "
            f"${payout_amount:,.2f} (difference ${variance:,.2f}). Do NOT deliver — investigate."
        )


# The summary grid (rows 3-7) carries one row per product line; Ads and Kali show
# gross only (their net cell is =J, ignoring refund/adjustment/reversal columns).
SUMMARY_CATEGORIES = ("Business", "Individual", "Plaque", "Muso Ads", "Kali Audio Speaker")
GROSS_ONLY_CATEGORIES = ("Muso Ads", "Kali Audio Speaker")


def _conv(rows, name):
    return sum((money(r, "Converted Amount") for r in rows if product_group(r) == name), Decimal("0"))


def category_net(name, charges, refunds, adjustments, reversals):
    """Mirror the summary N cell: =J for gross-only lines, else =J-K+L+M.

    Refund/adjustment/reversal Converted Amounts are already signed in the CSV, so
    the sum over all non-fee rows in the category is exactly what J-K+L+M evaluates to.
    """
    net = _conv(charges, name)
    if name not in GROSS_ONLY_CATEGORIES:
        net += _conv(refunds, name) + _conv(adjustments, name) + _conv(reversals, name)
    return net


def fee_totals(charges, stripe_fees, loans):
    """The J8:J11 fee block: (subscription, stripe loan, plaque, ads)."""
    charge_fees = {name: sum((money(c, "Fees") for c in charges if product_group(c) == name), Decimal("0")) for name in SUMMARY_CATEGORIES}
    fee_net = -sum((money(f, "Net") for f in stripe_fees), Decimal("0"))
    subscription_fees = charge_fees["Business"] + charge_fees["Individual"] + fee_net
    loan_total = -sum((money(l, "Net") for l in loans), Decimal("0"))
    return subscription_fees, loan_total, charge_fees["Plaque"], charge_fees["Muso Ads"]


def displayed_variance(charges, refunds, adjustments, reversals, stripe_fees, loans, payout_amount):
    """What the workbook's cyan M12 cell will show: payout − (SUM(N3:N7) − SUM(J8:J11)).

    This is the number Liza reads. It is derived independently of the sum(Net) gate,
    so it also catches rows the summary grid never categorizes (adjustments/reversals
    without a product, Kali charge fees) — the exact gap that lets sum(Net) balance
    while the displayed difference is non-zero.
    """
    sum_net = sum((category_net(n, charges, refunds, adjustments, reversals) for n in SUMMARY_CATEGORIES), Decimal("0"))
    l12 = sum_net - sum(fee_totals(charges, stripe_fees, loans), Decimal("0"))
    return payout_amount - l12


def assert_deliverable(charges, refunds, adjustments, reversals, stripe_fees, loans, payout_amount):
    """Refuse to build a workbook Liza would have to reject on sight."""
    # Checked first so the Ads/Kali limitation surfaces its own actionable message
    # rather than the generic variance error it would otherwise trip.
    for name in GROSS_ONLY_CATEGORIES:
        if any(product_group(r) == name for r in (*refunds, *adjustments, *reversals)):
            raise SystemExit(
                f"{name} refund/adjustment/reversal rows are present but the summary shows this line's "
                f"net as gross only (and would overwrite its refund cell) — define the accounting with "
                f"Liza before delivery."
            )
    variance = displayed_variance(charges, refunds, adjustments, reversals, stripe_fees, loans, payout_amount)
    if variance != 0:
        raise SystemExit(
            f"VISIBLE RECONCILIATION FAILURE: the summary's displayed difference computes to "
            f"${variance:,.2f}, not $0.00 — Liza would see a non-zero difference. Do NOT deliver; "
            f"investigate (usually an adjustment/reversal/Kali fee the summary grid does not categorize)."
        )


def build_workbook(rows, payout_date, payout_amount, output_xlsx):
    charges, refunds, stripe_fees, loans, adjustments, reversals = classify_rows(rows)
    reconcile_or_die(rows, payout_amount)
    assert_deliverable(charges, refunds, adjustments, reversals, stripe_fees, loans, payout_amount)

    wb = Workbook()
    ws = wb.active
    ws.title = f"{payout_date}-${payout_amount:,.2f}"[:31]
    ws.sheet_view.showGridLines = True

    for _ in range(1, 22):
        ws.append([None] * len(FIELDS))
    ws.append(FIELDS)
    header_fill = PatternFill("solid", fgColor="FFFF00")
    for cell in ws[22]:
        cell.font = Font(bold=True)
        cell.fill = header_fill
        cell.alignment = Alignment(horizontal="center")

    subtotals = {}
    section_specs = [
        ("Business", [r for r in charges if product_group(r) == "Business"]),
        ("Plaque", [r for r in charges if product_group(r) == "Plaque"]),
        ("Individual", [r for r in charges if product_group(r) == "Individual"]),
        ("Muso Ads", [r for r in charges if product_group(r) == "Muso Ads"]),
        ("Kali Audio Speaker", [r for r in charges if product_group(r) == "Kali Audio Speaker"]),
        ("Refunds", refunds),
        ("Adjustments", adjustments),
        ("Reversals", reversals),
        ("Stripe Fees", stripe_fees),
        ("Stripe Loan", loans),
    ]
    for name, section in section_specs:
        if not section:
            continue
        section.sort(key=lambda row: row.get("Created", ""), reverse=True)
        start = ws.max_row + 1
        for row in section:
            add_table_row(ws, ws.max_row + 1, row)
        subtotals[name] = add_subtotal(ws, start, ws.max_row)

    ws.auto_filter.ref = f"A22:AA{ws.max_row}"
    ws.freeze_panes = "A23"
    widths = [14, 30, 18, 36, 14, 14, 14, 14, 14, 14, 36, 30, 36, 24] + [20] * 10 + [14, 14, 14]
    for index, width in enumerate(widths, start=1):
        ws.column_dimensions[get_column_letter(index)].width = width

    summary_rows = {"Business": 3, "Individual": 4, "Plaque": 5, "Muso Ads": 6, "Kali Audio Speaker": 7}
    ws["K2"], ws["L2"], ws["M2"] = "Refund", "Adjustment/Dispute", "Reversal"
    for cell in (ws["K2"], ws["L2"], ws["M2"]):
        cell.font = Font(bold=True)
    for name, row in summary_rows.items():
        ws.cell(row, 9, name)
        ws.cell(row, 9).font = Font(bold=True)
        subtotal_row = subtotals.get(name)
        ws.cell(row, 10, f"=G{subtotal_row}" if subtotal_row else "=0")
        ws.cell(row, 11, float(sum((-money(item, "Converted Amount") for item in refunds if product_group(item) == name), Decimal("0"))))
        ws.cell(row, 12, float(sum((money(item, "Converted Amount") for item in adjustments if product_group(item) == name), Decimal("0"))))
        ws.cell(row, 13, float(sum((money(item, "Converted Amount") for item in reversals if product_group(item) == name), Decimal("0"))))
        if name in {"Muso Ads", "Kali Audio Speaker"}:
            ws.cell(row, 14, f"=J{row}")
        else:
            ws.cell(row, 14, f"=J{row}-K{row}+L{row}+M{row}")
        for col in (10, 11, 12, 13, 14):
            ws.cell(row, col).number_format = MONEY

    subscription_fees, loan_total, plaque_fees, ads_fees = fee_totals(charges, stripe_fees, loans)
    ws["I8"], ws["J8"] = "Subscription fee", float(subscription_fees)
    ws["I9"], ws["J9"] = "stripe loan", float(loan_total)
    ws["I10"], ws["J10"] = "Plaque fees", float(plaque_fees)
    ws["I11"], ws["J11"] = "Ads Fee", float(ads_fees)
    for row in range(8, 12):
        ws.cell(row, 9).font = Font(bold=True)
        ws.cell(row, 10).number_format = MONEY

    # (No total-gross cell here: it previously overwrote K6, the Muso Ads refund cell,
    # displaying gross under the "Refund" heading on every workbook. K6 is left to the
    # summary loop's actual Ads refund value.)
    ws["K12"] = float(payout_amount)
    ws["L12"] = "=SUM(N3:N7)-SUM(J8:J11)"
    ws["M12"] = "=K12-L12"
    for cell in (ws["K12"], ws["L12"], ws["M12"]):
        cell.number_format = MONEY
    ws["K12"].fill = PatternFill("solid", fgColor="00FF00")
    ws["M12"].fill = PatternFill("solid", fgColor="00FFFF")
    ws["K12"].font = ws["L12"].font = ws["M12"].font = Font(bold=True)

    # Force a full recalc when the workbook opens so the section subtotal and
    # reconciliation formulas render their computed values, not a stale 0.
    wb.calculation.fullCalcOnLoad = True
    wb.calculation.forceFullCalc = True
    wb.calculation.calcMode = "auto"
    wb.save(output_xlsx)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("payout_id")
    parser.add_argument("output_xlsx")
    parser.add_argument("--csv", help="format an existing payout_report.py CSV instead of fetching")
    args = parser.parse_args()

    payout = stripe_json("payouts", "retrieve", args.payout_id)
    payout_amount = Decimal(payout["amount"]) / 100
    payout_date = datetime.fromtimestamp(payout["arrival_date"], tz=timezone.utc).strftime("%B %-d,%Y")

    # When we fetch, the intermediate CSV (which holds customer PII) is a throwaway —
    # remove it however we exit, including if the engine subprocess itself fails.
    csv_path = args.csv
    temp_csv = None
    cleanup_error = None
    try:
        if not csv_path:
            fd, csv_path = tempfile.mkstemp(suffix=f"-{args.payout_id}.csv", dir=os.path.dirname(os.path.abspath(args.output_xlsx)))
            temp_csv = csv_path
            os.close(fd)
            engine = os.path.join(os.path.dirname(os.path.abspath(__file__)), "payout_report.py")
            subprocess.run([sys.executable, engine, args.payout_id, csv_path], check=True)

        with open(csv_path, newline="", encoding="utf-8-sig") as handle:
            rows = list(csv.DictReader(handle))
        if not rows:
            raise SystemExit(f"No transactions found for {args.payout_id} — refusing to emit an empty workbook.")

        build_workbook(rows, payout_date, payout_amount, args.output_xlsx)
    finally:
        if temp_csv:
            try:
                os.remove(temp_csv)
            except OSError as exc:
                cleanup_error = (temp_csv, exc)
                # Emit here (not only after finally): if the try block is already
                # unwinding a build exception, Python re-raises it right after finally
                # and the post-finally check is skipped — so this is the only place the
                # PII-leak warning surfaces when build AND cleanup both fail.
                print(
                    f"CLEANUP FAILURE: could not remove temporary CSV {temp_csv} ({exc}); "
                    f"it may contain customer PII. Delete it manually — this report is NOT "
                    f"safely complete.",
                    file=sys.stderr,
                )
    # Otherwise-successful build: turn the recorded cleanup failure into a non-zero exit
    # so success is never reported while PII-bearing temp data lingers. (The diagnostic
    # was already printed above; a build exception, if any, has already re-raised.)
    if cleanup_error:
        raise SystemExit(1)
    print(f"Wrote {len(rows)} transactions to {args.output_xlsx} (reconciled to ${payout_amount:,.2f}, variance $0.00)", file=sys.stderr)
    print(os.path.abspath(args.output_xlsx))


if __name__ == "__main__":
    main()
