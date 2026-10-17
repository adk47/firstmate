#!/usr/bin/env python3
"""Unit tests for scripts/credit_retro (role-scoped credit take-back + waves).

Stdlib unittest, no network: the admin API is faked. Run:
    python3 scripts/tests/test_credit_retro.py
"""

from __future__ import annotations

import base64
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_retro import notice, takeback, waves  # noqa: E402
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
    base.setdefault("evidence", {"verified": "public_page", "url": base["evidence_url"], "names": ["Eli WTF"],
                                 "sources": ["tidal"], "note": "Qobuz credits \"Eli WTF, Mixer\""})
    return base


class FakeSender:
    """Caroline's gate: validates and sends the take-back notice (recorded, never posted)."""

    approved_by = "U0TESTAPPR"

    def __init__(self, verdict="valid", outcome="sent"):
        self.verdict, self.outcome = verdict, outcome
        self.validated: list[dict] = []
        self.sent: list[dict] = []

    def validate(self, payload):
        self.validated.append(payload)
        return self.verdict, {"valid": "VALID", "deferred": "DEFERRED daily-cap"}.get(
            self.verdict, "campaign takeback-notice unknown")

    def send(self, payload):
        self.sent.append(payload)
        return self.outcome, "message 123"


def raw(source, name, role, pid="x"):
    return {"profile": {"source": source, "name": name, "id": pid}, "credit": role}


class FakeApi:
    """In-memory admin API: one request, raw credits per track, profiles."""

    actor = "nick@muso.ai"

    def __init__(self):
        self.request = {"id": RID, "status": "approved", "userId": int(UID), "profileId": PID, "trackId": TID,
                        "credits": ["Mixing", "Engineer"], "updatedAt": "2026-09-02T00:11:21Z",
                        "spotifyTrackArtists": [{"id": ARTIST_PID, "name": "k3"}],
                        "user": {"id": int(UID), "email": "rk@example.com", "fullName": "Rishi Krishnan"}}
        self.sender = FakeSender()
        self.raws = [raw("spotify", "Eli WTF", "mixing engineer", "sp1"), raw("tidal", "Eli WTF", "mixer", "td1"),
                     raw("muso", "Rishi Krishnan", "mixing", PID), raw("muso", "Rishi Krishnan", "engineer", PID)]
        self.profile = {"name": "Rishi Krishnan", "rawProfiles": []}
        self.writes: list[tuple] = []
        self.write_status = 200

    def get(self, path, params=None):
        params = params or {}
        if path == "/admin/credit-requests":
            mine = params.get("trackId") == TID or PID in str(params.get("profilesIds") or "").split(",")
            return {"items": [self.request] if mine and params.get("page", 1) == 1 else []}
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

    def approve(self, pairs=None):
        """Nick/Jan approved a set covering the row's pair (#10633 stamps each pair's decision)."""
        self.approval = {"id": "ap-1", "status": "approved", "expiresAt": None,
                         "pairs": pairs or [{"id": "1", "profileId": PID, "trackId": TID, "role": "mixing",
                                             "decision": "approved", "consumedAt": None}]}
        return ["ap-1"]

    def execute(self):
        """core #10638: spend every approved, unconsumed pair; remove the role; per-pair results."""
        results = []
        for p in self.approval["pairs"]:
            base = {k: p[k] for k in ("profileId", "trackId", "role")} | {"pairId": p["id"]}
            if p.get("decision") != "approved":
                results.append(base | {"status": "not_approved"})
            elif p.get("consumedAt"):
                results.append(base | {"status": "already_executed"})
            else:
                p["consumedAt"] = "2026-10-17T04:00:00Z"
                self.raws = [r for r in self.raws if not (r["profile"]["id"] == p["profileId"]
                                                           and r["credit"] == p["role"])]
                results.append(base | {"status": "removed", "removalEventId": "9"})
        return {"id": self.approval["id"], "ok": True, "results": results}

    def write(self, method, path, body, headers=None):
        self.writes.append((method, path, body, headers))
        if path == "/admin/credit-removals":
            self.approval = {"id": "ap-1", "status": "pending", "expiresAt": None,
                             "pairs": [{"id": str(n), "profileId": p["profileId"], "trackId": p["trackId"],
                                        "role": r.lower(), "decision": None, "consumedAt": None}
                                       for n, (p, r) in enumerate(((p, r) for p in body["pairs"]
                                                                   for r in p["roles"]), 1)]}
            return 201, {"result": "ok", "data": {"id": "ap-1", "status": "pending"}}
        if self.write_status >= 300:
            return self.write_status, {"result": "error", "errorCode": "credit_removal_agent_refused"}
        if path.endswith("/execute"):
            return 200, {"result": "ok", "data": self.execute()}
        role = body["credits"][0].lower()
        self.raws.append(raw("muso", "Rishi Krishnan", role, PID))
        return 200, {"result": "ok"}


def cli_apply(api, state_dir, manifest, plan_id) -> tuple[int, str]:
    """Run ``credit-retro.py apply`` in-process with ``api`` as the human's session and its FakeSender
    as Caroline's gate. Returns (exit code, stderr)."""
    import contextlib  # noqa: PLC0415
    import importlib.util  # noqa: PLC0415
    import io  # noqa: PLC0415
    from unittest import mock  # noqa: PLC0415
    spec = importlib.util.spec_from_file_location("credit_retro_cli", CLI)
    cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cli)
    live = Path(_LIVE_DIR.name)
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(cli, "session_api", lambda args: api), \
            mock.patch.object(notice, "ScriptSender", lambda *a, **k: api.sender), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.main(["--state-dir", str(state_dir), "apply", "--manifest", manifest, "--plan", plan_id,
                       "--approval", "ap-1", "--yes-remove", "--notice-approved-by", "U0TESTAPPR",
                       "--proof-on-file", str(live / "proof-on-file.json"),
                       "--org-affiliation", str(live / "org-affiliation.json"),
                       "--verify-ledger", str(live / "verify.sqlite3")])
    return rc, err.getvalue()


def write_manifest(tmp: Path, rows) -> str:
    p = tmp / "takeback.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return str(p)


def live_sources(tmp: Path, *, proof_entries=(), age=timedelta(0), stale_source=False, affiliation=None,
                 tagged=(), affiliation_file=True):
    """Write the live exclusion sources (credit-trust proof-on-file + org-affiliation, Caroline's
    send ledger) and load them through the real loader."""
    tmp.mkdir(parents=True, exist_ok=True)
    proof = tmp / "proof-on-file.json"
    proof.write_text(json.dumps({
        "generated_at": (datetime.now(timezone.utc) - age).isoformat().replace("+00:00", "Z"),
        "sources": [{"name": "intercom", "stale": stale_source, "age_hours": 0.5},
                    {"name": "verifications", "stale": False, "age_hours": 0.2}],
        "entries": list(proof_entries)}))
    aff = tmp / "org-affiliation.json"
    if affiliation_file:
        aff.write_text(json.dumps(affiliation if affiliation is not None else
                                  {UID: {"verdict": "none", "evidence": []},
                                   "161128": {"verdict": "none", "evidence": []}}))
    db_path = tmp / "verify.sqlite3"
    db = sqlite3.connect(db_path)
    db.execute("CREATE TABLE IF NOT EXISTS verify_messages (campaign TEXT, kind TEXT, status TEXT, user_key TEXT, "
               "request_ids_json TEXT, proof_tagged_at TEXT)")
    db.executemany("INSERT INTO verify_messages VALUES (?,?,?,?,?,?)", tagged)
    db.commit()
    db.close()
    return takeback.load_exclusions(proof_on_file=str(proof), org_affiliation=str(aff), verify_db=str(db_path))


_LIVE_DIR = tempfile.TemporaryDirectory()
OPEN = live_sources(Path(_LIVE_DIR.name))


class GateTests(unittest.TestCase):
    def test_pass_when_trusted_sources_credit_someone_else(self):
        res = takeback.gate(FakeApi(), row(), OPEN)
        self.assertTrue(res.ok, res.reason)
        self.assertEqual({h["name"] for h in res.before["trusted_holders"]}, {"Eli WTF"})

    def test_user_15_is_never_touched(self):
        api = FakeApi()
        self.assertEqual(takeback.gate(api, row(user_id="15"), OPEN).reason, "excluded_user")

    def test_confirmed_by_trusted_source_is_kept(self):
        # archiesarchiesarchies / yungpidi808 class: Spotify and Tidal credit the claimant too.
        api = FakeApi()
        api.raws.append(raw("spotify", "Rishi Krishnan", "mixing engineer", "sp9"))
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "not_contradicted_live:CONFIRMED")

    def test_only_a_muso_claim_by_someone_else_is_not_proof(self):
        # Chris Doss class: the other "holder" is another user's Muso claim, no trusted source.
        api = FakeApi()
        api.raws = [raw("muso", "Jay Baumgardner", "mixing", "jay"), raw("muso", "Rishi Krishnan", "mixing", PID)]
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "not_contradicted_live:UNVERIFIABLE")

    def test_alias_by_known_as_name_is_kept(self):
        api = FakeApi()
        api.profile["knownAsNames"] = ["Eli WTF"]
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "not_contradicted_live:CONFIRMED")

    def test_claimant_named_like_track_artist_is_skipped(self):
        api = FakeApi()
        api.profile["name"] = "k3"
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "claimant_is_track_artist")

    def test_claimant_profile_is_track_artist_is_skipped(self):
        api = FakeApi()
        api.request["spotifyTrackArtists"] = [{"id": PID, "name": "x"}]
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "claimant_is_track_artist")

    def test_request_no_longer_approved(self):
        api = FakeApi()
        api.request["status"] = "rejected"
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "request_not_approved:rejected")

    def test_role_dropped_from_request(self):
        api = FakeApi()
        api.request["credits"] = ["Engineer"]
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "role_not_on_request")

    def test_other_user(self):
        api = FakeApi()
        api.request["userId"] = 999
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "user_mismatch")

    def test_already_gone(self):
        api = FakeApi()
        api.raws = [r for r in api.raws if r["profile"]["id"] != PID]
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "claimant_credit_already_gone")

    def test_evidence_names_someone_no_longer_credited(self):
        ev = {"verified": "public_page", "url": "https://www.qobuz.com/x", "names": ["Somebody Else"],
              "note": "Qobuz credits \"Somebody Else, Mixer\""}
        self.assertEqual(takeback.gate(FakeApi(), row(evidence=ev), OPEN).reason, "evidence_holder_changed")

    def test_read_error_never_passes(self):
        api = FakeApi()
        api.get = lambda *a, **k: (_ for _ in ()).throw(ApiError("boom"))
        self.assertEqual(takeback.gate(api, row(), OPEN).reason, "read_error")

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
        _, counts = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        self.assertEqual(counts, {"would_remove": 1})
        self.assertEqual(api.writes, [])

    def test_apply_requires_a_matching_plan(self):
        api = FakeApi()
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run="nope", excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        Path(self.manifest).write_text(Path(self.manifest).read_text() + "\n")  # bytes changed
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(api.writes, [])

    def test_apply_removes_only_the_role_then_readback_then_revert(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(counts, {"removed": 1, "notice_sent": 1})
        # core #10638: the human's session executes the approved set; the tool never DELETEs itself
        self.assertEqual([w[:3] for w in api.writes], [("POST", "/admin/credit-removals/ap-1/execute", {})])
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
        plan_id, counts = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        self.assertEqual(counts, {"skip:evidence_holder_changed": 1})
        api.raws = good  # the source changed after the plan: the live gate alone would now pass
        self.assertTrue(takeback.gate(api, row(), OPEN).ok)
        api.approve()
        rc, err = cli_apply(api, self.dir / "state", self.manifest, plan_id)
        # the approved set holds a pair the plan never showed as would_remove: the WHOLE set is withheld,
        # the pair is recorded, and the CLI exits 3 so Nick or Jan decides
        self.assertEqual((rc, api.writes), (3, []))
        self.assertIn("WITHHELD", err)
        apply_id = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual(rep["counts"], {"withheld_sets": 1, "withheld:pair_not_in_plan": 1})
        self.assertEqual(rep["withheld"], [{"row_id": f"pair:{PID}/{TID}/mixing", "user_id": None,
                                            "reason": "pair_not_in_plan", "approval": "credit-removal-approval ap-1"}])

    def test_last_credit_on_track_is_recorded(self):
        api = FakeApi()
        api.raws = [r for r in api.raws if r["credit"] != "engineer"]
        plan_id, counts = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        self.assertEqual(counts, {"would_remove": 1, "would_remove_last_credit_on_track": 1})
        self.assertIn("last credit on track", self.out[-1])
        apply_id, _ = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                     excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(takeback.report(self.ledger, apply_id)["last_credit_on_track"], [f"{RID}:Mixing"])
        api2 = FakeApi()
        _, counts2 = takeback.plan(api2, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        self.assertEqual(counts2, {"would_remove": 1})

    def test_restore_re_adds_one_requests_roles(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        apply_id, _ = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                     excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        with self.assertRaises(SystemExit):
            takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, requests={"other"}, log=self.log)
        _, counts = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, requests={RID},
                                    ref="restore: valid proof conv 123", log=self.log)
        self.assertEqual(counts, {"re_added": 1})
        self.assertEqual(api.writes[-1][3]["X-Removal-Approval-Ref"], "restore: valid proof conv 123")

    def test_takeback_notice_is_the_removed_users_only_message_for_30_days(self):
        # firstmate 016, user 161128's sequence: apply removes the Mixing role and the notice goes
        # out; prepare-waves --apply-run then has nothing for them until 30 days after the notice
        uid = "161128"
        manifest = write_manifest(self.dir, [row(user_id=uid)])
        rows = takeback.load_manifest(manifest)
        api = FakeApi()
        api.request["userId"] = api.request["user"]["id"] = int(uid)
        plan_id, _ = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=OPEN, argv=[], log=self.log)
        apply_id, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                          pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(counts, {"removed": 1, "notice_sent": 1})
        other = {"request_id": "r-luna", "user_id": uid, "profile_id": PID, "track_id": "t-luna",
                 "track_title": "Luna", "artist": "Manuel Medrano", "pop_now": 36, "paying": False, "tier": "HOLD",
                 "sources": ["C"], "roles": [{"role": "Producer", "verdict": "UNVERIFIABLE"}]}
        (self.dir / "pop.jsonl").write_text(json.dumps(other) + "\n")
        (self.dir / "w.jsonl").write_text("")
        now = datetime.now(timezone.utc)

        def prepared(after):
            run_id, _ = waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                                      watch_path=str(self.dir / "w.jsonl"), takeback_path=manifest,
                                      apply_run=apply_id, out_root=self.dir / "waves", argv=[], actor="test",
                                      now=now + after, log=self.log)
            return [json.loads(f.read_text()) for f in (self.dir / "waves" / run_id).glob("*/user-*.json")]

        self.assertEqual(prepared(timedelta(0)), [])
        self.assertEqual(prepared(timedelta(days=29)), [])
        later = prepared(timedelta(days=30, hours=1))
        self.assertEqual([p["user"]["id"] for p in later], [uid])
        # the ask covers their other credits only: the removal is never restated
        self.assertEqual([(c["kind"], c["role"]) for c in later[0]["credits"]], [("verify", "Producer")])
        self.assertNotIn("takeback_credits", later[0])

    def test_a_role_removed_by_an_earlier_apply_run_is_never_asked_again(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        # canary: one user's set executed first (one set per user, firstmate 026)
        takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
                       pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        plan2, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        # the same set again: its pair is consumed, so execute spends nothing
        full_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan2,
                                         excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"], sender=api.sender, log=self.log)
        self.assertNotIn("removed", counts)
        hold = {"request_id": RID, "user_id": UID, "profile_id": PID, "track_id": TID, "track_title": "Lemonade",
                "artist": "k3", "pop_now": 35, "paying": False, "tier": "HOLD", "sources": ["C"],
                "roles": [{"role": "Engineer", "verdict": "UNVERIFIABLE"}]}
        (self.dir / "pop.jsonl").write_text(json.dumps(hold) + "\n")
        (self.dir / "w.jsonl").write_text("")
        later = datetime.now(timezone.utc) + timedelta(days=31)
        for anchor in (full_id, None):
            run_id, _ = waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                                      watch_path=str(self.dir / "w.jsonl"), takeback_path=self.manifest,
                                      apply_run=anchor, out_root=self.dir / "waves", argv=[], actor="test",
                                      now=later, log=self.log)
            p = json.loads((self.dir / "waves" / run_id / "W-01" / f"user-{UID}.json").read_text())
            # the canary removed Mixing; only the other role is ever asked about
            self.assertEqual([(c["kind"], c["role"]) for c in p["credits"]], [("verify", "Engineer")])

    def verify_db(self, rows=()):
        path = self.dir / "verify.sqlite3"
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE IF NOT EXISTS verify_messages (campaign TEXT, kind TEXT, status TEXT, "
                   "user_key TEXT, request_ids_json TEXT, proof_tagged_at TEXT)")
        db.executemany("INSERT INTO verify_messages VALUES (?,?,?,?,?,?)", rows)
        db.commit()
        db.close()
        return str(path)

    def doc_list(self, generated_at, users=(), requests=()):
        """A doc-submitted list as rebuilt before a send (``generated_at`` None: no stamp)."""
        path = self.dir / f"doc-fresh-{len(list(self.dir.glob('doc-fresh-*.json')))}.json"  # one file per list
        doc = {"users_doc_submitted": list(users), "human_approved_requests": list(requests)}
        if generated_at is not None:
            doc["generated_at"] = generated_at.strftime("%Y-%m-%dT%H:%M:%SZ")
        path.write_text(json.dumps(doc))
        return str(path)

    def test_send_check_drops_a_payload_prepared_before_a_later_takeback(self):
        # firstmate 018: day 1 the notice would defer, so X keeps the role and is put in a wave
        # (the role joins the verify ask); day 2 a later apply removes it and sends the notice;
        # the prepared payload must not reach X inside the 30-day quiet window
        api = FakeApi()
        db = self.verify_db()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        api.sender.verdict = "deferred"
        _, day1 = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                 pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(day1, {"withheld:notice_would_defer": 1, "withheld_sets": 1})
        hold = {"request_id": RID, "user_id": UID, "profile_id": PID, "track_id": TID, "track_title": "Lemonade",
                "artist": "k3", "pop_now": 35, "paying": False, "tier": "HOLD", "sources": ["C"],
                "roles": [{"role": "Engineer", "verdict": "UNVERIFIABLE"}]}
        (self.dir / "pop.jsonl").write_text(json.dumps(hold) + "\n")
        (self.dir / "w.jsonl").write_text("")
        run_id, _ = waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                                  watch_path=str(self.dir / "w.jsonl"), takeback_path=self.manifest, apply_run=None,
                                  out_root=self.dir / "waves", argv=[], actor="test", api=api, verify_db=db,
                                  log=self.log)
        path = self.dir / "waves" / run_id / "W-01" / f"user-{UID}.json"
        prepared = json.loads(path.read_text())
        self.assertEqual(prepared["status"], "prepared_not_sent")
        self.assertEqual({c["role"] for c in prepared["credits"]}, {"Engineer", "Mixing"})
        now = datetime.now(timezone.utc)
        self.assertEqual(waves.send_check(waves.send_state(self.ledger, verify_db=db, now=now,
                                                           doc_submitted_path=self.doc_list(now)),
                                          json.loads(path.read_text())), ("send", "ok"))
        api.sender.verdict = "valid"
        _, day2 = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                 pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(day2, {"removed": 1, "notice_sent": 1})
        for after in (timedelta(0), timedelta(days=29)):
            state = waves.send_state(self.ledger, verify_db=db, now=now + after,
                                     doc_submitted_path=self.doc_list(now + after))
            self.assertEqual(waves.send_check(state, json.loads(path.read_text())),
                             ("drop", "takeback_notice_quiet_window"))
        p = json.loads(path.read_text())
        later = now + timedelta(days=30, hours=1)
        state = waves.send_state(self.ledger, verify_db=db, now=later, doc_submitted_path=self.doc_list(later))
        self.assertEqual(waves.send_check(state, p), ("send", "ok"))
        self.assertEqual([c["role"] for c in p["credits"]], ["Engineer"])  # never restates the removal
        # the CLI form: cannot check without the send ledger (file untouched), drops inside the window
        cli = [sys.executable, str(CLI), "--state-dir", str(self.dir / "state"), "send-check",
               "--doc-submitted", self.doc_list(datetime.now(timezone.utc)), "--file", str(path)]
        proc = subprocess.run(cli + ["--verify-ledger", str(self.dir / "absent.sqlite3")], capture_output=True,
                              text=True, check=False)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertEqual(json.loads(path.read_text())["status"], "prepared_not_sent")
        proc = subprocess.run(cli + ["--verify-ledger", db], capture_output=True, text=True, check=False)
        self.assertEqual((proc.returncode, proc.stdout.strip()), (1, "DROP takeback_notice_quiet_window"))
        self.assertEqual(json.loads(path.read_text())["status"], "dropped_at_send_check")
        # no batch form: a whole wave dir holding a dropped user can never come back exit 0
        proc = subprocess.run(cli[:-2] + ["--wave-dir", str(self.dir / "waves"), "--verify-ledger", db],
                              capture_output=True, text=True, check=False)
        self.assertNotEqual(proc.returncode, 0)
        proc = subprocess.run([sys.executable, str(CLI), "--state-dir", str(self.dir / "none"), "send-check",
                               "--file", str(path), "--verify-ledger", db],
                              capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 2)
        self.assertFalse((self.dir / "none").exists())

    def test_send_check_rechecks_proof_human_approval_and_one_message(self):
        def payload(uid="7", email="x@example.com", rids=("r1", "r2")):
            credits = [{"request_id": r, "role": "Producer", "kind": "verify", "pop_now": 1} for r in rids]
            return {"status": "prepared_not_sent", "user": {"id": uid, "email": email},
                    "groups": [{"group": "producer", "credits": credits}], "account_asks": [],
                    "credits": credits, "credits_total": len(credits), "request_ids_all": list(rids)}
        doc = self.doc_list(datetime.now(timezone.utc), users=["8"], requests=["r2"])
        db = self.verify_db([("verify-live", "initial", "sent", "proof@example.com", '["r1"]', "2026-10-10"),
                             ("retro-past", "initial", "sent", "asked@example.com", '["r9"]', None)])
        state = waves.send_state(self.ledger, verify_db=db, now=datetime.now(timezone.utc), doc_submitted_path=doc)
        self.assertEqual(waves.send_check(state, payload(uid="8")), ("drop", "doc_submitted"))
        self.assertEqual(waves.send_check(state, payload(email="proof@example.com")), ("drop", "already_sent_proof"))
        self.assertEqual(waves.send_check(state, payload(email="asked@example.com")), ("drop", "already_asked"))
        self.assertEqual(waves.send_check(state, payload(email=None)), ("drop", "no_account_email"))
        self.assertEqual(waves.send_check(state, {**payload(), "status": "live_read_error"}),
                         ("drop", "status:live_read_error"))
        self.assertEqual(waves.send_check(state, payload(rids=("r1", "r2"))), ("drop", "nothing_left_to_ask"))
        p = payload(rids=("r1", "r2", "r3"))
        self.assertEqual(waves.send_check(state, p), ("send", "ok"))
        self.assertEqual((p["request_ids_all"], p["credits_total"]), (["r3"], 1))
        with self.assertRaises(waves.SendStateUnavailable):
            waves.send_state(self.ledger, verify_db=str(self.dir / "absent.sqlite3"), now=datetime.now(timezone.utc))

    def test_send_check_never_clears_a_send_on_a_doc_list_built_before_new_attachments(self):
        # a user who attached a document in Intercom after the list was built (untagged, so not in
        # the send ledger) is in no source an old list can see: only a list rebuilt within 3h counts
        now = datetime.now(timezone.utc)
        db = self.verify_db()
        payload = self.dir / "user-7.json"

        def write_payload():
            credits = [{"request_id": "r1", "role": "Producer", "kind": "verify", "pop_now": 1}]
            payload.write_text(json.dumps({"status": "prepared_not_sent", "user": {"id": "7", "email": "x@example.com"},
                                           "groups": [{"group": "producer", "credits": credits}],
                                           "account_asks": [], "credits": credits, "credits_total": 1,
                                           "request_ids_all": ["r1"]}))

        for stale in (str(MANIFEST_DIR / "doc-submitted-r1.json"),  # the committed snapshot: no generated_at
                      self.doc_list(None),
                      self.doc_list(now - timedelta(hours=3, minutes=1)),
                      self.doc_list(now + timedelta(days=365))):  # future-dated: never "fresh"
            with self.assertRaises(waves.SendStateUnavailable):
                waves.send_state(self.ledger, verify_db=db, now=now, doc_submitted_path=stale)
            write_payload()
            proc = subprocess.run([sys.executable, str(CLI), "--state-dir", str(self.dir / "state"), "send-check",
                                   "--file", str(payload), "--verify-ledger", db, "--doc-submitted", stale],
                                  capture_output=True, text=True, check=False)
            self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
            self.assertIn("CANNOT CHECK", proc.stderr)
            self.assertEqual(json.loads(payload.read_text())["status"], "prepared_not_sent")
        # the rebuilt list names the user who attached a document since: dropped
        proc = subprocess.run([sys.executable, str(CLI), "--state-dir", str(self.dir / "state"), "send-check",
                               "--file", str(payload), "--verify-ledger", db,
                               "--doc-submitted", self.doc_list(now - timedelta(hours=2), users=["7"])],
                              capture_output=True, text=True, check=False)
        self.assertEqual((proc.returncode, proc.stdout.strip()), (1, "DROP doc_submitted"), proc.stderr)
        self.assertEqual(json.loads(payload.read_text())["status"], "dropped_at_send_check")

    def test_a_user_still_owed_a_notice_is_in_no_wave(self):
        api = FakeApi()
        api.sender.outcome = "failed"
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        hold = {"request_id": "r-2", "user_id": UID, "profile_id": PID, "track_id": "t2", "track_title": "T",
                "artist": "A", "pop_now": 5, "paying": False, "tier": "HOLD", "sources": ["C"],
                "roles": [{"role": "Producer", "verdict": "UNVERIFIABLE"}]}
        (self.dir / "pop.jsonl").write_text(json.dumps(hold) + "\n")
        (self.dir / "w.jsonl").write_text("")
        run_id, index = waves.prepare(self.ledger, population_path=str(self.dir / "pop.jsonl"),
                                      watch_path=str(self.dir / "w.jsonl"), takeback_path=self.manifest,
                                      apply_run=None, out_root=self.dir / "waves", argv=[], actor="test",
                                      log=self.log)
        self.assertEqual(list((self.dir / "waves" / run_id).glob("*/user-*.json")), [])
        self.assertEqual(index["takeback_notice_quiet_users"], 1)

    def test_server_refusal_is_recorded_and_stops(self):
        api = FakeApi()
        api.write_status = 403
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(counts["refused"], 1)
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual(rep["server_refused_or_error"][0]["reason"], "credit_removal_agent_refused")
        self.assertEqual(rep["removed"], 0)

    def test_apply_without_an_approved_set_removes_nothing(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
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
        """The server performs the execute, then the response is lost."""
        real_write, real_get = api.write, api.get

        def write(method, path, body, headers=None):
            real_write(method, path, body, headers)
            if path.endswith("/execute"):
                if reads_fail:
                    api.get = lambda *a, **k: (_ for _ in ()).throw(ApiError("read timed out"))
                raise ApiError("POST execute: transport error timed out")
            return 200, {"result": "ok"}
        api.write = write
        return real_get

    def test_lost_delete_response_is_reconciled_live_and_revertible(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        self.lost_response(api, reads_fail=False)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        self.assertEqual(counts, {"removed": 1, "stopped_on_transport_error": 1, "notice_sent": 1})
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual((rep["removed"], rep["server_refused_or_error"], rep["unresolved"]), (1, [], []))
        _, rv = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv, {"re_added": 1})

    def test_gateway_error_after_the_server_removed_is_reconciled_announced_and_revertible(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        real_write = api.write

        def bad_gateway(method, path, body, headers=None):
            real_write(method, path, body, headers)  # core executes the set...
            return 502, {"raw": "Bad Gateway"}       # ...and the ingress answers 502
        api.write = bad_gateway
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender,
                                          log=self.log)
        self.assertEqual(counts, {"removed": 1, "stopped_on_error_response": 1, "notice_sent": 1})
        self.assertEqual([c["role"] for c in api.sender.sent[0]["credits"]], ["Mixing"])
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual((rep["removed"], rep["unresolved"], rep["unnotified"]), (1, [], []))
        self.assertEqual(self.ledger.removed_rows(apply_id)[0]["http_status"], 502)
        api.write = real_write
        _, rv = takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, log=self.log)
        self.assertEqual(rv, {"re_added": 1})

    def test_gateway_error_with_the_credit_still_live_is_not_removed_and_stops(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        api.write_status = 504
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender,
                                          log=self.log)
        self.assertEqual(counts, {"not_removed": 1, "stopped_on_error_response": 1})
        self.assertEqual(api.sender.sent, [])

    def test_unknown_delete_result_blocks_retry_revert_and_waves_until_reconciled(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        real_get = self.lost_response(api, reads_fail=True)
        apply_id, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                          excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
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
        # re-added before anyone was told: no notice is owed, and none is ever sent
        self.assertEqual(takeback.report(self.ledger, apply_id)["unnotified"], [])
        self.assertEqual(takeback.notify(api, self.ledger, apply_id, self.rows, api.sender, log=self.log), {})
        self.assertEqual(api.sender.sent, [])

    def test_lost_readd_response_is_recorded_and_never_reposted(self):
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        apply_id, _ = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id,
                                     excl=OPEN, argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
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
        plan_id, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        real_write = api.write

        def crash(method, path, body, headers=None):
            real_write(method, path, body, headers)
            raise KeyboardInterrupt  # killed after the server acted, before any response was handled
        api.write = crash
        with self.assertRaises(KeyboardInterrupt):
            takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.log)
        first = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        self.assertEqual(takeback.report(self.ledger, first)["unresolved"], [f"{RID}:Mixing"])
        self.assertEqual(api.sender.sent, [])  # nothing confirmed removed yet, so nothing announced
        self.assertIsNotNone(self.ledger.run_end(first))
        api.write = real_write
        plan2, _ = takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
        # the same approved set again: its pair was consumed by the first execute
        _, counts = takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan2,
                                   excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"], sender=api.sender, log=self.log)
        # nothing is executed again; the removal the reconcile confirmed in the first run is
        # announced to its user now
        self.assertEqual(counts, {"earlier_notice_sent": 1})
        self.assertEqual(sum(1 for w in api.writes if w[1].endswith("/execute")), 1)
        self.assertEqual([c["role"] for c in api.sender.sent[0]["credits"]], ["Mixing"])
        rep = takeback.report(self.ledger, first)
        self.assertEqual((rep["removed"], rep["unresolved"], rep["unnotified"]), (1, [], []))

    def test_ledger_is_append_only(self):
        api = FakeApi()
        takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[], log=self.log)
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
        ps = {p["user"]["id"]: p for p in waves.assemble(population, watch)}
        self.assertEqual(len(ps), 3)
        self.assertEqual({p["wave"] for p in ps.values()}, {"W-01"})
        self.assertEqual(ps["3"]["template"], "retro-verify-grouped")
        self.assertEqual([c["kind"] for c in ps["3"]["credits"]], ["verify"])
        # velocity account with a HOLD row: one message, carrying the account ask as a section
        self.assertEqual([a["kind"] for a in ps["9"]["account_asks"]], ["velocity"])
        self.assertTrue(ps["9"]["paying"])
        self.assertEqual([g["group"] for g in ps["1"]["groups"]], ["mixing-mastering", "producer"])
        self.assertEqual(ps["1"]["credits_total"], 3)
        p = ps["1"]
        self.assertEqual((p["send_not_before"], p["flag_unverified_after"]), ("2026-10-16", "2026-11-15"))
        # one past-credit message per user: send-check drops anyone already asked, so no follow-up is scheduled
        self.assertFalse({k for x in ps.values() for k in x if k.startswith("follow_up")})
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
        order = [p["user"]["id"] for p in sorted(waves.assemble(population, [], per_day=1),
                                                  key=lambda p: p["wave"])]
        self.assertEqual(order, ["paid_big", "paid_small", "free_big", "free_mid"])

    def test_cap_keeps_biggest_tracks(self):
        population = [self.pop("1", f"r{i:04d}", i % 100) for i in range(250)]
        p = waves.assemble(population, [])[0]
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
        ps = waves.assemble(population, [], ask)
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

    def test_users_who_sent_documents_and_human_approved_requests_are_never_asked(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            pop_path = d / "pop.jsonl"
            pop_path.write_text("".join(json.dumps(r) + "\n" for r in (
                self.row("1", "r1", "HOLD"), self.row("3", "r3", "HOLD"), self.row("4", "r4", "HOLD"))))
            (d / "w.jsonl").write_text(json.dumps({
                "user_id": "3", "profile_ids": ["p3"], "velocity_rows": 100, "first_request": "2026-10-01",
                "max_requests_per_day": 200, "example_tracks": [], "paying": True}) + "\n")
            (d / "tb.jsonl").write_text("")
            doc = d / "doc.json"
            doc.write_text(json.dumps({"users_doc_submitted": ["3"], "human_approved_requests": ["r1"]}))
            ledger = Ledger(d / "state")
            run_id, index = waves.prepare(ledger, population_path=str(pop_path), watch_path=str(d / "w.jsonl"),
                                          takeback_path=str(d / "tb.jsonl"), apply_run=None, out_root=d / "waves",
                                          argv=[], actor="test", doc_submitted_path=str(doc), log=lambda *_: None)
            ledger.close()
            files = sorted(f.name for f in (d / "waves" / run_id).glob("*/user-*.json"))
        self.assertEqual(files, ["user-4.json"])
        self.assertEqual(index["doc_submitted"]["before"], {"users": 3, "paying_users": 1})
        self.assertEqual(index["doc_submitted"]["after"], {"users": 1, "paying_users": 0})

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
        self.plan_id, _ = takeback.plan(self.api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[],
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
        self.assertIn(f"[{PID[:8]}/{TID[:8]}/Mixing] (public credits page) https://www.qobuz.com/x", body["reason"])
        self.assertLessEqual(len(body["reason"]), 2000)

    def test_evidence_never_truncated_sets_split_instead(self):
        rows = [row(row_id=f"r{i}:Mixing", request_id=f"r{i}", profile_id=f"{i:08d}-p", track_id=f"{i:08d}-t",
                    evidence_url="https://www.qobuz.com/" + "x" * 150) for i in range(30)]
        chunks = takeback.chunk_for_reasons(rows, "h" * 300)
        self.assertGreater(len(chunks), 1)
        self.assertEqual(sum(len(c) for c in chunks), 30)
        for c in chunks:
            self.assertLessEqual(300 + sum(len(takeback.evidence_line(r)) + 2 for r in c), 2000)

    def test_apply_refuses_until_approved_then_spends_only_pairs_whose_own_decision_is_approved(self):
        takeback.stage(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                       argv=[], log=lambda *_: None)
        with self.assertRaises(SystemExit):
            takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                           excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"], sender=self.api.sender, log=lambda *_: None)
        # Fable 024: a set counts as approved once ANY pair is; an undecided pair is never spent
        self.api.approval["status"] = "approved"
        _, counts = takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                                   excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"], sender=self.api.sender,
                                   log=lambda *_: None)
        self.assertEqual(counts, {})
        self.assertFalse(any(w[1].endswith("/execute") for w in self.api.writes))
        self.api.approval["pairs"][0]["decision"] = "approved"
        apply_id, counts = takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest,
                                          plan_run=self.plan_id, excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"],
                                          sender=self.api.sender, log=lambda *_: None)
        self.assertEqual(counts, {"removed": 1, "notice_sent": 1})
        self.assertEqual(self.api.writes[-1][:3], ("POST", "/admin/credit-removals/ap-1/execute", {}))
        removed = self.ledger.events(apply_id, "remove")
        self.assertTrue(removed[0]["approval_ref"].startswith(f"credit-removal-approval ap-1 | {takeback.DECISION_REF}"))

    def test_a_rejected_pair_in_an_approved_set_is_never_removed_or_announced(self):
        mastering = row(row_id=f"{RID}:Mastering", role="Mastering")
        (self.dir / "two").mkdir()
        manifest = write_manifest(self.dir / "two", [row(), mastering])
        rows = takeback.load_manifest(manifest)
        api = FakeApi()
        api.request["credits"] = ["Mixing", "Mastering"]
        api.raws += [raw("tidal", "Eli WTF", "mastering engineer", "td2"), raw("muso", "Rishi Krishnan", "mastering", PID)]
        plan_id, counts = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=OPEN, argv=[], log=lambda *_: None)
        self.assertEqual(counts, {"would_remove": 2})
        takeback.stage(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, argv=[], log=lambda *_: None)
        self.assertEqual(sum(1 for w in api.writes if w[1] == "/admin/credit-removals"), 1)  # one user, one set
        api.approval["status"] = "approved"
        api.approval["pairs"][0]["decision"] = "approved"   # Mixing
        api.approval["pairs"][1]["decision"] = "rejected"   # Mastering: Nick said no to this one
        apply_id, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN,
                                          argv=[], pause_s=0, approvals=["ap-1"], sender=api.sender, log=lambda *_: None)
        self.assertEqual(counts, {"removed": 1, "notice_sent": 1})
        self.assertTrue(any(r["credit"] == "mastering" and r["profile"]["id"] == PID for r in api.raws))
        self.assertEqual([c["role"] for c in api.sender.sent[0]["credits"]], ["Mixing"])
        self.assertEqual([e["row_id"] for e in self.ledger.removed_rows(apply_id)], [f"{RID}:Mixing"])

    def test_execute_result_that_is_not_removed_gets_no_notice_on_a_guess(self):
        takeback.stage(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                       argv=[], log=lambda *_: None)
        self.api.approve()
        self.api.execute = lambda: {"id": "ap-1", "ok": False, "results": [
            {"pairId": "1", "profileId": PID, "trackId": TID, "role": "mixing", "status": "error"}]}
        apply_id, counts = takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest,
                                          plan_run=self.plan_id, excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"],
                                          sender=self.api.sender, log=lambda *_: None)
        # the credit is still live: recorded not_removed, nobody is told anything
        self.assertEqual(counts, {"not_removed": 1})
        self.assertEqual(self.api.sender.sent, [])
        self.assertEqual(takeback.report(self.ledger, apply_id)["server_refused_or_error"][0]["outcome"], "not_removed")

    def test_set_with_no_spendable_pair_executes_nothing(self):
        takeback.stage(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                       argv=[], log=lambda *_: None)
        self.api.approval.update(status="approved", pairs=[])
        _, counts = takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=self.plan_id,
                                   excl=OPEN, argv=[], pause_s=0, approvals=["ap-1"], sender=self.api.sender, log=lambda *_: None)
        self.assertEqual(counts, {})
        self.assertFalse(any(w[1].endswith("/execute") for w in self.api.writes))

    def test_stage_one_set_per_user(self):
        other = row(row_id="r2:Mixing", request_id="r2", user_id="161128")
        (self.dir / "users").mkdir()
        manifest = write_manifest(self.dir / "users", [row(), other])
        rows = takeback.load_manifest(manifest)
        api = FakeApi()
        orig = api.get

        def get(path, params=None):
            if path == "/admin/credit-requests" and params and params.get("page", 1) == 1:
                return {"items": [api.request, dict(api.request, id="r2", userId=161128,
                                                    user={"id": 161128, "email": "o@example.com", "fullName": "O"})]}
            return orig(path, params)
        api.get = get
        plan_id, counts = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=OPEN, argv=[], log=lambda *_: None)
        self.assertEqual(counts, {"would_remove": 2})
        _, out = takeback.stage(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, argv=[], log=lambda *_: None)
        stages = [w for w in api.writes if w[1] == "/admin/credit-removals"]
        self.assertEqual(len(stages), 2)
        self.assertEqual(sorted(w[2]["sourceRef"].split("; ")[-1].split(" (")[0] for w in stages),
                         ["user 161128", f"user {UID}"])

    def test_agent_wrapper_may_only_stage(self):
        from credit_retro.api import WrapperReadApi
        w = WrapperReadApi.__new__(WrapperReadApi)
        with self.assertRaises(ApiError):
            w.write("DELETE", f"/admin/track/{TID}/profile/{PID}/credits", {})


class ExecuteRaceTests(unittest.TestCase):
    """A set changes on the board while apply runs, or is executed outside the tool."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.ledger = Ledger(self.dir / "state")
        self.api = FakeApi()
        self.api.request["credits"] = ["Mixing", "Mastering"]
        self.api.raws += [raw("tidal", "Eli WTF", "mastering engineer", "td2"),
                          raw("muso", "Rishi Krishnan", "mastering", PID)]
        self.mastering = [{"id": "2", "profileId": PID, "trackId": TID, "role": "mastering", "decision": None,
                           "consumedAt": None}]

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def planned(self, rows):
        self.manifest = write_manifest(self.dir, rows)
        self.rows = takeback.load_manifest(self.manifest)
        plan_id, _ = takeback.plan(self.api, self.ledger, self.rows, manifest=self.manifest, excl=OPEN, argv=[],
                                   log=lambda *_: None)
        return plan_id

    def apply(self, plan_id):
        return takeback.apply(self.api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=OPEN,
                              argv=[], pause_s=0, approvals=["ap-1"], sender=self.api.sender, log=lambda *_: None)

    def holds(self, role):
        return any(r["credit"] == role and r["profile"]["id"] == PID for r in self.api.raws)

    def test_a_set_with_an_undecided_pair_is_withheld_whole_until_every_pair_is_decided(self):
        plan_id = self.planned([row(), row(row_id=f"{RID}:Mastering", role="Mastering")])
        self.api.approve()
        self.api.approval["pairs"] += self.mastering
        apply_id, counts = self.apply(plan_id)
        self.assertFalse([w for w in self.api.writes if w[1].endswith("/execute")])
        self.assertTrue(self.holds("mixing") and self.holds("mastering"))
        self.assertEqual(counts, {"withheld:pair_undecided": 1, "withheld_sets": 1})
        self.assertEqual([(e["row_id"], e["reason"]) for e in takeback.report(self.ledger, apply_id)["withheld"]],
                         [(f"{RID}:Mixing", "pair_undecided")])
        self.assertEqual(self.api.sender.sent, [])
        # Jan decides the last pair: the next apply gates and executes both, and the user is told
        self.api.approval["pairs"][1]["decision"] = "approved"
        _, counts = self.apply(plan_id)
        self.assertEqual(counts, {"removed": 2, "notice_sent": 1})
        self.assertEqual(sorted(c["role"] for c in self.api.sender.sent[0]["credits"]), ["Mastering", "Mixing"])

    def approve_mastering_just_before_the_execute(self):
        """Jan approves the undecided pair between apply's live gate and its execute POST."""
        real_write = self.api.write

        def write(method, path, body, headers=None):
            if path.endswith("/execute"):
                self.api.approval["pairs"][1]["decision"] = "approved"
            return real_write(method, path, body, headers)
        self.api.write = write

    def test_a_planned_pair_approved_between_the_gate_and_the_execute_is_never_removed(self):
        plan_id = self.planned([row(), row(row_id=f"{RID}:Mastering", role="Mastering")])
        self.api.approve()
        self.api.approval["pairs"] += self.mastering
        self.approve_mastering_just_before_the_execute()
        _, counts = self.apply(plan_id)
        self.assertFalse([w for w in self.api.writes if w[1].endswith("/execute")])
        self.assertTrue(self.holds("mixing") and self.holds("mastering"))
        self.assertEqual(counts, {"withheld:pair_undecided": 1, "withheld_sets": 1})
        self.assertEqual(self.api.sender.sent, [])

    def test_an_unplanned_pair_approved_between_the_gate_and_the_execute_is_never_removed(self):
        plan_id = self.planned([row()])
        self.api.approve()
        self.api.approval["pairs"] += self.mastering
        self.approve_mastering_just_before_the_execute()
        rc, err = cli_apply(self.api, self.dir / "state", self.manifest, plan_id)
        self.assertEqual(rc, 3)
        self.assertIn("WITHHELD", err)
        self.assertFalse([w for w in self.api.writes if w[1].endswith("/execute")])
        self.assertTrue(self.holds("mixing") and self.holds("mastering"))
        apply_id = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        rep = takeback.report(self.ledger, apply_id)
        self.assertEqual([(e["row_id"], e["reason"]) for e in rep["withheld"]], [(f"{RID}:Mixing", "pair_undecided")])
        self.assertEqual(self.api.sender.sent, [])

    def board_executes(self, plan_id, *, removes=True):
        self.api.approve()
        if removes:
            self.api.execute()
        else:
            self.api.approval["pairs"][0]["consumedAt"] = "2026-10-17T04:00:00Z"

    def test_a_set_executed_on_the_board_is_resolved_live_and_announced(self):
        plan_id = self.planned([row()])
        self.board_executes(plan_id)
        apply_id, counts = self.apply(plan_id)
        self.assertFalse([w for w in self.api.writes if w[1].endswith("/execute")])
        self.assertEqual(counts, {"removed": 1, "executed_outside_tool": 1, "notice_sent": 1})
        self.assertEqual([e["reason"] for e in self.ledger.removed_rows(apply_id)], ["executed_outside_tool"])
        self.assertEqual([c["role"] for c in self.api.sender.sent[0]["credits"]], ["Mixing"])
        # recorded once: the next apply sees the removal as ours and says nothing again
        _, again = self.apply(plan_id)
        self.assertEqual((again, len(self.api.sender.sent)), ({}, 1))

    def test_a_set_consumed_on_the_board_with_the_credit_still_live_is_withheld(self):
        plan_id = self.planned([row()])
        self.board_executes(plan_id, removes=False)
        apply_id, counts = self.apply(plan_id)
        self.assertEqual(counts, {"withheld:consumed_still_credited": 1})
        self.assertEqual([(e["row_id"], e["reason"]) for e in takeback.report(self.ledger, apply_id)["withheld"]],
                         [(f"{RID}:Mixing", "consumed_still_credited")])
        self.assertEqual(self.api.sender.sent, [])

    def test_a_set_executed_on_the_board_with_an_unreadable_credit_stays_unresolved(self):
        plan_id = self.planned([row()])
        self.board_executes(plan_id)
        real_get = self.api.get

        def get(path, params=None):
            if path.endswith("/raw-credits"):
                raise ApiError("read timed out")
            return real_get(path, params)
        self.api.get = get
        apply_id, counts = self.apply(plan_id)
        self.assertEqual(counts, {"indeterminate": 1, "executed_outside_tool": 1})
        self.assertEqual(takeback.report(self.ledger, apply_id)["unresolved"], [f"{RID}:Mixing"])
        self.assertEqual(self.api.sender.sent, [])
        self.api.get = real_get  # the API answers: the next apply reconciles it and announces it
        _, counts = self.apply(plan_id)
        self.assertEqual(counts, {"earlier_notice_sent": 1})
        self.assertEqual(takeback.report(self.ledger, apply_id)["removed"], 1)


class EvidenceAndNoticeTests(unittest.TestCase):
    """Firstmate 012: evidence for the row's own role; every take-back tells its user."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.ledger = Ledger(self.dir / "state")
        self.out: list[str] = []

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def plan_for(self, rows):
        manifest = write_manifest(self.dir, rows)
        rows = takeback.load_manifest(manifest)
        api = FakeApi()
        plan_id, _ = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=OPEN, argv=[], log=self.out.append)
        return api, manifest, rows, plan_id

    def test_unverified_or_mismatched_evidence_is_never_removed(self):
        api = FakeApi()
        self.assertEqual(takeback.gate(api, row(evidence={}), OPEN).reason, "evidence_unverified")
        mism = {"verified": "public_page", "url": "https://www.qobuz.com/other-album", "names": ["Eli WTF"]}
        self.assertEqual(takeback.gate(api, row(evidence=mism), OPEN).reason, "evidence_unverified")
        self.assertEqual(takeback.gate(api, row(excluded="alias risk"), OPEN).reason, "excluded_row")
        dsp = {"verified": "trusted_dsp_only", "url": "https://listen.tidal.com/track/1", "names": ["Eli WTF"],
               "sources": ["tidal"], "note": "Tidal credits Eli WTF as mixer"}
        r = row(evidence_url="https://listen.tidal.com/track/1", evidence=dsp)
        self.assertTrue(takeback.gate(api, r, OPEN).ok)
        self.assertIn("(Tidal credits, evidence_class=dsp_track_level) https://listen.tidal.com/track/1",
                      takeback.evidence_line(r))
        self.assertNotIn("evidence_class", takeback.evidence_line(row()))
        both = row(evidence_url="https://open.spotify.com/track/1",
                   evidence={**dsp, "url": "https://open.spotify.com/track/1", "sources": ["spotify", "tidal"]})
        self.assertEqual(takeback.evidence_label(both), "Spotify and Tidal credits")
        # a name the recorded note does not quote is never cited to the user
        felix = {**row()["evidence"], "names": ["Eli WTF", "Felix Byrne"]}
        self.assertEqual(takeback.gate(api, row(evidence=felix), OPEN).reason, "evidence_unverified")

    def test_trusted_dsp_only_means_a_current_spotify_or_tidal_credit(self):
        api = FakeApi()
        dsp = {"verified": "trusted_dsp_only", "url": "https://listen.tidal.com/track/1", "names": ["Eli WTF"],
               "sources": ["tidal"], "note": "Tidal credits Eli WTF as mixer"}
        base = dict(evidence_url="https://listen.tidal.com/track/1")
        jaxsta_url = "https://jaxsta.com/recording/x/credits"
        for bad in ({**dsp, "sources": ["jaxsta", "tidal"]}, {**dsp, "sources": ["mlc"]}, {**dsp, "sources": []}):
            self.assertEqual(takeback.gate(api, row(**base, evidence=bad), OPEN).reason, "evidence_unverified")
        self.assertEqual(takeback.gate(api, row(evidence_url=jaxsta_url, evidence={**dsp, "url": jaxsta_url}), OPEN).reason,
                         "evidence_unverified")
        # the Tidal credit vanished; only Jaxsta still names him: never removed on the Tidal citation
        api.raws = [raw("jaxsta", "Eli WTF", "mixer", "jx1"), raw("spotify", "Eli WTF", "mixing engineer", "sp1"),
                    raw("muso", "Rishi Krishnan", "mixing", PID)]
        self.assertEqual(takeback.gate(api, row(**base, evidence=dsp), OPEN).reason, "dsp_holder_vanished")
        # cited as Spotify AND Tidal with the Tidal link: a surviving Spotify credit alone does not
        # back a notice that cites the Tidal page (which no longer names him)
        both = {**dsp, "sources": ["spotify", "tidal"]}
        self.assertEqual(takeback.gate(api, row(**base, evidence=both), OPEN).reason, "dsp_holder_vanished")
        # the cited URL's own source must be among the cited sources
        self.assertEqual(takeback.gate(api, row(**base, evidence={**dsp, "sources": ["spotify"]}), OPEN).reason,
                         "evidence_unverified")
        api.raws.append(raw("tidal", "Eli WTF", "mixer", "td1"))
        self.assertTrue(takeback.gate(api, row(**base, evidence=both), OPEN).ok)

    def test_no_removal_when_the_notice_cannot_be_sent(self):
        api, manifest, rows, plan_id = self.plan_for([row()])
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[], pause_s=0,
                           approvals=api.approve(), sender=FakeSender(verdict="refused"), log=self.out.append)
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[], pause_s=0,
                           approvals=api.approve(), sender=None, log=self.out.append)
        self.assertFalse([w for w in api.writes if w[1].endswith("/execute")])

    def test_notice_sent_after_removal_with_who_why_and_how_to_dispute(self):
        api, manifest, rows, plan_id = self.plan_for([row()])
        apply_id, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                          pause_s=0, approvals=api.approve(), sender=api.sender,
                                          log=self.out.append)
        self.assertEqual(counts, {"removed": 1, "notice_sent": 1})
        payload = api.sender.sent[0]
        self.assertEqual(payload["campaign"], "takeback-notice")
        self.assertEqual(payload["user"], {"email": "rk@example.com", "id": UID, "first_name": "Rishi"})
        c = payload["credits"][0]
        self.assertEqual((c["role"], c["other_names"], c["evidence_url"]), ("Mixing", ["Eli WTF"], "https://www.qobuz.com/x"))
        subject, body = notice.render("Rishi", payload["credits"])
        self.assertIn('Mixing credit on "Lemonade"', subject)
        self.assertIn("name Eli WTF for Mixing", body)
        self.assertIn("https://www.qobuz.com/x", body)
        self.assertIn("reply to this message with one document", body)
        self.assertNotIn("\u2014", body)  # house copy rule: no em dashes
        notified = self.ledger.events(apply_id, "notify")
        self.assertEqual([e["outcome"] for e in notified], ["sent"])
        self.assertEqual(json.loads(notified[0]["after_json"])["approved_by"], "U0TESTAPPR")
        self.assertNotIn("rk@example.com", json.dumps([dict(e) for e in self.ledger.events(apply_id)]))

    def test_deferred_notice_is_retried_once_by_notify(self):
        api, manifest, rows, plan_id = self.plan_for([row()])
        api.sender.outcome = "deferred"
        # a removal whose notice did not go out is never reported as a completed apply
        with self.assertRaises(SystemExit) as stop:
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        apply_id = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        self.assertIn(f"notify --run {apply_id}", str(stop.exception.code))
        self.assertEqual(json.loads(self.ledger.run_end(apply_id)["counts_json"])["notice_deferred"], 1)
        self.assertEqual(takeback.report(self.ledger, apply_id)["unnotified"], [f"{RID}:Mixing"])
        # still deferred: notify stops loudly too, and the next apply removes nothing new
        with self.assertRaises(SystemExit):
            takeback.notify(api, self.ledger, apply_id, rows, api.sender, log=self.out.append)
        writes = len(api.writes)
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        self.assertEqual(len(api.writes), writes)
        api.sender.outcome = "sent"
        self.assertEqual(takeback.notify(api, self.ledger, apply_id, rows, api.sender, log=self.out.append),
                         {"notice_sent": 1})
        self.assertEqual(takeback.notify(api, self.ledger, apply_id, rows, api.sender, log=self.out.append), {})
        self.assertEqual(takeback.report(self.ledger, apply_id)["unnotified"], [])

    def test_no_removal_on_a_day_the_notice_would_be_deferred(self):
        api, manifest, rows, plan_id = self.plan_for([row()])
        api.sender.verdict = "deferred"
        apply_id, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                          pause_s=0, approvals=api.approve(), sender=api.sender,
                                          log=self.out.append)
        self.assertEqual(counts, {"withheld:notice_would_defer": 1, "withheld_sets": 1})
        self.assertFalse([w for w in api.writes if w[1].endswith("/execute")])
        self.assertEqual(api.sender.sent, [])
        self.assertEqual(takeback.report(self.ledger, apply_id)["skipped"],
                         [{"row_id": f"{RID}:Mixing", "reason": "notice_would_defer"}])
        api.sender.verdict = "valid"  # a later day: the pair goes, with its message
        _, counts2 = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                    pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        self.assertEqual(counts2, {"removed": 1, "notice_sent": 1})

    def test_no_notice_for_a_role_restored_before_notify(self):
        api, manifest, rows, plan_id = self.plan_for([row()])
        api.sender.outcome = "failed"
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                           pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        apply_id = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        takeback.revert(api, self.ledger, apply_id, argv=[], pause_s=0, requests={RID}, ref="restore",
                        log=self.out.append)
        api.sender.outcome = "sent"
        self.assertEqual(takeback.notify(api, self.ledger, apply_id, rows, api.sender, log=self.out.append), {})
        self.assertEqual(len(api.sender.sent), 1)  # only the failed attempt; nothing after the restore

    def test_a_crashing_sender_still_finishes_the_run(self):
        api, manifest, rows, plan_id = self.plan_for([row()])

        def boom(payload):
            raise RuntimeError("intercom hung")
        api.sender.send = boom
        with self.assertRaises(RuntimeError):
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[], pause_s=0,
                           approvals=api.approve(), sender=api.sender, log=self.out.append)
        apply_id = self.ledger.child_runs(plan_id, "apply")[0]["run_id"]
        self.assertIsNotNone(self.ledger.run_end(apply_id))
        self.assertEqual(takeback.report(self.ledger, apply_id)["unnotified"], [f"{RID}:Mixing"])

    def test_script_sender_maps_exit_codes_and_never_raises(self):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "gate.sh"
            argv_log = Path(d) / "argv"
            script.write_text(f'printf "%s\\n" "$@" > {argv_log}\n'
                              'case "$CODE" in sleep) sleep 5 ;; *) echo out; echo err >&2; exit "$CODE" ;; esac\n')
            sender = notice.ScriptSender(str(script), approved_by="U0TESTAPPR", timeout=1)
            payload = notice.credits_file({"id": UID, "email": "rk@example.com", "first_name": "Rishi"},
                                          [notice.notice_credit(row())])
            env = dict(os.environ)
            try:
                for code, verdict, outcome in (("0", "valid", "sent"), ("3", "deferred", "deferred"),
                                               ("1", "refused", "failed"), ("sleep", "refused", "failed")):
                    os.environ["CODE"] = code
                    self.assertEqual(sender.validate(payload)[0], verdict, code)
                    self.assertEqual(sender.send(payload)[0], outcome, code)
            finally:
                os.environ.clear()
                os.environ.update(env)
            args = argv_log.read_text().splitlines()
            self.assertEqual(args[args.index("--approved-by") + 1], "U0TESTAPPR")
            self.assertEqual(args[args.index("--campaign") + 1], "takeback-notice")
        with self.assertRaises(SystemExit):
            notice.ScriptSender(str(script), approved_by="")

    def test_multi_credit_notice_reads_correctly_for_both_labels(self):
        dsp = {"verified": "trusted_dsp_only", "url": "https://listen.tidal.com/track/1", "names": ["Eli WTF"],
               "sources": ["tidal"], "note": "Tidal credits Eli WTF as mixer"}
        rows = [row(), row(row_id=f"{RID}:Mastering", role="Mastering",
                           evidence_url="https://listen.tidal.com/track/1", evidence=dsp)]
        _, body = notice.render("Rishi", [notice.notice_credit(r) for r in rows])
        self.assertIn("The public credits name someone else for these roles, so we have removed them "
                      "from your profile:", body)
        self.assertIn('- Mixing on "Lemonade" by k3: Eli WTF (public credits page: https://www.qobuz.com/x)', body)
        self.assertIn('- Mastering on "Lemonade" by k3: Eli WTF (Tidal credits: https://listen.tidal.com/track/1)',
                      body)
        self.assertIn("If the document checks out, we will put the credit back. Your other credits are not "
                      "affected.", body)
        self.assertNotIn("\u2014", body)

    def test_two_requests_for_the_same_credit_are_one_line(self):
        # Fable: user 161128 has two request ids for "Autentica" by Manuel Medrano (Mixing)
        rows = [row(track_title="Autentica", artist="Manuel Medrano"),
                row(row_id="r2:Mixing", request_id="r2", track_title="Autentica", artist="Manuel Medrano")]
        subject, body = notice.render("Rishi", [notice.notice_credit(r) for r in rows])
        self.assertEqual(subject, 'About your Mixing credit on "Autentica"')
        self.assertIn('The public credits for "Autentica" by Manuel Medrano name Eli WTF for Mixing '
                      '(public credits page: https://www.qobuz.com/x), so we have removed the Mixing credit '
                      'from your profile.', body)
        three = rows + [row(row_id="r3:Mixing", request_id="r3", track_title="Luna", artist="Manuel Medrano")]
        subject, body = notice.render("Rishi", [notice.notice_credit(r) for r in three])
        self.assertEqual(subject, "About 2 of your credits on Muso")
        self.assertEqual(body.count('on "Autentica"'), 1)

    def test_a_request_gone_since_the_plan_holds_only_that_user(self):
        api, manifest, rows, plan_id = self.plan_for([row()])
        api.request["id"] = "deleted-since-the-plan"
        apply_id, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                          pause_s=0, approvals=api.approve(), sender=api.sender,
                                          log=self.out.append)
        self.assertEqual(counts, {"withheld:request_not_found": 1, "withheld_sets": 1})
        self.assertFalse([w for w in api.writes if w[1].endswith("/execute")])
        api.request["id"] = RID
        del api.request["user"]["email"]
        with self.assertRaises(SystemExit):
            takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[], pause_s=0,
                           approvals=api.approve(), sender=api.sender, log=self.out.append)

    def test_notice_never_goes_to_the_account_a_request_moved_to(self):
        # user A (UID) has two planned rows on two requests; after the plan both move to user B
        manifest = write_manifest(self.dir, [row(), row(row_id="r2:Mixing", request_id="r2")])
        rows = takeback.load_manifest(manifest)
        api = FakeApi()
        second = dict(api.request, id="r2", user=dict(api.request["user"]))
        get = api.get
        api.get = lambda path, params=None: ({"items": [api.request, second]} if path == "/admin/credit-requests"
                                             else get(path, params))
        plan_id, _ = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=OPEN, argv=[], log=self.out.append)
        b = {"userId": 999, "user": {"id": 999, "email": "b@example.com", "fullName": "Bea B"}}
        api.request.update(b)
        second.update(b)
        _, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                   pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        self.assertEqual(counts, {"withheld:user_mismatch": 2, "withheld_sets": 1})
        self.assertEqual((api.sender.validated, api.sender.sent), ([], []))
        # the second request is A's again (the account id too); the first still belongs to B
        second.update(userId=int(UID), user=dict(second["user"], id=999))
        _, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                   pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        self.assertEqual(counts, {"withheld:user_mismatch": 2, "withheld_sets": 1})
        second["user"] = {"id": int(UID), "email": "rk@example.com", "fullName": "Rishi Krishnan"}
        _, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                   pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        # the first request still belongs to B: the WHOLE set is withheld, never part of it (firstmate 026)
        self.assertEqual(counts, {"withheld:user_mismatch": 1, "withheld:with_set": 1, "withheld_sets": 1})
        self.assertEqual(api.sender.sent, [])
        self.assertEqual([p["user"]["email"] for p in api.sender.validated], ["rk@example.com"])
        # both requests are A's again: the one pair goes, and A is told once
        api.request.update(userId=int(UID), user=dict(second["user"]))
        _, counts = takeback.apply(api, self.ledger, rows, manifest=manifest, plan_run=plan_id, excl=OPEN, argv=[],
                                   pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)
        self.assertEqual(counts, {"removed": 2, "notice_sent": 1})
        self.assertEqual([p["user"]["email"] for p in api.sender.sent], ["rk@example.com"])

    def test_preview_groups_by_user(self):
        rows = [row(), row(row_id=f"{RID}:Mastering", role="Mastering")]
        out = notice.preview(rows)
        self.assertEqual(len(out), 1)
        self.assertIn("About 2 of your credits", out[0]["subject"])


class LiveExclusionTests(unittest.TestCase):
    """Firstmate 020: plan and apply read the live exclusion sources every run."""

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

    def plan(self, api, excl):
        return takeback.plan(api, self.ledger, self.rows, manifest=self.manifest, excl=excl, argv=[],
                             log=self.out.append)

    def apply(self, api, plan_id, excl):
        return takeback.apply(api, self.ledger, self.rows, manifest=self.manifest, plan_run=plan_id, excl=excl,
                              argv=[], pause_s=0, approvals=api.approve(), sender=api.sender, log=self.out.append)

    def test_proof_sent_after_a_deferred_day_blocks_the_removal(self):
        api = FakeApi()
        plan_id, _ = self.plan(api, OPEN)
        api.sender.verdict = "deferred"
        _, day1 = self.apply(api, plan_id, OPEN)
        self.assertEqual(day1, {"withheld:notice_would_defer": 1, "withheld_sets": 1})
        api.sender.verdict = "valid"
        # X sends an invoice: credit-trust lists it, or Caroline proof-tags the note
        for n, (excl, reason) in enumerate((
                (live_sources(self.dir / "a", proof_entries=[{"user_id": int(UID), "request_id": RID,
                                                               "kind": "pending_doc", "source": "intercom",
                                                               "ref": "conv 1"}]), "proof_on_file:pending_doc"),
                (live_sources(self.dir / "b", proof_entries=[{"user_id": int(UID), "request_id": None,
                                                               "kind": "approved_doc", "source": "verifications",
                                                               "ref": "v 9"}]), "proof_on_file:approved_doc"),
                (live_sources(self.dir / "c", tagged=[("retro-past", "initial", "sent", "rk@example.com", "[]",
                                                       "2026-10-17")]), "proof_tagged"),
                (live_sources(self.dir / "d", tagged=[("verify-live", "initial", "sent", "other@example.com",
                                                       f'["{RID}"]', "2026-10-17")]), "proof_tagged"))):
            _, counts = self.plan(api, excl)
            self.assertEqual(counts, {f"skip:{reason}": 1}, n)
            _, day2 = self.apply(api, plan_id, excl)
            self.assertEqual(day2, {f"withheld:{reason}": 1, "withheld_sets": 1}, n)
        self.assertFalse([w for w in api.writes if w[1].endswith("/execute")])
        self.assertEqual(api.sender.sent, [])
        events = json.dumps([dict(e) for e in self.ledger.db.execute("SELECT * FROM events")])
        self.assertNotIn("rk@example.com", events)

    def test_doc_submitted_users_and_human_approved_requests_are_skipped(self):
        api = FakeApi()
        self.assertEqual(takeback.gate(api, row(user_id="119347"), OPEN).reason, "doc_submitted")
        approved = "8d83d287-9d4e-4540-a181-f9e50702477d"
        self.assertEqual(takeback.gate(api, row(request_id=approved), OPEN).reason, "human_approved_after_doc")

    def test_stale_or_unreadable_proof_sources_remove_nothing(self):
        api = FakeApi()
        plan_id, _ = self.plan(api, OPEN)
        for excl in (live_sources(self.dir / "old", age=timedelta(hours=4)),
                     # a future stamp would otherwise read as fresh forever
                     live_sources(self.dir / "future", age=-timedelta(days=365)),
                     live_sources(self.dir / "stale", stale_source=True),
                     takeback.load_exclusions(proof_on_file=str(self.dir / "absent.json"),
                                              org_affiliation=str(self.dir / "absent2.json"),
                                              verify_db=str(self.dir / "absent.sqlite3"))):
            _, counts = self.plan(api, excl)
            self.assertEqual(counts, {"skip:proof_source_unavailable": 1})
            with self.assertRaises(SystemExit):
                self.apply(api, plan_id, excl)
        self.assertFalse([w for w in api.writes if w[1].endswith("/execute")])

    def test_missing_affiliation_removes_nothing(self):
        api = FakeApi()
        plan_id, _ = self.plan(api, OPEN)
        missing = live_sources(self.dir / "m", affiliation_file=False)
        self.assertEqual(self.plan(api, missing)[1], {"skip:affiliation_source_unavailable": 1})
        with self.assertRaises(SystemExit):
            self.apply(api, plan_id, missing)
        # firstmate 021: one user with no verdict is skipped; it does not stop the run
        no_verdict = live_sources(self.dir / "n", affiliation={"161128": {"verdict": "none", "evidence": []}})
        self.assertEqual(self.plan(api, no_verdict)[1], {"skip:affiliation_unknown": 1})
        _, counts = self.apply(api, plan_id, no_verdict)
        self.assertEqual(counts, {"withheld:affiliation_unknown": 1, "withheld_sets": 1})
        self.assertFalse([w for w in api.writes if w[1].endswith("/execute")])
        self.assertEqual(api.sender.sent, [])

    def test_affiliation_only_holds_rows_that_would_be_removed(self):
        api = FakeApi()
        evidence = [{"org": "Sony Music Publishing", "source": "pro-registry"}]
        excl = live_sources(self.dir / "s", affiliation={UID: {"verdict": "verified_org", "evidence": evidence}})
        unverified = row(row_id="r2:Mixing", request_id="r2", evidence={})
        (self.dir / "two").mkdir()
        manifest = write_manifest(self.dir / "two", [row(), unverified])
        rows = takeback.load_manifest(manifest)
        plan_id, counts = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=excl, argv=[],
                                        log=self.out.append)
        self.assertEqual(counts, {"skip:org_affiliated": 1, "skip:evidence_unverified": 1})
        listed = takeback.report(self.ledger, plan_id)["needs_human_review"]
        self.assertEqual([x["row_id"] for x in listed], [f"{RID}:Mixing"])
        no_verdict = live_sources(self.dir / "n", affiliation={})
        _, counts = takeback.plan(api, self.ledger, rows, manifest=manifest, excl=no_verdict, argv=[],
                                  log=self.out.append)
        self.assertEqual(counts, {"skip:affiliation_unknown": 1, "skip:evidence_unverified": 1})

    def test_malformed_proof_file_is_unavailable_not_a_crash(self):
        bad = self.dir / "bad"
        bad.mkdir()
        (bad / "proof.json").write_text(json.dumps({
            "generated_at": datetime.now(timezone.utc).isoformat(), "sources": ["intercom"], "entries": []}))
        excl = takeback.load_exclusions(proof_on_file=str(bad / "proof.json"), org_affiliation=str(bad / "a.json"),
                                        verify_db=str(bad / "v.sqlite3"))
        self.assertEqual(excl.unavailable, "proof_source_unavailable")
        api = FakeApi()
        self.assertEqual(self.plan(api, excl)[1], {"skip:proof_source_unavailable": 1})
        for verdict in (["none"], {"v": "none"}):
            malformed = live_sources(self.dir / "aff", affiliation={UID: {"verdict": verdict, "evidence": []}})
            self.assertEqual(malformed.unavailable, "affiliation_source_unavailable")

    def test_affiliated_user_is_skipped_and_listed_for_human_review(self):
        api = FakeApi()
        evidence = [{"org": "Sony Music Publishing", "source": "pro-registry"}]
        excl = live_sources(self.dir / "s", affiliation={UID: {"verdict": "verified_org", "evidence": evidence}})
        plan_id, counts = self.plan(api, excl)
        self.assertEqual(counts, {"skip:org_affiliated": 1})
        self.assertIn("affiliation=verified_org", self.out[-1])
        rep = takeback.report(self.ledger, plan_id)
        self.assertEqual(rep["needs_human_review"], [{"row_id": f"{RID}:Mixing", "user_id": UID, "role": "Mixing",
                                                      "track_id": TID, "affiliation": {"verdict": "verified_org",
                                                                                       "evidence": evidence}}])
        claimed = live_sources(self.dir / "c", affiliation={UID: {"verdict": "claimed_unverified", "evidence": []}})
        plan2, counts2 = self.plan(api, claimed)
        self.assertEqual(counts2, {"would_remove": 1})
        self.assertIn("affiliation=claimed_unverified", self.out[-1])
        self.assertEqual(takeback.report(self.ledger, plan2)["needs_human_review"], [])


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
        # firstmate 012/014: rows carry checked evidence for their own role; every name cited
        # to the user is quoted in the recorded evidence note
        for r in rows:
            for name in (r.get("evidence") or {}).get("names") or []:
                self.assertIn(name.lower(), r["evidence"]["note"].lower(), r["row_id"])
        verified = [r for r in rows if takeback.evidence_verified(r)]
        # 5 excluded by review (alias risk / live edition / press naming the claimant) and 9 more
        # because their users sent documents in Intercom (captain 013); the rest stay unverified
        # and can never pass the gate
        self.assertEqual(sum(1 for r in rows if r.get("excluded")), 14)
        live = [r for r in verified if not r.get("excluded")]
        self.assertEqual(len(live), 10)
        self.assertEqual({r["user_id"] for r in live}, {"197122", "161128", "182594", "150514"})
        self.assertEqual({r["evidence"]["verified"] for r in live}, {"public_page", "trusted_dsp_only"})
        doc_users, _ = waves.load_doc_submitted(MANIFEST_DIR / "doc-submitted-r1.json")
        self.assertFalse([r["row_id"] for r in live if r["user_id"] in doc_users])
        ganas = next(r for r in rows if r["row_id"].startswith("64fce28d"))
        self.assertEqual((ganas["evidence_url"], takeback.evidence_label(ganas)),
                         ("https://listen.tidal.com/track/396743891", "Spotify and Tidal credits"))

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
        payloads = waves.assemble(population, watch, editing_ask)
        self.assertLess(len(payloads), 450)
        # captain 013: nobody who already sent a document, and no human-approved request, is asked
        doc = waves.load_doc_submitted(MANIFEST_DIR / "doc-submitted-r1.json")
        merged = waves.merge_unremoved(population, takeback.load_manifest(MANIFEST_DIR / "takeback-r1.jsonl"), set())
        before = waves.assemble(merged, watch, editing_ask)
        after = waves.assemble(merged, watch, editing_ask, doc=doc)
        self.assertEqual((len(before), sum(p["paying"] for p in before)), (417, 141))
        self.assertEqual((len(after), sum(p["paying"] for p in after)), (219, 46))
        self.assertFalse({p["user"]["id"] for p in after} & doc[0])
        self.assertFalse({i for p in after for i in p["request_ids_all"]} & doc[1])
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
