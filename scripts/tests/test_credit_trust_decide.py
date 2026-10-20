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
import warnings
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import test_credit_review as T  # noqa: E402  (FakeAdmin, request(), raw(), PROFILES, TRACKS, NOW)
from credit_review import decide  # noqa: E402
from credit_review.judge import JudgeResult  # noqa: E402
from credit_review.ledger import Ledger  # noqa: E402

PID_CLAIMANT_A = "ff7a7b1c-0000-4000-8000-000000000015"
PROFILES = {**T.PROFILES,
            PID_CLAIMANT_A: {"name": "Claimant A", "rawProfiles": [{"id": "TJ", "source": "tidal"}], "knownAsNames": []}}
TRACKS = {**T.TRACKS, "small": T.track(20), "nopop": T.track(None), "mid": T.track(40),
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


TERMS = decide.Policy.load().editorial_role_terms
POLICY = decide.Policy(deny_user_ids={666}, deny_profile_ids=set(), editorial_role_terms=TERMS)


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
        self.proof()
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
                               max_approvals_per_user_per_day=1)
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

    def test_ledger_is_append_only_and_revert_lists_the_run(self):
        res, _ = self.go([req(uuid_of(26), track="t3")], judge=FakeJudge(credible()))
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("UPDATE decisions SET decision='approve'")
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("DELETE FROM decision_outcomes")
        self.assertEqual(decide.revert(self.db, res.run_id, apply=False)["approved_ids"], [uuid_of(26)])
        w = Writer(self.db)
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
        rows = [req(uuid_of(190), uid=900, track="t3"), req(uuid_of(191), uid=501, track="t3"),
                req(uuid_of(192), uid=900, track="t2")]
        res, w = self.go(rows, {}, judge=judge)
        d = self.decisions()
        self.assertEqual((d[uuid_of(190)]["decision"], d[uuid_of(190)]["evidence_kind"], d[uuid_of(190)]["web_verdict"]),
                         ("approve", "provisional_paid", "NOT_FOUND"))
        self.assertIn("trust yet verify", d[uuid_of(190)]["reason"])
        self.assertEqual(d[uuid_of(191)]["decision"], "support", "free user: asked")
        self.assertEqual(d[uuid_of(192)]["decision"], "support", "big track (pop 70): proof required")
        self.assertIn(uuid_of(190), [i for c in w.calls if c["status"] == decide.APPROVED for i in c["ids"]])

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
        self.go([req(uuid_of(220), uid=900, track="t3"), req(uuid_of(221), uid=900, track="t3")], {}, judge=judge)
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
            res, _ = self.go([req(uuid_of(200 + i), uid=900, track="t3") for i in range(3)], {}, judge=judge)
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
            res, w = self.go([req(uuid_of(240 + i), uid=900, track="t3") for i in range(2)], {}, judge=judge)
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
        self.assertEqual(self.support_writes(w), [uuid_of(114)])
        self.assertEqual((res.support_candidates, res.held_proof, res.support, res.held), (4, 3, 1, 3))
        self.assertIn("4 before filters, 3 held for proof on file", res.line())
        self.assertIn("1 sent", res.line())

    def test_daily_ask_cap_limits_distinct_users_and_keeps_a_users_batch_whole(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=2)
        rows = [req(uuid_of(160), uid=801, track="t1"), req(uuid_of(161), uid=801, track="t9"),
                req(uuid_of(162), uid=802, track="t1"), req(uuid_of(163), uid=803, track="t1")]
        res, w = self.go(rows, self.RAWS, policy=policy)
        self.assertEqual(sorted(self.support_writes(w)), sorted([uuid_of(160), uuid_of(161), uuid_of(162)]))
        d = self.decisions()
        self.assertEqual(d[uuid_of(163)]["decision"], "defer")
        self.assertTrue(d[uuid_of(163)]["reason"].startswith(decide.ASK_CAP_DEFER))
        self.assertEqual(res.deferred_ask_cap, 1)
        self.assertIn("1 deferred by the daily ask cap", res.line())

    def test_daily_ask_cap_counts_users_already_asked_today(self):
        self.proof([])
        policy = dataclasses.replace(POLICY, max_ask_users_per_day=1)
        res, w = self.go([req(uuid_of(170), uid=811, track="t1")], self.RAWS, policy=policy)
        self.assertEqual(self.support_writes(w), [uuid_of(170)])
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
            self.assertEqual(self.support_writes(w), [], why)
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
            self.assertEqual(self.support_writes(w), [], why)
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
        self.assertEqual(self.support_writes(w), [uuid_of(161)])

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
        later = [req(uuid_of(152), uid=730, track="t1"), req(uuid_of(153), uid=731, track="t1")]
        res2, w2 = self.go(later, self.RAWS, now=T.NOW + decide.timedelta(hours=3))
        self.assertEqual(self.support_writes(w2), [uuid_of(153)])
        self.assertEqual(res2.deferred_window, 1)
        res3, w3 = self.go([later[0]], self.RAWS, now=T.NOW + decide.timedelta(hours=25))
        self.assertEqual(self.support_writes(w3), [uuid_of(152)])

    def run_at(self, now, held):
        """One scheduled run at ``now`` over the held queue as the admin API lists it."""
        admin = T.FakeAdmin(list(held), self.RAWS, PROFILES, TRACKS)
        w = Writer(self.db)
        self.proof(generated_at=decide.utc(now - decide.timedelta(minutes=30)))
        res = decide.run(admin, self.db, self.NOT_FOUND, mode="apply", policy=POLICY, writer=w, now=now)
        return res, w

    def test_a_users_waiting_rows_go_out_together_after_the_window(self):
        h = decide.timedelta(hours=1)
        r1, r2, r3 = (req(uuid_of(160 + i), uid=740, track="t1") for i in range(3))
        _, w = self.run_at(T.NOW, [r1])
        self.assertEqual(self.support_writes(w), [r1["id"]])
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


if __name__ == "__main__":
    warnings.filterwarnings("ignore", category=ResourceWarning)
    unittest.main(verbosity=1, warnings="")
