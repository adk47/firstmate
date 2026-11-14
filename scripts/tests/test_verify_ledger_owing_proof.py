"""verify_ledger rules for Fable's two owing-proof lines (copy-owing-proof-1027; send-locked until L14):
credit-hold-status (S1) is a once-per-user status campaign and a notice, NOT an ask, and NOT stopped by the
hold-silent flags that stop the "nothing else is needed" notes (Fable: S1 goes to held accounts too);
claim-proof-pending (S2) follows claim-status's claim rules. Also pins the IN-list fix: the claim tuple grew
to three, and the hard-coded "NOT IN (?,?)" broke every uvn-status claim."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import verify_ledger as vl  # noqa: E402

KW = dict(message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref")
NOW = datetime(2026, 10, 28, 1, 0, tzinfo=timezone.utc)


class OwingProofTest(unittest.TestCase):
    def setUp(self):
        self.db = vl.connect(str(Path(tempfile.mkdtemp()) / "ledger.sqlite3"))

    def claim(self, campaign, ids, day="2026-10-28", user="jane@example.com", uid="42"):
        return vl.claim(self.db, user_key=user, day=day, request_ids=list(ids), campaign=campaign, user_id=uid,
                        now=datetime.fromisoformat(day + "T01:00:00+00:00"), **KW)

    def sent(self, c):
        vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id="m1")

    def test_registered(self):
        for c in ("credit-hold-status", "claim-proof-pending"):
            self.assertIn(c, vl.CAMPAIGNS)
        self.assertIn("credit-hold-status", vl.STATUS_CAMPAIGNS)
        self.assertNotIn("credit-hold-status", vl.ASK_CAMPAIGNS)
        self.assertNotIn("credit-hold-status", vl.STATUS_NOTE_CAMPAIGNS)
        self.assertIn("claim-proof-pending", vl.CLAIM_CAMPAIGNS)
        self.assertNotIn("claim-proof-pending", vl.ASK_CAMPAIGNS)

    def test_s1_once_per_user_ever_and_never_an_ask(self):
        c = self.claim("credit-hold-status", ["r1"])
        self.assertEqual(c["result"], "claimed")
        self.sent(c)
        self.assertFalse(vl.asked_within(self.db, user_key="jane@example.com", day="2026-10-29", user_id="42"))
        later = self.claim("credit-hold-status", ["r2"], day="2026-12-30")
        self.assertEqual((later["result"], later.get("reason")), ("user_done", "already_sent"))
        # within 7 days of S1, a status note defers (messaged_7d), nothing closed
        tr = self.claim("status-team-review", ["r3"], day="2026-10-30")
        self.assertEqual((tr["result"], tr.get("reason")), ("recent", "messaged_7d"))

    def test_s1_is_not_blocked_by_an_ask_on_the_same_credit(self):
        self.sent(self.claim("uvn-status", ["r1"], day="2026-09-01"))
        self.assertEqual(vl.blocked_ids(self.db, ["r1"], "credit-hold-status"), set())

    def test_hold_silent_does_not_stop_s1(self):
        vl.hold_silent(self.db, user_ids=["42"], reason="account-hold")
        self.assertTrue(vl.refusal_hold(self.db, "status-team-review", "jane@example.com", user_id="42"))
        self.assertEqual(vl.refusal_hold(self.db, "credit-hold-status", "jane@example.com", user_id="42"), {})
        self.assertEqual(self.claim("credit-hold-status", ["r1"])["result"], "claimed")

    def test_s2_follows_the_claim_status_rules(self):
        c = self.claim("claim-proof-pending", ["claim-1"], day="2026-10-28")
        self.assertEqual(c["result"], "claimed")
        self.sent(c)
        ask = self.claim("claim-proof-ask", ["claim-2"], day="2026-11-02")
        self.assertEqual((ask["result"], ask.get("reason")), ("recent", "messaged_7d"))
        self.assertEqual(self.claim("claim-proof-pending", ["claim-1"], day="2026-12-30")["result"], "already_notified")
        # a claim with a proof ask never gets S2 (closed)
        self.sent(self.claim("claim-proof-ask", ["claim-3"], day="2026-11-20"))
        s2 = self.claim("claim-proof-pending", ["claim-3"], day="2026-12-30")
        self.assertEqual((s2["result"], s2.get("reason")), ("user_done", "proof_ask_sent"))

    def test_claim_status_never_follows_s2_on_the_same_claim(self):
        # QA on #1409: S2 then claim-status 9 days later must not say "nothing else is needed"
        self.sent(self.claim("claim-proof-pending", ["claim-7"], day="2026-10-28"))
        st = self.claim("claim-status", ["claim-7"], day="2026-11-06")
        self.assertEqual((st["result"], st.get("reason")), ("user_done", "proof_pending_sent"))
        # another claim of the same user is unaffected (after the 7 days)
        self.assertEqual(self.claim("claim-status", ["claim-8"], day="2026-11-06")["result"], "claimed")
        # the other order stays allowed: S2 after claim-status corrects the earlier note
        self.sent(self.claim("claim-status", ["claim-9"], day="2026-09-01", user="b@example.com", uid="43"))
        self.assertEqual(self.claim("claim-proof-pending", ["claim-9"], day="2026-10-01", user="b@example.com",
                                    uid="43")["result"], "claimed")

    def test_the_in_list_covers_every_claim_campaign(self):
        # regression: a proof-tagged claim-proof-pending reply is claim proof, never credit proof, so a
        # uvn-status note still goes (the old "NOT IN (?,?)" raised once the tuple held three campaigns)
        c = self.claim("claim-proof-pending", ["claim-1"], day="2026-10-01")
        self.sent(c)
        self.db.execute("UPDATE verify_messages SET proof_tagged_at='2026-10-02T00:00:00Z' WHERE id=?", (c["message_row"],))
        self.db.commit()
        self.assertEqual(vl.uvn_user_done(self.db, "jane@example.com", now=NOW, user_id="42"), "")
        self.assertEqual(vl.past_user_done(self.db, "jane@example.com", "42"), "")


class CorrectionCooldownLedgerTest(unittest.TestCase):
    """[key=k-proof-required] /c2 (r5 05:3xZ): a status line sent HOURS ago does not defer the ask that corrects it -
    in uvn_user_done (claim + the runner prefilter). A recent note of any other kind still defers."""

    def test_recent_status_line_on_the_same_request_does_not_defer_its_correction(self):
        import tempfile as _t
        from datetime import datetime as _dt, timezone as _tz
        from credit_review import verify_ledger as vl
        db = vl.connect(str(Path(_t.mkdtemp()) / "l.sqlite3"))
        today = _dt.now(_tz.utc).strftime("%Y-%m-%d")
        c = vl.claim(db, campaign="status-team-review", user_key="a@x.com", day=today, request_ids=["r1"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="7")
        vl.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        self.assertEqual(vl.uvn_user_done(db, "a@x.com", user_id="7", request_ids=["r1"]), "")
        self.assertEqual(vl.uvn_user_done(db, "a@x.com", user_id="7", request_ids=["r9"]), "messaged_7d")   # other request
        self.assertEqual(vl.uvn_user_done(db, "a@x.com", user_id="7"), "messaged_7d")                     # no ids: no exemption
        c = vl.claim(db, campaign="withdrawal-confirm", user_key="a@x.com", day=today, request_ids=["w1"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="7", enforce_cap=False)
        vl.finalize(db, message_row=c["message_row"], status="sent", message_id="2")
        self.assertEqual(vl.uvn_user_done(db, "a@x.com", user_id="7", request_ids=["r1"]), "messaged_7d")  # another note


    def test_an_attempted_status_line_keeps_the_cooldown(self):
        # QA / r5 #1565: unknown holds - an unconfirmed line earns no correction, so it never lifts messaged_7d
        import tempfile as _t
        from datetime import datetime as _dt, timezone as _tz
        from credit_review import verify_ledger as vl
        db = vl.connect(str(Path(_t.mkdtemp()) / "l.sqlite3"))
        today = _dt.now(_tz.utc).strftime("%Y-%m-%d")
        c = vl.claim(db, campaign="status-team-review", user_key="a@x.com", day=today, request_ids=["r1"],
                     message_type="email", approved_by="U", approval_ref="r", user_id="7")
        self.assertEqual(db.execute("SELECT status FROM verify_messages WHERE id=?", (c["message_row"],)).fetchone()[0], "attempted")
        self.assertEqual(vl.uvn_user_done(db, "a@x.com", user_id="7", request_ids=["r1"]), "messaged_7d")
        vl.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        self.assertEqual(vl.uvn_user_done(db, "a@x.com", user_id="7", request_ids=["r1"]), "")


class UvnReminder14LedgerTest(unittest.TestCase):
    """uvn-reminder-14 (captain 2026-11-13 15:08Z): ONE reminder of a SENT uvn-status ask, from day 14, to a user who
    neither replied nor sent a document. The 90-day one-ask lock is untouched for every first ask."""
    USER, UID = "jane@example.com", "42"

    def setUp(self):
        self.db = vl.connect(str(Path(tempfile.mkdtemp()) / "ledger.sqlite3"))

    def at(self, day):
        return datetime.fromisoformat(day + "T01:00:00+00:00")

    def claim(self, campaign, ids, day, user=None, uid=None):
        return vl.claim(self.db, user_key=user or self.USER, day=day, request_ids=list(ids), campaign=campaign,
                        user_id=self.UID if uid is None else uid, now=self.at(day), **KW)

    def ask(self, day="2026-10-20", ids=("r1",), campaign="uvn-status", sent=True, mid="1001"):
        c = self.claim(campaign, ids, day)
        self.assertEqual(c["result"], "claimed", c)
        if sent:
            vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id=mid)
        return c

    def why(self, day):
        return vl.reminder14_user_done(self.db, self.USER, now=self.at(day), user_id=self.UID)

    def sql(self, q, *a):
        self.db.execute(q, a)
        self.db.commit()

    def test_registered_as_a_follow_up_never_as_an_ask(self):
        self.assertEqual(vl.UVN_REMINDER, "uvn-reminder-14")
        self.assertIn(vl.UVN_REMINDER, vl.CAMPAIGNS)
        self.assertNotIn(vl.UVN_REMINDER, vl.ASK_CAMPAIGNS)       # it never restarts or shortens the one-ask lock
        self.assertEqual(vl.UVN_REMINDER_AFTER_DAYS, 14)
        self.assertEqual(vl.REASK_LOCK_DAYS, 90)

    def test_no_ask_no_reminder_and_nothing_is_closed(self):
        self.assertEqual(self.why("2026-11-13"), "no_prior_ask")
        c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-13")
        self.assertEqual(c["result"], "no_prior_ask")
        self.assertEqual(self.db.execute("SELECT count(*) FROM verify_requests").fetchone()[0], 0)

    def test_an_unconfirmed_ask_is_not_an_ask_to_remind_of(self):
        self.ask(sent=False)                                      # attempted: delivery unknown
        self.assertEqual(self.why("2026-11-13"), "no_prior_ask")

    def test_due_from_day_14_not_before(self):
        self.ask(day="2026-10-20")
        self.assertEqual(self.why("2026-11-02"), "not_due")       # day 13
        early = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-02")
        self.assertEqual((early["result"], early.get("reason")), ("recent", "not_due"))
        self.assertEqual(self.why("2026-11-03"), "")              # day 14
        self.assertEqual(vl.blocked_ids(self.db, ["r1"], vl.UVN_REMINDER), set())   # the ask's own row does not block it
        c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-03")
        self.assertEqual(c["result"], "claimed", c)
        row = self.db.execute("SELECT campaign, kind, status FROM verify_messages WHERE id=?", (c["message_row"],)).fetchone()
        self.assertEqual(tuple(row), ("uvn-reminder-14", "initial", "attempted"))

    def test_one_reminder_per_ask(self):
        """Pins the rule for a second ask. uvn_user_done() closes any user with an earlier sent uvn-status initial,
        so a second ask is NOT reachable through claim() today: the ask row is written directly, the way the other
        ledger tests write rows, and only the reminder path is exercised."""
        self.ask(day="2026-10-20", ids=("r1",), mid="1001")
        c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-03")
        self.assertEqual(c["result"], "claimed", c)
        vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id="1002")
        self.assertEqual(self.why("2026-12-20"), "already_sent")                # ask 1 is reminded
        again = self.claim(vl.UVN_REMINDER, ["r2"], "2026-12-20")
        self.assertEqual((again["result"], again.get("reason")), ("user_done", "already_sent"))
        # a LATER sent uvn-status ask, 14+ days old, nothing else since: its own reminder may go
        self.sql("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_id, "
                 "message_type, request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
                 "VALUES ('uvn-status','initial',?, '42','2026-12-21','sent','1003','email','[\"r3\"]',1,'U7RP6HKUZ',"
                 "'ref','2026-12-21T01:00:00Z','2026-12-21T01:00:00Z')", self.USER)
        self.assertEqual(self.why("2027-01-05"), "")
        second = self.claim(vl.UVN_REMINDER, ["r3"], "2027-01-05")
        self.assertEqual(second["result"], "claimed", second)
        vl.finalize(self.db, message_row=second["message_row"], status="sent", message_id="1004")
        self.assertEqual(self.why("2027-02-01"), "already_sent")

    def test_a_reminder_row_with_no_readable_reference_closes_the_user(self):
        self.ask(day="2026-10-20")
        self.sql("INSERT INTO verify_messages (campaign, kind, parent_row, user_key, account_id, day, status, "
                 "message_type, request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) "
                 "VALUES ('uvn-reminder-14','initial',NULL,?, '42','2026-11-03','sent','email','[]',1,'U7RP6HKUZ',"
                 "'ref','2026-11-03T01:00:00Z','2026-11-03T01:00:00Z')", self.USER)
        self.assertEqual(self.why("2027-02-01"), "already_sent")

    def test_a_rejected_document_still_counts_as_a_document_sent(self):
        """A rejected review sets proof_tagged_at back to NULL (the note returns to "no proof"), and the AI proof
        reviewer (#1961) writes rejections with no person in the loop. The tag alone would then make a user who DID
        send a document remindable with "we haven't received it yet". With an attachment counted, and with none (a
        link in a reply), the review on record keeps them closed: the rule, its one-pass twin and the claim agree."""
        for attachments in (1, 0):
            with self.subTest(attachments=attachments):
                self.setUp()
                self.ask(day="2026-10-20")
                self.assertEqual(self.why("2026-11-09"), "")
                vl.mark_tagged(self.db, message_id="1001", conversation_id="c1", attachments=attachments,
                               now=self.at("2026-10-25"))
                self.assertEqual(self.why("2026-11-09"), "proof_received")
                r = vl.record_proof_review(self.db, message_id="1001", request_ids=["r1"], outcome="rejected",
                                           reviewer="proof-reviewer", reason="unreadable", now=self.at("2026-10-26"))
                self.assertEqual(r["result"], "ok", r)
                tag = self.db.execute("SELECT proof_tagged_at FROM verify_messages WHERE message_id='1001'").fetchone()
                self.assertIsNone(tag[0])                              # the tag is gone: this is the case under test
                self.assertEqual(self.why("2026-11-09"), "proof_received")
                self.assertEqual(vl.reminder14_bulk(self.db, now=self.at("2026-11-09"))[int(self.UID)]["why"],
                                 "proof_received")
                c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-09")
                self.assertEqual((c["result"], c.get("reason")), ("user_done", "proof_received"))

    def test_the_reminder_does_not_touch_the_90_day_lock(self):
        self.ask(day="2026-10-20")
        c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-03")
        vl.finalize(self.db, message_row=c["message_row"], status="sent", message_id="1002")
        # the lock still runs from the ASK (10-20), not from the reminder (11-03): locked on day 89, open on day 91
        self.assertTrue(vl.asked_within(self.db, user_key=self.USER, day="2027-01-17", user_id=self.UID))
        self.assertFalse(vl.asked_within(self.db, user_key=self.USER, day="2027-01-19", user_id=self.UID))
        # and a first ask to someone asked 14+ days ago is still refused: only the reminder path opens at day 14
        other = self.claim("verify-live", ["r9"], "2026-11-20")
        self.assertEqual(other["result"], "recently_asked", other)

    def test_never_to_someone_who_replied(self):
        self.ask(day="2026-10-20")
        self.sql("UPDATE verify_messages SET last_reply_at='2026-10-25T10:00:00Z' WHERE message_id='1001'")
        self.assertEqual(self.why("2026-11-13"), "replied")
        c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-13")
        self.assertEqual((c["result"], c.get("reason")), ("user_done", "replied"))

    def test_never_to_someone_who_asked_for_more_time(self):
        self.ask(day="2026-10-20")
        self.sql("UPDATE verify_messages SET extension_requested_at='2026-10-25T10:00:00Z' WHERE message_id='1001'")
        self.assertEqual(self.why("2026-11-13"), "replied")

    def test_never_to_someone_who_sent_a_document_on_any_credit_note(self):
        self.ask(day="2026-10-20")
        r = self.claim("status-team-review", ["r5"], "2026-10-28")
        vl.finalize(self.db, message_row=r["message_row"], status="sent", message_id="1003")
        self.sql("UPDATE verify_messages SET proof_tagged_at='2026-10-29T10:00:00Z' WHERE message_id='1003'")
        self.assertEqual(self.why("2026-11-13"), "proof_received")

    def test_a_reminder_from_any_sender_counts_even_with_no_account_id(self):
        # the 2026-11-09 `reminder-1` rows: kind reminder-14, the account email only, no account id, no request ids
        self.ask(day="2026-10-20")
        self.sql("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                 "n_credits, approved_by, approval_ref, created_at, updated_at) VALUES ('reminder-1','reminder-14',?,"
                 "'2026-10-28','sent','email','[]',1,'system:reminder-driver','auto:reminder-1','x','x')", self.USER)
        self.assertEqual(self.why("2026-11-13"), "already_reminded")
        bulk = vl.reminder14_bulk(self.db, now=self.at("2026-11-13"))
        self.assertEqual(bulk[42]["why"], "already_reminded")     # the audience builder finds it by the email too

    def test_a_reminder_before_the_ask_belongs_to_an_older_ask(self):
        self.sql("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                 "n_credits, approved_by, approval_ref, created_at, updated_at) VALUES ('reminder-1','reminder-14',?,"
                 "'2026-09-01','sent','email','[]',1,'system:reminder-driver','auto:reminder-1','x','x')", self.USER)
        self.ask(day="2026-10-20")
        self.assertEqual(self.why("2026-11-13"), "")

    def test_a_claim_note_in_the_last_7_days_defers(self):
        # a note about a profile CLAIM is another subject: it never closes the credit reminder, it only spaces it
        self.ask(day="2026-10-20")
        r = self.claim("claim-status", ["c5"], "2026-11-10")
        self.assertEqual(r["result"], "claimed", r)
        vl.finalize(self.db, message_row=r["message_row"], status="sent", message_id="1003")
        self.assertEqual(self.why("2026-11-13"), "messaged_7d")
        c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-13")
        self.assertEqual((c["result"], c.get("reason")), ("recent", "messaged_7d"))
        self.assertEqual(self.why("2026-11-18"), "")

    def test_any_other_credit_note_since_the_ask_closes_the_reminder(self):
        # the reminder follows an ask NOTHING followed: a status line, or a note of a sender outside this gate (the
        # 2026-11-09 `first-ask-1` emails carry the account email only), means the ask is no longer our last word
        for name, add in (
                ("status line", lambda: vl.finalize(
                    self.db, message_row=self.claim("status-team-review", ["r5"], "2026-10-28")["message_row"],
                    status="sent", message_id="1003")),
                ("outside sender, email only", lambda: self.sql(
                    "INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, "
                    "n_credits, approved_by, approval_ref, created_at, updated_at) VALUES ('first-ask-1', 'initial', ?, "
                    "'2026-11-09', 'sent', 'email', '[]', 1, 'first-ask', 'auto', '2026-11-09T19:01:00Z', "
                    "'2026-11-09T19:01:00Z')", self.USER))):
            with self.subTest(name):
                self.setUp()
                self.ask(day="2026-10-20")
                self.assertEqual(self.why("2026-11-20"), "")
                add()
                self.assertEqual(self.why("2026-11-20"), "noted_since_ask")
                c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-20")
                self.assertEqual((c["result"], c.get("reason")), ("user_done", "noted_since_ask"))
                self.assertEqual(vl.reminder14_bulk(self.db, now=self.at("2026-11-20"))[int(self.UID)]["why"],
                                 "noted_since_ask")
        # a note BEFORE the ask is what the ask itself followed: it closes nothing
        self.setUp()
        vl.finalize(self.db, message_row=self.claim("status-team-review", ["r5"], "2026-10-10")["message_row"],
                    status="sent", message_id="1003")
        self.ask(day="2026-10-20")
        self.assertEqual(self.why("2026-11-20"), "")

    def test_only_the_last_ask_counts_and_only_a_uvn_status_one(self):
        self.ask(day="2026-10-20")
        g = self.claim("gap-ask", ["r7"], "2026-10-30")           # a later ask from another family: the copy would be false
        self.assertEqual(g["result"], "claimed", g)
        vl.finalize(self.db, message_row=g["message_row"], status="sent", message_id="1004")
        self.assertEqual(self.why("2026-11-20"), "no_prior_ask")

    def test_one_message_per_user_per_day_still_holds(self):
        self.ask(day="2026-10-20")
        other = vl.claim(self.db, user_key=self.USER, day="2026-11-13", request_ids=["c1"], campaign="claim-status",
                         user_id=self.UID, now=self.at("2026-11-13"), **KW)
        if other["result"] == "claimed":                          # a claim note the same day: the reminder waits
            c = self.claim(vl.UVN_REMINDER, ["r1"], "2026-11-13")
            self.assertIn(c["result"], ("recent", "daily_cap"), c)
            self.assertNotEqual(c["result"], "claimed")

    def test_bulk_and_per_user_agree_and_bulk_names_the_ask(self):
        self.ask(day="2026-10-20", ids=("r1", "r2"))
        for day in ("2026-11-02", "2026-11-03"):
            bulk = vl.reminder14_bulk(self.db, now=self.at(day))
            self.assertEqual(bulk[42]["why"], self.why(day))
        self.assertEqual(bulk[42]["asked_day"], "2026-10-20")
        self.assertEqual(sorted(bulk[42]["request_ids"]), ["r1", "r2"])

if __name__ == "__main__":
    unittest.main()
