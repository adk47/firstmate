#!/usr/bin/env python3
"""Hermetic tests for render_validate.py; standard library only."""

import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
MODULE_PATH = HERE.parent / "render_validate.py"
SPEC = importlib.util.spec_from_file_location("render_validate", MODULE_PATH)
rv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rv)

NOW = "2026-09-09T12:04:00Z"


def stat_mode(path):
    return path.stat().st_mode & 0o777


def skill_document_text():
    root = HERE.parent.parent
    path = root / "SKILL.md"
    if not path.exists():
        path = root / "PROPOSAL.md"
    return path.read_text(encoding="utf-8")


def claim(cid="C-1"):
    return {
        "claim_id": cid,
        "status": "pending",
        "profile_id": "P-1",
        "profile_name": "Artist One",
        "profile_url": "https://credits.muso.ai/profile/P-1",
        "snapshot_profile_id": "P-1",
        "live_profile_id": "P-1",
        "snapshot_team_id": "T-1",
        "live_team_id": "T-1",
        "revalidated_at": "2026-09-09T12:03:30Z",
        "evidence_kinds": ["official_links", "representative_authorization"],
        "excluded_case_flags": [],
        "prior_verified_delivery": False,
    }


def recipient(rid="R-1", claims=None):
    return {
        "recipient_id": rid,
        "recipient_name": "Customer",
        "recipient_email": "customer@example.com",
        "mapping_verified": True,
        "route": "support_email",
        "intercom_conversation_id": None,
        "relevant_conversation_verified": False,
        "claims": claims or [claim()],
    }


def manifest(recipients=None):
    return {
        "schema_version": 1,
        "run_id": "run-1",
        "captured_at": "2026-09-09T12:00:00Z",
        "revalidated_at": "2026-09-09T12:03:30Z",
        "skipped_counts": {
            "no_longer_pending": 2,
            "special_resolution": 1,
        },
        "recipients": [recipient()] if recipients is None else recipients,
    }


def audit(event, **extra):
    audit_label = extra.pop("audit_id", "A-1")
    communication_id = extra.pop(
        "communication_id",
        hashlib.sha256(audit_label.encode("utf-8")).hexdigest(),
    )
    attempt_number = extra.pop("attempt_number", 1)
    row = {
        "schema_version": 1,
        "event": event,
        "run_id": "old-run",
        "communication_id": communication_id,
        "attempt_number": attempt_number,
        "audit_id": rv.deterministic_attempt_audit_id(
            communication_id, attempt_number
        ),
        "timestamp": "2026-09-09T11:00:00Z",
        "recipient_id": "R-1",
        "claim_ids": ["C-1"],
        "route": "support_email",
        "content_hash": "a" * 64,
    }
    row.update(extra)
    return row


def private_plan(run_id, recipient_id, claim_ids, route="support_email"):
    subject = rv.communication_subject(len(claim_ids))
    message = f"Private outreach for {recipient_id}\n"
    content_hash = hashlib.sha256((subject + "\n" + message).encode("utf-8")).hexdigest()
    destination = (
        "private@example.com" if route == "support_email" else "CONV-1"
    )
    communication_id = rv.deterministic_communication_id(
        run_id, recipient_id, sorted(claim_ids), route, content_hash, destination
    )
    return {
        "schema_version": 1,
        "run_id": run_id,
        "revalidated_at": "2026-09-09T12:03:30Z",
        "oldest_revalidated_at": "2026-09-09T12:03:30Z",
        "max_revalidation_age_seconds": 300,
        "skipped_counts": {"no_longer_pending": 2},
        "communications": [{
            "communication_id": communication_id,
            "subject": subject,
            "recipient_id": recipient_id,
            "route": route,
            "intercom_conversation_id": None if route == "support_email" else "CONV-1",
            "recipient_email": "private@example.com" if route == "support_email" else None,
            "claim_ids": sorted(claim_ids),
            "content_hash": content_hash,
            "message": message,
        }],
    }


def write_private_plan(root, plan):
    with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
        path = rv.prepare_plan_path(plan["run_id"])
        rv.atomic_write_plan(path, json.dumps(plan, sort_keys=True) + "\n")
    return f"state/runs/{plan['run_id']}/plan.json"


def subprocess_command(root, *arguments):
    wrapper = """
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("reserve_subprocess", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.APPLIED_SKILL_DIR = Path(sys.argv[2])
sys.argv = [sys.argv[1]] + sys.argv[3:]
raise SystemExit(module.main())
"""
    return [
        sys.executable,
        "-c",
        wrapper,
        str(MODULE_PATH),
        str(root),
        *arguments,
    ]


class Tests(unittest.TestCase):
    def validate(self, value, rows=None):
        return rv.validate_manifest(
            value, rows or [], rv.parse_utc(NOW, "now"), 300
        )

    def assert_closed(self, value, text, rows=None):
        with self.assertRaisesRegex(rv.ValidationError, text):
            self.validate(value, rows)

    def test_valid_and_grouped_render(self):
        value = manifest([recipient(claims=[claim("C-2"), claim("C-1")])])
        recipients = self.validate(value)
        rendered = rv.render_recipient(
            recipients[0],
            "{recipient_name}|{claim_plural}|{claim_object}\n{claim_blocks}\n{pending_sentence}",
        )
        self.assertEqual(rendered.count("Claim C-1"), 1)
        self.assertEqual(rendered.count("Claim C-2"), 1)
        self.assertLess(rendered.index("Claim C-1"), rendered.index("Claim C-2"))

    def test_duplicate_claim_ids_fail(self):
        value = manifest([recipient(claims=[claim("C-1"), claim("C-1")])])
        self.assert_closed(value, "duplicate claim id")

    def test_duplicate_recipients_fail(self):
        value = manifest([recipient(), recipient()])
        self.assert_closed(value, "duplicate recipient")

    def test_claim_recipient_ambiguity_fails(self):
        value = manifest([recipient("R-1"), recipient("R-2")])
        self.assert_closed(value, "claim-to-recipient ambiguity")

    def test_non_pending_fails(self):
        value = manifest()
        value["recipients"][0]["claims"][0]["status"] = "approved"
        self.assert_closed(value, "not pending")

    def test_missing_url_fails(self):
        value = manifest()
        value["recipients"][0]["claims"][0]["profile_url"] = ""
        self.assert_closed(value, "missing profile URL")

    def test_excluded_flag_fails(self):
        value = manifest()
        value["recipients"][0]["claims"][0]["excluded_case_flags"] = ["contested_cross_team"]
        self.assert_closed(value, "excluded-case flag")

    def test_live_revalidation_identifiers_are_required_nonempty_strings(self):
        fields = (
            "profile_id", "snapshot_profile_id", "live_profile_id",
            "snapshot_team_id", "live_team_id",
        )
        for field in fields:
            for invalid in (None, "", 7):
                with self.subTest(field=field, invalid=invalid):
                    value = manifest()
                    if invalid is None:
                        del value["recipients"][0]["claims"][0][field]
                    else:
                        value["recipients"][0]["claims"][0][field] = invalid
                    self.assert_closed(value, field)

    def test_excluded_case_flags_is_required_and_must_be_a_list(self):
        for invalid in (None, "contested_cross_team", {}):
            with self.subTest(invalid=invalid):
                value = manifest()
                if invalid is None:
                    del value["recipients"][0]["claims"][0]["excluded_case_flags"]
                else:
                    value["recipients"][0]["claims"][0]["excluded_case_flags"] = invalid
                self.assert_closed(value, "excluded_case_flags")

    def test_profile_or_team_mismatch_fails(self):
        value = manifest()
        value["recipients"][0]["claims"][0]["live_team_id"] = "T-2"
        self.assert_closed(value, "team mismatch")

    def test_prior_delivery_fails(self):
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id="MSG-1", outcome="accepted"),
            audit("verification", provider_id="MSG-1", verified_status="delivered"),
        ]
        self.assert_closed(manifest(), "prior verified delivery", rows)

    def test_unknown_without_reconciliation_fails(self):
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id=None, outcome="unknown"),
            audit("verification", provider_id=None, verified_status="unknown"),
        ]
        self.assert_closed(manifest(), "active or unresolved", rows)

    def test_unknown_with_not_delivered_reconciliation_allows_retry(self):
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id=None, outcome="unknown"),
            audit("verification", provider_id=None, verified_status="unknown"),
            audit("reconciliation", provider_id=None, history_source="gmail",
                  result="not_delivered"),
        ]
        self.validate(manifest(), rows)

    def test_duplicate_provider_id_fails(self):
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id="MSG-1", outcome="accepted"),
            audit("pre_send", audit_id="A-2"),
            audit("provider_result", audit_id="A-2",
                  provider_id="MSG-1", outcome="accepted"),
        ]
        with self.assertRaisesRegex(rv.ValidationError, "duplicate provider_id"):
            rv.validate_ledger(rows)

    def test_mismatched_provider_result_fails(self):
        rows = [
            audit("pre_send"),
            dict(audit("provider_result", provider_id="MSG-1", outcome="accepted"),
                 content_hash="b" * 64),
        ]
        with self.assertRaisesRegex(rv.ValidationError, "mismatched provider result"):
            rv.validate_ledger(rows)

    def test_malformed_ledger_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir(mode=0o700)
            os.chmod(state, 0o700)
            path = state / "outreach-ledger.jsonl"
            path.write_text("{bad json}\n", encoding="utf-8")
            os.chmod(path, 0o600)
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                with self.assertRaisesRegex(rv.ValidationError, "malformed ledger"):
                    rv.load_ledger("state/outreach-ledger.jsonl")

    def test_ledger_permissions_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir(mode=0o700)
            os.chmod(state, 0o700)
            path = state / "outreach-ledger.jsonl"
            path.write_text("", encoding="utf-8")
            os.chmod(path, 0o644)
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                with self.assertRaisesRegex(rv.ValidationError, "permissions"):
                    rv.load_ledger("state/outreach-ledger.jsonl")

    def test_private_state_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real_state = root / "real-state"
            real_state.mkdir(mode=0o700)
            os.chmod(real_state, 0o700)
            (root / "state").symlink_to(real_state, target_is_directory=True)
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                with self.assertRaisesRegex(rv.ValidationError, "must not be a symlink"):
                    rv.ensure_state_directory()

    def test_ledger_plan_and_lock_symlinks_are_rejected(self):
        cases = ("ledger", "plan", "lock")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                    plan = private_plan("run-1", "R-1", ["C-1"])
                    plan_path = rv.prepare_plan_path("run-1")
                    if case == "ledger":
                        target = root / "ledger-target"
                        target.write_text("", encoding="utf-8")
                        os.chmod(target, 0o600)
                        (root / "state" / "outreach-ledger.jsonl").symlink_to(target)
                        with self.assertRaisesRegex(rv.ValidationError, "must not be a symlink"):
                            rv.ensure_ledger("state/outreach-ledger.jsonl")
                    elif case == "plan":
                        target = root / "plan-target"
                        target.write_text(json.dumps(plan), encoding="utf-8")
                        os.chmod(target, 0o600)
                        plan_path.symlink_to(target)
                        with self.assertRaisesRegex(rv.ValidationError, "must not be a symlink"):
                            rv.load_private_plan("state/runs/run-1/plan.json")
                    else:
                        target = root / "lock-target"
                        target.write_text("", encoding="utf-8")
                        os.chmod(target, 0o600)
                        (root / "state" / "outreach.lock").symlink_to(target)
                        with self.assertRaisesRegex(rv.ValidationError, "must not be a symlink"):
                            rv.ensure_lock_file()

    def test_complete_run_requires_result_and_verification(self):
        with self.assertRaisesRegex(rv.ValidationError, "incomplete audit sequence"):
            rv.validate_ledger([audit("pre_send", run_id="run-1")], "run-1")



    def test_only_canonical_profile_urls_are_accepted(self):
        rv.validate_url("https://credits.muso.ai/profile/P-1")
        invalid = [
            "http://credits.muso.ai/profile/P-1",
            "https://credits.muso.ai/profile/",
            "https://credits.muso.ai/profile",
            "https://credits.muso.ai.evil.example/profile/P-1",
            "https://evilcredits.muso.ai/profile/P-1",
            "https://credits.muso.ai:443/profile/P-1",
            "https://user@credits.muso.ai/profile/P-1",
            "https://credits.muso.ai/profile/P-1?x=1",
            "https://credits.muso.ai/profile/P-1#fragment",
            "https://CREDITS.muso.ai/profile/P-1",
            "https://credits.muso.ai/profile/P-1/extra",
            "https://credits.muso.ai/profile/P 1",
        ]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(rv.ValidationError):
                    rv.validate_url(value)

    def test_exact_relative_state_paths(self):
        self.assertEqual(rv.LEDGER_RELATIVE_PATH.as_posix(), "state/outreach-ledger.jsonl")
        self.assertEqual(rv.LOCK_RELATIVE_PATH.as_posix(), "state/outreach.lock")
        self.assertEqual(
            (rv.RUNS_RELATIVE_PATH / "run-1" / "plan.json").as_posix(),
            "state/runs/run-1/plan.json",
        )

    def test_atomic_plan_write_uses_exact_modes_and_is_immutable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                path = rv.prepare_plan_path("run-1")
                with mock.patch.object(rv.os, "replace", wraps=rv.os.replace) as replace:
                    rv.atomic_write_plan(path, "{\"version\":1}\n")
                    rv.atomic_write_plan(path, "{\"version\":1}\n")
                    with self.assertRaisesRegex(rv.ValidationError, "immutable"):
                        rv.atomic_write_plan(path, "{\"version\":2}\n")
                replace.assert_called_once()
                self.assertEqual(stat_mode(root / "state"), 0o700)
                self.assertEqual(stat_mode(root / "state" / "runs"), 0o700)
                self.assertEqual(stat_mode(root / "state" / "runs" / "run-1"), 0o700)
                self.assertEqual(stat_mode(path), 0o600)
                self.assertEqual(path.read_text(encoding="utf-8"), "{\"version\":1}\n")

    def test_broader_existing_state_directory_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir(mode=0o700)
            runs = state / "runs"
            runs.mkdir(mode=0o700)
            os.chmod(runs, 0o755)
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                with self.assertRaisesRegex(rv.ValidationError, "permissions must be 0700"):
                    rv.prepare_plan_path("run-1")

    def test_non_0600_existing_plan_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                path = rv.prepare_plan_path("run-1")
                path.write_text("old\n", encoding="utf-8")
                os.chmod(path, 0o644)
                with self.assertRaisesRegex(rv.ValidationError, "permissions must be 0600"):
                    rv.atomic_write_plan(path, "new\n")

    def test_noncanonical_plan_output_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", Path(directory)):
                with self.assertRaisesRegex(rv.ValidationError, "plan path must be exactly"):
                    rv.prepare_plan_path("run-1", "plan.json")

    def test_plan_has_deterministic_communication_ids_and_singular_plural_subjects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            template_path = root / "template.txt"
            first = recipient("R-1", [claim("C-1")])
            second_claims = [claim("C-3"), claim("C-2")]
            second = recipient("R-2", second_claims)
            manifest_path.write_text(
                json.dumps(manifest([first, second])), encoding="utf-8"
            )
            template_path.write_text(
                "{recipient_name}\n{claim_plural}\n{claim_object}\n"
                "{claim_blocks}\n{pending_sentence}\n",
                encoding="utf-8",
            )
            args = SimpleNamespace(
                manifest=str(manifest_path),
                ledger="state/outreach-ledger.jsonl",
                template=str(template_path),
                output=None,
                now=NOW,
                max_revalidation_age_seconds=300,
            )
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout"
            ):
                rv.cmd_plan(args)
                first_plan = json.loads(
                    (root / "state" / "runs" / "run-1" / "plan.json").read_text(
                        encoding="utf-8"
                    )
                )
                rv.cmd_plan(args)
                second_plan = json.loads(
                    (root / "state" / "runs" / "run-1" / "plan.json").read_text(
                        encoding="utf-8"
                    )
                )
            self.assertEqual(first_plan, second_plan)
            by_recipient = {
                item["recipient_id"]: item for item in first_plan["communications"]
            }
            self.assertEqual(
                by_recipient["R-1"]["subject"],
                "Evidence needed for your Muso profile claim",
            )
            self.assertEqual(
                by_recipient["R-2"]["subject"],
                "Evidence needed for your Muso profile claims",
            )
            for item in by_recipient.values():
                self.assertRegex(item["communication_id"], r"^[0-9a-f]{64}$")
                self.assertNotIn("audit_id", item)

    def test_template_requests_every_profile_relationship_without_deadline(self):
        template_path = HERE.parent.parent / "templates" / "profile-claim-evidence.txt"
        template = template_path.read_text(encoding="utf-8")
        rendered = rv.render_recipient(recipient(), template)
        self.assertIn("confirm your relationship to every profile listed above", rendered)
        self.assertIn("This claim will stay pending while we review your evidence.", rendered)
        self.assertNotIn("deadline", rendered.lower())
        punctuation = {character for character in template if not character.isalnum() and not character.isspace()}
        self.assertTrue(all(ord(character) < 128 for character in punctuation))


    def test_append_row_rejects_pre_send(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = SimpleNamespace(
                ledger="state/outreach-ledger.jsonl",
                row_json=json.dumps(audit("pre_send")),
            )
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                with self.assertRaisesRegex(rv.ValidationError, "reserve"):
                    rv.cmd_append(args)
                self.assertEqual(
                    (root / "state" / "outreach-ledger.jsonl").read_text(encoding="utf-8"),
                    "",
                )

    def test_overlapping_reservations_are_process_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first_path = write_private_plan(
                root, private_plan("run-a", "R-A", ["OVERLAP"])
            )
            second_path = write_private_plan(
                root, private_plan("run-b", "R-B", ["OVERLAP", "OTHER"])
            )
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
            commands = [
                subprocess_command(
                    root, "reserve", "--plan", first_path, "--recipient-id", "R-A",
                    "--now", NOW,
                ),
                subprocess_command(
                    root, "reserve", "--plan", second_path, "--recipient-id", "R-B",
                    "--now", NOW,
                ),
            ]
            processes = [
                subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, env=env)
                for command in commands
            ]
            results = [process.communicate(timeout=10) for process in processes]
            self.assertEqual(sorted(process.returncode for process in processes), [0, 2])
            for stdout, _ in results:
                self.assertNotIn("OVERLAP", stdout)
                self.assertNotIn("R-A", stdout)
                self.assertNotIn("R-B", stdout)
            ledger = root / "state" / "outreach-ledger.jsonl"
            rows = [json.loads(line) for line in ledger.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["event"], "pre_send")

    def test_same_run_retry_gets_new_attempt_identity_and_active_duplicate_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan_path = write_private_plan(
                root, private_plan("run-1", "R-1", ["C-1"])
            )
            reserve_args = SimpleNamespace(
                plan=plan_path,
                recipient_id="R-1",
                ledger="state/outreach-ledger.jsonl",
                now=NOW,
                max_revalidation_age_seconds=300,
            )
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", io.StringIO()
            ):
                rv.cmd_reserve(reserve_args)
                ledger_path = root / "state" / "outreach-ledger.jsonl"
                first = json.loads(ledger_path.read_text(encoding="utf-8").splitlines()[0])
                correlation = {
                    key: first[key]
                    for key in rv.CORRELATION
                }
                for row in (
                    dict(correlation, schema_version=1, event="provider_result",
                         timestamp="2026-09-09T12:05:00Z", provider_id=None,
                         outcome="unknown"),
                    dict(correlation, schema_version=1, event="verification",
                         timestamp="2026-09-09T12:06:00Z", provider_id=None,
                         verified_status="unknown"),
                    dict(correlation, schema_version=1, event="reconciliation",
                         timestamp="2026-09-09T12:07:00Z", provider_id=None,
                         history_source="gmail", result="not_delivered"),
                ):
                    rv.cmd_append(SimpleNamespace(
                        ledger="state/outreach-ledger.jsonl",
                        row_json=json.dumps(row),
                    ))
                rv.cmd_reserve(reserve_args)
                rows = [
                    json.loads(line)
                    for line in ledger_path.read_text(encoding="utf-8").splitlines()
                ]
                presends = [row for row in rows if row["event"] == "pre_send"]
                self.assertEqual([row["attempt_number"] for row in presends], [1, 2])
                self.assertEqual(
                    presends[0]["communication_id"], presends[1]["communication_id"]
                )
                self.assertNotEqual(presends[0]["audit_id"], presends[1]["audit_id"])
                before_duplicate = ledger_path.read_bytes()
                with self.assertRaisesRegex(rv.ValidationError, "active attempt"):
                    rv.cmd_reserve(reserve_args)
                self.assertEqual(ledger_path.read_bytes(), before_duplicate)

    def test_latest_attempt_controls_retry_eligibility(self):
        old = [
            audit("pre_send", audit_id="A-old"),
            audit("provider_result", audit_id="A-old", provider_id=None, outcome="unknown"),
            audit("verification", audit_id="A-old", provider_id=None,
                  verified_status="unknown"),
            audit("reconciliation", audit_id="A-old", provider_id=None,
                  history_source="gmail", result="not_delivered"),
        ]
        newer = [
            audit("pre_send", audit_id="A-new"),
            audit("provider_result", audit_id="A-new", provider_id=None, outcome="failed"),
            audit("verification", audit_id="A-new", provider_id=None,
                  verified_status="not_delivered"),
        ]
        state = rv.validate_ledger(old + newer)
        self.assertFalse(state["latest_attempt_by_claim"]["C-1"]["retryable"])
        resolved = newer + [
            audit("reconciliation", audit_id="A-new", provider_id=None,
                  history_source="gmail", result="not_delivered")
        ]
        state = rv.validate_ledger(old + resolved)
        self.assertTrue(state["latest_attempt_by_claim"]["C-1"]["retryable"])

    def test_delivered_attempt_is_never_retryable_after_contradictory_reconciliation(self):
        # An authoritative delivered verification followed by a contradictory
        # not_delivered reconciliation must not read as BOTH. cmd_reserve
        # consults `retryable` before `delivered`, so the contradiction would
        # let an already-delivered claim be reserved and the customer
        # contacted a second time.
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id="MSG-1", outcome="accepted"),
            audit("verification", provider_id="MSG-1", verified_status="delivered"),
            audit("reconciliation", provider_id="MSG-1", history_source="gmail",
                  result="not_delivered"),
        ]
        state = rv.validate_ledger(rows)
        attempt = state["latest_attempt_by_claim"]["C-1"]
        self.assertTrue(attempt["delivered"])
        self.assertFalse(attempt["retryable"])
        self.assertEqual(attempt["status"], "delivered")
        self.assertFalse(attempt["active"])

    def test_malformed_destinations_are_rejected_at_manifest_validation(self):
        # Destinations were accepted on truthiness, so a blank-but-truthy email
        # or a numeric conversation id passed planning and reservation, and the
        # provider only rejected them AFTER pre_send was committed — leaving the
        # claim stuck behind an active attempt.
        for overrides, expected in (
            ({"recipient_email": "   "}, "support email route is malformed"),
            ({"recipient_email": 42}, "support email route is malformed"),
            ({"recipient_email": "not-an-address"}, "support email route is malformed"),
            ({"recipient_email": "who@example"}, "support email route is malformed"),
            ({"recipient_email": "a b@example.com"}, "support email route is malformed"),
            # Surrounding whitespace: the untrimmed address would otherwise be
            # copied verbatim into the immutable plan and only rejected by the
            # provider after pre_send was committed.
            ({"recipient_email": " customer@example.com "}, "support email route is malformed"),
            ({"recipient_email": "customer@example.com "}, "support email route is malformed"),
            ({"recipient_email": " customer@example.com"}, "support email route is malformed"),
            ({"recipient_email": "customer@example.com\n"}, "support email route is malformed"),
            (
                {"route": "intercom_existing", "recipient_email": None,
                 "intercom_conversation_id": 12345,
                 "relevant_conversation_verified": True},
                "Intercom conversation relevance is not verified",
            ),
            (
                {"route": "intercom_existing", "recipient_email": None,
                 "intercom_conversation_id": "  ",
                 "relevant_conversation_verified": True},
                "Intercom conversation relevance is not verified",
            ),
        ):
            with self.subTest(**overrides):
                self.assert_closed(
                    manifest([{**recipient(), **overrides}]), expected, []
                )

    def test_reserve_refuses_a_plan_whose_revalidation_has_gone_stale(self):
        # cmd_plan already enforces a caller-supplied freshness window on the
        # manifest, but reserve re-read the plan without it, so a claim that
        # became ineligible between plan and reserve still got a pre_send and
        # the customer was contacted after they stopped qualifying.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan_path = write_private_plan(root, private_plan("run-1", "R-1", ["C-1"]))
            base = dict(
                plan=plan_path,
                recipient_id="R-1",
                ledger="state/outreach-ledger.jsonl",
                max_revalidation_age_seconds=300,
            )
            ledger_path = root / "state" / "outreach-ledger.jsonl"
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", io.StringIO()
            ):
                # 17 minutes after revalidation: well past the window
                with self.assertRaisesRegex(rv.ValidationError, "stale"):
                    rv.cmd_reserve(SimpleNamespace(**base, now="2026-09-09T12:20:00Z"))
                self.assertFalse(ledger_path.exists() and ledger_path.read_text(encoding="utf-8").strip())
                # inside the window: the reservation is allowed
                rv.cmd_reserve(SimpleNamespace(**base, now=NOW))
                rows = ledger_path.read_text(encoding="utf-8").splitlines()
                self.assertEqual(len(rows), 1)
                self.assertEqual(json.loads(rows[0])["event"], "pre_send")

    def test_reserve_cannot_widen_the_freshness_window_the_plan_was_validated_with(self):
        # The window is the plan'"'"'s property, not the caller'"'"'s. If reserve
        # honoured its own larger --max-revalidation-age-seconds, anyone could
        # disable the staleness gate by passing a big number, which makes it
        # not a gate at all.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan_path = write_private_plan(root, private_plan("run-1", "R-1", ["C-1"]))
            base = dict(
                plan=plan_path,
                recipient_id="R-1",
                ledger="state/outreach-ledger.jsonl",
            )
            ledger_path = root / "state" / "outreach-ledger.jsonl"
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", io.StringIO()
            ):
                # a day-long override must NOT rescue a plan stale by the
                # 300s limit the plan was validated with
                with self.assertRaisesRegex(rv.ValidationError, "stale"):
                    rv.cmd_reserve(SimpleNamespace(
                        **base, now="2026-09-09T13:00:00Z",
                        max_revalidation_age_seconds=86400,
                    ))
                self.assertFalse(
                    ledger_path.exists()
                    and ledger_path.read_text(encoding="utf-8").strip()
                )
                # a NARROWER reserve-time value still applies
                with self.assertRaisesRegex(rv.ValidationError, "stale"):
                    rv.cmd_reserve(SimpleNamespace(
                        **base, now=NOW, max_revalidation_age_seconds=10,
                    ))
                self.assertFalse(
                    ledger_path.exists()
                    and ledger_path.read_text(encoding="utf-8").strip()
                )
                # within both limits it proceeds
                rv.cmd_reserve(SimpleNamespace(
                    **base, now=NOW, max_revalidation_age_seconds=300,
                ))
                self.assertEqual(
                    len(ledger_path.read_text(encoding="utf-8").splitlines()), 1
                )

    def test_plan_without_a_usable_freshness_limit_is_refused_cleanly(self):
        # Plans written before the freshness fields existed - including any
        # in flight on the server at deploy time - carry neither field. Reserve
        # must refuse them with a ValidationError, not crash on a KeyError or a
        # str/int comparison inside min().
        for mutate, expected in (
            (lambda p: p.pop("max_revalidation_age_seconds"), "max_revalidation_age_seconds"),
            (lambda p: p.update(max_revalidation_age_seconds="300"), "max_revalidation_age_seconds"),
            (lambda p: p.update(max_revalidation_age_seconds=0), "max_revalidation_age_seconds"),
            (lambda p: p.update(max_revalidation_age_seconds=-1), "max_revalidation_age_seconds"),
            (lambda p: p.update(max_revalidation_age_seconds=True), "max_revalidation_age_seconds"),
            (lambda p: p.pop("revalidated_at"), "revalidated_at"),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan = private_plan("run-1", "R-1", ["C-1"])
                mutate(plan)
                plan_path = write_private_plan(root, plan)
                args = SimpleNamespace(
                    plan=plan_path, recipient_id="R-1",
                    ledger="state/outreach-ledger.jsonl", now=NOW,
                    max_revalidation_age_seconds=300,
                )
                with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                    rv.sys, "stdout", io.StringIO()
                ):
                    with self.assertRaisesRegex(rv.ValidationError, expected):
                        rv.cmd_reserve(args)
                    ledger_path = root / "state" / "outreach-ledger.jsonl"
                    self.assertFalse(
                        ledger_path.exists()
                        and ledger_path.read_text(encoding="utf-8").strip()
                    )

    def test_swapping_only_the_destination_in_a_plan_is_refused(self):
        # content_hash covers subject and message, and the communication id
        # covered run/recipient/claims/route/content_hash - none of which is
        # the address. Editing only recipient_email therefore left every
        # integrity value intact, and the send would carry one customer's
        # claim ids and profile details to a different address.
        for route, field, replacement in (
            ("support_email", "recipient_email", "attacker@example.com"),
            ("intercom_existing", "intercom_conversation_id", "CONV-OTHER"),
        ):
            with self.subTest(route=route), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan = private_plan("run-1", "R-1", ["C-1"], route=route)
                plan["communications"][0][field] = replacement
                plan_path = write_private_plan(root, plan)
                args = SimpleNamespace(
                    plan=plan_path, recipient_id="R-1",
                    ledger="state/outreach-ledger.jsonl", now=NOW,
                    max_revalidation_age_seconds=300,
                )
                with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                    rv.sys, "stdout", io.StringIO()
                ):
                    with self.assertRaisesRegex(rv.ValidationError, "communication_id mismatch"):
                        rv.cmd_reserve(args)
                    ledger_path = root / "state" / "outreach-ledger.jsonl"
                    self.assertFalse(
                        ledger_path.exists()
                        and ledger_path.read_text(encoding="utf-8").strip()
                    )

    def test_plan_destination_must_be_actionable_not_merely_present(self):
        # The manifest rejects malformed destinations; the plan loader must
        # apply the same rule, or a hand-edited plan reintroduces them.
        for route, field, bad in (
            ("support_email", "recipient_email", " private@example.com "),
            ("support_email", "recipient_email", "not-an-address"),
            ("intercom_existing", "intercom_conversation_id", 12345),
        ):
            with self.subTest(route=route, bad=bad), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan = private_plan("run-1", "R-1", ["C-1"], route=route)
                plan["communications"][0][field] = bad
                plan_path = write_private_plan(root, plan)
                args = SimpleNamespace(
                    plan=plan_path, recipient_id="R-1",
                    ledger="state/outreach-ledger.jsonl", now=NOW,
                    max_revalidation_age_seconds=300,
                )
                with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                    rv.sys, "stdout", io.StringIO()
                ):
                    with self.assertRaisesRegex(rv.ValidationError, "destination"):
                        rv.cmd_reserve(args)

    def test_padded_conversation_ids_are_rejected_like_padded_emails(self):
        # The email path already rejects padding; the Intercom path only
        # rejected whitespace-ONLY values, so " 12345 " reached the plan
        # verbatim and the provider could only reject it after pre_send.
        for bad in (" CONV-1 ", "CONV-1 ", " CONV-1", "CONV-1\n"):
            with self.subTest(bad=bad):
                self.assert_closed(
                    manifest([{
                        **recipient(), "route": "intercom_existing",
                        "recipient_email": None, "intercom_conversation_id": bad,
                        "relevant_conversation_verified": True,
                    }]),
                    "Intercom conversation relevance is not verified",
                    [],
                )

    def test_reserve_measures_freshness_from_the_oldest_claim_not_the_root(self):
        # Planning validates every claim timestamp, but reserve only read the
        # plan root. A claim 299s old at planning plus 200s until reserve is
        # 499s of real staleness that the root-only check scored as 200s.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan = private_plan("run-1", "R-1", ["C-1"])
            plan["oldest_revalidated_at"] = "2026-09-09T11:55:00Z"  # 9 min before NOW
            plan_path = write_private_plan(root, plan)
            args = SimpleNamespace(
                plan=plan_path, recipient_id="R-1",
                ledger="state/outreach-ledger.jsonl", now=NOW,
                max_revalidation_age_seconds=300,
            )
            ledger_path = root / "state" / "outreach-ledger.jsonl"
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", io.StringIO()
            ):
                # root says 30s, oldest claim says 540s: the oldest wins
                with self.assertRaisesRegex(rv.ValidationError, "stale"):
                    rv.cmd_reserve(args)
                self.assertFalse(
                    ledger_path.exists()
                    and ledger_path.read_text(encoding="utf-8").strip()
                )

    # Class sweep: every user-supplied string the manifest copies verbatim into
    # the immutable plan or the customer-facing message must be rejected here
    # if it is not in canonical form. Padding is invisible in most renderings
    # and is otherwise only discovered downstream, at provider time, after
    # pre_send is committed. One case per field, not one per reported finding.
    def test_no_manifest_string_field_accepts_surrounding_whitespace(self):
        recipient_fields = ("recipient_id", "recipient_name")
        claim_fields = (
            "claim_id", "profile_name", "profile_id", "snapshot_profile_id",
            "live_profile_id", "snapshot_team_id", "live_team_id",
        )
        for field in recipient_fields:
            for bad in (" R-1 ", "R-1 ", " R-1"):
                with self.subTest(field=field, bad=bad):
                    self.assert_closed(
                        manifest([{**recipient(), field: bad}]),
                        "whitespace",
                        [],
                    )
        for field in claim_fields:
            for bad in (" X ", "X "):
                with self.subTest(field=field, bad=bad):
                    base = claim()
                    # the profile/team ids are cross-compared, so pad the whole
                    # equality group to prove padding is refused on its own
                    if field in ("profile_id", "snapshot_profile_id", "live_profile_id"):
                        mutated = {**base, "profile_id": bad,
                                   "snapshot_profile_id": bad, "live_profile_id": bad}
                    elif field in ("snapshot_team_id", "live_team_id"):
                        mutated = {**base, "snapshot_team_id": bad, "live_team_id": bad}
                    else:
                        mutated = {**base, field: bad}
                    self.assert_closed(
                        manifest([{**recipient(), "claims": [mutated]}]),
                        "whitespace",
                        [],
                    )

    def test_plan_loader_applies_the_same_canonical_string_rule(self):
        # Built so the identity check CANNOT be what rejects these: each plan
        # derives its communication_id from the padded value itself, so it is
        # internally consistent and only the canonical-string rule can fire.
        # Without this the test would pass for the wrong reason.
        cases = (
            ("recipient_id", private_plan("run-1", " R-1 ", ["C-1"]), " R-1 "),
            ("claim_ids", private_plan("run-1", "R-1", [" C-1 "]), "R-1"),
        )
        for field, plan, reserve_id in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan_path = write_private_plan(root, plan)
                args = SimpleNamespace(
                    plan=plan_path, recipient_id=reserve_id,
                    ledger="state/outreach-ledger.jsonl", now=NOW,
                    max_revalidation_age_seconds=300,
                )
                with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                    rv.sys, "stdout", io.StringIO()
                ):
                    with self.assertRaisesRegex(rv.ValidationError, "whitespace"):
                        rv.cmd_reserve(args)

    # Class: validation must reject everything the PROVIDER will reject. If the
    # provider is the real arbiter, anything reaching pre_send that it can
    # bounce is a bug, because the claim is then stranded behind an active
    # attempt. Whitespace was one instance; syntactic validity is the class.
    def test_email_contract_has_one_case_per_rule(self):
        # The contract is "reject anything SMTP will reject". One case per RULE
        # so the next dimension is already covered rather than found later:
        # canonical form, addr-spec shape, dot-atom local, local length, LDH
        # labels, TLD, total mailbox length, and ASCII.
        local64 = "a" * 64
        dom189 = "b" * 63 + "." + "c" * 63 + "." + "d" * 57 + ".com"
        at254 = local64 + "@" + dom189
        at255 = local64 + "@" + "b" * 63 + "." + "c" * 63 + "." + "d" * 58 + ".com"
        self.assertEqual(len(at254), 254)
        self.assertEqual(len(at255), 255)
        rules = {
            "canonical form": [" a@example.com", "a@example.com ", "a@exa mple.com"],
            "addr-spec shape": ["@example.com", "a@", "a@@example.com", "aexample.com"],
            "dot-atom local": ["a.@example.com", ".a@example.com", "a..b@example.com"],
            "local <= 64 (RFC 5321)": ["a" * 65 + "@example.com"],
            "LDH labels (RFC 1035)": ["a@-example.com", "a@example-.com", "a@example..com"],
            "TLD present and alphabetic": ["a@example", "a@example.c", "a@example.c0m"],
            "total <= 254 (RFC 5321)": [at255],
            "ASCII only": ["a@example.com\x00", "cust\x1eomer@example.com", "\u00fc@example.com"],
        }
        for rule, values in rules.items():
            for value in values:
                with self.subTest(rule=rule, value=value[:40]):
                    self.assertFalse(rv.is_actionable_email(value))
        for value in (
            "customer@example.com", "a.b+c@sub.example.co.uk", "x@ex.io",
            "first.last@example.museum", "a!#$%&'*+/=?^_`{|}~-b@example.com",
            at254,  # the boundary itself is accepted
        ):
            with self.subTest(good=value[:40]):
                self.assertTrue(rv.is_actionable_email(value))

    def test_email_grammar_rejects_everything_a_provider_would_bounce(self):
        bad = [
            "customer@example.com\x00", "cust\x1eomer@example.com",  # control chars
            "a.@example.com", ".a@example.com", "a..b@example.com",     # dot-atom
            "@example.com", "a@", "a@@example.com",
            "a@-example.com", "a@example-.com", "a@example..com",       # LDH labels
            "a@example", "a@example.c",                                  # no/short TLD
            "a@exa mple.com", " a@example.com",
            "a" * 65 + "@example.com",                                   # local > 64
        ]
        for value in bad:
            with self.subTest(bad=value):
                self.assertFalse(rv.is_actionable_email(value))
        for value in (
            "customer@example.com", "a.b+c@sub.example.co.uk", "x@ex.io",
            "first.last@example.museum", "a!#$%&'*+/=?^_`{|}~-b@example.com",
        ):
            with self.subTest(good=value):
                self.assertTrue(rv.is_actionable_email(value))

    # Class: a parameter that BOUNDS a guard must reject its degenerate values
    # at parse time. Zero or negative does not tighten the guard, it disables
    # it or strands the run. Same defect QA flagged on hydra #917 today for
    # UVN_REVERSAL_WINDOW_DAYS; one case per knob.
    def test_every_guard_bound_rejects_degenerate_values_at_parse_time(self):
        for command in ("plan", "reserve"):
            for value in ("0", "-1"):
                with self.subTest(command=command, value=value):
                    argv = [
                        command, "--max-revalidation-age-seconds", value,
                        "--plan", "state/runs/run-1/plan.json", "--recipient-id", "R-1",
                    ] if command == "reserve" else [
                        command, "--max-revalidation-age-seconds", value,
                        "--manifest", "m.json", "--template", "t.txt",
                    ]
                    with mock.patch.object(rv.sys, "stderr", io.StringIO()):
                        with self.assertRaises(SystemExit) as caught:
                            rv.build_parser().parse_args(argv)
                    self.assertEqual(caught.exception.code, 2)

    def test_a_delivered_signal_anywhere_in_the_history_is_terminal(self):
        # Round 4 made a delivered VERIFICATION beat a later contradictory
        # reconciliation. This is the same rule one layer deeper: a delivered
        # RECONCILIATION followed by a not_delivered one. classify_attempt read
        # only the latest, so delivered went false and retryable true, and the
        # customer could be contacted again for a message we have authoritative
        # evidence they received.
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id=None, outcome="unknown"),
            audit("verification", provider_id=None, verified_status="unknown"),
            audit("reconciliation", provider_id="MSG-1", history_source="gmail",
                  result="delivered"),
            audit("reconciliation", provider_id="MSG-1", history_source="gmail",
                  result="not_delivered"),
        ]
        state = rv.validate_ledger(rows)
        attempt = state["latest_attempt_by_claim"]["C-1"]
        self.assertTrue(attempt["delivered"])
        self.assertFalse(attempt["retryable"])
        self.assertEqual(attempt["status"], "delivered")

    def test_conversation_ids_must_be_url_safe_tokens(self):
        # Same contract as the address: reject anything the provider will
        # reject. strip() only sees the ends, so CONV\n1 and CONV<NUL>1 reached
        # the plan and could only fail at send time.
        bad = ["CONV\n1", "CONV\x001", "CONV 1", "CONV\t1", "CONV/1", "CONV;1",
               "CONV.1", "", "   ", "C" * 65]
        for value in bad:
            with self.subTest(bad=value[:20]):
                self.assert_closed(
                    manifest([{
                        **recipient(), "route": "intercom_existing",
                        "recipient_email": None, "intercom_conversation_id": value,
                        "relevant_conversation_verified": True,
                    }]),
                    "Intercom conversation relevance is not verified",
                    [],
                )
        for value in ("215475790964247", "CONV-1", "conv_1"):
            with self.subTest(good=value):
                rv.validate_manifest(
                    manifest([{
                        **recipient(), "route": "intercom_existing",
                        "recipient_email": None, "intercom_conversation_id": value,
                        "relevant_conversation_verified": True,
                    }]),
                    [], rv.parse_utc(NOW, "now"), 300,
                )

    def test_reconciliation_recovers_provider_id_and_completes_run(self):
        rows = [
            audit("pre_send"),
            audit("provider_result", provider_id=None, outcome="unknown"),
            audit("verification", provider_id=None, verified_status="unknown"),
            audit("reconciliation", provider_id="RECOVERED", history_source="gmail",
                  result="delivered"),
        ]
        state = rv.validate_ledger(rows, require_complete_run="old-run")
        attempt = next(iter(state["attempts"].values()))
        self.assertTrue(attempt["delivered"])
        self.assertEqual(attempt["effective_provider_id"], "RECOVERED")

    def test_provider_ids_are_route_scoped_and_repeatable_within_audit(self):
        first = [
            audit("pre_send", audit_id="A-email", claim_ids=["C-email"]),
            audit("provider_result", audit_id="A-email", claim_ids=["C-email"],
                  provider_id="SAME", outcome="accepted"),
            audit("verification", audit_id="A-email", claim_ids=["C-email"],
                  provider_id="SAME", verified_status="delivered"),
        ]
        second = [
            audit("pre_send", audit_id="A-intercom", claim_ids=["C-intercom"],
                  route="intercom_existing"),
            audit("provider_result", audit_id="A-intercom", claim_ids=["C-intercom"],
                  route="intercom_existing", provider_id="SAME", outcome="accepted"),
            audit("verification", audit_id="A-intercom", claim_ids=["C-intercom"],
                  route="intercom_existing", provider_id="SAME",
                  verified_status="delivered"),
        ]
        rv.validate_ledger(first + second)
        conflicting = [
            audit("pre_send", audit_id="A-other", claim_ids=["C-other"]),
            audit("provider_result", audit_id="A-other", claim_ids=["C-other"],
                  provider_id="SAME", outcome="accepted"),
        ]
        with self.assertRaisesRegex(rv.ValidationError, "duplicate provider_id within route"):
            rv.validate_ledger(first + second + conflicting)

    def test_complete_run_rejects_incomplete_and_unresolved_attempts(self):
        cases = {
            "missing provider result": [audit("pre_send")],
            "missing verification": [
                audit("pre_send"),
                audit("provider_result", provider_id=None, outcome="failed"),
            ],
            "unresolved unknown": [
                audit("pre_send"),
                audit("provider_result", provider_id=None, outcome="unknown"),
                audit("verification", provider_id=None, verified_status="unknown"),
            ],
        }
        for label, rows in cases.items():
            with self.subTest(label=label):
                with self.assertRaises(rv.ValidationError):
                    rv.validate_ledger(rows, require_complete_run="old-run")

    def test_summary_is_per_run_deterministic_counts_only_and_identifier_free(self):
        rows = [
            audit("pre_send", run_id="run-1", audit_id="SECRET-AUDIT",
                  claim_ids=["SECRET-CLAIM"]),
            audit("provider_result", run_id="run-1", audit_id="SECRET-AUDIT",
                  claim_ids=["SECRET-CLAIM"],
                  provider_id="SECRET-PROVIDER", outcome="accepted"),
            audit("verification", run_id="run-1", audit_id="SECRET-AUDIT",
                  claim_ids=["SECRET-CLAIM"],
                  provider_id="SECRET-PROVIDER", verified_status="delivered"),
            audit("pre_send", run_id="other-run", audit_id="OTHER-AUDIT",
                  recipient_id="OTHER-RECIPIENT", claim_ids=["OTHER-CLAIM"]),
            audit("provider_result", run_id="other-run", audit_id="OTHER-AUDIT",
                  recipient_id="OTHER-RECIPIENT", claim_ids=["OTHER-CLAIM"],
                  provider_id=None, outcome="failed"),
            audit("verification", run_id="other-run", audit_id="OTHER-AUDIT",
                  recipient_id="OTHER-RECIPIENT", claim_ids=["OTHER-CLAIM"],
                  provider_id=None, verified_status="not_delivered"),
        ]
        plan = private_plan("run-1", "R-1", ["C-1"])
        plan["skipped_counts"] = {"mapping_unresolved": 3}
        first = json.dumps(
            rv.summary_counts(rows, plan, "run-1"), sort_keys=True, separators=(",", ":")
        )
        second = json.dumps(
            rv.summary_counts(rows, plan, "run-1"), sort_keys=True, separators=(",", ":")
        )
        self.assertEqual(first, second)
        value = json.loads(first)
        self.assertEqual(value["delivered_customers"], 1)
        self.assertEqual(value["delivered_claims"], 1)
        self.assertEqual(value["delivered_attempts"], 1)
        self.assertEqual(value["not_delivered_attempts"], 0)
        self.assertEqual(value["skipped_counts"], {"mapping_unresolved": 3})
        for forbidden in ("SECRET-AUDIT", "SECRET-CLAIM", "SECRET-PROVIDER",
                          "OTHER-AUDIT", "OTHER-CLAIM", "OTHER-RECIPIENT",
                          "private@example.com", "credits.muso.ai"):
            self.assertNotIn(forbidden, first)
        def assert_counts_only(value):
            if isinstance(value, dict):
                for child in value.values():
                    assert_counts_only(child)
            else:
                self.assertIs(type(value), int)
        assert_counts_only(json.loads(first))

    def test_skipped_counts_validation_and_plan_reporting(self):
        self.assertEqual(
            rv.validate_skipped_counts({"special_resolution": 0, "no_longer_pending": 4}),
            {"no_longer_pending": 4, "special_resolution": 0},
        )
        invalid = (
            None,
            {"special_resolution": -1},
            {"special_resolution": True},
            {"special_resolution": 1.5},
            {"Customer One": 1},
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(rv.ValidationError):
                    rv.validate_skipped_counts(value)
        missing = manifest()
        del missing["skipped_counts"]
        self.assert_closed(missing, "skipped_counts")

    def test_identifier_like_skipped_count_key_is_rejected(self):
        with self.assertRaisesRegex(rv.ValidationError, "unsupported reason key"):
            rv.validate_skipped_counts({"claim_c_123456789": 1})

    def test_separate_append_only_audit_is_documented(self):
        proposal = skill_document_text()
        contract = (
            HERE.parent.parent / "references" / "manifest-contract.md"
        ).read_text(encoding="utf-8")
        for document in (proposal, contract):
            self.assertIn(
                "/opt/hydra/workspaces/operations/api-logs/support/YYYY-MM-DD.jsonl",
                document,
            )
            self.assertIn("customer_provider_pre_write", document)
            self.assertIn("customer_provider_result", document)
            self.assertIn("customer_provider_verification", document)
            self.assertIn("run_id", document)
            self.assertIn("communication_id", document)
            self.assertIn("attempt_number", document)
            self.assertIn("audit_id", document)
            self.assertIn("requester", document)
            self.assertIn("authorization", document)
            self.assertIn("non-audit", document)
            self.assertIn("never substitutes", document)

    def test_documented_examples_are_non_sending_and_per_run(self):
        proposal = skill_document_text()
        self.assertIn(
            "cd /opt/hydra/workspaces/operations/skills/"
            "muso-profile-claim-evidence-outreach",
            proposal,
        )
        for command in (
            "scripts/render_validate.py plan",
            "scripts/render_validate.py reserve",
            "scripts/render_validate.py append-row",
            "scripts/render_validate.py validate-ledger",
            "scripts/render_validate.py summary",
            "--require-complete-run",
            "--run-id",
        ):
            self.assertIn(command, proposal)
        examples = proposal.split("## Command examples", 1)[1].split(
            "## Cron readiness", 1
        )[0]
        self.assertNotIn("sessions_send", examples)
        self.assertNotIn("intercom-ops-write", examples)
        self.assertIn("do not authorize or perform a provider send", examples)

    def test_plan_stdout_contains_counts_not_private_plan_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            template_path = root / "template.txt"
            manifest_path.write_text(json.dumps(manifest()), encoding="utf-8")
            template_path.write_text(
                "{recipient_name}\n{claim_plural}\n{claim_object}\n"
                "{claim_blocks}\n{pending_sentence}\n",
                encoding="utf-8",
            )
            args = SimpleNamespace(
                manifest=str(manifest_path),
                ledger="state/outreach-ledger.jsonl",
                template=str(template_path),
                output=None,
                now=NOW,
                max_revalidation_age_seconds=300,
            )
            output = io.StringIO()
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", output
            ):
                rv.cmd_plan(args)
            rendered_stdout = output.getvalue()
            self.assertEqual(json.loads(rendered_stdout), {"communications_planned": 1})
            self.assertNotIn("customer@example.com", rendered_stdout)
            self.assertNotIn("https://credits.muso.ai", rendered_stdout)
            self.assertNotIn("C-1", rendered_stdout)


    def test_zero_recipient_noop_plan_summary_and_reserve(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            template_path = root / "template.txt"
            manifest_path.write_text(json.dumps(manifest([])), encoding="utf-8")
            template_path.write_text(
                "{recipient_name}\n{claim_plural}\n{claim_object}\n"
                "{claim_blocks}\n{pending_sentence}\n",
                encoding="utf-8",
            )
            plan_args = SimpleNamespace(
                manifest=str(manifest_path),
                ledger="state/outreach-ledger.jsonl",
                template=str(template_path),
                output=None,
                now=NOW,
                max_revalidation_age_seconds=300,
            )
            plan_output = io.StringIO()
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", plan_output
            ):
                rv.cmd_plan(plan_args)
            plan_path = root / "state" / "runs" / "run-1" / "plan.json"
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
            self.assertEqual(plan["communications"], [])
            self.assertEqual(
                json.loads(plan_output.getvalue()), {"communications_planned": 0}
            )

            summary_output = io.StringIO()
            summary_args = SimpleNamespace(
                plan="state/runs/run-1/plan.json",
                run_id="run-1",
                ledger="state/outreach-ledger.jsonl",
            )
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", summary_output
            ):
                rv.cmd_summary(summary_args)
            self.assertEqual(
                json.loads(summary_output.getvalue()),
                {
                    "delivered_customers": 0,
                    "delivered_claims": 0,
                    "per_route_attempts": {
                        "intercom_existing": 0,
                        "support_email": 0,
                    },
                    "delivered_attempts": 0,
                    "not_delivered_attempts": 0,
                    "unknown_attempts": 0,
                    "incomplete_attempts": 0,
                    "skipped_counts": {
                        "no_longer_pending": 2,
                        "special_resolution": 1,
                    },
                },
            )

            reserve_args = SimpleNamespace(
                plan="state/runs/run-1/plan.json",
                recipient_id="missing-recipient",
                ledger="state/outreach-ledger.jsonl",
                now=NOW,
                max_revalidation_age_seconds=300,
            )
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root):
                with self.assertRaisesRegex(rv.ValidationError, "no-op plan"):
                    rv.cmd_reserve(reserve_args)
            self.assertEqual(
                (root / "state" / "outreach-ledger.jsonl").read_text(encoding="utf-8"),
                "",
            )

    def test_byte_identical_cmd_plan_regeneration_succeeds_after_same_run_reservation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            template_path = root / "template.txt"
            manifest_path.write_text(json.dumps(manifest()), encoding="utf-8")
            template_path.write_text(
                "{recipient_name}\n{claim_plural}\n{claim_object}\n"
                "{claim_blocks}\n{pending_sentence}\n",
                encoding="utf-8",
            )
            plan_args = SimpleNamespace(
                manifest=str(manifest_path),
                ledger="state/outreach-ledger.jsonl",
                template=str(template_path),
                output=None,
                now=NOW,
                max_revalidation_age_seconds=300,
            )
            with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                rv.sys, "stdout", io.StringIO()
            ):
                rv.cmd_plan(plan_args)
                plan_path = root / "state" / "runs" / "run-1" / "plan.json"
                original_bytes = plan_path.read_bytes()
                rv.cmd_reserve(SimpleNamespace(
                    plan="state/runs/run-1/plan.json",
                    recipient_id="R-1",
                    ledger="state/outreach-ledger.jsonl",
                    now=NOW,
                    max_revalidation_age_seconds=300,
                ))
                rv.cmd_plan(plan_args)
            self.assertEqual(plan_path.read_bytes(), original_bytes)

    def test_changed_same_run_manifest_is_rejected_before_and_after_reservation(self):
        for reserve_first in (False, True):
            with self.subTest(reserve_first=reserve_first), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                manifest_path = root / "manifest.json"
                template_path = root / "template.txt"
                original = manifest()
                manifest_path.write_text(json.dumps(original), encoding="utf-8")
                template_path.write_text(
                    "{recipient_name}\n{claim_plural}\n{claim_object}\n"
                    "{claim_blocks}\n{pending_sentence}\n",
                    encoding="utf-8",
                )
                plan_args = SimpleNamespace(
                    manifest=str(manifest_path),
                    ledger="state/outreach-ledger.jsonl",
                    template=str(template_path),
                    output=None,
                    now=NOW,
                    max_revalidation_age_seconds=300,
                )
                with mock.patch.object(rv, "APPLIED_SKILL_DIR", root), mock.patch.object(
                    rv.sys, "stdout", io.StringIO()
                ):
                    rv.cmd_plan(plan_args)
                    plan_path = root / "state" / "runs" / "run-1" / "plan.json"
                    original_bytes = plan_path.read_bytes()
                    if reserve_first:
                        rv.cmd_reserve(SimpleNamespace(
                            plan="state/runs/run-1/plan.json",
                            recipient_id="R-1",
                            ledger="state/outreach-ledger.jsonl",
                            now=NOW,
                            max_revalidation_age_seconds=300,
                        ))
                    changed = manifest()
                    changed["skipped_counts"] = {"mapping_unresolved": 99}
                    manifest_path.write_text(json.dumps(changed), encoding="utf-8")
                    with self.assertRaisesRegex(rv.ValidationError, "immutable"):
                        rv.cmd_plan(plan_args)
                    self.assertEqual(plan_path.read_bytes(), original_bytes)
                    summary_output = io.StringIO()
                    with mock.patch.object(rv.sys, "stdout", summary_output):
                        rv.cmd_summary(SimpleNamespace(
                            plan="state/runs/run-1/plan.json",
                            run_id="run-1",
                            ledger="state/outreach-ledger.jsonl",
                        ))
                summary = json.loads(summary_output.getvalue())
                self.assertEqual(
                    summary["skipped_counts"],
                    original["skipped_counts"],
                )
                self.assertNotEqual(summary["skipped_counts"], changed["skipped_counts"])


if __name__ == "__main__":
    unittest.main()
