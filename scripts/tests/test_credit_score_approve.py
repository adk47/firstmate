#!/usr/bin/env python3
"""score-approve (captain 2026-10-20 "approve low risk credits", firstmate 110)."""
import json
import os
import random
import re
import sqlite3
import sys
import tempfile
import unittest
from types import SimpleNamespace
import dataclasses
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
import credit_test_env  # noqa: E402,F401  (test log isolation)
from credit_review import decide, score_approve as sa, verify_notify  # noqa: E402
from credit_review import verify_notify as _vn_r5  # noqa: E402
_vn_r5.PRESENTED_LOOKUP = lambda ids: {}  # r5: presented profile ids never come from the replica in tests

NOW = datetime(2026, 10, 20, 12, 0, tzinfo=timezone.utc)

#: Core's profile burst guard, clear for every profile: the live reader is never run by a test.
NO_BURST = lambda rs: {str(r.get("profileId") or "").lower(): None for r in rs}


def row(rid, *, uid=500, pid="p1", risk=0, approved=True, pop=20, roles=("Producer",), rules=None, status=decide.UVN,
        created="2026-10-19T00:00:00Z", meta=None, band="A"):
    # Every validator verdict today carries band_hint; core refuses one without (band_not_a_or_b).
    vd = {"is_approved": approved, "total_risk_percent": risk, "rule_risk_percent": dict(rules or {})}
    if band is not None:
        vd["band_hint"] = band
    return {"id": rid, "profileId": pid, "userId": uid, "trackId": "t-" + rid, "status": status,
            "spotifyTrackTitle": "Song " + rid, "spotifyPopularity": pop, "credits": list(roles),
            "createdAt": created, "verificationData": vd, "metadata": dict(meta or {})}



# Steward 019 / captain 2026-10-26: every approval calls the shared account gate first. These tests cover the
# other rules, so the gate answers allow on a GREEN account here (an allow that names no band is not approved:
# account_gate.watch_refusal); its own behaviour is pinned below and in test_credit_account_gate.py.
from credit_review import account_gate as _gate  # noqa: E402
from unittest import mock as _mock  # noqa: E402


def _allow(band="green", reasons=(), **extra):
    """The gate's allow as node-8 prints it: the band and the watch flag ride in the payload."""
    return _gate.GateResult(_gate.ALLOW, tuple(reasons), {"decision": "allow", "band": band,
                                                           "watch": band == "amber", **extra})


_ALLOW = _mock.patch.object(_gate, "check", lambda uid, runner=None: _allow())


def setUpModule():
    _ALLOW.start()


def tearDownModule():
    _ALLOW.stop()


class FakeAdmin:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    def get(self, path, params=None):
        self.calls.append((path, dict(params or {})))
        assert path == "/admin/credit-requests"
        assert params.get("profilesIds"), "only profile-filtered reads"
        assert params.get("status") in sa.HELD_STATUSES
        pids = set(params["profilesIds"].split(","))
        return {"items": [r for r in self.rows if r["profileId"] in pids and r["status"] == params["status"]]}


class Writer:
    def __init__(self):
        self.calls = []

    def __call__(self, status, ids, expected):
        self.calls.append((status, list(ids), expected))
        return {"data": {"updatedIds": list(ids)}}


def policy(**kw):
    return decide.Policy(deny_user_ids=set(kw.get("deny_users", ())), deny_profile_ids=set(kw.get("deny_profiles", ())),
                         editorial_role_terms=(), max_approvals_per_user_per_day=kw.get("per_user", 200))


class ScoreApprove(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = sqlite3.connect(os.path.join(self.tmp, "ledger.sqlite3"))
        reg = Path(self.tmp) / "registry.json"
        reg.write_text(json.dumps({"automations": {sa.AUTOMATION: {"approved": True, "approved_by": "captain",
                                                                    "approval_ref": "test"}}}))
        self._reg = decide.REGISTRY
        decide.REGISTRY = reg
        self.addCleanup(setattr, decide, "REGISTRY", self._reg)
        pay = Path(self.tmp) / "paying.json"
        pay.write_text(json.dumps({"generated_at": "2026-10-20T11:30:00Z", "source": "t", "definition": "t",
                                   "counts_by_basis": {}, "count": 1, "ids": [900]}))
        self._pay = decide.PAYING_USERS_FILE
        decide.PAYING_USERS_FILE = pay
        self.addCleanup(setattr, decide, "PAYING_USERS_FILE", self._pay)
        self._pause, self._audit = sa.PAUSE_FILE, sa.AUDIT_DIR
        sa.PAUSE_FILE, sa.AUDIT_DIR = Path(self.tmp) / "paused", Path(self.tmp) / "audit"
        self.addCleanup(setattr, sa, "PAUSE_FILE", self._pause)
        self.addCleanup(setattr, sa, "AUDIT_DIR", self._audit)
        self._proof = decide.PROOF_ON_FILE
        decide.PROOF_ON_FILE = Path(self.tmp) / "proof.json"
        self.addCleanup(setattr, decide, "PROOF_ON_FILE", self._proof)
        self.proof()
        self._lock = decide.WRITE_LOCK
        decide.WRITE_LOCK = Path(self.tmp) / "w.lock"
        self.addCleanup(setattr, decide, "WRITE_LOCK", self._lock)

    def proof(self, entries=(), contacts=(), at="2026-10-20T11:00:00Z"):
        """The proof-on-file export as the producer lane writes it."""
        entries = list(entries)
        decide.PROOF_ON_FILE.write_text(json.dumps({
            "generated_at": at,
            "gmail_contacts_90d": {"generated_at": at, "source": "test", "user_ids": list(contacts)},
            "sources": [{"name": "core", "generated_at": at, "count": len(entries)},
                        {"name": "cs-intercom", "generated_at": at, "stale": False, "count": 0},
                        {"name": "cs-gmail", "generated_at": at, "stale": False, "count": 0}],
            "users": len({e["user_id"] for e in entries}), "entries": entries}))

    def go(self, rows, *, mode="apply", sp=None, pol=None, convo=None, admin=None, anchors=None, fanout=None,
           editorial_velocity=None, gate=None, writer=None, now=None, profile_burst=None):
        sp = sp or sa.ScorePolicy(enabled=True)
        w = writer or Writer()
        cands = lambda risk, limit: [(r["id"], r["profileId"], float(r["verificationData"]["total_risk_percent"]),
                                      r["status"], r["userId"])
                                     for r in sorted(rows, key=lambda r: r["verificationData"]["total_risk_percent"])]
        self.convo_asked = {}

        def conversations(users):
            self.convo_asked.update(users)
            return {u: (convo or {}).get(u, False) for u in users}
        res = sa.run(admin or FakeAdmin(rows), self.db, mode=mode, policy=pol or policy(), sp=sp, candidates=cands, writer=w,
                     readback=lambda status, ids: set(), now=now or NOW, sleep=lambda _s: None, conversations=conversations,
                     anchors=anchors or (lambda rs: {str(r["id"]): ("none", None) for r in rs}),
                     fanout=fanout or (lambda rs: {}),
                     profile_burst=profile_burst or (lambda rs: {str(r.get("profileId") or "").lower(): None
                                                               for r in rs}),
                     editorial_velocity=editorial_velocity or (lambda rs: {}), account_gate=gate)
        return res, w

    def decisions(self):
        self.db.row_factory = sqlite3.Row
        return {r["request_id"]: dict(r) for r in self.db.execute(
            "SELECT * FROM decisions WHERE run_id LIKE 'score-%'")}

    def test_only_clean_validator_approved_low_risk_rows_are_approved(self):
        rows = [row("ok"), row("risk30", risk=30), row("notappr", approved=False), row("big", pop=60),
                row("pop0", pop=0), row("label", roles=("Record Label",)), row("reject", rules={"reject_artist_credit": 100}),
                row("conflict", rules={"review_hourly_velocity_profile": 100}), row("proofreq", meta={"proofRequest": {}}),
                row("band", band="B"), row("deny", uid=13), row("ok2", risk=12, pid="p2")]
        res, w = self.go(rows, pol=policy(deny_users=(13,)))
        approved = sorted(i for c in w.calls for i in c[1])
        self.assertEqual(approved, ["ok", "ok2"])
        self.assertTrue(all(c[0] == decide.APPROVED and c[2] == decide.UVN for c in w.calls),
                        "approve only from the row's own held status")
        d = self.decisions()
        self.assertEqual(d["ok"]["evidence_kind"], sa.EVIDENCE_KIND)
        for rid in ("risk30", "notappr", "big", "pop0", "label", "reject", "conflict", "proofreq", "band", "deny"):
            self.assertNotEqual(d[rid]["decision"], "approve", rid)
            self.assertIsNone(d[rid]["evidence_kind"], rid)
        self.assertEqual(res.approved, 2)

    def test_paid_first_then_risk_zero_then_oldest_and_paced(self):
        rows = [row("r12-free", risk=12, uid=501, pid="a"), row("r0-free", uid=501, pid="b", created="2026-10-01T00:00:00Z"),
                row("r0-paid", uid=900, pid="c", created="2026-10-18T00:00:00Z"), row("r5-paid", risk=5, uid=900, pid="d")]
        res, w = self.go(rows, sp=sa.ScorePolicy(enabled=True, max_per_run=3))
        # Fable band-B condition 8: paid first; risk 0 before risk > 0; then oldest.
        self.assertEqual([i for c in w.calls for i in c[1]], ["r0-paid", "r5-paid", "r0-free"])
        self.assertEqual(res.capped, 1)
        self.assertIn("per-run pace", self.decisions()["r12-free"]["reason"])

    def test_a_rate_limited_read_backs_off_then_stops_reading_and_decides_nothing_unread(self):
        rows = [row("a", pid="pa"), row("b", pid="pb")]

        class Limited(FakeAdmin):
            def get(self, path, params=None):
                if params.get("profilesIds") == "pb":
                    raise sa.admin_api.AdminError("admin GET /admin/credit-requests returned HTTP 429")
                return super().get(path, params)
        slept = []
        cands = lambda risk, limit: [(r["id"], r["profileId"], 0.0) for r in rows]
        w = Writer()
        res = sa.run(Limited(rows), self.db, mode="apply", policy=policy(), sp=sa.ScorePolicy(enabled=True),
                     candidates=cands, writer=w, readback=lambda s, i: set(), now=NOW, sleep=slept.append,
                     conversations=lambda users: {u: False for u in users},
                     anchors=lambda rs: {str(r["id"]): ("none", None) for r in rs}, fanout=lambda rs: {},
                     profile_burst=NO_BURST)
        self.assertEqual([i for c in w.calls for i in c[1]], ["a"])
        self.assertIn("HTTP 429", res.note)
        self.assertNotIn("b", self.decisions(), "an unread row is not decided")
        self.assertIn(20.0, slept)

    def test_per_user_daily_cap(self):
        rows = [row(f"u{i}", pid=f"p{i}") for i in range(3)]
        res, w = self.go(rows, pol=policy(per_user=2))
        self.assertEqual(len([i for c in w.calls for i in c[1]]), 2)

    def test_shadow_and_unapproved_registry_write_nothing(self):
        res, w = self.go([row("ok")], mode="shadow")
        self.assertEqual((w.calls, res.would_approve), ([], 1))
        decide.REGISTRY.write_text(json.dumps({"automations": {sa.AUTOMATION: {"approved": False}}}))
        res, w = self.go([row("ok2", pid="p9")])
        self.assertEqual((w.calls, res.mode), ([], "shadow"))
        self.assertIn("APPLY REFUSED", res.note)

    def test_policy_bounds_are_enforced_in_code(self):
        p = Path(self.tmp) / "policy.json"
        for bad in ({"max_total_risk": 31}, {"max_popularity": 61}, {"max_total_risk": 0}):
            p.write_text(json.dumps({"score_approve": {"enabled": True, **bad}}))
            with self.assertRaises(ValueError):
                sa.ScorePolicy.load(p)
        p.write_text(json.dumps({}))
        self.assertFalse(sa.ScorePolicy.load(p).enabled, "absent = off")

    def test_score_approvals_get_the_verify_note_like_any_provisional_approval(self):
        """Fable band-B ruling condition 6: provisional - the user gets the (v1) verify note."""
        self.go([row("ok")])
        from credit_review import verify_ledger
        self.db.executescript(verify_ledger.SCHEMA)
        cands = verify_notify.candidates(self.db, since_hours=None)
        self.assertEqual([c[0] for c in cands], ["ok"])

    def test_band_b_only_with_the_phase_1_flag_and_never_band_c_or_an_open_proof_request(self):
        rows = [row("b", band="B"), row("c", band="C", pid="p2"), row("bproof", band="B", pid="p3", meta={"proofRequest": {}})]
        res, w = self.go(rows)
        self.assertEqual(w.calls, [], "today's core guard: band above A is refused")
        res, w = self.go([row("b2", band="B", pid="p4"), row("c2", band="C", pid="p5"),
                          row("bp2", band="B", pid="p6", meta={"proofRequest": {}}),
                          row("hold100", band="B", pid="p7", rules={"review_x": 100})],
                         sp=sa.ScorePolicy(enabled=True, admit_band_b=True))
        self.assertEqual([i for c in w.calls for i in c[1]], ["b2"])
        d = self.decisions()
        self.assertIn("band_hint_C", d["c2"]["reason"])
        self.assertIn("proof_requested", d["bp2"]["reason"])

    def test_one_person_roles_need_the_trusted_source_check_at_zero(self):
        rows = [row("mix-ok", roles=("Mixing",), rules={sa.ONE_PERSON_RULE: 0}),
                row("mix-absent", roles=("Mixing",), pid="p2"),
                row("master-hit", roles=("Mastering",), pid="p3", rules={sa.ONE_PERSON_RULE: 5}),
                row("remix-hit", roles=("Remixer",), pid="p4", rules={sa.ONE_PERSON_RULE: 5}),
                row("remix-absent", roles=("Remixer",), pid="p5")]
        res, w = self.go(rows)
        self.assertEqual([i for c in w.calls for i in c[1]], ["mix-ok"])

    def test_profile_and_fleet_caps(self):
        rows = [row(f"x{i}", uid=600 + i, pid="same") for i in range(4)]
        res, w = self.go(rows, sp=sa.ScorePolicy(enabled=True, per_profile_per_day=2))
        self.assertEqual(len([i for c in w.calls for i in c[1]]), 2)
        rows = [row(f"y{i}", uid=700 + i, pid=f"q{i}") for i in range(4)]
        res, w = self.go(rows, sp=sa.ScorePolicy(enabled=True, fleet_per_day=3))
        self.assertEqual(len([i for c in w.calls for i in c[1]]), 1, "2 already written today by the first run")
        p = Path(self.tmp) / "policy.json"
        p.write_text(json.dumps({"score_approve": {"enabled": True, "per_user_per_day": 21}}))
        with self.assertRaises(ValueError):
            sa.ScorePolicy.load(p)
        p.write_text(json.dumps({"score_approve": {"enabled": True, "max_per_run": 101}}))
        with self.assertRaises(ValueError):
            sa.ScorePolicy.load(p)
        p.write_text(json.dumps({"score_approve": {"enabled": True, "max_per_run": 100}}))
        self.assertEqual(sa.ScorePolicy.load(p).max_per_run, 100)

    def test_the_checked_in_policy_paces_a_run_at_50_and_the_pace_binds(self):
        """The lane's ruling item (c), cap 50 per run (the task brief's required cap, confirmed by firstmate
        2026-11-14): the job is armed at 50 a run, half the registered ceiling of 100, and the number bounds the
        live approve path once the cron row leaves enabled: false. Raising the checked-in number is a decision, so
        it is pinned here; the pace itself is the code's (row 51 waits)."""
        sp = sa.ScorePolicy.load(ROOT / "policies" / "credit-trust-decide.json")
        self.assertEqual(sp.max_per_run, 50)
        rows = [row(f"c{i:02d}", uid=700 + i, pid=f"cp{i}") for i in range(53)]
        res, w = self.go(rows, sp=sa.ScorePolicy(enabled=True, max_per_run=sp.max_per_run))
        self.assertEqual((res.approved, len([i for c in w.calls for i in c[1]])), (50, 50))
        self.assertEqual(res.held.get("per-run pace of 50 reached"), 3)

    def test_a_pause_stops_writes_and_audit_samples_are_filed(self):
        sa.PAUSE_FILE.write_text("audit precision 0.93 < 0.95 (audit-1)")
        res, w = self.go([row("p1x", pid="pz")])
        self.assertEqual((w.calls, res.mode), ([], "shadow"))
        self.assertIn("PAUSED", res.note)
        sa.PAUSE_FILE.unlink()
        rows = [row(f"s{i}", uid=800 + i, pid=f"sp{i}") for i in range(60)]
        res, w = self.go(rows)
        self.assertGreater(res.audit_sampled, 0)
        lines = (sa.AUDIT_DIR / "2026-10-20.jsonl").read_text().splitlines()
        self.assertEqual(len(lines), res.audit_sampled)
        self.assertTrue(sa.audit_sampled("abc", ["Producer"], "2026-10-20") in (True, False))
        rate = sum(sa.audit_sampled(f"r{i}", ["Producer"], "2026-11-01") for i in range(2000)) / 2000
        self.assertLess(abs(rate - 0.05), 0.02, "5 % after week 1")
        rate = sum(sa.audit_sampled(f"r{i}", ["Mixing"], "2026-11-01") for i in range(2000)) / 2000
        self.assertLess(abs(rate - 0.10), 0.03, "one-person roles stay at 10 %")
        rate = sum(sa.audit_sampled(f"r{i}", ["Remixer"], "2026-11-01") for i in range(2000)) / 2000
        self.assertLess(abs(rate - 0.10), 0.03, "a remix is a one-person role too")

    # ---- Fable 15:40Z band-hint stamp ruling ----
    STAMP = {"proofRequest": {"at": "2026-10-20T01:43:56Z", "noticeSentAt": "2026-10-20T01:43:57Z",
                              "reasons": ["validator_band_hint"]}}

    def phase1(self):
        return sa.ScorePolicy(enabled=True, admit_band_b=True)

    def test_a_band_hint_only_stamp_is_not_an_open_ask_in_phase_1(self):
        rows = [row("st", band="B", meta=self.STAMP)]
        res, w = self.go(rows)
        self.assertEqual(w.calls, [], "phase 1 off: the stamp still holds (and band B too)")
        res, w = self.go([row("st2", band="B", pid="p2", meta=self.STAMP)], sp=self.phase1())
        self.assertEqual([i for c in w.calls for i in c[1]], ["st2"])
        self.assertEqual(self.convo_asked, {500: "2026-10-20T01:43:56Z"}, "conversation checked since the stamp")

    def test_engaged_users_and_other_reasons_keep_the_proof_path(self):
        """proof_on_file || conversation_since_ask || support_email_90d -> proof path (Fable (3))."""
        self.proof(entries=[{"user_id": 601, "request_id": None, "kind": "pending_doc", "source": "cs-intercom",
                             "ref": "conv:1"}], contacts=[602])
        two = {"proofRequest": dict(self.STAMP["proofRequest"], reasons=["validator_band_hint", "proof_requested"])}
        other = {"proofRequest": dict(self.STAMP["proofRequest"], reasons=["high_risk_score"])}
        rows = [row("proof", uid=601, pid="a", band="B", meta=self.STAMP),
                row("mail", uid=602, pid="b", band="B", meta=self.STAMP),
                row("convo", uid=603, pid="c", band="B", meta=self.STAMP),
                row("unknown", uid=604, pid="d", band="B", meta=self.STAMP),
                row("second", uid=605, pid="e", band="B", meta=two),
                row("other", uid=606, pid="f", band="B", meta=other),
                row("clean", uid=607, pid="g", band="B", meta=self.STAMP)]
        res, w = self.go(rows, sp=self.phase1(), convo={603: True, 604: None})
        self.assertEqual([i for c in w.calls for i in c[1]], ["clean"])
        d = self.decisions()
        self.assertIn("proof on file", d["proof"]["reason"])
        self.assertIn("emailed support", d["mail"]["reason"])
        self.assertIn("Intercom conversation since the ask", d["convo"]["reason"])
        self.assertIn("status unknown", d["unknown"]["reason"])
        self.assertIn("proof_requested", d["second"]["reason"])
        self.assertIn("proof_requested", d["other"]["reason"])

    def test_unknown_proof_on_file_holds_every_row(self):
        """Fable review-core-10733 condition 1, fail closed: proof status unknown = every claimant
        may be engaged, so nothing is approved (stamped or not)."""
        decide.PROOF_ON_FILE.unlink()
        res, w = self.go([row("st", band="B", meta=self.STAMP), row("plain", pid="p2")], sp=self.phase1())
        self.assertEqual(w.calls, [])
        d = self.decisions()
        self.assertIn("proof on file unknown", d["plain"]["reason"])
        self.assertEqual(res.engaged_excluded, 2)

    def test_engaged_users_are_excluded_on_every_row_not_only_stamped_ones(self):
        """Fable review-core-10733 condition 1: core now parks rows in UVN WITHOUT a stamp; the
        executor still keeps proof-on-file, support-email and Intercom-since-the-ask users out,
        and logs the count."""
        self.proof(entries=[{"user_id": 701, "request_id": None, "kind": "pending_doc", "source": "cs-intercom",
                             "ref": "conv:9"}], contacts=[702])
        rows = [row("doc", uid=701, pid="a"), row("mail", uid=702, pid="b"), row("ic", uid=703, pid="c"),
                row("clean", uid=704, pid="d")]
        res, w = self.go(rows, convo={703: True})
        self.assertEqual([i for c in w.calls for i in c[1]], ["clean"])
        self.assertEqual(res.engaged_excluded, 3)
        self.assertIn("3 excluded as engaged claimants", res.line())
        self.assertEqual(set(self.convo_asked), {703, 704}, "no Intercom look-up for users already excluded")
        self.assertEqual(self.convo_asked[704], "2026-10-19T00:00:00Z", "unstamped: since the request was made")

    def test_a_stamp_with_empty_attachments_is_unanswered_and_replied_at_is_answered(self):
        """Fable review-core-10733 follow-up: pin the reply semantics of the stamp."""
        empty = {"proofRequest": dict(self.STAMP["proofRequest"], attachments=[])}
        replied = {"proofRequest": dict(self.STAMP["proofRequest"], repliedAt="2026-10-20T05:00:00Z")}
        attached = {"proofRequest": dict(self.STAMP["proofRequest"], attachments=[{"id": "a1"}])}
        rows = [row("empty", band="B", meta=empty), row("replied", band="B", pid="p2", meta=replied),
                row("attached", band="B", pid="p3", meta=attached)]
        res, w = self.go(rows, sp=self.phase1())
        self.assertEqual([i for c in w.calls for i in c[1]], ["empty"])
        d = self.decisions()
        self.assertIn("proof_requested(answered)", d["replied"]["reason"])
        self.assertIn("proof_requested(answered)", d["attached"]["reason"])

    def test_the_account_gate_decides_last_and_only_an_allow_approves(self):
        """Steward 019: hold / unknown = skip (no approval); one gate call per account per run."""
        rows = [row("g1", uid=901, pid="g1"), row("g2", uid=902, pid="g2"), row("g3", uid=903, pid="g3"),
                row("g4", uid=903, pid="g4")]
        asked = []

        def gate(uid):
            asked.append(uid)
            return {901: _allow(), 902: _gate.GateResult(_gate.HOLD, ("count_90d 412 >= 250",)),
                    903: _gate.GateResult(_gate.UNKNOWN, ("check could not run",))}[uid]
        res, w = self.go(rows, gate=gate)
        self.assertEqual([i for c in w.calls for i in c[1]], ["g1"])
        d = self.decisions()
        self.assertIn("account gate hold (count_90d 412 >= 250): no approval, proof ask", d["g2"]["reason"])
        self.assertIn("account gate unknown", d["g3"]["reason"])
        self.assertEqual(res.account_held, 3)
        self.assertEqual(sorted(asked), [901, 902, 903], "one gate call per account per run")
        self.assertIn("3 held by the account gate", res.line())

    def test_an_amber_fraud_watch_account_is_not_approved_and_a_green_one_still_is(self):
        """Captain 2026-11-14. The gate ALLOWS an amber account (the watch was never a hold), so until this
        rule the job approved it: 28 rows of 5 amber accounts in the dry run. Same row shape on both accounts;
        the band is the only difference."""
        rows = [row("amber1", uid=911, pid="pa"), row("amber2", uid=911, pid="pa2"), row("green1", uid=912, pid="pg")]
        gate = lambda uid: {911: _allow("amber", ("AMBER 37 approvals despite decline in 90d",)),
                            912: _allow("green", ("no account-level signal; under every level",))}[uid]
        res, w = self.go(rows, gate=gate)
        self.assertEqual([i for c in w.calls for i in c[1]], ["green1"], "only the green account's row is written")
        d = self.decisions()
        self.assertEqual(d["green1"]["decision"], "approve")
        for rid in ("amber1", "amber2"):
            self.assertEqual(d[rid]["decision"], "hold")
            self.assertIn("account on fraud watch (gate band amber: AMBER 37 approvals despite decline in 90d): "
                          "no score approval", d[rid]["reason"])
        self.assertEqual((res.approved, res.watch_held, res.account_held), (1, 2, 0))
        self.assertEqual(res.held, {"account on fraud watch": 2})
        self.assertIn("2 not approved: account not green at the gate (fraud watch)", res.line())

    def test_the_amber_rule_holds_in_shadow_too(self):
        """Dry run and apply are one code path: a shadow run must not count an amber row as a would-approve."""
        rows = [row("amber1", uid=911, pid="pa"), row("green1", uid=912, pid="pg")]
        gate = lambda uid: _allow("amber" if uid == 911 else "green")
        res, w = self.go(rows, mode="shadow", gate=gate)
        self.assertEqual((res.would_approve, res.watch_held, w.calls), (1, 1, []))

    def test_an_allow_that_is_red_or_names_no_band_is_not_approved(self):
        rows = [row("red1", uid=921, pid="pr"), row("none1", uid=922, pid="pn"), row("green1", uid=923, pid="pg")]
        gate = lambda uid: {921: _allow("red", ("RELEASED (not verified clean): manual hold",)),
                            922: _gate.GateResult(_gate.ALLOW), 923: _allow()}[uid]
        res, w = self.go(rows, gate=gate)
        self.assertEqual([i for c in w.calls for i in c[1]], ["green1"])
        d = self.decisions()
        self.assertIn("account gate band red (allowed by the gate, not green", d["red1"]["reason"])
        self.assertIn("account gate band unread", d["none1"]["reason"])
        self.assertEqual(res.watch_held, 2)

    def test_unverified_rows_are_in_scope_and_written_from_their_own_status(self):
        rows = [row("u", status=decide.UNVERIFIED), row("v", pid="p2")]
        res, w = self.go(rows)
        self.assertEqual(sorted((c[1][0], c[2]) for c in w.calls),
                         [("u", decide.UNVERIFIED), ("v", decide.UVN)])


    # ---- QA @6c2a51b4 ----
    def test_caps_are_rechecked_under_the_write_lock_against_committed_outcomes(self):
        """Another run commits 2 score approvals for the same user between our read and our write."""
        def other_run_commits():
            for i in range(2):
                d = decide.request_decision(row(f"other{i}", pid=f"o{i}"))
                d.evidence_kind = sa.EVIDENCE_KIND
                decide._set(d, "approve", "other run")
                decide.record_decision(self.db, "score-other", "apply", d, NOW)
                decide.record_outcome(self.db, "score-other", d.request_id, "approve", "approved", NOW)
            return None
        orig = sa.paused
        calls = []
        sa.paused = lambda: (calls.append(1), other_run_commits() if len(calls) == 2 else None)[1]
        self.addCleanup(setattr, sa, "paused", orig)
        res, w = self.go([row("a"), row("b", pid="p2"), row("c", pid="p3")],
                         sp=sa.ScorePolicy(enabled=True, per_user_per_day=2))
        self.assertEqual(w.calls, [], "the user already has 2 committed score approvals at write time")
        self.assertEqual(res.capped, 3)
        outs = [o for (o,) in self.db.execute("SELECT outcome FROM decision_outcomes WHERE run_id = ?", (res.run_id,))]
        # 1 deferred at decision time (cap 2), the 2 decided approvals refused at write time.
        self.assertEqual(outs, ["skipped:user_score_cap_at_write"] * 2)

    def test_a_pause_during_the_reads_stops_the_writes(self):
        test = self

        class PausingAdmin(FakeAdmin):
            def get(self, path, params=None):
                sa.PAUSE_FILE.write_text("audit-7 precision 0.91")
                return super().get(path, params)
        rows = [row("a"), row("b", pid="p2")]
        res, w = self.go(rows, admin=PausingAdmin(rows))
        test.assertEqual(w.calls, [])
        test.assertTrue(res.paused_mid_run)
        outs = {o for (o,) in self.db.execute("SELECT outcome FROM decision_outcomes WHERE run_id = ?", (res.run_id,))}
        test.assertEqual(outs, {"skipped:paused"})

    def test_rate_limited_reads_are_reported_as_incomplete(self):
        class LimitedAdmin(FakeAdmin):
            def get(self, path, params=None):
                from credit_review import admin as admin_api
                raise admin_api.AdminError("admin GET failed: HTTP 429")
        rows = [row("a")]
        res, w = self.go(rows, admin=LimitedAdmin(rows))
        self.assertTrue(res.read_exhausted)
        self.assertIn("READS INCOMPLETE", res.line())

    def test_the_cli_fails_loud_on_incomplete_reads(self):
        import importlib.util
        import io
        from contextlib import redirect_stdout
        spec = importlib.util.spec_from_file_location("credit_review_cli", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        res = sa.ScoreResult(run_id="score-x", mode="apply")
        res.read_exhausted = True
        orig = sa.run
        sa.run = lambda *a, **k: res
        self.addCleanup(setattr, sa, "run", orig)
        for attr in ("KILL_SWITCH",):
            self.addCleanup(setattr, sa, attr, getattr(sa, attr))
            setattr(sa, attr, Path(self.tmp) / "nope")
        self.addCleanup(setattr, decide, "KILL_SWITCH", decide.KILL_SWITCH)
        decide.KILL_SWITCH = Path(self.tmp) / "nope2"
        pol = Path(self.tmp) / "pol.json"
        args = cli.argparse.Namespace(pause=None, resume=False, mode="apply", max_per_run=None,
                                      ledger=os.path.join(self.tmp, "cli.sqlite3"))
        orig_load, orig_sp = decide.Policy.load, sa.ScorePolicy.load
        decide.Policy.load = staticmethod(lambda *a, **k: policy())
        sa.ScorePolicy.load = staticmethod(lambda *a, **k: sa.ScorePolicy(enabled=True))
        self.addCleanup(setattr, decide.Policy, "load", orig_load)
        self.addCleanup(setattr, sa.ScorePolicy, "load", orig_sp)
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.cmd_score_approve(args)
        self.assertEqual(rc, 1)
        self.assertNotIn("NO_REPLY", buf.getvalue())
        self.assertIn("READS INCOMPLETE", buf.getvalue())

    def test_the_candidate_limit_applies_after_paid_first(self):
        """QA @f88ed225 (1): 5 older free rows + 1 newer paid row with candidate_limit 3 -> the
        paid row is still a candidate (and approved first)."""
        rows = [row(f"old{i}", uid=1100 + i, pid=f"o{i}", created=f"2026-10-01T00:00:0{i}Z") for i in range(5)]
        rows.append(row("paid", uid=900, pid="pp", created="2026-10-19T00:00:00Z"))
        res, w = self.go(rows, sp=sa.ScorePolicy(enabled=True, candidate_limit=3))
        approved = [i for c in w.calls for i in c[1]]
        self.assertEqual(approved[0], "paid")
        self.assertEqual(len(approved), 3)

    def test_hitting_the_scan_cap_fails_loud_and_approves_nothing(self):
        orig = sa.SCAN_CAP
        sa.SCAN_CAP = 2
        self.addCleanup(setattr, sa, "SCAN_CAP", orig)
        res, w = self.go([row("a"), row("b", pid="p2")])
        self.assertEqual(w.calls, [])
        self.assertTrue(res.read_exhausted)
        self.assertIn("scan reached", res.note)

    def test_an_unwritable_audit_dir_writes_nothing_and_pauses(self):
        """QA @f88ed225 (2): no approval may be written that its audit sample cannot follow."""
        blocker = Path(self.tmp) / "not-a-dir"
        blocker.write_text("x")
        sa.AUDIT_DIR = blocker / "audit"
        res, w = self.go([row("a")])
        self.assertEqual(w.calls, [])
        self.assertTrue(res.audit_failed)
        self.assertTrue(sa.PAUSE_FILE.exists(), "self-paused")
        res2, w2 = self.go([row("b", pid="p2")])
        self.assertEqual((w2.calls, res2.mode), ([], "shadow"), "later runs are shadow until --resume")

    def test_a_sample_committed_but_never_filed_is_filed_by_the_next_run_first(self):
        """QA @7c371efa: a run killed between a committed write and its filing loses nothing:
        the next apply run files it before approving anything new; filing is idempotent."""
        orig = sa.write_audit_sample
        sa.write_audit_sample = lambda *a, **k: True          # the crash: nothing filed
        rows = [row(f"s{i}", uid=800 + i, pid=f"sp{i}") for i in range(60)]
        res, w = self.go(rows)
        sa.write_audit_sample = orig
        self.assertGreater(res.audit_sampled, 0)
        f = sa.AUDIT_DIR / "2026-10-20.jsonl"
        self.assertFalse(f.exists() and f.read_text().strip(), "nothing filed by the crashed run")
        res2, w2 = self.go([row("next", uid=990, pid="nx")])
        lines = [json.loads(l) for l in f.read_text().splitlines()]
        self.assertEqual(len({l["request_id"] for l in lines if l["run_id"] == res.run_id}), res.audit_sampled)
        self.go([row("again", uid=991, pid="ny")])
        lines2 = [json.loads(l) for l in f.read_text().splitlines()]
        self.assertEqual(len(lines2), len(lines) + sum(1 for l in lines2[len(lines):] if l["run_id"] != res.run_id),
                         "re-running never files a sample twice")
        self.assertEqual(len({(l["run_id"], l["request_id"]) for l in lines2}), len(lines2))

    def test_negative_or_zero_popularity_never_reaches_the_writer(self):
        res, w = self.go([row("neg", pop=-1), row("zero", pop=0, pid="p2"), row("ok", pop=1, pid="p3")])
        self.assertEqual([i for c in w.calls for i in c[1]], ["ok"])
        d = self.decisions()
        self.assertIn("unknown", d["neg"]["reason"])
        self.assertIn("human", d["zero"]["reason"])

    def test_an_unappendable_daily_audit_file_writes_nothing(self):
        """QA @389d0d62: the daily target itself is checked (here it is a directory)."""
        (sa.AUDIT_DIR / "2026-10-20.jsonl").mkdir(parents=True)
        res, w = self.go([row("a")])
        self.assertEqual(w.calls, [])
        self.assertTrue(res.audit_failed)
        self.assertTrue(sa.PAUSE_FILE.exists())

    def test_an_audit_file_failure_after_the_writes_pauses_later_runs(self):
        orig = sa.write_audit_sample

        def failing(db, res, now, since=None):
            if since is not None:
                return orig(db, res, now, since=since)     # the start-of-run reconcile passes
            sa.write_audit_sample_failed(res, now, OSError(28, "No space left on device"))
            return False
        sa.write_audit_sample = failing
        self.addCleanup(setattr, sa, "write_audit_sample", orig)
        res, w = self.go([row("a")])
        self.assertTrue(res.audit_failed)
        self.assertIn("AUDIT SAMPLE NOT FILED", res.line())
        self.assertTrue(sa.PAUSE_FILE.exists())

    def test_the_read_budget_is_spent_paid_first(self):
        rows = [row(f"free{i}", uid=1000 + i, pid=f"f{i}", created=f"2026-10-01T00:{i // 60:02d}:{i % 60:02d}Z")
                for i in range(151)]
        rows.append(row("paid", uid=900, pid="paidp", created="2026-10-19T00:00:00Z"))
        res, w = self.go(rows, sp=sa.ScorePolicy(enabled=True, max_profiles_per_run=150, max_per_run=1))
        self.assertEqual([i for c in w.calls for i in c[1]], ["paid"])


    # ---- Fable 10-22 09:30Z: anchors are trusted or none; own Muso credits never count ----
    def creds(self, **rules):
        return dict({"approve_owning_track": 100, "approve_credit_exists": 100, "approve_common_collaborator": 100}, **rules)

    def test_trusted_roles_make_anchor_kind_trusted(self):
        r = row("t", band="B", roles=("Producer", "Mixing"), rules=self.creds(approve_credit_exists=0))
        self.assertEqual(sa.classify_anchor(r, {"producer", "mixing"}), ("trusted", None))

    def test_an_own_muso_credit_is_never_an_anchor(self):
        """82d6f002 (same second), a577a774 / 8120b80f / 0531dfa2 (written later) AND the earlier-Muso
        rows (3617d070 Conductor 2023): if approve_credit_exists approved it and no trusted source
        names the claimant, the row is held, whatever the Muso credit's date."""
        for rid, roles in (("82d6f002", ("Mastering",)), ("a577a774", ("Mastering",)), ("0531dfa2", ("Composer", "Producer")),
                           ("3617d070", ("Conductor",))):
            r = row(rid, band="B", roles=roles, rules=self.creds(approve_credit_exists=0))
            kind, held = sa.classify_anchor(r, set())
            self.assertIsNone(kind, rid)
            self.assertIn("duplicate signal, never evidence", held)
        r = row("part", band="B", roles=("Composer", "Producer"), rules=self.creds(approve_credit_exists=0))
        self.assertIn("for Producer", sa.classify_anchor(r, {"composer"})[1], "every role needs a trusted credit")

    def test_a_validator_approval_on_its_own_is_provisional_none(self):
        for rules in (self.creds(approve_common_collaborator=0), self.creds(), self.creds(approve_owning_track=0)):
            r = row("own", band="B", roles=("Bass",), rules=rules)
            self.assertEqual(sa.classify_anchor(r, set()), ("none", None))

    def test_no_claimed_role_is_held(self):
        """QA @23e75a95: empty roles must not bypass the anchor gate."""
        for roles in ((), ("",), (" ",)):
            kind, held = sa.classify_anchor(row("empty", band="B", roles=roles), set())
            self.assertIsNone(kind)
            self.assertIn("names no role", held)

    def test_anchor_kind_is_recorded_and_held_rows_counted(self):
        rows = [row("tr", band="B", meta=self.STAMP), row("no", band="B", pid="p2", meta=self.STAMP),
                row("held", band="B", pid="p3", meta=self.STAMP)]
        res, w = self.go(rows, sp=self.phase1(), anchors=lambda rs: {
            "tr": ("trusted", None), "no": ("none", None), "held": (None, "no independent anchor: ...")})
        self.assertEqual(sorted(i for c in w.calls for i in c[1]), ["no", "tr"])
        d = self.decisions()
        self.assertEqual((d["tr"]["evidence_kind"], d["no"]["evidence_kind"]),
                         (sa.TRUSTED_EVIDENCE_KIND, sa.EVIDENCE_KIND))
        self.assertIn("anchor_kind=trusted", d["tr"]["reason"])
        self.assertIn("anchor_kind=none", d["no"]["reason"])
        self.assertNotIn("muso_earlier", " ".join(x["reason"] for x in d.values()))
        self.assertEqual(res.no_anchor, 1)
        self.assertIn("anchor_kind {'none': 1, 'trusted': 1}", res.line())

    def test_editorial_roles_need_a_trusted_anchor_under_pop_30(self):
        """2026-10-22 22:40Z prod: Producer+Editorial rows approved on the validator alone. The
        decider's editorial rule now binds score-approve too."""
        rows = [row("ed_none", uid=601, pid="pa", roles=("Producer", "Editorial"), pop=16),
                row("ed_trusted", uid=602, pid="pb", roles=("Producer", "Editorial"), pop=16),
                row("ed_big", uid=603, pid="pc", roles=("Vocal Editing",), pop=30),
                row("plain", uid=604, pid="pd", roles=("Producer",), pop=16)]
        terms = tuple(json.loads(Path(__file__).resolve().parents[2].joinpath(
            "policies/credit-trust-decide.json").read_text())["editorial_role_terms"])
        pol = dataclasses.replace(policy(), editorial_role_terms=terms)
        calm = SimpleNamespace(requests_24h=1, requests_7d=1)
        res, w = self.go(rows, sp=self.phase1(), pol=pol, anchors=lambda rs: {
            "ed_none": ("none", None), "ed_trusted": ("trusted", None), "ed_big": ("trusted", None),
            "plain": ("none", None)}, editorial_velocity=lambda rs: {str(r["id"]): calm for r in rs})
        self.assertEqual(sorted(i for c in w.calls for i in c[1]), ["ed_trusted", "plain"])
        d = self.decisions()
        self.assertIn("never the validator's verdict alone", d["ed_none"]["reason"])
        self.assertIn("pop >= 30", d["ed_big"]["reason"])
        self.assertEqual(res.editorial_held, 2)
        self.assertIn("2 editorial-role rows held", res.line())

    def test_editorial_proof_path_wordings_are_recorded_as_ask(self):
        terms = tuple(json.loads(Path(__file__).resolve().parents[2].joinpath(
            "policies/credit-trust-decide.json").read_text())["editorial_role_terms"])
        pol = dataclasses.replace(policy(), editorial_role_terms=terms)
        rows = [row("ed_doc", uid=611, pid="qa", roles=("Editorial",), pop=30),
                row("ed_proof", uid=612, pid="qb", roles=("Editorial",), pop=16)]
        res, w = self.go(rows, sp=self.phase1(), pol=pol,
                         anchors=lambda rs: {str(r["id"]): ("none", None) for r in rs})
        d = self.decisions()
        self.assertIn("documentation required", d["ed_doc"]["reason"])
        self.assertIn("never the validator's verdict alone", d["ed_proof"]["reason"])
        self.assertEqual(res.outcomes["ed_doc"], "ask")
        self.assertEqual(res.outcomes["ed_proof"], "ask")
        self.assertEqual(w.calls, [])

    def test_a_trusted_editorial_claim_still_gets_the_deciders_velocity_hold(self):
        """QA @d0f07f55: editorial weighs double against 50/24 h and 150/7 d (decide.editorial_velocity)."""
        terms = tuple(json.loads(Path(__file__).resolve().parents[2].joinpath(
            "policies/credit-trust-decide.json").read_text())["editorial_role_terms"])
        pol = dataclasses.replace(policy(), editorial_role_terms=terms)
        rows = [row("at_24h", uid=631, pid="sa", roles=("Editorial",), pop=16),
                row("at_7d", uid=632, pid="sb", roles=("Editorial",), pop=16),
                row("below", uid=633, pid="sc", roles=("Editorial",), pop=16),
                row("unread", uid=634, pid="sd", roles=("Editorial",), pop=16)]
        vel = {"at_24h": SimpleNamespace(requests_24h=25, requests_7d=25),
               "at_7d": SimpleNamespace(requests_24h=0, requests_7d=75),
               "below": SimpleNamespace(requests_24h=24, requests_7d=74), "unread": None}
        seen = []
        res, w = self.go(rows, sp=self.phase1(), pol=pol, anchors=lambda rs: {str(r["id"]): ("trusted", None) for r in rs},
                         editorial_velocity=lambda rs: seen.extend(str(r["id"]) for r in rs) or vel)
        self.assertEqual([i for c in w.calls for i in c[1]], ["below"])
        d = self.decisions()
        self.assertIn("high velocity, editorial weighs double (25/24h, 25/7d (x2))", d["at_24h"]["reason"])
        self.assertIn("(0/24h, 75/7d (x2))", d["at_7d"]["reason"])
        self.assertIn("velocity could not be read", d["unread"]["reason"])
        self.assertEqual(sorted(seen), ["at_24h", "at_7d", "below", "unread"], "read only for editorial rows")

    def test_the_read_budget_rotates_to_rows_not_decided_recently(self):
        """2026-10-23: 35 runs re-read the same 150 profiles. With a budget of 2 profiles, the second
        run must read the two it has not decided yet, not the first two again."""
        rows = [row(f"r{i}", uid=700 + i, pid=f"rot{i}", approved=False) for i in range(4)]
        sp = sa.ScorePolicy(enabled=True, max_profiles_per_run=2)
        self.go(rows, sp=sp)
        first = set(self.decisions())
        self.assertEqual(len(first), 2)
        res, w = self.go(rows, sp=sp)
        latest = {r[0] for r in self.db.execute(
            "SELECT request_id FROM decisions WHERE run_id = ?", (res.run_id,))}
        self.assertEqual(latest, {"r0", "r1", "r2", "r3"} - first)

    def test_held_paid_rows_cool_down_so_the_budget_reaches_free_rows(self):
        """Firstmate 171: a held row is re-read at most every 6 h; paid still first among due rows."""
        rows = [row("paid1", uid=900, pid="pa1", approved=False), row("paid2", uid=900, pid="pa2", approved=False),
                row("free1", uid=701, pid="fr1", approved=False), row("free2", uid=702, pid="fr2", approved=False)]
        sp = sa.ScorePolicy(enabled=True, max_profiles_per_run=2)
        read = []
        for _ in range(3):
            res, _w = self.go(rows, sp=sp)
            read.append({r[0] for r in self.db.execute("SELECT request_id FROM decisions WHERE run_id = ?", (res.run_id,))})
        self.assertEqual(read[0], {"paid1", "paid2"}, "paid first")
        self.assertEqual(read[1], {"free1", "free2"}, "held paid rows cool down; the spare budget reaches free rows")
        self.assertEqual(read[2], {"paid1", "paid2"}, "all cooling: paid first again")

    def test_an_unknown_engagement_source_is_retried_next_run_not_cooled(self):
        """QA @1340: Intercom status unknown (and a stale proof export) hold the row this run only."""
        rows = [row("paid1", uid=900, pid="pa1"), row("free1", uid=701, pid="fr1", approved=False)]
        sp = sa.ScorePolicy(enabled=True, max_profiles_per_run=1)
        res, _w = self.go(rows, sp=sp, convo={900: None})
        d = self.decisions()
        self.assertIn("Intercom conversation status unknown", d["paid1"]["reason"])
        res2, w2 = self.go(rows, sp=sp)          # Intercom back
        latest = {r[0] for r in self.db.execute("SELECT request_id FROM decisions WHERE run_id = ?", (res2.run_id,))}
        self.assertEqual(latest, {"paid1"}, "the paid row is re-read at once, not cooled behind the free row")
        self.assertEqual([i for c in w2.calls for i in c[1]], ["paid1"])

    def test_a_transient_hold_is_not_cooled_down(self):
        decide.ensure_schema(self.db)
        for rid, dec, why in (("t1", "hold", "score approval not now: evidence unreadable (HTTP 503)"),
                              ("t2", "hold", "score approval not now: proof path: engaged user (proof on file unknown: "
                                             "export older than 3h): stage 2"),
                              ("t3", "hold", "score approval not now: proof path: engaged user (Intercom conversation "
                                             "status unknown): stage 2"),
                              ("d1", "hold", "score approval not now: organization / label / publisher / studio role"),
                              ("a1", "approve", "score approval anchor_kind=trusted")):
            self.db.execute("INSERT INTO decisions (run_id, decided_at, request_id, profile_id, decision, reason, mode, "
                            "big_track, claimed_roles) VALUES ('score-x', ?, ?, 'p', ?, ?, 'apply', 0, 'Bass')",
                            (NOW.strftime("%Y-%m-%dT%H:%M:%SZ"), rid, dec, why))
        self.assertEqual(sa.recently_held(self.db, NOW), {"d1"})

    def test_the_reread_stops_at_its_time_budget(self):
        """18:40Z/18:55Z 2026-10-23: 500 profiles per run hit the cron's 900 s timeout; the read phase now
        stops at its deadline and the rest waits for the next run."""
        rows = [row(f"tb{i}", uid=800 + i, pid=f"tbp{i}") for i in range(5)]
        ticks = iter(range(100))
        notes = []
        got = sa.reread(FakeAdmin(rows), [(r["id"], r["profileId"], 0.0, r["status"]) for r in rows],
                        max_profiles=500, sleep=lambda _s: None, note=notes, deadline=2, clock=lambda: next(ticks))
        self.assertEqual(len(got), 2)
        self.assertIn("time budget", notes[0])

    def test_anchors_past_the_deadline_are_a_transient_hold(self):
        from unittest import mock
        from credit_review import evidence
        r1, r2 = row("an1", pid="anp1"), row("an2", pid="anp2")
        ev = mock.Mock(roles=[evidence.RoleEvidence("Producer", "producer", evidence.CONFIRMED)], errors=[])
        ticks = iter([0, 99, 99])
        with mock.patch.object(evidence.EvidenceBuilder, "build", return_value=ev):
            out = sa.live_anchors(object(), sleep=lambda _s: None, deadline=10, clock=lambda: next(ticks))([r1, r2])
        self.assertEqual(out["an1"][0], "trusted")
        self.assertIn("time budget", out["an2"][1])
        self.assertTrue(any(t in out["an2"][1] for t in sa.TRANSIENT_HOLD), "never cooled")

    def test_fanout_past_its_deadline_is_unreadable_and_transient(self):
        """QA @1347: the fan-out phase is bounded too; past the deadline every user reads None."""
        from unittest import mock
        r = row("fo1", uid=901, pid="fop1")
        with mock.patch.object(sa.subprocess, "run") as run:
            out = sa.live_fanout(object(), NOW, sleep=lambda _s: None, deadline=10, clock=lambda: 99)([r])
        run.assert_not_called()
        self.assertEqual(out, {901: None})
        with mock.patch.object(sa.subprocess, "run", side_effect=sa.subprocess.TimeoutExpired("trino", 5)):
            out = sa.live_fanout(object(), NOW, sleep=lambda _s: None, deadline=100, clock=lambda: 0)([r])
        self.assertEqual(out, {901: None})
        self.assertTrue(any(t in "same_anchor_requests_7d unreadable" for t in sa.TRANSIENT_HOLD))

    def test_a_fanout_deadline_after_the_bar_is_met_still_holds_unchecked_admitted_rows(self):
        """QA @1347: 4 admitted rows, the bar (3) met by the first three, the deadline before the 4th read."""
        from unittest import mock
        rows = [row(f"r{i}", uid=901, pid=f"fp{i}") for i in range(1, 5)]
        trino = "\n".join(f'"r{i}","901","fp{i}","t-r{i}","{{Producer}}","2026-10-2{i}T00:00:00Z"' for i in range(1, 5))
        ticks = iter([0, 0, 0, 0, 99, 99, 99])
        with mock.patch.object(sa.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=trino)), \
                mock.patch.object(sa.admin_api, "track_raw_credits", return_value=[]), \
                mock.patch.object(sa, "own_earlier_credit", return_value=True):
            out = sa.live_fanout(object(), NOW, sleep=lambda _s: None, deadline=10, clock=lambda: next(ticks))(rows)
        self.assertIsNone(out[901], "never a partial set that lets r4 through unchecked")

    def test_a_write_batch_starts_only_if_its_worst_case_ends_inside_the_run_budget(self):
        """QA @1347 23:48Z: a batch near the deadline is never started (the cron would kill it mid-PUT)."""
        from unittest import mock
        clock = [0.0]
        rows = [row("w1", uid=970, pid="w1"), row("w2", uid=971, pid="w2")]

        class SlowWriter(Writer):
            def __call__(self, status, ids, expected):
                clock[0] = sa.RUN_BUDGET_S - sa.WRITE_BATCH_WORST_S + 1   # the first batch ran long
                return super().__call__(status, ids, expected)
        w = SlowWriter()
        cands = lambda risk, limit: [(r["id"], r["profileId"], 0.0, r["status"], r["userId"]) for r in rows]
        with mock.patch("time.monotonic", side_effect=lambda: clock[0]), mock.patch.object(decide, "BATCH", 1):
            res = sa.run(FakeAdmin(rows), self.db, mode="apply", policy=policy(), sp=sa.ScorePolicy(enabled=True),
                         candidates=cands, writer=w, readback=lambda st, i: set(), now=NOW, sleep=lambda _s: None,
                         conversations=lambda users: {u: False for u in users},
                         anchors=lambda rs: {str(r["id"]): ("none", None) for r in rs},
                         fanout=lambda rs: {}, editorial_velocity=lambda rs: {}, profile_burst=NO_BURST)
        self.assertEqual(len(w.calls), 1, "the second batch is not started")
        out = dict(self.db.execute("SELECT request_id, outcome FROM decision_outcomes WHERE run_id=?", (res.run_id,)))
        self.assertEqual(sorted(out.values()), ["approved", "skipped:time_budget"])
        self.assertIn("write budget", res.note)
        self.assertLessEqual(sa.FANOUT_BUDGET_S + sa.WRITE_BATCH_WORST_S, sa.RUN_BUDGET_S)
        self.assertLess(sa.RUN_BUDGET_S, 900)

    def test_a_busy_write_lock_near_the_deadline_skips_the_writes_never_waits_past_the_budget(self):
        """QA @1347 00:02Z: the lock wait is bounded by what is left of the run budget."""
        import fcntl
        from unittest import mock
        clock = [0.0]
        rows = [row("lk1", uid=980, pid="lk1")]
        cands = lambda risk, limit: [(r["id"], r["profileId"], 0.0, r["status"], r["userId"]) for r in rows]

        def anchors(rs):
            clock[0] = sa.RUN_BUDGET_S - sa.WRITE_BATCH_WORST_S + 1   # the live phases ran long
            return {str(r["id"]): ("none", None) for r in rs}
        w, slept = Writer(), []
        with open(decide.WRITE_LOCK, "a+") as peer:
            fcntl.flock(peer.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)   # a peer holds the lock
            with mock.patch("time.monotonic", side_effect=lambda: clock[0]), \
                    mock.patch("time.sleep", side_effect=lambda d: (slept.append(d), clock.__setitem__(0, clock[0] + d))):
                res = sa.run(FakeAdmin(rows), self.db, mode="apply", policy=policy(), sp=sa.ScorePolicy(enabled=True),
                             candidates=cands, writer=w, readback=lambda st, i: set(), now=NOW, sleep=lambda _s: None,
                             conversations=lambda users: {u: False for u in users}, anchors=anchors,
                             fanout=lambda rs: {}, editorial_velocity=lambda rs: {}, profile_burst=NO_BURST)
        self.assertEqual(w.calls, [])
        out = [o for (o,) in self.db.execute("SELECT outcome FROM decision_outcomes WHERE run_id=?", (res.run_id,))]
        self.assertEqual(out, ["skipped:write_lock_busy"])
        self.assertIn("write lock busy", res.note)
        self.assertLessEqual(sum(slept), 1, "no wait past the write budget")

    def test_live_phases_run_in_deadline_order(self):
        """QA @1347: editorial velocity runs before fan-out, and each live phase gets a later deadline than the
        one before it, so a fan-out that uses its budget can never starve editorial velocity."""
        from unittest import mock
        order, deadlines = [], {}

        def factory(name):
            def make(*a, deadline=None, **k):
                deadlines[name] = deadline
                return lambda rs: order.append(name) or {}
            return make
        self.assertLess(sa.PROFILE_BURST_BUDGET_S, sa.ANCHOR_BUDGET_S)
        self.assertLess(sa.ANCHOR_BUDGET_S, sa.EDITORIAL_BUDGET_S)
        self.assertLess(sa.EDITORIAL_BUDGET_S, sa.FANOUT_BUDGET_S)
        r = row("ed1", uid=960, pid="ed", roles=("Producer", "Editorial"))
        terms = tuple(json.loads(Path(__file__).resolve().parents[2].joinpath(
            "policies/credit-trust-decide.json").read_text())["editorial_role_terms"])
        pol = dataclasses.replace(policy(), editorial_role_terms=terms)
        with mock.patch.object(sa, "live_anchors", factory("anchors")), \
                mock.patch.object(sa, "live_editorial_velocity", factory("editorial")), \
                mock.patch.object(sa, "live_fanout", factory("fanout")), \
                mock.patch.object(sa, "live_profile_burst", factory("burst")), \
                mock.patch("time.monotonic", return_value=1000.0):
            w = Writer()
            sa.run(FakeAdmin([r]), self.db, mode="shadow", policy=pol, sp=sa.ScorePolicy(enabled=True),
                   candidates=lambda risk, limit: [(r["id"], r["profileId"], 0.0, r["status"], r["userId"])],
                   writer=w, readback=lambda s, i: set(), now=NOW, sleep=lambda _s: None,
                   conversations=lambda users: {u: False for u in users})
        self.assertEqual(order, ["burst", "anchors", "editorial", "fanout"])
        self.assertEqual(deadlines, {"burst": 1000.0 + sa.PROFILE_BURST_BUDGET_S,
                                     "anchors": 1000.0 + sa.ANCHOR_BUDGET_S,
                                     "editorial": 1000.0 + sa.EDITORIAL_BUDGET_S,
                                     "fanout": 1000.0 + sa.FANOUT_BUDGET_S})

    def test_the_candidate_query_has_its_own_budget(self):
        from unittest import mock
        with mock.patch.object(sa.subprocess, "run", side_effect=sa.subprocess.TimeoutExpired("trino", 240)) as run:
            with self.assertRaises(sa.admin_api.AdminError):
                sa.replica_candidates(30, 10, timeout_s=sa.CANDIDATES_BUDGET_S)
        # The budget is the whole walk's: a page gets what is left of it, never a fresh budget of its own.
        self.assertGreater(run.call_args.kwargs["timeout"], sa.CANDIDATES_BUDGET_S - 5)
        self.assertLessEqual(run.call_args.kwargs["timeout"], sa.CANDIDATES_BUDGET_S)
        self.assertLess(sa.CANDIDATES_BUDGET_S, sa.READ_BUDGET_S)
        self.assertLess(sa.READ_BUDGET_S, sa.PROFILE_BURST_BUDGET_S)
        self.assertLess(sa.PROFILE_BURST_BUDGET_S, sa.ANCHOR_BUDGET_S)
        self.assertLess(sa.ANCHOR_BUDGET_S, sa.FANOUT_BUDGET_S)
        self.assertLessEqual(sa.FANOUT_BUDGET_S, 900 - 120, "room for caps + writes under the 900 s cron")
    def test_a_verdict_without_band_hint_is_held_like_core_refuses_it(self):
        """2026-10-23 20:36Z: 95 of 100 PUTs refused by core (band_not_a_or_b) for verdicts with no band_hint."""
        rows = [row("nob", uid=650, pid="nb1", band=None), row("okb", uid=651, pid="nb2", band="B")]
        res, w = self.go(rows, sp=self.phase1())
        self.assertEqual([i for c in w.calls for i in c[1]], ["okb"])
        self.assertIn("band_hint_missing", self.decisions()["nob"]["reason"])

    def test_trusted_approvals_get_no_verify_note_and_count_toward_caps(self):
        self.go([row("tr", band="B", meta=self.STAMP), row("no", band="B", pid="p2", meta=self.STAMP)],
                sp=self.phase1(), anchors=lambda rs: {"tr": ("trusted", None), "no": ("none", None)})
        from credit_review import verify_ledger
        self.db.executescript(verify_ledger.SCHEMA)
        self.assertEqual([c[0] for c in verify_notify.candidates(self.db, since_hours=None)], ["no"])
        users, profiles, fleet = sa.written_today(self.db, "2026-10-20T00:00:00Z")
        self.assertEqual(fleet, 2, "both kinds count toward the caps")

    def test_the_live_fetcher_uses_trusted_roles_only(self):
        from unittest import mock
        from credit_review import evidence
        r = row("live", band="B", roles=("Mastering", "Bass"), rules=self.creds(approve_credit_exists=0))
        ev = mock.Mock(roles=[evidence.RoleEvidence("Mastering", "master", evidence.CONFIRMED),
                              evidence.RoleEvidence("Bass", "performer", evidence.UNVERIFIABLE)], errors=[])
        with mock.patch.object(evidence.EvidenceBuilder, "build", return_value=ev):
            out = sa.live_anchors(object(), sleep=lambda _s: None)([r])
        self.assertIsNone(out["live"][0])
        self.assertIn("for Bass", out["live"][1])

    def test_incomplete_evidence_is_never_trusted(self):
        """QA @1dd5d112: a failed claimant-profile read can still yield CONFIRMED from a fallback name."""
        from unittest import mock
        from credit_review import evidence
        r = row("partial", band="B", roles=("Mastering",))
        ev = mock.Mock(roles=[evidence.RoleEvidence("Mastering", "master", evidence.CONFIRMED)],
                       errors=["claimant profile p1 unreadable: HTTP 503"])
        with mock.patch.object(evidence.EvidenceBuilder, "build", return_value=ev):
            out = sa.live_anchors(object(), sleep=lambda _s: None)([r])
        self.assertEqual(out["partial"][0], None)
        self.assertIn("evidence incomplete", out["partial"][1])

    # ---- same_anchor_requests_7d (Fable 10-22 09:30Z item 4; firstmate 143) ----
    def own(self, role, at, pid="p1"):
        return {"profile": {"source": "muso", "id": pid}, "credit": role, "createdAt": at}

    def test_own_earlier_credit_shape(self):
        q = {"profileId": "p1", "credits": ["Mastering"], "createdAt": "2026-10-14T10:00:00Z"}
        self.assertTrue(sa.own_earlier_credit(q, [self.own("mastering", "2026-05-21T00:00:00")]))
        self.assertFalse(sa.own_earlier_credit(q, [self.own("mastering", "2026-10-14T10:00:00")]), "the request's own write")
        self.assertFalse(sa.own_earlier_credit(q, [self.own("mastering", "2026-05-21T00:00:00", pid="p9")]))
        self.assertFalse(sa.own_earlier_credit(q, [self.own("producer", "2026-05-21T00:00:00")]))

    def test_117111_four_mastering_rows_are_held_as_velocity_not_rejected(self):
        rows = [row(f"m{i}", uid=117111, pid=f"pm{i}") for i in range(4)] + [row("other", uid=500, pid="po")]
        res, w = self.go(rows, fanout=lambda rs: {117111: {"m0", "m1", "m2", "m3"}, 500: {"other"}})
        self.assertEqual([i for c in w.calls for i in c[1]], ["other"], "1 such request (< 3) is not held")
        d = self.decisions()
        for i in range(4):
            self.assertIn("same_anchor_requests_7d=4 >= 3", d[f"m{i}"]["reason"])
            self.assertNotEqual(d[f"m{i}"]["decision"], "reject")
        self.assertEqual(res.fanout_held, 4)
        self.assertIn("4 held by same_anchor_requests_7d", res.line())

    def test_only_the_such_rows_are_held_and_unreadable_holds(self):
        rows = [row("such", uid=601, pid="a"), row("plain", uid=601, pid="b"), row("unk", uid=602, pid="c")]
        res, w = self.go(rows, fanout=lambda rs: {601: {"such", "x1", "x2"}, 602: None})
        self.assertEqual([i for c in w.calls for i in c[1]], ["plain"])
        self.assertIn("unreadable", self.decisions()["unk"]["reason"])

    def test_the_live_fanout_counts_from_the_replica_and_raw_credits(self):
        from unittest import mock
        rows = [row("r1", uid=117111, pid="p1")]
        out = ('"r1","117111","p1","t1","{Mastering}","2026-10-14T10:00:00Z"\n'
               '"r2","117111","p1","t2","{Mastering}","2026-10-14T10:05:00Z"\n'
               '"r3","117111","p1","t3","{Mastering,Engineer}","2026-10-14T10:10:00Z"\n'
               '"r4","117111","p1","t4","{Mastering}","2026-10-15T09:00:00Z"\n')
        raws = {"t1": [self.own("mastering", "2026-05-21T00:00:00")], "t2": [self.own("mastering", "2025-05-28T00:00:00")],
                "t3": [self.own("engineer", "2026-05-21T00:00:00")], "t4": [self.own("mastering", "2026-10-15T09:00:00")]}
        with mock.patch.object(sa.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=out)), \
                mock.patch.object(sa.admin_api, "track_raw_credits", side_effect=lambda a, t: raws[t]):
            got = sa.live_fanout(object(), NOW, sleep=lambda _s: None)(rows)
        self.assertEqual(got, {117111: {"r1", "r2", "r3"}}, "r4's only Muso credit is its own same-time write")
        with mock.patch.object(sa.subprocess, "run", return_value=mock.Mock(returncode=1, stdout="")):
            self.assertEqual(sa.live_fanout(object(), NOW, sleep=lambda _s: None)(rows), {117111: None})

    def test_an_unreadable_anchor_holds_the_row(self):
        class Boom:
            def get(self, *a, **k):
                raise sa.admin_api.AdminError("HTTP 503")
        out = sa.live_anchors(Boom(), sleep=lambda _s: None)([row("x", band="B", meta=self.STAMP)])
        self.assertIsNone(out["x"][0])
        self.assertIn("evidence unreadable", out["x"][1])



# 2026-11-15: core's admin credit-requests list answers HTTP 400 for a profile id that is not strict RFC 4122
# (assertUuidQuery.js, core-backend #10162). This is the real one: its version nibble is f.
LEGACY_PID = "f8bd5f94-05c8-f52f-3129-6fa98f44e8d1"


class RefusesProfile(FakeAdmin):
    """Core as it answers: HTTP 400 for the read scoped to a refused profile, rows for every other one."""

    def __init__(self, rows, refused=(LEGACY_PID,)):
        super().__init__(rows)
        self.refused = set(refused)

    def get(self, path, params=None):
        self.calls.append((path, dict(params or {})))
        if params.get("profilesIds") in self.refused:
            raise sa.admin_api.BadRequest(f"admin GET {path}?profilesIds={params['profilesIds']} returned HTTP 400")
        self.calls.pop()
        return super().get(path, params)


class UnreadableProfile(unittest.TestCase):
    """One profile core answers HTTP 400 for is skipped, counted and named; the run goes on."""
    setUp = ScoreApprove.setUp
    proof = ScoreApprove.proof
    go = ScoreApprove.go
    decisions = ScoreApprove.decisions

    def skip_rows(self):
        return self.db.execute(f"SELECT run_id, profile_id, status, requests, request_ids, reason "
                               f"FROM {sa.UNREADABLE_TABLE} ORDER BY id").fetchall()

    def test_one_profile_answering_400_is_skipped_and_the_run_approves_the_rest(self):
        # The refused profile sorts FIRST (risk 0, oldest): before the fix the run ended on this read.
        rows = [row("legacy1", pid=LEGACY_PID, created="2026-09-01T00:00:00Z"),
                row("legacy2", pid=LEGACY_PID, created="2026-09-02T00:00:00Z"),
                row("a", pid="pa", uid=501), row("b", pid="pb", uid=502), row("c", pid="pc", uid=503)]
        admin = RefusesProfile(rows)
        res, w = self.go(rows, admin=admin)
        self.assertEqual(admin.calls[0][1]["profilesIds"], LEGACY_PID, "the refused profile was the first read")
        self.assertEqual(sorted(i for c in w.calls for i in c[1]), ["a", "b", "c"])
        self.assertEqual(res.approved, 3)
        # Reported by count and by id, on the run's own result and in its one line.
        self.assertEqual([s["profile_id"] for s in res.unreadable_profiles], [LEGACY_PID])
        self.assertEqual(res.unreadable_profiles[0]["request_ids"], ["legacy1", "legacy2"])
        self.assertEqual(res.unreadable_new, 1)
        line = res.line()
        self.assertIn("SKIPPED 1 profile(s)", line)
        self.assertIn("HTTP 400", line)
        self.assertIn(f"{LEGACY_PID} (2 request(s))", line)
        self.assertIn("2 request(s) not read and not decided", line)
        self.assertIn("3 approved", line)
        # Nothing was decided on the requests that were not read, and the run is not a failed read.
        d = self.decisions()
        self.assertNotIn("legacy1", d)
        self.assertNotIn("legacy2", d)
        self.assertFalse(res.read_exhausted)
        self.assertEqual(res.write_errors, [])
        # Readable afterwards: one row, naming the profile, its requests and why.
        (run_id, pid, status, n, ids, reason), = self.skip_rows()
        self.assertEqual((run_id, pid, status, n), (res.run_id, LEGACY_PID, decide.UVN, 2))
        self.assertEqual(json.loads(ids), ["legacy1", "legacy2"])
        self.assertEqual(reason, sa.admin_api.BAD_REQUEST_REASON)

    def test_a_refused_profile_in_the_middle_does_not_drop_the_profiles_after_it(self):
        wanted = [("r1", "p1", 0.0), ("r2", "p2", 0.0), ("bad1", LEGACY_PID, 0.0), ("bad2", LEGACY_PID, 0.0),
                  ("r3", "p3", 0.0), ("r4", "p4", 0.0)]
        rows = [row(rid, pid=pid) for rid, pid, _ in wanted]
        skipped, notes = [], []
        out = sa.reread(RefusesProfile(rows), wanted, sleep=lambda _s: None, note=notes, skipped=skipped)
        self.assertEqual(sorted(out), ["r1", "r2", "r3", "r4"])
        self.assertEqual(skipped, [{"profile_id": LEGACY_PID, "status": decide.UVN, "request_ids": ["bad1", "bad2"],
                                    "reason": sa.admin_api.BAD_REQUEST_REASON}])
        self.assertEqual(notes, [], "a skipped profile is not a short read")

    def test_a_refused_profile_does_not_spend_the_profile_budget_or_wait_out_a_backoff(self):
        wanted = [("bad", LEGACY_PID, 0.0)] + [(f"r{i}", f"p{i}", 0.0) for i in range(3)]
        rows = [row(rid, pid=pid) for rid, pid, _ in wanted]
        skipped, notes, slept = [], [], []
        admin = RefusesProfile(rows)
        out = sa.reread(admin, wanted, max_profiles=3, sleep=slept.append, note=notes, skipped=skipped)
        self.assertEqual(sorted(out), ["r0", "r1", "r2"], "3 readable profiles fit a budget of 3")
        self.assertEqual(notes, [])
        self.assertEqual(len(admin.calls), 4, "a 400 is asked once, never retried")
        self.assertNotIn(20.0, slept, "a 400 is not a rate limit: no backoff")

    def test_every_profile_answering_400_is_an_outage_not_a_skip(self):
        wanted = [("x", "legacy-a", 0.0), ("y", "legacy-b", 0.0)]
        rows = [row(rid, pid=pid) for rid, pid, _ in wanted]
        skipped = []
        with self.assertRaises(sa.admin_api.AdminError) as ctx:
            sa.reread(RefusesProfile(rows, refused=("legacy-a", "legacy-b")), wanted, sleep=lambda _s: None,
                      skipped=skipped)
        self.assertNotIsInstance(ctx.exception, sa.admin_api.BadRequest)
        self.assertIn("2 of 2 profiles", str(ctx.exception))
        self.assertIn("legacy-a", str(ctx.exception))

    def test_one_profile_holding_both_statuses_is_one_profile_and_never_an_outage(self):
        # A profile is read once per held status, so this ONE profile answers 400 twice. Counted by read it
        # was "2 of 2 refused" and the run aborted (QA + Fable on f52836298): the failure this fix is for.
        wanted = [("l-uvn", LEGACY_PID, 0.0, decide.UVN), ("l-unv", LEGACY_PID, 0.0, decide.UNVERIFIED)]
        rows = [row(rid, pid=pid, status=status) for rid, pid, _, status in wanted]
        admin, skipped, notes = RefusesProfile(rows), [], []
        out = sa.reread(admin, wanted, sleep=lambda _s: None, note=notes, skipped=skipped)
        self.assertEqual(out, {})
        self.assertEqual([(c[1]["profilesIds"], c[1]["status"]) for c in admin.calls],
                         [(LEGACY_PID, decide.UVN), (LEGACY_PID, decide.UNVERIFIED)], "two reads, both refused")
        self.assertEqual([(s["profile_id"], s["status"], s["request_ids"]) for s in skipped],
                         [(LEGACY_PID, decide.UVN, ["l-uvn"]), (LEGACY_PID, decide.UNVERIFIED, ["l-unv"])])
        self.assertEqual(notes, [])

    def test_a_run_whose_first_profile_holds_both_statuses_skips_it_once_and_approves_the_rest(self):
        rows = [row("l-uvn", pid=LEGACY_PID, created="2026-09-01T00:00:00Z"),
                row("l-unv", pid=LEGACY_PID, status=decide.UNVERIFIED, created="2026-09-02T00:00:00Z"),
                row("a", pid="pa", uid=501), row("b", pid="pb", uid=502)]
        admin = RefusesProfile(rows)
        res, w = self.go(rows, admin=admin)
        self.assertEqual(sorted(i for c in w.calls for i in c[1]), ["a", "b"])
        self.assertEqual(res.approved, 2)
        # Two refused reads, ONE profile: counted once, named once, both of its requests accounted for.
        self.assertEqual(sorted((s["profile_id"], s["status"]) for s in res.unreadable_profiles),
                         sorted([(LEGACY_PID, decide.UVN), (LEGACY_PID, decide.UNVERIFIED)]))
        self.assertEqual(res.unreadable_new, 1)
        line = res.line()
        self.assertIn("SKIPPED 1 profile(s)", line)
        self.assertEqual(line.count(LEGACY_PID), 1)
        self.assertIn(f"{LEGACY_PID} (2 request(s))", line)
        self.assertIn("2 request(s) not read and not decided", line)
        d = self.decisions()
        self.assertNotIn("l-uvn", d)
        self.assertNotIn("l-unv", d)
        self.assertEqual(sorted((pid, status, n) for _run, pid, status, n, _ids, _why in self.skip_rows()),
                         sorted([(LEGACY_PID, decide.UVN, 1), (LEGACY_PID, decide.UNVERIFIED, 1)]))
        (rep,) = sa.unreadable_report(self.db, NOW)
        self.assertEqual((rep["profile_id"], rep["runs"], rep["request_ids"]), (LEGACY_PID, 1, ["l-unv", "l-uvn"]))

    def test_a_run_whose_only_profile_holds_both_statuses_is_a_skip_not_an_abort(self):
        rows = [row("l-uvn", pid=LEGACY_PID), row("l-unv", pid=LEGACY_PID, status=decide.UNVERIFIED)]
        res, w = self.go(rows, admin=RefusesProfile(rows))
        self.assertEqual(w.calls, [])
        self.assertIn("SKIPPED 1 profile(s)", res.line())
        self.assertEqual(res.unreadable_new, 1)

    def test_the_outage_rule_counts_profiles_not_reads(self):
        # Two DISTINCT profiles, three refused reads, nothing answered: still the outage, and it says 2.
        wanted = [("x1", "legacy-a", 0.0, decide.UVN), ("x2", "legacy-a", 0.0, decide.UNVERIFIED),
                  ("y", "legacy-b", 0.0, decide.UVN)]
        rows = [row(rid, pid=pid, status=status) for rid, pid, _, status in wanted]
        with self.assertRaises(sa.admin_api.AdminError) as ctx:
            sa.reread(RefusesProfile(rows, refused=("legacy-a", "legacy-b")), wanted, sleep=lambda _s: None,
                      skipped=[])
        self.assertNotIsInstance(ctx.exception, sa.admin_api.BadRequest)
        self.assertIn("2 of 2 profiles", str(ctx.exception))
        self.assertIn("first legacy-a", str(ctx.exception))

    def test_the_only_candidate_profile_answering_400_is_still_a_skip(self):
        rows = [row("only", pid=LEGACY_PID)]
        res, w = self.go(rows, admin=RefusesProfile(rows))
        self.assertEqual(w.calls, [])
        self.assertEqual([s["profile_id"] for s in res.unreadable_profiles], [LEGACY_PID])
        self.assertIn("SKIPPED 1 profile(s)", res.line())

    def test_any_other_failed_read_still_ends_the_run(self):
        rows = [row("a", pid="pa"), row("b", pid="pb")]

        class Down(FakeAdmin):
            def get(self, path, params=None):
                raise sa.admin_api.AdminError("admin GET /admin/credit-requests returned HTTP 500")
        with self.assertRaises(sa.admin_api.AdminError):
            self.go(rows, admin=Down(rows))
        self.assertEqual(self.skip_rows(), [], "a 500 is not recorded as a skipped profile")

    def test_a_caller_with_nowhere_to_record_the_skip_gets_the_error(self):
        rows = [row("bad", pid=LEGACY_PID), row("a", pid="pa")]
        with self.assertRaises(sa.admin_api.BadRequest):
            sa.reread(RefusesProfile(rows), [("bad", LEGACY_PID, 0.0), ("a", "pa", 0.0)], sleep=lambda _s: None)

    def test_a_profile_skipped_before_keeps_its_place_is_asked_again_and_is_not_new(self):
        """Production has more candidates than candidate_limit (12,136 against 2,000 on 2026-11-15): a
        skipped profile moved behind the others would fall outside the limit, not be asked and not be
        counted. It keeps its place, so the next run asks it again and counts it again."""
        rows = [row("legacy", pid=LEGACY_PID, created="2026-09-01T00:00:00Z"), row("a", pid="pa", uid=501)]
        first, _ = self.go(rows, admin=RefusesProfile(rows))
        self.assertEqual(first.unreadable_new, 1)
        rows2 = [row("legacy", pid=LEGACY_PID, created="2026-09-01T00:00:00Z"), row("b", pid="pb", uid=502),
                 row("c", pid="pc", uid=503), row("d", pid="pd", uid=504)]
        admin = RefusesProfile(rows2)
        second, w = self.go(rows2, admin=admin, sp=sa.ScorePolicy(enabled=True, candidate_limit=2))
        self.assertEqual([c[1]["profilesIds"] for c in admin.calls], [LEGACY_PID, "pb"],
                         "asked again inside the candidate limit, in its own place")
        self.assertEqual([i for c in w.calls for i in c[1]], ["b"])
        self.assertEqual(second.unreadable_new, 0, "already reported inside the window")
        self.assertEqual([s["profile_id"] for s in second.unreadable_profiles], [LEGACY_PID], "counted again")
        self.assertIn(LEGACY_PID, second.line(), "every run's line still carries it")
        self.assertEqual(len(self.skip_rows()), 2, "one row per run that skipped it")
        (rep,) = sa.unreadable_report(self.db, NOW)
        self.assertEqual((rep["profile_id"], rep["requests"], rep["request_ids"]), (LEGACY_PID, 1, ["legacy"]))

    def test_a_profile_core_reads_again_is_decided_normally(self):
        rows = [row("legacy", pid=LEGACY_PID), row("a", pid="pa", uid=501)]
        self.go(rows, admin=RefusesProfile(rows))
        res, w = self.go(rows)   # core now answers rows for it
        self.assertIn("legacy", [i for c in w.calls for i in c[1]])
        self.assertEqual(res.unreadable_profiles, [])
        self.assertNotIn("SKIPPED", res.line())

    def test_the_report_says_not_recorded_when_no_run_wrote_the_table(self):
        self.assertIsNone(sa.unreadable_report(sqlite3.connect(":memory:"), NOW))
        self.go([row("a")])
        self.assertEqual(sa.unreadable_report(self.db, NOW), [], "a run that skipped nothing: a measured zero")

    def test_the_admin_client_raises_bad_request_on_http_400_only(self):
        script = Path(self.tmp) / "wrapper.sh"
        for status, exc in ((400, sa.admin_api.BadRequest), (500, sa.admin_api.AdminError)):
            script.write_text(f"#!/bin/bash\necho '{{\"http_status\": {status}, \"body\": {{\"message\": \"x\"}}}}'\n")
            with self.assertRaises(sa.admin_api.AdminError) as ctx:
                sa.admin_api.list_requests(sa.admin_api.AdminClient(script=str(script)), status=decide.UVN,
                                           limit=1000, page=1, profile_ids=[LEGACY_PID])
            self.assertIs(type(ctx.exception), exc, status)
            self.assertIn(LEGACY_PID, str(ctx.exception))
            self.assertIn(f"HTTP {status}", str(ctx.exception))

    def _cli(self, res):
        import importlib.util
        spec = importlib.util.spec_from_file_location("credit_review_cli", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        orig = sa.run
        sa.run = lambda *a, **k: res
        self.addCleanup(setattr, sa, "run", orig)
        self.addCleanup(setattr, sa, "KILL_SWITCH", sa.KILL_SWITCH)
        sa.KILL_SWITCH = Path(self.tmp) / "nope"
        self.addCleanup(setattr, decide, "KILL_SWITCH", decide.KILL_SWITCH)
        decide.KILL_SWITCH = Path(self.tmp) / "nope2"
        orig_load, orig_sp = decide.Policy.load, sa.ScorePolicy.load
        decide.Policy.load = staticmethod(lambda *a, **k: policy())
        sa.ScorePolicy.load = staticmethod(lambda *a, **k: sa.ScorePolicy(enabled=True))
        self.addCleanup(setattr, decide.Policy, "load", orig_load)
        self.addCleanup(setattr, sa.ScorePolicy, "load", orig_sp)
        return cli

    def _run_cli(self, cli, **kw):
        import io
        from contextlib import redirect_stdout
        args = cli.argparse.Namespace(**{"pause": None, "resume": False, "skipped_profiles": False, "mode": "apply",
                                         "max_per_run": None, "ledger": os.path.join(self.tmp, "cli.sqlite3"), **kw})
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.cmd_score_approve(args)
        return rc, buf.getvalue()

    def test_the_cli_announces_a_newly_skipped_profile_and_does_not_fail_the_run(self):
        skip = {"profile_id": LEGACY_PID, "status": decide.UVN, "request_ids": ["legacy1"],
                "reason": sa.admin_api.BAD_REQUEST_REASON}
        res = sa.ScoreResult(run_id="score-x", mode="apply", unreadable_profiles=[skip], unreadable_new=1)
        rc, out = self._run_cli(self._cli(res))
        self.assertEqual(rc, 0, "one unreadable profile is not a failed run")
        self.assertNotIn("NO_REPLY", out)
        self.assertIn("SKIPPED 1 profile(s)", out)
        self.assertIn(LEGACY_PID, out)
        # Already reported in the window and nothing approved: quiet on the channel, the line is still logged.
        res = sa.ScoreResult(run_id="score-y", mode="apply", unreadable_profiles=[skip], unreadable_new=0)
        rc, out = self._run_cli(self._cli(res))
        self.assertEqual((rc, out.strip()), (0, "NO_REPLY"))

    def test_the_cli_lists_the_skipped_profiles_read_only(self):
        rows = [row("legacy", pid=LEGACY_PID), row("a", pid="pa", uid=501)]
        self.go(rows, admin=RefusesProfile(rows))
        self.db.close()
        path = os.path.join(self.tmp, "ledger.sqlite3")
        before = Path(path).read_bytes()
        cli = self._cli(None)
        clock = _mock.patch.object(cli, "datetime", SimpleNamespace(now=lambda tz=None: NOW))  # the run was at NOW
        clock.start()
        self.addCleanup(clock.stop)
        rc, out = self._run_cli(cli, skipped_profiles=True, ledger=path)
        self.assertEqual(rc, 0)
        self.assertIn("skipped 1 profile(s)", out)
        self.assertIn(LEGACY_PID, out)
        self.assertIn("legacy", out)
        self.assertEqual(Path(path).read_bytes(), before, "the listing writes nothing")
        # A ledger no run has written the table to, and one that is not there: neither is "0 skipped".
        empty = os.path.join(self.tmp, "empty.sqlite3")
        sqlite3.connect(empty).execute("CREATE TABLE t (x)").connection.commit()
        rc, out = self._run_cli(cli, skipped_profiles=True, ledger=empty)
        self.assertEqual(rc, 1)
        self.assertIn("NOT RECORDED", out)
        rc, out = self._run_cli(cli, skipped_profiles=True, ledger=os.path.join(self.tmp, "absent.sqlite3"))
        self.assertEqual(rc, 1)
        self.assertIn("NOT READ", out)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "absent.sqlite3")), "a read never creates a ledger")


class FakeReplica:
    """credit_requests as the replica holds it, answering the page statement the way Trino does.

    It reads the statement's own text: the status, the createdAt bound and the LIMIT come from the inner
    SELECT, and the candidate rule's parameters from the projected column. Rows that share a createdAt
    come back in a different order on every call, as an ORDER BY createdat alone allows."""

    INNER = re.compile(r"FROM \(SELECT id, profileid, userid, status, createdat, verificationdata, metadata "
                       r"FROM postgresql_core\.public\.credit_requests WHERE status = '(?P<status>[a-z_]+)' "
                       r"AND deletedat IS NULL (?:AND createdat >= TIMESTAMP '(?P<since>[^']+)' )?"
                       r"ORDER BY createdat ASC LIMIT (?P<rows>\d+)\)$")

    HEADER = ("id", "profileid", "total_risk_percent", "status", "userid", "createdat", "keep")

    def __init__(self, rows, fail_on_call=None, clock=None, cost_s=0.0, header=False):
        self.rows, self.calls, self.fail_on_call, self.clock, self.cost_s = rows, [], fail_on_call, clock, cost_s
        self.header = header

    @staticmethod
    def kept(r, max_risk, bands, stamp_ok):
        """The candidate rule, row by row (SQL three-valued logic collapsed: NULL is not kept)."""
        if r["approved"] != "true" or r["risk"] is None or not float(r["risk"]) < max_risk or r["band"] not in bands:
            return False
        return r["proof"] is None or (stamp_ok and r["proof"] == ["validator_band_hint"])

    def single_statement(self, max_risk, limit, bands=("A",), stamp_ok=False):
        """What the statement this read replaced returned: the rule in the WHERE, ORDER BY r, createdat LIMIT."""
        hit = [r for r in self.rows if r["status"] in sa.HELD_STATUSES and not r["deleted"]
               and self.kept(r, max_risk, bands, stamp_ok) and r["profile"]]
        hit.sort(key=lambda r: (float(r["risk"]), r["created"]))
        return [(r["id"], r["profile"], float(r["risk"]), r["status"], r["user"]) for r in hit[:limit]]

    def __call__(self, cmd, *, input, timeout, **_kw):          # noqa: A002 (subprocess.run's own name)
        self.calls.append({"cmd": cmd, "sql": input, "timeout": timeout})
        if self.clock is not None:
            self.clock[0] += self.cost_s
        if self.fail_on_call == len(self.calls):
            return _mock.Mock(returncode=1, stdout="", stderr="Query failed: replica went away")
        m = self.INNER.search(input)
        assert m, f"not the page statement: {input}"
        max_risk = float(re.search(r"AS double\) < ([0-9.]+) ", input).group(1))
        bands = tuple(re.findall(r"'([AB])'", re.search(r"'\$\.band_hint'\) IN \(([^)]*)\)", input).group(1)))
        stamp_ok = "json_format(" in input
        page = [r for r in self.rows if r["status"] == m["status"] and not r["deleted"]
                and (m["since"] is None or r["created"] >= m["since"])]
        random.Random(len(self.calls)).shuffle(page)
        page.sort(key=lambda r: r["created"])
        out = ["WARNING: Unable to create a system terminal, creating a dumb terminal"]
        if self.header:
            out.append(",".join(f'"{f}"' for f in self.HEADER))
        for r in page[:int(m["rows"])]:
            keep = "true" if self.kept(r, max_risk, bands, stamp_ok) else "false"
            fields = (r["id"], r["profile"], "" if r["risk"] is None else repr(float(r["risk"])), r["status"],
                      "" if r["user"] is None else str(r["user"]), r["created"], keep)
            out.append(",".join(f'"{f}"' for f in fields))
        return _mock.Mock(returncode=0, stdout="\n".join(out) + "\n", stderr="")


def _held(n, *, status=decide.UVN, created, risk=5.0, approved="true", band="A", proof=None, deleted=False,
          profile=None, user=1):
    return {"id": f"id-{n:04d}", "profile": f"prof-{n:04d}" if profile is None else profile, "user": user,
            "status": status, "created": created, "risk": risk, "approved": approved, "band": band,
            "proof": proof, "deleted": deleted}


def _ts(day, sec=0, micro=0):
    return f"2026-10-{day:02d} 00:00:{sec:02d}.{micro:06d} UTC"


def held_population():
    """Both held statuses, every way a row misses the rule, and createdAt groups larger than a small page.
    Rows the rule keeps are unique on (risk, createdAt): the single statement's order was defined only there."""
    rows, n = [], 0
    for day in range(1, 21):                       # one row a day, alternating status, risk falling with age
        n += 1
        rows.append(_held(n, status=sa.HELD_STATUSES[day % 2], created=_ts(day), risk=29.0 - day))
    for k in range(9):                             # nine rows on ONE createdAt, every one kept, risks distinct
        n += 1
        rows.append(_held(n, created=_ts(7, 30), risk=0.5 + k / 10))
    for k in range(6):                             # six on another, in the other status, only two kept
        n += 1
        rows.append(_held(n, status=decide.UNVERIFIED, created=_ts(12, 30), risk=40.0 + k if k % 3 else 1.5 + k))
    n += 1; rows.append(_held(n, created=_ts(3, 1), approved="false"))                        # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 2), risk=30.0))                               # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 3), risk=None))                               # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 4), band="B", risk=3.25))                     # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 5), band=None))                               # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 6), proof=["validator_band_hint"], risk=2.25))  # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 7), proof=["validator_band_hint", "other"]))  # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 8), deleted=True, risk=0.25))                 # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 9), status="approved", risk=0.125))           # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 10), status="rejected", risk=0.0625))         # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 11), user=None, risk=4.5))                    # noqa: E702
    n += 1; rows.append(_held(n, created=_ts(3, 12), profile="", risk=4.75))                  # noqa: E702
    return rows


class BoundedCandidateRead(unittest.TestCase):
    """The candidate read is a walk of bounded statements, and it selects what the one statement did."""

    INPUTS = ((30.0, ("A",), False), (30.0, ("A", "B"), True), (100.0, ("A", "B"), True), (10.0, ("A",), False))

    def walk(self, replica, max_risk=30.0, limit=None, bands=("A",), stamp_ok=False, page_rows=4, page_rows_max=64,
             timeout_s=600):
        with _mock.patch.object(sa.subprocess, "run", side_effect=replica), \
                _mock.patch.object(sa, "PAGE_ROWS", page_rows), _mock.patch.object(sa, "PAGE_ROWS_MAX", page_rows_max):
            return sa.replica_candidates(max_risk, sa.SCAN_CAP if limit is None else limit, bands,
                                         band_hint_stamp_ok=stamp_ok, timeout_s=timeout_s)

    def test_the_json_predicates_are_a_per_page_filter_and_never_the_scan_driving_where(self):
        for max_risk, bands, stamp_ok in self.INPUTS:
            keep = sa.candidate_keep_sql(max_risk, bands, stamp_ok)
            for since in (None, _ts(4)):
                sql = sa.candidate_page_sql(decide.UVN, since, 5000, keep)
                outer, _, inner = sql.partition(" FROM (")
                self.assertTrue(inner.endswith(")"), sql)
                scan = inner[inner.index(" WHERE "):]
                self.assertNotIn("json", scan)
                self.assertNotIn("verificationdata", scan)
                self.assertNotIn("metadata", scan)
                bound = f"AND createdat >= TIMESTAMP '{since}' " if since else ""
                self.assertEqual(scan, " WHERE status = 'user_verification_needed' AND deletedat IS NULL "
                                       f"{bound}ORDER BY createdat ASC LIMIT 5000)")
                self.assertEqual(sql.count(" WHERE "), 1)       # the outer SELECT filters nothing: no pushdown below the LIMIT
                self.assertIn(f"({keep})", outer)
                self.assertEqual(sql.count(keep), 1)

    def test_the_rule_the_pages_apply_is_the_four_predicates_the_single_statement_carried(self):
        self.assertEqual(
            sa.candidate_keep_sql(30.0, ("A",), False),
            "json_extract_scalar(verificationdata, '$.is_approved') = 'true' "
            "AND CAST(json_extract_scalar(verificationdata, '$.total_risk_percent') AS double) < 30.0 "
            "AND json_extract_scalar(verificationdata, '$.band_hint') IN ('A') "
            "AND json_extract(metadata, '$.proofRequest') IS NULL")
        self.assertEqual(
            sa.candidate_keep_sql(30.0, ("A", "B"), True),
            "json_extract_scalar(verificationdata, '$.is_approved') = 'true' "
            "AND CAST(json_extract_scalar(verificationdata, '$.total_risk_percent') AS double) < 30.0 "
            "AND json_extract_scalar(verificationdata, '$.band_hint') IN ('A','B') "
            "AND (json_extract(metadata, '$.proofRequest') IS NULL OR json_format(json_extract(metadata, "
            "'$.proofRequest.reasons')) = '[\"validator_band_hint\"]')")

    def test_every_statement_a_walk_sends_is_one_bounded_page(self):
        replica = FakeReplica(held_population())
        self.walk(replica, page_rows=4)
        self.assertGreater(len(replica.calls), 5)
        for call in replica.calls:
            self.assertEqual(call["cmd"], [sa.TRINO])
            self.assertNotIn(";", call["sql"])
            self.assertRegex(call["sql"], FakeReplica.INNER)
            self.assertLessEqual(int(FakeReplica.INNER.search(call["sql"])["rows"]), 64)
            self.assertNotIn("json", call["sql"][call["sql"].index(" FROM ("):])

    def test_the_page_size_is_bounded_and_the_ceiling_is_a_ceiling(self):
        self.assertLess(sa.PAGE_ROWS_MAX, sa.SCAN_CAP)
        replica = FakeReplica([_held(1, created=_ts(1))])
        self.walk(replica, page_rows=sa.PAGE_ROWS, page_rows_max=sa.PAGE_ROWS_MAX)
        self.assertEqual([int(FakeReplica.INNER.search(c["sql"])["rows"]) for c in replica.calls], [5000, 5000])

    def test_the_walk_selects_the_rows_and_the_order_the_single_statement_did(self):
        rows = held_population()
        for max_risk, bands, stamp_ok in self.INPUTS:
            want = FakeReplica(rows).single_statement(max_risk, sa.SCAN_CAP, bands, stamp_ok)
            self.assertGreater(len(want), 3)
            for page_rows in (1, 2, 3, 4, 5, 7, 11, 5000):
                got = self.walk(FakeReplica(rows), max_risk, None, bands, stamp_ok, page_rows=page_rows)
                self.assertEqual(got, want, f"risk<{max_risk} bands={bands} stamp={stamp_ok} page={page_rows}")

    def test_a_csv_header_row_is_dropped_and_selects_the_same_rows(self):
        rows = held_population()
        for max_risk, bands, stamp_ok in self.INPUTS:
            want = self.walk(FakeReplica(rows), max_risk, None, bands, stamp_ok, page_rows=4)
            got = self.walk(FakeReplica(rows, header=True), max_risk, None, bands, stamp_ok, page_rows=4)
            self.assertEqual(got, want)
            self.assertGreater(len(want), 3)

    def test_a_first_row_that_is_not_the_header_still_fails_the_read(self):
        replica = FakeReplica([_held(1, created=_ts(1))])
        real = replica.__call__

        def with_bad_first_row(cmd, *, input, timeout, **kw):     # noqa: A002
            answer = real(cmd, input=input, timeout=timeout, **kw)
            answer.stdout = '"id","profileid","total_risk_percent","status","userid","not_a_createdat","keep"\n' \
                            + answer.stdout
            return answer
        with self.assertRaisesRegex(sa.admin_api.AdminError, "cannot place"):
            self.walk(with_bad_first_row)

    def test_the_limit_cuts_the_sorted_output_and_not_the_read(self):
        rows = held_population()
        for limit in (0, 1, 5, 12):
            want = FakeReplica(rows).single_statement(30.0, limit)
            replica = FakeReplica(rows)
            self.assertEqual(self.walk(replica, limit=limit, page_rows=4), want)
            self.assertEqual(len(want), limit)
            self.assertGreater(len(replica.calls), 5)       # every page was still read: the lowest risk may be the newest row

    def test_a_createdat_group_larger_than_a_page_is_read_whole(self):
        rows = [_held(n, created=_ts(5), risk=n / 10) for n in range(1, 10)] + [_held(20, created=_ts(6), risk=0.05)]
        replica = FakeReplica(rows)
        got = self.walk(replica, page_rows=2, page_rows_max=64)
        self.assertEqual(got, FakeReplica(rows).single_statement(30.0, sa.SCAN_CAP))
        self.assertEqual(len(got), 10)
        self.assertEqual(len({g[0] for g in got}), 10)
        asked = [int(FakeReplica.INNER.search(c["sql"])["rows"]) for c in replica.calls
                 if "'user_verification_needed'" in c["sql"]]
        self.assertEqual(asked[:4], [2, 2, 4, 8])       # widened only while one createdAt filled the page
        self.assertEqual(max(asked), 16)

    def test_a_group_past_the_ceiling_fails_the_read_instead_of_an_unbounded_statement(self):
        rows = [_held(n, created=_ts(5)) for n in range(1, 40)]
        replica = FakeReplica(rows)
        with self.assertRaisesRegex(sa.admin_api.AdminError, "share createdAt"):
            self.walk(replica, page_rows=2, page_rows_max=8)
        self.assertLessEqual(max(int(FakeReplica.INNER.search(c["sql"])["rows"]) for c in replica.calls), 8)

    def test_a_page_that_fails_fails_the_read_with_no_partial_list(self):
        for nth in (1, 2, 5):
            replica = FakeReplica(held_population(), fail_on_call=nth)
            with self.assertRaisesRegex(sa.admin_api.AdminError, "rc=1"):
                self.walk(replica, page_rows=4)
            self.assertEqual(len(replica.calls), nth)

    def test_a_row_the_walk_cannot_place_fails_the_read(self):
        for created in ("2026-10-05 00:00:00.000 UTC", "2026-10-05 02:00:00.000000 Europe/Rome", ""):
            replica = FakeReplica([_held(1, created=created)])
            with self.assertRaisesRegex(sa.admin_api.AdminError, "cannot place"):
                self.walk(replica)
        with self.assertRaises(ValueError):
            sa.candidate_page_sql(decide.UVN, "2026-10-05' OR 1=1 --", 10, "true")
        with self.assertRaises(ValueError):
            sa.candidate_page_sql("approved", None, 10, "true")

    def test_the_budget_is_the_whole_walks_and_no_page_starts_past_it(self):
        clock = [1000.0]
        replica = FakeReplica(held_population(), clock=clock, cost_s=30.0)
        with _mock.patch.object(sa.time, "monotonic", side_effect=lambda: clock[0]):
            with self.assertRaisesRegex(sa.admin_api.AdminError, "exceeded its 100s budget"):
                self.walk(replica, page_rows=4, timeout_s=100)
        self.assertEqual(len(replica.calls), 4)
        self.assertEqual([c["timeout"] for c in replica.calls], [100.0, 70.0, 40.0, 10.0])
class TrackAdmin(FakeAdmin):
    """FakeAdmin plus the catalog track document. ``tracks`` = {track id: the document, or the error the
    read raises}; a track that is not in it answers 404, as core does."""

    def __init__(self, rows, tracks):
        super().__init__(rows)
        self.tracks = tracks
        self.track_reads = []

    def get(self, path, params=None):
        if not path.startswith("/admin/track/"):
            return super().get(path, params)
        tid = path.rsplit("/", 1)[1]
        self.track_reads.append(tid)
        doc = self.tracks.get(tid, sa.admin_api.NotFound(f"HTTP 404 {tid}"))
        if isinstance(doc, Exception):
            raise doc
        return doc


def zero(rid, **kw):
    """A row whose request row stores a popularity of 0, on its own profile."""
    return row(rid, pop=0, pid="p-" + rid, **kw)


class PopularityReread(unittest.TestCase):
    """Captain 2026-11-15T19:51Z: a stored popularity of 0 is read again from the run's own catalog track
    document before the row is scored. A value of 1 or more is scored like any other; a 0 there is a
    measured 0 and stays 0; no value leaves the row held as unknown. No number is ever assumed."""

    setUp = ScoreApprove.setUp
    proof = ScoreApprove.proof
    decisions = ScoreApprove.decisions

    def run_kwargs(self, convo=None):
        return dict(readback=lambda status, ids: set(), now=NOW, sleep=lambda _s: None,
                    conversations=lambda users: {u: (convo or {}).get(u, False) for u in users},
                    anchors=lambda rs: {str(r["id"]): ("none", None) for r in rs}, fanout=lambda rs: {},
                    editorial_velocity=lambda rs: {}, profile_burst=NO_BURST)

    def go(self, rows, tracks, *, mode="apply", on=True, popularity=None, pol=None, convo=None):
        admin, w = TrackAdmin(rows, tracks), Writer()
        cands = lambda risk, limit: [(r["id"], r["profileId"], float(r["verificationData"]["total_risk_percent"]),
                                      r["status"], r["userId"]) for r in rows]
        res = sa.run(admin, self.db, mode=mode, policy=pol or policy(),
                     sp=sa.ScorePolicy(enabled=True, popularity_reread=on), candidates=cands, writer=w,
                     popularity=popularity, **self.run_kwargs(convo))
        return res, w, admin

    def written(self, w):
        return sorted(i for c in w.calls for i in c[1])

    def test_an_uncaptured_zero_is_read_again_from_the_runs_track_document_and_scored_on_it(self):
        res, w, admin = self.go([zero("z")], {"t-z": {"id": "t-z", "popularity": 23}})
        d = self.decisions()["z"]
        self.assertEqual(admin.track_reads, ["t-z"])
        self.assertEqual(res.pop_reread, {sa.POP_CAPTURED: 1})
        self.assertEqual(d["popularity"], 23)
        self.assertEqual(d["decision"], "approve")
        self.assertIn("the request row stored 0", d["reason"])
        self.assertEqual(self.written(w), ["z"])

    def test_a_measured_zero_is_not_overwritten_and_is_held_as_a_zero_not_as_unknown(self):
        res, w, admin = self.go([zero("z")], {"t-z": {"id": "t-z", "popularity": 0}})
        d = self.decisions()["z"]
        self.assertEqual(admin.track_reads, ["t-z"])
        self.assertEqual(res.pop_reread, {sa.POP_MEASURED_ZERO: 1})
        self.assertEqual(d["popularity"], 0)
        self.assertEqual(d["decision"], "hold")
        self.assertIn("popularity 0 measured", d["reason"])
        self.assertNotIn("unknown", d["reason"])
        self.assertEqual(w.calls, [])

    def test_a_track_document_with_no_value_leaves_the_row_held_and_no_number_is_assumed(self):
        docs = {"absent": {"id": "x"}, "null": {"popularity": None}, "bool": {"popularity": True},
                "text": {"popularity": "23"}, "fraction": {"popularity": 23.5}, "negative": {"popularity": -1},
                "deleted": {"popularity": 23, "deleted": True}, "merged": {"popularity": 23, "merged": True}}
        res, w, _admin = self.go([zero(k) for k in docs], {"t-" + k: doc for k, doc in docs.items()})
        d = self.decisions()
        self.assertEqual(res.pop_reread, {sa.POP_NO_VALUE: len(docs)})
        self.assertEqual(w.calls, [])
        for k in docs:
            self.assertEqual(d[k]["decision"], "hold", k)
            self.assertEqual(d[k]["popularity"], 0, k)
            self.assertIn("no number assumed", d[k]["reason"], k)

    def test_an_integral_float_is_the_whole_number_it_names(self):
        res, w, _admin = self.go([zero("z")], {"t-z": {"id": "t-z", "popularity": 23.0}})
        d = self.decisions()["z"]
        self.assertEqual(res.pop_reread, {sa.POP_CAPTURED: 1})
        self.assertEqual(d["popularity"], 23)
        self.assertEqual(d["decision"], "approve")
        self.assertEqual(self.written(w), ["z"])

    def test_a_non_integral_float_is_no_value_and_the_row_is_held(self):
        res, w, _admin = self.go([zero("z")], {"t-z": {"id": "t-z", "popularity": 23.5}})
        d = self.decisions()["z"]
        self.assertEqual(res.pop_reread, {sa.POP_NO_VALUE: 1})
        self.assertEqual(d["popularity"], 0)
        self.assertEqual(d["decision"], "hold")
        self.assertIn("no number assumed", d["reason"])
        self.assertEqual(w.calls, [])

    def test_the_proof_path_wordings_are_recorded_as_ask_not_hold(self):
        rows = [zero("guard", band="B"), zero("engaged", uid=501)]
        res, w, _admin = self.go(rows, {"t-guard": {"popularity": 23}, "t-engaged": {"popularity": 23}},
                                 convo={501: True})
        d = self.decisions()
        self.assertIn("server approval guard would refuse (proof_required", d["guard"]["reason"])
        self.assertIn("stage 2, never a provisional approval", d["engaged"]["reason"])
        self.assertEqual(res.outcomes["guard"], "ask")
        self.assertEqual(res.outcomes["engaged"], "ask")
        self.assertEqual(w.calls, [])

    def test_a_request_that_names_no_track_is_held_and_nothing_is_read(self):
        res, w, admin = self.go([{**zero("z"), "trackId": None}], {})
        self.assertEqual(admin.track_reads, [])
        self.assertEqual(res.pop_reread, {sa.POP_NO_VALUE: 1})
        self.assertEqual(self.decisions()["z"]["decision"], "hold")
        self.assertEqual(w.calls, [])

    def test_a_track_read_that_fails_leaves_the_row_held_and_is_tried_again_on_a_later_run(self):
        res, w, admin = self.go([zero("gone"), zero("down")],
                                {"t-down": sa.admin_api.AdminError("admin GET failed: HTTP 500")})
        d = self.decisions()
        self.assertEqual(admin.track_reads.count("t-gone"), 2, "one re-read on a 404, as every catalog read")
        self.assertEqual(res.pop_reread, {sa.POP_UNREAD: 2})
        self.assertEqual(w.calls, [])
        for k in ("gone", "down"):
            self.assertNotEqual(d[k]["decision"], "approve", k)
            self.assertEqual(d[k]["popularity"], 0, k)
            self.assertIn("did not answer", d[k]["reason"], k)
            self.assertTrue(any(m in d[k]["reason"] for m in sa.TRANSIENT_HOLD), k)

    def test_an_answer_nobody_can_vouch_for_scores_no_row(self):
        bad = {"zero-as-captured": (sa.POP_CAPTURED, 0, ""), "none": (sa.POP_CAPTURED, None, ""),
               "text": (sa.POP_CAPTURED, "23", ""), "bool": (sa.POP_CAPTURED, True, ""),
               "five-as-zero": (sa.POP_MEASURED_ZERO, 5, ""), "state": ("guess", 23, ""), "bare": 23,
               "valued-no-value": (sa.POP_NO_VALUE, 23, "")}
        rows = [zero(k) for k in bad] + [zero("unanswered")]
        res, w, _admin = self.go(rows, {}, popularity=lambda rs: dict(bad))
        d = self.decisions()
        self.assertEqual(res.pop_reread, {sa.POP_UNREAD: len(rows)})
        self.assertEqual(w.calls, [])
        for r in rows:
            self.assertNotEqual(d[r["id"]]["decision"], "approve", r["id"])
            self.assertEqual(d[r["id"]]["popularity"], 0, r["id"])

    def test_a_reader_that_answers_with_no_mapping_scores_no_row(self):
        res, w, _admin = self.go([zero("z")], {}, popularity=lambda rs: None)
        self.assertEqual(res.pop_reread, {sa.POP_UNREAD: 1})
        self.assertEqual(self.decisions()["z"]["decision"], "hold")
        self.assertEqual(w.calls, [])

    def test_the_reread_is_off_unless_the_policy_turns_it_on(self):
        res, w, admin = self.go([zero("z")], {"t-z": {"popularity": 23}}, on=False)
        d = self.decisions()["z"]
        self.assertEqual(admin.track_reads, [])
        self.assertEqual(res.pop_reread, {})
        self.assertEqual(d["decision"], "hold")
        self.assertIn(sa.STORED_ZERO_HOLD, d["reason"])
        self.assertEqual(w.calls, [])

    def test_only_a_literal_true_in_the_policy_turns_it_on_and_the_checked_in_policy_has_it_off(self):
        p = Path(self.tmp) / "policy.json"
        p.write_text(json.dumps({"score_approve": {"enabled": True}}))
        self.assertFalse(sa.ScorePolicy.load(p).popularity_reread)
        p.write_text(json.dumps({"score_approve": {"enabled": True, "popularity_reread": "true"}}))
        self.assertFalse(sa.ScorePolicy.load(p).popularity_reread)
        p.write_text(json.dumps({"score_approve": {"enabled": True, "popularity_reread": True}}))
        self.assertTrue(sa.ScorePolicy.load(p).popularity_reread)
        self.assertFalse(sa.ScorePolicy.load(ROOT / "policies" / "credit-trust-decide.json").popularity_reread)

    def test_a_value_read_again_is_scored_by_the_same_rules_as_a_stored_one(self):
        rows = [zero("small"), zero("big"), zero("label", roles=("Record Label",)), zero("denied", uid=13)]
        tracks = {"t-small": {"popularity": 59}, "t-big": {"popularity": 60}, "t-label": {"popularity": 23},
                  "t-denied": {"popularity": 23}}
        res, w, _admin = self.go(rows, tracks, pol=policy(deny_users=(13,)))
        d = self.decisions()
        self.assertEqual(res.pop_reread, {sa.POP_CAPTURED: 4})
        self.assertEqual(self.written(w), ["small"])
        self.assertEqual(d["big"]["popularity"], 60)
        self.assertEqual(d["big"]["big_track"], 1)
        self.assertIn("big track (popularity 60 >= 60)", d["big"]["reason"])
        self.assertIn("organization", d["label"]["reason"])
        self.assertIn("deny", d["denied"]["reason"])

    def test_a_row_held_by_a_rule_ahead_of_the_popularity_check_is_never_read(self):
        rows = [zero("declined", approved=False), zero("risk30", risk=30),
                zero("conflict", rules={"review_hourly_velocity_profile": 100}),
                zero("reject", rules={"reject_artist_credit": 100}), zero("proofreq", meta={"proofRequest": {}})]
        res, w, admin = self.go(rows, {"t-" + r["id"]: {"popularity": 23} for r in rows})
        d = self.decisions()
        self.assertEqual(admin.track_reads, [])
        self.assertEqual(res.pop_reread, {})
        self.assertEqual(w.calls, [])
        for r in rows:
            self.assertEqual(d[r["id"]]["decision"], "hold", r["id"])
            self.assertEqual(d[r["id"]]["popularity"], 0, r["id"])

    def test_two_requests_on_one_track_are_scored_on_the_runs_one_read_of_it(self):
        rows = [{**zero("a"), "trackId": "shared"}, {**zero("b"), "trackId": "shared"}]
        res, w, admin = self.go(rows, {"shared": {"popularity": 7}})
        self.assertEqual(admin.track_reads, ["shared"])
        self.assertEqual(res.pop_reread, {sa.POP_CAPTURED: 2})
        self.assertEqual(self.written(w), ["a", "b"])

    def test_a_row_past_the_time_budget_is_held_unread_and_no_track_is_asked(self):
        class Builder:
            def track_popularity(self, tid):
                raise AssertionError("asked past the deadline")
        got = sa.live_popularity(Builder(), sleep=lambda _s: None, deadline=10.0, clock=lambda: 10.0)([zero("z")])
        self.assertEqual(got["z"][:2], (sa.POP_UNREAD, None))

    def test_shadow_mode_applies_nothing(self):
        res, w, _admin = self.go([zero("z")], {"t-z": {"popularity": 23}}, mode="shadow")
        outcomes = self.db.execute("SELECT outcome FROM decision_outcomes WHERE request_id = 'z'").fetchall()
        self.assertEqual(w.calls, [])
        self.assertEqual(res.approved, 0)
        self.assertEqual(res.would_approve, 1)
        self.assertEqual(outcomes, [("shadow",)])

    # -- the shadow report ------------------------------------------------------------------------------
    def held_run(self, rows, tracks):
        """A source run with the re-read off (today's code), committed to the ledger file."""
        self.go(rows, tracks, on=False)
        self.db.commit()
        return os.path.join(self.tmp, "ledger.sqlite3")

    def shadow(self, path, rows, tracks, **kw):
        w = Writer()
        report = sa.popularity_reread_shadow(TrackAdmin(rows, tracks), path, policy=policy(),
                                             sp=sa.ScorePolicy(enabled=True), scratch_dir=self.tmp, writer=w,
                                             source_run=kw.get("source_run"),
                                             **self.run_kwargs(kw.get("convo")))
        return report, w

    def test_the_shadow_report_decides_the_runs_stored_zero_holds_again_and_applies_nothing(self):
        rows = [zero("approve"), zero("ask", uid=501), zero("big"), zero("measured"), zero("novalue"), zero("gone"),
                row("scored", pop=20, pid="p-scored")]
        tracks = {"t-approve": {"popularity": 23}, "t-ask": {"popularity": 12}, "t-big": {"popularity": 64},
                  "t-measured": {"popularity": 0}, "t-novalue": {"id": "t-novalue"}}
        path = self.held_run(rows, tracks)
        before = Path(path).read_bytes()
        # User 501 has written to support since the source run: the proof path, never a provisional approval.
        report, w = self.shadow(path, rows, tracks, convo={501: True})
        self.assertEqual(report["held_on_stored_zero"], 6)
        self.assertEqual(report["reread"], {sa.POP_CAPTURED: 3, sa.POP_MEASURED_ZERO: 1, sa.POP_NO_VALUE: 1,
                                            sa.POP_UNREAD: 1})
        self.assertEqual(report["captured"], {"approve": 1, "ask": 1, "hold": 1})
        self.assertEqual(report["captured_bands"], {"1-29": 2, "30-59": 0, "60+": 1})
        self.assertEqual(report["not_decided"], 0)
        self.assertEqual(report["applied"], 0)
        self.assertEqual(w.calls, [])
        self.assertEqual(Path(path).read_bytes(), before, "no row in the live ledger")
        self.assertEqual([n for n in os.listdir(self.tmp) if n.startswith("score-approve-popularity-shadow-")], [])
        printed = "\n".join(sa.shadow_report_lines(report, sa.ScorePolicy(enabled=True)))
        self.assertIn("nothing applied", printed)
        self.assertIn("3 hold a real popularity of 1 or more", printed)
        self.assertIn("1 would approve, 1 hold, 1 ask", printed)

    def test_a_row_still_storing_zero_but_held_by_another_rule_is_not_called_updated(self):
        rows = [zero("still"), zero("updated")]
        path = self.held_run(rows, {})
        now = [{**rows[0], "verificationData": {**rows[0]["verificationData"],
                                                "rule_risk_percent": {"review_x": 100}}},
               {**rows[1], "spotifyPopularity": 20}]
        report, w = self.shadow(path, now, {"t-still": {"popularity": 23}, "t-updated": {"popularity": 23}})
        self.assertEqual(sum(report["other_rule_now"].values()), 1)
        self.assertEqual(sum(report["not_stored_zero"].values()), 1)
        self.assertEqual(sum(report["reread"].values()), 0)
        self.assertEqual(w.calls, [])

    def test_shadow_slices_leave_room_for_both_statuses_of_every_profile(self):
        rows = [zero(f"z{i}", uid=600 + i) for i in range(4)]
        tracks = {f"t-z{i}": {"popularity": 23} for i in range(4)}
        path = self.held_run(rows, tracks)
        w = Writer()
        report = sa.popularity_reread_shadow(TrackAdmin(rows, tracks), path, policy=policy(),
                                             sp=sa.ScorePolicy(enabled=True, max_per_run=4, max_profiles_per_run=4),
                                             scratch_dir=self.tmp, writer=w, **self.run_kwargs())
        self.assertEqual(report["not_decided"], 0)
        self.assertEqual(report["reread"][sa.POP_CAPTURED], 4)
        self.assertEqual(w.calls, [])

    def test_the_shadow_report_runs_with_the_reread_on_while_the_policy_has_it_off(self):
        rows = [zero("z")]
        tracks = {"t-z": {"popularity": 23}}
        path = self.held_run(rows, tracks)
        sp = sa.ScorePolicy(enabled=True)
        report = sa.popularity_reread_shadow(TrackAdmin(rows, tracks), path, policy=policy(), sp=sp,
                                             scratch_dir=self.tmp, **self.run_kwargs())
        self.assertEqual(report["captured"], {"approve": 1})
        self.assertFalse(sp.popularity_reread, "the caller's policy is not armed by the report")

    def test_a_held_request_core_no_longer_holds_is_reported_as_not_decided_never_as_a_zero(self):
        rows = [zero("z")]
        path = self.held_run(rows, {})
        report, w = self.shadow(path, [{**rows[0], "status": decide.APPROVED}], {"t-z": {"popularity": 23}})
        self.assertEqual(report["not_decided"], 1)
        self.assertEqual(sum(report["reread"].values()), 0)
        self.assertEqual(w.calls, [])

    def test_a_ledger_with_no_stored_zero_hold_reports_that_and_not_a_count_of_zero(self):
        rows = [row("scored", pop=20)]
        path = self.held_run(rows, {})
        report, _w = self.shadow(path, rows, {})
        printed = "\n".join(sa.shadow_report_lines(report, sa.ScorePolicy(enabled=True)))
        self.assertIsNone(report["source_run"])
        self.assertIn("This is not a count of zero", printed)

    def test_the_shadow_report_reads_the_run_it_is_given(self):
        first = self.held_run([zero("old")], {})
        run_id = self.db.execute("SELECT run_id FROM decisions WHERE request_id = 'old'").fetchone()[0]
        rows = [zero("old"), zero("new")]
        self.go([rows[1]], {}, on=False)
        self.db.commit()
        tracks = {"t-old": {"popularity": 5}, "t-new": {"popularity": 5}}
        w = Writer()
        report = sa.popularity_reread_shadow(TrackAdmin(rows, tracks), first, policy=policy(),
                                             sp=sa.ScorePolicy(enabled=True), source_run=run_id,
                                             scratch_dir=self.tmp, writer=w, **self.run_kwargs())
        self.assertEqual(report["source_run"], run_id)
        self.assertEqual(report["held_on_stored_zero"], 1)
        self.assertEqual(report["reread"][sa.POP_CAPTURED], 1)
        self.assertEqual(report["captured"], {"approve": 1})
        self.assertEqual(w.calls, [])
    def test_a_source_run_this_ledger_does_not_hold_is_not_measured_and_never_a_zero(self):
        rows = [zero("z")]
        path = self.held_run(rows, {"t-z": {"popularity": 23}})
        w = Writer()
        report = sa.popularity_reread_shadow(TrackAdmin(rows, {"t-z": {"popularity": 23}}), path,
                                             policy=policy(), sp=sa.ScorePolicy(enabled=True),
                                             source_run="score-typo", scratch_dir=self.tmp, writer=w,
                                             **self.run_kwargs())
        printed = "\n".join(sa.shadow_report_lines(report, sa.ScorePolicy(enabled=True)))
        self.assertFalse(report["source_run_found"])
        self.assertIn("source run score-typo was not found", printed)
        self.assertIn("This is not a count of zero", printed)
        self.assertNotIn("row(s) held on a stored popularity of 0", printed)
        self.assertEqual(w.calls, [])

    def test_a_source_run_that_held_no_stored_zero_row_still_reports_that_it_held_none(self):
        rows = [row("scored", pop=20)]
        path = self.held_run(rows, {})
        run_id = self.db.execute("SELECT run_id FROM decisions WHERE request_id = 'scored'").fetchone()[0]
        report, w = self.shadow(path, rows, {}, source_run=run_id)
        printed = "\n".join(sa.shadow_report_lines(report, sa.ScorePolicy(enabled=True)))
        self.assertTrue(report["source_run_found"])
        self.assertEqual(report["held_on_stored_zero"], 0)
        self.assertIn(f"source run {run_id}: 0 row(s) held on a stored popularity of 0", printed)
        self.assertNotIn("was not found", printed)
        self.assertEqual(w.calls, [])


class LiveAdmin(FakeAdmin):
    """Core's list as it really answers: a NEW object per read, so a row read before a write and the same
    row read after it are compared by value (FakeAdmin hands back the test's own dicts)."""

    def get(self, path, params=None):
        return json.loads(json.dumps(super().get(path, params)))

    def change(self, rid, **cols):
        """Another actor rewrote the request: the columns given, and core's updatedAt with them."""
        for r in self.rows:
            if r["id"] == rid:
                r.update(cols)
                r["updatedAt"] = "2026-10-20T12:00:%02d.000Z" % len(self.calls)


class CoreWriter:
    """Core's answer per send. ``lost[n]`` names the ids the n-th send answers ``lost_race`` for (the last
    entry repeats); ``after(n)`` runs once that send has answered."""

    def __init__(self, lost, after=None):
        self.lost, self.after, self.calls = [set(x) for x in lost], after, []

    def __call__(self, status, ids, expected):
        n = len(self.calls)
        self.calls.append((status, list(ids), expected))
        lost = self.lost[min(n, len(self.lost) - 1)] & set(ids)
        if self.after:
            self.after(n)
        return {"data": {"updatedIds": [i for i in ids if i not in lost],
                         "skipped": [{"id": i, "reason": "lost_race"} for i in ids if i in lost]}}


class LostRace(unittest.TestCase):
    """2026-11-15: core answers ``lost_race`` both for a row another actor rewrote mid-write and for a row
    one of its own guards refuses. The executor reads the row again and records which it was."""

    # The fixture of ScoreApprove, without running its tests a second time.
    setUp, proof, go = ScoreApprove.setUp, ScoreApprove.proof, ScoreApprove.go

    def outcomes(self, rid):
        return [r[0] for r in self.db.execute(
            "SELECT outcome FROM decision_outcomes WHERE request_id = ? ORDER BY id", (rid,))]

    def sends(self, w, rid):
        return [c for c in w.calls if rid in c[1]]

    # -- the three the task names -------------------------------------------------------------------

    def test_a_row_that_changed_between_read_and_write_is_sent_once_more_and_lands(self):
        admin = LiveAdmin([row("x", status=decide.UNVERIFIED)])
        w = CoreWriter([{"x"}, set()], after=lambda n: n == 0 and admin.change("x", status=decide.UVN))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(self.sends(w, "x")), 2)
        self.assertEqual(w.calls[0][2], decide.UNVERIFIED)
        self.assertEqual(w.calls[1][2], decide.UVN, "the second send expects the status just read")
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:retrying", decide.APPROVED])
        self.assertEqual(res.approved, 1)
        self.assertEqual(res.retried, 1)
        self.assertEqual(res.retry_landed, 1)
        self.assertEqual(res.guard_refused, 0)

    def test_the_resend_is_bounded_and_running_out_is_recorded(self):
        admin = LiveAdmin([row("x")])
        w = CoreWriter([{"x"}], after=lambda n: admin.change("x", metadata={"touched": n}))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(self.sends(w, "x")), 2, "the first send and one more, never a third")
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:retrying", "skipped:retry_exhausted:lost_race"])
        self.assertEqual(res.approved, 0)
        self.assertEqual(res.retried, 1)
        self.assertEqual(res.retry_landed, 0)
        self.assertEqual(res.skipped_by_server, {"retry_exhausted:lost_race": 1})

    def test_a_write_core_takes_lands_first_time_with_no_second_read(self):
        admin = LiveAdmin([row("x")])
        w = CoreWriter([set()])
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1)
        self.assertEqual(self.outcomes("x"), [decide.APPROVED])
        self.assertEqual(len(admin.calls), 1, "one read to decide, none after a write that landed")
        self.assertEqual(res.approved, 1)
        self.assertEqual(res.retried, 0)
        self.assertEqual(res.skipped_by_server, {})

    # -- the label: a refusal of a row nobody touched is a guard, never a race --------------------------

    def test_a_row_that_reads_the_same_after_the_refusal_is_a_guard_refusal_and_is_not_resent(self):
        admin = LiveAdmin([row("x")])
        w = CoreWriter([{"x"}])
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1)
        self.assertEqual(self.outcomes("x"), [sa.GUARD_REFUSED])
        self.assertEqual(res.guard_refused, 1)
        self.assertEqual(res.retried, 0)
        self.assertEqual(res.skipped_by_server, {"core_guard_refused": 1})
        self.assertNotIn("'lost_race'", res.line(), "the funnel's count is not under core's word for it")
        self.assertIn("1 refused by a core guard", res.line())

    def test_the_rest_of_the_batch_lands_beside_a_guard_refusal(self):
        admin = LiveAdmin([row("x"), row("ok", pid="p2", uid=501)])
        w = CoreWriter([{"x"}])
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(self.outcomes("ok"), [decide.APPROVED])
        self.assertEqual(self.outcomes("x"), [sa.GUARD_REFUSED])
        self.assertEqual(res.approved, 1)
        self.assertEqual(len(w.calls), 1)

    def test_a_changed_row_whose_verdict_changed_is_not_resent(self):
        admin = LiveAdmin([row("x")])
        w = CoreWriter([{"x"}], after=lambda n: admin.change("x", verificationData={
            "is_approved": True, "total_risk_percent": 5, "rule_risk_percent": {}, "band_hint": "A"}))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1, "still approvable, but not the row that was decided")
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:decision_stale"])
        self.assertEqual(res.retried, 0)
        self.assertEqual(res.guard_refused, 0)

    def test_a_changed_row_the_rules_no_longer_admit_is_not_resent(self):
        admin = LiveAdmin([row("x")])
        w = CoreWriter([{"x"}], after=lambda n: admin.change("x", metadata={"proofRequest": {}}))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1)
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:decision_stale"])

    def test_a_row_that_left_the_held_statuses_is_not_resent(self):
        admin = LiveAdmin([row("x")])
        w = CoreWriter([{"x"}], after=lambda n: admin.change("x", status=decide.APPROVED))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1)
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:left_held"])
        self.assertEqual(res.approved, 0, "somebody else's approval is not counted as this run's")

    def test_a_row_that_cannot_be_read_again_is_neither_a_guard_refusal_nor_resent(self):
        class DiesAfterWrite(LiveAdmin):
            dead = False

            def get(self, path, params=None):
                if self.dead:
                    raise sa.admin_api.AdminError("admin GET timed out")
                return super().get(path, params)
        admin = DiesAfterWrite([row("x")])
        w = CoreWriter([{"x"}], after=lambda n: setattr(admin, "dead", True))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1)
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:state_unread:read_failed"])
        self.assertEqual(res.guard_refused, 0)
        self.assertEqual(sa.recently_guard_refused(self.db, NOW), set(), "unread is not unchanged: not cooled")

    def test_the_second_send_goes_through_the_same_caps_once(self):
        admin = LiveAdmin([row("x", status=decide.UNVERIFIED)])
        w = CoreWriter([{"x"}, set()], after=lambda n: n == 0 and admin.change("x", status=decide.UVN))
        self.go(admin.rows, admin=admin, writer=w)
        users, profiles, fleet = sa.written_today(self.db, "2026-10-20T00:00:00Z")
        self.assertEqual(fleet, 1)
        self.assertEqual(users, {500: 1})
        self.assertEqual(profiles, {"p1": 1})

    # -- the backoff, keyed on the recorded outcome ---------------------------------------------------

    def test_a_guard_refused_row_is_not_read_decided_or_sent_on_the_next_tick(self):
        admin = LiveAdmin([row("x")])
        self.go(admin.rows, admin=admin, writer=CoreWriter([{"x"}]))
        decided, reads = len(self.db.execute("SELECT 1 FROM decisions").fetchall()), len(admin.calls)
        w = CoreWriter([{"x"}])
        res, _ = self.go(admin.rows, admin=admin, writer=w, now=NOW + timedelta(minutes=15))
        self.assertEqual(w.calls, [])
        self.assertEqual(len(admin.calls), reads, "no profile read is spent on it")
        self.assertEqual(len(self.db.execute("SELECT 1 FROM decisions").fetchall()), decided)
        self.assertEqual(self.outcomes("x"), [sa.GUARD_REFUSED])
        self.assertEqual(res.guard_cooling, 1)
        self.assertEqual(res.candidates, 1, "it is still counted as a candidate")
        self.assertIn("1 not sent: a core guard refused them", res.line())

    def test_a_run_that_only_parks_guard_refused_rows_is_not_silent(self):
        admin = LiveAdmin([row("x")])
        self.go(admin.rows, admin=admin, writer=CoreWriter([{"x"}]))
        import importlib.util
        import io
        from contextlib import redirect_stdout
        spec = importlib.util.spec_from_file_location("credit_review_cli", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        orig_run = sa.run

        def run_again(_admin, db, **kw):
            cands = lambda risk, limit: [(r["id"], r["profileId"],
                                          float(r["verificationData"]["total_risk_percent"]),
                                          r["status"], r["userId"]) for r in admin.rows]
            return orig_run(admin, db, **{**kw, "candidates": cands, "writer": CoreWriter([{"x"}]),
                                          "now": NOW + timedelta(minutes=15)})
        sa.run = run_again
        self.addCleanup(setattr, sa, "run", orig_run)
        for attr in ("KILL_SWITCH",):
            self.addCleanup(setattr, sa, attr, getattr(sa, attr))
            setattr(sa, attr, Path(self.tmp) / "nope")
        self.addCleanup(setattr, decide, "KILL_SWITCH", decide.KILL_SWITCH)
        decide.KILL_SWITCH = Path(self.tmp) / "nope2"
        args = cli.argparse.Namespace(pause=None, resume=False, mode="apply", max_per_run=None,
                                      ledger=os.path.join(self.tmp, "ledger.sqlite3"))
        orig_load, orig_sp = decide.Policy.load, sa.ScorePolicy.load
        decide.Policy.load = staticmethod(lambda *a, **k: policy())
        sa.ScorePolicy.load = staticmethod(lambda *a, **k: sa.ScorePolicy(enabled=True))
        self.addCleanup(setattr, decide.Policy, "load", orig_load)
        self.addCleanup(setattr, sa.ScorePolicy, "load", orig_sp)
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.cmd_score_approve(args)
        out = buf.getvalue()
        self.assertEqual(rc, 0)
        self.assertNotIn("NO_REPLY", out)
        self.assertIn("1 not sent: a core guard refused them", out)

    def test_a_cooling_row_does_not_take_the_slot_of_a_row_that_can_land(self):
        admin = LiveAdmin([row("x")])
        self.go(admin.rows, admin=admin, writer=CoreWriter([{"x"}]))
        admin.rows.append(row("ok", pid="p2", uid=501))
        w = CoreWriter([{"x"}])
        res, _ = self.go(admin.rows, admin=admin, writer=w, now=NOW + timedelta(minutes=15),
                         sp=sa.ScorePolicy(enabled=True, max_per_run=1))
        self.assertEqual([c[1] for c in w.calls], [["ok"]])
        self.assertEqual(res.approved, 1)

    def test_the_cooldown_ends_and_the_row_lands_once_the_guard_clears(self):
        # An outcome row carries the wall-clock time of its write, so the earlier refusal is put on file here.
        decide.ensure_schema(self.db)
        ended = NOW - timedelta(hours=sa.GUARD_REFUSED_COOLDOWN_H, minutes=1)
        decide.record_outcome(self.db, "score-earlier", "x", "approve", sa.GUARD_REFUSED, ended)
        self.assertEqual(sa.recently_guard_refused(self.db, NOW - timedelta(minutes=2)), {"x"})
        self.assertEqual(sa.recently_guard_refused(self.db, NOW), set())
        admin = LiveAdmin([row("x")])
        w = CoreWriter([set()])
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 1)
        self.assertEqual(self.outcomes("x"), [sa.GUARD_REFUSED, decide.APPROVED])
        self.assertEqual(res.guard_cooling, 0)
        self.assertEqual(res.approved, 1)

    def test_only_the_latest_written_outcome_cools_a_row(self):
        at = NOW - timedelta(hours=1)
        decide.ensure_schema(self.db)
        decide.record_outcome(self.db, "score-a", "refused-then-unread", "approve", sa.GUARD_REFUSED, at)
        decide.record_outcome(self.db, "score-b", "refused-then-unread", "approve",
                              "skipped:lost_race:state_unread:read_failed", at)
        decide.record_outcome(self.db, "score-a", "refused-then-shadow", "approve", sa.GUARD_REFUSED, at)
        decide.record_outcome(self.db, "score-b", "refused-then-shadow", "approve", "shadow", at)
        decide.record_outcome(self.db, "trust-a", "another-jobs-row", "approve", sa.GUARD_REFUSED, at)
        decide.record_outcome(self.db, "score-a", "core-said-race", "approve", "skipped:lost_race", at)
        cooling = sa.recently_guard_refused(self.db, NOW)
        self.assertNotIn("refused-then-unread", cooling)
        self.assertIn("refused-then-shadow", cooling, "a shadow run wrote nothing: it lifts no cooldown")
        self.assertNotIn("another-jobs-row", cooling)
        self.assertNotIn("core-said-race", cooling, "the rows recorded before this change are not cooled")

    def test_a_shadow_run_still_decides_a_cooling_row(self):
        admin = LiveAdmin([row("x")])
        self.go(admin.rows, admin=admin, writer=CoreWriter([{"x"}]))
        res, w = self.go(admin.rows, admin=admin, mode="shadow", now=NOW + timedelta(minutes=15))
        self.assertEqual(res.would_approve, 1)
        self.assertEqual(res.guard_cooling, 0)
        self.assertEqual(w.calls, [])

    # -- the settle read is bounded ---------------------------------------------------------------------

    def test_no_settle_read_starts_that_could_outlive_the_run(self):
        admin = LiveAdmin([row("x")])
        rows, unread = sa.fresh_rows(admin, {"x": "p1"}, sleep=lambda _s: None, clock=lambda: 100.0,
                                     deadline=100.0 + 2 * (sa.RACE_PACE_S + sa.RACE_READ_TIMEOUT_S) - 1, spent=[0])
        self.assertEqual(rows, {})
        self.assertEqual(unread, {"x": "time_budget"})
        self.assertEqual(admin.calls, [])

    def test_the_settle_reads_stop_at_the_profile_budget(self):
        admin = LiveAdmin([row("x")])
        spent = [sa.RACE_REREAD_MAX_PROFILES]
        rows, unread = sa.fresh_rows(admin, {"x": "p1"}, sleep=lambda _s: None, clock=lambda: 0.0,
                                     deadline=10_000.0, spent=spent)
        self.assertEqual(unread, {"x": "reread_budget"})
        self.assertEqual(admin.calls, [])

    def test_a_settle_read_is_held_to_its_own_timeout_and_the_client_gets_its_own_back(self):
        seen = []

        class Timed(LiveAdmin):
            timeout = 90

            def get(self, path, params=None):
                seen.append(self.timeout)
                return super().get(path, params)
        admin = Timed([row("x")])
        rows, unread = sa.fresh_rows(admin, {"x": "p1"}, sleep=lambda _s: None, clock=lambda: 0.0,
                                     deadline=10_000.0, spent=[0])
        self.assertEqual(seen, [sa.RACE_READ_TIMEOUT_S] * len(sa.HELD_STATUSES))
        self.assertEqual(admin.timeout, 90)
        self.assertEqual(sorted(rows), ["x"])
        self.assertEqual(unread, {})

    def test_a_full_page_that_does_not_show_the_row_is_unread_not_left(self):
        admin = LiveAdmin([row("x")] + [row(f"f{i}") for i in range(3)])
        with _mock.patch.object(sa, "RACE_READ_LIMIT", 3):
            with _mock.patch.object(sa.admin_api, "list_requests",
                                    lambda a, **kw: [r for r in a.rows if r["id"] != "x"
                                                     and r["status"] == kw["status"]][:3]):
                rows, unread = sa.fresh_rows(admin, {"x": "p1"}, sleep=lambda _s: None, clock=lambda: 0.0,
                                             deadline=10_000.0, spent=[0])
        self.assertEqual(rows, {})
        self.assertEqual(unread, {"x": "page_full"})

    def test_a_second_send_that_dies_is_recorded_as_unconfirmed_not_as_a_skip(self):
        admin = LiveAdmin([row("x")])

        class Dies(CoreWriter):
            def __call__(self, status, ids, expected):
                if self.calls:
                    self.calls.append((status, list(ids), expected))
                    raise RuntimeError("boom")
                return super().__call__(status, ids, expected)
        w = Dies([{"x"}], after=lambda n: admin.change("x", metadata={"touched": n}))
        res, _ = self.go(admin.rows, admin=admin, writer=w)
        self.assertEqual(len(w.calls), 2)
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:retrying", "error:unverified:re-send raised RuntimeError"])
        self.assertEqual(len(res.write_errors), 1)

    def test_a_changed_row_is_not_resent_when_no_write_can_still_finish(self):
        decide.ensure_schema(self.db)
        was = row("x")
        admin = LiveAdmin([dict(was, metadata={"touched": 1}, updatedAt="2026-10-20T12:00:01.000Z")])
        res, w = sa.ScoreResult(run_id="score-t", mode="apply"), CoreWriter([set()])
        late = sa.RUN_BUDGET_S - sa.WRITE_BATCH_WORST_S + 1   # room for the two reads, none for a write
        sa.settle_lost_race(self.db, res, ["x"], {"x": SimpleNamespace(profile_id="p1")}, policy(),
                            sa.ScorePolicy(enabled=True), w, lambda status, ids: set(), 0.0,
                            SimpleNamespace(monotonic=lambda: float(late)),
                            SimpleNamespace(admin=admin, rows={"x": was}, engaged=None, sleep=lambda _s: None,
                                            spent=[0]))
        self.assertEqual(len(admin.calls), len(sa.HELD_STATUSES), "it was read")
        self.assertEqual(w.calls, [])
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:changed_not_resent:time_budget"])
        self.assertEqual(res.retried, 0)

    def test_a_failure_while_settling_still_leaves_an_outcome_for_every_row(self):
        admin = LiveAdmin([row("x")])
        with _mock.patch.object(sa, "fresh_rows", side_effect=RuntimeError("boom")):
            res, w = self.go(admin.rows, admin=admin, writer=CoreWriter([{"x"}]))
        self.assertEqual(self.outcomes("x"), ["skipped:lost_race:state_unread:RuntimeError"])
        self.assertEqual(len(res.write_errors), 1)
        self.assertEqual(res.guard_refused, 0)


class ProfileBurstGate(unittest.TestCase):
    """Core's PROFILE burst guard (`notProfileBurstSql`) is a pin INSIDE the approving UPDATE, so a
    refused row matches nothing, reads back exactly as it was, and is reported as `lost_race` — the same
    word core uses for a real race. 2026-11-16: 34 requests on 5 profiles (every profile carrying a
    `review_hourly_velocity_profile` sibling inside 7 days) were re-decided and re-refused every tick
    for up to a day, and the queue report printed them as 1,036 `core_guard_refused` rows.

    The executor now reads the guard's EFFECT and DEFERS the row, naming the rule, the sibling and the
    date the window lapses. Nothing is relaxed: core still refuses, and the row is approved by the first
    run after that date. Doc: data/decided-not-closed-core-guard-r1/report.md."""

    def test_a_fired_rule_is_a_burst_and_zero_null_or_absent_is_not(self):
        # core: key present, jsonb value not numeric-zero (a NON-numeric value counts as fired)
        cases = [({"review_hourly_velocity_profile": 100}, "review_hourly_velocity_profile"),
                 ({"reject_high_velocity_profile": 1}, "reject_high_velocity_profile"),
                 ({"review_high_velocity_profile": "55"}, "review_high_velocity_profile"),
                 ({"review_hourly_velocity_profile": "abc"}, "review_hourly_velocity_profile"),
                 ({"review_hourly_velocity_profile": True}, "review_hourly_velocity_profile"),
                 ({"review_hourly_velocity_profile": 0}, None),
                 ({"review_hourly_velocity_profile": "0"}, None),
                 ({"review_hourly_velocity_profile": "0.0"}, None),
                 ({"review_hourly_velocity_profile": None}, None),
                 ({"review_editing_role_without_trusted_credit": None}, None),
                 ({"track_credit": 0}, None),
                 ({}, None)]
        for rules, want in cases:
            self.assertEqual(sa.burst_rule_fired(rules), want, repr(rules))

    def test_the_window_lapses_seven_days_after_the_sibling_was_created(self):
        self.assertEqual(sa.PROFILE_BURST_WINDOW, timedelta(days=7))
        self.assertEqual(sa.burst_clears_at("2026-11-14 01:01:44 UTC", NOW), "2026-11-21T01:01:44Z")
        self.assertEqual(sa.burst_clears_at("2026-11-14T01:01:44Z", NOW), "2026-11-21T01:01:44Z")
        self.assertEqual(sa.burst_clears_at("", NOW), "unknown")   # never a date it did not read

    def test_the_reason_names_the_rule_the_sibling_and_the_date(self):
        r = row("burst1", uid=700, pid="bp1")
        bursts = (("review_hourly_velocity_profile", "sib1", "2026-11-14 01:01:44 UTC"),)
        why = sa.burst_hold(r, bursts, NOW)
        self.assertTrue(why.startswith(sa.PROFILE_BURST_PREFIX), why)
        self.assertIn("notProfileBurstSql", why)
        self.assertIn("review_hourly_velocity_profile", why)
        self.assertIn("sib1", why)
        self.assertIn("2026-11-21T01:01:44Z", why)
        self.assertIsNone(sa.burst_hold(r, None, NOW), "a clear profile is not held")
        self.assertIsNone(sa.burst_hold(r, (), NOW))

    def test_a_row_never_holds_its_own_profile(self):
        r = row("self1", pid="sp1")
        self.assertIsNone(sa.burst_hold(r, (("review_hourly_velocity_profile", "self1",
                                            "2026-11-14 01:01:44 UTC"),), NOW))

    def test_a_clock_answer_is_deferred_not_held(self):
        self.assertTrue(sa.PROFILE_BURST_PREFIX in sa.CLOCK_DEFER_PREFIXES)

    def test_the_live_reader_asks_one_statement_for_every_profile(self):
        rows = [row("a", pid="Pa"), row("b", pid="pb")]
        verdict = json.dumps({"review_hourly_velocity_profile": 100})
        # one CSV line as trino-query.sh prints it: quoted fields, the JSON object included
        out = '"pa","b1","2026-11-14 01:01:44 UTC","{}"\n'.format(verdict.replace('"', '""'))
        with _mock.patch.object(sa.subprocess, "run",
                                return_value=_mock.Mock(returncode=0, stdout=out)) as run:
            got = sa.live_profile_burst(NOW, deadline=1000.0, clock=lambda: 0.0)([rows[0]])
        self.assertEqual(got, {"pa": (("review_hourly_velocity_profile", "b1",
                                       "2026-11-14 01:01:44 UTC"),)})
        self.assertEqual(run.call_count, 1, "one replica statement for every profile of the run")
        sql = run.call_args.kwargs["input"]
        self.assertIn("postgresql_core.public.credit_requests", sql)
        self.assertIn("rule_risk_percent", sql)
        self.assertIn("'pa'", sql, "the profile ids are the run's, lowercased")
        self.assertIn("createdat > TIMESTAMP '2026-10-13 12:00:00'", sql, "core's 7-day window")

    def test_a_successful_but_malformed_response_never_clears_a_profile(self):
        # Trino exits 0 on a truncated or malformed response. A row this cannot read is a row it cannot
        # rule out: skipping it would let the only burst sibling of a profile vanish and the profile read
        # clear, which is the 15-minute core_guard_refused loop this reader exists to stop.
        r = row("m1", pid="mp1")
        good = '"mp1","sib","2026-11-14 01:01:44 UTC","{""review_hourly_velocity_profile"":100}"'
        cases = {
            "a truncated row": '"mp1","sib","2026-11-14 01:01:44 UTC"',
            "a verdict that is not JSON": '"mp1","sib","2026-11-14 01:01:44 UTC","{oops"',
            "a row naming no profile of the run": '"other","sib","2026-11-14 01:01:44 UTC","{}"',
            "a good row beside a truncated one": good + '\n"mp1","sib2"',
        }
        for why, out in cases.items():
            with _mock.patch.object(sa.subprocess, "run",
                                    return_value=_mock.Mock(returncode=0, stdout=out)):
                got = sa.live_profile_burst(NOW, deadline=1000.0, clock=lambda: 0.0)([r])
            self.assertIs(got["mp1"], sa.BURST_UNREADABLE, why)
        # and the well-formed response still reads as a burst, so the rule is not "always unreadable"
        with _mock.patch.object(sa.subprocess, "run",
                                return_value=_mock.Mock(returncode=0, stdout=good)):
            got = sa.live_profile_burst(NOW, deadline=1000.0, clock=lambda: 0.0)([r])
        self.assertEqual(got["mp1"], (("review_hourly_velocity_profile", "sib",
                                       "2026-11-14 01:01:44 UTC"),))

    def test_an_unreadable_replica_is_never_a_clear_profile(self):
        r = row("u1", pid="up1")
        for side in (sa.subprocess.TimeoutExpired("trino", 5), OSError("no trino"),
                     _mock.Mock(returncode=1, stdout="")):
            kw = {"side_effect": side} if isinstance(side, BaseException) else {"return_value": side}
            with _mock.patch.object(sa.subprocess, "run", **kw):
                got = sa.live_profile_burst(NOW, deadline=1000.0, clock=lambda: 0.0)([r])
            self.assertIs(got["up1"], sa.BURST_UNREADABLE)
            self.assertIn("unreadable", repr(got["up1"]))
        with _mock.patch.object(sa.subprocess, "run") as run:
            past = sa.live_profile_burst(NOW, deadline=10.0, clock=lambda: 99.0)([r])
        run.assert_not_called()
        self.assertIs(past["up1"], sa.BURST_UNREADABLE)


class ProfileBurstDecisions(unittest.TestCase):
    """The burst guard's effect on the ROW: deferred by name, never approved while core would refuse."""

    # The fixture of ScoreApprove, without running its tests a second time.
    setUp, proof, go, decisions = ScoreApprove.setUp, ScoreApprove.proof, ScoreApprove.go, ScoreApprove.decisions

    def test_a_bursting_profile_is_deferred_with_the_guard_named_and_writes_nothing(self):
        rows = [row("hit", uid=701, pid="bp1"), row("clean", uid=702, pid="bp2")]
        res, w = self.go(rows, profile_burst=lambda rs: {
            "bp1": (("review_hourly_velocity_profile", "sib1", "2026-11-14 01:01:44 UTC"),),
            "bp2": None})
        self.assertEqual([i for c in w.calls for i in c[1]], ["clean"])
        d = self.decisions()["hit"]
        self.assertEqual(d["decision"], "defer", "a clock answer is not a person's queue")
        self.assertIn(sa.PROFILE_BURST_PREFIX, d["reason"])
        self.assertIn("sib1", d["reason"])
        self.assertEqual(res.burst_held, 1)
        self.assertEqual(res.approved, 1)

    def test_a_deferred_burst_row_is_never_counted_against_a_cap(self):
        # the defer happens before the caps: 3 rows on one user, 2 bursting, max_per_run caps nothing away
        rows = [row("d1", uid=703, pid="bp1"), row("d2", uid=703, pid="bp1"), row("d3", uid=703, pid="bp2")]
        res, w = self.go(rows, pol=policy(per_user=1), profile_burst=lambda rs: {
            "bp1": (("review_hourly_velocity_profile", "sib1", "2026-11-14 01:01:44 UTC"),),
            "bp2": None})
        self.assertEqual(res.burst_held, 2)
        self.assertEqual([i for c in w.calls for i in c[1]], ["d3"])

    def test_an_unreadable_burst_read_holds_the_row_and_is_never_cooled_for_six_hours(self):
        rows = [row("unk", uid=704, pid="bp1")]
        res, w = self.go(rows, profile_burst=lambda rs: {})
        self.assertEqual(w.calls, [])
        why = self.decisions()["unk"]["reason"]
        self.assertIn(sa.PROFILE_BURST_PREFIX, why)
        self.assertIn("notProfileBurstSql", why)
        self.assertEqual(res.burst_held, 1)
        self.assertTrue(any(t in why for t in sa.TRANSIENT_HOLD), "retried next run, not parked 6h")

    def test_the_run_line_says_how_many_rows_core_s_burst_guard_deferred(self):
        rows = [row("hit", uid=705, pid="bp1")]
        res, _w = self.go(rows, profile_burst=lambda rs: {
            "bp1": (("review_hourly_velocity_profile", "sib1", "2026-11-14 01:01:44 UTC"),)})
        self.assertIn("core's profile burst guard", res.line())
        self.assertIn("notProfileBurstSql", res.line())
        quiet, _w2 = self.go([row("ok2", uid=706, pid="bp9")], profile_burst=NO_BURST)
        self.assertNotIn("core's profile burst guard", quiet.line())


if __name__ == "__main__":
    unittest.main(verbosity=2)
