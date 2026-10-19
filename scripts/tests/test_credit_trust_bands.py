#!/usr/bin/env python3
"""The credit-trust band table mirror (scripts/credit_trust) stays byte-identical to IDP's.

Stdlib unittest, no network. Run:
    python3 scripts/tests/test_credit_trust_bands.py
Set IDP_CHECKOUT=<industry-data-processing checkout> to also compare against the live source.
"""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import hashlib
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_trust import bands  # noqa: E402


class MirrorPinTest(unittest.TestCase):
    def test_copy_matches_the_pinned_idp_sha(self):
        self.assertEqual(
            bands.BANDS_SHA256,
            bands.IDP_SOURCE_SHA256,
            "scripts/credit_trust/credit_trust_bands.json changed without updating the IDP pin: "
            "copy IDP's common/credit_trust_bands.json verbatim and update IDP_SOURCE_SHA256/COMMIT",
        )

    def test_matches_an_idp_checkout_when_one_is_given(self):
        checkout = os.environ.get("IDP_CHECKOUT")
        if not checkout:
            self.skipTest("IDP_CHECKOUT not set (CI has no industry-data-processing checkout)")
        source = Path(checkout) / bands.IDP_SOURCE_PATH
        self.assertTrue(source.is_file(), f"missing {source}")
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), bands.BANDS_SHA256)


class TableShapeTest(unittest.TestCase):
    """What hydra's readers rely on (T07 runner, T09 digest, Caroline case tools)."""

    def test_bands_are_disjoint_and_proof_rules_are_band_b(self):
        b, c = set(bands.BANDS["band_b_rules"]), set(bands.BANDS["band_c_rules"])
        self.assertFalse(b & c)
        proof = set(bands.BANDS["proof_required"]["rules"])
        self.assertTrue(proof <= b, "a proof-required rule must be band B (the claimant can answer it)")
        self.assertFalse(proof & c)

    def test_every_hold_rule_is_review_or_reject_and_has_a_sentence(self):
        for name in bands.hold_rule_names():
            if name == "validation_error":
                continue
            self.assertTrue(name.startswith(("review_", "reject_")), name)
        for name in bands.hold_rule_names() | set(bands.BANDS["band_c_error_keys"]):
            sentence = bands.hold_reason_sentence(name)
            self.assertTrue(sentence and sentence.endswith("."), name)

    def test_review_prefix_hold_threshold_matches_core(self):
        # core-backend agentApprovalGuard and hydra treat any review_* score >= 30 as a hold.
        self.assertEqual(bands.BANDS["approve_threshold"], 30.0)
        self.assertEqual(bands.hold_reason_sentence("no_such_code"), None)


if __name__ == "__main__":
    unittest.main()
