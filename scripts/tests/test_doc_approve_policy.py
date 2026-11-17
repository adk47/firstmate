"""The doc-approve class's registry entry and the code must not drift.

[key=doc-approval-doctrine]: Fable ruled the NUMBERS (T0/T1, popularity < 60, 50/day, provisional
7d, the seven gates). They live in two places by design - the registry entry that t01b's executor
reads, and `credit_review/doc_approve.py` that enforces them - so this test pins them equal. A
silently raised cap, a dropped gate, or an entry that loses its approver is a test failure.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import decide, doc_approve  # noqa: E402

REGISTRY = Path(__file__).resolve().parents[2] / "policies" / "credit-approval-automation.json"


class DocApprovePolicy(unittest.TestCase):
    def setUp(self) -> None:
        self.entry = json.loads(REGISTRY.read_text(encoding="utf-8"))["automations"][decide.DOC_AUTOMATION]

    def test_the_entry_keeps_the_ruling_it_cites(self):
        """The ruling travels with the row, shadowed or armed. R22 is the ruling that governs it."""
        self.assertIn("doc-approval-doctrine", self.entry["approval_ref"])
        self.assertIn("R22", self.entry["approval_ref"])

    def test_the_entry_ships_SHADOW_and_arming_is_the_only_switch(self):
        """Shadow first (firstmate 2026-11-04 18:32Z; Fable's arming word is the gate).

        The row is registered so t01b's executor and decide.py read ONE description of the
        class, but `approved` is false: decide.doc_class_approved() then refuses, so the
        code writes no doc_verified approval and the class's alerts stay dormant. Flipping
        this flag is the whole arming act, and it must always come with who said yes and
        where - an armed row with no named approver is the failure this pins.
        """
        self.assertIs(self.entry["approved"], False)
        self.assertIsNone(self.entry["approved_by"])
        self.assertIn("SHADOW", self.entry["status_note"])

    def test_an_armed_row_must_name_who_said_yes_and_where(self):
        """If it is armed, the approval is auditable; if it is not, the code must refuse."""
        armed = bool(self.entry["approved"])
        self.assertEqual(armed, bool(self.entry["approved_by"]))
        # the ruling is cited whether or not the row is armed - that is what lets a reviewer
        # see WHY it exists before anyone turns it on.
        self.assertIn("doc-approval-doctrine", self.entry["approval_ref"])
        # and the code reads exactly this flag: whatever the file says, the class turns on
        # only for approved=true + a named approver + a citation.
        self.assertEqual(armed, decide.doc_class_approved(REGISTRY)[0])

    def test_the_wider_automation_stays_unapproved_so_only_the_doc_class_writes(self):
        automations = json.loads(REGISTRY.read_text(encoding="utf-8"))["automations"]
        self.assertIs(automations[decide.AUTOMATION]["approved"], False)

    def test_the_numbers_match_the_code(self):
        cls = self.entry["doc_class"]
        # R22 guard 7: the cap is in USERS, with per-user AND per-profile bounds under it.
        self.assertEqual(cls["cap_unit"], "users")
        self.assertEqual(cls["daily_cap"], doc_approve.DAILY_USER_CAP)
        self.assertEqual(cls["per_user_daily_max"], doc_approve.PER_USER_DAILY_MAX)
        self.assertEqual(cls["per_profile_daily_max"], doc_approve.PER_PROFILE_DAILY_MAX)
        self.assertEqual(cls["scope"], doc_approve.SCOPE)
        self.assertEqual(decide.DOC_AUTOMATION, doc_approve.SCOPE)
        self.assertEqual(cls["order"], "paid_first_oldest")
        self.assertIs(cls["shadow"], True)
        self.assertEqual(cls["provisional_days"], doc_approve.PROVISIONAL_DAYS)
        self.assertEqual(cls["max_popularity_exclusive"], doc_approve.TIER_MAX_POPULARITY)
        self.assertEqual(cls["verdict_version"], doc_approve.VERDICT_VERSION)
        self.assertEqual(cls["evidence_kind"], doc_approve.DOC_KIND)
        self.assertEqual(sorted(cls["gates"]), sorted(doc_approve.GATES))

    def test_guard6_says_the_provisional_window_is_never_lowered(self):
        cls = self.entry["doc_class"]
        self.assertIs(cls["provisional_never_lowered"], True)
        self.assertGreaterEqual(doc_approve.PROVISIONAL_DAYS, doc_approve.PROVISIONAL_MIN_DAYS)

    def test_guard8_declares_the_audit_the_freeze_and_the_notice(self):
        cls = self.entry["doc_class"]
        self.assertEqual(cls["audit"]["days"], doc_approve.AUDIT_DAYS)
        self.assertEqual(cls["audit"]["coverage"], "100%")
        self.assertIn("single reversal", cls["audit"]["auto_freeze_on"])
        # the registry names the PRODUCTION path, so compare against the default rather than the live
        # constant: FREEZE_PATH is env-overridable and a test run may point it at a tmpdir.
        self.assertEqual(cls["audit"]["freeze_marker"], doc_approve.DEFAULT_FREEZE_PATH)
        self.assertIn("approval notice", cls["requester_notice"])

    def test_the_class_is_t0_t1_only(self):
        self.assertEqual(self.entry["doc_class"]["tiers"], ["T0", "T1"])

    def test_an_anchor_row_is_not_claimed_before_the_ddl_lands(self):
        # Fable: the approval is ALSO a credit_anchor_records row (kind proof_verification) once that
        # DDL lands. Claiming it early would be a false record.
        self.assertEqual(self.entry["doc_class"]["anchor_row"]["available"], doc_approve.ANCHOR_ROWS_AVAILABLE)

    def test_the_kill_switch_matches_the_code(self):
        self.assertEqual(self.entry["doc_class"]["kill_switch"], str(decide.DOC_APPROVE_KILL))


class R5GoRetirement(unittest.TestCase):
    """The r5 GO is retired by name (captain 2026-11-14), and the retirement is a record, not a switch."""

    def test_the_retirement_arms_nothing(self):
        registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
        doc = registry["automations"][decide.DOC_AUTOMATION]
        self.assertIs(doc["approved"], False)
        self.assertIs(doc["doc_class"]["shadow"], True)
        close = json.loads((REGISTRY.parent / "credit-validator-reject-close.json").read_text(encoding="utf-8"))
        self.assertIs(close["apply_enabled"], False)
        self.assertIsNone(close["approved_by"])


    def test_the_class_carries_the_approve_filter_and_stays_in_shadow(self):
        """[key=approve-filter-two-blocks] The same keys as the tray executor's block, read by the same floor.
        Adding the filter arms nothing: `shadow` stays true and `approved` stays false."""
        from credit_review import fable_executor
        entry = json.loads(REGISTRY.read_text(encoding="utf-8"))["automations"][decide.DOC_AUTOMATION]
        cls = entry["doc_class"]
        self.assertIs(cls["shadow"], True)
        self.assertIs(entry["approved"], False)
        self.assertEqual(set(cls["apply_filter"]), set(fable_executor.APPLY_FILTER_KEYS))
        self.assertEqual(fable_executor.apply_filter_floor(cls["apply_filter"]), (cls["apply_filter"], ""))
        self.assertEqual(decide.doc_class_apply_filter(REGISTRY), cls["apply_filter"])
        executor = json.loads(REGISTRY.read_text())["automations"][fable_executor.AUTOMATION_ID]
        self.assertEqual(cls["apply_filter"], executor["apply_filter"])


if __name__ == "__main__":
    unittest.main()
