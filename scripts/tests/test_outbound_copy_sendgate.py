"""The copy gate's caller side (scripts/outbound_copy/sendgate.py) and the three live notifiers
that go through it: overdue-verification-notifier, resolve-notify, merge-outcome-notify.

What is proven here, per family and for the adapter itself:

  * a message with no verdict bound to its sha256 is not sent (no POST leaves the process);
  * a verdict for OTHER bytes is not a verdict for these;
  * a gate that cannot answer (missing, crashed, timed out, unreadable, exit 0 without an
    approval) is a no-send with a recorded reason, and fails the run;
  * a held message leaves no "told" state, so it is offered again and sent exactly once when
    the verdict arrives, as the very bytes the verdict names.

The gate here is a stand-in executable that keys its answer on the body's sha256 exactly as
gate.py does, run through the adapter's real subprocess path (`python3 -I <gate> check`). The
notifiers' real POST functions run; only the HTTP transport underneath them is faked.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))

from outbound_copy import sendgate  # noqa: E402
import test_merge_outcome_notify as tm  # noqa: E402

mon = tm.mon
PINNED_GATE_PATH = sendgate.GATE_PATH      # as the module set it, before any test points it elsewhere


def load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


overdue = load("overdue_verification_notifier", "overdue-verification-notifier.py")
resolve = load("resolve_notify", "resolve-notify.py")


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


FAKE_GATE = r'''
import hashlib, json, sys, time
ctl = json.load(open(CTL))
req = json.loads(sys.stdin.read())
with open(SEEN, "a") as fh:
    fh.write(json.dumps({"argv": sys.argv[1:], "req": req}) + "\n")
h = lambda t: hashlib.sha256(t.encode("utf-8")).hexdigest()
mode = ctl.get("mode", "verdicts")
if mode == "sleep":
    time.sleep(ctl["seconds"])
if mode == "raw":
    sys.stdout.write(ctl["out"])
    sys.exit(ctl["rc"])
base = {"body_sha256": h(req["body"]), "subject_sha256": h(req["subject"])}
if mode == "answer":
    print(json.dumps({**base, **ctl["answer"]}))
    sys.exit(ctl["rc"])
b = base["body_sha256"]
asked_copy = sys.argv[sys.argv.index("--copy") + 1] if "--copy" in sys.argv else ""
if b in ctl.get("approved", []) or ctl.get("approved_for_copy", {}).get(b, None) == asked_copy:
    print(json.dumps({**base, "result": "approved", "verdict_id": "ocv-" + b[:16], "verdict_sha256": h("v" + b)}))
    sys.exit(0)
if b in ctl.get("refused", []):
    print(json.dumps({**base, "result": "refused", "reason": "copy_review_refuse:ocv-" + b[:16]}))
    sys.exit(1)
print(json.dumps({**base, "result": "pending", "reason": "copy_review_pending"}))
sys.exit(3)
'''


class Gate:
    """A stand-in gate on disk, wired into the adapter for one test and removed after it."""

    def __init__(self, test: unittest.TestCase):
        self.dir = Path(tempfile.mkdtemp(prefix="sendgate-"))
        self.ctl, self.seen_path = self.dir / "ctl.json", self.dir / "seen.jsonl"
        self.path = self.dir / "gate.py"
        self.path.write_text(f"CTL = {str(self.ctl)!r}\nSEEN = {str(self.seen_path)!r}\n" + FAKE_GATE)
        self.set()
        saved = (sendgate.GATE_PATH, sendgate.LOG_PATH, sendgate.GATE_TIMEOUT_S, sendgate._ask)
        sendgate.GATE_PATH, sendgate.LOG_PATH = self.path, self.dir / "sendgate.jsonl"

        def restore():
            sendgate.GATE_PATH, sendgate.LOG_PATH, sendgate.GATE_TIMEOUT_S, sendgate._ask = saved
        test.addCleanup(restore)

    def set(self, **ctl) -> None:
        self.ctl.write_text(json.dumps(ctl))

    def approve(self, *texts: str) -> None:
        self.set(approved=[sha(t) for t in texts])

    def missing(self) -> None:
        self.path.unlink()

    def seen(self) -> list[dict]:
        return [json.loads(x) for x in self.seen_path.read_text().splitlines()] if self.seen_path.exists() else []

    def log(self) -> list[dict]:
        p = sendgate.LOG_PATH
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


# Every way the gate can fail to say "approved for these bytes". (name, arrange, result, reason
# prefix). `result == "error"` is the class "the gate could not decide"; it must never send.
def _situations(body: str):
    return [
        ("no verdict yet", lambda g: g.set(), "pending", "copy_review_pending"),
        ("reviewer refused", lambda g: g.set(refused=[sha(body)]), "refused", "copy_review_refuse:"),
        ("a verdict for other bytes", lambda g: g.approve(body + " "), "pending", "copy_review_pending"),
        ("gate file missing", lambda g: g.missing(), "error", "copy_gate_unavailable:gate_missing"),
        ("gate exits 2", lambda g: g.set(mode="answer", rc=2, answer={"result": "error",
                                                                     "reason": "copy_gate_error:store unreadable"}),
         "error", "copy_gate_error:store unreadable"),
        ("gate crashes with a traceback", lambda g: g.set(mode="raw", rc=1, out="Traceback (most recent call last)\n"),
         "error", "copy_gate_unavailable:unreadable_answer_rc1"),
        ("gate prints nothing and exits 0", lambda g: g.set(mode="raw", rc=0, out=""),
         "error", "copy_gate_unavailable:unreadable_answer_rc0"),
        ("gate exits 0 but says pending", lambda g: g.set(mode="answer", rc=0, answer={"result": "pending"}),
         "error", "copy_gate_unavailable:rc0_without_approval"),
        ("gate approves without a verdict id", lambda g: g.set(mode="answer", rc=0, answer={"result": "approved"}),
         "error", "copy_gate_unavailable:approval_without_verdict"),
        ("gate approves a different hash", lambda g: g.set(mode="answer", rc=0, answer={
            "result": "approved", "body_sha256": sha("something else"), "verdict_id": "ocv-x",
            "verdict_sha256": "0" * 64}), "error", "copy_gate_unavailable:answer_for_other_bytes"),
        ("gate exits with an unknown code", lambda g: g.set(mode="answer", rc=7, answer={"result": "approved"}),
         "error", "copy_gate_rc7"),
        ("gate exits 4 without saying observed", lambda g: g.set(mode="answer", rc=4, answer={"result": "pending"}),
         "error", "copy_gate_unavailable:rc4_without_observe"),
        ("gate exits 4 observed but not in observe mode", lambda g: g.set(mode="answer", rc=4, answer={
            "result": "observed", "mode": "enforce", "review": "pending"}),
         "error", "copy_gate_unavailable:rc4_without_observe"),
        ("gate observes a different hash", lambda g: g.set(mode="answer", rc=4, answer={
            "result": "observed", "mode": "observe", "review": "pending", "body_sha256": sha("something else")}),
         "error", "copy_gate_unavailable:answer_for_other_bytes"),
        ("gate says observed on exit 0", lambda g: g.set(mode="answer", rc=0, answer={
            "result": "observed", "mode": "observe", "review": "pending"}),
         "error", "copy_gate_unavailable:rc0_without_approval"),
    ]


class SendgateTests(unittest.TestCase):
    BODY = "hi! quick update on your request with us."

    def setUp(self):
        self.gate = Gate(self)

    def ask(self, body=None, **kw):
        return sendgate.require_verdict(self.BODY if body is None else body, family="fam", campaign="camp",
                                        copy="c1", message_type="comment", ref="conv-1", **kw)

    def test_every_non_approval_raises_and_is_recorded_with_its_reason(self):
        for name, arrange, result, reason in _situations(self.BODY):
            with self.subTest(name):
                gate = Gate(self)
                arrange(gate)
                with redirect_stderr(StringIO()), self.assertRaises(sendgate.NotApproved) as cm:
                    self.ask()
                self.assertEqual(cm.exception.result, result)
                self.assertTrue(cm.exception.reason.startswith(reason), cm.exception.reason)
                row = gate.log()[-1]
                self.assertEqual((row["result"], row["reason"]), (result, cm.exception.reason))
                self.assertEqual((row["family"], row["campaign"], row["ref"]), ("fam", "camp", "conv-1"))
                self.assertEqual(row["body_sha256"], sha(self.BODY))

    def test_a_gate_that_hangs_is_an_error_not_a_wait(self):
        self.gate.set(mode="sleep", seconds=20)
        sendgate.GATE_TIMEOUT_S = 1
        with self.assertRaises(sendgate.NotApproved) as cm:
            self.ask()
        self.assertEqual((cm.exception.result, cm.exception.reason), ("error", "copy_gate_unavailable:timeout"))

    def test_an_empty_body_never_reaches_the_gate(self):
        for body in ("", None):
            with self.assertRaises(sendgate.NotApproved) as cm:
                sendgate.require_verdict(body, family="fam", campaign="camp")
            self.assertEqual(cm.exception.reason, "copy_gate_unavailable:empty_body")
        self.assertEqual(self.gate.seen(), [])

    def test_approval_is_for_the_exact_bytes_and_carries_the_verdict(self):
        self.gate.approve(self.BODY)
        permit = self.ask()
        self.assertEqual(permit.body_sha256, sha(self.BODY))
        self.assertEqual(permit.verdict_id, "ocv-" + sha(self.BODY)[:16])
        seen = self.gate.seen()[-1]
        self.assertEqual(seen["req"], {"subject": "", "body": self.BODY})
        self.assertEqual(seen["argv"], ["check", "--campaign", "camp", "--copy", "c1", "--kind", "",
                                        "--message-type", "comment"])
        for other in (self.BODY + "\n", self.BODY.replace("hi!", "Hi!"), self.BODY + " "):
            with self.assertRaises(sendgate.NotApproved):
                self.ask(other)
        # the subject is part of what was reviewed
        with self.assertRaises(sendgate.NotApproved) as cm:
            self.gate.set(mode="answer", rc=0, answer={"result": "approved", "subject_sha256": sha(""),
                                                       "verdict_id": "ocv-x", "verdict_sha256": "0" * 64})
            self.ask(subject="A subject nobody reviewed")
        self.assertEqual(cm.exception.reason, "copy_gate_unavailable:answer_for_other_bytes")

    def test_an_observed_campaign_sends_and_the_log_says_it_was_observed_not_approved(self):
        # Observe mode is the gate's answer about ITS table (exit 4, result observed, mode observe, these bytes).
        # Nothing in this module can ask for it.
        for review in ("pending", "rewrite"):
            with self.subTest(review):
                gate = Gate(self)
                gate.set(mode="answer", rc=4, answer={"result": "observed", "mode": "observe", "review": review})
                permit = self.ask()
                self.assertEqual((permit.body_sha256, permit.verdict_id, permit.verdict_sha256),
                                 (sha(self.BODY), "", ""))
                row = gate.log()[-1]
                self.assertEqual((row["result"], row["reason"], row["verdict_id"]), ("observed", f"observed:{review}", ""))
                self.assertNotIn("mode", " ".join(gate.seen()[-1]["argv"]))
        # the subject is part of what was observed too
        gate = Gate(self)
        gate.set(mode="answer", rc=4, answer={"result": "observed", "mode": "observe", "review": "pending",
                                              "subject_sha256": sha("")})
        with self.assertRaises(sendgate.NotApproved) as cm:
            self.ask(subject="A subject nobody looked at")
        self.assertEqual(cm.exception.reason, "copy_gate_unavailable:answer_for_other_bytes")

    def test_the_gate_is_run_isolated_from_the_callers_environment(self):
        seen = []
        real = sendgate._run_gate

        def spy(argv, stdin):
            seen.append(argv)
            return real(argv, stdin)
        sendgate._run_gate = spy
        self.addCleanup(setattr, sendgate, "_run_gate", real)
        self.gate.approve(self.BODY)
        self.ask()
        self.assertEqual(seen[0][:4], [sys.executable, "-I", str(sendgate.GATE_PATH), "check"])

    def test_there_is_no_environment_seam_for_the_gate_path(self):
        src = (ROOT / "scripts" / "outbound_copy" / "sendgate.py").read_text()
        for seam in ("os.environ", "getenv", "argparse", "sys.argv"):
            self.assertFalse(seam in src, f"sendgate.py reads {seam}: the gate's path must not be the caller's to choose")
        self.assertEqual(PINNED_GATE_PATH, ROOT / "scripts" / "outbound_copy" / "gate.py")

    def test_the_log_carries_hashes_and_ids_never_the_message(self):
        self.gate.approve(self.BODY)
        permit = self.ask()
        sendgate.record_sent(permit, ref="conv-1", message_id="part-9")
        text = sendgate.LOG_PATH.read_text()
        self.assertNotIn("quick update", text)
        asked, sent = self.gate.log()
        self.assertEqual((asked["result"], sent["result"]), ("approved", "sent"))
        self.assertEqual((sent["verdict_id"], sent["message_id"], sent["body_sha256"]),
                         (permit.verdict_id, "part-9", sha(self.BODY)))
        self.assertEqual(oct(sendgate.LOG_PATH.stat().st_mode & 0o777), "0o600")

    def test_an_unwritable_log_changes_no_answer_and_the_row_goes_to_stderr(self):
        sendgate.LOG_PATH = self.gate.dir / "is-a-file" / "sendgate.jsonl"
        (self.gate.dir / "is-a-file").write_text("x")
        err = StringIO()
        with redirect_stderr(err), self.assertRaises(sendgate.NotApproved):
            self.ask()
        self.assertIn('"result": "pending"', err.getvalue())
        self.gate.approve(self.BODY)
        with redirect_stderr(StringIO()):
            self.assertEqual(self.ask().body_sha256, sha(self.BODY))


class FamilyCase(unittest.TestCase):
    """One live notifier driven end to end: real POST function, faked transport, stand-in gate."""

    def setUp(self):
        self.gate = Gate(self)
        self.dir = self.gate.dir
        self.posts: list[tuple[str, str]] = []
        self._env = dict(os.environ)
        self.addCleanup(self._restore_env)

    def _restore_env(self):
        os.environ.clear()
        os.environ.update(self._env)

    def run_main(self, fn, *args):
        out, err = StringIO(), StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = fn(*args)
        return rc, out.getvalue() + err.getvalue()


class _TicketNotifier(FamilyCase):
    """overdue-verification-notifier and resolve-notify share one shape: a fixed MESSAGE, a
    state file of told tickets, `post_intercom_reply` as the only customer POST."""

    mod = None
    prefix = ""

    def task(self) -> dict:
        raise NotImplementedError

    def conv(self) -> dict:
        raise NotImplementedError

    def setUp(self):
        super().setUp()
        m, p = self.mod, self.prefix
        self.state_path = self.dir / "notified.json"
        os.environ.update({f"{p}_STATE": str(self.state_path), f"{p}_SKIP_HOST_GUARD": "1",
                           f"{p}_SUMMARY_MODE": "never", f"{p}_LOG": str(self.dir / "send.log"),
                           f"{p}_NOW": "1781784000", "JEV_SHADOW_DIR": str(self.dir / "jev"),
                           "CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
        os.environ.pop("INTERCOM_ADMIN_ID", None)
        saved = (m.fetch_all_tasks, m.get_conversation, m.http, sys.argv)
        self.addCleanup(lambda: (setattr(m, "fetch_all_tasks", saved[0]), setattr(m, "get_conversation", saved[1]),
                                 setattr(m, "http", saved[2]), setattr(sys, "argv", saved[3])))
        m.fetch_all_tasks = lambda key, lid: [self.task()]
        m.get_conversation = lambda cid, tok: self.conv()

        def http(method, url, headers, body=None, **_):
            self.assertEqual(method, "POST")
            self.assertTrue(url.endswith("/conversations/C1/reply"), url)
            self.posts.append((url, body["body"]))
            return 200, {"id": "part-1"}
        m.http = http
        sys.argv = ["n", "--apply"]

    def state(self) -> dict:
        return json.loads(self.state_path.read_text())

    def check_held_then_sent(self):
        m = self.mod
        for name, arrange, result, reason in _situations(m.MESSAGE):
            with self.subTest(name):
                self.gate = Gate(self)
                self.posts.clear()
                self.seed_state()
                arrange(self.gate)
                rc, out = self.run_main(m.main)
                self.assertEqual(self.posts, [], f"{name}: a message left without a verdict")
                self.assertEqual(rc, 3 if result == "error" else 0, out)
                self.assertIn("held=1 (" + reason, out)
                self.assertIn(f"HELD by the copy gate ({result})", out)
                self.assertNotIn("T1", self.state())
                self.assertNotIn("conv:C1", self.state())
                self.assertFalse((self.dir / "send.log").exists(), "the send log claims a send that did not happen")
                row = self.gate.log()[-1]
                self.assertEqual((row["result"], row["family"], row["ref"], row["body_sha256"]),
                                 (result, m.COPY_FAMILY, "C1", sha(m.MESSAGE)))
                self.assertTrue(row["reason"].startswith(reason))
        # The verdict arrives: the held ticket is offered again and goes out once, as those bytes.
        self.gate = Gate(self)
        self.gate.approve(m.MESSAGE)
        rc, out = self.run_main(m.main)
        self.assertEqual(rc, 0, out)
        self.assertEqual([b for _, b in self.posts], [m.MESSAGE])
        self.assertIn("T1", self.state())
        self.assertIn("held=0 ", out)
        asked, sent = self.gate.log()
        self.assertEqual((asked["result"], sent["result"], sent["message_id"]), ("approved", "sent", "part-1"))
        self.assertEqual(sent["verdict_id"], "ocv-" + sha(m.MESSAGE)[:16])
        rc, _ = self.run_main(m.main)
        self.assertEqual((rc, len(self.posts)), (0, 1))


class OverdueNotifierGate(_TicketNotifier):
    mod, prefix = overdue, "OVERDUE_NOTIFY"

    def seed_state(self):
        self.state_path.write_text(json.dumps({"OLD": 1781784000 - 100}))
        (self.dir / "send.log").unlink(missing_ok=True)

    def task(self):
        now = 1781784000
        return {"id": "T1", "status": {"type": "open"},
                "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
                "custom_fields": [{"id": overdue.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
                "description": '---ACTION-REQUEST---\n{"customer_email": "a@b.com"}\n---END-ACTION-REQUEST---',
                "due_date": str((now - 5 * 86400) * 1000)}

    def conv(self):
        return {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
                "conversation_parts": {"conversation_parts": [
                    {"author": {"type": "admin", "id": overdue.CAROLINE_ADMIN_ID}}]}}

    def test_no_verdict_no_send_then_sent_once_when_the_verdict_arrives(self):
        self.check_held_then_sent()

    def test_a_hold_stops_the_batch_and_counts_every_candidate_left(self):
        tasks = [dict(self.task(), id=f"T{i}", custom_fields=[
            {"id": overdue.INTERCOM_LINK_FIELD, "value": f"/conversation/C{i}"}]) for i in (1, 2, 3)]
        overdue.fetch_all_tasks = lambda key, lid: tasks
        self.seed_state()
        rc, out = self.run_main(overdue.main)
        self.assertEqual((rc, self.posts), (0, []))
        self.assertIn("held=3 (copy_review_pending)", out)
        self.assertEqual(len(self.gate.seen()), 1, "the same fixed copy was asked about more than once")


class ResolveNotifyGate(_TicketNotifier):
    mod, prefix = resolve, "RESOLVE_NOTIFY"

    def seed_state(self):
        resolve.write_state(str(self.state_path), {resolve.SEED_SENTINEL: 1781000000, "TOLD": 1781000000,
                                                   "conv:COLD": 1781000000})
        (self.dir / "send.log").unlink(missing_ok=True)

    def task(self):
        return {"id": "T1", "status": {"type": "done"},
                "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-claim"},
                         {"name": "customer-outcome:complete"}],
                "custom_fields": [{"id": resolve.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
                "description": '---ACTION-REQUEST---\n{"customer_email": "a@b.com"}\n---END-ACTION-REQUEST---'}

    def conv(self):
        return {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
                "conversation_parts": {"conversation_parts": [{"author": {"type": "user"}}]}}

    def test_no_verdict_no_send_then_sent_once_when_the_verdict_arrives(self):
        self.check_held_then_sent()


class MergeOutcomeGate(FamilyCase):
    """merge-outcome-notify claims `attempted` BEFORE its one never-retried POST, so a held
    message must leave no claim at all."""

    MSG = mon.COPY[("profile-merge", "merged")]

    def setUp(self):
        super().setUp()
        tm.MergeOutcomeNotifyTests.setUp(self)      # its fakes; it also stubs the gate to "approved"
        self.addCleanup(tm.MergeOutcomeNotifyTests.tearDown, self)
        self.merge_dir = self.dir
        mon.sendgate._ask = self.gate_ask = _never_the_real_gate     # the real ask, refused at the real path
        mon.MERGE_OUTCOME_COPY_APPROVED = True

    wire = tm.MergeOutcomeNotifyTests.wire

    def tickets(self) -> dict:
        p = self.merge_dir / "state.json"
        return json.loads(p.read_text())["tickets"] if p.exists() else {}

    def fresh(self):
        self.gate = Gate(self)
        self.merge_dir = Path(tempfile.mkdtemp(prefix="merge-outcome-gate-"))
        os.environ["MERGE_OUTCOME_STATE"] = str(self.merge_dir / "state.json")
        return self.wire([tm.task()], {"900": tm.conv()})

    def test_no_verdict_no_send_and_no_claim_then_sent_once_when_the_verdict_arrives(self):
        for name, arrange, result, reason in _situations(self.MSG):
            with self.subTest(name):
                f = self.fresh()
                arrange(self.gate)
                rc, out = self.run_main(mon.main, ["--apply"])
                self.assertEqual(f.posts, [], f"{name}: a message left without a verdict")
                self.assertEqual(f.tags, [])
                self.assertEqual(rc, 3 if result == "error" else 0, out)
                self.assertIn('"copy-held": 1', out)
                self.assertIn(f"copy gate {result} ({reason}", out)
                self.assertNotIn("t1", self.tickets(), "a held message burned its one attempt")
                row = self.gate.log()[-1]
                self.assertEqual((row["result"], row["family"], row["ref"], row["copy"], row["body_sha256"]),
                                 (result, mon.COPY_FAMILY, "900", "profile-merge/merged", sha(self.MSG)))
        f = self.fresh()
        rc, _ = self.run_main(mon.main, ["--apply"])
        self.assertEqual((rc, f.posts), (0, []))
        self.gate.approve(self.MSG)
        rc, out = self.run_main(mon.main, ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(f.posts, [("900", "5763097", self.MSG)])
        self.assertEqual(self.tickets()["t1"]["state"], "sent")
        self.assertEqual(self.gate.log()[-1]["result"], "sent")
        rc, _ = self.run_main(mon.main, ["--apply"])
        self.assertEqual(len(f.posts), 1)

    def test_each_of_the_nine_messages_needs_its_own_verdict(self):
        f = self.fresh()
        f.tasks[:] = [tm.task("t1"), tm.task("t2", kind="track-merge", conv="901", email="b@example.com")]
        f.convs["901"] = tm.conv(email="b@example.com")
        self.gate.approve(self.MSG)
        rc, out = self.run_main(mon.main, ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(f.posts, [("900", "5763097", self.MSG)])
        self.assertIn('"copy-held": 1', out)
        self.assertNotIn("t2", self.tickets())

    def test_the_post_itself_refuses_when_the_verdict_is_gone_and_the_claim_is_undone(self):
        f = self.fresh()
        self.gate.approve(self.MSG)
        real = mon.copy_permit
        calls = []

        def once(conv_id, message):
            calls.append(conv_id)
            permit = real(conv_id, message)
            if len(calls) == 1:
                self.gate.set()         # the verdict is withdrawn between the claim and the POST
            return permit
        mon.copy_permit = once
        self.addCleanup(setattr, mon, "copy_permit", real)
        rc, out = self.run_main(mon.main, ["--apply"])
        self.assertEqual((rc, f.posts), (3, []))
        self.assertIn("after the claim; nothing sent, claim undone", out)
        self.assertNotIn("t1", self.tickets())
        self.assertNotIn("UNCONFIRMED", out)

    def test_a_verdict_scoped_to_its_copy_id_sends_because_both_asks_name_the_same_copy(self):
        """The ask before the claim and the ask at the POST once named two copy ids, so a gate
        that binds a verdict to (copy, hash) approved the first and held the second."""
        f = self.fresh()
        self.gate.set(approved_for_copy={sha(self.MSG): "profile-merge/merged"})
        rc, out = self.run_main(mon.main, ["--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(f.posts, [("900", "5763097", self.MSG)])
        asked = [row["argv"][row["argv"].index("--copy") + 1] for row in self.gate.seen()]
        self.assertEqual(asked, ["profile-merge/merged", "profile-merge/merged"])
        f = self.fresh()
        self.gate.set(approved_for_copy={sha(self.MSG): "track-merge/merged"})
        rc, out = self.run_main(mon.main, ["--apply"])
        self.assertEqual(f.posts, [], "a verdict for another copy id released this one")

    def test_every_fixed_message_has_its_own_copy_id(self):
        ids = [mon.copy_id(text) for text in mon.COPY.values()]
        self.assertEqual(sorted(ids), sorted(f"{k}/{o}" for k, o in mon.COPY))
        self.assertEqual(mon.copy_id("not one of the nine"), "")

    def test_post_reply_once_cannot_post_without_a_verdict(self):
        f = self.fresh()
        with redirect_stderr(StringIO()), self.assertRaises(sendgate.NotApproved):
            mon.post_reply_once("900", self.MSG, "t")
        self.assertEqual(f.posts, [])


sendgate_real_ask = sendgate._ask

# No case in this file may ask the gate at its REAL path: that gate's store is the live review queue. An ask that
# would reach it is refused here (it never runs), recorded, and fails the module in tearDownModule, because a
# sender under test may swallow the exception and report a hold.
REAL_PATH_ASKS: list[str] = []


def _never_the_real_gate(*args, **kwargs):
    if Path(sendgate.GATE_PATH).resolve() == Path(PINNED_GATE_PATH).resolve():
        REAL_PATH_ASKS.append(str(kwargs.get("campaign") or (args[2:3] or ["?"])[0]))
        raise AssertionError("a test asked the checked-in gate at its real path; its store is the live review queue")
    return sendgate_real_ask(*args, **kwargs)


def setUpModule():
    sendgate._ask = _never_the_real_gate


def tearDownModule():
    sendgate._ask = sendgate_real_ask
    if REAL_PATH_ASKS:
        raise AssertionError(f"asked the gate at its real path (live store): {REAL_PATH_ASKS}")


class RealGateContract(unittest.TestCase):
    """The stand-in above answers in gate.py's own shape. When gate.py is in this tree, hold the
    two together: a body the real gate has never seen is not approved.

    Every case here runs a byte-for-byte copy of the checked-in gate with ONE literal rewritten: where it
    keeps its store. The gate at its real path keeps its store at /var/lib/hydra/outbound-copy, and a suite
    run as root on node-8 can write there. The first case once asked that gate, and each QA review left a
    body in the LIVE review queue (three found 2026-11-12): a body a reviewer is asked to read, the stall
    page counts and the campaign's backlog report carries. It stayed green in CI because the pod cannot
    create that directory and the case accepted "the gate could not run" as an answer."""

    REAL = ROOT / "scripts" / "outbound_copy" / "gate.py"
    LIVE_STORE = 'STORE_DEFAULT = "/var/lib/hydra/outbound-copy"'

    def scratch(self, *policies: str) -> Path:
        """A tree holding the checked-in gate with its store moved under it; sendgate asks that gate."""
        tmp = Path(tempfile.mkdtemp(prefix="sendgate-real-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / "scripts" / "outbound_copy").mkdir(parents=True)
        (tmp / "policies").mkdir()
        src = self.REAL.read_text(encoding="utf-8")
        self.assertEqual(src.count(self.LIVE_STORE), 1, "the store default moved; this test rewrites that one literal")
        gate = tmp / "scripts" / "outbound_copy" / "gate.py"
        gate.write_text(src.replace(self.LIVE_STORE, f"STORE_DEFAULT = {str(tmp / 'store')!r}"), encoding="utf-8")
        for name in ("outbound-copy-rubric.md", "outbound-copy-reviewer.allowed_signers", *policies):
            shutil.copy(ROOT / "policies" / name, tmp / "policies" / name)
        saved = (sendgate.GATE_PATH, sendgate.LOG_PATH)
        sendgate.GATE_PATH, sendgate.LOG_PATH = gate, tmp / "sendgate.jsonl"
        self.addCleanup(lambda: (setattr(sendgate, "GATE_PATH", saved[0]), setattr(sendgate, "LOG_PATH", saved[1])))
        return tmp

    @unittest.skipUnless(REAL.is_file(), "scripts/outbound_copy/gate.py is not in this tree yet")
    def test_the_real_gate_never_approves_a_body_it_has_no_verdict_for(self):
        tmp = self.scratch("outbound-copy-enforce.json")
        body = "a body no reviewer has seen"
        # Whatever mode the SHIPPED table gives this campaign, the answer is never an approval: it is a hold, or an
        # observed send that names no verdict. "The gate could not run" is not accepted: the shipped table and
        # rubric are read here, so one that cannot be read fails this case instead of passing it.
        try:
            with redirect_stderr(StringIO()):
                permit = sendgate.require_verdict(body, family="contract", campaign="resolve-notify")
        except sendgate.NotApproved as exc:
            self.assertEqual((exc.result, exc.reason), ("pending", "copy_review_pending"))
        else:
            self.assertEqual((permit.verdict_id, permit.verdict_sha256), ("", ""))
        # The body is queued in the scratch store. A gate writes to one store, so this is also the proof that the
        # ask did not reach the live queue.
        queued = [json.loads(q.read_text(encoding="utf-8")) for q in (tmp / "store" / "pending").glob("*.json")]
        self.assertEqual([q["body"] for q in queued], [body])

    @unittest.skipUnless(REAL.is_file(), "scripts/outbound_copy/gate.py is not in this tree yet")
    def test_the_real_gate_in_a_scratch_tree_observes_or_holds_by_its_own_table(self):
        tmp = self.scratch()
        modes = tmp / "policies" / "outbound-copy-enforce.json"

        def ask(body):
            with redirect_stderr(StringIO()):
                return sendgate.require_verdict(body, family="contract", campaign="resolve-notify")
        body = "hi! quick update on your request with us: it's all sorted now on our side."
        table = {"version": 1, "default": "enforce", "enforce": [], "observe": [], "retired": []}
        modes.write_text(json.dumps(table))
        with self.assertRaises(sendgate.NotApproved) as cm:
            ask(body)
        self.assertEqual((cm.exception.result, cm.exception.reason), ("pending", "copy_review_pending"))
        modes.write_text(json.dumps({**table, "default": "observe"}))
        permit = ask(body)
        self.assertEqual((permit.body_sha256, permit.verdict_id), (sha(body), ""))
        rows = [json.loads(x) for x in sendgate.LOG_PATH.read_text().splitlines()]
        self.assertEqual((rows[-1]["result"], rows[-1]["reason"]), ("observed", "observed:pending"))
        # observe mode never sends what the code lint refuses, and a table nobody can read holds everything
        with self.assertRaises(sendgate.NotApproved) as cm:
            ask("hi! your account was flagged for fraud.")
        self.assertEqual(cm.exception.result, "refused")
        modes.unlink()
        with self.assertRaises(sendgate.NotApproved) as cm:
            ask(body)
        self.assertEqual(cm.exception.result, "error")


if __name__ == "__main__":
    unittest.main()
