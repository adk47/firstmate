"""Unit tests for the churn win-back routing model, store and lane writers.

The property under test is R2's precondition, not a happy path: every user with an unhandled
support state lands in exactly one owning lane, once, and every path that cannot prove a fix
refuses to produce a message.
"""

import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from churn import lanes, model, state, tickets  # noqa: E402

POLICY = json.loads((pathlib.Path(__file__).resolve().parent.parent / "policies" / "winback-fix.json").read_text())
SCHEDULE = tuple(POLICY["readback"]["backoff_hours"])


def cand(**kw):
    base = dict(user_id="1001", tier="T2-open-told-wait", primary_class="credits_not_approved",
                mrr_cents=4900, plan="muso_team_pro_graduated_monthly", reason="cancellation_requested",
                cancel_at=1_700_000_000.0, wait_days=120.0, evidence=["3 open credit requests"])
    base.update(kw)
    return model.Candidate(**base)


class NormalizeClassTest(unittest.TestCase):
    def test_strips_stage_prefix(self):
        self.assertEqual(model.normalize_class("open_told_wait:credits_not_approved"), "credits_not_approved")
        self.assertEqual(model.normalize_class("no_reply:proof_sent_no_update"), "proof_sent_no_update")
        self.assertEqual(model.normalize_class("promise_not_kept"), "other")
        self.assertEqual(model.normalize_class("promise_not_kept:other"), "other")

    def test_unknown_is_other_not_a_new_lane(self):
        self.assertEqual(model.normalize_class("weird_vendor_class"), "other")
        self.assertEqual(model.normalize_class(None), "other")
        self.assertEqual(model.normalize_class(""), "other")

    def test_every_measured_class_normalizes_to_itself(self):
        for cls in model.CLASSES:
            self.assertEqual(model.normalize_class(cls), cls)

    def test_tier_rank_orders_t1_first(self):
        self.assertLess(model.tier_rank("T1-unanswered"), model.tier_rank("T2-open-told-wait"))
        self.assertLess(model.tier_rank("T2-open-told-wait"), model.tier_rank("T3-silent-pending"))
        self.assertEqual(model.tier_rank("none"), len(model.TIERS))


class LaneTest(unittest.TestCase):
    def test_credit_class_goes_to_the_decider_queue(self):
        self.assertEqual(cand().lane, model.CREDIT_REVIEW)

    def test_proof_class_goes_to_the_proof_reread(self):
        self.assertEqual(cand(primary_class="proof_sent_no_update").lane, model.PROOF)

    def test_merge_class_splits_on_evidence(self):
        self.assertEqual(cand(primary_class="merge_claim_stuck").lane, model.MERGE)
        self.assertEqual(cand(primary_class="merge_claim_stuck", claims={"pending": 1}).lane, model.CLAIM)

    def test_analytics_class_goes_to_clickup_followup(self):
        self.assertEqual(cand(primary_class="analytics_stale_wrong").lane, model.ANALYTICS)

    def test_billing_goes_to_refund_and_escalates_over_150(self):
        small = cand(primary_class="billing_confusion", mrr_cents=4900)
        self.assertEqual(small.lane, model.REFUND)
        self.assertFalse(model.refund_escalates(small))
        big_annual = cand(primary_class="billing_confusion", mrr_cents=4900, plan="muso_pro_annual")
        self.assertEqual(big_annual.charge_cents, 58800)
        self.assertTrue(model.refund_escalates(big_annual))

    def test_other_goes_to_the_paid_thread_drain(self):
        self.assertEqual(cand(primary_class="other").lane, model.CAROLINE)

    def test_in_lane_sorts_by_mrr_then_wait(self):
        rows = [cand(user_id="a", mrr_cents=1000, wait_days=5),
                cand(user_id="b", mrr_cents=9000, wait_days=1),
                cand(user_id="c", mrr_cents=1000, wait_days=90)]
        buckets = model.in_lane(rows)
        self.assertEqual([c.user_id for c in buckets[model.CREDIT_REVIEW]], ["b", "c", "a"])


class HoldoutTest(unittest.TestCase):
    def test_is_deterministic_and_about_a_tenth(self):
        ids = [str(i) for i in range(2000)]
        hits = [i for i in ids if model.holdout(i, 10, 0)]
        self.assertEqual(hits, [i for i in ids if model.holdout(i, 10, 0)])
        self.assertGreater(len(hits), 150)
        self.assertLess(len(hits), 250)

    def test_rejects_a_zero_modulus(self):
        with self.assertRaises(ValueError):
            model.holdout("1", 0, 0)

    def test_the_assignment_is_the_documented_hashed_prefix(self):
        # The control group must not drift between runs, so the exact assignment is a contract
        # (policies/winback-fix.json holdout._doc, docs/support/churn-winback-fix-first.md): these
        # are the values sha256('muso-holdout:<id>') % 10 == 0 produces. Renaming the prefix would
        # reshuffle every control group mid-campaign, so it fails here instead.
        self.assertEqual([uid for uid in ("1000", "1001", "1002", "1005", "1008", "1012")
                          if model.holdout(uid, 10, 0)], ["1005", "1008", "1012"])
        self.assertFalse(model.holdout("1005", 10, 1))  # the residue is part of the assignment too


class TicketKeyTest(unittest.TestCase):
    def test_stable_and_per_class(self):
        a = cand().ticket_key()
        self.assertEqual(a, cand().ticket_key())
        self.assertNotEqual(a, cand(primary_class="other").ticket_key())
        self.assertNotEqual(a, cand(user_id="1002").ticket_key())
        self.assertEqual(len(a), 24)


class StateJsonTest(unittest.TestCase):
    def _write(self, rows, **doc):
        tmp = pathlib.Path(tempfile.mkdtemp()) / "candidates.json"
        payload = {"generated_at": 1_700_000_000.0, "candidates": rows, **doc}
        tmp.write_text(json.dumps(payload))
        return tmp

    def test_window_skips_old_and_unhandled(self):
        rows = [
            {"user_id": "1", "tier": "T1-unanswered", "primary": "no_reply:other", "mrr": 49.0,
             "cancel_at": 1_700_000_000.0 - 10 * 86400},
            {"user_id": "2", "tier": "none", "primary": "other", "mrr": 9.0,
             "cancel_at": 1_700_000_000.0 - 10 * 86400},
            {"user_id": "3", "tier": "T3-silent-pending", "primary": "credits_not_approved", "mrr": 49.0,
             "cancel_at": 1_700_000_000.0 - 300 * 86400},
        ]
        snap = state.load_json(self._write(rows))
        self.assertEqual([c.user_id for c in snap.candidates], ["1"])
        self.assertEqual(snap.skipped_tier_none, 1)
        self.assertEqual(snap.skipped_old, 1)
        self.assertEqual(snap.candidates[0].mrr_cents, 4900)

    def test_anchor_is_the_snapshot_never_the_wall_clock(self):
        rows = [{"user_id": "1", "tier": "T1-unanswered", "primary": "other", "mrr": 1.0,
                 "cancel_at": 1_700_000_000.0 - 59 * 86400}]
        snap = state.load_json(self._write(rows))
        self.assertAlmostEqual(snap.anchor, 1_700_000_000.0)
        self.assertEqual(len(snap.candidates), 1)


class StateSqliteTest(unittest.TestCase):
    def _store(self, rows, *, generated_at=None):
        path = pathlib.Path(tempfile.mkdtemp()) / "support-state.sqlite"
        db = sqlite3.connect(path)
        db.executescript(
            "CREATE TABLE support_state (user_id TEXT PRIMARY KEY, tier TEXT NOT NULL, primary_class TEXT NOT NULL,"
            " classes_json TEXT, mrr_cents INTEGER, plan TEXT, reason TEXT, cancel_at REAL NOT NULL, request_at REAL,"
            " wait_days REAL, evidence_json TEXT, intercom_convs_json TEXT, credit_open_json TEXT, claims_json TEXT,"
            " refunds INTEGER, disputes INTEGER, discount TEXT, customer_id TEXT, profile_id TEXT, measured_at REAL NOT NULL);"
            "CREATE TABLE support_state_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);"
        )
        for row in rows:
            db.execute(
                "INSERT INTO support_state (user_id, tier, primary_class, classes_json, mrr_cents, plan, reason,"
                " cancel_at, request_at, wait_days, evidence_json, intercom_convs_json, credit_open_json, claims_json,"
                " refunds, disputes, discount, customer_id, profile_id, measured_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (row["user_id"], row["tier"], row["primary_class"], json.dumps(row.get("classes", [])),
                 row["mrr_cents"], row.get("plan", ""), row.get("reason", ""), row["cancel_at"], 0.0,
                 row.get("wait_days", 0.0), json.dumps(row.get("evidence", [])),
                 json.dumps(row.get("intercom_convs", [])), json.dumps(row.get("credit_open", {})),
                 json.dumps(row.get("claims")) if row.get("claims") else None, row.get("refunds", 0),
                 row.get("disputes", 0), row.get("discount"), row.get("customer_id"), row.get("profile_id"), 1.7e9),
            )
        if generated_at:
            db.execute("INSERT INTO support_state_meta (k, v) VALUES ('generated_at', ?)", (str(generated_at),))
        db.commit()
        db.close()
        return path

    def test_reads_the_contract_and_anchors_on_generated_at(self):
        path = self._store(
            [{"user_id": "7", "tier": "T3-silent-pending", "primary_class": "credits_not_approved",
              "mrr_cents": 4900, "cancel_at": 1_700_000_000.0 - 20 * 86400, "wait_days": 290.0,
              "credit_open": {"open": 2, "oldest": 1.6e9}, "classes": ["credits_not_approved"]}],
            generated_at=1_700_000_000.0,
        )
        snap = state.load_sqlite(path)
        self.assertEqual(snap.source, "sqlite")
        self.assertEqual([c.user_id for c in snap.candidates], ["7"])
        self.assertEqual(snap.candidates[0].credit_open["open"], 2)
        self.assertEqual(snap.anchor, 1_700_000_000.0)

    def test_a_store_without_an_anchor_is_fatal(self):
        path = self._store([])
        with self.assertRaises(state.StateUnreadable):
            state.load_sqlite(path)

    def test_a_missing_store_names_the_producer_and_the_alternative(self):
        with self.assertRaises(state.StateUnreadable) as ctx:
            state.load_sqlite("/nonexistent/support-state.sqlite")
        self.assertIn("churn-risk-signal-prevent-p1", str(ctx.exception))
        self.assertIn("--source json", str(ctx.exception))


class TicketStoreTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.store = tickets.TicketStore(self.dir / "tickets.sqlite")
        self.row = tickets.draft(cand(), lane=model.CREDIT_REVIEW, now=1_700_000_000.0, paid_priority_days=30)

    def tearDown(self):
        self.store.close()

    def test_route_is_idempotent_and_keeps_one_row(self):
        status, first = self.store.route(self.row, now=1_700_000_000.0)
        self.assertEqual(status, "new")
        status, second = self.store.route(self.row, now=1_700_000_100.0)
        self.assertEqual(status, "existing")
        self.assertEqual(second.ticket_id, first.ticket_id)
        self.assertEqual(self.store.state_counts(), {"routed": 1})

    def test_route_records_the_lane_ref_and_audit(self):
        self.store.route(self.row, now=1_700_000_000.0)
        self.store.set_lane_ref(self.row["ticket_id"], "intake/credit-review.jsonl#abc")
        events = [r[0] for r in self.store.db.execute("SELECT event FROM fix_events ORDER BY id")]
        self.assertEqual(events, ["routed", "lane_ref"])
        self.assertEqual(self.store.get(self.row["ticket_id"]).lane_ref, "intake/credit-review.jsonl#abc")

    def test_only_seen_tickets_are_eligible_and_only_inside_the_window(self):
        self.store.route(self.row, now=1_700_000_000.0)
        self.assertEqual(self.store.eligible(7, now=1_700_000_500.0), [])
        self.store.mark_seen(self.row["ticket_id"], evidence={"credits_approved": 2}, at=1_700_000_000.0)
        self.assertEqual(len(self.store.eligible(7, now=1_700_000_500.0)), 1)
        self.assertEqual(self.store.eligible(7, now=1_700_000_000.0 + 8 * 86400), [])
        self.assertEqual(self.store.pending_readback(schedule=SCHEDULE, now=1_700_000_000.0 + 8 * 86400), [])

    def test_the_window_boundary_is_inclusive_at_the_cutoff_instant(self):
        fixed_at = 1_700_000_000.0
        self.store.route(self.row, now=fixed_at)
        self.store.mark_seen(self.row["ticket_id"], evidence={"credits_approved": 2}, at=fixed_at)
        cutoff = fixed_at + 7 * 86400.0
        self.assertEqual(len(self.store.eligible(7, now=cutoff)), 1)
        self.assertEqual(self.store.eligible(7, now=cutoff + 1.0), [])

    def test_ineligible_leaves_the_queue_and_never_becomes_eligible(self):
        self.store.route(self.row, now=1_700_000_000.0)
        self.store.mark_ineligible(self.row["ticket_id"], reason="no approved credit", at=1_700_000_010.0)
        self.assertEqual(self.store.eligible(30, now=1_700_000_020.0), [])
        self.assertEqual(self.store.pending_readback(schedule=SCHEDULE, now=1_700_000_020.0), [])
        self.assertEqual(self.store.state_counts(), {"ineligible": 1})

    def test_one_message_per_user_ever_is_a_constraint(self):
        self.store.route(self.row, now=1_700_000_000.0)
        ticket = self.store.get(self.row["ticket_id"])
        self.assertTrue(self.store.ledger_row(user_id="1001", ticket=ticket, body_sha256="a", state="handed"))
        self.assertFalse(self.store.ledger_row(user_id="1001", ticket=ticket, body_sha256="b", state="handed"))
        self.assertTrue(self.store.messaged("1001"))
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM send_messages").fetchone()[0], 1)


class ReadbackBudgetTest(unittest.TestCase):
    """The read-back queue is a budget: due under the policy's backoff, bounded, and finite."""

    NOW = 1_700_000_000.0

    def setUp(self):
        self.store = tickets.TicketStore(pathlib.Path(tempfile.mkdtemp()) / "tickets.sqlite")
        self.rows = {}
        for user_id in ("1001", "1002", "1003"):
            row = tickets.draft(cand(user_id=user_id), lane=model.CREDIT_REVIEW, now=self.NOW,
                                paid_priority_days=30)
            self.store.route(row, now=self.NOW)
            self.rows[user_id] = row["ticket_id"]
        self.ticket_id = self.rows["1001"]

    def tearDown(self):
        self.store.close()

    def _due(self, now):
        return {t.user_id for t in self.store.pending_readback(schedule=SCHEDULE, now=now)}

    def _attempt(self, at, reason="nothing has happened yet"):
        return self.store.record_readback(self.ticket_id, verdict="not-yet", schedule=SCHEDULE,
                                          detail={"reason": reason}, at=at)

    def test_the_first_attempt_is_not_due_until_its_interval_has_passed(self):
        self.assertEqual(self._due(self.NOW + 60), set())
        self.assertEqual(self._due(self.NOW + SCHEDULE[0] * 3600 - 1), set())
        self.assertEqual(self._due(self.NOW + SCHEDULE[0] * 3600), {"1001", "1002", "1003"})

    def test_each_attempt_waits_its_own_interval_from_the_previous_one(self):
        at = self.NOW
        for attempt, hours in enumerate(SCHEDULE):
            due_at = at + hours * 3600
            self.assertNotIn(self.rows["1001"], {t.ticket_id for t in self.store.pending_readback(
                schedule=SCHEDULE, now=due_at - 1)}, attempt)
            self.assertIn(self.rows["1001"], {t.ticket_id for t in self.store.pending_readback(
                schedule=SCHEDULE, now=due_at)}, attempt)
            self._attempt(at=due_at)
            at = due_at
        self.assertEqual(self.store.get(self.ticket_id).readback_attempts, len(SCHEDULE))

    def test_the_queue_is_bounded_and_oldest_due_first(self):
        # 1003 was routed first, so it is the most overdue and must be taken before 1001.
        self.store.db.execute("UPDATE fix_tickets SET routed_at = ? WHERE ticket_id = ?",
                              (self.NOW - 3 * 3600, self.rows["1003"]))
        self.store.db.execute("UPDATE fix_tickets SET routed_at = ? WHERE ticket_id = ?",
                              (self.NOW - 2 * 3600, self.rows["1002"]))
        self.store.db.commit()
        due = self.store.pending_readback(schedule=SCHEDULE, now=self.NOW + 3600, limit=2)
        self.assertEqual([t.user_id for t in due], ["1003", "1002"])

    def test_a_repeated_verdict_is_not_appended_to_the_audit_twice(self):
        self._attempt(at=self.NOW + 3600)
        self._attempt(at=self.NOW + 3600 + 6 * 3600)
        events = [r[0] for r in self.store.db.execute(
            "SELECT event FROM fix_events WHERE ticket_id = ? ORDER BY id", (self.ticket_id,))]
        self.assertEqual(events, ["routed", "readback:not-yet"])
        self.assertEqual(self.store.get(self.ticket_id).readback_attempts, 2)

    def test_a_changed_verdict_is_recorded(self):
        self._attempt(at=self.NOW + 3600)
        self._attempt(at=self.NOW + 3600 + 6 * 3600, reason="the ClickUp task was reopened")
        events = [r[0] for r in self.store.db.execute(
            "SELECT event FROM fix_events WHERE ticket_id = ? ORDER BY id", (self.ticket_id,))]
        self.assertEqual(events, ["routed", "readback:not-yet", "readback:not-yet"])

    def test_the_budget_ends_in_readback_exhausted_and_the_ticket_stays_routed(self):
        at = self.NOW
        for attempt, hours in enumerate(SCHEDULE):
            at = at + hours * 3600
            exhausted = self._attempt(at=at)
            self.assertEqual(exhausted, attempt == len(SCHEDULE) - 1, attempt)
        ticket = self.store.get(self.ticket_id)
        self.assertEqual(ticket.state, tickets.ROUTED)
        self.assertEqual([t.ticket_id for t in self.store.exhausted_readback(schedule=SCHEDULE)],
                         [self.ticket_id])
        self.assertNotIn(self.ticket_id, {t.ticket_id for t in self.store.pending_readback(
            schedule=SCHEDULE, now=at + 30 * 86400)})
        events = [r[0] for r in self.store.db.execute(
            "SELECT event FROM fix_events WHERE ticket_id = ? ORDER BY id", (self.ticket_id,))]
        self.assertEqual(events.count("readback_exhausted"), 1)


class LaneBuildTest(unittest.TestCase):
    def _row(self, **kw):
        row = tickets.draft(cand(**kw), lane=model.CREDIT_REVIEW, now=1_700_000_000.0, paid_priority_days=30)
        row["lane"] = model.lane_for(cand(**kw))
        return row

    def test_common_payload_carries_the_tag_and_the_paid_priority(self):
        payload = lanes.build(self._row(), policy=POLICY, lane=model.CREDIT_REVIEW)
        line = payload.payload
        self.assertEqual(line["tag"], "churned:2023-11-14")
        self.assertEqual(line["priority"], "paid")
        self.assertIn("cause:credits_not_approved", line["tags"])
        self.assertGreater(line["priority_until"], line["cancel_at"])
        self.assertTrue(line["no_customer_contact"])

    def test_paid_priority_is_anchored_on_the_routing_run_not_the_cancel(self):
        # R4 is a promotion we grant at routing time, and the audience is churned up to 60 days
        # before the snapshot: anchoring on cancel_at would hand the longest-waiting half a flag
        # that is already in the past, and decide.load_churn_priority drops a lapsed entry.
        routed_at = 1_700_000_000.0
        row = self._row(cancel_at=routed_at - 45 * 86400)
        self.assertAlmostEqual(row["paid_priority_until"], routed_at + 30 * 86400)
        self.assertGreater(row["paid_priority_until"], routed_at)
        payload = lanes.build(row, policy=POLICY, lane=model.CREDIT_REVIEW)
        self.assertAlmostEqual(payload.payload["priority_until"], routed_at + 30 * 86400)

    def test_refund_g8_classification_is_evidence_driven(self):
        self.assertEqual(lanes.refund_class(["charged after cancel"], refunds=0, annual=False),
                         lanes.G8_CHARGED_AFTER_CANCEL)
        self.assertEqual(lanes.refund_class([], refunds=1, annual=False), lanes.G8_REFUND_ASKED_UNANSWERED)
        self.assertEqual(lanes.refund_class([], refunds=0, annual=True), lanes.G8_ACCIDENTAL_ANNUAL)
        self.assertEqual(lanes.refund_class([], refunds=0, annual=False), lanes.G8_UNCLASSIFIED)

    def test_refund_payload_escalates_a_big_charge_to_the_systemic_lane(self):
        row = self._row(primary_class="billing_confusion", mrr_cents=4900)
        payload = lanes.build(row, policy=POLICY, lane=model.REFUND)
        self.assertFalse(payload.payload["escalate_to"])
        big = self._row(primary_class="billing_confusion", mrr_cents=4900, plan="muso_pro_annual")
        payload = lanes.build(big, policy=POLICY, lane=model.REFUND)
        self.assertEqual(payload.payload["escalate_to"], "cs-systemic-c3")

    def test_refund_task_body_states_the_read_back_contract(self):
        # readback.refund_verdict needs the tag AND both the Stripe id and the amount, so the person
        # reading the task must be told both; a task closed with only the id can never be read back.
        row = self._row(primary_class="billing_confusion", mrr_cents=4900)
        payload = lanes.build(row, policy=POLICY, lane=model.REFUND)
        readback = payload.payload["readback"]
        self.assertIn("customer-outcome:complete", readback)
        self.assertIn("stripe_refund_id", readback)
        self.assertIn("stripe_refund_amount", readback)
        self.assertIn(readback, lanes.task_body(payload, policy=POLICY)["description"])

    def test_analytics_payload_never_invents_a_profile_id(self):
        row = self._row(primary_class="analytics_stale_wrong")
        line = lanes.build(row, policy=POLICY, lane=model.ANALYTICS).payload
        self.assertIsNone(line["profile_id"])
        self.assertIn("resolved by the lane", line["profile_id_source"])

    def test_clickup_task_body_carries_marker_and_contract_tags(self):
        row = self._row(primary_class="analytics_stale_wrong")
        payload = lanes.build(row, policy=POLICY, lane=model.ANALYTICS)
        body = lanes.task_body(payload, policy=POLICY)
        self.assertIn(lanes.marker(row["ticket_id"]), body["description"])
        for tag in ("hydra-action-request", "action-source:churn-winback", "tier-2", "action:analytics-followup"):
            self.assertIn(tag, body["tags"])


class LaneWriteTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        row = tickets.draft(cand(), lane=model.CREDIT_REVIEW, now=1_700_000_000.0, paid_priority_days=30)
        self.payload = lanes.build(row, policy=POLICY, lane=model.CREDIT_REVIEW)
        self.row = row

    def _board_row(self, lane, **kw):
        row = tickets.draft(cand(primary_class="merge_claim_stuck", claims={"pending": 1}, **kw),
                            lane=lane, now=1_700_000_000.0, paid_priority_days=30)
        return row, lanes.build(row, policy=POLICY, lane=lane)

    def test_credit_lane_writes_no_queue_only_the_priority_list(self):
        # The decider already holds this user's request: the campaign supplies the ORDER, not a
        # second queue nobody drains (that was the finding).
        payload = lanes.build(tickets.draft(cand(), lane=model.CREDIT_REVIEW, now=1_700_000_000.0,
                                           paid_priority_days=30), policy=POLICY, lane=model.CREDIT_REVIEW)
        ref = lanes.write(payload, state_dir=self.dir, policy=POLICY, apply=True)
        self.assertEqual(ref, f"intake/churn-priority.json#{self.row['ticket_id']}")
        self.assertEqual(sorted(p.name for p in (self.dir / "intake").iterdir()), ["churn-priority.json"])

    def test_dry_run_writes_nothing_but_still_names_the_ref(self):
        ref = lanes.write(self.payload, state_dir=self.dir, policy=POLICY, apply=False)
        self.assertTrue(ref.startswith("intake/churn-priority.json#"))
        self.assertFalse((self.dir / "intake").exists())

    def test_apply_writes_one_priority_entry(self):
        lanes.write(self.payload, state_dir=self.dir, policy=POLICY, apply=True)
        doc = json.loads((self.dir / "intake" / "churn-priority.json").read_text())
        self.assertEqual(doc["schema"], "churn-priority/v1")
        self.assertEqual([e["user_id"] for e in doc["entries"]], ["1001"])
        self.assertGreater(doc["entries"][0]["until"], 1_700_000_000.0)

    def test_priority_list_is_idempotent_and_survives_a_bad_document(self):
        lanes.write(self.payload, state_dir=self.dir, policy=POLICY, apply=True)
        lanes.write(self.payload, state_dir=self.dir, policy=POLICY, apply=True)
        doc = json.loads((self.dir / "intake" / "churn-priority.json").read_text())
        self.assertEqual(len(doc["entries"]), 1)
        (self.dir / "intake" / "churn-priority.json").write_text("{not json")
        lanes.write(self.payload, state_dir=self.dir, policy=POLICY, apply=True)
        doc = json.loads((self.dir / "intake" / "churn-priority.json").read_text())
        self.assertEqual(len(doc["entries"]), 1)  # rebuilt, and the unreadable copy kept for a human
        self.assertTrue((self.dir / "intake" / "churn-priority.json.unreadable").exists())

    def test_board_lane_without_a_client_refuses_instead_of_inventing_a_ref(self):
        # A placeholder ref would persist as "already routed" and could never be read back.
        _, payload = self._board_row(model.MERGE)
        with self.assertRaises(lanes.LaneUnavailable):
            lanes.write(payload, state_dir=self.dir, policy=POLICY, apply=True, client=None)
        ref = lanes.write(payload, state_dir=self.dir, policy=POLICY, apply=False, client=None)
        self.assertTrue(ref.startswith("clickup:"))

    def test_board_lane_writes_one_task_into_the_drained_list(self):
        row, payload = self._board_row(model.ANALYTICS)
        seen = {}

        class FakeClient:
            def list_tasks(self, list_id, params, max_pages):  # noqa: D401 - test double
                seen["list_id"] = list_id
                return []

            def request(self, method, path, body=None, **kw):
                seen["body"] = body
                return 200, {"id": "86a1b2c3"}

        ref = lanes.write(payload, state_dir=self.dir, policy=POLICY, apply=True, client=FakeClient())
        self.assertEqual(ref, "86a1b2c3")
        self.assertEqual(seen["list_id"], POLICY["clickup"]["list_id"])
        self.assertIn(lanes.marker(row["ticket_id"]), json.dumps(seen["body"]))
        self.assertIn("churned:", json.dumps(seen["body"]))
        self.assertEqual(row["lane"], model.ANALYTICS)

    def test_sweep_copy_is_recognised(self):
        self.assertTrue(lanes.sweep_copy_like("Closing this chat as there was no response."))
        self.assertTrue(lanes.sweep_copy_like(""))
        self.assertFalse(lanes.sweep_copy_like(
            "You were right about the duplicate profile. I merged it into the one you log in with and "
            "moved all four credits across, so nothing is missing any more."))


if __name__ == "__main__":
    unittest.main()
