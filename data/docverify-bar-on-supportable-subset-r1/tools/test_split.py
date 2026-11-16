#!/usr/bin/env python3
"""The lane rule of split.py, against the repo's own gate constants and ask words (never restated).

    python3 data/docverify-bar-on-supportable-subset-r1/tools/test_split.py
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import split  # noqa: E402
from credit_review import proof_reviewer  # noqa: E402
from credit_verify.docverify import gate  # noqa: E402


def doc(kind="unknown", doc_type="other", outcome="unverifiable", need=gate.NEED_DASHBOARD, hold=False):
    return {"proof_id": "p", "kind": kind, "doc_type": doc_type, "outcome": outcome, "need": need,
            "account_hold": hold}


def route(docs):
    return split.route(docs, gate.RECORD_H3_KINDS, gate.RECORD_DOC_TYPES, proof_reviewer.ASK_LINES,
                       gate.NEED_ACCOUNT, gate.NEED_READABLE)


class RouteTests(unittest.TestCase):
    def test_no_document_read_is_ours_not_an_ask(self):
        self.assertEqual(route([])["lane"], split.NO_DOC)

    def test_an_account_hold_is_never_asked(self):
        r = route([doc(kind="contract", hold=True), doc()])
        self.assertEqual(r["lane"], split.HOLD_LANE)
        self.assertNotIn("ask", r)

    def test_a_forged_document_is_never_asked(self):
        self.assertEqual(route([doc(outcome="forged", need=None)])["lane"], split.HOLD_LANE)

    def test_the_gates_account_hold_need_is_never_asked(self):
        r = route([doc(kind="catalog_page", doc_type="credits_page", need=gate.NEED_ACCOUNT)])
        self.assertEqual(r["lane"], split.HOLD_LANE)
        self.assertNotIn("ask", r)

    def test_a_record_kind_waits_on_the_bar(self):
        r = route([doc(kind="pro_portal")])
        self.assertEqual(r["lane"], split.RECORD)
        self.assertNotIn("ask", r)

    def test_a_record_extraction_type_waits_on_the_bar_as_the_gate_reads_it(self):
        self.assertEqual(route([doc(kind="unknown", doc_type="contract")])["lane"], split.RECORD)

    def test_one_record_document_among_others_waits_on_the_bar(self):
        self.assertEqual(route([doc(doc_type="credits_page"), doc(kind="invoice")])["lane"], split.RECORD)

    def test_a_credits_page_gets_the_gates_own_need_in_the_approved_words(self):
        r = route([doc(kind="catalog_page", doc_type="credits_page", need=gate.NEED_DASHBOARD)])
        self.assertEqual(r["lane"], split.ASK)
        self.assertEqual(r["need"], gate.NEED_DASHBOARD)
        self.assertEqual(r["ask"], proof_reviewer.ASK_LINES[gate.NEED_DASHBOARD])

    def test_the_most_recorded_need_is_the_one_ask(self):
        r = route([doc(need=gate.NEED_ISSUER_DOMAIN), doc(need=gate.NEED_ISSUER_DOMAIN), doc(need=gate.NEED_DASHBOARD)])
        self.assertEqual(r["need"], gate.NEED_ISSUER_DOMAIN)

    def test_a_tie_prefers_the_document_of_record(self):
        r = route([doc(need=gate.NEED_DASHBOARD), doc(need=gate.NEED_COUNTERPARTY)])
        self.assertEqual(r["need"], gate.NEED_COUNTERPARTY)

    def test_an_unread_document_gets_the_gates_readable_copy_ask(self):
        r = route([doc(outcome="unknown", need=None)])
        self.assertEqual(r["lane"], split.ASK)
        self.assertEqual(r["need"], gate.NEED_READABLE)
        self.assertEqual(r["ask"], proof_reviewer.ASK_LINES[gate.NEED_READABLE])

    def test_every_need_the_gate_can_record_has_approved_words(self):
        for need in split.NEED_ORDER:
            self.assertIn(need, proof_reviewer.ASK_LINES)

    def test_the_gate_record_lists_are_the_ones_the_blocker_reads(self):
        self.assertIn("pro_portal", gate.RECORD_H3_KINDS)
        self.assertIn("pro_registration", gate.RECORD_DOC_TYPES)
        self.assertNotIn("credits_page", gate.RECORD_DOC_TYPES)
        self.assertNotIn("dashboard_screenshot", gate.RECORD_DOC_TYPES)


if __name__ == "__main__":
    unittest.main()
