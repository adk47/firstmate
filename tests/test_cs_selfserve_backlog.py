"""Behavioral tests for scripts/cs-selfserve-backlog.py.

This script runs UNATTENDED (daily --collect, monthly --post) and its only
side effects are its own durable rollup state and one Slack post -- it never
writes to Intercom/ClickUp/muso. The safety-relevant invariants covered
here: the context.compiled tool-catalog decoy is never counted; toolCallId
call+result pairing (including cross-sweep upgrades) is idempotent; a
corrupt rollup fails closed rather than silently zeroing history; a zero-
event sweep and a zero-total report month both fail loud instead of
reporting "all clear"/"nothing to build"; and FEATURE_MAP stays in lockstep
with plugins/support-tools/src/tools/ticket-format.ts's TIER_MAP.

Stdlib unittest + stubs only -- no pytest dependency, no network -- same
bare python3 -m unittest the other py-tests CI job entries use.
"""
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile
import unittest
import unittest.mock

_REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "cs-selfserve-backlog.py"
_spec = importlib.util.spec_from_file_location("cs_selfserve_backlog", _SCRIPT)
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)


def tool_call(tcid, action_type, session_key, ts):
    return {"type": "tool.call", "ts": ts, "sessionKey": session_key,
            "data": {"name": "create_ticket", "toolCallId": tcid,
                     "arguments": {"actionType": action_type}}}


def tool_result(tcid, payload, session_key, ts):
    return {"type": "tool.result", "ts": ts, "sessionKey": session_key,
            "data": {"name": "create_ticket", "toolCallId": tcid,
                     "contentItems": [{"type": "text", "text": json.dumps(payload)}]}}


def context_compiled_decoy(ts="2026-06-01T00:00:00Z"):
    """Every session's context.compiled event lists the full tool catalog,
    including create_ticket -- a decoy the substring pre-filter would match
    but the type check must exclude."""
    return {"type": "context.compiled", "ts": ts,
            "data": {"tools": [{"name": "create_ticket"}, {"name": "other_tool"}]}}


def write_jsonl(path, records):
    with open(path, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


class TestDecoyAndTypeFiltering(unittest.TestCase):
    def test_context_compiled_decoy_not_counted(self):
        lines = [json.dumps(context_compiled_decoy())]
        partial, calls_seen = m._sweep_lines(lines)
        self.assertEqual(calls_seen, 0)
        self.assertEqual(partial, {})

    def test_decoy_alongside_a_real_call_only_counts_the_real_one(self):
        lines = [
            json.dumps(context_compiled_decoy()),
            json.dumps(tool_call("t1", "credit-verify",
                                  "agent:support:intercom:direct:C1",
                                  "2026-06-01T00:00:00Z")),
        ]
        partial, calls_seen = m._sweep_lines(lines)
        self.assertEqual(calls_seen, 1)
        self.assertEqual(set(partial), {"t1"})


class TestCallResultPairing(unittest.TestCase):
    def test_new_ticket_status(self):
        lines = [
            json.dumps(tool_call("t1", "credit-verify",
                                  "agent:support:intercom:direct:C1",
                                  "2026-06-01T00:00:00Z")),
            json.dumps(tool_result("t1", {"submitted": True, "ticket_id": "1"},
                                    "agent:support:intercom:direct:C1",
                                    "2026-06-01T00:00:05Z")),
        ]
        partial, _ = m._sweep_lines(lines)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial, "2026-06-01")
        rec = state["months"]["2026-06"]["records"]["t1"]
        self.assertEqual(rec["status"], "new_ticket")
        self.assertEqual(rec["actionType"], "credit-verify")
        self.assertEqual(rec["conv"], "C1")

    def test_updated_existing_excluded_from_new_tickets(self):
        lines = [
            json.dumps(tool_call("t2", "credit-verify",
                                  "agent:support:intercom:direct:C2",
                                  "2026-06-02T00:00:00Z")),
            json.dumps(tool_result("t2", {"submitted": True, "updated_existing": True,
                                           "ticket_id": "1"},
                                    "agent:support:intercom:direct:C2",
                                    "2026-06-02T00:00:05Z")),
        ]
        partial, _ = m._sweep_lines(lines)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial, "2026-06-01")
        rec = state["months"]["2026-06"]["records"]["t2"]
        self.assertEqual(rec["status"], "updated")
        counts, _ = m.aggregate_month(state["months"]["2026-06"])
        self.assertEqual(counts["credit-verify"]["new_tickets"], 0)
        self.assertEqual(counts["credit-verify"]["updated"], 1)
        self.assertEqual(counts["credit-verify"]["touches"], 1)

    def test_submitted_false_is_error(self):
        lines = [
            json.dumps(tool_call("t3", "credit-claim",
                                  "agent:support:intercom:direct:C3",
                                  "2026-06-03T00:00:00Z")),
            json.dumps(tool_result("t3", {"submitted": False, "reason": "queue_busy"},
                                    "agent:support:intercom:direct:C3",
                                    "2026-06-03T00:00:05Z")),
        ]
        partial, _ = m._sweep_lines(lines)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial, "2026-06-01")
        rec = state["months"]["2026-06"]["records"]["t3"]
        self.assertEqual(rec["status"], "error")

    def test_orphan_call_is_touches_only_then_upgraded_by_later_result(self):
        first_sweep = [
            json.dumps(tool_call("t4", "profile-merge",
                                  "agent:support:intercom:direct:C4",
                                  "2026-06-04T00:00:00Z")),
        ]
        partial1, _ = m._sweep_lines(first_sweep)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial1, "2026-06-04")
        rec = state["months"]["2026-06"]["records"]["t4"]
        self.assertEqual(rec["status"], "call_only")
        counts, _ = m.aggregate_month(state["months"]["2026-06"])
        self.assertEqual(counts["profile-merge"], {"new_tickets": 0, "touches": 1,
                                                     "updated": 0, "error": 0})

        # A LATER sweep sees only the result (the call's file has since aged
        # off the reaper's ~5-day window) -- must still upgrade the record.
        later_sweep = [
            json.dumps(tool_result("t4", {"submitted": True, "ticket_id": "9"},
                                    "agent:support:intercom:direct:C4",
                                    "2026-06-04T00:05:00Z")),
        ]
        partial2, _ = m._sweep_lines(later_sweep)
        state = m.merge_into_state(state, partial2, "2026-06-05")
        rec = state["months"]["2026-06"]["records"]["t4"]
        self.assertEqual(rec["status"], "new_ticket")
        self.assertEqual(rec["actionType"], "profile-merge")  # preserved from the call

    def test_toolcallid_idempotency_double_sweep_identical_counts(self):
        lines = [
            json.dumps(tool_call("t5", "billing-issue",
                                  "agent:support:intercom:direct:C5",
                                  "2026-06-05T00:00:00Z")),
            json.dumps(tool_result("t5", {"submitted": True, "ticket_id": "5"},
                                    "agent:support:intercom:direct:C5",
                                    "2026-06-05T00:00:05Z")),
        ]
        partial, _ = m._sweep_lines(lines)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial, "2026-06-05")
        first = json.loads(json.dumps(state))
        state = m.merge_into_state(state, partial, "2026-06-05")
        self.assertEqual(state, first)


class TestSessionKeyConvResolution(unittest.TestCase):
    def test_non_intercom_direct_sessionkey_is_unattributed(self):
        lines = [
            json.dumps(tool_call("t6", "support-general", "agent:support:topic-xyz",
                                  "2026-06-06T00:00:00Z")),
            json.dumps(tool_result("t6", {"submitted": True, "ticket_id": "6"},
                                    "agent:support:topic-xyz", "2026-06-06T00:00:05Z")),
        ]
        partial, _ = m._sweep_lines(lines)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial, "2026-06-06")
        rec = state["months"]["2026-06"]["records"]["t6"]
        self.assertEqual(rec["conv"], "unattributed")
        _, unattributed = m.aggregate_month(state["months"]["2026-06"])
        self.assertEqual(unattributed, 1)


class TestMonthAttribution(unittest.TestCase):
    def test_utc_month_boundary(self):
        # 2026-06-30T23:59:59Z is still June; 2026-07-01T00:00:00Z is July.
        self.assertEqual(m.month_of("2026-06-30T23:59:59Z"), "2026-06")
        self.assertEqual(m.month_of("2026-07-01T00:00:00Z"), "2026-07")

    def test_records_attributed_to_the_boundary_months(self):
        lines = [
            json.dumps(tool_call("tb1", "credit-verify",
                                  "agent:support:intercom:direct:CB1",
                                  "2026-06-30T23:59:59Z")),
            json.dumps(tool_call("tb2", "credit-verify",
                                  "agent:support:intercom:direct:CB2",
                                  "2026-07-01T00:00:00Z")),
        ]
        partial, _ = m._sweep_lines(lines)
        state = m.merge_into_state({"schema": 1, "months": {}}, partial, "2026-07-01")
        self.assertIn("tb1", state["months"]["2026-06"]["records"])
        self.assertIn("tb2", state["months"]["2026-07"]["records"])


class TestCorruptRollupFailsClosed(unittest.TestCase):
    def test_corrupt_state_raises_and_file_untouched(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "monthly.json")
            with open(path, "w") as f:
                f.write("{not valid json")
            with self.assertRaises(m.StateUnreadable):
                m.load_state(path)
            with open(path) as f:
                self.assertEqual(f.read(), "{not valid json")

    def test_do_collect_exit_4_on_corrupt_state(self):
        with tempfile.TemporaryDirectory() as td:
            traj_dir = os.path.join(td, "sessions")
            os.makedirs(traj_dir)
            write_jsonl(os.path.join(traj_dir, "s1.trajectory.jsonl"), [
                tool_call("t1", "credit-verify", "agent:support:intercom:direct:C1",
                          "2026-06-01T00:00:00Z"),
            ])
            state_path = os.path.join(td, "monthly.json")
            with open(state_path, "w") as f:
                f.write("{not valid json")
            state, rc = m.do_collect(os.path.join(traj_dir, "*.trajectory.jsonl"),
                                      state_path, "2026-06-01")
            self.assertEqual(rc, 4)
            self.assertIsNone(state)
            with open(state_path) as f:
                self.assertEqual(f.read(), "{not valid json")


class TestZeroEventSweepFailsLoud(unittest.TestCase):
    def test_empty_dir_exit_4(self):
        with tempfile.TemporaryDirectory() as td:
            state_path = os.path.join(td, "monthly.json")
            state, rc = m.do_collect(os.path.join(td, "*.trajectory.jsonl"),
                                      state_path, "2026-06-01")
            self.assertEqual(rc, 4)
            self.assertIsNone(state)

    def test_files_present_but_zero_create_ticket_calls_exit_4(self):
        with tempfile.TemporaryDirectory() as td:
            write_jsonl(os.path.join(td, "s1.trajectory.jsonl"), [
                context_compiled_decoy(),
                {"type": "tool.call", "ts": "2026-06-01T00:00:00Z",
                 "sessionKey": "agent:support:intercom:direct:C1",
                 "data": {"name": "other_tool", "toolCallId": "x1"}},
            ])
            state_path = os.path.join(td, "monthly.json")
            state, rc = m.do_collect(os.path.join(td, "*.trajectory.jsonl"),
                                      state_path, "2026-06-01")
            self.assertEqual(rc, 4)
            self.assertIsNone(state)


class TestPostZeroTotalMonthFailsLoud(unittest.TestCase):
    def test_zero_total_report_month(self):
        state = {"schema": 1, "months": {}}
        report = m.build_report(state, "2026-07")
        self.assertEqual(report["total_touches"], 0)

    def test_nonzero_report_month(self):
        state = {"schema": 1, "months": {"2026-07": {"records": {
            "t1": {"actionType": "credit-verify", "conv": "C1", "status": "new_ticket"},
        }}}}
        report = m.build_report(state, "2026-07")
        self.assertEqual(report["total_touches"], 1)


class TestUnmappedActionType(unittest.TestCase):
    def test_unmapped_actiontype_rendered_not_dropped(self):
        state = {"schema": 1, "months": {"2026-07": {"records": {
            "t1": {"actionType": "some-brand-new-action", "conv": "C1", "status": "new_ticket"},
        }}}}
        report = m.build_report(state, "2026-07")
        keys = list(report["groups"])
        self.assertIn(("UNMAPPED", "some-brand-new-action"), keys)
        text = m.render_text(report)
        self.assertIn("some-brand-new-action", text)
        self.assertIn("UNMAPPED", text)


class TestTierMapParity(unittest.TestCase):
    """FEATURE_MAP must classify every actionType key in TIER_MAP, and vice
    versa -- a new repo-side actionType fails CI until it is classified
    here, and a stale FEATURE_MAP entry fails CI once TIER_MAP drops it."""

    @classmethod
    def setUpClass(cls):
        ts_path = _REPO_ROOT / "plugins" / "support-tools" / "src" / "tools" / "ticket-format.ts"
        text = ts_path.read_text()
        match = re.search(r"TIER_MAP:\s*Record<string,\s*Tier>\s*=\s*\{(.*?)\};", text, re.S)
        assert match, "could not locate TIER_MAP block in ticket-format.ts"
        cls.tier_map_keys = set(re.findall(r'"([a-z][a-z-]*)"\s*:', match.group(1)))

    def test_tier_map_has_17_keys(self):
        # Locks the known-good count so a parsing regression (e.g. the regex
        # silently matching 0 keys) can't masquerade as "parity".
        self.assertEqual(len(self.tier_map_keys), 17, self.tier_map_keys)

    def test_every_tier_map_key_is_classified(self):
        missing = self.tier_map_keys - set(m.FEATURE_MAP)
        self.assertEqual(missing, set(),
                          f"actionType(s) in TIER_MAP but not classified in FEATURE_MAP: {missing}")

    def test_every_feature_map_key_is_a_real_tier_map_action(self):
        stale = set(m.FEATURE_MAP) - self.tier_map_keys
        self.assertEqual(stale, set(),
                          f"FEATURE_MAP actionType(s) no longer in TIER_MAP: {stale}")


class TestPartialMonthLabel(unittest.TestCase):
    def test_partial_from_set_when_first_collect_is_mid_month(self):
        state = m.merge_into_state(
            {"schema": 1, "months": {}},
            m._sweep_lines([json.dumps(tool_call(
                "t1", "credit-verify", "agent:support:intercom:direct:C1",
                "2026-06-15T00:00:00Z"))])[0],
            "2026-06-15")
        self.assertEqual(state["months"]["2026-06"]["partial_from"], "2026-06-15")
        report = m.build_report(state, "2026-06")
        self.assertEqual(report["partial_from"], "2026-06-15")
        self.assertIn("data from 2026-06-15", m.render_text(report))

    def test_partial_from_absent_when_first_collect_is_month_start(self):
        state = m.merge_into_state(
            {"schema": 1, "months": {}},
            m._sweep_lines([json.dumps(tool_call(
                "t1", "credit-verify", "agent:support:intercom:direct:C1",
                "2026-06-01T00:00:00Z"))])[0],
            "2026-06-01")
        self.assertNotIn("partial_from", state["months"]["2026-06"])


class TestPolicyLowerBoundLabel(unittest.TestCase):
    def test_refund_line_carries_lower_bound_label(self):
        state = {"schema": 1, "months": {"2026-07": {"records": {
            "t1": {"actionType": "subscription-refund", "conv": "C1", "status": "new_ticket"},
        }}}}
        report = m.build_report(state, "2026-07")
        text = m.render_text(report)
        self.assertIn("subscription-refund", text)
        self.assertIn("lower bound", text)
        # Ensure the label sits on/near the refund line, not just the footer.
        refund_line = next(l for l in text.splitlines() if "subscription-refund" in l)
        self.assertIn("lower bound", refund_line)


class TestMonthCloseCollapse(unittest.TestCase):
    def test_collapse_drops_ids_and_preserves_counts(self):
        bucket = {"records": {
            "t1": {"actionType": "credit-verify", "conv": "C1", "status": "new_ticket"},
            "t2": {"actionType": "credit-verify", "conv": "C2", "status": "updated"},
        }}
        before_counts, before_unattributed = m.aggregate_month(bucket)
        collapsed = m.collapse_month(bucket)
        self.assertNotIn("records", collapsed)
        self.assertEqual(collapsed["counts"], before_counts)
        self.assertEqual(collapsed["unattributed"], before_unattributed)

    def test_collapse_is_a_noop_on_an_already_collapsed_bucket(self):
        bucket = {"counts": {"credit-verify": {"new_tickets": 1, "touches": 1,
                                                "updated": 0, "error": 0}},
                  "unattributed": 0}
        collapsed = m.collapse_month(bucket)
        self.assertEqual(collapsed, bucket)

    def test_collapsed_month_no_longer_accepts_record_merges(self):
        state = {"schema": 1, "months": {"2026-06": {
            "counts": {"credit-verify": {"new_tickets": 1, "touches": 1,
                                          "updated": 0, "error": 0}},
            "unattributed": 0}}}
        partial, _ = m._sweep_lines([json.dumps(tool_call(
            "tnew", "credit-verify", "agent:support:intercom:direct:CNEW",
            "2026-06-20T00:00:00Z"))])
        state = m.merge_into_state(state, partial, "2026-06-21")
        self.assertNotIn("records", state["months"]["2026-06"])
        self.assertEqual(state["months"]["2026-06"]["counts"]["credit-verify"]["touches"], 1)


class TestFlagComboValidation(unittest.TestCase):
    """main() must fail loud (exit 2) on flag combos where one flag would be
    silently ignored. --state is consulted only in the dry-run branch, so
    --state alongside --collect/--post would post to the REAL channel and
    collapse the REAL month state while the operator believed they were
    sandboxed. --collect wins over --post, silently skipping the post."""

    def _run_main(self, argv):
        with unittest.mock.patch.object(sys, "argv", ["cs-selfserve-backlog.py", *argv]):
            return m.main()

    def test_collect_and_post_mutually_exclusive(self):
        self.assertEqual(self._run_main(["--collect", "--post"]), 2)

    def test_state_with_collect_is_rejected(self):
        self.assertEqual(self._run_main(["--collect", "--state", "/tmp/x.json"]), 2)

    def test_state_with_post_is_rejected(self):
        self.assertEqual(self._run_main(["--post", "--state", "/tmp/x.json"]), 2)


class TestSelfTest(unittest.TestCase):
    def test_self_test_passes(self):
        self.assertTrue(m._self_test())


if __name__ == "__main__":
    unittest.main()
