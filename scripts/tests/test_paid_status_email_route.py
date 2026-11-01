"""scripts/paid-status/email_route.py and health_check.py, the QA/Fable findings on #1384:
  - a transport failure (no send-gateway pod, no token, fetch error, non-2xx) stays RETRYABLE, never terminal;
    only a 2xx gateway decline is a terminal skip, and old 'send-gateway failed' rows never read as terminal;
  - a status-note silent hold (verify_ledger.hold_silent) never blocks the uvn-status ask by email;
  - the health check fails closed (exit 2) when any sent contact could not be read.
Stdlib only; no network, no kubectl."""
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..")
sys.path.insert(0, SCRIPTS)
from credit_review import verify_ledger  # noqa: E402

spec = importlib.util.spec_from_file_location("email_route", os.path.join(SCRIPTS, "paid-status", "email_route.py"))
er = importlib.util.module_from_spec(spec)
spec.loader.exec_module(er)
NOW = datetime(2026, 10, 27, 6, 0, tzinfo=timezone.utc)


class ClassifySendTest(unittest.TestCase):
    def test_sent_and_unconfirmed(self):
        self.assertEqual(er.classify_send({"http": 200, "status": "sent"}), {"status": "sent", "log": "send-gateway"})
        for st in ("unconfirmed", "sent_unrecorded"):
            self.assertEqual(er.classify_send({"status": st})["status"], "attempted")

    def test_a_2xx_gateway_decline_is_terminal(self):
        for st in ("suppressed", "skipped", "unsubscribed"):
            self.assertEqual(er.classify_send({"http": 200, "status": st}), {"status": "rejected", "log": "send-gateway"})

    def test_transport_failures_stay_retryable(self):
        for res in ({"status": "failed", "reason": "no running send-gateway pod"},
                    {"status": "failed", "reason": "no admin caller token in the pod"},
                    {"status": "failed", "reason": "fetch ECONNREFUSED"},
                    {"http": 503, "status": None, "reason": "unavailable"},
                    {"http": 401, "reason": "unauthorized"}, {"http": 429, "status": "rate_limited"}, {}):
            self.assertEqual(er.classify_send(res), {"status": "rejected", "log": "send-gateway-transport"}, res)


class PodAnswerTest(unittest.TestCase):
    """QA/Fable on 40d1cb7c: a kubectl exec that fails before Node prints anything is a retryable failure."""

    def test_an_exec_that_never_started_node_is_failed_and_retryable(self):
        ans = er.pod_answer(1, "", "error: unable to upgrade connection: container not found")
        self.assertEqual(ans["status"], "failed")
        self.assertIn("rc=1", ans["reason"])
        self.assertEqual(er.classify_send(ans), {"status": "rejected", "log": "send-gateway-transport"})

    def test_the_pods_json_answer_wins_whatever_the_exit_code(self):
        line = json.dumps({"http": 200, "status": "sent", "id": "m1"})
        self.assertEqual(er.pod_answer(0, "noise\n" + line + "\n")["status"], "sent")
        self.assertEqual(er.pod_answer(137, line)["status"], "sent")   # answered, then the exec was torn down

    def test_a_zero_exit_with_no_readable_answer_is_unconfirmed(self):
        self.assertEqual(er.pod_answer(0, "garbage")["status"], "unconfirmed")
        self.assertEqual(er.classify_send(er.pod_answer(0, ""))["status"], "attempted")

    def test_send_in_pod_maps_kubectl_failures_to_failed(self):
        import subprocess as sp
        from unittest import mock
        calls = []

        def fake(argv, **kw):
            calls.append(argv)
            if "get" in argv:
                return sp.CompletedProcess(argv, 0, "pod/send-gateway-1\n", "")
            return sp.CompletedProcess(argv, 1, "", "error: container not found")
        with mock.patch.object(er.subprocess, "run", side_effect=fake):
            self.assertEqual(er.send_in_pod({"key": "x"})["status"], "failed")
        with mock.patch.object(er.subprocess, "run", side_effect=sp.TimeoutExpired("kubectl", 60)):
            self.assertEqual(er.send_in_pod({"key": "x"})["status"], "failed")
        with mock.patch.object(er.subprocess, "run", return_value=sp.CompletedProcess([], 1, "", "forbidden")):
            self.assertEqual(er.send_in_pod({"key": "x"})["status"], "failed")


class LedgerReadsTest(unittest.TestCase):
    def setUp(self):
        self.db = verify_ledger.connect(os.path.join(tempfile.mkdtemp(), "l.sqlite3"))

    def message(self, uid, api_log, reason, status="rejected", campaign="uvn-status"):
        c = verify_ledger.claim(self.db, campaign=campaign, user_key=f"u{uid}@x.com", day="2026-10-26",
                                request_ids=[f"r{uid}-{api_log[:5]}"], message_type="email", approved_by="U7RP6HKUZ",
                                approval_ref="ref", enforce_cap=False, user_id=str(uid), now=NOW)
        verify_ledger.finalize(self.db, message_row=c["message_row"], status=status, reason=reason, api_log=api_log)

    def test_only_a_terminal_decline_skips_the_user_for_good(self):
        self.message(1, "send-gateway:abc", "send-gateway suppressed bounced")
        self.message(2, "send-gateway-transport:", "send-gateway failed no running send-gateway pod")
        self.message(3, "send-gateway:", "send-gateway failed no running send-gateway pod")   # written before the split
        self.assertEqual(er.gateway_declined_before(self.db, "uvn-status", 1, "u1@x.com"), "send-gateway suppressed bounced")
        self.assertIsNone(er.gateway_declined_before(self.db, "uvn-status", 2, "u2@x.com"))
        self.assertIsNone(er.gateway_declined_before(self.db, "uvn-status", 3, "u3@x.com"))
        # and the retryable row is re-offered by the ledger (a rejected row below MAX_ATTEMPTS blocks nothing)
        self.assertEqual(verify_ledger.blocked_ids(self.db, ["r2-send-"], "uvn-status"), set())

    def test_retired_status_copies_are_held_never_rendered_for_email(self):
        # QA #1603: the email route's status texts are retired copy (docrecvq "no need to send anything else"; the
        # pre-/k teamreview "Nothing else is needed") - both campaigns are held with a stated reason; the ask is not
        self.assertEqual(set(er.RETIRED_EMAIL), {"status-doc-received", "status-team-review"})
        self.assertNotIn("uvn-status", er.RETIRED_EMAIL)
        src = open(er.__file__).read()
        main = src[src.index("def main():"):]
        self.assertIn('if campaign in RETIRED_EMAIL:\n            done("hold", RETIRED_EMAIL[campaign]); continue', main)
        # the hold comes before ANY read or send decision for that row
        self.assertLess(main.index("if campaign in RETIRED_EMAIL:"), main.index('if a.mode == "apply" and (uid, campaign) not in approved:'))

    def test_a_status_note_silent_hold_never_blocks_the_ask(self):
        verify_ledger.hold_silent(self.db, user_ids=["7"], reason="owe-proof-told-nothing-needed", now=NOW)
        self.assertIsNone(er.other_refusal_hold(self.db, "uvn-status", "u7@x.com", 7, NOW))
        self.assertEqual(er.other_refusal_hold(self.db, "status-team-review", "u7@x.com", 7, NOW),
                         "owe-proof-told-nothing-needed")


class HealthCheckTest(unittest.TestCase):
    def run_check(self, contacts):
        """health_check.py against a stub Intercom (urllib patched via sitecustomize) and a temp ledger."""
        d = tempfile.mkdtemp()
        ledger = os.path.join(d, "ledger.sqlite3")
        db = sqlite3.connect(ledger)
        db.execute("create table verify_messages (contact_id text, status text, sent_at text, updated_at text)")
        for cid in contacts:
            db.execute("insert into verify_messages values (?, 'sent', '2026-10-27T05:00:00Z', '2026-10-27T05:00:00Z')", (cid,))
        db.commit(); db.close()
        src = open(os.path.join(SCRIPTS, "paid-status", "health_check.py")).read()
        src = src.replace("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", f"file:{ledger}?mode=ro")
        path = os.path.join(d, "hc.py"); open(path, "w").write(src)
        site = os.path.join(d, "sitecustomize.py")
        open(site, "w").write(
            "import io, json, urllib.request, urllib.error, time\n"
            "time.sleep = lambda s: None\n"
            f"C = {json.dumps(contacts)}\n"
            "class R(io.BytesIO):\n"
            "    def __enter__(self): return self\n"
            "    def __exit__(self, *a): return False\n"
            "def fake(req, timeout=None):\n"
            "    cid = req.full_url.rsplit('/', 1)[1]\n"
            "    if C[cid] is None: raise urllib.error.URLError('down')\n"
            "    return R(json.dumps(C[cid]).encode())\n"
            "urllib.request.urlopen = fake\n")
        env = {**os.environ, "PYTHONPATH": d, "MUSOAI_INTERCOM_TOKEN": "t"}
        p = subprocess.run([sys.executable, path, "--since", "2026-10-27T00:00", "--spam-baseline", "0"],
                           capture_output=True, text=True, env=env, timeout=120)
        return p.returncode, (json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {})

    def test_every_contact_read_and_clean_is_healthy(self):
        rc, out = self.run_check({f"c{i}": {} for i in range(20)})
        self.assertEqual((rc, out.get("verdict")), (0, "healthy"))

    def test_one_unreadable_contact_of_twenty_fails_closed(self):
        contacts = {f"c{i}": {} for i in range(19)}
        contacts["c19"] = None
        rc, out = self.run_check(contacts)
        self.assertEqual(rc, 2, out)
        self.assertTrue(out["verdict"].startswith("UNMEASURED"))


if __name__ == "__main__":
    unittest.main()
