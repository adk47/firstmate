"""CLI tests for scripts/intercom-backlog/send.py (hydra#1379, Fable/QA NO-GO findings 1).

The sender is LOCKED (COPY_APPROVED=0) and these tests do not change that. They prove the
send-eligible allowlist holds BEFORE the lock could ever be flipped: a --plan naming a
captain-legal/billing, gate-owned, ledger-today, claim-pending or ambiguous-identity
conversation is refused for the whole run, in dry-run AND apply mode.

Safety: CI runs this job as root on node-8. Every CLI case must stop at a refusal before any
network, Trino or intercom-ops-write call: MUSOAI_INTERCOM_TOKEN is removed from the child
environment, and the refusal paths all sit ahead of the token check. A case that got past the
refusals would die on "MUSOAI_INTERCOM_TOKEN not set", which the assertions reject.
Stdlib unittest only.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEND = os.path.join(ROOT, "scripts", "intercom-backlog", "send.py")

spec = importlib.util.spec_from_file_location("ib_send", SEND)
ib_send = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib_send)

FORBIDDEN = ["captain-legal", "captain-billing", "gate-uvn-status", "gate-team-review",
             "gate-doc-received", "ledger-today", "claim-pending", "ambiguous-identity"]


def row(cid, action, band="1-30d", paid=False, waiting=100):
    return {"id": cid, "action": action, "band": band, "paid": paid, "waiting_since": waiting,
            "user_id": None}


class SelectRows(unittest.TestCase):
    def test_every_forbidden_action_refused_in_recent_plan(self):
        for act in FORBIDDEN:
            with self.subTest(action=act):
                rows = [row("1", act), row("2", "draft-merge")]
                with self.assertRaises(ib_send.Refused) as cm:
                    ib_send.select_rows(rows, "recent", {"1": "merge", "2": "merge"})
                self.assertIn("not send-eligible", str(cm.exception))
                self.assertIn(act, str(cm.exception))

    def test_tail_never_selects_forbidden_actions(self):
        rows = [row(str(i), a, band="gt30d") for i, a in enumerate(FORBIDDEN)]
        rows.append(row("ok", "draft-other", band="gt30d"))
        self.assertEqual([r["id"] for r in ib_send.select_rows(rows, "tail", {})], ["ok"])

    def test_recent_needs_plan_and_known_lines_and_ids(self):
        rows = [row("1", "draft-merge")]
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows(rows, "recent", {})
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows(rows, "recent", {"1": "invented-line"})
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows(rows, "recent", {"999": "merge"})

    def test_recent_plan_refuses_tail_rows_and_tail_refuses_plan(self):
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows([row("1", "draft-merge", band="gt30d")], "recent", {"1": "merge"})
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows([row("1", "draft-merge", band="gt30d")], "tail", {"1": "merge"})

    def test_eligible_recent_plan_selected_paid_first(self):
        rows = [row("a", "draft-merge", waiting=1), row("b", "no-identity", paid=True, waiting=5)]
        got = ib_send.select_rows(rows, "recent", {"a": "merge", "b": "generic"})
        self.assertEqual([r["id"] for r in got], ["b", "a"])

    def test_sender_stays_locked(self):
        self.assertEqual(ib_send.COPY_APPROVED, 0)
        self.assertEqual(ib_send.CLOSE_APPROVED, 0)


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {k: v for k, v in os.environ.items() if k != "MUSOAI_INTERCOM_TOKEN"}

    def run_cli(self, rows, plan, *extra):
        tri = os.path.join(self.tmp.name, "t.jsonl")
        with open(tri, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        args = [sys.executable, SEND, tri, "--band", "recent"]
        if plan is not None:
            pl = os.path.join(self.tmp.name, "plan.json")
            with open(pl, "w") as f:
                json.dump(plan, f)
            args += ["--plan", pl]
        return subprocess.run(args + list(extra), capture_output=True, text=True, env=self.env,
                              timeout=30)

    def assertRefused(self, p, needle):
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("REFUSED", p.stderr)
        self.assertIn(needle, p.stderr)
        self.assertNotIn("MUSOAI_INTERCOM_TOKEN", p.stderr)

    def test_cli_refuses_each_forbidden_action_dry_run_and_apply(self):
        for act in FORBIDDEN:
            for mode in ((), ("--apply",)):
                with self.subTest(action=act, mode=mode):
                    p = self.run_cli([row("1", act)], {"1": "merge"}, *mode)
                    self.assertRefused(p, "not send-eligible")

    def test_cli_recent_without_plan_refused(self):
        self.assertRefused(self.run_cli([row("1", "draft-merge")], None), "--plan")

    def test_cli_apply_refused_while_locked(self):
        p = self.run_cli([row("1", "draft-merge")], {"1": "merge"}, "--apply")
        self.assertRefused(p, "COPY_APPROVED=0")


if __name__ == "__main__":
    unittest.main()
