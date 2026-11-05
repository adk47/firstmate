"""Tests for the SA store (SA-01). Python 3 stdlib only.

Run from the repo root:

    python3 -m unittest discover -s sa/tests -v
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SA_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SA_DIR.parent
sys.path.insert(0, str(SA_DIR / "lib"))

from sa_paths import canonical, parse_at, sa_home, sha256_of  # noqa: E402
from sa_store import (  # noqa: E402
    EVENT_TYPES,
    TABLE_ORDER,
    StoreError,
    append_event,
    fold,
    query,
    read_events,
    snapshot,
    table,
)

CLI = SA_DIR / "bin" / "sa-store"


def run_cli(args, home, check=True):
    """Run the CLI with an isolated SA_HOME and return the completed process."""
    env = dict(os.environ)
    env["SA_HOME"] = str(home)
    proc = subprocess.run(
        [sys.executable, str(CLI), *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"sa-store {' '.join(args)} exited {proc.returncode}\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc


class TempHomeCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="sa-test-")
        self.home = Path(self._tmp.name) / "home"
        self.home.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def append(self, type_, actor="router", ticket=None, at="2026-11-05T02:00:00Z", payload=None):
        return append_event(
            type=type_, actor=actor, ticket=ticket, at=at,
            payload=payload or {}, home=self.home,
        )


class CanonicalJsonTest(unittest.TestCase):
    def test_canonical_form_is_exact(self):
        self.assertEqual(
            canonical({"b": 1, "a": [1, 2], "c": "é"}),
            '{"a":[1,2],"b":1,"c":"é"}',
        )

    def test_canonical_has_no_spaces_and_sorted_keys(self):
        text = canonical({"z": {"y": 1, "x": 2}})
        self.assertEqual(text, '{"z":{"x":2,"y":1}}')
        self.assertNotIn(" ", text)

    def test_sha256_is_stable_across_key_order(self):
        self.assertEqual(sha256_of({"a": 1, "b": 2}), sha256_of({"b": 2, "a": 1}))

    def test_parse_at_normalizes_offsets(self):
        self.assertEqual(parse_at("2026-11-05T02:10:00Z"), "2026-11-05T02:10:00Z")
        self.assertEqual(parse_at("2026-11-05T03:10:00+01:00"), "2026-11-05T02:10:00Z")

    def test_parse_at_rejects_naive_and_garbage(self):
        for bad in ("2026-11-05T02:10:00", "yesterday", ""):
            with self.assertRaises(ValueError):
                parse_at(bad)


class AppendTest(TempHomeCase):
    def test_seq_starts_at_one_and_ids_are_deterministic(self):
        first = self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        second = self.append("ticket.created", ticket="T-2", payload={"title": "b"})
        self.assertEqual(first["seq"], 1)
        self.assertEqual(first["id"], "ev-0000000000000001")
        self.assertEqual(second["seq"], 2)
        self.assertEqual(second["id"], "ev-0000000000000002")

    def test_envelope_has_exactly_the_contract_fields(self):
        event = self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        self.assertEqual(
            sorted(event),
            ["actor", "at", "id", "payload", "seq", "ticket", "type"],
        )
        self.assertEqual(event["actor"], "router")
        self.assertEqual(event["at"], "2026-11-05T02:00:00Z")

    def test_log_is_one_canonical_line_per_event(self):
        self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        self.append("ticket.classified", ticket="T-1", payload={"class": "code"})
        raw = (self.home / "events.jsonl").read_text(encoding="utf-8")
        lines = raw.splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(raw.endswith("\n"))
        for line in lines:
            self.assertEqual(line, canonical(json.loads(line)))

    def test_ticket_defaults_to_null(self):
        event = self.append("usage.recorded", actor="worker", payload={"tier": "t1"})
        self.assertIsNone(event["ticket"])

    def test_rejects_unknown_actor(self):
        with self.assertRaises(StoreError):
            self.append("ticket.created", actor="captain")

    def test_rejects_non_object_payload(self):
        with self.assertRaises(StoreError):
            append_event("ticket.created", "router", payload=[1], home=self.home)

    def test_rejects_bad_timestamp(self):
        with self.assertRaises(ValueError):
            self.append("ticket.created", at="not-a-time")

    def test_append_creates_home_when_absent(self):
        nested = Path(self._tmp.name) / "a" / "b"
        append_event("ticket.created", "router", ticket="T-1", home=nested)
        self.assertTrue((nested / "events.jsonl").exists())


class FoldTest(TempHomeCase):
    def test_all_ten_tables_exist_on_empty_log(self):
        state = snapshot(self.home)
        self.assertEqual(sorted(state), sorted(TABLE_ORDER))
        self.assertEqual(len(state), 10)
        for name in TABLE_ORDER:
            self.assertEqual(state[name], {})

    def test_unknown_event_type_is_recorded_and_ignored(self):
        self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        before = snapshot(self.home)
        self.append("future.thing", ticket="T-1", payload={"x": 1})
        after = snapshot(self.home)
        self.assertEqual(len(after["events"]), 2)
        self.assertEqual(after["events"]["2"]["type"], "future.thing")
        for name in TABLE_ORDER:
            if name == "events":
                continue
            self.assertEqual(after[name], before[name], name)

    def test_ticket_lifecycle(self):
        self.append("ticket.created", ticket="T-1", payload={
            "title": "Add store", "body": "b", "requester": "aaron",
            "acceptance": {"command": "true"},
        })
        self.append("ticket.classified", ticket="T-1", payload={"class": "code"})
        self.append("ticket.assigned", ticket="T-1", payload={"owner": "w1", "reason": "r"})
        self.append("ticket.dispatched", ticket="T-1", payload={
            "worktree": "/tmp/wt", "brief": "/tmp/b", "worker": "w1", "mandate": "T-1",
        })
        row = snapshot(self.home)["tickets"]["T-1"]
        self.assertEqual(row["title"], "Add store")
        self.assertEqual(row["requester"], "aaron")
        self.assertEqual(row["acceptance"], {"command": "true"})
        self.assertEqual(row["class"], "code")
        self.assertEqual(row["owner"], "w1")
        self.assertEqual(row["state"], "dispatched")
        self.assertEqual(row["created_at"], "2026-11-05T02:00:00Z")
        self.assertEqual(row["updated_at"], "2026-11-05T02:00:00Z")

    def test_ticket_refused_sets_state(self):
        self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        self.append("ticket.refused", actor="engine", ticket="T-1",
                    payload={"missing_question": "What command proves this?"})
        self.assertEqual(snapshot(self.home)["tickets"]["T-1"]["state"], "refused")

    def test_mandate_issued_then_revoked(self):
        self.append("mandate.issued", actor="engine", ticket="T-1", payload={
            "requester": "aaron", "scope_paths": ["sa/"],
            "rules_in_force": ["no-delete"], "expires_at": "2026-11-06T02:00:00Z",
        })
        row = snapshot(self.home)["mandates"]["T-1"]
        self.assertEqual(row["scope_paths"], ["sa/"])
        self.assertEqual(row["rules_in_force"], ["no-delete"])
        self.assertFalse(row["revoked"])
        self.append("mandate.revoked", actor="engine", ticket="T-1", payload={"reason": "done"})
        self.assertTrue(snapshot(self.home)["mandates"]["T-1"]["revoked"])

    def test_thread_messages_accumulate_in_order(self):
        self.append("thread.opened", ticket="T-1", payload={"thread": "th-1"})
        self.append("thread.message", ticket="T-1",
                    payload={"thread": "th-1", "text": "one", "actor": "router"})
        self.append("thread.message", ticket="T-1",
                    payload={"thread": "th-1", "text": "two", "actor": "worker"})
        row = snapshot(self.home)["threads"]["th-1"]
        self.assertEqual(row["ticket"], "T-1")
        self.assertEqual([m["text"] for m in row["messages"]], ["one", "two"])
        self.assertEqual([m["actor"] for m in row["messages"]], ["router", "worker"])

    def test_sub_spawned(self):
        self.append("sub.spawned", actor="engine", ticket="T-1",
                    payload={"sub": "sub-1", "parent": "w1", "role": "scout"})
        row = snapshot(self.home)["subs"]["sub-1"]
        self.assertEqual(row["parent"], "w1")
        self.assertEqual(row["role"], "scout")
        self.assertEqual(row["state"], "spawned")

    def test_assignment_created(self):
        self.append("assignment.created", ticket="T-1",
                    payload={"owner": "w1", "reason": "scope"})
        row = snapshot(self.home)["assignments"]["T-1"]
        self.assertEqual(row["owner"], "w1")
        self.assertEqual(row["reason"], "scope")

    def test_outbox_enqueued_delivered_failed(self):
        self.append("outbox.enqueued", actor="code", ticket="T-1",
                    payload={"event_id": "ev-1", "owner": "w1"})
        self.append("outbox.delivered", actor="code", ticket="T-1", payload={
            "event_id": "ev-1", "owner": "w1",
            "receipt": {"path": "/tmp/p", "sha256": "0" * 64, "at": "2026-11-05T02:00:05Z"},
        })
        self.append("outbox.failed", actor="code", ticket="T-1", payload={
            "event_id": "ev-2", "owner": "w1", "attempt": 2, "error": "EACCES",
        })
        outbox = snapshot(self.home)["outbox"]
        self.assertEqual(outbox["ev-1"]["state"], "delivered")
        self.assertEqual(outbox["ev-1"]["delivered_at"], "2026-11-05T02:00:05Z")
        self.assertEqual(outbox["ev-1"]["attempts"], 1)
        self.assertEqual(outbox["ev-2"]["state"], "failed")
        self.assertEqual(outbox["ev-2"]["attempts"], 2)
        self.assertEqual(outbox["ev-2"]["last_error"], "EACCES")

    def test_ruling_recorded(self):
        self.append("ruling.recorded", ticket="T-1",
                    payload={"ruling": "allow", "rationale": "in scope"})
        rulings = snapshot(self.home)["rulings"]
        self.assertEqual(len(rulings), 1)
        row = next(iter(rulings.values()))
        self.assertEqual(row["ruling"], "allow")
        self.assertEqual(row["rationale"], "in scope")
        self.assertEqual(row["actor"], "router")
        self.assertEqual(row["ticket"], "T-1")

    def test_usage_accumulates_per_tier(self):
        self.append("usage.recorded", actor="worker", ticket="T-1",
                    payload={"tier": "t1", "tokens": 100, "calls": 1})
        self.append("usage.recorded", actor="worker", ticket="T-1",
                    payload={"tier": "t1", "tokens": 50, "calls": 2})
        self.append("usage.recorded", actor="worker", ticket="T-1",
                    payload={"tier": "t2", "tokens": 7, "calls": 1})
        row = snapshot(self.home)["usage"]["T-1"]
        self.assertEqual(row["by_tier"]["t1"], {"tokens": 150, "calls": 3})
        self.assertEqual(row["by_tier"]["t2"], {"tokens": 7, "calls": 1})
        self.assertEqual(row["total_tokens"], 157)

    def test_claim_recorded(self):
        self.append("claim.recorded", actor="worker", ticket="T-1", payload={
            "claim": "tests pass", "evidence_command": "python3 -m unittest",
        })
        claims = snapshot(self.home)["claims"]
        self.assertEqual(len(claims), 1)
        row = next(iter(claims.values()))
        self.assertEqual(row["claim"], "tests pass")
        self.assertEqual(row["evidence_command"], "python3 -m unittest")
        self.assertEqual(row["ticket"], "T-1")

    def test_fold_is_byte_identical_across_replays(self):
        for type_ in EVENT_TYPES:
            self.append(type_, actor="engine", ticket="T-1", payload={"tier": "t1"})
        first = canonical(fold(read_events(self.home)))
        second = canonical(fold(read_events(self.home)))
        self.assertEqual(first, second)
        self.assertEqual(sha256_of(json.loads(first)), sha256_of(json.loads(second)))

    def test_fold_does_not_mutate_the_log(self):
        self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        before = (self.home / "events.jsonl").read_bytes()
        snapshot(self.home)
        self.assertEqual((self.home / "events.jsonl").read_bytes(), before)

    def test_query_filters_rows(self):
        self.append("ticket.created", ticket="T-1", payload={"title": "a"})
        self.append("ticket.created", ticket="T-2", payload={"title": "b"})
        self.append("ticket.assigned", ticket="T-2", payload={"owner": "w1", "reason": "r"})
        state = snapshot(self.home)
        self.assertEqual(len(query(state, "tickets")), 2)
        rows = query(state, "tickets", ["state=assigned"])
        self.assertEqual([r["id"] for r in rows], ["T-2"])
        self.assertEqual(query(state, "tickets", ["state=assigned", "owner=w1"]), rows)
        self.assertEqual(query(state, "tickets", ["state=nope"]), [])

    def test_query_rejects_unknown_table_and_bad_where(self):
        state = snapshot(self.home)
        with self.assertRaises(StoreError):
            query(state, "nope")
        with self.assertRaises(StoreError):
            query(state, "tickets", ["noequals"])

    def test_table_rejects_unknown_name(self):
        with self.assertRaises(StoreError):
            table(snapshot(self.home), "nope")


class CliTest(TempHomeCase):
    def test_append_prints_event_id(self):
        proc = run_cli(
            ["append", "--type", "ticket.created", "--actor", "router",
             "--ticket", "T-1", "--at", "2026-11-05T02:00:00Z",
             "--payload", '{"title":"a"}'],
            self.home,
        )
        self.assertEqual(proc.stdout.strip(), "ev-0000000000000001")

    def test_tables_prints_all_ten_in_order(self):
        proc = run_cli(["tables"], self.home)
        self.assertEqual(proc.stdout.split(), list(TABLE_ORDER))

    def test_state_prints_canonical_json(self):
        run_cli(["append", "--type", "ticket.created", "--actor", "router",
                 "--ticket", "T-1", "--payload", '{"title":"a"}'], self.home)
        proc = run_cli(["state"], self.home)
        text = proc.stdout.strip()
        self.assertEqual(text, canonical(json.loads(text)))
        self.assertIn('"tickets"', text)

    def test_state_table_prints_one_table(self):
        run_cli(["append", "--type", "ticket.created", "--actor", "router",
                 "--ticket", "T-1", "--payload", '{"title":"a"}'], self.home)
        proc = run_cli(["state", "--table", "tickets"], self.home)
        self.assertEqual(json.loads(proc.stdout), snapshot(self.home)["tickets"])

    def test_query_prints_canonical_array(self):
        run_cli(["append", "--type", "ticket.created", "--actor", "router",
                 "--ticket", "T-1", "--payload", '{"title":"a"}'], self.home)
        proc = run_cli(["query", "--table", "tickets", "--where", "id=T-1"], self.home)
        rows = json.loads(proc.stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "T-1")
        self.assertEqual(proc.stdout.strip(), canonical(rows))

    def test_log_prints_raw_lines(self):
        run_cli(["append", "--type", "ticket.created", "--actor", "router",
                 "--ticket", "T-1", "--payload", '{"title":"a"}'], self.home)
        proc = run_cli(["log"], self.home)
        self.assertEqual(proc.stdout, (self.home / "events.jsonl").read_text(encoding="utf-8"))

    def test_bad_actor_exits_nonzero(self):
        proc = run_cli(["append", "--type", "ticket.created", "--actor", "nope"],
                       self.home, check=False)
        self.assertNotEqual(proc.returncode, 0)

    def test_bad_payload_exits_nonzero(self):
        proc = run_cli(["append", "--type", "ticket.created", "--actor", "router",
                        "--payload", "not-json"], self.home, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("payload", proc.stderr)

    def test_selftest_passes_and_prints_both_hashes(self):
        proc = run_cli(["selftest"], self.home)
        out = proc.stdout
        self.assertIn("PASS", out)
        hashes = [line.split(": ", 1)[1] for line in out.splitlines()
                  if line.startswith("state A sha256:") or line.startswith("state B sha256:")]
        self.assertEqual(len(hashes), 2)
        self.assertEqual(hashes[0], hashes[1])
        self.assertEqual(len(hashes[0]), 64)

    def test_selftest_does_not_touch_the_caller_home(self):
        run_cli(["selftest"], self.home)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_cli_writes_only_inside_sa_home(self):
        repo_var = REPO_ROOT / "sa" / "var"
        existed = repo_var.exists()
        run_cli(["append", "--type", "ticket.created", "--actor", "router",
                 "--ticket", "T-1", "--payload", '{"title":"a"}'], self.home)
        self.assertTrue((self.home / "events.jsonl").exists())
        if not existed:
            self.assertFalse(repo_var.exists(), "CLI wrote into the repo default SA_HOME")


class SaHomeTest(unittest.TestCase):
    def test_env_override_wins(self):
        old = os.environ.get("SA_HOME")
        try:
            os.environ["SA_HOME"] = "/tmp/sa-home-test"
            self.assertEqual(str(sa_home()), "/tmp/sa-home-test")
        finally:
            if old is None:
                os.environ.pop("SA_HOME", None)
            else:
                os.environ["SA_HOME"] = old

    def test_default_is_repo_sa_var(self):
        old = os.environ.pop("SA_HOME", None)
        try:
            self.assertEqual(sa_home(), REPO_ROOT / "sa" / "var")
        finally:
            if old is not None:
                os.environ["SA_HOME"] = old


if __name__ == "__main__":
    unittest.main()
