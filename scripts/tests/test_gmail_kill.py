#!/usr/bin/env python3
"""The shared support@ Gmail readers kill file (firstmate 10-31): a deploy that re-enables a cron cannot restart
Gmail reads while /etc/hydra/gmail-readers.disabled exists."""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import types
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class GmailKillTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.kill = os.path.join(self.td.name, "gmail-readers.disabled")
        from credit_verify.proof import gmail_kill
        self.gk = gmail_kill
        self._old = gmail_kill.GMAIL_READERS_KILL
        gmail_kill.GMAIL_READERS_KILL = self.kill
        self.cp = load("credit_proof_cli", "credit-proof.py")
        self.dv = load("credit_doc_verify_cli", "credit-doc-verify.py")
        # legal-intake.py imports the Google client libs at module scope (they are only installed on node-8), so the
        # import is stubbed here: the gate under test runs before any of them is used.
        self._stubbed = []
        stubs = {"google": {}, "google.oauth2": {},
                 "google.oauth2.service_account": {"Credentials": object},
                 "googleapiclient": {}, "googleapiclient.discovery": {"build": lambda *a, **k: None}}
        for name, attrs in stubs.items():
            if name not in sys.modules:
                mod = types.ModuleType(name)
                for k, v in attrs.items():
                    setattr(mod, k, v)
                sys.modules[name] = mod
                self._stubbed.append(name)
        sys.modules["google.oauth2"].service_account = sys.modules["google.oauth2.service_account"]
        self.li = load("legal_intake_cli", "legal-intake.py")

    def tearDown(self):
        self.gk.GMAIL_READERS_KILL = self._old
        for name in ("google.oauth2.service_account", "google.oauth2", "googleapiclient.discovery",
                     "googleapiclient", "google"):
            if name in self._stubbed:
                sys.modules.pop(name, None)
        self.td.cleanup()

    def test_file_recent_turns_gmail_off_only_while_the_file_exists(self):
        self.assertFalse(self.cp.file_recent_no_gmail(False))
        self.assertTrue(self.cp.file_recent_no_gmail(True))                    # --no-gmail still wins
        Path(self.kill).touch()
        self.assertTrue(self.cp.file_recent_no_gmail(False))                   # Intercom only, ids kept

    def test_file_source_gmail_refuses_before_reading_anything(self):
        Path(self.kill).touch()
        args = argparse.Namespace(message_ids=os.path.join(self.td.name, "missing-ids.txt"), store=None,
                                  apply=True, limit=None, out=None)
        self.assertEqual(self.cp.cmd_file_gmail(args), 0)                     # no ids file read, no gog

    def test_blob_backfill_refuses(self):
        Path(self.kill).touch()
        self.dv.KILL_SWITCH = os.path.join(self.td.name, "no-credit-verify-kill")
        args = argparse.Namespace(store=None, proof_store="/nonexistent", max_messages=30, per_min=6)
        self.assertEqual(self.dv.cmd_blob_backfill(args), 0)

    def test_the_kill_path_is_a_constant_and_the_skill_preflight_checks_the_same_one(self):
        # r5 [key=unattended]: no env var may move a kill path
        pre = (HERE.parent / "workspaces/operations/skills/muso-support-email-triage/scripts/preflight.sh").read_text()
        self.assertIn('GMAIL_READERS_KILL="/etc/hydra/gmail-readers.disabled"', pre)
        self.assertNotIn("HYDRA_GMAIL_READERS_KILL", pre)
        self.assertEqual(self._old, "/etc/hydra/gmail-readers.disabled")
        os.environ["HYDRA_GMAIL_READERS_KILL"] = self.kill
        try:
            m = load("gmail_kill_env_probe", "credit_verify/proof/gmail_kill.py")
            self.assertEqual(m.GMAIL_READERS_KILL, "/etc/hydra/gmail-readers.disabled")
        finally:
            del os.environ["HYDRA_GMAIL_READERS_KILL"]

class OtherSupportReadersTests(unittest.TestCase):
    """QA #1569: the hourly proof-on-file scan and paid-status support7d read support@ too - the same kill file stops
    them before their first gog call."""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        # The scan's one seam points at a directory it can only accept as a bats temp root; the kill file a
        # case writes must live INSIDE it, because the seam owns that path (a hostile env cannot pick another).
        self.seam = os.path.join(self.td.name, "bats-gmail-kill")
        os.makedirs(self.seam)
        self.kill = os.path.join(self.seam, "gmail-readers.disabled")
        bindir = os.path.join(self.td.name, "bin")
        os.makedirs(bindir)
        self.gog = os.path.join(bindir, "gog")
        self.calls = os.path.join(self.td.name, "gog.calls")
        Path(self.gog).write_text(f'#!/bin/bash\necho "$@" >> {self.calls}\necho \'{{"messages": []}}\'\n')
        os.chmod(self.gog, 0o755)
        self.empty_env = os.path.join(self.td.name, "empty.env")
        Path(self.empty_env).touch()
        # legal-intake.py imports the Google client libs at module scope (installed only on node-8), and reads the
        # kill path from the shared module at CALL time - so repoint that module attribute, exactly as above.
        from credit_verify.proof import gmail_kill
        self.gk = gmail_kill
        self._old = gmail_kill.GMAIL_READERS_KILL
        gmail_kill.GMAIL_READERS_KILL = self.kill
        self._stubbed = []
        stubs = {"google": {}, "google.oauth2": {}, "google.oauth2.service_account": {"Credentials": object},
                 "googleapiclient": {}, "googleapiclient.discovery": {"build": lambda *a, **k: None}}
        for name, attrs in stubs.items():
            if name not in sys.modules:
                mod = types.ModuleType(name)
                for k, v in attrs.items():
                    setattr(mod, k, v)
                sys.modules[name] = mod
                self._stubbed.append(name)
        sys.modules["google.oauth2"].service_account = sys.modules["google.oauth2.service_account"]
        self.li = load("legal_intake_cli", "legal-intake.py")

    def tearDown(self):
        self.gk.GMAIL_READERS_KILL = self._old
        for name in self._stubbed:
            sys.modules.pop(name, None)
        self.td.cleanup()

    def scan_copy(self):
        src = (HERE / "cs_proof_feed" / "gmail_scan.sh").read_text()
        const = 'GMAIL_READERS_KILL="/etc/hydra/gmail-readers.disabled"'
        self.assertEqual(src.count(const), 1)                              # a constant, no env override
        self.assertNotIn("HYDRA_GMAIL_READERS_KILL", src)
        p = os.path.join(self.td.name, "gmail_scan.sh")
        Path(p).write_text(src.replace(const, f'GMAIL_READERS_KILL="{self.kill}"'))
        return p

    def run_scan(self):
        # The scan's gates are CONSTANTS (r5 on #1558): the only seam is CS_PROOF_FEED_TEST_SEAM, which holds the
        # state, the lock dir and the stand-in gog. CS_PROOF_* no longer moves anything, and BATS_TEST_TMPDIR is
        # deliberately NOT a seam - it is inherited from a parent shell (QA on a2d87a1c9 withdrew GO over it).
        d = self.seam
        os.makedirs(os.path.join(d, "state", "gmail"), exist_ok=True)
        stand_in = os.path.join(d, "gog")
        if not os.path.exists(stand_in):
            Path(stand_in).write_text(Path(self.gog).read_text())
            os.chmod(stand_in, 0o755)
        env = dict(os.environ, CS_PROOF_FEED_TEST_SEAM=d,
                   CS_PROOF_ENV=self.empty_env, CS_PROOF_GOG=self.gog,
                   CS_PROOF_GMAIL_DIR=os.path.join(d, "g"), CS_PROOF_GMAIL_BACKOFF="0",
                   CS_PROOF_GMAIL_PAGE_PAUSE="0", CS_PROOF_LOCK_DIR=d)
        env.pop("BATS_TEST_TMPDIR", None)
        return subprocess.run(["bash", self.scan_copy(), "atti", "newer_than:2d"], env=env, capture_output=True,
                              text=True, timeout=60)

    def test_the_proof_on_file_scan_stops_before_any_gog_call(self):
        Path(self.kill).touch()
        p = self.run_scan()
        self.assertEqual(p.returncode, 4)
        self.assertIn("support@ Gmail readers disabled", p.stderr)
        self.assertFalse(os.path.exists(self.calls))
        self.assertFalse(os.path.exists(os.path.join(self.td.name, "state", "gmail", "atti.log")))   # no DONE, feed stays stale

    def test_the_proof_on_file_scan_runs_without_the_file(self):
        p = self.run_scan()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(os.path.exists(self.calls))

    def test_support7d_fails_closed_before_any_gog_call(self):
        os.environ.setdefault("PWR_DIR", self.td.name)            # support7d reads its run dir at import
        s7 = load("support7d_kill_probe", "paid-status/support7d.py")
        self.assertEqual(s7.GMAIL_READERS_KILL, "/etc/hydra/gmail-readers.disabled")
        s7.GMAIL_READERS_KILL = self.kill
        Path(self.kill).touch()
        called = []
        s7.sh = lambda *a, **k: called.append(a) or {}
        with self.assertRaises(SystemExit) as cm:
            s7.main()
        self.assertIn("fail closed", str(cm.exception.code))
        self.assertEqual(called, [])

    # ---- notices@/legal@ intake (found missing on 2026-11-04: the file had existed since 11-03 14:47 and
    # ---- legal-intake.py was still reading mailboxes, because the freeze was only wired into the support@ readers)
    # These assert the MESSAGE, not just the exit code: main() ends in `sys.exit(2 if failed else 0)` and wraps each
    # mailbox in `except Exception`, so a mutant that drops the gate also exits 2 - with a mailbox error instead of
    # the refusal. Mutation-testing this file found exactly that trap; do not weaken it back to an exit-code assert.

    def _boom(self, *a, **k):
        self.gmail_calls += 1
        raise AssertionError("a frozen legal-intake must not build a Gmail client")

    def test_legal_intake_refuses_while_the_file_exists_and_says_why(self):
        Path(self.kill).touch()
        self.gmail_calls = 0
        self.li.svc = self._boom
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as e:
            self.li.main()
        self.assertEqual(e.exception.code, 2)
        text = out.getvalue()
        self.assertIn("ERROR frozen", text)
        self.assertIn("nothing was read", text)
        self.assertEqual(self.gmail_calls, 0)                 # no client, no mailbox, no label, no ack
        self.assertNotIn("ERROR kyran@", text)                # the failure is the freeze, not a mailbox error
        self.assertNotIn("intake:", text)                     # and it never reports a run it did not perform

    def test_legal_intake_goes_ahead_when_the_file_is_absent(self):
        self.assertEqual(self.li.frozen(), 0)

    def test_legal_intake_reads_the_shared_constant_instead_of_its_own(self):
        # a second copy of the path in that file is how a freeze gets a hole
        src = (HERE / "legal-intake.py").read_text()
        self.assertIn("from credit_verify.proof import gmail_kill", src)
        self.assertIn("gmail_kill.gmail_readers_disabled()", src)
        self.assertNotIn('GMAIL_READERS_KILL = "/etc/hydra', src)


if __name__ == "__main__":
    unittest.main()
