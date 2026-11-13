"""The paid-band ask lane (captain r4 GO 3, firstmate 413): the cap, the cohort predicate, and the re-signed list.

Pins the three things that keep this lane bounded - an unreadable policy is a REFUSAL not an uncapped wave, the
scope lists only never-told PAID users with band rows in paid-then-oldest order, and the filtered list still
passes owing_proof.verify_facts (a list that would be refused at signing is worthless).

And the count itself (2026-11-13: the builder said 213, the send gate would message 15): `candidates` is measured
with the gate's own rules, so a user with documents on file or with nothing to ask about is not a candidate, and
the builder's count equals the gate's dry-run count for the rules the gate decides FROM THE LIST on one list (its
per-send holds stay in the gate, so the builder's number is an upper bound)."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import contextlib
import io
import json
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
from credit_review import owing_proof, paid_band_ask, uvn_status, verify_ledger, verify_notify  # noqa: E402
# the gate's own test doubles (module imports, never `from ... import <TestCase>`: unittest.main() runs what is
# in this namespace). Importing them also installs the null fraud lens the gate tests run under.
import test_stage2_asks as stage2_fixtures  # noqa: E402
import test_uvn_status as gate_fixtures  # noqa: E402


def build_doc(users):
    return {"generated_at": "2026-11-11T11:00:00+00:00", "users": users,
            "counts": {}, "replica_facts": owing_proof.facts_header(users)}


def user(uid, rid, *, paid=True, oldest="2026-10-01T00:00:00Z", status="user_verification_needed", cls="uvn"):
    return {"user_id": str(uid), "paid": paid, "skip": None, "at_risk": False, "request_ids": [rid],
            "class": cls, "oldest": oldest, "facts": [[rid, status, False]]}


def replica(entries):
    """The 8-column replica shape owing_proof reads: uid, rid, status, createdat, paid, review_fired,
    proofRequest marker, proof_required."""
    return [[str(uid), rid, status, oldest, "1" if paid else "0", "0", "0", "0"]
            for uid, rid, oldest, paid, status in entries]


def owing_replica(entries):
    """A replica for `owing_proof.verify_facts`: the status guard it runs first, then the 8-column rows."""
    def q(sql):
        if sql == owing_proof.STATUS_GUARD_SQL:
            return [[s] for s in owing_proof.CLOSED_STATUSES + owing_proof.OPEN_STATUSES]
        return replica(entries)
    return q


class AskCapTest(unittest.TestCase):
    def test_policy_cap_is_read(self):
        p = Path(tempfile.mkdtemp()) / "p.json"
        p.write_text(json.dumps({"max_ask_users_per_day": 400}))
        self.assertEqual(paid_band_ask.ask_cap(str(p)), 400)

    def test_unreadable_or_missing_cap_is_a_refusal(self):
        d = Path(tempfile.mkdtemp())
        for body in ({}, {"max_ask_users_per_day": 0}, {"max_ask_users_per_day": "400"},
                     {"max_ask_users_per_day": True}):
            p = d / "p.json"
            p.write_text(json.dumps(body))
            with self.assertRaises(paid_band_ask.BandAskError):
                paid_band_ask.ask_cap(str(p))
        with self.assertRaises(paid_band_ask.BandAskError):
            paid_band_ask.ask_cap(str(d / "nope.json"))


class CohortTest(unittest.TestCase):
    def test_band_rows_are_parsed_per_user(self):
        q = lambda sql: [["7|a"], ["7|b"], ["9|c"]]  # noqa: E731
        self.assertEqual(paid_band_ask.band_users(q), {7: {"a", "b"}, 9: {"c"}})

    def test_a_malformed_row_is_a_refusal(self):
        for rows in ([["7"]], [["x|a"]], [["7|"]], [["7|a", "extra"]]):
            with self.assertRaises(paid_band_ask.BandAskError):
                paid_band_ask.band_users(lambda sql, r=rows: r)

    def test_scope_keeps_only_never_told_paid_band_users_oldest_first(self):
        doc = build_doc([user(1, "a", oldest="2026-10-05T00:00:00Z"),
                         user(2, "b", paid=False, oldest="2026-09-01T00:00:00Z"),
                         user(3, "c", oldest="2026-09-02T00:00:00Z"),
                         user(4, "d", oldest="2026-08-01T00:00:00Z")])
        out = paid_band_ask.scope(doc, {1: {"a"}, 2: {"b"}, 3: {"c"}}, cap=400)   # 4 has no band row
        self.assertEqual([u["user_id"] for u in out["users"]], ["3", "1"])       # oldest paid first, free dropped
        self.assertEqual(out["ask_lane"]["candidates"], 2)
        self.assertEqual(out["ask_lane"]["listed"], 2)

    def test_an_already_asked_follow_up_user_spends_no_slot(self):
        # QA 1886: owing_proof also lists uvn_new_rows (already asked, new rows unnamed). uvn-status drops those as
        # already_sent before spending budget, so counting them would make the two-day drain a fiction.
        doc = build_doc([user(1, "a", oldest="2026-09-01T00:00:00Z", cls="uvn_new_rows"),
                         user(2, "b", oldest="2026-10-02T00:00:00Z")])
        out = paid_band_ask.scope(doc, {1: {"a"}, 2: {"b"}}, cap=400)
        self.assertEqual([u["user_id"] for u in out["users"]], ["2"])
        self.assertEqual(out["ask_lane"]["candidates"], 1)

    def test_users_inside_the_senders_90_day_lock_are_dropped_and_counted(self):
        doc = build_doc([user(1, "a"), user(2, "b"), user(3, "c")])
        out = paid_band_ask.scope(doc, {1: {"a"}, 2: {"b"}, 3: {"c"}}, cap=400,
                                  asked_recently=lambda uid: uid in {"1", "3"})
        self.assertEqual([u["user_id"] for u in out["users"]], ["2"])
        self.assertEqual(out["ask_lane"]["recently_asked_inside_90d"], 2)
        self.assertEqual(out["ask_lane"]["candidates"], 1)

    def test_the_build_read_is_narrowed_to_the_band_users_only(self):
        seen = []

        def q(sql):
            seen.append(sql)
            return []

        with mock.patch.object(paid_band_ask.verify_notify, "trino", q):
            paid_band_ask.narrowed_query({9, 7})("SELECT 1")
            paid_band_ask.narrowed_query({9, 7})(owing_proof.REPLICA_SQL)
            paid_band_ask.narrowed_query(set())(owing_proof.REPLICA_SQL)
        self.assertEqual(len(seen), 2)                                  # an empty cohort reads nothing at all
        self.assertTrue(seen[1].startswith(owing_proof.REPLICA_SQL))
        self.assertTrue(seen[1].endswith("AND cr.userid IN (7,9)"))     # sorted, ints only

    def test_a_big_cohort_is_read_in_batches(self):
        # 1,015 ids in one IN list blew the cluster's statement timeout (486s, killed); batches of 100 answer in ~5s
        seen = []

        def q(sql):
            seen.append(sql)
            return [["1", "a", "user_verification_needed", "2026-10-01", "1", "0", "0", "0"]]

        with mock.patch.object(paid_band_ask.verify_notify, "trino", q):
            rows = paid_band_ask.narrowed_query(range(1, 251))(owing_proof.REPLICA_SQL)
        self.assertEqual(len(seen), 3)                       # 250 users -> 3 reads, not one
        self.assertEqual(len(rows), 3)
        self.assertIn("IN (" + ",".join(str(i) for i in range(1, 101)) + ")", seen[0])

    def test_cap_defers_the_rest_to_a_later_day(self):
        users = [user(i, f"r{i}", oldest=f"2026-10-{i:02d}T00:00:00Z") for i in range(1, 11)]
        out = paid_band_ask.scope(build_doc(users), {i: {f"r{i}"} for i in range(1, 11)}, cap=4)
        self.assertEqual(len(out["users"]), 4)
        self.assertEqual(out["ask_lane"]["candidates"], 10)
        self.assertEqual(out["ask_lane"]["deferred_to_later_day"], 6)
        self.assertEqual([u["user_id"] for u in out["users"]], ["1", "2", "3", "4"])

    def setUp(self):
        d = Path(tempfile.mkdtemp())
        self.ledger = str(d / "ledger.sqlite3")
        verify_ledger.connect(self.ledger).close()
        self.holds = d / "account_holds.jsonl"
        self.holds.write_text("")

    def facts(self, doc, q):
        return owing_proof.verify_facts(doc, q, holds_path=str(self.holds), ledger_path=self.ledger)

    def test_the_filtered_list_still_passes_verify_facts(self):
        users = [user(1, "a", oldest="2026-10-05T00:00:00Z"), user(2, "b", oldest="2026-10-06T00:00:00Z")]
        doc = paid_band_ask.scope(build_doc(users), {1: {"a"}, 2: {"b"}}, cap=400)
        q = owing_replica([(1, "a", "2026-10-05T00:00:00Z", True, "user_verification_needed"),
                           (2, "b", "2026-10-06T00:00:00Z", True, "user_verification_needed")])
        self.assertEqual(self.facts(doc, q), [])

    def test_a_list_edited_after_the_build_is_refused(self):
        users = [user(1, "a")]
        doc = paid_band_ask.scope(build_doc(users), {1: {"a"}}, cap=400)
        doc["users"][0]["request_ids"] = ["a", "injected"]
        q = owing_replica([(1, "a", "2026-10-01T00:00:00Z", True, "user_verification_needed")])
        self.assertTrue(any(d.startswith("1:") for d in self.facts(doc, q)))


class OwesProofTest(unittest.TestCase):
    """`candidates` is the people the send gate would still ask, measured with the gate's own functions."""

    OLDEST = "2026-10-01T00:00:00Z"
    #: 1 and 5 have no document; 2 has one nobody judged; 3 has one a stage-2 verdict released; 4's only row is on
    #: the approval path (nothing to ask about)
    USERS = (1, 2, 3, 4, 5)
    #: what the Intercom gate script answers a dry run for a user it would message
    VALID = "VALID uvn-status initial email credits=1 copy=default"

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="band-owes-"))
        self.ledger = str(self.dir / "ledger.sqlite3")
        verify_ledger.connect(self.ledger).close()
        self.holds = self.dir / "account_holds.jsonl"
        self.holds.write_text("")
        self.proof = self.dir / "proof.json"
        self.store = stage2_fixtures.Store(self.dir / "proof.sqlite")
        self.store.add("r3", 3, "no_document")
        self.documents(2, 3)
        admit = gate_fixtures.UvnStatusTests.ADMIT
        gate = gate_fixtures.replica(self.USERS, verification={"r4": admit})
        owing = owing_replica([(u, f"r{u}", self.OLDEST, True, "user_verification_needed") for u in self.USERS])

        def q(sql):
            if sql == owing_proof.STATUS_GUARD_SQL or sql.startswith(owing_proof.REPLICA_SQL):
                return owing(sql)
            return gate(sql)
        self.q = q
        self.band = {u: {f"r{u}"} for u in self.USERS}

    def documents(self, *uids):
        gate_fixtures.proof(self.proof, [stage2_fixtures.entry(u, "pending_doc") for u in uids])

    def build(self):
        return build_doc([user(u, f"r{u}", oldest=self.OLDEST) for u in self.USERS])

    def owes(self):
        return paid_band_ask.still_owing(self.ledger, str(self.proof), self.store.path)

    def scoped(self, **kw):
        with mock.patch.object(paid_band_ask.verify_notify, "trino", self.q):
            return paid_band_ask.scope(self.build(), self.band, cap=400, **kw)

    def ids(self, doc):
        return [u["user_id"] for u in doc["users"]]

    def test_a_user_with_documents_on_file_was_a_candidate_and_no_longer_is(self):
        before = self.scoped()                                  # the old count: no gate rule applied
        self.assertIn("2", self.ids(before))
        self.assertEqual(before["ask_lane"]["candidates"], 5)
        after = self.scoped(owes=self.owes())
        self.assertNotIn("2", self.ids(after))
        self.assertEqual(after["ask_lane"]["not_owed"]["documents_on_file"], 1)

    def test_a_user_with_no_documents_on_file_is_still_a_candidate(self):
        after = self.scoped(owes=self.owes())
        self.assertIn("1", self.ids(after))
        self.assertIn("5", self.ids(after))

    def test_a_document_a_stage2_verdict_released_does_not_drop_the_user(self):
        self.assertIn("3", self.ids(self.scoped(owes=self.owes())))

    def test_a_user_whose_rows_are_all_on_the_approval_path_is_not_a_candidate(self):
        after = self.scoped(owes=self.owes())
        self.assertNotIn("4", self.ids(after))
        self.assertEqual(after["ask_lane"]["not_owed"], {"documents_on_file": 1, "nothing_to_ask": 1})
        self.assertEqual((after["ask_lane"]["candidates"], after["ask_lane"]["listed"]), (3, 3))

    def test_the_gate_rules_run_before_the_cap_so_no_slot_goes_to_a_user_the_gate_drops(self):
        with mock.patch.object(paid_band_ask.verify_notify, "trino", self.q):
            out = paid_band_ask.scope(self.build(), self.band, cap=2, owes=self.owes())
        self.assertEqual(self.ids(out), ["1", "3"])
        self.assertEqual((out["ask_lane"]["candidates"], out["ask_lane"]["deferred_to_later_day"]), (3, 1))

    def gate_dry_run(self, doc):
        """The real send gate's dry run over the list the builder wrote. Only the Intercom gate script is faked,
        and it validates everyone: what it holds per send is not the list's business."""
        path = self.dir / "list.json"
        doc = dict(doc, generated_at=gate_fixtures.iso(1))      # the gate refuses a list older than its age bar
        path.write_text(json.dumps(doc))
        wrapper = self.dir / "gate.sh"
        wrapper.write_text("readonly UVN_STATUS_COPY_APPROVED=1\nreadonly CREDIT_HOLD_STATUS_COPY_APPROVED=0\n")
        return uvn_status.run(list_path=str(path), segment="paid", mode="dry-run", max_users=50,
                              ledger_path=self.ledger, proof_path=str(self.proof), stage2_path=self.store.path,
                              holds_path=str(self.holds), query=self.q, runner=gate_fixtures.FakeGate(out=self.VALID),
                              wrapper=str(wrapper), now=gate_fixtures.NOW, pace_seconds=0)

    def test_the_builders_count_is_the_gates_would_be_messaged_count(self):
        # THE regression: one list holding both kinds of user. Before, the builder said 5 and the gate 3.
        old = self.scoped()
        rep = self.gate_dry_run(old)
        self.assertEqual(rep.halted, "")
        self.assertEqual((old["ask_lane"]["candidates"], rep.listed, rep.users), (5, 5, 3))
        self.assertEqual((rep.proof_on_file, rep.by_reason.get("nothing_to_ask")), (1, 1))
        new = self.scoped(owes=self.owes())
        rep = self.gate_dry_run(new)
        self.assertEqual(rep.halted, "")
        self.assertEqual(rep.users, new["ask_lane"]["candidates"])
        self.assertEqual((rep.listed, rep.users, rep.proof_on_file), (3, 3, 0))
        self.assertNotIn("nothing_to_ask", rep.by_reason)
        self.assertIn("3 on the list, 3 would be messaged", uvn_status.render(rep, "dry-run", "paid"))
        # and what the builder dropped is exactly what the gate dropped from the old list
        self.assertEqual(new["ask_lane"]["not_owed"], {"documents_on_file": 1, "nothing_to_ask": 1})

    def test_an_unreadable_documents_snapshot_is_a_refusal_never_nobody_has_documents(self):
        self.proof.write_text("{}")
        with self.assertRaises(verify_notify.ProofFileError):
            self.scoped(owes=self.owes())

    def test_an_unreadable_verdict_store_releases_nobody_and_says_so(self):
        self.store.path = str(self.dir / "missing.sqlite")
        after = self.scoped(owes=self.owes())
        self.assertNotIn("3", self.ids(after))                  # the gate's rule: unreadable store, nobody released
        self.assertEqual(after["ask_lane"]["not_owed"],
                         {"documents_on_file": 2, "nothing_to_ask": 1, "stage2_unreadable": 0})

    def cli(self, *extra):
        policy = self.dir / "policy.json"
        policy.write_text(json.dumps({"max_ask_users_per_day": 400}))
        built = self.dir / "built.json"
        built.write_text(json.dumps(self.build()))

        def trino(sql):
            return [[f"{u}|r{u}"] for u in self.USERS] if sql == paid_band_ask.BAND_SQL else self.q(sql)
        out = io.StringIO()
        with mock.patch.object(paid_band_ask.verify_notify, "trino", trino), contextlib.redirect_stdout(out):
            rc = paid_band_ask.main(["--filter-built", str(built), "--policy", str(policy), "--ledger", self.ledger,
                                     "--proof-on-file", str(self.proof), "--proof-store", self.store.path, *extra])
        return rc, json.loads(out.getvalue())

    def test_dry_run_keeps_its_keys_and_adds_not_owed(self):
        rc, summary = self.cli("--dry-run")
        self.assertEqual(rc, 0)
        self.assertEqual(summary, {"candidates": 3, "listed": 3, "deferred_to_later_day": 0, "max_users_per_day": 400,
                                   "recently_asked_inside_90d": 0, "users_with_band_rows": 5, "dry_run": True,
                                   "not_owed": {"documents_on_file": 1, "nothing_to_ask": 1}})

    def test_a_refused_documents_read_lists_nobody(self):
        self.proof.write_text("{}")
        out = self.dir / "out.json"
        rc, summary = self.cli("--out", str(out))
        self.assertEqual(rc, 2)
        self.assertIn("error", summary)
        self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
