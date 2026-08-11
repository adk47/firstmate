#!/usr/bin/env python3

import fcntl
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("uvn_under30_cron", SCRIPTS / "uvn-under30-cron.py")
cron = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cron)

CR_ID = "11111111-1111-4111-8111-111111111111"
PROFILE_ID = "profile-1"


def task():
    action = {
        "action_type": "credit-verify",
        "customer_profile_id": PROFILE_ID,
        "details": {"pending_credits": [{"cr_id": CR_ID}]},
    }
    return {
        "id": "ticket-1",
        "description": f"---ACTION-REQUEST---\n{json.dumps(action)}\n---END-ACTION-REQUEST---",
        "status": {"status": "to do"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
    }


def credit(status="user_verification_needed"):
    return {
        "id": CR_ID,
        "profileId": PROFILE_ID,
        "status": status,
        "spotifyTrackId": "spotify-1",
        "verificationData": {"rule_risk_percent": {}},
    }


class CronOrchestrationTests(unittest.TestCase):
    def run_main(self, fraud_ids, rows, unresolved_ids=None):
        output = io.StringIO()
        with (
            patch.object(cron, "credit_write_lock", return_value=nullcontext()),
            patch.object(cron, "load_fraud_ids", return_value=fraud_ids),
            patch.object(cron, "load_unresolved_ids", return_value=unresolved_ids or set()),
            patch.object(cron, "list_todo_tickets", return_value=[task()]),
            patch.object(cron, "get_task_and_comments", return_value=(task(), [])),
            patch.object(cron, "list_profile_requests", side_effect=rows),
            patch.object(cron, "spotify_lookup", return_value={"found": True, "track": {"popularity": 29}}),
            patch.object(cron, "approve_chunk", return_value={CR_ID}) as approve,
            patch.object(cron, "update_ticket") as update,
            redirect_stdout(output),
        ):
            rc = cron.main()
        return rc, output.getvalue(), approve, update

    def test_approves_exact_ticket_id_then_resolves_after_authoritative_state(self):
        rc, output, approve, update = self.run_main(
            set(),
            [
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit("approved")},
            ],
        )
        self.assertEqual(rc, 0)
        approve.assert_called_once()
        self.assertEqual(approve.call_args.args[2], [CR_ID])
        update.assert_called_once()
        self.assertTrue(update.call_args.args[3])
        self.assertIn("1 approval(s) confirmed by readback", output)
        self.assertIn("rejects: 0", output)

    def test_fraud_marker_prevents_approval_and_ticket_write(self):
        rc, output, approve, update = self.run_main(
            {CR_ID},
            [
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
            ],
        )
        self.assertEqual(rc, 0)
        approve.assert_not_called()
        update.assert_not_called()
        self.assertEqual(output.strip(), "NO_REPLY")

    def test_unresolved_partial_commit_keeps_ticket_open(self):
        rc, _, approve, update = self.run_main(
            set(),
            [
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit()},
                {CR_ID: credit("approved")},
            ],
            {CR_ID},
        )
        self.assertEqual(rc, 0)
        approve.assert_called_once()
        update.assert_called_once()
        self.assertFalse(update.call_args.args[3])


class SharedLockEntrypointTests(unittest.TestCase):
    def test_real_entrypoint_fails_before_external_boundaries_when_lock_is_held(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lock_path = tmp_path / "credit-status-writes.lock"
            boundary_calls = tmp_path / "boundary.calls"
            boundary_stub = tmp_path / "boundary-stub.sh"
            boundary_stub.write_text(
                "#!/usr/bin/env bash\n"
                'printf "called\\n" >> "$UVN_TEST_BOUNDARY_CALLS"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            boundary_stub.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "CV_CREDIT_WRITE_LOCK_PATH": str(lock_path),
                "CV_CREDIT_WRITE_LOCK_WAIT_SECS": "1",
                "MUSO_BIN": str(boundary_stub),
                "UVN_ADMIN_SCRIPT": str(boundary_stub),
                "UVN_STATUS_VERIFY": str(boundary_stub),
                "UVN_TEST_BOUNDARY_CALLS": str(boundary_calls),
                "UVN_FRAUD_ROOT": str(tmp_path / "fraud-runs"),
                "CV_FRAUD_ATTEMPT_PATH": str(tmp_path / "fraud-attempts.jsonl"),
                "UVN_AUDIT_ROOT": str(tmp_path / "audit"),
                "UVN_UNRESOLVED_PATH": str(tmp_path / "unresolved.json"),
            })

            with lock_path.open("a+", encoding="utf-8") as lock_handle:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(
                    [sys.executable, str(SCRIPTS / "uvn-under30-cron.py")],
                    capture_output=True,
                    text=True,
                    env=env,
                    timeout=5,
                    check=False,
                )

            self.assertEqual(result.returncode, 1)
            self.assertIn("timed out waiting for the shared credit-write lock", result.stdout)
            self.assertFalse(boundary_calls.exists())

    def test_invalid_lock_wait_fails_before_external_boundaries(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            boundary_calls = tmp_path / "boundary.calls"
            boundary_stub = tmp_path / "boundary-stub.sh"
            boundary_stub.write_text(
                "#!/usr/bin/env bash\n"
                'printf "called\\n" >> "$UVN_TEST_BOUNDARY_CALLS"\n'
                "exit 99\n",
                encoding="utf-8",
            )
            boundary_stub.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "CV_CREDIT_WRITE_LOCK_PATH": str(tmp_path / "credit-status-writes.lock"),
                "CV_CREDIT_WRITE_LOCK_WAIT_SECS": "0",
                "MUSO_BIN": str(boundary_stub),
                "UVN_TEST_BOUNDARY_CALLS": str(boundary_calls),
            })

            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "uvn-under30-cron.py")],
                capture_output=True,
                text=True,
                env=env,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("CV_CREDIT_WRITE_LOCK_WAIT_SECS must be a positive integer", result.stdout)
            self.assertFalse(boundary_calls.exists())


class ApprovalReadbackTests(unittest.TestCase):
    def test_non_2xx_partial_commit_is_persisted_and_reported(self):
        with (
            patch.object(cron, "audit"),
            patch.object(cron, "admin_raw", return_value={"http_status": 500, "body": {}}),
            patch.object(cron, "verify_status", return_value={CR_ID}),
            patch.object(cron, "mark_unresolved") as mark_unresolved,
        ):
            with self.assertRaises(cron.ApprovalAttemptError) as raised:
                cron.approve_chunk("run-1", "ticket-1", [CR_ID])

        self.assertEqual(raised.exception.confirmed_ids, {CR_ID})
        self.assertEqual(mark_unresolved.call_count, 2)
        self.assertIn("attempt started", mark_unresolved.call_args_list[0].args[2])

    def test_exact_2xx_and_readback_clears_prior_unresolved_state(self):
        response = {
            "http_status": 200,
            "body": {"data": {"updatedIds": [CR_ID]}},
        }
        with (
            patch.object(cron, "audit"),
            patch.object(cron, "admin_raw", return_value=response),
            patch.object(cron, "verify_status", return_value={CR_ID}),
            patch.object(cron, "mark_unresolved"),
            patch.object(cron, "clear_unresolved") as clear_unresolved,
        ):
            confirmed = cron.approve_chunk("run-1", "ticket-1", [CR_ID])

        self.assertEqual(confirmed, {CR_ID})
        clear_unresolved.assert_called_once_with("run-1", [CR_ID])

    def test_durable_unresolved_marker_precedes_admin_write(self):
        events = []

        def mark(*_args):
            events.append("mark")

        def write(*_args):
            events.append("write")
            raise cron.RunError("transport failed after request")

        with (
            patch.object(cron, "audit"),
            patch.object(cron, "mark_unresolved", side_effect=mark),
            patch.object(cron, "admin_raw", side_effect=write),
            patch.object(cron, "verify_status", return_value=set()),
        ):
            with self.assertRaises(cron.ApprovalAttemptError):
                cron.approve_chunk("run-1", "ticket-1", [CR_ID])

        self.assertEqual(events[:2], ["mark", "write"])

    def test_directory_fsync_failure_refuses_admin_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker_path = Path(tmp) / "unresolved.json"
            with (
                patch.object(cron, "UNRESOLVED_PATH", marker_path),
                patch.object(cron, "audit"),
                patch.object(cron.os, "fsync", side_effect=[None, OSError("directory fsync failed")]),
                patch.object(cron, "admin_raw") as admin_raw,
            ):
                with self.assertRaises(OSError):
                    cron.approve_chunk("run-1", "ticket-1", [CR_ID])

            admin_raw.assert_not_called()

    def test_malformed_readback_cannot_confirm_an_id(self):
        result = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout=json.dumps({
                "expected": "approved",
                "matched": 1,
                "mismatched": [{"actual": "rejected"}],
            }),
            stderr="",
        )
        with patch.object(cron.subprocess, "run", return_value=result):
            with self.assertRaises(cron.RunError):
                cron.verify_status([CR_ID])


class ClickUpBoundaryTests(unittest.TestCase):
    def test_comments_are_paginated_with_both_cursor_fields(self):
        first_page = [
            {"id": f"comment-{index}", "date": str(1000 - index)}
            for index in range(25)
        ]
        with patch.object(
            cron,
            "clickup",
            side_effect=[task(), {"comments": first_page}, {"comments": []}],
        ) as clickup:
            _, comments = cron.get_task_and_comments("ticket-1")

        self.assertEqual(comments, first_page)
        self.assertEqual(
            clickup.call_args_list[2].kwargs["query"],
            ["start=976", "start_id=comment-24"],
        )

    def test_unresolved_id_blocks_status_write_after_final_scope_reread(self):
        with (
            patch.object(cron, "audit"),
            patch.object(cron, "clickup") as clickup,
            patch.object(cron, "assert_ticket_scope"),
            patch.object(cron, "list_profile_requests", return_value={CR_ID: credit("approved")}),
            patch.object(cron, "load_unresolved_ids", return_value={CR_ID}),
        ):
            resolved = cron.update_ticket(
                "run-1",
                "ticket-1",
                "automation comment",
                True,
                PROFILE_ID,
                {CR_ID},
            )

        self.assertFalse(resolved)
        clickup.assert_called_once_with(
            "POST",
            "/task/ticket-1/comment",
            {"comment_text": "automation comment", "notify_all": False},
        )


if __name__ == "__main__":
    unittest.main()
