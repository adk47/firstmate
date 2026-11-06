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
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import decide, doc_approve  # noqa: E402

# The R22 guard 1-3 evidence a dv-4 run records: forensics PLAUSIBLE with an extracted issuer and
# signatory, and two independent cross-checks positive (xc_dsp on the track, xc_isrc by ISRC).
_R22_DETAIL = json.dumps({
    "h3": "PLAUSIBLE",
    "checks": {"xc_dsp": "positive", "xc_isrc": "positive", "xc_label": "unknown",
               "xc_domain": "skipped", "xc_signatory": "unknown"},
    "issuer": {"name": "Label Ltd", "type": "label", "confidence": 0.9},
    "signatory": {"name": "A Person", "title": "Head of A&R", "confidence": 0.9},
})


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
        # QA #1800 finding 3: the reversal tests wrote the GLOBAL freeze marker, which contaminated
        # every later test and could freeze the host's real class. The marker is per-test now.
        self._freeze = doc_approve.FREEZE_PATH
        doc_approve.FREEZE_PATH = self.dir / "doc-approve.frozen"
        self.addCleanup(setattr, doc_approve, "FREEZE_PATH", self._freeze)
        # the proof store the reuse gate reads (R22a D3) is this test's, never the host's
        self._proof_default = doc_approve.DEFAULT_PROOF_STORE
        doc_approve.DEFAULT_PROOF_STORE = str(self.proof)
        self.addCleanup(setattr, doc_approve, "DEFAULT_PROOF_STORE", self._proof_default)
        self.request_id = "4bec612c-565d-4abf-abc3-db5cc4feb25a"
        self._runs: list[str] = []
        # R22 guard 4: the fixture account is a CLEAN claimant (60 days of ledger history, no pull), so
        # the guards under test are the ones each test names, not the claimant gate.
        self.clean_claimant(145833, days=60)

    def clean_claimant(self, user_id: int, *, days: int = 60, decided_at: str | None = None) -> None:
        at = decided_at or (self.now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, big_track,"
                        " decision, reason, mode) VALUES ('r0',?,?,?,?,0,'support','fixture','shadow')",
                        (at, f"fixture-{user_id}-{at}", "prof-1", user_id))
        self.db.commit()

    def tearDown(self) -> None:
        self.db.close()
        self.tmp.cleanup()

    # ── fixtures ────────────────────────────────────────────────────────────
    def file_doc(self, *, intake_id="145833:a4205f34", user_id=145833, request_id=None, sha="a4205f34",
                 roles=("Lyricist", "Composer"), outcome="verified", version="dv-4", at=None,
                 account_hold=0, candidates=None, filed_at="2026-10-24T06:49:57Z", run_id=None,
                 h3="PLAUSIBLE", checks=None, issuer_type="label", issuer_conf=0.9,
                 sign_conf=0.9) -> None:
        """One dv-4 run. `h3`/`checks`/`issuer_*` are the R22 guard 1-3 evidence the run recorded."""
        detail = json.dumps({
            "h3": h3,
            "checks": checks if checks is not None else {
                "xc_dsp": "positive", "xc_isrc": "positive", "xc_label": "unknown",
                "xc_domain": "skipped", "xc_signatory": "unknown"},
            "issuer": {"name": "Label Ltd", "type": issuer_type, "confidence": issuer_conf},
            "signatory": {"name": "A Person", "title": "Head of A&R", "confidence": sign_conf},
        })
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
                      " 'PLAUSIBLE',?,'because',?,?,?,?)",
                      (run_id, at, rid, role, user_id, outcome, account_hold, detail, version,
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

    def cand(self, popularity=12, user_id=145833, docs=None, profile_id="prof-1",
             roles=("Lyricist",), account_created_at=None) -> doc_approve.Candidate:
        if docs is None:
            docs = tuple(doc_approve.verified_docs(self.docs, self.proof).get(self.request_id, ()))
        # QA #1800 r18 finding 1: the claimant gate needs core's own createdAt; the ledger's first
        # sighting is our clock and can no longer stand in for the account's age.
        if account_created_at is None:
            account_created_at = (self.now - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        return doc_approve.Candidate(self.request_id, user_id, popularity, docs, profile_id,
                                     tuple(roles), False, account_created_at)

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

    def test_gate_tier_reads_popularity_ZERO_as_KNOWN_and_REFUSES_it(self):
        """`0` is never "unknown" - and, since Fable R22a D1, it is never approvable either.

        `0` is falsy in Python, so a `pop or default` (or an `if not pop` guard) would silently read a
        zero-popularity track as ABSENT. The two cases must stay distinguishable: `0` is a KNOWN
        popularity that R22's tier line ("1-59") excludes, and `None` is UNKNOWN. R22a D1 answered d2's
        popularity-0 question NO, because core's own agent guard refuses a zero as
        `popularity_unattributable` - so approving it here would plan a write core rejects.
        """
        zero = doc_approve.gate_tier(self.cand(popularity=0))
        self.assertFalse(zero.ok)
        self.assertIn("1-59", zero.why, "0 is refused as OUT of the tier line, not as unknown")
        self.assertNotIn("unknown", zero.why)
        self.assertEqual(doc_approve.tier_of(0), "T0", "0 is still T0 - known, never unknown")
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
    def _row(self, i: int, user_id: int, profile_id: str = "prof-1") -> None:
        self.db.execute("INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
                        " popularity, tier, approved_at, expires_at, state)"
                        " VALUES (?,?,?,'i','s','r',1,'T0',?,'x','provisional')",
                        (f"r{i}", user_id, profile_id, doc_approve.utc(self.now)))

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

    def test_gate_daily_cap_fails_at_the_R22_per_user_bound(self):
        """R22 guard 7: 5 requests per user per day (the 2026-11-04 ruling's 25 is superseded)."""
        self.file_doc()
        for i in range(doc_approve.PER_USER_DAILY_MAX):
            self._row(i, 145833)
        self.db.commit()
        g = doc_approve.gate_daily_cap(self.cand(), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertIn(f"cap {doc_approve.PER_USER_DAILY_MAX}/user/day", g.why)

    def test_gate_daily_cap_passes_at_one_below_the_per_user_bound(self):
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
        """Finding 2's second half: two workers that both read one below the bound must not each spend
        the last slot (R22 guard 7: 5/user/day)."""
        self.file_doc()
        for i in range(doc_approve.PER_USER_DAILY_MAX):
            self._row(i, 145833)
        self.db.commit()
        ap = doc_approve.Approval("next", 145833, "145833:x", "sha", "dv4:sha:x", 3, "T0")
        spent, why = doc_approve.spend_slot(self.db, ap, now=self.now,
                                           expires=self.now + timedelta(days=doc_approve.PROVISIONAL_DAYS))
        self.assertFalse(spent)
        self.assertIn(f"{doc_approve.PER_USER_DAILY_MAX}/user/day", why)

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
        self._proof_default = doc_approve.DEFAULT_PROOF_STORE
        doc_approve.DEFAULT_PROOF_STORE = str(self.proof)
        self.addCleanup(setattr, doc_approve, "DEFAULT_PROOF_STORE", self._proof_default)
        # QA #1800 r11 findings 3+4: a host freeze marker (or one left by another test) made these
        # cases red. The marker is per-test, so the suite can neither read nor write the real class's.
        self._freeze = doc_approve.FREEZE_PATH
        doc_approve.FREEZE_PATH = self.dir / "doc-approve.frozen"
        self.addCleanup(setattr, doc_approve, "FREEZE_PATH", self._freeze)
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
                      " 'sha',?,?,145833,'PLAUSIBLE','verified','because',0,?,'dv-4','145833:a4205f34')",
                      (rid, role, _R22_DETAIL))
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
        decide.ensure_schema(self.db)
        doc_approve.ensure_schema(self.db)
        self.now = datetime(2026, 11, 3, 20, 0, 0, tzinfo=timezone.utc)
        # R22 guard 4: a clean claimant (60 days of ledger history), so these tests exercise the
        # plan/release lifecycle rather than the claimant gate.
        self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, big_track,"
                        " decision, reason, mode) VALUES ('r0','2026-09-04T00:00:00Z','fixture','prof-1',145833,0,"
                        " 'support','fixture','shadow')")
        self.db.commit()

    def tearDown(self) -> None:
        self.db.close()
        self.tmp.cleanup()

    def cand(self, popularity=12):
        docs = tuple(doc_approve.verified_docs(self.docs, self.proof)[self.rid])
        # QA #1800 r18 finding 1: core's own createdAt, not the ledger's first sighting.
        created = (self.now - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        return doc_approve.Candidate(self.rid, 145833, popularity, docs, "prof-1", ("Lyricist",),
                                     False, created)

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
              "?,'because',0,?,'dv-4','145833:a4205f34')",
              (run_id, at, "4bec612c-565d-4abf-abc3-db5cc4feb25a", role, outcome, _R22_DETAIL))
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
        # the reuse gate (R22a D3) reads the proof store; never the host's
        self._proof_default = doc_approve.DEFAULT_PROOF_STORE
        doc_approve.DEFAULT_PROOF_STORE = str(self.dir / "proof.sqlite")
        self.addCleanup(setattr, doc_approve, "DEFAULT_PROOF_STORE", self._proof_default)
        self._freeze = doc_approve.FREEZE_PATH
        doc_approve.FREEZE_PATH = self.dir / "doc-approve.frozen"
        self.addCleanup(setattr, doc_approve, "FREEZE_PATH", self._freeze)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def allowed(self, *_a, **_kw):
        from credit_review.account_gate import ALLOW, GateResult
        return GateResult(ALLOW, ())

    def _ledger(self, name: str = "ledger.sqlite") -> sqlite3.Connection:
        db = sqlite3.connect(self.dir / name, timeout=5.0)
        decide.ensure_schema(db)
        doc_approve.ensure_schema(db)
        # R22 guard 4: a clean claimant, so these tests exercise the lifecycle, not the claimant gate
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, big_track,"
                   " decision, reason, mode) VALUES ('r0','2026-09-04T00:00:00Z','fixture','prof-1',145833,0,"
                   " 'support','fixture','shadow')")
        db.commit()
        return db

    def _approved_then_released(self, db: sqlite3.Connection, docs: Path, proof: Path, *, sha="a4205f34"):
        # QA #1800 r18 finding 1: core's own createdAt, not the ledger's first sighting.
        created = (self.now - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        c = doc_approve.Candidate(self.RID, 145833, 12,
                                  tuple(doc_approve.verified_docs(docs, proof)[self.RID]), "prof-1",
                                  ("Lyricist",), False, created)
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


class _R22Fixture(unittest.TestCase):
    """The R22 fixture: one dv-4 verified document with the forensics/cross-check evidence a real run
    records, a ledger, and a per-test freeze marker. No tests of its own, so a later round can reuse
    the fixture without re-running every earlier case."""

    RID = "4bec612c-565d-4abf-abc3-db5cc4feb25a"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.docs, self.proof = _make_stores(self.dir)
        _role_row(self.docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Lyricist", outcome="verified")
        self.db = sqlite3.connect(self.dir / "ledger.sqlite")
        decide.ensure_schema(self.db)
        doc_approve.ensure_schema(self.db)
        self.now = datetime(2026, 11, 5, 20, 0, 0, tzinfo=timezone.utc)
        self.freeze = self.dir / "doc-approve.frozen"
        self._freeze_patch = mock.patch.object(doc_approve, "FREEZE_PATH", self.freeze)
        self._freeze_patch.start()
        self._proof_patch = mock.patch.object(doc_approve, "DEFAULT_PROOF_STORE", str(self.proof))
        self._proof_patch.start()
        self.clean_claimant(145833, days=60)

    def tearDown(self) -> None:
        self._freeze_patch.stop()
        self._proof_patch.stop()
        self.db.close()
        self.tmp.cleanup()

    def clean_claimant(self, user_id: int, *, days: int = 60) -> None:
        at = (self.now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, big_track,"
                        " decision, reason, mode) VALUES ('r0',?,?,?,?,0,'support','fixture','shadow')",
                        (at, f"fixture-{user_id}-{at}", "prof-1", user_id))
        self.db.commit()

    def allowed(self, *_a, **_kw):
        from credit_review.account_gate import ALLOW, GateResult
        return GateResult(ALLOW, ())

    def core_age(self, *, days: int = 60) -> str:
        """Core's own `user.createdAt` for a clean claimant, in the format decide.py passes through.

        QA #1800 r18 finding 1: the claimant gate no longer accepts the ledger's first sighting as an
        account age - the ledger is OUR clock, and an account created five days ago whose first
        `decisions` row is forty days old would pass a 30-day floor it never earned. So every fixture
        that means "a clean claimant" has to supply core's stamp, exactly as `decide.run()` does.
        """
        return (self.now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def cand(self, *, popularity=12, user_id=145833, profile_id="prof-1", roles=("Lyricist",),
             big_track=False, account_created_at=None):
        docs = tuple(doc_approve.verified_docs(self.docs, self.proof)[self.RID])
        return doc_approve.Candidate(self.RID, user_id, popularity, docs, profile_id, tuple(roles),
                                     big_track,
                                     self.core_age() if account_created_at is None
                                     else account_created_at)

    def rewrite_evidence(self, **kw) -> None:
        """Replace the newest run's detail_json (the R22 guard 1-3 evidence) in place."""
        detail = json.loads(_R22_DETAIL)
        for k, v in kw.items():
            if k in ("h3",):
                detail["h3"] = v
            elif k == "checks":
                detail["checks"] = v
            elif k == "issuer_conf":
                detail["issuer"]["confidence"] = v
            elif k == "sign_conf":
                detail["signatory"]["confidence"] = v
            elif k == "issuer_name":
                detail["issuer"]["name"] = v
            elif k == "sign_name":
                detail["signatory"]["name"] = v
        d = sqlite3.connect(self.docs)
        d.execute("UPDATE dv_outcomes SET detail_json = ?", (json.dumps(detail),))
        d.commit()
        d.close()


class DocApproveR22(_R22Fixture):
    """Fable R22 (2026-11-05): document-only approval for T0/T1 under EIGHT coded guards.

    One CAN-FAIL test per guard the ruling added or tightened, because a guard with no failing test is a
    guard nobody would notice losing.
    """

    # ── guard 1: verified WITH an independent cross-check PLUS forensics ─────
    def test_guard1_a_SUSPECT_forensics_verdict_is_refused(self):
        self.rewrite_evidence(h3="SUSPECT")
        g = doc_approve.gate_forensics(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("SUSPECT", g.why)

    def test_guard1_forensics_that_extracted_no_issuer_is_refused(self):
        """A run that never extracted the issuer/signatory did not do forensics, whatever its outcome."""
        self.rewrite_evidence(issuer_conf=0.0, sign_conf=0.0)
        g = doc_approve.gate_forensics(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("forensics did not run", g.why)

    def test_guard1_a_document_with_NO_positive_crosscheck_is_refused(self):
        """PLUS means both: forensics alone is not enough, and neither is a cross-check alone."""
        self.rewrite_evidence(checks={"xc_dsp": "unknown", "xc_isrc": "unknown", "xc_label": "unknown",
                                      "xc_domain": "skipped"})
        g = doc_approve.gate_crosscheck(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("no independent cross-check is positive", g.why)

    def test_guard1_a_CONTRADICTING_crosscheck_is_refused_even_with_a_positive_one(self):
        self.rewrite_evidence(checks={"xc_dsp": "positive", "xc_isrc": "positive", "xc_label": "contradicts",
                                      "xc_domain": "skipped"})
        g = doc_approve.gate_crosscheck(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("xc_label", g.why)

    # ── guard 2: same-release scope ─────────────────────────────────────────
    def test_guard2_a_document_with_no_RELEASE_keyed_check_is_refused(self):
        """A label-line match is not a release identity: only xc_dsp (this track) and xc_isrc (by ISRC) are."""
        self.rewrite_evidence(checks={"xc_dsp": "unknown", "xc_isrc": "unknown", "xc_label": "positive",
                                      "xc_domain": "positive"})
        g = doc_approve.gate_same_release(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("no trusted source ties the document to this release", g.why)

    def test_guard2_a_release_contradiction_is_refused(self):
        self.rewrite_evidence(checks={"xc_dsp": "positive", "xc_isrc": "contradicts", "xc_label": "unknown",
                                      "xc_domain": "skipped"})
        g = doc_approve.gate_same_release(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("another release", g.why)

    # ── guard 3: role not contradicted, and not artist/org ──────────────────
    def test_guard3_an_ARTIST_role_is_refused(self):
        g = doc_approve.gate_role(self.cand(roles=("Primary Artist",)), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("artist", g.why)

    def test_guard3_an_ORG_role_is_refused(self):
        g = doc_approve.gate_role(self.cand(roles=("Publisher",)), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("org", g.why)

    def test_guard3_a_role_CONTRADICTED_at_a_trusted_source_is_refused(self):
        self.rewrite_evidence(checks={"xc_dsp": "contradicts", "xc_isrc": "positive", "xc_label": "unknown",
                                      "xc_domain": "skipped"})
        g = doc_approve.gate_role(self.cand(), self.docs)
        self.assertFalse(g.ok)
        self.assertIn("credits someone else", g.why)

    # ── guard 4: clean claimant >= 30d, or a prior approval ─────────────────
    def test_guard4_a_brand_new_account_with_no_prior_approval_is_refused(self):
        g = doc_approve.gate_claimant(self.cand(user_id=999, account_created_at=""), self.db,
                                      self.now)
        self.assertFalse(g.ok)
        self.assertEqual(g.name, "claimant_no_history")

    def test_guard4_an_account_younger_than_30_days_is_refused(self):
        g = doc_approve.gate_claimant(
            self.cand(user_id=888, account_created_at=self.core_age(days=3)), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertEqual(g.name, "claimant")
        self.assertIn("30d clean-claimant floor", g.why)

    def test_guard4_an_OLD_decision_does_not_stand_in_for_core_age(self):
        """QA #1800 r18 finding 1: the ledger is OUR clock, not the account's age.

        An account created five days ago whose first `decisions` row is forty days old (a claim, a
        merge, a backfill) used to pass a 30-day floor it never earned. R22a D2 says a missing core
        `createdAt` is `claimant_no_history`, so the ledger can never PASS this gate - only core's own
        stamp can.
        """
        self.clean_claimant(888, days=40)
        g = doc_approve.gate_claimant(self.cand(user_id=888, account_created_at=""), self.db,
                                      self.now)
        self.assertFalse(g.ok, "a 40-day-old ledger row is not a 40-day-old account")
        self.assertEqual(g.name, "claimant_no_history")
        self.assertIn("not supplied", g.why)

    def test_guard4_a_PRIOR_APPROVAL_lets_a_new_account_through(self):
        self.db.execute("INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
                        " popularity, tier, approved_at, expires_at, state)"
                        " VALUES ('old','777','prof-9','i','s','r',1,'T0','2026-11-01T00:00:00Z','x','confirmed')")
        self.db.commit()
        g = doc_approve.gate_claimant(self.cand(user_id=777), self.db, self.now)
        self.assertTrue(g.ok, g.why)

    def test_guard4_an_account_with_a_PULLED_approval_is_not_a_clean_claimant(self):
        self.db.execute("INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
                        " popularity, tier, approved_at, expires_at, state)"
                        " VALUES ('old','145833','prof-1','i','s','r',1,'T0','2026-10-01T00:00:00Z','x','pulled')")
        self.db.commit()
        g = doc_approve.gate_claimant(self.cand(), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertIn("PULLED", g.why)

    # ── guard 7: 1/request, 5/user, 10/profile, 50/day ──────────────────────
    def test_guard7_the_per_PROFILE_cap_is_ten(self):
        for i in range(doc_approve.PER_PROFILE_DAILY_MAX):
            self.db.execute("INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
                            " popularity, tier, approved_at, expires_at, state)"
                            " VALUES (?,?,?,'i','s','r',1,'T0',?,'x','provisional')",
                            (f"p{i}", 1000 + i, "prof-1", doc_approve.utc(self.now)))
        self.db.commit()
        g = doc_approve.gate_profile_cap(self.cand(), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertIn(f"cap {doc_approve.PER_PROFILE_DAILY_MAX}/profile/day", g.why)

    def test_guard7_a_request_with_no_profile_id_is_refused(self):
        g = doc_approve.gate_profile_cap(self.cand(profile_id=None), self.db, self.now)
        self.assertFalse(g.ok)
        self.assertIn("no profile id", g.why)

    # ── guard 6: PROVISIONAL served, never lowered ──────────────────────────
    def test_guard6_a_provisional_window_below_seven_days_is_refused_at_the_write(self):
        ap = doc_approve.Approval(self.RID, 145833, "145833:a4205f34", "sha", "dv4:sha:x", 12, "T0", "prof-1")
        spent, why = doc_approve.spend_slot(self.db, ap, now=self.now,
                                            expires=self.now + timedelta(days=1))
        self.assertFalse(spent)
        self.assertIn("below the 7d floor", why)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0)

    # ── guard 8: 100% audit, auto-freeze on ONE reversal, requester told ────
    def test_guard8_every_approval_writes_an_audit_row_with_its_evidence(self):
        ap, _ = doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                                    now=self.now, mode="apply")
        self.assertIsNotNone(ap)
        row = self.db.execute("SELECT h3, checks_json, scope, notice FROM doc_approval_audit").fetchone()
        self.assertEqual(row[0], "PLAUSIBLE")
        self.assertIn("xc_dsp", json.loads(row[1]))
        self.assertEqual(row[2], doc_approve.SCOPE)
        self.assertIn("core approval notice", row[3])

    def test_guard8_a_SINGLE_pull_FREEZES_the_class(self):
        c = self.cand()
        ap, _ = doc_approve.approve(c, self.db, doc_store=self.docs, gate=self.allowed,
                                    now=self.now, mode="apply")
        self.assertIsNotNone(ap)
        # a later forgery verdict on the document
        _role_row(self.docs, run_id="r2", at="2026-11-05T21:00:00Z", role="Lyricist", outcome="forged")
        out = doc_approve.sweep(self.db, doc_store=self.docs, now=self.now + timedelta(hours=2))
        self.assertEqual([t.now for t in out], ["pulled"])
        self.assertTrue(self.freeze.exists(), "one reversal must freeze the class")
        self.assertFalse(doc_approve.gate_not_frozen(c, self.db).ok)

    def test_guard8_the_freeze_survives_a_marker_file_that_cannot_be_written(self):
        """QA #1800 finding 1 (Critical): the marker file was the ONLY record and a failed write was
        swallowed, so after a pull the next run could keep approving - which defeats the guard the whole
        arming condition rests on. The ledger row is written first and is authoritative, so a filesystem
        that refuses the marker still leaves the class frozen."""
        c = self.cand()
        doc_approve.approve(c, self.db, doc_store=self.docs, gate=self.allowed, now=self.now, mode="apply")
        _role_row(self.docs, run_id="r2", at="2026-11-05T21:00:00Z", role="Lyricist", outcome="forged")
        # a marker path that cannot be created: its parent is a FILE
        blocker = self.dir / "not-a-dir"
        blocker.write_text("x", encoding="utf-8")
        with mock.patch.object(doc_approve, "FREEZE_PATH", blocker / "doc-approve.frozen"):
            out = doc_approve.sweep(self.db, doc_store=self.docs, now=self.now + timedelta(hours=2))
            self.assertEqual([t.now for t in out], ["pulled"])
            self.assertFalse((blocker / "doc-approve.frozen").exists())
            # the class is STILL frozen, by the ledger row, and the failure is recorded
            self.assertTrue(doc_approve.frozen(self.db))
            self.assertFalse(doc_approve.gate_not_frozen(c, self.db).ok)
            self.assertIn("freeze_marker_failed",
                          [r[0] for r in self.db.execute("SELECT state FROM doc_approval_events")])
            # a DIFFERENT, still-verified document: the freeze alone must refuse it
            other = "11111111-2222-4333-8444-555555555555"
            d = sqlite3.connect(self.docs)
            d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict,"
                      " outcome, reason, account_hold, detail_json, version, intake_id) VALUES"
                      " ('r9','2026-11-05T20:00:00Z','beef',?,?,145833,'PLAUSIBLE','verified','because',0,"
                      " ?,'dv-4','145833:beef')", (other, "Lyricist", _R22_DETAIL))
            d.commit()
            d.close()
            p = sqlite3.connect(self.proof)
            p.execute("INSERT OR REPLACE INTO proof_intake (intake_id, user_id, subject,"
                      " candidate_request_ids_json, conversation_id, source, file_sha256, received_at, filed_by)"
                      " VALUES ('145833:beef',145833,'credit',?,'777','intercom','beef',"
                      "'2026-10-24T06:49:57Z','proof_intake')", (json.dumps([other]),))
            p.commit()
            p.close()
            c2 = doc_approve.Candidate(other, 145833, 12,
                                       tuple(doc_approve.verified_docs(self.docs, self.proof)[other]),
                                       "prof-1", ("Lyricist",))
            ap, answers = doc_approve.approve(c2, self.db, doc_store=self.docs,
                                              gate=self.allowed, now=self.now + timedelta(hours=3),
                                              mode="apply")
            self.assertIsNone(ap, "a pull whose marker failed must still stop the next approval")
            # the freeze gate refuses this candidate on its own (the claimant gate also refuses it now,
            # because the pull made the account unclean - both are correct, and both fail closed)
            self.assertFalse(doc_approve.gate_not_frozen(c2, self.db).ok)

    def test_guard8_the_audit_row_and_the_approval_are_ONE_transaction(self):
        """QA #1800 finding 4: the approval committed before its audit row, so an audit failure left an
        UNAUDITED approval - and "100% audit for 14 days" is exactly the property that must not have a
        gap. The audit insert now runs inside the approval's own transaction, so a failure rolls the
        approval back with it."""
        with mock.patch.object(doc_approve, "_audit_row", side_effect=sqlite3.OperationalError("disk I/O")):
            with self.assertRaises(sqlite3.OperationalError):
                doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                                    now=self.now, mode="apply")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0,
                         "an approval whose audit row could not be written must not exist")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approval_audit").fetchone()[0], 0)

    def test_guard8_a_ledger_that_predates_profile_id_is_MIGRATED(self):
        """QA #1800 finding 2: `doc_approvals` shipped without `profile_id`, and CREATE TABLE IF NOT
        EXISTS does not add a column to an existing table - so on a real ledger every new query and
        write naming it failed. ensure_schema adds it."""
        old = sqlite3.connect(self.dir / "old-ledger.sqlite")
        old.executescript("""
            CREATE TABLE doc_approvals (id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE,
              user_id INTEGER NOT NULL, intake_id TEXT NOT NULL, proof_id TEXT NOT NULL, ref TEXT NOT NULL,
              popularity INTEGER, tier TEXT NOT NULL, approved_at TEXT NOT NULL, expires_at TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'provisional', state_at TEXT, reason TEXT);""")
        old.commit()
        doc_approve.ensure_schema(old)
        cols = {str(r[1]) for r in old.execute("PRAGMA table_info(doc_approvals)")}
        self.assertIn("profile_id", cols)
        # and the per-profile cap query works against the migrated table
        self.assertTrue(doc_approve.gate_profile_cap(self.cand(), old, self.now).ok)
        old.close()

    def test_guard8_a_FROZEN_class_approves_nothing(self):
        doc_approve.freeze(self.db, reason="a reversal", now=self.now)
        ap, answers = doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                                          now=self.now, mode="apply")
        self.assertIsNone(ap)
        self.assertEqual(answers[-1].name, "not_frozen")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0)

    def test_guard8_the_audit_window_is_fourteen_days_from_the_first_approval(self):
        open_, why = doc_approve.audit_window(self.db, self.now)
        self.assertFalse(open_)
        self.assertIn("has not opened", why)
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                            now=self.now, mode="apply")
        open_, why = doc_approve.audit_window(self.db, self.now + timedelta(days=1))
        self.assertTrue(open_, why)
        self.assertIn("1 rows written", why)
        open_, why = doc_approve.audit_window(self.db, self.now + timedelta(days=15))
        self.assertFalse(open_)
        self.assertIn("closed", why)

    # ── guard 5: the registered scope name ──────────────────────────────────
    def test_guard5_the_tier_line_also_refuses_a_big_ARTIST_on_a_small_track(self):
        """R22's tier line is "popularity 1-59, artist < 90" - the decider's own big-track rule.

        A pop-20 track by a 95-popularity artist is a T2/T3 case wearing a small track's number, so
        the caller's `big_track` (which carries the artist bound) is refused even though the
        popularity alone would pass.
        """
        g = doc_approve.gate_tier(self.cand(popularity=20, big_track=True))
        self.assertFalse(g.ok)
        self.assertIn("big-track", g.why)
        self.assertTrue(doc_approve.gate_tier(self.cand(popularity=20, big_track=False)).ok)

    def test_guard4_the_claimant_age_comes_from_CORE_createdAt_when_it_is_supplied(self):
        """R22a D2: "Claimant age must come from core createdAt, or count claimant_no_history."

        The ledger's first sighting is OUR clock, not the account's age: an account that has been on
        Muso for years but only reached this ledger yesterday would read as brand new. Core's own
        createdAt is the authority when the caller can supply it.
        """
        young = doc_approve.Candidate(self.RID, 145833, 12,
                                      tuple(doc_approve.verified_docs(self.docs, self.proof)[self.RID]),
                                      "prof-1", ("Lyricist",), False,
                                      (self.now - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        g = doc_approve.gate_claimant(young, self.db, self.now)
        self.assertFalse(g.ok, "3 days at core is below the 30-day floor, whatever our ledger says")
        self.assertIn("3d old at core", g.why)
        old = doc_approve.Candidate(self.RID, 145833, 12,
                                    tuple(doc_approve.verified_docs(self.docs, self.proof)[self.RID]),
                                    "prof-1", ("Lyricist",), False,
                                    (self.now - timedelta(days=400)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertTrue(doc_approve.gate_claimant(old, self.db, self.now).ok)

    def test_guard4_no_history_at_all_is_counted_as_claimant_no_history(self):
        """R22a D2's second half: when core's createdAt is not supplied and the ledger has never seen
        the account, the refusal is NAMED so a dry run can count it instead of it hiding inside a
        generic refusal."""
        stranger = doc_approve.Candidate(self.RID, 999999, 12,
                                         tuple(doc_approve.verified_docs(self.docs, self.proof)[self.RID]),
                                         "prof-1", ("Lyricist",))
        g = doc_approve.gate_claimant(stranger, self.db, self.now)
        self.assertFalse(g.ok)
        self.assertEqual(g.name, "claimant_no_history")

    def test_guard3_a_document_filed_for_TWO_accounts_is_refused(self):
        """R22a D3: one file is one person's evidence. The same sha256 filed under a second account is
        either a shared template (forged or recycled) or a mis-filing, and neither proves THIS person's
        credit. The check is on the sha across the whole proof store, because a second intake id is
        exactly what would hide the reuse."""
        c = self.cand()
        self.assertTrue(doc_approve.gate_doc_reuse(c, self.proof).ok)
        p = sqlite3.connect(self.proof)
        p.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                  " conversation_id, source, file_sha256, received_at, filed_by) VALUES"
                  " ('999999:a4205f34',999999,'credit','[]','777','intercom','a4205f34',"
                  "'2026-10-25T00:00:00Z','proof_intake')")
        p.commit()
        p.close()
        g = doc_approve.gate_doc_reuse(c, self.proof)
        self.assertFalse(g.ok)
        self.assertIn("999999", g.why)

    def test_the_dry_run_writes_NOTHING_and_splits_the_refusals_per_guard(self):
        """Fable R22a's arming condition: a 0-write pass over every document row with a per-guard split.

        The two questions are kept apart on purpose. The per-guard split excludes the cap gates (a
        50-user day cap would refuse nearly every row and say nothing about the row), and the caps are
        reported separately as the plan they produce.
        """
        rows = {self.RID.lower(): {"user_id": 145833, "profile_id": "prof-1", "popularity": 12,
                                   "big_track": False, "roles": ("Lyricist",), "created_at": None,
                                   "account_created_at": self.core_age()}}
        before = (self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0],
                  self.db.execute("SELECT COUNT(*) FROM doc_approval_events").fetchone()[0],
                  self.db.execute("SELECT COUNT(*) FROM doc_approval_audit").fetchone()[0])
        res = doc_approve.dry_run(self.db, doc_store=self.docs, proof_store=self.proof,
                                  gate=self.allowed, now=self.now, rows=rows)
        after = (self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0],
                 self.db.execute("SELECT COUNT(*) FROM doc_approval_events").fetchone()[0],
                 self.db.execute("SELECT COUNT(*) FROM doc_approval_audit").fetchone()[0])
        self.assertEqual(before, after, "a dry run writes no row, no event and no audit row")
        self.assertFalse(self.freeze.exists(), "a dry run never freezes the class")
        self.assertEqual(res["rows"], 1)
        self.assertEqual(res["per_guard"], {"would_approve": 1})
        self.assertEqual((res["would_users"], res["would_requests"]), (1, 1))

    def test_the_dry_run_reads_the_LEDGERS_comma_joined_roles_not_json(self):
        """QA #1800 r11 finding 2: `record_decision` persists claimed_roles COMMA-JOINED.

        Parsing it as JSON raised ValueError, became (), and every row was then falsely counted as a
        `role` refusal - the arming dry run would have reported zero eligible rows on real data.
        """
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "credit_review_cli", Path(__file__).resolve().parents[1] / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id,"
                        " claimed_roles, popularity, big_track, decision, reason, mode)"
                        " VALUES ('r','2026-10-01T00:00:00Z',?,?,?,'Lyricist,Composer',12,0,'support','x',"
                        " 'apply')",
                        (self.RID, "prof-1", 145833))
        self.db.commit()
        rows = cli._doc_dry_run_rows(self.db)
        self.assertEqual(rows[self.RID.lower()]["roles"], ("Lyricist", "Composer"),
                         "a comma-joined ledger value is two roles, not an unparseable blob")
        # the ledger has no core age; the CLI reads it from core (QA #1800 r18 finding 1)
        rows[self.RID.lower()]["account_created_at"] = self.core_age()
        res = doc_approve.dry_run(self.db, doc_store=self.docs, proof_store=self.proof,
                                  gate=self.allowed, now=self.now, rows=rows)
        self.assertEqual(res["per_guard"], {"would_approve": 1},
                         "the row is eligible; it is not a false `role` refusal")

    def test_the_dry_run_names_the_guard_that_refuses_and_counts_a_missing_ledger_row(self):
        rows = {self.RID.lower(): {"user_id": 145833, "profile_id": "prof-1", "popularity": 0,
                                   "big_track": False, "roles": ("Lyricist",), "created_at": None}}
        res = doc_approve.dry_run(self.db, doc_store=self.docs, proof_store=self.proof,
                                  gate=self.allowed, now=self.now, rows=rows)
        self.assertEqual(res["per_guard"], {"tier": 1}, "R22a D1: a zero is refused at the tier gate")
        self.assertEqual(res["would_approve"], 0)
        # a document whose request the ledger never decided is counted, never guessed at
        res2 = doc_approve.dry_run(self.db, doc_store=self.docs, proof_store=self.proof,
                                   gate=self.allowed, now=self.now, rows={})
        self.assertEqual(res2["per_guard"], {"no_ledger_row": 1})

    def test_guard5_the_scope_is_document_small_track_and_the_registry_key_matches(self):
        self.assertEqual(doc_approve.SCOPE, "document_small_track")
        self.assertEqual(decide.DOC_AUTOMATION, doc_approve.SCOPE,
                         "the registry key and the code's scope must be the same string")

    def test_guard5_the_registry_actually_CARRIES_the_scope_the_code_looks_up(self):
        """The two halves of the class's name, pinned to each other.

        `doc_class_approved` looks up `DOC_AUTOMATION` in the registry and refuses when the entry is
        absent - fail-closed, so a rename on ONE side does not approve anything wrongly, it makes the
        class DORMANT FOREVER while the registry row sits there as dead weight no code reads. That is
        a silent no-op, not a safe failure, and it is exactly what a rebase across a rename produces.
        """
        registry = json.loads((Path(__file__).resolve().parents[2]
                               / "policies" / "credit-approval-automation.json").read_text())
        self.assertIn(doc_approve.SCOPE, registry["automations"],
                      "the registry must carry the scope the code looks up, or the class is dormant")
        self.assertIs(registry["automations"][doc_approve.SCOPE].get("approved"), False,
                      "the class ships SHADOW: approved must be false until Fable's arming word")


class _CliFixture(_R22Fixture):
    """The R22 fixture plus the `credit-review.py` CLI, loaded the way the operator runs it.

    Shared by every QA round that has to exercise the ARMING MEASUREMENT (`doc-approvals --dry-run`)
    rather than the library, because the findings in those rounds were about the entrypoint: which
    store it read, which gate it built, and what it wrote on the way to reporting zero.
    """

    def setUp(self) -> None:
        super().setUp()
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "credit_review_cli", Path(__file__).resolve().parents[1] / "credit-review.py")
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)
        self._store_patch = mock.patch.object(decide, "DOC_STORE", self.docs)
        self._store_patch.start()
        self._proof_store_patch = mock.patch.object(decide, "DOC_PROOF_STORE", self.proof)
        self._proof_store_patch.start()
        # the CLI builds the same cached account gate apply builds; the live fraud-lens check is not
        # what these tests are about, so it is stubbed to an allow exactly as `self.allowed` is.
        from credit_review import account_gate
        self._gate_patch = mock.patch.object(account_gate, "Cached", return_value=self.allowed)
        self._gate_patch.start()
        # QA #1800 r18 finding 1: the claimant gate needs core's own `user.createdAt`, and the dry run
        # reads it from core. These tests are about the ledger and the doc store, so core is stubbed to
        # the same 60-day-old account `self.core_age()` gives the library fixtures.
        self._real_core_ages = self.cli._doc_dry_run_core_ages   # the pager itself, for its own test
        self._core_patch = mock.patch.object(self.cli, "_doc_dry_run_core_ages",
                                             side_effect=self._core_ages)
        self._core_patch.start()

    def _core_ages(self, _admin, rows: dict) -> dict:
        return {rid: self.core_age() for rid in rows}

    def tearDown(self) -> None:
        self._core_patch.stop()
        self._gate_patch.stop()
        self._proof_store_patch.stop()
        self._store_patch.stop()
        super().tearDown()

    def _dry_run(self, ledger=None, *, offline: bool = False) -> tuple[int, dict]:
        import argparse
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = self.cli.cmd_doc_approvals(argparse.Namespace(
                ledger=str(ledger or self.dir / "ledger.sqlite"), dry_run=True, pull=False,
                list=False, user=None, offline=offline))
        return rc, json.loads(buf.getvalue())

    def _decide_row(self, request_id: str, user_id: int, *, roles: str = "Lyricist",
                    popularity: int = 12, profile_id: str = "prof-1") -> None:
        self.db.execute(
            "INSERT INTO decisions (run_id, decided_at, request_id, profile_id, user_id, claimed_roles,"
            " popularity, big_track, decision, reason, mode) VALUES ('r','2026-10-01T00:00:00Z',?,?,?,?,?,0,"
            " 'support','x','apply')",
            (request_id, profile_id, user_id, roles, popularity))
        self.db.commit()


class DocApproveQaR13(_CliFixture):
    """QA #1800 round 13: one CAN-FAIL test per finding, at the boundary the finding named.

    r13 found the class's WRITE boundary and its ARMING MEASUREMENT both weaker than they read: a
    freeze could land between the gate and the write, and the dry run - the number d2 arms on -
    omitted the owner and hold inputs, started its cap plan from zero, and could report a clean zero
    off a ledger it could not read (or migrate that ledger while claiming to write nothing).
    """

    # ── finding 1 (Critical): the freeze is re-asked INSIDE the write transaction ──
    def test_r13_a_freeze_committed_between_evaluation_and_the_write_REFUSES(self):
        """The one-reversal stop condition had a window: `gate_not_frozen` runs during evaluation, so
        a concurrent `sweep()` could commit a pull and freeze the class before this worker's
        `BEGIN IMMEDIATE` - and the approval still committed. The freeze is now re-asked inside the
        write transaction, so the interleaving refuses instead of approving after auto-freeze."""
        real = doc_approve.doc_evidence
        calls = {"n": 0}

        def freeze_then_evidence(*a, **kw):
            # `evaluate` reads the evidence once itself; the SECOND read is `approve`'s, which happens
            # after every gate has passed and before `spend_slot` opens its transaction. That is the
            # exact interleaving: evaluation has already said yes, the write has not begun.
            calls["n"] += 1
            if calls["n"] == 2:
                doc_approve.freeze(self.db, reason="a concurrent pull", now=self.now)
            return real(*a, **kw)

        with mock.patch.object(doc_approve, "doc_evidence", side_effect=freeze_then_evidence):
            ap, answers = doc_approve.approve(self.cand(), self.db, doc_store=self.docs,
                                              gate=self.allowed, now=self.now, mode="apply")
        self.assertIsNone(ap, "a freeze that lands after evaluation must still stop the write")
        self.assertEqual(answers[-1].name, "not_frozen")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approval_audit").fetchone()[0], 0)

    def test_r13_spend_slot_itself_refuses_when_the_class_is_frozen(self):
        """The same guard at its narrowest: `spend_slot` is the write boundary, so it must refuse on
        its own even when every gate upstream said yes."""
        ap = doc_approve.Approval(self.RID, 145833, "145833:a4205f34", "sha", "ref", 12, "T1",
                                  "prof-1", {})
        doc_approve.freeze(self.db, reason="a reversal", now=self.now)
        spent, why = doc_approve.spend_slot(self.db, ap, now=self.now,
                                            expires=self.now + timedelta(days=7))
        self.assertFalse(spent)
        self.assertIn("not_frozen", why)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0], 0)

    # ── finding 2: the dry run asks the SAME owner and hold inputs apply asks ──
    def test_r13_the_dry_run_refuses_a_document_bound_to_TWO_accounts(self):
        """With `req_users=None`, `gate_one_request` skipped the cross-account check entirely, so a
        document bound to accounts A and B was reported `would_approve` although apply refuses it."""
        self._decide_row(self.RID, 145833)
        other = "11111111-2222-3333-4444-555555555555"
        self._decide_row(other, 999999)
        p = sqlite3.connect(self.proof)
        p.execute("UPDATE proof_intake SET candidate_request_ids_json = ?",
                  (json.dumps([self.RID, other]),))
        p.commit()
        p.close()
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        # QA #1800 r19 finding 2: the census unit is the (document, request) PAIR, so the second
        # binding is its own row. dv-4 judged only `self.RID`, so that row is refused `one_request`
        # (the binding spans two accounts, exactly as apply refuses it) and the unjudged binding is
        # counted at `dv4_verified` instead of vanishing with the filing.
        self.assertEqual(res["per_guard"], {"one_request": 1, "dv4_verified": 1},
                         "a cross-account binding is refused by the dry run, exactly as apply refuses it")
        self.assertEqual(res["would_approve"], 0)

    def test_r13_the_dry_run_refuses_a_document_filed_by_a_HELD_account(self):
        """An empty hold set bypassed `gate_no_hold`, so a document filed by a held account read as
        `would_approve`. The dry run now loads the same deny/hold policy apply loads."""
        self._decide_row(self.RID, 145833)
        policy = decide.Policy(deny_user_ids={145833}, deny_profile_ids=set(),
                               editorial_role_terms=())
        with mock.patch.object(decide.Policy, "load", return_value=policy):
            rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["per_guard"], {"no_hold": 1})
        self.assertEqual(res["would_approve"], 0)

    def test_r13_the_dry_run_still_approves_the_clean_row_with_the_new_inputs(self):
        """The two refusals above must not be bought by refusing everything: the clean row still
        passes with the owner and hold inputs wired in."""
        self._decide_row(self.RID, 145833)
        policy = decide.Policy(deny_user_ids=set(), deny_profile_ids=set(),
                               editorial_role_terms=())
        with mock.patch.object(decide.Policy, "load", return_value=policy):
            rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["per_guard"], {"would_approve": 1})
        self.assertEqual((res["would_users"], res["would_requests"]), (1, 1))

    # ── finding 3: the cap plan starts from TODAY'S ledger, not from zero ──
    def test_r13_the_cap_plan_counts_the_slots_ALREADY_SPENT_today(self):
        """With 49 users already approved today, the old plan reported 50 more users/requests while
        apply could admit exactly one. The plan now simulates today's ledger plus the planned slots."""
        for i in range(49):
            self.db.execute(
                "INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
                " popularity, tier, approved_at, expires_at, state) VALUES (?,?,?,?,?,?,?,?,?,?,"
                " 'provisional')",
                (f"spent-{i}", 900000 + i, f"spent-prof-{i}", "i", "p", "r", 12, "T1",
                 "2026-11-05T09:00:00Z", "2026-11-12T09:00:00Z"))
        self.db.commit()
        passed = [(f"req-{i}", 100000 + i, f"prof-{i}",
                   doc_approve.order_key(100000 + i, None, None, self.now)) for i in range(50)]
        res = doc_approve._plan_caps(self.db, self.now, passed)
        self.assertEqual(res["spent_users_today"], 49)
        self.assertEqual(res["spent_requests_today"], 49)
        self.assertEqual(res["would_users"], 1, "one fleet slot is left, not fifty")
        self.assertEqual(res["would_requests"], 1)
        self.assertEqual(res["rolled_to_tomorrow"], 49,
                         "the users past the fleet cap roll to tomorrow; they are not dropped")

    def test_r13_the_cap_plan_respects_the_PER_PROFILE_bound(self):
        """The old plan ignored profile ids entirely, so ten requests on one profile read as ten
        approvals when apply admits at most PER_PROFILE_DAILY_MAX."""
        passed = [(f"req-{i}", 100000 + i, "prof-shared",
                   doc_approve.order_key(100000 + i, None, None, self.now)) for i in range(15)]
        res = doc_approve._plan_caps(self.db, self.now, passed)
        self.assertEqual(res["would_requests"], doc_approve.PER_PROFILE_DAILY_MAX)
        self.assertEqual(res["rolled_to_tomorrow"], 15 - doc_approve.PER_PROFILE_DAILY_MAX)

    def test_r13_the_cap_plan_respects_the_PER_USER_bound(self):
        passed = [(f"req-{i}", 145833, f"prof-{i}",
                   doc_approve.order_key(145833, None, None, self.now)) for i in range(8)]
        res = doc_approve._plan_caps(self.db, self.now, passed)
        self.assertEqual(res["would_requests"], doc_approve.PER_USER_DAILY_MAX)
        self.assertEqual(res["would_users"], 1)

    # ── finding 4: an unreadable ledger is an ERROR, never a clean zero ──
    def test_r13_an_OLDER_ledger_makes_the_dry_run_FAIL_LOUD_not_report_zero(self):
        """`_doc_dry_run_rows` swallowed every query error and returned `{}`, so a ledger without
        `claimed_roles` classified every document as `no_ledger_row`, printed a successful 0-eligible
        result and exited 0 - a silently false arming measurement."""
        old = self.dir / "old-ledger.sqlite"
        o = sqlite3.connect(old)
        o.executescript("""
            CREATE TABLE doc_approvals (id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE,
              user_id INTEGER NOT NULL, profile_id TEXT, intake_id TEXT NOT NULL, proof_id TEXT NOT NULL,
              ref TEXT NOT NULL, popularity INTEGER, tier TEXT NOT NULL, approved_at TEXT NOT NULL,
              expires_at TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'provisional', state_at TEXT, reason TEXT);
            CREATE TABLE doc_approval_events (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, request_id TEXT,
              user_id INTEGER, intake_id TEXT, state TEXT, gate TEXT, reason TEXT);
            CREATE TABLE doc_approval_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, request_id TEXT,
              user_id INTEGER, intake_id TEXT, proof_id TEXT, ref TEXT, popularity INTEGER, tier TEXT,
              profile_id TEXT, evidence_json TEXT);
            CREATE TABLE doc_approval_freeze (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, reason TEXT);
            CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, decided_at TEXT,
              request_id TEXT, profile_id TEXT, user_id INTEGER, popularity INTEGER, big_track INTEGER,
              decision TEXT, reason TEXT, mode TEXT);""")
        o.commit()
        o.close()
        rc, res = self._dry_run(ledger=old)
        self.assertEqual(rc, 1, "an unreadable ledger must not exit 0")
        self.assertIn("could not be read", res["unreadable"])
        self.assertEqual(res["would_approve"], 0)

    # ── finding 5: the dry run does not MIGRATE the ledger ──
    @staticmethod
    def _db_state(path):
        """The WHOLE database state a dry run must leave untouched: every table, every column, every
        index and trigger, plus the file's own existence and size.

        QA #1800 r14 finding 1: the earlier version of this test only looked at `doc_approvals` and
        two table names, so it passed while `Ledger.__init__` was still creating the file and five
        review-schema tables. A 0-write claim has to be checked against the whole file, not the part
        the finding happened to name.
        """
        p = Path(path)
        if not p.exists():
            return {"exists": False}
        c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
        try:
            objs = sorted((str(t), str(n)) for t, n in c.execute(
                "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"))
            cols = {t: sorted(str(r[1]) for r in c.execute(f"PRAGMA table_info('{t}')"))
                    for t, _ in objs if t == "table"}
        finally:
            c.close()
        return {"exists": True, "objects": objs, "columns": cols, "size": p.stat().st_size}

    def test_r13_the_dry_run_does_NOT_migrate_an_old_ledger(self):
        """`ensure_schema` ran before the `--dry-run` branch, so the promised 0-write arming pass ran
        `ALTER TABLE doc_approvals ADD COLUMN profile_id` (and created the audit/freeze tables) on a
        production ledger. The dry run now refuses an unmigrated ledger and writes nothing."""
        old = self.dir / "old-ledger.sqlite"
        o = sqlite3.connect(old)
        o.executescript("""
            CREATE TABLE doc_approvals (id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE,
              user_id INTEGER NOT NULL, intake_id TEXT NOT NULL, proof_id TEXT NOT NULL, ref TEXT NOT NULL,
              popularity INTEGER, tier TEXT NOT NULL, approved_at TEXT NOT NULL, expires_at TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'provisional', state_at TEXT, reason TEXT);""")
        o.commit()
        o.close()
        before = self._db_state(old)
        rc, res = self._dry_run(ledger=old)
        self.assertEqual(rc, 1)
        self.assertIn("profile_id", res["unreadable"])
        self.assertEqual(self._db_state(old), before,
                         "a dry run must leave the ENTIRE ledger byte-identical: no ALTER, no CREATE")

    def test_r14_the_dry_run_does_NOT_create_a_MISSING_ledger(self):
        """QA #1800 r14 finding 1: `Ledger(args.ledger)` ran before the dry-run branch, and its
        constructor mkdirs the parent and runs `executescript(SCHEMA)`. A dry run against a path that
        did not exist therefore CREATED the file and five review-schema tables, then reported
        unreadable - the arming measurement mutated production state before saying anything."""
        missing = self.dir / "nested" / "never-created.sqlite"
        self.assertFalse(missing.exists())
        rc, res = self._dry_run(ledger=missing)
        self.assertEqual(rc, 1)
        self.assertIn("does not exist", res["unreadable"])
        self.assertFalse(missing.exists(), "a dry run must never create the ledger file")
        self.assertFalse(missing.parent.exists(), "a dry run must never create the ledger's directory")

    def test_r14_the_dry_run_leaves_a_MIGRATED_ledger_byte_identical(self):
        """The same whole-file check on the happy path: a ledger that IS ready must come out of a dry
        run with the same objects, columns and size it went in with."""
        self._decide_row(self.RID, 145833)
        before = self._db_state(self.dir / "ledger.sqlite")
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["per_guard"], {"would_approve": 1})
        self.assertEqual(self._db_state(self.dir / "ledger.sqlite"), before,
                         "a dry run must not write the ledger it measures")

    def test_r13_schema_ready_is_READ_ONLY_and_names_what_is_missing(self):
        self.assertEqual(doc_approve.schema_ready(self.db), "")
        old = sqlite3.connect(self.dir / "bare.sqlite")
        self.assertIn("no doc_approvals table", doc_approve.schema_ready(old))
        self.assertEqual(
            {str(r[0]) for r in old.execute("SELECT name FROM sqlite_master WHERE type='table'")},
            set(), "schema_ready creates nothing")
        old.close()


class DocApproveQaR15(_R22Fixture):
    """QA #1800 r15 finding 1: a confidence is not an identity.

    `gate_forensics` claimed the run EXTRACTED the issuer and signatory, but only checked that both
    confidences were above zero. A `detail_json` with `confidence: 0.9` and a blank `name` therefore
    passed, and a document nobody was named on could reach approval. These cases go through
    `evaluate()`, not the gate alone, because the finding is about the class admitting the document.
    """

    def _evaluate(self):
        return doc_approve.evaluate(self.cand(), self.db, doc_store=self.docs, proof_store=self.proof,
                                    gate=self.allowed, now=self.now,
                                    req_users={self.RID: 145833})

    def test_r15_a_blank_issuer_name_is_REFUSED_through_evaluate(self):
        self.rewrite_evidence(issuer_name="")
        verdict, answers = self._evaluate()
        self.assertFalse(verdict.ok)
        self.assertEqual(verdict.name, "forensics")
        self.assertIn("issuer", verdict.why)
        self.assertIn("confidence without an identity", verdict.why)

    def test_r15_a_blank_signatory_name_is_REFUSED_through_evaluate(self):
        self.rewrite_evidence(sign_name="   ")
        verdict, answers = self._evaluate()
        self.assertFalse(verdict.ok)
        self.assertEqual(verdict.name, "forensics")
        self.assertIn("signatory", verdict.why)

    def test_r15_a_blank_name_on_ONE_role_poisons_the_whole_document(self):
        """The merge is fail-closed like the h3 verdict and the cross-checks: one role's run naming
        nobody means the document was not fully extracted, and another role cannot rescue it."""
        _role_row(self.docs, run_id="r1", at="2026-10-31T12:26:32Z", role="Composer", outcome="verified")
        d = sqlite3.connect(self.docs)
        detail = json.loads(_R22_DETAIL)
        detail["issuer"]["name"] = ""
        d.execute("UPDATE dv_outcomes SET detail_json = ? WHERE role = 'Composer'", (json.dumps(detail),))
        d.commit()
        d.close()
        ev = doc_approve.doc_evidence(self.docs, "145833:a4205f34", self.RID)
        self.assertTrue(ev.readable)
        self.assertEqual(ev.issuer_name, "", "a blank name on any role must blank the merged name")
        self.assertEqual(ev.signatory_name, "A Person", "the untouched identity still merges")
        verdict, _ = self._evaluate()
        self.assertFalse(verdict.ok)
        self.assertEqual(verdict.name, "forensics")

    def test_r15_the_named_issuer_and_signatory_still_PASS(self):
        """The refusal must not be bought by refusing everything: the fixture's named document still
        clears every gate."""
        ev = doc_approve.doc_evidence(self.docs, "145833:a4205f34", self.RID)
        self.assertEqual((ev.issuer_name, ev.signatory_name), ("Label Ltd", "A Person"))
        verdict, answers = self._evaluate()
        self.assertTrue(verdict.ok, f"{verdict.name}: {verdict.why}")


class DocApproveQaR16(_CliFixture):
    """QA #1800 r16: the configured proof store never reached the gate, and the dry run reported a
    gate's FAMILY instead of the answer it gave.

    Both are measurement bugs with a real consequence: the first approves a reused document after
    arming, the second hides the population R22a D2 requires to be counted by name.
    """

    def _file_sha(self) -> str:
        """The sha256 the fixture's document actually carries - `Doc.proof_id` comes from the proof
        store's `file_sha256`, not from `dv_outcomes.proof_id`."""
        p = sqlite3.connect(self.proof)
        try:
            return str(p.execute("SELECT file_sha256 FROM proof_intake").fetchone()[0])
        finally:
            p.close()

    def _configured_proof_store(self, *, other_user: int = 999999) -> Path:
        """A proof store where the SAME file sha256 is also filed for another account."""
        other = self.dir / "configured-proof.sqlite"
        p = sqlite3.connect(other)
        p.executescript("""
            CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
              subject TEXT NOT NULL, candidate_request_ids_json TEXT NOT NULL DEFAULT '[]',
              conversation_id TEXT NOT NULL, source TEXT NOT NULL, file_sha256 TEXT NOT NULL,
              file_path TEXT, mime TEXT, bytes INTEGER, received_at TEXT NOT NULL,
              filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT,
              UNIQUE (user_id, file_sha256));""")
        p.execute("INSERT INTO proof_intake (intake_id, user_id, subject, conversation_id, source,"
                  " file_sha256, received_at, filed_by) VALUES (?,?,'credit','888','intercom',?,"
                  "'2026-10-25T00:00:00Z','proof_intake')",
                  (f"{other_user}:b", other_user, self._file_sha()))
        p.commit()
        p.close()
        return other

    def test_r16_the_plan_checks_the_CONFIGURED_proof_store_not_the_default(self):
        """`plan()` accepted `proof_store` and dropped it, so `gate_doc_reuse` read the DEFAULT store.
        With `CREDIT_PROOF_STORE` pointing at a store where the same file sha256 belongs to two
        accounts, the gate refused and the plan approved - and the apply recheck read the default
        store too, so after arming the reused document went through."""
        other = self._configured_proof_store()
        # The default store knows only this account, so the same candidate is clean there.
        ap, _ = doc_approve.plan(self.cand(), self.db, doc_store=self.docs, proof_store=self.proof,
                                 gate=self.allowed, now=self.now, req_users={self.RID: 145833})
        self.assertIsNotNone(ap, "the fixture's own proof store must not refuse this candidate")
        # The configured store knows a second account filed the same bytes.
        ap2, answers = doc_approve.plan(self.cand(), self.db, doc_store=self.docs, proof_store=other,
                                        gate=self.allowed, now=self.now,
                                        req_users={self.RID: 145833})
        self.assertIsNone(ap2, "a reused file sha256 in the CONFIGURED store must refuse the plan")
        self.assertEqual(answers[-1].name, "doc_reuse")
        self.assertIn("999999", answers[-1].why)

    def test_r16_the_apply_recheck_also_uses_the_CONFIGURED_proof_store(self):
        """The same store has to reach `approve()`, or the write recheck disagrees with the plan."""
        other = self._configured_proof_store()
        got, answers = doc_approve.approve(self.cand(), self.db, doc_store=self.docs,
                                           proof_store=other, gate=self.allowed, now=self.now,
                                           mode="apply")
        self.assertIsNone(got)
        self.assertEqual(answers[-1].name, "doc_reuse")
        rows = self.db.execute("SELECT COUNT(*) FROM doc_approvals").fetchone()[0]
        self.assertEqual(rows, 0, "a refused candidate must write no approval")

    def _dry_run_rows(self, db=None, **kw) -> dict:
        """The library dry run over one hand-built ledger row.

        `rows` is a parameter of `dry_run`, so a candidate can be measured without a `decisions` row
        existing - which is exactly the population `claimant_no_history` names, and the only way to
        reach it: the CLI builds its rows FROM `decisions`, so a request with no row there is
        `no_ledger_row` before the claimant gate is ever asked.
        """
        row = {"user_id": 145833, "profile_id": "prof-1", "popularity": 12, "big_track": False,
               "roles": ("Lyricist",), "created_at": "2026-10-01T00:00:00Z",
               "account_created_at": self.core_age()}
        row.update(kw)
        return doc_approve.dry_run(db or self.db, doc_store=self.docs, proof_store=self.proof,
                                   gate=self.allowed, now=self.now, rows={self.RID: row},
                                   req_users={self.RID: row["user_id"]})

    def _empty_ledger(self) -> sqlite3.Connection:
        """A migrated ledger with NO `decisions` row: the fixture's claimant has 60 days of history in
        setUp and `decisions` is append-only, so a second ledger is the only way to stand in the
        population `claimant_no_history` names without also breaking the document's owner binding."""
        db = sqlite3.connect(self.dir / "no-history.sqlite")
        decide.ensure_schema(db)
        doc_approve.ensure_schema(db)
        return db

    def test_r16_the_dry_run_counts_a_NO_HISTORY_candidate_by_name(self):
        """`_row_verdict` returned the tuple label, so `gate_claimant`'s `claimant_no_history` answer
        was reported as plain `claimant`. R22a D2 requires that population to be counted BY NAME.

        Since QA #1800 r18 finding 1 the gate answers `claimant_no_history` for a MISSING core age
        rather than for a missing ledger row, so that is the input this case supplies.
        """
        db = self._empty_ledger()
        try:
            res = self._dry_run_rows(db, account_created_at="")
        finally:
            db.close()
        self.assertEqual(res["per_guard"], {"claimant_no_history": 1},
                         "the no-history population must be counted by the name the gate answered")
        self.assertEqual(res["would_approve"], 0)

    def test_r16_a_clean_claimant_is_still_counted_as_would_approve(self):
        """The naming fix must not rename a passing row: a claimant with 35 days of history still
        approves, and the plan still counts it."""
        self._decide_row(self.RID, 145833)
        res = self._dry_run_rows()
        self.assertEqual(res["per_guard"], {"would_approve": 1})
        self.assertEqual((res["would_users"], res["would_requests"]), (1, 1))


class DocApproveQaR17(_CliFixture):
    """QA #1800 r17: the arming measurement only saw the documents that had ALREADY verified.

    `dry_run` started from `verified_docs()`, which is the WRITE's view - it drops every document whose
    newest dv-4 run is contradicted or unverifiable, and every filing that never got a run at all. So
    the number d2 arms on was a pass over the rows that were already fine, reported as a pass over the
    backlog: a real queue of unverified documents produced `rows: 0` and no `dv4_verified` refusal.
    """

    def _file_without_a_run(self, intake_id: str, request_id: str, user_id: int = 145833) -> None:
        """A credit filing in the proof store that the doc-verify store has never judged."""
        p = sqlite3.connect(self.proof)
        p.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                  " conversation_id, source, file_sha256, received_at, filed_by)"
                  " VALUES (?,?,'credit',?,'777','intercom',?,'2026-10-24T06:49:57Z','proof_intake')",
                  (intake_id, user_id, json.dumps([request_id]), f"sha-{intake_id}"))
        p.commit()
        p.close()

    def test_r17_a_CONTRADICTED_latest_verdict_is_counted_at_dv4_verified(self):
        """The document is filed and judged - just not verified. It must appear in the measurement."""
        _role_row(self.docs, run_id="r2", at="2026-11-01T00:00:00Z", role="Lyricist",
                  outcome="contradicted")
        self._decide_row(self.RID, 145833)
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["rows"], 1, "the contradicted document is still a document")
        self.assertEqual(res["per_guard"], {"dv4_verified": 1},
                         "an unverified document is refused at the gate that refuses it, not dropped")
        self.assertEqual(res["would_approve"], 0)

    def test_r17_a_filing_with_NO_dv4_run_is_counted_at_dv4_verified(self):
        """A filing the verifier never reached is the population most likely to be waiting."""
        rid = "9d1c0f7e-1111-4222-8333-444455556666"
        self._file_without_a_run("145833:neverrun", rid)
        self._decide_row(rid, 145833)
        self._decide_row(self.RID, 145833)
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["rows"], 2, "a filing with no run is still a filed document")
        self.assertEqual(res["per_guard"], {"would_approve": 1, "dv4_verified": 1},
                         "the never-run filing is counted at the gate that refuses it, beside the "
                         "verified row the write would approve")
        self.assertEqual(res["would_approve"], 1)

    def test_r17_the_clean_row_is_still_measured_once_and_approves(self):
        """The control: widening the universe must not double-count or refuse the verified row."""
        self._decide_row(self.RID, 145833)
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["rows"], 1)
        self.assertEqual(res["per_guard"], {"would_approve": 1})
        self.assertEqual((res["would_users"], res["would_requests"]), (1, 1))

    def test_r17_a_verified_document_beside_a_NEWER_unverified_one_is_measured_as_the_write_picks_it(self):
        """`plan()`/`approve()` pick the newest VERIFIED document; the measurement must agree.

        Counting the request at `dv4_verified` because a newer unverified document also names it would
        report a refusal the write never makes - the mirror image of the bug this round is about.
        """
        _role_row(self.docs, run_id="r2", at="2026-11-01T00:00:00Z", role="Lyricist",
                  outcome="contradicted")
        # a SECOND, older-but-verified document for the same request, filed under another intake
        d = sqlite3.connect(self.docs)
        d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict,"
                  " outcome, reason, account_hold, detail_json, version, intake_id)"
                  " VALUES ('r3','2026-10-20T00:00:00Z','sha',?,?,145833,'PLAUSIBLE','verified','because',"
                  " 0,?,'dv-4','145833:older')",
                  (self.RID, "Lyricist", _R22_DETAIL))
        d.commit()
        d.close()
        # the older document's own filing, so `gate_one_request` can bind it to this request
        p = sqlite3.connect(self.proof)
        p.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                  " conversation_id, source, file_sha256, received_at, filed_by)"
                  " VALUES ('145833:older',145833,'credit',?,'777','intercom','sha-older',"
                  " '2026-10-20T00:00:00Z','proof_intake')", (json.dumps([self.RID]),))
        p.commit()
        p.close()
        self._decide_row(self.RID, 145833)
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["per_guard"], {"would_approve": 1},
                         "the write would approve on the verified document, so the measurement must too")


class DocApproveQaR18(_CliFixture):
    """QA #1800 r18: the claimant age must come from core, and the audit window from AUDITED rows.

    Two findings, both about a measurement that looked complete while measuring the wrong thing: the
    ledger's first sighting standing in for the account's age, and a pre-audit approval starting the
    14-day clock before the class had audited anything.
    """

    def test_r18_the_dry_run_reads_core_for_the_account_age(self):
        """The measurement matches apply only because it asks core, exactly as `decide.run()` does."""
        self._decide_row(self.RID, 145833)
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["per_guard"], {"would_approve": 1})

    def test_r18_OFFLINE_reports_every_row_as_claimant_no_history(self):
        """Without core there is no account age, and R22a D2 says that is `claimant_no_history`.

        This is the honest answer, not a pass: the ledger's first sighting is OUR clock, and an
        account created five days ago whose first `decisions` row is forty days old would otherwise
        pass a 30-day floor it never earned.
        """
        self._decide_row(self.RID, 145833)
        rc, res = self._dry_run(offline=True)
        self.assertEqual(rc, 0)
        self.assertEqual(res["per_guard"], {"claimant_no_history": 1})
        self.assertEqual(res["would_approve"], 0)

    def test_r18_a_MIGRATED_ledger_opens_the_audit_window_at_the_first_AUDITED_approval(self):
        """A pre-audit approval must not start the 14-day clock.

        On a migrated ledger whose oldest `doc_approvals` row is 15 days old, anchoring to that row
        reported the window CLOSED the moment the class was armed - the audit would have been declared
        over before it began. The window is about the rows this class audits.
        """
        old = (self.now - timedelta(days=15)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.db.execute(
            "INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
            " popularity, tier, approved_at, expires_at, state)"
            " VALUES ('pre-audit','145833','prof-1','i','s','r',12,'T0',?,?,'confirmed')",
            (old, (self.now + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")))
        self.db.commit()
        open_, why = doc_approve.audit_window(self.db, self.now)
        self.assertFalse(open_, "a pre-audit row is not an audited approval")
        self.assertIn("no AUDITED approval yet", why)
        # the first approval this class actually audits opens the window, and it runs 14 days from then
        self.assertIsNotNone(doc_approve.approve(self.cand(), self.db, doc_store=self.docs,
                                                 gate=self.allowed, now=self.now, mode="apply"))
        open_, why = doc_approve.audit_window(self.db, self.now + timedelta(days=1))
        self.assertTrue(open_, why)
        self.assertIn("1 rows written", why)
        open_, why = doc_approve.audit_window(self.db, self.now + timedelta(days=15))
        self.assertFalse(open_)
        self.assertIn("closed", why)

    def test_r18_an_EIGHT_day_old_pre_audit_row_does_not_shorten_the_window(self):
        """The 8-day case QA named: it used to leave six days of a fourteen-day audit."""
        old = (self.now - timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.db.execute(
            "INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id, ref,"
            " popularity, tier, approved_at, expires_at, state)"
            " VALUES ('pre-audit','145833','prof-1','i','s','r',12,'T0',?,?,'confirmed')",
            (old, (self.now + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")))
        self.db.commit()
        doc_approve.approve(self.cand(), self.db, doc_store=self.docs, gate=self.allowed,
                            now=self.now, mode="apply")
        open_, why = doc_approve.audit_window(self.db, self.now + timedelta(days=13))
        self.assertTrue(open_, f"13 days in, the window still has a day: {why}")
        self.assertIn("1d left", why)


class DocApproveQaR19(_CliFixture):
    """QA #1800 r19: the census must not stop at a page cap, and must not skip a half-judged filing."""

    def test_r19_a_PARTIALLY_judged_filing_counts_its_unjudged_binding(self):
        """One filing bound to A and B, dv-4 judged only A.

        The census de-duplicated by INTAKE, so the filing was skipped whole and B vanished instead of
        being counted at `dv4_verified`. The unit is the (document, request) pair, which is what a
        verdict is.
        """
        other = "11111111-2222-3333-4444-555555555555"
        self._decide_row(self.RID, 145833)
        self._decide_row(other, 145833)
        p = sqlite3.connect(self.proof)
        p.execute("UPDATE proof_intake SET candidate_request_ids_json = ?",
                  (json.dumps([self.RID, other]),))
        p.commit()
        p.close()
        rc, res = self._dry_run()
        self.assertEqual(rc, 0)
        self.assertEqual(res["rows"], 2, "both bindings are filed documents, so both are measured")
        self.assertEqual(res["per_guard"], {"would_approve": 1, "dv4_verified": 1},
                         "the judged binding approves; the unjudged one is counted, not dropped")

    def test_r19_the_core_age_read_pages_PAST_the_old_40_page_cap(self):
        """`held_rows` stopped after 40 x 200 = 8,000, so a document-backed row beyond that measured
        as `claimant_no_history` even though core had its `createdAt` - understating `would_approve`
        on exactly the backlog this class exists for."""
        target = "99999999-8888-7777-6666-555555555555"
        filler = [{"id": f"filler-{i}", "user": {"createdAt": "2026-01-01T00:00:00Z"}}
                  for i in range(8050)]
        rows = [{"id": target, "user": {"createdAt": "2026-01-01T00:00:00Z"}}]
        population = filler + rows          # the target sits on page 41, past the old cap

        class _Paged:
            def __init__(self, items):
                self.items = items
                self.pages = []

            def get(self, path, params=None):
                params = dict(params or {})
                self.pages.append(params.get("page"))
                page, size = int(params.get("page", 1)), int(params.get("limit", 200))
                start = (page - 1) * size
                return {"items": self.items[start:start + size]}

        admin = _Paged(population)
        ages = self._real_core_ages(admin, {target: {}})
        self.assertEqual(ages, {target: "2026-01-01T00:00:00Z"},
                         "the age is read even though the row is past the old 40-page cap")
        self.assertIn(41, admin.pages, "the pager went past page 40")

    def test_r20_hitting_the_pager_ceiling_REFUSES_instead_of_reporting_a_partial_census(self):
        """QA #1800 r20: the pager fixed the 8,000-row limit but still RETURNED the partial map and
        exited 0, so a row past the ceiling measured as `claimant_no_history` and the census printed
        as complete. A measurement that could not finish is not a measurement."""
        target = "99999999-8888-7777-6666-555555555555"
        population = [{"id": f"filler-{i}", "user": {"createdAt": "2026-01-01T00:00:00Z"}}
                      for i in range(600)]

        class _Paged:
            def get(self, path, params=None):
                params = dict(params or {})
                page, size = int(params.get("page", 1)), int(params.get("limit", 200))
                start = (page - 1) * size
                return {"items": population[start:start + size]}

        with mock.patch.object(self.cli, "_CORE_AGE_MAX_PAGES", 2):
            with self.assertRaises(self.cli.CoreCensusIncomplete) as caught:
                self._real_core_ages(_Paged(), {target: {}})
        self.assertIn("INCOMPLETE", str(caught.exception))

    def test_r20_the_CLI_exits_NON_ZERO_when_the_census_cannot_finish(self):
        """The refusal has to reach the operator as a non-zero exit, not a printed partial map."""
        self._decide_row(self.RID, 145833)
        with mock.patch.object(self.cli, "_doc_dry_run_core_ages",
                               side_effect=self.cli.CoreCensusIncomplete("the census is INCOMPLETE")):
            rc, res = self._dry_run()
        self.assertEqual(rc, 1, "an incomplete census is a refusal, not a successful measurement")
        self.assertIn("INCOMPLETE", res["unreadable"])


if __name__ == "__main__":
    warnings.filterwarnings("ignore", category=ResourceWarning)
    unittest.main(verbosity=1, warnings="")
