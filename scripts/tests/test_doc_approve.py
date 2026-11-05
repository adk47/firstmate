"""Doc-approve doctrine [key=doc-approval-doctrine]: one CAN-FAIL test per gate.

Fable 2026-11-03 19:3xZ (under Aaron's 11-03 delegation): a dv-4 verified document may approve a
T0/T1 credit WITHOUT a same-run DSP anchor, under CODED gates only. Each gate is testable alone
here - a gate with no failing test is a gate nobody would notice losing.
"""
from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
import warnings
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import decide, doc_approve  # noqa: E402


class DocApproveGates(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.docs = self.dir / "doc-verify.sqlite"
        self.proof = self.dir / "proof.sqlite"
        self.ledger = self.dir / "decider.sqlite"
        d = sqlite3.connect(self.docs)
        d.executescript("""
            CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at TEXT NOT NULL,
              proof_id TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER,
              source_ref TEXT, h3_verdict TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, need TEXT,
              account_hold INTEGER NOT NULL DEFAULT 0, detail_json TEXT NOT NULL, version TEXT NOT NULL,
              intake_id TEXT);
        """)
        d.commit()
        d.close()
        p = sqlite3.connect(self.proof)
        p.executescript("""
            CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, subject TEXT NOT NULL,
              candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', conversation_id TEXT NOT NULL,
              source TEXT NOT NULL, file_sha256 TEXT NOT NULL, file_path TEXT, mime TEXT, bytes INTEGER,
              received_at TEXT NOT NULL, filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT,
              UNIQUE (user_id, file_sha256));
        """)
        p.commit()
        p.close()
        self.db = sqlite3.connect(self.ledger)
        decide.ensure_schema(self.db)
        doc_approve.ensure_schema(self.db)
        self.now = datetime(2026, 11, 3, 20, 0, 0, tzinfo=timezone.utc)
        self.request_id = "4bec612c-565d-4abf-abc3-db5cc4feb25a"
        self._runs: list[str] = []

    def tearDown(self) -> None:
        self.db.close()
        self.tmp.cleanup()

    # ── fixtures ────────────────────────────────────────────────────────────
    def file_doc(self, *, intake_id="145833:a4205f34", user_id=145833, request_id=None, sha="a4205f34",
                 roles=("Lyricist", "Composer"), outcome="verified", version="dv-4", at=None,
                 account_hold=0, candidates=None, filed_at="2026-10-24T06:49:57Z", run_id=None) -> None:
        rid = request_id or self.request_id
        at = at or "2026-10-31T12:26:32Z"
        # a NEW run per call: run_id is the run boundary (QA #1684 round 3, finding 2), and two calls to
        # this fixture are two runs - the earlier ones all wrote 'r1', so a "later run" merged into the first
        run_id = run_id or f"r{len(self._runs) + 1}"
        self._runs.append(run_id)
        d = sqlite3.connect(self.docs)
        for role in roles:
            d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict, outcome,"
                      " reason, account_hold, detail_json, version, intake_id) VALUES (?,?,'sha',?,?,?,"
                      " 'PLAUSIBLE',?,'because',?,'{}',?,?)",
                      (run_id, at, rid, role, user_id, outcome, account_hold, version,
                       intake_id if intake_id else None))
        d.commit()
        d.close()
        p = sqlite3.connect(self.proof)
        p.execute("INSERT OR REPLACE INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                  " conversation_id, source, file_sha256, received_at, filed_by) VALUES (?,?,'credit',?,'777',"
                  "'intercom',?,?,'proof_intake')",
                  (intake_id or "x", user_id, json.dumps(candidates if candidates is not None else [rid]), sha, filed_at))
        p.commit()
        p.close()

    def cand(self, popularity=12, user_id=145833, docs=None) -> doc_approve.Candidate:
        if docs is None:
            docs = tuple(doc_approve.verified_docs(self.docs, self.proof).get(self.request_id, ()))
        return doc_approve.Candidate(self.request_id, user_id, popularity, docs)

    def allowed(self, *_a, **_kw):
        from credit_review.account_gate import ALLOW, GateResult
        return GateResult(ALLOW, ())

    def denied(self, *_a, **_kw):
        from credit_review.account_gate import HOLD, GateResult
        return GateResult(HOLD, ("velocity",))

    # ── gate 1: attributed to EXACTLY ONE request ────────────────────────────
    def test_gate_one_request_passes_on_several_documents_that_each_name_this_request(self):
        self.file_doc()
        self.file_doc(intake_id="145833:second", sha="bbbb", at="2026-11-01T00:00:00Z")
        c = self.cand()
        self.assertEqual(len(c.docs), 2)
        self.assertTrue(doc_approve.gate_one_request(c).ok)
        self.assertEqual(doc_approve.pick(c).intake_id, "145833:second")   # the newest one

    def test_gate_one_request_PASSES_when_one_document_binds_two_requests_of_the_SAME_user(self):
        """2026-11-04 ruling: the one-request binding is PER REQUEST; a document may bind several
        requests of the same person, each binding exact, and they are approved together."""
        other = "11111111-2222-3333-4444-555555555555"
        self.file_doc(candidates=[self.request_id, other])
        users = {self.request_id: 145833, other: 145833}
        g = doc_approve.gate_one_request(self.cand(), users)
        self.assertTrue(g.ok, g.why)

    def test_gate_one_request_fails_when_a_document_binds_TWO_ACCOUNTS(self):
        """A filing that credits two people cannot say which of them the evidence is about - the
        shape a duplicated screenshot takes."""
        other = "11111111-2222-3333-4444-555555555555"
        self.file_doc(candidates=[self.request_id, other])
        g = doc_approve.gate_one_request(self.cand(), {self.request_id: 145833, other: 999})
        self.assertFalse(g.ok)
        self.assertEqual(g.name, "one_request")
        self.assertIn("binds 2 accounts", g.why)

    def test_gate_one_request_fails_when_the_document_belongs_to_ANOTHER_account(self):
        """QA #1684 round 6, finding 1: the bindings all named the request owner, so the cross-account check
        passed - but the DOCUMENT was filed and verified for a different account. Another person's document
        proves nothing about this request, however exactly it names it."""
        self.file_doc(user_id=555)                          # the document belongs to account 555
        c = self.cand(user_id=145833)                       # the request belongs to 145833
        self.assertEqual(c.docs[0].user_id, 555)
        g = doc_approve.gate_one_request(c, {self.request_id: 145833})
        self.assertFalse(g.ok)
        self.assertIn("belongs to account 555", g.why)
        self.assertIn("request is account 145833", g.why)

    def test_gate_one_request_fails_when_a_bound_requests_owner_is_UNKNOWN(self):
        """Fail closed: an unreadable request owner cannot exclude a cross-account binding."""
        other = "11111111-2222-3333-4444-555555555555"
        self.file_doc(candidates=[self.request_id, other])
        g = doc_approve.gate_one_request(self.cand(), {self.request_id: 145833})
        self.assertFalse(g.ok)
        self.assertIn("owner is unknown", g.why)

    def test_gate_one_request_fails_when_the_filing_names_no_request(self):
        self.file_doc(candidates=[])
        g = doc_approve.gate_one_request(self.cand())
        self.assertFalse(g.ok)
        self.assertIn("does not bind this request", g.why)

    def test_gate_one_request_fails_when_the_filing_names_another_request(self):
        self.file_doc(candidates=["11111111-2222-3333-4444-555555555555"])
        g = doc_approve.gate_one_request(self.cand())
        self.assertFalse(g.ok)
        self.assertIn("does not bind this request", g.why)

    def test_gate_one_request_passes_on_one_attributed_request(self):
        self.file_doc()
        self.assertTrue(doc_approve.gate_one_request(self.cand()).ok)

    # ── gate 2: the STANDING dv-4 verdict is verified ────────────────────────
    def test_gate_dv4_verified_fails_when_a_newer_run_is_unverifiable(self):
        self.file_doc()
        doc = self.cand().docs[0]
        self.file_doc(outcome="unverifiable", at="2026-11-02T00:00:00Z")   # a later run says no
        g = doc_approve.gate_dv4_verified(doc_approve.Candidate(self.request_id, 145833, 12, (doc,)),
                                          self.docs)
        self.assertFalse(g.ok)
        self.assertIn("unverifiable", g.why)

    def test_gate_dv4_verified_fails_when_a_newer_run_is_forged(self):
        self.file_doc()
        doc = self.cand().docs[0]
        self.file_doc(outcome="forged", at="2026-11-02T00:00:00Z")
        g = doc_approve.gate_dv4_verified(doc_approve.Candidate(self.request_id, 145833, 12, (doc,)), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("forged", g.why)

    def test_gate_dv4_verified_ignores_a_dv3_verified_verdict(self):
        self.file_doc(version="dv-3")
        self.assertEqual(doc_approve.verified_docs(self.docs, self.proof), {})

    def test_gate_dv4_verified_passes_on_one_verified_role_set(self):
        self.file_doc()
        self.assertTrue(doc_approve.gate_dv4_verified(self.cand(), self.docs).ok)

    def test_gate_dv4_verified_rechecks_the_document_the_approval_RECORDS(self):
        """QA #1684 round 4, finding 3: the gate asked about `c.docs[0]` while `approve()` records
        `pick(c)` - the NEWEST document. A newer document forged after planning must refuse the
        approval, not be recorded as its proof."""
        self.file_doc()
        self.file_doc(intake_id="145833:second", sha="bbbb", at="2026-11-01T00:00:00Z")
        c = self.cand()
        self.assertEqual(len(c.docs), 2)
        self.assertEqual(doc_approve.pick(c).intake_id, "145833:second")
        # the newer document is contradicted AFTER the plan was built
        self.file_doc(intake_id="145833:second", sha="bbbb", at="2026-11-02T00:00:00Z",
                      outcome="contradicted")
        g = doc_approve.gate_dv4_verified(c, self.docs)
        self.assertFalse(g.ok, "the RECORDED document is the forged one")
        self.assertIn("145833:second", g.why)
        self.assertIn("contradicted", g.why)

    # ── gate 3: T0/T1 only ──────────────────────────────────────────────────
    def test_gate_tier_fails_on_unknown_popularity(self):
        self.file_doc()
        g = doc_approve.gate_tier(self.cand(popularity=None))
        self.assertFalse(g.ok)
        self.assertIn("popularity unknown", g.why)

    def test_gate_tier_fails_at_60(self):
        self.file_doc()
        g = doc_approve.gate_tier(self.cand(popularity=60))
        self.assertFalse(g.ok)
        self.assertIn("T2/T3", g.why)

    def test_gate_tier_reads_popularity_ZERO_as_a_KNOWN_small_track(self):
        """The tier gate must NEVER turn `0` into "unknown". `0` is falsy in Python, so a `pop or default`
        (or a `if not pop` guard) would silently read a zero-popularity track as absent - and the ruling's
        1c class is built on "0 < 60 reads as T0". This pins the two cases apart so they cannot collapse
        into each other again: 0 is KNOWN and small, None is UNKNOWN and refused."""
        zero = self.cand(popularity=0)
        self.assertTrue(doc_approve.gate_tier(zero).ok, doc_approve.gate_tier(zero).why)
        self.assertEqual(doc_approve.tier_of(0), "T0", "0 is T0 - known and small, never unknown")
        unknown = doc_approve.gate_tier(self.cand(popularity=None))
        self.assertFalse(unknown.ok)
        self.assertIn("unknown", unknown.why)
        self.assertFalse(doc_approve.gate_tier(self.cand(popularity=False)).ok,
                         "a bool is not a popularity")

    def test_gate_tier_passes_below_60(self):
        self.file_doc()
        self.assertTrue(doc_approve.gate_tier(self.cand(popularity=59)).ok)

    # ── gate 4: the account gate ────────────────────────────────────────────
    def test_gate_account_fails_on_hold(self):
        self.file_doc()
        g = doc_approve.gate_account(self.cand(), self.denied)
        self.assertFalse(g.ok)
        self.assertIn("not an allow", g.why)

    def test_gate_account_fails_with_no_account_id(self):
        self.file_doc()
        g = doc_approve.gate_account(doc_approve.Candidate(self.request_id, None, 12, ()), self.allowed)
        self.assertFalse(g.ok)
        self.assertIn("no account id", g.why)

    def test_gate_account_passes_on_allow(self):
        self.file_doc()
        self.assertTrue(doc_approve.gate_account(self.cand(), self.allowed).ok)

    # ── gate 5: no fraud/velocity HOLD row ──────────────────────────────────
    def test_gate_no_hold_fails_on_the_documents_own_account_hold(self):
        self.file_doc(account_hold=1)
        g = doc_approve.gate_no_hold(self.cand())
        self.assertFalse(g.ok)
        self.assertIn("account-level fraud HOLD", g.why)

    def test_gate_no_hold_fails_when_only_a_LATER_role_of_the_run_is_held(self):
        """QA #1684 round 4, finding 1: `_group_runs` copied `account_hold` from the first role row, so
        a clean Composer masked a held Lyricist and the fraud-held credit got approved."""
        self.file_doc(roles=("Composer",), account_hold=0)
        self.file_doc(roles=("Lyricist",), account_hold=1, run_id=self._runs[-1])
        c = self.cand()
        self.assertTrue(c.docs[0].account_hold, "the hold from any role must reach the document")
        g = doc_approve.gate_no_hold(c)
        self.assertFalse(g.ok)
        self.assertIn("account-level fraud HOLD", g.why)

    def test_gate_no_hold_fails_when_the_request_is_held(self):
        self.file_doc()
        g = doc_approve.gate_no_hold(self.cand(), hold_ids=[self.request_id])
        self.assertFalse(g.ok)
        self.assertIn("names this request", g.why)

    def test_gate_no_hold_fails_when_the_account_is_on_the_hold_list(self):
        self.file_doc()
        g = doc_approve.gate_no_hold(self.cand(), hold_users=[145833])
        self.assertFalse(g.ok)
        self.assertIn("HOLD / RE-VERIFY", g.why)

    def test_gate_no_hold_passes_clean(self):
        self.file_doc()
        self.assertTrue(doc_approve.gate_no_hold(self.cand()).ok)

    # ── gate 6: 1 approval per request ──────────────────────────────────────
    def test_gate_one_per_request_fails_when_a_row_exists(self):
        self.file_doc()
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now,
                            mode="apply")
        g = doc_approve.gate_one_per_request(self.cand(), self.db)
        self.assertFalse(g.ok)
        self.assertIn("already provisional", g.why)

    def test_gate_one_per_request_passes_with_no_row(self):
        self.file_doc()
        self.assertTrue(doc_approve.gate_one_per_request(self.cand(), self.db).ok)

    # ── gate 7: <= 50 approvals per UTC day ─────────────────────────────────
    def _row(self, i: int, user_id: int) -> None:
        self.db.execute("INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref, popularity,"
                        " tier, approved_at, expires_at, state) VALUES (?,?,'i','s','r',1,'T0',?,'x','provisional')",
                        (f"r{i}", user_id, doc_approve.utc(self.now)))

    def test_gate_daily_cap_counts_USERS_not_requests(self):
        """2026-11-04 ruling: 50 is in USERS. A person with 24 credits today has spent ONE slot."""
        self.file_doc()
        for i in range(24):
            self._row(i, 777)                      # one other user, 24 requests
        self.db.commit()
        self.assertTrue(doc_approve.gate_daily_cap(self.cand(), self.db, self.now).ok)

    def test_gate_daily_cap_fails_at_50_DISTINCT_users(self):
        self.file_doc()
        for i in range(doc_approve.DAILY_USER_CAP):
            self._row(i, 1000 + i)                 # 50 users, one request each
        self.db.commit()
        g = doc_approve.gate_daily_cap(self.cand(user_id=900001), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertIn("cap 50 users", g.why)

    def test_gate_daily_cap_lets_a_user_ALREADY_counted_today_have_their_next_credit(self):
        """Once your user slot is spent the 50 does not grow: your remaining credits are bounded by
        the 25/user bound, never by a second user slot."""
        self.file_doc()
        for i in range(doc_approve.DAILY_USER_CAP):
            self._row(i, 1000 + i)
        self._row(99, 145833)                      # this candidate's own user is already in today's 50
        self.db.commit()
        self.assertTrue(doc_approve.gate_daily_cap(self.cand(), self.db, self.now).ok)

    def test_gate_daily_cap_fails_at_25_REQUESTS_for_one_user(self):
        self.file_doc()
        for i in range(doc_approve.PER_USER_DAILY_MAX):
            self._row(i, 145833)
        self.db.commit()
        g = doc_approve.gate_daily_cap(self.cand(), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertIn("cap 25/user/day", g.why)

    def test_gate_daily_cap_passes_at_24_requests_for_one_user(self):
        self.file_doc()
        for i in range(doc_approve.PER_USER_DAILY_MAX - 1):
            self._row(i, 145833)
        self.db.commit()
        self.assertTrue(doc_approve.gate_daily_cap(self.cand(), self.db, self.now).ok)

    def test_two_users_with_25_each_do_NOT_spend_the_fleet_day(self):
        """QA #1684 round 4, finding 2: the cap counted REQUESTS, so 2 users x 25 consumed all 50 and
        blocked the other 48 permitted users. It counts PEOPLE: those two are two slots."""
        self.file_doc()
        for i in range(25):
            self._row(i, 1000)
            self._row(100 + i, 1001)
        self.db.commit()
        self.assertTrue(doc_approve.gate_daily_cap(self.cand(), self.db, self.now).ok)
        ap = doc_approve.Approval("fresh", 145833, "145833:x", "sha", "dv4:sha:x", 3, "T0")
        spent, why = doc_approve.spend_slot(self.db, ap, now=self.now,
                                           expires=self.now + timedelta(days=doc_approve.PROVISIONAL_DAYS))
        self.assertTrue(spent, why)

    def test_spend_slot_reasks_the_PER_USER_bound_inside_its_transaction(self):
        """Finding 2's second half: two workers that both read 24 must not each spend a 25th and 26th."""
        self.file_doc()
        for i in range(doc_approve.PER_USER_DAILY_MAX):
            self._row(i, 145833)
        self.db.commit()
        ap = doc_approve.Approval("next", 145833, "145833:x", "sha", "dv4:sha:x", 3, "T0")
        spent, why = doc_approve.spend_slot(self.db, ap, now=self.now,
                                           expires=self.now + timedelta(days=doc_approve.PROVISIONAL_DAYS))
        self.assertFalse(spent)
        self.assertIn("25/user/day", why)

    # ── the order the 50 user slots are spent in ────────────────────────────
    def test_order_is_paid_first_then_oldest(self):
        """`paid_first_oldest`: paid before free, longest-waiting first, and a USER sorts as one unit."""
        def paid_tier(user_id, created_at):
            return 0 if user_id == 1 and str(created_at) == "2026-10-01T00:00:00Z" else (
                1 if user_id == 1 else 2)

        paid_old = doc_approve.order_key(1, "2026-10-01T00:00:00Z", paid_tier=paid_tier)
        paid_new = doc_approve.order_key(1, "2026-11-03T00:00:00Z", paid_tier=paid_tier)
        free = doc_approve.order_key(2, "2026-09-01T00:00:00Z", paid_tier=paid_tier)
        self.assertEqual(sorted([free, paid_new, paid_old]), [paid_old, paid_new, free])

    def test_order_never_fails_a_run_when_the_paid_lookup_blows_up(self):
        def boom(*_a):
            raise RuntimeError("paying list unreadable")

        self.assertEqual(doc_approve.order_key(5, "2026-10-01T00:00:00Z", paid_tier=boom)[0], 2)

    # ── the whole pass, and what a pass writes ──────────────────────────────
    def test_approve_applies_a_seven_day_provisional_row(self):
        self.file_doc()
        ap, answers = doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                                          now=self.now, mode="apply")
        self.assertIsNotNone(ap)
        self.assertTrue(all(g.ok for g in answers))
        row = doc_approve.rows_for(self.db)[0]
        self.assertEqual(row["state"], "provisional")
        self.assertEqual(row["tier"], "T0")
        self.assertEqual(row["ref"], f"dv4:a4205f34:145833:a4205f34")
        self.assertEqual(row["expires_at"], doc_approve.utc(self.now + timedelta(days=7)))
        self.assertEqual(doc_approve.approved_refs(self.db, doc_store=self.docs, now=self.now),
                         {self.request_id: row["ref"]})

    def test_shadow_mode_records_the_event_and_writes_no_row(self):
        self.file_doc()
        ap, _ = doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                                    now=self.now, mode="shadow")
        self.assertIsNotNone(ap)
        self.assertEqual(doc_approve.rows_for(self.db), [])
        states = [r[0] for r in self.db.execute("SELECT state FROM doc_approval_events")]
        self.assertEqual(states, ["would_approve"])

    def test_a_refused_candidate_records_the_gate_that_refused_it(self):
        self.file_doc()
        ap, _ = doc_approve.approve(self.cand(popularity=80), self.db, doc_store=self.docs, gate=self.allowed,
                                    now=self.now, mode="apply")
        self.assertIsNone(ap)
        gate, reason = self.db.execute("SELECT gate, reason FROM doc_approval_events").fetchone()
        self.assertEqual(gate, "tier")
        self.assertIn("T2/T3", reason)

    # ── provisional lifecycle ───────────────────────────────────────────────
    def test_sweep_pulls_an_approval_whose_verdict_later_contradicted(self):
        self.file_doc()
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now, mode="apply")
        self.file_doc(outcome="contradicted", at="2026-11-04T00:00:00Z")
        out = doc_approve.sweep(self.db, doc_store=self.docs, now=self.now + timedelta(days=2))
        self.assertEqual([(t.request_id, t.now) for t in out], [(self.request_id, "pulled")])
        self.assertEqual(doc_approve.approved_refs(self.db, doc_store=self.docs, now=self.now), {})

    def test_sweep_PULLS_when_the_documents_verdict_rows_have_vanished(self):
        """QA #1684 round 6, finding 2: `current_verdict` answers ('','') when the rows are GONE, so the old
        branch confirmed a provisional approval at day 7 on a document that no longer proves anything."""
        self.file_doc()
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now,
                            mode="apply")
        d = sqlite3.connect(self.docs)                     # the document is deleted from the store
        d.execute("DELETE FROM dv_outcomes")
        d.commit()
        d.close()
        out = doc_approve.sweep(self.db, doc_store=self.docs, now=self.now + timedelta(days=7, seconds=1))
        self.assertEqual([(t.was, t.now) for t in out], [("provisional", "pulled")])
        self.assertIn("no standing dv-4 verdict can be read", out[0].reason)
        self.assertEqual(doc_approve.approved_refs(self.db, doc_store=self.docs,
                                                  now=self.now + timedelta(days=8)), {})

    def test_sweep_confirms_at_day_seven_with_no_contradiction(self):
        self.file_doc()
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now, mode="apply")
        out = doc_approve.sweep(self.db, doc_store=self.docs, now=self.now + timedelta(days=7, seconds=1))
        self.assertEqual([(t.was, t.now) for t in out], [("provisional", "confirmed")])
        self.assertEqual(len(doc_approve.approved_refs(self.db, doc_store=self.docs, now=self.now)), 1)

    # ── the registry class (PR B's surface) ─────────────────────────────────
    def test_doc_class_approval_reads_its_own_entry_and_never_the_wider_automation(self):
        reg = self.dir / "registry.json"
        reg.write_text(json.dumps({"automations": {
            decide.AUTOMATION: {"approved": False},
            decide.DOC_AUTOMATION: {"approved": True, "approved_by": "Fable", "approval_ref": "r"}}}))
        self.assertTrue(decide.doc_class_approved(reg)[0])
        self.assertFalse(decide.registry_approved(reg)[0])

    def test_the_class_is_dormant_without_its_registry_entry(self):
        """The repo state before PR B (and every decider test without an entry): no store read, no log line, no row.
        This is what keeps the existing "the decider says nothing on this path" assertions true - a new subsystem
        must not start narrating in a run that never had its approval on file."""
        reg = self.dir / "registry.json"
        reg.write_text(json.dumps({"automations": {decide.AUTOMATION: {"approved": False}}}))
        ok, why = decide.doc_class_active(reg, kill=self.dir / "no-kill-file")
        self.assertFalse(ok)
        self.assertIn(decide.DOC_AUTOMATION, why)

    def test_the_class_is_dormant_under_the_kill_switch(self):
        reg = self.dir / "registry.json"
        reg.write_text(json.dumps({"automations": {decide.DOC_AUTOMATION: {
            "approved": True, "approved_by": "Fable", "approval_ref": "r"}}}))
        kill = self.dir / "doc-approve.disabled"
        kill.write_text("")
        ok, why = decide.doc_class_active(reg, kill=kill)
        self.assertFalse(ok)
        self.assertIn("kill switch", why)

    def test_the_class_is_active_only_with_both_the_approval_and_no_kill_switch(self):
        reg = self.dir / "registry.json"
        reg.write_text(json.dumps({"automations": {decide.DOC_AUTOMATION: {
            "approved": True, "approved_by": "Fable", "approval_ref": "r"}}}))
        ok, why = decide.doc_class_active(reg, kill=self.dir / "absent")
        self.assertTrue(ok, why)
        self.assertIn("Fable", why)

    def test_doc_class_approval_refuses_an_entry_without_approved_by(self):
        reg = self.dir / "registry.json"
        reg.write_text(json.dumps({"automations": {
            decide.DOC_AUTOMATION: {"approved": True, "approved_by": " ", "approval_ref": "r"}}}))
        ok, why = decide.doc_class_approved(reg)
        self.assertFalse(ok)
        self.assertIn("approved_by", why)


class DocApprovePlanAndRelease(unittest.TestCase):
    """QA #1684 finding 2: the decider has guards AFTER the doc gates, and a core write can still fail, so a
    row must be plannable without being written and releasable when the credit does not confirm."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.docs = self.dir / "doc-verify.sqlite"
        self.proof = self.dir / "proof.sqlite"
        d = sqlite3.connect(self.docs)
        d.executescript("""
            CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at TEXT NOT NULL,
              proof_id TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER,
              source_ref TEXT, h3_verdict TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, need TEXT,
              account_hold INTEGER NOT NULL DEFAULT 0, detail_json TEXT NOT NULL, version TEXT NOT NULL,
              intake_id TEXT);""")
        rid = "4bec612c-565d-4abf-abc3-db5cc4feb25a"
        for role in ("Lyricist", "Composer"):
            d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict, outcome,"
                      " reason, account_hold, detail_json, version, intake_id) VALUES ('r1','2026-10-31T12:26:32Z',"
                      " 'sha',?,?,145833,'PLAUSIBLE','verified','because',0,'{}','dv-4','145833:a4205f34')",
                      (rid, role))
        d.commit()
        d.close()
        p = sqlite3.connect(self.proof)
        p.executescript("""
            CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, subject TEXT NOT NULL,
              candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', conversation_id TEXT NOT NULL,
              source TEXT NOT NULL, file_sha256 TEXT NOT NULL, file_path TEXT, mime TEXT, bytes INTEGER,
              received_at TEXT NOT NULL, filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT,
              UNIQUE (user_id, file_sha256));""")
        p.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, conversation_id,"
                  " source, file_sha256, received_at, filed_by) VALUES ('145833:a4205f34',145833,'credit',?,'777',"
                  "'intercom','a4205f34','2026-10-24T06:49:57Z','proof_intake')", (json.dumps([rid]),))
        p.commit()
        p.close()
        self.rid = rid
        self.db = sqlite3.connect(self.dir / "ledger.sqlite")
        doc_approve.ensure_schema(self.db)
        self.now = datetime(2026, 11, 3, 20, 0, 0, tzinfo=timezone.utc)

    def tearDown(self) -> None:
        self.db.close()
        self.tmp.cleanup()

    def cand(self, popularity=12):
        docs = tuple(doc_approve.verified_docs(self.docs, self.proof)[self.rid])
        return doc_approve.Candidate(self.rid, 145833, popularity, docs)

    def allowed(self, *_a, **_kw):
        from credit_review.account_gate import ALLOW, GateResult
        return GateResult(ALLOW, ())

    def test_plan_answers_without_writing_a_row_or_an_event(self):
        ap, answers = doc_approve.plan(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now)
        self.assertIsNotNone(ap)
        self.assertTrue(all(g.ok for g in answers))
        self.assertEqual(ap.ref, "dv4:a4205f34:145833:a4205f34")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approval_events").fetchone()[0], 0)

    def test_plan_reports_the_gate_that_would_refuse(self):
        ap, answers = doc_approve.plan(self.cand(popularity=80), self.db, doc_store=self.docs, gate=self.allowed,
                                      now=self.now)
        self.assertIsNone(ap)
        self.assertEqual(answers[-1].name, "tier")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0)

    def test_release_gives_the_slot_back_and_keeps_the_audit_row(self):
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now, mode="apply")
        self.assertTrue(doc_approve.release(self.db, self.rid, reason="core write did not confirm (skipped:x)",
                                            now=self.now))
        self.assertEqual(doc_approve.approved_refs(self.db, doc_store=self.docs, now=self.now), {},
                         "a released row is not an approval: nothing may read it as one")
        self.assertEqual(doc_approve.rows_for(self.db), [], "the read-back never shows a released row")
        self.assertEqual(self.db.execute("SELECT state, reason FROM doc_approvals").fetchone()[0], "released")
        self.assertEqual([r[0] for r in self.db.execute("SELECT state FROM doc_approval_events")],
                         ["approved", "released"])
        self.assertTrue(doc_approve.gate_one_per_request(self.cand(), self.db).ok,
                        "the 1-per-request slot is free again")
        self.assertFalse(doc_approve.release(self.db, self.rid, reason="again"), "only a provisional row releases")

    def test_a_released_row_does_not_count_against_the_daily_cap(self):
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed, now=self.now, mode="apply")
        doc_approve.release(self.db, self.rid, reason="core write did not confirm", now=self.now)
        for i in range(doc_approve.MAX_PER_DAY - 1):
            self.db.execute("INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref, popularity,"
                            " tier, approved_at, expires_at, state) VALUES (?,1,'i','s','r',1,'T0',?,'x','provisional')",
                            (f"r{i}", doc_approve.utc(self.now)))
        self.db.commit()
        g = doc_approve.gate_daily_cap(self.cand(), self.db, self.now)
        self.assertTrue(g.ok, "49 live rows: the released one must not push the day to the cap")


def _make_stores(base: Path, *, wal: bool = False) -> tuple[Path, Path]:
    """The two read-only stores (`dv_outcomes`, `proof_intake`) with one verified dv-4 run for one request."""
    docs, proof = base / "doc-verify.sqlite", base / "proof.sqlite"
    d = sqlite3.connect(docs)
    if wal:
        d.execute("PRAGMA journal_mode=WAL")
    d.executescript("""
        CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at TEXT NOT NULL,
          proof_id TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER,
          source_ref TEXT, h3_verdict TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, need TEXT,
          account_hold INTEGER NOT NULL DEFAULT 0, detail_json TEXT NOT NULL, version TEXT NOT NULL,
          intake_id TEXT);""")
    d.commit()
    p = sqlite3.connect(proof)
    p.executescript("""
        CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, subject TEXT NOT NULL,
          candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', conversation_id TEXT NOT NULL,
          source TEXT NOT NULL, file_sha256 TEXT NOT NULL, file_path TEXT, mime TEXT, bytes INTEGER,
          received_at TEXT NOT NULL, filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT,
          UNIQUE (user_id, file_sha256));""")
    p.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, conversation_id,"
              " source, file_sha256, received_at, filed_by) VALUES ('145833:a4205f34',145833,'credit',?,'777',"
              "'intercom','a4205f34','2026-10-24T06:49:57Z','proof_intake')",
              (json.dumps(["4bec612c-565d-4abf-abc3-db5cc4feb25a"]),))
    p.commit()
    p.close()
    return docs, proof


def _role_row(docs: Path, *, run_id: str, at: str, role: str, outcome: str) -> None:
    d = sqlite3.connect(docs)
    d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict, outcome,"
              " reason, account_hold, detail_json, version, intake_id) VALUES (?,?,'sha',?,?,145833,'PLAUSIBLE',"
              "?,'because',0,'{}','dv-4','145833:a4205f34')",
              (run_id, at, "4bec612c-565d-4abf-abc3-db5cc4feb25a", role, outcome))
    d.commit()
    d.close()


class DocApproveQaRound3(unittest.TestCase):
    """QA #1684 round 3: WAL-visibility, run boundaries (not second-resolution stamps), a released slot that
    can actually be re-approved, and a daily cap that cannot be spent twice from one stale count."""

    RID = "4bec612c-565d-4abf-abc3-db5cc4feb25a"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.now = datetime(2026, 11, 3, 20, 0, 0, tzinfo=timezone.utc)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def allowed(self, *_a, **_kw):
        from credit_review.account_gate import ALLOW, GateResult
        return GateResult(ALLOW, ())

    def _ledger(self, name: str = "ledger.sqlite") -> sqlite3.Connection:
        db = sqlite3.connect(self.dir / name, timeout=5.0)
        doc_approve.ensure_schema(db)
        return db

    def _approved_then_released(self, db: sqlite3.Connection, docs: Path, proof: Path, *, sha="a4205f34"):
        c = doc_approve.Candidate(self.RID, 145833, 12,
                                  tuple(doc_approve.verified_docs(docs, proof)[self.RID]))
        ap, _ = doc_approve.approve(c, db, doc_store=docs, gate=self.allowed, now=self.now, mode="apply")
        self.assertIsNotNone(ap)
        self.assertTrue(doc_approve.release(db, self.RID, reason="core write did not confirm", now=self.now))
        return c

    # ── finding 1: a committed verdict in the WAL is the verdict that counts ──
    def test_a_forged_verdict_committed_to_the_wal_is_seen(self):
        """`immutable=1` reads the main database only, so the PREVIOUS `verified` run was read while the newest
        `forged` run sat uncheckpointed in the -wal: the request would have been approved from revoked proof."""
        docs, proof = _make_stores(self.dir, wal=True)
        _role_row(docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Composer", outcome="verified")
        writer = sqlite3.connect(docs)                     # held OPEN so nothing checkpoints the WAL
        writer.execute("PRAGMA journal_mode=WAL")
        for role in ("Composer", "Lyricist"):
            writer.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict,"
                           " outcome, reason, account_hold, detail_json, version, intake_id) VALUES ('r2',"
                           " '2026-11-03T09:00:00Z','sha',?,?,145833,'CONTRADICTED','forged','fake letter',0,'{}',"
                           " 'dv-4','145833:a4205f34')", (self.RID, role))
        writer.commit()                                    # committed, NOT checkpointed
        self.assertTrue((self.dir / "doc-verify.sqlite-wal").exists())
        try:
            self.assertEqual(doc_approve.verified_docs(docs, proof), {},
                             "the newest run is forged: the document proves nothing")
            self.assertEqual(doc_approve.current_verdict(docs, "145833:a4205f34", self.RID)[0], "forged")
        finally:
            writer.close()

    # ── finding 2: the newest run is a RUN, not the row with the highest second ──
    def test_a_run_crossing_a_second_boundary_keeps_its_contradicted_role(self):
        docs, proof = _make_stores(self.dir)
        _role_row(docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Composer", outcome="verified")
        _role_row(docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Lyricist", outcome="verified")
        # ONE run, two roles, two different second-resolution stamps: the contradicted role landed first
        _role_row(docs, run_id="r2", at="2026-11-03T09:00:00Z", role="Lyricist", outcome="contradicted")
        _role_row(docs, run_id="r2", at="2026-11-03T09:00:01Z", role="Composer", outcome="verified")
        self.assertEqual(doc_approve.verified_docs(docs, proof), {},
                         "MAX(at) dropped the contradicted role and read the document as fully verified")
        self.assertEqual(doc_approve.current_verdict(docs, "145833:a4205f34", self.RID)[0], "mixed")

    def test_a_later_run_that_re_judges_only_one_role_cannot_clear_the_other(self):
        """A cheaper version of the same hole: a later run that only re-judged one role would otherwise make
        the document `verified` again while the other role's newest verdict is still contradicted."""
        docs, proof = _make_stores(self.dir)
        _role_row(docs, run_id="r1", at="2026-11-01T09:00:00Z", role="Lyricist", outcome="contradicted")
        _role_row(docs, run_id="r1", at="2026-11-01T09:00:00Z", role="Composer", outcome="verified")
        _role_row(docs, run_id="r2", at="2026-11-02T09:00:00Z", role="Composer", outcome="verified")
        self.assertEqual(doc_approve.verified_docs(docs, proof), {})
        self.assertNotEqual(doc_approve.current_verdict(docs, "145833:a4205f34", self.RID)[0], "verified")

    # ── finding 3: a released slot is a slot that can be spent again ──
    def test_a_released_slot_can_be_approved_again(self):
        docs, proof = _make_stores(self.dir)
        _role_row(docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Composer", outcome="verified")
        db = self._ledger()
        try:
            c = self._approved_then_released(db, docs, proof)
            ap, answers = doc_approve.approve(c, db, doc_store=docs, gate=self.allowed, now=self.now,
                                              mode="apply")
            self.assertIsNotNone(ap, f"a released slot was promised back but the retry was refused: "
                                     f"{answers[-1] if answers else ''}")
            rows = db.execute("SELECT request_id, state, approved_at FROM doc_approvals").fetchall()
            self.assertEqual(len(rows), 1, "the released row IS the slot: no second row")
            self.assertEqual(rows[0][1], "provisional")
            self.assertEqual([r[0] for r in db.execute("SELECT state FROM doc_approval_events ORDER BY id")],
                             ["approved", "released", "approved"])
            self.assertEqual(len(doc_approve.approved_refs(db, doc_store=docs, now=self.now)), 1)
        finally:
            db.close()

    # ── finding 4: the day cap is spent inside ONE write transaction ──
    def test_two_workers_at_49_cannot_both_spend_the_last_slot(self):
        docs, proof = _make_stores(self.dir)
        _role_row(docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Composer", outcome="verified")
        a = self._ledger()
        b = sqlite3.connect(self.dir / "ledger.sqlite", timeout=0.2)
        try:
            # the day is made full the way the 2026-11-04 ruling defines full: 49 DISTINCT USERS
            for i in range(doc_approve.DAILY_USER_CAP - 1):
                a.execute("INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref, popularity,"
                          " tier, approved_at, expires_at, state) VALUES (?,?,'i','s','r',1,'T0',?,'x','provisional')",
                          (f"r{i}", 1000 + i, doc_approve.utc(self.now)))
            a.commit()
            ap = doc_approve.Approval(self.RID, 145833, "145833:a4205f34", "a4205f34", "dv4:a4205f34:x",
                                      12, "T0")
            # worker A reads 49 and holds the write transaction before it writes the 50th
            a.execute("BEGIN IMMEDIATE")
            self.assertEqual(a.execute("SELECT COUNT(*) FROM doc_approvals WHERE approved_at >= ?",
                                       (doc_approve.utc(self.now)[:11] + "00:00:00Z",)).fetchone()[0], 49)
            # worker B must NOT be able to reserve on that same stale count
            with self.assertRaises(sqlite3.OperationalError):
                doc_approve.spend_slot(b, ap, now=self.now,
                                       expires=self.now + timedelta(days=doc_approve.PROVISIONAL_DAYS))
            a.execute("INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref, popularity,"
                      " tier, approved_at, expires_at, state) VALUES ('last',9999,'i','s','r',1,'T0',?,'x',"
                      "'provisional')", (doc_approve.utc(self.now),))
            a.execute("COMMIT")
            spent, why = doc_approve.spend_slot(b, ap, now=self.now,
                                                expires=self.now + timedelta(days=doc_approve.PROVISIONAL_DAYS))
            self.assertFalse(spent, "the day is full: the 50th row already exists")
            self.assertIn("daily_cap", why)
            self.assertEqual(b.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0],
                             doc_approve.DAILY_USER_CAP)
        finally:
            a.close()
            b.close()


if __name__ == "__main__":
    warnings.filterwarnings("ignore", category=ResourceWarning)
    unittest.main(verbosity=1, warnings="")
