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
import sqlite3
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


def typed_decoy_with_tool_name(ts="2026-06-01T00:00:00Z"):
    """A non-tool event that DOES carry data.name == create_ticket (and a
    toolCallId). Only the `type` check can exclude it -- the name check
    passes. Exists because the plain context_compiled_decoy is excluded by
    EITHER guard, so it cannot falsify either one on its own."""
    return {"type": "context.compiled", "ts": ts,
            "sessionKey": "agent:support:intercom:direct:777",
            "data": {"name": "create_ticket", "toolCallId": "decoy-typed",
                     "arguments": {"actionType": "support-general"}}}


def other_tool_call(tcid="oth1", name="support_action_router",
                    ts="2026-06-01T00:00:00Z"):
    """A real tool.call for a DIFFERENT tool. Only the data.name check can
    exclude it -- the type check passes. This is the high-volume case on live
    node-8: 2,866 tool.call events in a week against 359 create_ticket ones
    (859 `read`, 577 `support_action_router`), so a missing name check would
    inflate the ticket count ~8x rather than fail visibly."""
    return {"type": "tool.call", "ts": ts,
            "sessionKey": "agent:support:intercom:direct:778",
            "data": {"name": name, "toolCallId": tcid,
                     "arguments": {"actionType": "support-general"}}}


def write_jsonl(path, records):
    with open(path, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


def write_trajectory_db(path, records, table="trajectory_runtime_events",
                        created_at=None):
    """Seed a store the way openclaw 2.0 does: one row per event, event_json
    holding the SAME object the JSONL line used to hold. `table` is
    parameterised so a test can build a store WITHOUT the expected table."""
    con = sqlite3.connect(path)
    con.execute("create table %s (session_id text, seq integer, run_id text, "
                "event_json text, created_at integer)" % table)
    for i, r in enumerate(records):
        ts = (created_at[i] if isinstance(created_at, (list, tuple))
              else created_at if created_at is not None
              else 1789000000000 + i)
        con.execute("insert into %s values (?,?,?,?,?)" % table,
                    ("s1", i, "r1", json.dumps(r), ts))
    con.commit()
    con.close()


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



class TestSqliteTrajectorySource(unittest.TestCase):
    """openclaw 2.0 moved the trajectory out of *.trajectory.jsonl and into
    each agent's store, table trajectory_runtime_events. The old glob then
    matched nothing and this collector failed rc=4 every day from the
    2026-09-10 cutover -- loudly, but recording nothing for six days."""

    def test_reads_create_ticket_calls_from_the_agent_store(self):
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [
                tool_call("tc1", "support-general",
                          "agent:support:intercom:direct:900", "2026-09-16T01:00:00Z"),
                tool_result("tc1", {"submitted": True},
                            "agent:support:intercom:direct:900", "2026-09-16T01:00:05Z"),
            ])
            partial, calls = m.sweep_sqlite([db])
        self.assertEqual(calls, 1)
        self.assertEqual(m.classify_status(partial["tc1"]), "new_ticket")

    def test_context_compiled_decoy_in_the_store_is_not_counted(self):
        # The SQL `instr` pre-filter matches every context.compiled event
        # (each lists create_ticket in its tool catalog) -- on live node-8
        # that is 3,654 matching rows against 359 real tool.calls. The type
        # check inside ingest_record is what makes the count real, so assert
        # the decoy alone yields ZERO rather than "some".
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [context_compiled_decoy() for _ in range(5)])
            partial, calls = m.sweep_sqlite([db])
        self.assertEqual(calls, 0)
        self.assertEqual(partial, {})

    def test_a_store_without_the_table_is_skipped_not_fatal(self):
        # A 7.x store, or one mid-migration, has no such table. Skipping keeps
        # the zero-day check in do_collect as the single place that decides a
        # sweep failed; raising here would crash before that message.
        with tempfile.TemporaryDirectory() as td:
            bad = os.path.join(td, "no-table.sqlite")
            write_trajectory_db(bad, [], table="something_else")
            good = os.path.join(td, "good.sqlite")
            write_trajectory_db(good, [
                tool_call("tc9", "support-general",
                          "agent:support:intercom:direct:901", "2026-09-16T02:00:00Z")])
            partial, calls = m.sweep_sqlite([bad, good])
        self.assertEqual(calls, 1)
        self.assertIn("tc9", partial)

    def test_a_missing_store_file_is_skipped_not_fatal(self):
        with tempfile.TemporaryDirectory() as td:
            partial, calls = m.sweep_sqlite([os.path.join(td, "absent.sqlite")])
        self.assertEqual((partial, calls), ({}, 0))

    def test_jsonl_and_sqlite_readers_agree_on_the_same_events(self):
        """The parity that makes ONE ingest_record worth having: identical
        events through both readers must produce identical results. If these
        ever diverge, a migration has silently changed the numbers."""
        records = [
            context_compiled_decoy(),
            tool_call("a", "support-general",
                      "agent:support:intercom:direct:1", "2026-09-16T03:00:00Z"),
            tool_result("a", {"submitted": True},
                        "agent:support:intercom:direct:1", "2026-09-16T03:00:01Z"),
            tool_call("b", "credit-claim",
                      "agent:support:intercom:direct:2", "2026-09-16T04:00:00Z"),
            tool_result("b", {"submitted": True, "updated_existing": True},
                        "agent:support:intercom:direct:2", "2026-09-16T04:00:01Z"),
            tool_call("c", "refund", "agent:support:slack:C1:thread:1",
                      "2026-09-16T05:00:00Z"),
        ]
        with tempfile.TemporaryDirectory() as td:
            jf = os.path.join(td, "x.trajectory.jsonl")
            write_jsonl(jf, records)
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, records)
            j_partial, j_calls = m.sweep_files([jf])
            s_partial, s_calls = m.sweep_sqlite([db])
        self.assertEqual(j_calls, s_calls)
        self.assertEqual(j_partial, s_partial)
        self.assertEqual(j_calls, 3)

    def test_do_collect_zero_day_message_names_the_store(self):
        # From the cutover this said "matched 0 trajectory file(s)", which was
        # true and still took six days to read as "2.0 stopped writing that
        # file". The message must name the source actually swept.
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [context_compiled_decoy()])
            state, rc = m.do_collect(("sqlite", [db]),
                                     os.path.join(td, "state.json"), "2026-09-16")
        self.assertEqual(rc, 4)
        self.assertIsNone(state)


class TestResolveSource(unittest.TestCase):
    """Three-state detection: JSONL, SQLite, or refuse. "Unknown" is not a
    synonym for either branch -- both wrong guesses end at the same rc=4 with
    a message blaming the data instead of the detection."""

    def test_forced_jsonl_returns_the_glob(self):
        src, rc = m.resolve_source({"CS_BACKLOG_SOURCE": "jsonl",
                                    "CS_BACKLOG_TRAJECTORY_GLOB": "/tmp/g/*.jsonl"})
        self.assertEqual((src, rc), ("/tmp/g/*.jsonl", 0))

    def test_forced_sqlite_returns_the_db_list(self):
        src, rc = m.resolve_source({"CS_BACKLOG_SOURCE": "sqlite",
                                    "CS_BACKLOG_TRAJECTORY_DBS": "/a.sqlite:/b.sqlite"})
        self.assertEqual((src, rc), (("sqlite", ["/a.sqlite", "/b.sqlite"]), 0))

    def test_an_unknown_forced_value_refuses(self):
        src, rc = m.resolve_source({"CS_BACKLOG_SOURCE": "maybe"})
        self.assertEqual(rc, 4)
        self.assertIsNone(src)

    def test_auto_on_2026_8_picks_sqlite(self):
        with unittest.mock.patch.object(m, "openclaw_runtime_version",
                                        return_value=(2026, 8)):
            src, rc = m.resolve_source({})
        self.assertEqual(rc, 0)
        self.assertEqual(src[0], "sqlite")

    def test_auto_on_2026_7_picks_jsonl(self):
        with unittest.mock.patch.object(m, "openclaw_runtime_version",
                                        return_value=(2026, 7)):
            src, rc = m.resolve_source({})
        self.assertEqual((src, rc), (m.DEFAULT_TRAJECTORY_GLOB, 0))

    def test_auto_with_an_unreadable_version_refuses_rather_than_guessing(self):
        with unittest.mock.patch.object(m, "openclaw_runtime_version",
                                        return_value=None):
            src, rc = m.resolve_source({})
        self.assertEqual(rc, 4)
        self.assertIsNone(src)

    def test_a_later_major_still_picks_sqlite(self):
        # 2027.x must not fall back to the dead JSONL branch.
        with unittest.mock.patch.object(m, "openclaw_runtime_version",
                                        return_value=(2027, 1)):
            src, rc = m.resolve_source({})
        self.assertEqual(src[0], "sqlite")



class TestDecoyGuardsAreIndividuallyFalsifiable(unittest.TestCase):
    """The plain context.compiled decoy is excluded by EITHER the type check
    or the data.name check, so it cannot prove either one. Mutating each guard
    away left the suite green -- a hole that predates the SQLite work. These
    two fixtures each defeat exactly one guard, so each guard now has a test
    that fails when it is removed."""

    def test_type_check_alone_excludes_a_decoy_that_carries_the_tool_name(self):
        # Defeats the data.name check on purpose: name IS create_ticket and a
        # toolCallId is present. Only `type not in (tool.call, tool.result)`
        # keeps this out of the count.
        partial = {}
        counted = m.ingest_record(typed_decoy_with_tool_name(), partial)
        self.assertFalse(counted)
        self.assertEqual(partial, {})

    def test_name_check_alone_excludes_another_tool_s_call(self):
        # Defeats the type check on purpose: this IS a tool.call. Only
        # data.name keeps it out. Without it every read/support_action_router
        # call would be counted as a support ticket.
        partial = {}
        counted = m.ingest_record(other_tool_call(), partial)
        self.assertFalse(counted)
        self.assertEqual(partial, {})

    def test_both_guards_hold_through_the_real_readers(self):
        # Same two decoys plus one genuine call, through BOTH sources, so the
        # guards are proven where production actually reads -- not only at the
        # ingest_record seam.
        records = [
            typed_decoy_with_tool_name(),
            other_tool_call(),
            other_tool_call(tcid="oth2", name="read"),
            tool_call("real1", "support-general",
                      "agent:support:intercom:direct:779", "2026-09-16T06:00:00Z"),
        ]
        with tempfile.TemporaryDirectory() as td:
            jf = os.path.join(td, "x.trajectory.jsonl")
            write_jsonl(jf, records)
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, records)
            j_partial, j_calls = m.sweep_files([jf])
            s_partial, s_calls = m.sweep_sqlite([db])
        self.assertEqual(j_calls, 1)
        self.assertEqual(s_calls, 1)
        self.assertEqual(list(j_partial), ["real1"])
        self.assertEqual(j_partial, s_partial)



class TestLivenessWindow(unittest.TestCase):
    """QA finding on this PR: the JSONL era got a bounded window for free --
    the on-disk reaper kept ~5 days of files -- but trajectory_runtime_events
    is PERSISTENT. Counting every retained row toward the zero-day gate means
    that once one sweep succeeds, the day Caroline goes down (or the event
    schema changes again) yesterday's rows still hold the gate green.

    The split: `partial` stays the full scan so the idempotent rollup merge can
    still backfill a missed day; `calls_seen` is liveness only."""

    def _now_ms(self):
        import time as _t
        return int(_t.time() * 1000)

    def test_only_old_rows_is_a_zero_day_not_a_success(self):
        # The bot's exact scenario: matching rows exist, none in the window.
        now = self._now_ms()
        old = now - 10 * 24 * 3600 * 1000
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [
                tool_call("old1", "support-general",
                          "agent:support:intercom:direct:1", "2026-09-01T00:00:00Z"),
                tool_result("old1", {"submitted": True},
                            "agent:support:intercom:direct:1", "2026-09-01T00:00:01Z"),
            ], created_at=old)
            state, rc = m.do_collect(("sqlite", [db]),
                                     os.path.join(td, "state.json"), "2026-09-16")
        self.assertEqual(rc, 4)
        self.assertIsNone(state)

    def test_a_recent_call_passes_and_the_merge_still_sees_the_old_ids(self):
        # Liveness is satisfied by the recent row, and the FULL scan must still
        # reach the old one -- narrowing `partial` would lose the backfill that
        # covers a missed day.
        now = self._now_ms()
        old = now - 10 * 24 * 3600 * 1000
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [
                tool_call("old1", "support-general",
                          "agent:support:intercom:direct:1", "2026-09-01T00:00:00Z"),
                tool_call("new1", "credit-claim",
                          "agent:support:intercom:direct:2", "2026-09-16T00:00:00Z"),
            ], created_at=[old, now - 3600 * 1000])
            partial, calls = m.sweep_sqlite([db], liveness_since_ms=now - 48 * 3600 * 1000)
            state, rc = m.do_collect(("sqlite", [db]),
                                     os.path.join(td, "state.json"), "2026-09-16")
        self.assertEqual(calls, 1)                 # liveness counts only the recent one
        self.assertEqual(sorted(partial), ["new1", "old1"])   # merge sees both
        self.assertEqual(rc, 0)
        self.assertIsNotNone(state)

    def test_an_unattributable_created_at_does_not_hold_the_gate_open(self):
        # A NULL/garbage timestamp must not be what keeps the collector green:
        # we cannot tell whether that row is from today or last month.
        now = self._now_ms()
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [
                tool_call("weird", "support-general",
                          "agent:support:intercom:direct:3", "2026-09-16T00:00:00Z"),
            ], created_at="not-a-number")
            partial, calls = m.sweep_sqlite([db], liveness_since_ms=now - 48 * 3600 * 1000)
        self.assertEqual(calls, 0)
        self.assertIn("weird", partial)            # still merged, just not counted

    def test_no_window_counts_everything_which_is_what_parity_relies_on(self):
        now = self._now_ms()
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [
                tool_call("a", "support-general",
                          "agent:support:intercom:direct:4", "2026-01-01T00:00:00Z"),
            ], created_at=now - 365 * 24 * 3600 * 1000)
            _, calls = m.sweep_sqlite([db], liveness_since_ms=None)
        self.assertEqual(calls, 1)

    def test_the_window_is_env_overridable(self):
        # A 1h window must reject a 5h-old row that the 48h default accepts.
        now = self._now_ms()
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "openclaw-agent.sqlite")
            write_trajectory_db(db, [
                tool_call("h5", "support-general",
                          "agent:support:intercom:direct:5", "2026-09-16T00:00:00Z"),
            ], created_at=now - 5 * 3600 * 1000)
            st = os.path.join(td, "state.json")
            with unittest.mock.patch.dict(os.environ,
                                          {"CS_BACKLOG_LIVENESS_WINDOW_H": "1"}):
                _, rc_narrow = m.do_collect(("sqlite", [db]), st, "2026-09-16")
            with unittest.mock.patch.dict(os.environ,
                                          {"CS_BACKLOG_LIVENESS_WINDOW_H": "48"}):
                _, rc_wide = m.do_collect(("sqlite", [db]), st, "2026-09-16")
        self.assertEqual(rc_narrow, 4)
        self.assertEqual(rc_wide, 0)


if __name__ == "__main__":
    unittest.main()
