#!/usr/bin/env python3
"""Unit tests for scripts/credit_review/decide.py (credit-trust-decide,
trust-yet-verify; captain 2026-10-15 ~22:12Z).

Stdlib unittest, no network: the admin API, the judge and the write path are
faked (fixtures shared with test_credit_review.py). Run:
    python3 scripts/tests/test_credit_trust_decide.py
"""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import dataclasses
from datetime import timedelta
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock
import warnings
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import test_credit_review as T  # noqa: E402  (FakeAdmin, request(), raw(), PROFILES, TRACKS, NOW)
from credit_review import decide  # noqa: E402
from credit_review import verify_notify as _vn_r5  # noqa: E402
_vn_r5.PRESENTED_LOOKUP = lambda ids: {}  # r5: presented profile ids never come from the replica in tests
from credit_review.judge import JudgeResult  # noqa: E402
from credit_review.ledger import Ledger  # noqa: E402

PID_CLAIMANT_A = "ff7a7b1c-0000-4000-8000-000000000015"
PROFILES = {**T.PROFILES,
            PID_CLAIMANT_A: {"name": "Claimant A", "rawProfiles": [{"id": "TJ", "source": "tidal"}], "knownAsNames": []}}
TRACKS = {**T.TRACKS, "zero": T.track(0), "small": T.track(20), "nopop": T.track(None), "mid": T.track(40),
          "artless": T.track(20, artists=("art-unreadable",)), "starry": T.track(20, artists=(T.ART_STAR,)),
          "artnopop": T.track(20, artists=("art-nopop",)),
          "art404": T.track(20, artists=("art-deleted",)), "flaky": T.track(20), "p12a": T.track(12), "p12b": T.track(12), "p12c": T.track(12)}
PROFILES["art-nopop"] = {"name": "No Pop Artist", "rawProfiles": []}


def req(rid, *, uid=500, pid=T.PID_GOOD, track="small", roles=("Mixing",), vd_rules=None, errors=None, **kw):
    # The row's own stored spotifyPopularity follows the catalog track, as on prod
    # (core-backend's agent guard reads the STORED value).
    kw.setdefault("pop", (TRACKS.get(track) or {}).get("popularity", 20))
    r = T.request(rid, pid=pid, track=track, roles=roles, status="unverified", approved=False, risk=40, **kw)
    r["userId"] = uid
    r["verificationData"]["rule_risk_percent"] = dict(vd_rules or {})
    if errors:
        r["verificationData"]["rule_errors"] = errors
    return r


def anchored(r):
    """E1 (Fable review-audit-1021): a positive anchor for the paid provisional arm."""
    r["verificationData"]["is_approved"] = True
    return r


def uuid_of(n):
    return f"00000000-0000-4000-8000-{n:012d}"


class FakeJudge:
    def __init__(self, result=None, raises=None):
        self.result, self.raises, self.calls = result, raises, []

    def judge(self, mode, evidence):
        self.calls.append(evidence)
        if self.raises:
            raise self.raises
        return self.result


def credible(*urls):
    urls = urls or ("https://www.allmusic.com/album/x", "https://musicbrainz.org/recording/r")
    findings = [{"source_url": u, "says": "credited", "effect": "supports", "quote": "Mixing: Real Engineer",
                 "body_sha256": "ab" * 32} for u in urls]
    cited = list(urls)
    return JudgeResult(ok=True, verdict="APPROVE-RECOMMENDED", confidence=0.92, findings=findings, cited_urls=cited,
                       identity_consistent=True, model="gpt-6-sol", prompt_sha256="cd" * 32, llm_call_id=7,
                       provider="codex")


def contradicting():
    f = [{"source_url": "https://musicbrainz.org/recording/r", "says": "mixed by X", "effect": "contradicts",
          "quote": "- mix: Somebody Else", "body_sha256": "ef" * 32}]
    return JudgeResult(ok=True, verdict="REJECT-RECOMMENDED", confidence=0.95, findings=f,
                       cited_urls=["https://musicbrainz.org/recording/r"], identity_consistent=None, model="gpt-6-sol")


class Writer:
    """Fake conditional-status endpoint. Records (status, ids, expected) and the
    ledger state at call time (to prove the decision row precedes the PUT)."""

    def __init__(self, db, skip=None):
        self.db, self.skip, self.calls = db, dict(skip or {}), []

    def __call__(self, status, ids, expected):
        n = self.db.execute("SELECT COUNT(*) FROM decisions WHERE request_id IN (%s)" % ",".join("?" * len(ids)),
                            ids).fetchone()[0]
        self.calls.append({"status": status, "ids": list(ids), "expected": expected, "decided_before_put": n})
        upd = [i for i in ids if i not in self.skip]
        return {"data": {"updatedIds": upd, "skippedIds": [i for i in ids if i in self.skip],
                         "skipped": [{"id": i, "reason": r} for i, r in self.skip.items() if i in ids]}}


# credit_verify/proof/stage2.py SCHEMA (the columns stage2_verdicts reads).
STAGE2_SCHEMA = """CREATE TABLE stage2_shadow (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
  judged_at TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER, paid INTEGER,
  popularity INTEGER, tier TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, verdict TEXT, proof_id TEXT,
  source_ref TEXT, doc_kind TEXT, documents INTEGER NOT NULL, detail_json TEXT NOT NULL, analyzer_version TEXT);
CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, subject TEXT NOT NULL,
  candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', conversation_id TEXT NOT NULL, source TEXT NOT NULL,
  file_sha256 TEXT NOT NULL, file_path TEXT, mime TEXT, bytes INTEGER, received_at TEXT NOT NULL,
  filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT, UNIQUE (user_id, file_sha256));"""


def stage2_row(path, request_id, role, user_id, outcome, *, reason="r", version=None, doc_kind="contract"):
    from credit_verify.proof import FORENSICS_VERSION
    db = sqlite3.connect(path)
    db.execute("INSERT INTO stage2_shadow (run_id, judged_at, request_id, role, user_id, paid, outcome, reason, "
               "proof_id, doc_kind, documents, detail_json, analyzer_version) VALUES "
               "('run','2026-10-26T12:00:00Z',?,?,?,1,?,?,'p1',?,1,'[]',?)",
               (request_id, role, user_id, outcome, reason, doc_kind, version or FORENSICS_VERSION))
    db.commit()
    db.close()


TERMS = decide.Policy.load().editorial_role_terms
POLICY = decide.Policy(deny_user_ids={666}, deny_profile_ids=set(), editorial_role_terms=TERMS,
                       approve_arm=True)  # the approve-arm tests: opt in explicitly (the default is OFF)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.ledger = Ledger(str(Path(self.tmp) / "ledger.sqlite3"))
        self.db = self.ledger.db
        decide.ensure_schema(self.db)
        reg = Path(self.tmp) / "registry.json"
        reg.write_text(json.dumps({"automations": {"credit-trust-decide": {
            "approved": True, "approved_by": "captain (Aaron)", "approval_ref": "2026-10-15 ~22:12Z"}}}))
        self._reg = decide.REGISTRY
        decide.REGISTRY = reg
        self._lock = decide.WRITE_LOCK
        decide.WRITE_LOCK = Path(self.tmp) / "w.lock"
        self._paying, self._log, self._proof = decide.PAYING_USERS_FILE, decide.log, decide.PROOF_ON_FILE
        decide.PAYING_USERS_FILE = Path(self.tmp) / "paying-users.json"
        decide.PROOF_ON_FILE = Path(self.tmp) / "proof-on-file.json"
        # firstmate 125: the host's switch file must never leak into a test run (node-8 CI).
        self._prov_switch = decide.PROVISIONAL_PAID_SWITCH
        decide.PROVISIONAL_PAID_SWITCH = Path(self.tmp) / "provisional-paid.disabled"
        self.addCleanup(setattr, decide, "PROVISIONAL_PAID_SWITCH", self._prov_switch)
        # d2 [key=decider-support-arm]: the approve-arm switch is redirected into the temp dir too
        # (an /etc/hydra file present on the host must never decide a test outcome).
        self._approve_switch = decide.APPROVE_SWITCH
        decide.APPROVE_SWITCH = Path(self.tmp) / "approve.disabled"
        self.addCleanup(setattr, decide, "APPROVE_SWITCH", self._approve_switch)
        self.proof()
        # The stage-2 verdict store (with_stage2): empty unless a test writes verdicts.
        self._stage2 = decide.STAGE2_STORE
        decide.STAGE2_STORE = Path(self.tmp) / "proof.sqlite"
        self.addCleanup(setattr, decide, "STAGE2_STORE", self._stage2)
        s2 = sqlite3.connect(decide.STAGE2_STORE)
        s2.executescript(STAGE2_SCHEMA)
        s2.close()
        self.logged = []
        decide.log = self.logged.append

    def tearDown(self):
        decide.REGISTRY = self._reg
        decide.WRITE_LOCK = self._lock
        decide.PAYING_USERS_FILE, decide.log, decide.PROOF_ON_FILE = self._paying, self._log, self._proof

    def proof(self, entries=(), generated_at="2026-10-11T02:12:00Z", sources=None, contacts=()):
        """The proof-on-file export as the producer lane writes it."""
        entries = list(entries)
        decide.PROOF_ON_FILE.write_text(json.dumps({
            "generated_at": generated_at,
            "gmail_contacts_90d": {"generated_at": generated_at, "source": "test", "user_ids": list(contacts)},
            "sources": sources if sources is not None else [
                {"name": "core", "generated_at": generated_at, "count": len(entries)},
                {"name": "cs-intercom", "generated_at": generated_at, "stale": False, "count": 0},
                {"name": "cs-gmail", "generated_at": generated_at, "stale": False, "count": 0}],
            "users": len({e["user_id"] for e in entries}), "entries": entries}))

    def clear_readback(self):
        """Settle the read-back a previous apply run owes, the way the operator does.

        qa-review #1782 (r7): the pending-read-back check now runs INSIDE the write lock, so a second apply run in the
        same test is refused until the first is read back - which is the d2 condition, not a test artefact.
        """
        for p in decide.pending_readback(self.db):
            decide.run_readback(self.db, p["run_id"], readback=lambda st, ids: set(ids))

    def go(self, rows, raws=None, judge=None, mode="apply", skip=None, policy=POLICY, admin_requests=(),
           transient_404=None, raw_404=(), **kw):
        admin = T.FakeAdmin(list(admin_requests), raws or {}, PROFILES, TRACKS)
        admin.raw_404 = set(raw_404)
        admin.unreadable = {"art-unreadable", "flaky"}
        admin.transient_404 = dict(transient_404 or {})
        w = Writer(self.db, skip)
        res = decide.run(admin, self.db, judge, mode=mode, policy=policy, writer=w, now=T.NOW, rows=rows, **kw)
        return res, w

    def decisions(self):
        self.db.row_factory = sqlite3.Row
        return {r["request_id"]: dict(r) for r in self.db.execute("SELECT * FROM decisions")}


class PolicyLoad(unittest.TestCase):
    def test_a_missing_or_mistyped_deny_list_refuses_to_load(self):
        good = json.loads(decide.POLICY.read_text(encoding="utf-8"))
        tmp = Path(tempfile.mkdtemp()) / "policy.json"
        bad = [{k: v for k, v in good.items() if k != "deny_user_ids"},
               {k: v for k, v in good.items() if k != "deny_profile_ids"},
               {**good, "deny_user_ids": None}, {**good, "deny_profile_ids": None},
               {**good, "deny_user_ids": ["13373"]}, {**good, "deny_user_ids": [True]},
               {**good, "deny_profile_ids": [7]}, {**good, "deny_profile_ids": "stillfloo"}]
        for doc in bad:
            tmp.write_text(json.dumps(doc))
            with self.assertRaises(ValueError, msg=json.dumps(doc)[:120]):
                decide.Policy.load(tmp)
        tmp.write_text(json.dumps(good))
        p = decide.Policy.load(tmp)
        self.assertEqual(p.deny_user_ids, set(good["deny_user_ids"]))
        self.assertEqual(p.deny_profile_ids, {x.lower() for x in good["deny_profile_ids"]})


class ServerMirror(unittest.TestCase):
    def test_validator_conflict_matches_agent_approval_guard(self):
        self.assertIsNone(decide.validator_conflict({"rule_risk_percent": {"track_credit": 69, "collaborations": 100}}))
        self.assertTrue(decide.validator_conflict({"rule_risk_percent": {"track_credit": 70, "collaborations": 90}})["class_c"])
        self.assertEqual(decide.validator_conflict({"rule_risk_percent": {"review_big_track_without_trusted_credit": 100}})
                         ["hold_rules"], ["review_big_track_without_trusted_credit"])
        self.assertIsNone(decide.validator_conflict({"rule_risk_percent": {"review_x": 29.9}}))
        self.assertIsNone(decide.validator_conflict({"rule_risk_percent": {"review_x": "100"}}), "only JSON numbers count")
        self.assertTrue(decide.validator_conflict({"rule_errors": {"_hold_on_error": "boom"}})["hold_on_error"])
        self.assertIsNone(decide.validator_conflict(None))


class Decisions(Base):
    def test_conflict_rows_are_never_sent_as_approve(self):
        rows = [req(uuid_of(1), vd_rules={"review_role_credited_to_other_at_trusted_source": 80}),
                req(uuid_of(2), vd_rules={"track_credit": 75, "collaborations": 95})]
        res, w = self.go(rows, {"small": [T.raw("Real Engineer", "mixer")]}, judge=FakeJudge(credible()))
        self.assertEqual(res.approved, 0)
        self.assertTrue(all(c["status"] == decide.UVN for c in w.calls))
        self.assertEqual(sorted(w.calls[0]["ids"]), [uuid_of(1), uuid_of(2)])

    def test_high_risk_big_track_fixture_is_caught_by_the_score(self):
        rows = [req(uuid_of(3), uid=15, pid=PID_CLAIMANT_A, track="t1", roles=("Keyboard",)),
                req(uuid_of(4), uid=15, pid=PID_CLAIMANT_A, track="t9", roles=("Producer",))]
        raws = {"t1": [T.raw("Claimant A", "keyboards")], "t9": [T.raw("Claimant A", "producer")]}
        j = FakeJudge(credible())
        res, w = self.go(rows, raws, judge=j)
        self.assertEqual((res.approved, res.support), (0, 2))
        self.assertEqual(j.calls, [], "the big-track score refuses them without a model call")
        d = self.decisions()
        self.assertTrue(all("big track" in d[r["id"]]["reason"] for r in rows))
        self.assertTrue(all(c["status"] != decide.APPROVED for c in w.calls))

    def test_big_tracks_are_never_approved_even_when_confirmed(self):
        rows = [req(uuid_of(5), track="t1"), req(uuid_of(6), track="starry")]
        raws = {"t1": [T.raw("Real Engineer", "mixer")], "starry": [T.raw("Real Engineer", "mixer")]}
        res, w = self.go(rows, raws, judge=FakeJudge(credible()))
        self.assertEqual(res.approved, 0)
        d = self.decisions()
        self.assertTrue(all(x["decision"] == "support" and x["big_track"] == 1 for x in d.values()))

    def test_failed_reads_defer_but_missing_popularity_asks_for_support(self):
        deferred = [req(uuid_of(61), track="artless"), req(uuid_of(56), track="flaky")]
        support = [req(uuid_of(60), track="nopop"), req(uuid_of(59), track="artnopop")]
        tracks = ("nopop", "artless", "artnopop", "flaky")
        res, w = self.go(deferred + support, {t: [T.raw("Real Engineer", "mixer")] for t in tracks},
                         judge=FakeJudge(credible()))
        d = self.decisions()
        self.assertEqual((res.approved, res.support, res.deferred), (0, 2, 2))
        self.assertEqual([d[r["id"]]["decision"] for r in deferred], ["defer", "defer"])
        self.assertIn("unreadable this run", d[uuid_of(61)]["reason"])
        self.assertFalse(any(d[r["id"]]["reason"].startswith("catalog_unreadable") for r in deferred))
        self.assertEqual(sorted(w.calls[0]["ids"]), sorted(r["id"] for r in support))

    def test_a_transient_404_is_re_read_and_decided_normally(self):
        raws = {"small": [T.raw("Real Engineer", "mixer")]}
        res, w = self.go([req(uuid_of(55))], raws, transient_404={"small": 1, "art-small": 1})
        d = self.decisions()[uuid_of(55)]
        self.assertEqual((d["decision"], d["evidence_kind"]), ("approve", "catalog_confirmed"))

    def test_only_consecutive_404s_count(self):
        row = req(uuid_of(54), track="t3")
        for _ in range(decide.CATALOG_404_MAX_DEFERS):
            res, _ = self.go([row], judge=None, transient_404={"t3": 2})
        self.assertEqual(decide.catalog_404_defers(self.db, uuid_of(54), "apply"), 3)
        res, _ = self.go([row], judge=None)
        self.assertIn("web check unavailable", self.decisions()[uuid_of(54)]["reason"])
        self.assertEqual(decide.catalog_404_defers(self.db, uuid_of(54), "apply"), 0, "a good read resets the count")
        res, w = self.go([row], judge=None, transient_404={"t3": 2})
        self.assertEqual((res.deferred, res.support, w.calls), (1, 0, []))

    def test_filter_deferrals_do_not_reset_the_404_count(self):
        row = req(uuid_of(51), track="gone")
        for _ in range(decide.CATALOG_404_MAX_DEFERS):
            self.go([row], judge=FakeJudge(credible()))
        decide.PROOF_ON_FILE.unlink()
        res, w = self.go([row], judge=FakeJudge(credible()))
        self.assertEqual((res.deferred_proof_unknown, w.calls), (1, []))
        self.assertEqual(decide.catalog_404_defers(self.db, uuid_of(51), "apply"), 3)
        self.proof()
        res, w = self.go([row], judge=FakeJudge(credible()))
        self.assertEqual((res.support, w.calls[0]["ids"]), (1, [uuid_of(51)]))
        self.assertTrue(self.decisions()[uuid_of(51)]["reason"].startswith("catalog_unreadable:"))

    def test_a_raw_credits_404_still_escalates_but_a_reject_row_never_does(self):
        ordinary = req(uuid_of(48), uid=611, track="t3")
        rejected = req(uuid_of(49), uid=612, track="t3", vd_rules={"reject_deleted_catalog_track": 100})
        for run in range(1, 5):
            res, w = self.go([ordinary, rejected], judge=FakeJudge(credible()), raw_404={"t3"})
            last = {r["request_id"]: (r["decision"], r["reason"]) for r in self.db.execute(
                "SELECT * FROM decisions WHERE run_id = ?", (res.run_id,))}
            if run == 1:
                self.assertEqual(last[uuid_of(49)][0], "hold")
                self.assertIn("reject_deleted_catalog_track", last[uuid_of(49)][1])
            self.assertTrue(all(uuid_of(49) not in c["ids"] for c in w.calls), run)
        d = self.decisions()
        self.assertEqual(d[uuid_of(48)]["decision"], "support")
        self.assertTrue(d[uuid_of(48)]["reason"].startswith("catalog_unreadable:"))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM decisions WHERE request_id = ? AND decision != 'hold'",
                                         (uuid_of(49),)).fetchone()[0], 0)

    def test_a_persistent_404_defers_three_runs_then_asks_for_support(self):
        rows = [req(uuid_of(52), track="art404"), req(uuid_of(53), track="gone")]
        raws = {t: [T.raw("Real Engineer", "mixer")] for t in ("art404", "gone")}
        for run in range(1, 5):
            res, w = self.go(rows, raws, judge=FakeJudge(credible()))
            last = {r["request_id"]: dict(r) for r in self.db.execute(
                "SELECT * FROM decisions WHERE run_id = ?", (res.run_id,))}
            for r in rows:
                self.assertTrue(last[r["id"]]["reason"].startswith("catalog_unreadable"), last[r["id"]]["reason"])
            if run <= decide.CATALOG_404_MAX_DEFERS:
                self.assertEqual((res.deferred, res.approved, res.support, w.calls), (2, 0, 0, []), run)
            else:
                self.assertEqual((res.deferred, res.approved, res.support), (0, 0, 2))
                self.assertEqual(w.calls[0]["status"], decide.UVN)
                self.assertTrue(all(last[r["id"]]["doc_required"] == 1 for r in rows))

    def test_approve_needs_one_evidence_kind(self):
        rows = [req(uuid_of(7)), req(uuid_of(8), track="t3"), req(uuid_of(9), track="t2")]
        raws = {"small": [T.raw("Real Engineer", "mixer")]}           # 7: catalog confirmed
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        tracks_t2_small = dict(TRACKS)
        res, w = self.go(rows, raws, judge=judge)
        d = self.decisions()
        self.assertEqual((d[uuid_of(7)]["decision"], d[uuid_of(7)]["evidence_kind"]), ("approve", "catalog_confirmed"))
        self.assertEqual(d[uuid_of(8)]["decision"], "support")      # small, web NOT_FOUND
        self.assertEqual(d[uuid_of(8)]["web_verdict"], "NOT_FOUND")
        self.assertEqual(d[uuid_of(9)]["decision"], "support")      # t2 is pop 70 = big
        self.assertIsNotNone(tracks_t2_small)

    def test_web_credible_approves_with_verified_citation_and_audit_fields(self):
        res, w = self.go([req(uuid_of(10), track="t3")], judge=FakeJudge(credible()))
        d = self.decisions()[uuid_of(10)]
        self.assertEqual((d["decision"], d["evidence_kind"], d["web_verdict"]), ("approve", "web_credible", "CREDIBLE"))
        self.assertEqual((d["model"], d["prompt_sha256"], d["llm_call_id"]), ("gpt-6-sol", "cd" * 32, 7))
        self.assertIn("allmusic.com", json.loads(d["web_urls"])[0]["url"])
        self.assertEqual(w.calls[0], {"status": "approved", "ids": [uuid_of(10)], "expected": "unverified",
                                      "decided_before_put": 1})

    def test_web_credible_needs_two_domains_not_only_crowd_edited(self):
        cases = {uuid_of(62): credible("https://www.allmusic.com/album/x"),
                 uuid_of(63): credible("https://musicbrainz.org/recording/r", "https://en.wikipedia.org/wiki/Song")}
        for n, (rid, j) in enumerate(cases.items()):
            self.go([req(rid, uid=600 + n, track="t3")], judge=FakeJudge(j))
        d = self.decisions()
        self.assertEqual([(d[r]["decision"], d[r]["web_verdict"]) for r in cases], [("support", "NOT_FOUND")] * 2)

    def test_web_claim_without_verified_citation_is_not_credible(self):
        j = credible()
        j.cited_urls = []          # the finding's page was not fetched/cited
        res, _ = self.go([req(uuid_of(11), track="t3")], judge=FakeJudge(j))
        self.assertEqual(self.decisions()[uuid_of(11)]["decision"], "support")

    def test_contradiction_on_one_person_role_is_flagged_n1(self):
        res, _ = self.go([req(uuid_of(12), track="t3", roles=("Mixing",))], judge=FakeJudge(contradicting()))
        d = self.decisions()[uuid_of(12)]
        self.assertEqual((d["decision"], d["n1"], d["web_verdict"]), ("support", 1, "CONTRADICTED"))
        self.assertEqual(res.n1, 1)
        res2, _ = self.go([req(uuid_of(13))], {"small": [T.raw("Serban Ghenea", "mixing engineer")]})
        self.assertEqual(self.decisions()[uuid_of(13)]["n1"], 1)
        self.go([req(uuid_of(15), uid=650, roles=("Remixer",))], {"small": [T.raw("DJ X", "remixer")]})
        self.assertEqual(self.decisions()[uuid_of(15)]["n1"], 1)

    def test_model_outage_defers_instead_of_asking_users(self):
        res, w = self.go([req(uuid_of(14), track="t3")], judge=FakeJudge(JudgeResult(ok=False, error="codex: quota")))
        self.assertEqual((res.deferred, res.support, w.calls), (1, 0, []))
        res2, w2 = self.go([req(uuid_of(15), track="t3")], judge=FakeJudge(raises=RuntimeError("boom")))
        self.assertEqual((res2.deferred, w2.calls), (1, []))
        res3, w3 = self.go([req(uuid_of(16), track="t3")], judge=None)
        self.assertEqual((res3.deferred, w3.calls), (1, []))

    def test_source_outage_defers_instead_of_asking_users(self):
        from credit_trust import credibility, websearch

        class Prov:
            codex_model = "gpt-6-sol"

            def judge(self, *a, **k):
                raise AssertionError("no model call without sources")

        def offline(url, **kw):
            raise OSError("offline")
        j = credibility.FetchedSourcesJudge(Prov(), websearch.Searcher(None, get=offline, sleep=lambda _s: None),
                                            skip_model_without_sources=True)
        res, w = self.go([req(uuid_of(64), track="t3")], judge=j)
        self.assertEqual((res.deferred, res.support, w.calls), (1, 0, []))
        self.assertIn("source fetch failed", self.decisions()[uuid_of(64)]["reason"])

    def test_jev_answer_can_only_support_or_defer(self):
        jev = JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.0, provider="jev", model="jev-latest")
        res, w = self.go([req(uuid_of(65), track="t3")], judge=FakeJudge(jev))
        self.assertEqual((res.support, res.approved, res.jev_calls), (1, 0, 1))
        self.assertEqual(self.decisions()[uuid_of(65)]["provider"], "jev")
        res2, w2 = self.go([req(uuid_of(66), track="t3")],
                           judge=FakeJudge(JudgeResult(ok=False, provider="jev", error="jev answered 'names_claimant'")))
        self.assertEqual((res2.deferred, w2.calls), (1, []))

    def test_untracked_rows_defer(self):
        r = req(uuid_of(17))
        r["trackId"] = None
        res, w = self.go([r], judge=FakeJudge(credible()))
        self.assertEqual((res.deferred, w.calls), (1, []))

    def test_server_skips_are_recorded_not_retried(self):
        rows = [req(uuid_of(18), track="t3"), req(uuid_of(19), track="t3")]
        res, w = self.go(rows, judge=FakeJudge(credible()), skip={uuid_of(19): "needs_human_review"})
        self.assertEqual(len(w.calls), 1)
        self.assertEqual((res.approved, res.skipped_by_server), (1, {"needs_human_review": 1}))
        out = decide.explain(self.db, uuid_of(19))
        self.assertEqual(out[0]["outcomes"][0]["outcome"], "skipped:needs_human_review")
        self.assertIn(uuid_of(19), decide.recently_decided(self.db, "2000-01-01T00:00:00Z"))

    def test_deny_lists_and_daily_cap(self):
        policy = decide.Policy(deny_user_ids={666},
                               deny_profile_ids={T.PID_BAD.lower()}, editorial_role_terms=TERMS,
                               max_approvals_per_user_per_day=1, approve_arm=True)
        rows = [req(uuid_of(20), uid=666, track="t3"), req(uuid_of(21), pid=T.PID_BAD, uid=700, track="t3"),
                req(uuid_of(22), uid=800, track="t3"), req(uuid_of(23), uid=800, track="t3")]
        res, w = self.go(rows, judge=FakeJudge(credible()), policy=policy)
        d = self.decisions()
        self.assertEqual(d[uuid_of(20)]["decision"], "support")
        self.assertEqual(d[uuid_of(21)]["decision"], "support")
        self.assertEqual(sorted(x["decision"] for k, x in d.items() if k in (uuid_of(22), uuid_of(23))), ["approve", "defer"])

    def test_registry_not_approved_runs_as_shadow(self):
        decide.REGISTRY.write_text(json.dumps({"automations": {"credit-trust-decide": {"approved": False}}}))
        res, w = self.go([req(uuid_of(24), track="t3")], judge=FakeJudge(credible()))
        self.assertEqual((res.mode, w.calls), ("shadow", []))
        self.assertIn("APPLY REFUSED", res.line())

    def test_shadow_mode_writes_nothing(self):
        res, w = self.go([req(uuid_of(25), track="t3")], judge=FakeJudge(credible()), mode="shadow")
        self.assertEqual((res.approved, w.calls), (1, []))
        self.assertIn("would approve", res.line())

    def test_judge_mode_writes_nothing_and_records_judge_rows(self):
        # Fable [key=l11b]: judge = shadow (no approval PUT, no ask, no provisional) with mode='judge'
        # in the ledger, so stage 2 gets its "proof on file" holds while the approve path is off.
        res, w = self.go([req(uuid_of(27), track="t3")], judge=FakeJudge(credible()), mode="judge")
        self.assertEqual((res.mode, res.approved, w.calls), ("judge", 1, []))
        self.assertIn("would approve", res.line())
        self.assertNotIn("APPLY REFUSED", res.line())
        modes = {r[0] for r in self.db.execute("SELECT mode FROM decisions")}
        self.assertEqual(modes, {"judge"})
        outs = {r[0] for r in self.db.execute("SELECT outcome FROM decision_outcomes")}
        self.assertEqual(outs, {"shadow"})                      # nothing was written to core
        self.assertEqual(decide.approvals_today_by_user(self.db, "2000-01-01T00:00:00Z"), {})

    def test_judge_mode_never_writes_even_when_the_registry_is_approved_or_not(self):
        for approved in (True, False):
            decide.REGISTRY.write_text(json.dumps({"automations": {"credit-trust-decide": {
                "approved": approved, "approved_by": "t", "approval_ref": "t"}}}))
            res, w = self.go([req(uuid_of(28 + approved), track="t3")], judge=FakeJudge(credible()), mode="judge")
            self.assertEqual((res.mode, w.calls), ("judge", []), approved)

    def test_ledger_is_append_only_and_revert_lists_the_run(self):
        res, _ = self.go([req(uuid_of(26), track="t3")], judge=FakeJudge(credible()))
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("UPDATE decisions SET decision='approve'")
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("DELETE FROM decision_outcomes")
        self.assertEqual(decide.revert(self.db, res.run_id, apply=False)["approved_ids"], [uuid_of(26)])
        w = Writer(self.db)
        # captain 2026-10-23 (firstmate 104/105/106): approved -> unverified hides the credit, so
        # without the live Spotify+Tidal gate it is refused and nothing is written ...
        with mock.patch.object(decide.dsp_gate, "WIRED", False), self.assertRaises(SystemExit) as cm:
            decide.revert(self.db, res.run_id, apply=True, writer=w)
        self.assertIn("live_dsp_gate_required", str(cm.exception.code))
        self.assertEqual(w.calls, [])
        # ... and the write mechanics stay as they were once the gate is wired
        with mock.patch.object(decide.dsp_gate, "WIRED", True):
            out = decide.revert(self.db, res.run_id, apply=True, writer=w)
        self.assertEqual(w.calls[0]["status"], "unverified")
        self.assertEqual(w.calls[0]["expected"], "approved")
        self.assertEqual(out["results"][uuid_of(26)], "unverified")

    def test_footprint_from_trusted_confirmations(self):
        for i in range(3):
            self.ledger.record({"request_id": f"old{i}", "mode": "audit", "phase": "live", "verdict": "CONFIRMED",
                                "confidence": 1, "basis": "trusted_source_confirmation", "big_track": False,
                                "profile_id": T.PID_GOOD, "claimed_roles": ["Mix Engineer"]})
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"mix"}), 3)
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"master"}), 0)
        res, w = self.go([req(uuid_of(27), track="t3")], judge=FakeJudge(JudgeResult(ok=False, error="x")))
        self.assertEqual(self.decisions()[uuid_of(27)]["evidence_kind"], "footprint")

    def test_paid_fallback_is_capped_and_overflow_defers(self):
        class Paid:
            calls = 0

            def judge(self, mode, ev):
                Paid.calls += 1
                r = credible()
                r.cost_usd, r.provider = 0.6, "openrouter"
                return r
        capped = decide.CappedJudge(Paid(), run_cap_usd=1.0, daily_cap_usd=25.0, spent_today_usd=0.0)
        rows = [req(uuid_of(40 + i), track="t3") for i in range(4)]
        res, w = self.go(rows, judge=capped, workers=1)
        self.assertEqual(Paid.calls, 1, "after one $0.60 call the next reserve no longer fits a $1 run cap")
        self.assertEqual((res.approved, res.deferred), (1, 3))
        self.assertEqual((res.paid_calls, round(res.spend_usd, 2)), (1, 0.6))
        daily = decide.CappedJudge(Paid(), run_cap_usd=10.0, daily_cap_usd=25.0, spent_today_usd=24.97)
        self.assertFalse(daily.judge("review", {}).ok)
        self.assertGreater(decide.spent_today_usd(self.db, "2000-01-01T00:00:00Z"), 0.59)

    def test_footprint_counts_only_server_approved_apply_decisions(self):
        raws = {"small": [T.raw("Real Engineer", "mixer")]}
        shadow = [req(uuid_of(200 + i)) for i in range(3)]
        self.go(shadow, raws, mode="shadow")
        self.assertEqual({d["evidence_kind"] for d in self.decisions().values()}, {"catalog_confirmed"})
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"mix"}), 0, "shadow decisions are not a footprint")
        refused = [req(uuid_of(210 + i)) for i in range(3)]
        self.go(refused, raws, skip={r["id"]: "needs_human_review" for r in refused})
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"mix"}), 0, "server-skipped approvals are not one")
        capped = [req(uuid_of(220 + i)) for i in range(3)]
        self.go(capped, raws, policy=dataclasses.replace(POLICY, max_approvals_per_user_per_day=0))
        self.assertEqual({self.decisions()[r["id"]]["decision"] for r in capped}, {"defer"})
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"mix"}), 0, "deferred approvals are not one")
        self.go([req(uuid_of(230 + i)) for i in range(3)], raws)
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"mix"}), 3)

    def test_footprint_must_cover_every_claimed_family(self):
        for i in range(3):
            self.ledger.record({"request_id": f"prod{i}", "mode": "audit", "phase": "live", "verdict": "CONFIRMED",
                                "confidence": 1, "basis": "trusted_source_confirmation", "big_track": False,
                                "profile_id": T.PID_GOOD, "claimed_roles": ["Producer"]})
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"producer"}), 3)
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"producer", "mix"}), 0)
        self.assertEqual(decide.footprint(self.db, T.PID_GOOD, {"producer", "other"}), 0)
        self.go([req(uuid_of(67), track="t3", roles=("Producer", "Mix Engineer"))],
                judge=FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, provider="codex")))
        d = self.decisions()[uuid_of(67)]
        self.assertEqual((d["decision"], d["evidence_kind"]), ("support", None))
        self.go([req(uuid_of(68), track="t3", roles=("Producer",))], judge=FakeJudge(credible()))
        self.assertEqual(self.decisions()[uuid_of(68)]["evidence_kind"], "footprint")


class Editorial(Base):
    def test_predicate(self):
        for role in ("Editor", "Vocal Editing", "Digital Editing", "Editing Engineer", "Pro Tools Editing",
                     "Dialogue Editor", "Music Editor", "Compilation", "Assembly", "ProTools"):
            self.assertTrue(decide.is_editorial(role, TERMS), role)
        for role in ("Mixing", "Producer", "Composer", "Recording Engineer", "Credit Manager"):
            self.assertFalse(decide.is_editorial(role, TERMS), role)

    def test_only_catalog_confirmation_on_a_small_track_approves(self):
        raws = {"small": [T.raw("Real Engineer", "vocal editing")], "mid": [T.raw("Real Engineer", "vocal editing")]}
        rows = [req(uuid_of(70), roles=("Vocal Editing",)), req(uuid_of(71), track="mid", roles=("Vocal Editing",)),
                req(uuid_of(72), track="t3", roles=("Vocal Editing",))]
        for i in range(3):
            self.ledger.record({"request_id": f"ed{i}", "mode": "audit", "phase": "live", "verdict": "CONFIRMED",
                                "confidence": 1, "basis": "trusted_source_confirmation", "big_track": False,
                                "profile_id": T.PID_GOOD, "claimed_roles": ["Vocal Editing"]})
        judge = FakeJudge(credible())
        res, w = self.go(rows, raws, judge=judge)
        d = self.decisions()
        self.assertEqual((d[uuid_of(70)]["decision"], d[uuid_of(70)]["evidence_kind"]), ("approve", "catalog_confirmed"))
        self.assertEqual(d[uuid_of(71)]["decision"], "support")
        self.assertIn("pop >= 30", d[uuid_of(71)]["reason"])
        self.assertEqual(d[uuid_of(72)]["decision"], "support", "no footprint or web approval for editorial roles")
        self.assertIn("editorial role", d[uuid_of(72)]["reason"])
        self.assertEqual(judge.calls, [])

    def test_velocity_weighs_double_on_editorial_roles(self):
        recent = [T.request(f"v{i}", pid=T.PID_GOOD, track="small", status="approved") for i in range(25)]
        raws = {"small": [T.raw("Real Engineer", "vocal editing"), T.raw("Real Engineer", "mixer")]}
        self.go([req(uuid_of(73), roles=("Vocal Editing",)), req(uuid_of(74), roles=("Mixing",))], raws,
                admin_requests=recent)
        d = self.decisions()
        self.assertEqual(d[uuid_of(73)]["decision"], "support")
        self.assertIn("weighs double", d[uuid_of(73)]["reason"])
        self.assertEqual(d[uuid_of(74)]["decision"], "approve", "25/24h is not high velocity for other roles")


class DocRequired(Base):
    """The decider's doc_required marker is what keeps uvn-under30 from
    approving a support request that needs documents on popularity alone."""

    def uvn_row(self, rid):
        r = req(rid, track="p12a")
        r.update(status="user_verification_needed", spotifyTrackId="sp-" + rid[-4:])
        return r

    def test_support_rows_need_documents_except_not_found(self):
        rows = [req(uuid_of(90), uid=666), req(uuid_of(91), track="t1"), req(uuid_of(92), track="p12c")]
        self.go(rows, {"t1": [T.raw("Real Engineer", "mixer")]},
                judge=FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, provider="codex")))
        d = self.decisions()
        self.assertEqual([d[uuid_of(i)]["decision"] for i in (90, 91, 92)], ["support"] * 3)
        self.assertEqual([d[uuid_of(i)]["doc_required"] for i in (90, 91, 92)], [1, 1, 0])

    def test_decider_marked_rows_are_refused_by_uvn_under30(self):
        import uvn_under30_policy as uvn
        editorial = req(uuid_of(93), track="p12a", roles=("Vocal Editing",))
        contradicted = req(uuid_of(94), track="p12b")
        ordinary = req(uuid_of(95), track="p12c")
        self.go([editorial, contradicted, ordinary], {"p12b": [T.raw("Serban Ghenea", "mixing engineer")]},
                judge=FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, provider="codex")))
        d = self.decisions()
        self.assertEqual([d[r["id"]]["decision"] for r in (editorial, contradicted, ordinary)], ["support"] * 3)
        deny = uvn.load_deny_list(decide.POLICY, Path(self.tmp) / "ledger.sqlite3")
        live = {"found": True, "track": {"popularity": 12}}
        verdicts = {}
        for r in (editorial, contradicted, ordinary):
            row = self.uvn_row(r["id"])
            row["credits"] = r["credits"]
            verdicts[r["id"]] = uvn.qualifies_for_approval(row, live, set(), deny)
        self.assertEqual(verdicts, {editorial["id"]: False, contradicted["id"]: False, ordinary["id"]: True})
        self.assertIn("documentation", deny.why(self.uvn_row(contradicted["id"])))

    def test_existing_ledger_gains_the_marker_column(self):
        db = sqlite3.connect(":memory:")
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, run_id TEXT, decided_at TEXT, request_id TEXT)")
        db.execute("INSERT INTO decisions (request_id) VALUES ('old')")
        decide.ensure_schema(db)
        self.assertEqual(db.execute("SELECT doc_required FROM decisions").fetchall(), [(0,)])


class PaidUsersFirst(Base):
    def rows(self):
        return [req(uuid_of(100), uid=501, created="2026-10-01T00:00:00Z"),
                req(uuid_of(101), uid=502, created="2026-10-02T00:00:00Z"),
                req(uuid_of(102), uid=900, created="2026-10-09T00:00:00Z"),
                req(uuid_of(103), uid=900, track="t1", created="2026-10-10T00:00:00Z")]

    def paying(self, generated_at, ids=(900,), count=None):
        ids = sorted(ids)
        decide.PAYING_USERS_FILE.write_text(json.dumps({
            "generated_at": generated_at, "source": "core.subscriptions", "definition": "active paid plan",
            "count": len(ids) if count is None else count, "counts_by_basis": {"subscription": len(ids)},
            "ids": ids}))

    def decided(self, res):
        return [r[0] for r in self.db.execute("SELECT request_id FROM decisions WHERE run_id = ? ORDER BY id",
                                             (res.run_id,))]

    RAWS = {"small": [T.raw("Real Engineer", "mixer")], "t1": [T.raw("Real Engineer", "mixer")]}

    def test_fresh_export_puts_paying_users_first(self):
        self.paying("2026-10-11T02:30:00Z")
        res, _ = self.go(self.rows(), self.RAWS, policy=dataclasses.replace(POLICY, max_rows_per_run=3))
        self.assertEqual(self.decided(res), [uuid_of(102), uuid_of(103), uuid_of(100)])
        d = self.decisions()
        self.assertEqual((d[uuid_of(102)]["paid_priority"], d[uuid_of(100)]["paid_priority"]), (1, 0))
        self.assertEqual(self.logged, [])

    def test_unknown_paying_status_keeps_oldest_first_and_logs_why(self):
        cases = {"missing": None, "stale": ("2026-10-10T23:00:00Z",), "future": ("2026-10-11T04:00:00Z",),
                 "malformed": "not json"}
        for why, content in cases.items():
            if content is None:
                decide.PAYING_USERS_FILE.unlink(missing_ok=True)
            elif isinstance(content, tuple):
                self.paying(content[0])
            else:
                decide.PAYING_USERS_FILE.write_text(content)
            self.logged.clear()
            res, _ = self.go(self.rows(), self.RAWS, policy=dataclasses.replace(POLICY, max_rows_per_run=2))
            self.assertEqual(self.decided(res), [uuid_of(100), uuid_of(101)], why)
            self.assertEqual(len(self.logged), 1, why)
            self.assertIn("unknown", self.logged[0])
            self.assertIn(why if why != "malformed" else "unreadable", self.logged[0])
            self.assertEqual({x["paid_priority"] for x in self.db.execute(
                "SELECT paid_priority FROM decisions WHERE run_id = ?", (res.run_id,))}, {None})
        for bad in ({"generated_at": "2026-10-11T02:30:00Z", "user_ids": [900]},
                    {"generated_at": "2026-10-11T02:30:00Z", "count": 1, "ids": ["900"]}):
            decide.PAYING_USERS_FILE.write_text(json.dumps(bad))
            self.assertIsNone(decide.paying_users(now=T.NOW)[0], bad)
        self.paying("2026-10-11T02:30:00Z", ids=(900, 901), count=3)
        paying, why = decide.paying_users(now=T.NOW)
        self.assertIsNone(paying)
        self.assertIn("count == len(ids)", why)

    def test_tiers_paid_over_24h_then_paid_under_24h_then_free_oldest_first(self):
        """Fable ruling 6 (credit-backlog-1019). NOW is 10-11 03:00Z."""
        self.paying("2026-10-11T02:30:00Z", ids=(900, 901))
        rows = [req(uuid_of(180), uid=501, created="2026-10-01T00:00:00Z"),          # free, oldest
                req(uuid_of(181), uid=900, created="2026-10-10T20:00:00Z"),          # paid < 24h
                req(uuid_of(182), uid=901, created="2026-10-09T00:00:00Z"),          # paid > 24h
                req(uuid_of(183), uid=900, created="2026-10-08T00:00:00Z")]          # paid > 24h, older
        self.assertEqual([r["id"] for r in decide.order_rows(rows, frozenset({900, 901}), T.NOW)],
                         [uuid_of(183), uuid_of(182), uuid_of(181), uuid_of(180)])
        self.assertEqual([r["id"] for r in decide.order_rows(rows, None, T.NOW)],
                         [uuid_of(180), uuid_of(183), uuid_of(182), uuid_of(181)], "unknown paying = oldest first")

    def test_paid_not_found_small_track_is_provisionally_approved_free_is_asked(self):
        """Fable ruling 4: trust yet verify for PAID users (small/medium, NOT_FOUND, nothing
        against the claim); free users stay on the ask path; big tracks stay strict."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        rows = [anchored(req(uuid_of(190), uid=900, track="t3")), req(uuid_of(191), uid=501, track="t3"),
                req(uuid_of(192), uid=900, track="t2")]
        res, w = self.go(rows, {}, judge=judge)
        d = self.decisions()
        self.assertEqual((d[uuid_of(190)]["decision"], d[uuid_of(190)]["evidence_kind"], d[uuid_of(190)]["web_verdict"]),
                         ("approve", "provisional_paid", "NOT_FOUND"))
        self.assertIn("trust yet verify", d[uuid_of(190)]["reason"])
        self.assertEqual(d[uuid_of(191)]["decision"], "support", "free user: asked")
        self.assertEqual(d[uuid_of(192)]["decision"], "support", "big track (pop 70): proof required")
        self.assertIn(uuid_of(190), [i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]])

    def test_the_provisional_paid_switch_turns_only_that_arm_off(self):
        """firstmate 125 / Fable review-audit-1021: with the switch file present the paid
        NOT_FOUND row is NOT provisionally approved; it stays on the support (ask) path."""
        decide.PROVISIONAL_PAID_SWITCH.write_text("off")
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        res, w = self.go([anchored(req(uuid_of(193), uid=900, track="t3"))], {}, judge=judge)
        d = self.decisions()[uuid_of(193)]
        self.assertEqual(d["decision"], "support")
        self.assertNotEqual(d["evidence_kind"], decide.PROVISIONAL_KIND)
        self.assertNotIn(uuid_of(193), [i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]])

    # ---- E1 (Fable review-audit-1021) ----
    def test_e1_paid_and_nothing_contradicts_is_not_an_anchor(self):
        """The 7 'unverifiable' of the audit: validator declined, catalog UNVERIFIABLE -> no approve."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        res, w = self.go([req(uuid_of(300), uid=900, track="t3")], {}, judge=judge)
        d = self.decisions()[uuid_of(300)]
        self.assertEqual(d["decision"], "support")
        self.assertIn("no positive anchor", d["reason"])
        self.assertEqual([i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]], [])

    def test_e1_prodgxm_others_only_plus_type_beat_web_is_never_approved(self):
        """ProdGxm fixture: Producer credited to the artist only (OTHERS_ONLY) and the web finds
        nothing for the claimant ('type beat' seller) -> stage 2, never approved, even with the
        validator's approval as an anchor."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        row = anchored(req(uuid_of(301), uid=900, track="t3", roles=("Producer",)))
        res, w = self.go([row], {"t3": [T.raw("comehelpglo", "producer")]}, judge=judge)
        d = self.decisions()[uuid_of(301)]
        self.assertNotEqual(d["decision"], "approve")
        self.assertNotEqual(d["evidence_kind"], decide.PROVISIONAL_KIND)
        self.assertEqual([i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]], [])

    def test_e1_pixlpxl_catalog_confirmed_role_is_approved_with_the_citation(self):
        """pixlpxl fixture: one claimed role CONFIRMED by the catalog (the Atmos mix), the other
        unverifiable, web NOT_FOUND -> provisional approval citing the confirmed role."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        res, w = self.go([req(uuid_of(303), uid=900, track="t3", roles=("Mixing", "Mastering"))],
                         {"t3": [T.raw("Real Engineer", "mixer")]}, judge=judge)
        d = self.decisions()[uuid_of(303)]
        self.assertEqual((d["decision"], d["evidence_kind"]), ("approve", decide.PROVISIONAL_KIND), d["reason"])
        self.assertIn("catalog confirms Mixing", d["reason"])
        d0 = decide.Decision(request_id="x", profile_id="p", user_id=900, track_id="t", track_title="V",
                             claimed_roles="Immersive Mixing,Mastering", popularity=20, big_track=False,
                             decision="support", reason="")
        d0.catalog = "Immersive Mixing=CONFIRMED,Mastering=UNVERIFIABLE"
        proof = decide.ProofOnFile(frozenset(), frozenset())
        self.assertEqual(decide.provisional_anchor(d0, {"verificationData": {"is_approved": False}}, proof),
                         "catalog confirms Immersive Mixing")
        d0.catalog = "Immersive Mixing=CONFIRMED,Composer=OTHERS_ONLY"
        self.assertTrue(decide.provisional_anchor(d0, {}, proof).startswith("no:the catalog credits Composer"))
        self.assertTrue(decide.provisional_anchor(d0, {}, None).startswith("no:the catalog credits"))
        d0.catalog = "Immersive Mixing=CONFIRMED"
        self.assertTrue(decide.provisional_anchor(d0, {}, None).startswith("no:proof on file"))
        self.assertTrue(decide.provisional_anchor(d0, {}, decide.ProofOnFile(frozenset({900}), frozenset())).startswith(
            "no:proof on file"))

    def test_e1_a_user_with_proof_on_file_goes_to_the_verifier_not_provisional(self):
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        self.proof([{"user_id": 900, "request_id": None, "kind": "pending_doc", "source": "cs-intercom", "ref": "c1"}])
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        res, w = self.go([anchored(req(uuid_of(302), uid=900, track="t3"))], {}, judge=judge)
        d = self.decisions()[uuid_of(302)]
        self.assertNotEqual(d["evidence_kind"], decide.PROVISIONAL_KIND)
        self.assertEqual([i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]], [])

    def test_the_web_check_cap_always_admits_paid_rows_first(self):
        """firstmate 099 (Fable ruling 6, paid first): with room for ONE web check, the newer
        paid row is checked and the older free row waits for the next run."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        rows = [req(uuid_of(250), uid=501, track="t3", created="2026-10-01T00:00:00Z"),
                req(uuid_of(251), uid=900, track="t3", created="2026-10-10T00:00:00Z")]
        self.go(rows, {}, judge=judge, max_model_calls=1)
        d = self.decisions()
        self.assertEqual(d[uuid_of(251)]["web_verdict"], "NOT_FOUND", "paid row web-checked")
        self.assertEqual((d[uuid_of(250)]["decision"], d[uuid_of(250)]["reason"]),
                         ("defer", "web-check cap for this run reached; next run"))

    def test_a_row_with_no_user_is_not_labelled_as_the_ask_cap(self):
        """firstmate 099: a row with no account user id is deferred as such, not as 'daily ask
        cap reached' (which misreported the cap at 122/400)."""
        self.proof([])
        row = req(uuid_of(260), track="t1")
        row["userId"] = None
        row.pop("user", None)
        res, w = self.go([row], {"t1": [T.raw("Real Engineer", "mixer")]})
        d = self.decisions()[uuid_of(260)]
        self.assertEqual(d["decision"], "defer")
        self.assertNotIn("ask cap", d["reason"])
        self.assertEqual(res.deferred_ask_cap, 0)

    def test_an_overridden_provisional_approval_keeps_no_provisional_kind(self):
        """firstmate 099 ledger hygiene: when a later guard turns ruling 4's approval into an ask
        or a hold, decisions.evidence_kind must not still say provisional_paid."""
        d = decide.Decision(request_id="x", profile_id=None, user_id=1, track_id=None, track_title="", claimed_roles=[],
                            popularity=10, big_track=False, decision="approve", reason="r")
        d.evidence_kind = decide.PROVISIONAL_KIND
        decide._set(d, "support", "server approval guard would refuse (proof_required): documentation required")
        self.assertIsNone(d.evidence_kind)
        d.evidence_kind = "catalog_confirmed"
        decide._set(d, "hold", "x")
        self.assertEqual(d.evidence_kind, "catalog_confirmed", "only the provisional kind is cleared")

    def test_the_daily_ask_cap_admits_paid_users_first(self):
        """Ruling 1 + 6: with room for one user, the paid user is asked, the older free one waits."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        self.proof([])
        rows = [req(uuid_of(210), uid=501, track="t1", created="2026-10-01T00:00:00Z"),
                req(uuid_of(211), uid=900, track="t1", created="2026-10-09T00:00:00Z")]
        res, w = self.go(rows, {"t1": [T.raw("Real Engineer", "mixer")]},
                         policy=dataclasses.replace(POLICY, max_ask_users_per_day=1))
        asked = [i for c in w.calls if c["status"] == decide.UVN for i in c["ids"]]
        self.assertEqual(asked, [uuid_of(211)])
        self.assertTrue(self.decisions()[uuid_of(210)]["reason"].startswith(decide.ASK_CAP_DEFER))

    def test_unconfirmed_provisional_approvals_go_to_the_ops_review_list_never_removal(self):
        """Ruling 4 as amended (firstmate 073): no day-30 auto-removal. After 30 days without
        a document the row is LISTED for Ops review (still live); a documented one is not."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        self.go([anchored(req(uuid_of(220), uid=900, track="t3")), anchored(req(uuid_of(221), uid=900, track="t3"))],
                {}, judge=judge)
        d = self.decisions()[uuid_of(220)]
        self.assertIn("never auto-removed", d["reason"])
        self.assertNotIn("removed on day", d["reason"])
        self.assertEqual(decide.provisional_review(self.db, None, now=T.NOW), [], "not before day 30")
        later = T.NOW + decide.timedelta(days=31)
        listed = decide.provisional_review(self.db, None, now=later)
        self.assertEqual(sorted(r["request_id"] for r in listed), [uuid_of(220), uuid_of(221)])
        self.assertTrue(all(r["flag"] == "provisional_unconfirmed_30d" for r in listed))
        # A user's other decider approval that rode in the same no-deadline v1 note (#1257, one
        # note per user) is listed too: it has no removal date either.
        from credit_review import verify_ledger
        self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, big_track, decision, reason, "
                        "evidence_kind, mode) VALUES ('run-y', ?, ?, 900, 0, 'approve', 't', 'catalog_confirmed', 'apply')",
                        (decide.utc(T.NOW), uuid_of(222)))
        self.db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                        "VALUES ('run-y', ?, ?, 'approve', 'approved')", (decide.utc(T.NOW), uuid_of(222)))
        self.db.executescript(verify_ledger.SCHEMA)
        self.db.row_factory = sqlite3.Row
        c = verify_ledger.claim(self.db, user_key="u900@example.com", day="2026-10-11",
                                request_ids=[uuid_of(220), uuid_of(222)], message_type="email",
                                approved_by="U7RP6HKUZ", approval_ref="ref", now=T.NOW)
        verify_ledger.finalize(self.db, message_row=c["message_row"], status="sent", message_id="1")
        self.db.execute("UPDATE verify_messages SET created_at = ?", (decide.utc(T.NOW),))
        listed = decide.provisional_review(self.db, None, now=later)
        self.assertEqual(sorted((r["request_id"], r["flag"]) for r in listed),
                         sorted([(uuid_of(220), "provisional_unconfirmed_30d"), (uuid_of(221), "provisional_unconfirmed_30d"),
                                 (uuid_of(222), "v1_note_unconfirmed_30d")]))
        self.proof([{"user_id": 900, "request_id": uuid_of(221), "kind": "pending_doc", "source": "intercom", "ref": "c"}])
        proof, _ = decide.proof_on_file(now=T.NOW)
        self.assertEqual([r["request_id"] for r in decide.provisional_review(self.db, proof, now=later)], [],
                         "a document on file for the user covers both")

    def test_paid_provisional_approvals_are_capped_per_user_per_day(self):
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        old = decide.PROVISIONAL_MAX_PER_USER_PER_DAY
        decide.PROVISIONAL_MAX_PER_USER_PER_DAY = 2
        try:
            res, _ = self.go([anchored(req(uuid_of(200 + i), uid=900, track="t3")) for i in range(3)], {}, judge=judge)
        finally:
            decide.PROVISIONAL_MAX_PER_USER_PER_DAY = old
        got = sorted(x["decision"] for x in self.decisions().values() if x["request_id"] in {uuid_of(200 + i) for i in range(3)})
        self.assertEqual(got, ["approve", "approve", "defer"])

    def test_the_provisional_cap_is_enforced_at_the_write_on_the_write_day(self):
        """QA review of #1275 @7c1830a: rows decided before UTC midnight but written after it
        count on the WRITE day, so a run after midnight cannot approve another full cap."""
        self.paying("2026-10-11T02:30:00Z", ids=(900,))
        judge = FakeJudge(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, model="gpt-6-sol"))
        yesterday = decide.utc(T.NOW - decide.timedelta(hours=4))   # 10-10 23:00Z, decided
        written = decide.utc(T.NOW - decide.timedelta(hours=2))     # 10-11 01:00Z, written
        decide.ensure_schema(self.db)
        for i in range(2):
            rid = uuid_of(230 + i)
            self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, user_id, big_track, decision, "
                            "reason, evidence_kind, mode) VALUES ('run-x', ?, ?, 900, 0, 'approve', 't', "
                            "'provisional_paid', 'apply')", (yesterday, rid))
            self.db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                            "VALUES ('run-x', ?, ?, 'approve', 'approved')", (written, rid))
        self.db.commit()
        old = decide.PROVISIONAL_MAX_PER_USER_PER_DAY
        decide.PROVISIONAL_MAX_PER_USER_PER_DAY = 2
        try:
            res, w = self.go([anchored(req(uuid_of(240 + i), uid=900, track="t3")) for i in range(2)], {}, judge=judge)
        finally:
            decide.PROVISIONAL_MAX_PER_USER_PER_DAY = old
        d = self.decisions()
        self.assertEqual({d[uuid_of(240 + i)]["decision"] for i in range(2)}, {"approve"},
                         "the decision-time count (run day, decided_at) saw none")
        self.assertEqual([i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]], [],
                         "the write-time count saw 2 already written today: nothing approved")
        outs = {r[0] for r in self.db.execute("SELECT outcome FROM decision_outcomes WHERE run_id = ?", (res.run_id,))}
        self.assertEqual(outs, {"deferred:provisional_user_cap"})

    def test_paying_status_never_changes_a_decision(self):
        """Except ruling 4 (paid NOT_FOUND provisional approval, tested above): with catalog
        evidence or a big track, paying status only changes the ORDER."""
        res_a, _ = self.go(self.rows(), self.RAWS, mode="shadow")
        self.paying("2026-10-11T02:30:00Z")
        res_b, _ = self.go(self.rows(), self.RAWS, mode="shadow")

        def outcome(res):
            return {r[0]: (r[1], r[2]) for r in self.db.execute(
                "SELECT request_id, decision, reason FROM decisions WHERE run_id = ?", (res.run_id,))}
        self.assertEqual(outcome(res_a), outcome(res_b))
        self.assertEqual(outcome(res_b)[uuid_of(103)][0], "support", "a paying user's big track is not approved")


class NeverReAsk(Base):
    """Captain standing order 2026-10-16: never ask a user for documents they
    already gave us, and never ask about the same credit twice."""

    NOT_FOUND = JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, provider="codex")
    RAWS = {"small": [T.raw("Real Engineer", "mixer")]}

    def support_writes(self, w):
        return [i for c in w.calls if c["status"] == decide.UVN for i in c["ids"]]

    def test_judge_mode_records_proof_on_file_holds_and_sends_no_ask(self):
        self.proof([{"user_id": 701, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c1"}])
        res, w = self.go([req(uuid_of(115), uid=701, track="t1"), req(uuid_of(116), uid=704, track="t1")],
                         self.RAWS, mode="judge")
        d = self.decisions()
        self.assertEqual((d[uuid_of(115)]["decision"], d[uuid_of(115)]["mode"]), ("hold", "judge"))
        self.assertTrue(d[uuid_of(115)]["reason"].startswith("proof on file: human review"))
        self.assertEqual((w.calls, support_ids(w)), ([], []))     # the ask for 116 is only "would"

    def test_proof_on_file_holds_the_ask_but_never_blocks_an_approval(self):
        self.proof([{"user_id": 701, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c1"},
                    {"user_id": 702, "request_id": uuid_of(112), "kind": "approved_doc", "source": "email", "ref": "m1"},
                    {"user_id": 703, "request_id": None, "kind": "human_approved_after_doc", "source": "core",
                     "ref": "r1"}])
        rows = [req(uuid_of(110), uid=701, track="t1"), req(uuid_of(111), uid=701),
                req(uuid_of(112), uid=799, track="t1"), req(uuid_of(113), uid=703, track="t1"),
                req(uuid_of(114), uid=704, track="t1")]
        res, w = self.go(rows, self.RAWS)
        d = self.decisions()
        self.assertEqual([d[uuid_of(i)]["decision"] for i in (110, 112, 113)], ["hold"] * 3)
        self.assertTrue(all(d[uuid_of(i)]["reason"].startswith("proof on file: human review") for i in (110, 112, 113)))
        self.assertEqual(d[uuid_of(111)]["decision"], "approve", "an approval is not an ask")
        self.assertEqual(support_ids(w), [uuid_of(114)])
        self.assertEqual((res.support_candidates, res.held_proof, res.support, res.held), (4, 3, 1, 3))
        self.assertIn("4 before filters, 3 held for proof on file", res.line())
        self.assertIn("1 sent", res.line())

    # [key=pof-user-scope] (proof-loop lead 2026-10-27 via firstmate 009): proof on file is scoped to the
    # REQUEST. A whole-user entry covers only requests that existed when the proof arrived.
    def at(self, minutes):
        return (T.NOW + timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")

    def test_a_whole_user_proof_covers_only_requests_that_existed_when_it_arrived(self):
        self.proof([{"user_id": 801, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c1",
                     "proof_at": self.at(-60)}])
        older, newer = uuid_of(130), uuid_of(131)
        rows = [req(older, uid=801, track="t1", created=self.at(-120)),
                req(newer, uid=801, track="t1", created=self.at(-30))]
        res, w = self.go(rows, self.RAWS)
        d = self.decisions()
        self.assertEqual(d[older]["decision"], "hold")
        self.assertTrue(d[older]["reason"].startswith("proof on file: human review"))
        self.assertEqual(support_ids(w), [newer], "a request created after the newest proof is not covered")

    def test_anything_not_known_keeps_todays_whole_user_cover(self):
        self.proof([{"user_id": 802, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c1"},
                    {"user_id": 803, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "m1",
                     "proof_at": self.at(-60)},
                    {"user_id": 803, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c2"},
                    {"user_id": 804, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "m2",
                     "proof_at": self.at(-60)}])
        rows = [req(uuid_of(132), uid=802, track="t1", created=self.at(-30)),       # undated entry
                req(uuid_of(133), uid=803, track="t1", created=self.at(-30)),       # one dated + one undated
                req(uuid_of(134), uid=804, track="t1")]                             # request without createdAt
        rows[2].pop("createdAt")
        res, w = self.go(rows, self.RAWS)
        self.assertEqual(support_ids(w), [])
        self.assertTrue(all(self.decisions()[uuid_of(i)]["decision"] == "hold" for i in (132, 133, 134)))

    def test_request_scoped_entries_and_proof_intake_cover_only_their_requests(self):
        self.proof([{"user_id": 805, "request_id": uuid_of(135), "kind": "pending_doc", "source": "intercom",
                     "ref": "c1"}])
        db = sqlite3.connect(decide.STAGE2_STORE)
        db.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json, conversation_id,"
                   " source, file_sha256, received_at, filed_by) VALUES ('806:x', 806, 'credit', ?, 'c9', 'intercom',"
                   " 'x', ?, 'test')", (json.dumps([uuid_of(137).upper()]), self.at(-5)))
        db.commit()
        db.close()
        rows = [req(uuid_of(i), uid=u, track="t1") for i, u in ((135, 805), (136, 805), (137, 806), (138, 806))]
        res, w = self.go(rows, self.RAWS)
        d = self.decisions()
        self.assertEqual([d[uuid_of(i)]["decision"] for i in (135, 137)], ["hold", "hold"])
        self.assertEqual(sorted(support_ids(w)), [uuid_of(136), uuid_of(138)],
                         "the user's OTHER requests are not covered by a request-scoped entry or a filing")

    def test_an_unreadable_proof_intake_keeps_whole_user_cover_and_says_so(self):
        self.proof([{"user_id": 807, "request_id": uuid_of(139), "kind": "pending_doc", "source": "intercom",
                     "ref": "c1"},
                    {"user_id": 808, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c2",
                     "proof_at": self.at(-60)}])
        db = sqlite3.connect(decide.STAGE2_STORE)
        db.execute("DROP TABLE proof_intake")
        db.commit()
        db.close()
        rows = [req(uuid_of(140), uid=807, track="t1"), req(uuid_of(141), uid=808, track="t1", created=self.at(-30))]
        res, w = self.go(rows, self.RAWS)
        self.assertEqual(support_ids(w), [], "no scope without proof_intake: nobody newly asked")
        self.assertTrue(any("proof_intake unreadable" in m for m in self.logged), self.logged)

    def test_a_non_request_id_entry_is_whole_user(self):
        self.proof([{"user_id": 809, "request_id": "legacy-ticket-12", "kind": "pending_doc", "source": "intercom",
                     "ref": "c1", "proof_at": self.at(-60)}])
        proof, why = decide.proof_on_file(now=T.NOW)
        proof = decide.with_intake(proof)
        self.assertIsNone(why)
        self.assertIn(809, proof.user_level)
        before = decide.Decision(request_id=uuid_of(142), profile_id="p", user_id=809, track_id="t", track_title="t",
                                 claimed_roles=[], popularity=None, big_track=False, decision="", reason="",
                                 request_created_at=self.at(-90))
        after = dataclasses.replace(before, request_id=uuid_of(143), request_created_at=self.at(-10))
        self.assertEqual((proof.covers(before), proof.covers(after)), (True, False))

    def test_stage2_hands_a_covered_request_to_the_gap_ask_never_to_a_support_write(self):
        # Fable 2026-10-26 13:23Z GO 2: need_more -> gap-ask, no_document -> uvn-status. The request
        # stays held (no Knock re-ask outside the verify ledger) and is labelled for the gate's ask;
        # an approved proof naming the request, or any other verdict, keeps the plain hold.
        self.proof([{"user_id": 701, "request_id": None, "kind": "human_approved_after_doc", "source": "intercom",
                     "ref": "c1"},
                    {"user_id": 702, "request_id": uuid_of(122), "kind": "approved_doc", "source": "core", "ref": ""},
                    {"user_id": 703, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c3"},
                    {"user_id": 704, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c4"}])
        store = str(decide.STAGE2_STORE)
        stage2_row(store, uuid_of(120), "Mixing", 701, "need_more")
        stage2_row(store, uuid_of(121), "Mixing", 701, "no_document")
        stage2_row(store, uuid_of(122), "Mixing", 702, "need_more")
        stage2_row(store, uuid_of(123), "Mixing", 703, "review")
        stage2_row(store, uuid_of(124), "Mixing", 704, "need_more", version="pf-0")   # stale analyzer
        rows = [req(uuid_of(i), uid=u, track="t1") for i, u in ((120, 701), (121, 701), (122, 702), (123, 703),
                                                                  (124, 704))]
        res, w = self.go(rows, self.RAWS)
        d = self.decisions()
        self.assertEqual(support_ids(w), [], "no support write (Knock notice) for anyone with proof on file")
        self.assertTrue(all(d[uuid_of(i)]["decision"] == "hold" for i in range(120, 125)))
        self.assertIn("--campaign gap-ask", d[uuid_of(120)]["reason"])
        self.assertIn("--campaign uvn-status", d[uuid_of(121)]["reason"])
        for i in (120, 121):
            self.assertTrue(d[uuid_of(i)]["reason"].startswith("proof on file"), "stage 2 still reads these as held")
        for i in (122, 123, 124):
            self.assertTrue(d[uuid_of(i)]["reason"].startswith("proof on file: human review"), i)
        self.assertEqual((res.held_stage2_ask, res.held_proof), (2, 3))
        self.assertIn("2 held for proof on file and handed to the stage-2 ask", res.line())

    def test_an_unreadable_stage2_store_releases_nothing(self):
        self.proof([{"user_id": 701, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c1"}])
        decide.STAGE2_STORE.write_text("not sqlite")
        res, w = self.go([req(uuid_of(130), uid=701, track="t1")], self.RAWS)
        self.assertTrue(self.decisions()[uuid_of(130)]["reason"].startswith("proof on file: human review"))
        self.assertEqual((res.held_stage2_ask, res.held_proof, support_ids(w)), (0, 1, []))
        self.assertTrue(any("stage-2 verdicts unreadable" in m for m in self.logged))

    def test_daily_ask_cap_limits_distinct_users_and_keeps_a_users_batch_whole(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=2)
        rows = [req(uuid_of(160), uid=801, track="t1"), req(uuid_of(161), uid=801, track="t9"),
                req(uuid_of(162), uid=802, track="t1"), req(uuid_of(163), uid=803, track="t1")]
        res, w = self.go(rows, self.RAWS, policy=policy)
        self.assertEqual(sorted(support_ids(w)), sorted([uuid_of(160), uuid_of(161), uuid_of(162)]))
        d = self.decisions()
        self.assertEqual(d[uuid_of(163)]["decision"], "defer")
        self.assertTrue(d[uuid_of(163)]["reason"].startswith(decide.ASK_CAP_DEFER))
        self.assertEqual(res.deferred_ask_cap, 1)
        self.assertIn("1 deferred by the daily ask cap", res.line())

    def test_daily_ask_cap_counts_users_already_asked_today(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=1)
        res, w = self.go([req(uuid_of(170), uid=811, track="t1")], self.RAWS, policy=policy)
        self.assertEqual(support_ids(w), [uuid_of(170)])
        res2, w2 = self.go([req(uuid_of(171), uid=812, track="t1")], self.RAWS, policy=policy)
        self.assertEqual(self.support_writes(w2), [], "the day's one ask slot is already used")
        self.assertEqual(res2.deferred_ask_cap, 1)

    def test_ask_cap_is_rechecked_at_the_write_boundary_for_overlapping_runs(self):
        # Run A decides against an empty day; before it reaches the write lock,
        # an overlapping run B has already asked another user and used the day's
        # only slot. Run A must defer at the write boundary (QA on #1251).
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=1)
        admin = T.FakeAdmin([], self.RAWS, PROFILES, TRACKS)

        def run_b_sends_first():
            b = decide.Decision(request_id=uuid_of(181), profile_id=T.PID_GOOD, user_id=822, track_id="t1",
                                track_title="x", claimed_roles=["Mixing"], popularity=88, big_track=True,
                                decision="support", reason="run B")
            decide.record_decision(self.db, "run-B", "apply", b)
            decide.record_outcome(self.db, "run-B", uuid_of(181), "support", decide.UVN, T.NOW)
            return T.NOW
        w = Writer(self.db)
        res = decide.run(admin, self.db, None, mode="apply", policy=policy, writer=w, now=T.NOW,
                         clock=run_b_sends_first, rows=[req(uuid_of(180), uid=821, track="t1")])
        sent = [i for c in w.calls if c["status"] == decide.UVN for i in c["ids"]]
        self.assertEqual(sent, [], "run B used the day's only slot; run A's ask is deferred at the write boundary")
        self.assertEqual(res.deferred_ask_cap, 1)
        outs = [o["outcome"] for o in decide.explain(self.db, uuid_of(180))[0]["outcomes"]]
        self.assertEqual(outs, ["deferred:daily_ask_cap"])

    def test_ask_cap_uses_the_send_day_not_the_run_start_day(self):
        self.proof([], generated_at="2026-10-11T23:30:00Z")
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=1)
        before = T.NOW.replace(hour=23, minute=45)
        after = before + timedelta(minutes=20)        # crosses UTC midnight before the PUT
        admin = T.FakeAdmin([], self.RAWS, PROFILES, TRACKS)
        decide.run(admin, self.db, None, mode="apply", policy=policy, writer=Writer(self.db), now=before,
                   clock=lambda: after, rows=[req(uuid_of(190), uid=831, track="t1")])
        w2 = Writer(self.db)
        res2 = decide.run(admin, self.db, None, mode="apply", policy=policy, writer=w2, now=after,
                          rows=[req(uuid_of(191), uid=832, track="t1")])
        self.assertEqual([i for c in w2.calls for i in c["ids"] if c["status"] == decide.UVN], [],
                         "the first ask was recorded on the day it was SENT, so the cap holds")
        self.assertEqual(res2.deferred_ask_cap, 1)

    def test_ask_cap_day_is_read_at_the_support_write_not_before_approvals(self):
        # QA on #1251 (2nd round): the lock is taken at 23:59, approval writes
        # finish after midnight, then support is sent; it must count on the new day.
        self.proof([], generated_at="2026-10-11T23:30:00Z")
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=1)
        before = T.NOW.replace(hour=23, minute=59)
        after = before + timedelta(minutes=3)
        ticks = iter([before, before] + [after] * 20)   # approval PUT starts and ends before midnight
        admin = T.FakeAdmin([], self.RAWS, PROFILES, TRACKS)
        w = Writer(self.db)
        res = decide.run(admin, self.db, None, mode="apply", policy=policy, writer=w, now=before,
                         clock=lambda: next(ticks),
                         rows=[req(uuid_of(200), uid=850), req(uuid_of(201), uid=851, track="t1")])
        self.assertEqual((res.approved, res.support), (1, 1))
        at = {o["outcome"]: o["at"] for o in decide.explain(self.db, uuid_of(201))[0]["outcomes"]}
        self.assertEqual(at[decide.UVN], decide.utc(after))
        w2 = Writer(self.db)
        res2 = decide.run(admin, self.db, None, mode="apply", policy=policy, writer=w2, now=after,
                          rows=[req(uuid_of(202), uid=852, track="t1")])
        self.assertEqual([i for c in w2.calls for i in c["ids"] if c["status"] == decide.UVN], [])
        self.assertEqual(res2.deferred_ask_cap, 1)

    def test_a_support_put_in_flight_across_midnight_counts_on_the_later_day(self):
        # QA on #1251 (3rd round): the PUT starts at 23:59:59 and returns after
        # midnight; the asks must be booked to the new day.
        self.proof([], generated_at="2026-10-11T23:30:00Z")
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=1)
        pre = T.NOW.replace(hour=23, minute=59, second=59)
        post = pre + timedelta(seconds=4)
        ticks = iter([pre] + [post] * 20)       # cap check before the PUT, then the PUT returns
        admin = T.FakeAdmin([], self.RAWS, PROFILES, TRACKS)
        res = decide.run(admin, self.db, None, mode="apply", policy=policy, writer=Writer(self.db), now=pre,
                         clock=lambda: next(ticks), rows=[req(uuid_of(210), uid=861, track="t1")])
        self.assertEqual(res.support, 1)
        at = {o["outcome"]: o["at"] for o in decide.explain(self.db, uuid_of(210))[0]["outcomes"]}
        self.assertEqual(at[decide.UVN], decide.utc(post))
        w2 = Writer(self.db)
        res2 = decide.run(admin, self.db, None, mode="apply", policy=policy, writer=w2, now=post,
                          rows=[req(uuid_of(211), uid=862, track="t1")])
        self.assertEqual([i for c in w2.calls for i in c["ids"] if c["status"] == decide.UVN], [])
        self.assertEqual(res2.deferred_ask_cap, 1)

    def test_policy_ask_cap_defaults_and_validates(self):
        # Fable ruling 1 (credit-backlog-1019): 100 -> 400 users/day after the 48h go-live cap.
        self.assertEqual(decide.Policy.load().max_ask_users_per_day, 400)
        with self.assertRaises(ValueError):
            decide._nonneg_int(-1, "max_ask_users_per_day")
        with self.assertRaises(ValueError):
            decide._nonneg_int(True, "max_ask_users_per_day")

    def test_unknown_proof_status_sends_no_support_request_at_all(self):
        rows = [req(uuid_of(120), track="t1"), req(uuid_of(121))]
        cases = {"missing": None, "old": "2026-10-10T23:00:00Z", "not authoritative": "{}"}  # word the logged reason carries
        for why, content in cases.items():
            if content is None:
                decide.PROOF_ON_FILE.unlink(missing_ok=True)
            elif content.startswith("{"):
                decide.PROOF_ON_FILE.write_text(content)
            else:
                self.proof(generated_at=content)
            self.logged.clear()
            res, w = self.go(rows, self.RAWS)
            self.assertEqual(support_ids(w), [], why)
            last = {r[0]: (r[1], r[2]) for r in self.db.execute(
                "SELECT request_id, decision, reason FROM decisions WHERE run_id = ?", (res.run_id,))}
            self.assertEqual(last[uuid_of(120)][0], "defer", why)
            self.assertTrue(last[uuid_of(120)][1].startswith("proof_status_unknown"), why)
            self.assertEqual(last[uuid_of(121)][0], "approve", "approvals are unaffected")
            self.assertEqual(res.deferred_proof_unknown, 1, why)
            self.assertTrue(any("proof-on-file status unknown" in m and why in m for m in self.logged), why)
        bad = {"user_id": True, "request_id": None, "kind": "pending_doc", "source": "x", "ref": "y"}
        self.proof([bad])
        self.assertIsNone(decide.proof_on_file(now=T.NOW)[0])
        self.proof([{**bad, "user_id": 5, "kind": "maybe"}])
        self.assertIsNone(decide.proof_on_file(now=T.NOW)[0])

    def test_a_missing_or_stale_source_makes_proof_status_unknown(self):
        """A user whose proof sits only in an unusable part is absent from entries:
        asking them now would re-ask for documents already given. The rule is the
        shared credit_review.proof_parts (all three parts required, for everyone)."""
        g = "2026-10-11T02:12:00Z"
        core, inter, gmail = ({"name": "core", "generated_at": g}, {"name": "cs-intercom", "generated_at": g},
                              {"name": "cs-gmail", "generated_at": g})
        cases = {
            "part 'cs-gmail' is missing": [core, inter],
            "part 'cs-gmail' is marked missing": [core, inter, {"name": "cs-gmail", "missing": True}],
            "part 'cs-intercom' is marked stale": [core, {**inter, "stale": True}, gmail],
            "part 'core' is": [{"name": "core", "generated_at": "2026-10-10T00:00:00Z"}, inter, gmail],
            "stale or missing part(s): x-part": [core, inter, gmail, {"name": "x-part", "missing": True}],
        }
        for n, (why, srcs) in enumerate(cases.items()):
            self.proof(sources=srcs)
            res, w = self.go([req(uuid_of(130 + n), uid=760 + n, track="t1")], self.RAWS)
            self.assertEqual(support_ids(w), [], why)
            d = self.decisions()[uuid_of(130 + n)]
            self.assertEqual(d["decision"], "defer", why)
            self.assertTrue(d["reason"].startswith("proof_status_unknown"), why)
            self.assertIn(why, d["reason"])
            self.assertEqual(res.deferred_proof_unknown, 1, why)

    def test_support_contacts_are_held_never_asked(self):
        """firstmate 041: everyone who emailed support@ in the last 90 days is held for
        a human, even with no document found; everyone else may be asked."""
        self.proof(contacts=[781])
        res, w = self.go([req(uuid_of(160), uid=781, track="t1"), req(uuid_of(161), uid=782, track="t1")], self.RAWS)
        d = self.decisions()
        self.assertEqual(d[uuid_of(160)]["decision"], "hold")
        self.assertIn("emailed support@", d[uuid_of(160)]["reason"])
        self.assertEqual(support_ids(w), [uuid_of(161)])

    def test_a_missing_or_malformed_contact_list_asks_nobody(self):
        for bad in (None, {"user_ids": "x"}, [True], ["abc"]):
            self.proof()
            doc = json.loads(decide.PROOF_ON_FILE.read_text())
            if bad is None:
                doc.pop("gmail_contacts_90d")
            else:
                doc["gmail_contacts_90d"] = bad
            decide.PROOF_ON_FILE.write_text(json.dumps(doc))
            p, why = decide.proof_on_file(now=T.NOW)
            self.assertIsNone(p, bad)
            self.assertIn("gmail_contacts_90d", why)
        sc = decide.proof_parts.support_contacts
        kw = dict(now=T.NOW, max_age_h=3, max_skew_h=0.1)
        fresh = (T.NOW - decide.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        stale = (T.NOW - decide.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(sc({"gmail_contacts_90d": {"generated_at": fresh, "user_ids": [1, "2"]}}, **kw), frozenset({1, 2}))
        # QA review of #1257 @53428d0: the embedded snapshot needs its OWN fresh stamp.
        for bad in ([1, "2"], {"user_ids": [1]}, {"generated_at": stale, "user_ids": [1]}):
            self.assertIsNone(sc({"gmail_contacts_90d": bad}, **kw), bad)

    def test_a_credit_is_asked_about_once_ever(self):
        row = req(uuid_of(140), uid=720, track="t1")
        res1, w1 = self.go([row], self.RAWS)
        self.assertEqual(self.support_writes(w1), [uuid_of(140)])
        self.clear_readback()
        res2, w2 = self.go([row], self.RAWS, now=T.NOW + decide.timedelta(days=5))
        self.assertEqual(self.support_writes(w2), [])
        last = [r for r in self.db.execute("SELECT decision, reason FROM decisions WHERE run_id = ?", (res2.run_id,))]
        self.assertEqual(last[0][0], "hold")
        self.assertIn("never re-ask", last[0][1])
        self.assertEqual(res2.held_reasked, 1)

    def test_one_support_batch_per_user_per_24h(self):
        first = [req(uuid_of(150), uid=730, track="t1"), req(uuid_of(151), uid=730, track="t2")]
        res1, w1 = self.go(first, self.RAWS)
        self.assertEqual(sorted(self.support_writes(w1)), sorted(r["id"] for r in first), "one run = one batch")
        self.clear_readback()
        later = [req(uuid_of(152), uid=730, track="t1"), req(uuid_of(153), uid=731, track="t1")]
        res2, w2 = self.go(later, self.RAWS, now=T.NOW + decide.timedelta(hours=3))
        self.assertEqual(self.support_writes(w2), [uuid_of(153)])
        self.assertEqual(res2.deferred_window, 1)
        self.clear_readback()
        res3, w3 = self.go([later[0]], self.RAWS, now=T.NOW + decide.timedelta(hours=25))
        self.assertEqual(self.support_writes(w3), [uuid_of(152)])

    def run_at(self, now, held):
        """One scheduled run at ``now`` over the held queue as the admin API lists it."""
        admin = T.FakeAdmin(list(held), self.RAWS, PROFILES, TRACKS)
        w = Writer(self.db)
        self.proof(generated_at=decide.utc(now - decide.timedelta(minutes=30)))
        res = decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY, writer=w, now=now)
        self.clear_readback()
        return res, w

    def test_a_users_waiting_rows_go_out_together_after_the_window(self):
        h = decide.timedelta(hours=1)
        r1, r2, r3 = (req(uuid_of(160 + i), uid=740, track="t1") for i in range(3))
        _, w = self.run_at(T.NOW, [r1])
        self.assertEqual(support_ids(w), [r1["id"]])
        self.run_at(T.NOW + h / 2, [r2])
        self.run_at(T.NOW + 1.25 * h, [r2, r3])
        res, w = self.run_at(T.NOW + 23.25 * h, [r2, r3])
        self.assertEqual((res.scanned, w.calls), (0, []), "waiting rows are not re-decided inside the window")
        res, w = self.run_at(T.NOW + 24.5 * h, [r2, r3])
        self.assertEqual([sorted(c["ids"]) for c in w.calls if c["status"] == decide.UVN],
                         [sorted([r2["id"], r3["id"]])], "one batch once the window ends")

    def test_held_rows_are_not_rebuilt_every_two_hours(self):
        h = decide.timedelta(hours=1)
        asked = req(uuid_of(170), uid=750, track="t1")
        proofed = req(uuid_of(171), uid=751, track="t1")
        self.run_at(T.NOW, [asked])
        entry = {"user_id": 751, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "c9"}

        def run(now):
            admin = T.FakeAdmin([asked, proofed], self.RAWS, PROFILES, TRACKS)
            self.proof([entry], generated_at=decide.utc(now - decide.timedelta(minutes=30)))
            return decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY, writer=Writer(self.db),
                              now=now)

        res = run(T.NOW + 3 * h)
        self.assertEqual((res.scanned, res.held), (2, 2))
        self.assertEqual(run(T.NOW + 6 * h).scanned, 0, "neither hold is rebuilt 3h later")
        res = run(T.NOW + 28 * h)
        self.assertEqual((res.scanned, res.held_proof), (1, 1), "the proof hold is looked at again after 24h")

    def test_unknown_proof_status_is_announced_once_per_outage(self):
        notes = []
        for n, present in enumerate((True, False, False, False, True, True, False)):
            if present:
                self.proof()
            else:
                decide.PROOF_ON_FILE.unlink(missing_ok=True)
            res, w = super().go([req(uuid_of(180 + n), uid=760 + n, track="t1")], self.RAWS, judge=self.NOT_FOUND)
            self.clear_readback()
            if not present:
                self.assertEqual((res.support, w.calls), (0, []))
            notes.append(res.note)
        self.assertEqual(notes[0], "")
        self.assertIn("PROOF-ON-FILE STATUS UNKNOWN", notes[1])
        self.assertEqual(notes[2:4], ["", ""], "quiet while the outage lasts")
        self.assertEqual(notes[4], "PROOF-ON-FILE status restored: support requests resume.")
        self.assertEqual(notes[5], "")
        self.assertIn("PROOF-ON-FILE STATUS UNKNOWN", notes[6], "a new outage is announced again")

    def test_announced_runs_are_posted_by_the_cron(self):
        decide.PROOF_ON_FILE.unlink()
        res, _ = super().go([req(uuid_of(190), uid=790, track="t1")], self.RAWS, judge=self.NOT_FOUND)
        self.assertIn("PROOF-ON-FILE STATUS UNKNOWN", res.line())

    def go(self, rows, raws=None, judge=None, now=None, **kw):
        if now is None:
            return super().go(rows, raws, judge=judge or self.NOT_FOUND, **kw)
        admin = T.FakeAdmin([], raws or {}, PROFILES, TRACKS)
        w = Writer(self.db)
        self.proof(generated_at=decide.utc(now - decide.timedelta(minutes=30)))
        res = decide.run(admin, self.db, judge or self.NOT_FOUND, mode="apply", policy=POLICY, writer=w, now=now,
                         rows=rows, **kw)
        return res, w


class ValidatorRejectAndProof(Base):
    RAWS = {"small": [T.raw("Real Engineer", "mixer")]}

    def test_a_trusted_confirmed_reject_row_is_held_by_the_shared_predicate(self):
        from credit_review.policy import AgentApprovalContext, approver_identity_alert, validator_rejected_rules
        row = req(uuid_of(200), vd_rules={"reject_high_velocity_profile": 100, "reject_artist_credit": 0})
        res, w = self.go([row], self.RAWS, judge=FakeJudge(credible()))
        d = self.decisions()[uuid_of(200)]
        self.assertEqual((d["decision"], d["doc_required"], w.calls), ("hold", 0, []))
        self.assertIn("reject_high_velocity_profile", d["reason"])
        self.assertNotIn("reject_artist_credit", d["reason"])
        self.assertEqual(validator_rejected_rules(row["verificationData"]), ["reject_high_velocity_profile"])
        approved = dict(row, status="approved")
        approved["metadata"] = {**row["metadata"], "approval": {"via": "admin", "isAgent": True,
                                                                "account": "agent-credit-decider@muso.ai"}}
        ev = decide.EvidenceBuilder(T.FakeAdmin([], self.RAWS, PROFILES, TRACKS), now=T.NOW).build(approved)
        alert = approver_identity_alert(approved, ev, AgentApprovalContext(frozenset({"credit-trust-decide"}), TERMS))
        self.assertIn("the validator declined it (reject_high_velocity_profile)", alert)
        clean = req(uuid_of(201), uid=601)
        self.go([clean], self.RAWS)
        self.assertEqual(self.decisions()[uuid_of(201)]["decision"], "approve")

    def mark_doc_required(self, rid, mode="apply"):
        d = decide.Decision(request_id=rid, profile_id=T.PID_GOOD, user_id=500, track_id="small", track_title="Song",
                            claimed_roles=["Mixing"], popularity=20, big_track=True, decision="support",
                            reason="big track", doc_required=True)
        decide.record_decision(self.db, "earlier-run", mode, d, T.NOW - decide.timedelta(days=3))

    def test_a_documentation_required_row_needs_a_recorded_proof_to_be_approved(self):
        from credit_review import runner
        no_proof, with_proof, shadow_marked = uuid_of(210), uuid_of(211), uuid_of(212)
        for rid in (no_proof, with_proof):
            self.mark_doc_required(rid)
        self.mark_doc_required(shadow_marked, mode="shadow")
        self.proof([{"user_id": 990, "request_id": with_proof, "kind": "approved_doc", "source": "intercom",
                     "ref": "conv-42"},
                    {"user_id": 991, "request_id": no_proof, "kind": "pending_doc", "source": "email", "ref": "m-1"}])
        rows = [req(r, uid=600 + i) for i, r in enumerate((no_proof, with_proof, shadow_marked))]
        res, w = self.go(rows, self.RAWS)
        d = self.decisions()
        self.assertEqual(d[no_proof]["decision"], "hold", "a pending document is not a proof to approve on")
        self.assertIn("no approved proof is on file", d[no_proof]["reason"])
        self.assertEqual((d[with_proof]["decision"], d[with_proof]["proof_id"]), ("approve", "intercom:conv-42"))
        self.assertEqual((d[shadow_marked]["decision"], d[shadow_marked]["proof_id"]), ("approve", None),
                         "a shadow run's marker does not count")
        approve = next(c for c in w.calls if c["status"] == decide.APPROVED)
        self.assertEqual(sorted(approve["ids"]), sorted([with_proof, shadow_marked]))
        ctx = runner.agent_approval_context(self.ledger)
        self.assertEqual(ctx.proof_ids.get(with_proof), "intercom:conv-42")
        self.assertIn(no_proof, ctx.doc_required_ids)
        self.assertNotIn(shadow_marked, ctx.doc_required_ids)

    def test_unknown_proof_status_defers_a_documentation_required_approval(self):
        rid = uuid_of(213)
        self.mark_doc_required(rid)
        decide.PROOF_ON_FILE.unlink()
        res, w = self.go([req(rid, uid=620)], self.RAWS)
        d = self.decisions()[rid]
        self.assertEqual((d["decision"], w.calls), ("defer", []))
        self.assertTrue(d["reason"].startswith("proof_status_unknown"), d["reason"])
        self.assertEqual(res.deferred_proof_unknown, 1)
        self.proof([{"user_id": 620, "request_id": rid, "kind": "approved_doc", "source": "email", "ref": "m-9"}])
        res, w = self.go([req(rid, uid=620)], self.RAWS)
        last = self.db.execute("SELECT decision, proof_id FROM decisions WHERE run_id = ?", (res.run_id,)).fetchone()
        self.assertEqual(tuple(last), ("approve", "email:m-9"), "once the export is back it is approved on the proof")

    def test_shadow_runs_never_mark_documentation_required(self):
        res, _ = self.go([req(uuid_of(220), track="t1")], {"t1": [T.raw("Real Engineer", "mixer")]}, mode="shadow")
        d = self.decisions()[uuid_of(220)]
        self.assertEqual((d["decision"], d["doc_required"]), ("support", 0))


class AdminIdentity(unittest.TestCase):
    def test_the_decider_writes_as_its_own_admin_identity(self):
        tmp = Path(tempfile.mkdtemp())
        script, seen = tmp / "wrapper.sh", tmp / "seen"
        script.write_text(f'#!/usr/bin/env bash\nprintf "%s %s %s\\n" "$MUSO_ADMIN_IDENTITY" "$CREDIT_TRUST_DECIDE" "$*" > {seen}\n'
                          'echo \'{"http_status":200,"body":{"data":{"updatedIds":["a"]}}}\'\n')
        old = os.environ.pop("MUSO_ADMIN_IDENTITY", None)
        try:
            body = decide.admin_writer(str(script))("approved", ["a"], "unverified")
        finally:
            if old is not None:
                os.environ["MUSO_ADMIN_IDENTITY"] = old
        self.assertEqual(body["data"]["updatedIds"], ["a"])
        identity, flag, argv = seen.read_text().split(" ", 2)
        self.assertEqual((identity, flag), ("credit-decider", "1"))
        self.assertIn("--requester credit-trust-decide@hydra-ops", argv)

    def test_score_approve_writes_with_its_own_requester_and_flag_never_the_deciders(self):
        """2026-10-22 18:25Z: score-approve PUT user_verification_needed rows as the decider and
        the wrapper's decider branch (unverified only) sent all 31 to the browser-evidence gate."""
        from credit_review import score_approve as sa
        tmp = Path(tempfile.mkdtemp())
        script, seen = tmp / "wrapper.sh", tmp / "seen"
        script.write_text(f'#!/usr/bin/env bash\nprintf "%s %s %s %s\\n" "$MUSO_ADMIN_IDENTITY" "$CREDIT_TRUST_DECIDE" '
                          f'"$CREDIT_TRUST_SCORE_APPROVE" "$*" > {seen}\n'
                          'echo \'{"http_status":200,"body":{"data":{"updatedIds":["a"]}}}\'\n')
        old = {k: os.environ.pop(k, None) for k in ("MUSO_ADMIN_IDENTITY", "CREDIT_TRUST_DECIDE")}
        os.environ["CREDIT_TRUST_DECIDE"] = "1"  # an inherited decider flag must not leak into score-approve
        try:
            decide.admin_writer(str(script), requester=sa.REQUESTER,
                                automation_flag="CREDIT_TRUST_SCORE_APPROVE")("approved", ["a"], "user_verification_needed")
        finally:
            os.environ.pop("CREDIT_TRUST_DECIDE", None)
            for k, v in old.items():
                if v is not None:
                    os.environ[k] = v
        identity, decide_flag, score_flag, argv = seen.read_text().split(" ", 3)
        self.assertEqual((identity, decide_flag, score_flag), ("credit-decider", "0", "1"))
        self.assertIn("--requester credit-trust-score-approve@hydra-ops", argv)
        self.assertIn('"expectedStatus":"user_verification_needed"', argv)


class PartialWrites(Base):
    def test_failed_put_records_what_the_server_committed(self):
        rows = [req(uuid_of(80 + i), uid=900 + i, track="t3") for i in range(3)]
        a, b, c = (r["id"] for r in rows)

        def writer(status, ids, expected):
            raise decide.WriteFailed("PUT HTTP 502", {"data": {"updatedIds": [a]}})
        asked = []

        def readback(status, ids):
            asked.append((status, list(ids)))
            return {b}
        admin = T.FakeAdmin([], {}, PROFILES, TRACKS)
        res = decide.run(admin, self.db, FakeJudge(credible()), mode="apply", policy=POLICY, writer=writer,
                         readback=readback, now=T.NOW, rows=rows)
        self.assertEqual(asked, [("approved", [b, c])])
        self.assertEqual((res.approved, len(res.write_errors)), (2, 1))
        self.assertEqual(sorted(decide.run_approvals(self.db, res.run_id)), sorted([a, b]))
        self.assertTrue(decide.explain(self.db, c)[0]["outcomes"][0]["outcome"].startswith("error:"))

        def broken(status, ids):
            raise decide.admin_api.AdminError("trino down")
        rows2 = [req(uuid_of(84), uid=950, track="t3")]
        res2 = decide.run(admin, self.db, FakeJudge(credible()), mode="apply", policy=POLICY,
                          writer=lambda *x: (_ for _ in ()).throw(decide.admin_api.AdminError("timeout")),
                          readback=broken, now=T.NOW, rows=rows2)
        self.assertEqual(res2.approved, 0)
        self.assertTrue(decide.explain(self.db, uuid_of(84))[0]["outcomes"][0]["outcome"].startswith("error:unverified:"))

    def test_status_readback_parses_the_verifier_report(self):
        script = Path(self.tmp) / "verify.sh"

        def verifier(rc, report):
            script.write_text(f"#!/bin/bash\necho '{json.dumps(report)}'\nexit {rc}\n")
            return decide.status_readback(str(script))
        ok = verifier(1, {"expected": "approved", "matched": 1, "mismatched": [{"id": "B", "actual": "unverified"}]})
        self.assertEqual(ok("approved", ["A", "B"]), {"A"})
        for rc, report in ((3, {}), (1, {"expected": "approved", "matched": 2, "mismatched": [{"id": "B"}]}),
                           (0, {"expected": "unverified", "matched": 2, "mismatched": []})):
            with self.assertRaises(decide.admin_api.AdminError):
                verifier(rc, report)("approved", ["A", "B"])


class Cli(unittest.TestCase):
    def test_decide_refuses_the_uncapped_openrouter_provider(self):
        cli = T.load_cli()
        tmp = Path(tempfile.mkdtemp())
        cli.KILL_SWITCH = tmp / "absent"
        decide.KILL_SWITCH, old = tmp / "absent2", decide.KILL_SWITCH
        try:
            self.assertEqual(cli.main(["--ledger", str(tmp / "l.sqlite3"), "decide", "--provider", "openrouter"]), 2)
        finally:
            decide.KILL_SWITCH = old

    def test_shipped_policy_pins_user_15(self):
        p = decide.Policy.load()
        self.assertNotIn(15, p.deny_user_ids, "no named-user rules: the fixture user is caught by the score")
        self.assertIn("94ad2ad2-0be9-4b8e-94a6-dc85eb100310", p.deny_profile_ids)
        self.assertTrue(p.editorial_role_terms)


class ServerAgentGuardMirror(Base):
    """Approvals core-backend's T12 agent guard would refuse are never sent, and
    a refusal of some rows never rejects the rest of the batch (firstmate 036)."""

    RAWS = {"small": [T.raw("Real Engineer", "mixer")]}

    def test_stored_popularity_zero_goes_to_a_human_not_an_ask(self):
        res, w = self.go([req(uuid_of(300), pop=0)], self.RAWS)
        d = self.decisions()[uuid_of(300)]
        self.assertEqual(d["decision"], "hold")
        self.assertIn("popularity_unattributable", d["reason"])
        self.assertEqual(w.calls, [])

    def test_stored_big_popularity_or_client_metadata_or_proof_marker_asks_for_documents(self):
        rows = [req(uuid_of(301), pop=70), req(uuid_of(302)), req(uuid_of(303))]
        rows[1]["metadata"]["source"] = "client"
        rows[2]["metadata"]["proofRequest"] = {"at": "2026-10-10T00:00:00Z"}
        self.proof([])
        res, w = self.go(rows, self.RAWS)
        d = self.decisions()
        for i in (301, 302, 303):
            self.assertEqual(d[uuid_of(i)]["decision"], "support", i)
            self.assertIn("server approval guard would refuse", d[uuid_of(i)]["reason"])
        self.assertEqual([c for c in w.calls if c["status"] == decide.APPROVED], [])

    def test_validator_approved_row_is_not_scoped(self):
        r = req(uuid_of(304), pop=0)
        r["verificationData"]["is_approved"] = True
        res, w = self.go([r], self.RAWS)
        self.assertEqual(self.decisions()[uuid_of(304)]["decision"], "approve")

    def test_a_refusal_of_some_rows_never_rejects_the_rest_of_the_batch(self):
        refused = uuid_of(311)
        calls = []

        def writer(status, ids, expected):
            calls.append(list(ids))
            if refused in ids:
                raise decide.WriteFailed("PUT HTTP 400", {
                    "result": "error", "code": 400, "errorCode": "agent_cannot_approve_declined",
                    "refusedRequestIds": [refused],
                    "refused": [{"id": refused, "band": "B_request_info", "reasons": ["popularity_unattributable"]}]})
            return {"data": {"updatedIds": list(ids)}}
        outs, err = decide.write_chunk(writer, lambda st, ids: set(), decide.APPROVED,
                                       [uuid_of(310), refused, uuid_of(312)], decide.UNVERIFIED)
        self.assertIsNone(err)
        self.assertEqual(outs[uuid_of(310)], decide.APPROVED)
        self.assertEqual(outs[uuid_of(312)], decide.APPROVED)
        self.assertEqual(outs[refused], "skipped:agent_cannot_approve_declined:popularity_unattributable")
        self.assertEqual(calls, [[uuid_of(310), refused, uuid_of(312)], [uuid_of(310), uuid_of(312)]])

    def test_a_second_refusal_is_not_retried_again(self):
        def writer(status, ids, expected):
            raise decide.WriteFailed("PUT HTTP 400", {"errorCode": "agent_cannot_approve_declined",
                                                       "refusedRequestIds": [ids[0]], "refused": []})
        outs, err = decide.write_chunk(writer, lambda st, ids: set(), decide.APPROVED,
                                       [uuid_of(320), uuid_of(321)], decide.UNVERIFIED)
        self.assertTrue(outs[uuid_of(320)].startswith("skipped:agent_cannot_approve_declined"))
        self.assertTrue(outs[uuid_of(321)].startswith("error:"), "one retry only; then it is an error")
        self.assertIsNotNone(err)

# ── the support-only writer (Fable d2 [key=decider-support-arm], 2026-11-04) ────────────────────
# The decider is re-enabled as a SUPPORT-ONLY writer: support keeps writing unverified ->
# user_verification_needed, and an approval is RECORDED and NEVER WRITTEN. Each test below is one
# of d2's six conditions; a condition without a failing-when-removed test is not shipped.
#   fixture facts (measured, not guessed): track "t3" + a credible judge approves, "t1" asks,
#   "small" holds. Every class carries its own RAWS.
APPROVE_RAWS = {"t3": [T.raw("Real Engineer", "mixer")], "t1": [], "small": [], "t9": []}
BARE_POLICY = {"deny_user_ids": [], "deny_profile_ids": [], "editorial_role_terms": ["editor"]}


def support_ids(w):
    """The ids a run actually wrote user_verification_needed for."""
    return [i for c in w.calls if c["status"] == decide.UVN for i in c["ids"]]


def utc_stamp():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class SupportOnlyArm(Base):
    """Condition 1: support-only enforced in code (the kill file is defence in depth)."""

    RAWS = APPROVE_RAWS

    def approve_calls(self, w):
        return [c for c in w.calls if c["status"] == decide.APPROVED]

    def test_approve_verdict_is_recorded_and_never_written_when_the_arm_is_off(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, approve_arm=False)
        rows = [req(uuid_of(400), uid=901, track="t3"), req(uuid_of(401), uid=902, track="t3")]
        res, w = self.go(rows, self.RAWS, judge=FakeJudge(credible()), policy=policy)
        d = self.decisions()
        for rid in (uuid_of(400), uuid_of(401)):
            self.assertEqual(d[rid]["decision"], "approve", "the VERDICT is still recorded: stage 2 reads it")
            outs = [o["outcome"] for o in decide.explain(self.db, rid)[0]["outcomes"]]
            self.assertEqual(outs, [decide.APPROVE_ARM_OFF_OUTCOME])
        self.assertEqual(self.approve_calls(w), [], "the approve arm wrote nothing")
        self.assertEqual((res.approved, res.held_approve_arm), (0, 2))
        self.assertIn("APPROVE ARM OFF", res.note)
        self.assertIn("2 approve verdict(s) recorded and NOT written", res.line())

    def test_support_keeps_writing_while_the_approve_arm_is_off(self):
        # The whole point of the scope: the same run that withholds an approval still asks.
        self.proof([])
        policy = dataclasses.replace(POLICY, approve_arm=False)
        rows = [req(uuid_of(402), uid=903, track="t3"), req(uuid_of(403), uid=904, track="t1")]
        res, w = self.go(rows, self.RAWS, judge=FakeJudge(credible()), policy=policy)
        d = self.decisions()
        self.assertEqual(d[uuid_of(402)]["decision"], "approve")
        self.assertEqual(d[uuid_of(403)]["decision"], "support")
        self.assertEqual(support_ids(w), [uuid_of(403)])
        self.assertEqual((res.support, res.approved, res.held_approve_arm), (1, 0, 1))

    def test_shadow_says_plainly_that_none_of_them_would_be_written(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, approve_arm=False)
        res, w = self.go([req(uuid_of(407), uid=908, track="t3")], self.RAWS,
                         judge=FakeJudge(credible()), mode="shadow", policy=policy)
        self.assertEqual(w.calls, [])
        self.assertEqual(res.approved, 1, "shadow still counts VERDICTS")
        self.assertIn("would be recorded and NOT written", res.note)

    def test_the_code_default_is_off_not_a_file_that_may_be_absent(self):
        self.assertFalse(decide.Policy(deny_user_ids=set(), deny_profile_ids=set(),
                                       editorial_role_terms=()).approve_arm,
                         "a policy object that says nothing means the arm is OFF")
        p = Path(self.tmp) / "policy.json"
        p.write_text(json.dumps(BARE_POLICY))
        self.assertFalse(decide.Policy.load(p).approve_arm, "a policy file that omits the key is OFF too")
        self.assertTrue(decide.approve_arm_off(decide.Policy(deny_user_ids=set(), deny_profile_ids=set(),
                                                             editorial_role_terms=())))

    def test_a_string_is_not_a_boolean(self):
        p = Path(self.tmp) / "policy.json"
        for bad in ("false", 0, "yes", None):
            p.write_text(json.dumps({**BARE_POLICY, "approve_arm": bad}))
            with self.assertRaises(ValueError):
                decide.Policy.load(p)

    def test_the_switch_blocks_an_armed_policy(self):
        self.proof([])
        decide.APPROVE_SWITCH.write_text("off")
        policy = dataclasses.replace(POLICY, approve_arm=True)
        res, w = self.go([req(uuid_of(404), uid=905, track="t3")], self.RAWS, judge=FakeJudge(credible()),
                         policy=policy)
        self.assertEqual(self.approve_calls(w), [])
        self.assertEqual(res.held_approve_arm, 1)
        self.assertIn("approve arm disabled by", res.note)

    def test_armed_and_unswitched_writes_the_approval(self):
        # The control: when a reviewed policy arms the arm and no switch exists, an approval
        # still writes. Without this test the "off" tests would pass on a writer that can never
        # approve anything at all.
        self.proof([])
        policy = dataclasses.replace(POLICY, approve_arm=True)
        res, w = self.go([req(uuid_of(405), uid=906, track="t3")], self.RAWS, judge=FakeJudge(credible()),
                         policy=policy)
        self.assertEqual([i for c in self.approve_calls(w) for i in c["ids"]], [uuid_of(405)])
        self.assertEqual((res.approved, res.held_approve_arm), (1, 0))

    def test_an_unreadable_switch_refuses(self):
        policy = dataclasses.replace(POLICY, approve_arm=True)
        with mock.patch.object(Path, "exists", side_effect=OSError("EACCES")):
            why = decide.approve_arm_off(policy)
        self.assertIn("unreadable", why)
        self.assertTrue(why, "cannot prove the switch absent => the arm is OFF")

    def test_the_write_boundary_refuses_even_if_a_caller_forgot(self):
        # The caller check runs before the write loop; the tripwire is inside write_ids(), so a
        # future caller that re-adds an approve path is refused by the boundary itself. Simulated
        # by letting the first check pass and the boundary check fail.
        self.proof([])
        policy = dataclasses.replace(POLICY, approve_arm=True)
        with mock.patch.object(decide, "approve_arm_off", side_effect=["", "approve arm disabled by /etc/x"]):
            res, w = self.go([req(uuid_of(406), uid=907, track="t3")], self.RAWS, judge=FakeJudge(credible()),
                             policy=policy)
        self.assertEqual(self.approve_calls(w), [], "refused AT the boundary, not only by the caller")
        outs = [o["outcome"] for o in decide.explain(self.db, uuid_of(406))[0]["outcomes"]]
        self.assertEqual(outs, [decide.APPROVE_ARM_OFF_OUTCOME])
        self.assertTrue(any("write boundary" in e for e in res.write_errors))


class PerRunUserCap(Base):
    """Condition 3: caps in USERS - at most 100 per run, paid first, one move per user per 24h."""

    RAWS = APPROVE_RAWS

    def test_the_default_is_100_users_per_run(self):
        self.assertEqual(decide.Policy.load().max_ask_users_per_run, 100)

    def test_run_cap_bounds_distinct_users_not_rows(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_run=2, max_ask_users_per_day=1000)
        rows = [req(uuid_of(410), uid=911, track="t1"), req(uuid_of(411), uid=911, track="t1"),
                req(uuid_of(412), uid=912, track="t1"), req(uuid_of(413), uid=913, track="t1"),
                req(uuid_of(414), uid=914, track="t1")]
        res, w = self.go(rows, self.RAWS, policy=policy)
        sent = sorted(support_ids(w))
        self.assertEqual(sent, sorted([uuid_of(410), uuid_of(411), uuid_of(412)]),
                         "two USERS (three rows: a user's batch stays whole), the rest wait")
        d = self.decisions()
        for rid in (uuid_of(413), uuid_of(414)):
            self.assertEqual(d[rid]["decision"], "defer")
            self.assertTrue(d[rid]["reason"].startswith(decide.RUN_CAP_DEFER))
        self.assertEqual(res.deferred_run_cap, 2)
        self.assertIn("2 deferred by the per-run ask cap", res.line())

    def test_run_cap_is_counted_across_chunks_at_the_write_boundary(self):
        # decide.BATCH chunks a run; a cap counted per chunk would admit BATCH x the users.
        decide.ensure_schema(self.db)
        res = decide.RunResult(run_id="run-x", mode="apply")
        user_of = {"a": 1, "b": 2, "c": 3}
        admitted: set[int] = set()
        first = decide.cap_at_write(self.db, res, ["a"], user_of, None, T.NOW, run_cap=2, admitted_run=admitted)
        second = decide.cap_at_write(self.db, res, ["b"], user_of, None, T.NOW, run_cap=2, admitted_run=admitted)
        third = decide.cap_at_write(self.db, res, ["c"], user_of, None, T.NOW, run_cap=2, admitted_run=admitted)
        self.assertEqual((first, second, third), (["a"], ["b"], []))
        self.assertEqual(res.deferred_run_cap, 1)


class AskLedgerClause(Base):
    """Condition 2: ONE named sender for the Knock ask - the tick's gates must see it."""

    RAWS = APPROVE_RAWS

    def asks(self):
        return self.db.execute("SELECT campaign, status, approved_by, request_ids_json, account_id,"
                               " n_credits FROM verify_messages").fetchall()

    def test_a_ledgered_ask_is_visible_to_the_next_tick(self):
        from credit_review import verify_ledger
        self.proof([])
        res, w = self.go([req(uuid_of(420), uid=921, track="t1")], self.RAWS)
        self.assertEqual(support_ids(w), [uuid_of(420)])
        rows = self.asks()
        self.assertEqual(len(rows), 1, "one row per ASKED USER, not per row")
        self.assertEqual((rows[0][0], rows[0][1], rows[0][2], rows[0][4]),
                         (verify_ledger.DECIDER_SUPPORT, "sent", decide.ASK_SENDER, "921"))
        self.assertEqual(json.loads(rows[0][3]), [uuid_of(420)])
        # The shared per-user locks now know, so a second campaign stands down today.
        self.assertTrue(verify_ledger.asked_within(self.db, user_key="", user_id="921", day="2020-01-01"))
        self.assertTrue(verify_ledger.capped(self.db, user_key="", user_id="921", day=T.NOW.strftime("%Y-%m-%d")))
        self.assertFalse(verify_ledger.prior_uvn_ask(self.db, user_key="", user_id="921"),
                         "the decider's in-app note is not the uvn-status EMAIL ask")
        self.assertEqual(res.asks_ledgered, 1)

    def test_one_row_per_user_covering_all_their_rows(self):
        self.proof([])
        res, w = self.go([req(uuid_of(421), uid=922, track="t1"), req(uuid_of(422), uid=922, track="t1")],
                         self.RAWS)
        self.assertEqual(len(support_ids(w)), 2)
        rows = self.asks()
        self.assertEqual(len(rows), 1)
        self.assertEqual(sorted(json.loads(rows[0][3])), sorted([uuid_of(421), uuid_of(422)]))
        self.assertEqual(rows[0][5], 2)

    def test_a_ledger_failure_is_booked_and_never_silent(self):
        from credit_review import verify_ledger
        self.proof([])
        with mock.patch.object(verify_ledger, "record_external_ask", side_effect=RuntimeError("db is busy")):
            res, w = self.go([req(uuid_of(423), uid=923, track="t1")], self.RAWS)
        self.assertEqual(support_ids(w), [uuid_of(423)], "the ask is out; the gap is what we book")
        self.assertTrue(any("ask ledger for user 923" in e for e in res.write_errors))
        self.assertIn("ASK LEDGER INCOMPLETE", res.note)
        keys = [r[0] for r in self.db.execute("SELECT k FROM state").fetchall()]
        self.assertTrue(any(k.startswith("support-writer:ask-ledger-error:") for k in keys))

    def test_a_failing_ledger_MIGRATION_still_owes_a_readback(self):
        """qa-review #1782 (r6) Important: the schema setup sat outside the per-user handler.

        A legacy ledger whose migration fails raised out of `ledger_asks()` - past the per-user booking AND past
        `record_apply_run()`, which is what records the read-back obligation. The asks had already LANDED, so the
        run left no `ask-ledger-error` state and no pending read-back, and a second apply was admitted without
        reconciling them. Measured through the apply entrypoint, not the helper.
        """
        from credit_review import verify_ledger
        self.proof([])
        with mock.patch.object(verify_ledger, "ensure_schema", side_effect=RuntimeError("migration failed")):
            res, w = self.go([req(uuid_of(426), uid=926, track="t1")], self.RAWS)
        self.assertEqual(support_ids(w), [uuid_of(426)], "the ask is out; the gap is what we book")
        self.assertTrue(any("ask ledger schema setup failed" in e for e in res.write_errors), res.write_errors)
        self.assertIn("ASK LEDGER UNAVAILABLE", res.note)
        keys = [r[0] for r in self.db.execute("SELECT k FROM state").fetchall()]
        self.assertTrue(any(k.startswith("support-writer:ask-ledger-error:") for k in keys),
                        "the watchdog has nothing to page on")
        pending = decide.pending_readback(self.db)
        self.assertEqual([p["run_id"] for p in pending], [res.run_id],
                         "a landed ask with no read-back obligation admits a second apply unreconciled")

    def test_an_unexpected_ledger_exception_still_owes_a_readback(self):
        """The belt to the braces: even an exception the setup guard does not anticipate must not skip
        `record_apply_run()`, because that is the only thing standing between a landed ask and a second apply."""
        from credit_review import verify_ledger
        self.proof([])
        with mock.patch.object(verify_ledger, "record_external_ask", side_effect=RuntimeError("db is busy")), \
                mock.patch.object(decide, "ledger_asks", side_effect=RuntimeError("unexpected")):
            res, w = self.go([req(uuid_of(427), uid=927, track="t1")], self.RAWS)
        self.assertEqual(support_ids(w), [uuid_of(427)])
        self.assertTrue(any("ask ledger: unexpected" in e for e in res.write_errors), res.write_errors)
        self.assertEqual([p["run_id"] for p in decide.pending_readback(self.db)], [res.run_id])

    def test_deferrals_are_not_ledgered_as_asks(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_run=1)
        res, w = self.go([req(uuid_of(424), uid=924, track="t1"), req(uuid_of(425), uid=925, track="t1")],
                         self.RAWS, policy=policy)
        self.assertEqual([r[4] for r in self.asks()], ["924"], "only the row that was actually SENT is an ask")


class ReadbackBeforeSecondApply(Base):
    """Condition 5: a read-back after the first apply run before the second."""

    RAWS = APPROVE_RAWS

    def test_an_apply_run_that_asked_owes_a_readback(self):
        self.proof([])
        res, w = self.go([req(uuid_of(430), uid=931, track="t1")], self.RAWS)
        pending = decide.pending_readback(self.db)
        self.assertEqual([p["run_id"] for p in pending], [res.run_id])
        self.assertEqual(pending[0]["asks"], 1)

    def test_a_run_that_sent_nothing_owes_nothing(self):
        self.proof([])
        decide.APPROVE_SWITCH.write_text("off")
        res, w = self.go([req(uuid_of(431), uid=932, track="t3")], self.RAWS, judge=FakeJudge(credible()))
        self.assertEqual((support_ids(w), res.held_approve_arm), ([], 1))
        self.assertEqual(decide.pending_readback(self.db), [])

    def test_the_readback_clears_it_only_when_core_confirms_every_row(self):
        self.proof([])
        res, w = self.go([req(uuid_of(432), uid=933, track="t1")], self.RAWS)
        partial = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set())
        self.assertFalse(partial["ok"])
        self.assertEqual(partial["missing"], [uuid_of(432)])
        self.assertEqual(len(decide.pending_readback(self.db)), 1, "a partial answer does not clear the gate")
        ok = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids))
        self.assertTrue(ok["ok"])
        self.assertEqual(decide.pending_readback(self.db), [])

    def test_a_readback_that_cannot_read_is_a_refusal(self):
        self.proof([])
        res, w = self.go([req(uuid_of(433), uid=934, track="t1")], self.RAWS)

        def boom(status, ids):
            raise RuntimeError("trino down")
        doc = decide.run_readback(self.db, res.run_id, readback=boom)
        self.assertFalse(doc["ok"])
        self.assertIn("trino down", doc["error"])
        self.assertEqual(len(decide.pending_readback(self.db)), 1)

    def test_a_second_apply_cannot_start_while_the_first_owes_a_readback(self):
        """qa-review #1782 (r7) Important: the check ran BEFORE the write lock and the obligation was recorded AFTER
        it, so two apply processes starting with no pending read-back could both pass - the first wrote asks, the
        second wrote another batch without reading the first back. Both halves are now inside the lock."""
        self.proof([])
        res1, w1 = self.go([req(uuid_of(440), uid=941, track="t1")], self.RAWS)
        self.assertEqual(support_ids(w1), [uuid_of(440)])
        res2, w2 = self.go([req(uuid_of(441), uid=942, track="t1")], self.RAWS)
        self.assertEqual(w2.calls, [], "a second apply wrote while the first owed a read-back")
        self.assertEqual(support_ids(w2), [])
        self.assertTrue(any("read-back owed" in e for e in res2.write_errors), res2.write_errors)
        self.assertIn("READ-BACK OWED", res2.note)
        # ... and once the first is read back, the second may run
        self.clear_readback()
        res3, w3 = self.go([req(uuid_of(442), uid=943, track="t1")], self.RAWS)
        self.assertEqual(support_ids(w3), [uuid_of(442)])

    def test_an_UNCERTAIN_only_run_can_be_read_back_and_a_MIXED_run_needs_both(self):
        """qa-review #1782 (r9) Important: `run_readback` selected only `outcome=user_verification_needed`, so an
        uncertain-only run raised "wrote no ask to read back" (wedged) and a mixed run recorded ok:true while the
        uncertain ask was unreconciled."""
        self.proof([])
        real = decide.write_chunk
        calls = {"n": 0}

        def mixed(writer, readback, status, chunk, prior):
            calls["n"] += 1
            if calls["n"] == 1:
                return ({chunk[0]: "error:unverified: readback failed"}, "readback failed")
            return ({rid: status for rid in chunk}, None)
        with mock.patch.object(decide, "write_chunk", side_effect=mixed):
            res, w = self.go([req(uuid_of(460), uid=961, track="t1"), req(uuid_of(461), uid=962, track="t1")],
                             self.RAWS)
        self.assertEqual(1, res.support_uncertain)
        # the uncertain id is part of the read-back set, so a read-back that only confirms the landed one is NOT ok
        partial = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids) - {uuid_of(460)})
        self.assertFalse(partial["ok"], "a mixed run recorded ok:true while the uncertain ask was unreconciled")
        self.assertIn(uuid_of(460), partial["missing"])
        self.assertEqual(len(decide.pending_readback(self.db)), 1, "a partial answer does not clear the gate")
        ok = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids))
        self.assertTrue(ok["ok"])
        self.assertEqual(decide.pending_readback(self.db), [])

    def test_a_RECOVERED_uncertain_ask_is_ledgered_for_the_shared_gates(self):
        """qa-review #1782 (r10) Important: an uncertain ask that the read-back CONFIRMS was never ledgered - the write
        path only ledgers what it saw land. Without a `verify_messages` row the tick's asked_within/capped gates
        cannot see it and can mail the same user another ask."""
        from credit_review import verify_ledger
        self.proof([])

        def uncertain(writer, readback, status, chunk, prior):
            return ({rid: "error:unverified: readback failed" for rid in chunk}, "readback failed")
        with mock.patch.object(decide, "write_chunk", side_effect=uncertain):
            res, w = self.go([req(uuid_of(470), uid=971, track="t1")], self.RAWS)
        self.assertEqual(1, res.support_uncertain)
        verify_ledger.ensure_schema(self.db)
        self.assertFalse(verify_ledger.asked_within(self.db, user_key="", user_id="971",
                                                    day=T.NOW.strftime("%Y-%m-%d")),
                         "precondition: the uncertain ask was not ledgered at write time")
        doc = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids))
        self.assertTrue(doc["ok"], doc)
        self.assertEqual([uuid_of(470)], doc["recovered_uncertain"])
        self.assertTrue(verify_ledger.asked_within(self.db, user_key="", user_id="971",
                                                   day=T.NOW.strftime("%Y-%m-%d")),
                        "the recovered ask was never ledgered, so the tick can mail the user again")

    def test_a_CONFIRMED_ask_whose_ledger_write_failed_is_reconciled_by_the_read_back(self):
        """qa-review #1782 (r11) Important: a CONFIRMED ask whose ledger_asks() failed (SQLite busy, say) is not in
        `uncertain`, so it was never re-ledgered either - a successful read-back then recorded ok:true and admitted
        the next apply while verify_messages still had no ask."""
        from credit_review import verify_ledger
        self.proof([])
        with mock.patch.object(verify_ledger, "record_external_ask", side_effect=RuntimeError("db is busy")):
            res, w = self.go([req(uuid_of(480), uid=981, track="t1")], self.RAWS)
        self.assertEqual(1, res.support, "precondition: the PUT was CONFIRMED")
        verify_ledger.ensure_schema(self.db)
        self.assertFalse(verify_ledger.asked_within(self.db, user_key="", user_id="981",
                                                    day=T.NOW.strftime("%Y-%m-%d")),
                         "precondition: the confirmed ask was not ledgered at write time")
        doc = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids))
        self.assertTrue(doc["ok"], doc)
        self.assertIn(uuid_of(480), doc["ledgered"])
        self.assertTrue(verify_ledger.asked_within(self.db, user_key="", user_id="981",
                                                   day=T.NOW.strftime("%Y-%m-%d")),
                        "the confirmed-but-unledgered ask was never reconciled")

    def test_a_reconciled_gap_clears_the_state_row_that_pages(self):
        """qa-review #1782 (r12) Important: the ask-ledger gap was booked as state and NOTHING ever removed it,
        so a gap the read-back later reconciled paged every 6h forever. The read-back is the reconciliation, so
        it is also the discharge."""
        from credit_review import verify_ledger
        self.proof([])
        with mock.patch.object(verify_ledger, "record_external_ask", side_effect=RuntimeError("db is busy")):
            res, w = self.go([req(uuid_of(482), uid=983, track="t1")], self.RAWS)
        self.assertEqual(1, res.support, "precondition: the PUT was CONFIRMED")
        gaps = [k for (k,) in self.db.execute(
            "SELECT k FROM state WHERE k LIKE 'support-writer:ask-ledger-error:%'")]
        self.assertEqual(1, len(gaps), "precondition: the unledgered ask was booked")
        self.assertIn(":983", gaps[0], "the key names the USER, so N users cannot overwrite each other")
        doc = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids))
        self.assertTrue(doc["ok"], doc)
        self.assertEqual(1, doc.get("cleared_gaps"), doc)
        self.assertEqual([], [k for (k,) in self.db.execute(
            "SELECT k FROM state WHERE k LIKE 'support-writer:ask-ledger-error:%'")],
            "a reconciled gap must stop paging")

    def test_a_recovered_ask_that_cannot_be_ledgered_keeps_the_gate_CLOSED(self):
        from credit_review import verify_ledger
        self.proof([])

        def uncertain(writer, readback, status, chunk, prior):
            return ({rid: "error:unverified: readback failed" for rid in chunk}, "readback failed")
        with mock.patch.object(decide, "write_chunk", side_effect=uncertain):
            res, w = self.go([req(uuid_of(471), uid=972, track="t1")], self.RAWS)
        with mock.patch.object(verify_ledger, "record_external_ask", side_effect=RuntimeError("db is busy")):
            doc = decide.run_readback(self.db, res.run_id, readback=lambda st, ids: set(ids))
        self.assertFalse(doc["ok"], "an unledgered recovered ask must not clear the gate")
        self.assertIn("could not be ledgered", doc.get("error", ""))
        self.assertEqual(len(decide.pending_readback(self.db)), 1)

    def test_an_INDETERMINATE_support_put_owes_a_readback(self):
        """qa-review #1782 (r8) Important: `write_chunk` returns `error:unverified` for a PUT that may have committed
        and whose status read-back also failed. That does not increment `res.support`, so `record_apply_run()` wrote
        no state row and the next apply passed `pending_readback()` and wrote another batch unreconciled."""
        self.proof([])
        real = decide.write_chunk

        def uncertain(writer, readback, status, chunk, prior):
            return ({rid: "error:unverified: readback failed" for rid in chunk}, "readback failed")
        with mock.patch.object(decide, "write_chunk", side_effect=uncertain):
            res, w = self.go([req(uuid_of(450), uid=951, track="t1")], self.RAWS)
        self.assertEqual(res.support, 0, "precondition: nothing was CONFIRMED")
        self.assertEqual(res.support_uncertain, 1)
        self.assertEqual([p["run_id"] for p in decide.pending_readback(self.db)], [res.run_id],
                         "an ask we cannot rule out must owe a read-back")

    def test_a_readback_for_a_run_that_asked_nothing_is_refused(self):
        with self.assertRaises(ValueError):
            decide.run_readback(self.db, "no-such-run", readback=lambda s, i: set(i))


class _Answering:
    """A judge that returns one prepared JudgeResult for every claim (the decider calls .judge)."""

    def __init__(self, result):
        self.result, self.calls = result, 0

    def judge(self, mode, evidence):
        self.calls += 1
        return self.result

    def judge_many(self, mode, evidences, ids):
        return {i: self.result for i in ids}


class DocApprovalDispatcher(Base):
    """QA #1684 findings 1-3 at the DISPATCHER, not at the gates: a verified document must be able to
    change a `support` ask into an approval, must never leave a phantom row when a later guard or the
    core write refuses it, and a doc-only apply must hold the asks it does not authorise."""

    RAWS = {"small": [T.raw("Real Engineer", "mixer")], "t1": [T.raw("Real Engineer", "mixer")]}

    def setUp(self):
        super().setUp()
        from credit_review import account_gate
        # both classes approved: the doc class may approve, and the wider automation is NOT doc-only
        Path(decide.REGISTRY).write_text(json.dumps({"automations": {
            decide.AUTOMATION: {"approved": True, "approved_by": "captain", "approval_ref": "r0"},
            decide.DOC_AUTOMATION: {"approved": True, "approved_by": "Fable", "approval_ref": "doc-approval-doctrine"}}}))
        self._doc_store, self._doc_proof = decide.DOC_STORE, decide.DOC_PROOF_STORE
        self._doc_kill = decide.DOC_APPROVE_KILL
        decide.DOC_STORE = Path(self.tmp) / "doc-verify.sqlite"
        decide.DOC_PROOF_STORE = Path(self.tmp) / "doc-intake.sqlite"
        decide.DOC_APPROVE_KILL = Path(self.tmp) / "no-kill-file"
        self.addCleanup(setattr, decide, "DOC_STORE", self._doc_store)
        self.addCleanup(setattr, decide, "DOC_PROOF_STORE", self._doc_proof)
        self.addCleanup(setattr, decide, "DOC_APPROVE_KILL", self._doc_kill)
        # the account gate shells out in production; here it is an allow (its own suite covers HOLD/UNKNOWN)
        self._patches = [unittest.mock.patch.object(
            account_gate, "check", lambda uid, runner=None: account_gate.GateResult(account_gate.ALLOW, ()))]
        for p in self._patches:
            p.start()
            self.addCleanup(p.stop)
        d = sqlite3.connect(decide.DOC_STORE)
        d.executescript("""
            CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at TEXT NOT NULL,
              proof_id TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER,
              source_ref TEXT, h3_verdict TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, need TEXT,
              account_hold INTEGER NOT NULL DEFAULT 0, detail_json TEXT NOT NULL, version TEXT NOT NULL,
              intake_id TEXT);""")
        d.commit()
        d.close()
        p = sqlite3.connect(decide.DOC_PROOF_STORE)
        p.executescript(STAGE2_SCHEMA)
        p.commit()
        p.close()
        self.doc_rid = uuid_of(400)
        self.file_doc(self.doc_rid, user_id=900)
        # a judge that answers the same way for every claim: NEEDS-HUMAN with no citation is NOT_FOUND
        self.NOT_FOUND = _Answering(JudgeResult(ok=True, verdict="NEEDS-HUMAN", confidence=0.5, provider="codex"))
        contradicted = JudgeResult(ok=True, verdict="CONTRADICTED", confidence=0.9, provider="codex")
        contradicted.findings = [{"source_url": "https://label.example/press", "quote": "credited to another writer",
                                  "effect": "contradicts", "confidence": 0.9}]
        contradicted.cited_urls = ["https://label.example/press"]
        self.CONTRADICTED = _Answering(contradicted)

    def file_doc(self, request_id, *, user_id=900, outcome="verified", version="dv-4", at="2026-10-31T12:26:32Z",
                 sha="a4205f34", intake_id=None):
        intake = intake_id or "145833:a4205f34"
        d = sqlite3.connect(decide.DOC_STORE)
        for role in ("Lyricist", "Composer"):
            d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, h3_verdict, outcome,"
                      " reason, account_hold, detail_json, version, intake_id) VALUES ('r1',?,'sha',?,?,?,"
                      " 'PLAUSIBLE',?,'because',0,'{}',?,?)",
                      (at, request_id, role, user_id, outcome, version, intake))
        d.commit()
        d.close()
        p = sqlite3.connect(decide.DOC_PROOF_STORE)
        p.execute("INSERT OR REPLACE INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                  " conversation_id, source, file_sha256, received_at, filed_by) VALUES (?,?,'credit',?,'777',"
                  "'intercom',?,'2026-10-24T06:49:57Z','proof_intake')",
                  (intake, user_id, json.dumps([request_id]), sha))
        p.commit()
        p.close()

    def approve_writes(self, w):
        return [i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]]

    def doc_rows(self):
        return [dict(zip(("request_id", "state", "ref"), r)) for r in
                sqlite3.connect(decide.DOC_STORE).execute("SELECT 1").fetchall()] if False else [
            {"request_id": r[0], "state": r[1], "ref": r[2]} for r in
            self.db.execute("SELECT request_id, state, ref FROM doc_approvals")]

    def test_a_doc_only_apply_with_the_arm_off_gives_the_slot_back(self):
        """qa-review #1782 (r8) Important: a DOC-ONLY apply commits the provisional row (and spends the
        one-per-request slot) BEFORE the arm-off branch runs, and then the id is dropped from approve_ids - so no
        core PUT happened and `doc_approve.release()` was never called. The credit stayed `unverified` while the
        ledger said approved and the slot blocked another attempt.

        qa-review #1782 (r12) Important: this test was VACUOUS. It filed no verified document and left the approve
        arm ON, so `doc_pending` was empty, `doc_approve.approve` never ran, `res.doc_approved` was 0 for the wrong
        reason, and deleting the `doc_approve.release()` call still left it green. It now files a real document,
        turns the arm OFF, and asserts the release happened AND the slot is free afterwards."""
        from credit_review import doc_approve
        rid = uuid_of(451)
        self.file_doc(rid, user_id=952)          # a dv-4 verified document: the doc class may approve this row
        arm_off = decide.Policy(deny_user_ids=set(), deny_profile_ids=set(), editorial_role_terms=TERMS,
                                approve_arm=False)
        released = []
        real_release = doc_approve.release

        def spy_release(db, request_id, **kw):
            released.append(request_id)
            return real_release(db, request_id, **kw)
        # NO raw DSP evidence: with an anchor the row is approved on the anchor and never reaches the doc path,
        # which is how the first version of this test managed to assert nothing (qa-review #1782 r12).
        with mock.patch.object(doc_approve, "release", side_effect=spy_release):
            res, w = self.go([req(rid, uid=952, track="small")], {}, judge=self.NOT_FOUND, policy=arm_off)
        # The doc row WAS committed and then given back - otherwise this test proves nothing.
        self.assertEqual([rid.lower()], [r.lower() for r in released],
                         "the arm-off branch did not give the committed doc slot back")
        # The slot is free: no provisional/confirmed row stands, so a later attempt is not blocked for ever.
        self.assertEqual({}, doc_approve.approved_refs(self.db, doc_store=decide.DOC_STORE, now=T.NOW),
                         "a released doc row still occupies the one-per-request slot")
        self.assertEqual(0, res.doc_approved, "a released doc row must not be reported as approved")
        self.assertEqual([], self.approve_writes(w), "the arm is off: no core PUT may be made")

    # ── round 8, finding 1: a bound request OUTSIDE this batch still has a known owner ──────────
    def test_the_rollover_works_when_a_document_binds_more_requests_than_the_per_user_cap(self):
        """25 today, 1 tomorrow - and tomorrow's batch does NOT contain the 25 already approved.

        `req_users` was built from this run's rows alone, so the survivor's document looked as if it
        bound requests with unknown owners and `gate_one_request` refused it for ever. The doc store
        judged all 26 requests and recorded the account, so it is the authoritative filler; a binding
        nobody can attribute is still unknown and still fails closed.
        """
        rids = [uuid_of(600 + i) for i in range(26)]
        # a real filing writes one dv_outcomes row per BOUND request (that is what makes a document
        # multi-binding), so the store can attribute every binding on the day of the filing
        self.file_multi(rids, user_id=900, intake_id="145833:many", sha="s600")
        res1, w1 = self.go([req(r, uid=900, track="small") for r in rids[:25]], {}, judge=self.NOT_FOUND)
        self.assertEqual(len(self.approve_writes(w1)), 25, "the cap spent the whole day on one person")
        self.assertEqual(res1.doc_approved, 25)
        # tomorrow: only the SURVIVOR is a candidate - the other 25 bindings are not in this batch
        admin = T.FakeAdmin([], {}, PROFILES, TRACKS)
        admin.unreadable = {"art-unreadable", "flaky"}
        w2 = Writer(self.db)
        res2 = decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY, writer=w2,
                          readback=lambda status, ids: set(), now=T.NOW + timedelta(days=1),
                          rows=[req(rids[25], uid=900, track="small")])
        self.assertIn(rids[25].lower(), [str(i).lower() for i in self.approve_writes(w2)],
                      "the rolled-over request is approved, not refused as an unknown owner")
        self.assertEqual(res2.doc_refused_by_core, 0)

    def file_multi(self, rids, *, user_id=900, intake_id="145833:many", sha="s600"):
        d = sqlite3.connect(decide.DOC_STORE)
        for rid in rids:
            for role in ("Lyricist", "Composer"):
                d.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id,"
                          " h3_verdict, outcome, reason, account_hold, detail_json, version, intake_id)"
                          " VALUES ('r1','2026-10-31T12:26:32Z','sha',?,?,?,'PLAUSIBLE','verified','because',"
                          " 0,'{}','dv-4',?)", (rid, role, user_id, intake_id))
        d.commit()
        d.close()
        p = sqlite3.connect(decide.DOC_PROOF_STORE)
        p.execute("INSERT OR REPLACE INTO proof_intake (intake_id, user_id, subject,"
                  " candidate_request_ids_json, conversation_id, source, file_sha256, received_at, filed_by)"
                  " VALUES (?,?,'credit',?,'777','intercom',?,'2026-10-24T06:49:57Z','proof_intake')",
                  (intake_id, user_id, json.dumps(list(rids)), sha))
        p.commit()
        p.close()

    def test_a_bound_owner_the_store_never_judged_still_fails_closed(self):
        rid = uuid_of(700)
        self.file_doc(rid, user_id=900)
        p = sqlite3.connect(decide.DOC_PROOF_STORE)
        p.execute("UPDATE proof_intake SET candidate_request_ids_json = ? WHERE intake_id = '145833:a4205f34'",
                  (json.dumps([rid, uuid_of(701)]),))
        p.commit()
        p.close()
        res, w = self.go([req(rid, uid=900, track="small")], {}, judge=self.NOT_FOUND)
        self.assertEqual(self.approve_writes(w), [], "an unattributable co-binding is never an approval")
        self.assertEqual(self.decisions()[rid]["decision"], "support",
                         "…and the row keeps the decision it had: the document changed nothing")

    # ── round 8, finding 2: the document lives in OUR ledger, so core's guard still decides ──────
    def test_a_document_never_plans_an_approval_CORES_guard_would_refuse(self):
        """A popularity of 0 passes `gate_tier` (known and small, T0) but core's agent guard refuses a
        zero-popularity approval as `popularity_unattributable` - the document is recorded in our
        ledger, never in core, and the PUT carries no proof. Planning it anyway only demoted it later,
        which made both the class's claim and the run report overstate coverage. It is now refused by
        name at plan time and the row keeps the guard that already explains it."""
        rid = self.doc_rid
        self.file_doc(rid, user_id=900)
        res, w = self.go([req(rid, uid=900, track="zero")], {}, judge=self.NOT_FOUND)
        self.assertEqual(self.approve_writes(w), [], "core would refuse it, so nothing is written")
        self.assertEqual(res.doc_refused_by_core, 1)
        row = self.db.execute("SELECT state FROM doc_approvals WHERE request_id = ?", (rid,)).fetchone()
        self.assertIsNone(row, "no doc_approvals row is recorded for an approval core refuses")
        d = self.decisions()[rid]
        self.assertEqual(d["decision"], "hold", "the class never claims what core will not accept")
        self.assertIn("dv-4 verified document", d["reason"])
        self.assertIn("popularity_unattributable", d["reason"])

    def test_a_high_risk_row_with_a_verified_document_is_HELD_not_asked_for_another_document(self):
        """The same rule for core's other refusal: a `proof_required` row (risk 100) that already has a
        verified document must not be sent a document ask - the user already sent one. It is held, with
        the document and the refusal named."""
        rid = self.doc_rid
        self.file_doc(rid, user_id=900)
        row = req(rid, uid=900, track="small")
        row["verificationData"]["total_risk_percent"] = 100
        res, w = self.go([row], {}, judge=self.NOT_FOUND)
        self.assertEqual(self.approve_writes(w), [])
        self.assertEqual([c["status"] for c in w.calls], [], "no ask and no approval")
        self.assertEqual(res.doc_refused_by_core, 1)
        d = self.decisions()[rid]
        self.assertEqual(d["decision"], "hold", d["reason"])
        self.assertIn("proof_required", d["reason"])

    # ── round 5, finding 1: `paid_first_oldest` sorts USERS, so a person's credits are adjacent ──
    def test_the_doc_pass_visits_a_persons_requests_TOGETHER_in_the_rulings_order(self):
        """The ruling approves a person's requests together (told ONCE, and "the rest roll to the next
        day, same user first"), so the plan must visit a user's requests adjacently, oldest user first.
        Pinned on the order the planner sees, because that adjacency is the property, not the outcome."""
        a_old, a_new, b = uuid_of(420), uuid_of(421), uuid_of(422)
        for rid, uid, sha in ((a_old, 900, "s420"), (a_new, 900, "s421"), (b, 901, "s422")):
            self.file_doc(rid, user_id=uid, intake_id=f"i-{rid}", sha=sha)
        seen = []
        real = decide.doc_approve.plan

        def spy(c, *a, **kw):
            seen.append(c.request_id)
            return real(c, *a, **kw)

        rows = [req(a_old, uid=900, track="small", created="2026-10-01T00:00:00Z"),
                req(b, uid=901, track="small", created="2026-11-01T00:00:00Z"),
                req(a_new, uid=900, track="small", created="2026-11-02T00:00:00Z")]
        with unittest.mock.patch.object(decide.doc_approve, "plan", spy):
            self.go(rows, {}, judge=self.NOT_FOUND)
        self.assertEqual(seen, [a_old, a_new, b],
                         "user A's two credits are adjacent and A waits longer than B")

    def test_a_user_already_counted_today_never_loses_their_own_remaining_credits(self):
        """The reason the ordering above cannot cost a person anything: the fleet cap counts PEOPLE, so
        once a user's slot is spent their other credits do not need another one. (This is what makes
        QA's "B takes the final slot" interleaving harmless - so the ordering is for the told-once
        notice and next-day-first rolling, which are the ruling's other two requirements.)"""
        a_old, a_new, b = uuid_of(430), uuid_of(431), uuid_of(432)
        for rid, uid, sha in ((a_old, 900, "s430"), (a_new, 900, "s431"), (b, 901, "s432")):
            self.file_doc(rid, user_id=uid, intake_id=f"i-{rid}", sha=sha)
        decide.doc_approve.ensure_schema(self.db)
        for i in range(49):        # exactly ONE fleet slot is left
            self.db.execute("INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref,"
                            " popularity, tier, approved_at, expires_at, state)"
                            " VALUES (?,?,'i','s','r',3,'T0','2026-11-03T07:00:00Z',"
                            "'2026-11-10T07:00:00Z','provisional')", (f"filler-{i}", 5000 + i))
        self.db.commit()
        rows = [req(a_old, uid=900, track="small", created="2026-10-01T00:00:00Z"),
                req(b, uid=901, track="small", created="2026-11-01T00:00:00Z"),
                req(a_new, uid=900, track="small", created="2026-11-02T00:00:00Z")]
        res, w = self.go(rows, {}, judge=self.NOT_FOUND)
        approved = set(self.approve_writes(w))
        self.assertIn(a_old, approved)
        self.assertIn(a_new, approved, "the user's own second credit rides the slot already spent on them")
        self.assertNotIn(b, approved, "the user who was already waiting keeps the last slot")

    # ── round 7, finding 1: an UNKNOWN write outcome is not a refusal ──
    class _BrokenWriter:
        def __init__(self, committed=frozenset()):
            self.calls, self.committed = [], set(committed)

        def __call__(self, status, ids, expected):
            self.calls.append((status, list(ids)))
            raise decide.admin_api.AdminError("502 from core after the PUT was accepted")

    def test_an_INDETERMINATE_write_neither_releases_the_row_nor_frees_its_slot(self):
        """QA #1684 round 7, finding 1: `write_chunk` answers `error:unverified:` when the PUT failed AND
        the readback failed - core may have COMMITTED the credit. Releasing on it took away the only
        record behind a live credit and gave the slot back for a second approval."""
        def dead_readback(status, ids):
            raise decide.admin_api.AdminError("status readback also failed")

        w = self._BrokenWriter()
        admin = T.FakeAdmin([], {}, PROFILES, TRACKS)
        res = decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY,
                         writer=w, readback=dead_readback, now=T.NOW,
                         rows=[req(self.doc_rid, uid=900, track="small")])
        row = self.db.execute("SELECT state FROM doc_approvals WHERE request_id = ?", (self.doc_rid,)).fetchone()
        self.assertEqual(row[0], "indeterminate", "the row stands, for a human to reconcile")
        self.assertEqual(res.doc_indeterminate, 1)
        self.assertEqual(res.doc_approved, 0)
        self.assertEqual(decide.doc_approve.approved_refs(self.db), {},
                         "an unknown outcome is never served as proof")
        # the slot stayed spent: a second approval of the same request is refused, not re-counted
        def dead_readback2(status, ids):
            raise decide.admin_api.AdminError("nope")
        w2 = self._BrokenWriter()
        res2 = decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY,
                          writer=w2, readback=dead_readback2, now=T.NOW,
                          rows=[req(self.doc_rid, uid=900, track="small")])
        self.assertEqual([c for c in w2.calls if c[0] == decide.APPROVED], [],
                         "no second APPROVAL PUT while the slot is indeterminate")
        self.assertEqual(self.db.execute("SELECT state FROM doc_approvals WHERE request_id = ?",
                                         (self.doc_rid,)).fetchone()[0], "indeterminate")
        self.assertEqual(res2.doc_indeterminate, 0)

    # ── round 7, finding 2: one person's credits reach core in ONE PUT ──
    def test_a_users_credits_are_never_split_across_PUTs_so_the_notice_is_sent_once(self):
        """The ruling tells the requester ONCE, listing their credits, and core's notice groups per PUT -
        so a user's run must not straddle a chunk boundary."""
        a1, a2, b = uuid_of(440), uuid_of(441), uuid_of(442)
        for rid, uid, sha in ((a1, 900, "s440"), (a2, 900, "s441"), (b, 901, "s442")):
            self.file_doc(rid, user_id=uid, intake_id=f"i-{rid}", sha=sha)
        rows = [req(a1, uid=900, track="small", created="2026-10-01T00:00:00Z"),
                req(b, uid=901, track="small", created="2026-10-02T00:00:00Z"),
                req(a2, uid=900, track="small", created="2026-10-03T00:00:00Z")]
        with unittest.mock.patch.object(decide, "BATCH", 2):
            res, w = self.go(rows, {}, judge=self.NOT_FOUND)
        puts = [c["ids"] for c in w.calls if c["status"] == decide.APPROVED]
        self.assertEqual(len(puts), 2, puts)
        self.assertEqual(sorted(puts[0]), sorted([a1, a2]), "A's two credits share ONE PUT")
        self.assertEqual(puts[1], [b])

    # ── finding 1: a NOT_FOUND small track is exactly the case the ruling is about ──
    def test_a_not_found_small_track_is_approved_by_a_verified_document(self):
        res, w = self.go([req(self.doc_rid, uid=900, track="small")], {}, judge=self.NOT_FOUND)
        d = self.decisions()[self.doc_rid]
        self.assertEqual(d["decision"], "approve", d["reason"])
        self.assertEqual(d["evidence_kind"], "doc_verified")
        self.assertEqual(self.approve_writes(w), [self.doc_rid])
        rows = self.doc_rows()
        self.assertEqual([(r["request_id"], r["state"]) for r in rows], [(self.doc_rid, "provisional")])
        self.assertEqual(res.doc_approved, 1)

    def test_a_contradicted_verdict_is_never_converted_by_a_document(self):
        res, w = self.go([req(self.doc_rid, uid=900, track="small")], {}, judge=self.CONTRADICTED)
        d = self.decisions()[self.doc_rid]
        self.assertEqual(d["decision"], "support", "a document never overrides a contradiction")
        self.assertEqual(self.approve_writes(w), [])
        self.assertEqual(self.doc_rows(), [])

    def test_a_big_track_document_is_not_converted_and_stays_an_ask(self):
        """A T2/T3 row never reaches the document path at all: the pre-model big-track rule asks for the
        DSP credit before any web check, so the ruling's T0/T1 bound is enforced by the ask path itself."""
        res, w = self.go([req(self.doc_rid, uid=900, track="t1")], {}, judge=self.NOT_FOUND)  # pop 88
        d = self.decisions()[self.doc_rid]
        self.assertEqual(d["decision"], "support")
        self.assertEqual(self.doc_rows(), [])
        self.assertFalse([line for line in self.logged if "doc-approve planned" in line])

    def test_a_forged_document_is_never_even_a_candidate(self):
        """`verified_docs()` is the universe, so the newest forged verdict removes the request before any
        gate runs: it cannot be planned, never mind approved."""
        self.file_doc(self.doc_rid, outcome="forged")
        from credit_review import doc_approve
        self.assertEqual(doc_approve.verified_docs(decide.DOC_STORE, decide.DOC_PROOF_STORE), {})
        res, w = self.go([req(self.doc_rid, uid=900, track="small")], {}, judge=self.NOT_FOUND)
        self.assertEqual(self.decisions()[self.doc_rid]["decision"], "support", "the ask stands")
        self.assertEqual(self.doc_rows(), [])

    # ── finding 2: a later guard refuses -> NO row (no phantom, no spent slot) ──
    def test_a_later_guard_that_refuses_the_approval_leaves_no_document_row(self):
        policy = dataclasses.replace(POLICY, max_approvals_per_user_per_day=1)
        other = uuid_of(401)
        self.file_doc(other, user_id=900, sha="bbbb", intake_id="145833:bbbb")
        rows = [req(self.doc_rid, uid=900, track="small"), req(other, uid=900, track="small")]
        res, w = self.go(rows, {}, judge=self.NOT_FOUND, policy=policy)
        approved = [r for r in self.decisions().values() if r["decision"] == "approve"]
        self.assertEqual(len(approved), 1)
        self.assertEqual(len(self.doc_rows()), 1, "only the request that was actually approved holds a row")
        self.assertEqual(len(self.approve_writes(w)), 1)

    def test_a_core_write_that_does_not_confirm_releases_the_document_row(self):
        w = Writer(self.db, {self.doc_rid: "refused_by_human_review"})
        admin = T.FakeAdmin([], {}, PROFILES, TRACKS)
        res = decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY, writer=w, now=T.NOW,
                         rows=[req(self.doc_rid, uid=900, track="small")])
        self.assertEqual(self.approve_writes(w), [self.doc_rid])
        rows = self.doc_rows()
        self.assertEqual([(r["request_id"], r["state"]) for r in rows], [(self.doc_rid, "released")])
        self.assertEqual(res.doc_approved, 0, "a released row is not an approval and must not be counted")
        from credit_review import doc_approve
        self.assertEqual(doc_approve.approved_refs(self.db, doc_store=decide.DOC_STORE, now=T.NOW), {})
        self.assertTrue(doc_approve.gate_one_per_request(
            doc_approve.Candidate(self.doc_rid, 900, 20, tuple(
                doc_approve.verified_docs(decide.DOC_STORE, decide.DOC_PROOF_STORE)[self.doc_rid])),
            self.db).ok, "the slot was given back: a later run may approve this request")

    # ── finding 3: a doc-only apply holds everything that is not a doc approval ──
    def test_doc_only_apply_holds_the_support_asks_it_does_not_authorise(self):
        Path(decide.REGISTRY).write_text(json.dumps({"automations": {
            decide.AUTOMATION: {"approved": False},
            decide.DOC_AUTOMATION: {"approved": True, "approved_by": "Fable", "approval_ref": "d"}}}))
        unproven = uuid_of(402)
        res, w = self.go([req(self.doc_rid, uid=900, track="small"), req(unproven, uid=901, track="small")],
                         {}, judge=self.NOT_FOUND)
        d = self.decisions()
        self.assertEqual(d[self.doc_rid]["decision"], "approve", "the doc class still writes")
        self.assertEqual(d[unproven]["decision"], "hold", d[unproven]["reason"])
        self.assertIn("only doc-verified-t0t1", d[unproven]["reason"])
        self.assertEqual([i for c in w.calls if c["status"] == decide.UVN for i in c["ids"]], [],
                         "no ask goes out under a grant that only authorises doc approvals")
        self.assertEqual(self.approve_writes(w), [self.doc_rid])


if __name__ == "__main__":
    warnings.filterwarnings("ignore", category=ResourceWarning)
    unittest.main(verbosity=1, warnings="")
