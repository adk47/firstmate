"""Unit tests for the read-back gate, the audience exclusions and the returns measurement.

Every test here is about refusing. The read-back is the only thing standing between "we think we
fixed it" and "we told them we fixed it", so an unreadable source, a held decision, an uncovered
affiliation check and a dispute all have to end in HOLD - never in a send.
"""

import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import time
import unittest
from decimal import Decimal
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from churn import audience, model, readback, returns, tickets  # noqa: E402

POLICY = json.loads((ROOT / "policies" / "winback-fix.json").read_text())
NOW = 1_700_000_000.0


class Ticket:
    def __init__(self, lane=model.CREDIT_REVIEW, user_id="1001", routed_at=NOW - 3600, lane_ref=None,
                 readback_evidence=None, candidate=None, primary_class="credits_not_approved",
                 mrr_cents=4900, tier="T2-open-told-wait", cancel_at=NOW - 30 * 86400):
        self.ticket_id = "t" * 24
        self.user_id = user_id
        self.lane = lane
        self.routed_at = routed_at
        self.lane_ref = lane_ref
        self.readback = readback_evidence or {}
        # Every credit ticket is routed with the candidate's start of wait and the churn-window
        # floor the snapshot fixed at routing: the read-back dates a fix against those, never
        # against the routing run.
        self.candidate = candidate if candidate is not None else {
            "request_at": NOW - 30 * 86400,
            "churn_window_start": NOW - 60 * 86400,
            "credit_open": {"request_ids": ["req1"]},
        }
        self.primary_class = primary_class
        self.mrr_cents = mrr_cents
        self.tier = tier
        self.cancel_at = cancel_at
        self.state = "seen"
        self.fixed_at = NOW - 60


def ledger(tmp, *, decisions=(), outcomes=(), messages=()):
    """A credit-review ledger with the REAL schema (scripts/credit_review/decide.py)."""
    path = pathlib.Path(tmp) / "ledger.sqlite3"
    db = sqlite3.connect(path)
    db.executescript(
        "CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, decided_at TEXT NOT NULL,"
        " request_id TEXT NOT NULL, profile_id TEXT, user_id INTEGER, track_id TEXT, track_title TEXT,"
        " claimed_roles TEXT, popularity INTEGER, big_track INTEGER NOT NULL, decision TEXT NOT NULL,"
        " reason TEXT NOT NULL, evidence_kind TEXT, catalog TEXT, web_verdict TEXT, web_urls TEXT, footprint INTEGER,"
        " n1 INTEGER NOT NULL DEFAULT 0, doc_required INTEGER NOT NULL DEFAULT 0, paid_priority INTEGER, proof_id TEXT,"
        " model TEXT, provider TEXT, cost_usd REAL, prompt_sha256 TEXT, llm_call_id INTEGER, conflict TEXT,"
        " mode TEXT NOT NULL);"
        "CREATE TABLE decision_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at TEXT NOT NULL,"
        " request_id TEXT NOT NULL, action TEXT NOT NULL, outcome TEXT NOT NULL);"
        "CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT NOT NULL, kind TEXT NOT NULL,"
        " parent_row INTEGER, user_key TEXT NOT NULL, account_id TEXT, day TEXT NOT NULL, due_day TEXT, removal_day TEXT,"
        " status TEXT NOT NULL, message_type TEXT NOT NULL, contact_id TEXT, message_id TEXT, conversation_id TEXT,"
        " request_ids_json TEXT NOT NULL, refs_json TEXT, n_credits INTEGER NOT NULL, approved_by TEXT NOT NULL,"
        " approval_ref TEXT NOT NULL, body_sha256 TEXT, reason TEXT, api_log TEXT, created_at TEXT NOT NULL,"
        " sent_at TEXT, updated_at TEXT NOT NULL);"
    )
    for request_id, user_id, decision, at in decisions:
        db.execute(
            "INSERT INTO decisions (run_id, decided_at, request_id, user_id, big_track, decision, reason, mode)"
            " VALUES ('r', ?, ?, ?, 0, ?, 'because', 'apply')", (at, request_id, user_id, decision))
    for request_id, outcome, at in outcomes:
        db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES ('r', ?, ?, 'approve', ?)",
                   (at, request_id, outcome))
    for message in messages:
        account_id, status, campaign, at = message[:4]
        request_ids = message[4] if len(message) > 4 else []
        db.execute(
            "INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type,"
            " request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at)"
            " VALUES (?, 'initial', 'k', ?, '2023-11-14', ?, 'email', ?, 1, 'a', 'r', ?, ?)",
            (campaign, account_id, status, json.dumps(list(request_ids)), at, at))
    db.commit()
    db.close()
    return str(path)


def since(delta=-3600):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + delta))


class CreditReadbackTest(unittest.TestCase):
    def _sources(self, **kw):
        tmp = tempfile.mkdtemp()
        return readback.Sources(ledger=ledger(tmp, **kw), run_sql=lambda sql: [])

    def test_no_decision_is_not_a_fix(self):
        v = readback.read(Ticket(), self._sources())
        self.assertFalse(v.eligible)
        self.assertIn("no credit decision", v.reason)

    def test_a_hold_is_not_a_decision(self):
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "hold", since())]))
        self.assertFalse(v.eligible)

    def test_approved_but_silent_is_not_a_fix_seen(self):
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "approve", since())],
            outcomes=[("req1", "approved", since())]))
        self.assertFalse(v.eligible)
        self.assertIn("does not know yet", v.reason)
        self.assertEqual(v.evidence["credits_approved"], 1)

    def test_approved_and_told_is_the_only_pass(self):
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "approve", since())],
            outcomes=[("req1", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req1"])]))
        self.assertTrue(v.eligible, v.reason)
        self.assertEqual(v.evidence["credits_approved"], 1)

    def test_a_later_deferred_note_does_not_mask_the_sent_one(self):
        # The "was told" read used to take the newest verify_messages row for the account, whatever
        # its status. A deferred note for a DIFFERENT request then hid the earlier `sent` row and
        # the user was reported as never told, so a fixed user stayed held forever.
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "approve", since())],
            outcomes=[("req1", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(-3600), ["req1"]),
                      ("1001", "deferred_pending_doc", "uvn-status", since(-60), ["req1"])]))
        self.assertTrue(v.eligible, v.reason)

    def test_an_attempted_note_has_not_told_anyone(self):
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "approve", since())],
            outcomes=[("req1", "approved", since())],
            messages=[("1001", "attempted", "uvn-status", since())]))
        self.assertFalse(v.eligible)

    def test_a_declined_only_decision_is_not_a_fix(self):
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "support", since())],
            outcomes=[("req1", "unverified", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req1"])]))
        self.assertFalse(v.eligible)
        self.assertEqual(v.evidence["credits_declined"], 1)

    def test_a_fix_older_than_the_users_own_start_of_wait_does_not_count(self):
        # A pre-existing approval that predates the wait they complained about proves nothing.
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "approve", since(-40 * 86400))],
            outcomes=[("req1", "approved", since(-40 * 86400))],
            messages=[("1001", "sent", "uvn-status", since(-40 * 86400))]))
        self.assertFalse(v.eligible)

    def test_a_fix_between_the_measurement_and_the_routing_run_is_seen(self):
        # The audience is measured up to windows.churn_days back and the decider promotes these
        # users daily, so an approval that lands after the measurement but before this ticket was
        # routed is the expected case - and it used to read as "nothing since routing" forever.
        v = readback.read(Ticket(routed_at=NOW), self._sources(
            decisions=[("req1", 1001, "approve", since(-1800))],
            outcomes=[("req1", "approved", since(-1800))],
            messages=[("1001", "sent", "uvn-status", since(-1200), ["req1"])]))
        self.assertTrue(v.eligible, v.reason)

    def test_a_fix_earlier_than_the_churn_window_floor_does_not_count(self):
        old = {"request_at": NOW - 90 * 86400, "churn_window_start": NOW - 60 * 86400}
        v = readback.read(Ticket(candidate=old), self._sources(
            decisions=[("req1", 1001, "approve", since(-75 * 86400))],
            outcomes=[("req1", "approved", since(-75 * 86400))],
            messages=[("1001", "sent", "uvn-status", since(-75 * 86400))]))
        self.assertFalse(v.eligible)

    def test_an_earlier_open_credit_wait_is_the_start_of_wait(self):
        # credit_open.oldest is the earliest still-open credit request, and the wait began then:
        # a fix newer than that counts even though it predates the newest request, while a fix
        # from before it does not.
        candidate = {"request_at": NOW - 10 * 86400,
                     "credit_open": {"oldest": NOW - 40 * 86400, "request_ids": ["req1"]},
                     "churn_window_start": NOW - 60 * 86400}

        def verdict(age_days):
            at = since(-age_days * 86400)
            return readback.read(Ticket(candidate=candidate), self._sources(
                decisions=[("req1", 1001, "approve", at)],
                outcomes=[("req1", "approved", at)],
                messages=[("1001", "sent", "uvn-status", at, ["req1"])]))

        self.assertTrue(verdict(20).eligible)
        self.assertFalse(verdict(45).eligible)

    def test_a_decision_and_note_about_another_request_is_not_this_fix(self):
        # The ticket is waiting on req-a. A credit approved for req-b (and a note naming req-b)
        # says nothing about the thing this user complained about.
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "credit_open": {"request_ids": ["req-a"]}})
        v = readback.read(ticket, self._sources(
            decisions=[("req-b", 1001, "approve", since())],
            outcomes=[("req-b", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req-b"])]))
        self.assertFalse(v.eligible)
        self.assertIn("requests this user is waiting on", v.reason)

    def test_a_ticket_without_a_request_binding_is_held_even_when_another_request_was_fixed(self):
        # The candidate schema makes request_ids optional. Without them we cannot tell whether an
        # approval belongs to the request this user complained about, so an unrelated approval
        # must not certify the ticket (the no-ID A/B case).
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400})
        v = readback.read(ticket, self._sources(
            decisions=[("req-b", 1001, "approve", since())],
            outcomes=[("req-b", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req-b"])]))
        self.assertFalse(v.eligible)
        self.assertIn("no request binding", v.reason)

    def test_the_waiting_request_approved_and_named_is_the_pass(self):
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "credit_open": {"request_ids": ["req-a"]}})
        v = readback.read(ticket, self._sources(
            decisions=[("req-b", 1001, "approve", since()),
                       ("req-a", 1001, "approve", since())],
            outcomes=[("req-a", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req-b"]),
                      ("1001", "sent", "uvn-status", since(), ["req-a"])]))
        self.assertTrue(v.eligible, v.reason)
        self.assertEqual(v.evidence["credits_approved"], 1)

    def test_a_pending_request_blocks_a_ticket_even_when_another_is_fixed(self):
        # The ticket names req-a and req-b. req-b is approved and the user was told, but req-a is
        # still pending: the copy says the thing they waited for is done, and for req-a it is not.
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "credit_open": {"request_ids": ["req-a", "req-b"]}})
        v = readback.read(ticket, self._sources(
            decisions=[("req-a", 1001, "hold", since()),
                       ("req-b", 1001, "approve", since())],
            outcomes=[("req-b", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req-b"])]))
        self.assertFalse(v.eligible)
        self.assertIn("req-a", v.reason)

    def test_every_waiting_request_must_be_named_in_the_status_note(self):
        # Both requests are approved, but the note names only req-b: the user has not been told
        # about req-a, so the ticket is not Seen.
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "credit_open": {"request_ids": ["req-a", "req-b"]}})
        v = readback.read(ticket, self._sources(
            decisions=[("req-a", 1001, "approve", since()),
                       ("req-b", 1001, "approve", since())],
            outcomes=[("req-a", "approved", since()), ("req-b", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req-b"])]))
        self.assertFalse(v.eligible)
        self.assertIn("does not know yet", v.reason)

    def test_two_approvals_each_with_their_own_note_are_both_seen(self):
        # A is approved and told, then B is approved and told later. Ordering the note query from
        # the LATEST approval dropped A's earlier note and held a user who had been told about
        # both fixes, so each request's note is read against its own outcome.
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "credit_open": {"request_ids": ["req-a", "req-b"]}})
        v = readback.read(ticket, self._sources(
            decisions=[("req-a", 1001, "approve", since(-3000)),
                       ("req-b", 1001, "approve", since(-1200))],
            outcomes=[("req-a", "approved", since(-3000)),
                      ("req-b", "approved", since(-1200))],
            messages=[("1001", "sent", "uvn-status", since(-2900), ["req-a"]),
                      ("1001", "sent", "uvn-status", since(-1100), ["req-b"])]))
        self.assertTrue(v.eligible, v.reason)
        self.assertEqual(v.evidence["credits_approved"], 2)

    def test_a_note_for_one_request_does_not_cover_another_approved_later(self):
        # A single note names both requests but was sent after A was approved and before B was:
        # the user was not told about B at a point when B's fix existed.
        ticket = Ticket(candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "credit_open": {"request_ids": ["req-a", "req-b"]}})
        v = readback.read(ticket, self._sources(
            decisions=[("req-a", 1001, "approve", since(-3000)),
                       ("req-b", 1001, "approve", since(-600))],
            outcomes=[("req-a", "approved", since(-3000)),
                      ("req-b", "approved", since(-600))],
            messages=[("1001", "sent", "uvn-status", since(-2500), ["req-a", "req-b"])]))
        self.assertFalse(v.eligible)
        self.assertIn("does not know yet", v.reason)

    def test_a_status_note_from_before_the_approval_is_not_being_told(self):
        v = readback.read(Ticket(), self._sources(
            decisions=[("req1", 1001, "approve", since(-600))],
            outcomes=[("req1", "approved", since(-600))],
            messages=[("1001", "sent", "uvn-status", since(-7200))]))
        self.assertFalse(v.eligible)
        self.assertIn("does not know yet", v.reason)

    def test_a_ticket_with_no_start_of_wait_is_never_seen(self):
        # A DATA gap in one ticket, not an outage: the run has to bucket it as `undatable` so a
        # missing request date is never reported to operators as "Trino/Intercom is down".
        v = readback.read(Ticket(candidate={}), self._sources(
            decisions=[("req1", 1001, "approve", since())],
            outcomes=[("req1", "approved", since())],
            messages=[("1001", "sent", "uvn-status", since(), ["req1"])]))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("undatable"), v.reason)
        self.assertNotIn("unreadable", v.reason)

    def test_an_unreadable_ledger_is_a_hold(self):
        sources = readback.Sources(ledger="/nonexistent/ledger.sqlite3")
        v = readback.read(Ticket(), sources)
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("unreadable"))

    def test_an_unreadable_decision_outcomes_table_is_a_source_outage_not_an_approval_zero(self):
        tmp = tempfile.mkdtemp()
        path = ledger(tmp, decisions=[("req1", 1001, "approve", since())],
                      outcomes=[("req1", "approved", since(-10))],
                      messages=[("1001", "sent", "uvn-status", since(-5))])
        db = sqlite3.connect(path)
        db.executescript("DROP TABLE decision_outcomes;"
                         "CREATE TABLE decision_outcomes (id INTEGER PRIMARY KEY, run_id TEXT);")
        db.commit()
        db.close()
        v = readback.read(Ticket(), readback.Sources(ledger=path, run_sql=lambda sql: []))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("unreadable"), v.reason)


class ClaimReadbackTest(unittest.TestCase):
    def _ticket(self):
        return Ticket(lane=model.CLAIM, primary_class="merge_claim_stuck")

    def test_processed_is_a_fix(self):
        rows = [["c1", "processed", "2023-11-10T00:00:00Z", "2023-11-10T00:00:00Z", ""]]
        v = readback.read(self._ticket(), readback.Sources(run_sql=lambda sql: rows))
        self.assertTrue(v.eligible)
        self.assertEqual(v.evidence["merge_claim_result"], "claim")

    def test_a_processed_claim_with_no_date_is_held(self):
        # Without a terminal date the claim cannot be dated against the wait, so a 2023 processed
        # row must not certify a 2026 ticket.
        v = readback.read(self._ticket(), readback.Sources(run_sql=lambda sql: [["processed"]]))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_claim_ticket_with_no_start_of_wait_is_never_seen(self):
        ticket = Ticket(lane=model.CLAIM, primary_class="merge_claim_stuck", candidate={})
        rows = [["c1", "processed", "2023-11-10T00:00:00Z", "2023-11-10T00:00:00Z", ""]]
        v = readback.read(ticket, readback.Sources(run_sql=lambda sql: rows))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("undatable"), v.reason)

    def test_pending_is_not(self):
        v = readback.read(self._ticket(), readback.Sources(run_sql=lambda sql: [["pending"]]))
        self.assertFalse(v.eligible)
        self.assertIn("pending", v.reason)

    def test_an_empty_read_is_a_data_gap_not_a_source_outage(self):
        # Trino answered; this user simply has no claiming row. That is a permanent gap in the
        # ticket's own data, so it must spend a read-back attempt and reach the datagap bucket
        # rather than masquerade as "the replica is down" for ever.
        v = readback.read(self._ticket(), readback.Sources(run_sql=lambda sql: []))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_historical_processed_claim_does_not_certify_a_newer_pending_one(self):
        # One account can have several claiming rows. An old `processed` must not make a new
        # pending claim look done.
        rows = [["old", "processed", "2023-10-01T00:00:00Z", "2023-10-01T00:00:00Z", ""],
                ["new", "pending", "2023-11-10T00:00:00Z", "2023-11-10T00:00:00Z", ""]]
        v = readback.read(self._ticket(), readback.Sources(run_sql=lambda sql: rows))
        self.assertFalse(v.eligible)
        self.assertIn("pending", v.reason)

    def test_the_claim_this_ticket_is_waiting_on_must_be_the_processed_one(self):
        rows = [["new", "pending", "2023-11-10T00:00:00Z", "2023-11-10T00:00:00Z", ""],
                ["old", "processed", "2023-10-01T00:00:00Z", "2023-10-01T00:00:00Z", ""]]
        ticket = Ticket(lane=model.CLAIM, primary_class="merge_claim_stuck",
                        candidate={"request_at": NOW - 30 * 86400,
                                   "churn_window_start": NOW - 60 * 86400,
                                   "claims": {"claim_id": "new"}})
        v = readback.read(ticket, readback.Sources(run_sql=lambda sql: rows))
        self.assertFalse(v.eligible)
        self.assertIn("pending", v.reason)

    def test_a_claim_processed_before_the_wait_is_not_this_fix(self):
        rows = [["old", "processed", "2023-09-01T00:00:00Z", "2023-09-01T00:00:00Z", ""]]
        v = readback.read(self._ticket(), readback.Sources(run_sql=lambda sql: rows))
        self.assertFalse(v.eligible)
        self.assertIn("predates", v.reason)

    def test_a_trino_error_is_unknown(self):
        def boom(sql):
            raise RuntimeError("trino exit 2: table not found")
        v = readback.read(self._ticket(), readback.Sources(run_sql=boom))
        self.assertFalse(v.eligible)
        self.assertIn("unreadable", v.reason)


class ClickUpReadbackTest(unittest.TestCase):
    def _task(self, status="resolved", type_="done", tags=("customer-outcome:complete",), desc=""):
        return {"id": "abc123", "status": {"status": status, "type": type_},
                "tags": [{"name": t} for t in tags], "description": desc, "text_content": desc}

    def test_closed_and_customer_complete_is_a_fix(self):
        sources = readback.Sources(clickup_task=lambda t: self._task())
        v = readback.read(Ticket(lane=model.MERGE, primary_class="merge_claim_stuck", lane_ref="abc123"), sources)
        self.assertTrue(v.eligible)
        self.assertEqual(v.evidence["merge_claim_result"], "merge")

    def test_open_task_is_not(self):
        sources = readback.Sources(clickup_task=lambda t: self._task(status="in progress", type_="open"))
        v = readback.read(Ticket(lane=model.MERGE, lane_ref="abc123"), sources)
        self.assertFalse(v.eligible)

    def test_closed_without_the_outcome_tag_is_not(self):
        sources = readback.Sources(clickup_task=lambda t: self._task(tags=()))
        v = readback.read(Ticket(lane=model.MERGE, lane_ref="abc123"), sources)
        self.assertFalse(v.eligible)
        self.assertIn("customer-outcome:complete", v.reason)

    def test_analytics_needs_a_fresh_as_of(self):
        stale = self._task(desc="Spotify numbers refreshed. as of: 2020-01-01")
        fresh = self._task(desc="Spotify numbers refreshed. as of: 2023-11-10T04:00:00Z")
        ticket = Ticket(lane=model.ANALYTICS, primary_class="analytics_stale_wrong", lane_ref="abc123")
        self.assertFalse(readback.read(ticket, readback.Sources(clickup_task=lambda t: stale,
                                                               now=lambda: NOW)).eligible)
        sources = readback.Sources(clickup_task=lambda t: fresh, now=lambda: NOW)
        v = readback.read(ticket, sources)
        self.assertTrue(v.eligible, v.reason)
        self.assertEqual(v.evidence["as_of"], "2023-11-10T04:00:00Z")
        self.assertEqual(v.evidence["platform"], "Spotify")

    def test_analytics_with_a_future_as_of_is_not_fresh(self):
        # A future stamp makes the age negative; it must not certify a fix we cannot measure.
        future = self._task(desc="Spotify numbers refreshed. as of: 2024-11-02T04:00:00Z")
        ticket = Ticket(lane=model.ANALYTICS, primary_class="analytics_stale_wrong", lane_ref="abc123")
        v = readback.read(ticket, readback.Sources(clickup_task=lambda t: future, now=lambda: NOW))
        self.assertFalse(v.eligible)

    def test_analytics_with_two_platforms_is_a_hold_not_a_guess(self):
        # The task text embeds evidence written elsewhere; putting a platform in a customer's copy
        # that the fix never touched is the exact failure R2 exists to prevent.
        both = self._task(desc="Apple Music numbers refreshed; the ticket also mentions Spotify. "
                               "as of: 2023-11-10T04:00:00Z")
        ticket = Ticket(lane=model.ANALYTICS, primary_class="analytics_stale_wrong", lane_ref="abc123")
        v = readback.read(ticket, readback.Sources(clickup_task=lambda t: both, now=lambda: NOW))
        self.assertFalse(v.eligible)
        self.assertIn("exactly one platform", v.reason)

    def test_apple_music_is_not_shadowed_by_apple(self):
        self.assertEqual(readback._platform_from("Apple Music numbers updated"), "Apple Music")
        self.assertEqual(readback._platform_from("Amazon Music numbers updated"), "Amazon Music")

    def test_a_deleted_task_is_a_data_gap_not_a_source_outage(self):
        v = readback.read(Ticket(lane=model.MERGE, lane_ref="abc123"),
                          readback.Sources(clickup_task=lambda task_id: None))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_clickup_error_is_a_source_outage(self):
        def boom(task_id):
            raise RuntimeError("clickup 500")
        v = readback.read(Ticket(lane=model.MERGE, lane_ref="abc123"),
                          readback.Sources(clickup_task=boom))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("unreadable"), v.reason)

    def test_no_task_id_is_not_a_pass(self):
        v = readback.read(Ticket(lane=model.MERGE, lane_ref=None), readback.Sources(clickup_task=lambda t: None))
        self.assertFalse(v.eligible)


class RefundReadbackTest(unittest.TestCase):
    """The refund lane's record is the task a PERSON closes, carrying the Stripe object."""

    def _task(self, *, type_="done", tags=("customer-outcome:complete",),
              desc="Refunded in Stripe. stripe_refund_id: re_3Qabc123XYZ stripe_refund_amount: 49.00"):
        return {"id": "abc123", "status": {"status": "resolved", "type": type_},
                "tags": [{"name": t} for t in tags], "description": desc, "text_content": desc}

    def _sources(self, task, *, cents=4900, status="succeeded", exists=True, raises=None,
                 customer="cus_123"):
        def stripe(_refund_id):
            if raises is not None:
                raise raises
            if not exists:
                return None
            return {"id": _refund_id, "status": status, "amount": cents,
                    "charge": {"customer": customer}}

        return readback.Sources(clickup_task=lambda t: task, stripe_refund=stripe)

    def _ticket(self, customer="cus_123"):
        return Ticket(lane=model.REFUND, primary_class="billing_confusion", lane_ref="abc123",
                      candidate={"customer_id": customer} if customer else {})

    def test_no_task_id_is_a_hold(self):
        v = readback.read(Ticket(lane=model.REFUND, primary_class="billing_confusion"),
                          readback.Sources(clickup_task=lambda t: self._task(),
                                           stripe_refund=lambda rid: {"status": "succeeded", "amount": 4900}))
        self.assertFalse(v.eligible)

    def test_an_open_refund_task_is_not_a_refund(self):
        v = readback.read(self._ticket(), self._sources(self._task(type_="open")))
        self.assertFalse(v.eligible)

    def test_a_decision_without_a_stripe_id_is_not_a_refund(self):
        v = readback.read(self._ticket(), self._sources(self._task(desc="Refund approved, no id yet.")))
        self.assertFalse(v.eligible)
        self.assertIn("Stripe", v.reason)

    def test_a_refund_object_is_a_fix_and_carries_the_amount(self):
        v = readback.read(self._ticket(), self._sources(self._task()))
        self.assertTrue(v.eligible, v.reason)
        self.assertEqual(v.evidence["refund_amount"], "49.00")
        self.assertEqual(v.evidence["stripe_refund_id"], "re_3Qabc123XYZ")

    def test_a_task_with_no_refund_id_or_amount_is_a_data_gap(self):
        # A person closed the task without pasting the id (or the amount). Nothing about this
        # ticket changes on its own, so it must spend an attempt and land in `datagap` instead of
        # reading as "still waiting" for ever.
        for desc in ("Refund approved, no id yet.", "stripe_refund_id: re_3Qabc123XYZ"):
            v = readback.read(self._ticket(), self._sources(self._task(desc=desc)))
            self.assertFalse(v.eligible, desc)
            self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_refund_id_stripe_does_not_hold_is_a_data_gap(self):
        # A typo'd id: Stripe answered and holds nothing, so nothing changes without a person
        # editing the task. It must land in `datagap`, not read as "still waiting".
        v = readback.read(self._ticket(), self._sources(self._task(), exists=False))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_refund_id_with_no_amount_cannot_name_the_money(self):
        v = readback.read(self._ticket(), self._sources(self._task(desc="stripe_refund_id: re_3Qabc123XYZ")))
        self.assertFalse(v.eligible)
        self.assertIn("amount", v.reason)

    def test_a_grouped_amount_is_read_as_the_dollars_it_records(self):
        # The task body renders the charge as `$1,234.00` and tells the person to write the amount
        # in dollars, so the grouped form is the one they copy. Truncating at the comma told the
        # customer a $1,234 refund was $1.00.
        for written, expected in (("$1,234.00", "1234.00"), ("1,234.56", "1234.56"),
                                  ("$49", "49.00"), ("1234.00", "1234.00")):
            v = readback.read(self._ticket(), self._sources(self._task(
                desc=f"Refunded in Stripe. stripe_refund_id: re_3Qabc123XYZ stripe_refund_amount: {written}"),
                cents=int(Decimal(expected) * 100)))
            self.assertTrue(v.eligible, f"{written}: {v.reason}")
            self.assertEqual(v.evidence["refund_amount"], expected, written)

    def test_a_malformed_amount_is_held_not_guessed_and_not_closed(self):
        # A grouping typo used to become evidence of a fix, and the renderer then marked the
        # ticket ineligible for good - so the user whose money WAS refunded never heard from us,
        # and correcting the ClickUp task could not help. Held means still routed, still re-read.
        for written, expected in (("1,23.00", "not a dollar figure"),
                                  ("1,2345.00", "not a dollar figure"),
                                  ("some", "records no amount")):
            v = readback.read(self._ticket(), self._sources(self._task(
                desc=f"Refunded in Stripe. stripe_refund_id: re_3Qabc123XYZ stripe_refund_amount: {written}")))
            self.assertFalse(v.eligible, written)
            self.assertIsNone(v.evidence.get("refund_amount"), written)
            self.assertIn(expected, v.reason)

    def test_the_amount_is_read_as_the_dollars_the_task_records(self):
        # The refund task instruction says `stripe_refund_amount: <dollars>`. Reading it as cents
        # turned a $49 refund into "$0.49" in the customer's copy.
        for written, expected in (("49", "49.00"), ("49.00", "49.00"), ("49.5", "49.50"),
                                  ("4900", "4900.00")):
            v = readback.read(self._ticket(), self._sources(self._task(
                desc=f"Refunded in Stripe. stripe_refund_id: re_3Qabc123XYZ stripe_refund_amount: {written}"),
                cents=int(Decimal(expected) * 100)))
            self.assertTrue(v.eligible, f"{written}: {v.reason}")
            self.assertEqual(v.evidence["refund_amount"], expected, written)

    def test_a_refund_that_is_not_succeeded_is_not_a_fix(self):
        for status in ("pending", "failed", "canceled"):
            v = readback.read(self._ticket(), self._sources(self._task(), status=status))
            self.assertFalse(v.eligible, status)
            self.assertIn(status, v.reason)

    def test_an_amount_that_disagrees_with_stripe_is_not_a_fix(self):
        v = readback.read(self._ticket(), self._sources(self._task(), cents=4800))
        self.assertFalse(v.eligible)
        self.assertIn("48.00", v.reason)
        self.assertIn("49.00", v.reason)

    def test_the_message_states_stripes_amount_not_the_tasks(self):
        v = readback.read(self._ticket(), self._sources(self._task(
            desc="stripe_refund_id: re_3Qabc123XYZ stripe_refund_amount: $49"), cents=4900))
        self.assertTrue(v.eligible, v.reason)
        self.assertEqual(v.evidence["refund_amount"], "49.00")
        self.assertEqual(v.evidence["stripe_status"], "succeeded")

    def test_a_refund_stripe_does_not_have_is_not_a_fix(self):
        v = readback.read(self._ticket(), self._sources(self._task(), exists=False))
        self.assertFalse(v.eligible)
        self.assertIn("no refund object", v.reason)

    def test_a_refund_for_another_customer_is_not_a_fix(self):
        # Same amount, someone else's charge: the customer's copy must not say their money came back.
        v = readback.read(self._ticket(), self._sources(self._task(), customer="cus_other"))
        self.assertFalse(v.eligible)
        self.assertIn("another customer", v.reason)

    def test_a_refund_without_customer_ownership_is_not_a_fix(self):
        v = readback.read(self._ticket(customer=None), self._sources(self._task()))
        self.assertFalse(v.eligible)
        self.assertIn("customer", v.reason)

    def test_a_refund_object_without_a_customer_is_not_a_fix(self):
        sources = self._sources(self._task())
        sources.stripe_refund = lambda rid: {"id": rid, "status": "succeeded", "amount": 4900}
        v = readback.read(self._ticket(), sources)
        self.assertFalse(v.eligible)
        self.assertIn("which customer", v.reason)

    def test_an_unreadable_stripe_is_unknown_and_never_ineligible(self):
        # UNKNOWN is a third state: the ticket stays routed and is re-read, so an outage can
        # neither close the user out nor become evidence that their money came back.
        for exc in (readback.SourceUnreadable("stripe could not be run"), RuntimeError("boom")):
            v = readback.read(self._ticket(), self._sources(self._task(), raises=exc))
            self.assertFalse(v.eligible)
            self.assertTrue(v.reason.startswith("unreadable"), v.reason)
            self.assertEqual(v.evidence["stripe_refund_id"], "re_3Qabc123XYZ")

    def test_the_stripe_cli_is_read_through_stripe_bin(self):
        # The real reader, executed: a fake `stripe` on STRIPE_BIN stands in for the live CLI.
        cases = [
            ('printf \'{"id": "re_3Qabc123XYZ", "status": "succeeded", "amount": 4900, '
             '"charge": {"customer": "cus_123"}}\'', True),
            ('printf \'{"error": {"code": "resource_missing", "message": "No such refund"}}\'; exit 1',
             False),
            ('echo "not json"; exit 1', False),
        ]
        for body, expected in cases:
            bindir = pathlib.Path(tempfile.mkdtemp())
            fake = bindir / "stripe"
            fake.write_text(f"#!/bin/sh\n{body}\n")
            fake.chmod(0o755)
            with mock.patch.dict(os.environ, {"STRIPE_BIN": str(fake)}):
                v = readback.read(self._ticket(), readback.Sources(clickup_task=lambda t: self._task()))
            self.assertEqual(v.eligible, expected, f"{body}: {v.reason}")
            if not expected and "resource_missing" in body:
                self.assertIn("no refund object", v.reason)
            if not expected and "not json" in body:
                self.assertTrue(v.reason.startswith("unreadable"), v.reason)


def conversation(*parts, open_=False):
    return {"open": open_, "conversation_parts": {"conversation_parts": list(parts)}}


def admin(body, at=NOW - 10 * 86400, name="Nadia (Muso)", part_type="comment"):
    return {"author": {"type": "admin", "name": name}, "body": body, "created_at": at,
            "part_type": part_type}


LONG_ANSWER = ("You were right that these are the same profile and I am sorry it took us so long to sort out. "
               "I merged the duplicate into the account you log in with, moved every credit across, and "
               "checked that the second profile no longer appears in search results for your name. Nothing "
               "else about the account changed and the extra seat you had is back on the plan.")


class IntercomReadbackTest(unittest.TestCase):
    def _sources(self, conv):
        return readback.Sources(fetch_conversation=lambda cid: conv)

    def _ticket(self, convs=("215476631700310",)):
        return Ticket(lane=model.CAROLINE, primary_class="other", candidate={
            "intercom_convs": list(convs),
            "request_at": NOW - 30 * 86400,
            "churn_window_start": NOW - 60 * 86400,
        })

    def test_open_thread_is_not_a_fix(self):
        v = readback.read(self._ticket(), self._sources(conversation(admin(LONG_ANSWER), open_=True)))
        self.assertFalse(v.eligible)

    def test_a_short_admin_line_is_not_an_answer(self):
        v = readback.read(self._ticket(), self._sources(conversation(admin("Closing this chat."))))
        self.assertFalse(v.eligible)

    def test_a_sweep_line_is_not_a_human_answer(self):
        sweep = ("Closing this chat as there was no response from you. If you still need help you can reply "
                 "to this message at any time and the team will pick it back up on the next business day.")
        v = readback.read(self._ticket(), self._sources(conversation(admin(sweep))))
        self.assertFalse(v.eligible)

    def test_a_human_answer_on_a_closed_thread_is_a_fix(self):
        v = readback.read(self._ticket(), self._sources(conversation(admin(LONG_ANSWER))))
        self.assertTrue(v.eligible, v.reason)
        self.assertIn("You were right that these are the same profile", v.human_reply)

    def test_an_internal_note_is_never_the_answer_a_customer_waited_for(self):
        # Intercom notes are staff-only. A long internal note is not a reply to the customer, so
        # it can neither prove the fix nor be quoted back to them in the win-back email.
        v = readback.read(self._ticket(), self._sources(
            conversation(admin(LONG_ANSWER, part_type="note"))))
        self.assertFalse(v.eligible)
        self.assertNotIn("human_reply", v.evidence)

    def test_a_later_internal_note_does_not_unset_an_answer_the_customer_saw(self):
        # The note came after the customer-visible answer but the customer never replied, so the
        # thread WAS closed on that answer.
        v = readback.read(self._ticket(), self._sources(
            conversation(admin(LONG_ANSWER, at=NOW - 20 * 86400),
                         admin("Internal: check the seat credit before the next billing run.",
                               at=NOW - 10 * 86400, part_type="note"))))
        self.assertTrue(v.eligible, v.reason)
        self.assertIn("You were right that these are the same profile", v.human_reply)

    def test_a_customer_reply_after_the_answer_is_not_a_fix(self):
        # The admin answered at length, then the customer wrote back that it is still broken and
        # the thread was closed after that. The close does not make the earlier answer a fix.
        customer = {"author": {"type": "user", "name": "Dana"},
                    "body": "This is still broken, nothing changed for me.",
                    "created_at": NOW - 10 * 86400}
        v = readback.read(self._ticket(), self._sources(
            conversation(admin(LONG_ANSWER, at=NOW - 20 * 86400), customer)))
        self.assertFalse(v.eligible)
        self.assertIn("newer message", v.reason)

    def test_a_close_before_the_answer_is_not_tied_to_it(self):
        conv = conversation(admin(LONG_ANSWER, at=NOW - 10 * 86400))
        conv["closed_at"] = NOW - 20 * 86400
        v = readback.read(self._ticket(), self._sources(conv))
        self.assertFalse(v.eligible)
        self.assertIn("closed before", v.reason)

    def test_no_conversation_id_is_a_hold(self):
        v = readback.read(self._ticket(convs=()), self._sources(conversation(admin(LONG_ANSWER))))
        self.assertFalse(v.eligible)

    def test_an_intercom_error_is_a_hold(self):
        def boom(cid):
            raise RuntimeError("intercom 503")
        v = readback.read(self._ticket(), readback.Sources(fetch_conversation=boom))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("unreadable"), v.reason)

    def test_a_conversation_with_no_open_state_is_a_data_gap(self):
        conv = {"conversation_parts": {"conversation_parts": [admin(LONG_ANSWER)]}}
        v = readback.read(self._ticket(), self._sources(conv))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_data_gap_on_every_conversation_leads_the_composite_reason(self):
        # The caller classifies on the first token, so a gap shared by every conversation has to
        # lead the composite instead of hiding behind a conversation id.
        conv = {"conversation_parts": {"conversation_parts": [admin(LONG_ANSWER)]}}
        v = readback.read(self._ticket(convs=("546", "547")), self._sources(conv))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("datagap"), v.reason)

    def test_a_partly_read_thread_is_answered_from_what_was_read(self):
        # One conversation could not be fetched, the other was and holds no answer: the reason
        # reports the answer we DID read, so the ticket spends an attempt like any other miss.
        def sometimes(cid):
            if cid == "546":
                raise RuntimeError("intercom 503")
            return conversation(admin("Thanks, looking into it now."))

        v = readback.read(self._ticket(convs=("546", "547")),
                          readback.Sources(fetch_conversation=sometimes))
        self.assertFalse(v.eligible)
        self.assertFalse(v.reason.startswith("unreadable"), v.reason)

    def test_an_old_answered_thread_does_not_certify_a_newer_open_complaint(self):
        # The ticket carries both conversations. The older one was closed with a long answer,
        # but the current complaint is still open, so the user is still waiting.
        convs = {
            "546": conversation(admin(LONG_ANSWER, at=NOW - 20 * 86400)),
            "547": conversation(admin("Thanks, looking into it now.", at=NOW - 10 * 86400),
                                open_=True),
        }
        v = readback.read(self._ticket(convs=("546", "547")),
                          readback.Sources(fetch_conversation=lambda cid: convs[cid]))
        self.assertFalse(v.eligible)
        self.assertIn("still open", v.reason)

    def test_an_answer_older_than_the_wait_is_not_a_fix(self):
        # The thread is still live after the wait began, but the long reply predates the request
        # the user is waiting on, so it cannot be the fix.
        customer = {"author": {"type": "user", "name": "Dana"},
                    "body": "Any update on this?", "created_at": NOW - 20 * 86400}
        v = readback.read(self._ticket(), self._sources(
            conversation(admin(LONG_ANSWER, at=NOW - 40 * 86400), customer)))
        self.assertFalse(v.eligible)
        self.assertIn("predates the start of wait", v.reason)

    def test_a_thread_resolved_before_the_wait_is_not_the_current_complaint(self):
        # The only conversation ended before this wait began, so nothing establishes the wait.
        v = readback.read(self._ticket(), self._sources(
            conversation(admin(LONG_ANSWER, at=NOW - 40 * 86400))))
        self.assertFalse(v.eligible)
        self.assertIn("nothing establishes", v.reason)

    def test_an_unreadable_conversation_blocks_an_otherwise_eligible_ticket(self):
        def sometimes(cid):
            if cid == "546":
                raise RuntimeError("intercom 503")
            return conversation(admin(LONG_ANSWER))

        v = readback.read(self._ticket(convs=("546", "547")),
                          readback.Sources(fetch_conversation=sometimes))
        self.assertFalse(v.eligible)
        self.assertTrue(v.reason.startswith("unreadable"), v.reason)


class RedactStaffTextTest(unittest.TestCase):
    """stdout gets the redacted view; the 0600 files keep the text."""

    def test_a_reply_is_replaced_by_its_length_wherever_it_sits(self):
        reply = "You were right that these are the same profile and the merge is fixed now"
        doc = {"seen": [{"user_id": "1001", "human_reply": reply,
                        "evidence": {"human_reply": reply}}],
               "not_yet": 2}
        redacted = readback.redact_staff_text(doc)
        placeholder = "<redacted, %d words>" % len(reply.split())
        self.assertEqual(redacted["seen"][0]["human_reply"], placeholder)
        self.assertEqual(redacted["seen"][0]["evidence"]["human_reply"], placeholder)
        self.assertEqual(redacted["not_yet"], 2)
        self.assertEqual(doc["seen"][0]["human_reply"], reply)


class StaffTest(unittest.TestCase):
    def test_staff_and_test_addresses(self):
        for email in ("aaron@muso.ai", "qa@example.com", "test1@somewhere.com", "demo@label.com", ""):
            self.assertTrue(audience.is_staff_or_test(email), email)

    def test_real_customers_pass(self):
        for email in ("nadia@bigcatrecords.com", "mixer@studio.co"):
            self.assertFalse(audience.is_staff_or_test(email), email)


class SelectTest(unittest.TestCase):
    def _people(self, uid="1001", **kw):
        rec = audience.Recipient(user_id=uid, email=kw.get("email", "nadia@bigcatrecords.com"),
                                 first_name=kw.get("first_name", "Nadia"),
                                 email_confirmed=kw.get("confirmed", True),
                                 is_admin=kw.get("is_admin", False), live_subs=kw.get("live", 0))
        return {uid: rec}

    CLEAR = {"verdict": "none", "coverage": "full"}

    def _select(self, ticket, **kw):
        """Default: a full-coverage affiliation verdict of `none`, i.e. every box ticked."""
        verdicts = kw.get("verdicts")
        if verdicts is None:
            verdicts = {ticket.user_id: self.CLEAR}
        return audience.select([ticket], policy=POLICY,
                               people=kw.get("people", self._people(ticket.user_id)),
                               watchlist=kw.get("watchlist"), verdicts=verdicts,
                               already_messaged=kw.get("messaged"), cap=kw.get("cap"))

    def test_a_clean_user_is_in_the_batch(self):
        batch = self._select(Ticket())
        self.assertEqual([d.user_id for d in batch.send], ["1001"])

    def test_the_holdout_is_never_in_the_batch(self):
        uid = next(i for i in range(100, 400) if model.holdout(str(i), 10, 0))
        batch = self._select(Ticket(user_id=str(uid)))
        self.assertEqual(batch.send, [])
        self.assertEqual(len(batch.holdout), 1)

    def test_paying_again_is_held(self):
        batch = self._select(Ticket(), people=self._people(live=1))
        self.assertEqual(batch.reasons(), {"paying_again": 1})

    def test_an_unparseable_subscription_count_is_held_not_read_as_zero(self):
        batch = self._select(Ticket(), people=self._people(live=None))
        self.assertEqual(batch.reasons(), {"unreadable: live subscription count": 1})

    def test_resolve_people_marks_a_malformed_count_unreadable(self):
        rows = [["1001", "nadia@bigcatrecords.com", "Nadia", "false", "true", "not-a-number"]]
        people = audience.resolve_people(["1001"], run_sql=lambda sql: rows)
        self.assertIsNone(people["1001"].live_subs)

    def test_dispute_is_held(self):
        batch = self._select(Ticket(candidate={"disputes": 1}))
        self.assertEqual(batch.reasons(), {"open_dispute": 1})

    def test_staff_is_held(self):
        batch = self._select(Ticket(), people=self._people(email="someone@muso.ai"))
        self.assertEqual(batch.reasons(), {"staff_or_test": 1})

    def test_unconfirmed_email_is_held(self):
        batch = self._select(Ticket(), people=self._people(confirmed=False))
        self.assertEqual(batch.reasons(), {"email_not_confirmed": 1})

    def test_a_missing_core_row_is_held_not_skipped(self):
        batch = self._select(Ticket(user_id="4242"), people={})
        self.assertEqual(list(batch.reasons()), ["unreadable: core read returned no row for this user"])

    def test_already_messaged_is_held(self):
        batch = self._select(Ticket(user_id="4242"), people=self._people("4242"), messaged=lambda uid: True)
        self.assertEqual(batch.reasons(), {"campaign_once": 1})

    def test_watchlisted_is_held(self):
        class WL:
            user_ids = frozenset({1001})
        batch = self._select(Ticket(), watchlist=WL())
        self.assertEqual(batch.reasons(), {"fraud_watchlist": 1})

    def test_affiliated_is_held(self):
        verdicts = {"1001": {"verdict": "verified_org", "coverage": "full"}}
        batch = self._select(Ticket(), verdicts=verdicts)
        self.assertEqual(batch.reasons(), {"org_affiliated": 1})

    def test_unknown_affiliation_is_held(self):
        batch = self._select(Ticket(), verdicts={"9999": {"verdict": "none", "coverage": "full"}})
        self.assertEqual(batch.reasons(), {"affiliation_unknown": 1})

    def test_the_per_run_cap_holds_the_rest(self):
        rows = [Ticket(user_id=str(uid)) for uid in ("1001", "1002", "1003")]
        people = {}
        for uid in ("1001", "1002", "1003"):
            people[uid] = audience.Recipient(uid, f"n{uid}@label.com", "N", True, False, 0)
        verdicts = {uid: self.CLEAR for uid in people}
        batch = audience.select(rows, policy=POLICY, people=people, verdicts=verdicts, cap=2)
        self.assertEqual(len(batch.send), 2)
        self.assertEqual(batch.reasons(), {"cap_per_run": 1})


class ReturnsTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.store = tickets.TicketStore(self.dir / "tickets.sqlite")

    def tearDown(self):
        self.store.close()

    def _route(self, uid, *, seen=True):
        from churn import model as _m
        row = tickets.draft(_m.Candidate(user_id=uid, tier="T2-open-told-wait",
                                         primary_class="credits_not_approved", mrr_cents=4900,
                                         cancel_at=NOW - 30 * 86400),
                            lane=_m.CREDIT_REVIEW, now=NOW, paid_priority_days=30)
        self.store.route(row, now=NOW)
        ticket = self.store.get(row["ticket_id"])
        if seen:
            self.store.mark_seen(ticket.ticket_id, evidence={"credits_approved": 2}, at=NOW)
        return ticket

    def test_rates_and_text(self):
        self._route("1001")
        self._route("1002")
        cohort = returns.build_cohort(self.store, policy=POLICY)
        self.assertEqual(set(cohort.intent), {"1001", "1002"})
        sqls: list[str] = []

        def run_sql(sql):
            sqls.append(sql)
            return [["1001", time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW + 3600))]]

        doc = returns.report(self.store, policy=POLICY, run_sql=run_sql, now=NOW + 86400)
        self.assertEqual(doc["intent_to_treat"], {"returned": 1, "n": 2, "rate": 0.5})
        self.assertEqual(doc["holdout"]["rate"], None)  # nobody in the control group: no rate claimed
        self.assertIn("holdout 0/0 (n/a)", returns.text(doc))
        # The return window is CLOSED at each user's own bound: without an upper bound, every
        # subscription created after the send counts as a return, including one from a year later,
        # and the line creeps up forever.
        self.assertTrue(all("< TIMESTAMP" in sql for sql in sqls), sqls)
        self.assertEqual(doc["until"], doc["since"] + 30 * 86400.0)

    def test_the_window_is_per_user_so_a_late_fix_can_still_count(self):
        # The campaign runs daily for months, so fixes read back at different times. With one
        # campaign-wide bound, the return of anyone fixed after its 30th day could never register.
        self._route("1001")
        late = self._route("1002", seen=False)
        self.store.mark_seen(late.ticket_id, evidence={"credits_approved": 2}, at=NOW + 45 * 86400)
        created = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW + 60 * 86400))

        def run_sql(sql):
            return [["1001", created], ["1002", created]]

        doc = returns.report(self.store, policy=POLICY, run_sql=run_sql, now=NOW + 61 * 86400)
        # 1001 was fixed and messaged at T, so its 30-day window closed at T+30d: nothing counts.
        # 1002 was fixed at T+45d, so a subscription at T+60d is inside ITS window.
        self.assertEqual(doc["intent_to_treat"], {"returned": 1, "n": 2, "rate": 0.5})

    def test_a_subscription_outside_a_users_own_window_is_not_a_return(self):
        self._route("1001")
        created = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW + 31 * 86400))
        doc = returns.report(self.store, policy=POLICY, now=NOW + 32 * 86400,
                            run_sql=lambda sql: [["1001", created]])
        self.assertEqual(doc["intent_to_treat"]["returned"], 0)

    def test_intent_to_treat_is_the_headline_because_selection_cannot_bias_it(self):
        # Per-protocol ("messaged") drops every user whose fix did not read back, which is exactly
        # the cohort most likely to have gone badly: comparing it to an unselected control flatters
        # the campaign. The ITT arm is every non-holdout routed user, messaged or not.
        self._route("1001")
        self._route("1002", seen=False)  # routed, fix not seen
        cohort = returns.build_cohort(self.store, policy=POLICY)
        self.assertEqual(set(cohort.intent), {"1001", "1002"})
        doc = returns.report(self.store, policy=POLICY, run_sql=lambda sql: [], now=NOW + 86400)
        self.assertEqual(doc["intent_to_treat"], {"returned": 0, "n": 2, "rate": 0.0})
        line = returns.text(doc)
        self.assertTrue(line.startswith("wb_fix_1 returns over 30d: intent-to-treat 0/2"), line)
        self.assertNotIn("messaged-only", line)

    def test_holdout_members_are_the_never_messaged_control(self):
        uid = next(i for i in range(100, 400) if model.holdout(str(i), 10, 0))
        self._route(str(uid), seen=False)
        cohort = returns.build_cohort(self.store, policy=POLICY)
        self.assertEqual(set(cohort.holdout), {str(uid)})

    def test_an_unfixed_user_is_anchored_on_the_moment_we_touched_them(self):
        # Ruling (firstmate inbox 008): anchor EVERY routed user at fixed_at if set else routed_at,
        # so a user whose fix never read back can still register a return. Anchoring only fixed
        # users gave every unfixed control a window that could never open, which diluted the
        # holdout toward zero and flattered the campaign.
        self._route("1002", seen=False)
        created = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW + 3600))
        doc = returns.report(self.store, policy=POLICY, now=NOW + 86400,
                            run_sql=lambda sql: [["1002", created]])
        self.assertEqual(doc["intent_to_treat"], {"returned": 1, "n": 1, "rate": 1.0})
        self.assertEqual(doc["fixed_vs_unfixed"]["intent_to_treat"]["unfixed"],
                         {"returned": 1, "n": 1, "rate": 1.0})
        self.assertEqual(doc["fixed_vs_unfixed"]["intent_to_treat"]["fixed"]["n"], 0)

    def test_an_unfixed_holdout_user_can_register_a_return(self):
        uid = next(i for i in range(100, 400) if model.holdout(str(i), 10, 0))
        self._route(str(uid), seen=False)
        created = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(NOW + 3600))
        doc = returns.report(self.store, policy=POLICY, now=NOW + 86400,
                            run_sql=lambda sql: [[str(uid), created]])
        self.assertEqual(doc["holdout"], {"returned": 1, "n": 1, "rate": 1.0})
        self.assertEqual(doc["fixed_vs_unfixed"]["holdout"]["unfixed"]["returned"], 1)
        self.assertEqual(doc["denominators"]["holdout"], 1)

    def test_a_user_with_neither_anchor_is_counted_as_unmeasurable(self):
        ticket = self._route("1002", seen=False)
        self.store.db.execute("UPDATE fix_tickets SET routed_at = 0 WHERE ticket_id = ?",
                              (ticket.ticket_id,))
        self.store.db.commit()
        cohort = returns.build_cohort(self.store, policy=POLICY)
        self.assertEqual(cohort.unmeasurable, {"1002"})
        self.assertEqual(set(cohort.intent), set())
        doc = returns.report(self.store, policy=POLICY, now=NOW + 86400, run_sql=lambda sql: [])
        self.assertEqual(doc["denominators"]["unmeasurable"], 1)
        self.assertEqual(doc["intent_to_treat"], {"returned": 0, "n": 0, "rate": None})
        self.assertIn("unmeasurable 1", returns.text(doc))

    def test_per_tier_and_per_lane_numbers_are_labelled_as_holdout_only(self):
        # The artifact is what the weekly churn line reads. A per-tier number scored against the
        # holdout is NOT the campaign's per-tier rate, so it must never be published under a name
        # that reads as one.
        uid = next(i for i in range(100, 400) if model.holdout(str(i), 10, 0))
        self._route(str(uid), seen=False)
        self._route("1001")
        doc = returns.report(self.store, policy=POLICY, run_sql=lambda sql: [], now=NOW + 86400)
        self.assertNotIn("by_tier", doc)
        self.assertNotIn("by_lane", doc)
        self.assertEqual(sum(b["n"] for b in doc["holdout_by_tier"].values()), doc["holdout"]["n"])
        self.assertEqual(sum(b["n"] for b in doc["holdout_by_lane"].values()), doc["holdout"]["n"])

    def test_one_holdout_user_with_two_tickets_is_counted_once_per_tier(self):
        # fix_tickets is keyed per (user, class), so a user whose primary class changed has two
        # rows. Appending per row counted them twice in a per-tier denominator, which made the
        # holdout rate a rate over tickets while the headline was a rate over people.
        uid = next(i for i in range(100, 400) if model.holdout(str(i), 10, 0))
        for cause in ("credits_not_approved", "billing_confusion"):
            row = tickets.draft(model.Candidate(user_id=str(uid), tier="T2-open-told-wait",
                                                primary_class=cause, mrr_cents=4900,
                                                cancel_at=NOW - 30 * 86400),
                                lane=model.CREDIT_REVIEW, now=NOW, paid_priority_days=30)
            self.store.route(row, now=NOW)
        doc = returns.report(self.store, policy=POLICY, run_sql=lambda sql: [], now=NOW + 86400)
        self.assertEqual(doc["holdout"]["n"], 1)
        self.assertEqual(sum(b["n"] for b in doc["holdout_by_tier"].values()), 1)
        self.assertEqual(sum(b["n"] for b in doc["holdout_by_lane"].values()), 1)

    def test_report_is_written_atomically(self):
        self._route("1001")
        doc = returns.report(self.store, policy=POLICY, run_sql=lambda sql: [], now=NOW)
        path = returns.write_report(doc, state_dir=self.dir)
        self.assertTrue(path.exists())
        self.assertEqual(json.loads(path.read_text())["campaign"], "wb_fix_1")


if __name__ == "__main__":
    unittest.main()
