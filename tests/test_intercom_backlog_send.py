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
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEND = os.path.join(ROOT, "scripts", "intercom-backlog", "send.py")

spec = importlib.util.spec_from_file_location("ib_send", SEND)
ib_send = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib_send)

NO_OV = {"add": {}, "remove": {}}
OVR = ib_send.overrides
FORBIDDEN = ["captain-legal", "captain-billing", "gate-uvn-status", "gate-team-review",
             "gate-doc-received", "ledger-today", "claim-pending", "ambiguous-identity",
             "hold-read"]


def row(cid, action, band="1-30d", paid=False, waiting=100):
    return {"id": cid, "action": action, "band": band, "paid": paid, "waiting_since": waiting,
            "user_id": None}


class SelectRows(unittest.TestCase):
    def test_every_forbidden_action_refused_in_recent_plan(self):
        for act in FORBIDDEN:
            with self.subTest(action=act):
                rows = [row("1", act), row("2", "draft-merge")]
                with self.assertRaises(ib_send.Refused) as cm:
                    ib_send.select_rows(rows, "recent", {"1": "merge", "2": "merge"}, NO_OV)
                self.assertIn("not send-eligible", str(cm.exception))
                self.assertIn(act, str(cm.exception))

    def test_tail_never_selects_forbidden_actions(self):
        rows = [row(str(i), a, band="gt30d") for i, a in enumerate(FORBIDDEN)]
        rows.append(row("ok", "draft-other", band="gt30d"))
        self.assertEqual([r["id"] for r in ib_send.select_rows(rows, "tail", {}, NO_OV)], ["ok"])

    def test_recent_needs_plan_and_known_lines_and_ids(self):
        rows = [row("1", "draft-merge")]
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows(rows, "recent", {}, NO_OV)
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows(rows, "recent", {"1": "invented-line"}, NO_OV)
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows(rows, "recent", {"999": "merge"}, NO_OV)

    def test_recent_plan_refuses_tail_rows_and_tail_refuses_plan(self):
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows([row("1", "draft-merge", band="gt30d")], "recent", {"1": "merge"}, NO_OV)
        with self.assertRaises(ib_send.Refused):
            ib_send.select_rows([row("1", "draft-merge", band="gt30d")], "tail", {"1": "merge"}, NO_OV)

    def test_eligible_recent_plan_selected_paid_first(self):
        rows = [row("a", "draft-merge", waiting=1), row("b", "draft-other", paid=True, waiting=5)]
        got = ib_send.select_rows(rows, "recent", {"a": "merge", "b": "generic"}, NO_OV)
        self.assertEqual([r["id"] for r in got], ["b", "a"])

    def test_unresolved_identity_is_never_send_eligible(self):
        # R25 standing guard: a thread the identity resolver cannot resolve gets NOTHING.
        for act in ib_send.UNRESOLVED_ACTIONS:
            with self.subTest(action=act):
                self.assertNotIn(act, ib_send.ACTION_LINE)
                self.assertFalse(ib_send.eligible(row("1", act)))
                with self.assertRaises(ib_send.Refused):
                    ib_send.select_rows([row("1", act)], "recent", {"1": "generic"}, NO_OV)

    def test_sender_is_unlocked_only_against_fable_r25(self):
        # R25 (inbox 057) approved the two credit lines; closing and the bucket lines stay locked.
        self.assertEqual(ib_send.COPY_APPROVED, 1)
        self.assertEqual(ib_send.COPY_APPROVAL_REF, "Fable R25")
        self.assertEqual(ib_send.CLOSE_APPROVED, 0)
        self.assertEqual(ib_send.BUCKET_APPROVED, {})


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {k: v for k, v in os.environ.items() if k != "MUSOAI_INTERCOM_TOKEN"}
        self.overrides = NO_OV

    def run_cli(self, rows, plan, *extra):
        tri = os.path.join(self.tmp.name, "t.jsonl")
        with open(tri, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        ov = os.path.join(self.tmp.name, "ov.json")
        with open(ov, "w") as f:
            json.dump(self.overrides, f)
        args = [sys.executable, SEND, tri, "--band", "recent", "--overrides", ov]
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

    def test_cli_refuses_planned_override_ids_dry_run_and_apply(self):
        # Hand-read moves: an 'add' id the keywords called draft-other is now the captain's,
        # and a 'remove' id (keyword misfire off the captain list) is hold-read. Both refused.
        self.overrides = {"add": {"111": "privacy"}, "remove": {"222": "misfire"}}
        for cid, want in (("111", "captain-privacy"), ("222", "hold-read")):
            for mode in ((), ("--apply",)):
                with self.subTest(id=cid, mode=mode):
                    p = self.run_cli([row(cid, "draft-other")], {cid: "generic"}, *mode)
                    self.assertRefused(p, "not send-eligible")
                    self.assertIn(want, p.stderr)

    def test_cli_missing_overrides_file_refused(self):
        tri = os.path.join(self.tmp.name, "t.jsonl")
        with open(tri, "w") as f:
            f.write(json.dumps(row("1", "draft-merge")) + "\n")
        pl = os.path.join(self.tmp.name, "plan.json")
        with open(pl, "w") as f:
            json.dump({"1": "merge"}, f)
        p = subprocess.run([sys.executable, SEND, tri, "--band", "recent", "--plan", pl,
                            "--overrides", os.path.join(self.tmp.name, "absent.json")],
                           capture_output=True, text=True, env=self.env, timeout=30)
        self.assertRefused(p, "cannot read captain overrides")

    def test_cli_apply_refused_while_closing_locked(self):
        p = self.run_cli([row("1", "draft-merge")], {"1": "merge"}, "--apply", "--close")
        self.assertRefused(p, "CLOSE_APPROVED=1")


class Overrides(unittest.TestCase):
    """One loader for lists.py and send.py (Fable review @4a57414d)."""

    def tmpdir(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        return d

    def write(self, data):
        p = os.path.join(self.tmpdir(), "ov.json")
        with open(p, "w") as f:
            f.write(data if isinstance(data, str) else json.dumps(data))
        return p

    def test_select_rows_applies_overrides(self):
        ov = {"add": {"111": "billing"}, "remove": {"222": "x"}}
        for cid in ("111", "222"):
            with self.subTest(id=cid), self.assertRaises(ib_send.Refused) as cm:
                ib_send.select_rows([row(cid, "draft-other")], "recent", {cid: "generic"}, ov)
            self.assertIn("not send-eligible", str(cm.exception))
        tail = [row("111", "draft-other", band="gt30d"), row("222", "draft-credit", band="gt30d"),
                row("33", "draft-other", band="gt30d")]
        self.assertEqual([r["id"] for r in ib_send.select_rows(tail, "tail", {}, ov)], ["33"])

    def test_load_fails_closed(self):
        for bad in ("not json", "[]", {"add": {"1x": "legal"}}, {"add": {"12": "refunds"}},
                    {"add": {"12": "legal"}, "remove": {"12": "x"}}, {"add": []}):
            with self.subTest(bad=bad), self.assertRaises(OVR.OverridesError):
                OVR.load(self.write(bad))
        with self.assertRaises(OVR.OverridesError):
            OVR.load("/nonexistent/captain-overrides.json")

    def test_repo_overrides_file_loads(self):
        ov = OVR.load()
        self.assertTrue(ov["add"] and ov["remove"])

    def test_lists_captain_and_hold_agree(self):
        spec2 = importlib.util.spec_from_file_location(
            "ib_lists", os.path.join(ROOT, "scripts", "intercom-backlog", "lists.py"))
        lists = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(lists)
        tri = os.path.join(self.tmpdir(), "t.jsonl")
        rows = [dict(row("111", "draft-other"), age_days=1), dict(row("222", "captain-billing"), age_days=2),
                dict(row("33", "draft-credit"), age_days=3), dict(row("44", "captain-legal"), age_days=4),
                dict(row("55", "gate-uvn-status"), age_days=5)]
        with open(tri, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        got = lists.load_rows(tri, {"add": {"111": "privacy"}, "remove": {"222": "misfire"}})
        cap = "\n".join(lists.captain(got))
        hold = "\n".join(lists.hold(got))
        self.assertIn("| 111 | privacy", cap)
        self.assertIn("| 44 | legal", cap)
        self.assertNotIn("| 222 |", cap)
        self.assertIn("### hold-read (1)", hold)
        self.assertIn("### draft-credit (1)", hold)
        held_ids = {x.split("(")[0] for ln in hold.splitlines() if ln.startswith("- **")
                    for x in ln.split(": ", 1)[1].split(", ")}
        self.assertEqual(held_ids, {"222", "33"})


class BucketMode(unittest.TestCase):
    """--band bucket (captain 10-29, unanswered-1029): nine self-serve buckets map to lines A-I, each line
    locked on its own until the captain's yes lands in a PR."""

    def brow(self, cid, bucket, action="draft-other", paid=False, waiting=100):
        return {"id": cid, "bucket": bucket, "action": action, "band": "gt30d", "paid": paid,
                "waiting_since": waiting, "user_id": None, "email": "x@y.io"}

    def test_every_line_is_locked_until_approved(self):
        self.assertEqual(ib_send.BUCKET_APPROVED, {})
        self.assertEqual(set(ib_send.BUCKET_LINE.values()), set(ib_send.BUCKET_LINES))

    def test_only_the_nine_buckets_map(self):
        for b in ("credit-owned-l1", "credit-like", "merge-like", "removal-like", "other", "thanks-only",
                  "social-noise", "auto-noise", "billing-money", "legal", "account-delete", "business",
                  "account-email", "nope"):
            with self.subTest(bucket=b), self.assertRaises(ib_send.Refused):
                ib_send.select_rows([self.brow("1", b)], "bucket", {}, NO_OV, bucket=b)

    def test_selects_one_bucket_paid_first_and_skips_owned_actions(self):
        rows = [self.brow("1", "stats", waiting=1), self.brow("2", "stats", paid=True, waiting=9),
                self.brow("3", "plaque-order"), self.brow("4", "stats", action="captain-billing"),
                self.brow("5", "stats", action="gate-uvn-status"), self.brow("6", "stats", action="ledger-today")]
        got = ib_send.select_rows(rows, "bucket", {}, NO_OV, bucket="stats")
        self.assertEqual([r["id"] for r in got], ["2", "1"])

    def test_captain_overrides_apply_in_bucket_mode(self):
        rows = [self.brow("111", "stats"), self.brow("222", "stats"), self.brow("333", "stats")]
        ov = {"add": {"111": "billing"}, "remove": {"222": "misfire"}}
        self.assertEqual([r["id"] for r in ib_send.select_rows(rows, "bucket", {}, ov, bucket="stats")], ["333"])

    def test_render_and_lines_pass_the_write_wrappers_sanitizer(self):
        body = ib_send.render_bucket(self.brow("1", "plaque-order"), "Ann Marie")
        self.assertTrue(body.startswith("Hi Ann, sorry for the slow reply. You can order a plaque"))
        self.assertIn("muso.ai/amp/promote/plaque", body)
        self.assertTrue(body.endswith("If you still need help, just reply here."))
        self.assertTrue(ib_send.render_bucket(self.brow("1", "stats"), "").startswith("Hi there,"))
        with open(os.path.join(ROOT, "scripts", "intercom-ops-write.sh")) as fh:
            wrapper = fh.read()
        words = re.search(r'readonly SANITIZER_WORDS="([^"]+)"', wrapper).group(1)
        leak = re.compile(r"(^|[^A-Za-z0-9_])(" + words + r")([^A-Za-z0-9_]|$)", re.I)
        for k, line in ib_send.BUCKET_LINES.items():
            text = " ".join([ib_send.BUCKET_OPEN, line, ib_send.BUCKET_CLOSER])
            with self.subTest(line=k):
                self.assertIsNone(leak.search(text))
                self.assertNotRegex(text, r"github\.com/|#[0-9]{3,}|<@U|\u2014")
                for promise in ("we fixed", "we updated", "has been processed", "we have updated"):
                    self.assertNotIn(promise, text.lower())

    def test_cli_bucket_apply_refused_while_line_locked(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        f = os.path.join(d, "b.jsonl")
        with open(f, "w") as fh:
            fh.write(json.dumps(self.brow("1", "stats")) + "\n")
        ov = os.path.join(d, "ov.json")
        with open(ov, "w") as fh:
            json.dump(NO_OV, fh)
        env = {k: v for k, v in os.environ.items() if k != "MUSOAI_INTERCOM_TOKEN"}
        p = subprocess.run([sys.executable, SEND, f, "--band", "bucket", "--bucket", "stats", "--apply",
                            "--overrides", ov], capture_output=True, text=True, env=env, timeout=30)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("line B (stats) is not approved", p.stderr)
        p = subprocess.run([sys.executable, SEND, f, "--band", "bucket", "--bucket", "legal",
                            "--overrides", ov], capture_output=True, text=True, env=env, timeout=30)
        self.assertIn("has no line", p.stderr)


class SharedLedger(unittest.TestCase):
    """Sends claim and finalize in the SHARED verify ledger (Fable review @092894d4), so the
    one-message-per-user-per-UTC-day cap holds across this lane and every campaign."""
    DAY = "2026-10-27"

    def setUp(self):
        self.db = ib_send.verify_ledger.connect(":memory:")

    def other_campaign_sent(self, user_key="a@x.io", user_id="7", campaign="status-team-review"):
        c = ib_send.verify_ledger.claim(self.db, user_key=user_key, day=self.DAY, request_ids=["r1"],
                                        message_type="email", approved_by="U7RP6HKUZ",
                                        approval_ref="t", campaign=campaign, user_id=user_id)
        ib_send.verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent")

    def claim(self, conv="100", key="a@x.io", uid="7"):
        return ib_send.ledger_claim(self.db, conv, key, uid, self.DAY)

    def test_campaign_registered_as_notice(self):
        v = ib_send.verify_ledger
        self.assertIn(v.BACKLOG_REPLY, v.CAMPAIGNS)
        self.assertIn(v.BACKLOG_REPLY, v.NOTICE_CAMPAIGNS)

    def test_other_campaign_today_blocks_reply(self):
        self.other_campaign_sent()
        self.assertEqual(self.claim()["result"], "daily_cap")
        self.assertIn("messaged today", ib_send.ledger_precheck(self.db, "100", "a@x.io", "7", self.DAY))

    def test_same_user_by_account_id_after_email_change(self):
        self.other_campaign_sent(user_key="old@x.io", user_id="7")
        self.assertEqual(self.claim(key="new@x.io", uid="7")["result"], "daily_cap")

    def test_reply_caps_the_day_for_every_other_campaign(self):
        c = self.claim()
        ib_send.ledger_finalize(self.db, c["message_row"], "100", 0,
                                "POSTED comment conversation=100 part=555\n", "", "body")
        self.assertTrue(ib_send.verify_ledger.capped(self.db, user_key="a@x.io", day=self.DAY, user_id="7"))
        row = self.db.execute("SELECT campaign, status, message_id, conversation_id FROM verify_messages "
                              "WHERE campaign='backlog-reply'").fetchone()
        self.assertEqual(tuple(row), ("backlog-reply", "sent", "555", "100"))
        # The status campaigns defer this user for 7 days (messaged_7d), as for any of our notes.
        self.assertEqual(ib_send.verify_ledger.uvn_user_done(
            self.db, "a@x.io", campaign="status-team-review", user_id="7",
            now=ib_send.verify_ledger.datetime(2026, 10, 28, tzinfo=ib_send.verify_ledger.timezone.utc)),
            "messaged_7d")

    def test_one_reply_per_conversation_ever(self):
        c = self.claim()
        ib_send.ledger_finalize(self.db, c["message_row"], "100", 0,
                                "POSTED comment conversation=100 part=1\n", "", "b")
        self.assertEqual(ib_send.ledger_claim(self.db, "100", "a@x.io", "7", "2026-11-05")["result"],
                         "already_notified")

    def test_unverified_post_keeps_holding_the_day(self):
        c = self.claim()
        ib_send.ledger_finalize(self.db, c["message_row"], "100", 4, "", "POST NOT VERIFIED", "b")
        self.assertTrue(ib_send.verify_ledger.capped(self.db, user_key="a@x.io", day=self.DAY, user_id="7"))

    def test_failed_post_frees_the_day(self):
        c = self.claim()
        ib_send.ledger_finalize(self.db, c["message_row"], "100", 1, "", "REFUSED", "b")
        self.assertFalse(ib_send.verify_ledger.capped(self.db, user_key="a@x.io", day=self.DAY, user_id="7"))

    def test_no_email_means_no_key(self):
        self.assertEqual(ib_send.user_key_of({"email": ""}, ""), "")
        self.assertEqual(ib_send.user_key_of({"email": "C@X.io"}, ""), "c@x.io")
        self.assertEqual(ib_send.user_key_of({"email": "c@x.io"}, "Acct@X.io"), "acct@x.io")


if __name__ == "__main__":
    unittest.main()


class R25CreditLines(unittest.TestCase):
    """Fable R25 (inbox 057): the credit class is TWO approved lines, chosen by a LIVE core read at send
    time, sent verbatim, and never to a thread the stage-2 lane owns."""

    def test_zero_vs_nonzero_picks_the_line(self):
        self.assertEqual(ib_send.credit_line(0), "credit-request-none")
        self.assertEqual(ib_send.credit_line(1), "credit-request-pending")
        self.assertEqual(ib_send.credit_line(7), "credit-request-pending")

    def test_lines_are_verbatim_and_pluralise_from_the_real_count(self):
        self.assertEqual(ib_send.render_credit("credit-request-none", 0), ib_send.R25_CREDIT_NONE)
        one = ib_send.render_credit("credit-request-pending", 1)
        many = ib_send.render_credit("credit-request-pending", 3)
        self.assertIn("your credit request is with our verification team", one)
        self.assertIn("your credit requests are with our verification team", many)
        for body in (one, many):
            self.assertNotIn("{s}", body)
            self.assertNotIn("{is|are}", body)
            # R25: no dates, no timing promises, no first name, no opener/closer wrapper.
            self.assertNotIn("Hi ", body)
            self.assertNotIn("reply here and it will come straight back", body)

    def test_assert_approved_refuses_any_edit(self):
        good = ib_send.render_credit("credit-request-pending", 2)
        ib_send.assert_approved(good, "credit-request-pending", 2)  # no raise
        for bad in (good + " We'll have it done by Friday.", good.replace("now", "soon"),
                    ib_send.render_credit("credit-request-pending", 1)):
            with self.subTest(bad=bad[:40]):
                with self.assertRaises(ib_send.Refused):
                    ib_send.assert_approved(bad, "credit-request-pending", 2)

    def test_plan_cannot_borrow_the_credit_lines_for_another_action(self):
        rows = [row("1", "draft-merge")]
        with self.assertRaises(ib_send.Refused) as cm:
            ib_send.select_rows(rows, "recent", {"1": "credit-request"}, NO_OV)
        self.assertIn("dynamic line", str(cm.exception))

    def test_plan_accepts_the_dynamic_key_on_the_credit_action(self):
        rows = [row("1", "draft-credit")]
        got = ib_send.select_rows(rows, "recent", {"1": "credit-request"}, NO_OV)
        self.assertEqual([r["id"] for r in got], ["1"])

    def test_live_credit_pending_counts_every_presented_profile(self):
        from credit_review import identity_resolver
        seen = []
        orig = identity_resolver.presented_ids
        identity_resolver.presented_ids = lambda uids, q: {str(u): ["prof-a", "prof-b"] for u in uids}
        self.addCleanup(setattr, identity_resolver, "presented_ids", orig)

        def q(sql):
            seen.append(sql)
            return [["2"]]

        self.assertEqual(ib_send.live_credit_pending(7, q), 2)
        self.assertIn("userid = 7", seen[0])
        self.assertIn("profileid in ('prof-a','prof-b')", seen[0])
        self.assertIn("user_verification_needed", seen[0])

    def test_live_credit_pending_refuses_an_unreadable_count(self):
        from credit_review import identity_resolver
        orig = identity_resolver.presented_ids
        identity_resolver.presented_ids = lambda uids, q: {str(u): [] for u in uids}
        self.addCleanup(setattr, identity_resolver, "presented_ids", orig)
        for bad in ([], [[""]], [["nope"]]):
            with self.subTest(bad=bad):
                with self.assertRaises(Exception):
                    ib_send.live_credit_pending(7, lambda sql, b=bad: b)


class Stage2Hold(unittest.TestCase):
    """R25 standing guard: an open proof ask, or a document on file in the last 30 days, belongs to the
    stage-2 lane. Unreadable ledger or proof store REFUSES (a hold, never a message)."""

    DAY = "2026-11-05"

    def setUp(self):
        self.db = ib_send.verify_ledger.connect(":memory:")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = os.path.join(self.tmp.name, "proof.sqlite")
        self._orig = ib_send.PROOF_STORE
        ib_send.PROOF_STORE = self.store
        self.addCleanup(setattr, ib_send, "PROOF_STORE", self._orig)
        import sqlite3
        pdb = sqlite3.connect(self.store)
        pdb.execute("CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER, subject TEXT, "
                    "conversation_id TEXT, received_at TEXT)")
        pdb.commit()
        pdb.close()

    def add_doc(self, user_id, conversation_id, received_at):
        import sqlite3
        pdb = sqlite3.connect(self.store)
        pdb.execute("INSERT INTO proof_intake VALUES (?,?,?,?,?)",
                    (f"{user_id}:{received_at}", user_id, "credit", conversation_id, received_at))
        pdb.commit()
        pdb.close()

    def test_clean_thread_may_be_answered(self):
        self.assertEqual(ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY), "")

    def test_open_proof_ask_holds(self):
        ib_send.verify_ledger.claim(self.db, user_key="a@x.io", day="2026-11-01", request_ids=["r1"],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="test",
                                    campaign=ib_send.verify_ledger.PROOF_NEED_ASK)
        self.assertIn("open proof ask", ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY))

    def test_claim_ask_holds(self):
        ib_send.verify_ledger.claim(self.db, user_key="a@x.io", day="2026-11-01", request_ids=["r1"],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="test",
                                    campaign=ib_send.verify_ledger.CLAIM_CAMPAIGN)
        self.assertIn("open proof ask", ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY))

    def test_old_ask_outside_the_window_does_not_hold(self):
        ib_send.verify_ledger.claim(self.db, user_key="a@x.io", day="2026-09-01", request_ids=["r1"],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="test",
                                    campaign=ib_send.verify_ledger.PROOF_NEED_ASK)
        self.assertEqual(ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY), "")

    def test_document_on_file_holds_by_user_and_by_conversation(self):
        self.add_doc(7, "999", "2026-10-20")
        self.assertIn("document on file", ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY))
        self.assertIn("document on file", ib_send.stage2_hold(self.db, "b@x.io", "8", "999", self.DAY))

    def test_old_document_outside_the_window_does_not_hold(self):
        self.add_doc(7, "999", "2026-09-01")
        self.assertEqual(ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY), "")

    def test_unreadable_proof_store_fails_closed(self):
        ib_send.PROOF_STORE = os.path.join(self.tmp.name, "absent.sqlite")
        self.assertIn("proof store unreadable", ib_send.stage2_hold(self.db, "a@x.io", "7", "100", self.DAY))
