"""The wait-apology family (Fable d2, 2026-11-05 01:4xZ) on the RUNNER side: the one live fact sentence, the paid/free
variant, and the refusal. The gate's own rendering (the three approved sentences, the subject, the refusal of an
unknown fact) is pinned in intercom-verify-request.bats. No network, no Trino.
"""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production

import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import fraud_lens, uvn_status, verify_ledger  # noqa: E402

uvn_status.DEFAULT_LENS = lambda query, **kw: fraud_lens.null_lens

NOW = datetime.now(timezone.utc).replace(microsecond=0)


def iso(h: float) -> str:
    return (NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")


def proof(path, entries=()):
    """A fresh proof-on-file file: the documents-on-file fact the F1/F2 split depends on."""
    Path(path).write_text(json.dumps({
        "generated_at": iso(0.2), "users": len(entries), "entries": list(entries),
        "sources": [{"name": "core", "generated_at": iso(0.2)},
                    {"name": "cs-intercom", "generated_at": iso(0.5), "stale": False},
                    {"name": "cs-gmail", "generated_at": iso(0.5), "stale": False}],
        "gmail_contacts_90d": {"generated_at": iso(0.5), "source": "test", "user_ids": []}}))


class Gate:
    """The gate's seam: records each send's payload, answers POSTED."""

    def __init__(self):
        self.calls = []

    def __call__(self, argv):
        payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
        if "--thread-contact" in argv:
            return subprocess.CompletedProcess(argv, 0, "THREAD_CONTACT " + json.dumps(
                {"contacts": 1, "role": "user", "external_id": ""}), "")
        self.calls.append(payload)
        return subprocess.CompletedProcess(argv, 0, "POSTED email message=1 credits=1", "")


def replica(users, requests, states, docs=()):
    """answers public.users, the request read (status IN ...) and the apology state read by SQL shape"""
    docs = set(docs)

    def q(sql):
        if "proof_required_owed" in sql:
            return [["0", "0"]]
        key = "userid IN (" if "userid IN (" in sql else "id IN ("
        ids = {int(x) for x in sql[sql.index(key) + len(key):].split(")")[0].split(",") if x.strip().isdigit()}
        if "public.users" in sql:
            return [[str(u), f"u{u}@x.com", f"Name{u}", f"pro{u}", f"auth{u}"] for u in sorted(ids & set(users))]
        if "SELECT CAST(userid AS varchar), status" in sql:
            # QA #1788 r10: the state read also carries the request id, so the send-time check can ask whether a
            # document covers EACH live waiting request rather than whether the user appears anywhere in the export.
            # One row per LIVE REQUEST (not per status), so two waiting requests are two distinct ids.
            out = []
            for u in sorted(ids & set(states)):
                mine = [r for r, owner in sorted(requests.items()) if owner == u]
                sts = states[u]
                if mine and len(mine) == len(sts):
                    out.extend([str(u), st, r] for st, r in zip(sts, mine))
                else:
                    out.extend([str(u), st, None] for st in sts)
            return out
        wanted = {s.strip().strip("'") for s in sql[sql.index("status IN (") + 11:].split(")")[0].split(",")}
        want = {rid for rid, u in requests.items() if u in ids}
        return [[rid, str(u), "p1", "t1", f"Song {rid}", '[{"name":"Art"}]', "{Mixing}", "5", "{}", "{}", ""]
                for rid, u in sorted(requests.items()) if rid in want and requests_status(rid) in wanted]
    return q


STATUS = {}


def requests_status(rid):
    return STATUS.get(rid, "user_verification_needed")


class ApologyFactTests(unittest.TestCase):
    def test_the_three_facts_and_nothing_else(self):
        f = uvn_status.apology_fact
        # F1: something is with the user and no usable document is on file
        self.assertEqual(f({"waiting": 1, "decided": 0, "approved": 0}, False), ("F1", False))
        # F2: a document is on file, no decision yet
        self.assertEqual(f({"waiting": 1, "decided": 0, "approved": 0}, True), ("F2", False))
        # F3: every request decided; the copy drops its "could not verify" clause only when all were approved
        self.assertEqual(f({"waiting": 0, "decided": 2, "approved": 2}, True), ("F3", True))
        self.assertEqual(f({"waiting": 0, "decided": 2, "approved": 1}, True), ("F3", False))
        # a mixed state is NONE of the four: the user is refused, never defaulted to a sentence
        self.assertEqual(f({"waiting": 1, "decided": 1, "approved": 1}, False), ("", False))
        self.assertEqual(f({"waiting": 0, "decided": 0, "approved": 0}, False), ("", False))
        self.assertEqual(f(None, False), ("", False))

    def test_f3_requires_an_approved_row_and_an_all_rejected_user_gets_f4(self):
        """QA #1788 finding 2 (d2 copy v2): F3 states an approval that may not exist. An all-rejected user must never
        receive F3 - they get F4, the ONLY fact allowed when zero rows are approved. Refusing the state and leaving the
        user silent is the D gap the copy exists to close."""
        f = uvn_status.apology_fact
        self.assertEqual(f({"waiting": 0, "decided": 2, "approved": 0}, True), ("F4", False))
        self.assertEqual(f({"waiting": 0, "decided": 1, "approved": 0}, False), ("F4", False))
        # one approved row is enough for F3, and the unverified clause stays
        self.assertEqual(f({"waiting": 0, "decided": 3, "approved": 1}, True), ("F3", False))

    def test_an_unrecognised_status_is_unknown_and_refuses_the_user(self):
        """QA #1788 finding 5: an unrecognised live status used to be ignored, so a user with one approved row and one
        status we cannot read got F3 - a sentence claiming a decision about a request whose state we could not read."""
        f = uvn_status.apology_fact
        self.assertEqual(f({"waiting": 0, "decided": 1, "approved": 1, "unknown": 1}, True), ("", False))
        self.assertEqual(f({"waiting": 1, "decided": 0, "approved": 0, "unknown": 1}, False), ("", False))

        def q(sql):
            return [["7", "approved"], ["7", "some_new_status_we_do_not_know"]]

        self.assertEqual(uvn_status.apology_states([7], q),
                         {7: {"waiting": 0, "team": 0, "decided": 1, "approved": 1, "unknown": 1,
                              "undecided_ids": []}})

    def test_a_request_in_our_own_queue_is_never_waiting_on_the_user(self):
        """QA #1788 finding 2 (carried twice): `processing` is TEAM-owned. Grouping it with the user-owed states told a
        user whose request is already in our queue that it was "waiting on one thing from you" - false, and the one
        thing this copy must never do. With a document on file F2 is exactly true; with nothing on file neither F1 nor
        F2 is, so the user is refused rather than defaulted to a sentence."""
        f = uvn_status.apology_fact
        self.assertEqual(f({"waiting": 0, "team": 1, "decided": 0, "approved": 0}, True), ("F2", False))
        self.assertEqual(f({"waiting": 0, "team": 1, "decided": 0, "approved": 0}, False), ("", False))
        # a team-owned request mixed with a user-owed or a decided one has no single true sentence either
        self.assertEqual(f({"waiting": 1, "team": 1, "decided": 0, "approved": 0}, True), ("", False))
        self.assertEqual(f({"waiting": 0, "team": 1, "decided": 1, "approved": 1}, True), ("", False))

        def q(sql):
            return [["7", "processing"]]

        self.assertEqual(uvn_status.apology_states([7], q),
                         {7: {"waiting": 0, "team": 1, "decided": 0, "approved": 0, "unknown": 0,
                              "undecided_ids": []}})

    def test_the_state_read_counts_waiting_decided_and_approved_per_user(self):
        rows = {"credit_requests": [["7", "user_verification_needed"], ["7", "approved"], ["8", "rejected"],
                                    ["8", "processing"], ["9", "approved"], ["9", "approved"]]}

        def q(sql):
            return rows["credit_requests"]

        self.assertEqual(uvn_status.apology_states([7, 8, 9], q),
                         {7: {"waiting": 1, "team": 0, "decided": 1, "approved": 1, "unknown": 0,
                              "undecided_ids": []},
                          8: {"waiting": 0, "team": 1, "decided": 1, "approved": 0, "unknown": 0,
                              "undecided_ids": []},
                          9: {"waiting": 0, "team": 0, "decided": 2, "approved": 2, "unknown": 0,
                              "undecided_ids": []}})


class WaitApologyRunTests(unittest.TestCase):
    def setUp(self):
        global STATUS
        self.dir = Path(tempfile.mkdtemp(prefix="apol-"))
        self.list = self.dir / "list.json"
        self.proof = self.dir / "proof.json"
        self.ledger = str(self.dir / "ledger.sqlite3")
        # user 1: waiting, no document -> F1 (paid).  user 2: a document on file -> F2 (free).
        # user 3: everything decided, all approved -> F3 (paid).  user 4: no live request at all -> refused.
        status = {1: "user_verification_needed", 2: "user_verification_needed", 3: "approved", 4: "approved"}
        STATUS = {"r1": status[1], "r2": status[2], "r3": status[3], "r4": status[4]}
        rows = {1: ["user_verification_needed"], 2: ["user_verification_needed"], 3: ["approved"]}
        self.list.write_text(json.dumps({"generated_at": iso(3), "users": [
            {"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]},
            {"user_id": 2, "paid": False, "skip": None, "request_ids": ["r2"]},
            {"user_id": 3, "paid": True, "skip": None, "request_ids": ["r3"]},
            {"user_id": 4, "paid": True, "skip": None, "request_ids": ["r4"]},
        ]}))
        proof(self.proof, [{"user_id": 2, "request_id": None, "kind": "pending_doc", "source": "intercom",
                            "ref": "x"}])
        self.q = replica({1, 2, 3, 4}, {"r1": 1, "r2": 2, "r3": 3, "r4": 4}, rows, docs=(2,))

    def gate_file(self):
        p = self.dir / "gate.sh"
        p.write_text("readonly UVN_STATUS_COPY_APPROVED=1\n")
        return str(p)

    def run_(self, **kw):
        gate = kw.pop("gate", Gate())
        rep = uvn_status.run(list_path=str(self.list), segment=kw.pop("segment", "paid"), mode=kw.pop("mode", "apply"),
                             max_users=10, ledger_path=self.ledger, proof_path=str(self.proof), query=kw.pop("query", self.q),
                             runner=gate, wrapper=self.gate_file(), now=NOW, pace_seconds=0,
                             campaign=uvn_status.WAIT_APOLOGY, **kw)
        return rep, gate

    def test_each_user_gets_the_fact_their_live_state_supports(self):
        rep, gate = self.run_(segment="paid")
        facts = {p["user"]["id"]: p["apology"] for p in gate.calls}
        self.assertEqual(facts["1"], {"fact": "F1", "paid": True, "all_approved": False})
        self.assertEqual(facts["3"], {"fact": "F3", "paid": True, "all_approved": True})
        # the free variant is decided by the segment, never by the note
        self.assertNotIn("2", facts)                     # segment paid: user 2 is not walked
        free, g2 = self.run_(segment="free")
        self.assertEqual({p["user"]["id"]: p["apology"] for p in g2.calls},
                         {"2": {"fact": "F2", "paid": False, "all_approved": False}})

    def test_a_user_whose_state_is_none_of_the_three_is_refused_not_messaged(self):
        # user 4 is on the list but has NO live request: the copy cannot name a fact, so no message
        rep, gate = self.run_()
        self.assertEqual([p["user"]["id"] for p in gate.calls], ["1", "3"])
        self.assertEqual(rep.refused_no_fact, 1)
        self.assertEqual(rep.by_reason.get("apology_fact_missing"), 1)
        self.assertIn("refused: the live request state is not one of the three", uvn_status.render(rep, "apply", "paid"))

    def test_the_apply_re_derives_the_fact_from_a_fresh_send_time_read(self):
        """QA #1788 finding 6: the apply used to compute the fact from the page-level `states` snapshot taken before the
        walk, so a request that flipped waiting -> approved between the snapshot and the send still got F1 ("waiting on
        one thing from you") for a credit that had just been decided. The apply now re-reads this ONE user immediately
        before the gate call."""
        calls = {"n": 0}

        def flipping(sql):
            if "SELECT CAST(userid AS varchar), status" in sql:
                calls["n"] += 1
                # the page-level snapshot (first read) says waiting; every later per-user read says approved
                return [["1", "user_verification_needed" if calls["n"] == 1 else "approved"]]
            return self.q(sql)

        rep, gate = self.run_(query=flipping)
        self.assertGreaterEqual(calls["n"], 2, "the apply made its own send-time read")
        facts = {p["user"]["id"]: p["apology"] for p in gate.calls}
        self.assertEqual(facts["1"]["fact"], "F3",
                         "the sentence describes the state at SEND time, not the page snapshot")
        self.assertNotIn("F1", [f["fact"] for f in facts.values()])

    def test_a_document_for_one_of_two_waiting_requests_never_produces_f2_for_both(self):
        """QA #1788 r10 (Important): the send-time check only asked whether the user appears ANYWHERE in the proof
        export, although entries can be request-specific. A user with two waiting requests and a document for only one
        therefore got F2 - "we have what you sent ... nothing more is needed from you" - which is FALSE for the second
        request. Coverage is now per live waiting request id, and a MIX is refused rather than told something untrue."""
        self.list.write_text(json.dumps({"generated_at": iso(3), "users": [
            {"user_id": 6, "paid": True, "skip": None, "request_ids": ["r6a", "r6b"]},
            {"user_id": 7, "paid": True, "skip": None, "request_ids": ["r7a", "r7b"]},
            {"user_id": 8, "paid": True, "skip": None, "request_ids": ["r8a", "r8b"]}]}))
        global STATUS
        STATUS = {"r6a": "user_verification_needed", "r6b": "user_verification_needed",
                  "r7a": "user_verification_needed", "r7b": "user_verification_needed",
                  "r8a": "user_verification_needed", "r8b": "user_verification_needed"}
        # user 6: a document naming ONLY r6a -> mixed coverage -> refused (F2 would be false for r6b)
        # user 7: a whole-user document (request_id None) -> covers both -> F2
        # user 8: a document naming only r8a, and r8b is decided -> not a waiting mix, still refused by the state rule
        proof(self.proof, [{"user_id": 6, "request_id": "r6a", "kind": "pending_doc", "source": "intercom",
                            "ref": "x"},
                           {"user_id": 7, "request_id": None, "kind": "pending_doc", "source": "intercom",
                            "ref": "y"}])
        self.q = replica({6, 7, 8}, {"r6a": 6, "r6b": 6, "r7a": 7, "r7b": 7, "r8a": 8, "r8b": 8},
                         {6: ["user_verification_needed", "user_verification_needed"],
                          7: ["user_verification_needed", "user_verification_needed"],
                          8: ["user_verification_needed", "user_verification_needed"]}, docs=(6, 7))
        rep, gate = self.run_()
        facts = {p["user"]["id"]: p["apology"]["fact"] for p in gate.calls}
        self.assertNotIn("6", facts, "a document for one of two waiting requests must never produce F2 for both")
        self.assertEqual(facts.get("7"), "F2", "a whole-user document covers every request")
        self.assertEqual(rep.refused_no_fact, 1)

    def test_doc_coverage_is_per_request_and_a_whole_user_entry_covers_everything(self):
        cov = uvn_status.doc_coverage
        self.assertEqual(cov([("r1", "pending_doc")], ["r1", "r2"]), (1, 1))
        self.assertEqual(cov([(None, "pending_doc")], ["r1", "r2"]), (2, 0))
        self.assertEqual(cov([("r1", "pending_doc"), ("r2", "pending_doc")], ["r1", "r2"]), (2, 0))
        self.assertEqual(cov([], ["r1"]), (0, 1))
        self.assertEqual(cov(None, []), (0, 0))
        # and the fact refuses the mix, keeps F1 when nothing is covered, F2 only when everything is
        f = uvn_status.apology_fact
        st = {"waiting": 2, "team": 0, "decided": 0, "approved": 0, "unknown": 0}
        self.assertEqual(f(st, True, (1, 1)), ("", False))
        self.assertEqual(f(st, False, (0, 2)), ("F1", False))
        self.assertEqual(f(st, True, (2, 0)), ("F2", False))

    def test_an_all_rejected_user_gets_f4_never_f3(self):
        """QA #1788 finding 2 (d2 copy v2): F3 states an approval that may not exist."""
        self.list.write_text(json.dumps({"generated_at": iso(3), "users": [
            {"user_id": 5, "paid": True, "skip": None, "request_ids": ["r5"]}]}))
        rows = {5: ["rejected"]}
        q = replica({5}, {"r5": 5}, rows)
        rep, gate = self.run_(query=q)
        self.assertEqual([p["apology"] for p in gate.calls],
                         [{"fact": "F4", "paid": True, "all_approved": False}])

    def test_the_apply_re_reads_the_document_half_of_the_fact_at_send_time(self):
        """QA #1788 finding 1 (carried three times): only the STATE half was re-read at send time; `documented` was the
        page-level snapshot taken before the walk. A document that arrives while earlier users are being messaged still
        produced F1 ("waiting on one thing from you") for a user whose document is now on file. Both halves of the
        sentence must describe the same instant."""
        calls = {"n": 0}

        def doc_arrives(sql):
            if "SELECT CAST(userid AS varchar), status" in sql:
                calls["n"] += 1
                if calls["n"] > 1:      # the send-time read: the document lands at the same moment
                    proof(self.proof, [{"user_id": 1, "request_id": None, "kind": "pending_doc",
                                        "source": "intercom", "ref": "x"}])
            return self.q(sql)

        rep, gate = self.run_(query=doc_arrives)
        facts = {p["user"]["id"]: p["apology"] for p in gate.calls}
        self.assertEqual(facts["1"]["fact"], "F2",
                         "the document is on file NOW: F1 would tell the user to send what we already have")

    def test_an_unreadable_state_read_halts_the_family_rather_than_sending_a_factless_note(self):
        def boom(sql):
            if "SELECT CAST(userid AS varchar), status" in sql:
                raise RuntimeError("trino: gateway timeout")
            return self.q(sql)

        rep, gate = self.run_(query=boom)
        self.assertEqual(gate.calls, [])
        self.assertIn("apology_state_unreadable", rep.halted)
        self.assertIn("trino: gateway timeout", rep.halted)


if __name__ == "__main__":
    unittest.main()
