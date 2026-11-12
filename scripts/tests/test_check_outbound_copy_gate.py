"""scripts/check-outbound-copy-gate.py: the list of customer senders, and the AST rule that a
`gated` sender asks the copy gate above its POST. Each rule has a mutation that must go red."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("check_outbound_copy_gate", ROOT / "scripts" / "check-outbound-copy-gate.py")
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)  # type: ignore[union-attr]

GATED = '''
from outbound_copy import sendgate


def post_intercom_reply(conv_id, message):
    """Posts to /conversations/{id}/reply (this docstring line is not a send)."""
    permit = sendgate.require_verdict(message, family="f", campaign="f")
    s, body = http("POST", f"{API}/conversations/{conv_id}/reply", body={"body": message})
    return permit
'''


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="copy-gate-guard-"))
        (self.root / "scripts").mkdir()
        (self.root / "policies").mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.rows = [{"path": "scripts/a.py", "family": "a", "status": "gated",
                      "send_functions": ["post_intercom_reply"]}]
        self.not_senders: list[dict] = []
        self.write("scripts/a.py", GATED)

    def write(self, rel: str, text: str) -> None:
        (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.root / rel).write_text(text)

    def run_guard(self, *extra: str) -> tuple[int, str]:
        self.write("policies/outbound-copy-senders.json",
                   json.dumps({"version": 1, "senders": self.rows, "not_senders": self.not_senders}))
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        out = StringIO()
        with redirect_stdout(out), redirect_stderr(out):
            rc = guard.main(["--root", str(self.root), *extra])
        return rc, out.getvalue()

    def commit(self) -> None:
        self.run_guard()
        subprocess.run(["git", "-C", str(self.root), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base"],
                       check=True)

    def test_this_tree_passes_and_names_what_is_still_open(self):
        out = StringIO()
        with redirect_stdout(out), redirect_stderr(out):
            rc = guard.main([])
        self.assertEqual(rc, 0, out.getvalue())
        self.assertIn("sender file(s) gated", out.getvalue())
        reg = json.loads((ROOT / "policies" / "outbound-copy-senders.json").read_text())
        gated = {r["path"] for r in reg["senders"] if r["status"] == "gated"}
        self.assertLessEqual({"scripts/overdue-verification-notifier.py", "scripts/resolve-notify.py",
                              "scripts/merge-outcome-notify.py"}, gated)

    def test_a_gated_sender_passes(self):
        self.assertEqual(self.run_guard()[0], 0)

    def test_removing_the_gate_call_fails(self):
        self.write("scripts/a.py", GATED.replace(
            '    permit = sendgate.require_verdict(message, family="f", campaign="f")\n', "    permit = None\n"))
        rc, out = self.run_guard()
        self.assertEqual(rc, 1)
        self.assertIn("without asking the copy gate above it", out)

    def test_asking_after_the_post_fails(self):
        lines = GATED.splitlines(keepends=True)
        ask = next(i for i, x in enumerate(lines) if "require_verdict" in x)
        lines[ask], lines[ask + 1] = lines[ask + 1], lines[ask]
        self.write("scripts/a.py", "".join(lines))
        rc, out = self.run_guard()
        self.assertEqual(rc, 1)
        self.assertIn("without asking", out)

    def test_a_commented_out_gate_call_fails(self):
        self.write("scripts/a.py", GATED.replace("    permit = sendgate", "    permit = 1  # sendgate"))
        self.assertEqual(self.run_guard()[0], 1)

    def test_a_second_unlisted_send_function_fails(self):
        self.write("scripts/a.py", GATED + '\n\ndef side_door(c, m):\n    return http("POST", f"{API}/conversations/{c}/reply")\n')
        rc, out = self.run_guard()
        self.assertEqual(rc, 1)
        self.assertIn("side_door() holds a customer send and is not in send_functions", out)

    def test_a_send_at_module_level_fails(self):
        self.write("scripts/a.py", GATED + '\nhttp("POST", f"{API}/conversations/{C}/reply")\n')
        rc, out = self.run_guard()
        self.assertEqual(rc, 1)
        self.assertIn("outside any function", out)

    def test_a_helper_in_the_same_file_counts_only_when_it_asks(self):
        via = GATED.replace('    permit = sendgate.require_verdict(message, family="f", campaign="f")\n',
                            "    permit = copy_permit(message)\n")
        self.write("scripts/a.py", via + '\n\ndef copy_permit(m):\n    return sendgate.require_verdict(m, family="f", campaign="f")\n')
        self.assertEqual(self.run_guard()[0], 0)
        self.write("scripts/a.py", via + "\n\ndef copy_permit(m):\n    return None\n")
        self.assertEqual(self.run_guard()[0], 1)
        self.write("scripts/a.py", via + '\n\ndef copy_permit(m):\n    if SKIP:\n        return None\n'
                   '    else:\n        return sendgate.require_verdict(m, family="f", campaign="f")\n')
        self.assertEqual(self.run_guard()[0], 1, "a helper that asks only on one branch is not an ask")

    def test_an_ask_that_may_not_run_is_not_an_ask(self):
        ask = '    permit = sendgate.require_verdict(message, family="f", campaign="f")\n'
        call = 'sendgate.require_verdict(message, family="f", campaign="f")'
        for name, block in (
                ("dead branch", f"    if False:\n        permit = {call}\n"),
                ("live-looking branch", f"    if message:\n        permit = {call}\n"),
                ("swallowed", f"    try:\n        permit = {call}\n    except Exception:\n        permit = None\n"),
                ("loop that may run zero times", f"    for _ in ROWS:\n        permit = {call}\n"),
                ("short circuit", f"    permit = SKIP or {call}\n"),
                ("conditional expression", f"    permit = {call} if CHECK else None\n"),
                ("nested function never called", f"    def later():\n        return {call}\n    permit = None\n")):
            with self.subTest(name):
                self.assertIn(ask, GATED)
                self.write("scripts/a.py", GATED.replace(ask, block))
                rc, out = self.run_guard()
                self.assertEqual(rc, 1, out)
                self.assertIn("without asking the copy gate above it", out)

    def test_an_unlisted_sender_file_fails_in_every_shape(self):
        for name, text in (("b.py", 'requests.post(f"{API}/conversations/{c}/reply")\n'),
                           ("c.sh", 'gog gmail send --account support@muso.ai --to "$1"\n'),
                           ("d.py", 'cmd = [gog, "gmail", "send", "--to", email]\n'),
                           ("e.py", 'post(GATEWAY + "/v1/send", payload)\n'),
                           ("f.py", 'base = [OPS_WRITE, "reply", "--conversation", cid]\n'),
                           ("g.js", 'fetch(`https://api.intercom.io/conversations/${id}/reply`)\n')):
            with self.subTest(name):
                self.write(f"scripts/{name}", text)
                rc, out = self.run_guard()
                self.assertEqual(rc, 1)
                self.assertIn(f"scripts/{name}: holds a customer send and is on neither list", out)
                (self.root / "scripts" / name).unlink()

    def test_a_test_file_or_a_not_sender_row_is_not_a_sender(self):
        self.write("scripts/tests/test_x.py", 'url = "/conversations/1/reply"\n')
        self.write("scripts/doc.sh", "# never curl /conversations/<id>/reply by hand\n")
        self.assertEqual(self.run_guard()[0], 1)
        self.not_senders = [{"path": "scripts/doc.sh", "why": "a comment"}]
        self.assertEqual(self.run_guard()[0], 0)
        self.not_senders = [{"path": "scripts/doc.sh"}]
        self.assertEqual(self.run_guard()[0], 1)

    def test_an_open_row_needs_an_owner_and_a_reason_and_is_printed(self):
        self.write("scripts/b.py", 'requests.post(f"{API}/conversations/{c}/reply")\n')
        self.rows.append({"path": "scripts/b.py", "family": "b", "status": "open", "owner": "lane-x", "why": "next"})
        rc, out = self.run_guard()
        self.assertEqual(rc, 0, out)
        self.assertIn("OPEN scripts/b.py [b] owner=lane-x: next", out)
        for drop in ("owner", "why"):
            self.rows[-1] = {k: v for k, v in {"path": "scripts/b.py", "family": "b", "status": "open",
                                               "owner": "lane-x", "why": "next"}.items() if k != drop}
            self.assertEqual(self.run_guard()[0], 1)

    def test_a_listed_file_that_is_gone_and_an_unknown_status_fail(self):
        self.rows.append({"path": "scripts/gone.py", "family": "g", "status": "open", "owner": "o", "why": "w"})
        self.assertEqual(self.run_guard()[0], 1)
        self.rows[-1] = {"path": "scripts/a.py", "family": "a", "status": "approved"}
        self.assertEqual(self.run_guard()[0], 1)

    def test_a_sender_gated_at_the_base_cannot_become_open_or_unlisted(self):
        self.commit()
        self.assertEqual(self.run_guard("--base", "HEAD")[0], 0)
        self.rows[0] = {"path": "scripts/a.py", "family": "a", "status": "open", "owner": "o", "why": "w"}
        rc, out = self.run_guard("--base", "HEAD")
        self.assertEqual(rc, 1)
        self.assertIn("was `gated` at the base and is not behind the gate now", out)
        self.rows.clear()
        self.not_senders = [{"path": "scripts/a.py", "why": "trust me"}]
        self.assertEqual(self.run_guard("--base", "HEAD")[0], 1)

    def test_the_other_caller_of_the_same_gate_counts_and_only_above_the_send(self):
        """lib/copy_gate.require is the second caller of scripts/outbound_copy/gate.py; it raises like sendgate."""
        ask = '    permit = sendgate.require_verdict(message, family="f", campaign="f")\n'
        other = GATED.replace("from outbound_copy import sendgate", "from lib import copy_gate").replace(
            ask, '    copy_gate.require("f", message)\n').replace("    return permit\n", "")
        self.assertNotIn("sendgate", other)
        self.write("scripts/a.py", other)
        self.assertEqual(self.run_guard()[0], 0)
        self.write("scripts/a.py", other.replace('    copy_gate.require("f", message)\n',
                                                 '    if message:\n        copy_gate.require("f", message)\n'))
        rc, out = self.run_guard()
        self.assertEqual(rc, 1)
        self.assertIn("without asking the copy gate above it", out)
        # a look-alike is not the gate
        self.write("scripts/a.py", other.replace("copy_gate.require(", "copy_gate.maybe("))
        self.assertEqual(self.run_guard()[0], 1)

    def test_gated_elsewhere_must_name_a_test_that_exists_and_cannot_fall_back_to_open(self):
        self.write("scripts/b.sh", 'api POST "/conversations/$THREAD/reply"\n')
        self.write("scripts/tests/b.bats", "@test x { true; }\n")
        row = {"path": "scripts/b.sh", "family": "b", "status": "gated_elsewhere",
               "checked_by": "scripts/tests/b.bats", "why": "bash"}
        self.rows.append(dict(row))
        rc, out = self.run_guard()
        self.assertEqual(rc, 0, out)
        self.assertIn("2 sender file(s) gated, 0 open", out)
        self.commit()
        for broken, said in (({"checked_by": ""}, "must name the test that proves it"),
                             ({"why": ""}, "must name the test that proves it"),
                             ({"checked_by": "scripts/tests/gone.bats"}, "there is no such file")):
            self.rows[1] = {**row, **broken}
            rc, out = self.run_guard()
            self.assertEqual(rc, 1, broken)
            self.assertIn(said, out)
        self.rows[1] = {"path": "scripts/b.sh", "family": "b", "status": "open", "owner": "o", "why": "w"}
        rc, out = self.run_guard("--base", "HEAD")
        self.assertEqual(rc, 1)
        self.assertIn("scripts/b.sh: was `gated_elsewhere` at the base and is not behind the gate now", out)

    def test_this_tree_lists_every_sender_this_repo_gates_as_behind_the_gate(self):
        reg = json.loads((ROOT / "policies" / "outbound-copy-senders.json").read_text())
        status = {r["path"]: r["status"] for r in reg["senders"]}
        for path in ("scripts/resolution-matcher.py", "scripts/close-duplicate-conversations.py",
                     "scripts/dedup/sweeps/notify-merged-customers.py"):
            self.assertEqual(status[path], "gated", path)
        for path in ("scripts/intercom-verify-request.sh", "scripts/request_comms/channels.py"):
            self.assertEqual(status[path], "gated_elsewhere", path)

    def test_an_unreadable_registry_fails(self):
        self.run_guard()
        (self.root / "policies" / "outbound-copy-senders.json").write_text("{")
        out = StringIO()
        with redirect_stdout(out), redirect_stderr(out):
            self.assertEqual(guard.main(["--root", str(self.root)]), 1)


if __name__ == "__main__":
    unittest.main()
