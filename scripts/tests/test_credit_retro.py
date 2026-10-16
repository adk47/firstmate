#!/usr/bin/env python3
"""Unit tests for scripts/credit_retro (role-scoped credit take-back + waves).

Stdlib unittest, no network: the admin API is faked. Run:
    python3 scripts/tests/test_credit_retro.py
"""

from __future__ import annotations

import base64
import json
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_retro import takeback, waves  # noqa: E402
from credit_retro.api import ApiError, SessionApi, check_session_claims, header_value  # noqa: E402
from credit_retro.ledger import Ledger  # noqa: E402

MANIFEST_DIR = Path(__file__).resolve().parents[1] / "credit_retro" / "manifests"
CLI = Path(__file__).resolve().parents[1] / "credit-retro.py"

RID = "11111111-1111-4111-8111-111111111111"
UID = "197122"
PID = "22222222-2222-4222-8222-222222222222"
TID = "33333333-3333-4333-8333-333333333333"
ARTIST_PID = "44444444-4444-4444-8444-444444444444"


def row(**over):
    base = {"row_id": f"{RID}:Mixing", "request_id": RID, "user_id": UID, "profile_id": PID, "track_id": TID,
            "role": "Mixing", "displaced": ["Eli WTF"], "evidence_url": "https://www.qobuz.com/x",
            "track_title": "Lemonade", "artist": "k3", "pop_now": 35, "web": {"verdict": "CONTRADICTED"}}
    base.update(over)
    return base


def raw(source, name, role, pid="x"):
    return {"profile": {"source": source, "name": name, "id": pid}, "credit": role}


class FakeApi:
    """In-memory admin API: one request, raw credits per track, profiles."""

    actor = "nick@muso.ai"

    def __init__(self):
        self.request = {"id": RID, "status": "approved", "userId": int(UID), "profileId": PID, "trackId": TID,
                        "credits": ["Mixing", "Engineer"], "updatedAt": "2026-09-02T00:11:21Z",
                        "spotifyTrackArtists": [{"id": ARTIST_PID, "name": "k3"}]}
        self.raws = [raw("spotify", "Eli WTF", "mixing engineer", "sp1"), raw("tidal", "Eli WTF", "mixer", "td1"),
                     raw("muso", "Rishi Krishnan", "mixing", PID), raw("muso", "Rishi Krishnan", "engineer", PID)]
        self.profile = {"name": "Rishi Krishnan", "rawProfiles": []}
        self.writes: list[tuple] = []
        self.write_status = 200

    def get(self, path, params=None):
        params = params or {}
        if path == "/admin/credit-requests":
            return {"items": [self.request] if params.get("trackId") == TID else []}
        if path.endswith("/raw-credits"):
            items = self.raws
            if "credit" in params:
                fam = takeback.family_of(params["credit"])
                items = [r for r in items if takeback.family_of(r["credit"]) == fam]
            if "profileId" in params:
                items = [r for r in items if r["profile"]["id"] == params["profileId"]]
            page = params.get("page", 1)
            return {"items": items if page == 1 else [], "total": len(items)}
        if path.startswith("/admin/profile/"):
            return self.profile
        if path.startswith("/admin/credit-removals/"):
            return self.approval
        raise ApiError(f"unexpected GET {path}")

    approval = None

    def approve(self):
        """Nick/Jan approved a set covering the row's pair."""
        self.approval = {"id": "ap-1", "status": "approved", "expiresAt": None,
                         "pairs": [{"profileId": PID, "trackId": TID, "role": "mixing"}]}
        return ["ap-1"]

    def write(self, method, path, body, headers=None):
        self.writes.append((method, path, body, headers))
        if path == "/admin/credit-removals":
            self.approval = {"id": "ap-1", "status": "pending", "expiresAt": None,
                             "pairs": [{"profileId": p["profileId"], "trackId": p["trackId"], "role": r.lower()}
                                       for p in body["pairs"] for r in p["roles"]]}
            return 201, {"result": "ok", "data": {"id": "ap-1", "status": "pending"}}
        if self.write_status >= 300:
            return self.write_status, {"result": "error", "errorCode": "credit_removal_agent_refused"}
        role = body["credits"][0].lower()
        if method == "DELETE":
            self.raws = [r for r in self.raws if not (r["profile"]["id"] == PID and r["credit"] == role)]
        else:
            self.raws.append(raw("muso", "Rishi Krishnan", role, PID))
        return 200, {"result": "ok"}


def write_manifest(tmp: Path, rows) -> str:
    p = tmp / "takeback.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return str(p)


class GateTests(unittest.TestCase):
    def test_pass_when_trusted_sources_credit_someone_else(self):
        res = takeback.gate(FakeApi(), row())
        self.assertTrue(res.ok, res.reason)
        self.assertEqual({h["name"] for h in res.before["trusted_holders"]}, {"Eli WTF"})

    def test_user_15_is_never_touched(self):
        api = FakeApi()
        self.assertEqual(takeback.gate(api, row(user_id="15")).reason, "excluded_user")

    def test_confirmed_by_trusted_source_is_kept(self):
        # archiesarchiesarchies / yungpidi808 class: Spotify and Tidal credit the claimant too.
        api = FakeApi()
        api.raws.append(raw("spotify", "Rishi Krishnan", "mixing engineer", "sp9"))
        self.assertEqual(takeback.gate(api, row()).reason, "not_contradicted_live:CONFIRMED")

    def test_only_a_muso_claim_by_someone_else_is_not_proof(self):
        # Chris Doss class: the other "holder" is another user's Muso claim, no trusted source.
        api = FakeApi()
        api.raws = [raw("muso", "Jay Baumgardner", "mixing", "jay"), raw("muso", "Rishi Krishnan", "mixing", PID)]
        self.assertEqual(takeback.gate(api, row()).reason, "not_contradicted_live:UNVERIFIABLE")

    def test_alias_by_known_as_name_is_kept(self):
        api = FakeApi()
        api.profile["knownAsNames"] = ["Eli WTF"]
        self.assertEqual(takeback.gate(api, row()).reason, "not_contradicted_live:CONFIRMED")

    def test_claimant_named_like_track_artist_is_skipped(self):
        api = FakeApi()
        api.profile["name"] = "k3"
        self.assertEqual(takeback.gate(api, row()).reason, "claimant_is_track_artist")

    def test_claimant_profile_is_track_artist_is_skipped(self):
        api = FakeApi()
        api.request["spotifyTrackArtists"] = [{"id": PID, "name": "x"}]
        self.assertEqual(takeback.gate(api, row()).reason, "claimant_is_track_artist")

    def test_request_no_longer_approved(self):
        api = FakeApi()
        api.request["status"] = "rejected"
        self.assertEqual(takeback.gate(api, row()).reason, "request_not_approved:rejected")

    def test_role_dropped_from_request(self):
        api = FakeApi()
        api.request["credits"] = ["Engineer"]
        self.assertEqual(takeback.gate(api, row()).reason, "role_not_on_request")

    def test_other_user(self):
        api = FakeApi()
        api.request["userId"] = 999
        self.assertEqual(takeback.gate(api, row()).reason, "user_mismatch")

    def test_already_gone(self):
        api = FakeApi()
        api.raws = [r for r in api.raws if r["profile"]["id"] != PID]
        self.assertEqual(takeback.gate(api, row()).reason, "claimant_credit_already_gone")

    def test_evidence_names_someone_no_longer_credited(self):
        self.assertEqual(takeback.gate(FakeApi(), row(displaced=["Somebody Else"])).reason,
                         "evidence_holder_changed")

    def test_read_error_never_passes(self):
        api = FakeApi()
        api.get = lambda *a, **k: (_ for _ in ()).throw(ApiError("boom"))
        self.assertEqual(takeback.gate(api, row()).reason, "read_error")

    def test_manifest_refuses_multi_person_roles(self):
        with tempfile.TemporaryDirectory() as d:
            path = write_manifest(Path(d), [row(role="Engineer", row_id=f"{RID}:Engineer")])
            with self.assertRaises(ValueError):
                takeback.load_manifest(path)


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.ledger = Ledger(self.dir / "state")
        self.manifest = write_manifest(self.dir, [row()])
        self.rows = takeback.load_manifest(self.manifest)
        self.out: list[str] = []

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def log(self, line):
        self.out.append(line)

    def test_plan_writes_nothing(self):
        api = FakeApi()
        _, counts = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        self.assertEqual(counts, {"would_remove": 1})
        self.assertEqual(api.writes, [])

    def test_apply_requires_a_matching_plan(self):
        api = FakeApi()
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run="nope", argv=[],
                           pause_s=0, approvals=api.approve(), log=self.log)
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        Path(self.manifest).write_text(Path(self.manifest).read_text() + "\n")  # bytes changed
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, argv=[],
                           pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(api.writes, [])

    def test_apply_removes_only_the_role_then_readback_then_revert(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(counts, {"removed": 1})
        method, path, body, headers = api.writes[0]
        self.assertEqual((method, path, body), ("DELETE", f"/admin/track/{TID}/profile/{PID}/credits",
                                                {"credits": ["Mixing"]}))
        self.assertIn("https://www.qobuz.com/x", headers["X-Removal-Approval-Ref"])
        # the Engineer role on the same request is untouched
        self.assertTrue(any(r["credit"] == "engineer" and r["profile"]["id"] == PID for r in api.raws))

        rb_id, rb = takeback.readback(api, self.ledger, apply_id, argv=[], log=self.log)
        self.assertEqual(rb, {"removed_trusted_intact": 1})

        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual(rep["removed"], 1)
        self.assertEqual(rep["server_refused_or_error"], [])
        self.assertEqual(rep["revert_command"].split()[-4:], ["revert", "--run", apply_id, "--login"])

        rv_id, rv = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv, {"re_added": 1})
        self.assertEqual(api.writes[-1][:3], ("POST", f"/admin/track/{TID}/profile/{PID}/credits",
                                              {"credits": ["Mixing"]}))
        _, rb2 = takeback.readback(api, self.ledger, rv_id, argv=[], log=self.log)
        self.assertEqual(rb2, {"re_added_live": 1})
        # a second revert re-adds nothing
        _, rv2 = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv2, {"already_reverted": 1})

    def test_apply_removes_only_rows_the_plan_showed_as_would_remove(self):
        api = FakeApi()
        good = api.raws
        api.raws = [raw("spotify", "Charles Fischer", "mixing engineer", "sp1"),
                    raw("muso", "Rishi Krishnan", "mixing", PID)]
        plan_id, counts = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        self.assertEqual(counts, {"skip:evidence_holder_changed": 1})
        api.raws = good  # the source changed after the plan: the live gate alone would now pass
        self.assertTrue(takeback.gate(api, row()).ok)
        _, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                   argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(counts, {})
        self.assertEqual(api.writes, [])

    def test_last_credit_on_track_is_recorded(self):
        api = FakeApi()
        api.raws = [r for r in api.raws if r["credit"] != "engineer"]
        plan_id, counts = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        self.assertEqual(counts, {"would_remove": 1, "would_remove_last_credit_on_track": 1})
        self.assertIn("last credit on track", self.out[-1])
        apply_id, _ = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                     argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(takeback.report(self.ledger, apply_id)["last_credit_on_track"], [f"{RID}:Mixing"])
        api2 = FakeApi()
        _, counts2 = takeback.plan(api2, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        self.assertEqual(counts2, {"would_remove": 1})

    def test_restore_re_adds_one_requests_roles(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        apply_id, _ = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                     argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        with self.assertRaises(SystemExit):
            takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, requests={"other"}, log=self.log)
        _, counts = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, requests={RID},
                                    ref="restore: valid proof conv 123", log=self.log)
        self.assertEqual(counts, {"re_added": 1})
        self.assertEqual(api.writes[-1][3]["X-Removal-Approval-Ref"], "restore: valid proof conv 123")

    def test_prepare_waves_counts_the_canary_removal_from_an_earlier_apply_run(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, argv=[],
                       only={f"{RID}:Mixing"}, pause_s=0, approvals=api.approve(), log=self.log)
        plan2, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        full_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan2,
                                         argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertNotIn("removed", counts)
        (self.dir / "pop.jsonl").write_text("")
        (self.dir / "w.jsonl").write_text("")
        for anchor in (full_id, None):
            run_id, _ = waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                                      watch_path=str(self.dir / "w.jsonl"), takeback_path=self.manifest,
                                      apply_run=anchor, out_root=self.dir / "waves", argv=[], actor="test",
                                      log=self.log)
            p = json.loads((self.dir / "waves" / run_id / "T-01" / f"user-{UID}.json").read_text())
            self.assertEqual([(c["kind"], c["role"]) for c in p["credits"]], [("takeback", "Mixing")])
            self.assertEqual(list((self.dir / "waves" / run_id).glob("W-*")), [])

    def test_server_refusal_is_recorded_and_stops(self):
        api = FakeApi()
        api.write_status = 403
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(counts["refused"], 1)
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual(rep["server_refused_or_error"][0]["reason"], "credit_removal_agent_refused")
        self.assertEqual(rep["removed"], 0)

    def test_apply_without_an_approved_set_removes_nothing(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, argv=[],
                           pause_s=0, approvals=[], log=self.log)
        self.assertEqual(api.writes, [])
        self.assertEqual(self.ledger.child_runs(plan_id, "apply"), [])
        # the CLI refuses before it asks for a password or opens the ledger
        proc = subprocess.run([sys.executable, str(CLI), "--state-dir", str(self.dir / "cli"), "apply",
                               "--plan", plan_id, "--yes-remove", "--login"],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, check=False)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("--approval", proc.stderr)
        self.assertFalse((self.dir / "cli").exists())

    def lost_response(self, api, *, reads_fail):
        """The server performs the DELETE, then the response is lost."""
        real_write, real_get = api.write, api.get

        def write(method, path, body, headers=None):
            real_write(method, path, body, headers)
            if method == "DELETE":
                if reads_fail:
                    api.get = lambda *a, **k: (_ for _ in ()).throw(ApiError("read timed out"))
                raise ApiError("DELETE: transport error timed out")
            return 200, {"result": "ok"}
        api.write = write
        return real_get

    def test_lost_delete_response_is_reconciled_live_and_revertible(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        self.lost_response(api, reads_fail=False)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(counts, {"removed": 1, "stopped_on_transport_error": 1})
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual((rep["removed"], rep["server_refused_or_error"], rep["unresolved"]), (1, [], []))
        _, rv = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv, {"re_added": 1})

    def test_unknown_delete_result_blocks_retry_revert_and_waves_until_reconciled(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        real_get = self.lost_response(api, reads_fail=True)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(counts, {"indeterminate": 1, "stopped_on_transport_error": 1})
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual((rep["removed"], rep["unresolved"]), (0, [f"{RID}:Mixing"]))
        with self.assertRaises(SystemExit):
            takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        (self.dir / "pop.jsonl").write_text("")
        (self.dir / "w.jsonl").write_text("")
        with self.assertRaises(SystemExit):
            waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                          watch_path=str(self.dir / "w.jsonl"), takeback_path=self.manifest, apply_run=None,
                          out_root=self.dir / "waves", argv=[], actor="test", log=self.log)
        api.get = real_get  # the admin API answers again: the role is gone, so the removal is recorded
        _, rv = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv, {"re_added": 1})
        self.assertEqual(takeback.report(self.ledger, apply_id)["removed"], 1)

    def test_lost_readd_response_is_recorded_and_never_reposted(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        apply_id, _ = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                     argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        real_write, real_get = api.write, api.get

        def lost(method, path, body, headers=None):
            real_write(method, path, body, headers)          # the server re-adds the credit
            api.get = lambda *a, **k: (_ for _ in ()).throw(ApiError("read timed out"))
            raise ApiError("POST: transport error timed out")  # ...and the response is lost
        api.write = lost
        _, rv = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv, {"indeterminate": 1, "stopped_on_transport_error": 1})
        posts = sum(1 for w in api.writes if w[0] == "POST")
        # unknown re-add: waves and a second revert refuse instead of treating the role as removed
        (self.dir / "pop.jsonl").write_text("")
        (self.dir / "w.jsonl").write_text("")
        with self.assertRaises(SystemExit):
            waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                          watch_path=str(self.dir / "w.jsonl"), takeback_path=self.manifest, apply_run=None,
                          out_root=self.dir / "waves", argv=[], actor="test", log=self.log)
        with self.assertRaises(SystemExit):
            takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        api.write, api.get = real_write, real_get  # the admin API answers: the credit is live again
        _, rv2 = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv2, {"already_reverted": 1})
        self.assertEqual(sum(1 for w in api.writes if w[0] == "POST"), posts)  # never POSTed twice
        self.assertEqual(self.ledger.reverted_row_ids(apply_id), {f"{RID}:Mixing"})

    def test_crash_after_sending_is_reconciled_by_the_next_apply(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        real_write = api.write

        def crash(method, path, body, headers=None):
            real_write(method, path, body, headers)
            raise KeyboardInterrupt  # killed after the server acted, before any response was handled
        api.write = crash
        with self.assertRaises(KeyboardInterrupt):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, argv=[],
                           pause_s=0, approvals=api.approve(), log=self.log)
        first = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        self.assertEqual(takeback.report(self.ledger, first)["unresolved"], [f"{RID}:Mixing"])
        api.write = real_write
        plan2, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        _, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan2,
                                   argv=[], pause_s=0, approvals=api.approve(), log=self.log)
        self.assertEqual(counts, {})  # the plan already skipped it as gone; nothing re-sent
        rep = takeback.report(self.ledger, first)
        self.assertEqual((rep["removed"], rep["unresolved"]), (1, []))

    def test_ledger_is_append_only(self):
        api = FakeApi()
        takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, argv=[], log=self.log)
        with self.assertRaises(sqlite3.DatabaseError):
            self.ledger.db.execute("UPDATE events SET outcome = 'x'")
        with self.assertRaises(sqlite3.DatabaseError):
            self.ledger.db.execute("DELETE FROM events")
        jsonl = list((self.dir / "state" / "runs").glob("plan-*.jsonl"))
        self.assertEqual(len(jsonl), 1)
        kinds = [json.loads(line)["type"] for line in jsonl[0].read_text().splitlines()]
        self.assertEqual(kinds, ["run_start", "event", "run_end"])


def jwt(claims):
    enc = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return f"h.{enc}.s"


class SessionTests(unittest.TestCase):
    def test_only_named_humans_with_fresh_sign_in(self):
        now = time.time()
        ok = {"email": "Nick@muso.ai", "authTime": int(now), "exp": int(now) + 3600}
        self.assertEqual(check_session_claims(ok, now=now), "nick@muso.ai")
        for bad in ({**ok, "email": "agent-hydra-main@muso.ai"}, {**ok, "impersonatedBy": 3},
                    {**ok, "authTime": None}, {**ok, "exp": int(now) + 60}):
            with self.assertRaises(ApiError):
                check_session_claims(bad, now=now)

    def test_session_api_refuses_agent_tokens_up_front(self):
        with self.assertRaises(ApiError):
            SessionApi(jwt({"email": "admin_u@muso.ai", "authTime": 1, "exp": time.time() + 3600}))

    def test_login_refuses_non_https_before_asking_for_the_password(self):
        with self.assertRaises(ApiError):
            SessionApi.login(email="nick@muso.ai", base="http://api.example", prompt=lambda _: self.fail("asked"),
                             ask=lambda _: self.fail("asked"), opener=lambda *a: self.fail("no network"))

    def test_session_api_only_deletes_and_posts(self):
        api = SessionApi(jwt({"email": "jan@muso.ai", "authTime": 1, "exp": time.time() + 3600}),
                         opener=lambda *a: self.fail("no network"))
        with self.assertRaises(ApiError):
            api.write("PUT", "/admin/credit-requests", {})

    def test_header_values_are_single_line_ascii_and_capped(self):
        v = header_value("a\nb — " + "x" * 400)
        self.assertNotIn("\n", v)
        self.assertTrue(v.isascii())
        self.assertLessEqual(len(v), 255)


class WaveTests(unittest.TestCase):
    def pop(self, uid, rid, pop, roles=("Producer",), paying=False, tier="HOLD"):
        return {"request_id": rid, "user_id": uid, "profile_id": f"p{uid}", "track_id": f"t{rid}",
                "track_title": "T", "artist": "A", "pop_now": pop, "paying": paying, "tier": tier,
                "sources": ["C"], "roles": [{"role": r, "verdict": "UNVERIFIABLE"} for r in roles]}

    def test_one_payload_per_user_grouped_friendly_no_removal(self):
        population = [self.pop("1", "r1", 80, roles=("Producer", "Mixing")), self.pop("1", "r2", 10),
                      self.pop("3", "r4", 90, roles=("Engineer",)), self.pop("9", "r9", 5)]
        watch = [{"user_id": "9", "profile_ids": ["p9"], "velocity_rows": 100, "first_request": "2026-10-01",
                  "max_requests_per_day": 200, "example_tracks": [], "paying": True}]
        removed = [row(user_id="3", request_id="r4", row_id="r4:Mixing")]
        ps = {p["user"]["id"]: p for p in waves.assemble(population, watch, removed)}
        self.assertEqual(len(ps), 3)
        self.assertEqual(ps["3"]["wave"], "T-01")
        self.assertEqual(ps["3"]["template"], "takeback-mixing-mastering")
        self.assertEqual([c["kind"] for c in ps["3"]["credits"]], ["takeback", "verify"])
        # velocity account with a HOLD row: one message, carrying the account ask as a section
        self.assertEqual([a["kind"] for a in ps["9"]["account_asks"]], ["velocity"])
        self.assertTrue(ps["9"]["paying"])
        self.assertEqual([g["group"] for g in ps["1"]["groups"]], ["mixing-mastering", "producer"])
        self.assertEqual(ps["1"]["credits_total"], 3)
        p = ps["1"]
        self.assertEqual((p["send_not_before"], p["follow_up_on"], p["flag_unverified_after"]),
                         ("2026-10-16", "2026-10-30", "2026-11-15"))
        # captain 2026-10-16 ~00:35Z: past credits get a friendly ask, never a removal threat
        for x in ps.values():
            self.assertEqual(x["status"], "prepared_not_sent")
            self.assertTrue(x["credits_stay_visible"])
            self.assertFalse(x["removal_threat"] or x["deadline_language"])
            self.assertIn("never removed", x["on_silence"])
            self.assertNotIn("removal_on", x)
            self.assertNotIn("reply_by", x)
            self.assertEqual(x["send_campaign"], "retro-past")

    def test_paid_first_then_big_tracks(self):
        population = [self.pop("free_big", "r1", 95), self.pop("paid_small", "r2", 3, paying=True),
                      self.pop("paid_big", "r3", 70, paying=True), self.pop("free_mid", "r4", 40)]
        order = [p["user"]["id"] for p in sorted(waves.assemble(population, [], [], per_day=1),
                                                  key=lambda p: p["wave"])]
        self.assertEqual(order, ["paid_big", "paid_small", "free_big", "free_mid"])

    def test_cap_keeps_biggest_tracks(self):
        population = [self.pop("1", f"r{i:04d}", i % 100) for i in range(250)]
        p = waves.assemble(population, [], [])[0]
        self.assertEqual((p["credits_total"], len(p["credits"]), p["more_credits"]), (250, 200, 50))
        self.assertEqual(len(p["request_ids_all"]), 250)
        self.assertEqual(p["credits"][0]["pop_now"], 99)

    def test_unremoved_takeback_rows_join_population(self):
        tb = [row(), row(role="Mastering", row_id=f"{RID}:Mastering")]
        merged = waves.merge_unremoved([], tb, {f"{RID}:Mixing"})
        self.assertEqual([x["role"] for x in merged[0]["roles"]], ["Mastering"])
        self.assertEqual(waves.merge_unremoved([], [row(user_id="15")], set()), [])


class AskSelectionTests(unittest.TestCase):
    """Firstmate 006: ask only genuine risk; everyone else is left alone."""

    def row(self, uid, rid, tier, pop=10, roles=("Producer",)):
        return {"request_id": rid, "user_id": uid, "profile_id": f"p{uid}", "track_id": f"t{rid}",
                "track_title": "T", "artist": "A", "pop_now": pop, "paying": False, "tier": tier, "sources": ["C"],
                "roles": [{"role": r, "verdict": "UNVERIFIABLE"} for r in roles]}

    def test_small_unverifiable_and_ordinary_accounts_are_not_asked(self):
        population = [self.row("1", "r1", "KEEP_unverifiable_small"), self.row("2", "r2", "WATCH_big_unverifiable"),
                      self.row("3", "r3", "HOLD"), self.row("4", "r4", "A_HOLD")]
        asked, accounts, not_asked = waves.select(population, [], None)
        self.assertEqual({h["user_id"] for h in asked}, {"3", "4"})
        self.assertEqual({h["user_id"] for h in not_asked}, {"1", "2"})
        self.assertEqual(accounts, {})

    def test_editing_rows_contradicted_or_mid_big_only(self):
        population = [self.row("5", "e1", "EDITING_LOOSE", pop=5, roles=("Editorial",)),
                      self.row("5", "e2", "EDITING_LOOSE", pop=45, roles=("Assembly",)),
                      self.row("6", "e3", "EDITING_LOOSE", pop=5, roles=("Editorial",)),
                      self.row("7", "e4", "KEEP_unverifiable_small", pop=50, roles=("Editorial", "Producer"))]
        ask = {"accounts": [], "rows": [
            {"request_id": "e1", "user_id": "5", "pop_now": 5, "verdict": "UNVERIFIABLE"},
            {"request_id": "e2", "user_id": "5", "pop_now": 45, "verdict": "UNVERIFIABLE"},
            {"request_id": "e3", "user_id": "6", "pop_now": 5, "verdict": "CONTRADICTED"},
            {"request_id": "e4", "user_id": "7", "pop_now": 50, "verdict": "UNVERIFIABLE"}]}
        asked, _, not_asked = waves.select(population, [], ask)
        self.assertEqual(sorted(h["request_id"] for h in asked), ["e2", "e3", "e4"])
        e4 = next(h for h in asked if h["request_id"] == "e4")
        self.assertEqual([x["role"] for x in e4["roles"]], ["Editorial"])   # the editing role only
        self.assertIn("e1", {h["request_id"] for h in not_asked})
        asked60, _, _ = waves.select(population, [], ask, editing_min_pop=60)
        self.assertEqual([h["request_id"] for h in asked60], ["e3"])

    def test_burst_account_gets_one_ask_not_a_row_list(self):
        population = [self.row("8", f"b{i}", "EDITING_LOOSE", pop=50, roles=("Editorial",)) for i in range(5)]
        ask = {"accounts": [
            {"user_id": "8", "ask": True, "editing_rows": 5, "peak_per_day": 50, "first": "2024-01-01",
             "profile_ids": ["p8"], "review": {"UNVERIFIABLE": 8}, "paying": False,
             "example_tracks": [{"request_id": "b0", "track_id": "t", "role": "Editorial", "track_title": "X",
                                 "artist": "Y", "pop_now": 50}]},
            {"user_id": "9", "ask": False, "editing_rows": 99, "peak_per_day": 99, "first": "2024-01-01",
             "profile_ids": ["p9"], "review": {"CONFIRMED": 8}, "paying": False, "example_tracks": []}],
            "rows": [{"request_id": f"b{i}", "user_id": "8", "pop_now": 50, "verdict": "UNVERIFIABLE"}
                     for i in range(5)]}
        ps = waves.assemble(population, [], [], ask)
        self.assertEqual(len(ps), 1)
        self.assertEqual((ps[0]["template"], ps[0]["credits_total"]), ("account-three-tracks", 0))
        self.assertEqual([a["kind"] for a in ps[0]["account_asks"]], ["editing_burst"])

    def test_never_reask_proof_senders_and_at_most_one_message(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = str(Path(d) / "v.sqlite3")
            db = sqlite3.connect(db_path)
            db.execute("CREATE TABLE verify_messages (campaign TEXT, kind TEXT, status TEXT, user_key TEXT, "
                       "request_ids_json TEXT, proof_tagged_at TEXT)")
            db.execute("INSERT INTO verify_messages VALUES ('verify-live','initial','sent','a@x.com','[\"r1\"]',"
                       "'2026-10-10')")
            db.execute("INSERT INTO verify_messages VALUES ('retro-past','initial','sent','b@x.com','[\"r2\"]',NULL)")
            db.execute("INSERT INTO verify_messages VALUES ('verify-live','initial','sent','c@x.com','[\"r3\"]',NULL)")
            db.commit()
            db.close()
            ids, proof_users, asked_users = waves.already_engaged(db_path)
        self.assertEqual((ids, proof_users, asked_users), ({"r1"}, {"a@x.com"}, {"b@x.com"}))

    def test_prepare_writes_internal_flags_for_everyone_not_asked(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            pop_path = d / "pop.jsonl"
            pop_path.write_text("".join(json.dumps(r) + "\n" for r in (
                self.row("1", "r1", "KEEP_unverifiable_small"), self.row("3", "r3", "HOLD"))))
            (d / "w.jsonl").write_text("")
            (d / "tb.jsonl").write_text("")
            ledger = Ledger(d / "state")
            run_id, index = waves.prepare(ledger, population_path=str(pop_path), watch_path=str(d / "w.jsonl"),
                                          takeback_path=str(d / "tb.jsonl"), apply_run=None, out_root=d / "waves",
                                          argv=[], actor="test", log=lambda *_: None)
            ledger.close()
            flags = [json.loads(x) for x in (d / "waves" / run_id / "unverified-internal.jsonl").read_text().splitlines()]
        self.assertEqual([f["request_id"] for f in flags], ["r1"])
        self.assertEqual(index["not_asked_flagged_internal_users"], 1)

    def test_missing_send_ledger_never_fails_open(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            pop_path = d / "pop.jsonl"
            pop_path.write_text(json.dumps(self.row("3", "r3", "HOLD")) + "\n")
            (d / "w.jsonl").write_text("")
            (d / "tb.jsonl").write_text("")
            ledger = Ledger(d / "state")
            run_id, index = waves.prepare(ledger, population_path=str(pop_path), watch_path=str(d / "w.jsonl"),
                                          takeback_path=str(d / "tb.jsonl"), apply_run=None, out_root=d / "waves",
                                          argv=[], actor="test", verify_db=str(d / "absent.sqlite3"),
                                          log=lambda *_: None)
            ledger.close()
            payload = json.loads(next((d / "waves" / run_id).glob("*/user-3.json")).read_text())
        self.assertIsNone(waves.already_engaged(str(d / "absent.sqlite3")))
        self.assertEqual(payload["status"], "send_ledger_unavailable")
        self.assertTrue(index["send_ledger"].startswith("UNAVAILABLE"))
        self.assertEqual(sum(w["not_sendable"] for w in index["waves"].values()), 1)

    def test_live_read_error_makes_the_payload_not_sendable(self):
        class DownApi:
            actor = "agent-read-only"

            def get(self, path, params=None):
                raise ApiError("credit-requests: transport error timed out")

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            pop_path = d / "pop.jsonl"
            pop_path.write_text(json.dumps(self.row("3", "r3", "HOLD")) + "\n")
            (d / "w.jsonl").write_text("")
            (d / "tb.jsonl").write_text("")
            ledger = Ledger(d / "state")
            run_id, index = waves.prepare(ledger, population_path=str(pop_path), watch_path=str(d / "w.jsonl"),
                                          takeback_path=str(d / "tb.jsonl"), apply_run=None, out_root=d / "waves",
                                          argv=[], actor="test", api=DownApi(), log=lambda *_: None)
            counts = json.loads(ledger.run_end(run_id)["counts_json"])
            ledger.close()
            p = json.loads(next((d / "waves" / run_id).glob("W-*/user-3.json")).read_text())
        self.assertEqual(p["status"], "live_read_error")
        self.assertEqual(counts["sendable_users"], 0)
        self.assertEqual(index["waves"]["W-01"]["not_sendable"], 1)


class ApprovalTests(unittest.TestCase):
    """Core-backend #10597: stage once, Nick/Jan approve once, apply only what was approved."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.ledger = Ledger(self.dir / "state")
        self.manifest = write_manifest(self.dir, [row()])
        self.rows = takeback.load_manifest(self.manifest)
        self.api = FakeApi()
        self.plan_id, _ = takeback.plan(self.api, self.ledger, self.rows, manifest=self.manifest, argv=[],
                                        log=lambda *_: None)

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def test_stage_posts_one_set_with_the_evidence(self):
        _, out = takeback.stage(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                                argv=[], log=lambda *_: None)
        self.assertEqual(out["approval_ids"], ["ap-1"])
        method, path, body, _ = self.api.writes[0]
        self.assertEqual((method, path), ("POST", "/admin/credit-removals"))
        self.assertEqual(body["pairs"], [{"profileId": PID, "trackId": TID, "roles": ["Mixing"]}])
        self.assertIn(f"[{PID[:8]}/{TID[:8]}/Mixing] https://www.qobuz.com/x", body["reason"])
        self.assertLessEqual(len(body["reason"]), 2000)

    def test_evidence_never_truncated_sets_split_instead(self):
        rows = [row(row_id=f"r{i}:Mixing", request_id=f"r{i}", profile_id=f"{i:08d}-p", track_id=f"{i:08d}-t",
                    evidence_url="https://www.qobuz.com/" + "x" * 150) for i in range(30)]
        chunks = takeback.chunk_for_reasons(rows, "h" * 300)
        self.assertGreater(len(chunks), 1)
        self.assertEqual(sum(len(c) for c in chunks), 30)
        for c in chunks:
            self.assertLessEqual(300 + sum(len(takeback.evidence_line(r)) + 2 for r in c), 2000)

    def test_apply_refuses_until_approved_then_only_covered_pairs(self):
        takeback.stage(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                       argv=[], log=lambda *_: None)
        with self.assertRaises(SystemExit):
            takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                           argv=[], pause_s=0, approvals=["ap-1"], log=lambda *_: None)
        self.api.approval["status"] = "approved"
        apply_id, counts = takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest,
                                          plan_run=self.plan_id, argv=[], pause_s=0, approvals=["ap-1"],
                                          log=lambda *_: None)
        self.assertEqual(counts, {"removed": 1})
        self.assertTrue(self.api.writes[-1][3]["X-Removal-Approval-Ref"].startswith(
            "approval ap-1 | https://www.qobuz.com/x"))
        removed = self.ledger.events(apply_id, "remove")
        self.assertTrue(removed[0]["approval_ref"].startswith(f"credit-removal-approval ap-1 | {takeback.DECISION_REF}"))

    def test_row_outside_the_approval_is_skipped(self):
        takeback.stage(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                       argv=[], log=lambda *_: None)
        self.api.approval.update(status="approved", pairs=[])
        _, counts = takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                                   argv=[], pause_s=0, approvals=["ap-1"], log=lambda *_: None)
        self.assertEqual(counts, {"skip:not_in_approval": 1})

    def test_agent_wrapper_may_only_stage(self):
        from credit_retro.api import WrapperReadApi
        w = WrapperReadApi.__new__(WrapperReadApi)
        with self.assertRaises(ApiError):
            w.write("DELETE", f"/admin/track/{TID}/profile/{PID}/credits", {})


class ManifestTests(unittest.TestCase):
    """The committed manifests honour the decisions they encode."""

    def test_takeback_manifest(self):
        rows = takeback.load_manifest(MANIFEST_DIR / "takeback-r1.jsonl")
        self.assertEqual(len(rows), 40)
        self.assertEqual(len({r["request_id"] for r in rows}), 40)
        self.assertEqual(len({r["user_id"] for r in rows}), 21)
        self.assertFalse(any(r["user_id"] == "15" for r in rows))
        for r in rows:
            self.assertTrue(r["evidence_url"].startswith("https://"), r["row_id"])
            self.assertNotIn("muso.ai", r["evidence_url"])
            self.assertEqual(r["web"]["verdict"], "CONTRADICTED")
            # the cited web check read THIS role's credit, not a sibling role's on the same track
            self.assertEqual((r["web"]["scope"], r["web"]["role_checked"]), ("role", r["role"]), r["row_id"])
            # the server caps the logged header at 255: the approval id and the URL always survive it
            ref = header_value(takeback.header_ref(r, "00000000-0000-4000-8000-000000000000"))
            self.assertIn(r["evidence_url"], ref, r["row_id"])

    def test_population_and_watch_manifests(self):
        population = waves.load_jsonl(MANIFEST_DIR / "population-r1.jsonl.gz")
        watch = waves.load_jsonl(MANIFEST_DIR / "watch-velocity-r1.jsonl")
        self.assertFalse(any(h["user_id"] == "15" for h in population))
        tiers = {}
        for h in population:
            tiers[h["tier"]] = tiers.get(h["tier"], 0) + 1
        # captain 23:35Z: HOLD 1,281 + velocity 1,283 + big-unverifiable 63 + small-unverifiable 13,242,
        # plus Part A HOLD 45 and the 36 take-back requests' unproven roles (tier HOLD)
        self.assertEqual(tiers, {"HOLD": 1281 + 36, "WATCH_velocity": 1283, "WATCH_big_unverifiable": 63,
                                 "KEEP_unverifiable_small": 13242, "A_HOLD": 45, "EDITING_LOOSE": 11861})
        # captain ~23:42Z: every loose-path / agent-batch editing claim (Editorial, Assembly) too
        editing = [h for h in population if "E" in h["sources"]]
        self.assertEqual((len(editing), len({h["user_id"] for h in editing})), (11929, 233))
        for h in editing:
            if h["tier"] == "EDITING_LOOSE":
                self.assertTrue({x["role"] for x in h["roles"]} <= {"Editorial", "Assembly"})
        self.assertEqual(len(watch), 9)
        with open(MANIFEST_DIR / "editing-ask-r1.json", encoding="utf-8") as fh:
            editing_ask = json.load(fh)
        self.assertEqual((len(editing_ask["accounts"]), sum(a["ask"] for a in editing_ask["accounts"])), (29, 27))
        # firstmate 006 target: genuine risk only, a few hundred users, not 2,305
        payloads = waves.assemble(population, watch, [], editing_ask)
        self.assertLess(len(payloads), 450)
        # a small unverifiable claim is only ever asked for its editing role (high-risk family)
        for h in waves.select(population, watch, editing_ask)[0]:
            if h["tier"] == "KEEP_unverifiable_small":
                self.assertTrue({x["role"] for x in h["roles"]} <= waves.EDITING_ROLES)
        proven = {r["row_id"] for r in takeback.load_manifest(MANIFEST_DIR / "takeback-r1.jsonl")}
        for h in population:
            for x in h["roles"]:
                self.assertNotIn(f"{h['request_id']}:{x['role']}", proven)
        self.assertEqual(sum(len(h["roles"]) for h in population if h.get("takeback_residual")), 138)


if __name__ == "__main__":
    unittest.main(verbosity=1)
