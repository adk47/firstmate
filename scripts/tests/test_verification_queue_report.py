#!/usr/bin/env python3
"""scripts/verification-queue-report.py — the bucket classifier, the renderer and the
partition invariant the captain's every-30-minutes DM depends on.

Stdlib only, no network, no node-8: the script is imported as a module and fed fixtures.
The live measurement is the script's own `--selftest`, which this suite also runs, so a
cron regression that only changes the fixtures still trips here.

Why these cases: the bucket order is the whole semantic. "Not touched by us at all" must
mean literally nothing was ever written for that user (it is the bucket the captain acts
on), and a row that a person or the fraud watchlist owns must never also read as "waiting
on the user" — otherwise the DM reports work as going out when our own gate is what is
holding it.
"""
import importlib.util
import ast
import collections
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "verification-queue-report.py")
spec = importlib.util.spec_from_file_location("vqr", SCRIPT)
vqr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vqr)
sys.path.insert(0, os.path.join(REPO, "scripts"))
from credit_verify.docverify import VERSION  # noqa: E402

NOW = datetime(2026, 10, 26, 21, 0, tzinfo=timezone.utc)


def facts(**over):
    base = {"asked": {}, "messaged": {}, "latest": {}, "decided": set(),
            "replied": set(), "proof_waiting": set(), "muted": {}, "flagged": {},
            "claim_notes": {}, "claim_proofs": {}, "claim_replied": set(),
            "claim_muted": {}, "claim_flagged": {}, "first_proof_hold": {},
            "first_deadend": {}, "support_contacts": set()}
    base.update(over)
    return base


CREDIT = {"paid": False, "n": 1, "oldest": "2026-01-01 00:00:00.000000 UTC",
          "newest": "2026-01-01 00:00:00.000000 UTC",
          "core_ask": False, "core_reply": False, "needs_docs": True}
CLAIM = {"paid": False, "n": 1, "oldest": "2026-01-01 00:00:00.000000 UTC",
         "profiles": ["p1"], "claims": ["11"]}


class OpenStatusIndexTests(unittest.TestCase):
    """[key=open-status-index] The credits population must be read through the POSITIVE status
    list. `status NOT IN ('approved','rejected')` is not pushed down, so it scans the whole
    credit_requests table and dies on the session's 90s cap. On 2026-11-12 that is exactly what
    the reporter's credits query did ("Query exceeded the maximum execution time limit of
    90.00s"), which aborted the whole report and left last.json at 2026-11-10 12:01Z - so the
    untold count could not be measured at all."""

    def test_the_credits_query_filters_on_the_open_statuses_not_the_closed_ones(self):
        seen = []
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        self.addCleanup(lambda: sys.path.remove(os.path.join(REPO, "scripts")))

        def fake_trino(sql, *a, **kw):
            if "TABLE(postgresql_core.system.query" in sql:
                return [["approved"], ["rejected"], ["unverified"], ["processing"],
                        ["user_verification_needed"]]
            seen.append(sql)
            return []

        with mock.patch.object(vqr, "trino", fake_trino):
            vqr.credit_rows()
        self.assertTrue(seen, "credit_rows made no query")
        sql = seen[0]
        self.assertIn("cr.status in ('unverified', 'processing', 'user_verification_needed')", sql)
        # the negated form is the defect: it cannot use the status index
        self.assertNotIn("status not in (", sql.replace("\n", " ").lower())

    def test_an_unknown_status_refuses_the_report_instead_of_shrinking_it(self):
        """A positive list is only equal to "not approved/rejected" while every status is known. If core adds one,
        the population would silently shrink and the untold count would read lower while the work is still there."""
        def fake_trino(sql, *a, **kw):
            if "TABLE(postgresql_core.system.query" in sql:
                return [["approved"], ["rejected"], ["unverified"], ["processing"],
                        ["user_verification_needed"], ["review_pending"]]
            return []

        sys.path.insert(0, os.path.join(REPO, "scripts"))
        self.addCleanup(lambda: sys.path.remove(os.path.join(REPO, "scripts")))
        with mock.patch.object(vqr, "trino", fake_trino):
            with self.assertRaises(Exception) as ctx:
                vqr.credit_rows()
        self.assertIn("review_pending", str(ctx.exception))

    def test_a_known_status_set_lets_the_report_through(self):
        seen = []
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        self.addCleanup(lambda: sys.path.remove(os.path.join(REPO, "scripts")))

        def fake_trino(sql, *a, **kw):
            if "TABLE(postgresql_core.system.query" in sql:
                return [["approved"], ["rejected"], ["unverified"], ["processing"],
                        ["user_verification_needed"]]
            seen.append(sql)
            return []

        with mock.patch.object(vqr, "trino", fake_trino):
            vqr.credit_rows()
        self.assertTrue(seen, "the guard refused a known status set")

    def test_the_open_statuses_agree_with_the_send_path(self):
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        try:
            from credit_review import owing_proof
        finally:
            sys.path.pop(0)
        self.assertEqual(tuple(vqr.OPEN_STATUSES), tuple(owing_proof.OPEN_STATUSES))
        self.assertEqual(tuple(vqr.CLOSED_STATUSES), tuple(owing_proof.CLOSED_STATUSES))


class CreditBuckets(unittest.TestCase):
    def test_nothing_written_anywhere_is_not_touched(self):
        self.assertEqual(vqr.classify_credit(7, facts(), CREDIT, frozenset()), "untouched")

    def test_an_ask_note_alone_makes_the_user_told(self):
        self.assertEqual(vqr.classify_credit(1, facts(asked={1: "2026-10-01"}), CREDIT,
                                            frozenset()), "told")

    def test_a_core_notice_also_counts_as_told(self):
        self.assertEqual(vqr.classify_credit(1, facts(), dict(CREDIT, core_ask=True),
                                            frozenset()), "told")

    def test_a_status_note_is_a_message_so_the_user_is_not_untouched(self):
        # Not asked for documents, but we did message them: the honest bucket is
        # "needs documents - user NOT told", never "not touched by us at all".
        self.assertEqual(vqr.classify_credit(2, facts(messaged={2: "2026-10-01"}), CREDIT,
                                            frozenset()), "not_told")

    def test_a_hold_decision_without_a_message_is_not_told(self):
        f = facts(latest={3: {"decision": "hold", "reason": "score approval not now: no anchor",
                              "doc_required": 0, "at": ""}}, decided={3})
        self.assertEqual(vqr.classify_credit(3, f, CREDIT, frozenset()), "not_told")

    def test_watchlist_wins_over_everything(self):
        f = facts(asked={4: "2026-10-01"})
        self.assertEqual(vqr.classify_credit(4, f, CREDIT, frozenset({4})), "watch")

    def test_a_document_on_file_the_reader_dated_after_the_request_is_docs_in(self):
        # Reason 5's defect: the decider's proof feed carries no timestamp, so this hold used to be
        # counted with a person. The date is not missing from the box - the returned-document
        # reader records every date it reads out of the file - so the hold is decided on the
        # document's own date, exactly like a dated proof tag (5b).
        f = facts(asked={5: "2026-10-01"},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": True, "date": date(2026, 10, 20)}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "docs_in")

    def test_a_document_on_file_the_reader_dated_before_the_request_is_not_proof(self):
        # 5c's rule, applied to the document the reader actually read: an old document is not
        # proof of a current credit, so the user is owed an ask for a current one.
        f = facts(decided={5},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": True, "date": date(2025, 12, 1)}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "not_told")

    def test_an_old_document_does_not_re_ask_a_user_who_was_already_asked(self):
        # The ask lane is not a licence to ask twice: a user who already got an ask is `told`,
        # whatever their document says. Returning `not_told` from the document reading would
        # relabel them "needs documents - user NOT told" and put them back in the ask queue.
        f = facts(asked={5: "2026-10-01"},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": True, "date": date(2025, 12, 1)}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "told")

    def test_a_document_dated_the_same_day_as_the_request_counts_as_returned(self):
        # Asking someone for a document they may have just sent is the one error this lane must
        # never make, so the same day reads as returned, not as an old document.
        f = facts(asked={5: "2026-10-01"},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": True, "date": date(2026, 1, 1)}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "docs_in")

    def test_a_document_the_reader_read_with_no_date_in_it_is_an_ask_for_a_dated_copy(self):
        # The captain's order: the AI dates and judges the document; if it truly cannot be dated,
        # ASK for a dated copy. Read and undated is an ask we owe, never a person.
        f = facts(decided={5},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": True, "date": None}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "not_told")

    def test_a_document_the_reader_has_not_opened_is_ours_to_look_at(self):
        # Not read yet is work WE owe: asking a customer for a copy of a document we have not
        # opened is not an ask.
        f = facts(asked={5: "2026-10-01"},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": False, "date": None}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "docs_in")

    def test_a_document_the_reader_can_never_look_at_is_the_ask_lane(self):
        # A proof-on-file hold can rest on a document the returned-document reader will never
        # select (a core-verification-backed proof, or a filing it does not take). There is no
        # look to owe, so it is not `docs_in` forever: it is the ask lane.
        f = facts(decided={5},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": False, "read": False, "date": None}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "not_told")

    def test_a_stage2_hold_is_not_this_lane(self):
        # `proof on file: stage 2 judged the document` is a DIFFERENT hold: that user was already
        # asked through a campaign. Reading it as this lane would either ask them again (old or
        # undated document) or page a breach nobody owes (current document).
        f = facts(latest={5: {"decision": "hold",
                              "reason": "proof on file: stage 2 judged the document",
                              "doc_required": 0, "at": ""}},
                  doc_dates={5: {"filed": True, "read": True, "date": date(2025, 12, 1)}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "untouched")

    def test_an_unmeasured_document_date_keeps_the_hold_with_a_person(self):
        # The reader's store could not be read: an unmeasured date is never read as "undated"
        # (that would ask a customer for a copy of a document we simply did not open), and never
        # as "returned" either. It keeps the old reading.
        f = facts(asked={5: "2026-10-01"},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates=None)
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "human")

    def test_a_support_contact_does_not_outrank_the_document_reading(self):
        # #2108 (captain 2026-11-16): having emailed support@ is not work either, so it no longer
        # takes the row off the document reading. The document is read and dated after the
        # request, so the row is ours to look at - not a person's.
        f = facts(latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 1, "at": ""}},
                  support_contacts={5}, decided={5},
                  doc_dates={5: {"filed": True, "read": True, "date": date(2026, 10, 20)}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "docs_in")

    def test_a_per_role_split_with_no_document_is_not_a_document_on_file(self):
        # captain 2026-11-06: a per-role split has NO document at all (the catalog proved some roles,
        # the rest are owed an ask). Counting it as "a document is already on file" hides the very
        # population the captain ordered asked.
        f = facts(latest={8: {"decision": "approve_partial",
                              "reason": "per-role split: approved Mixing; pending Mastering",
                              "doc_required": 0, "at": "", "proof_id": ""}})
        self.assertEqual(vqr.classify_credit(8, f, CREDIT, frozenset()), "untouched")

    def test_a_per_role_split_held_for_a_document_on_file_is_dated_like_any_other(self):
        # F4: filter_support holds a PARTIAL row for a document on file by PREPENDING the hold sentence and
        # keeping the decision, so the row carries no proof_id. It is still a document on file, so it
        # is dated by the reader's own extraction like every other one.
        f = facts(latest={10: {"decision": "approve_partial",
                               "reason": "proof on file: human review (a document is already on file; never ask again)"
                                         " | per-role split: approved Mixing; pending Mastering",
                               "doc_required": 0, "at": "", "proof_id": ""}},
                  doc_dates={10: {"filed": True, "read": True, "date": date(2026, 10, 20)}})
        self.assertEqual(vqr.classify_credit(10, f, CREDIT, frozenset()), "docs_in")

    def test_a_per_role_split_with_a_document_is_dated_like_any_other(self):
        f = facts(decided={9},
                  latest={9: {"decision": "approve_partial",
                              "reason": "proof on file: dv-4 verified document dv-4:sha:1 proves Mixing",
                              "doc_required": 0, "at": "", "proof_id": "dv-4:sha:1"}},
                  doc_dates={9: {"filed": True, "read": True, "date": date(2025, 12, 1)}})
        self.assertEqual(vqr.classify_credit(9, f, CREDIT, frozenset()), "not_told")

    def test_a_document_dated_after_the_request_is_docs_in(self):
        f = facts(messaged={6: ""}, proof_waiting={6: "2026-10-27T10:00:00Z"})
        self.assertEqual(vqr.classify_credit(6, f, CREDIT, frozenset()), "docs_in")

    def test_a_document_dated_before_the_request_counts_for_nothing(self):
        f = facts(messaged={6: ""}, proof_waiting={6: "2025-12-01T10:00:00Z"})
        self.assertNotEqual(vqr.classify_credit(6, f, CREDIT, frozenset()), "docs_in")

    def test_the_bound_is_the_newest_open_request_not_the_oldest(self):
        # a doc between an old and a recent request cannot be shown to serve the recent one,
        # so it does not count (under-count on purpose: quieter, never louder)
        c = dict(CREDIT, oldest="2026-01-01 00:00:00.000000 UTC",
                 newest="2026-10-01 00:00:00.000000 UTC")
        f = facts(messaged={6: ""}, proof_waiting={6: "2026-09-01T10:00:00Z"})
        self.assertNotEqual(vqr.classify_credit(6, f, c, frozenset()), "docs_in")

    def test_a_core_response_newer_than_its_request_is_docs_in(self):
        f = facts()
        c = dict(CREDIT, reply_at="2026-10-26T00:00:00Z", core_reply=True)
        self.assertEqual(vqr.classify_credit(7, f, c, frozenset()), "docs_in")

    def test_a_reply_with_attachments_still_waiting_is_ours_to_look_at(self):
        # dated AFTER the request's oldest open row (CREDIT.oldest is 2026-01-01)
        f = facts(messaged={6: ""}, proof_waiting={6: "2026-10-26T00:00:00Z"})
        self.assertEqual(vqr.classify_credit(6, f, CREDIT, frozenset()), "docs_in")

    def test_core_recording_a_proof_response_is_ours_to_look_at(self):
        self.assertEqual(vqr.classify_credit(6, facts(), dict(CREDIT, core_reply=True),
                                            frozenset()), "docs_in")

    def test_a_support_write_is_our_own_ask_not_a_person(self):
        # decide.py's REQUEST SUPPORT is our ASK (status user_verification_needed + the Knock
        # "more info needed" notice), not a support ticket. No person owns the row.
        f = facts(latest={7: {"decision": "support", "reason": "no trusted web evidence",
                              "doc_required": 1, "at": ""}}, decided={7})
        bucket = vqr.classify_credit(7, f, CREDIT, frozenset())
        self.assertNotEqual(bucket, "human")
        self.assertEqual(bucket, "not_told", "ask never landed = we owe the tell")

    def test_a_support_write_core_told_the_user_is_waiting_on_the_user(self):
        # the same ledger verdict once core carries the notice (status user_verification_needed
        # + proofRequest.noticeSentAt): the requester was told, so the ball is in their court.
        f = facts(latest={7: {"decision": "support", "reason": "no trusted web evidence",
                              "doc_required": 1, "at": ""}}, decided={7})
        bucket = vqr.classify_credit(7, f, dict(CREDIT, core_ask=True), frozenset())
        self.assertNotEqual(bucket, "human")
        self.assertEqual(bucket, "told")

    def test_human_review_holds_are_with_a_person(self):
        for reason in ("support already requested for this credit once: never re-ask",):
            f = facts(latest={8: {"decision": "hold", "reason": reason,
                                  "doc_required": 0, "at": ""}}, decided={8})
            self.assertEqual(vqr.classify_credit(8, f, CREDIT, frozenset()), "human", reason)

    def test_a_legacy_support_at_hold_row_is_not_with_a_person(self):
        # reason 6 of the human bucket (captain 2026-11-16: "the only people involved should be
        # the requester. our AI should handle everything else"). The ledger is append-only, so the
        # pre-#1992 sentences are still on file; the row is the AI's to move, and the decider
        # already asks these users in the verify notes (#2090).
        f = facts(latest={8: {"decision": "hold",
                              "reason": "emailed support@ in the last 90 days: human review, never asked",
                              "doc_required": 0, "at": ""}}, decided={8})
        self.assertEqual(vqr.classify_credit(8, f, CREDIT, frozenset()), "not_told")

    def test_a_user_who_emailed_support_is_not_with_a_person(self):
        # the proof feed's 90-day contact list names a user, and nobody ever wrote to them: the
        # honest bucket is the one the ask ladder works from, never a human.
        self.assertEqual(vqr.classify_credit(9, facts(support_contacts={9}), CREDIT,
                                            frozenset()), "untouched")

    def test_a_user_who_emailed_support_and_was_asked_is_told(self):
        # and once an ask went out they are waiting on the user, not on a person.
        f = facts(support_contacts={9}, asked={9: "2026-10-01"})
        self.assertEqual(vqr.classify_credit(9, f, CREDIT, frozenset()), "told")

    def test_a_flagged_refusal_hold_is_with_a_person(self):
        self.assertEqual(vqr.classify_credit(10, facts(flagged={10: "2026-10-01"}), CREDIT,
                                            frozenset()), "human")

    def test_a_messaging_hold_mutes_the_user(self):
        self.assertEqual(vqr.classify_credit(11, facts(muted={11: "2030-01-01T00:00:00Z"}),
                                            CREDIT, frozenset()), "muted")

    def test_a_human_hold_beats_a_mute(self):
        f = facts(muted={12: "2030-01-01T00:00:00Z"}, flagged={12: "2026-10-01"})
        self.assertEqual(vqr.classify_credit(12, f, CREDIT, frozenset()), "human")


class ClaimBuckets(unittest.TestCase):
    def test_a_claim_note_is_the_only_thing_that_makes_a_claim_told(self):
        f = facts(claim_notes={"claim-11": {"at": "2026-10-26"}})
        self.assertEqual(vqr.classify_claim(1, f, CLAIM, frozenset(), frozenset()), "told")

    def test_a_credit_decision_never_makes_a_claim_look_touched(self):
        # A credit `support` write says nothing about a profile claim: the claim is still
        # untouched, and reporting otherwise would hide real claim backlog.
        f = facts(latest={2: {"decision": "support", "reason": "x", "doc_required": 1, "at": ""}},
                  support={2}, decided={2}, asked={2: "2026-10-01"}, messaged={2: "2026-10-01"})
        self.assertEqual(vqr.classify_claim(2, f, CLAIM, frozenset(), frozenset()), "untouched")

    def test_the_watchlist_matches_a_claim_by_profile(self):
        self.assertEqual(vqr.classify_claim(3, facts(), CLAIM, frozenset(), frozenset({"p1"})),
                         "watch")

    def test_a_claimant_who_emailed_support_is_with_a_person(self):
        self.assertEqual(
            vqr.classify_claim(4, facts(support_contacts={4}), CLAIM, frozenset(), frozenset()),
            "human")


class Feeds(unittest.TestCase):
    """The two local feeds, read from the repo's own files.

    A duplicated/shadowed top-level definition is not hypothetical: an earlier revision
    of watchlist_ids() parsed top-level `user_ids` keys that the watchlist does not have,
    while a second copy of the function read the real `entries` shape. Python silently
    used the LAST one, every fraud bucket read 0, and the DM would have told the captain
    that nothing is on the watchlist. Both tests below exist to make that loud."""

    def test_no_top_level_name_is_defined_twice(self):
        with open(SCRIPT) as fh:
            tree = ast.parse(fh.read())
        names = [n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))]
        dupes = [n for n, c in collections.Counter(names).items() if c > 1]
        self.assertEqual(dupes, [], f"defined more than once: {dupes}")

    def test_the_watchlist_parser_reads_the_committed_file(self):
        old, vqr.WATCHLIST = vqr.WATCHLIST, os.path.join(REPO, "policies", "fraud-watchlist.json")
        try:
            users, profiles = vqr.watchlist_ids()
        finally:
            vqr.WATCHLIST = old
        self.assertTrue(users, "no user ids parsed from policies/fraud-watchlist.json")
        self.assertTrue(profiles, "no profile ids parsed from policies/fraud-watchlist.json")
        self.assertTrue(all(isinstance(u, int) for u in users))

    def test_the_proof_feed_parser_reads_the_support_contact_list(self):
        payload = {"generated_at": "2026-10-26T00:00:00Z", "users": 3,
                   "entries": [], "gmail_contacts_90d": {"user_ids": [11, "12", "x"]}}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(payload, f)
        old, vqr.PROOF = vqr.PROOF, f.name
        try:
            contacts, meta = vqr.proof_feed()
        finally:
            vqr.PROOF = old
            os.unlink(f.name)
        self.assertEqual(contacts, frozenset({11, 12}))
        self.assertEqual(meta["support_contacts_90d"], 2)


class BacklogSentinel(unittest.TestCase):
    """The captain's 21:05Z rule: nothing may sit waiting on us past its SLA from the
    21:00Z line onward. The three-way split (breach / legacy / not yet due) is the whole
    contract, and the dedupe is what makes "DM once per new breach" survivable."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)   # 3 days after the baseline

    def evaluate(self, bucket, items, unmeasured=()):
        found = {"items": {bucket: items}, "unmeasured": set(unmeasured)}
        return vqr.sentinel_evaluate(found, self.NOW)

    def test_an_item_entered_after_the_line_and_past_its_sla_is_a_breach(self):
        ev = self.evaluate("credits_untouched", [("user:1", "2026-10-27T00:00:00Z")])
        self.assertEqual(len(ev["credits_untouched"]["breaches"]), 1)
        self.assertEqual(ev["credits_untouched"]["legacy"], 0)

    def test_an_item_that_was_healthy_at_the_baseline_but_is_overdue_now_is_a_breach(self):
        # QA @dc108d7: a decider hold entered 20:45Z with a 1h SLA was healthy at the
        # 21:00Z baseline and only became overdue at 21:45Z. That is a NEW breach the
        # captain must hear about, not old backlog.
        ev = self.evaluate("fable_decider", [("user:1", "2026-10-26T20:45:00Z")])
        self.assertEqual(len(ev["fable_decider"]["breaches"]), 1)
        self.assertEqual(ev["fable_decider"]["legacy"], 0)

    def test_an_item_already_overdue_at_the_baseline_is_legacy(self):
        ev = self.evaluate("fable_decider", [("user:1", "2026-10-26T19:30:00Z")])
        self.assertEqual(ev["fable_decider"]["breaches"], [])
        self.assertEqual(ev["fable_decider"]["legacy"], 1)

    def test_an_item_entered_before_the_line_is_legacy_not_a_breach(self):
        ev = self.evaluate("credits_untouched", [("user:1", "2026-10-01T00:00:00Z")])
        self.assertEqual(ev["credits_untouched"]["breaches"], [])
        self.assertEqual(ev["credits_untouched"]["legacy"], 1)

    def test_an_item_inside_its_sla_is_neither(self):
        ev = self.evaluate("credits_untouched", [("user:1", "2026-10-29T00:00:00Z")])
        self.assertEqual(ev["credits_untouched"]["breaches"], [])
        self.assertEqual(ev["credits_untouched"]["legacy"], 0)

    def test_the_sla_is_per_bucket(self):
        # 5h old: past the 4h Intercom SLA, inside the 24h credits SLA.
        old = "2026-10-29T07:00:00Z"
        ev = vqr.sentinel_evaluate({"items": {"intercom_customer_last": [("conv:1", old)],
                                              "credits_untouched": [("user:1", old)]},
                                    "unmeasured": set()}, self.NOW)
        self.assertEqual(len(ev["intercom_customer_last"]["breaches"]), 1)
        self.assertEqual(ev["credits_untouched"]["breaches"], [])

    def test_an_undateable_item_is_counted_as_neither(self):
        ev = self.evaluate("credits_untouched", [("user:1", ""), ("user:2", "not-a-date")])
        self.assertEqual(ev["credits_untouched"]["breaches"], [])
        self.assertEqual(ev["credits_untouched"]["legacy"], 0)
        self.assertEqual(ev["credits_untouched"]["undateable"], 2)

    def test_a_bucket_with_no_source_is_unmeasured_never_zero(self):
        ev = self.evaluate("support_unanswered", [], unmeasured={"support_unanswered"})
        self.assertTrue(ev["support_unanswered"]["unmeasured"])

    def test_every_bucket_in_the_captains_list_is_covered(self):
        keys = [k for k, _, _, _ in vqr.SENTINEL_BUCKETS]
        self.assertEqual(keys, ["credits_untouched", "credits_docs_in", "claims_untouched",
                                "claims_docs_in", "merges_waiting", "intercom_customer_last",
                                "support_unanswered", "fable_decider"])
        self.assertTrue(all(lane and sla > 0 for _, _, lane, sla in vqr.SENTINEL_BUCKETS))

    def test_the_untouched_claims_owner_is_a_seat_that_exists(self):
        # claim-untouched-1050-r1: claim-lane-resume-c2 exists in no home, so the bucket was orphaned
        owners = {k: lane for k, _, lane, _ in vqr.SENTINEL_BUCKETS}
        self.assertIn("claim-untouched-1050-r1", owners["claims_untouched"])
        self.assertNotIn("claim-lane-resume-c2", owners["claims_untouched"])

    def page(self, items, prev=None):
        msgs, state, page_map = vqr.sentinel_page(
            self.evaluate("credits_untouched", items), prev, self.NOW, False)
        # a page that Slack confirmed becomes part of the delivery ledger
        state = vqr.record_paged(state, page_map, [True] * len(page_map))
        return msgs, state

    def test_a_new_breach_pages_once_with_the_captains_wording(self):
        msgs, state = self.page([("user:1", "2026-10-27T00:00:00Z")])
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG FORMING: credits nobody has touched 1 items"))
        self.assertIn("owner verify-ask-wiring-h2", msgs[0])
        self.assertEqual(len(state["breaches"][0]["items"]), 1)

    def test_the_same_breach_does_not_page_again(self):
        _, state = self.page([("user:1", "2026-10-27T00:00:00Z")])
        msgs, _ = self.page([("user:1", "2026-10-27T00:00:00Z")], state)
        self.assertEqual(msgs, [])

    def test_a_second_item_pages_even_though_the_bucket_was_already_reported(self):
        _, state = self.page([("user:1", "2026-10-27T00:00:00Z")])
        msgs, _ = self.page([("user:1", "2026-10-27T00:00:00Z"),
                             ("user:2", "2026-10-28T00:00:00Z")], state)
        self.assertEqual(len(msgs), 1)
        self.assertIn("2 items", msgs[0])

    def test_an_undelivered_page_is_retried_on_the_next_tick(self):
        # QA @dc108d7: state used to be written before slack_post, so a Slack failure meant
        # the item counted as told forever and the queue rotted silently.
        msgs, state, page_map = vqr.sentinel_page(
            self.evaluate("credits_untouched", [("user:1", "2026-10-27T00:00:00Z")]),
            None, self.NOW, False)
        self.assertEqual(len(msgs), 1)
        state = vqr.record_paged(state, page_map, [False])     # Slack rejected it
        self.assertEqual(state["paged"], {})
        self.assertEqual(len(state["breaches"][0]["items"]), 1)  # still reported to firstmate
        again, _ = self.page([("user:1", "2026-10-27T00:00:00Z")], state)
        self.assertEqual(len(again), 1)                         # and paged again

    def test_a_delivered_page_is_not_repeated(self):
        _, state, page_map = vqr.sentinel_page(
            self.evaluate("credits_untouched", [("user:1", "2026-10-27T00:00:00Z")]),
            None, self.NOW, False)
        state = vqr.record_paged(state, page_map, [True])
        again, _ = self.page([("user:1", "2026-10-27T00:00:00Z")], state)
        self.assertEqual(again, [])

    def test_state_carries_what_firstmate_reads(self):
        ev = self.evaluate("credits_untouched", [("user:1", "2026-10-27T00:00:00Z")])
        _, state, _ = vqr.sentinel_page(ev, None, self.NOW, False)
        self.assertEqual(state["baseline"], vqr.BASELINE)
        self.assertIn("legacy", state)
        self.assertIn("unmeasured", state)
        self.assertIn("owner", state["breaches"][0])


class QAFindings(unittest.TestCase):
    """The three blocking findings from Fable's review of 25079636, each pinned so the
    numbers the captain reads cannot silently regress."""

    def test_an_unrelated_credit_reply_never_moves_a_claim_off_untouched(self):
        # A user replied to a CREDIT note and their CREDIT messages are muted; their claim
        # has had nothing from us at all. Reading the credit facts here would report the
        # claim as "sitting with a person"/"muted" and hide real claim backlog.
        f = facts(replied={7}, muted={7: "2030-01-01T00:00:00Z"}, flagged={7: "2026-01-01"})
        self.assertEqual(vqr.classify_claim(7, f, CLAIM, frozenset(), frozenset()), "untouched")

    def test_a_claim_scoped_reply_still_marks_the_claim(self):
        f = facts(claim_replied={7})
        self.assertEqual(vqr.classify_claim(7, f, CLAIM, frozenset(), frozenset()), "human")

    def test_returned_claim_documents_land_in_the_sentinel_lane(self):
        # QA @e878249: classify_claim had no docs_in path, so a claimant who sent documents
        # stayed "told" forever and their returned documents could never breach.
        f = facts(claim_notes={"claim-11": {"at": "2026-10-26"}},
                  claim_proofs={"claim-11": "2026-10-27T00:00:00Z"})
        self.assertEqual(vqr.classify_claim(1, f, CLAIM, frozenset(), frozenset()), "docs_in")
        found = vqr.sentinel_items({}, {1: dict(CLAIM, n=1, paid=False)}, f,
                                   lambda u, i: "untouched",
                                   lambda u, i: vqr.classify_claim(u, f, i, frozenset(), frozenset()),
                                   frozenset(), frozenset(), light=False,
                                   prev_state={"intercom": {"items": {}, "last_walk": "x"},
                                               "merges": {"items": {}}},
                                   now=datetime(2026, 10, 28, tzinfo=timezone.utc))
        self.assertEqual([i for i, _ in found["items"]["claims_docs_in"]], ["user:1"])

    def test_a_returned_claim_document_outranks_an_active_mute(self):
        # QA @0b45ef9: a claim-scoped hold must not hide a returned document from the 24h
        # review SLA lane.
        f = facts(claim_muted={7: "2030-01-01T00:00:00Z"},
                  claim_notes={"claim-11": {"at": "2026-10-26"}},
                  claim_proofs={"claim-11": "2026-10-27T00:00:00Z"})
        self.assertEqual(vqr.classify_claim(7, f, CLAIM, frozenset(), frozenset()), "docs_in")
        found = vqr.sentinel_items({}, {7: dict(CLAIM, n=1, paid=False)}, f,
                                   lambda u, i: "untouched",
                                   lambda u, i: vqr.classify_claim(u, f, i, frozenset(), frozenset()),
                                   frozenset(), frozenset(), light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=datetime(2026, 10, 28, tzinfo=timezone.utc))
        self.assertEqual([i for i, _ in found["items"]["claims_docs_in"]], ["user:7"])

    def test_a_claim_scoped_mute_still_mutes_the_claim(self):
        f = facts(claim_muted={7: "2030-01-01T00:00:00Z"})
        self.assertEqual(vqr.classify_claim(7, f, CLAIM, frozenset(), frozenset()), "muted")

    def test_paid_users_and_paid_rows_are_different_numbers(self):
        # one paid user holding two requests: 1 paid user, 2 paid requests.
        pop = {1: dict(CREDIT, n=2, paid=True, paid_n=2), 2: dict(CREDIT, n=1, paid=False, paid_n=0)}
        b = Invariants.summarize(self, pop, lambda u, i: "untouched")
        self.assertEqual(b["untouched"]["users"], 2)
        self.assertEqual(b["untouched"]["rows"], 3)
        self.assertEqual(b["untouched"]["paid_users"], 1)
        self.assertEqual(b["untouched"]["paid_rows"], 2)

    def test_a_failed_core_measurement_is_fatal_not_a_zero(self):
        errs = ["credits: TimeoutError: timed out", "intercom: HTTPError"]
        self.assertEqual(vqr.incomplete_errors(errs), ["credits: TimeoutError: timed out"])
        self.assertEqual(vqr.incomplete_errors(["claim flow: boom"]), ["claim flow: boom"])

    def test_a_claim_reply_with_documents_is_docs_in_not_human(self):
        # QA @be2b000: a reply that carried a document sets both facts; the generic "a
        # person is on it" branch used to win, so the returned document never reached
        # claims_docs_in and its SLA could never page.
        f = facts(claim_replied={1}, support_contacts={1},
                  claim_notes={"claim-11": {"at": "2026-10-26"}},
                  claim_proofs={"claim-11": "2026-10-27T00:00:00Z"})
        self.assertEqual(vqr.classify_claim(1, f, CLAIM, frozenset(), frozenset()), "docs_in")

    def test_an_incomplete_report_never_raises_in_render(self):
        # A failed flow query leaves flow={}; render() would raise KeyError('approved')
        # before the honest INCOMPLETE line could be sent.
        m = {"at": "2026-10-27 00:30Z",
             "credits": {"buckets": {}, "flow": {}, "open_users": 0, "open_rows": 0,
                         "open_paid": 0, "open_paid_users": 0},
             "claims": {"buckets": {}, "flow": {}, "open_users": 0, "open_rows": 0,
                        "open_paid": 0, "open_paid_users": 0}, "errors": []}
        with self.assertRaises(KeyError):
            vqr.render(m, None)          # documents why the order matters
        self.assertEqual(vqr.incomplete_errors(["credit flow: boom"]), ["credit flow: boom"])

    def test_a_subsidiary_lane_failure_does_not_suppress_the_report(self):
        self.assertEqual(vqr.incomplete_errors(["merges: boom", "intercom: boom"]), [])


class DecidedNotClosed(unittest.TestCase):
    """QA @987d77e: rows and users must use the SAME terminal rule — a row is closed when its
    outcome is the terminal one for ITS OWN ruling, not for some global list."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        db = sqlite3.connect(self.path)
        db.executescript("""
        CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
          decided_at TEXT NOT NULL, request_id TEXT NOT NULL, user_id INTEGER,
          big_track INTEGER NOT NULL DEFAULT 0, decision TEXT NOT NULL, reason TEXT NOT NULL,
          proof_id TEXT, mode TEXT NOT NULL);
        CREATE TABLE decision_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
          at TEXT NOT NULL, request_id TEXT NOT NULL, action TEXT NOT NULL, outcome TEXT NOT NULL);
        """)
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        rows = [("req-a", 5, "support", "user_verification_needed"),   # executed
                ("req-b", 6, "support", "approved"),                   # NOT its terminal -> open
                ("req-c", 6, "approve", "approved"),                   # executed for its ruling
                ("req-d", 7, "approve", ""),                           # no outcome -> open
                ("req-e", 8, "support", "skipped:x")]                  # skipped -> open
        for rid, uid, dec, outcome in rows:
            db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, decision,"
                       " reason, mode) VALUES ('r', ?, ?, ?, ?, 'x', 'apply')", (now, rid, uid, dec))
            if outcome:
                db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action,"
                           " outcome) VALUES ('r', ?, ?, ?, ?)", (now, rid, dec, outcome))
        db.commit(); db.close()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_rows_and_users_agree_on_what_is_closed(self):
        old = vqr.LEDGER
        vqr.LEDGER = self.path
        try:
            out = vqr.decided_not_closed(days=1)
        finally:
            vqr.LEDGER = old
        # open: req-b (support/approved), req-d (approve/no outcome), req-e (support/skipped)
        self.assertEqual(out["rows"], 3)
        # users behind those rows: 6 (req-b), 7 (req-d), 8 (req-e) — req-b's user counts
        self.assertEqual(out["users_lb"], 3,
                         "the distinct-user count must use the same rule as the row count")
        self.assertEqual(out["by_ruling"], {"support": 2, "approve": 1})


class QA62baa91(unittest.TestCase):
    """A COMPLETE Intercom scan must still hand back the never-answered ledger, or the comms
    class silently reads zero and its growth page can never fire."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def conv(self, cid, admin_at=None, contact_at=None):
        c = {"id": cid, "created_at": 1, "statistics": {}}
        if admin_at is not None:
            c["statistics"]["last_admin_reply_at"] = admin_at
        if contact_at is not None:
            c["statistics"]["last_contact_reply_at"] = contact_at
        return c

    def test_a_complete_first_scan_reports_the_never_answered_ledger(self):
        convs = [self.conv(1, contact_at=1000),                 # waiting, never answered
                 self.conv(2, contact_at=1000, admin_at=900)]   # we answered, they came back
        old = vqr.intercom_search
        vqr.intercom_search = lambda *a, **k: (convs, False, None)
        try:
            items, info = vqr.intercom_items(None, self.NOW)
        finally:
            vqr.intercom_search = old
        self.assertIsNotNone(info, "a complete scan must still return its ledger")
        self.assertEqual(list((info.get("never_answered") or {}).keys()), ["conv:1"])
        self.assertEqual([i for i, _ in items], ["conv:1", "conv:2"])

    def test_probe_sources_persists_it_through_the_state_handoff(self):
        convs = [self.conv(1, contact_at=1000)]

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            return convs, False, None

        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            probe = vqr.probe_sources(None, self.NOW)
        finally:
            vqr.intercom_search = old
        saved = probe["intercom"]
        self.assertEqual(list((saved.get("never_answered") or {}).keys()), ["conv:1"],
                         "the state handed to the next tick keeps the never-answered ledger")
        self.assertTrue(saved.get("last_walk"))
        self.assertFalse(probe.get("intercom_flag"), "a complete scan is not unmeasured")

    def test_the_resumed_scan_keeps_what_the_partial_one_saw(self):
        convs = [self.conv(7, contact_at=1000)]
        old = vqr.intercom_search
        vqr.intercom_search = lambda *a, **k: (convs, True, "cur-2")
        try:
            _, info = vqr.intercom_items(None, self.NOW)
        finally:
            vqr.intercom_search = old
        self.assertTrue(info["truncated"])
        self.assertEqual(list((info.get("never_answered") or {}).keys()), ["conv:7"])

    def conv(self, cid, admin_at=None, contact_at=None):
        c = {"id": cid, "created_at": 1, "statistics": {}}
        if admin_at is not None:
            c["statistics"]["last_admin_reply_at"] = admin_at
        if contact_at is not None:
            c["statistics"]["last_contact_reply_at"] = contact_at
        return c

    def run_scan(self, prev, convs, truncated=False, cursor=None):
        def is_closed(q):
            v = q.get("value")
            if isinstance(v, list):
                return any(isinstance(f, dict) and f.get("value") == "closed" for f in v)
            return v == "closed"          # the bootstrap query is a plain {"field": state}

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            # the CLOSED query must not echo the open rows, or the closures would undo them
            if is_closed(query):
                return [], False, None
            return convs, truncated, cursor
        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            return vqr.intercom_items(prev, self.NOW)
        finally:
            vqr.intercom_search = old

    def test_a_complete_delta_scan_keeps_the_ledger_through_the_state_handoff(self):
        # QA @265e00b: the complete DELTA path returned None, so the persisted state lost it
        prev = {"intercom": {"items": {}, "never_answered": {},
                             "last_walk": "2026-10-29T11:00:00Z"}}
        convs = [self.conv(9, contact_at=1000)]
        _, info = self.run_scan(prev, convs)
        self.assertIsInstance(info, dict)
        self.assertEqual(list((info.get("never_answered") or {}).keys()), ["conv:9"])

        def is_closed(q):
            v = q.get("value")
            if isinstance(v, list):
                return any(isinstance(f, dict) and f.get("value") == "closed" for f in v)
            return v == "closed"

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            if is_closed(query):
                return [], False, None
            return convs, False, None
        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            probe = vqr.probe_sources(prev, self.NOW)
        finally:
            vqr.intercom_search = old
        saved = probe["intercom"]
        self.assertEqual(list((saved.get("never_answered") or {}).keys()), ["conv:9"],
                         "the delta handoff must persist the never-answered ledger")
        self.assertTrue(saved.get("last_walk"))
        self.assertFalse(probe.get("intercom_flag"))

    def test_a_truncated_bootstrap_scan_keeps_what_it_saw(self):
        convs = [self.conv(11, contact_at=1000)]
        _, info = self.run_scan(None, convs, truncated=True, cursor="cur-2")
        self.assertTrue(info["truncated"])
        self.assertEqual(list((info.get("never_answered") or {}).keys()), ["conv:11"])

    def test_a_truncated_delta_scan_keeps_what_it_saw(self):
        prev = {"intercom": {"items": {}, "never_answered": {},
                             "last_walk": "2026-10-29T11:00:00Z"}}
        convs = [self.conv(12, contact_at=1000)]
        _, info = self.run_scan(prev, convs, truncated=True, cursor="cur-3")
        self.assertTrue(info["truncated"])
        self.assertEqual(list((info.get("never_answered") or {}).keys()), ["conv:12"])

    def test_a_truncated_bootstrap_handoff_persists_the_ledger(self):
        # QA @ccd62bf: the keep_walk=False branch saved items/last_walk/boot_cursor only, so the
        # resumed scan started with an empty never-answered set and the page we HAD read was
        # lost for ever.
        convs = [self.conv(21, contact_at=1000)]

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            return convs, True, "next-page"

        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            probe = vqr.probe_sources(None, self.NOW)          # no prior state -> bootstrap
        finally:
            vqr.intercom_search = old
        saved = probe["intercom"]
        self.assertEqual(saved.get("boot_cursor"), "next-page")
        self.assertEqual(list((saved.get("never_answered") or {}).keys()), ["conv:21"])
        # and the resume starts from the saved cursor with the ledger intact
        seen = []

        def resume(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            seen.append(start_after)
            return [], False, None

        old = vqr.intercom_search
        vqr.intercom_search = resume
        try:
            items2, info2 = vqr.intercom_items({"intercom": saved}, self.NOW)
        finally:
            vqr.intercom_search = old
        self.assertEqual(seen[0], "next-page")
        self.assertEqual(list((info2.get("never_answered") or {}).keys()), ["conv:21"],
                         "the resumed scan inherits the ledger")

    def test_answering_a_conversation_removes_it_from_the_ledger(self):
        held, na = {}, {}
        vqr.apply_intercom([self.conv(1, contact_at=1000)], held, na)
        self.assertIn("conv:1", na)
        vqr.apply_intercom([self.conv(1, contact_at=2000, admin_at=2000)], held, na)
        self.assertNotIn("conv:1", na)


class Headline(unittest.TestCase):
    """Fable's three-bucket headline (firstmate 014): awaiting us / awaiting the user /
    decided-not-closed — and NO raw status count."""

    DNC = {"rows": 907, "users_lb": 104,
           "by_outcome": {"no outcome recorded": 726, "shadow": 141}, "by_ruling": {"support": 888}}

    def build(self, credits):
        f = facts()
        return vqr.headline_build(credits, {}, lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                                  lambda u, i: "untouched", self.DNC)

    def test_the_three_buckets_and_where_each_class_lands(self):
        creds = {
            1: dict(CREDIT),                                   # untouched -> awaiting us
            2: dict(CREDIT, paid=True),                        # untouched -> awaiting us (paid)
            3: dict(CREDIT, core_ask=True),                    # told -> awaiting the user
        }
        h = self.build(creds)
        self.assertEqual(h["awaiting_us"]["users"], 2)
        self.assertEqual(h["awaiting_us"]["paid_users"], 1)
        self.assertEqual(h["awaiting_user"]["users"], 1)
        self.assertEqual(h["decided_not_closed"]["rows"], 907)
        self.assertEqual(h["decided_not_closed"]["users"], 104)

    def test_the_headline_names_the_write_failure_reasons(self):
        text = "\n".join(vqr.headline_render(self.build({1: dict(CREDIT)}), self.DNC))
        self.assertIn("Awaiting US", text)
        self.assertIn("Awaiting the USER", text)
        self.assertIn("DECIDED-NOT-CLOSED", text)
        self.assertIn("no outcome recorded 726", text)
        # the raw status vocabulary is gone from the headline
        for raw in ("unverified", "user_verification_needed"):
            self.assertNotIn(raw, text)

    def test_an_unreadable_ledger_makes_decided_not_closed_unmeasured(self):
        import subprocess
        env = dict(os.environ, VQR_OFFLINE="1")
        rc = subprocess.run([sys.executable, "-c",
                             "import importlib.util as u;s=u.spec_from_file_location('v',%r);"
                             "v=u.module_from_spec(s);s.loader.exec_module(v);"
                             "d=v.decided_not_closed();print(d['rows'],d.get('unmeasured'))"
                             % SCRIPT], capture_output=True, text=True, env=env)
        self.assertEqual(rc.stdout.strip(), "None True", rc.stderr)

    def test_a_ruling_only_counts_as_closed_when_its_write_landed(self):
        self.assertEqual(vqr.RULING_TERMINAL, {"approve": "approved",
                                               "support": "user_verification_needed"})


class QA99d61a6(unittest.TestCase):
    """Three Important findings: page metadata must stay aligned with its message, the report
    kill switch must not silence the sentinel, and an unreadable local source must degrade to
    unmeasured rather than aborting the unattended job."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_a_held_page_keeps_the_delivery_booleans_aligned(self):
        # one held lane + one normal lane: two messages, two page_map entries
        ev = vqr.sentinel_evaluate({"items": {
            "credits_docs_in": [("user:1", "2026-10-27T00:00:00Z")],
            "claims_docs_in": [("user:2", "2026-10-27T00:00:00Z")]}, "unmeasured": set()}, self.NOW)
        msgs, state, page_map = vqr.sentinel_page(ev, None, self.NOW, False)
        self.assertEqual(len(msgs), len(page_map))
        # held page: ids None. normal page: ids present.
        self.assertIsNone(dict(page_map)["credits_docs_in"])
        self.assertEqual(dict(page_map)["claims_docs_in"], ["user:2"])
        # the held post succeeded, the normal one failed: the claim must NOT be recorded
        state = vqr.record_paged(state, page_map, [True, False])
        self.assertNotIn("claims_docs_in", state.get("paged") or {})

    def test_the_report_kill_switch_does_not_stop_a_light_sentinel_tick(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            kill = os.path.join(d, "kill")
            open(kill, "w").close()
            env = dict(os.environ, VQR_OFFLINE="1", VQR_KILL_SWITCH=kill,
                       VQR_SENTINEL_KILL=os.path.join(d, "sentinel.kill"),
                       VQR_STATE=os.path.join(d, "last.json"),
                       VQR_SENTINEL_STATE=os.path.join(d, "s.json"),
                       VQR_SENTINEL_LOCK=os.path.join(d, "l.lock"),
                       VQR_LEDGER=os.path.join(d, "nope.sqlite3"))
            p = subprocess.run([sys.executable, vqr.__file__, "--light"], capture_output=True,
                               text=True, env=env)
            # the report switch silenced nothing: it did NOT print the NO_REPLY of a skipped run
            self.assertNotEqual(p.stdout.strip(), "NO_REPLY")
            self.assertTrue(os.path.exists(os.path.join(d, "s.json")),
                            "a light tick under the report switch never wrote sentinel state")

    def run_incomplete(self, **overrides):
        """Run the ENTRYPOINT in-process with one local source broken. Hermetic: every Trino /
        ClickUp / Intercom reader is stubbed, so nothing here can hang on a live service or
        depend on a credential (QA @17edb6c — the offline flag alone did not make these
        tests hermetic, which is exactly what these two cases uncovered)."""
        import contextlib
        import io
        import tempfile
        patches = {
            "credit_rows": lambda: {},
            "claim_rows": lambda: {},
            "flow_24h": lambda *a, **k: {"approved": {"rows": 0, "users": 0, "paid": 0},
                                         "declined": {"rows": 0, "users": 0, "paid": 0}},
            "ledger_facts": lambda: m_qafacts(),
            "proof_feed": lambda: (frozenset(), {}),
            "watchlist_ids": lambda: (frozenset(), frozenset()),
            "merge_rows": lambda: {},
            "merges_24h": lambda: {"rows": 0, "users": 0},
            "clickup_merge_queue": lambda now: {},
            "probe_sources": lambda prev, now: {"unmeasured": set()},
            "read_sentinel_state": lambda: None,
            "write_sentinel_state": lambda state: None,
        }
        patches.update(overrides)
        saved = {k: getattr(vqr, k) for k in patches}
        for k, fn in patches.items():
            setattr(vqr, k, fn)
        tmp = tempfile.mkdtemp()
        old = (vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK)
        vqr.STATE = os.path.join(tmp, "last.json")
        vqr.SENTINEL_KILL = os.path.join(tmp, "kill")
        vqr.SENTINEL_LOCK = os.path.join(tmp, "l.lock")
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                vqr.main(["vqr", "--dry-run"])
        finally:
            for k, fn in saved.items():
                setattr(vqr, k, fn)
            vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK = old
        return out.getvalue()

    def test_a_failed_watchlist_makes_the_sentinel_lanes_unmeasured_too(self):
        def boom():
            raise OSError("watchlist unreadable")
        text = self.run_incomplete(watchlist_ids=boom)
        self.assertIn("INCOMPLETE", text)
        self.assertNotIn("Traceback", text)

    def test_an_unreadable_ledger_marks_lanes_unmeasured_instead_of_aborting(self):
        def boom():
            raise sqlite3.OperationalError("unable to open database file")
        text = self.run_incomplete(ledger_facts=boom, proof_feed=boom)
        self.assertIn("INCOMPLETE", text)
        self.assertNotIn("Traceback", text)

    def test_an_offline_run_touches_no_external_reader(self):
        # VQR_OFFLINE must bypass Trino / ClickUp / Intercom / feeds, not just the probe: point
        # every path at something that cannot work and require a rendered report anyway.
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, VQR_OFFLINE="1",
                       VQR_STATE=os.path.join(d, "last.json"),
                       VQR_SENTINEL_STATE=os.path.join(d, "s.json"),
                       VQR_SENTINEL_LOCK=os.path.join(d, "l.lock"),
                       VQR_TRINO="/nonexistent/trino-query.sh",
                       VQR_LEDGER=os.path.join(d, "nope.sqlite3"),
                       VQR_PROOF_ON_FILE=os.path.join(d, "nope.json"),
                       VQR_WATCHLIST=os.path.join(d, "nope-watchlist.json"))
            p = subprocess.run([sys.executable, vqr.__file__, "--dry-run"], capture_output=True,
                               text=True, env=env, timeout=60)
            self.assertNotIn("Traceback", p.stdout + p.stderr)
            self.assertIn("CREDITS", p.stdout)


class QAba0264b(unittest.TestCase):
    """Two Important findings: the Intercom delta watermark only excluded same-second
    updates, and a busy sentinel lock silently swallowed the 30-minute report."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_the_delta_watermark_overlaps_so_a_same_second_update_is_not_lost(self):
        seen = {}

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            # record the epoch the open-delta asked for
            for f in query.get("value") or []:
                if f.get("field") == "updated_at":
                    seen["ep"] = f["value"]
            return [], False, None

        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            walk = "2026-10-29T11:00:00Z"
            vqr.intercom_items({"intercom": {"items": {}, "last_walk": walk}},
                               datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc))
        finally:
            vqr.intercom_search = old
        exact = int(datetime(2026, 10, 29, 11, 0, tzinfo=timezone.utc).timestamp())
        self.assertLess(seen["ep"], exact,
                        "the delta must re-read a small window behind the watermark")

    def test_a_busy_sentinel_lock_does_not_swallow_the_report(self):
        import contextlib
        import io
        import tempfile
        tmp = tempfile.mkdtemp()
        class Busy:
            def __init__(self, *a, **k):
                pass
            def __enter__(self):
                raise TimeoutError("another tick held the lock")
            def __exit__(self, *a):
                return False
        patches = {
            "credit_rows": lambda: {1: {"paid": False, "n": 1, "oldest": "2026-10-01 00:00:00.000000 UTC",
                                        "core_ask": False, "reply_at": "", "core_reply": False,
                                        "needs_docs": True, "paid_n": 0}},
            "claim_rows": lambda: {},
            "flow_24h": lambda *a, **k: {"approved": {"rows": 0, "users": 0, "paid": 0},
                                         "declined": {"rows": 0, "users": 0, "paid": 0}},
            "ledger_facts": lambda: m_qafacts(),
            "proof_feed": lambda: (frozenset(), {}),
            "watchlist_ids": lambda: (frozenset(), frozenset()),
            "merge_rows": lambda: {},
            "merges_24h": lambda: {"rows": 0, "users": 0},
            "clickup_merge_queue": lambda now: {},
            "probe_sources": lambda prev, now: {"unmeasured": set()},
            "read_sentinel_state": lambda: None,
            "write_sentinel_state": lambda state: None,
            "sentinel_lock": Busy,
        }
        saved = {k: getattr(vqr, k) for k in patches}
        for k, fn in patches.items():
            setattr(vqr, k, fn)
        old_state, old_kit, old_lock = vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK
        vqr.STATE = os.path.join(tmp, "last.json")
        vqr.SENTINEL_KILL = os.path.join(tmp, "kill")
        vqr.SENTINEL_LOCK = os.path.join(tmp, "l.lock")
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                rc = vqr.main(["vqr", "--dry-run"])
        finally:
            for k, fn in saved.items():
                setattr(vqr, k, fn)
            vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK = old_state, old_kit, old_lock
        text = out.getvalue()
        self.assertEqual(rc, 0)                     # dry-run still renders
        self.assertIn("CREDITS", text)              # the report is there
        self.assertIn("could not take its state lock", text)


def m_qafacts():
    return {"asked": {}, "messaged": {}, "latest": {}, "decided": set(), "support": set(),
            "replied": set(), "proof_waiting": {}, "muted": {}, "flagged": {},
            "claim_notes": {}, "claim_proofs": {}, "claim_replied": set(), "claim_muted": {},
            "claim_flagged": {}, "first_proof_hold": {}, "first_deadend": {},
            "support_contacts": set()}


class QA90e4006(unittest.TestCase):
    """Lock contention WITH saved state, and a sentinel-state write that fails after Slack
    already accepted the page."""

    def test_a_lock_timeout_with_saved_state_still_sends_the_report(self):
        # the old code emptied m["legacy"] and then read m["legacy"]["total"] -> KeyError
        m = {"legacy": {}, "at": "2026-10-27 02:00Z"}
        self.assertEqual(vqr.stall_pages(m, {"legacy": {"total": 4000}}), [])
        self.assertEqual(vqr.legacy_line(m, {"legacy": {"total": 4000}}), "")

    def test_a_failed_sentinel_state_write_fails_the_run(self):
        import contextlib
        import io
        import tempfile
        tmp = tempfile.mkdtemp()
        patches = {
            "credit_rows": lambda: {1: {"paid": False, "n": 1, "oldest": "2026-10-01 00:00:00.000000 UTC",
                                        "core_ask": False, "reply_at": "", "core_reply": False,
                                        "needs_docs": True, "paid_n": 0}},
            "claim_rows": lambda: {},
            "flow_24h": lambda *a, **k: {"approved": {"rows": 0, "users": 0, "paid": 0},
                                         "declined": {"rows": 0, "users": 0, "paid": 0}},
            "ledger_facts": lambda: m_qafacts(),
            "proof_feed": lambda: (frozenset(), {}),
            "watchlist_ids": lambda: (frozenset(), frozenset()),
            "merge_rows": lambda: {},
            "merges_24h": lambda: {"rows": 0, "users": 0},
            "clickup_merge_queue": lambda now: {},
            "probe_sources": lambda prev, now: {"unmeasured": set()},
            "read_sentinel_state": lambda: None,
            "write_sentinel_state": lambda state: (_ for _ in ()).throw(OSError(28, "No space left")),
        }
        saved = {k: getattr(vqr, k) for k in patches}
        for k, fn in patches.items():
            setattr(vqr, k, fn)
        old_state, old_kit, old_lock = vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK
        vqr.STATE = os.path.join(tmp, "last.json")
        vqr.SENTINEL_KILL = os.path.join(tmp, "kill")
        vqr.SENTINEL_LOCK = os.path.join(tmp, "l.lock")
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                rc = vqr.main(["vqr"])
        finally:
            for k, fn in saved.items():
                setattr(vqr, k, fn)
            vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK = old_state, old_kit, old_lock
        self.assertEqual(rc, 1, out.getvalue())
        self.assertIn("could not be persisted", out.getvalue())


class CommsCoverage(unittest.TestCase):
    """Captain 2026-10-27: "are you sure all users that need to be communicated have been
    already?" — the block counts who is still owed a message, by class, paid vs free."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def build(self, credits=None, claims=None, clickup=None, never=None):
        f = facts()
        return vqr.comms_build(credits or {}, claims or {}, f,
                               lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                               lambda u, i: vqr.classify_claim(u, f, i, frozenset(), frozenset()),
                               frozenset(), frozenset(), clickup or {},
                               never or {}, self.NOW)

    def test_the_claims_class_owner_is_the_seat_that_exists(self):
        c = self.build()
        sentinel = {k: owner for k, _label, owner, _sla in vqr.SENTINEL_BUCKETS}
        self.assertEqual(c["claims_pending"]["owner"], sentinel["claims_untouched"])
        self.assertNotIn("claim-lane-resume-c2", c["claims_pending"]["owner"])

    def test_no_owner_the_report_prints_names_a_seat_that_exists_in_no_home(self):
        dead = ("claim-lane-resume-c2",)
        owners = [owner for _k, _l, owner, _s in vqr.SENTINEL_BUCKETS]
        owners += [owner for _k, _l, owner, _p in vqr.comms_classes()]
        owners += [c["owner"] for c in self.build().values()]
        stored = {k: {"count": 1, "oldest_h": 1, "owner": "stored"} for k in vqr.CAPTAIN_HELD}
        for lanes in (vqr.read_held_lanes(), {}):
            owners += [row["owner"] for row in vqr.held_words_now(stored, {}, lanes).values()]
        for owner in owners:
            self.assertTrue(owner)
            for seat in dead:
                self.assertNotIn(seat, owner)

    def test_a_truncated_intercom_scan_is_unmeasured_not_a_count(self):
        # QA @059da4d: a partial never_answered map must not print as a complete count
        f = facts()
        c = vqr.comms_build({}, {}, f, lambda u, i: "untouched", lambda u, i: "untouched",
                            frozenset(), frozenset(), {}, {"conv:1": "2026-10-28T00:00:00Z"},
                            self.NOW, unmeasured={"intercom_customer_last"})
        self.assertFalse(c["intercom_inbound"]["measured"])
        self.assertEqual(c["intercom_inbound"]["free"], 0)
        line = " ".join(vqr.comms_render(c))
        self.assertIn("UNMEASURED", line)
        self.assertNotIn("1 (paid not measured", line)

    def test_an_unmeasured_class_keeps_the_previous_signature_and_never_pages(self):
        f = facts()
        c = vqr.comms_build({}, {}, f, lambda u, i: "untouched", lambda u, i: "untouched",
                            frozenset(), frozenset(), {}, {}, self.NOW,
                            unmeasured={"merges_waiting", "intercom_customer_last"})
        prev = {"merges_pending": {"count": 7, "paid_48h": False},
                "intercom_inbound": {"count": 3, "paid_48h": False}}
        sig = vqr.comms_signature(c, prev)
        # the failed ClickUp / truncated Intercom read does NOT persist a zero baseline
        self.assertEqual(sig["merges_pending"], {"count": 7, "paid_48h": False})
        self.assertEqual(sig["intercom_inbound"], {"count": 3, "paid_48h": False})
        self.assertEqual(vqr.comms_pages(c, prev), [], "an unmeasured class never pages")
        # and with no previous baseline at all, nothing is persisted for it either
        self.assertNotIn("merges_pending", vqr.comms_signature(c, None))

    def test_a_recovered_source_does_not_page_unchanged_backlog_as_growth(self):
        f = facts()
        c = vqr.comms_build({}, {}, f, lambda u, i: "untouched", lambda u, i: "untouched",
                            frozenset(), frozenset(), {"untouched": 7}, {}, self.NOW)
        prev = {"merges_pending": {"count": 7, "paid_48h": False}}      # carried through the outage
        self.assertEqual([m for m in vqr.comms_pages(c, prev) if "merge" in m.lower()], [])

    def test_the_first_measured_sample_after_an_unmeasured_one_is_a_baseline_not_growth(self):
        # QA @ac05f37: previous ticks could not read Intercom, so comms_signature persisted no
        # entry for the class; when it recovers with three unchanged conversations that is the
        # first baseline, never "grew to 3"
        f = facts()
        never = {f"conv:{i}": "2026-10-28T00:00:00Z" for i in range(3)}
        c = vqr.comms_build({}, {}, f, lambda u, i: "untouched", lambda u, i: "untouched",
                            frozenset(), frozenset(), {}, never, self.NOW)
        self.assertEqual(c["intercom_inbound"]["free"], 3)
        self.assertEqual(vqr.comms_pages(c, {}), [], "no measured prior = baseline, not growth")
        self.assertEqual(vqr.comms_pages(c, {"credits_waiting_us": {"count": 0, "paid_48h": False}}), [])
        # and a measured prior that is smaller still pages
        self.assertEqual(len(vqr.comms_pages(c, {"intercom_inbound": {"count": 2, "paid_48h": False}})), 1)

    def test_a_failed_classification_feed_blinds_the_credits_and_claims_classes(self):
        # QA @ac05f37: with the ledger unreadable the classifier runs on empty facts, so an
        # already-asked user would read as untouched; those classes are unmeasured, never paged
        creds = {7: {"paid": True, "n": 1, "oldest": "2026-10-20 00:00:00.000000 UTC",
                     "profiles": [], "paid_n": 1}}
        c = vqr.comms_build(creds, {}, vqr._EMPTY_FACTS(), lambda u, i: "untouched",
                            lambda u, i: "untouched", frozenset(), frozenset(), {}, {}, self.NOW,
                            unmeasured=set(vqr.CLASSIFICATION_LANES))
        for key in ("credits_waiting_us", "credits_owing_proof", "claims_pending"):
            self.assertFalse(c[key]["measured"], key)
            self.assertEqual(c[key]["paid"] + c[key]["free"], 0, key)
        prev = {"credits_waiting_us": {"count": 0, "paid_48h": False}}
        self.assertEqual(vqr.comms_pages(c, prev), [])
        self.assertEqual(vqr.comms_signature(c, prev)["credits_waiting_us"], prev["credits_waiting_us"])

    def test_the_five_classes_the_captain_named(self):
        self.assertEqual([k for k, _, _, _ in vqr.comms_classes()],
                         ["credits_waiting_us", "credits_owing_proof", "claims_pending",
                          "merges_pending", "intercom_inbound"])

    def test_paid_and_free_are_counted_separately_with_their_own_oldest(self):
        creds = {1: dict(CREDIT, paid=True, oldest="2026-09-01 00:00:00.000000 UTC"),
                 2: dict(CREDIT, paid=False, oldest="2026-10-20 00:00:00.000000 UTC")}
        c = self.build(credits=creds)["credits_waiting_us"]
        self.assertEqual((c["paid"], c["free"]), (1, 1))
        self.assertGreater(c["paid_oldest_h"], c["free_oldest_h"])

    def test_owing_proof_is_its_own_class(self):
        f = facts(messaged={3: ""}, latest={3: {"decision": "hold", "reason": "score approval not now",
                                               "doc_required": 0, "at": ""}})
        creds = {3: dict(CREDIT)}
        c = vqr.comms_build(creds, {}, f,
                            lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                            lambda u, i: "untouched", frozenset(), frozenset(), {}, {}, self.NOW)
        self.assertEqual(c["credits_owing_proof"]["free"], 1)
        self.assertEqual(c["credits_waiting_us"]["free"], 0)

    def test_a_source_that_cannot_tell_the_plan_says_unmeasured_not_zero(self):
        c = self.build(clickup={"untouched": 32}, never={"conv:1": "2026-10-28T00:00:00Z"})
        self.assertIs(c["merges_pending"]["paid_known"], False)
        self.assertIs(c["intercom_inbound"]["paid_known"], None)
        self.assertEqual(c["intercom_inbound"]["free"], 1)
        lines = " ".join(vqr.comms_render(c))
        self.assertIn("paid not measured on this source", lines)

    def test_the_first_reading_pages_nothing(self):
        c = self.build(credits={1: dict(CREDIT)})
        self.assertEqual(vqr.comms_pages(c, None), [], "no previous number is not growth")

    def test_a_class_that_grows_pages(self):
        c = self.build(credits={1: dict(CREDIT), 2: dict(CREDIT, paid=True)})
        prev = {"credits_waiting_us": {"count": 1, "paid_48h": False}}
        msgs = vqr.comms_pages(c, prev)
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("COMMS COVERAGE: credits waiting on us, never told grew"))
        self.assertIn("owner verify-ask-wiring-h2", msgs[0])

    def test_a_shrinking_class_is_silent(self):
        c = self.build(credits={1: dict(CREDIT)})
        prev = {"credits_waiting_us": {"count": 9, "paid_48h": False}}
        self.assertEqual(vqr.comms_pages(c, prev), [])

    def test_a_paid_user_untold_past_48h_pages_once(self):
        creds = {1: dict(CREDIT, paid=True, oldest="2026-10-26 00:00:00.000000 UTC")}
        c = self.build(credits=creds)
        prev = {"credits_waiting_us": {"count": 1, "paid_48h": False}}
        msgs = vqr.comms_pages(c, prev)
        self.assertEqual(len(msgs), 1)
        self.assertIn("paid user has been untold", msgs[0])
        # already paged: the same state does not page again
        self.assertEqual(vqr.comms_pages(c, {"credits_waiting_us": {"count": 1, "paid_48h": True}}), [])


class QA870cebb(unittest.TestCase):
    """A blind lane may report what it carries but must not PAGE from it, and a probe taken
    outside the lock must not roll back a newer tick's state."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_a_blind_lane_reports_its_carried_items_but_does_not_page(self):
        carried = [("user:1", "2026-10-27T00:00:00Z")]      # 2.5 days old: well past 24h
        ev = vqr.sentinel_evaluate({"items": {"credits_untouched": carried},
                                    "unmeasured": {"credits_untouched"}}, self.NOW)
        self.assertEqual(len(ev["credits_untouched"]["breaches"]), 1)   # still reported
        msgs, state, page_map = vqr.sentinel_page(ev, None, self.NOW, False)
        self.assertEqual(msgs, [], "a lane we could not measure must not page")
        self.assertEqual(page_map, [])
        self.assertEqual(state["breaches"][0]["bucket"], "credits_untouched")

    def test_a_measured_lane_still_pages(self):
        ev = vqr.sentinel_evaluate({"items": {"credits_untouched": [
            ("user:1", "2026-10-27T00:00:00Z")]}, "unmeasured": set()}, self.NOW)
        msgs, _, page_map = vqr.sentinel_page(ev, None, self.NOW, False)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(len(page_map), 1)

    def test_a_stale_out_of_lock_probe_is_detected(self):
        # probed from ts=A, but the state under the lock is ts=B (a faster tick wrote it)
        self.assertTrue(vqr.probe_stale("2026-10-29T11:00:00Z",
                                        {"ts": "2026-10-29T11:05:00Z"}))
        # same state: our probe is current
        self.assertFalse(vqr.probe_stale("2026-10-29T11:05:00Z",
                                         {"ts": "2026-10-29T11:05:00Z"}))
        # nothing written at all yet: whatever we probed is still news
        self.assertFalse(vqr.probe_stale(None, None))
        # QA @17edb6c: no state BEFORE the lock, state now -> the later holder must not win
        self.assertTrue(vqr.probe_stale(None, {"ts": "2026-10-29T11:05:00Z"}))

    def test_a_stale_probe_marks_both_source_lanes_unmeasured(self):
        # with an empty unmeasured set the lanes would be treated as measured-and-empty (and
        # their delivered ids pruned), so the stale branch must be explicit about it
        src = open(SCRIPT).read()
        self.assertIn('"unmeasured": {"merges_waiting", "intercom_customer_last"}', src)
        found = vqr.sentinel_items({}, {}, m_qafacts(), lambda u, i: "untouched",
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {"conv:1": "2026-10-28T00:00:00Z"}},
                                               "merges": {"items": {}}},
                                   now=datetime(2026, 10, 29, tzinfo=timezone.utc),
                                   probe={"merges": None, "intercom": None,
                                          "unmeasured": {"merges_waiting",
                                                         "intercom_customer_last"}})
        self.assertEqual([i for i, _ in found["items"]["intercom_customer_last"]], ["conv:1"],
                         "the carried set must survive a stale probe")
        self.assertIn("intercom_customer_last", found["unmeasured"])


class QA4a25b33(unittest.TestCase):
    """The tag is chosen AFTER the comparison (an old tag must not hide a new one), and a failed
    watchlist / proof feed must blind the sentinel as well as the table — the watchlist for both
    families, the proof feed for the claim lanes only."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_an_old_tag_beside_a_new_one_still_qualifies(self):
        c = dict(CREDIT, newest="2026-10-26 00:00:00.000000 UTC")
        f = facts(proof_tags={7: ["2026-01-02T10:00:00Z", "2026-10-27T10:00:00Z"]})
        self.assertTrue(vqr.proof_newer_than_request(7, f, c))
        self.assertEqual(vqr.classify_credit(7, f, c, frozenset()), "docs_in")
        self.assertEqual(vqr.qualifying_proof_tags(7, f, c), ["2026-10-27T10:00:00Z"])

    def test_only_old_tags_do_not_qualify(self):
        c = dict(CREDIT, newest="2026-10-26 00:00:00.000000 UTC")
        f = facts(proof_tags={7: ["2026-01-02T10:00:00Z"]})
        self.assertFalse(vqr.proof_newer_than_request(7, f, c))
        self.assertNotEqual(vqr.classify_credit(7, f, c, frozenset()), "docs_in")

    def test_the_clock_is_the_newest_qualifying_tag(self):
        c = dict(CREDIT, newest="2026-10-26 00:00:00.000000 UTC", core_reply=False,
                 reply_at="")
        f = facts(messaged={7: ""},
                  proof_tags={7: ["2026-01-02T10:00:00Z", "2026-10-27T10:00:00Z"]})
        found = vqr.sentinel_items({7: c}, {}, f,
                                   lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=self.NOW)
        entered = dict(found["items"]["credits_docs_in"])["user:7"]
        self.assertEqual(vqr.parse_ts(entered), vqr.parse_ts("2026-10-27T10:00:00Z"))

    def test_a_failed_watchlist_blinds_the_classification_lanes(self):
        self.assertEqual(vqr.CLASSIFICATION_LANES,
                         {"credits_untouched", "credits_docs_in", "claims_untouched",
                          "claims_docs_in"})

    def test_a_failed_proof_feed_blinds_only_the_claim_classes(self):
        # `classify_credit` reads no contact list, so a failed proof feed leaves the credit
        # classes measurable and only the claim ones blind.
        credits = {7: {"paid": True, "oldest": "2026-10-01 00:00:00.000000 UTC"}}
        claims = {8: {"paid": True, "oldest": "2026-10-01 00:00:00.000000 UTC"}}
        args = (credits, claims, facts(), lambda u, i: "untouched", lambda u, i: "untouched",
                frozenset(), frozenset(), {}, {}, self.NOW)
        fed = vqr.comms_build(*args, unmeasured=vqr.PROOF_FEED_LANES)
        self.assertTrue(fed["credits_waiting_us"]["measured"])
        self.assertTrue(fed["credits_owing_proof"]["measured"])
        self.assertEqual(fed["credits_waiting_us"]["paid"], 1)
        self.assertFalse(fed["claims_pending"]["measured"])
        blind = vqr.comms_build(*args, unmeasured=vqr.CLASSIFICATION_LANES)
        self.assertFalse(blind["credits_waiting_us"]["measured"])
        self.assertFalse(blind["credits_owing_proof"]["measured"])
        self.assertFalse(blind["claims_pending"]["measured"])


class QAecfa985(unittest.TestCase):
    """A truncated closed scan must APPLY the closures it did return, and the docs_in clock must
    come from the evidence that qualified the row — not from a historic hold."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_a_closed_conversation_seen_before_truncation_is_dropped(self):
        held = {"conv:1": "2026-10-27T00:00:00Z", "conv:2": "2026-10-27T00:00:00Z"}
        calls = []

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            is_closed = any(f.get("value") == "closed" for f in (query.get("value") or []))
            calls.append("closed" if is_closed else "open")
            if is_closed:
                # page 1 returns conv:1 as closed, then the scan truncates
                return [{"id": 1}], True, "closed-page-2"
            return [], False, None

        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            items, info = vqr.intercom_items(
                {"intercom": {"items": held, "last_walk": "2026-10-27T07:25:01Z"}}, self.NOW)
        finally:
            vqr.intercom_search = old
        self.assertTrue(info["truncated"])
        self.assertEqual(info["closed_cursor"], "closed-page-2")
        self.assertEqual([i for i, _ in items], ["conv:2"],
                         "the closure on the page we DID read must be applied")

    def test_an_old_proof_hold_does_not_date_a_fresh_document(self):
        # user has a pre-baseline "proof on file" hold, and a brand-new core response
        fresh = {"paid": False, "n": 1, "oldest": "2026-10-20 00:00:00.000000 UTC",
                 "newest": "2026-10-20 00:00:00.000000 UTC",
                 "core_ask": False, "reply_at": "2026-10-29T06:00:00Z", "core_reply": True,
                 "needs_docs": True, "paid_n": 0}
        f = facts(first_proof_hold={7: "2026-10-01T00:00:00Z"},
                  latest={7: {"decision": "hold",
                              "reason": "proof on file: human review", "doc_required": 0,
                              "at": "2026-10-01T00:00:00Z"}})
        found = vqr.sentinel_items({7: fresh}, {}, f,
                                   lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=self.NOW)
        entered = dict(found["items"]["credits_docs_in"])["user:7"]
        self.assertEqual(vqr.parse_ts(entered), vqr.parse_ts("2026-10-29T06:00:00Z"),
                         "the fresh document, not the historic hold, is the clock")
        ev = vqr.sentinel_evaluate(found, self.NOW)
        self.assertEqual(len(ev["credits_docs_in"]["breaches"]), 0)   # fresh: not yet due
        self.assertEqual(ev["credits_docs_in"]["legacy"], 0, "it must not be filed as legacy")

    def test_a_document_on_file_is_clocked_from_when_it_arrived(self):
        # The document is the evidence that put the row in docs_in, so the lane is clocked from
        # when the customer sent it: a document received 2026-11-15 is not a 2026-10-01 item.
        c = dict(CREDIT, oldest="2026-10-01 00:00:00.000000 UTC",
                 newest="2026-10-01 00:00:00.000000 UTC")
        f = facts(latest={7: {"decision": "hold",
                              "reason": "proof on file: human review (a document is on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={7: {"filed": True, "read": True, "date": date(2026, 11, 15),
                                 "received_at": "2026-11-15T00:00:00Z",
                                 "docs": [{"read": True, "date": date(2026, 11, 15),
                                           "received_at": "2026-11-15T00:00:00Z"}]}})
        found = vqr.sentinel_items({7: c}, {}, f,
                                   lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=self.NOW)
        entered = dict(found["items"]["credits_docs_in"])["user:7"]
        self.assertEqual(vqr.parse_ts(entered), vqr.parse_ts("2026-11-15T00:00:00Z"))

    def test_an_older_document_does_not_date_a_row_qualified_by_a_newer_reply(self):
        # The row is docs_in because of the core reply, not the document: an older document date
        # must not pull the lane clock back into the pre-baseline legacy backlog.
        c = dict(CREDIT, oldest="2026-10-01 00:00:00.000000 UTC",
                 newest="2026-10-01 00:00:00.000000 UTC",
                 reply_at="2026-11-15T00:00:00Z", core_reply=True)
        f = facts(latest={7: {"decision": "hold",
                              "reason": "proof on file: human review (a document is on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={7: {"filed": True, "read": True, "date": date(2025, 12, 1),
                                 "received_at": "2025-12-01T00:00:00Z"}})
        found = vqr.sentinel_items({7: c}, {}, f,
                                   lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=self.NOW)
        entered = dict(found["items"]["credits_docs_in"])["user:7"]
        self.assertEqual(vqr.parse_ts(entered), vqr.parse_ts("2026-11-15T00:00:00Z"))

    def test_an_unopened_document_is_clocked_from_its_own_arrival(self):
        # One document read and dated 2025-01-05, another never opened and received 2026-11-15:
        # the look is ours, and the lane is clocked from the unopened document's arrival, never
        # from the other document's signed date.
        c = dict(CREDIT, oldest="2026-10-01 00:00:00.000000 UTC",
                 newest="2026-10-01 00:00:00.000000 UTC")
        f = facts(latest={7: {"decision": "hold",
                              "reason": "proof on file: human review (a document is on file)",
                              "doc_required": 0, "at": ""}},
                  doc_dates={7: {"filed": True, "read": False, "date": date(2025, 1, 5),
                                 "received_at": "2026-11-15T00:00:00Z",
                                 "docs": [{"read": True, "date": date(2025, 1, 5),
                                           "received_at": "2025-01-05T00:00:00Z"},
                                          {"read": False, "date": None,
                                           "received_at": "2026-11-15T00:00:00Z"}]}})
        found = vqr.sentinel_items({7: c}, {}, f,
                                   lambda u, i: vqr.classify_credit(u, f, i, frozenset()),
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=self.NOW)
        entered = dict(found["items"]["credits_docs_in"])["user:7"]
        self.assertEqual(vqr.parse_ts(entered), vqr.parse_ts("2026-11-15T00:00:00Z"))


class QAc61de56(unittest.TestCase):
    """A truncated CLOSED scan must resume from its saved cursor. The old key mapping was built
    with chained str.replace, which stored `closed_delta_cursor` while the reader asked for
    `closed_cursor` — so the scan restarted at page 1 for ever and the watermark stayed frozen."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_a_truncated_closed_scan_is_saved_under_the_key_the_reader_uses(self):
        seen = []

        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            seen.append(start_after)
            is_closed = any(f.get("value") == "closed" for f in (query.get("value") or []))
            return [], True, ("closed-page-2" if is_closed else "open-page-2")

        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            items, info = vqr.intercom_items(
                {"intercom": {"items": {}, "last_walk": "2026-10-27T07:25:01Z"}}, self.NOW)
        finally:
            vqr.intercom_search = old
        # a truncated OPEN scan stops before the closed scan runs, so drive the closed case
        self.assertTrue(info["truncated"])

    def test_probe_sources_stores_the_closed_cursor_literally_and_next_tick_resumes(self):
        # emulate what intercom_items returns when only the CLOSED scan was cut short
        old_items = vqr.intercom_items
        vqr.intercom_items = lambda prev, now: (
            [], {"truncated": True, "keep_walk": True, "closed_cursor": "closed-page-2"})
        try:
            probe = vqr.probe_sources({"intercom": {"items": {}, "last_walk": "2026-10-27T07:25:01Z"}},
                                      self.NOW)
        finally:
            vqr.intercom_items = old_items
        saved = probe["intercom"]
        self.assertEqual(saved.get("closed_cursor"), "closed-page-2",
                         "the reader asks prev_state['intercom']['closed_cursor']")
        self.assertNotIn("closed_delta_cursor", saved)
        self.assertEqual(saved.get("last_walk"), "2026-10-27T07:25:01Z")

        # and the resume actually reaches the search on the next tick
        seen = []
        old_search = vqr.intercom_search
        vqr.intercom_search = lambda q, per_page=150, max_pages=40, deadline_s=25.0, start_after=None: (
            seen.append(start_after), ([], False, None))[1]
        try:
            vqr.intercom_items({"intercom": saved}, self.NOW)
        finally:
            vqr.intercom_search = old_search
        self.assertIn("closed-page-2", seen)

    def test_the_cursor_map_is_explicit(self):
        self.assertEqual(dict(vqr.INTERCOM_CURSORS),
                         {"cursor": "delta_cursor", "closed_cursor": "closed_cursor"})


class QA36fb305(unittest.TestCase):
    """A user with several pending claims is clocked at the OLDEST unreviewed proof, whichever
    order the query returns the claims in — a fresh proof must not hide an overdue one."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def lane(self, claims, proofs):
        two = {"paid": False, "n": 2, "oldest": "2026-10-01 00:00:00.000000 UTC",
               "profiles": [], "claims": claims, "paid_n": 0}
        f = facts(claim_proofs=proofs, claim_notes={f"claim-{c}": {"at": "2026-10-01"}
                                                    for c in claims})
        found = vqr.sentinel_items({}, {7: two}, f, lambda u, i: "untouched",
                                   lambda u, i: vqr.classify_claim(u, f, i, frozenset(),
                                                                   frozenset()),
                                   frozenset(), frozenset(), light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=self.NOW)
        ev = vqr.sentinel_evaluate(found, self.NOW)
        return found, ev

    def test_the_fresh_proof_cannot_hide_the_overdue_one(self):
        # claim 11's proof is 49h old, claim 12's is 1h old; 12 is listed FIRST on purpose
        found, ev = self.lane(["12", "11"], {"claim-12": "2026-10-29T11:00:00Z",
                                            "claim-11": "2026-10-27T11:00:00Z"})
        entered = dict(found["items"]["claims_docs_in"])["user:7"]
        self.assertEqual(vqr.parse_ts(entered), vqr.parse_ts("2026-10-27T11:00:00Z"))
        self.assertEqual(len(ev["claims_docs_in"]["breaches"]), 1,
                         "the 49h-old proof is past the 24h SLA and must breach")

    def test_the_order_of_the_claim_list_does_not_change_the_clock(self):
        a = self.lane(["11", "12"], {"claim-11": "2026-10-27T11:00:00Z",
                                     "claim-12": "2026-10-29T11:00:00Z"})[0]
        b = self.lane(["12", "11"], {"claim-11": "2026-10-27T11:00:00Z",
                                     "claim-12": "2026-10-29T11:00:00Z"})[0]
        self.assertEqual(dict(a["items"]["claims_docs_in"]), dict(b["items"]["claims_docs_in"]))


class QAd5c1d18(unittest.TestCase):
    """A lane whose blocker ships must stop being labelled captain-held, and a failed REPORT
    state write must fail the run."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_a_lane_that_is_no_longer_held_drops_its_held_entry_but_still_pages(self):
        # fable_decider while held...
        ev_held = vqr.sentinel_evaluate({"items": {"fable_decider": [
            ("user:1", "2026-10-27T00:00:00Z")]}, "unmeasured": set()}, self.NOW)
        msgs, state, pm = vqr.sentinel_page(ev_held, None, self.NOW, False,
                                            held_facts_now={"decide_switch": True,
                                                            "account_gate_live": False},
                                            held_lanes_now={})
        state = vqr.record_paged(state, pm, [True] * len(pm))
        self.assertIn("fable_decider", state["held"])
        self.assertTrue(msgs[0].startswith("BACKLOG HELD BY CAPTAIN ORDER"))
        # ...then the switch is gone and the gate is live: the blocker shipped
        ev_after = vqr.sentinel_evaluate({"items": {"fable_decider": [
            ("user:1", "2026-10-27T00:00:00Z"),
            ("user:2", "2026-10-27T00:00:00Z")]}, "unmeasured": set()}, self.NOW)
        msgs2, state2, _ = vqr.sentinel_page(ev_after, state, self.NOW, False,
                                             held_facts_now={"decide_switch": False,
                                                             "account_gate_live": True},
                                             held_lanes_now={})
        self.assertNotIn("fable_decider", state2["held"],
                         "a lane whose blocker shipped must not stay labelled held")
        self.assertTrue(msgs2 and msgs2[0].startswith("BACKLOG FORMING"))

    def test_a_failed_report_state_write_returns_nonzero(self):
        import contextlib
        import io
        import tempfile
        tmp = tempfile.mkdtemp()
        patches = {
            "credit_rows": lambda: {},
            "claim_rows": lambda: {},
            "flow_24h": lambda *a, **k: {"approved": {"rows": 0, "users": 0, "paid": 0},
                                         "declined": {"rows": 0, "users": 0, "paid": 0}},
            "ledger_facts": lambda: m_qafacts(),
            "proof_feed": lambda: (frozenset(), {}),
            "watchlist_ids": lambda: (frozenset(), frozenset()),
            "merge_rows": lambda: {},
            "merges_24h": lambda: {"rows": 0, "users": 0},
            "clickup_merge_queue": lambda now: {},
            "probe_sources": lambda prev, now: {"unmeasured": set()},
            "read_sentinel_state": lambda: None,
            "write_sentinel_state": lambda state: None,
        }
        saved = {k: getattr(vqr, k) for k in patches}
        for k, fn in patches.items():
            setattr(vqr, k, fn)
        old = (vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK)
        vqr.STATE = os.path.join(tmp, "blocked", "last.json")   # parent is a FILE
        open(os.path.join(tmp, "blocked"), "w").close()
        vqr.SENTINEL_KILL = os.path.join(tmp, "kill")
        vqr.SENTINEL_LOCK = os.path.join(tmp, "l.lock")
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                rc = vqr.main(["vqr"])
        finally:
            for k, fn in saved.items():
                setattr(vqr, k, fn)
            vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK = old
        self.assertEqual(rc, 1, out.getvalue())
        self.assertIn("could not write", out.getvalue())


class IntercomDeltaResume(unittest.TestCase):
    """A stale watermark makes the delta window grow every tick, so "never advance on
    truncation" alone deadlocks: on 10-27 the watermark froze at 07:25Z and every tick
    truncated at ~30s, leaving the lane unmeasured for hours. A truncated scan must save a
    resume cursor."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def stub(self, truncated, cursor, seen):
        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            seen.append(start_after)
            return [], truncated, cursor
        return fake

    def test_a_truncated_delta_saves_its_cursor(self):
        seen = []
        old = vqr.intercom_search
        vqr.intercom_search = self.stub(True, "cur-42", seen)
        try:
            _, info = vqr.intercom_items(
                {"intercom": {"items": {}, "last_walk": "2026-10-27T07:25:01Z"}}, self.NOW)
        finally:
            vqr.intercom_search = old
        self.assertTrue(info["keep_walk"])
        self.assertEqual(info["cursor"], "cur-42")

    def test_the_next_tick_resumes_from_that_cursor(self):
        seen = []
        old = vqr.intercom_search
        vqr.intercom_search = self.stub(True, "cur-43", seen)
        try:
            vqr.intercom_items({"intercom": {"items": {},
                                             "last_walk": "2026-10-27T07:25:01Z",
                                             "delta_cursor": "cur-42"}}, self.NOW)
        finally:
            vqr.intercom_search = old
        self.assertEqual(seen[0], "cur-42", "the second tick must continue, not restart")


class QAa327b83(unittest.TestCase):
    """The five-minute tick must fail on a sentinel-state write failure too: Slack can accept a
    page, the ledger save can fail, and the next tick then re-pages the same breach."""

    def run_light(self):
        import contextlib
        import io
        import tempfile
        tmp = tempfile.mkdtemp()
        patches = {
            "probe_sources": lambda prev, now: {"unmeasured": set()},
            "read_sentinel_state": lambda: {"intercom": {"items": {}, "last_walk": "x"},
                                            "merges": {"items": {}}},
            "write_sentinel_state": lambda state: (_ for _ in ()).throw(OSError(28, "No space left")),
        }
        saved = {k: getattr(vqr, k) for k in patches}
        for k, fn in patches.items():
            setattr(vqr, k, fn)
        old = (vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK)
        vqr.STATE = os.path.join(tmp, "last.json")
        vqr.SENTINEL_KILL = os.path.join(tmp, "kill")
        vqr.SENTINEL_LOCK = os.path.join(tmp, "l.lock")
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                rc = vqr.main(["vqr", "--light"])
        finally:
            for k, fn in saved.items():
                setattr(vqr, k, fn)
            vqr.STATE, vqr.SENTINEL_KILL, vqr.SENTINEL_LOCK = old
        return rc, out.getvalue()

    def test_a_light_tick_fails_when_the_sentinel_state_cannot_be_saved(self):
        rc, text = self.run_light()
        self.assertEqual(rc, 1, text)
        self.assertIn("could not be persisted", text)


class EntrypointFailures(unittest.TestCase):
    """QA asked for the ENTRYPOINT to be exercised with a failed flow query, not just the
    helper: a stubbed main() must DM an INCOMPLETE line, never raise, and never write the
    arrows baseline. Everything that would touch Trino, the ledger, Intercom or Slack is
    replaced, so this runs anywhere."""

    def run_main(self, args, overrides=None):
        import contextlib
        import io
        patches = {
            "credit_rows": lambda: {1: {"paid": False, "n": 1, "oldest": "2026-10-01 00:00:00.000000 UTC",
                                        "core_ask": False, "reply_at": "", "core_reply": False,
                                        "needs_docs": True, "paid_n": 0}},
            "claim_rows": lambda: {2: {"paid": False, "n": 1, "oldest": "2026-10-01 00:00:00.000000 UTC",
                                       "profiles": [], "claims": ["9"], "paid_n": 0}},
            "flow_24h": lambda *a, **k: (_ for _ in ()).throw(RuntimeError("trino down")),
            "ledger_facts": lambda: {"asked": {}, "messaged": {}, "latest": {}, "decided": set(),
                                     "support": set(), "replied": set(), "proof_waiting": {},
                                     "muted": {}, "flagged": {}, "claim_notes": {},
                                     "claim_proofs": {}, "claim_replied": set(),
                                     "claim_muted": {}, "claim_flagged": {},
                                     "first_proof_hold": {}, "first_deadend": {},
                                     "support_contacts": set()},
            "proof_feed": lambda: (frozenset(), {}),
            "watchlist_ids": lambda: (frozenset(), frozenset()),
            "merge_rows": lambda: {},
            "merges_24h": lambda: {"rows": 0, "users": 0},
            "clickup_merge_queue": lambda now: {},
            "probe_sources": lambda prev, now: {"unmeasured": set()},
            "read_sentinel_state": lambda: None,
            "write_sentinel_state": lambda state: None,
            "pending_request_ids": lambda: ["r1", "r2", "r3"],
            "ask_gap": lambda pending: {"pending": len(pending), "ours": 2, "never_asked": 1},
            "intake_1h": lambda: {"requests": 4},
            "request_median_h": lambda family, now: 12.0,
        }
        patches.update(overrides or {})
        saved = {k: getattr(vqr, k) for k in patches}
        for k, fn in patches.items():
            setattr(vqr, k, fn)
        old_state, old_kit = vqr.STATE, vqr.SENTINEL_KILL
        old_lock = vqr.SENTINEL_LOCK
        import tempfile
        tmp = tempfile.mkdtemp()
        # KEEP the temp path: returning vqr.STATE after restoring it made both tests below
        # assert against the HOST's real state file — passing vacuously where it is absent
        # and failing where it exists (QA @99d61a6).
        tmp_state = os.path.join(tmp, "last.json")
        vqr.STATE = tmp_state
        vqr.SENTINEL_KILL = os.path.join(tmp, "kill")
        vqr.SENTINEL_LOCK = os.path.join(tmp, "sentinel.lock")
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = vqr.main(["vqr"] + args)
        finally:
            for k, fn in saved.items():
                setattr(vqr, k, fn)
            vqr.STATE, vqr.SENTINEL_KILL = old_state, old_kit
            vqr.SENTINEL_LOCK = old_lock
        return rc, out.getvalue() + err.getvalue(), tmp_state

    def test_a_failed_flow_query_reports_incomplete_and_never_traces_back(self):
        rc, text, state = self.run_main(["--dry-run"])
        self.assertIn("INCOMPLETE", text)
        self.assertNotIn("Traceback", text)
        self.assertIn("trino down", text)
        self.assertFalse(os.path.exists(state), "an incomplete report wrote a baseline")

    def test_an_incomplete_run_exits_non_zero_when_it_could_have_posted(self):
        rc, text, state = self.run_main([])
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(state))

    def test_the_saved_snapshot_is_what_the_standing_page_reads(self):
        """scripts/verification-standing.py takes open, decided and ages from the file THIS run
        saves. Run the real writer, hand its file to the real page: no hand-built snapshot."""
        flow = {"approved": {"rows": 3, "users": 2, "paid": 0}, "declined": {"rows": 0, "users": 0, "paid": 0}}
        rc, _, state = self.run_main([], {"flow_24h": lambda *a, **k: json.loads(json.dumps(flow))})
        self.assertEqual(rc, 0)
        with open(state) as fh:
            snap = json.load(fh)
        self.assertEqual(snap["errors"], [])
        self.assertEqual((snap["credits"]["age"]["users"], snap["credits"]["age"]["undated"]), (1, 0))
        spec = importlib.util.spec_from_file_location(
            "vstanding", os.path.join(os.path.dirname(SCRIPT), "verification-standing.py"))
        page_mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(page_mod)
        missing = os.path.join(os.path.dirname(state), "absent")
        page = page_mod.build(ledger=missing, snapshot=state, policy=missing, kill=missing,
                              now=page_mod.parse_ts(snap["at"]) + timedelta(minutes=5))
        for fam in page["families"]:
            self.assertEqual((fam["open"], fam["decided_24h"]["value"]), ({"value": 1, "stale": False}, 2), fam)
            self.assertEqual(fam["median_h"]["value"], snap[fam["family"]]["age"]["median_h"])
            self.assertEqual(fam["median_h"]["value"], 12.0)
            self.assertEqual(fam["oldest_h"]["value"], snap[fam["family"]]["age"]["oldest_h"])
            self.assertEqual((fam["waiting_us"]["value"], fam["waiting_user"]["value"]), (1, 0))
        self.assertEqual((snap["ours"], snap["intake_1h"]),
                         ({"pending": 3, "ours": 2, "never_asked": 1}, {"requests": 4}))
        self.assertEqual(page["tracking"]["ours"], {"value": 2, "stale": False, "pending": 3, "never_asked": 1})

    def test_a_failed_tracking_read_is_an_error_and_no_number(self):
        """OURS and the intake are read for the standing page. A read that fails leaves its key
        OUT of the saved file (a 0 there would be read as nothing waiting), fails the run, and
        does not stop the tables."""
        flow = {"approved": {"rows": 3, "users": 2, "paid": 0}, "declined": {"rows": 0, "users": 0, "paid": 0}}

        def boom(*a, **k):
            raise RuntimeError("the pending-request read returned no rows")

        rc, out, state = self.run_main([], {"flow_24h": lambda *a, **k: json.loads(json.dumps(flow)),
                                            "pending_request_ids": boom, "intake_1h": boom})
        self.assertEqual(rc, 1)
        with open(state) as fh:
            snap = json.load(fh)
        self.assertNotIn("ours", snap)
        self.assertNotIn("intake_1h", snap)
        self.assertEqual([e.split(":")[0] for e in snap["errors"]], ["ours", "intake"])
        self.assertEqual(snap["credits"]["open_users"], 1)
        self.assertEqual(vqr.incomplete_errors(snap["errors"]), [])

    def test_a_failed_median_read_is_an_error_and_no_number(self):
        """The per-request median is a read of its own. A read that fails leaves `median_h` OUT
        of the saved file (a 0 there would be read as a fresh backlog), fails the run, and does
        not stop the tables or the per-user figure."""
        flow = {"approved": {"rows": 3, "users": 2, "paid": 0}, "declined": {"rows": 0, "users": 0, "paid": 0}}

        def boom(family, now):
            raise RuntimeError("no open credits request has a readable time")

        rc, _, state = self.run_main([], {"flow_24h": lambda *a, **k: json.loads(json.dumps(flow)),
                                          "request_median_h": boom})
        self.assertEqual(rc, 1)
        with open(state) as fh:
            snap = json.load(fh)
        self.assertNotIn("median_h", snap["credits"]["age"])
        self.assertIn("oldest_per_user_median_h", snap["credits"]["age"])
        self.assertEqual([e.split(":")[0] for e in snap["errors"]], ["credits median", "claims median"])
        self.assertEqual(snap["credits"]["open_users"], 1)

    def test_a_light_tick_reads_no_tracking_number(self):
        calls = []

        def seen(*a, **k):
            calls.append(1)
            return {"requests": 1}

        self.run_main(["--light"], {"pending_request_ids": seen, "ask_gap": seen, "intake_1h": seen,
                                    "request_median_h": seen})
        self.assertEqual(calls, [])


DOCS_IN_OWNER = "verification worker, creds home (firstmate-assigned 2026-11-13)"


class HeldByCaptainOrder(unittest.TestCase):
    """Captain 2026-10-27 00:52Z: four lanes are held by his own order. They stay visible and
    page once per CHANGE, never per tick, and never as "backlog forming" — while a breach in
    any other lane still pages at once."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def page(self, items, bucket="credits_docs_in", prev=None, delivered=True):
        ev = vqr.sentinel_evaluate({"items": {bucket: items}, "unmeasured": set()}, self.NOW)
        msgs, state, page_map = vqr.sentinel_page(ev, prev, self.NOW, False)
        # a held signature is only persisted once Slack confirmed the page
        state = vqr.record_paged(state, page_map, [delivered] * len(page_map))
        return msgs, state, page_map

    def test_a_held_lane_pages_as_held_not_as_backlog_forming(self):
        msgs, state, _ = self.page([("user:1", "2026-10-27T00:00:00Z")])
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG HELD BY CAPTAIN ORDER"))
        self.assertIn("owner " + DOCS_IN_OWNER, msgs[0])
        self.assertIn("unblock:", msgs[0])
        self.assertIn("credits_docs_in", state["held"])

    def test_the_same_held_breach_does_not_page_again(self):
        _, state, _ = self.page([("user:1", "2026-10-27T00:00:00Z")])
        msgs, _, _ = self.page([("user:1", "2026-10-27T00:00:00Z")], prev=state)
        self.assertEqual(msgs, [])

    def test_a_change_in_a_held_lane_pages_once_more(self):
        _, state, _ = self.page([("user:1", "2026-10-27T00:00:00Z")])
        msgs, _, _ = self.page([("user:1", "2026-10-27T00:00:00Z"),
                                ("user:2", "2026-10-27T00:00:00Z")], prev=state)
        self.assertEqual(len(msgs), 1)
        self.assertIn("2 items", msgs[0])

    def test_a_breach_in_another_lane_still_pages_immediately(self):
        _, state, _ = self.page([("user:1", "2026-10-27T00:00:00Z")])
        ev = vqr.sentinel_evaluate({"items": {"claims_docs_in": [
            ("user:3", "2026-10-27T00:00:00Z")]}, "unmeasured": set()}, self.NOW)
        msgs, state, _ = vqr.sentinel_page(ev, state, self.NOW, False)
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG FORMING"))

    def test_a_rejected_held_page_is_retried_on_the_next_tick(self):
        # QA @f64ebbb: the signature used to be stored before delivery, so a rejected Slack
        # post meant the held lane never paged again for the same count/oldest.
        msgs, state, _ = self.page([("user:1", "2026-10-27T00:00:00Z")], delivered=False)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(state.get("held"), {})          # not recorded as told
        again, _, _ = self.page([("user:1", "2026-10-27T00:00:00Z")], prev=state)
        self.assertEqual(len(again), 1)                  # retried

    def test_a_held_lane_that_drains_leaves_the_state_and_the_report(self):
        # Fable's document rule emptied credits_docs_in on prod: the held row must go with it,
        # not linger in the report with a sentence about a lane that no longer has anything.
        _, state, _ = self.page([("user:1", "2026-10-27T00:00:00Z")])
        self.assertIn("credits_docs_in", state["held"])
        ev = vqr.sentinel_evaluate({"items": {"credits_docs_in": []}, "unmeasured": set()},
                                   self.NOW)
        _, state2, _ = vqr.sentinel_page(ev, state, self.NOW, False)
        self.assertNotIn("credits_docs_in", state2["held"])

    def test_the_four_held_lanes_are_the_ones_the_captain_named(self):
        self.assertEqual(set(vqr.CAPTAIN_HELD), {"credits_docs_in", "claims_untouched",
                                                 "fable_decider", "intercom_customer_last"})


class HeldLanesFromLiveState(unittest.TestCase):
    """firstmate 038/039 (2026-10-27): a held page named a blocker that had already shipped
    ("ship the account gate", live since 06:30Z), re-paged every hour because the oldest item
    aged (120 held pages on 10-27), and named the wrong owner for returned documents."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)
    ITEMS = [("user:1", "2026-10-27T00:00:00Z"), ("user:2", "2026-10-27T01:00:00Z")]

    def page(self, items, bucket="credits_docs_in", prev=None, now=None, facts=None, lanes=None):
        now = now or self.NOW
        ev = vqr.sentinel_evaluate({"items": {bucket: items}, "unmeasured": set()}, now)
        msgs, state, page_map = vqr.sentinel_page(ev, prev, now, False, facts, lanes)
        return msgs, vqr.record_paged(state, page_map, [True] * len(page_map))

    def test_an_aging_held_lane_does_not_page_again(self):
        _, state = self.page(self.ITEMS)
        for hours in (1, 2, 6, 30):
            msgs, state = self.page(self.ITEMS, prev=state, now=self.NOW + timedelta(hours=hours))
            self.assertEqual(msgs, [], f"re-paged after {hours}h with the same items")

    def test_a_new_item_in_a_held_lane_pages_once(self):
        _, state = self.page(self.ITEMS)
        msgs, _ = self.page(self.ITEMS + [("user:3", "2026-10-27T02:00:00Z")], prev=state)
        self.assertEqual(len(msgs), 1)
        self.assertIn("3 items", msgs[0])

    def test_a_swapped_item_with_the_same_count_pages(self):
        _, state = self.page(self.ITEMS)
        msgs, _ = self.page([("user:1", "2026-10-27T00:00:00Z"), ("user:9", "2026-10-27T01:00:00Z")],
                            prev=state)
        self.assertEqual(len(msgs), 1)

    def test_a_pre_fix_state_file_does_not_re_page_on_deploy(self):
        prev = {"held": {"credits_docs_in": {"count": 2, "oldest_h": 45}}}
        msgs, _ = self.page(self.ITEMS, prev=prev)
        self.assertEqual(msgs, [])

    def test_the_decider_lane_names_the_kill_switch_once_the_gate_is_live(self):
        facts = {"account_gate_live": True, "decide_switch": True}
        msgs, _ = self.page(self.ITEMS, bucket="fable_decider", facts=facts)
        self.assertEqual(len(msgs), 1)
        self.assertNotIn("ship the account gate", msgs[0])
        self.assertIn("credit-trust-decide.disabled", msgs[0])
        self.assertIn("the account gate is live", msgs[0])
        self.assertIn("the captain lifts the approval pause", msgs[0])

    def test_the_decider_lane_is_not_held_when_gate_live_and_switch_gone(self):
        facts = {"account_gate_live": True, "decide_switch": False}
        msgs, _ = self.page(self.ITEMS, bucket="fable_decider", facts=facts)
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG FORMING"))

    def test_a_blocker_sentence_change_pages_once(self):
        _, state = self.page(self.ITEMS, bucket="fable_decider",
                             facts={"account_gate_live": False, "decide_switch": None})
        msgs, _ = self.page(self.ITEMS, bucket="fable_decider", prev=state,
                            facts={"account_gate_live": True, "decide_switch": True})
        self.assertEqual(len(msgs), 1)
        self.assertIn("credit-trust-decide.disabled", msgs[0])

    def test_claims_lane_says_claim_status_is_live_when_its_lock_is_on(self):
        facts = {"claim_status_on": True, "claim_proof_ask_on": False}
        msgs, _ = self.page(self.ITEMS, bucket="claims_untouched", facts=facts)
        self.assertIn("#1377 is live", msgs[0])
        self.assertNotIn("behind hydra #1377 review", msgs[0])

    def test_owner_and_eta_come_from_the_policy_file(self):
        lanes = {"credits_docs_in": {"owner": "lane-x", "eta": "tonight", "unblock": "reader live"}}
        msgs, _ = self.page(self.ITEMS, lanes=lanes)
        self.assertIn("owner lane-x", msgs[0])
        self.assertIn("ETA tonight", msgs[0])
        self.assertIn("unblock: reader live", msgs[0])

    def test_a_malformed_policy_file_falls_back_and_still_pages(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write("{not json")
        try:
            self.assertEqual(vqr.read_held_lanes(fh.name), {})
        finally:
            os.unlink(fh.name)
        msgs, _ = self.page(self.ITEMS, lanes={})
        self.assertEqual(len(msgs), 1)

    def test_the_repo_policy_file_covers_every_held_lane(self):
        lanes = vqr.read_held_lanes()
        self.assertEqual(set(lanes), set(vqr.CAPTAIN_HELD))
        self.assertEqual(lanes["credits_docs_in"]["owner"], DOCS_IN_OWNER)

    def test_the_held_claims_lane_is_owned_by_the_creds_home(self):
        """2026-11-13: the creds home owns the claim breaches; the page names it from the policy file."""
        lanes = vqr.read_held_lanes()
        self.assertEqual(lanes["claims_untouched"]["owner"], "creds")
        held = vqr.held_lane("claims_untouched", vqr._EMPTY_FACTS(), lanes)
        self.assertEqual(held["owner"], "creds")

    def test_the_docs_in_page_names_the_write_back_and_no_closed_lane(self):
        """2026-11-13: the page said the reader was not live for 17 days after it went live,
        and named two lanes that had already closed. Both are asserted on the rendered page."""
        facts = {"doc_reader_state": "live", "doc_writeback_approved": False,
                 "doc_reader_last_step": "2026-11-13T15:58:00Z"}
        msgs, _ = self.page(self.ITEMS, facts=facts)
        self.assertEqual(len(msgs), 1)
        self.assertIn("nothing writes its verdict back", msgs[0])
        self.assertNotIn("not live", msgs[0])
        self.assertNotIn("2026-10-27", msgs[0])
        for closed_lane in ("doc-verify-build-b1", "user-decisions-fable-d1"):
            self.assertNotIn(closed_lane, msgs[0])
        self.assertIn("owner " + DOCS_IN_OWNER, msgs[0])
        # an ETA is a decision or nothing, never a date (a date goes stale; this one did)
        self.assertIn("ETA when the captain decides", msgs[0])

    def test_live_facts_read_the_real_locks_and_switch(self):
        d = tempfile.mkdtemp()
        sh = os.path.join(d, "ivr.sh"); open(sh, "w").write(
            "readonly CLAIM_PROOF_ASK_COPY_APPROVED=0\nreadonly CLAIM_STATUS_COPY_APPROVED=1\n")
        sa = os.path.join(d, "sa.py"); open(sa, "w").write("from x import account_gate\n")
        gate = os.path.join(d, "account_gate.py"); open(gate, "w").write("")
        sw = os.path.join(d, "decide.disabled"); open(sw, "w").write("")
        reg = os.path.join(d, "registry.json")
        with open(reg, "w") as fh:
            json.dump({"automations": {vqr.DOC_APPROVAL_AUTOMATION: {"approved": False}}}, fh)
        with mock.patch.multiple(vqr, VERIFY_REQUEST_SH=sh, SCORE_APPROVE_PY=sa, GATE_SCRIPT=gate,
                                 DECIDE_SWITCH=sw, APPROVAL_REGISTRY=reg,
                                 DOC_VERIFY_STORE=os.path.join(d, "no-such-store.sqlite")):
            f = vqr.held_facts()
        self.assertEqual(f, {"account_gate_live": True, "decide_switch": True,
                             "claim_status_on": True, "claim_proof_ask_on": False,
                             "doc_reader_state": "unknown", "doc_reader_last_step": None,
                             "doc_writeback_approved": False})


class DocsInHeldSentenceFromLiveState(unittest.TestCase):
    """2026-11-13: the docs_in page went on saying the reader was "not live yet" for 17 days
    after the reader went live, because this lane was the one held lane whose
    sentence was never read from the box. The reader's own store and the approval registry
    now decide it; the policy file is what is said when the store cannot be read."""

    NOW = datetime(2026, 11, 13, 16, 0, tzinfo=timezone.utc)
    ITEMS = [("user:1", "2026-10-26T00:00:00Z"), ("user:2", "2026-11-10T00:00:00Z")]
    LIVE = {"doc_reader_state": "live", "doc_reader_last_step": "2026-11-13T15:58:00Z",
            "doc_writeback_approved": False}
    STOPPED = {"doc_reader_state": "stopped", "doc_reader_last_step": "2026-11-09T04:00:00Z",
               "doc_writeback_approved": False}
    CAUGHT_UP = {"doc_reader_state": "caught_up", "doc_reader_last_step": "2026-11-13T10:00:00Z",
                 "doc_writeback_approved": False}
    BLIND = {"doc_reader_state": "unknown", "doc_reader_last_step": None,
             "doc_writeback_approved": False}
    BYTES_OWED = {"doc_reader_state": "bytes_owed",
                  "doc_reader_last_step": "2026-11-09T04:00:00Z",
                  "doc_writeback_approved": False}
    # the other lanes' facts, as the box reads today
    OTHERS = {"account_gate_live": True, "decide_switch": True,
              "claim_status_on": True, "claim_proof_ask_on": False}

    def store(self, step_at=None, outcomes=(), steps=(), blobs=()):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "doc-verify.sqlite")
        db = sqlite3.connect(path)
        db.execute("create table dv_steps (id integer primary key autoincrement, at text, "
                   "proof_id text)")
        db.execute("create table dv_outcomes (id integer primary key autoincrement, at text, "
                   "user_id integer)")
        db.execute("create table dv_blobs (sha256 text primary key, at text, source text)")
        if step_at:
            db.execute("insert into dv_steps (at) values (?)", (step_at,))
        db.executemany("insert into dv_steps (at, proof_id) values (?, ?)", list(steps))
        db.executemany("insert into dv_outcomes (at, user_id) values (?, ?)", list(outcomes))
        db.executemany("insert into dv_blobs (sha256, at, source) values (?, '2026-11-01T00:00:00Z', "
                       "'intercom')", [(sha,) for sha in blobs])
        db.commit()
        db.close()
        return path

    def blobs(self, stored=()):
        """The blob store the reader reads bytes from, `<root>/<sha[:2]>/<sha>`."""
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        for sha in stored:
            os.makedirs(os.path.join(d, sha[:2]), exist_ok=True)
            with open(os.path.join(d, sha[:2], sha), "wb") as fh:
                fh.write(b"%PDF-1.4")
        return d

    def blob_root(self, stored=()):
        old = vqr.DOC_BLOB_ROOT
        vqr.DOC_BLOB_ROOT = self.blobs(stored)
        self.addCleanup(setattr, vqr, "DOC_BLOB_ROOT", old)

    def proof_store(self, filings=()):
        """The returned documents: (file_sha256, received_at, candidate_request_ids_json,
        subject, conversation_id). intake_id is `<user_id>:<sha256 prefix>` and subject defaults
        to credit, as production files them, so a join on the wrong identifier cannot pass
        here."""
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "proof.sqlite")
        db = sqlite3.connect(path)
        db.execute("create table proof_intake (intake_id text primary key, subject text, "
                   "file_sha256 text, received_at text, candidate_request_ids_json text, "
                   "conversation_id text)")
        rows = []
        for n, filing in enumerate(filings, start=1):
            sha, at, cands = filing[:3]
            subject = filing[3] if len(filing) > 3 else "credit"
            convo = filing[4] if len(filing) > 4 else "conv-1"
            rows.append((f"{n}:{sha[:32]}", subject, sha, at, cands, convo))
        db.executemany(
            "insert into proof_intake (intake_id, subject, file_sha256, received_at, "
            "candidate_request_ids_json, conversation_id) values (?, ?, ?, ?, ?, ?)", rows)
        db.commit()
        db.close()
        return path

    def registry(self, entry):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "registry.json")
        with open(path, "w") as fh:
            json.dump({"automations": {vqr.DOC_APPROVAL_AUTOMATION: entry}}, fh)
        return path

    def page(self, facts, prev=None, now=None):
        now = now or self.NOW
        ev = vqr.sentinel_evaluate({"items": {"credits_docs_in": self.ITEMS},
                                    "unmeasured": set()}, now)
        msgs, state, page_map = vqr.sentinel_page(ev, prev, now, False, facts,
                                                  vqr.read_held_lanes())
        return msgs, vqr.record_paged(state, page_map, [True] * len(page_map))

    # -- the sentence ------------------------------------------------------------------

    def test_a_live_reader_names_the_missing_write_back(self):
        spec = vqr.held_lane("credits_docs_in", self.LIVE, vqr.read_held_lanes())
        self.assertNotIn("not live", spec["reason"])
        self.assertIn("reader is live and reading", spec["reason"])
        self.assertIn("nothing writes its verdict back", spec["reason"])
        self.assertIn(vqr.DOC_APPROVAL_AUTOMATION + " is approved=false", spec["reason"])
        self.assertIn("write-back", spec["unblock"])
        self.assertEqual(spec["owner"], DOCS_IN_OWNER)
        self.assertEqual(spec["eta"], "when the captain decides")

    def test_a_live_reader_with_no_policy_file_still_says_so(self):
        spec = vqr.held_lane("credits_docs_in", self.LIVE, {})
        self.assertIn("reader is live and reading", spec["reason"])
        self.assertIn("nothing writes its verdict back", spec["reason"])
        self.assertEqual(spec["eta"], "when the captain decides")

    def test_a_stopped_reader_is_named_and_never_called_live(self):
        spec = vqr.held_lane("credits_docs_in", self.STOPPED, vqr.read_held_lanes())
        self.assertIn("returned-document reader has stopped reading", spec["reason"])
        self.assertIn("2026-11-09T04:00:00Z", spec["reason"])
        self.assertNotIn("reader is live", spec["reason"])
        self.assertIn("restart the reader", spec["unblock"])
        self.assertIn("write-back", spec["unblock"])

    def test_a_stopped_reader_says_the_write_back_as_measured(self):
        """A stopped reader is one claim; whether anything writes a verdict back is another,
        and it is read from the same registry on this path as on every other."""
        lanes = vqr.read_held_lanes()
        off = vqr.held_lane("credits_docs_in", self.STOPPED, lanes)["reason"]
        self.assertIn("nothing writes a doc-verify verdict back", off)
        on = vqr.held_lane("credits_docs_in", dict(self.STOPPED, doc_writeback_approved=True),
                           lanes)["reason"]
        self.assertIn("registered approved", on)
        self.assertNotIn("nothing writes", on)
        blind = vqr.held_lane("credits_docs_in", dict(self.STOPPED, doc_writeback_approved=None),
                              lanes)["reason"]
        self.assertIn("was not measured", blind)
        self.assertNotIn("nothing writes", blind)

    def test_a_reader_with_nothing_to_read_is_caught_up_not_stopped(self):
        spec = vqr.held_lane("credits_docs_in", self.CAUGHT_UP, vqr.read_held_lanes())
        self.assertIn("in the newest filings", spec["reason"])
        self.assertNotIn("stopped", spec["reason"])
        self.assertNotIn("restart the reader", spec["unblock"])
        self.assertIn("nothing writes its verdict back", spec["reason"])

    def test_a_reader_left_only_with_bytes_owed_filings_is_neither_stopped_nor_caught_up(self):
        """The reader cannot read a filing whose bytes were never stored, so a restart clears
        nothing: the page must not call it stopped, and must not say there was nothing left."""
        spec = vqr.held_lane("credits_docs_in", self.BYTES_OWED, vqr.read_held_lanes())
        self.assertIn("not the blocker", spec["reason"])
        self.assertNotIn("stopped", spec["reason"])
        self.assertIn("in the newest filings", spec["reason"])
        self.assertNotIn("every returned credit document it can read has been read",
                         spec["reason"])
        self.assertIn("blob-backfill", spec["unblock"])
        self.assertNotIn("restart the reader", spec["unblock"])
        self.assertIn("nothing writes its verdict back", spec["reason"])
        self.assertIn("write-back", spec["unblock"])
        self.assertEqual(spec["owner"], DOCS_IN_OWNER)

    def test_an_unmeasured_reader_is_never_called_live_or_stopped(self):
        lanes = vqr.read_held_lanes()
        for facts in ({}, {"doc_reader_state": None, "doc_writeback_approved": False},
                      self.BLIND):
            spec = vqr.held_lane("credits_docs_in", facts, lanes)
            self.assertIn("was not measured", spec["reason"])
            self.assertNotIn("reader is live", spec["reason"])
            self.assertNotIn("has stopped reading", spec["reason"])
            self.assertNotIn("caught up", spec["reason"])
            self.assertNotIn(lanes["credits_docs_in"]["reason"], spec["reason"])
            self.assertEqual(spec["owner"], DOCS_IN_OWNER)

    def test_an_unread_registry_is_said_as_unmeasured(self):
        spec = vqr.held_lane("credits_docs_in", dict(self.LIVE, doc_writeback_approved=None),
                             vqr.read_held_lanes())
        self.assertIn("reader is live and reading", spec["reason"])
        self.assertIn("was not measured", spec["reason"])
        self.assertNotIn("nothing writes", spec["reason"])

    def test_an_approved_document_path_is_not_called_missing(self):
        spec = vqr.held_lane("credits_docs_in", dict(self.LIVE, doc_writeback_approved=True),
                             vqr.read_held_lanes())
        self.assertIn("registered approved", spec["reason"])
        self.assertNotIn("nothing writes", spec["reason"])
        self.assertNotIn("captain decides", spec["unblock"])

    def test_no_reader_state_brings_the_false_sentence_back(self):
        lanes = vqr.read_held_lanes()
        for state in ("live", "stopped", "caught_up", "bytes_owed", "unknown", None):
            for armed in (True, False, None):
                facts = {"doc_reader_state": state, "doc_writeback_approved": armed,
                         "doc_reader_last_step": "2026-11-09T04:00:00Z"}
                for file_lanes in (lanes, {}):
                    spec = vqr.held_lane("credits_docs_in", facts, file_lanes)
                    self.assertNotIn("not live", json.dumps(spec), (state, armed))
                    self.assertNotIn("2026-10-27", json.dumps(spec), (state, armed))
                    self.assertTrue(spec["reason"], (state, armed))

    # -- the page ----------------------------------------------------------------------

    def test_the_page_carries_the_live_sentence(self):
        msgs, _ = self.page(self.LIVE)
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG HELD BY CAPTAIN ORDER"))
        self.assertIn("reader is live and reading", msgs[0])
        self.assertIn("nothing writes its verdict back", msgs[0])
        self.assertIn("owner " + DOCS_IN_OWNER, msgs[0])
        self.assertNotIn("not live", msgs[0])

    def test_a_working_reader_does_not_page_again_as_its_latest_step_moves(self):
        """The reason is part of the held signature, so nothing that moves while the reader
        works may be in it: 6 ticks an hour would be 6 pages an hour."""
        _, state = self.page(self.LIVE)
        for minutes in (5, 30, 65, 600):
            now = self.NOW + timedelta(minutes=minutes)
            facts = dict(self.LIVE, doc_reader_last_step=now.strftime("%Y-%m-%dT%H:%M:%SZ"))
            msgs, state = self.page(facts, prev=state, now=now)
            self.assertEqual(msgs, [], f"re-paged {minutes} min later with a newer step")

    def test_a_reader_that_stops_pages_once(self):
        _, state = self.page(self.LIVE)
        msgs, state = self.page(self.STOPPED, prev=state, now=self.NOW + timedelta(hours=30))
        self.assertEqual(len(msgs), 1)
        self.assertIn("has stopped reading", msgs[0])
        msgs, state = self.page(self.STOPPED, prev=state, now=self.NOW + timedelta(hours=31))
        self.assertEqual(msgs, [])

    def test_a_store_that_cannot_be_read_for_one_tick_pages_once_not_every_tick(self):
        _, state = self.page(self.LIVE)
        msgs, state = self.page(self.BLIND, prev=state, now=self.NOW + timedelta(minutes=5))
        self.assertEqual(len(msgs), 1)
        self.assertIn("was not measured", msgs[0])
        self.assertNotIn("not live", msgs[0])
        msgs, state = self.page(self.BLIND, prev=state, now=self.NOW + timedelta(minutes=10))
        self.assertEqual(msgs, [])

    # -- the report's held block --------------------------------------------------------

    STORED = {"credits_docs_in": {
        "count": 296, "items_sha": "abc", "oldest_h": 446, "label": "credit documents back",
        "owner": "user-decisions-fable-d1 (review) + doc-verify-build-b1 (reader go-live)",
        "eta": "backfill the night of 2026-10-27",
        "unblock": "doc-verify-build-b1 takes the reader live",
        # the stored sentence, split so a grep for it across the repo stays empty
        "reason": "no paperwork asks until a returned document can be accepted: "
                  "the returned-document reader is " "not live yet"}}

    def test_the_report_says_todays_sentence_not_the_last_delivered_one(self):
        """The state file keeps the words of the last DELIVERED page. A dry run, a rejected
        page or the sentinel kill switch leave them there, and the report printed them."""
        shown = vqr.held_words_now(self.STORED, self.LIVE, vqr.read_held_lanes())
        row = shown["credits_docs_in"]
        self.assertNotIn("not live", json.dumps(shown))
        self.assertNotIn("2026-10-27", json.dumps(shown))
        self.assertIn("reader is live and reading", row["reason"])
        self.assertIn("write-back", row["unblock"])
        self.assertEqual(row["owner"], DOCS_IN_OWNER)
        # the dedupe record is the stored one: only the words are today's
        self.assertEqual(row["count"], 296)
        self.assertEqual(row["items_sha"], "abc")
        self.assertEqual(row["oldest_h"], 446)
        # and the stored row itself is not rewritten
        self.assertIn("not live", self.STORED["credits_docs_in"]["reason"])

    def test_the_held_block_prints_this_ticks_count_and_age(self):
        """The stored numbers are the dedupe record of the last delivered page; the report
        prints what this tick measured, next to the sentence this tick derived."""
        shown = vqr.held_words_now(self.STORED, self.CAUGHT_UP, vqr.read_held_lanes(),
                                   {"credits_docs_in": (312, 470)})
        row = shown["credits_docs_in"]
        self.assertEqual((row["count"], row["oldest_h"]), (312, 470))
        self.assertEqual(row["items_sha"], "abc")
        self.assertIn("in the newest filings", row["reason"])
        self.assertNotIn("not live", row["reason"])

    def test_a_lane_whose_words_did_not_change_is_shown_as_stored(self):
        lanes = vqr.read_held_lanes()
        spec = vqr.held_lane("intercom_customer_last", self.OTHERS, lanes)
        stored = {"intercom_customer_last": {
            "count": 49, "items_sha": "def", "oldest_h": 44, "label": "Intercom",
            "owner": spec["owner"], "eta": spec["eta"], "unblock": spec["unblock"],
            "reason": spec["reason"]}}
        for reader in (self.LIVE, self.STOPPED, self.CAUGHT_UP, self.BLIND, {}):
            self.assertEqual(vqr.held_words_now(stored, dict(self.OTHERS, **reader), lanes), stored)
        self.assertEqual(vqr.held_words_now({}, self.LIVE, lanes), {})
        self.assertEqual(vqr.held_words_now(stored, None, None)["intercom_customer_last"]["count"], 49)

    # -- the reads ---------------------------------------------------------------------

    def test_a_step_inside_the_hour_is_live(self):
        f = vqr.doc_reader_facts(self.store("2026-11-13T15:20:00Z"), self.NOW)
        self.assertEqual(f["doc_reader_state"], "live")
        self.assertEqual(f["doc_reader_last_step"], "2026-11-13T15:20:00Z")

    def test_a_user_judged_inside_24_hours_is_live_without_a_fresh_step(self):
        f = vqr.doc_reader_facts(
            self.store("2026-11-13T02:00:00Z", [("2026-11-12T17:00:00Z", 7)]), self.NOW)
        self.assertEqual(f["doc_reader_state"], "live")

    def test_an_old_step_with_a_document_waiting_is_stopped(self):
        f = vqr.doc_reader_facts(
            self.store("2026-11-09T04:00:00Z", [("2026-11-09T03:00:00Z", 7)]), self.NOW,
            self.proof_store([("doc-1", "2026-11-13T10:00:00Z", '["req-1"]')]))
        self.assertEqual(f["doc_reader_state"], "stopped")
        self.assertEqual(f["doc_reader_last_step"], "2026-11-09T04:00:00Z")

    def test_a_quiet_step_with_nothing_waiting_is_caught_up(self):
        path = self.store("2026-11-09T04:00:00Z", steps=[
            ("2026-11-13T10:00:00Z", "doc-1")])
        read = self.proof_store([("doc-1", "2026-11-13T10:00:00Z", '["req-1"]')])
        self.assertEqual(vqr.doc_reader_facts(path, self.NOW, read)["doc_reader_state"],
                         "caught_up")
        # a claim filing is not work the credit pass was given, and an empty feed is no work
        for filings in ([("doc-3", "2026-11-09T00:00:00Z", '["req-2"]', "claim")], []):
            self.assertEqual(
                vqr.doc_reader_facts(path, self.NOW, self.proof_store(filings))
                ["doc_reader_state"], "caught_up", filings)

    def test_a_filing_with_no_usable_request_is_not_evidence_the_reader_stopped(self):
        """The reader skips a filing whose candidates carry no usable id, so no step will ever
        appear for it: it is unreadable, never a sign that the reader stopped."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-09T03:00:00Z", "doc-9")])
        for cands in ("[]", "[null]", '[""]', "not json"):
            self.assertEqual(
                vqr.doc_reader_facts(path, self.NOW,
                                     self.proof_store([("doc-2", "2026-11-13T10:00:00Z", cands)]))
                ["doc_reader_state"], "bytes_owed", cands)

    def test_a_filing_whose_bytes_were_never_stored_is_owed_not_waiting(self):
        """A support@ filing keeps no bytes, and no run pulls Gmail: the reader is not the
        blocker and restarting it clears nothing. An Intercom filing with no stored blob is
        still fetched from the conversation attachment, so that one is readable work."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-09T03:00:00Z", "doc-9")])
        self.blob_root()
        owed = vqr.doc_reader_facts(
            path, self.NOW, self.proof_store([("doc-1", "2026-11-13T10:00:00Z", '["req-1"]',
                                               "credit", "gmail:18f")]))
        self.assertEqual(owed["doc_reader_state"], "bytes_owed")
        readable = vqr.doc_reader_facts(
            path, self.NOW, self.proof_store([("doc-2", "2026-11-13T10:00:00Z", '["req-1"]',
                                               "credit", "1283312")]))
        self.assertEqual(readable["doc_reader_state"], "stopped")

    def test_stored_bytes_are_readable_work_and_a_deleted_one_is_owed(self):
        """Selection follows the reader's own rule: bytes on file are work; a registration whose
        blob was deleted is never re-fetched, so it is owed."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-09T03:00:00Z", "doc-9")],
                          blobs=["b" * 64])
        stored, deleted = "a" * 64, "b" * 64
        self.blob_root([stored])
        self.assertEqual(
            vqr.doc_reader_facts(
                path, self.NOW,
                self.proof_store([(stored, "2026-11-13T10:00:00Z", '["req-1"]', "credit",
                                   "gmail:1")]))["doc_reader_state"], "stopped")
        self.assertEqual(
            vqr.doc_reader_facts(
                path, self.NOW,
                self.proof_store([(deleted, "2026-11-13T10:00:00Z", '["req-1"]', "credit",
                                   "1283312")]))["doc_reader_state"], "bytes_owed")

    def test_a_readable_filing_older_than_the_window_never_reads_as_whole_store_read(self):
        """The waiting read inspects only the newest DOC_READER_WAIT_ROWS filings. An older
        readable filing left unread while the newest ones are all owed is outside that window,
        so the bytes_owed sentence may claim only the newest filings -- never the whole store."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-09T03:00:00Z", "doc-9")])
        self.blob_root(["old-readable"])
        filings = [("old-readable", "2026-11-13T10:00:00Z", '["req-1"]', "credit",
                    "1283312")]
        filings += [(f"owed-{n}", "2026-11-13T10:00:00Z", '["req-1"]', "credit",
                     "gmail:1") for n in range(vqr.DOC_READER_WAIT_ROWS)]
        facts = vqr.doc_reader_facts(path, self.NOW, self.proof_store(filings))
        self.assertEqual(facts["doc_reader_state"], "bytes_owed")
        spec = vqr.held_lane("credits_docs_in", facts, vqr.read_held_lanes())
        self.assertIn("in the newest filings", spec["reason"])
        self.assertNotIn("every returned credit document it can read has been read",
                         spec["reason"])

    def test_a_quiet_step_with_an_unreadable_blob_registry_is_unmeasured(self):
        """Whether a filing's bytes were ever stored is what separates readable work from a blob
        the reader skips. An unreadable registry must not silently call every filing readable
        and page a healthy reader as stopped: the state is unmeasured."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-09T03:00:00Z", "doc-9")])
        db = sqlite3.connect(path)
        db.execute("drop table dv_blobs")
        db.commit()
        db.close()
        self.blob_root()
        proof = self.proof_store([("doc-1", "2026-11-13T10:00:00Z", '["req-1"]',
                                   "credit", "1283312")])
        self.assertEqual(vqr.doc_reader_facts(path, self.NOW, proof)["doc_reader_state"],
                         "unknown")

    def test_a_document_sent_days_ago_and_filed_now_is_still_waiting(self):
        """`received_at` is when the customer sent the document, not when the feeder filed it:
        a feeder that paused for days files old documents, and the reader is idle on them."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-09T03:00:00Z", "doc-9")])
        for received in ("2026-11-06T10:00:00Z", "2026-11-11T10:00:00Z"):
            self.assertEqual(
                vqr.doc_reader_facts(path, self.NOW,
                                     self.proof_store([("doc-1", received, '["req-1"]')]))
                ["doc_reader_state"], "stopped", received)

    def test_a_read_document_is_matched_by_its_sha_not_its_intake_id(self):
        """doc-verify keys every step by the document's sha256; intake_id is
        `<user_id>:<sha256 prefix>` and equals no step, so joining on it can never see a read."""
        path = self.store("2026-11-09T04:00:00Z", steps=[("2026-11-13T10:00:00Z", "doc-1")])
        read = self.proof_store([("doc-1", "2026-11-13T10:00:00Z", '["req-1"]')])
        self.assertEqual(vqr.doc_reader_facts(path, self.NOW, read)["doc_reader_state"],
                         "caught_up")

    def test_a_quiet_step_with_an_unreadable_proof_feed_is_unmeasured(self):
        path = self.store("2026-11-09T04:00:00Z")
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        foreign = os.path.join(d, "other.sqlite")
        sqlite3.connect(foreign).execute("create table t (x)").connection.close()
        for proof in ("/nonexistent/proof.sqlite", foreign):
            self.assertEqual(vqr.doc_reader_facts(path, self.NOW, proof)["doc_reader_state"],
                             "unknown")

    def test_the_thresholds_are_the_named_constants(self):
        proof = self.proof_store([("doc-1", "2026-11-13T10:00:00Z", '["req-1"]')])
        edge = self.NOW - vqr.DOC_READER_STEP_FRESH
        inside = vqr.doc_reader_facts(self.store(edge.strftime("%Y-%m-%dT%H:%M:%SZ")), self.NOW,
                                      proof)
        self.assertEqual(inside["doc_reader_state"], "live")
        past = edge - timedelta(seconds=1)
        outside = vqr.doc_reader_facts(self.store(past.strftime("%Y-%m-%dT%H:%M:%SZ")), self.NOW,
                                       proof)
        self.assertEqual(outside["doc_reader_state"], "stopped")
        self.assertEqual(vqr.DOC_READER_STEP_FRESH, timedelta(hours=1))
        self.assertEqual(vqr.DOC_READER_JUDGED_WINDOW, timedelta(hours=24))

    def test_an_empty_store_is_caught_up_and_a_missing_or_foreign_one_is_unknown(self):
        self.assertEqual(
            vqr.doc_reader_facts(self.store(), self.NOW, self.proof_store())["doc_reader_state"],
            "caught_up")
        missing = vqr.doc_reader_facts("/nonexistent/doc-verify.sqlite", self.NOW)
        self.assertEqual(missing["doc_reader_state"], "unknown")
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        foreign = os.path.join(d, "other.sqlite")
        sqlite3.connect(foreign).execute("create table t (x)").connection.close()
        self.assertEqual(vqr.doc_reader_facts(foreign, self.NOW)["doc_reader_state"], "unknown")

    def test_the_read_is_bounded_and_opens_the_store_read_only(self):
        """dv_steps holds 2.46M rows with no index on `at`: the read must walk the rowid, and a
        tail that carries no recent row must not turn into a scan of the whole table."""
        old = [("2026-11-01T00:00:00Z", n) for n in range(40)]
        path = self.store("2026-11-09T04:00:00Z", [("2026-11-13T15:00:00Z", 1)] + old)
        proof = self.proof_store()
        with mock.patch.object(vqr, "DOC_READER_TAIL_ROWS", 10):
            f = vqr.doc_reader_facts(path, self.NOW, proof)
        self.assertEqual(f["doc_reader_state"], "caught_up")
        before = os.stat(path).st_mtime_ns
        vqr.doc_reader_facts(path, self.NOW, proof)
        self.assertEqual(os.stat(path).st_mtime_ns, before)
        self.assertEqual(sorted(os.listdir(os.path.dirname(path))), ["doc-verify.sqlite"])
        # the same store read with the real bound finds the judged user the small bound cut off
        self.assertEqual(vqr.doc_reader_facts(path, self.NOW, proof)["doc_reader_state"], "live")

    def test_the_waiting_read_is_bounded(self):
        """proof_intake has no index on received_at: only the newest rows are examined, so the
        30-minute tick never scans the feed."""
        read = [("doc-%d" % n, "2026-11-13T10:00:00Z", '["req-1"]') for n in range(1, 21)]
        proof = self.proof_store([("doc-0", "2026-11-13T10:00:00Z", '["req-1"]')] + read)
        path = self.store("2026-11-09T04:00:00Z",
                          steps=[("2026-11-13T10:00:00Z", f[0]) for f in read])
        with mock.patch.object(vqr, "DOC_READER_WAIT_ROWS", 5):
            self.assertEqual(vqr.doc_reader_facts(path, self.NOW, proof)["doc_reader_state"],
                             "caught_up")
        self.assertEqual(vqr.doc_reader_facts(path, self.NOW, proof)["doc_reader_state"],
                         "stopped")

    def test_the_registry_read_is_the_rule_the_decider_applies(self):
        full = {"approved": True, "approved_by": "captain", "approval_ref": "ruling-1"}
        self.assertIs(vqr.doc_writeback_approved(self.registry(full)), True)
        self.assertIs(vqr.doc_writeback_approved(self.registry({"approved": False})), False)
        self.assertIs(vqr.doc_writeback_approved(self.registry(dict(full, approved_by=""))), False)
        self.assertIs(vqr.doc_writeback_approved(self.registry(dict(full, approval_ref=None))), False)
        self.assertIs(vqr.doc_writeback_approved(self.registry(dict(full, approved="true"))), False)
        self.assertIsNone(vqr.doc_writeback_approved("/nonexistent/registry.json"))
        self.assertIsNone(vqr.doc_writeback_approved(self.registry(None)))
        # the same row and the same answer as the decider's own gate, on every shape above
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        self.addCleanup(lambda: sys.path.remove(os.path.join(REPO, "scripts")))
        from credit_review import decide
        self.assertEqual(decide.DOC_AUTOMATION, vqr.DOC_APPROVAL_AUTOMATION)
        for entry in (full, {"approved": False}, dict(full, approved_by=""),
                      dict(full, approval_ref=None), dict(full, approved="true")):
            path = self.registry(entry)
            self.assertEqual(bool(vqr.doc_writeback_approved(path)),
                             decide.doc_class_approved(path)[0], entry)
        # and today that row is not approved
        self.assertIs(vqr.doc_writeback_approved(), False)
        self.assertIs(decide.doc_class_approved()[0], False)

    # -- the other lanes ---------------------------------------------------------------

    def test_the_other_held_lanes_do_not_read_the_docs_in_facts(self):
        """The docs_in facts must not move another lane's words, whatever the reader does, and
        each lane's own words come from the policy file it is given."""
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "lanes.json")
        with open(path, "w") as fh:
            json.dump({"lanes": {
                "credits_docs_in": {"owner": "docs-owner"},
                "claims_untouched": {"owner": "claims-owner",
                                     "unblock_after_status": "the reader goes live (this file)"},
                "fable_decider": {"owner": "decider-owner"},
                "intercom_customer_last": {"owner": "intercom-owner",
                                           "reason": "no new copy (this file)",
                                           "unblock": "approved copy (this file)"}}}, fh)
        lanes = vqr.read_held_lanes(path)
        self.assertEqual(lanes["claims_untouched"]["owner"], "claims-owner")
        for reader in (self.LIVE, self.STOPPED, self.CAUGHT_UP, self.BYTES_OWED, self.BLIND, {}):
            facts = dict(self.OTHERS, **reader)
            claims = vqr.held_lane("claims_untouched", facts, lanes)
            self.assertEqual(claims["unblock"], "the reader goes live (this file)", reader)
            self.assertEqual(claims["owner"], "claims-owner")
            self.assertEqual(vqr.held_lane("fable_decider", facts, lanes)["owner"],
                             "decider-owner")
            intercom = vqr.held_lane("intercom_customer_last", facts, lanes)
            self.assertEqual(intercom["reason"], "no new copy (this file)")
            self.assertEqual(intercom["unblock"], "approved copy (this file)")
            # a lane that is not held stays not held
            self.assertIsNone(vqr.held_lane("credits_untouched", facts, lanes))
            self.assertIsNone(vqr.held_lane(
                "fable_decider", dict(facts, decide_switch=False), lanes))
            self.assertIsNone(vqr.held_lane(
                "claims_untouched", dict(facts, claim_proof_ask_on=True), lanes))
        self.assertEqual(set(vqr.CAPTAIN_HELD), {"credits_docs_in", "claims_untouched",
                                                 "fable_decider", "intercom_customer_last"})


class DeliveryLedger(unittest.TestCase):
    """QA @0b3507c: the dedupe key is the item id, not the waiting episode, and the ledger
    was never pruned — so a user who was paged once, cleared, then came back with new
    overdue work never paged again."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def page(self, items, prev=None, delivered=True):
        # a NON-held lane: held lanes keep their signature in `held`, not in the delivery
        # ledger, so they would not exercise pruning.
        ev = vqr.sentinel_evaluate({"items": {"claims_docs_in": items}, "unmeasured": set()},
                                   self.NOW)
        msgs, state, page_map = vqr.sentinel_page(ev, prev, self.NOW, False)
        return msgs, vqr.record_paged(state, page_map, [delivered] * len(page_map))

    def test_a_cleared_breach_is_pruned_so_a_returning_user_pages_again(self):
        old = [("user:1", "2026-10-27T00:00:00Z")]
        msgs, state = self.page(old)
        self.assertEqual(len(msgs), 1)
        self.assertIn("user:1", state["paged"]["claims_docs_in"])
        # the lane clears: nothing overdue any more
        msgs, state = self.page([], state)
        self.assertEqual(msgs, [])
        self.assertNotIn("claims_docs_in", state["paged"])     # ledger pruned
        # the same user comes back with new overdue work
        msgs, _ = self.page(old, state)
        self.assertEqual(len(msgs), 1)

    def test_a_still_overdue_item_is_not_re_paged(self):
        old = [("user:1", "2026-10-27T00:00:00Z")]
        _, state = self.page(old)
        msgs, _ = self.page(old, state)
        self.assertEqual(msgs, [])

    def test_a_partial_first_intercom_scan_keeps_the_watermark_unset(self):
        calls = []

        def fake_search(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            calls.append(start_after)
            return ([{"id": 1, "statistics": {"last_contact_reply_at": 1}},
                     {"id": 2, "statistics": {"last_contact_reply_at": 1}}], True, "cur-2")

        old = vqr.intercom_search
        vqr.intercom_search = fake_search
        try:
            items, info = vqr.intercom_items(None, self.NOW)
            self.assertTrue(info["truncated"])
            self.assertEqual(info["cursor"], "cur-2")
            self.assertEqual(len(items), 2)
            # the next tick resumes from the cursor, never a full re-walk
            vqr.intercom_items({"intercom": {"items": {}, "boot_cursor": "cur-2"}}, self.NOW)
            self.assertEqual(calls[-1], "cur-2")
        finally:
            vqr.intercom_search = old


class SentinelRobustness(unittest.TestCase):
    """QA @3974dfd: a resolved hold must leave the lane, a truncated delta must not advance
    the watermark, and a failed population query must not zero the carried set."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)
    BASE_FACTS = {"asked": {}, "messaged": {}, "latest": {}, "decided": set(), "support": set(),
                  "replied": set(), "proof_waiting": {}, "muted": {}, "flagged": {},
                  "claim_notes": {}, "claim_proofs": {}, "claim_replied": set(),
                  "claim_muted": {}, "claim_flagged": {}, "first_proof_hold": {},
                  "first_deadend": {5: "2026-10-27T00:00:00Z"},
                  "support_contacts": set()}

    def items(self, facts, failed=frozenset(), prev=None):
        return vqr.sentinel_items({}, {}, facts, lambda u, i: "untouched",
                                  lambda u, i: "untouched", frozenset(), frozenset(),
                                  light=False, prev_state=prev or {"intercom": {"items": {}},
                                                                   "merges": {"items": {}}},
                                  now=self.NOW, probe={"unmeasured": set()},
                                  failed_pop=failed)

    def test_a_resolved_dead_end_hold_leaves_the_lane(self):
        resolved = dict(self.BASE_FACTS, latest={5: {"decision": "approve", "reason": "x",
                                                     "doc_required": 0, "at": ""}})
        self.assertEqual(self.items(resolved)["items"]["fable_decider"], [])

    def test_an_unresolved_dead_end_hold_stays(self):
        live = dict(self.BASE_FACTS, latest={5: {"decision": "hold",
                                                 "reason": "validator reject rule fired (x)",
                                                 "doc_required": 0, "at": ""}})
        self.assertEqual([i for i, _ in self.items(live)["items"]["fable_decider"]], ["user:5"])

    def test_a_failed_population_query_keeps_the_carried_items(self):
        prev = {"items": {"credits_docs_in": {"user:9": "2026-10-20T00:00:00Z"}},
                "intercom": {"items": {}}, "merges": {"items": {}}}
        found = self.items(dict(self.BASE_FACTS), failed=frozenset({"credits_docs_in"}),
                           prev=prev)
        self.assertEqual([i for i, _ in found["items"]["credits_docs_in"]], ["user:9"])
        self.assertIn("credits_docs_in", found["unmeasured"])

    def test_a_truncated_delta_keeps_the_watermark(self):
        calls = {"n": 0}

        def fake_search(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            calls["n"] += 1
            return [{"id": 3, "statistics": {"last_contact_reply_at": 1}}], True, None

        old = vqr.intercom_search
        vqr.intercom_search = fake_search
        try:
            _, info = vqr.intercom_items({"intercom": {"items": {}, "last_walk":
                                                       "2026-10-29T11:00:00Z"}}, self.NOW)
            self.assertTrue(info["truncated"])
            self.assertTrue(info["keep_walk"])
        finally:
            vqr.intercom_search = old


class EpisodeAndBlindness(unittest.TestCase):
    """QA @3fd56a0: a fresh dead-end hold must be clocked from its own episode, a truncated
    CLOSED scan must hold the watermark, and a failed Intercom probe must not clear the lane
    or its delivery ledger."""

    NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)

    def test_a_truncated_closed_scan_keeps_the_watermark(self):
        def fake(query, per_page=150, max_pages=40, deadline_s=25.0, start_after=None):
            if query.get("operator") == "AND" and any(
                    f.get("value") == "closed" for f in query["value"]):
                return [], True, None          # the CLOSED scan was cut short
            return [], False, None

        old = vqr.intercom_search
        vqr.intercom_search = fake
        try:
            _, info = vqr.intercom_items(
                {"intercom": {"items": {}, "last_walk": "2026-10-29T11:00:00Z"}}, self.NOW)
            self.assertTrue(info["truncated"])
            self.assertTrue(info["keep_walk"])
        finally:
            vqr.intercom_search = old

    def test_a_failed_intercom_probe_carries_the_lane_and_its_ledger(self):
        prev = {"items": {"intercom_customer_last": {"conv:1": "2026-10-01T00:00:00Z"}},
                "intercom": {"items": {"conv:1": "2026-10-01T00:00:00Z"},
                             "last_walk": "2026-10-29T00:00:00Z"},
                "merges": {"items": {}}}
        found = vqr.sentinel_items({}, {}, {"first_deadend": {}, "latest": {}},
                                   lambda u, i: "untouched", lambda u, i: "untouched",
                                   frozenset(), frozenset(), light=False, prev_state=prev,
                                   now=self.NOW,
                                   probe={"unmeasured": {"intercom_customer_last"}})
        self.assertEqual([i for i, _ in found["items"]["intercom_customer_last"]], ["conv:1"])
        self.assertIn("intercom_customer_last", found["unmeasured"])

    def test_an_unmeasured_lane_keeps_its_delivery_ledger(self):
        ev = vqr.sentinel_evaluate({"items": {"intercom_customer_last": []},
                                    "unmeasured": {"intercom_customer_last"}}, self.NOW)
        prev = {"paged": {"intercom_customer_last": ["conv:1"]}}
        _, state, _ = vqr.sentinel_page(ev, prev, self.NOW, False)
        self.assertEqual(state["paged"]["intercom_customer_last"], ["conv:1"])


class LedgerSQL(unittest.TestCase):
    """QA @05262eb: the tests injected `first_deadend` and so could not see that the SQL
    predicate was malformed (`reason LIKE (reason LIKE ? OR ...)` matches nothing). This runs
    ledger_facts() against a REAL SQLite fixture: hold -> approval -> fresh hold."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        db = sqlite3.connect(self.path)
        db.executescript("""
        CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
          decided_at TEXT NOT NULL, request_id TEXT NOT NULL, profile_id TEXT, user_id INTEGER,
          track_id TEXT, track_title TEXT, claimed_roles TEXT, popularity INTEGER,
          big_track INTEGER NOT NULL, decision TEXT NOT NULL, reason TEXT NOT NULL,
          evidence_kind TEXT, catalog TEXT, web_verdict TEXT, web_urls TEXT, footprint INTEGER,
          n1 INTEGER NOT NULL DEFAULT 0, doc_required INTEGER NOT NULL DEFAULT 0,
          paid_priority INTEGER, proof_id TEXT, model TEXT, provider TEXT, cost_usd REAL,
          prompt_sha256 TEXT, llm_call_id INTEGER, conflict TEXT, mode TEXT NOT NULL);
        CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT NOT NULL,
          kind TEXT NOT NULL, parent_row INTEGER, user_key TEXT NOT NULL, day TEXT NOT NULL,
          due_day TEXT, removal_day TEXT, status TEXT NOT NULL, message_type TEXT NOT NULL,
          contact_id TEXT, message_id TEXT, conversation_id TEXT, request_ids_json TEXT NOT NULL,
          refs_json TEXT, n_credits INTEGER NOT NULL, approved_by TEXT NOT NULL,
          approval_ref TEXT NOT NULL, body_sha256 TEXT, reason TEXT, api_log TEXT,
          attempts INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          proof_tagged_at TEXT, proof_checked_at TEXT,
          proof_attachments INTEGER NOT NULL DEFAULT 0, extension_requested_at TEXT,
          last_reply_at TEXT, account_id TEXT, sent_at TEXT);
        CREATE TABLE verify_proof_reviews (family INTEGER NOT NULL, request_id TEXT NOT NULL,
          outcome TEXT NOT NULL, reason TEXT, document INTEGER NOT NULL DEFAULT 0,
          reviewed_at TEXT NOT NULL, reviewed_by TEXT NOT NULL, PRIMARY KEY (family, request_id));
        CREATE TABLE verify_refusal_holds (campaign TEXT NOT NULL, user_key TEXT NOT NULL,
          user_id TEXT, refusals INTEGER NOT NULL DEFAULT 0, reason TEXT,
          next_recheck_at TEXT NOT NULL, flagged_at TEXT, updated_at TEXT NOT NULL,
          PRIMARY KEY (campaign, user_key));
        """)
        rows = [("2026-10-20T00:00:00Z", "hold", "validator reject rule fired (reject_artist_credit)"),
                ("2026-10-22T00:00:00Z", "approve", "verified web support"),
                ("2026-10-28T06:00:00Z", "hold", "validator reject rule fired (reject_artist_credit)")]
        for at, dec, reason in rows:
            db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, big_track,"
                       " decision, reason, mode) VALUES ('r', ?, 'req', 5, 0, ?, ?, 'apply')",
                       (at, dec, reason))
        db.commit()
        db.close()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_reviewed_claim_proof_is_not_waiting_on_us(self):
        # QA @059da4d: an accepted verify_proof_reviews row for the claim removes it from
        # claim_proofs, so classify_claim cannot answer docs_in for a document already reviewed
        db = sqlite3.connect(self.path)
        cols = ("campaign, kind, parent_row, user_key, day, status, message_type, request_ids_json, "
                "n_credits, approved_by, approval_ref, created_at, updated_at, proof_tagged_at, account_id")
        db.execute(f"INSERT INTO verify_messages ({cols}) VALUES ('claim-status','ask',NULL,'u:7',"
                   "'2026-10-27','sent','email','[\"claim-11\"]',1,'fable','r','2026-10-27T10:00:00Z',"
                   "'2026-10-27T10:00:00Z','2026-10-27T11:00:00Z','7')")
        db.execute(f"INSERT INTO verify_messages ({cols}) VALUES ('claim-status','ask',NULL,'u:8',"
                   "'2026-10-27','sent','email','[\"claim-12\"]',1,'fable','r','2026-10-27T10:00:00Z',"
                   "'2026-10-27T10:00:00Z','2026-10-27T11:00:00Z','8')")
        reviewed_family = db.execute("SELECT id FROM verify_messages WHERE user_key='u:8'").fetchone()[0]
        db.execute("INSERT INTO verify_proof_reviews (family, request_id, outcome, reviewed_at, reviewed_by)"
                   " VALUES (?, 'claim-12', 'accepted', '2026-10-27T12:00:00Z', 'nick')", (reviewed_family,))
        db.commit(); db.close()
        old = vqr.LEDGER
        vqr.LEDGER = self.path
        try:
            facts_ = vqr.ledger_facts()
        finally:
            vqr.LEDGER = old
        self.assertIn("claim-11", facts_["claim_proofs"], "an unreviewed tagged proof still waits on us")
        self.assertNotIn("claim-12", facts_["claim_proofs"], "a reviewed proof is not waiting on us")

    def test_a_fresh_dead_end_hold_is_clocked_from_its_own_episode(self):
        old = vqr.LEDGER
        vqr.LEDGER = self.path
        try:
            facts = vqr.ledger_facts()
        finally:
            vqr.LEDGER = old
        self.assertEqual(facts["first_deadend"].get(5), "2026-10-28T06:00:00Z")

    def test_the_dead_end_lane_is_not_empty_for_a_live_hold(self):
        old = vqr.LEDGER
        vqr.LEDGER = self.path
        try:
            facts = vqr.ledger_facts()
        finally:
            vqr.LEDGER = old
        found = vqr.sentinel_items({}, {}, facts, lambda u, i: "untouched",
                                   lambda u, i: "untouched", frozenset(), frozenset(),
                                   light=False,
                                   prev_state={"intercom": {"items": {}}, "merges": {"items": {}}},
                                   now=datetime(2026, 10, 29, tzinfo=timezone.utc),
                                   probe={"unmeasured": set()})
        self.assertEqual([i for i, _ in found["items"]["fable_decider"]], ["user:5"])

    def test_a_resolved_hold_with_no_new_one_leaves_the_lane(self):
        db = sqlite3.connect(self.path)
        db.execute("DELETE FROM decisions WHERE decided_at = '2026-10-28T06:00:00Z'")
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, big_track,"
                   " decision, reason, mode) VALUES ('r','2026-10-28T06:00:00Z','req',5,0,"
                   "'approve','verified web support','apply')")
        db.commit(); db.close()
        old = vqr.LEDGER
        vqr.LEDGER = self.path
        try:
            facts = vqr.ledger_facts()
        finally:
            vqr.LEDGER = old
        self.assertEqual(facts["first_deadend"], {})


class Locking(unittest.TestCase):
    def test_two_ticks_cannot_hold_the_sentinel_lock_at_once(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            lockf = os.path.join(d, ".lock")
            probe = (f"import sys; sys.path.insert(0,{os.path.dirname(SCRIPT)!r});"
                     f"import importlib.util as u;"
                     f"sp=u.spec_from_file_location('v',{SCRIPT!r});"
                     f"v=u.module_from_spec(sp); sp.loader.exec_module(v);"
                     f"L=v.sentinel_lock({lockf!r}, timeout=0.5);"
                     f"L.__enter__(); print('held'); L.__exit__()")
            out = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True)
            self.assertIn("held", out.stdout + out.stderr)
            self.assertTrue(os.path.exists(lockf))

    def test_the_state_write_uses_a_per_process_temp_file(self):
        # a shared ".tmp" path let a second writer replace the first's file mid-write
        with open(SCRIPT) as fh:
            src = fh.read()
        self.assertIn('f"{SENTINEL_STATE}.tmp.{os.getpid()}"', src)


class LightTick(unittest.TestCase):
    def test_a_light_tick_never_writes_the_report_state(self):
        # It measured no tables: storing its payload would wipe the arrows baseline the
        # next 30-minute report compares against (which is exactly what happened at 22:10Z).
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            state = os.path.join(d, "last.json")
            env = dict(os.environ, VQR_OFFLINE="1", VQR_STATE=state,
                       VQR_SENTINEL_STATE=os.path.join(d, "s.json"),
                       VQR_LEDGER=os.path.join(d, "nope.sqlite3"), VQR_PROOF_ON_FILE=os.path.join(d, "p.json"),
                       VQR_WATCHLIST=os.path.join(REPO, "policies", "fraud-watchlist.json"))
            subprocess.run([sys.executable, vqr.__file__, "--light"], capture_output=True,
                           text=True, env=env)
            self.assertFalse(os.path.exists(state), "a light tick wrote the report state")

    def test_a_light_tick_never_runs_the_legacy_trend(self):
        # A light tick does not write the report state, so its legacy comparison would be
        # against a stale baseline and would re-page the same delta on every probe.
        import subprocess
        out = subprocess.run([sys.executable, vqr.__file__, "--light", "--dry-run"],
                             capture_output=True, text=True,
                             env=dict(os.environ, VQR_OFFLINE="1",
                                      VQR_SENTINEL_STATE="/nonexistent/x.json",
                                      VQR_LEDGER="/nonexistent/ledger.sqlite3"))
        self.assertNotIn("BACKLOG", out.stdout)
        self.assertNotIn("Old backlog", out.stdout)


class LegacyTrend(unittest.TestCase):
    def m(self, total, flat=0):
        return {"legacy": {"total": total, "credits_untouched": total}, "legacy_flat": flat}

    def test_no_previous_report_means_no_stall_page(self):
        self.assertEqual(vqr.stall_pages(self.m(100), None), [])

    def test_a_falling_backlog_never_pages(self):
        prev = {"legacy": {"total": 120}}
        self.assertEqual(vqr.stall_pages(self.m(100), prev), [])

    def test_a_rise_pages(self):
        msgs = vqr.stall_pages(self.m(130), {"legacy": {"total": 120}})
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG FORMING: old backlog rose"))

    def test_flat_once_is_tolerated_flat_twice_pages(self):
        prev = {"legacy": {"total": 100}}
        self.assertEqual(vqr.stall_pages(self.m(100, flat=1), prev), [])
        msgs = vqr.stall_pages(self.m(100, flat=2), prev)
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0].startswith("BACKLOG STUCK"))

    def test_flat_at_zero_is_not_a_stuck_backlog(self):
        self.assertEqual(vqr.stall_pages(self.m(0, flat=5), {"legacy": {"total": 0}}), [])

    def test_the_report_shows_the_old_backlog_line_with_its_change(self):
        line = vqr.legacy_line(self.m(100), {"legacy": {"total": 112}})
        self.assertIn("Old backlog from before the 21:00Z line", line)
        self.assertIn("100", line)
        self.assertIn("▼12", line)


class Invariants(unittest.TestCase):
    def summarize(self, pop, classify):
        # Mirror main()'s bookkeeping without touching Trino, the ledger or Slack.
        buckets = {k: {"users": 0, "rows": 0, "paid_users": 0, "paid_rows": 0,
                       "oldest_h": None} for k, _ in vqr.BUCKETS}
        for user, item in pop.items():
            b = buckets[classify(user, item)]
            b["users"] += 1
            b["rows"] += item["n"]
            b["paid_rows"] += item.get("paid_n") or (item["n"] if item["paid"] else 0)
            if item["paid"]:
                b["paid_users"] += 1
        return buckets

    def test_every_open_row_lands_in_exactly_one_bucket(self):
        pop = {i: dict(CREDIT, n=i % 3 + 1, paid=bool(i % 2)) for i in range(1, 40)}
        b = self.summarize(pop, lambda u, i: vqr.classify_credit(u, facts(), i, frozenset()))
        self.assertEqual(sum(v["rows"] for v in b.values()), sum(i["n"] for i in pop.values()))
        self.assertEqual(sum(v["users"] for v in b.values()), len(pop))

    def test_every_bucket_has_a_label_and_the_list_is_stable(self):
        keys = [k for k, _ in vqr.BUCKETS]
        self.assertEqual(keys, ["watch", "docs_in", "human", "muted", "told", "untouched",
                                "not_told"])


class Render(unittest.TestCase):
    def measurement(self, **over):
        buckets = {k: {"users": 1, "rows": 2, "paid_users": 1, "paid_rows": 2,
                       "oldest_h": 50.0} for k, _ in vqr.BUCKETS}
        sec = {"buckets": buckets, "open_users": len(vqr.BUCKETS), "open_rows": 14,
               "open_paid": 7, "open_paid_users": 4,
               "flow": {"approved": {"rows": 3, "users": 2, "paid": 1},
                        "declined": {"rows": 0, "users": 0, "paid": 0}}}
        m = {"at": "2026-10-26 21:00Z", "credits": dict(sec), "claims": dict(sec)}
        m.update(over)
        return m

    def test_the_message_names_both_tables_and_every_bucket(self):
        text = vqr.render(self.measurement(), None)
        self.assertIn("CREDITS", text)
        self.assertIn("PROFILE CLAIMS", text)
        for _, label in vqr.BUCKETS:
            # once per table, plus any mention in the footnote
            self.assertGreaterEqual(text.count(label), 2, label)
        self.assertEqual(text.count("Total open"), 2)

    def test_the_first_report_has_no_arrows(self):
        self.assertNotIn("▲", vqr.render(self.measurement(), None))
        self.assertNotIn("▼", vqr.render(self.measurement(), None))

    def test_a_second_report_shows_the_change_in_users(self):
        prev = self.measurement()
        cur = self.measurement()
        cur["credits"]["buckets"]["untouched"]["users"] = 1 + 5
        cur["credits"]["open_users"] = prev["credits"]["open_users"] + 5
        text = vqr.render(cur, prev)
        self.assertIn("▲5", text)

    def test_flat_buckets_render_an_equals_sign(self):
        self.assertIn(" =", vqr.render(self.measurement(), self.measurement()))


class Live(unittest.TestCase):
    def test_selftest_exit_code(self):
        p = subprocess.run([sys.executable, SCRIPT, "--selftest"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_help_exits_zero_and_documents_the_kill_switch(self):
        p = subprocess.run([sys.executable, SCRIPT, "--help"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn("Kill switch", p.stdout)

    def test_a_kill_switch_suppresses_the_post_without_touching_anything_else(self):
        with tempfile.NamedTemporaryFile() as kill:
            env = dict(os.environ, VQR_KILL_SWITCH=kill.name)
            p = subprocess.run([sys.executable, SCRIPT, "--post"], capture_output=True,
                               text=True, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), "NO_REPLY")


class AgeStats(unittest.TestCase):
    """The median and oldest wait of a table's open users, saved for scripts/verification-standing.py."""

    def pop(self, *oldest):
        return {i: dict(CREDIT, oldest=ts) for i, ts in enumerate(oldest)}

    def test_the_per_user_median_and_oldest_in_hours(self):
        got = vqr.age_stats(self.pop("2026-10-25 21:00:00.000000 UTC", "2026-10-24 21:00:00.000000 UTC",
                                     "2026-10-16 21:00:00.000000 UTC"), NOW)
        self.assertEqual(got, {"users": 3, "undated": 0, "oldest_per_user_median_h": 48.0,
                               "oldest_h": 240.0})

    def test_the_median_age_is_the_per_request_one_when_it_was_read(self):
        got = vqr.age_stats(self.pop("2026-10-25 21:00:00.000000 UTC", "2026-10-24 21:00:00.000000 UTC"),
                            NOW, 3.0)
        self.assertEqual((got["median_h"], got["oldest_per_user_median_h"]), (3.0, 36.0))

    def test_a_user_without_a_readable_time_is_counted_apart_not_as_zero_hours(self):
        got = vqr.age_stats(self.pop("2026-10-24 21:00:00.000000 UTC", "", "soon"), NOW)
        self.assertEqual(got, {"users": 1, "undated": 2, "oldest_per_user_median_h": 48.0,
                               "oldest_h": 48.0})

    def test_nothing_open_has_no_age(self):
        self.assertEqual(vqr.age_stats({}, NOW), {"users": 0, "undated": 0,
                                                  "oldest_per_user_median_h": None, "oldest_h": None})

    def test_an_undated_user_still_lands_in_the_grids_first_column(self):
        pop = {0: dict(CREDIT, oldest="", oldest_h=vqr.age_h("", NOW))}
        grid = vqr.grid_build(pop, lambda user, item: "untouched", {})
        self.assertEqual(grid["cells"][vqr.DATE_BUCKETS[0][0]]["a"]["users"], 1)
        self.assertEqual(vqr.age_stats(pop, NOW)["undated"], 1)


class RequestMedian(unittest.TestCase):
    """The median age of an OPEN REQUEST, one sample per request, not one per user."""

    def read(self, rows):
        with mock.patch.object(vqr, "trino", return_value=rows):
            return vqr.request_median_h("credits", NOW)

    def test_one_old_request_beside_ten_fresh_ones_does_not_move_the_median(self):
        old = "2025-10-26 21:00:00.000000 UTC"
        fresh = "2026-10-26 20:00:00.000000 UTC"
        self.assertEqual(self.read([[old]] + [[fresh]] * 10), 1.0)

    def test_a_hundred_users_with_a_30_day_and_a_700_day_request_median_at_8_748_hours(self):
        rows = [["2026-09-26 21:00:00.000000 UTC"], ["2024-11-26 21:00:00.000000 UTC"]] * 100
        self.assertEqual(self.read(rows), 8748.0)

    def test_an_empty_read_raises_instead_of_answering_zero(self):
        with self.assertRaises(RuntimeError):
            self.read([])

    def test_an_unreadable_time_is_left_out_not_counted_as_zero(self):
        self.assertEqual(self.read([["2026-10-26 20:00:00.000000 UTC"], [""], ["soon"]]), 1.0)

    def test_the_read_keeps_timestamp_rows_and_drops_the_banner(self):
        out = ('"2026-10-26 20:00:00.000000 UTC"\n'
               'WARNING: query took a while\n'
               '"2026-10-25 21:00:00.000000 UTC"\n')
        p = mock.Mock(returncode=0, stdout=out, stderr="")
        with mock.patch.object(vqr.subprocess, "run", return_value=p):
            self.assertEqual(vqr.request_median_h("credits", NOW), 12.5)


class AskGap(unittest.TestCase):
    """OURS for the standing page: pending requests with no DELIVERED ask, joined by request id."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.path = os.path.join(self.tmp, "ledger.sqlite3")
        db = sqlite3.connect(self.path)
        db.executescript("""
        CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, status TEXT, campaign TEXT);
        CREATE TABLE verify_requests (campaign TEXT, request_id TEXT, message_row INTEGER, status TEXT,
          PRIMARY KEY (campaign, request_id));
        INSERT INTO verify_messages VALUES (1, 'sent', 'uvn-status'), (2, 'refused', 'uvn-status'),
          (3, 'sent', 'uvn-status'), (4, 'attempted', 'uvn-status'), (5, 'sent', 'status-team-review');
        INSERT INTO verify_requests VALUES ('uvn-status', 'aaaa', 1, 'sent'), ('uvn-status', 'bbbb', 2, 'refused'),
          ('uvn-status', 'GONE', 3, 'sent'), ('gap-ask', 'gone', 3, 'sent'), ('uvn-status', 'eeee', 4, 'attempted'),
          ('gap-ask', 'EEEE', 1, 'sent'), ('status-team-review', 'ffff', 5, 'sent');
        """)
        db.commit()
        db.close()
        old = vqr.LEDGER
        vqr.LEDGER = self.path
        self.addCleanup(setattr, vqr, "LEDGER", old)

    def test_it_is_joined_by_request_id_not_subtracted(self):
        # delivered: aaaa, eeee (its second campaign reached the user) and one that is no longer
        # pending. 5 pending - 3 delivered ids would say 2; 3 pending requests have no delivered ask.
        gap = vqr.ask_gap(["aaaa", "bbbb", "cccc", "dddd", "eeee"])
        self.assertEqual(gap, {"pending": 5, "ours": 3, "never_asked": 2})

    def test_only_a_delivered_ask_takes_a_request_out_of_ours(self):
        self.assertEqual(vqr.ask_gap(["ffff"]), {"pending": 1, "ours": 1, "never_asked": 0})
        db = sqlite3.connect(self.path)
        db.execute("INSERT INTO verify_messages VALUES (6, 'sent', 'proof-need-ask')")
        db.execute("INSERT INTO verify_requests VALUES ('proof-need-ask', 'ffff', 6, 'sent')")
        db.commit()
        db.close()
        self.assertEqual(vqr.ask_gap(["ffff"]), {"pending": 1, "ours": 0, "never_asked": 0})

    def test_an_ask_that_was_tried_and_not_delivered_is_still_ours(self):
        self.assertEqual(vqr.ask_gap(["bbbb"]), {"pending": 1, "ours": 1, "never_asked": 0})

    def test_a_missing_ledger_raises_and_is_not_created(self):
        vqr.LEDGER = os.path.join(self.tmp, "absent.sqlite3")
        with self.assertRaises(sqlite3.Error):
            vqr.ask_gap(["aaaa"])
        self.assertFalse(os.path.exists(vqr.LEDGER))

    def test_an_empty_pending_read_is_a_failed_read(self):
        old = vqr.trino
        self.addCleanup(setattr, vqr, "trino", old)
        vqr.trino = lambda sql, **k: []
        with self.assertRaises(RuntimeError):
            vqr.pending_request_ids()
        with self.assertRaises(RuntimeError):
            vqr.intake_1h()

    def test_the_two_replica_reads(self):
        answers = iter([[['aaaa'], ['bbbb']], [['26']]])

        def fake(sql, **k):
            return next(answers)

        old = vqr.trino
        self.addCleanup(setattr, vqr, "trino", old)
        vqr.trino = fake
        self.assertEqual(vqr.pending_request_ids(), ["aaaa", "bbbb"])
        self.assertEqual(vqr.intake_1h(), {"requests": 26})


class DocDatesTests(unittest.TestCase):
    """[key=reason5-undated-doc] The document's own date, read from the returned-document reader.

    Reason 5 parked every "a document is on file" hold on a person because the decider's proof
    feed carries no timestamp. The date is not missing from the box: doc-verify records every date
    it reads out of the file in its `extract` step, keyed by the document's sha256, which is the
    same value `proof_intake.file_sha256` holds. These cases pin that join, and pin the two
    readings that must never be confused: a document nobody has opened is work WE owe (never a
    reason to ask a customer for a dated copy), and a store we could not read is UNMEASURED
    (never "undated").
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.docs = os.path.join(self.dir, "doc-verify.sqlite")
        self.proofs = os.path.join(self.dir, "proof.sqlite")
        db = sqlite3.connect(self.docs)
        db.execute("CREATE TABLE dv_steps (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, at TEXT, "
                   "proof_id TEXT, request_id TEXT, step TEXT, status TEXT, detail_json TEXT, version TEXT)")
        db.commit()
        db.close()
        db = sqlite3.connect(self.proofs)
        db.execute("CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, "
                   "subject TEXT NOT NULL, file_sha256 TEXT, received_at TEXT, "
                   "candidate_request_ids_json TEXT NOT NULL DEFAULT '[]')")
        db.commit()
        db.close()

    def intake(self, user, sha, subject="credit", received_at=None, candidates=("r1",)):
        # `candidates` is the reader's own eligibility: `intake_read.intake_docs` selects
        # `candidate_request_ids_json != '[]'`, so a filing with no candidate request is one it
        # will never open.
        db = sqlite3.connect(self.proofs)
        db.execute("INSERT INTO proof_intake (intake_id, user_id, subject, file_sha256, received_at, "
                   "candidate_request_ids_json) VALUES (?,?,?,?,?,?)",
                   (f"{user}:{sha[:8]}", user, subject, sha, received_at,
                    json.dumps(list(candidates))))
        db.commit()
        db.close()

    def extract(self, sha, status="ok", dates=None, error=None, version=None):
        db = sqlite3.connect(self.docs)
        body = {"dates": dates or []}
        if error is not None:
            body["error"] = error
        db.execute("INSERT INTO dv_steps (run_id, at, proof_id, step, status, detail_json, version) "
                   "VALUES ('r1','2026-10-26T00:00:00Z',?,'extract',?,?,?)",
                   (sha, status, json.dumps(body), version or VERSION))
        db.commit()
        db.close()

    def agg(self, users):
        """The per-account reading without the per-document list, which has its own cases."""
        got = vqr.doc_dates(users, self.docs, self.proofs)
        if got is None:
            return None
        return {u: {k: v for k, v in d.items() if k != "docs"} for u, d in got.items()}

    def test_the_documents_own_date_is_read_through_the_sha256_join(self):
        self.intake(5, "a" * 64)
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2026-10-20", "confidence": 0.9}])
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": True, "date": date(2026, 10, 20), "received_at": None}})

    def test_an_extract_from_a_superseded_reader_version_is_not_an_answer(self):
        # A version bump makes the deployed reader re-read the document, so an answer under the
        # old version is not an answer under the current one: the look is still ours.
        self.intake(5, "a" * 64)
        self.extract("a" * 64, dates=[], version="dv-3")
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": False, "date": None, "received_at": None}})
        self.extract("a" * 64, dates=[])
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": True, "date": None, "received_at": None}})

    def test_a_document_nobody_opened_is_not_read(self):
        # No extract step at all: the look is OURS. This must never read as "undated", which
        # would ask a customer for a copy of a document we have not opened.
        self.intake(5, "b" * 64)
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": False, "date": None, "received_at": None}})

    def test_a_settled_error_is_read_and_undated(self):
        # The reader looked and could not read the file: that is an ANSWER, so the user is owed
        # an ask for a readable/dated copy, not a look no later run will ever make.
        self.intake(5, "c" * 64)
        self.extract("c" * 64, status="error", error="unsupported file type")
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": True, "date": None, "received_at": None}})

    def test_a_transient_error_is_still_unread(self):
        # A provider outage is no answer: a later run will look, so the look stays ours.
        self.intake(5, "c" * 64)
        self.extract("c" * 64, status="error", error="transport: connection reset")
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": False, "date": None, "received_at": None}})

    def test_a_transient_error_at_the_attempt_cap_is_read_and_undated(self):
        self.intake(5, "c" * 64)
        for _ in range(3):
            self.extract("c" * 64, status="error", error="transport: connection reset")
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": True, "date": None, "received_at": None}})

    def test_a_read_document_with_no_date_in_it_is_read_and_undated(self):
        # The one case that is genuinely an ask: the reader opened the file and it carries no
        # signed/issued/sent date.
        self.intake(5, "d" * 64)
        self.extract("d" * 64, dates=[])
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": True, "date": None, "received_at": None}})

    def test_one_unopened_document_keeps_the_whole_account_unread(self):
        # A read document with no date plus a document nobody opened: the look is still OURS, so
        # the account is not read and must never be asked for a dated copy.
        self.intake(5, "d" * 64)
        self.intake(5, "b" * 64)
        self.extract("d" * 64, dates=[])
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": False, "date": None, "received_at": None}})

    def test_an_ok_extract_with_unparseable_detail_is_read_and_undated(self):
        # store.step truncates detail_json at 20,000 chars, so a cut-off body is a read we cannot
        # interpret: it is still an ANSWER (no later run will look), so it is read with no date.
        self.intake(5, "a" * 64)
        db = sqlite3.connect(self.docs)
        db.execute("INSERT INTO dv_steps (run_id, at, proof_id, step, status, detail_json, version) "
                   "VALUES ('r1','2026-10-26T00:00:00Z',?,'extract','ok',?,?)",
                   ("a" * 64, '{"dates": [{"what": "signed", "date": "2026-10-', VERSION))
        db.commit()
        db.close()
        self.assertEqual(self.agg([5]),
                         {5: {"filed": True, "read": True, "date": None, "received_at": None}})

    def test_the_newest_arrival_among_a_users_documents_wins(self):
        self.intake(5, "e" * 64, received_at="2025-01-05T00:00:00Z")
        self.intake(5, "f" * 64, received_at="2026-10-20T00:00:00Z")
        self.assertEqual(self.agg([5])[5]["received_at"],
                         "2026-10-20T00:00:00Z")

    def test_the_newest_date_among_a_users_documents_wins(self):
        # A user with an old document and a fresh one has returned a fresh one: reading the
        # oldest would ask them for a copy of a document they already sent.
        self.intake(5, "e" * 64)
        self.intake(5, "f" * 64)
        self.extract("e" * 64, dates=[{"what": "signed", "date": "2025-01-05", "confidence": 0.9}])
        self.extract("f" * 64, dates=[{"what": "issued", "date": "2026-10-20", "confidence": 0.9}])
        self.assertEqual(self.agg([5])[5]["date"], date(2026, 10, 20))

    def test_only_the_newest_extract_of_a_document_counts(self):
        # A re-read replaces the earlier reading: the newest extract row is the one that counts.
        self.intake(5, "a" * 64)
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2025-01-05", "confidence": 0.9}])
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2026-10-20", "confidence": 0.9}])
        self.assertEqual(self.agg([5])[5]["date"], date(2026, 10, 20))

    def test_a_claim_document_is_not_a_credit_document(self):
        # A claim's document is not the credit's: the user has no credit filing at all, so the
        # reader will never look at one and there is no look to owe.
        self.intake(5, "a" * 64, subject="claim")
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2026-10-20", "confidence": 0.9}])
        self.assertEqual(self.agg([5]),
                         {5: {"filed": False, "read": False, "date": None, "received_at": None}})

    def test_a_hold_with_no_reader_eligible_filing_is_not_a_look_we_owe(self):
        # A proof-on-file hold can rest on a document the reader will never select (a
        # core-verification-backed proof, or a filing it does not take). `filed` is what tells
        # that apart from a document nobody has opened yet, so the row reaches the ask lane
        # instead of sitting in `docs_in` forever with no reader work behind it.
        self.assertEqual(self.agg([5]),
                         {5: {"filed": False, "read": False, "date": None, "received_at": None}})

    def test_a_filing_the_reader_will_never_select_is_not_a_look_we_owe(self):
        # The reader selects `candidate_request_ids_json != '[]'` (intake_read.intake_docs), so a
        # filing with no candidate request is one it will never open. Counting it as "on file"
        # would put the row in docs_in forever with no reader work behind it - the exact lane this
        # change exists to empty.
        self.intake(5, "a" * 64, candidates=())
        self.assertEqual(self.agg([5]),
                         {5: {"filed": False, "read": False, "date": None, "received_at": None}})

    def test_an_unreadable_store_is_unmeasured_never_undated(self):
        # None, not {}: an unmeasured date must never be read as "undated" (that would ask a
        # customer for a copy of a document we simply did not open) and never as "returned".
        self.assertIsNone(vqr.doc_dates([5], os.path.join(self.dir, "nope.sqlite"), self.proofs))
        self.assertIsNone(vqr.doc_dates([5], self.docs, os.path.join(self.dir, "nope.sqlite")))

    def test_no_users_asks_nothing(self):
        self.assertEqual(self.agg([]), {})

    def test_the_hold_population_is_the_one_whose_date_is_read(self):
        # The read is scoped to the users whose LATEST verdict is a "document on file" hold, and
        # the classifier reads the same predicate, so the two can never disagree about who is in
        # this lane.
        f = facts(latest={5: {"decision": "hold", "reason": "proof on file: human review (x)",
                              "doc_required": 0, "at": ""},
                           6: {"decision": "hold", "reason": "validator reject rule fired",
                               "doc_required": 0, "at": ""},
                           7: {"decision": "approve_partial", "reason": "per-role split: x",
                               "doc_required": 0, "at": "", "proof_id": ""}})
        self.assertEqual(vqr.undated_hold_users(f), [5])

    def test_the_per_document_reading_is_kept_because_the_clock_needs_it(self):
        # A user can have several documents and they are not interchangeable: the lane clock has
        # to be the arrival of the one that keeps the row in docs_in.
        self.intake(5, "a" * 64, received_at="2026-10-20T00:00:00Z")
        self.intake(5, "b" * 64, received_at="2026-11-15T00:00:00Z")
        self.extract("b" * 64, dates=[{"what": "signed", "date": "2026-11-15", "confidence": 0.9}])
        docs = vqr.doc_dates([5], self.docs, self.proofs)[5]["docs"]
        self.assertEqual(sorted((d["read"], d["received_at"]) for d in docs),
                         [(False, "2026-10-20T00:00:00Z"), (True, "2026-11-15T00:00:00Z")])

    def test_the_lane_clock_is_the_oldest_outstanding_look(self):
        # The QA case: A arrived 2026-10-20 and nobody opened it; B arrived 2026-11-15 and was
        # read. The row is docs_in because of A, so the clock is A's arrival - clocking from B
        # would file A's look as fresh and never page its breach.
        self.intake(5, "a" * 64, received_at="2026-10-20T00:00:00Z")
        self.intake(5, "b" * 64, received_at="2026-11-15T00:00:00Z")
        self.extract("b" * 64, dates=[{"what": "signed", "date": "2026-11-15", "confidence": 0.9}])
        f = facts(doc_dates=vqr.doc_dates([5], self.docs, self.proofs))
        self.assertEqual(vqr.doc_lane_arrival(5, f, CREDIT), "2026-10-20T00:00:00Z")

    def test_the_lane_clock_is_the_oldest_qualifying_document_when_all_are_read(self):
        # Nothing is unopened, so the evidence is the documents dated on/after the request: the
        # oldest of those, for the same reason.
        self.intake(5, "a" * 64, received_at="2026-10-20T00:00:00Z")
        self.intake(5, "b" * 64, received_at="2026-11-15T00:00:00Z")
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2026-10-20", "confidence": 0.9}])
        self.extract("b" * 64, dates=[{"what": "signed", "date": "2026-11-15", "confidence": 0.9}])
        f = facts(doc_dates=vqr.doc_dates([5], self.docs, self.proofs))
        self.assertEqual(vqr.doc_lane_arrival(5, f, CREDIT), "2026-10-20T00:00:00Z")

    def test_a_document_older_than_the_request_does_not_clock_the_lane(self):
        # A read document dated before the request is not the evidence that qualified the row,
        # so its arrival must not pull the clock back.
        self.intake(5, "a" * 64, received_at="2025-01-05T00:00:00Z")
        self.intake(5, "b" * 64, received_at="2026-11-15T00:00:00Z")
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2025-01-05", "confidence": 0.9}])
        self.extract("b" * 64, dates=[{"what": "signed", "date": "2026-11-15", "confidence": 0.9}])
        f = facts(doc_dates=vqr.doc_dates([5], self.docs, self.proofs))
        self.assertEqual(vqr.doc_lane_arrival(5, f, CREDIT), "2026-11-15T00:00:00Z")

    def test_a_qualifying_document_with_no_arrival_does_not_borrow_another_documents(self):
        # The QA case: the document that qualifies the row (read, dated on/after the request) has
        # no recorded arrival, and an older document that does NOT qualify has one. Clocking from
        # the older arrival would file the new work as pre-baseline LEGACY and never page its
        # breach, so there is nothing to clock from and the caller falls back to the request date.
        self.intake(5, "a" * 64, received_at="2025-01-05T00:00:00Z")
        self.intake(5, "b" * 64, received_at=None)
        self.extract("a" * 64, dates=[{"what": "signed", "date": "2025-01-05", "confidence": 0.9}])
        self.extract("b" * 64, dates=[{"what": "signed", "date": "2026-11-15", "confidence": 0.9}])
        f = facts(doc_dates=vqr.doc_dates([5], self.docs, self.proofs))
        self.assertIsNone(vqr.doc_lane_arrival(5, f, CREDIT))

    def test_the_lane_is_the_deciders_own_document_on_file_sentences(self):
        # A contract, not a string match: the decider owns the sentences, so a new one must be
        # classified here deliberately rather than silently joining or leaving this lane. The
        # stage-2 hold is the one that must stay out - that user was already asked.
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        self.addCleanup(sys.path.remove, os.path.join(REPO, "scripts"))
        from credit_review import decide
        self.assertIn(decide.DOC_ON_FILE_HOLD, vqr.ON_FILE_HOLD_PREFIXES)
        self.assertNotIn(decide.STAGE2_ASK_HOLD, vqr.ON_FILE_HOLD_PREFIXES)
        self.assertFalse(vqr.on_file_hold({"decision": "hold",
                                           "reason": decide.STAGE2_ASK_HOLD}))
        self.assertTrue(vqr.on_file_hold({"decision": "hold",
                                          "reason": decide.DOC_ON_FILE_HOLD}))
        # The per-role split that carries a verified document is the intended partial variant.
        self.assertTrue(vqr.on_file_hold({"decision": "approve_partial", "proof_id": "dv-4:sha:1",
                                          "reason": "proof on file: dv-4 verified document "
                                                    "dv-4:sha:1 proves Mixing"}))


if __name__ == "__main__":
    unittest.main()
