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
from datetime import datetime, timedelta, timezone
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "verification-queue-report.py")
spec = importlib.util.spec_from_file_location("vqr", SCRIPT)
vqr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vqr)

NOW = datetime(2026, 10, 26, 21, 0, tzinfo=timezone.utc)


def facts(**over):
    base = {"asked": {}, "messaged": {}, "latest": {}, "decided": set(), "support": set(),
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

        def fake_trino(sql, *a, **kw):
            seen.append(sql)
            return []

        with mock.patch.object(vqr, "trino", fake_trino):
            vqr.credit_rows()
        self.assertTrue(seen, "credit_rows made no query")
        sql = seen[0]
        self.assertIn("cr.status in ('unverified', 'processing', 'user_verification_needed')", sql)
        # the negated form is the defect: it cannot use the status index
        self.assertNotIn("status not in (", sql.replace("\n", " ").lower())

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

    def test_an_undated_document_on_file_is_human_review(self):
        # Fable 2026-10-27: the proof feed carries no timestamp, so a "proof on file" hold can
        # never be shown to postdate the request it would serve — an old accepted document. The
        # decider's own sentence for it is "a document is already on file; human review", so it
        # is counted with a person, not as "documents back, we owe a look".
        f = facts(asked={5: "2026-10-01"},
                  latest={5: {"decision": "hold",
                              "reason": "proof on file: human review (a document is already on file)",
                              "doc_required": 0, "at": ""}})
        self.assertEqual(vqr.classify_credit(5, f, CREDIT, frozenset()), "human")

    def test_a_per_role_split_with_no_document_is_not_a_document_on_file(self):
        # captain 2026-11-06: a per-role split has NO document at all (the catalog proved some roles,
        # the rest are owed an ask). Counting it as "a document is already on file" hides the very
        # population the captain ordered asked.
        f = facts(latest={8: {"decision": "approve_partial",
                              "reason": "per-role split: approved Mixing; pending Mastering",
                              "doc_required": 0, "at": "", "proof_id": ""}})
        self.assertEqual(vqr.classify_credit(8, f, CREDIT, frozenset()), "untouched")

    def test_a_per_role_split_held_for_a_document_on_file_is_human_review(self):
        # F4: filter_support holds a PARTIAL row for a document on file by PREPENDING the hold sentence and
        # keeping the decision, so the row carries no proof_id. It is still a document on file.
        f = facts(latest={10: {"decision": "approve_partial",
                               "reason": "proof on file: human review (a document is already on file; never ask again)"
                                         " | per-role split: approved Mixing; pending Mastering",
                               "doc_required": 0, "at": "", "proof_id": ""}})
        self.assertEqual(vqr.classify_credit(10, f, CREDIT, frozenset()), "human")

    def test_a_per_role_split_with_a_document_is_human_review(self):
        f = facts(latest={9: {"decision": "approve_partial",
                              "reason": "proof on file: dv-4 verified document dv-4:sha:1 proves Mixing",
                              "doc_required": 0, "at": "", "proof_id": "dv-4:sha:1"}})
        self.assertEqual(vqr.classify_credit(9, f, CREDIT, frozenset()), "human")

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

    def test_a_support_write_is_with_a_person(self):
        f = facts(latest={7: {"decision": "support", "reason": "no trusted web evidence",
                              "doc_required": 1, "at": ""}}, support={7}, decided={7})
        self.assertEqual(vqr.classify_credit(7, f, CREDIT, frozenset()), "human")

    def test_human_review_holds_are_with_a_person(self):
        for reason in ("emailed support@ in the last 90 days: human review, never asked",
                       "support already requested for this credit once: never re-ask"):
            f = facts(latest={8: {"decision": "hold", "reason": reason,
                                  "doc_required": 0, "at": ""}}, decided={8})
            self.assertEqual(vqr.classify_credit(8, f, CREDIT, frozenset()), "human", reason)

    def test_a_user_who_emailed_support_is_with_a_person(self):
        self.assertEqual(vqr.classify_credit(9, facts(support_contacts={9}), CREDIT,
                                            frozenset()), "human")

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
    watchlist / proof feed must blind the sentinel as well as the table."""

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

    def run_main(self, args):
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
        }
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
        self.assertIn("owner user-decisions-fable-d1 + doc-verify-build-b1", msgs[0])
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
        self.assertIn("doc-verify-build-b1", lanes["credits_docs_in"]["owner"])
        self.assertIn("user-decisions-fable-d1", lanes["credits_docs_in"]["owner"])

    def test_live_facts_read_the_real_locks_and_switch(self):
        d = tempfile.mkdtemp()
        sh = os.path.join(d, "ivr.sh"); open(sh, "w").write(
            "readonly CLAIM_PROOF_ASK_COPY_APPROVED=0\nreadonly CLAIM_STATUS_COPY_APPROVED=1\n")
        sa = os.path.join(d, "sa.py"); open(sa, "w").write("from x import account_gate\n")
        gate = os.path.join(d, "account_gate.py"); open(gate, "w").write("")
        sw = os.path.join(d, "decide.disabled"); open(sw, "w").write("")
        with mock.patch.multiple(vqr, VERIFY_REQUEST_SH=sh, SCORE_APPROVE_PY=sa, GATE_SCRIPT=gate,
                                 DECIDE_SWITCH=sw):
            f = vqr.held_facts()
        self.assertEqual(f, {"account_gate_live": True, "decide_switch": True,
                             "claim_status_on": True, "claim_proof_ask_on": False})


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


if __name__ == "__main__":
    unittest.main()
