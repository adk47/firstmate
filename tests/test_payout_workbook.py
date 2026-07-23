"""Behavioral tests for skills-all/muso-stripe-payout-report/scripts/payout_workbook.py.

This script is a FINANCIAL DELIVERABLE: it builds the Excel payout workbook Liza reads
and reconciles to Stripe. Liza's standing rule is that the workbook's *displayed*
difference must be exactly $0.00, or the report is stopped and investigated before
delivery. The subtle trap (flagged in PR #726 review) is that the true-ledger gate
`sum(Net) == payout` is a near-identity that almost always passes, while the number Liza
actually sees (cell M12) is derived separately from per-category Converted-Amount/fee
formulas — so a payout can balance on `sum(Net)` yet still display a non-zero difference
when the summary grid fails to categorize a row (an adjustment/reversal with no product,
a Kali charge fee) or special-cases a line (Ads/Kali net = gross only).

These lock the guards that make autonomous delivery safe:
  - the true-ledger gate fails loud on a dropped/edited row (reconcile_or_die);
  - the DISPLAYED reconciliation is computed independently and asserted to $0.00, so a
    payout that balances on sum(Net) but would show Liza a non-zero difference is refused
    (displayed_variance / assert_deliverable);
  - Ads/Kali refund/adjustment/reversal activity — which the current layout drops from the
    net and would overwrite the refund cell — is refused with an actionable message;
  - money() fails loud with the offending row on a non-numeric field instead of an opaque
    Decimal traceback;
  - category_net mirrors the sheet's N formula (=J for gross-only lines, else =J-K+L+M).

Stdlib unittest only — no pytest, no network — so it runs under the same bare
`python3 -m unittest` the py-tests CI job already uses. (openpyxl is imported at module
load; the hydra self-hosted runner has it, matching production.)
"""
import importlib.util
import os
import pathlib
import tempfile
import unittest
from decimal import Decimal

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "skills-all" / "muso-stripe-payout-report" / "scripts" / "payout_workbook.py"
)
_spec = importlib.util.spec_from_file_location("payout_workbook", _SCRIPT)
pw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pw)


def charge(product, conv, fees, net, cid="ch_x"):
    return {"Type": "Charge", "ID": cid, "Converted Amount": conv,
            "Fees": fees, "Net": net, "product_name": product}


def txn(kind, conv, net, product="", tid="t_x"):
    return {"Type": kind, "ID": tid, "Converted Amount": conv,
            "Fees": "0.00", "Net": net, "product_name": product}


# A clean set of Business/Individual/Plaque charges with no separate fee/refund rows.
# payout = sum(Net); the displayed grid reconciles to exactly $0.00.
CLEAN_CHARGES = [
    charge("Business Plan", "100.00", "3.00", "97.00", "ch_b"),
    charge("Pro Plan", "50.00", "2.00", "48.00", "ch_i"),
    charge("Plaque - Regular", "200.00", "10.00", "190.00", "ch_p"),
]
CLEAN_PAYOUT = Decimal("335.00")  # 97 + 48 + 190


class TrueLedgerGate(unittest.TestCase):
    def test_balanced_payout_passes(self):
        pw.reconcile_or_die(CLEAN_CHARGES, CLEAN_PAYOUT)  # no raise

    def test_dropped_row_fails_loud(self):
        with self.assertRaises(SystemExit) as cm:
            pw.reconcile_or_die(CLEAN_CHARGES[:-1], CLEAN_PAYOUT)
        self.assertIn("RECONCILIATION FAILURE", str(cm.exception))


class DisplayedReconciliation(unittest.TestCase):
    def test_clean_set_shows_zero_difference(self):
        self.assertEqual(
            pw.displayed_variance(CLEAN_CHARGES, [], [], [], [], [], CLEAN_PAYOUT),
            Decimal("0"),
        )
        # and the deliverable gate is satisfied
        pw.assert_deliverable(CLEAN_CHARGES, [], [], [], [], [], CLEAN_PAYOUT)

    def test_uncategorized_adjustment_balances_ledger_but_breaks_display(self):
        # An adjustment with no product_name: sum(Net) still equals payout (the true-ledger
        # gate PASSES), but the summary grid can't place it, so the displayed difference is
        # non-zero and delivery must be refused. This is the exact gap the review flagged.
        adj = txn("Adjustment", "-5.00", "-5.00", product="")
        payout = CLEAN_PAYOUT + Decimal("-5.00")  # 330.00
        pw.reconcile_or_die(CLEAN_CHARGES + [adj], payout)  # ledger gate passes
        self.assertNotEqual(
            pw.displayed_variance(CLEAN_CHARGES, [], [adj], [], [], [], payout),
            Decimal("0"),
        )
        with self.assertRaises(SystemExit) as cm:
            pw.assert_deliverable(CLEAN_CHARGES, [], [adj], [], [], [], payout)
        self.assertIn("VISIBLE RECONCILIATION FAILURE", str(cm.exception))

    def test_kali_charge_fee_breaks_display(self):
        # Kali charge fees are excluded from the fee block AND Kali net shows gross only,
        # so a Kali fee makes the displayed difference non-zero even though sum(Net) balances.
        kali = charge("Kali Audio Speaker", "30.00", "1.00", "29.00", "ch_k")
        payout = CLEAN_PAYOUT + Decimal("29.00")  # 364.00
        pw.reconcile_or_die(CLEAN_CHARGES + [kali], payout)  # ledger gate passes
        with self.assertRaises(SystemExit) as cm:
            pw.assert_deliverable(CLEAN_CHARGES + [kali], [], [], [], [], [], payout)
        self.assertIn("VISIBLE RECONCILIATION FAILURE", str(cm.exception))


class GrossOnlyGuard(unittest.TestCase):
    def test_ads_refund_refused_with_actionable_message(self):
        ads = charge("Muso Ads", "40.00", "0.00", "40.00", "ch_a")
        refund = txn("Refund", "-10.00", "-10.00", product="Muso Ads", tid="re_a")
        payout = Decimal("30.00")  # 40 - 10
        with self.assertRaises(SystemExit) as cm:
            pw.assert_deliverable(CLEAN_CHARGES + [ads], [refund], [], [], [], [], payout)
        self.assertIn("Muso Ads", str(cm.exception))
        self.assertIn("Liza", str(cm.exception))


class CategoryNet(unittest.TestCase):
    def test_business_net_includes_refund(self):
        refund = txn("Refund", "-20.00", "-20.00", product="Business Plan")
        net = pw.category_net("Business", [charge("Business Plan", "100.00", "0", "100.00")],
                              [refund], [], [])
        self.assertEqual(net, Decimal("80.00"))  # 100 gross - 20 refund

    def test_ads_net_ignores_refund(self):
        refund = txn("Refund", "-10.00", "-10.00", product="Muso Ads")
        net = pw.category_net("Muso Ads", [charge("Muso Ads", "40.00", "0", "40.00")],
                              [refund], [], [])
        self.assertEqual(net, Decimal("40.00"))  # gross only, refund ignored


class BuildWorkbookOutput(unittest.TestCase):
    """Cover the workbook output contract, not just the helper math — the summary cells
    are what Finance reads, so a layout regression must be caught here."""

    def _build(self):
        from openpyxl import load_workbook
        fd, path = tempfile.mkstemp(suffix=".xlsx")
        os.close(fd)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        pw.build_workbook(CLEAN_CHARGES, "July 14,2026", CLEAN_PAYOUT, path)
        return load_workbook(path).active

    def test_ads_refund_cell_is_not_total_gross(self):
        # Regression: K6 (Muso Ads refund cell, under the "Refund" header K2) must not be
        # overwritten with total gross. With no Ads refunds it must read 0, not 335.
        ws = self._build()
        self.assertEqual(ws["K2"].value, "Refund")
        self.assertNotEqual(ws["K6"].value, float(CLEAN_PAYOUT))
        self.assertIn(ws["K6"].value, (0, 0.0, None))

    def test_core_layout_contract(self):
        ws = self._build()
        self.assertEqual(ws.freeze_panes, "A23")
        self.assertEqual(ws.cell(22, 1).value, "Type")
        self.assertEqual(ws.cell(22, 27).value, "tier")
        self.assertEqual(ws.cell(22, 1).fill.fgColor.rgb, "00FFFF00")  # yellow header
        self.assertEqual(ws["K12"].value, float(CLEAN_PAYOUT))          # payout cell
        self.assertEqual(ws["M12"].value, "=K12-L12")                   # difference formula


class CleanupOnBuildFailure(unittest.TestCase):
    """When build_workbook() raises AND the temp-CSV os.remove() also fails, Python
    re-raises the build error right after `finally`, skipping the post-finally check.
    The cleanup diagnostic must still surface (from the except path) so a PII-bearing
    CSV never lingers silently, while the primary (build) exception is preserved."""

    def test_simultaneous_build_and_cleanup_failure_surfaces_both(self):
        import io
        from contextlib import redirect_stderr
        from unittest import mock

        bad_csv = ("Type,ID,Converted Amount,Fees,Net,product_name\r\n"
                   "Charge,ch_1,10.00,0.00,10.00,Mystery Plan\r\n")  # unknown product → build raises

        def fake_engine(cmd, **kwargs):
            with open(cmd[3], "w", encoding="utf-8") as handle:
                handle.write(bad_csv)
            return mock.Mock(returncode=0)

        real_remove = os.remove

        def fail_csv_remove(path):
            if str(path).endswith(".csv"):
                raise OSError("simulated FS failure")
            return real_remove(path)

        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.xlsx")
            buf = io.StringIO()
            with mock.patch.object(pw, "stripe_json",
                                   return_value={"amount": 1000, "arrival_date": 1783987200, "currency": "usd"}), \
                 mock.patch.object(pw.subprocess, "run", side_effect=fake_engine), \
                 mock.patch.object(pw.sys, "argv", ["pw", "po_x", out]), \
                 mock.patch("os.remove", side_effect=fail_csv_remove), \
                 redirect_stderr(buf):
                with self.assertRaises(SystemExit) as cm:
                    pw.main()
            # primary (build) exception is preserved, not masked by cleanup:
            self.assertIn("Unrecognized charge products", str(cm.exception))
            # and the PII-leak cleanup failure still surfaced:
            self.assertIn("CLEANUP FAILURE", buf.getvalue())


class MoneyGuard(unittest.TestCase):
    def test_valid_value(self):
        self.assertEqual(pw.money({"Net": "12.34"}, "Net"), Decimal("12.34"))

    def test_missing_defaults_zero(self):
        self.assertEqual(pw.money({}, "Net"), Decimal("0"))

    def test_garbage_fails_loud_with_row_id(self):
        with self.assertRaises(SystemExit) as cm:
            pw.money({"Net": "GARBAGE", "ID": "ch_bad"}, "Net")
        self.assertIn("ch_bad", str(cm.exception))
        self.assertIn("Net", str(cm.exception))


class FormulaInjection(unittest.TestCase):
    """openpyxl stores a =/+/-/@-leading string as a live formula; customer- and
    Stripe-controlled text must be neutralized so it can't execute when Finance opens
    the workbook (a hostile customer name / description / metadata value)."""

    def test_formula_leading_text_is_neutralized(self):
        for hostile in ("=1+1", "+1", "-cmd", "@SUM(A1)", "=HYPERLINK(\"http://x\")"):
            out = pw.safe_text(hostile)
            self.assertTrue(out.startswith("'"), f"{hostile!r} not neutralized")
            self.assertEqual(out[1:], hostile)

    def test_benign_text_untouched(self):
        for benign in ("Business Plan", "smoplus27@gmail.com", "Liza Basco", "", "Tier 1"):
            self.assertEqual(pw.safe_text(benign), benign)

    def test_non_strings_pass_through(self):
        self.assertEqual(pw.safe_text(12.5), 12.5)
        self.assertIsNone(pw.safe_text(None))


class ProductGroup(unittest.TestCase):
    def test_known_products(self):
        cases = {
            "Business Plan": "Business",
            "Pro Plan": "Individual",
            "Plaque - Regular": "Plaque",
            "Muso Ads": "Muso Ads",
            "Kali Audio Speaker": "Kali Audio Speaker",
        }
        for name, expected in cases.items():
            self.assertEqual(pw.product_group({"product_name": name}), expected)

    def test_unknown_product_is_empty(self):
        self.assertEqual(pw.product_group({"product_name": "Mystery Plan"}), "")


if __name__ == "__main__":
    unittest.main()
