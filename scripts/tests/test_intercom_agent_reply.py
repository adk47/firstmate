"""The caller for an agent-composed Intercom reply (scripts/intercom-agent-reply.py).

What is proven here, each against a REAL ledger (temp sqlite, the module's own schema) and the
real caller code:

  * nothing is posted without a signed copy-gate verdict on those exact bytes, and a pending
    review is a HOLD (exit 3) that claims nothing, so the reply is offered again later;
  * the shared one-message-per-person-per-UTC-day rule and the conversation key are claimed
    BEFORE the POST and finalized after it, so a second send to the same person that day - or
    a thread another reply campaign already answered - is skipped without a POST;
  * a writer that posted nothing (rc 3 HELD, rc 1 refused, rc 2 error) gives the claim back as a
    deferred LOG, so the same day can try again with new copy;
  * a writer whose POST may have landed (rc 4, or exit 0 without its POSTED line) holds the day:
    "uncertain" is never retried blind;
  * an approved, posted reply's ledger row is a CLEAN approval stamp (`audit_stamps` finds no
    problem), naming the verdict id and the campaign the copy gate approves.

The copy gate is a faked `sendgate.require_verdict` and the writer is a stand-in executable, so
no network, no model and no Intercom call happens here. Stdlib only.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import verify_ledger  # noqa: E402
from outbound_copy import sendgate  # noqa: E402


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


agent = load("intercom_agent_reply", "intercom-agent-reply.py")

VERDICT = "ocv-0123456789abcdef"
CONV = "215476322440709"
USER = "someone@example.com"
BODY = "Hi there - your two credits are on the profile now, and both are live."


class FakeGate:
    """Stands in for sendgate.require_verdict. Records what it was asked, answers as told."""

    def __init__(self):
        self.calls = []
        self.answer = ("approved", "", VERDICT, "b" * 64)

    def __call__(self, body, **kw):
        self.calls.append({"body": body, **kw})
        result, reason, vid, vsha = self.answer
        if result not in ("approved", "observed"):
            raise sendgate.NotApproved(result, reason)
        return sendgate.Permit(family="agent-reply", campaign="agent-reply", copy=kw.get("copy", ""),
                               body_sha256=__import__("hashlib").sha256(body.encode()).hexdigest(),
                               subject_sha256=__import__("hashlib").sha256(b"").hexdigest(),
                               verdict_id=vid, verdict_sha256=vsha)


FAKE_WRITER = '''#!/usr/bin/env python3
import hashlib, json, os, sys, time
ctl = json.load(open(os.environ["FAKE_WRITER_CTL"]))
open(os.environ["FAKE_WRITER_LOG"], "a").write(json.dumps(sys.argv[1:]) + "\\n")
open(os.environ["FAKE_WRITER_LOG"] + ".started", "a").write("x")
if "--body-file" in sys.argv:
    # what the writer would actually post: the real one reads it with BODY="$(cat ...)", which strips trailing newlines
    raw = open(sys.argv[sys.argv.index("--body-file") + 1], "rb").read()
    open(os.environ["FAKE_WRITER_LOG"] + ".body", "w").write(hashlib.sha256(raw.rstrip(b"\\n")).hexdigest())
hold = ctl.get("hold")
if hold:
    end = time.time() + 10
    while time.time() < end and not os.path.exists(hold):
        time.sleep(0.02)
if ctl.get("signal"):
    os.kill(os.getpid(), int(ctl["signal"]))
conv = sys.argv[sys.argv.index("--conversation") + 1]
sys.stdout.write(ctl.get("stdout", "").replace("<conv>", conv))
sys.stderr.write(ctl.get("stderr", ""))
sys.exit(int(ctl.get("rc", 0)))
'''


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.ledger = str(self.dir / "ledger.sqlite3")
        self.db = verify_ledger.connect(self.ledger)
        self.writer = self.dir / "writer.py"
        self.writer.write_text(FAKE_WRITER)
        self.writer.chmod(0o755)
        self.ctl = self.dir / "ctl.json"
        self.wlog = self.dir / "writer.log"
        self.set_writer(rc=0, stdout="POSTED comment conversation=<conv> part=part-1\n")
        self.gate = FakeGate()
        self._saved = (agent.OPS_WRITE, sendgate.require_verdict)
        agent.OPS_WRITE = str(self.writer)
        sendgate.require_verdict = self.gate
        os.environ["FAKE_WRITER_CTL"] = str(self.ctl)
        os.environ["FAKE_WRITER_LOG"] = str(self.wlog)

    def tearDown(self):
        agent.OPS_WRITE, sendgate.require_verdict = self._saved
        self.db.close()
        self.tmp.cleanup()

    def set_writer(self, **kw):
        self.ctl.write_text(json.dumps(kw))

    def posted(self) -> list[list[str]]:
        if not self.wlog.exists():
            return []
        return [json.loads(line) for line in self.wlog.read_text().splitlines() if line.strip()]

    def rows(self, sql="SELECT * FROM verify_messages ORDER BY id", args=()):
        return self.db.execute(sql, args).fetchall()

    def run_send(self, db=None, **kw):
        args = {"conversation_id": CONV, "body": BODY, "agent": "caroline", "user_key": USER,
                "day": "2026-11-15"}
        args.update(kw)
        return agent.send(self.db if db is None else db, **args)


class SendsOnlyOnASignedVerdict(Base):
    def test_a_signed_approve_posts_once_and_finalizes_sent(self):
        out = self.run_send()
        self.assertEqual(out["result"], "sent", out)
        self.assertEqual(len(self.posted()), 1, "exactly one POST")
        argv = self.posted()[0]
        self.assertIn("--agent", argv)
        self.assertEqual(argv[argv.index("--agent") + 1], "caroline")
        self.assertIn("--customer-facing", argv)
        self.assertEqual(argv[argv.index("--gate-campaign") + 1], "agent-reply")
        row = self.rows()[0]
        self.assertEqual(row["status"], "sent")
        self.assertEqual(row["campaign"], "agent-reply")
        self.assertEqual(row["copy_verdict_id"], VERDICT)
        self.assertEqual(row["copy_review"], "approved")
        self.assertEqual(row["approver_kind"], "copy-gate")
        self.assertEqual(row["approval_id"], VERDICT)
        self.assertEqual(row["approved_by"], VERDICT)
        self.assertEqual(row["message_id"], "part-1")
        self.assertEqual(row["day"], "2026-11-15")
        # the conversation key exists so the other reply campaign can see it
        req = self.db.execute("SELECT campaign, request_id, status FROM verify_requests").fetchall()
        self.assertEqual([(r[0], r[1], r[2]) for r in req], [("agent-reply", f"conv-{CONV}", "sent")])

    def test_a_newline_terminated_body_is_gated_and_posted_as_the_same_bytes(self):
        """The writer reads the body with `BODY="$(cat "$BODY_FILE")"`, which strips trailing newlines, so a
        newline-terminated file would be gated on one sha and posted as another and the writer's own ask would hold
        it forever. The caller normalizes before the first ask, so all three name the same bytes (QA 2026-11-15)."""
        out = self.run_send(body=BODY + "\n")
        self.assertEqual(out["result"], "sent", out)
        self.assertEqual(self.gate.calls[0]["body"], BODY, "the gate is asked about the bytes that are posted")
        posted_sha = Path(str(self.wlog) + ".body").read_text()
        self.assertEqual(posted_sha, sha(BODY), "the writer posts the bytes the verdict names")
        self.assertEqual(self.rows()[0]["body_sha256"], sha(BODY))

    def test_the_row_is_a_clean_approval_stamp(self):
        self.run_send()
        audit = verify_ledger.audit_stamps(self.db, since_day="2026-11-01",
                                          registry=ROOT / "policies" / "fable-rulings.json")
        self.assertEqual(audit["checked"], 1)
        self.assertEqual(audit["problems"], [], "a copy-gate send is a stamped send, not a finding")

    def test_a_pending_review_claims_nothing_and_posts_nothing(self):
        self.gate.answer = ("pending", "pending", "", "")
        out = self.run_send()
        self.assertEqual(out["result"], "held", out)
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.rows(), [], "a hold must not consume the person's day")

    def test_a_refused_body_posts_nothing(self):
        self.gate.answer = ("refused", "accusation_word: 'fraud'", "", "")
        out = self.run_send()
        self.assertEqual(out["result"], "refused", out)
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.rows(), [])

    def test_the_gate_is_asked_about_the_bytes_that_would_be_posted(self):
        self.run_send(copy="frame-a")
        self.assertEqual(self.gate.calls[0]["body"], BODY)
        self.assertEqual(self.gate.calls[0]["campaign"], "agent-reply")
        self.assertEqual(self.gate.calls[0]["copy"], "frame-a")


class TheSharedLedgerRules(Base):
    def test_one_message_per_person_per_utc_day_across_conversations(self):
        self.assertEqual(self.run_send()["result"], "sent")
        out = self.run_send(conversation_id="215476322440710")
        self.assertEqual(out["result"], "skipped", out)
        self.assertTrue(out["reason"].startswith("daily_cap"), out)
        self.assertEqual(len(self.posted()), 1, "the second reply never reached the writer")
        self.assertEqual(len(self.gate.calls), 1, "and the gate was not asked again")

    def test_a_conversation_the_backlog_drain_answered_is_skipped(self):
        verify_ledger.claim(self.db, user_key=USER, day="2026-11-14", request_ids=[f"conv-{CONV}"],
                            message_type="comment", approved_by="U7RP6HKUZ", approval_ref="Fable R25",
                            campaign=verify_ledger.BACKLOG_REPLY)
        out = self.run_send(day="2026-11-15")
        self.assertEqual(out["result"], "skipped", out)
        self.assertIn("conversation_already_answered:backlog-reply", out["reason"])
        self.assertEqual(self.posted(), [])

    def test_an_answered_conversation_is_not_answered_again_the_next_day(self):
        self.assertEqual(self.run_send(day="2026-11-15")["result"], "sent")
        out = self.run_send(day="2026-11-16")
        self.assertEqual(out["result"], "skipped", out)
        self.assertIn("conversation_already_answered:agent-reply", out["reason"])
        self.assertEqual(len(self.posted()), 1)

    def test_a_claim_with_no_identity_is_refused_before_anything_else(self):
        out = self.run_send(user_key="")
        self.assertEqual(out["result"], "refused", out)
        self.assertTrue(out["reason"].startswith("no_identity"), out)
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.gate.calls, [])

    def test_a_contact_id_is_a_valid_identity(self):
        out = self.run_send(user_key="", contact_id="65f000000000000000000001")
        self.assertEqual(out["result"], "sent", out)
        self.assertEqual(self.rows()[0]["user_key"], "intercom-contact:65f000000000000000000001")


class TheClaimComesFirst(Base):
    def test_the_ledger_row_exists_when_the_writer_runs(self):
        """QA 2026-11-15 finding 1: claim before the writer can POST, or two runs both post and one is invisible."""
        release = self.dir / "release"
        self.set_writer(rc=0, stdout=f"POSTED comment conversation={CONV} part=part-1\n", hold=str(release))
        err = []

        def run():
            # a sqlite connection belongs to the thread that made it, so the posting run opens its own
            db = verify_ledger.connect(self.ledger)
            try:
                self.run_send(db=db)
            except Exception as exc:  # pragma: no cover - a thread's failure must surface
                err.append(exc)
            finally:
                db.close()

        t = threading.Thread(target=run)
        t.start()
        started = Path(str(self.wlog) + ".started")
        for _ in range(500):
            if started.exists():
                break
            time.sleep(0.02)
        self.assertTrue(started.exists(), "the writer never ran")
        row = self.rows()
        self.assertEqual(len(row), 1, "the claim must be on the ledger before the writer starts")
        self.assertEqual(row[0]["status"], "attempted", "an unconfirmed POST holds the day from the first instant")
        # a second run for the same person, while the first is still posting, must not reach the writer
        second = self.run_send(conversation_id="215476322440710")
        self.assertEqual(second["result"], "skipped", second)
        self.assertTrue(second["reason"].startswith("daily_cap"), second)
        self.assertEqual(len(self.posted()), 1, "only the first run ever reached the writer")
        release.write_text("go")
        t.join()
        self.assertEqual(err, [])
        self.assertEqual([r["status"] for r in self.rows()], ["sent"])


class WhenTheWriterDidNotPost(Base):
    def test_held_gives_the_claim_back_so_the_same_day_can_try_again(self):
        self.set_writer(rc=3, stderr="HELD: no signed verdict yet\n")
        out = self.run_send()
        self.assertEqual(out["result"], "held", out)
        row = self.rows()[0]
        self.assertEqual(row["status"], "deferred", "a hold is a log, not a lock")
        self.assertTrue(str(row["reason"]).startswith("copy_review:"), row["reason"])
        # the day is free again: new copy, approved, posted
        self.set_writer(rc=0, stdout=f"POSTED comment conversation={CONV} part=part-2\n")
        again = self.run_send(body=BODY + " Sorry for the wait.")
        self.assertEqual(again["result"], "sent", again)
        self.assertEqual(len(self.posted()), 2)
        sent = self.rows("SELECT status FROM verify_messages ORDER BY id")
        self.assertEqual([r[0] for r in sent], ["deferred", "sent"])

    def test_a_refusal_gives_the_claim_back_too(self):
        self.set_writer(rc=1, stderr="REFUSED: the customer-facing body contains internal wording\n")
        out = self.run_send()
        self.assertEqual(out["result"], "refused", out)
        self.assertEqual(self.rows()[0]["status"], "deferred")

    def test_a_maybe_posted_reply_holds_the_day(self):
        self.set_writer(rc=4, stderr="POST FAILED (curl rc=56)\n")
        out = self.run_send()
        self.assertEqual(out["result"], "uncertain", out)
        self.assertEqual(self.rows()[0]["status"], "attempted")
        # never retried blind: the same person cannot be messaged again today
        self.set_writer(rc=0, stdout=f"POSTED comment conversation={CONV} part=part-9\n")
        again = self.run_send(conversation_id="215476322440710")
        self.assertEqual(again["result"], "skipped", again)
        self.assertTrue(again["reason"].startswith("daily_cap"), again)

    def test_exit_zero_without_a_posted_line_is_uncertain(self):
        self.set_writer(rc=0, stdout="VALID comment conversation=1\n")
        out = self.run_send()
        self.assertEqual(out["result"], "uncertain", out)
        row = self.rows()[0]
        self.assertEqual(row["status"], "attempted")
        self.assertEqual(row["reason"], "posted_line_unreadable")


class AnExitThatIsNotACleanNo(Base):
    def test_a_writer_killed_after_it_may_have_posted_holds_the_day(self):
        """A signal is not the writer's "I posted nothing": the POST may have landed (QA carried-forward finding 1)."""
        self.set_writer(signal=9)
        out = self.run_send()
        self.assertEqual(out["result"], "uncertain", out)
        row = self.rows()[0]
        self.assertEqual(row["status"], "attempted", "a killed writer keeps the claim")
        self.assertIn("post_may_have_landed", row["reason"])
        again = self.run_send(conversation_id="215476322440710")
        self.assertEqual(again["result"], "skipped", again)
        self.assertTrue(again["reason"].startswith("daily_cap"), "the person cannot be messaged twice today")

    def test_an_exit_the_writer_does_not_document_holds_the_day_too(self):
        self.set_writer(rc=7, stderr="traceback: connection reset\n")
        out = self.run_send()
        self.assertEqual(out["result"], "uncertain", out)
        self.assertEqual(self.rows()[0]["status"], "attempted")


class TheDayIsClaimedWhenThePostHappens(Base):
    def setUp(self):
        super().setUp()
        self._utcnow = agent.utcnow

    def tearDown(self):
        agent.utcnow = self._utcnow
        super().tearDown()

    def test_a_reply_written_before_midnight_is_recorded_on_the_day_it_went_out(self):
        """A day fixed before the copy gate's answer leaves the delivery day unclaimed (QA carried-forward finding 2)."""
        import datetime as dt
        agent.utcnow = lambda: dt.datetime(2026, 11, 16, 0, 0, 5, tzinfo=dt.timezone.utc)
        out = self.run_send(day="", now=dt.datetime(2026, 11, 15, 23, 59, 59, tzinfo=dt.timezone.utc))
        self.assertEqual(out["result"], "sent", out)
        self.assertEqual(self.rows()[0]["day"], "2026-11-16")

    def test_a_writer_that_stalls_across_midnight_still_holds_the_new_day(self):
        """The guard waits a boundary out, but the writer has no latency bound: a claim at 23:59:45 whose POST is
        accepted at 00:00:02 is recorded yesterday and delivered today, so a second conversation for the same person
        today must not pass (QA 2026-11-15)."""
        import datetime as dt
        agent.utcnow = lambda: dt.datetime(2026, 11, 15, 23, 59, 45, tzinfo=dt.timezone.utc)
        first = self.run_send(day="", now=dt.datetime(2026, 11, 15, 23, 59, 45, tzinfo=dt.timezone.utc))
        self.assertEqual(first["result"], "sent", first)
        self.assertEqual([r["day"] for r in self.rows()], ["2026-11-15"])

        agent.utcnow = lambda: dt.datetime(2026, 11, 16, 0, 0, 2, tzinfo=dt.timezone.utc)
        second = self.run_send(conversation_id="215476322440710", day="",
                               now=dt.datetime(2026, 11, 16, 0, 0, 2, tzinfo=dt.timezone.utc))
        self.assertEqual(second["result"], "skipped", second)
        self.assertRegex(second["reason"], r"^(recent_reply:|daily_cap)", second["reason"])
        self.assertEqual(len(self.posted()), 1, "one message to this person, not two on the day it arrived")

    def test_a_run_that_passed_the_precheck_before_another_claimed_cannot_post(self):
        """The precheck is not the authority (QA 2026-11-15): two runs can both pass it before either claims, so the
        rolling interval is enforced inside the claim's own transaction. Run A passed its precheck, run B claimed and
        posted, and A's claim must then be refused."""
        import datetime as dt
        agent.utcnow = lambda: dt.datetime(2026, 11, 15, 23, 59, 45, tzinfo=dt.timezone.utc)
        first = self.run_send(day="", now=dt.datetime(2026, 11, 15, 23, 59, 45, tzinfo=dt.timezone.utc))
        self.assertEqual(first["result"], "sent", first)

        was_precheck = agent.precheck
        agent.precheck = lambda *a, **k: ""          # run A already passed it, before run B claimed
        try:
            agent.utcnow = lambda: dt.datetime(2026, 11, 16, 0, 0, 3, tzinfo=dt.timezone.utc)
            second = self.run_send(conversation_id="215476322440710", day="",
                                   now=dt.datetime(2026, 11, 16, 0, 0, 3, tzinfo=dt.timezone.utc))
        finally:
            agent.precheck = was_precheck
        self.assertEqual(second["result"], "skipped", second)
        self.assertRegex(second["reason"], r"min_interval|daily_cap", second["reason"])
        self.assertEqual(len(self.posted()), 1, "the claim, not the precheck, decides")

    def test_another_campaigns_reply_that_crossed_midnight_holds_today(self):
        """The shared cap, not just this caller: a row another campaign claimed at 23:59:45 is recorded on yesterday
        and delivered today, so today must read as capped for every campaign (QA 2026-11-15)."""
        import datetime as dt
        yesterday = dt.datetime(2026, 11, 15, 23, 59, 45, tzinfo=dt.timezone.utc)
        claimed = verify_ledger.claim(self.db, user_key=USER, day="2026-11-15",
                                      request_ids=["conv-215476322440799"], message_type="comment",
                                      approved_by="U7RP6HKUZ", approval_ref="test",
                                      campaign=verify_ledger.BACKLOG_REPLY, conversation="215476322440799",
                                      now=yesterday)
        # the POST is accepted at 00:00:02 on the 16th: the row keeps the 15th and `sent_at` records the 16th
        verify_ledger.finalize(self.db, message_row=claimed["message_row"], status="sent", message_id="part-6",
                               now=dt.datetime(2026, 11, 16, 0, 0, 2, tzinfo=dt.timezone.utc))
        # The cap reads the day and no clock, so the 16th is held to its END: at 23:59:50 on the 16th the row is
        # outside a rolling 24 hours AND carries the 15th, and a check on either of those misses it (QA 2026-11-15,
        # the late-next-day case).
        self.assertTrue(verify_ledger.capped(self.db, user_key=USER, day="2026-11-16"),
                        "a message claimed a second before midnight holds the whole day it arrived on")
        # The 17th is free: the reply was delivered on the 16th, and the rule is one per delivery day.
        self.assertFalse(verify_ledger.capped(self.db, user_key=USER, day="2026-11-17"),
                         "a reply delivered on the 16th does not hold the 17th")
        # A message claimed in the morning was delivered that day, so the next day is free: the hold is the delivery
        # day, not a rolling 24 hours (a rolling window would block a legitimate next-morning message).
        morning = dt.datetime(2026, 11, 18, 10, 0, 0, tzinfo=dt.timezone.utc)
        claimed = verify_ledger.claim(self.db, user_key="morning@example.com", day="2026-11-18",
                                      request_ids=["conv-215476322440798"], message_type="comment",
                                      approved_by="U7RP6HKUZ", approval_ref="test",
                                      campaign=verify_ledger.BACKLOG_REPLY, conversation="215476322440798",
                                      now=morning)
        verify_ledger.finalize(self.db, message_row=claimed["message_row"], status="sent", message_id="part-9",
                               now=morning)
        self.assertFalse(verify_ledger.capped(self.db, user_key="morning@example.com", day="2026-11-19"),
                         "a message claimed in the morning does not hold the next day")

    def test_a_post_that_lands_after_midnight_holds_the_day_it_landed_on(self):
        """QA 2026-11-15: the writer has no bounded POST latency, so a claim at 22:30 can be accepted at 00:01. The
        row keeps its claim day and `sent_at` records the delivery, so the day the customer received it is held."""
        import datetime as dt
        claimed = verify_ledger.claim(self.db, user_key="late@example.com", day="2026-11-15",
                                      request_ids=["conv-215476322440797"], message_type="comment",
                                      approved_by="U7RP6HKUZ", approval_ref="test",
                                      campaign=verify_ledger.BACKLOG_REPLY, conversation="215476322440797",
                                      now=dt.datetime(2026, 11, 15, 22, 30, tzinfo=dt.timezone.utc))
        verify_ledger.finalize(self.db, message_row=claimed["message_row"], status="sent", message_id="part-7",
                               now=dt.datetime(2026, 11, 16, 0, 1, tzinfo=dt.timezone.utc))
        self.assertTrue(verify_ledger.capped(self.db, user_key="late@example.com", day="2026-11-16"),
                        "a reply accepted at 00:01 holds the day it was delivered on")
        # ...and a reply delivered at 23:30 on the 15th does NOT hold the 16th: the rule is one per delivery day.
        claimed = verify_ledger.claim(self.db, user_key="early@example.com", day="2026-11-15",
                                      request_ids=["conv-215476322440796"], message_type="comment",
                                      approved_by="U7RP6HKUZ", approval_ref="test",
                                      campaign=verify_ledger.BACKLOG_REPLY, conversation="215476322440796",
                                      now=dt.datetime(2026, 11, 15, 23, 0, tzinfo=dt.timezone.utc))
        verify_ledger.finalize(self.db, message_row=claimed["message_row"], status="sent", message_id="part-8",
                               now=dt.datetime(2026, 11, 15, 23, 30, tzinfo=dt.timezone.utc))
        self.assertFalse(verify_ledger.capped(self.db, user_key="early@example.com", day="2026-11-16"),
                         "a reply delivered on the 15th does not hold the 16th")

    def test_an_unresolved_attempt_holds_every_day_until_it_is_reconciled(self):
        """QA 2026-11-15: the writer has no POST latency bound, so a claim on the 15th can still be in flight on the
        17th. An `attempted` row is a message that may have been delivered and whose day nobody knows, so it holds
        every day until it is reconciled, not just the day after its claim."""
        import datetime as dt
        verify_ledger.claim(self.db, user_key="stalled@example.com", day="2026-11-15",
                            request_ids=["conv-215476322440795"], message_type="comment",
                            approved_by="U7RP6HKUZ", approval_ref="test",
                            campaign=verify_ledger.BACKLOG_REPLY, conversation="215476322440795",
                            now=dt.datetime(2026, 11, 15, 12, 0, tzinfo=dt.timezone.utc))
        for day in ("2026-11-16", "2026-11-17", "2026-12-01"):
            self.assertTrue(verify_ledger.capped(self.db, user_key="stalled@example.com", day=day),
                            f"an unresolved attempt still holds {day}")

    def test_a_pinned_day_is_the_claim_day_and_the_delivery_day_is_what_holds(self):
        """A pinned day is the day the claim is made on. The row keeps it, and `sent_at` records when the POST
        landed, so the cap holds the day the customer actually received the reply (QA 2026-11-15)."""
        import datetime as dt
        agent.utcnow = lambda: dt.datetime(2026, 11, 16, 0, 0, 5, tzinfo=dt.timezone.utc)
        out = self.run_send(now=dt.datetime(2026, 11, 15, 23, 59, 59, tzinfo=dt.timezone.utc),
                            day="2026-11-15")
        self.assertEqual(out["result"], "sent", out)
        row = self.rows()[0]
        self.assertEqual(row["day"], "2026-11-15", "the pinned day is the day the claim was made on")
        self.assertEqual(row["sent_at"][:10], "2026-11-16", "the send is recorded when the POST landed")
        self.assertTrue(verify_ledger.capped(self.db, user_key=USER, day="2026-11-16"),
                        "the day the customer received it is held")


class CommandLine(Base):
    def run_main(self, *argv):
        buf = StringIO()
        with redirect_stdout(buf):
            rc = agent.main(list(argv))
        return rc, buf.getvalue()

    def body_file(self, text=BODY) -> str:
        p = self.dir / "body.txt"
        p.write_text(text)
        return str(p)

    def test_a_dry_run_is_the_default_and_writes_nothing(self):
        rc, out = self.run_main("--conversation", CONV, "--body-file", self.body_file(),
                                "--user-key", USER, "--ledger", self.ledger)
        self.assertEqual(rc, 0, out)
        self.assertIn("DRY-RUN would send", out)
        self.assertEqual(self.rows(), [])
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.gate.calls, [], "a dry run asks neither the reviewer nor the writer")

    def test_a_dry_run_says_why_it_would_skip(self):
        self.assertEqual(self.run_send()["result"], "sent")
        rc, out = self.run_main("--conversation", CONV, "--body-file", self.body_file(),
                                "--user-key", USER, "--ledger", self.ledger)
        self.assertEqual(rc, 0, out)
        self.assertIn("would skip", out)

    def test_apply_posts_and_a_hold_exits_3(self):
        rc, out = self.run_main("--conversation", CONV, "--body-file", self.body_file(),
                                "--user-key", USER, "--ledger", self.ledger, "--apply")
        self.assertEqual(rc, 0, out)
        self.assertIn("SENT", out)
        self.gate.answer = ("pending", "pending", "", "")
        rc, out = self.run_main("--conversation", "215476322440710", "--body-file", self.body_file(),
                                "--user-key", "another@example.com", "--ledger", self.ledger, "--apply")
        self.assertEqual(rc, 3, out)
        self.assertIn("HELD", out)

    def test_the_command_line_never_pins_the_day_it_started_in(self):
        """`--apply` must let the claim choose the day: a day pinned from the run's start is the original bug, and
        the reply's real delivery day then goes unclaimed (QA 2026-11-15, carried-forward finding 2)."""
        import datetime as dt
        clock = [dt.datetime(2026, 11, 15, 23, 59, 58, tzinfo=dt.timezone.utc)]
        slept = []
        was_now, was_sleep = agent.utcnow, agent.time.sleep

        def sleep(seconds):
            slept.append(seconds)
            clock[0] = dt.datetime(2026, 11, 16, 0, 0, 0, 200000, tzinfo=dt.timezone.utc)

        agent.utcnow = lambda: clock[0]
        agent.time.sleep = sleep
        try:
            rc, out = self.run_main("--conversation", CONV, "--body-file", self.body_file(),
                                    "--user-key", USER, "--ledger", self.ledger, "--apply")
        finally:
            agent.utcnow, agent.time.sleep = was_now, was_sleep
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(slept), 1, "a claim two seconds before midnight must wait the boundary out")
        self.assertAlmostEqual(slept[0], 2.2, places=1)
        self.assertEqual([r["day"] for r in self.rows()], ["2026-11-16"])

    def test_an_empty_identity_or_body_is_a_usage_error(self):
        rc, _ = self.run_main("--conversation", CONV, "--body-file", self.body_file(), "--ledger", self.ledger)
        self.assertEqual(rc, 2)
        rc, _ = self.run_main("--conversation", CONV, "--body-file", self.body_file("   "),
                              "--user-key", USER, "--ledger", self.ledger)
        self.assertEqual(rc, 2)


class TheCopyGateStamp(unittest.TestCase):
    def test_a_well_formed_copy_gate_stamp_round_trips(self):
        kind, aid, tsha = verify_ledger.approval_stamp(
            kind=verify_ledger.APPROVER_COPY_GATE, approval_id=VERDICT, approved_by=VERDICT,
            template_sha256=verify_ledger.template_identity_sha256(
                campaign=verify_ledger.AGENT_REPLY, kind="initial", copy_ref=""))
        self.assertEqual(kind, "copy-gate")
        self.assertEqual(aid, VERDICT)
        self.assertEqual(len(tsha), 64)

    def test_a_stamp_whose_id_is_not_a_verdict_is_rejected(self):
        for bad in ("U7RP6HKUZ", "ocv-XYZ", "fable-ruling-20260101-1"):
            with self.assertRaises(ValueError, msg=bad):
                verify_ledger.approval_stamp(kind=verify_ledger.APPROVER_COPY_GATE, approval_id=bad,
                                             approved_by=bad)

    def test_the_audit_names_each_way_a_copy_gate_row_can_be_wrong(self):
        tsha = verify_ledger.template_identity_sha256(campaign="agent-reply", kind="initial", copy_ref="")
        good = ["1", "agent-reply", "sent", "2026-11-15", "initial", "", "copy-gate", VERDICT, tsha, VERDICT, "",
                "2026-11-15T06:00:00Z"]
        self.assertEqual(verify_ledger.stamp_problem(good, {}), "")
        # row layout: 1 campaign, 5 copy_ref, 6 approver kind, 7 approval id, 8 template hash, 9 approved_by
        cases = {
            7: ("ocv-nothex", "not an ocv-<16 hex> verdict id"),
            9: ("ocv-ffffffffffffffff", "approved_by is"),
            8: ("f" * 63, "template hash"),
            6: ("captain-sig", "unknown approver kind"),
        }
        for idx, (value, expect) in cases.items():
            row = list(good)
            row[idx] = value
            self.assertIn(expect, verify_ledger.stamp_problem(row, {}), f"index {idx}")
        # a verdict for another campaign is refused even when the template hash is recomputed to match it
        row = list(good)
        row[1] = "something-else"
        row[8] = verify_ledger.template_identity_sha256(campaign="something-else", kind="initial", copy_ref="")
        self.assertIn("copy-gate authorized campaign 'something-else'", verify_ledger.stamp_problem(row, {}))

    def test_the_campaign_is_in_the_ledger_s_tables(self):
        self.assertIn("agent-reply", verify_ledger.CAMPAIGNS)
        self.assertIn("agent-reply", verify_ledger.NOTICE_CAMPAIGNS,
                      "a reply is a notice: it asks for nothing and closes no ask")


class ALedgerNobodyCouldRead(Base):
    """Every pre-check read answers for an unreadable ledger, and that answer is a refusal, never a skip and never
    a traceback (reviewer note on 05924c452: only the last of the three reads was guarded)."""

    run_main = CommandLine.run_main
    body_file = CommandLine.body_file

    def bare(self) -> sqlite3.Connection:
        db = sqlite3.connect(":memory:")  # no table at all: the FIRST read (verify_requests) fails
        self.addCleanup(db.close)
        return db

    def test_the_first_read_failing_is_a_named_refusal_and_nothing_is_asked_or_posted(self):
        out = self.run_send(db=self.bare())
        self.assertEqual(out["result"], "refused", out)
        self.assertEqual(out["reason"], "ledger_unreadable:OperationalError")
        self.assertEqual(self.gate.calls, [], "the reviewer is not asked about a reply that cannot be claimed")
        self.assertEqual(self.posted(), [])

    def test_the_cap_read_failing_is_the_same_refusal(self):
        db = self.bare()
        db.execute("CREATE TABLE verify_requests (request_id TEXT, campaign TEXT, status TEXT)")
        out = self.run_send(db=db)  # the first read now answers; the cap's read of verify_messages fails
        self.assertEqual((out["result"], out["reason"]), ("refused", "ledger_unreadable:OperationalError"), out)
        self.assertEqual(self.posted(), [])

    def test_it_is_not_reported_as_a_skip(self):
        """A skip exits 0 ("this person already has a message"); "could not read whether they do" must not."""
        self.assertEqual(agent.precheck(self.bare(), CONV, USER, "", "2026-11-15"),
                         "ledger_unreadable:OperationalError")
        def io_error(*_a, **_kw):  # connect() re-creates a missing table, so the failure here is a read that dies
            raise sqlite3.OperationalError("disk I/O error")
        real = verify_ledger.capped
        verify_ledger.capped = io_error
        self.addCleanup(setattr, verify_ledger, "capped", real)
        rc, out = self.run_main("--conversation", CONV, "--body-file", self.body_file(), "--user-key", USER,
                                "--ledger", self.ledger, "--apply")
        self.assertEqual(rc, 1, out)
        self.assertIn("REFUSED", out)
        self.assertIn("ledger_unreadable:", out)
        self.assertEqual(self.posted(), [])

    def test_a_ledger_that_cannot_be_opened_is_exit_2_in_both_modes(self):
        junk = self.dir / "junk.sqlite3"
        junk.write_bytes(b"this is not a database, " * 200)
        for extra in ([], ["--apply"]):
            with self.subTest(extra=extra), redirect_stderr(StringIO()) as err:
                rc, out = self.run_main("--conversation", CONV, "--body-file", self.body_file(), "--user-key", USER,
                                        "--ledger", str(junk), *extra)
                self.assertEqual(rc, 2, out + err.getvalue())
                self.assertIn("cannot open the ledger", err.getvalue())
        self.assertEqual(self.posted(), [])
        self.assertEqual(self.gate.calls, [])


if __name__ == "__main__":
    unittest.main()
