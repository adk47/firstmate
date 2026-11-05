"""Churn-risk signal (firstmate churn-risk-signal-prevent-p1).

Stdlib unittest only: no network, no Trino, no Intercom, no ClickUp. Every store and
policy lives in a temp dir, so nothing here can read or write /var/lib/hydra/churn
or /etc/hydra/churn-risk.disabled on the machine running it.

What is pinned, and why each matters:
  * stages: the report's regex / courtesy / promise / ask rules and the T1>T2>T3
    precedence, because the store's tiers ARE those rules; a silent edit here makes
    `--churned-since 60d` stop reproducing 86 / 81 / 184 and the weekly line lie.
  * store: JSON columns decode identically through user() and users(); a reader
    that gets "[...]" where it expects a list crashes a send queue.
  * risk.py: risk classes, the churned 30-day window (R4), renews-soonest order,
    and the fail-closed refusal to publish a fresh timestamp over a stale sweep.
  * risk_reader.py: fail-open on every bad input (missing, stale, malformed, kill
    file), an unknown user is never risk, and a reorder never invalidates a signed
    audience (the facts header hashes a SORTED list).
  * cancel_alert.py: the join, the dedup window, the survey escalation, and that a
    commit writes intake + sent + watermark only after the posts happened.
  * weekly_line.py: the window/tier counting behind the Monday line.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from churn import (cancel_alert, intercom, risk as risk_mod, risk_reader,  # noqa: E402
                   sources as src_mod, stages, support_state, weekly_line)
from churn import intercom as ic_mod  # noqa: E402
from churn.store import Store, decode_state_row  # noqa: E402
from churn.support_state import thread_facts  # noqa: E402

DAY = 86400.0
NOW = 1_790_000_000.0            # fixed epoch: no test depends on the wall clock


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def thread(*events: tuple[float, str, str], conv_id: str = "c1",
           state: str = "open", created: float | None = None) -> dict:
    return {"id": conv_id, "created_at": created if created is not None else events[0][0],
            "updated_at": events[-1][0], "state": state,
            "events": [{"at": at, "who": who, "body": body} for at, who, body in events]}


class PolicyFixture(unittest.TestCase):
    """A temp policy + store + risk file, and the env that points every module at them."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.policy_path = self.dir / "churn-risk.json"
        self.store_path = self.dir / "support-state.sqlite"
        self.risk_path = self.dir / "risk.json"
        self.kill_path = self.dir / "churn-risk.disabled"
        self.policy = {
            "_doc": "test policy",
            "store": {"dir": str(self.dir), "support_state": str(self.store_path),
                      "risk": str(self.risk_path),
                      "intake": str(self.dir / "intake.jsonl"),
                      "cancel_watermark": str(self.dir / "cancel-alert.watermark"),
                      "cancel_sent": str(self.dir / "cancel-alert.sent.json")},
            "kill_file": str(self.kill_path),
            "thresholds": {"customer_last_hours": 24, "request_pending_hours": 48,
                           "promise_no_followup_hours": 48, "thread_min_age_days": 2,
                           "churned_paid_priority_days": 30,
                           "thread_lookback_days": 120, "risk_max_age_hours": 36},
            "priority": {"churn_risk": {"enabled": True}},
            "risk": {"kinds": ["customer_last", "promise_no_followup", "request_pending",
                               "proof_no_update"]},
            "mrr": {"plan_list_usd": {"muso_individual_pro_monthly": 12.5,
                                      "muso_team_business_graduated_monthly": 49.0},
                    "default_usd": 12.5},
            "survey_immediate": ["customer_service", "low_quality"],
            "alert": {"dedup_days": 30, "on_demand_max": 5},
            "lanes": {"credits_not_approved": "credit-review",
                      "proof_sent_no_update": "credit-review",
                      "merge_claim_stuck": "merge-queue",
                      "billing_confusion": "refund-judge",
                      "analytics_stale_wrong": "analytics-followup",
                      "login_access": "caroline-backlog",
                      "other": "caroline-backlog"},
            "consumers": [],
            "slack": {"channel": "C0TEST",
                      "weekly_line": "churned with open support issue: {n} users / ${mrr} "
                                     "(T1 {t1} / T2 {t2} / T3 {t3}) - prev week {prev}",
                      "alert_line": "paying user cancelled with an open {class} issue "
                                    "({age}d, ${mrr}): route -> {lane} (user {user_id}, {tier}{extra})"},
        }
        self.write_policy()
        self._env = {k: os.environ.get(k) for k in ("CHURN_RISK_POLICY", "CHURN_SUPPORT_STATE")}
        os.environ["CHURN_RISK_POLICY"] = str(self.policy_path)
        os.environ["CHURN_SUPPORT_STATE"] = str(self.store_path)
        risk_reader.reset_cache()

    def tearDown(self) -> None:
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        risk_reader.reset_cache()
        self.tmp.cleanup()

    def write_policy(self) -> None:
        self.policy_path.write_text(json.dumps(self.policy), encoding="utf-8")

    def store(self, *, write: bool = True) -> Store:
        return Store(str(self.store_path), readonly=not write)

    def put(self, **row) -> dict:
        base = {"user_id": 1, "mode": "paying", "tier": "T1", "cause_class": "credits_not_approved",
                "kinds": ["customer_last"], "evidence": [{"kind": "no_reply"}],
                "anchor": iso(NOW - 3 * DAY), "ball_days": 3.0, "mrr_list": 12.5,
                "renews_at": iso(NOW + 5 * DAY), "intercom_conv_ids": ["c1"],
                "open_request_ids": ["r1"], "paying": 1, "churned_at": None,
                "plan": "muso_individual_pro_monthly", "cancel_reason": None,
                "service": None, "checked_at": iso(NOW), "run_id": "test"}
        base.update(row)
        st = self.store()
        try:
            st.put_user(base)
        finally:
            st.close()
        return base

    def write_risk(self, *, generated_at: float | None = None, users=(), churned=()) -> None:
        doc = {"generated_at": iso(generated_at if generated_at is not None else NOW),
               "counts": {"risk_users": len(list(users))}, "users": list(users),
               "churned": list(churned)}
        self.risk_path.write_text(json.dumps(doc), encoding="utf-8")


# ─── the report's stage rules ────────────────────────────────────────────────
class StageRules(unittest.TestCase):
    def setUp(self) -> None:
        self.t = stages.Thresholds()

    def test_customer_last_past_threshold_is_tier1(self):
        th = thread((NOW - 30 * DAY, "contact", "my credits are still missing"),
                    (NOW - 3 * DAY, "contact", "any update on this?"))
        issues = stages.classify_thread(th["events"], NOW, "c1", True, th["created_at"], self.t)
        self.assertEqual([i.kind for i in issues], [stages.KIND_NO_REPLY])
        self.assertEqual(issues[0].cause_class, "credits_not_approved")
        self.assertAlmostEqual(issues[0].days, 3.0, places=1)

    def test_courtesy_after_resolution_is_not_an_issue(self):
        th = thread((NOW - 10 * DAY, "contact", "my credits are missing"),
                    (NOW - 9 * DAY, "us", "fixed, added your credit"),
                    (NOW - 5 * DAY, "contact", "thanks!"))
        self.assertEqual(stages.classify_thread(th["events"], NOW, "c1", False, th["created_at"], self.t), [])

    def test_courtesy_after_a_promise_is_a_promise_not_a_close(self):
        th = thread((NOW - 10 * DAY, "contact", "my credits are missing"),
                    (NOW - 9 * DAY, "us", "we'll follow up in 2 business days"),
                    (NOW - 6 * DAY, "contact", "thanks"))
        issues = stages.classify_thread(th["events"], NOW, "c1", True, th["created_at"], self.t)
        self.assertEqual([i.kind for i in issues], [stages.KIND_PROMISE])

    def test_answered_and_closed_thread_is_not_an_issue_at_this_anchor(self):
        th = thread((NOW - 10 * DAY, "contact", "help"),
                    (NOW - 1 * DAY, "us", "here you go"), state="closed")
        self.assertEqual(stages.classify_thread(th["events"], NOW, "c1", False, th["created_at"], self.t), [])

    def test_open_thread_we_spoke_last_is_told_to_wait_unless_we_asked(self):
        hold = thread((NOW - 10 * DAY, "contact", "help"), (NOW - 6 * DAY, "us", "working on it"))
        self.assertEqual([i.kind for i in stages.classify_thread(
            hold["events"], NOW, "c1", True, hold["created_at"], self.t)], [stages.KIND_OPEN_TOLD_WAIT])
        ask = thread((NOW - 10 * DAY, "contact", "help"),
                     (NOW - 6 * DAY, "us", "could you send a screenshot of the split sheet?"))
        self.assertEqual(stages.classify_thread(ask["events"], NOW, "c1", True, ask["created_at"], self.t), [])

    def test_class_precedence_is_the_reports(self):
        self.assertEqual(stages.classify_text("please refund the charge and approve my credit"),
                         "billing_confusion")
        self.assertEqual(stages.classify_text("my streaming stats are not updating"), "analytics_stale_wrong")
        self.assertEqual(stages.classify_text("here are the documents you asked for, i attached them"),
                         "proof_sent_no_update")
        self.assertEqual(stages.classify_text("random words here"), "other")

    def test_pending_request_waits_for_the_threshold_and_the_absence_of_a_note(self):
        reqs = [{"request_id": "r1", "created_at": iso(NOW - 3 * DAY)}]
        issues, ids = stages.classify_requests(reqs, [], NOW, [], [], self.t, require_no_note=True)
        self.assertEqual([i.kind for i in issues], [stages.KIND_PENDING_REQUEST])
        self.assertEqual(ids, ["r1"])
        told, _ = stages.classify_requests(reqs, [], NOW, [NOW - 2 * DAY], [], self.t, require_no_note=True)
        self.assertEqual(told, [])
        # the baseline mode keeps the told user: not being asked is not the same as handled
        baseline, _ = stages.classify_requests(reqs, [], NOW, [NOW - 2 * DAY], [], self.t)
        self.assertEqual([i.kind for i in baseline], [stages.KIND_PENDING_REQUEST])

    def test_pending_claim_is_tier3(self):
        cls = stages.classify_user(anchor=NOW, threads=[],
                                   pending_claims=[{"claim_id": "9", "created_at": iso(NOW - 4 * DAY)}],
                                   t=self.t)
        self.assertEqual(cls.tier, "T3")
        self.assertEqual(cls.cause_class, "merge_claim_stuck")

    def test_a_pending_claim_with_a_status_note_is_not_an_unattended_case(self):
        # the documented class is "open past 48h with NO status note"; a claim we told
        # them about yesterday is handled work and must not outrank a truly unanswered
        # payer in risk.json (the note gate used to cover requests only).
        claims = [{"claim_id": "9", "created_at": iso(NOW - 4 * DAY)}]
        cls = stages.classify_user(anchor=NOW, threads=[], pending_claims=claims,
                                   tells=[NOW - 1 * DAY], t=self.t, require_no_note=True)
        self.assertEqual(cls.issues, [])
        self.assertIsNone(cls.tier)
        # a note from BEFORE the claim was opened does not count: it answered nothing
        stale = stages.classify_user(anchor=NOW, threads=[], pending_claims=claims,
                                     tells=[NOW - 6 * DAY], t=self.t, require_no_note=True)
        self.assertEqual([i.kind for i in stale.issues], [stages.KIND_PENDING_CLAIM])
        # the baseline mode keeps the told user: not being asked is not the same as handled
        baseline = stages.classify_user(anchor=NOW, threads=[], pending_claims=claims,
                                        tells=[NOW - 1 * DAY], t=self.t)
        self.assertEqual([i.kind for i in baseline.issues], [stages.KIND_PENDING_CLAIM])

    def test_tier_precedence_and_risk_kinds(self):
        cls = stages.classify_user(
            anchor=NOW, threads=[thread((NOW - 5 * DAY, "contact", "still broken"), conv_id="c9")],
            open_requests=[{"request_id": "r1", "created_at": iso(NOW - 6 * DAY)}], t=self.t)
        self.assertEqual(cls.tier, "T1")
        self.assertEqual(stages.risk_kinds(cls, self.t), ["customer_last", "request_pending"])

    def test_a_promise_short_of_48h_is_still_a_customer_last_risk(self):
        # customer answered "thanks" to our promise 30h ago: the report's class (a)
        # (they spoke last and waited), not yet class (c) (48h), and it must still
        # carry a risk kind or the cancel page skips a T1 row
        cls = stages.classify_user(
            anchor=NOW, threads=[thread((NOW - 10 * DAY, "contact", "where are my credits"),
                                        (NOW - 5 * DAY, "us", "i will follow up on this soon"),
                                        (NOW - 30 * 3600, "contact", "thanks"))], t=self.t)
        self.assertEqual(cls.tier, "T1")
        self.assertEqual(stages.risk_kinds(cls, self.t), ["customer_last"])

    def test_a_promise_past_48h_is_the_promise_risk(self):
        cls = stages.classify_user(
            anchor=NOW, threads=[thread((NOW - 10 * DAY, "contact", "where are my credits"),
                                        (NOW - 5 * DAY, "us", "i will follow up on this soon"),
                                        (NOW - 3 * DAY, "contact", "thanks"))], t=self.t)
        self.assertEqual(stages.risk_kinds(cls, self.t), ["promise_no_followup"])

    def test_told_to_wait_is_not_a_risk_kind(self):
        cls = stages.classify_user(
            anchor=NOW, threads=[thread((NOW - 10 * DAY, "contact", "help"),
                                        (NOW - 5 * DAY, "us", "working on it"))], t=self.t)
        self.assertEqual(cls.tier, "T2")
        self.assertEqual(stages.risk_kinds(cls, self.t), ["told_to_wait"])

    def test_iso_and_days_helpers(self):
        self.assertAlmostEqual(stages.iso_to_ts(iso(NOW)), NOW, places=0)
        self.assertEqual(stages.iso_to_ts(""), 0.0)
        self.assertEqual(stages.iso_to_ts("not a date"), 0.0)
        self.assertAlmostEqual(stages.days_between(NOW, NOW - 3 * DAY), 3.0)
        self.assertEqual(stages.days_between(NOW - DAY, NOW), 0.0)   # never negative


# ─── the store ───────────────────────────────────────────────────────────────
class StoreRoundTrip(PolicyFixture):
    def test_user_and_users_decode_json_columns_the_same_way(self):
        self.put(user_id=7)
        st = self.store(write=False)
        try:
            one = st.user(7)
            many = {r["user_id"]: r for r in st.users(mode="paying")}
        finally:
            st.close()
        self.assertEqual(one["kinds"], ["customer_last"])
        self.assertEqual(one["evidence_json"], [{"kind": "no_reply"}])
        self.assertEqual(one["intercom_conv_ids"], ["c1"])
        self.assertEqual(one["open_request_ids"], ["r1"])
        self.assertEqual(one, many[7])

    def test_decode_state_row_survives_junk(self):
        row = decode_state_row({"kinds": "not json", "evidence_json": None})
        self.assertEqual(row["kinds"], [])
        self.assertEqual(row["evidence_json"], [])

    def test_mode_filter_and_delete_mode_users(self):
        self.put(user_id=1, mode="paying")
        self.put(user_id=2, mode="paying")
        self.put(user_id=3, mode="churned", churned_at=iso(NOW - 2 * DAY))
        st = self.store()
        try:
            self.assertEqual(sorted(r["user_id"] for r in st.users(mode="paying")), [1, 2])
            self.assertEqual([r["user_id"] for r in st.users(mode="churned")], [3])
            self.assertEqual(st.delete_mode_users("paying", [1]), 1)
            self.assertEqual([r["user_id"] for r in st.users(mode="paying")], [1])
        finally:
            st.close()

    def test_a_resubscriber_keeps_their_churned_with_issue_history(self):
        """The 77 sequence: paying+issue -> cancel -> resubscribe must NOT erase the cancel.

        With `user_id` alone as the key, the third write REPLACED the churned row, so
        Monday's line reported 0 for that cancel and risk.json's churned set lost a user
        who had just come back - the win-back case this signal exists to see.
        """
        self.put(user_id=77, mode="paying", tier="T1", kinds=["customer_last"],
                 cause_class="credits_not_approved", checked_at=iso(NOW - 3 * DAY))
        self.put(user_id=77, mode="churned", tier="T1", kinds=["customer_last"],
                 cause_class="credits_not_approved", churned_at=iso(NOW - 2 * DAY),
                 paying=0, checked_at=iso(NOW - 2 * DAY))
        self.put(user_id=77, mode="paying", tier="T1", kinds=["customer_last"],
                 cause_class="credits_not_approved", checked_at=iso(NOW))   # came back
        st = self.store(write=False)
        try:
            paying = st.users(mode="paying")
            churned = st.users(mode="churned")
            newest = st.user(77)
            paying_only = st.user(77, mode="paying")
        finally:
            st.close()
        self.assertEqual([r["user_id"] for r in paying], [77])
        self.assertEqual([r["user_id"] for r in churned], [77], "the churned row survived the re-subscribe")
        self.assertEqual(churned[0]["churned_at"], iso(NOW - 2 * DAY))
        self.assertEqual(churned[0]["tier"], "T1")
        self.assertEqual(paying_only["churned_at"], None)
        self.assertEqual(newest["mode"], "paying", "the newest row answers an unqualified read")

    def test_a_corrupt_store_reads_as_empty_instead_of_raising(self):
        # a truncated sqlite (disk full mid-commit, killed write) is a DatabaseError, not
        # an OperationalError: readers must still reach their "no sweep finished" guards
        self.store_path.write_bytes(b"not a database at all")
        st = Store(str(self.store_path), readonly=True)
        try:
            self.assertIsNone(st.last_run("paying"))
            self.assertEqual(st.users(mode="paying"), [])
        finally:
            st.close()

    def test_a_writable_open_refuses_a_store_still_keyed_on_user_id_alone(self):
        """CREATE TABLE IF NOT EXISTS would accept it, and INSERT OR REPLACE would go
        back to replacing the churned row - silently, which is the whole bug."""
        with sqlite3.connect(self.store_path) as db:
            db.execute("CREATE TABLE support_state (user_id INTEGER PRIMARY KEY, mode TEXT NOT NULL,"
                       " tier TEXT, cause_class TEXT, kinds TEXT NOT NULL DEFAULT '[]',"
                       " evidence_json TEXT NOT NULL DEFAULT '[]', anchor TEXT,"
                       " ball_days REAL NOT NULL DEFAULT 0, mrr_list REAL, renews_at TEXT,"
                       " intercom_conv_ids TEXT NOT NULL DEFAULT '[]',"
                       " open_request_ids TEXT NOT NULL DEFAULT '[]',"
                       " paying INTEGER NOT NULL DEFAULT 0, churned_at TEXT, plan TEXT,"
                       " cancel_reason TEXT, service TEXT, checked_at TEXT NOT NULL,"
                       " run_id TEXT NOT NULL)")
        with self.assertRaises(SystemExit) as caught:
            Store(str(self.store_path))
        self.assertIn("PRIMARY KEY(user_id)", str(caught.exception))

    def test_runs_are_recorded_so_staleness_is_knowable(self):
        st = self.store()
        try:
            st.start_run("r1", "paying")
            st.finish_run("r1", users=2, errors=0, tiers={"T1": 2}, note="ok")
            run = st.last_run("paying")
        finally:
            st.close()
        self.assertEqual(run["users"], 2)
        self.assertIsNotNone(run["finished_at"])


# ─── risk.json builder ───────────────────────────────────────────────────────
class RiskBuild(PolicyFixture):
    def _run(self):
        st = self.store()
        try:
            st.start_run("r1", "paying")
            st.finish_run("r1", users=3, errors=0, tiers={}, note="")
            return risk_mod.build(st, self.policy, now=NOW)
        finally:
            st.close()

    def test_classes_order_and_counts(self):
        self.put(user_id=1, renews_at=iso(NOW + 20 * DAY), mrr_list=12.5)
        self.put(user_id=2, renews_at=iso(NOW + 2 * DAY), mrr_list=49.0, cause_class="billing_confusion")
        self.put(user_id=3, tier="T2", kinds=["told_to_wait"], cause_class="credits_not_approved")
        doc = self._run()
        # told_to_wait is not a risk class: 3 is excluded, 2 renews first
        self.assertEqual([r["user_id"] for r in doc["users"]], [2, 1])
        self.assertEqual(doc["counts"]["risk_users"], 2)
        self.assertEqual(doc["counts"]["mrr_risk"], 61.5)
        self.assertEqual(doc["counts"]["by_tier"], {"T1": 2})
        self.assertEqual(doc["counts"]["by_lane"], {"refund-judge": 1, "credit-review": 1})
        self.assertEqual(doc["users"][0]["renews_in_days"], 2.0)

    def test_churned_window_is_thirty_days(self):
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 3 * DAY))
        self.put(user_id=6, mode="churned", churned_at=iso(NOW - 40 * DAY))
        self.put(user_id=7, mode="churned", churned_at=iso(NOW - 10 * DAY), tier=None,
                 kinds=["told_to_wait"])
        doc = self._run()
        self.assertEqual([r["user_id"] for r in doc["churned"]], [5])
        self.assertEqual(doc["counts"]["churned"], 1)

    def _finish(self, run_id: str, mode: str) -> None:
        st = self.store()
        try:
            st.start_run(run_id, mode)
            st.finish_run(run_id, users=1, errors=0, tiers={}, note="")
        finally:
            st.close()

    def test_writes_atomically_and_refuses_a_stale_sweep(self):
        self.put(user_id=1)
        self._finish("r1", "paying")
        self._finish("c1", "churned")
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 0)
        doc = json.loads(self.risk_path.read_text())
        self.assertEqual(doc["counts"]["risk_users"], 1)
        self.assertEqual(doc["users"][0]["user_id"], 1)

        # a sweep that stopped finishing 100h ago: no file, exit 4, and an old file is
        # never refreshed with a new timestamp (a reader would trust that timestamp)
        self.risk_path.unlink()
        st = self.store()
        try:
            st.db.execute("UPDATE runs SET finished_at=?",
                          ((datetime.now(timezone.utc) - timedelta(hours=100))
                           .strftime("%Y-%m-%dT%H:%M:%SZ"),))
            st.db.commit()
        finally:
            st.close()
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 4)
        self.assertFalse(self.risk_path.exists())
        # the override is for a human running the publisher by hand, never for the cron
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json",
                                        "--allow-stale-store"]), 0)
        self.assertTrue(self.risk_path.exists())

    def test_the_published_policy_path_is_the_one_that_was_read(self):
        self.put(user_id=1)
        self._finish("r1", "paying")
        self._finish("c1", "churned")
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 0)
        doc = json.loads(self.risk_path.read_text())
        self.assertEqual(doc["policy"]["path"], str(self.policy_path))
        self.assertEqual(doc["policy"]["sha256"],
                         risk_mod.policy_digest(str(self.policy_path)))

    def test_never_finished_sweep_writes_nothing(self):
        self.store().close()
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 3)
        self.assertFalse(self.risk_path.exists())

    def test_a_fresh_paying_sweep_does_not_publish_over_a_dead_churned_sweep(self):
        # churned rows are never pruned: a fresh generated_at over a churned sweep that
        # never finished keeps calling answered users churned-with-issue for 30 days
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 3 * DAY))
        self.put(user_id=1)
        self._finish("r1", "paying")
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 3)
        self.assertFalse(self.risk_path.exists())

    def test_a_fresh_paying_sweep_does_not_publish_over_a_stale_churned_sweep(self):
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 3 * DAY))
        self.put(user_id=1)
        self._finish("r1", "paying")
        self._finish("c1", "churned")
        st = self.store()
        try:
            st.db.execute("UPDATE runs SET finished_at=? WHERE mode='churned'",
                          ((datetime.now(timezone.utc) - timedelta(hours=100))
                           .strftime("%Y-%m-%dT%H:%M:%SZ"),))
            st.db.commit()
        finally:
            st.close()
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 4)
        self.assertFalse(self.risk_path.exists())

    def test_a_sweep_that_finished_with_source_errors_writes_nothing(self):
        # an Intercom search failure yields zero threads, which reads as "nobody is
        # waiting": a fresh timestamp over it would drop every thread-based class
        self.put(user_id=1)
        st = self.store()
        try:
            st.start_run("r1", "paying")
            st.finish_run("r1", users=1, errors=2, tiers={}, note="intercom: 429")
            st.start_run("c1", "churned")
            st.finish_run("c1", users=0, errors=0, tiers={}, note="")
        finally:
            st.close()
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 5)
        self.assertFalse(self.risk_path.exists())
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json",
                                        "--allow-errored-store"]), 0)
        self.assertTrue(self.risk_path.exists())


# ─── a store that does not exist yet ────────────────────────────────────────
class MissingStoreReadOnly(PolicyFixture):
    """A fresh install runs every reader before the first nightly sweep finishes."""

    def test_reading_a_store_that_was_never_built_is_an_empty_store(self):
        missing = self.dir / "not-yet.sqlite"
        st = Store(str(missing), readonly=True)
        try:
            self.assertIsNone(st.last_run("paying"))
            self.assertEqual(st.users(mode="paying"), [])
            self.assertIsNone(st.user(1))
        finally:
            st.close()
        self.assertFalse(missing.exists())

    def test_risk_py_reaches_its_own_never_finished_guard(self):
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 3)
        self.assertFalse(self.risk_path.exists())

    def test_the_weekly_line_warns_instead_of_crashing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = weekly_line.main(["--policy", str(self.policy_path), "--json", "--now", str(NOW)])
        self.assertEqual(rc, 0)
        self.assertIn("no churned sweep has finished", json.loads(out.getvalue())["warning"])


# ─── the one reader ─────────────────────────────────────────────────────────
class RiskReaderFailOpen(PolicyFixture):
    def test_missing_file_means_no_override(self):
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertFalse(r.applies())
        self.assertIn("missing", r.why)
        self.assertEqual(r.sort_key(1), (1.0, 0.0, 0.0))

    def test_stale_file_means_no_override(self):
        self.write_risk(generated_at=NOW - 48 * 3600, users=[{"user_id": 1}])
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertFalse(r.applies())
        self.assertIn("stale", r.why)

    def test_kill_file_means_no_override(self):
        self.write_risk(users=[{"user_id": 1}])
        self.kill_path.write_text("")
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertFalse(r.applies())
        self.assertIn("kill file", r.why)

    def test_disabled_policy_means_no_override(self):
        self.policy["priority"]["churn_risk"]["enabled"] = False
        self.write_policy()
        self.write_risk(users=[{"user_id": 1}])
        self.assertFalse(risk_reader.Risk(self.policy, now=NOW).applies())

    def test_unreadable_policy_means_no_override(self):
        policy, why = risk_reader.load_policy(str(self.dir / "nope.json"))
        self.assertEqual(policy, {})
        self.assertTrue(why)
        self.assertFalse(risk_reader.Risk(policy, policy_why=why, now=NOW).applies())

    def test_a_malformed_file_leaves_every_queue_alone(self):
        # QA: valid JSON with no generated_at used to load rows and enable the override,
        # contradicting the documented fail-open contract
        for doc in ({"users": [{"user_id": 42}], "counts": {}},
                    {"generated_at": iso(NOW), "users": [{"user_id": 42}, {"no": "id"}]},
                    {"generated_at": iso(NOW), "users": {"user_id": 42}},
                    {"generated_at": iso(NOW), "churned": [{"user_id": 42}, {"nope": 1}]}):
            (self.dir / "risk.json").write_text(json.dumps(doc))
            r = risk_reader.Risk(self.policy, path=str(self.dir / "risk.json"), now=NOW)
            self.assertFalse(r.applies(), doc)
            self.assertTrue(r.why)
            self.assertEqual(r.sort_key(42), (1.0, 0.0, 0.0))

    def test_a_future_dated_file_is_not_authoritative(self):
        # a clock-skewed or hand-edited file would otherwise never be stale
        self.write_risk(generated_at=NOW + 6 * 3600, users=[{"user_id": 1}])
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertFalse(r.applies())
        self.assertIn("future", r.why)

    def test_a_churned_with_issue_user_sorts_paid_priority(self):
        # firstmate ruling 2026-11-04: sort_key falls back to churned_row() exactly like
        # lane() and renews_in_days(), so R4's paid-priority is real through this API
        self.write_risk(users=[{"user_id": 1, "renews_at": iso(NOW + 3 * DAY)}],
                        churned=[{"user_id": 7, "churned_at": iso(NOW - 5 * DAY),
                                  "mrr_list": 12.5, "lane": "credit-review"}])
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertTrue(r.applies())
        self.assertIsNone(r.row(7))
        self.assertTrue(r.paid_priority(7))
        self.assertEqual(r.sort_key(7), (0.0, risk_reader.FAR_FUTURE, -12.5))
        rows = [{"user_id": 9}, {"user_id": 7}, {"user_id": 1}]
        self.assertEqual([x["user_id"] for x in risk_reader.order_rows(rows, risk=r)],
                         [1, 7, 9])

    def test_sort_key_is_risk_first_then_renews_soonest(self):
        self.write_risk(users=[
            {"user_id": 1, "renews_at": iso(NOW + 20 * DAY), "mrr_list": 12.5},
            {"user_id": 2, "renews_at": iso(NOW + 2 * DAY), "mrr_list": 12.5},
            {"user_id": 3, "mrr_list": 49.0},                       # no renewal date
        ])
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertTrue(r.applies())
        rows = [{"user_id": 9}, {"user_id": 1}, {"user_id": 3}, {"user_id": 2}]
        self.assertEqual([x["user_id"] for x in risk_reader.order_rows(rows, risk=r)],
                         [2, 1, 3, 9])
        self.assertFalse(r.is_risk(9))
        self.assertEqual(r.sort_key(9), (1.0, 0.0, 0.0))

    def test_a_malformed_row_keeps_the_whole_one_pass_queue(self):
        # fail-open means "keep the queue's own order", never "drop the queue":
        # sorted() drains a generator, so a key that raises mid-sort used to leave the
        # fallback with an empty tail (three rows in, zero out).
        self.write_risk(users=[{"user_id": 1, "renews_at": iso(NOW + 3 * DAY)}])
        r = risk_reader.Risk(self.policy, now=NOW)
        rows = (row for row in [{"user_id": 9}, None, {"user_id": 1}])
        self.assertEqual(risk_reader.order_rows(rows, risk=r),
                         [{"user_id": 9}, None, {"user_id": 1}])

    def test_churned_row_expires_after_the_paid_priority_window(self):
        self.write_risk(churned=[{"user_id": 5, "churned_at": iso(NOW - 40 * DAY)}])
        r = risk_reader.Risk(self.policy, now=NOW)
        self.assertTrue(r.applies())
        self.assertIsNone(r.churned_row(5))
        self.assertFalse(r.paid_priority(5))

    def test_reorder_keeps_the_signed_header_and_every_entry(self):
        self.write_risk(users=[{"user_id": 2, "renews_at": iso(NOW + DAY)},
                               {"user_id": 1, "renews_at": iso(NOW + 9 * DAY)}])
        r = risk_reader.Risk(self.policy, now=NOW)
        doc = {"replica_facts": {"sha256": "deadbeef"},
               "users": [{"user_id": 1, "facts": {"a": 1}}, {"user_id": 2, "facts": {"a": 2}}]}
        out, moved, _ = risk_reader.order_document(doc, r)
        self.assertEqual([u["user_id"] for u in out["users"]], [2, 1])
        self.assertEqual(out["replica_facts"], doc["replica_facts"])
        self.assertEqual(sorted(u["user_id"] for u in out["users"]), [1, 2])

    def test_order_document_without_an_audience_is_a_noop(self):
        self.write_risk(users=[])
        r = risk_reader.Risk(self.policy, now=NOW)
        doc = {"generated_at": "x", "claims": []}
        out, moved, note = risk_reader.order_document(doc, r)
        self.assertEqual(out, doc)
        self.assertEqual(moved, 0)
        self.assertIn("no audience array", note)


# ─── store row -> the stage's thread dict (the canary's other half) ─────────
class StoredConvShape(unittest.TestCase):
    """The 2026-11-04 canary's second finding: `sweep()` passed the raw `conv` rows
    from read_conversations() to classify_user, which reads `events`, so every thread
    classified as empty and T1/T2 read 24/0 against the report's 86/81. The stage
    needs thread_facts(); this pins the round trip and the classification it buys."""

    def conv(self, **kw):
        base = {"conv_id": "c1", "updated_at": NOW - 5 * DAY, "created_at": NOW - 40 * DAY,
                "state": "open", "last_at": NOW - 5 * DAY, "last_who": "contact",
                "admin_at": NOW - 30 * DAY, "opening_body": "my credits are still missing",
                "last_body": "any update on this?", "our_last_body": "working on it",
                "external_ids": ["ext-1"], "read_full": 1, "rating": None}
        base.update(kw)
        return base

    def test_thread_facts_carries_the_events_the_stage_reads(self):
        th = thread_facts(self.conv())
        self.assertEqual([(e["who"], e["at"]) for e in th["events"]],
                         [("contact", NOW - 40 * DAY), ("us", NOW - 30 * DAY), ("contact", NOW - 5 * DAY)])
        self.assertEqual(th["id"], "c1")
        self.assertEqual(th["state"], "open")

    def test_a_stored_conv_classifies_as_an_unanswered_thread(self):
        cls = stages.classify_user(anchor=NOW, threads=[thread_facts(self.conv())],
                                   t=stages.Thresholds())
        self.assertEqual(cls.tier, "T1")
        self.assertEqual([i.kind for i in cls.issues], [stages.KIND_NO_REPLY])
        self.assertEqual(cls.conv_ids, ["c1"])

    def test_the_customers_last_message_survives_our_last_reply(self):
        # the cause class is read from the CUSTOMER's words; dropping last_body whenever
        # we spoke last classified "my credits are still missing" as `other`
        th = thread_facts(self.conv(last_who="us", last_at=NOW - 6 * DAY,
                                    updated_at=NOW - 6 * DAY, admin_at=NOW - 6 * DAY,
                                    opening_body="Hi",
                                    last_body="my credits are still missing",
                                    our_last_body="we'll check and get back"))
        cls = stages.classify_user(anchor=NOW, threads=[th], t=stages.Thresholds())
        self.assertEqual(cls.cause_class, "credits_not_approved")
        self.assertEqual(th["events"][-1]["who"], "us")

    def test_open_told_wait_needs_a_thread_touched_recently(self):
        t = stages.Thresholds()
        fresh = thread_facts(self.conv(state="open", last_who="us", last_at=NOW - 6 * DAY,
                                       updated_at=NOW - 6 * DAY, admin_at=NOW - 6 * DAY,
                                       created_at=NOW - 50 * DAY))
        # opened 50 d before the anchor, our last word 47 d before it: past the 45-day gate
        stale = thread_facts(self.conv(state="open", last_who="us", last_at=NOW - 47 * DAY,
                                       updated_at=NOW - 47 * DAY, admin_at=NOW - 47 * DAY,
                                       created_at=NOW - 50 * DAY))
        self.assertEqual([i.kind for i in stages.classify_user(
            anchor=NOW, threads=[fresh], t=t).issues], [stages.KIND_OPEN_TOLD_WAIT])
        # analyze.py's gate: an open thread nobody touched for 47 d is not a live hold
        self.assertEqual(stages.classify_user(anchor=NOW, threads=[stale], t=t).issues, [])

    def test_the_45_day_gate_is_policy_data(self):
        t = stages.Thresholds.from_policy({"thresholds": {"open_thread_recent_days": 90}})
        self.assertEqual(t.open_thread_recent_days, 90.0)
        self.assertEqual(stages.Thresholds().open_thread_recent_days, 45.0)


# ─── the reader must honour the caller's policy ────────────────────────────
class ReaderHonoursTheCallerPolicy(PolicyFixture):
    """2026-11-04 canary: cancel_alert.py loaded its policy, then called
    risk_reader.default() with no arguments, so it read the process default risk
    path and logged "risk file missing, no override" while its own policy named a
    real file. The reader now takes the caller's policy + path."""

    def test_a_caller_policy_and_path_are_used(self):
        self.write_policy()
        # generated now(): the reader judges staleness against the wall clock
        self.write_risk(generated_at=time.time(),
                        users=[{"user_id": 42, "tier": "T1", "class": "credits_not_approved",
                                "renew_in_days": 3.0, "mrr_list": 12.5}])
        policy, why = risk_reader.load_policy(str(self.policy_path))
        self.assertEqual(why, "")
        risk_reader.reset_cache()
        risk = risk_reader.default(policy=policy, path=str(self.risk_path))
        self.assertTrue(risk.applies(), risk.why)
        self.assertEqual(risk.source, str(self.risk_path))
        self.assertTrue(risk.is_risk(42))

    def test_a_different_caller_is_not_answered_from_the_cache(self):
        self.write_policy()
        self.write_risk(generated_at=time.time(),
                        users=[{"user_id": 42, "tier": "T1", "class": "credits_not_approved"}])
        policy, _ = risk_reader.load_policy(str(self.policy_path))
        risk_reader.reset_cache()
        self.assertTrue(risk_reader.default(policy=policy, path=str(self.risk_path)).applies())
        absent = self.dir / "absent.json"
        other = risk_reader.default(policy=dict(policy), path=str(absent))
        self.assertFalse(other.applies())
        self.assertIn("missing", other.why)

    def test_the_alert_reads_the_risk_file_its_policy_names(self):
        """cancel_alert's own path: a risk-only hit joins from the file, not the store."""
        self.write_policy()
        self.write_risk(generated_at=time.time(),
                        users=[{"user_id": 7, "tier": "T1", "class": "credits_not_approved",
                                "kind": ["customer_last"], "lane": "credit-review",
                                "age_days": 3.0, "mrr_list": 12.5, "renew_in_days": 2.0}])
        st = self.store()
        st.start_run("r1", "churned")
        st.finish_run("r1", users=1, errors=0, tiers={}, note="")
        st.put_user(self.put(user_id=7, mode="churned", tier="", kinds=[], evidence=[],
                             churned_at=iso(NOW - 66 * 3600)))
        st.close()
        src = FakeSources(cancels=[{"user_id": 7, "cancelled_at": iso(NOW - 60),
                                    "reason": "cancellation_requested", "plan": "muso_individual_pro_monthly",
                                    "service": "stripe"}])
        doc = cancel_alert.collect(policy=self.policy, now=NOW, sources=src,
                                   store=Store(str(self.store_path), readonly=True))
        self.assertTrue(doc["risk_applies"], doc["risk_why"])
        self.assertEqual([a["user_id"] for a in doc["alerts"]], [7])
        self.assertEqual(doc["alerts"][0]["issue_source"], "risk.json")


# ─── the Intercom row -> thread shape ───────────────────────────────────────
class IntercomThreadShape(unittest.TestCase):
    """The 2026-11-04 canary crash: `--churned-since 60d` on node-8 died with
    UnboundLocalError in thread_from_row because the no-GET branch built `events`
    but never bound `last`. Every row without a full GET hit it, so the store could
    never be built from search rows alone. Pinned here so it cannot come back."""

    def row(self, **kw):
        base = {"id": "c1", "created_at": 1000.0, "updated_at": 2000.0, "state": "open",
                "source": {"type": "user", "subject": "help", "body": "<p>my credits are missing</p>",
                           "created_at": 1000.0},
                "contacts": {"type": "contact.list", "contacts": [{"id": "p1", "external_id": "ext-1"}]},
                "statistics": {"last_contact_reply_at": 3000.0, "last_admin_reply_at": 2500.0},
                "waiting_since": None, "conversation_rating": None}
        base.update(kw)
        return base

    def test_no_get_builds_a_synthetic_last_event_without_raising(self):
        th = intercom.thread_from_row(self.row())
        self.assertEqual(th["last_who"], "contact")
        self.assertEqual(th["last_at"], 3000.0)
        self.assertEqual([e["at"] for e in th["events"]], sorted(e["at"] for e in th["events"]))
        self.assertEqual(th["events"][0]["who"], "contact")
        self.assertEqual(th["events"][0]["body"], "my credits are missing")   # html stripped
        self.assertEqual(th["external_ids"], ["ext-1"])

    def test_admin_last_is_us(self):
        th = intercom.thread_from_row(self.row(statistics={"last_contact_reply_at": 2000.0,
                                                          "last_admin_reply_at": 4000.0}))
        self.assertEqual(th["last_who"], "us")

    def test_waiting_since_beats_the_statistics_when_it_is_later(self):
        th = intercom.thread_from_row(self.row(waiting_since=5000.0))
        self.assertEqual((th["last_who"], th["last_at"]), ("contact", 5000.0))

    def test_the_stage_reads_the_synthetic_thread(self):
        t = stages.Thresholds()
        now = 3000.0 + 3 * DAY
        th = intercom.thread_from_row(self.row())
        issues = stages.classify_thread(th["events"], now, "c1", True, th["created_at"], t)
        self.assertEqual([i.kind for i in issues], [stages.KIND_NO_REPLY])

    def test_a_get_with_no_parts_falls_back_to_the_row(self):
        th = intercom.thread_from_row(self.row(), full={"events": []})
        self.assertEqual(th["last_who"], "contact")
        self.assertEqual(th["last_at"], 2000.0)

    def test_events_are_ordered_even_when_a_get_returns_them_unsorted(self):
        th = intercom.thread_from_row(self.row(), full={"events": [
            {"at": 5000.0, "who": "contact", "body": "later"},
            {"at": 1000.0, "who": "us", "body": "earlier"}]})
        self.assertEqual([e["at"] for e in th["events"]], [1000.0, 5000.0])
        self.assertEqual(th["last_who"], "contact")


# ─── the source readers ─────────────────────────────────────────────────────
class SourcesReaders(PolicyFixture):
    def ledger(self, rows) -> Path:
        path = self.dir / "ledger.sqlite3"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE IF NOT EXISTS verify_messages (account_id TEXT, user_key TEXT, campaign TEXT,"
                       " kind TEXT, created_at TEXT, contact_id TEXT, conversation_id TEXT, status TEXT)")
            db.executemany("INSERT INTO verify_messages VALUES (?,?,?,?,?,?,?,?)", rows)
        return path

    def sources(self, ledger: Path, proof: Path | None = None) -> src_mod.Sources:
        return src_mod.Sources(ledger=str(ledger), proof=str(proof or self.dir / "proof.sqlite"))

    def test_only_a_sent_note_counts_as_one_the_customer_saw(self):
        ledger = self.ledger([
            ("7", "a@x", "verify-live", "initial", "2026-01-01", "ct", "cv", "sent"),
            ("7", "a@x", "verify-live", "reminder-14", "2026-01-02", "ct", "cv", "attempted"),
            ("7", "a@x", "verify-live", "reminder-25", "2026-01-03", "ct", "cv", ""),
            ("8", "b@x", "verify-live", "initial", "2026-01-04", "ct", "cv", "deferred")])
        tells = self.sources(ledger).tells()
        self.assertEqual([r["kind"] for r in tells["7"]], ["initial"])
        self.assertNotIn("8", tells)

    def test_the_ledger_is_read_once_per_sources_instance(self):
        ledger = self.ledger([("7", "a@x", "verify-live", "initial", "2026-01-01", "ct", "cv", "sent")])
        src = self.sources(ledger)
        first = src.tells()
        with sqlite3.connect(ledger) as db:
            db.execute("INSERT INTO verify_messages VALUES ('9','c@x','verify-live','initial',"
                       "'2026-01-05','ct','cv','sent')")
        self.assertEqual(src.tells(), first)
        self.assertIn("9", self.sources(ledger).tells())

    def test_the_proof_store_is_read_once_per_sources_instance(self):
        proof = self.dir / "proof.sqlite"
        with sqlite3.connect(proof) as db:
            db.execute("CREATE TABLE proof_intake (user_id INTEGER, received_at TEXT, source TEXT,"
                       " subject TEXT)")
            db.execute("INSERT INTO proof_intake VALUES (7,'2026-01-01','email','doc')")
        src = self.sources(self.ledger([]), proof)
        first = src.proof_intake()
        with sqlite3.connect(proof) as db:
            db.execute("INSERT INTO proof_intake VALUES (8,'2026-01-02','email','doc')")
        self.assertEqual(src.proof_intake(), first)
        self.assertIn("8", self.sources(self.ledger([]), proof).proof_intake())


class ClickupIntakeRead(PolicyFixture):
    """The intake walk must survive the real list, and a capped walk is a FAILED read.

    The list is ~14,100 tasks / ~141 pages and is ordered newest-first, so a cap
    below that silently dropped the OLDEST (highest-risk) tickets and reported a
    complete read - which the nightly publisher and the on-demand classifier both
    believed (firstmate 2026-11-04, key nm-review5-clickup-page-cap).
    """

    class Resp:
        def __init__(self, body: bytes):
            self.body = body

        def read(self) -> bytes:
            return self.body

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def walk(self, pages: int, *, page_size: int = 100):
        """A stub ClickUp list of `pages` full pages, terminated by an empty one."""
        state = {"page": 0}

        def urlopen(req, timeout=60):
            page = state["page"]
            state["page"] += 1
            tasks = ([{"id": f"t{page}-{i}", "name": "credits missing"}
                      for i in range(page_size)] if page < pages else [])
            return self.Resp(json.dumps({"tasks": tasks}).encode())
        return urlopen

    def test_the_real_sized_list_is_read_to_the_end(self):
        # 141 full pages is the measured board; anything under it truncates for real
        src = src_mod.Sources(clickup_key="k", sleep=lambda s: None)
        with mock.patch.object(src_mod.urllib.request, "urlopen", self.walk(141)):
            tasks = src.clickup_tasks()
        self.assertEqual(len(tasks), 14_100)
        self.assertEqual(src.errors, [])
        self.assertEqual(tasks[-1]["id"], "t140-99")

    def test_a_capped_walk_raises_instead_of_returning_a_partial_set(self):
        src = src_mod.Sources(clickup_key="k", sleep=lambda s: None)
        with mock.patch.object(src_mod.urllib.request, "urlopen", self.walk(5)), \
                mock.patch.object(src_mod, "CLICKUP_MAX_PAGES", 3):
            with self.assertRaises(src_mod.SourceError) as caught:
                src.clickup_tasks()
        self.assertIn("cap", str(caught.exception))
        # and the on-demand path cannot record that walk as "read"
        with mock.patch.object(src_mod.urllib.request, "urlopen", self.walk(5)), \
                mock.patch.object(src_mod, "CLICKUP_MAX_PAGES", 3):
            tick = cancel_alert.read_tick_tasks(src)
        self.assertFalse(tick["ok"])
        self.assertIn("cap", tick["why"])


class FakeSweepSources:
    """The minimum `sweep()` reads, so a limited run can be exercised end to end."""

    def __init__(self):
        self.errors: list[str] = []

    def cancelled_since(self, since_ts):
        return []

    def users(self, ids):
        return {str(u): {"user_id": int(u), "email": f"u{u}@x", "auth0": "", "profile": ""}
                for u in ids}

    def subscriptions(self, ids):
        return {}

    def open_credit_requests(self, ids):
        return {}

    def pending_claims(self, ids):
        return {}

    def tells(self):
        return {}

    def proof_intake(self):
        return {}


class SweepLimit(PolicyFixture):
    def test_a_limited_canary_run_cannot_satisfy_the_publisher_guards(self):
        # a canary looked at a slice of the paying set: risk.py must still see "the
        # paying sweep has never finished" rather than publish over the slice
        self.put(user_id=1)
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            support_state.sweep(mode="paying", store=st, sources=FakeSweepSources(), ic=None,
                                t=t, now=time.time(), policy=self.policy, ids=[1],
                                no_clickup=True, limit=1)
            support_state.sweep(mode="churned", store=st, sources=FakeSweepSources(), ic=None,
                                t=t, now=time.time(), policy=self.policy, ids=[1],
                                no_clickup=True, limit=1)
            self.assertIsNone(st.last_run("paying"))
            self.assertIsNone(st.last_run("churned"))
        finally:
            st.close()
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 3)
        self.assertFalse(self.risk_path.exists())

    def test_an_on_demand_user_run_cannot_satisfy_the_publisher_guards(self):
        st = self.store()
        try:
            support_state.sweep_user(uid=1, store=st, sources=FakeSweepSources(), ic=None,
                                     t=stages.Thresholds.from_policy(self.policy),
                                     now=time.time(), policy=self.policy, write=True)
            self.assertIsNone(st.last_run("paying"))
            self.assertIsNone(st.last_run("churned"))
            self.assertIsNotNone(st.last_run("churned-user"))
        finally:
            st.close()
        self.assertEqual(risk_mod.main(["--policy", str(self.policy_path), "--json"]), 3)

    def test_a_limited_churned_sweep_only_reads_the_limit(self):
        # --limit is the canary knob: it used to apply to the paying set only, so a canary
        # paid for a full churned sweep and then filed a run nobody reads
        class Churned(FakeSweepSources):
            def __init__(self):
                super().__init__()
                self.sub_calls: list[list[int]] = []

            def cancelled_since(self, since_ts):
                return [{"user_id": u, "cancelled_at": iso(NOW - 3 * DAY)} for u in (1, 2, 3)]

            def subscriptions(self, ids):
                self.sub_calls.append(list(ids))
                return {}

        t = stages.Thresholds.from_policy(self.policy)
        src = Churned()
        st = self.store()
        try:
            out = support_state.sweep(mode="churned", store=st, sources=src, ic=None,
                                      t=t, now=NOW, policy=self.policy, window_s=60 * DAY,
                                      no_clickup=True, limit=1)
            self.assertEqual(out["users"], 1)
            # the replica lookups are bounded too, before the per-user ones start
            self.assertTrue(src.sub_calls)
            for ids in src.sub_calls:
                self.assertLessEqual(len(ids), 1)
            self.assertIsNone(st.last_run("churned"))
            self.assertIsNotNone(st.last_run("churned-canary"))
        finally:
            st.close()

    def test_a_limited_canary_sweep_keeps_the_rows_it_did_not_look_at(self):
        self.put(user_id=1)
        self.put(user_id=2)
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            support_state.sweep(mode="paying", store=st, sources=FakeSweepSources(), ic=None,
                                t=t, now=NOW, policy=self.policy, ids=[1],
                                no_clickup=True, limit=1)
            self.assertEqual(sorted(r["user_id"] for r in st.users(mode="paying")), [1, 2])
            support_state.sweep(mode="paying", store=st, sources=FakeSweepSources(), ic=None,
                                t=t, now=NOW, policy=self.policy, ids=[1], no_clickup=True)
            self.assertEqual([r["user_id"] for r in st.users(mode="paying")], [1])
        finally:
            st.close()


class FakeIntercom:
    def __init__(self, rows, fulls=None):
        self.rows = list(rows)
        self.fulls = dict(fulls or {})
        self.errors: list[str] = []
        self.gets = 0

    def search_conversations(self, since):
        return iter(self.rows)

    def conversations(self, ids):
        self.gets += 1
        return {i: self.fulls[i] for i in ids if i in self.fulls}


class ReadConversationsColdReuse(PolicyFixture):
    def test_a_search_only_row_gets_its_get_once_it_qualifies(self):
        # a row stored without a GET is re-evaluated: at 30h of customer wait it is a
        # risk thread, and skipping the GET forever left its last_body empty
        row = {"id": "c1", "created_at": NOW - 10 * DAY, "updated_at": NOW, "state": "open",
               "statistics": {"last_contact_reply_at": NOW - 30 * 3600},
               "contacts": {"contacts": [{"external_id": "ext1"}]},
               "source": {"created_at": NOW - 10 * DAY, "body": "Hi"}}
        full = {"events": [{"at": NOW - 10 * DAY, "who": "contact", "body": "Hi"},
                           {"at": NOW - 30 * 3600, "who": "contact",
                            "body": "my credits are still missing"}]}
        ic = FakeIntercom([row], {"c1": full})
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            st.put_conv({"conv_id": "c1", "updated_at": NOW, "created_at": NOW - 10 * DAY,
                         "state": "open", "last_at": NOW - 30 * 3600, "last_who": "contact",
                         "opening_body": "Hi", "last_body": "", "our_last_body": "",
                         "external_ids": ["ext1"], "read_full": 0})
            support_state.read_conversations(store=st, ic=ic, since=NOW - 120 * DAY,
                                             id_map={"ext1": 7}, uids={7}, t=t, now=NOW)
            conv = st.convs()["c1"]
        finally:
            st.close()
        self.assertEqual(ic.gets, 1)
        self.assertEqual(conv["read_full"], 1)
        self.assertIn("credits are still missing", conv["last_body"])

    def test_a_search_only_row_inside_the_threshold_is_not_read(self):
        row = {"id": "c2", "created_at": NOW - 10 * DAY, "updated_at": NOW, "state": "open",
               "statistics": {"last_contact_reply_at": NOW - 2 * 3600},
               "contacts": {"contacts": [{"external_id": "ext1"}]},
               "source": {"created_at": NOW - 10 * DAY, "body": "Hi"}}
        ic = FakeIntercom([row])
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            st.put_conv({"conv_id": "c2", "updated_at": NOW, "created_at": NOW - 10 * DAY,
                         "state": "open", "last_at": NOW - 2 * 3600, "last_who": "contact",
                         "opening_body": "Hi", "last_body": "", "our_last_body": "",
                         "external_ids": ["ext1"], "read_full": 0})
            support_state.read_conversations(store=st, ic=ic, since=NOW - 120 * DAY,
                                             id_map={"ext1": 7}, uids={7}, t=t, now=NOW)
        finally:
            st.close()
        self.assertEqual(ic.gets, 0)


class FakeContactIntercom:
    """The contact-scoped path sweep_user takes: one contact, no window enumeration."""

    def __init__(self, rows, fulls=None, kind=None):
        self.rows = list(rows)
        self.fulls = dict(fulls or {})
        self.kind = kind or (ic_mod.FOUND if self.rows else ic_mod.NONE)
        self.errors: list[str] = []
        self.contact_calls = 0
        self.enumerations = 0
        self.gets: list[str] = []

    def search_by_contact(self, external_id=None, email=None):
        if not (external_id or email):
            return ic_mod.ContactThreads(ic_mod.NO_IDENTITY)   # no lookup was made
        self.contact_calls += 1
        return ic_mod.ContactThreads(self.kind, self.rows)

    def conversations(self, ids):
        self.gets.extend(ids)
        return {i: self.fulls[i] for i in ids if i in self.fulls}

    def search_conversations(self, since, max_pages=500, progress=None):
        self.enumerations += 1
        return iter(())


class FakeCancelSweepSources:
    """Both halves of the on-demand path: the event read and the one-user join."""

    def __init__(self, cancels=()):
        self.cancels = list(cancels)
        self.errors: list[str] = []

    def cancelled_since(self, since_ts):
        return [c for c in self.cancels
                if stages.iso_to_ts(c.get("cancelled_at")) >= since_ts]

    def cancel_requests(self):
        return []

    def users(self, ids):
        return {str(u): {"user_id": int(u), "email": f"u{u}@x", "auth0": "", "profile": ""}
                for u in ids}

    def subscriptions(self, ids):
        return {}

    def open_credit_requests(self, ids):
        return {}

    def pending_claims(self, ids):
        return {}

    def tells(self):
        return {}

    def proof_intake(self):
        return {}


class OnDemandIntercomFailure(PolicyFixture):
    """An Intercom outage left the canceller looking like a clean answer.

    intercom.py records transport failures on the client and returns nothing, and
    sweep_user never read them, so a token-less or 500-ing read classified as 'no
    open issue' and the wrapper committed the watermark past a real cancel page.
    """

    def failing_ic(self) -> FakeContactIntercom:
        ic = FakeContactIntercom([])
        ic.errors.append("contact search email=u99@x: HTTP 500")
        return ic

    def test_classify_on_demand_raises_when_intercom_read_nothing(self):
        with self.assertRaises(cancel_alert.ClassifyFailed) as caught:
            cancel_alert.classify_on_demand(99, self.policy,
                                            stages.Thresholds.from_policy(self.policy),
                                            sources=FakeSweepSources(), ic=self.failing_ic())
        self.assertIn("Intercom", str(caught.exception))

    def test_an_unreadable_intercom_holds_the_watermark(self):
        (self.dir / "cancel-alert.watermark").write_text(iso(NOW - 3600) + "\n")
        src = FakeCancelSweepSources(cancels=[{"user_id": 99,
                                               "cancelled_at": iso(NOW - 600)}])
        st = self.store(write=False)
        try:
            with mock.patch.object(intercom, "Intercom", return_value=self.failing_ic()):
                doc = cancel_alert.collect(policy=self.policy, now=NOW, on_demand=True,
                                           sources=src, store=st)
        finally:
            st.close()
        self.assertEqual(doc["alerts"], [])
        self.assertEqual([u["user_id"] for u in doc["unclassified"]], [99])
        self.assertEqual([s for s in doc["skipped"] if s["user_id"] == 99], [])
        cancel_alert.commit(cancel_alert.store_paths(self.policy), doc)
        wm = cancel_alert.read_watermark(str(self.dir / "cancel-alert.watermark"), NOW)
        self.assertEqual(wm, NOW - 600)


class OnDemandClickupTickets(PolicyFixture):
    """A canceller whose ONLY open support state is a ClickUp intake ticket.

    ClickUp carries ~134 of the measured churned-with-issue users, so the on-demand
    path (the only one that can classify a canceller the nightly sweep has not seen)
    used to hardcode `"tasks": []` and answer "no open issue" for exactly that class,
    after which the wrapper committed the watermark past the page.
    firstmate 2026-11-04 (key nm-review5-clickup-on-demand) ruled: read the list ONCE
    per tick, share it across cancellers, and never let a failed read render as a
    clean answer.
    """

    def task(self, *, email: str = "u99@x", days: float = 5.0) -> dict:
        created_ms = int((NOW - days * DAY) * 1000)
        return {"id": "t-1", "name": "credits not appearing", "status": "in progress",
                "created": created_ms, "updated": created_ms, "closed": None,
                "text": "credits not appearing on the release page",
                "fields": {"User Email": email}, "url": "https://app.clickup.com/t/t-1"}

    def sources(self, tasks) -> "object":
        class Sources(FakeCancelSweepSources):
            reads = 0

            def clickup_tasks(inner):
                Sources.reads += 1
                if tasks is None:
                    raise src_mod.SourceError("ClickUp list 901000600160 page 0: HTTP 500")
                return list(tasks)
        return Sources(cancels=[{"user_id": 99, "cancelled_at": iso(NOW - 600)}])

    def test_a_clickup_only_ticket_pages_the_canceller(self):
        st = self.store(write=False)
        try:
            with mock.patch.object(intercom, "Intercom", return_value=FakeContactIntercom([])):
                doc = cancel_alert.collect(policy=self.policy, now=NOW, on_demand=True,
                                           sources=self.sources([self.task()]), store=st)
        finally:
            st.close()
        self.assertEqual([a["user_id"] for a in doc["alerts"]], [99])
        self.assertEqual(doc["alerts"][0]["kinds"], ["request_pending"])
        self.assertEqual(doc["alerts"][0]["class"], "credits_not_approved")
        self.assertIn("clickup task t-1", json.dumps(doc["alerts"][0]["evidence"]))

    def test_the_list_is_read_once_for_every_canceller_in_the_tick(self):
        # 25 cancellers per tick is the documented worst case; one walk, not 25
        src = self.sources([self.task()])
        st = self.store(write=False)
        try:
            with mock.patch.object(intercom, "Intercom", return_value=FakeContactIntercom([])):
                cancel_alert.collect(policy=self.policy, now=NOW, on_demand=True,
                                     sources=src, store=st)
                one = src.reads
                src2 = self.sources([self.task()])
                src2.cancels = [{"user_id": u, "cancelled_at": iso(NOW - 600)}
                                for u in range(90, 96)]
                cancel_alert.collect(policy=self.policy, now=NOW, on_demand=True,
                                     sources=src2, store=st)
        finally:
            st.close()
        self.assertEqual(one, 1)
        self.assertEqual(src2.reads, 1, "six cancellers must share one ClickUp walk")

    def test_the_event_plan_prices_the_on_demand_alert(self):
        # a canceller has no live subscription row left, so pricing from the live
        # lookup fell through to the $12.50 default and a $49 Business save sorted
        # below every $12.50 one (firstmate 2026-11-04, key nm-review5-churn-mrr)
        src = self.sources([self.task()])
        src.cancels = [{"user_id": 99, "plan": "muso_team_business_graduated_monthly",
                        "cancelled_at": iso(NOW - 600)}]
        st = self.store(write=False)
        try:
            with mock.patch.object(intercom, "Intercom", return_value=FakeContactIntercom([])):
                doc = cancel_alert.collect(policy=self.policy, now=NOW, on_demand=True,
                                           sources=src, store=st)
        finally:
            st.close()
        self.assertEqual(doc["alerts"][0]["plan"], "muso_team_business_graduated_monthly")
        self.assertEqual(doc["alerts"][0]["mrr_list"], 49.0)
        self.assertIn("$49.00", doc["alerts"][0]["text"])

    def test_a_failed_clickup_read_is_not_a_clean_no_open_issue(self):
        st = self.store(write=False)
        try:
            with mock.patch.object(intercom, "Intercom", return_value=FakeContactIntercom([])):
                doc = cancel_alert.collect(policy=self.policy, now=NOW, on_demand=True,
                                           sources=self.sources(None), store=st)
        finally:
            st.close()
        self.assertEqual(doc["alerts"], [])
        self.assertEqual([u["user_id"] for u in doc["unclassified"]], [99])
        self.assertIn("ClickUp", doc["unclassified"][0]["why"])
        self.assertNotIn("no open issue",
                         [u.get("why") for u in doc["skipped"]])

    def test_an_explicit_no_clickup_run_says_so_on_the_row(self):
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            row = support_state.sweep_user(uid=99, store=st, sources=FakeSweepSources(),
                                           ic=None, t=t, now=NOW, policy=self.policy,
                                           tick_tasks=None)
        finally:
            st.close()
        self.assertEqual(row["clickup"], "not-read")
        self.assertEqual(row["tasks"] if "tasks" in row else [], [])

    def test_a_walk_that_saw_many_rows_on_few_pages_logs_no_cap(self):
        # the cap message is what an operator uses to tell a papered-over broken
        # lookup from a real read; counting ROWS once made any walk with 8 or more
        # conversations report a cap that never happened (firstmate 2026-11-04,
        # key nm-review5-fallback-page-count)
        class Busy(FakeContactIntercom):
            def search_conversations(self, since, max_pages=500, progress=None):
                self.enumerations += 1
                for page in range(2):
                    if progress is not None:
                        progress["pages"] = page + 1
                    for _ in range(10):
                        yield self.rows[0] if self.rows else {}
        ic = Busy([{"id": "c1", "created_at": NOW - DAY, "updated_at": NOW - DAY,
                    "source": {"type": "user", "created_at": NOW - DAY, "body": "<p>x</p>"},
                    "contacts": {"contacts": []}, "statistics": {}}], kind=ic_mod.ERROR)
        support_state._window_fallback(ic=ic, ident={"email": "u@x"}, since=NOW - DAY)
        self.assertEqual(ic.errors, [])

    def test_the_cap_message_counts_pages_not_rows(self):
        class SilentCap(FakeContactIntercom):
            """Stops at the page bound WITHOUT recording its own message."""

            def search_conversations(self, since, max_pages=500, progress=None):
                for page in range(max_pages):
                    if progress is not None:
                        progress["pages"] = page + 1
                    yield {"id": f"c{page}", "created_at": NOW - DAY,
                           "updated_at": NOW - DAY,
                           "source": {"type": "user", "created_at": NOW - DAY, "body": ""},
                           "contacts": {"contacts": []}, "statistics": {}}
        ic = SilentCap([], kind=ic_mod.ERROR)
        with mock.patch.object(support_state, "FALLBACK_MAX_PAGES", 2):
            support_state._window_fallback(ic=ic, ident={"email": "u@x"}, since=NOW - DAY)
        self.assertEqual(ic.errors, ["window fallback stopped on the page cap (2 pages)"])

    def test_the_generators_own_cap_line_is_not_duplicated(self):
        class LoudCap(FakeContactIntercom):
            def search_conversations(self, since, max_pages=500, progress=None):
                for page in range(max_pages):
                    if progress is not None:
                        progress["pages"] = page + 1
                    yield {"id": f"c{page}", "created_at": NOW - DAY,
                           "updated_at": NOW - DAY,
                           "source": {"type": "user", "created_at": NOW - DAY, "body": ""},
                           "contacts": {"contacts": []}, "statistics": {}}
                self.errors.append(f"conversation search stopped at {max_pages} pages (2 rows)")
        ic = LoudCap([], kind=ic_mod.ERROR)
        with mock.patch.object(support_state, "FALLBACK_MAX_PAGES", 2):
            support_state._window_fallback(ic=ic, ident={"email": "u@x"}, since=NOW - DAY)
        self.assertEqual(len([e for e in ic.errors if "page" in e]), 1, "one cap, one line")


class OnDemandUser(PolicyFixture):
    """sweep_user hands the stage a thread shape, not a store shape.

    The contact-first branch used to wrap thread_from_row's stage thread in
    thread_facts(), which reads the STORE columns (opening_body/last_body/...).
    Every body came back empty, so the cause class fell to 'other' and the alert
    routed the canceller to the wrong lane while still paging.
    """

    def row(self, *, opening: float, last_contact: float = 0.0, last_admin: float = 0.0) -> dict:
        return {"id": "c1", "created_at": opening, "updated_at": max(last_contact, last_admin),
                "state": "open",
                "source": {"type": "user", "created_at": opening,
                           "body": "<p>hi, my credits are still missing</p>"},
                "contacts": {"type": "contact.list", "contacts": [{"external_id": "ext-1"}]},
                "statistics": {"last_contact_reply_at": last_contact,
                               "last_admin_reply_at": last_admin},
                "waiting_since": None}

    def classify(self, rows, fulls):
        ic = FakeContactIntercom(rows, fulls)
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            out = support_state.sweep_user(uid=1, store=st, sources=FakeSweepSources(), ic=ic,
                                           t=t, now=NOW, policy=self.policy)
        finally:
            st.close()
        self.assertEqual(ic.contact_calls, 1)
        self.assertEqual(ic.enumerations, 0)
        return out

    def test_a_quiet_canceller_costs_no_fleet_enumeration(self):
        # the contact search answered "no conversations": the old fallback walked the
        # whole 120-day fleet (~90 search pages) to find nothing, per canceller
        out = self.classify([], {})
        self.assertEqual(out["intercom_conv_ids"], [])
        self.assertIsNone(out["tier"])
        self.assertEqual(out["intercom"], {"threads": 0, "contact": ic_mod.NONE, "errors": []})

    # -- the five contact outcomes (firstmate ruling 2026-11-04) ------------
    def run_with(self, kind, *, identity=True, rows=None, errors=None):
        """sweep_user with one typed contact outcome; returns (row, client)."""
        class Sources(FakeSweepSources):
            def users(self, ids):
                return {str(u): {"user_id": int(u), "email": "u1@x" if identity else "",
                                 "auth0": "", "profile": ""} for u in ids}

        ic = FakeContactIntercom(rows or [], kind=kind)
        ic.errors.extend(errors or [])
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            out = support_state.sweep_user(uid=1, store=st, sources=Sources(), ic=ic,
                                           t=t, now=NOW, policy=self.policy)
        finally:
            st.close()
        return out, ic

    def test_no_identity_classifies_without_asking_or_enumerating(self):
        out, ic = self.run_with(ic_mod.NO_IDENTITY, identity=False)
        self.assertEqual(ic.contact_calls, 0)
        self.assertEqual(ic.enumerations, 0)
        self.assertEqual(out["intercom"]["contact"], ic_mod.NO_IDENTITY)
        self.assertEqual(out["intercom"]["errors"], [])

    def test_not_found_classifies_without_enumerating(self):
        out, ic = self.run_with(ic_mod.NOT_FOUND)
        self.assertEqual(ic.contact_calls, 1)
        self.assertEqual(ic.enumerations, 0)
        self.assertEqual(out["intercom"]["contact"], ic_mod.NOT_FOUND)

    def test_a_contact_with_no_conversations_classifies_without_enumerating(self):
        out, ic = self.run_with(ic_mod.NONE)
        self.assertEqual(ic.enumerations, 0)
        self.assertEqual(out["intercom"]["contact"], ic_mod.NONE)
        self.assertIsNone(out["tier"])

    def test_found_reads_only_the_contacts_own_threads(self):
        row = self.row(opening=NOW - 10 * DAY, last_contact=NOW - 7 * DAY)
        full = {"events": [
            {"at": NOW - 10 * DAY, "who": "contact", "body": "Hi"},
            {"at": NOW - 7 * DAY, "who": "contact", "body": "my credits are still missing"}]}
        out, ic = self.run_with(ic_mod.FOUND, rows=[row])
        self.assertEqual(ic.enumerations, 0)
        self.assertEqual(out["intercom"]["contact"], ic_mod.FOUND)
        self.assertEqual(out["cause_class"], "credits_not_approved")

    def test_error_is_the_only_kind_that_walks_the_window_and_it_is_bounded(self):
        class Enumerating(FakeContactIntercom):
            def search_conversations(self, since, max_pages=500, progress=None):
                self.enumerations += 1
                self.page_cap = max_pages
                return iter(())

        ic = Enumerating([], kind=ic_mod.ERROR)
        ic.errors.append("contact search email=u1@x: HTTP 500")
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            out = support_state.sweep_user(uid=1, store=st, sources=FakeSweepSources(), ic=ic,
                                           t=t, now=NOW, policy=self.policy)
        finally:
            st.close()
        self.assertEqual(ic.enumerations, 1)
        self.assertEqual(ic.page_cap, support_state.FALLBACK_MAX_PAGES)
        self.assertEqual(out["intercom"]["contact"], ic_mod.ERROR)
        # the failure is still on the record: a bounded walk does not launder it
        self.assertTrue(any("HTTP 500" in e for e in out["intercom"]["errors"]))

    def test_a_thread_on_a_duplicate_contact_comes_from_the_store(self):
        class Sources(FakeSweepSources):
            def users(self, ids):
                return {str(u): {"user_id": int(u), "email": f"u{u}@x",
                                 "auth0": "ext-1", "profile": ""} for u in ids}

        st = self.store()
        try:
            st.put_conv({"conv_id": "c9", "updated_at": NOW - 7 * DAY,
                         "created_at": NOW - 12 * DAY, "state": "open",
                         "last_at": NOW - 7 * DAY, "last_who": "contact", "admin_at": 0,
                         "opening_body": "Hi", "last_body": "my credits are still missing",
                         "our_last_body": "", "external_ids": ["ext-1"], "read_full": 1})
        finally:
            st.close()
        ic = FakeContactIntercom([], {"c9": {"events": [
            {"at": NOW - 12 * DAY, "who": "contact", "body": "Hi"},
            {"at": NOW - 7 * DAY, "who": "contact",
             "body": "my credits are still missing"}]}})
        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            out = support_state.sweep_user(uid=1, store=st, sources=Sources(), ic=ic,
                                           t=t, now=NOW, policy=self.policy)
        finally:
            st.close()
        self.assertEqual(ic.enumerations, 0)
        self.assertEqual(ic.gets, ["c9"])
        self.assertEqual(out["cause_class"], "credits_not_approved")
        self.assertEqual(out["tier"], "T1")
        self.assertEqual(out["intercom_conv_ids"], ["c9"])

    def test_a_customer_last_thread_keeps_its_bodies(self):
        row = self.row(opening=NOW - 10 * DAY, last_contact=NOW - 7 * DAY)
        full = {"events": [
            {"at": NOW - 10 * DAY, "who": "contact", "body": "Hi"},
            {"at": NOW - 7 * DAY, "who": "contact", "body": "my credits are still missing"}]}
        out = self.classify([row], {"c1": full})
        self.assertEqual(out["cause_class"], "credits_not_approved")
        self.assertEqual(out["tier"], "T1")
        self.assertEqual(out["kinds"], ["customer_last"])
        self.assertEqual(out["intercom_conv_ids"], ["c1"])

    def test_an_open_held_thread_keeps_the_promise_signal(self):
        row = self.row(opening=NOW - 10 * DAY, last_admin=NOW - 6 * DAY)
        full = {"events": [
            {"at": NOW - 10 * DAY, "who": "contact", "body": "my credits are still missing"},
            {"at": NOW - 6 * DAY, "who": "us",
             "body": "we'll look into this and get back to you"}]}
        out = self.classify([row], {"c1": full})
        self.assertEqual(out["tier"], "T2")
        self.assertEqual(out["kinds"], ["told_to_wait"])
        self.assertEqual(out["cause_class"], "credits_not_approved")
        self.assertEqual(out["intercom_conv_ids"], ["c1"])
        self.assertIn("promise", str(out["evidence"]))
        lane = risk_mod.lanes(self.policy)[out["cause_class"]]
        self.assertEqual(lane, "credit-review")


class IdentityKeyedIntercom(FakeContactIntercom):
    """Intercom keys a contact by ONE identity; every other identity answers NOT_FOUND."""

    def __init__(self, key, rows, fulls=None):
        super().__init__(rows, fulls)
        self.key = key
        self.asked: list[tuple[str, str]] = []

    def search_by_contact(self, external_id=None, email=None):
        field, value = ("external_id", external_id) if external_id else ("email", email)
        self.asked.append((field, value))
        if value != self.key:
            return ic_mod.ContactThreads(ic_mod.NOT_FOUND)
        return ic_mod.ContactThreads(ic_mod.FOUND if self.rows else ic_mod.NONE, self.rows)


class SplitContactIntercom(FakeContactIntercom):
    """One person, several Intercom contacts: `by_value` maps an identity to its rows.

    A missing key is NOT_FOUND (no contact under that identity); an empty list is NONE
    (the contact exists and has no conversations).
    """

    def __init__(self, by_value, fulls=None):
        super().__init__([], fulls)
        self.by_value = by_value
        self.asked: list[tuple[str, str]] = []

    def search_by_contact(self, external_id=None, email=None):
        field, value = ("external_id", external_id) if external_id else ("email", email)
        self.asked.append((field, value))
        rows = self.by_value.get(value)
        if rows is None:
            return ic_mod.ContactThreads(ic_mod.NOT_FOUND)
        return ic_mod.ContactThreads(ic_mod.FOUND if rows else ic_mod.NONE, rows)


class OnDemandContactIdentities(PolicyFixture):
    """A contact keyed by profile id or email, not the auth0 subject we ask first.

    The on-demand path is the only one that can classify a canceller the nightly
    sweep has not seen, and it used to ask exactly ONE identity (auth0 or profile,
    email only when neither existed). A NOT_FOUND there was read as "no open
    issue", so the wrapper committed the watermark past a payer with an unanswered
    thread and never paged.
    """

    def row(self) -> dict:
        return {"id": "c1", "created_at": NOW - 10 * DAY, "updated_at": NOW - 7 * DAY,
                "state": "open",
                "source": {"type": "user", "created_at": NOW - 10 * DAY,
                           "body": "<p>hi, my credits are still missing</p>"},
                "contacts": {"type": "contact.list", "contacts": [{"external_id": "12345"}]},
                "statistics": {"last_contact_reply_at": NOW - 7 * DAY,
                               "last_admin_reply_at": 0},
                "waiting_since": None}

    def classify_ic(self, ic):
        class Sources(FakeSweepSources):
            def users(self, ids):
                return {str(u): {"user_id": int(u), "email": "u1@x",
                                 "auth0": "auth0|x", "profile": "12345"} for u in ids}

        t = stages.Thresholds.from_policy(self.policy)
        st = self.store()
        try:
            return support_state.sweep_user(uid=1, store=st, sources=Sources(), ic=ic,
                                            t=t, now=NOW, policy=self.policy)
        finally:
            st.close()

    def classify(self, key: str):
        ic = IdentityKeyedIntercom(key, [self.row()])
        return self.classify_ic(ic), ic

    def test_a_contact_keyed_by_profile_id_is_found_after_the_auth0_miss(self):
        out, ic = self.classify("12345")
        self.assertEqual([v for _, v in ic.asked], ["auth0|x", "12345", "u1@x"])
        self.assertEqual(out["intercom"]["contact"], ic_mod.FOUND)
        self.assertEqual(out["cause_class"], "credits_not_approved")
        self.assertEqual(out["tier"], "T1")

    def test_a_contact_keyed_by_email_is_found_after_both_external_ids_miss(self):
        out, ic = self.classify("u1@x")
        self.assertEqual([v for _, v in ic.asked], ["auth0|x", "12345", "u1@x"])
        self.assertEqual(out["intercom"]["contact"], ic_mod.FOUND)
        self.assertEqual(out["tier"], "T1")

    def test_no_identity_anywhere_still_reports_not_found(self):
        out, ic = self.classify("nobody")
        self.assertEqual(out["intercom"]["contact"], ic_mod.NOT_FOUND)
        self.assertIsNone(out["tier"])

    def test_an_empty_auth0_contact_does_not_hide_the_profile_contacts_thread(self):
        # the auth0 contact exists but never wrote in; the unanswered thread hangs off
        # the profile-keyed contact. Stopping at the first NONE reported "no open issue".
        ic = SplitContactIntercom({"auth0|x": [], "12345": [self.row()]})
        out = self.classify_ic(ic)
        self.assertEqual([v for _, v in ic.asked], ["auth0|x", "12345", "u1@x"])
        self.assertEqual(out["intercom"]["contact"], ic_mod.FOUND)
        self.assertEqual(out["tier"], "T1")

    def test_the_same_conversation_on_two_contacts_is_counted_once(self):
        ic = SplitContactIntercom({"auth0|x": [self.row()], "12345": [self.row()]})
        threads, kind = support_state.user_threads(
            store=self.store(write=False), ic=ic,
            ident={"auth0": "auth0|x", "profile": "12345", "email": "u1@x"})
        self.assertEqual(kind, ic_mod.FOUND)
        self.assertEqual([t["id"] for t in threads], ["c1"])


# ─── the cancel alert ───────────────────────────────────────────────────────
class FakeSources:
    def __init__(self, cancels=(), requests=()):
        self.cancels = list(cancels)
        self.requests = list(requests)
        self.errors: list[str] = []

    def cancelled_since(self, since_ts):
        return [c for c in self.cancels if stages.iso_to_ts(c.get("cancelled_at")) >= since_ts]

    def cancel_requests(self):
        return list(self.requests)

    def clickup_tasks(self):
        return []          # tests that care about tickets override this


class CancelAlert(PolicyFixture):
    def collect(self, sources, *, on_demand=False):
        st = self.store(write=False)
        try:
            return cancel_alert.collect(policy=self.policy, now=NOW, on_demand=on_demand,
                                        sources=sources, store=st)
        finally:
            st.close()

    def test_cancel_with_an_open_issue_pages_with_its_lane(self):
        self.put(user_id=42, cause_class="credits_not_approved", mrr_list=49.0, ball_days=4.0)
        self.write_risk(users=[{"user_id": 42, "class": "credits_not_approved",
                                "lane": "credit-review", "tier": "T1", "mrr_list": 49.0,
                                "age_days": 4.0, "renews_at": iso(NOW + 3 * DAY),
                                "kind": ["customer_last"]}])
        doc = self.collect(FakeSources(cancels=[
            {"user_id": 42, "plan": "muso_team_business_graduated_monthly",
             "cancelled_at": iso(NOW - 3600), "reason": "billing", "feedback": "too expensive",
             "service": "muso"}]))
        self.assertEqual(len(doc["alerts"]), 1)
        a = doc["alerts"][0]
        self.assertEqual(a["lane"], "credit-review")
        self.assertEqual(a["class"], "credits_not_approved")
        self.assertIn("cancelled with an open credits_not_approved issue", a["text"])
        self.assertEqual(a["tag"], "churned:" + datetime.fromtimestamp(NOW, tz=timezone.utc).strftime("%Y-%m-%d"))

    def test_cancel_without_an_open_issue_does_not_page(self):
        self.put(user_id=43, tier=None, kinds=[])
        doc = self.collect(FakeSources(cancels=[
            {"user_id": 43, "cancelled_at": iso(NOW - 3600), "feedback": ""}]))
        self.assertEqual(doc["alerts"], [])
        self.assertIn("no open issue", doc["skipped"][0]["why"])

    def test_poor_survey_is_marked_and_sorted_first(self):
        self.put(user_id=1, mrr_list=12.5)
        self.put(user_id=2, mrr_list=49.0)
        doc = self.collect(FakeSources(cancels=[
            {"user_id": 1, "cancelled_at": iso(NOW - 3600), "feedback": "customer_service"},
            {"user_id": 2, "cancelled_at": iso(NOW - 3600), "feedback": ""}]))
        self.assertEqual([a["user_id"] for a in doc["alerts"]], [1, 2])
        self.assertEqual(doc["alerts"][0]["survey"], "customer_service")
        self.assertIn("survey=customer_service", doc["alerts"][0]["text"])

    def test_dedup_window_is_per_user(self):
        self.put(user_id=1)
        (self.dir / "cancel-alert.sent.json").write_text(json.dumps({"1": iso(NOW - 2 * DAY)}))
        doc = self.collect(FakeSources(cancels=[{"user_id": 1, "cancelled_at": iso(NOW - 3600)}]))
        self.assertEqual(doc["alerts"], [])
        self.assertIn("dedup", doc["skipped"][0]["why"])

    def test_dedup_expires_after_thirty_days(self):
        self.put(user_id=1)
        (self.dir / "cancel-alert.sent.json").write_text(json.dumps({"1": iso(NOW - 40 * DAY)}))
        doc = self.collect(FakeSources(cancels=[{"user_id": 1, "cancelled_at": iso(NOW - 3600)}]))
        self.assertEqual(len(doc["alerts"]), 1)

    def test_scheduled_cancel_pages_too(self):
        self.put(user_id=8, ball_days=5.0)
        doc = self.collect(FakeSources(requests=[
            {"user_id": 8, "plan": "muso_individual_pro_monthly", "expires_at": iso(NOW + 9 * DAY),
             "requested_at": iso(NOW - 3600)}]))
        self.assertEqual(len(doc["alerts"]), 1)
        self.assertEqual(doc["alerts"][0]["event"], "request")
        self.assertIn("cancel scheduled", doc["alerts"][0]["text"])

    def test_a_candidate_that_could_not_be_classified_is_not_a_clean_answer(self):
        # the join raised: recording "no open issue" used to advance the watermark past
        # the cancel, so the page was lost for the whole dedup window and nothing paged
        (self.dir / "cancel-alert.watermark").write_text(iso(NOW - 3600) + "\n")
        with mock.patch.object(cancel_alert, "classify_on_demand",
                              side_effect=cancel_alert.ClassifyFailed("replica blip")):
            doc = self.collect(FakeSources(cancels=[{"user_id": 99,
                                                     "cancelled_at": iso(NOW - 600)}]),
                               on_demand=True)
        self.assertEqual(doc["alerts"], [])
        self.assertEqual([u["user_id"] for u in doc["unclassified"]], [99])
        self.assertEqual([s for s in doc["skipped"] if s["user_id"] == 99], [])
        cancel_alert.commit(cancel_alert.store_paths(self.policy), doc)
        wm = cancel_alert.read_watermark(str(self.dir / "cancel-alert.watermark"), NOW)
        self.assertEqual(wm, NOW - 600)
        # and the next run, with the source healthy again, reads that cancel once more
        again = self.collect(FakeSources(cancels=[{"user_id": 99,
                                                  "cancelled_at": iso(NOW - 600)}]),
                             on_demand=False)
        self.assertEqual([s["user_id"] for s in again["skipped"]], [99])

    def test_a_spent_on_demand_budget_is_not_a_clean_answer(self):
        self.policy["alert"]["on_demand_max"] = 0
        doc = self.collect(FakeSources(cancels=[{"user_id": 99,
                                                 "cancelled_at": iso(NOW - 600)}]),
                           on_demand=True)
        self.assertEqual([u["user_id"] for u in doc["unclassified"]], [99])
        self.assertIn("budget", doc["unclassified"][0]["why"])
        self.assertEqual(doc["skipped"], [])

    def test_commit_writes_intake_sent_and_watermark_then_dedups(self):
        self.put(user_id=1)
        doc = self.collect(FakeSources(cancels=[{"user_id": 1, "cancelled_at": iso(NOW - 3600)}]))
        self.assertEqual(len(doc["alerts"]), 1)
        out = cancel_alert.commit(cancel_alert.store_paths(self.policy), doc)
        self.assertEqual(out["intake_rows"], 1)
        intake = (self.dir / "intake.jsonl").read_text().strip().splitlines()
        row = json.loads(intake[0])
        self.assertEqual(row["user_id"], 1)
        self.assertEqual(row["tag"], doc["alerts"][0]["tag"])
        self.assertTrue((self.dir / "cancel-alert.watermark").exists())
        self.assertEqual(json.loads((self.dir / "cancel-alert.sent.json").read_text())["1"], doc["now"])
        # a second commit of the same run must not duplicate the intake row
        again = cancel_alert.commit(cancel_alert.store_paths(self.policy), doc)
        self.assertEqual(again["intake_rows"], 0)

    def test_watermark_cold_start_does_not_page_a_month_of_history(self):
        wm = cancel_alert.read_watermark(str(self.dir / "nope"), NOW)
        self.assertAlmostEqual(wm, NOW - cancel_alert.COLD_START_HOURS * 3600, places=0)

    def test_text_for_renders_the_policy_template(self):
        text = cancel_alert.text_for(self.policy, {
            "class": "merge_claim_stuck", "age_days": 6.0, "mrr_list": 24.0,
            "lane": "merge-queue", "tier": "T1"}, 7, "cancel", None)
        self.assertIn("user 7, T1", text)
        self.assertIn("route -> merge-queue", text)


# ─── the weekly line ────────────────────────────────────────────────────────
class WeeklyLine(PolicyFixture):
    def test_counts_only_open_issue_rows_inside_the_window(self):
        rows = [
            {"churned_at": iso(NOW - 2 * DAY), "tier": "T1", "mrr_list": 49.0},
            {"churned_at": iso(NOW - 6 * DAY), "tier": "T3", "mrr_list": 12.5},
            {"churned_at": iso(NOW - 3 * DAY), "tier": None, "mrr_list": 12.5},
            {"churned_at": iso(NOW - 10 * DAY), "tier": "T2", "mrr_list": 12.5},
            {"churned_at": None, "tier": "T1", "mrr_list": 12.5},
        ]
        cur = weekly_line.window_counts(rows, NOW - 7 * DAY, NOW)
        prev = weekly_line.window_counts(rows, NOW - 14 * DAY, NOW - 7 * DAY)
        self.assertEqual(cur, {"users": 2, "mrr": 61.5, "tiers": {"T1": 1, "T3": 1}})
        self.assertEqual(prev, {"users": 1, "mrr": 12.5, "tiers": {"T2": 1}})
        line = weekly_line.line_for({"users": cur["users"], "mrr": cur["mrr"],
                                     "tiers": cur["tiers"], "prev_users": prev["users"]},
                                    self.policy["slack"]["weekly_line"])
        self.assertEqual(line, "churned with open support issue: 2 users / $61.50 "
                               "(T1 1 / T2 0 / T3 1) - prev week 1")

    def _churned_run(self, finished_at: str) -> None:
        st = self.store()
        try:
            st.start_run("c1", "churned")
            st.db.execute("UPDATE runs SET finished_at=? WHERE run_id='c1'", (finished_at,))
            st.db.commit()
        finally:
            st.close()

    def _line_doc(self) -> dict:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = weekly_line.main(["--policy", str(self.policy_path), "--json", "--now", str(NOW)])
        self.assertEqual(rc, 0)
        return json.loads(out.getvalue())

    def test_an_old_churned_sweep_warns_instead_of_reporting_an_old_week(self):
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 2 * DAY), tier="T1")
        self._churned_run(iso(NOW - 100 * 3600))
        doc = self._line_doc()
        self.assertEqual(doc["users"], 1)
        self.assertIn("repeats an old week", doc.get("warning") or "")
        self.assertAlmostEqual(doc["churned_sweep_age_hours"], 100.0)

    def test_a_fresh_churned_sweep_has_no_warning(self):
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 2 * DAY), tier="T1")
        self._churned_run(iso(NOW - 3600))
        self.assertIsNone(self._line_doc().get("warning"))

    def _posted_line(self) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = weekly_line.main(["--policy", str(self.policy_path), "--now", str(NOW)])
        self.assertEqual(rc, 0)
        return out.getvalue().strip()

    def test_the_posted_line_carries_the_warning_not_just_stderr(self):
        # the reader who acts on this number is in Slack; a warning only on stderr
        # announced an undercount as the week's measurement
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 2 * DAY), tier="T1")
        self._churned_run(iso(NOW - 100 * 3600))
        line = self._posted_line()
        self.assertIn("churned with open support issue: 1 users", line)
        self.assertIn("WARNING:", line)
        self.assertIn("repeats an old week", line)

    def test_a_fresh_sweep_posts_the_plain_line(self):
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 2 * DAY), tier="T1")
        self._churned_run(iso(NOW - 3600))
        line = self._posted_line()
        self.assertIn("churned with open support issue: 1 users", line)
        self.assertNotIn("WARNING", line)

    def test_a_churned_sweep_that_finished_with_source_errors_warns(self):
        # a ClickUp 500 sets tasks=[] and drops tiers, so this count is an undercount
        self.put(user_id=5, mode="churned", churned_at=iso(NOW - 2 * DAY), tier="T1")
        st = self.store()
        try:
            st.start_run("c1", "churned")
            st.finish_run("c1", users=1, errors=1, tiers={}, note="clickup: HTTP 500")
        finally:
            st.close()
        doc = self._line_doc()
        self.assertEqual(doc["churned_sweep_errors"], 1)
        self.assertIn("1 source error", doc.get("warning") or "")
        self.assertIn("undercounts", doc["warning"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
