#!/usr/bin/env python3
"""Tests for scripts/cs_proof_feed (the proof-on-file feed, moved Mac -> node-8 2026-10-26).

Stdlib only: no Intercom, Gmail, Trino or node-8 — the Trino wrapper is faked, the ledger is a
temp sqlite file, the install target is a temp dir. Run: python3 scripts/tests/test_cs_proof_feed.py
"""
import datetime as dt
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cs_proof_feed")
sys.path.insert(0, LIB)


def load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIB, fname))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


replica = load("replica", "replica.py")
ps = load("proof_scan", "proof_scan.py")
WRAPPER = os.path.join(LIB, "..", "cs-proof-feed.sh")
pe = load("proof_export", "proof_export.py")
gp = load("gmail_proof", "gmail_proof.py")
gp.SEED_DIR = tempfile.mkdtemp()  # never the CI host's real /root/fmc1-gmail

SENT = "2026-10-22T15:00:00Z"
T_SENT = 1792681200  # 2026-10-22T15:00:00Z


class FakeRun:
    def __init__(self, stdout="", rc=0):
        self.stdout, self.rc, self.calls = stdout, rc, []

    def __call__(self, argv, input=None, **kw):
        self.calls.append((argv, input))
        return subprocess.CompletedProcess(argv, self.rc, self.stdout, "boom" if self.rc else "")


class Replica(unittest.TestCase):
    def test_statement_is_a_postgres_passthrough_with_doubled_quotes(self):
        sql = replica.build_sql(["a@x.com", "b@y.org"])
        self.assertIn("TABLE(postgresql_core.system.query(query => '", sql)
        # the inner Postgres literals are doubled once for the Trino literal
        self.assertIn("IN (''a@x.com'',''b@y.org'')", sql)
        self.assertIn("lower(email)", sql)
        self.assertTrue(sql.startswith("SET SESSION query_max_execution_time"))

    def test_parse_drops_banner_and_non_numeric_rows(self):
        out = 'WARNING: jvm banner\nSET SESSION\n"a@x.com","42"\n"b@y.org","7"\n"bad","n/a"\n'
        self.assertEqual(replica.parse(out), {"a@x.com": 42, "b@y.org": 7})

    def test_unsafe_addresses_never_reach_the_statement(self):
        run = FakeRun('"ok@x.com","1"\n')
        got = replica.users_by_email({"ok@x.com", "o'brien@x.com", "back\\slash@x.com", "", "OK@X.COM"}, run=run)
        self.assertEqual(got, {"ok@x.com": 1})
        self.assertEqual(len(run.calls), 1)
        self.assertNotIn("brien", run.calls[0][1])
        self.assertNotIn("slash", run.calls[0][1])

    def test_chunks_of_500(self):
        run = FakeRun("")
        replica.users_by_email({f"u{i}@x.com" for i in range(1201)}, run=run)
        self.assertEqual(len(run.calls), 3)

    def test_unreadable_replica_fails_closed(self):
        with self.assertRaises(RuntimeError):
            replica.users_by_email({"a@x.com"}, run=FakeRun("", rc=1))

    def test_no_addresses_no_call(self):
        run = FakeRun("")
        self.assertEqual(replica.users_by_email(set(), run=run), {})
        self.assertEqual(run.calls, [])


def note(**kw):
    row = {"message_id": "215579392", "conversation_id": None, "contact_id": "c1",
           "request_ids_json": json.dumps(["r-a", "r-b"]), "created_at": SENT, "campaign": "uvn-status"}
    row.update(kw)
    return row


def rec(**kw):
    r = {"conv": "900", "part": "p1", "created": str(T_SENT + 60), "contact": "c1"}
    r.update(kw)
    return r


class RequestLinks(unittest.TestCase):
    """Ported unchanged from cs-systemic test_proof_export.py: the linking logic did not move."""

    def test_epoch_matches_fixture(self):
        self.assertEqual(pe._epoch(SENT), T_SENT)

    def test_reply_in_the_notes_thread_links_every_request(self):
        links = pe.request_links([rec()], [note()], {"900": "215579392"})
        v = "verify_messages:uvn-status:215579392"
        self.assertEqual(links, {("900", "p1"): [("r-a", v), ("r-b", v)]})

    def test_ledger_conversation_id_links_without_source_lookup(self):
        links = pe.request_links([rec()], [note(conversation_id="900", message_id=None)], {})
        self.assertEqual([rid for rid, _ in links[("900", "p1")]], ["r-a", "r-b"])

    def test_other_conversation_is_not_linked(self):
        self.assertEqual(pe.request_links([rec(conv="901")], [note()], {"901": "999"}), {})

    def test_unknown_conversation_source_is_not_linked(self):
        self.assertEqual(pe.request_links([rec()], [note()], {}), {})

    def test_part_posted_before_the_note_is_not_linked(self):
        self.assertEqual(pe.request_links([rec(created=str(T_SENT - 1))], [note()], {"900": "215579392"}), {})

    def test_contact_mismatch_is_not_linked(self):
        self.assertEqual(pe.request_links([rec(contact="c2")], [note()], {"900": "215579392"}), {})

    def test_bad_ledger_rows_are_skipped(self):
        rows = [note(request_ids_json="not json"), note(request_ids_json="[]"), note(created_at="")]
        self.assertEqual(pe.request_links([rec()], rows, {"900": "215579392"}), {})


class LedgerAndInstall(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def test_ledger_reads_sent_rows_only_and_read_only(self):
        db = os.path.join(self.d, "ledger.sqlite3")
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE verify_messages (message_id, conversation_id, contact_id, request_ids_json, "
                    "created_at, campaign, status)")
        con.execute("INSERT INTO verify_messages VALUES ('m1','c','k','[\"r\"]',?,'uvn-status','sent')", (SENT,))
        con.execute("INSERT INTO verify_messages VALUES ('m2','c','k','[\"r\"]',?,'uvn-status','attempted')", (SENT,))
        con.execute("INSERT INTO verify_messages VALUES ('m3','c','k',NULL,?,'uvn-status','sent')", (SENT,))
        con.commit()
        con.close()
        rows = pe.read_ledger(db)
        self.assertEqual([r["message_id"] for r in rows], ["m1"])
        self.assertEqual(set(rows[0]), {"message_id", "conversation_id", "contact_id", "request_ids_json",
                                        "created_at", "campaign"})

    def test_missing_ledger_fails_closed(self):
        self.assertIsNone(pe.read_ledger(os.path.join(self.d, "nope.sqlite3")))

    def test_install_is_atomic_and_leaves_no_temp(self):
        src, target = os.path.join(self.d, "local.json"), os.path.join(self.d, "cs-proofs.json")
        json.dump({"entries": [1]}, open(src, "w"))
        json.dump({"entries": ["old"]}, open(target, "w"))
        pe.install(src, target)
        self.assertEqual(json.load(open(target)), {"entries": [1]})
        self.assertEqual(sorted(os.listdir(self.d)), ["cs-proofs.json", "local.json"])

    def test_install_refuses_invalid_json_and_keeps_the_old_feed(self):
        src, target = os.path.join(self.d, "local.json"), os.path.join(self.d, "cs-proofs.json")
        open(src, "w").write("{truncated")
        json.dump({"entries": ["old"]}, open(target, "w"))
        with self.assertRaises(ValueError):
            pe.install(src, target)
        self.assertEqual(json.load(open(target)), {"entries": ["old"]})
        self.assertEqual(sorted(os.listdir(self.d)), ["cs-proofs.json", "local.json"])

    def test_export_has_no_ssh_left(self):
        # The Mac version reached node-8 and the replica over ssh/scp; on node-8 nothing may.
        for f in ("proof_export.py", "gmail_proof.py", "proof_scan.py", "replica.py"):
            text = open(os.path.join(LIB, f)).read()
            self.assertNotIn('"ssh"', text, f)
            self.assertNotIn('"scp"', text, f)
            self.assertNotIn("135.148.169.37", text, f)


class Gmail(unittest.TestCase):
    def setUp(self):
        self.g = tempfile.mkdtemp()
        self.out = tempfile.mkdtemp()

    def pages(self, prefix, msgs, done=True):
        json.dump({"messages": msgs}, open(os.path.join(self.g, f"{prefix}-0.json"), "w"))
        with open(os.path.join(self.g, f"{prefix}.log"), "w") as fh:
            fh.write("2026-10-26T22:00:00Z start\n")
            if done:
                fh.write("2026-10-26T22:01:00Z DONE pages=1\n")

    def test_pull_refuses_an_unfinished_scan(self):
        self.pages("atti", [{"id": "1"}], done=False)
        with self.assertRaises(SystemExit):
            gp.pull("atti", self.g)

    def test_pull_reads_a_finished_scan(self):
        self.pages("atti", [{"id": "1"}, {"id": "2"}])
        self.assertEqual([m["id"] for m in gp.pull("atti", self.g)], ["1", "2"])

    def test_merge_keeps_ids_only_and_prunes_contacts_to_90_days(self):
        now = dt.datetime(2026, 10, 26, 22, 0, tzinfo=dt.timezone.utc)
        att = [{"id": "m1", "threadId": "t1", "date": "2026-10-26 10:00", "from": "Ann <ann@x.com>"},
               {"id": "m2", "threadId": "t2", "date": "2026-10-26 10:00", "from": "nobody@x.com"}]
        c90 = [{"id": "m3", "date": "2026-10-25 10:00", "from": "ann@x.com"},
               {"id": "m4", "date": "2026-06-01 10:00", "from": "ann@x.com"}]
        proof, contacts = gp.merge(self.out, att, c90, {"ann@x.com": 5}, now, full=False)
        self.assertEqual(list(proof), ["m1"])
        self.assertEqual(proof["m1"], {"msg": "m1", "thread": "t1", "created": "2026-10-26 10:00", "user_id": 5})
        self.assertEqual(list(contacts), ["m3"])
        blob = open(os.path.join(self.out, "gmail-proof.jsonl")).read() + open(
            os.path.join(self.out, "gmail-contacts.json")).read()
        self.assertNotIn("ann@x.com", blob)
        state = json.load(open(os.path.join(self.out, "gmail-state.json")))
        self.assertEqual(state, {"last_success_at": "2026-10-26T22:00:00Z"})


class ScanFailure(unittest.TestCase):
    """QA #1391: a conversation read that exhausts its retries must fail the scan, not vanish."""

    def setUp(self):
        import urllib.error
        self.err = urllib.error
        self.sleep, self.urlopen = ps.time.sleep, ps.urllib.request.urlopen
        ps.time.sleep = lambda s: None

    def tearDown(self):
        ps.time.sleep, ps.urllib.request.urlopen = self.sleep, self.urlopen

    def fail_with(self, exc):
        calls = []

        def urlopen(*a, **k):
            calls.append(1)
            raise exc
        ps.urllib.request.urlopen = urlopen
        return calls

    def test_exhausted_retries_raise(self):
        calls = self.fail_with(OSError("connection reset"))
        with self.assertRaises(ps.ScanIncomplete):
            ps.scan_conv("123")
        self.assertEqual(len(calls), 8)

    def test_persistent_5xx_raises(self):
        self.fail_with(self.err.HTTPError("u", 503, "x", {}, None))
        with self.assertRaises(ps.ScanIncomplete):
            ps.req("https://api.intercom.io/conversations/1")

    def test_a_genuine_404_is_a_skip(self):
        self.fail_with(self.err.HTTPError("u", 404, "x", {}, None))
        self.assertEqual(ps.scan_conv("123"), (None, []))


class WrapperFreshness(unittest.TestCase):
    """cs-proof-feed.sh advances intercom-last-success only when proof_scan.py succeeds."""

    def run_wrapper(self, scan_rc):
        d = tempfile.mkdtemp()
        lib, state = os.path.join(d, "lib"), os.path.join(d, "state")
        os.makedirs(lib)
        os.makedirs(os.path.join(state, "out"))
        open(os.path.join(state, "out", "scan.log"), "w").write("FULL PASS COMPLETE\n")
        for name, rc in (("proof_scan.py", scan_rc), ("gmail_proof.py", 0), ("proof_export.py", 0)):
            open(os.path.join(lib, name), "w").write(f"import sys; sys.exit({rc})\n")
        env_file = os.path.join(d, "main.env")
        open(env_file, "w").write("MUSOAI_INTERCOM_TOKEN=fake\n")
        env = dict(os.environ, CS_PROOF_LIB=lib, CS_PROOF_STATE=state, CS_PROOF_ENV=env_file,
                   CS_PROOF_KILL=os.path.join(d, "absent"), PYTHON=sys.executable)
        p = subprocess.run(["bash", WRAPPER], env=env, capture_output=True, text=True, timeout=60)
        return p.returncode, os.path.exists(os.path.join(state, "out", "intercom-last-success"))

    def test_failed_scan_does_not_advance_freshness(self):
        rc, fresh = self.run_wrapper(3)
        self.assertNotEqual(rc, 0)
        self.assertFalse(fresh)

    def test_complete_scan_advances_freshness(self):
        rc, fresh = self.run_wrapper(0)
        self.assertEqual(rc, 0)
        self.assertTrue(fresh)

    def test_kill_switch_stops_before_anything(self):
        d = tempfile.mkdtemp()
        kill = os.path.join(d, "off")
        open(kill, "w").close()
        env = dict(os.environ, CS_PROOF_KILL=kill, CS_PROOF_STATE=os.path.join(d, "s"))
        p = subprocess.run(["bash", WRAPPER], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0)
        self.assertIn("kill switch", p.stdout)
        self.assertFalse(os.path.exists(os.path.join(d, "s")))


class ExportUnresolvedContacts(unittest.TestCase):
    """QA #1391 (proof_export.py:141): a contact Intercom will not return must not silently drop
    that user's proof while cs-intercom looks fresh."""

    def setUp(self):
        self.out = tempfile.mkdtemp()
        with open(os.path.join(self.out, "intercom-proof.jsonl"), "w") as fh:
            for i, contact in enumerate(("ok", "flaky")):
                fh.write(json.dumps({"conv": f"c{i}", "part": f"p{i}", "created": str(T_SENT),
                                     "contact": contact, "human_reviewed": False}) + "\n")
        now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        open(os.path.join(self.out, "intercom-last-success"), "w").write(now)
        self.saved = (pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv)
        pe.emails_to_users = lambda emails: {"ok@x.com": 11, "flaky@x.com": 22} if emails else {}
        pe.read_ledger = lambda db=None: []
        sys.argv = ["proof_export.py", self.out, "--no-install"]

    def tearDown(self):
        pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv = self.saved

    def export(self, flaky_answer):
        pe.contact_email = lambda cid: (cid, "ok@x.com" if cid == "ok" else flaky_answer)
        rc = pe.main()
        doc = json.load(open(os.path.join(self.out, "cs-proofs.json")))
        part = [s for s in doc["sources"] if s["name"] == "cs-intercom"][0]
        cache = json.load(open(os.path.join(self.out, "contact-user-cache.json")))
        return rc, part, cache, doc

    def test_unreadable_contact_marks_intercom_stale_and_is_not_cached(self):
        rc, part, cache, _ = self.export(None)
        self.assertEqual(rc, 4)
        self.assertTrue(part["stale"])
        self.assertEqual(part["unresolved_contacts"], 1)
        self.assertNotIn("flaky", cache)  # retried next run, never remembered as "no account"

    def test_stale_part_makes_the_export_unknown_for_the_reader(self):
        sys.path.insert(0, os.path.join(LIB, ".."))
        from credit_review import proof_parts
        _, _, _, doc = self.export(None)
        with self.assertRaises(proof_parts.PartsError):
            proof_parts.check(doc, now=dt.datetime.now(dt.timezone.utc), max_age_h=24, max_skew_h=1)

    def test_genuine_404_is_no_account_and_the_part_stays_fresh(self):
        rc, part, cache, _ = self.export("")
        self.assertEqual(rc, 0)
        self.assertFalse(part["stale"])
        self.assertNotIn("unresolved_contacts", part)
        self.assertIsNone(cache["flaky"])

    def test_all_contacts_resolved_is_fresh(self):
        rc, part, _, doc = self.export("flaky@x.com")
        self.assertEqual(rc, 0)
        self.assertFalse(part["stale"])
        self.assertEqual(sorted(e["user_id"] for e in doc["entries"]), [11, 22])


class ProofAt(unittest.TestCase):
    """proof_at per entry (proof-loop lead, [key=pof-user-scope], hydra #1420): when the customer sent it."""

    def setUp(self):
        self.out = tempfile.mkdtemp()
        self.saved = (pe.contact_email, pe.emails_to_users, pe.read_ledger, pe.conv_source, sys.argv)
        pe.contact_email = lambda cid: (cid, f"{cid}@x.com")
        pe.emails_to_users = lambda emails: {"u1@x.com": 11, "u2@x.com": 22}
        pe.conv_source = lambda cid: (cid, "215579392")
        sys.argv = ["proof_export.py", self.out, "--no-install"]
        now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        open(os.path.join(self.out, "intercom-last-success"), "w").write(now)

    def tearDown(self):
        pe.contact_email, pe.emails_to_users, pe.read_ledger, pe.conv_source, sys.argv = self.saved

    def export(self, recs, grecs=(), ledger=()):
        pe.read_ledger = lambda db=None: list(ledger)
        with open(os.path.join(self.out, "intercom-proof.jsonl"), "w") as fh:
            for r in recs:
                fh.write(json.dumps(r) + "\n")
        with open(os.path.join(self.out, "gmail-proof.jsonl"), "w") as fh:
            for g in grecs:
                fh.write(json.dumps(g) + "\n")
        self.assertEqual(pe.main(), 0)
        return json.load(open(os.path.join(self.out, "cs-proofs.json")))["entries"]

    def test_whole_user_entry_carries_the_newest_part_of_the_conversation(self):
        recs = [{"conv": "c1", "part": "p1", "created": T_SENT + 600, "contact": "u1"},
                {"conv": "c1", "part": "p2", "created": str(T_SENT + 60), "contact": "u1"},
                {"conv": "c1", "part": "p3", "created": T_SENT + 3600, "contact": "u1"}]
        (e,) = self.export(recs)
        self.assertIsNone(e["request_id"])
        self.assertEqual(e["proof_at"], "2026-10-22T16:00:00Z")

    def test_unreadable_time_is_left_out_not_guessed(self):
        (e,) = self.export([{"conv": "c1", "part": "p1", "created": "n/a", "contact": "u1"}])
        self.assertNotIn("proof_at", e)

    def test_any_undated_part_leaves_the_entry_undated(self):
        # QA #1391: the undated part might be the newer proof; borrowing the dated part's time could
        # release a request the undated proof covers. Both orders.
        for created in ((None, T_SENT), (T_SENT, None), ("n/a", T_SENT + 5)):
            recs = [{"conv": "c1", "part": "p1", "created": created[0], "contact": "u1"},
                    {"conv": "c1", "part": "p2", "created": created[1], "contact": "u1"}]
            (e,) = self.export(recs)
            self.assertNotIn("proof_at", e, created)

    def test_mixed_parts_linked_to_a_request_leave_it_undated(self):
        recs = [{"conv": "c1", "part": "p1", "created": T_SENT + 60, "contact": "u1"},
                {"conv": "c1", "part": "p2", "created": "n/a", "contact": "u1"}]
        ledger = [{"message_id": "215579392", "conversation_id": "c1", "contact_id": "u1",
                   "request_ids_json": json.dumps(["r-a"]), "created_at": SENT, "campaign": "uvn-status"}]
        entries = self.export(recs, ledger=ledger)
        # p2 has no readable time, so it is not linked (created < sent is unknowable); p1 alone dates r-a
        scoped = [e for e in entries if e["request_id"]]
        self.assertEqual([(e["request_id"], e.get("proof_at")) for e in scoped], [("r-a", "2026-10-22T15:01:00Z")])
        whole = [e for e in entries if not e["request_id"]]
        self.assertNotIn("proof_at", whole[0])

    def test_newer_is_sticky_undated(self):
        self.assertEqual(pe.newer("2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z"), "2026-10-02T00:00:00Z")
        for a, b in ((None, SENT), (SENT, None), (pe.UNDATED, SENT), (SENT, pe.UNDATED)):
            self.assertEqual(pe.newer(a, b), pe.UNDATED)

    def test_gmail_entry_dates_from_the_message(self):
        (e,) = self.export([], grecs=[{"msg": "m1", "thread": "t", "created": "2026-10-27 16:17", "user_id": 22}])
        self.assertEqual((e["source"], e["proof_at"]), ("gmail", "2026-10-27T16:17:59Z"))

    def test_minute_precision_rounds_up_so_a_same_minute_request_stays_covered(self):
        self.assertEqual(pe.iso_gmail("2026-10-27 16:17"), "2026-10-27T16:17:59Z")
        self.assertIsNone(pe.iso_gmail("yesterday"))
        # Intercom parts are whole epoch seconds already: exact, no rounding needed
        self.assertEqual(pe.iso_epoch(T_SENT), SENT)

    def test_request_scoped_entries_carry_the_newest_linked_part(self):
        recs = [{"conv": "c1", "part": "p1", "created": T_SENT + 60, "contact": "u1"},
                {"conv": "c1", "part": "p2", "created": T_SENT + 7200, "contact": "u1"}]
        ledger = [{"message_id": "215579392", "conversation_id": None, "contact_id": "u1",
                   "request_ids_json": json.dumps(["r-a"]), "created_at": SENT, "campaign": "uvn-status"}]
        entries = self.export(recs, ledger=ledger)
        scoped = [e for e in entries if e["request_id"]]
        self.assertEqual(len(scoped), 1)
        self.assertEqual((scoped[0]["request_id"], scoped[0]["proof_at"]), ("r-a", "2026-10-22T17:00:00Z"))

    def test_merge_contract_passes_proof_at_through(self):
        # H-DevOps proof_merge.py copies cs entries verbatim and dedupes on
        # (user_id, request_id, kind, source, ref): proof_at is an extra key and must not
        # split an entry into two.
        recs = [{"conv": "c1", "part": "p1", "created": T_SENT, "contact": "u1"},
                {"conv": "c1", "part": "p2", "created": T_SENT + 5, "contact": "u1"}]
        entries = self.export(recs)
        keys = {(e["user_id"], e.get("request_id"), e["kind"], e.get("source"), e.get("ref")) for e in entries}
        self.assertEqual(len(keys), len(entries))


class OutageRecovery(unittest.TestCase):
    """QA #1391: after an outage longer than the default window, the next run must reach back to the
    last SUCCESS, not just 2 h / 2 days, or proof sent during the outage is never ingested."""

    def stamp(self, hours_ago):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "intercom-last-success")
        t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours_ago)
        open(p, "w").write(t.strftime("%Y-%m-%dT%H:%M:%SZ"))
        return p

    def test_intercom_window_reaches_back_to_the_last_success_plus_overlap(self):
        import time as _t
        self.assertAlmostEqual(ps.resume_hours(2, self.stamp(5), _t.time()), 6.0, delta=0.05)
        self.assertEqual(ps.resume_hours(2, self.stamp(0.25), _t.time()), 2.0)
        self.assertEqual(ps.resume_hours(2, self.stamp(24 * 90), _t.time()), float(ps.MAX_RESUME_H))

    def test_intercom_without_a_readable_stamp_uses_the_cap_not_2h(self):
        import time as _t
        self.assertEqual(ps.resume_hours(2, "/nonexistent/stamp", _t.time()), float(ps.MAX_RESUME_H))
        bad = os.path.join(tempfile.mkdtemp(), "s")
        open(bad, "w").write("garbage")
        self.assertEqual(ps.resume_hours(2, bad, _t.time()), float(ps.MAX_RESUME_H))

    def test_gmail_days_reach_back_to_the_last_success(self):
        now = dt.datetime(2026, 10, 28, 12, 0, tzinfo=dt.timezone.utc)
        self.assertEqual(gp.resume_days({"last_success_at": "2026-10-23T11:00:00Z"}, now), 7)  # 5.04 d -> 6 +1
        self.assertEqual(gp.resume_days({"last_success_at": "2026-10-28T11:00:00Z"}, now), 2)
        self.assertEqual(gp.resume_days({"full_done_at": "2026-10-20T12:00:00Z"}, now), 9)
        self.assertEqual(gp.resume_days({}, now), 400)
        self.assertEqual(gp.resume_days({"last_success_at": "x"}, now), 400)

    def test_gmail_incremental_asks_gog_for_the_whole_gap(self):
        out = tempfile.mkdtemp()
        five_days = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=5, hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        json.dump({"full_done_at": five_days, "last_success_at": five_days}, open(os.path.join(out, "gmail-state.json"), "w"))
        queries = []
        saved = (gp.scan, gp.pull, gp.replica.users_by_email, gp.replica.users_created_since)
        try:
            gp.scan = lambda prefix, q, run=None: (queries.append(q), subprocess.CompletedProcess([], 0))[1]
            gp.pull = lambda prefix, gdir=None: []
            gp.replica.users_by_email = lambda a: {}
            gp.replica.users_created_since = lambda since: {}
            gp.main(["gmail_proof.py", out, "--incremental"])
        finally:
            gp.scan, gp.pull, gp.replica.users_by_email, gp.replica.users_created_since = saved
        self.assertEqual(len(queries), 2)
        self.assertTrue(all("newer_than:7d" in q for q in queries), queries)

    def test_wrapper_passes_the_resume_stamp_and_stamps_the_start(self):
        d = tempfile.mkdtemp()
        lib, state = os.path.join(d, "lib"), os.path.join(d, "state")
        os.makedirs(lib)
        os.makedirs(os.path.join(state, "out"))
        open(os.path.join(state, "out", "scan.log"), "w").write("FULL PASS COMPLETE\n")
        argv_log = os.path.join(d, "argv")
        open(os.path.join(lib, "proof_scan.py"), "w").write(
            f"import sys, time; open({argv_log!r}, 'w').write(' '.join(sys.argv[1:])); time.sleep(1.2)\n")
        for name in ("gmail_proof.py", "proof_export.py"):
            open(os.path.join(lib, name), "w").write("import sys; sys.exit(0)\n")
        env_file = os.path.join(d, "main.env")
        open(env_file, "w").write("MUSOAI_INTERCOM_TOKEN=fake\n")
        before = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        env = dict(os.environ, CS_PROOF_LIB=lib, CS_PROOF_STATE=state, CS_PROOF_ENV=env_file,
                   CS_PROOF_KILL=os.path.join(d, "absent"), PYTHON=sys.executable)
        p = subprocess.run(["bash", WRAPPER], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        stamp_path = os.path.join(state, "out", "intercom-last-success")
        self.assertIn(f"--incremental 2 --resume-from {stamp_path}", open(argv_log).read())
        stamped = dt.datetime.strptime(open(stamp_path).read().strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        self.assertLessEqual(stamped, before + dt.timedelta(seconds=1))  # the START, not the end


class IntercomCap(unittest.TestCase):
    def test_a_capped_window_is_not_a_complete_scan(self):
        out = tempfile.mkdtemp()
        saved = (ps.search_ids, ps.run, os.environ.get("MUSOAI_INTERCOM_TOKEN"))
        try:
            ps.search_ids = lambda field, lo, hi: []
            ps.run = lambda ids, seen, label: None
            os.environ["MUSOAI_INTERCOM_TOKEN"] = "fake"
            rc = ps.main(["proof_scan.py", out, "--incremental", "2", "--resume-from", "/nonexistent"])
            self.assertEqual(rc, 5)
            stamp = os.path.join(out, "s")
            open(stamp, "w").write(dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
            self.assertEqual(ps.main(["proof_scan.py", out, "--incremental", "2", "--resume-from", stamp]), 0)
        finally:
            ps.search_ids, ps.run = saved[0], saved[1]
            if saved[2] is None:
                os.environ.pop("MUSOAI_INTERCOM_TOKEN", None)
            else:
                os.environ["MUSOAI_INTERCOM_TOKEN"] = saved[2]


class GmailLateRegistration(unittest.TestCase):
    """QA #1391: proof mailed BEFORE the sender registered is attributed once the account exists."""

    def setUp(self):
        self.out = tempfile.mkdtemp()
        self.now = dt.datetime(2026, 10, 28, 3, 0, tzinfo=dt.timezone.utc)
        self.att = [{"id": "m1", "threadId": "t1", "date": "2026-10-20 10:00", "from": "Late <late@x.com>"}]
        self.c90 = [{"id": "m2", "date": "2026-10-20 10:05", "from": "late@x.com"}]

    def read(self, name):
        return json.load(open(os.path.join(self.out, name)))

    def test_unmapped_sender_is_kept_hashed_then_attributed_on_signup(self):
        proof, contacts = gp.merge(self.out, self.att, self.c90, {}, self.now, full=False, late_users={})
        self.assertEqual((proof, contacts), ({}, {}))
        unmapped = self.read("gmail-unmapped.json")
        self.assertEqual(sorted(unmapped), ["m1", "m2"])
        blob = open(os.path.join(self.out, "gmail-unmapped.json")).read()
        self.assertNotIn("late@x.com", blob)  # the address is never stored
        self.assertEqual(oct(os.stat(os.path.join(self.out, ".sender-hmac-key")).st_mode & 0o777), "0o600")
        # the customer signs up; the next run sees the new account
        proof, contacts = gp.merge(self.out, [], [], {}, self.now, full=False, late_users={"late@x.com": 99})
        self.assertEqual(proof["m1"]["user_id"], 99)
        self.assertEqual(contacts["m2"]["user_id"], 99)
        self.assertEqual(self.read("gmail-unmapped.json"), {})

    def test_a_different_new_account_does_not_match(self):
        gp.merge(self.out, self.att, [], {}, self.now, full=False, late_users={})
        proof, _ = gp.merge(self.out, [], [], {}, self.now, full=False, late_users={"other@x.com": 5})
        self.assertEqual(proof, {})
        self.assertEqual(list(self.read("gmail-unmapped.json")), ["m1"])

    def test_late_check_window(self):
        self.assertEqual(gp.late_since({"late_reg_checked_at": "2026-10-28T02:00:00Z"}, self.now), "2026-10-27T02:00:00Z")
        self.assertEqual(gp.late_since({}, self.now), "2025-09-23T03:00:00Z")  # first check: 400 days

    def test_first_run_seeds_from_the_full_scan_pages(self):
        seed_dir = tempfile.mkdtemp()
        json.dump({"messages": [{"id": "old1", "threadId": "t", "date": "2026-10-01 09:00", "from": "early@x.com"}]},
                  open(os.path.join(seed_dir, "att-0.json"), "w"))
        open(os.path.join(seed_dir, "att.log"), "w").write("x DONE pages=1\n")
        state = {"full_done_at": "2026-10-27T03:00:00Z", "last_success_at": "2026-10-28T02:00:00Z"}
        json.dump(state, open(os.path.join(self.out, "gmail-state.json"), "w"))
        saved = (gp.SEED_DIR, gp.scan, gp.pull, gp.replica.users_by_email, gp.replica.users_created_since)
        orig_pull = gp.pull
        try:
            gp.SEED_DIR = seed_dir
            gp.scan = lambda prefix, q, run=None: subprocess.CompletedProcess([], 0)
            gp.pull = lambda prefix, gdir=None: orig_pull(prefix, gdir) if gdir == seed_dir else []
            gp.replica.users_by_email = lambda a: {}
            gp.replica.users_created_since = lambda since: {"early@x.com": 42}
            gp.main(["gmail_proof.py", self.out, "--incremental"])
        finally:
            gp.SEED_DIR, gp.scan, gp.pull, gp.replica.users_by_email, gp.replica.users_created_since = saved
        rows = [json.loads(l) for l in open(os.path.join(self.out, "gmail-proof.jsonl"))]
        self.assertEqual([(r["msg"], r["user_id"]) for r in rows], [("old1", 42)])
        self.assertIn("late_reg_checked_at", self.read("gmail-state.json"))


class NegativeMappings(unittest.TestCase):
    """QA #1391: 'no Muso account' is re-checked, so a customer who signs up after sending proof is
    attributed instead of staying unattributed forever."""

    def test_stale_negatives_selection(self):
        now = 1_800_000_000
        old = time_iso(now - 25 * 3600)
        fresh = time_iso(now - 3600)
        cache = {"legacy": None, "old": None, "fresh": None, "known": 5, "gone": None}
        neg = {"old": old, "fresh": fresh}
        got = pe.stale_negatives(cache, neg, {"legacy", "old", "fresh", "known"}, now)
        self.assertEqual(got, ["legacy", "old"])  # never-checked first; 'gone' has no proof parts left
        self.assertEqual(pe.stale_negatives(cache, neg, {"legacy", "old"}, now, batch=1), ["legacy"])

    def test_a_customer_who_registers_later_is_attributed(self):
        out = tempfile.mkdtemp()
        with open(os.path.join(out, "intercom-proof.jsonl"), "w") as fh:
            fh.write(json.dumps({"conv": "c1", "part": "p1", "created": T_SENT, "contact": "late"}) + "\n")
            fh.write(json.dumps({"conv": "c2", "part": "p2", "created": T_SENT, "contact": "recent"}) + "\n")
        json.dump({"late": None, "recent": None}, open(os.path.join(out, "contact-user-cache.json"), "w"))
        recent_check = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        json.dump({"recent": recent_check}, open(os.path.join(out, "contact-negative-checked.json"), "w"))
        open(os.path.join(out, "intercom-last-success"), "w").write(recent_check)
        asked = []
        saved = (pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv)
        try:
            pe.contact_email = lambda cid: (asked.append(cid), (cid, f"{cid}@x.com"))[1]
            pe.emails_to_users = lambda emails: {"late@x.com": 77, "recent@x.com": 88}
            pe.read_ledger = lambda db=None: []
            sys.argv = ["proof_export.py", out, "--no-install"]
            self.assertEqual(pe.main(), 0)
        finally:
            pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv = saved
        self.assertEqual(asked, ["late"])  # the fresh negative is not re-asked within the TTL
        cache = json.load(open(os.path.join(out, "contact-user-cache.json")))
        neg = json.load(open(os.path.join(out, "contact-negative-checked.json")))
        self.assertEqual(cache["late"], 77)
        self.assertNotIn("late", neg)
        entries = json.load(open(os.path.join(out, "cs-proofs.json")))["entries"]
        self.assertEqual([e["user_id"] for e in entries], [77])

    def test_a_failed_recheck_marks_the_part_stale(self):
        out = tempfile.mkdtemp()
        with open(os.path.join(out, "intercom-proof.jsonl"), "w") as fh:
            fh.write(json.dumps({"conv": "c1", "part": "p1", "created": T_SENT, "contact": "flaky"}) + "\n")
        json.dump({"flaky": None}, open(os.path.join(out, "contact-user-cache.json"), "w"))
        open(os.path.join(out, "intercom-last-success"), "w").write(
            dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        saved = (pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv)
        try:
            pe.contact_email = lambda cid: (cid, None)  # Intercom exhausted every retry
            pe.emails_to_users = lambda emails: {}
            pe.read_ledger = lambda db=None: []
            sys.argv = ["proof_export.py", out, "--no-install"]
            self.assertEqual(pe.main(), 4)
        finally:
            pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv = saved
        doc = json.load(open(os.path.join(out, "cs-proofs.json")))
        part = [x for x in doc["sources"] if x["name"] == "cs-intercom"][0]
        self.assertTrue(part["stale"])
        self.assertEqual(part["unresolved_contacts"], 1)
        neg = json.load(open(os.path.join(out, "contact-negative-checked.json")))
        self.assertNotIn("flaky", neg)  # not stamped as checked: retried next run

    def test_still_no_account_is_rechecked_later_not_forgotten(self):
        out = tempfile.mkdtemp()
        with open(os.path.join(out, "intercom-proof.jsonl"), "w") as fh:
            fh.write(json.dumps({"conv": "c1", "part": "p1", "created": T_SENT, "contact": "nobody"}) + "\n")
        json.dump({"nobody": None}, open(os.path.join(out, "contact-user-cache.json"), "w"))
        open(os.path.join(out, "intercom-last-success"), "w").write(
            dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        saved = (pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv)
        try:
            pe.contact_email = lambda cid: (cid, "nobody@x.com")
            pe.emails_to_users = lambda emails: {}
            pe.read_ledger = lambda db=None: []
            sys.argv = ["proof_export.py", out, "--no-install"]
            self.assertEqual(pe.main(), 0)
        finally:
            pe.contact_email, pe.emails_to_users, pe.read_ledger, sys.argv = saved
        neg = json.load(open(os.path.join(out, "contact-negative-checked.json")))
        self.assertIn("nobody", neg)  # stamped, so it is re-checked again after the TTL


def time_iso(epoch):
    import time as _t
    return _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(epoch))


class GmailScanPages(unittest.TestCase):
    """QA #1391 (gmail_scan.sh:21): only a successful gog run printing a result page is a page."""

    SCAN = os.path.join(LIB, "gmail_scan.sh")

    def scan(self, gog_body):
        d = tempfile.mkdtemp()
        bindir, gdir = os.path.join(d, "bin"), os.path.join(d, "g")
        os.makedirs(bindir)
        gog = os.path.join(bindir, "gog")
        with open(gog, "w") as fh:
            fh.write('#!/bin/bash\ntouch "$(dirname "$0")/called"\n' + gog_body + "\n")
        os.chmod(gog, 0o755)
        empty_env = os.path.join(d, "empty.env")
        open(empty_env, "w").close()
        # Isolation: the CI runner can be a host that holds the real env file and a real gog.
        # An empty env file + an absolute fake gog mean this test can never reach a real mailbox.
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], CS_PROOF_GMAIL_DIR=gdir,
                   CS_PROOF_ENV=empty_env, CS_PROOF_GOG=gog,
                   CS_PROOF_GMAIL_BACKOFF="0", CS_PROOF_GMAIL_PAGE_PAUSE="0")
        p = subprocess.run(["bash", self.SCAN, "atti", "newer_than:2d"], env=env, capture_output=True,
                           text=True, timeout=60)
        log = open(os.path.join(gdir, "atti.log")).read()
        pages = sorted(f for f in os.listdir(gdir) if f.startswith("atti-") and f.endswith(".json"))
        self.assertTrue(os.path.exists(os.path.join(bindir, "called")), "the fake gog was not the one that ran")
        return p.returncode, log, pages, gdir

    def test_failed_gog_with_json_error_is_never_a_page(self):
        rc, log, pages, gdir = self.scan('echo \'{"error": "No auth"}\'; exit 4')
        self.assertNotEqual(rc, 0)
        self.assertNotIn("DONE", log)
        self.assertIn("FAILED", log)
        self.assertEqual(pages, [])
        with self.assertRaises(SystemExit):
            gp.pull("atti", gdir)

    def test_exit_0_with_a_non_result_object_is_not_a_page(self):
        rc, log, pages, _ = self.scan('echo \'{"error": {"code": 429}}\'')
        self.assertNotEqual(rc, 0)
        self.assertNotIn("DONE", log)
        self.assertEqual(pages, [])

    def test_a_real_result_page_finishes_done(self):
        rc, log, pages, gdir = self.scan('echo \'{"messages": [{"id": "m1"}], "nextPageToken": ""}\'')
        self.assertEqual(rc, 0)
        self.assertIn("DONE pages=1", log)
        self.assertEqual([m["id"] for m in gp.pull("atti", gdir)], ["m1"])

    def test_no_matches_is_an_empty_result_page_and_done(self):
        # live gog on node-8 answers a zero-hit search with rc 0 and {"messages": [], ...}
        rc, log, _, gdir = self.scan('echo \'{"messages": [], "nextPageToken": ""}\'')
        self.assertEqual(rc, 0)
        self.assertEqual(gp.pull("atti", gdir), [])

    def test_pull_refuses_a_non_result_page_even_if_marked_done(self):
        gdir = tempfile.mkdtemp()
        json.dump({"error": "x"}, open(os.path.join(gdir, "atti-0.json"), "w"))
        open(os.path.join(gdir, "atti.log"), "w").write("x DONE pages=1\n")
        with self.assertRaises(SystemExit):
            gp.pull("atti", gdir)


if __name__ == "__main__":
    unittest.main(verbosity=2)
