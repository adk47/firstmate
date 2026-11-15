"""The stage-2 release from the proof-on-file hold (Fable 2026-10-26 13:23Z, GO 2):
credit_review/stage2_verdicts.py, the uvn_status runner (uvn-status for no_document, gap-ask for
need_more) and the ledger's gap-ask rules. The gate is faked; its own behaviour is in
intercom-verify-request.bats. No network, no Trino."""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production

import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))

from credit_review import stage2_verdicts, uvn_status, verify_ledger  # noqa: E402

# The gate script the runner reads its send locks from (uvn_status.CAMPAIGN_LOCKS): uvn-status unlocked as committed
# (captain 2026-10-29 03:2xZ), so these tests exercise the runner's own rules, not the lock.
import tempfile as _tf
UNLOCKED_GATE = _tf.NamedTemporaryFile("w", suffix="-gate.sh", delete=False).name
open(UNLOCKED_GATE, "w").write("readonly UVN_STATUS_COPY_APPROVED=1\nreadonly CREDIT_HOLD_STATUS_COPY_APPROVED=1\n")
from credit_review import verify_notify as _vn_r5  # noqa: E402
_vn_r5.PRESENTED_LOOKUP = lambda ids: {}  # r5: presented profile ids never come from the replica in tests
from credit_verify.proof import FORENSICS_VERSION  # noqa: E402
from test_uvn_status import NOW, FakeGate, proof, replica  # noqa: E402

STAGE2_SCHEMA = """CREATE TABLE stage2_shadow (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
  judged_at TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER, paid INTEGER,
  popularity INTEGER, tier TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, verdict TEXT, proof_id TEXT,
  source_ref TEXT, doc_kind TEXT, documents INTEGER NOT NULL, detail_json TEXT NOT NULL, analyzer_version TEXT);"""


def entry(uid, kind="human_approved_after_doc", rid=None):
    return {"user_id": uid, "request_id": rid, "kind": kind, "source": "intercom", "ref": "c"}


class Store:
    def __init__(self, path):
        self.path = str(path)
        db = sqlite3.connect(self.path)
        db.executescript(STAGE2_SCHEMA)
        db.close()

    def add(self, rid, uid, outcome, *, role="Mixing", paid=1, kind="contract", proof_id="p1", lists=(),
            reason="r", version=FORENSICS_VERSION, run="run"):
        db = sqlite3.connect(self.path)
        db.execute("INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, paid, outcome, reason,"
                   " proof_id, doc_kind, documents, detail_json, analyzer_version) VALUES"
                   " (?,'2026-10-26T12:00:00Z',?,?,?,?,?,?,?,?,1,?,?)",
                   (run, rid, role, uid, paid, outcome, reason, proof_id, kind,
                    json.dumps([{"proof_id": proof_id, "lists": list(lists)}]), version))
        db.commit()
        db.close()


class VerdictTests(unittest.TestCase):
    def setUp(self):
        self.s = Store(Path(tempfile.mkdtemp()) / "proof.sqlite")

    def test_the_analyzer_version_is_read_from_the_deployed_tree(self):
        self.assertEqual(stage2_verdicts.analyzer_version(), FORENSICS_VERSION)

    def test_a_request_is_released_only_when_every_role_agrees_and_the_account_is_not_held(self):
        s = self.s
        s.add("a1", 1, "need_more", role="Mixing")
        s.add("a1", 1, "need_more", role="Mastering")
        s.add("a2", 1, "need_more", role="Mixing")
        s.add("a2", 1, "review", role="Mastering")                    # mixed: not released
        s.add("a3", 1, "review")
        s.add("a3", 1, "need_more")                                   # the latest row per role wins
        s.add("b1", 2, "need_more")
        s.add("b2", 2, "reject_hold")                                 # account 2 is held
        s.add("c1", 3, "need_more")
        s.add("c2", 3, "human", reason="account hold: a document on file for this account is likely forged")
        s.add("d1", 4, "need_more", version="pf-0")                   # stale analyzer: no verdict
        v = stage2_verdicts.load(s.path)
        self.assertEqual(stage2_verdicts.released(v, "need_more"), {"a1", "a3"})
        self.assertEqual(stage2_verdicts.held_accounts(v), {2, 3})
        pop = stage2_verdicts.population("need_more", path=s.path)
        self.assertEqual(pop, [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["a1", "a3"]}])

    def test_undetermined_is_asked_as_no_document_only_after_a_rerun(self):
        # firstmate inbox 010: "undetermined -> rerun once then ask".
        self.s.add("u1", 1, "undetermined", run="r1")
        self.assertEqual(stage2_verdicts.released(stage2_verdicts.load(self.s.path), "no_document"), set())
        self.s.add("u1", 1, "undetermined", run="r2")
        self.assertEqual(stage2_verdicts.released(stage2_verdicts.load(self.s.path), "no_document"), {"u1"})
        self.assertTrue(stage2_verdicts.gap_credits(["u1"], outcome="no_document", user_id="1", path=self.s.path)["eligible"])
        self.assertFalse(stage2_verdicts.gap_credits(["u1"], user_id="1", path=self.s.path)["eligible"], "never a gap ask")
        # a rerun that found something replaces it (the latest row stands) ...
        self.s.add("u1", 1, "review", run="r3")
        self.assertEqual(stage2_verdicts.released(stage2_verdicts.load(self.s.path), "no_document"), set())
        # ... and resets the rerun count: a new undetermined spell needs its own rerun (QA on 794e735).
        self.s.add("u1", 1, "undetermined", run="r4")
        self.assertEqual(stage2_verdicts.released(stage2_verdicts.load(self.s.path), "no_document"), set())
        self.s.add("u1", 1, "undetermined", run="r5")
        self.assertEqual(stage2_verdicts.released(stage2_verdicts.load(self.s.path), "no_document"), {"u1"})
        # several rows of one run are one judgement
        self.s.add("u2", 1, "undetermined", run="r1")
        self.s.add("u2", 1, "undetermined", run="r1")
        self.assertNotIn("u2", stage2_verdicts.released(stage2_verdicts.load(self.s.path), "no_document"))

    def test_gap_credits_reads_the_verdict_for_this_account_only(self):
        s = self.s
        s.add("a1", 1, "need_more", kind="split_sheet", proof_id="pX", lists=["Other Song"])
        s.add("a2", 1, "no_document", kind="")
        ok = stage2_verdicts.gap_credits(["A1"], user_id="1", path=s.path)
        self.assertTrue(ok["eligible"])
        self.assertEqual(ok["credits"]["a1"], {"roles": ["Mixing"], "doc_kind": "split_sheet", "proof_id": "pX",
                                               "lists": ["Other Song"]})
        self.assertFalse(stage2_verdicts.gap_credits(["a1"], user_id="2", path=s.path)["eligible"])
        self.assertIn("no_document", stage2_verdicts.gap_credits(["a1", "a2"], user_id="1", path=s.path)["reason"])
        self.assertIn("no verdict", stage2_verdicts.gap_credits(["zz"], user_id="1", path=s.path)["reason"])
        missing = stage2_verdicts.gap_credits(["a1"], user_id="1", path=str(Path(s.path).with_name("nope")))
        self.assertFalse(missing["eligible"])
        s.add("a9", 1, "reject_hold")
        self.assertIn("holds this account", stage2_verdicts.gap_credits(["a1"], user_id="1", path=s.path)["reason"])

    def test_the_cli_answers_json_under_isolated_mode(self):
        import subprocess
        self.s.add("a1", 1, "need_more")
        out = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/credit_review/stage2_verdicts.py"),
                              "--db", self.s.path, "gap-credits", "--request-ids", "a1", "--user-id", "1"],
                             capture_output=True, text=True, check=True).stdout
        self.assertTrue(json.loads(out)["eligible"])


class NotForgedTests(unittest.TestCase):
    """firstmate 152 / Fable l11b-forged-11: a reject_hold resting on a document ruled NOT forged reads as review, and
    the account is no longer held for a forgery; everything else about the store stays as it is."""
    PID = "a" * 64

    def setUp(self):
        self.s = Store(Path(tempfile.mkdtemp()) / "proof.sqlite")
        self.policy = Path(tempfile.mkdtemp()) / "not-forged.json"
        self.old = stage2_verdicts.NOT_FORGED
        stage2_verdicts.NOT_FORGED = str(self.policy)

    def tearDown(self):
        stage2_verdicts.NOT_FORGED = self.old

    def rule(self, entries):
        self.policy.write_text(json.dumps({"documents": entries}))

    def test_a_ruled_document_lifts_the_account_hold_and_the_request_goes_to_review(self):
        self.s.add("f1", 7, "reject_hold", proof_id=self.PID, reason="likely forged")
        self.s.add("g1", 7, "need_more", proof_id="other")
        self.assertEqual(stage2_verdicts.held_accounts(stage2_verdicts.load(self.s.path)), {7})
        self.rule([{"proof_id": self.PID, "user_id": 7, "ruling": "l11b-forged-11"}])
        v = stage2_verdicts.load(self.s.path)
        self.assertEqual(stage2_verdicts.held_accounts(v), set())
        self.assertEqual(v["f1"]["Mixing"].outcome, "review")
        self.assertIn("ruled NOT forged (l11b-forged-11)", v["f1"]["Mixing"].reason)
        self.assertEqual(stage2_verdicts.released(v, "need_more"), {"g1"})     # the account's other ask flows again
        self.assertNotIn("f1", stage2_verdicts.released(v, "need_more"))      # the ruled request is not asked

    def test_the_ruling_binds_to_its_user_and_a_broken_file_releases_nothing(self):
        self.s.add("f1", 7, "reject_hold", proof_id=self.PID)
        for bad in ([{"proof_id": self.PID, "user_id": 8, "ruling": "x"}],      # another account's document
                    [{"proof_id": self.PID[:10], "user_id": 7, "ruling": "x"}],  # not a sha256
                    [{"proof_id": self.PID, "user_id": 7, "ruling": " "}],      # no ruling reference
                    [{"proof_id": self.PID, "user_id": "7", "ruling": "x"}]):   # user id not an integer
            self.rule(bad)
            self.assertEqual(stage2_verdicts.held_accounts(stage2_verdicts.load(self.s.path)), {7}, bad)
        for shape in ('{"documents": 1}', '{"documents": "x"}', '{"documents": {"a": 1}}', '[1, 2]', '"x"',
                      '{"documents": [1, null, "x"]}'):
            self.policy.write_text(shape)           # QA #1543: valid JSON, wrong shape -> holds stay, no crash
            self.assertEqual(stage2_verdicts.held_accounts(stage2_verdicts.load(self.s.path)), {7}, shape)
            self.assertFalse(stage2_verdicts.gap_credits(["f1"], user_id="7", path=self.s.path)["eligible"])
        self.policy.write_text("{not json")
        self.assertEqual(stage2_verdicts.held_accounts(stage2_verdicts.load(self.s.path)), {7})
        self.policy.unlink()
        self.assertEqual(stage2_verdicts.held_accounts(stage2_verdicts.load(self.s.path)), {7})

    def test_the_gate_cli_honours_the_ruling_under_isolated_mode(self):
        import os
        import subprocess
        self.s.add("f1", 7, "reject_hold", proof_id=self.PID)
        self.s.add("g1", 7, "need_more", proof_id="other")
        self.rule([{"proof_id": self.PID, "user_id": 7, "ruling": "l11b-forged-11"}])
        out = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/credit_review/stage2_verdicts.py"),
                              "--db", self.s.path, "gap-credits", "--request-ids", "g1", "--user-id", "7"],
                             capture_output=True, text=True, check=True,
                             env={**os.environ, "STAGE2_NOT_FORGED": str(self.policy)}).stdout
        self.assertTrue(json.loads(out)["eligible"])

    def test_the_shipped_policy_is_well_formed(self):
        got = stage2_verdicts.not_forged(self.old)
        self.assertEqual(sorted(e["user_id"] for e in got.values()), [121667, 184339])


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="s2ask-"))
        self.ledger = str(self.dir / "ledger.sqlite3")
        self.proof = self.dir / "proof.json"
        self.list = self.dir / "list.json"
        self.s = Store(self.dir / "proof.sqlite")

    def write_list(self, users):
        self.list.write_text(json.dumps({"generated_at": (NOW - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                         "users": users}))

    def go(self, campaign, q, *, from_stage2=True, mode="apply", gate=None, **kw):
        gate = gate or FakeGate()
        rep = uvn_status.run(list_path=str(self.list) if not from_stage2 else None, segment=kw.pop("segment", "paid"),
                             mode=mode, max_users=10, ledger_path=self.ledger, proof_path=str(self.proof), query=q,
                             runner=gate, wrapper=UNLOCKED_GATE, now=NOW, pace_seconds=0, campaign=campaign,
                             from_stage2=from_stage2, stage2_path=self.s.path, **kw)
        return rep, gate

    def sent(self, gate):
        return {p["user"]["id"]: sorted(c["request_id"] for c in p["credits"]) for _, p in gate.calls}

    # -- item 1: a document on file excludes only on an approved proof for the credit or no release --

    def test_list_driven_uvn_status_lets_through_a_documented_user_stage2_found_nothing_for(self):
        proof(self.proof, [entry(1), entry(2, "pending_doc"), entry(3, "approved_doc", rid="r3")])
        self.s.add("r1", 1, "no_document")
        self.s.add("r3", 3, "no_document")
        self.write_list([{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2, 3)])
        rep, gate = self.go("uvn-status", replica([1, 2, 3]), from_stage2=False)
        self.assertEqual(self.sent(gate), {"1": ["r1"]})
        # 2: a document with no stage-2 verdict; 3: an approved proof names the credit
        self.assertEqual((rep.proof_on_file, rep.stage2_released, rep.sent_notes), (2, 1, 1))

    def test_without_a_readable_store_the_old_rule_stands(self):
        proof(self.proof, [entry(1)])
        self.write_list([{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}])
        self.s.path = str(self.dir / "missing.sqlite")
        rep, gate = self.go("uvn-status", replica([1]), from_stage2=False)
        self.assertEqual((gate.calls, rep.proof_on_file), ([], 1))
        rep, gate = self.go("uvn-status", replica([1]), from_stage2=True)
        self.assertIn("missing", rep.halted)
        self.assertEqual(gate.calls, [])

    # -- item 2: no_document users whose rows are still `unverified` get the uvn-status copy --

    def test_stage2_uvn_status_reaches_no_document_users_whose_rows_are_unverified(self):
        proof(self.proof, [entry(1), entry(2), entry(4)])
        self.s.add("r1", 1, "no_document")
        self.s.add("u2", 2, "no_document")
        self.s.add("r4", 4, "need_more")                       # gap ask, not this campaign
        q = replica([1, 2, 4], status={1: "unverified", 2: "user_verification_needed", 4: "unverified"},
                    requests={1: ["r1", "x1"], 2: ["u2"], 4: ["r4"]})
        rep, gate = self.go("uvn-status", q)
        # x1 is unverified with no release: it is not shown (it is with us, not waiting on them)
        self.assertEqual(self.sent(gate), {"1": ["r1"], "2": ["u2"]})
        self.assertTrue(all("--campaign" in a and a[a.index("--campaign") + 1] == "uvn-status" for a, _ in gate.calls))

    def test_a_stage2_note_names_only_released_requests_whatever_the_proof_export_says(self):
        # QA on #1364: an unjudged request of the same user (y1) is never named, and the released
        # one (r1) is not suppressed by it, with or without a proof-on-file entry for the user.
        self.s.add("r1", 1, "no_document")
        q = replica([1], status={1: "user_verification_needed"}, requests={1: ["r1", "y1"]})
        for entries in ([entry(1)], []):
            self.ledger = str(self.dir / f"ledger-{len(entries)}.sqlite3")
            proof(self.proof, entries)
            rep, gate = self.go("uvn-status", q)
            self.assertEqual(self.sent(gate), {"1": ["r1"]}, entries)
            self.assertEqual(rep.proof_on_file, 0)

    # -- item 3: the gap ask --

    def test_gap_ask_sends_only_need_more_credits_through_the_gap_campaign(self):
        proof(self.proof, [entry(1), entry(2), entry(3, "approved_doc", rid="r3")])
        self.s.add("r1", 1, "need_more")
        self.s.add("z1", 1, "review")
        self.s.add("r2", 2, "need_more")
        self.s.add("r3", 3, "need_more")
        q = replica([1, 2, 3], status={1: "unverified", 2: "user_verification_needed", 3: "unverified"},
                    requests={1: ["r1", "z1"], 2: ["r2"], 3: ["r3"]})
        rep, gate = self.go("gap-ask", q, exclude_users={"2"})
        self.assertEqual(self.sent(gate), {"1": ["r1"]})
        argv = gate.calls[0][0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "gap-ask")
        self.assertEqual((rep.excluded, rep.proof_on_file), (1, 1))
        text = uvn_status.render(rep, "apply", "paid")
        self.assertTrue(text.startswith("GAP ASK (paid): "), text)
        self.assertIn("1 left out: another lane messages them today (--exclude-users)", text)
        self.assertIn("1 documents on file (not asked)", text)

    def test_only_users_scopes_the_run_to_the_named_account_whatever_else_became_eligible(self):
        # QA on #1945: the one-account call names its account POSITIVELY. A same-segment user who
        # became eligible after the caller's own read sorts ahead of ours (paid first, then user id),
        # and can never take the single slot.
        proof(self.proof, [entry(6), entry(7)])
        self.s.add("r6", 6, "need_more")
        self.s.add("r7", 7, "need_more")
        q = replica([6, 7], status={6: "unverified", 7: "unverified"}, requests={6: ["r6"], 7: ["r7"]})
        rep, gate = self.go("gap-ask", q, only_users={"7"})
        self.assertEqual(self.sent(gate), {"7": ["r7"]})
        self.assertEqual(len(gate.calls), 1)
        # ... and an account that is no longer in the population is offered to nobody.
        rep, gate = self.go("gap-ask", replica([6, 7]), only_users={"9"})
        self.assertEqual(self.sent(gate), {})

    def test_gap_ask_needs_a_stage2_population_and_rereads_the_verdict_before_each_send(self):
        with self.assertRaises(ValueError):
            uvn_status.run(list_path=str(self.list), segment="paid", campaign="gap-ask")
        proof(self.proof, [entry(1), entry(2)])
        self.s.add("r1", 1, "need_more")
        self.s.add("r2", 2, "need_more")
        s = self.s

        class Rejudging(FakeGate):
            def __call__(self, argv):
                s.add("r2", 2, "review")                         # a later stage-2 run, mid-wave
                return super().__call__(argv)
        rep, gate = self.go("gap-ask", replica([1, 2], status={1: "unverified", 2: "unverified"}), gate=Rejudging())
        self.assertEqual(self.sent(gate), {"1": ["r1"]})
        self.assertEqual(rep.proof_on_file, 1)

    def test_the_fraud_lens_runs_first_held_never_messaged_ask_only_never_gap_asked(self):
        # main's fraud lens (Fable Ruling B) applies to the stage-2 campaigns too: a held user is
        # never messaged; an ask_only (big-track single-signal) user gets only the uvn-status ask.
        from credit_review import fraud_lens
        proof(self.proof, [entry(1), entry(2), entry(3)])
        for u in (1, 2, 3):
            self.s.add(f"r{u}", u, "need_more")
        verdicts = {1: fraud_lens.Verdict(held=["velocity"]), 2: fraud_lens.Verdict(single_signal_rows=2),
                    3: fraud_lens.Verdict()}
        rep, gate = self.go("gap-ask", replica([1, 2, 3], status={1: "unverified", 2: "unverified", 3: "unverified"}),
                            lens=lambda ids: {i: verdicts[i] for i in ids})
        self.assertEqual(self.sent(gate), {"3": ["r3"]})
        self.assertEqual((rep.fraud_held, rep.ask_only), (1, 1))
        self.s.add("n2", 2, "no_document")
        rep, gate = self.go("uvn-status", replica([2], status={2: "user_verification_needed"}, requests={2: ["n2"]}),
                            lens=lambda ids: {i: verdicts[i] for i in ids})
        self.assertEqual(self.sent(gate), {"2": ["n2"]})

    def test_gap_ask_dry_run_sends_nothing_and_checks_the_same_rules(self):
        proof(self.proof, [entry(1)])
        self.s.add("r1", 1, "need_more")
        rep, gate = self.go("gap-ask", replica([1], status={1: "unverified"}), mode="dry-run")
        self.assertEqual(self.sent(gate), {"1": ["r1"]})
        self.assertIn("--validate", gate.calls[0][0])  # the gate checks the verdict, posts nothing


def _policy_cap(test: unittest.TestCase, shared: int, email_cap: int = 2) -> None:
    """The two numbers the overflow path reads: DAILY_MAX paces EMAIL (the per-campaign cap the run takes), and
    policy_credit_cap() is the SHARED day contract it re-reads before every send. Gridable only because they can be
    pinned apart here; in the deployed configuration they are the same number."""
    saved_fn, saved_max = uvn_status.policy_credit_cap, uvn_status.DAILY_MAX
    uvn_status.policy_credit_cap = lambda *a, **k: shared
    uvn_status.DAILY_MAX = email_cap
    test.addCleanup(setattr, uvn_status, "policy_credit_cap", saved_fn)
    test.addCleanup(setattr, uvn_status, "DAILY_MAX", saved_max)


class InappOverflowTests(unittest.TestCase):
    """captain 2026-10-26 16:05Z (firstmate inbox 010): the cap paces EMAIL only; past it the
    note goes in-app (gate --channel inapp), one note per user still."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="inapp-"))
        self.list = self.dir / "list.json"
        self.ledger = str(self.dir / "ledger.sqlite3")
        self.proof = self.dir / "proof.json"
        proof(self.proof)
        users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 6)]
        self.list.write_text(json.dumps({"generated_at": (NOW - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                         "users": users}))
        self._cap = uvn_status.DAILY_MAX
        uvn_status.DAILY_MAX = 2
        self.addCleanup(setattr, uvn_status, "DAILY_MAX", self._cap)

    def gate(self):
        ledger = self.ledger

        class ChannelGate(FakeGate):
            def __call__(self, argv):
                super().__call__(argv)
                payload = self.calls[-1][1]
                mt = "inapp" if "--channel" in argv else "email"
                db = verify_ledger.connect(ledger)
                try:
                    c = verify_ledger.claim(db, campaign="uvn-status", user_key=payload["user"]["email"],
                                            day=NOW.strftime("%Y-%m-%d"),
                                            request_ids=[r["request_id"] for r in payload["credits"]], message_type=mt,
                                            approved_by="U7RP6HKUZ", approval_ref="ref", now=NOW,
                                            user_id=payload["user"]["id"])
                    verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=str(len(self.calls)))
                finally:
                    db.close()
                import subprocess
                return subprocess.CompletedProcess(argv, 0, f"POSTED {mt} message={len(self.calls)} credits=1", "")
        return ChannelGate()

    def gate_file(self) -> str:
        """The gate script the runner reads its locks from (main 10-28): a real apply halts before any gate call while
        `readonly UVN_STATUS_COPY_APPROVED` reads 0, so the stub must read 1 - this class is about the CHANNEL, not
        about the copy lock (test_uvn_status covers that)."""
        p = self.dir / "gate.sh"
        p.write_text("readonly UVN_STATUS_COPY_APPROVED=1\nreadonly CREDIT_HOLD_STATUS_COPY_APPROVED=0\n")
        return str(p)

    def go(self, **kw):
        gate = self.gate()
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=50,
                             ledger_path=self.ledger, proof_path=str(self.proof), query=replica(range(1, 6)), runner=gate,
                             wrapper=self.gate_file(), now=NOW, pace_seconds=0, lens=lambda ids: {i: __import__(
                                 "credit_review.fraud_lens", fromlist=["Verdict"]).Verdict() for i in ids}, **kw)
        return rep, gate

    def test_without_overflow_the_cap_still_bounds_every_note(self):
        rep, gate = self.go()
        self.assertEqual((len(gate.calls), rep.sent_notes), (2, 2))
        self.assertTrue(all("--channel" not in a for a, _ in gate.calls))

    def test_with_overflow_email_stops_at_the_cap_and_everyone_else_gets_the_in_app_note(self):
        rep, gate = self.go(inapp_overflow=True)
        self.assertEqual(rep.sent_notes, 5)
        self.assertEqual(["--channel" in a for a, _ in gate.calls], [False, False, True, True, True])
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.sent_today(db, campaign="uvn-status", day=NOW.strftime("%Y-%m-%d"),
                                                  message_type="email"), 2)
        self.assertEqual(verify_ledger.sent_today(db, campaign="uvn-status", day=NOW.strftime("%Y-%m-%d")), 5)


    def test_QA1370_the_equal_cap_case_still_reaches_every_user_in_app(self):
        """QA #1370 (Important): the deployed configuration is cap == DAILY_MAX == the policy number. Counting the in-app
        notes against the shared cap made the overflow INERT there - the 2,501st user was deferred before `--channel
        inapp` was chosen. The caps pace EMAIL (captain 2026-10-26 16:05Z), so at the equal cap 2 emails go out and
        every remaining user still gets the in-app note."""
        _policy_cap(self, 2, email_cap=2)      # equal: the deployed configuration
        rep, gate = self.go(inapp_overflow=True)
        self.assertEqual(["--channel" in a for a, _ in gate.calls], [False, False, True, True, True])
        self.assertEqual(rep.sent_notes, 5)
        db = verify_ledger.connect(self.ledger)
        today = NOW.strftime("%Y-%m-%d")
        self.assertEqual(verify_ledger.sent_today(db, campaign="uvn-status", day=today, message_type="email"), 2)
        self.assertEqual(verify_ledger.sent_today(db, campaign="uvn-status", day=today, message_type="inapp"), 3)

    def test_QA1370_an_in_app_note_never_spends_another_campaigns_email_budget(self):
        """The other half of the same rule: the shared credit cap is spent by EMAIL notes only, so the in-app notes this
        run sends must leave the other credit campaigns' email room intact (QA #1370)."""
        _policy_cap(self, 2, email_cap=2)
        db = verify_ledger.connect(self.ledger)
        try:                                    # another credit campaign already sent 1 of the day's 2 emails
            c = verify_ledger.claim(db, campaign="proof-need-ask", user_key="someone@example.com",
                                    day=NOW.strftime("%Y-%m-%d"), request_ids=["z1"], message_type="email",
                                    approved_by="U7RP6HKUZ", approval_ref="ref", now=NOW, user_id=999)
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="x")
        finally:
            db.close()
        self.assertEqual(uvn_status.credit_group_left(self.ledger, NOW.strftime("%Y-%m-%d")), 1)
        rep, gate = self.go(inapp_overflow=True)
        # one email of room left -> one email, then every remaining user is in-app, and the room is now spent by EMAIL
        self.assertEqual(["--channel" in a for a, _ in gate.calls], [False, True, True, True, True])
        self.assertEqual(rep.sent_notes, 5)
        db = verify_ledger.connect(self.ledger)
        try:
            today = NOW.strftime("%Y-%m-%d")
            self.assertEqual(sum(verify_ledger.sent_today(db, campaign=c, day=today, message_type="email")
                                 for c in uvn_status.CREDIT_GROUP), 2, "email budget spent by emails, 1+1")
            self.assertEqual(verify_ledger.sent_today(db, campaign="uvn-status", day=today, message_type="inapp"), 4)
        finally:
            db.close()
        # and the proof-need-ask campaign can no longer email anyone today: the 2 email slots are used
        self.assertEqual(uvn_status.credit_group_left(self.ledger, NOW.strftime("%Y-%m-%d")), 0)


class CountCopyTests(unittest.TestCase):
    """status-team-review: an unshowable or over-cap user is told by the count-only note
    (firstmate inbox 005), never held."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="count-"))
        self.list = self.dir / "list.json"
        self.ledger = str(self.dir / "ledger.sqlite3")

    def go(self, users, q, campaign="status-team-review", **kw):
        self.list.write_text(json.dumps({"generated_at": (NOW - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                         "users": users}))
        gate = FakeGate()
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=10,
                             ledger_path=self.ledger, query=q, runner=gate, wrapper=UNLOCKED_GATE, now=NOW, pace_seconds=0,
                             campaign=campaign, **kw)
        return rep, gate

    def test_an_all_unshowable_user_gets_the_count_note_and_a_showable_one_the_listed_note(self):
        users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["a1", "a2"]},
                 {"user_id": 2, "paid": True, "skip": None, "request_ids": ["b1"]}]
        q = replica([1, 2], requests={1: ["a1", "a2"], 2: ["b1"]},
                    rows={"a1": {"title": ""}, "a2": {"role": "{" + "x" * 130 + "}"}})
        rep, gate = self.go(users, q, wording="no-ask")
        by = {p["user"]["id"]: (a, p) for a, p in gate.calls}
        argv, p = by["1"]
        self.assertEqual(argv[-2:], ["--copy", "count"], "the count wording wins over --wording")
        self.assertEqual((sorted(c["request_id"] for c in p["credits"]), p["user"]["pending_count"]), (["a1", "a2"], 2))
        argv2, p2 = by["2"]
        self.assertNotIn("count", argv2)
        self.assertNotIn("pending_count", p2["user"])
        self.assertEqual((rep.count_copy, rep.incomplete, rep.sent_notes), (1, 0, 2))
        self.assertIn("1 told by the count-only note", uvn_status.render(rep, "apply", "paid"))

    def test_over_1000_requests_send_the_count_note_with_at_most_1000_ids(self):
        ids = [f"r{i:05d}" for i in range(1203)]
        users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ids}]
        rep, gate = self.go(users, replica([1], requests={1: ids}))
        argv, p = gate.calls[0]
        self.assertEqual(argv[-2:], ["--copy", "count"])
        self.assertEqual((len(p["credits"]), p["user"]["pending_count"]), (1000, 1203))

    def test_the_count_is_every_request_pending_at_send_time_not_the_stale_list(self):
        # QA + Fable on b2afc8be: the list (up to 30 h old) names a1 and a2, both unshowable; a3 was
        # opened after it was built, and a4 opens between the batch read and the send. The one-ever
        # note must say 4, with the listed requests first in the ids it records.
        users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["a1", "a2"]}]
        rows = {"a1": {"title": ""}, "a2": {"title": ""}}
        calls = {"n": 0}
        early, late = replica([1], requests={1: ["a3", "a1", "a2"]}, rows=rows), \
            replica([1], requests={1: ["a3", "a1", "a2", "a4"]}, rows=rows)

        def q(sql):
            if "proof_required_owed" in sql:              # the /k preflight read (owes nothing here), not a snapshot
                return [["0", "0"]]
            if "credit_requests" in sql:
                calls["n"] += 1
                return (early if calls["n"] == 1 else late)(sql)
            return early(sql)
        rep, gate = self.go(users, q)
        argv, p = gate.calls[0]
        self.assertEqual(argv[-2:], ["--copy", "count"])
        self.assertEqual(p["user"]["pending_count"], 4)
        self.assertEqual([c["request_id"] for c in p["credits"]][:2], ["a1", "a2"])
        self.assertEqual(sorted(c["request_id"] for c in p["credits"]), ["a1", "a2", "a3", "a4"])
        self.assertGreaterEqual(calls["n"], 2, "the replica is re-read right before the send")
        # A dry run counts from its own (single) read: 3 here, never the list's 2.
        calls["n"] = 0
        self.ledger = str(self.dir / "dry.sqlite3")
        self.list.write_text(json.dumps({"generated_at": (NOW - timedelta(hours=29)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                         "users": users}))
        gate = FakeGate()
        uvn_status.run(list_path=str(self.list), segment="paid", mode="dry-run", max_users=10, ledger_path=self.ledger,
                       query=q, runner=gate, wrapper=UNLOCKED_GATE, now=NOW, pace_seconds=0, campaign="status-team-review")
        self.assertEqual(gate.calls[0][1]["user"]["pending_count"], 3)

    def test_other_campaigns_keep_the_hold(self):
        users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["a1"]}]
        rep, gate = self.go(users, replica([1], requests={1: ["a1"]}, rows={"a1": {"title": ""}}),
                            campaign="status-doc-received")
        self.assertEqual((gate.calls, rep.incomplete, rep.count_copy), ([], 1, 0))


class CliTests(unittest.TestCase):
    def test_gap_ask_needs_from_stage2_and_a_list_run_needs_a_list(self):
        import os
        import subprocess
        env = {**os.environ, "CREDIT_OPS_NOTES_KILL_SWITCH": "/nonexistent/credit-ops-notes.disabled"}
        for extra, want in ((["--campaign", "gap-ask"], "add --from-stage2"), ([], "--list is required")):
            p = subprocess.run([sys.executable, str(ROOT / "scripts/credit-review.py"), "uvn-status", "--segment", "paid",
                                *extra], capture_output=True, text=True, env=env)
            self.assertEqual(p.returncode, 2)
            self.assertIn(want, p.stderr)


class GapLedgerTests(unittest.TestCase):
    def claim(self, db, campaign, rids, day, uid="42", email="a@x.com"):
        return verify_ledger.claim(db, campaign=campaign, user_key=email, day=day, request_ids=rids,
                                   message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                   now=NOW, user_id=uid)

    def sent(self, db, c, mid):
        # Sent on the day it was claimed for: the cap holds the day a message was DELIVERED on (`sent_at`), so a
        # note these tests date 20 days back must not be stamped as delivered today.
        day = db.execute("SELECT day FROM verify_messages WHERE id=?", (c["message_row"],)).fetchone()[0]
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=mid, conversation_id="c" + mid,
                               now=datetime.fromisoformat(day + "T12:00:00+00:00"))

    def test_an_earlier_ask_about_the_credit_does_not_block_the_gap_ask_but_its_own_note_does(self):
        db = verify_ledger.connect(":memory:")
        day = (NOW - timedelta(days=20)).strftime("%Y-%m-%d")
        self.sent(db, self.claim(db, "uvn-status", ["r1"], day), "1")
        c = self.claim(db, "gap-ask", ["r1"], NOW.strftime("%Y-%m-%d"))
        self.assertEqual(c["result"], "claimed")
        self.sent(db, c, "2")
        later = (NOW + timedelta(days=9)).strftime("%Y-%m-%d")
        self.assertEqual(self.claim(db, "gap-ask", ["r1"], later)["result"], "already_notified")
        # ... and the gap ask is an ask: no other ask campaign asks about that credit again
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1"], "retro-past"), {"r1"})

    def test_7_days_and_one_a_day_hold_except_after_a_doc_received_note(self):
        db = verify_ledger.connect(":memory:")
        today, yesterday = NOW.strftime("%Y-%m-%d"), (NOW - timedelta(days=1)).strftime("%Y-%m-%d")
        self.sent(db, self.claim(db, "status-doc-received", ["s1"], yesterday), "71")
        # the doc-received note promised this follow-up: not a 7-day deferral ...
        self.assertEqual(verify_ledger.gap_user_done(db, "a@x.com", now=NOW, user_id="42"), "")
        self.assertEqual(verify_ledger.followed_notes(db, "a@x.com", now=NOW, user_id="42"),
                         {"message_ids": ["71"], "conversation_ids": ["c71"]})
        # ... but never a second message the same day
        self.sent(db, self.claim(db, "status-doc-received", ["s2"], today, uid="43", email="b@x.com"), "72")
        self.assertEqual(self.claim(db, "gap-ask", ["g2"], today, uid="43", email="b@x.com")["result"], "daily_cap")
        # any other note in 7 days defers it (nothing closed)
        self.sent(db, self.claim(db, "status-team-review", ["t3"], yesterday, uid="44", email="c@x.com"), "73")
        r = self.claim(db, "gap-ask", ["g3"], today, uid="44", email="c@x.com")
        self.assertEqual((r["result"], r["reason"]), ("recent", "messaged_7d"))
        self.assertIsNone(db.execute("SELECT 1 FROM verify_requests WHERE request_id='g3'").fetchone())
        self.assertEqual(self.claim(db, "gap-ask", ["g1"], today)["result"], "claimed")

    def test_a_gap_ask_counts_toward_the_90_day_ask_lock_of_the_other_asks(self):
        db = verify_ledger.connect(":memory:")
        self.sent(db, self.claim(db, "gap-ask", ["g1"], (NOW - timedelta(days=10)).strftime("%Y-%m-%d")), "9")
        self.assertEqual(verify_ledger.uvn_user_done(db, "a@x.com", now=NOW, user_id="42"), "recently_asked")


if __name__ == "__main__":
    unittest.main()
