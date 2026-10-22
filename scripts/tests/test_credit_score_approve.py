#!/usr/bin/env python3
"""score-approve (captain 2026-10-20 "approve low risk credits", firstmate 110)."""
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
import credit_test_env  # noqa: E402,F401  (test log isolation)
from credit_review import decide, score_approve as sa, verify_notify  # noqa: E402

NOW = datetime(2026, 10, 20, 12, 0, tzinfo=timezone.utc)


def row(rid, *, uid=500, pid="p1", risk=0, approved=True, pop=20, roles=("Producer",), rules=None, status=decide.UVN,
        created="2026-10-19T00:00:00Z", meta=None, band=None):
    vd = {"is_approved": approved, "total_risk_percent": risk, "rule_risk_percent": dict(rules or {})}
    if band is not None:
        vd["band_hint"] = band
    return {"id": rid, "profileId": pid, "userId": uid, "trackId": "t-" + rid, "status": status,
            "spotifyTrackTitle": "Song " + rid, "spotifyPopularity": pop, "credits": list(roles),
            "createdAt": created, "verificationData": vd, "metadata": dict(meta or {})}


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

    def go(self, rows, *, mode="apply", sp=None, pol=None, convo=None, admin=None):
        sp = sp or sa.ScorePolicy(enabled=True)
        w = Writer()
        cands = lambda risk, limit: [(r["id"], r["profileId"], float(r["verificationData"]["total_risk_percent"]),
                                      r["status"], r["userId"])
                                     for r in sorted(rows, key=lambda r: r["verificationData"]["total_risk_percent"])]
        self.convo_asked = {}

        def conversations(users):
            self.convo_asked.update(users)
            return {u: (convo or {}).get(u, False) for u in users}
        res = sa.run(admin or FakeAdmin(rows), self.db, mode=mode, policy=pol or policy(), sp=sp, candidates=cands, writer=w,
                     readback=lambda status, ids: set(), now=NOW, sleep=lambda _s: None, conversations=conversations)
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
                     conversations=lambda users: {u: False for u in users})
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
                row("master-hit", roles=("Mastering",), pid="p3", rules={sa.ONE_PERSON_RULE: 5})]
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
