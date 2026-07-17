"""Behavioral tests for scripts/lib/detect-store-only-crons.py — the deploy gate
that halts if the live SQLite cron store holds a recurring cron absent from
cron-jobs.json (prevents silently deleting a live-created cron; incident
2026-07-16, PR #702).

Stdlib unittest only (no pytest, no network) — run by name in pr-validate.yml:
  python3 -m unittest -v tests.test_detect_store_only_crons
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "scripts" / "lib" / "detect-store-only-crons.py"

# A recurring cron declared in cron-jobs.json → must never be flagged.
REPO_JOB = {"id": "repo-1", "name": "in-repo-daily", "schedule": {"kind": "cron", "expr": "0 6 * * *"}}
# Agent one-shot (deleteAfterRun + `at`), not in repo → must be EXEMPT.
EPHEMERAL = {"id": "eph-1", "name": "qa-autoreview", "deleteAfterRun": True,
             "schedule": {"kind": "at", "at": 123}}
# Recurring cron in the store but not in repo (the incident class) → must be FLAGGED.
DURABLE = {"id": "store-only-1", "name": "Realtime MRR Movement",
           "schedule": {"kind": "cron", "expr": "*/5 * * * *"}}


class DetectStoreOnlyCrons(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def _write(self, name, obj):
        path = Path(self.tmp) / name
        path.write_text(json.dumps(obj))
        return str(path)

    def _run(self, repo_obj, store_obj, allow=False):
        repo = self._write("repo.json", repo_obj)
        store = self._write("store.json", store_obj)
        env = {k: v for k, v in os.environ.items() if k != "HYDRA_ALLOW_ORPHAN_CRON"}
        if allow:
            env["HYDRA_ALLOW_ORPHAN_CRON"] = "1"
        return subprocess.run(
            [sys.executable, str(HELPER), repo, store],
            capture_output=True, text=True, env=env,
        )

    def test_durable_store_only_cron_is_flagged(self):
        r = self._run({"jobs": [REPO_JOB]}, {"jobs": [REPO_JOB, EPHEMERAL, DURABLE]})
        self.assertEqual(r.returncode, 3, r.stderr)
        # names the durable orphan...
        self.assertIn("store-only-1", r.stderr)
        self.assertIn("Realtime MRR Movement", r.stderr)
        # ...and NOT the exempt/committed jobs
        self.assertNotIn("eph-1", r.stderr)
        self.assertNotIn("repo-1", r.stderr)

    def test_repo_and_ephemeral_only_passes(self):
        r = self._run({"jobs": [REPO_JOB]}, {"jobs": [REPO_JOB, EPHEMERAL]})
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_allow_env_downgrades_to_warning(self):
        r = self._run({"jobs": [REPO_JOB]}, {"jobs": [DURABLE]}, allow=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dropping", r.stderr)
        self.assertIn("store-only-1", r.stderr)

    def test_recurring_deleteafterrun_is_still_flagged(self):
        # deleteAfterRun alone does NOT exempt — only deleteAfterRun + `at` does.
        weird = {"id": "store-only-2", "name": "recurring-selfdelete",
                 "deleteAfterRun": True, "schedule": {"kind": "cron", "expr": "*/5 * * * *"}}
        r = self._run({"jobs": [REPO_JOB]}, {"jobs": [weird]})
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("store-only-2", r.stderr)

    def test_empty_store_and_repo(self):
        self.assertEqual(self._run({"jobs": []}, {"jobs": []}).returncode, 0)

    def test_bare_list_store_dump(self):
        # loadCronStore returns {"jobs": [...]}, but accept a bare list too.
        r = self._run({"jobs": [REPO_JOB]}, [DURABLE])
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("store-only-1", r.stderr)

    def test_bad_args_exit_2(self):
        r = subprocess.run([sys.executable, str(HELPER), "only-one-arg"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)

    def test_malformed_json_exit_2(self):
        bad = Path(self.tmp) / "bad.json"
        bad.write_text("{not json")
        good = self._write("repo.json", {"jobs": []})
        r = subprocess.run([sys.executable, str(HELPER), good, str(bad)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2, r.stderr)


if __name__ == "__main__":
    unittest.main()
