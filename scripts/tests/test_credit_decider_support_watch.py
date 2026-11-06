#!/usr/bin/env python3
"""Unit tests for scripts/credit-decider-support-watch.py (Fable d2 [key=decider-support-arm]
condition 4: the paging alert ships in the same PR as the writing arm).

Stdlib unittest, no network, no Slack: `page()` is faked. Run:
    python3 scripts/tests/test_credit_decider_support_watch.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

from credit_review import decide  # noqa: E402

SCRIPT = HERE.parent / "credit-decider-support-watch.py"


def _load():
    spec = importlib.util.spec_from_file_location("credit_decider_support_watch", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = _load()
NOW = datetime(2026, 11, 4, 20, 0, tzinfo=timezone.utc)


def ts(offset_h: float = 0.0) -> str:
    return (NOW + timedelta(hours=offset_h)).strftime("%Y-%m-%dT%H:%M:%SZ")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.ledger = self.tmp / "ledger.sqlite3"
        self.db = sqlite3.connect(self.ledger)
        decide.ensure_schema(self.db)
        self.policy = self.tmp / "policy.json"
        self.policy.write_text(json.dumps({"deny_user_ids": [], "deny_profile_ids": [],
                                           "editorial_role_terms": ["editor"], "approve_arm": False}))
        self.cron = self.tmp / "cron-jobs.json"
        self.cron.write_text(json.dumps({"jobs": []}))
        self.kill = self.tmp / "decide.disabled"
        self.switch = self.tmp / "approve.disabled"
        self.state = self.tmp / "watch.state"
        self._saved = {k: getattr(W, k) for k in
                       ("LEDGER", "POLICY", "CRON_JOBS", "WRITER_KILL", "APPROVE_SWITCH", "STATE",
                        "SUPPORT_ONLY_SINCE")}
        # The scope starts before this fixture's rows: the real constant is the deploy date.
        W.SUPPORT_ONLY_SINCE = "2026-11-01T00:00:00Z"
        W.LEDGER, W.POLICY, W.CRON_JOBS = self.ledger, self.policy, self.cron
        W.WRITER_KILL, W.APPROVE_SWITCH, W.STATE = self.kill, self.switch, self.state
        self.addCleanup(self._restore)
        self.pages = []
        self._page = W.page
        # the real page() returns whether delivery SUCCEEDED; the stub must too (a None stub reads as a failed page)
        W.page = lambda text: (self.pages.append(text), True)[1]
        self.addCleanup(setattr, W, "page", self._page)

    def _restore(self):
        for k, v in self._saved.items():
            setattr(W, k, v)
        self.db.close()

    # ── ledger fixtures ──────────────────────────────────────────────────────
    def decision(self, rid="r1", *, mode="apply", decision="support", at="2026-11-04T19:00:00Z"):
        self.db.execute(
            "INSERT INTO decisions (run_id, decided_at, request_id, user_id, decision, reason, big_track, mode)"
            " VALUES (?,?,?,?,?,?,?,?)", ("run1", at, rid, 9, decision, "x", 0, mode))
        self.db.commit()

    def outcome(self, rid="r1", *, action="support", outcome=decide.UVN, at="2026-11-04T19:00:00Z"):
        self.db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome)"
                        " VALUES (?,?,?,?,?)", ("run1", at, rid, action, outcome))
        self.db.commit()

    def state_row(self, key, doc):
        self.db.execute("INSERT INTO state (k, v) VALUES (?,?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                        (key, json.dumps(doc)))
        self.db.commit()

    def scheduled(self, mode="apply", enabled=True):
        self.cron.write_text(json.dumps({"jobs": [{
            "id": "credit-trust-decide-apply", "enabled": enabled,
            "payload": {"argv": ["python3", "scripts/credit-review.py", "decide", "--mode", mode]}}]}))

    def keys(self):
        return [f["key"] for f in W.findings(self.db, NOW)]

    # ── tests ────────────────────────────────────────────────────────────────
    def test_a_clean_ledger_pages_nothing(self):
        self.decision()
        self.outcome()
        self.assertEqual(W.findings(self.db, NOW), [])

    def test_an_approval_written_while_the_arm_is_off_pages(self):
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        self.assertEqual(self.keys(), ["approve_written"])
        text = W.findings(self.db, NOW)[0]["text"]
        self.assertIn("SUPPORT-ONLY VIOLATION", text)
        self.assertIn("run1", text)

    def test_the_arms_history_is_not_a_violation(self):
        # Measured on node-8 2026-11-04: 654 apply-mode approvals, newest 2026-10-26T23:17:06Z, all
        # written while the arm was legitimately armed. Paging on that backlog would bury the signal.
        self.decision(decision="approve", at="2026-10-26T23:17:06Z")
        self.outcome(action="approve", outcome=decide.APPROVED, at="2026-10-26T23:17:06Z")
        self.assertEqual(self.keys(), [], "before SUPPORT_ONLY_SINCE: history, not a violation")
        self.assertEqual([f["key"] for f in W.findings(self.db, NOW, since="2026-10-01T00:00:00Z")],
                         ["approve_written"], "--since is the audit path over the arm's history")

    def test_an_approval_inside_the_scope_pages(self):
        self.decision(decision="approve", at="2026-11-05T10:00:00Z")
        self.outcome(action="approve", outcome=decide.APPROVED, at="2026-11-05T10:00:00Z")
        later = datetime(2026, 11, 5, 12, 0, tzinfo=timezone.utc)
        self.assertEqual([f["key"] for f in W.findings(self.db, later)], ["approve_written"])

    def test_the_approval_finding_ignores_shadow_and_judge_runs(self):
        self.decision(decision="approve", mode="shadow")
        self.outcome(action="approve", outcome=decide.APPROVED)
        self.assertEqual(self.keys(), [], "shadow writes nothing: an 'approved' row there is not a write")

    def test_an_armed_policy_stops_the_approval_finding(self):
        self.policy.write_text(json.dumps({"approve_arm": True}))
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        self.assertEqual(self.keys(), [], "the arm was deliberately armed and unswitched")

    def test_the_switch_keeps_an_armed_policy_closed(self):
        self.policy.write_text(json.dumps({"approve_arm": True}))
        self.switch.write_text("off")
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        self.assertEqual(self.keys(), ["approve_written"])

    def test_a_failed_ask_ledger_pages(self):
        self.state_row("support-writer:ask-ledger-error:run1",
                       {"run_id": "run1", "user_id": 9, "error": "database is locked"})
        self.assertEqual(self.keys(), ["ask_ledger_gap"])

    def test_a_gap_the_read_back_RECONCILED_stops_paging(self):
        """qa-review #1782 (r12) Important: the query selected every historical error key unconditionally, so a
        gap the read-back later reconciled paged every 6h forever - telling an operator to reconcile something
        that already was. A run whose read-back recorded ok:true has no gap left."""
        self.state_row("support-writer:ask-ledger-error:run1:9",
                       {"run_id": "run1", "user_id": 9, "error": "database is locked", "asks": 2})
        self.assertEqual(self.keys(), ["ask_ledger_gap"], "precondition: an unreconciled gap pages")
        self.state_row("support-writer:readback:run1", {"run_id": "run1", "ok": True})
        self.assertEqual(self.keys(), [], "the read-back reconciled it, so there is nothing left to reconcile")

    def test_a_gap_whose_read_back_did_NOT_confirm_keeps_paging(self):
        self.state_row("support-writer:ask-ledger-error:run1:9",
                       {"run_id": "run1", "user_id": 9, "error": "database is locked"})
        self.state_row("support-writer:readback:run1", {"run_id": "run1", "ok": False, "missing": ["r1"]})
        self.assertEqual(self.keys(), ["ask_ledger_gap"], "an ask core does not show is still a real gap")

    def test_the_gap_finding_counts_USERS_and_ASKS_not_rows(self):
        """The key used to be per RUN, so N affected users overwrote each other and the page under-reported."""
        for uid in (9, 10, 11):
            self.state_row(f"support-writer:ask-ledger-error:run1:{uid}",
                           {"run_id": "run1", "user_id": uid, "error": "database is locked", "asks": 2})
        found = W.findings(self.db, NOW)
        self.assertEqual([f["key"] for f in found], ["ask_ledger_gap"])
        self.assertIn("3 user(s) / 6 ask(s)", found[0]["text"])

    def test_support_write_errors_page(self):
        self.decision()
        self.outcome(outcome="error:PUT HTTP 400")
        self.assertEqual(self.keys(), ["support_write_error"])

    def test_silence_pages_in_the_SHIPPED_support_only_configuration(self):
        """qa-review #1782 finding 2: `approve_arm:false` is what this PR ships, and the alert must fire in it.

        The two arms are separate axes: an approve arm that is off by policy says nothing about whether the SUPPORT
        writer is running. Gating this on approve_arm_on() made the alert unreachable in exactly the configuration it
        shipped in - the "guard whose first act is a false negative" failure, inverted.
        """
        self.assertEqual(json.loads(self.policy.read_text())["approve_arm"], False, "precondition: the shipped policy")
        self.decision()                      # a candidate in the window, nothing sent
        self.assertEqual(self.keys(), [], "nothing is scheduled to write, so silence is not a failure")
        self.scheduled()                     # Ops enabled the SUPPORT writer
        self.assertEqual(self.keys(), ["candidates_but_silent"],
                         "support-only policy + scheduled apply + a candidate + zero asks = the writer is stuck")
        self.assertIn("support writer is on", W.findings(self.db, NOW)[0]["text"])
        self.kill.write_text("off")          # the writer is killed: a killed arm must not page
        self.assertEqual(self.keys(), [])

    def test_an_armed_approve_arm_does_not_change_the_silence_branch(self):
        self.policy.write_text(json.dumps({"approve_arm": True}))
        self.scheduled()
        self.kill.write_text("off")
        self.decision()
        self.assertEqual(self.keys(), [], "the writer kill file still stops it, whatever the approve arm says")

    def test_silence_does_not_page_without_a_scheduled_apply(self):
        self.policy.write_text(json.dumps({"approve_arm": True}))
        self.scheduled(mode="judge")         # judge is the only scheduled mode
        self.decision()
        self.assertEqual(self.keys(), [], "nothing is scheduled to write, so silence is not a failure")
        self.scheduled(enabled=False)
        self.assertEqual(self.keys(), [])

    def test_readback_owed_pages_after_the_grace_window(self):
        self.state_row("support-writer:apply:run1", {"run_id": "run1", "at": ts(-1), "asks": 3})
        self.assertEqual(self.keys(), [], "1h is inside the grace window")
        self.state_row("support-writer:apply:run2", {"run_id": "run2", "at": ts(-7), "asks": 2})
        self.assertEqual(self.keys(), ["readback_owed"])
        self.assertIn("run2", W.findings(self.db, NOW)[0]["text"])

    def test_a_FAILED_readback_still_pages_after_the_grace_window(self):
        """qa-review #1782 finding 4: `ok:false` leaves the apply gate CLOSED, so the wedge is worse, not cleared."""
        for ok in (False, None, "yes"):
            with self.subTest(ok=ok):
                self.state_row("support-writer:apply:run9", {"run_id": "run9", "at": ts(-9), "asks": 4})
                self.state_row("support-writer:readback:run9", {"run_id": "run9", "at": ts(-7), "ok": ok,
                                                                "error": "core answered 3 of 4"})
                found = {f["key"]: f["text"] for f in W.findings(self.db, NOW)}
                self.assertIn("readback_failed", found, "a read-back that did not confirm every row leaves it owed")
                self.assertIn("run9", found["readback_failed"])
                self.assertIn("core answered 3 of 4", found["readback_failed"])
                self.assertNotIn("readback_owed", found, "one finding per condition, not two")

    def test_a_failed_readback_inside_the_grace_window_waits(self):
        self.state_row("support-writer:apply:run9", {"run_id": "run9", "at": ts(-3), "asks": 4})
        self.state_row("support-writer:readback:run9", {"run_id": "run9", "at": ts(-2), "ok": False})
        self.assertEqual(self.keys(), [], "the retry is still fresh: do not page yet")

    def test_an_unreadable_readback_record_is_treated_as_failed(self):
        self.state_row("support-writer:apply:run9", {"run_id": "run9", "at": ts(-9), "asks": 4})
        self.db.execute("INSERT INTO state (k, v) VALUES (?,?)",
                        ("support-writer:readback:run9", "{not json"))
        self.db.commit()
        self.assertIn("readback_failed", self.keys())

    def test_a_confirmed_readback_clears_the_owed_finding(self):
        self.state_row("support-writer:apply:run2", {"run_id": "run2", "at": ts(-7), "asks": 2})
        self.state_row("support-writer:readback:run2", {"run_id": "run2", "at": ts(-6), "ok": True})
        self.assertEqual(self.keys(), [])

    # ── main() ───────────────────────────────────────────────────────────────
    def test_main_pages_once_then_dedupes(self):
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        self.assertEqual(W.main([]), 1)
        self.assertEqual(len(self.pages), 1)
        self.assertIn("SUPPORT-ONLY VIOLATION", self.pages[0])
        self.assertEqual(W.main([]), 0, "4th call inside DEDUPE_H: already paged")
        self.assertEqual(len(self.pages), 1)
        self.assertEqual(self.state.exists(), True, "the dedupe stamp is recorded")

    def test_an_UNDELIVERED_page_is_not_recorded_and_is_retried(self):
        """qa-review #1782 finding 3: a Slack outage used to stamp the dedupe key, silencing the alert for DEDUPE_H."""
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        W.page = lambda text: False                      # the notifier fails
        self.assertEqual(W.main([]), 1, "the condition is still a finding, and still needs a human")
        self.assertEqual(self.pages, [], "nothing was delivered")
        self.assertFalse(self.state.exists(), "an undelivered page must not be stamped as delivered")
        W.page = lambda text: (self.pages.append(text), True)[1]   # Slack is back
        self.assertEqual(W.main([]), 1)
        self.assertEqual(len(self.pages), 1, "the retry delivers it - the dedupe stamp never suppressed it")
        self.assertTrue(self.state.exists())

    def test_dry_run_never_pages_and_never_records(self):
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        with mock.patch("builtins.print") as out:
            self.assertEqual(W.main(["--dry-run"]), 1)
        self.assertEqual(self.pages, [])
        self.assertFalse(self.state.exists())
        self.assertTrue(any("WOULD PAGE" in str(c) for c in out.call_args_list))

    def test_a_missing_ledger_is_not_clean(self):
        self.ledger.unlink()
        self.assertEqual(W.main([]), 2)
        self.assertEqual(len(self.pages), 1)
        self.assertIn("CANNOT MEASURE", self.pages[0])

    def test_json_output_names_what_it_paged(self):
        self.decision(decision="approve")
        self.outcome(action="approve", outcome=decide.APPROVED)
        with mock.patch("builtins.print") as out:
            W.main(["--json"])
        doc = json.loads(out.call_args_list[0][0][0])
        self.assertEqual(doc["paged"], ["approve_written"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
