#!/usr/bin/env python3
"""Unit tests for scripts/credit_review (AI credit reviewer + approval auditor).

Stdlib unittest, no network: the admin API and the model are faked. Run:
    python3 scripts/tests/test_credit_review.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import admin as admin_api  # noqa: E402
from credit_review.evidence import (  # noqa: E402
    CONFIRMED, CONTRADICTED, OTHERS_ONLY, UNVERIFIABLE, EvidenceBuilder, classify_roles,
)
from credit_review.judge import Judge, JudgeResult, parse_answer  # noqa: E402
from credit_review.ledger import Ledger  # noqa: E402
from credit_review.policy import (  # noqa: E402
    approver_identity_alert, combine, deterministic, facts_from_record,
)
from credit_review.roles import family_of, names_match  # noqa: E402
from credit_review import runner as runner_mod  # noqa: E402
from credit_review.runner import (  # noqa: E402
    Config, fetch_approved_window, profile_burst_alerts, record, render_digest, run_audit, run_review, sampled,
)

NOW = datetime(2026, 10, 11, 3, 0, tzinfo=timezone.utc)
PID_BAD = "94ad2ad2-0be9-4b8e-94a6-dc85eb100310"
PID_GOOD = "11111111-2222-3333-4444-555555555555"
ART_SMALL = "art-small"
ART_STAR = "art-star"


def track(pop, artists=(ART_SMALL,)):
    """A catalog track (GET /admin/track/<id>)."""
    doc = {"artists": [{"id": a, "name": a} for a in artists]}
    if pop is not None:
        doc["popularity"] = pop
    return doc


TRACKS = {"t1": track(88), "t2": track(70), "t3": track(10), "t9": track(75)}


def raw(name, role, source="tidal", rid="x", pop=0):
    return {"profile": {"id": rid, "name": name, "source": source, "popularity": pop},
            "recording": {"id": "r", "title": "t", "source": source}, "credit": role}


def request(rid, *, pid=PID_BAD, track="t1", roles=("Mixing",), pop=80, status="approved",
            approved=True, risk=5.0, updated=None, created=None, title="Song", artists=("Big Star",)):
    return {
        "id": rid, "profileId": pid, "trackId": track, "status": status,
        "spotifyTrackTitle": title, "spotifyPopularity": pop,
        "spotifyTrackArtists": [{"id": "a", "name": a} for a in artists],
        "credits": list(roles), "metadata": {"isrc": "US1", "label": "L", "releaseDate": "2026-01-01"},
        "verificationData": {"is_approved": approved, "total_risk_percent": risk, "rule_risk_percent": {}},
        "updatedAt": updated or (NOW - timedelta(minutes=10)).isoformat().replace("+00:00", "Z"),
        "createdAt": created or (NOW - timedelta(minutes=20)).isoformat().replace("+00:00", "Z"),
        "profile": {"name": "stillfloo" if pid == PID_BAD else "Real Engineer"},
        "user": {"email": "secret@example.com"}, "workspace": {"email": "secret@example.com"},
    }


class FakeAdmin:
    """Answers the four GET shapes the reviewer uses."""

    def __init__(self, requests, raw_by_track, profiles, tracks=None):
        self.requests = requests
        self.raw_by_track = raw_by_track
        self.profiles = profiles
        self.tracks = TRACKS if tracks is None else tracks
        self.unreadable: set[str] = set()   # ids whose read fails (a 5xx); an absent id answers 404
        self.transient_404: dict[str, int] = {}
        self.raw_404: set[str] = set()      # tracks whose raw-credits read answers 404   # id -> how many reads answer 404 before it is served
        self.paths = []

    def get(self, path, params=None):
        self.paths.append((path, dict(params or {})))
        if path == "/admin/credit-requests":
            params = params or {}
            rows = [r for r in self.requests if r["status"] == params.get("status")]
            if params.get("profilesIds"):
                rows = [r for r in rows if r["profileId"] in params["profilesIds"].split(",")]
            rows.sort(key=lambda r: r["updatedAt"], reverse=True)
            limit, page = int(params.get("limit", 200)), int(params.get("page", 1))
            return {"items": rows[(page - 1) * limit: page * limit]}
        if path.startswith("/admin/track/") and path.endswith("/raw-credits"):
            if path.split("/")[3] in self.raw_404:
                raise admin_api.NotFound("404")
            return {"items": self.raw_by_track.get(path.split("/")[3], [])}
        if path.startswith("/admin/track/") and path.count("/") == 3:
            tid = path.split("/")[3]
            if self.transient_404.get(tid, 0) > 0:
                self.transient_404[tid] -= 1
                raise admin_api.NotFound("404")
            if tid in self.unreadable:
                raise admin_api.AdminError("503")
            if tid not in self.tracks:
                raise admin_api.NotFound("404")
            return self.tracks[tid]
        if path.startswith("/admin/profile/"):
            pid = path.split("/")[3]
            if self.transient_404.get(pid, 0) > 0:
                self.transient_404[pid] -= 1
                raise admin_api.NotFound("404")
            if pid in self.unreadable:
                raise admin_api.AdminError("503")
            if pid not in self.profiles:
                raise admin_api.NotFound("404")
            return self.profiles[pid]
        raise AssertionError(f"unexpected path {path}")


PROFILES = {
    PID_BAD: {"name": "stillfloo", "rawProfiles": [{"id": PID_BAD, "source": "muso"}], "knownAsNames": []},
    PID_GOOD: {"name": "Real Engineer", "rawProfiles": [{"id": "T9", "source": "tidal"}], "knownAsNames": ["R. Engineer"]},
    ART_SMALL: {"name": "Small Artist", "popularity": 10, "rawProfiles": []},
    ART_STAR: {"name": "Star", "popularity": 95, "rawProfiles": []},
}


class FakeJudge:
    def __init__(self, result: JudgeResult):
        self.result = result
        self.calls = 0
        self.evidence = []

    def judge(self, mode, evidence):
        self.calls += 1
        self.evidence.append(evidence)
        return self.result

    def judge_many(self, mode, evidences, ids):
        """One call answering every claim with the same result (cost split)."""
        self.calls += 1
        self.evidence.extend(evidences)
        share = (self.result.cost_usd / len(ids)) if self.result.cost_usd is not None else None
        return {rid: JudgeResult(**{**self.result.__dict__, "cost_usd": share, "batch_size": len(ids)}) for rid in ids}


def jr(verdict, conf=0.9, findings=(), cited=(), ok=True, ident=None, error=None, cost=0.001):
    return JudgeResult(ok=ok, verdict=verdict, confidence=conf, findings=list(findings),
                       cited_urls=list(cited), model="fake", cost_usd=cost, identity_consistent=ident, error=error)


class RoleTests(unittest.TestCase):
    def test_families(self):
        cases = {
            "Mixing": "mix", "mixing engineer": "mix", "mixer": "mix", "Mastering": "master",
            "masterer": "master", "Immersive Mastering": "immersive_master", "immersive mix engineer": "immersive_mix",
            "Remastering": "remaster", "assistant mixer": "assistant", "Producer": "producer",
            "Co-Producer": "producer", "Executive Producer": "exec_producer", "Composer": "writer",
            "composerlyricist": "writer", "Lyricist": "writer", "A&R": "anr", "Recorder": "engineer",
            "recording engineer": "engineer", "primary artist": "artist", "publisher": "org", "label": "org",
        }
        for role, fam in cases.items():
            self.assertEqual(family_of(role), fam, role)

    def test_names(self):
        self.assertTrue(names_match("Serban Ghenea", "GHENEA SERBAN"))
        self.assertTrue(names_match("Jon Castelli", "Jon P. Castelli"))
        self.assertTrue(names_match("Beyoncé", "Beyonce"))
        self.assertFalse(names_match("Jon", "Jon Castelli"))
        self.assertFalse(names_match("stillfloo", "Serban Ghenea"))
        self.assertFalse(names_match("", "x"))


class ClassifyTests(unittest.TestCase):
    def test_statuses(self):
        raws = [raw("Serban Ghenea", "mixing engineer"), raw("Someone", "producer", "spotify"),
                raw("stillfloo", "mastering", "muso"), raw("Real Engineer", "mastering engineer", "mlc")]
        out = {r.claimed_role: r.status for r in classify_roles(
            ["Mixing", "Producer", "Mastering", "Arranger"], raws, ["stillfloo"], set())}
        self.assertEqual(out["Mixing"], CONTRADICTED)
        self.assertEqual(out["Producer"], OTHERS_ONLY)
        # Muso-sourced rows are never evidence; another person's mastering is a contradiction.
        self.assertEqual(out["Mastering"], CONTRADICTED)
        self.assertEqual(out["Arranger"], UNVERIFIABLE)

    def test_confirmed_by_name_and_by_raw_profile_link(self):
        raws = [raw("R. Engineer", "mixer", "tidal", rid="zzz"), raw("Other", "mastering engineer", "jaxsta", rid="T9")]
        out = {r.claimed_role: r.status for r in classify_roles(
            ["Mixing", "Mastering"], raws, ["Real Engineer", "R. Engineer"], {("jaxsta", "T9")})}
        self.assertEqual(out, {"Mixing": CONFIRMED, "Mastering": CONFIRMED})


class TrustedSourceAllowlistTests(unittest.TestCase):
    def test_only_allowlisted_sources_corroborate(self):
        # QA on hydra#1142: a denylist let a "user_import" raw credit for the
        # claimant certify the credit as CONFIRMED.
        for src in ("user_import", "muso", "discogs_scrape", "", "SpotifyX"):
            out = classify_roles(["Mixing"], [raw("stillfloo", "mixing engineer", src)], ["stillfloo"], set())
            self.assertEqual(out[0].status, UNVERIFIABLE, src)
        for src in ("spotify", "Tidal", "MLC", "jaxsta"):
            out = classify_roles(["Mixing"], [raw("stillfloo", "mixing engineer", src)], ["stillfloo"], set())
            self.assertEqual(out[0].status, CONFIRMED, src)

    def test_unknown_source_raw_profile_is_not_an_identity_anchor(self):
        profiles = {PID_BAD: {"name": "x", "rawProfiles": [{"id": "u", "source": "user_import"}], "knownAsNames": []}}
        ev = EvidenceBuilder(FakeAdmin([], {"t1": []}, profiles), now=NOW).build(request("r1"))
        self.assertTrue(ev.profile.muso_only)


class PolicyTests(unittest.TestCase):
    def ev(self, raws, **kw):
        admin = FakeAdmin([], {"t1": raws}, PROFILES, {"t1": track(kw.get("pop", 80))})
        return EvidenceBuilder(admin, now=NOW).build(request("r1", **kw))

    def test_contradiction_is_deterministic(self):
        ev = self.ev([raw("Serban Ghenea", "mixing engineer")])
        d = deterministic(ev, "audit")
        self.assertEqual(d.verdict, "CONTRADICTED")
        self.assertFalse(d.needs_model)
        self.assertIn("Serban Ghenea", d.reasons[0])
        self.assertEqual(deterministic(ev, "review").verdict, "REJECT-RECOMMENDED")

    def test_confirmation_is_deterministic(self):
        ev = self.ev([raw("Real Engineer", "mixer")], pid=PID_GOOD)
        self.assertEqual(deterministic(ev, "audit").verdict, "CONFIRMED")
        self.assertEqual(deterministic(ev, "review").verdict, "APPROVE-RECOMMENDED")

    def test_review_confirmation_with_red_flags_needs_a_human(self):
        # QA on hydra#1142: a catalog name match plus a red flag (here: the
        # row was approved despite a validator decline) must not be
        # APPROVE-RECOMMENDED.
        ev = self.ev([raw("Real Engineer", "mixer")], pid=PID_GOOD, approved=False, risk=58)
        self.assertEqual(deterministic(ev, "audit").verdict, "CONFIRMED")
        d = deterministic(ev, "review")
        self.assertEqual(d.verdict, "NEEDS-HUMAN")
        self.assertTrue(any("approved_despite_validator_decline" in r for r in d.reasons))
        # A stillfloo-pattern profile too.
        from credit_review.policy import Facts
        f = Facts(big_track=True, any_contradicted=False, all_confirmed=True, any_others_only=False,
                  stillfloo_pattern=True, flags=["stillfloo_pattern"], confirmed_sources=["tidal"])
        self.assertEqual(deterministic(f, "review").verdict, "NEEDS-HUMAN")

    def test_builder_computes_velocity_for_confirmed_rows_so_the_clamp_sees_the_pattern(self):
        # QA on hydra#1142: a Muso-only profile spraying one-person claims on
        # many big tracks, with a name-matched Tidal credit on a small track,
        # must be NEEDS-HUMAN end to end (builder -> policy), not only when the
        # Facts are hand-built.
        # The burst's big share comes from the CATALOG: every request row
        # carries a client-sourced popularity of 0.
        burst = [request(f"v{i}", pid=PID_BAD, track=f"x{i}", pop=0,
                         roles=("Mixing",), artists=(f"Artist {i}",), status="approved") for i in range(25)]
        target = request("tgt", pid=PID_BAD, track="t1", pop=20, status="unverified", approved=False, risk=40)
        tracks = {f"x{i}": track(80 if i < 10 else 20) for i in range(25)} | {"t1": track(20)}
        admin = FakeAdmin(burst + [target], {"t1": [raw("stillfloo", "mixing engineer", "tidal")]}, PROFILES, tracks)
        ev = EvidenceBuilder(admin, now=NOW).build(target)
        self.assertFalse(ev.big_track)
        self.assertAlmostEqual(ev.profile.big_share_7d, 10 / 26)
        self.assertTrue(ev.all_confirmed)
        self.assertTrue(ev.profile.stillfloo_pattern, ev.profile.as_dict())
        self.assertEqual(deterministic(ev, "review").verdict, "NEEDS-HUMAN")

    def test_review_never_approves_big_track_on_web_alone(self):
        ev = self.ev([], pid=PID_GOOD, pop=85)
        self.assertTrue(ev.big_track)
        j = jr("APPROVE-RECOMMENDED", 0.99,
               findings=[{"source_url": "https://www.discogs.com/r/1", "effect": "supports"},
                         {"source_url": "https://allmusic.com/x", "effect": "supports"}],
               cited=["https://www.discogs.com/r/1", "https://allmusic.com/x"])
        d = combine(ev, "review", j)
        self.assertEqual(d.verdict, "NEEDS-HUMAN")
        self.assertTrue(any("big track" in r for r in d.reasons))
        # Same evidence on a small track may be approve-recommended.
        ev_small = self.ev([], pid=PID_GOOD, pop=20)
        self.assertEqual(combine(ev_small, "review", j).verdict, "APPROVE-RECOMMENDED")

    def test_invented_urls_do_not_count(self):
        ev = self.ev([], pid=PID_GOOD, pop=20)
        j = jr("APPROVE-RECOMMENDED", 0.99,
               findings=[{"source_url": "https://www.discogs.com/r/1", "effect": "supports"},
                         {"source_url": "https://allmusic.com/x", "effect": "supports"}],
               cited=[])  # the search returned nothing: the URLs were written by the model
        self.assertEqual(combine(ev, "review", j).verdict, "NEEDS-HUMAN")

    def test_same_domain_different_page_is_not_a_citation(self):
        # QA on hydra#1142: search cited generic Discogs/AllMusic pages; the
        # model named different, credit-specific pages on those hosts. Those
        # findings must not count.
        ev = self.ev([], pid=PID_GOOD, pop=20)
        cited = ["https://www.discogs.com/search?q=x", "https://www.allmusic.com/"]
        invented = [{"source_url": "https://www.discogs.com/release/123-Real-Engineer", "effect": "supports"},
                    {"source_url": "https://www.allmusic.com/album/credits-mw000", "effect": "supports"}]
        self.assertEqual(combine(ev, "review", jr("APPROVE-RECOMMENDED", 0.99, findings=invented, cited=cited)).verdict,
                         "NEEDS-HUMAN")
        ev_big = self.ev([], pop=85)
        fake_con = [{"source_url": "https://www.discogs.com/release/999-Someone-Else", "effect": "contradicts"}]
        self.assertNotEqual(combine(ev_big, "audit", jr("CONTRADICTED", 0.95, findings=fake_con, cited=cited)).verdict,
                            "CONTRADICTED")
        # The exact cited pages, written with harmless variations, do count.
        exact = [{"source_url": "http://discogs.com/search?q=x&utm_source=openai#top", "effect": "supports"},
                 {"source_url": "https://allmusic.com", "effect": "supports"}]
        self.assertEqual(combine(ev, "review", jr("APPROVE-RECOMMENDED", 0.99, findings=exact, cited=cited)).verdict,
                         "APPROVE-RECOMMENDED")

    def test_normalize_url(self):
        from credit_review.judge import normalize_url
        self.assertEqual(normalize_url("https://WWW.Tidal.com/album/1/credits/?utm_source=openai#x"),
                         "tidal.com/album/1/credits")
        self.assertEqual(normalize_url("https://tidal.com:443/album/1/credits"), "tidal.com/album/1/credits")
        self.assertNotEqual(normalize_url("https://tidal.com/album/1"), normalize_url("https://tidal.com/album/2"))
        self.assertEqual(normalize_url("ftp://tidal.com/x"), "")
        self.assertEqual(normalize_url("not a url"), "")
        # QA on hydra#1142: urlparse accepts an invalid port and only .port
        # raises - it must normalize to "" instead of crashing the audit.
        self.assertEqual(normalize_url("https://discogs.com:abc/release/123"), "")
        self.assertEqual(normalize_url(None), "")
        self.assertEqual(normalize_url(123), "")

    def test_invalid_port_citation_does_not_abort_combine(self):
        ev = self.ev([], pid=PID_GOOD, pop=20)
        bad = "https://discogs.com:abc/release/123"
        j = jr("APPROVE-RECOMMENDED", 0.99, findings=[{"source_url": bad, "effect": "supports"}],
               cited=[bad, "https://allmusic.com/x"])
        self.assertEqual(combine(ev, "review", j).verdict, "NEEDS-HUMAN")

    def test_muso_pages_are_not_evidence(self):
        ev = self.ev([], pid=PID_GOOD, pop=20)
        urls = ["https://credits.muso.ai/profile/x", "https://muso.ai/track/y"]
        j = jr("APPROVE-RECOMMENDED", 0.99, findings=[{"source_url": u, "effect": "supports"} for u in urls], cited=urls)
        self.assertEqual(combine(ev, "review", j).verdict, "NEEDS-HUMAN")

    def test_model_error_holds(self):
        ev = self.ev([], pid=PID_GOOD, pop=85)
        self.assertEqual(combine(ev, "review", jr(None, ok=False, error="boom")).verdict, "NEEDS-HUMAN")
        self.assertEqual(combine(ev, "audit", jr(None, ok=False, error="boom")).verdict, "SUSPECT")

    def test_web_contradiction(self):
        ev = self.ev([], pop=85)
        j = jr("CONTRADICTED", 0.9, findings=[{"source_url": "https://www.discogs.com/r/2", "effect": "contradicts"}],
               cited=["https://www.discogs.com/r/2"])
        d = combine(ev, "audit", j)
        self.assertEqual(d.verdict, "CONTRADICTED")
        self.assertEqual(d.basis, "web_contradiction")

    def test_muso_only_identity_on_big_track_is_suspect_without_model(self):
        ev = self.ev([], pop=85)
        self.assertEqual(combine(ev, "audit", None).verdict, "SUSPECT")
        ev_small = self.ev([], pid=PID_GOOD, pop=10)
        self.assertEqual(combine(ev_small, "audit", None).verdict, "UNVERIFIABLE")

    def test_model_sees_no_pii(self):
        ev = self.ev([raw("Serban Ghenea", "mixing engineer")])
        blob = json.dumps(ev.for_model())
        self.assertNotIn("secret@example.com", blob)
        self.assertNotIn("email", blob)


class ApproverTests(unittest.TestCase):
    def rec(self, **approval):
        r = request("a", approved=False)
        r["metadata"]["approval"] = approval
        return approver_identity_alert(r)

    def test_legacy_rows_without_a_record(self):
        self.assertIsNone(approver_identity_alert(request("a", approved=True)))
        self.assertIn("approver identity not recorded", approver_identity_alert(request("a", approved=False)))
        self.assertIsNone(approver_identity_alert(request("a", status="unverified", approved=False)))

    def test_core_backend_approval_record(self):
        # Shape from core-backend #10307 (services/credit-requests/approvalRecord).
        self.assertIsNone(self.rec(via="validator", at="2026-10-11T05:29:19Z"))
        self.assertIn("forbidden", self.rec(via="admin", account="agent-hydra-main@muso.ai", isAgent=True))
        self.assertIn("forbidden", self.rec(via="admin", account="ADMIN_U@muso.ai"))
        self.assertIn("agent token", self.rec(via="admin", account="ops-bot@muso.ai", isAgent=True))
        self.assertIn("unknown identity", self.rec(via="admin", account="mallory@evil.test", isAgent=False))
        self.assertIn("without an approver account", self.rec(via="low_risk_approve"))
        self.assertIsNone(self.rec(via="admin", account="Jan@muso.ai", isAgent=False, requester="jan@muso.ai"))


class KnownAgentApproverTests(unittest.TestCase):
    """A registered automation's own account is a known AGENT approver: clean
    approvals pass, rule breaks alert with the automation and the rule."""

    TERMS = ("edit", "compil", "assembl", "pro tools", "protools")
    DECIDER = "agent-credit-decider@muso.ai"

    def alert(self, *, account=DECIDER, track="t3", roles=("Mixing",), rules=None, raws=None,
              approved=("credit-trust-decide", "uvn-under30"), doc_required=(), proof_id=None, terms=TERMS):
        from credit_review.policy import AgentApprovalContext
        r = request("a1", pid=PID_GOOD, track=track, roles=roles, approved=False)
        r["verificationData"]["rule_risk_percent"] = dict(rules or {})
        r["metadata"]["approval"] = {"via": "admin", "account": account, "isAgent": True}
        raws = {"t3": [raw("Real Engineer", "mixer")], "t1": []} if raws is None else raws
        ev = EvidenceBuilder(FakeAdmin([], raws, PROFILES, TRACKS), now=NOW).build(r)
        proofs = {"a1": proof_id} if proof_id else {}
        return approver_identity_alert(r, ev, AgentApprovalContext(frozenset(approved), terms, frozenset(doc_required),
                                                                   proofs))

    def test_clean_registered_automation_approval_is_not_alerted(self):
        self.assertIsNone(self.alert())
        self.assertIsNone(self.alert(account="agent-uvn-cron@muso.ai"))
        self.assertIsNone(self.alert(doc_required=("a1",), proof_id="intercom:proof-7"))

    def test_only_the_deciders_recorded_proof_counts(self):
        a = self.alert(account="agent-uvn-cron@muso.ai", doc_required=("a1",), proof_id="intercom:proof-7")
        self.assertIn("automation uvn-under30", a)
        self.assertIn("documentation-required row approved without a proof id", a)

    def test_more_than_ten_rule_breaks_report_the_total(self):
        reqs = []
        for i in range(12):
            r = request(f"b{i}", pid=PID_GOOD, track="t1", roles=("Mixing",), approved=False)
            r["metadata"]["approval"] = {"via": "admin", "account": self.DECIDER, "isAgent": True}
            reqs.append(r)
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(str(Path(tmp) / "l.sqlite3"))
            alerts, _ = run_audit(FakeAdmin(reqs, {"t1": []}, PROFILES, TRACKS), ledger, None,
                                  Config(mode="audit", sample_rate=0.0), window_min=90, now=NOW)
            ledger.close()
        self.assertEqual(sum("registered automation approval broke a rule" in a for a in alerts), 10)
        self.assertIn("... and 2 more automation rule break(s) (12 in total", " ".join(alerts))

    def test_each_rule_break_alerts_naming_the_automation_and_rule(self):
        cases = {
            "the validator declined it": dict(rules={"reject_role_mismatch": 100}),
            "validator conflict (review_role_credited_to_other_at_trusted_source)":
                dict(rules={"review_role_credited_to_other_at_trusted_source": 80}),
            "big track approved without trusted-source confirmation": dict(track="t1"),
            "editorial role without a trusted credit for the claimant (Vocal Editing)": dict(roles=("Mixing", "Vocal Editing")),
            "documentation-required row approved without a proof id": dict(doc_required=("a1",)),
            "editorial-role rule could not be checked": dict(terms=None),
        }
        for rule, kw in cases.items():
            a = self.alert(**kw)
            self.assertIsNotNone(a, rule)
            self.assertTrue(a.startswith(f"automation credit-trust-decide ({self.DECIDER}) approval broke:"), a)
            self.assertIn(rule, a)

    def test_unknown_agent_and_unapproved_automation_alert(self):
        self.assertIn("agent token", self.alert(account="agent-someone-else@muso.ai"))
        a = self.alert(account="agent-uvn-cron@muso.ai", approved=("credit-trust-decide",))
        self.assertIn("automation uvn-under30", a)
        self.assertIn("not approved:true", a)

    def test_registry_reading_fails_closed(self):
        from credit_review.policy import approved_automations
        with tempfile.TemporaryDirectory() as tmp:
            reg = Path(tmp) / "registry.json"
            self.assertEqual(approved_automations(reg), frozenset())
            reg.write_text(json.dumps({"automations": {
                "credit-trust-decide": {"approved": True, "approved_by": "captain", "approval_ref": "x"},
                "uvn-under30": {"approved": False, "approved_by": "Nick", "approval_ref": "y"},
                "other": {"approved": True, "approved_by": "", "approval_ref": "z"}}}))
            self.assertEqual(approved_automations(reg), frozenset({"credit-trust-decide"}))

    def test_audit_run_routes_automation_breaks_to_their_own_alert(self):
        r = request("a2", pid=PID_GOOD, track="t1", roles=("Mixing",), approved=False)
        r["metadata"]["approval"] = {"via": "admin", "account": self.DECIDER, "isAgent": True}
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(str(Path(tmp) / "l.sqlite3"))
            alerts, _ = run_audit(FakeAdmin([r], {"t1": []}, PROFILES, TRACKS), ledger, None,
                                  Config(mode="audit", sample_rate=0.0), window_min=90, now=NOW)
            ledger.close()
        mine = [a for a in alerts if "registered automation approval broke a rule" in a]
        self.assertEqual(len(mine), 1, alerts)
        self.assertIn("a2: automation credit-trust-decide", mine[0])
        self.assertIn("big track approved without trusted-source confirmation", mine[0])
        self.assertFalse(any("forbidden or unknown approver" in a for a in alerts), alerts)


class JudgeTests(unittest.TestCase):
    def test_parse(self):
        p = parse_answer('blah {"verdict":"suspect","confidence":1.4,"findings":[{"source_url":"u","effect":"Supports"}]} x', "audit")
        self.assertEqual(p["verdict"], "SUSPECT")
        self.assertEqual(p["confidence"], 1.0)
        self.assertEqual(p["findings"][0]["effect"], "supports")
        with self.assertRaises(ValueError):
            parse_answer('{"verdict":"APPROVE-RECOMMENDED"}', "audit")
        with self.assertRaises(ValueError):
            parse_answer("no json", "review")
        salvaged = parse_answer('{"verdict":"CONTRADICTED","confidence":0.8,"findings":[{"says":"he said "hi""}]}', "audit")
        self.assertEqual(salvaged["verdict"], "CONTRADICTED")
        self.assertEqual(salvaged["findings"], [])

    def test_interpret_reads_annotations_and_cost(self):
        data = {"usage": {"cost": 0.012, "prompt_tokens": 10, "completion_tokens": 5},
                "choices": [{"message": {"content": '{"verdict":"CONFIRMED","confidence":0.9,"findings":[]}',
                                         "annotations": [{"type": "url_citation", "url_citation": {"url": "https://tidal.com/a"}}]}}]}
        res = Judge.interpret(data, "audit", JudgeResult(ok=False))
        self.assertTrue(res.ok)
        self.assertEqual(res.cited_urls, ["https://tidal.com/a"])
        self.assertEqual(res.cost_usd, 0.012)

    def test_payload_has_web_plugin_and_no_tools(self):
        body = Judge("m", web=True).payload("audit", {"x": 1})
        self.assertEqual(body["plugins"][0]["id"], "web")
        self.assertNotIn("tools", body)
        self.assertNotIn("plugins", Judge("m", web=False).payload("audit", {"x": 1}))

    def test_no_key_is_an_error_not_a_pass(self):
        import os
        env = dict(os.environ)
        try:
            os.environ.pop("OPENROUTER_API_KEY", None)
            os.environ["CREDIT_REVIEW_KEY_FILE"] = "/nonexistent"
            res = Judge("m").judge("audit", {})
        finally:
            os.environ.clear()
            os.environ.update(env)
        self.assertFalse(res.ok)
        self.assertIn("no OpenRouter key", res.error)


class AdminClientTests(unittest.TestCase):
    def test_refuses_non_admin_path(self):
        with self.assertRaises(admin_api.AdminError):
            admin_api.AdminClient(script="/bin/false").get("/api/v3/anything")

    def test_only_ever_issues_get(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "wrapper.sh"
            log = Path(tmp) / "argv"
            fake.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> {log}\n'
                            'echo \'{"http_status":200,"body":{"data":{"items":[]}}}\'\n')
            fake.chmod(0o755)
            c = admin_api.AdminClient(script=str(fake))
            self.assertEqual(c.get("/admin/credit-requests", {"status": "approved"}), {"items": []})
            argv = log.read_text()
            self.assertIn("call GET /admin/credit-requests?status=approved", argv)
            self.assertNotIn(" PUT ", argv)

    def test_404_is_not_found_and_5xx_is_a_plain_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "wrapper.sh"
            for status, exc in ((404, admin_api.NotFound), (503, admin_api.AdminError)):
                fake.write_text(f"#!/usr/bin/env bash\necho '{{\"http_status\":{status},\"body\":{{}}}}'\n")
                fake.chmod(0o755)
                with self.assertRaises(exc) as ctx:
                    admin_api.AdminClient(script=str(fake)).get("/admin/profile/x")
                self.assertEqual(isinstance(ctx.exception, admin_api.NotFound), status == 404)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Ledger(str(Path(self.tmp.name) / "l.sqlite3"))

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def fixture(self):
        reqs = [
            request("bad-big", track="t1", pop=88, title="BIRDS OF A FEATHER", artists=("Billie Eilish",)),
            request("good", pid=PID_GOOD, track="t2", pop=70),
            request("small-unknown", pid=PID_GOOD, track="t3", pop=10, roles=("Producer",)),
            request("declined-approved", pid=PID_GOOD, track="t2", pop=30, approved=False, risk=58.0),
            request("old", track="t1", updated=(NOW - timedelta(hours=5)).isoformat().replace("+00:00", "Z")),
        ]
        raws = {"t1": [raw("Jon Castelli", "mixing engineer")], "t2": [raw("Real Engineer", "mixer")], "t3": []}
        return FakeAdmin(reqs, raws, PROFILES)

    def test_audit_alerts_once_and_is_read_only(self):
        admin = self.fixture()
        judge = FakeJudge(jr("SUSPECT", 0.5))
        cfg = Config(mode="audit", sample_rate=0.0)
        alerts, stats = run_audit(admin, self.ledger, judge, cfg, window_min=90, now=NOW)
        self.assertEqual(stats.scanned, 4)  # "old" is outside the window
        joined = "\n".join(alerts)
        self.assertIn("CONTRADICTED on big track", joined)
        self.assertIn("BIRDS OF A FEATHER", joined)
        self.assertIn("no recorded approver", joined)
        self.assertIn("declined-approved", joined)
        # Contradiction and confirmation are decided without the model; the small
        # unknown is sampled out at rate 0, so the model is never called.
        self.assertEqual(judge.calls, 0)
        self.assertEqual(stats.verdicts.get("CONTRADICTED"), 1)
        self.assertEqual(stats.verdicts.get("CONFIRMED"), 2)
        # Read-only: every admin call was a GET to a read path.
        for path, _ in admin.paths:
            self.assertTrue(path.startswith("/admin/credit-requests") or path.startswith("/admin/track/")
                            or path.startswith("/admin/profile/"), path)
        # Second run: nothing new, no repeated alert.
        alerts2, stats2 = run_audit(admin, self.ledger, judge, cfg, window_min=90, now=NOW)
        self.assertEqual(alerts2, [])
        self.assertEqual(stats2.skipped_seen, 4)
        q = self.ledger.db.execute("SELECT request_id FROM rereview_queue").fetchall()
        self.assertEqual([r[0] for r in q], ["bad-big"])

    def test_big_tracks_always_model_checked_when_undecided(self):
        reqs = [request("u-big", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",))]
        admin = FakeAdmin(reqs, {"t9": []}, PROFILES)
        judge = FakeJudge(jr("SUSPECT", 0.6))
        run_audit(admin, self.ledger, judge, Config(mode="audit", sample_rate=0.0), window_min=90, now=NOW)
        self.assertEqual(judge.calls, 1)

    def test_budget_stops_model_calls(self):
        reqs = [request(f"u{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(5)]
        admin = FakeAdmin(reqs, {"t9": []}, PROFILES)
        judge = FakeJudge(jr("SUSPECT", 0.6, cost=1.0))
        alerts, stats = run_audit(admin, self.ledger, judge, Config(mode="audit", budget_usd=2.0), window_min=90,
                                  now=NOW, workers=1)
        self.assertEqual(judge.calls, 2)
        self.assertTrue(stats.budget_stopped)
        self.assertTrue(any("budget reached" in a for a in alerts))
        # Every approval is still recorded (catalog-only for the unjudged ones).
        self.assertEqual(stats.reviewed, 5)

    def test_daily_budget_spans_runs(self):
        reqs = [request(f"d{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(4)]
        admin = FakeAdmin(reqs[:2], {"t9": []}, PROFILES)
        judge = FakeJudge(jr("SUSPECT", 0.6, cost=1.0))
        run_audit(admin, self.ledger, judge, Config(mode="audit", budget_usd=10), window_min=90,
                  now=NOW, workers=1, daily_budget_usd=2.5)
        self.assertEqual(judge.calls, 2)
        admin.requests = reqs
        _, stats = run_audit(admin, self.ledger, judge, Config(mode="audit", budget_usd=10), window_min=90,
                             now=NOW, workers=1, daily_budget_usd=2.5)
        # Only $0.50 of the day is left and the dearest recorded call cost
        # $1.00, so no further call is launched (no overspend past the cap).
        self.assertEqual(judge.calls, 2)
        self.assertTrue(stats.budget_stopped)

    def test_cheap_first_call_never_lets_dear_calls_overspend_the_run_budget(self):
        # QA on hydra#1142: with the default workers=6, a $0.01 first call
        # followed by $1 calls launched seven calls and spent $6.01 of a
        # $1.50 budget. Calls run one at a time, so the cap holds.
        reqs = [request(f"p{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(8)]
        admin = FakeAdmin(reqs, {"t9": []}, PROFILES)

        class CheapThenDear(FakeJudge):
            def judge(self, mode, evidence):
                super().judge(mode, evidence)
                return jr("SUSPECT", 0.6, cost=0.01 if self.calls == 1 else 1.0)

        judge = CheapThenDear(None)
        alerts, stats = run_audit(admin, self.ledger, judge, Config(mode="audit", budget_usd=1.5), window_min=90,
                                  now=NOW)
        self.assertEqual(judge.calls, 2)
        self.assertAlmostEqual(stats.cost_usd, 1.01)
        self.assertTrue(stats.budget_stopped)
        self.assertEqual(stats.reviewed, 8)
        # Cheap calls still all run up to the budget.
        judge2 = FakeJudge(jr("SUSPECT", 0.6, cost=0.01))
        led2 = Ledger(":memory:")
        reqs2 = [request(f"q{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(8)]
        _, s2 = run_audit(FakeAdmin(reqs2, {"t9": []}, PROFILES), led2, judge2, Config(mode="audit", budget_usd=1.5),
                          window_min=90, now=NOW)
        led2.close()
        self.assertEqual(judge2.calls, 8)
        self.assertFalse(s2.budget_stopped)

    def test_eval_arm_budget_is_shared_across_parallel_rows(self):
        from credit_review import evaluate
        reqs = [request(f"e{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(6)]
        admin = FakeAdmin(reqs, {"t9": []}, PROFILES)
        judge = FakeJudge(jr("APPROVE-RECOMMENDED", 0.6, cost=0.04))
        orig = evaluate.Judge
        evaluate.Judge = lambda *a, **k: judge
        try:
            res = evaluate.run_arm(admin, self.ledger, [("known_good", r) for r in reqs], "fake", "full", "review",
                                   budget_usd=0.12, workers=6)
        finally:
            evaluate.Judge = orig
        self.assertLessEqual(res.stats.cost_usd, 0.12 + 1e-9)
        self.assertEqual(judge.calls, 2)  # $0.05 reserved per call
        self.assertTrue(res.stats.budget_stopped)

    def test_raw_credit_failure_is_retried_not_marked_reviewed(self):
        # QA on hydra#1142: a transient 503 on raw-credits must not record the
        # approval as reviewed with an empty catalog; it is retried (even
        # after leaving the window) and the trusted contradiction is found.
        reqs = [request("bad-big", track="t1", pop=88, title="BIRDS OF A FEATHER", artists=("Billie Eilish",))]

        class Flaky(FakeAdmin):
            down = True

            def get(self, path, params=None):
                if self.down and path.endswith("/raw-credits"):
                    raise admin_api.AdminError("admin GET /admin/track/t1/raw-credits returned HTTP 503")
                return super().get(path, params)

        admin = Flaky(reqs, {"t1": [raw("Jon Castelli", "mixing engineer")]}, PROFILES)
        cfg = Config(mode="audit", sample_rate=0.0)
        alerts, stats = run_audit(admin, self.ledger, None, cfg, window_min=90, now=NOW)
        self.assertFalse(self.ledger.reviewed("bad-big", "audit"))
        self.assertEqual((stats.reviewed, stats.errors), (0, 1))
        self.assertTrue(any("could NOT be audited" in a and "bad-big" in a for a in alerts), alerts)
        self.assertIn("NOT YET AUDITED: 1", render_digest(self.ledger, now=NOW))
        # Still down an hour later: retried, but not re-alerted.
        alerts2, _ = run_audit(admin, self.ledger, None, cfg, window_min=90, now=NOW + timedelta(hours=1))
        self.assertFalse(any("could NOT be audited" in a for a in alerts2))
        # Recovered 5h later, long outside the 90-min window.
        admin.down = False
        alerts3, stats3 = run_audit(admin, self.ledger, None, cfg, window_min=90, now=NOW + timedelta(hours=5))
        self.assertTrue(self.ledger.reviewed("bad-big", "audit"))
        self.assertEqual(stats3.verdicts.get("CONTRADICTED"), 1)
        self.assertTrue(any("CONTRADICTED on big track" in a for a in alerts3), alerts3)
        self.assertEqual(self.ledger.evidence_retry_count("audit")[0], 0)

    def test_review_is_advisory_and_refuses_phase2(self):
        reqs = [request("held", status="unverified", approved=False, risk=58, track="t1", pop=89)]
        admin = FakeAdmin(reqs, {"t1": [raw("Jon Castelli", "mixing engineer")]}, PROFILES)
        cards, stats = run_review(admin, self.ledger, FakeJudge(jr("NEEDS-HUMAN")), Config(mode="review", phase="advise"),
                                  limit=10, sample_approved=0, now=NOW)
        self.assertEqual(stats.verdicts, {"REJECT-RECOMMENDED": 1})
        self.assertTrue(cards and cards[0].startswith("AI REVIEW REJECT-RECOMMENDED"))
        with self.assertRaises(ValueError):
            run_review(admin, self.ledger, None, Config(mode="review", phase="auto-approve"), limit=1, sample_approved=0)

    def test_review_pages_past_already_reviewed_rows(self):
        # QA on hydra#1142: 21 stable held rows, limit 20 -> the 21st must be
        # reviewed on the second run, not skipped forever.
        reqs = [request(f"h{i:02d}", status="unverified", approved=False, risk=50, pid=PID_GOOD, track="t9",
                        updated=(NOW - timedelta(minutes=i)).isoformat().replace("+00:00", "Z")) for i in range(21)]
        admin = FakeAdmin(reqs, {"t9": []}, PROFILES)
        cfg = Config(mode="review", phase="shadow")
        _, s1 = run_review(admin, self.ledger, None, cfg, limit=20, sample_approved=0, now=NOW, page_size=20)
        _, s2 = run_review(admin, self.ledger, None, cfg, limit=20, sample_approved=0, now=NOW, page_size=20)
        self.assertEqual((s1.reviewed, s2.reviewed), (20, 1))
        self.assertTrue(self.ledger.reviewed("h20", "review"))

    def test_metrics_never_counts_unread_rows_as_reversals(self):
        # QA on hydra#1142: profiles beyond the read cap (or with an
        # incomplete list) must be "not checkable", not "removed".
        from credit_review.runner import render_metrics
        old = (NOW - timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for i in range(202):
            self.ledger.record({"request_id": f"f{i}", "mode": "audit", "phase": "live", "reviewed_at": old,
                                "verdict": "CONTRADICTED", "confidence": 0.9, "basis": "x", "big_track": True,
                                "profile_id": f"p{i}"})
        # Every flagged row is still approved; the admin errors for p0.
        reqs = [request(f"f{i}", pid=f"p{i}") for i in range(202)]

        class Partial(FakeAdmin):
            def get(self, path, params=None):
                if (params or {}).get("profilesIds") == "p0":
                    raise admin_api.AdminError("boom")
                return super().get(path, params)

        text = render_metrics(Partial(reqs, {}, PROFILES), self.ledger, now=NOW)
        self.assertIn("since removed/reverted by a human: 0 of 199 checked (0%", text)
        self.assertIn("(3 not checkable this run)", text)

    def test_digest(self):
        admin = self.fixture()
        run_audit(admin, self.ledger, None, Config(mode="audit"), window_min=90, now=NOW)
        text = render_digest(self.ledger, now=NOW + timedelta(minutes=5))
        self.assertIn("CONTRADICTED", text)
        self.assertIn("BIRDS OF A FEATHER", text)
        empty = Ledger(":memory:")
        self.assertEqual(render_digest(empty, now=NOW), "NO_REPLY")

    def test_sampling_is_stable(self):
        ids = [f"id-{i}" for i in range(2000)]
        picked = [i for i in ids if sampled(i, 0.1)]
        self.assertEqual(picked, [i for i in ids if sampled(i, 0.1)])
        self.assertTrue(120 < len(picked) < 280)
        self.assertTrue(all(sampled(i, 1.0) for i in ids[:10]))
        self.assertFalse(any(sampled(i, 0.0) for i in ids[:10]))


class CatalogBigTrackTests(unittest.TestCase):
    """Big comes from catalog data (GET /admin/track, artist profiles), never
    the request row's client-sourced spotifyPopularity; unknown = big."""

    def ev(self, catalog, *, tracks=None, **kw):
        tracks = {"t1": catalog} if tracks is None else tracks
        admin = FakeAdmin([], {"t1": []}, PROFILES, tracks)
        return EvidenceBuilder(admin, now=NOW).build(request("r1", pid=PID_GOOD, **kw))

    def test_small_catalog_track_is_small(self):
        ev = self.ev(track(20), pop=95)
        self.assertFalse(ev.big_track)
        self.assertEqual(ev.errors, [])

    def test_missing_or_unreadable_popularity_is_big(self):
        self.assertTrue(self.ev(track(None), pop=5).big_track)
        unreadable = self.ev(None, tracks={}, pop=5)
        self.assertTrue(unreadable.big_track)
        self.assertTrue(any("track t1" in e for e in unreadable.errors), unreadable.errors)

    def test_featured_artist_at_90_is_big(self):
        self.assertTrue(self.ev(track(20, artists=(ART_SMALL, ART_STAR)), pop=5).big_track)

    def test_artist_without_readable_popularity_is_big(self):
        self.assertTrue(self.ev(track(20, artists=(ART_SMALL, "no-such-profile")), pop=5).big_track)

    def test_big_track_matches_the_idp_rule(self):
        # IDP _is_big_track: no linked artist -> decided by track popularity alone.
        self.assertFalse(self.ev(track(20, artists=()), pop=5).big_track)
        self.assertFalse(self.ev({"popularity": 1, "artists": [{"name": "unlinked"}]}, pop=1).big_track)
        self.assertTrue(self.ev({"popularity": 61, "artists": []}, pop=1).big_track)
        self.assertTrue(self.ev({"artists": []}, pop=1).big_track)            # unknown track popularity
        self.assertTrue(self.ev(track(20, artists=(ART_STAR,)), pop=5).big_track)  # artist >= 90
        # an unlinked artist next to a linked small one does not make it big
        self.assertFalse(self.ev({"popularity": 20, "artists": [{"name": "x"}, {"id": ART_SMALL, "name": ART_SMALL}]},
                                 pop=5).big_track)

    def test_low_request_popularity_on_catalog_big_track_is_big_and_model_checked(self):
        ev = self.ev(track(75), pop=3)
        self.assertTrue(ev.big_track)
        self.assertEqual(ev.for_model()["track"]["catalog_popularity"], 75)
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Ledger(str(Path(tmp) / "l.sqlite3"))
            reqs = [request("hit", pid=PID_GOOD, track="t1", pop=3, roles=("Producer",))]
            judge = FakeJudge(jr("SUSPECT", 0.6))
            run_audit(FakeAdmin(reqs, {"t1": []}, PROFILES, {"t1": track(75)}), ledger, judge,
                      Config(mode="audit", sample_rate=0.0), window_min=90, now=NOW)
            ledger.close()
        self.assertEqual(judge.calls, 1)


LINKED = {
    PID_GOOD: {"name": "Real Engineer", "knownAsNames": [], "links": [
        {"type": "instagram", "url": "https://www.instagram.com/realengineer"}],
        "rawProfiles": [{"id": "T9", "source": "tidal", "url": "https://tidal.com/artist/T9"}]},
    ART_SMALL: PROFILES[ART_SMALL],
}


class ClaimantDomainTests(unittest.TestCase):
    def ev(self):
        admin = FakeAdmin([], {"t1": []}, LINKED, {"t1": track(20)})
        return EvidenceBuilder(admin, now=NOW).build(request("r1", pid=PID_GOOD, pop=20))

    def judged(self, urls, verdict="APPROVE-RECOMMENDED", effect="supports"):
        return jr(verdict, 0.99, findings=[{"source_url": u, "effect": effect} for u in urls], cited=urls)

    def test_claimant_site_and_social_profile_are_not_independent(self):
        ev = self.ev()
        urls = ["https://realengineer.com/credits", "https://www.instagram.com/realengineer",
                "https://tidal.com/album/1/credits"]
        j = self.judged(urls)
        self.assertEqual(j.supporting_domains(ev.claimant_domains, ev.claimant_names), set())
        self.assertEqual(combine(ev, "review", j).verdict, "NEEDS-HUMAN")
        self.assertNotEqual(combine(ev, "audit", self.judged(urls, "CONFIRMED")).verdict, "CONFIRMED")
        con = self.judged(urls[:1], "CONTRADICTED", "contradicts")
        self.assertNotEqual(combine(ev, "audit", con).verdict, "CONTRADICTED")

    def test_exclusion_survives_the_ledger_round_trip(self):
        ev = self.ev()
        j = self.judged(["https://realengineer.com/credits", "https://www.instagram.com/realengineer"])
        cfg = Config(mode="review", phase="shadow")
        ledger = Ledger(":memory:")
        record(ledger, cfg, ev, combine(ev, "review", j), j)
        stored = json.loads(ledger.db.execute("SELECT evidence_json FROM reviews").fetchone()[0])
        ledger.close()
        self.assertEqual(combine(facts_from_record(stored, "unverified"), "review", j).verdict, "NEEDS-HUMAN")

    def test_subdomains_of_one_site_count_once(self):
        ev = self.ev()
        two_subs = ["https://news.example-press.com/a", "https://blog.example-press.com/b"]
        j = self.judged(two_subs)
        self.assertEqual(j.supporting_domains(ev.claimant_domains, ev.claimant_names), {"example-press.com"})
        self.assertEqual(combine(ev, "review", j).verdict, "NEEDS-HUMAN")
        self.assertEqual(combine(ev, "review", self.judged(two_subs + ["https://allmusic.com/x"])).verdict,
                         "APPROVE-RECOMMENDED")


class ClaimantDomainHardeningTests(unittest.TestCase):
    def judged(self, urls, verdict="APPROVE-RECOMMENDED"):
        return jr(verdict, 0.99, findings=[{"source_url": u, "effect": "supports"} for u in urls], cited=urls)

    def build(self, pid, profiles):
        admin = FakeAdmin([], {"t3": []}, profiles)
        return EvidenceBuilder(admin, now=NOW).build(request("r1", pid=pid, track="t3", pop=10))

    def test_claimant_name_on_shared_host_and_user_platforms_never_count(self):
        ev = self.build(PID_GOOD, PROFILES)
        urls = ["https://realengineer.wixsite.com/credits", "https://realengineer.blogspot.com/2026/01/mix",
                "https://soundcloud.com/someone/track", "https://someone.bandcamp.com/album/x",
                "https://x.com/someone/status/1"]
        j = self.judged(urls)
        self.assertEqual(j.supporting_domains(ev.claimant_domains, ev.claimant_names), set())
        self.assertEqual(combine(ev, "review", j).verdict, "NEEDS-HUMAN")
        self.assertNotEqual(combine(ev, "audit", self.judged(urls, "CONFIRMED")).verdict, "CONFIRMED")

    def test_unreadable_claimant_profile_is_an_error_and_blocks_web_confirmation(self):
        ev = self.build("unreadable-profile", PROFILES)
        self.assertIsNone(ev.claimant_domains)
        self.assertTrue(any("claimant profile" in e for e in ev.errors), ev.errors)
        urls = ["https://www.discogs.com/release/1", "https://allmusic.com/x"]
        self.assertEqual(combine(ev, "review", self.judged(urls)).verdict, "NEEDS-HUMAN")
        self.assertNotEqual(combine(ev, "audit", self.judged(urls, "CONFIRMED")).verdict, "CONFIRMED")

    def test_rescore_uses_the_names_the_live_run_excluded(self):
        pid = "dj-foo"
        profiles = PROFILES | {pid: {"name": "DJ Foo", "legalName": "John Smithson", "rawProfiles": []}}
        ev = self.build(pid, profiles)
        j = self.judged(["https://johnsmithson.com/credits", "https://allmusic.com/x"])
        live = combine(ev, "review", j)
        self.assertEqual(live.verdict, "NEEDS-HUMAN")
        ledger = Ledger(":memory:")
        record(ledger, Config(mode="review", phase="shadow"), ev, live, j)
        stored = json.loads(ledger.db.execute("SELECT evidence_json FROM reviews").fetchone()[0])
        ledger.close()
        self.assertNotIn("John Smithson", json.dumps(ev.for_model()))
        self.assertEqual(combine(facts_from_record(stored, "unverified"), "review", j).verdict, live.verdict)


class VelocityRegressionTests(unittest.TestCase):
    def test_big_share_samples_the_whole_week_evenly(self):
        reqs = [request(f"e{i}", pid=PID_BAD, track=f"z{i}", pop=0, roles=("Mixing",), artists=(f"Artist {i}",),
                        created=(NOW - timedelta(hours=150 - i)).isoformat().replace("+00:00", "Z"))
                for i in range(150)]
        tracks = {f"z{i}": track(80 if i < 100 else 20) for i in range(150)} | {"t3": track(10)}
        admin = FakeAdmin(reqs, {"t3": []}, PROFILES, tracks)
        target = request("tgt", pid=PID_BAD, track="t3", roles=("Producer",), status="unverified")
        ev = EvidenceBuilder(admin, now=NOW).build(target)
        p = ev.profile
        self.assertAlmostEqual(p.big_share_7d, 0.67, delta=0.03)
        self.assertEqual((p.as_dict()["velocity_big_share_sample_tracks"], p.as_dict()["velocity_distinct_tracks_7d"]),
                         (50, 150))
        self.assertEqual(len({path for path, _ in admin.paths if path.startswith("/admin/track/z")}), 50)
        flags = deterministic(ev, "audit").reasons
        self.assertIn("stillfloo_pattern", flags)
        self.assertTrue(any(f.startswith("high_velocity_on_big_tracks") for f in flags), flags)
        stored = ev.for_model()["profile"]
        self.assertEqual(stored["velocity_big_share_sample_tracks"], 50)

    def test_catalog_reads_per_velocity_scan_are_capped(self):
        from credit_review.evidence import VELOCITY_CATALOG_TRACKS
        reqs = [request(f"c{i}", pid=PID_GOOD, track=f"y{i}", pop=0,
                        created=(NOW - timedelta(minutes=30 + i)).isoformat().replace("+00:00", "Z"))
                for i in range(VELOCITY_CATALOG_TRACKS + 10)]
        admin = FakeAdmin(reqs, {}, PROFILES, {})
        builder = EvidenceBuilder(admin, now=NOW)
        sig = builder.profile_signals(PID_GOOD, {})
        builder.ensure_velocity(sig)
        track_reads = {p for p, _ in admin.paths if p.startswith("/admin/track/")}
        self.assertEqual(len(track_reads), VELOCITY_CATALOG_TRACKS)
        self.assertTrue(sig.window_truncated)
        self.assertTrue(sig.as_dict()["velocity_counts_are_a_floor_or_sample"])
        self.assertEqual(sig.requests_7d, VELOCITY_CATALOG_TRACKS + 10)
        self.assertEqual(sig.big_share_7d, 1.0)  # unreadable catalog = big

    def burst(self):
        reqs = [request(f"v{i}", pid=PID_BAD, track=f"x{i}", pop=0, roles=("Mixing",),
                        artists=(f"Artist {i}",)) for i in range(25)]
        tracks = {f"x{i}": track(80) for i in range(25)}
        return reqs, tracks

    def test_parallel_builds_share_one_fully_computed_profile(self):
        reqs, tracks = self.burst()

        class Slow(FakeAdmin):
            def get(self, path, params=None):
                if path.startswith("/admin/profile/") or path == "/admin/credit-requests":
                    time.sleep(0.02)
                return super().get(path, params)

        builder = EvidenceBuilder(Slow(reqs, {}, PROFILES, tracks), now=NOW)
        with ThreadPoolExecutor(max_workers=6) as pool:
            evs = list(pool.map(builder.build, reqs[:12]))
        self.assertEqual(len({id(ev.profile) for ev in evs}), 1)
        self.assertTrue(all(ev.profile.requests_7d == 25 and ev.profile.stillfloo_pattern for ev in evs))

    def test_velocity_read_failure_is_an_evidence_error_that_clamps(self):
        target = request("tgt", pid=PID_GOOD, track="t2", status="unverified", approved=True, risk=5)

        class NoVelocity(FakeAdmin):
            def get(self, path, params=None):
                if (params or {}).get("profilesIds"):
                    raise admin_api.AdminError("admin GET timed out: /admin/credit-requests")
                return super().get(path, params)

        ev = EvidenceBuilder(NoVelocity([target], {"t2": [raw("Real Engineer", "mixer")]}, PROFILES,
                                        {"t2": track(20)}), now=NOW).build(target)
        self.assertTrue(ev.all_confirmed)
        self.assertTrue(any("velocity" in e for e in ev.errors), ev.errors)
        d = deterministic(ev, "review")
        self.assertEqual(d.verdict, "NEEDS-HUMAN")
        self.assertIn("evidence_errors", d.reasons)


class AuditWindowTests(unittest.TestCase):
    def test_failed_runs_leave_no_gap(self):
        ledger = Ledger(":memory:")
        cfg = Config(mode="audit", sample_rate=0.0)
        admin = FakeAdmin([], {}, PROFILES)
        run_audit(admin, ledger, None, cfg, window_min=90, now=NOW)
        # The next two hourly runs fail (admin API down); this approval lands
        # between them and is older than the third run's 90-min window.
        ts = (NOW + timedelta(minutes=45)).isoformat().replace("+00:00", "Z")
        admin.requests = [request("gap", pid=PID_GOOD, track="t3", updated=ts, created=ts)]
        _, stats = run_audit(admin, ledger, None, cfg, window_min=90, now=NOW + timedelta(hours=3))
        self.assertEqual(stats.scanned, 1)
        self.assertTrue(ledger.reviewed("gap", "audit"))
        ledger.close()

    def test_lookback_is_bounded_and_the_older_gap_is_alerted(self):
        ledger = Ledger(":memory:")
        ledger.set_state("audit_last_run", (NOW - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        iso = lambda d: (NOW - d).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request("recent", pid=PID_GOOD, track="t3", updated=iso(timedelta(hours=2))),
                request("ancient", pid=PID_GOOD, track="t3", updated=iso(timedelta(hours=30)))]
        alerts, stats = run_audit(FakeAdmin(reqs, {}, PROFILES), ledger, None, Config(mode="audit", sample_rate=0.0),
                                  window_min=90, now=NOW)
        self.assertEqual(stats.scanned, 1)
        self.assertTrue(ledger.reviewed("recent", "audit"))
        self.assertFalse(ledger.reviewed("ancient", "audit"))
        gap = (timedelta(days=3) + timedelta(minutes=15) - timedelta(hours=24)).total_seconds() // 60
        self.assertTrue(any(f"{int(gap)} minutes not audited" in a for a in alerts), alerts)
        ledger.close()

    def test_interrupted_run_keeps_the_chunks_it_finished(self):
        from credit_review import runner
        iso = lambda m: (NOW - timedelta(minutes=m)).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request(f"k{m}", pid=PID_GOOD, track="boom" if m == 30 else "t3", updated=iso(m))
                for m in (50, 40, 30, 20)]

        class Killed(FakeAdmin):
            def get(self, path, params=None):
                if path == "/admin/track/boom/raw-credits":
                    raise RuntimeError("cron timeout")
                return super().get(path, params)

        ledger = Ledger(":memory:")
        orig = runner.AUDIT_CHUNK
        runner.AUDIT_CHUNK = 2
        try:
            with self.assertRaises(RuntimeError):
                run_audit(Killed(reqs, {}, PROFILES), ledger, None, Config(mode="audit", sample_rate=0.0),
                          window_min=90, now=NOW)
        finally:
            runner.AUDIT_CHUNK = orig
        self.assertTrue(ledger.reviewed("k50", "audit") and ledger.reviewed("k40", "audit"))
        self.assertFalse(ledger.reviewed("k20", "audit"))
        # A hard kill never advances the watermark, so the next run rescans
        # the same window (skipping what was recorded) and re-raises its alerts.
        self.assertIsNone(ledger.get_state("audit_last_run"))
        ledger.close()

    def chunked(self, fn):
        from credit_review import runner
        orig = runner.AUDIT_CHUNK
        runner.AUDIT_CHUNK = 2
        try:
            return fn()
        finally:
            runner.AUDIT_CHUNK = orig

    def test_deadline_stops_a_multi_chunk_run_and_still_prints_every_alert(self):
        iso = lambda d: (NOW - d).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request("bad-big", track="t1", pop=88, title="BIRDS OF A FEATHER", updated=iso(timedelta(hours=3))),
                request("d2", pid=PID_GOOD, track="t3", updated=iso(timedelta(hours=2))),
                request("d3", pid=PID_GOOD, track="t3", updated=iso(timedelta(hours=1))),
                request("d4", pid=PID_GOOD, track="t3", updated=iso(timedelta(minutes=30)))]
        admin = FakeAdmin(reqs, {"t1": [raw("Jon Castelli", "mixing engineer")], "t3": []}, PROFILES)
        ledger = Ledger(":memory:")
        ledger.set_state("audit_last_run", (NOW - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        cfg = Config(mode="audit", sample_rate=0.0)
        alerts, stats = self.chunked(lambda: run_audit(admin, ledger, None, cfg, window_min=90,
                                                       now=NOW, deadline_s=0))
        joined = "\n".join(alerts)
        self.assertIn("minutes not audited", joined)
        self.assertIn("CONTRADICTED on big track", joined)
        self.assertIn("stopped at its 0s deadline with 2 of 4", joined)
        self.assertEqual(stats.reviewed, 2)
        self.assertEqual(ledger.get_state("audit_last_run"), iso(timedelta(hours=2)))
        # The next run continues from the last finished chunk: no repeated
        # gap alert, and the rest is audited.
        alerts2, _ = self.chunked(lambda: run_audit(admin, ledger, None, cfg, window_min=90,
                                                    now=NOW + timedelta(minutes=5)))
        self.assertFalse(any("not audited" in a or "deadline" in a for a in alerts2), alerts2)
        self.assertTrue(ledger.reviewed("d3", "audit") and ledger.reviewed("d4", "audit"))
        ledger.close()

    def clocked(self, clock, fn):
        import types
        from credit_review import runner
        orig = runner.time
        runner.time = types.SimpleNamespace(monotonic=lambda: clock[0])
        try:
            return self.chunked(fn)
        finally:
            runner.time = orig

    def test_slow_chunk_stops_the_run_before_the_kill_with_earlier_alerts(self):
        iso = lambda d: (NOW - d).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request("bad-big", track="t1", pop=88, updated=iso(timedelta(minutes=80))),
                request("s2", pid=PID_GOOD, track="slow", updated=iso(timedelta(minutes=70))),
                request("s3", pid=PID_GOOD, track="t3", updated=iso(timedelta(minutes=60))),
                request("s4", pid=PID_GOOD, track="t3", updated=iso(timedelta(minutes=50)))]
        clock = [0.0]
        kill_at = 160.0

        class Slow(FakeAdmin):
            def get(self, path, params=None):
                if path == "/admin/track/slow/raw-credits":
                    clock[0] += 70
                return super().get(path, params)

        admin = Slow(reqs, {"t1": [raw("Jon Castelli", "mixing engineer")], "slow": [], "t3": []}, PROFILES,
                     TRACKS | {"slow": track(10)})
        ledger = Ledger(":memory:")
        alerts, stats = self.clocked(clock, lambda: run_audit(
            admin, ledger, None, Config(mode="audit", sample_rate=0.0), window_min=90,
            now=NOW, workers=1, deadline_s=100))
        self.assertLess(clock[0], kill_at)
        joined = "\n".join(alerts)
        self.assertIn("CONTRADICTED on big track", joined)
        self.assertIn("2 of 4 approval(s) in the window not yet audited", joined)
        self.assertEqual(stats.reviewed, 2)
        self.assertEqual(ledger.get_state("audit_last_run"), iso(timedelta(minutes=70)))
        ledger.close()

    def test_slow_deferred_pass_stops_and_reports_the_unjudged_sample(self):
        iso = lambda m: (NOW - timedelta(minutes=m)).isoformat().replace("+00:00", "Z")  # noqa: E731
        # Three different profiles, so three separate model calls (one profile's
        # non-big claims would be one batched call).
        reqs = [request(f"n{m}", pid=pid, track="t3", roles=("Producer",), updated=iso(m))
                for m, pid in ((40, PID_GOOD), (30, PID_BAD), (20, ART_SMALL))]
        clock = [0.0]
        kill_at = 200.0

        class SlowJudge(FakeJudge):
            def judge(self, mode, evidence):
                clock[0] += 60
                return super().judge(mode, evidence)

        judge = SlowJudge(jr("SUSPECT", 0.6))
        ledger = Ledger(":memory:")
        alerts, stats = self.clocked(clock, lambda: run_audit(
            FakeAdmin(reqs, {"t3": []}, PROFILES), ledger, judge, Config(mode="audit", sample_rate=1.0),
            window_min=90,
            now=NOW, workers=1, deadline_s=100))
        self.assertLess(clock[0], kill_at)
        self.assertEqual(judge.calls, 2)
        self.assertEqual(stats.reviewed, 3)
        self.assertIn("1 sampled/big approval(s) were catalog-checked only: deadline reached", "\n".join(alerts))
        self.assertFalse(stats.budget_stopped)
        ledger.close()

    def test_deadline_cut_big_track_is_not_recorded_and_is_model_checked_next_run(self):
        iso = lambda m: (NOW - timedelta(minutes=m)).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request(f"b{m}", pid=PID_GOOD, track="t9", roles=("Producer",), updated=iso(m)) for m in (20, 10)]
        clock = [0.0]

        class SlowJudge(FakeJudge):
            def judge(self, mode, evidence):
                clock[0] += 60
                return super().judge(mode, evidence)

        judge = SlowJudge(jr("SUSPECT", 0.6))
        admin = FakeAdmin(reqs, {"t9": []}, PROFILES)
        ledger = Ledger(":memory:")
        alerts, stats = self.clocked(clock, lambda: run_audit(
            admin, ledger, judge, Config(mode="audit", sample_rate=0.0), window_min=90,
            now=NOW, workers=1, deadline_s=50))
        self.assertEqual(judge.calls, 1)
        self.assertTrue(ledger.reviewed("b20", "audit"))
        self.assertFalse(ledger.reviewed("b10", "audit"))
        joined = "\n".join(alerts)
        self.assertIn("1 of 2 approval(s) in the window not yet audited, including 1 big track(s)", joined)
        self.assertNotIn("deadline reached", joined)
        self.assertIsNone(ledger.get_state("audit_last_run"))
        run_audit(admin, ledger, judge, Config(mode="audit", sample_rate=0.0), window_min=90,
                  now=NOW + timedelta(minutes=5), workers=1)
        self.assertEqual(judge.calls, 2)
        row = ledger.db.execute("SELECT model FROM reviews WHERE request_id='b10'").fetchone()
        self.assertEqual(row["model"], "fake")
        ledger.close()

    def test_rows_skipped_for_budget_and_for_time_are_counted_once(self):
        iso = lambda m: (NOW - timedelta(minutes=m)).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request(f"g{m}", pid=PID_GOOD, track="t9", roles=("Producer",), updated=iso(m)) for m in (50, 40)]
        reqs += [request(f"s{m}", pid=PID_GOOD, track="slow", roles=("Producer",), updated=iso(m)) for m in (30, 20)]
        clock = [0.0]

        class Slow(FakeAdmin):
            def get(self, path, params=None):
                if path == "/admin/track/slow/raw-credits":
                    clock[0] += 150
                return super().get(path, params)

        judge = FakeJudge(jr("SUSPECT", 0.6, cost=1.0))
        ledger = Ledger(":memory:")
        alerts, stats = self.clocked(clock, lambda: run_audit(
            Slow(reqs, {"t9": [], "slow": []}, PROFILES, TRACKS | {"slow": track(10)}), ledger, judge,
            Config(mode="audit", sample_rate=1.0, budget_usd=1.0), window_min=90,
            now=NOW, workers=1, deadline_s=100))
        joined = "\n".join(alerts)
        self.assertEqual(judge.calls, 1)
        self.assertIn("model budget reached this run ($1.00); 1 sampled/big approval(s)", joined)
        self.assertIn("2 sampled/big approval(s) were catalog-checked only: deadline reached", joined)
        self.assertEqual(stats.reviewed, 4)
        ledger.close()

    def test_budget_goes_to_big_tracks_across_chunks(self):
        iso = lambda m: (NOW - timedelta(minutes=m)).isoformat().replace("+00:00", "Z")  # noqa: E731
        small = [request(f"s{m}", pid=PID_GOOD, track="t3", roles=("Producer",), updated=iso(m)) for m in (80, 79, 78, 77)]
        big = [request(f"b{m}", pid=PID_GOOD, track="t9", roles=("Producer",), updated=iso(m)) for m in (20, 19, 18)]
        judge = FakeJudge(jr("SUSPECT", 0.6, cost=1.0))
        ledger = Ledger(":memory:")
        _, stats = self.chunked(lambda: run_audit(
            FakeAdmin(small + big, {"t3": [], "t9": []}, PROFILES), ledger, judge,
            Config(mode="audit", sample_rate=1.0, budget_usd=3.0), window_min=90, now=NOW))
        self.assertEqual(judge.calls, 3)
        self.assertTrue(all(e["track"]["big_track"] for e in judge.evidence), judge.evidence)
        self.assertTrue(stats.budget_stopped)
        self.assertEqual(stats.reviewed, 7)
        ledger.close()

    def test_scan_reads_every_page_back_to_the_window_start(self):
        reqs = [request(f"w{i}", pid=PID_GOOD, updated=(NOW - timedelta(minutes=i)).isoformat().replace("+00:00", "Z"))
                for i in range(5)] + [request("old", pid=PID_GOOD, updated=(NOW - timedelta(hours=2)).isoformat()
                                              .replace("+00:00", "Z"))]
        admin = FakeAdmin(reqs, {}, PROFILES)
        rows = fetch_approved_window(admin, NOW - timedelta(hours=1), page_size=2)
        self.assertEqual(sorted(r["id"] for r in rows), [f"w{i}" for i in range(5)])

    def test_approvals_past_the_first_page_are_audited_before_they_leave_the_window(self):
        # QA on hydra#1142: a page-capped scan read only the newest 200 of 201
        # in-window approvals yet advanced audit_last_run to now, so two hours
        # later the 201st was outside the window and never audited.
        iso = lambda s: (NOW - timedelta(seconds=s)).isoformat().replace("+00:00", "Z")  # noqa: E731
        reqs = [request(f"p{i}", pid=PID_GOOD, track="t3", updated=iso(10 + i)) for i in range(201)]
        admin = FakeAdmin(reqs, {"t3": []}, PROFILES)
        ledger = Ledger(":memory:")
        cfg = Config(mode="audit", sample_rate=0.0)
        alerts, stats = run_audit(admin, ledger, None, cfg, window_min=90, now=NOW)
        self.assertEqual((stats.scanned, stats.reviewed), (201, 201), alerts)
        self.assertTrue(ledger.reviewed("p200", "audit"))
        _, stats2 = run_audit(admin, ledger, None, cfg, window_min=90, now=NOW + timedelta(hours=2))
        self.assertEqual(stats2.reviewed, 0)
        self.assertEqual(sum(1 for r in reqs if ledger.reviewed(r["id"], "audit")), 201)
        ledger.close()


def load_cli():
    import importlib.util
    path = Path(__file__).resolve().parents[1] / "credit-review.py"
    spec = importlib.util.spec_from_file_location("credit_review_cli", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ModelGateTests(unittest.TestCase):
    """The model judge is OFF by default (no OpenRouter spend until the captain
    tops the account up) and never spends below the balance floor."""

    def setUp(self):
        self.cli = load_cli()
        self.tmp = tempfile.TemporaryDirectory()
        self.cli.MODEL_ENABLE_FILE = Path(self.tmp.name) / "model.enabled"

    def tearDown(self):
        self.tmp.cleanup()

    def args(self, *extra):
        return self.cli.parser().parse_args(["audit", *extra])

    def test_off_without_enable_file(self):
        self.cli.account_balance_usd = lambda: self.fail("balance must not even be read")
        self.assertIsNone(self.cli.make_judge(self.args()))

    def test_low_or_unreadable_balance_skips_model_with_a_note(self):
        self.cli.MODEL_ENABLE_FILE.write_text("")
        for bal in (9.5, None):
            self.cli.account_balance_usd = lambda b=bal: b
            notes = []
            self.assertIsNone(self.cli.make_judge(self.args(), notes))
            self.assertTrue(notes and "below the $10 floor" in notes[0])

    def test_runs_at_the_balance_seen_on_2026_10_13(self):
        # $38.13 left on 10-13 with auto top-up on: the judge must run (the old
        # $100 floor kept it off permanently).
        self.cli.MODEL_ENABLE_FILE.write_text("")
        self.cli.account_balance_usd = lambda: 38.13
        self.assertIsNotNone(self.cli.make_judge(self.args("--model", "x-ai/grok-4.3")))

    def test_on_with_enable_file_and_balance(self):
        self.cli.MODEL_ENABLE_FILE.write_text("")
        self.cli.account_balance_usd = lambda: 500.0
        j = self.cli.make_judge(self.args("--model", "x-ai/grok-4.3"))
        self.assertIsNotNone(j)
        self.assertEqual(j.model, "x-ai/grok-4.3")
        self.assertIsNone(self.cli.make_judge(self.args("--no-model")))

    def test_eval_refuses_model_spend_below_floor(self):
        self.cli.account_balance_usd = lambda: 9.0
        rc = self.cli.main(["eval", "--out", self.tmp.name, "--models", "x-ai/grok-4.3"])
        self.assertEqual(rc, 2)


class CronContractTests(unittest.TestCase):
    def test_cron_entries_are_read_only_commands(self):
        jobs = json.loads((Path(__file__).resolve().parents[2] / "cron-jobs.json").read_text())["jobs"]
        mine = [j for j in jobs if "credit-review.py" in " ".join(j.get("payload", {}).get("argv", []))]
        self.assertTrue(mine, "credit-review crons missing from cron-jobs.json")
        for j in mine:
            argv = j["payload"]["argv"]
            self.assertEqual(j["payload"]["kind"], "command")
            self.assertTrue(all(isinstance(a, str) and a for a in argv), "cron argv must not contain empty strings")
            self.assertIn(argv[2], ("audit", "review", "digest", "metrics", "decide"))
            if argv[2] == "decide":
                # The one writing subcommand: only as the registered, captain-approved
                # credit-trust-decide automation (policies/credit-approval-automation.json).
                reg = json.loads((Path(__file__).resolve().parents[2] / "policies"
                                  / "credit-approval-automation.json").read_text())["automations"]["credit-trust-decide"]
                self.assertIn(j["name"], reg["cron_names"])
                self.assertTrue(reg["approved"] is True and reg["approved_by"] and reg["approval_ref"])
            if argv[2] == "review":
                self.assertIn("shadow", argv, "the reviewer ships in shadow (Phase 0)")


def _audit_row(ledger, rid, pid, verdict, approved_at, name="Zach Miller"):
    ledger.record({"request_id": rid, "mode": "audit", "phase": "live", "verdict": verdict, "confidence": 0.5,
                   "basis": "catalog_only", "big_track": False, "profile_id": pid, "approved_at": approved_at,
                   "status_at_review": "approved",
                   "evidence_json": {"claim": {"person_or_profile_name": name, "claimed_roles": ["Mixing"]}}})


def _park(ledger, rid, pid, updated_at, since, name=None):
    req = {"id": rid, "profileId": pid, "status": "approved", "updatedAt": updated_at}
    if name:
        req["profile"] = {"name": name}
    ledger.note_evidence_failure(req, "audit", "raw credits unreadable")
    ledger.db.execute("UPDATE evidence_retry SET first_failed_at=? WHERE request_id=? AND mode='audit'", (since, rid))
    ledger.db.commit()


class ProfileBurstAlertTests(unittest.TestCase):
    """firstmate 035: a profile with 421 requests in <2h, 35 validator approvals and
    25 SUSPECT in one hour raised ZERO alerts (row alerts fire only on a CONTRADICTED
    big track). A per-profile burst now alerts once, naming the profile."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Ledger(str(Path(self.tmp.name) / "l.sqlite3"))

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def at(self, minutes_ago):
        return (NOW - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")

    def test_ten_flagged_approvals_alert_once_naming_the_profile(self):
        for i in range(10):
            _audit_row(self.ledger, f"s{i}", "zach", "SUSPECT" if i % 2 else "CONTRADICTED", self.at(10 + i))
        alerts = profile_burst_alerts(self.ledger, now=NOW)
        self.assertEqual(len(alerts), 1)
        self.assertIn("CREDIT-AUDIT ALERT", alerts[0])
        self.assertIn("Zach Miller (zach)", alerts[0])
        self.assertIn("10 approval(s) within 2h (up to 2026-10-11T02:50:00Z), 10 of them SUSPECT or CONTRADICTED",
                      alerts[0])
        self.assertIn("https://credits.muso.ai/profile/zach", alerts[0])
        # The next run, with no new approval, does not repeat it; a continuing burst alerts again.
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW + timedelta(hours=1)), [])
        _audit_row(self.ledger, "s-more", "zach", "SUSPECT", self.ts(NOW + timedelta(hours=1, minutes=30)))
        alerts = profile_burst_alerts(self.ledger, now=NOW + timedelta(hours=2))
        self.assertEqual(len(alerts), 1)
        self.assertIn("(up to 2026-10-11T04:30:00Z)", alerts[0])
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW + timedelta(hours=3)), [])

    def test_twenty_approvals_alert_even_when_none_are_flagged(self):
        for i in range(20):
            _audit_row(self.ledger, f"c{i}", "busy", "CONFIRMED", self.at(5 * i))
        alerts = profile_burst_alerts(self.ledger, now=NOW)
        self.assertEqual(len(alerts), 1)
        self.assertIn("20 approval(s) within 2h (up to 2026-10-11T03:00:00Z), 0 of them SUSPECT or CONTRADICTED",
                      alerts[0])

    def test_below_thresholds_outside_window_and_other_profiles_do_not_alert(self):
        for i in range(9):
            _audit_row(self.ledger, f"s{i}", "p1", "SUSPECT", self.at(10))
        for i in range(10):
            _audit_row(self.ledger, f"u{i}", "p1", "UNVERIFIABLE", self.at(10))   # 19 approvals, 9 flagged
        for i in range(15):
            _audit_row(self.ledger, f"old{i}", "p2", "SUSPECT", self.at(121 + i))  # outside 2h
        for i in range(5):
            _audit_row(self.ledger, f"a{i}", f"solo{i}", "SUSPECT", self.at(10))
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW), [])

    def test_approvals_after_now_are_not_counted(self):
        for i in range(12):
            _audit_row(self.ledger, f"f{i}", "p4", "SUSPECT", (NOW + timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW), [])

    def test_a_request_counts_once_by_its_latest_verdict(self):
        # A re-reviewed request has two audit rows; only its latest verdict counts.
        for i in range(10):
            _audit_row(self.ledger, f"r{i}", "p3", "SUSPECT", self.at(10))
        for i in range(10):
            _audit_row(self.ledger, f"r{i}", "p3", "CONFIRMED", self.at(10))
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW), [])

    @staticmethod
    def ts(dt):
        return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    def test_catch_up_run_after_an_outage_alerts_on_older_approvals(self):
        day = datetime(2026, 10, 14, tzinfo=timezone.utc)
        self.ledger.set_state("burst_last_check", "2026-10-14T10:45:00Z")
        # Admin API down 10:45-13:45: those runs never reach the burst check. The
        # 14:45 catch-up run records 25 SUSPECT approvals made 11:00-12:30.
        for i in range(25):
            _audit_row(self.ledger, f"o{i}", "zach", "SUSPECT", self.ts(day + timedelta(hours=11, minutes=90 * i // 24)))
        alerts = profile_burst_alerts(self.ledger, now=day + timedelta(hours=14, minutes=45))
        self.assertEqual(len(alerts), 1)
        self.assertIn("Zach Miller (zach): 25 approval(s) within 2h (up to 2026-10-14T12:30:00Z), 25 of them", alerts[0])
        self.assertEqual(self.ledger.get_state("burst_last_check"), "2026-10-14T14:45:00Z")
        # The next hourly run neither re-alerts nor finds anything new.
        self.assertEqual(profile_burst_alerts(self.ledger, now=day + timedelta(hours=15, minutes=45)), [])

    def test_burst_split_across_two_hourly_runs_alerts(self):
        day = datetime(2026, 10, 14, tzinfo=timezone.utc)
        for i in range(6):
            _audit_row(self.ledger, f"a{i}", "split", "SUSPECT", self.ts(day + timedelta(hours=10, minutes=40)))
        self.assertEqual(profile_burst_alerts(self.ledger, now=day + timedelta(hours=11, minutes=45)), [])
        for i in range(6):
            _audit_row(self.ledger, f"b{i}", "split", "SUSPECT", self.ts(day + timedelta(hours=12, minutes=30)))
        # A trailing [10:45, 12:45] window sees only 6; the 10:30-12:30 window holds all 12.
        alerts = profile_burst_alerts(self.ledger, now=day + timedelta(hours=12, minutes=45))
        self.assertEqual(len(alerts), 1)
        self.assertIn("12 approval(s) within 2h (up to 2026-10-14T12:30:00Z), 12 of them", alerts[0])
        self.assertEqual(profile_burst_alerts(self.ledger, now=day + timedelta(hours=13, minutes=45)), [])

    def test_first_run_without_state_judges_windows_ending_in_the_last_2h(self):
        for i in range(12):
            _audit_row(self.ledger, f"old{i}", "stale", "SUSPECT", self.at(150))
        for i in range(12):
            _audit_row(self.ledger, f"new{i}", "fresh", "SUSPECT", self.at(30))
        alerts = profile_burst_alerts(self.ledger, now=NOW)
        self.assertEqual(len(alerts), 1)
        self.assertIn("(fresh)", alerts[0])
        self.assertEqual(self.ledger.get_state("burst_last_check"), "2026-10-11T03:00:00Z")

    def test_approvals_parked_on_evidence_failure_count_toward_the_burst(self):
        day = datetime(2026, 10, 14, tzinfo=timezone.utc)
        self.ledger.set_state("burst_last_check", "2026-10-14T09:45:00Z")
        times = [day + timedelta(hours=10, minutes=90 * i // 21) for i in range(22)]
        for i, t in enumerate(times[:17]):
            _audit_row(self.ledger, f"ok{i}", "zach", "CONFIRMED", self.ts(t))
        for i, t in enumerate(times[17:]):
            _park(self.ledger, f"pk{i}", "zach", self.ts(t), "2026-10-14T11:00:00Z", name="Zach Miller")
        alerts = profile_burst_alerts(self.ledger, now=day + timedelta(hours=11, minutes=45))
        self.assertEqual(len(alerts), 1)
        self.assertIn("Zach Miller (zach): 22 approval(s) within 2h (up to 2026-10-14T11:30:00Z), "
                      "0 of them SUSPECT or CONTRADICTED, 5 not yet auditable. Nothing was changed", alerts[0])

    def test_parked_approvals_are_never_flagged_and_count_once_when_recorded(self):
        for i in range(9):
            _audit_row(self.ledger, f"s{i}", "p5", "SUSPECT", self.at(10))
        for i in range(5):
            _park(self.ledger, f"pk{i}", "p5", self.at(10), self.at(5))
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW), [])
        for i in range(9):
            _park(self.ledger, f"s{i}", "p5", self.at(10), self.at(5))
        self.ledger.set_state("burst_last_check", self.at(60))
        self.assertEqual(profile_burst_alerts(self.ledger, now=NOW), [])

    def test_parked_approval_later_recorded_suspect_completes_a_burst(self):
        day = datetime(2026, 10, 14, tzinfo=timezone.utc)
        self.ledger.set_state("burst_last_check", "2026-10-14T09:45:00Z")
        for i in range(8):
            _audit_row(self.ledger, f"s{i}", "zach", "SUSPECT", self.ts(day + timedelta(hours=10, minutes=4 * i)))
        late = self.ts(day + timedelta(hours=10, minutes=40))
        for i in range(4):
            _park(self.ledger, f"pk{i}", "zach", late, "2026-10-14T10:45:00Z")
        self.assertEqual(profile_burst_alerts(self.ledger, now=day + timedelta(hours=11, minutes=45)), [])
        self.assertEqual(self.ledger.get_state("burst_last_check"), "2026-10-14T10:39:59Z")
        for i in range(4):
            self.ledger.clear_evidence_failure(f"pk{i}", "audit")
            _audit_row(self.ledger, f"pk{i}", "zach", "SUSPECT", late)
        alerts = profile_burst_alerts(self.ledger, now=day + timedelta(hours=12, minutes=45))
        self.assertEqual(len(alerts), 1)
        self.assertIn("Zach Miller (zach): 12 approval(s) within 2h (up to 2026-10-14T10:40:00Z), 12 of them", alerts[0])
        self.assertEqual(self.ledger.get_state("burst_last_check"), "2026-10-14T12:45:00Z")
        self.assertEqual(profile_burst_alerts(self.ledger, now=day + timedelta(hours=13, minutes=45)), [])

    def test_a_stuck_parked_approval_never_repeats_an_old_burst_alert(self):
        day = datetime(2026, 10, 14, tzinfo=timezone.utc)
        self.ledger.set_state("burst_last_check", "2026-10-14T09:45:00Z")
        for i in range(10):
            _audit_row(self.ledger, f"s{i}", "zach", "SUSPECT", self.ts(day + timedelta(hours=10, minutes=3 * i)))
        _park(self.ledger, "stuck", "zach", self.ts(day + timedelta(hours=10, minutes=5)), "2026-10-14T10:45:00Z")
        self.assertEqual(len(profile_burst_alerts(self.ledger, now=day + timedelta(hours=10, minutes=45))), 1)
        self.assertEqual(profile_burst_alerts(self.ledger, now=day + timedelta(hours=23, minutes=45)), [])

    def test_a_long_stuck_parked_row_on_another_profile_never_repeats_alerts(self):
        day = datetime(2026, 10, 14, tzinfo=timezone.utc)
        self.ledger.set_state("burst_last_check", "2026-10-14T07:45:00Z")
        _park(self.ledger, "stuck", "other", self.ts(day + timedelta(hours=8)), "2026-10-14T08:45:00Z")
        for i in range(30):
            _audit_row(self.ledger, f"a{i}", "zach", "CONFIRMED", self.ts(day + timedelta(hours=9, minutes=2 * i)))
        for i in range(30):
            _audit_row(self.ledger, f"b{i}", "zach", "CONFIRMED", self.ts(day + timedelta(hours=12, minutes=i)))
        self.assertEqual(len(profile_burst_alerts(self.ledger, now=day + timedelta(hours=10, minutes=45))), 1)
        self.assertEqual(self.ledger.get_state("burst_last_check"), "2026-10-14T07:59:59Z")
        seen = []
        for hour in range(11, 33):
            seen += profile_burst_alerts(self.ledger, now=day + timedelta(hours=hour, minutes=45))
        self.assertEqual(len(seen), 1, seen)
        self.assertIn("30 approval(s) within 2h (up to 2026-10-14T12:29:00Z)", seen[0])
        # A new burst on the same profile, while the old windows are still in reach, alerts.
        for i in range(20):
            _audit_row(self.ledger, f"c{i}", "zach", "CONFIRMED", self.ts(day + timedelta(hours=33, minutes=3 * i)))
        alerts = profile_burst_alerts(self.ledger, now=day + timedelta(hours=34, minutes=45))
        self.assertEqual(len(alerts), 1)
        self.assertIn("20 approval(s) within 2h (up to 2026-10-15T09:57:00Z)", alerts[0])
        # Parked for more than 24h, the row no longer holds the check back.
        self.assertEqual(self.ledger.get_state("burst_last_check"), "2026-10-15T10:45:00Z")

    def test_lookback_is_capped_at_24h(self):
        self.ledger.set_state("burst_last_check", "2026-10-08T03:00:00Z")
        for i in range(12):
            _audit_row(self.ledger, f"x{i}", "ancient", "SUSPECT", self.ts(NOW - timedelta(hours=30)))
        for i in range(12):
            _audit_row(self.ledger, f"y{i}", "recent", "SUSPECT", self.ts(NOW - timedelta(hours=23)))
        alerts = profile_burst_alerts(self.ledger, now=NOW)
        self.assertEqual(len(alerts), 1)
        self.assertIn("(recent)", alerts[0])


class BatchJudge(FakeJudge):
    """Answers judge_many with one result per id and counts calls."""

    def __init__(self, result, cost=0.06):
        super().__init__(result)
        self.batches = []
        self.cost = cost

    def judge_many(self, mode, evidences, ids):
        self.calls += 1
        self.batches.append(list(ids))
        out = {}
        for rid in ids:
            r = JudgeResult(**{**self.result.__dict__})
            r.cost_usd, r.batch_size = self.cost / len(ids), len(ids)
            out[rid] = r
        return out


class CostFixTests(unittest.TestCase):
    """Fable credit-AI report fixes (2026-10-14): profile batching, audit/shadow
    dedupe, search-junk filter."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Ledger(str(Path(self.tmp.name) / "l.sqlite3"))

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def burst(self, n, pid=PID_BAD, status="approved"):
        return [request(f"b{i}", pid=pid, track="t9", pop=75, roles=("Producer",), status=status,
                        updated=(NOW - timedelta(minutes=10 + i)).isoformat().replace("+00:00", "Z"))
                for i in range(n)]

    def test_big_tracks_are_never_batched(self):
        judge = BatchJudge(jr("SUSPECT", 0.6))
        _, stats = run_audit(FakeAdmin(self.burst(3), {"t9": []}, PROFILES), self.ledger, judge,
                             Config(mode="audit", sample_rate=0.0, budget_usd=5), window_min=90, now=NOW)
        self.assertEqual(judge.batches, [])          # t9 is a big track (pop 75): one call each
        self.assertEqual(stats.model_calls, 3)

    def test_audit_judges_a_profile_burst_in_one_call_per_batch(self):
        judge = BatchJudge(jr("SUSPECT", 0.6))
        reqs = [dict(r, trackId="t3", spotifyPopularity=3) for r in self.burst(8)]   # t3: small track
        _, stats = run_audit(FakeAdmin(reqs, {"t3": []}, PROFILES), self.ledger, judge,
                             Config(mode="audit", sample_rate=1.0, budget_usd=5), window_min=90, now=NOW)
        self.assertEqual([len(b) for b in judge.batches], [6, 2])      # PROFILE_BATCH_MAX = 6
        self.assertEqual(stats.model_calls, 2)
        rows = self.ledger.db.execute("SELECT verdict, cost_usd, judge_json FROM reviews WHERE mode='audit'").fetchall()
        self.assertEqual(len(rows), 8)
        self.assertAlmostEqual(sum(r["cost_usd"] for r in rows), 0.12)   # per-claim shares add up to the calls
        self.assertTrue(all(json.loads(r["judge_json"])["batch_size"] in (6, 2) for r in rows))

    def test_a_claim_missing_from_a_batch_answer_is_a_model_error_not_a_pass(self):
        class Partial(BatchJudge):
            def judge_many(self, mode, evidences, ids):
                out = super().judge_many(mode, evidences, ids)
                self.dropped = ids[-1]
                out[ids[-1]] = JudgeResult(ok=False, error="claim missing from the batch answer", batch_size=len(ids))
                return out
        judge = Partial(jr("CONFIRMED", 0.95))
        reqs = [dict(r, trackId="t3", spotifyPopularity=3) for r in self.burst(3)]
        run_audit(FakeAdmin(reqs, {"t3": []}, PROFILES), self.ledger, judge,
                  Config(mode="audit", sample_rate=1.0, budget_usd=5), window_min=90, now=NOW)
        last = self.ledger.db.execute("SELECT verdict, basis FROM reviews WHERE request_id=?", (judge.dropped,)).fetchone()
        self.assertEqual(last["basis"], "model_error")
        self.assertNotEqual(last["verdict"], "CONFIRMED")
        others = self.ledger.db.execute("SELECT DISTINCT basis FROM reviews WHERE request_id != ?", (judge.dropped,)).fetchall()
        self.assertNotIn("model_error", {r[0] for r in others})

    def test_each_claim_missing_from_a_batch_answer_counts_as_an_error(self):
        class MostlyMissing(BatchJudge):
            def judge_many(self, mode, evidences, ids):
                out = super().judge_many(mode, evidences, ids)
                for rid in ids[1:]:
                    out[rid] = JudgeResult(ok=False, error="claim missing from the batch answer", batch_size=len(ids))
                return out
        judge = MostlyMissing(jr("SUSPECT", 0.6))
        reqs = [dict(r, trackId="t3", spotifyPopularity=3) for r in self.burst(6)]
        _, stats = run_audit(FakeAdmin(reqs, {"t3": []}, PROFILES), self.ledger, judge,
                             Config(mode="audit", sample_rate=1.0, budget_usd=5), window_min=90, now=NOW)
        self.assertEqual(stats.model_calls, 1)
        self.assertEqual(stats.errors, 5)

    def test_budget_reservation_covers_a_whole_prior_batch_call(self):
        ts = (NOW - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for i in range(6):
            self.ledger.record({"request_id": f"p{i}", "mode": "audit", "phase": "live", "verdict": "SUSPECT",
                                "confidence": 0.5, "basis": "model_suspect", "model": "x-ai/grok-4.3",
                                "cost_usd": 0.025, "judge_json": {"ok": True, "batch_size": 6}, "reviewed_at": ts})
        self.assertAlmostEqual(self.ledger.dearest_call_since(ts), 0.15)
        judge = BatchJudge(jr("SUSPECT", 0.6), cost=0.15)
        reqs = [dict(r, trackId="t3", spotifyPopularity=3) for r in self.burst(6)]
        _, stats = run_audit(FakeAdmin(reqs, {"t3": []}, PROFILES), self.ledger, judge,
                             Config(mode="audit", sample_rate=1.0, budget_usd=0.10), window_min=90, now=NOW)
        self.assertEqual(judge.calls, 0)
        self.assertTrue(stats.budget_stopped)

    def test_eval_batch_reports_model_spend_when_the_first_row_has_no_evidence(self):
        from credit_review import evaluate

        class BrokenFirstTrack(FakeAdmin):
            def get(self, path, params=None):
                if path == "/admin/track/tx/raw-credits":
                    raise admin_api.AdminError("503")
                return super().get(path, params)
        reqs = [request("e0", pid=PID_BAD, track="tx", pop=75, roles=("Producer",))] + [
            request(f"e{i}", pid=PID_BAD, track="t9", pop=75, roles=("Producer",)) for i in range(1, 4)]
        judge = FakeJudge(jr("SUSPECT", 0.6, cost=0.04))
        orig = evaluate.Judge
        evaluate.Judge = lambda *a, **k: judge
        try:
            res = evaluate.run_arm(BrokenFirstTrack(reqs, {"t9": []}, PROFILES), self.ledger,
                                   [("known_bad", r) for r in reqs], "fake", "full", "audit",
                                   budget_usd=5, batch=True)
        finally:
            evaluate.Judge = orig
        self.assertEqual(judge.calls, 3)
        self.assertEqual(res.stats.model_calls, 3)
        self.assertAlmostEqual(res.stats.cost_usd, 0.12)
        self.assertEqual(res.stats.errors, 1)

    def test_review_batches_held_claims_per_profile(self):
        judge = BatchJudge(jr("NEEDS-HUMAN", 0.5))
        reqs = [dict(r, trackId="t3", spotifyPopularity=3) for r in self.burst(4, status="unverified")] + [
            request("solo", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",), status="unverified")]
        _, stats = run_review(FakeAdmin(reqs, {"t9": [], "t3": []}, PROFILES), self.ledger, judge,
                              Config(mode="review", phase="shadow", budget_usd=5), limit=10, sample_approved=0, now=NOW)
        self.assertEqual(stats.model_calls, 2)          # one batch of 4 + one single call
        self.assertEqual(sorted(len(b) for b in judge.batches), [4])
        self.assertEqual(stats.reviewed, 5)

    def test_shadow_sample_skips_approvals_the_audit_already_model_checked(self):
        approved = [request(f"a{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(40)]
        picked = [r["id"] for r in approved if sampled(r["id"], 0.5)]
        for rid in picked[:3]:
            self.ledger.record({"request_id": rid, "mode": "audit", "phase": "live", "verdict": "SUSPECT",
                                "confidence": 0.5, "basis": "model_suspect", "big_track": True,
                                "model": "x-ai/grok-4.3", "reviewed_at": (NOW - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")})
        judge = FakeJudge(jr("NEEDS-HUMAN", 0.5))
        run_review(FakeAdmin(approved, {"t9": []}, PROFILES), self.ledger, judge,
                   Config(mode="review", phase="shadow", budget_usd=50), limit=0, sample_approved=len(picked), now=NOW)
        reviewed = {r[0] for r in self.ledger.db.execute("SELECT request_id FROM reviews WHERE mode='review'")}
        self.assertFalse(reviewed & set(picked[:3]))
        self.assertEqual(reviewed, set(picked[3:]))

    def test_shadow_sample_keeps_approvals_whose_audit_model_check_failed(self):
        approved = [request(f"a{i}", pid=PID_GOOD, track="t9", pop=75, roles=("Producer",)) for i in range(40)]
        picked = [r["id"] for r in approved if sampled(r["id"], 0.5)]
        for rid in picked[:3]:
            self.ledger.record({"request_id": rid, "mode": "audit", "phase": "live", "verdict": "SUSPECT",
                                "confidence": 0.3, "basis": "model_error", "big_track": True,
                                "model": "x-ai/grok-4.3", "reviewed_at": (NOW - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")})
        judge = FakeJudge(jr("NEEDS-HUMAN", 0.5))
        run_review(FakeAdmin(approved, {"t9": []}, PROFILES), self.ledger, judge,
                   Config(mode="review", phase="shadow", budget_usd=50), limit=0, sample_approved=len(picked), now=NOW)
        reviewed = {r[0] for r in self.ledger.db.execute("SELECT request_id FROM reviews WHERE mode='review'")}
        self.assertEqual(reviewed, set(picked))

    def test_search_junk_domains_are_excluded_from_the_web_search(self):
        import os
        body = Judge("x-ai/grok-4.3", key="k").payload("audit", {})
        self.assertEqual(body["plugins"][0]["exclude_domains"],
                         ["muso.ai", "soundbetter.com", "pandora.com", "imdb.com", "mobygames.com"])
        os.environ["CREDIT_REVIEW_WEB_EXCLUDE"] = "a.com, B.com,a.com,c.com,d.com,e.com,f.com"
        try:
            self.assertEqual(Judge(key="k").payload("audit", {})["plugins"][0]["exclude_domains"],
                             ["a.com", "b.com", "c.com", "d.com", "e.com"])   # xAI native: at most 5
            os.environ["CREDIT_REVIEW_WEB_EXCLUDE"] = ""
            self.assertNotIn("exclude_domains", Judge(key="k").payload("audit", {})["plugins"][0])
        finally:
            del os.environ["CREDIT_REVIEW_WEB_EXCLUDE"]

    def test_batch_answer_parsing(self):
        from credit_review.judge import parse_batch_answer
        text = json.dumps({"claims": [
            {"claim_id": "c1", "verdict": "SUSPECT", "confidence": 0.7, "findings": []},
            {"claim_id": "c2", "verdict": "BOGUS", "confidence": 0.7},
            {"claim_id": "zz", "verdict": "SUSPECT", "confidence": 0.7},
            {"claim_id": "c1", "verdict": "CONFIRMED", "confidence": 0.99}]})
        out = parse_batch_answer(text, "audit", ["c1", "c2", "c3"])
        self.assertEqual(set(out), {"c1"})                 # invalid, unknown and missing ids are absent
        self.assertEqual(out["c1"]["verdict"], "SUSPECT")  # first answer per id wins

    def test_judge_many_end_to_end_shares_citations_and_splits_cost(self):
        resp = {"usage": {"cost": 0.09, "prompt_tokens": 9000, "completion_tokens": 900},
                "choices": [{"message": {"annotations": [
                    {"type": "url_citation", "url_citation": {"url": "https://www.discogs.com/release/1"}}],
                    "content": json.dumps({"claims": [
                        {"claim_id": "c1", "verdict": "CONTRADICTED", "confidence": 0.9,
                         "findings": [{"source_url": "https://www.discogs.com/release/1", "says": "x",
                                       "effect": "contradicts"}]},
                        {"claim_id": "c2", "verdict": "SUSPECT", "confidence": 0.6}]})}}]}
        j = Judge(key="k")
        sent = []
        j._post = lambda body, res, timeout=None: sent.append(json.dumps(body)) or resp
        out = j.judge_many("audit", [{"claim": {}}, {"claim": {}}, {"claim": {}}], ["r1", "r2", "r3"])
        self.assertEqual(out["r1"].verdict, "CONTRADICTED")
        self.assertEqual(out["r1"].contradicting_domains(), {"discogs.com"})
        self.assertEqual(out["r2"].cited_urls, ["https://www.discogs.com/release/1"])
        self.assertFalse(out["r3"].ok)
        self.assertAlmostEqual(sum(r.cost_usd for r in out.values()), 0.09)
        # firstmate 042: internal request ids never reach the provider; local aliases do.
        self.assertNotIn("r1", sent[0].replace("\\", ""))
        self.assertIn('\\"claim_id\\": \\"c1\\"', sent[0])


class CronOutputTests(unittest.TestCase):
    """firstmate 035: #credit-verification showed 'stdout: NO_REPLY / stderr:
    [credit-review] ...'. openclaw posts stdout AND stderr of a command cron, so a
    cron run writes nothing to stderr: NO_REPLY alone when there is nothing to act
    on, plain alert lines otherwise, and a crash is one plain line."""

    def setUp(self):
        self.cli = load_cli()
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.cli.KILL_SWITCH = d / "off"
        self.cli.MODEL_ENABLE_FILE = d / "model.enabled"   # absent: catalog-only, no balance read
        self.log_path = d / "run.log"
        self._saved_log = runner_mod.LOG_PATH
        runner_mod.LOG_PATH = str(self.log_path)
        self.ledger_path = str(d / "l.sqlite3")
        self.cli.admin_api.AdminClient = lambda *a, **k: FakeAdmin([], {}, PROFILES)

    def tearDown(self):
        runner_mod.LOG_PATH = self._saved_log
        self.cli.admin_api.AdminClient = admin_api.AdminClient
        self.tmp.cleanup()

    def run_cli(self, *argv):
        import contextlib
        import io
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.cli.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_quiet_audit_posts_exactly_no_reply_and_logs_to_the_file(self):
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
        self.assertEqual((rc, out, err), (0, "NO_REPLY\n", ""))
        self.assertIn("[credit-review] audit", self.log_path.read_text())

    def test_quiet_review_posts_exactly_no_reply(self):
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "review", "--phase", "shadow")
        self.assertEqual((rc, out, err), (0, "NO_REPLY\n", ""))

    def test_burst_reaches_the_cron_output_with_no_stderr(self):
        led = Ledger(self.ledger_path)
        recent = (datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for i in range(12):
            _audit_row(led, f"z{i}", "zach", "SUSPECT", recent)
        led.close()
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(out.count("CREDIT-AUDIT ALERT: burst of approvals on one profile - Zach Miller (zach)"), 1)
        self.assertNotIn("NO_REPLY", out)
        self.assertNotIn("[credit-review]", out)

    def audit_with(self, reqs, **run_kwargs):
        self.cli.admin_api.AdminClient = lambda *a, **k: FakeAdmin(reqs, {"t3": []}, PROFILES)
        self.cli.run_audit = lambda *a, **k: run_audit(*a, **{**k, **run_kwargs})
        try:
            return self.run_cli("--ledger", self.ledger_path, "audit", "--sample-rate", "0")
        finally:
            self.cli.run_audit = run_audit

    @staticmethod
    def approvals(prefix, minutes_ago):
        now = datetime.now(timezone.utc)
        return [request(f"{prefix}{m}", pid=PID_GOOD, track="t3",
                        updated=(now - timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
                for m in minutes_ago]

    def burst_lines(self, out):
        return [line for line in out.splitlines() if "burst of approvals on one profile" in line and PID_GOOD in line]

    def test_approvals_beyond_an_early_stop_mark_alert_on_the_next_run(self):
        reqs = self.approvals("e", range(60, 38, -1))
        orig = runner_mod.AUDIT_CHUNK
        runner_mod.AUDIT_CHUNK = 5
        try:
            rc, out, err = self.audit_with(reqs, deadline_s=0)
        finally:
            runner_mod.AUDIT_CHUNK = orig
        self.assertEqual((rc, err), (0, ""))
        self.assertIn("stopped at its 0s deadline", out)
        self.assertEqual(self.burst_lines(out), [])
        rc, out, err = self.audit_with(reqs)
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(len(self.burst_lines(out)), 1, out)
        self.assertIn("22 approval(s) within 2h", self.burst_lines(out)[0])
        rc, out, _ = self.audit_with(reqs)
        self.assertEqual(self.burst_lines(out), [])

    def test_approvals_made_after_the_audit_fetch_alert_on_the_next_run(self):
        early = self.approvals("f", range(30, 15, -1))
        rc, out, err = self.audit_with(early, now=datetime.now(timezone.utc) - timedelta(minutes=10))
        self.assertEqual((rc, out, err), (0, "NO_REPLY\n", ""))
        late = self.approvals("g", range(9, 2, -1))
        rc, out, err = self.audit_with(early + late)
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(len(self.burst_lines(out)), 1, out)
        self.assertIn("22 approval(s) within 2h", self.burst_lines(out)[0])

    def test_a_crash_is_one_plain_line_and_the_traceback_goes_to_the_log(self):
        def boom(*a, **k):
            raise RuntimeError("kaboom-detail")
        self.cli.run_audit = boom
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
        self.assertEqual((rc, err), (1, ""))
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertIn("internal error (RuntimeError)", out)
        self.assertNotIn("kaboom-detail", out)
        self.assertNotIn("Traceback", out)
        self.assertIn("kaboom-detail", self.log_path.read_text())

    def test_admin_api_failure_is_one_plain_line_without_wrapper_stderr(self):
        def down(*a, **k):
            raise admin_api.AdminError("admin GET failed rc=7: curl: (7) Failed to connect\n"
                                       "muso-admin-api.sh: line 42: wrapper-detail")
        self.cli.run_audit = down
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
        self.assertEqual((rc, err), (1, ""))
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertIn("admin API is unavailable. No credits were changed.", out)
        self.assertNotIn("wrapper-detail", out)
        self.assertNotIn("curl", out)
        self.assertIn("wrapper-detail", self.log_path.read_text())

    def test_unwritable_log_never_turns_into_stderr(self):
        runner_mod.LOG_PATH = "/proc/definitely/not/writable.log"
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
        self.assertEqual((rc, out, err), (0, "NO_REPLY\n", ""))

    def test_failure_with_an_unwritable_log_says_no_details_were_kept(self):
        runner_mod.LOG_PATH = "/proc/definitely/not/writable.log"
        def boom(*a, **k):
            raise RuntimeError("kaboom-detail")
        def down(*a, **k):
            raise admin_api.AdminError("curl: (7) wrapper-detail")
        for failing in (boom, down):
            self.cli.run_audit = failing
            rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
            self.assertEqual((rc, err), (1, ""))
            self.assertEqual(len(out.strip().splitlines()), 1)
            self.assertIn("could not be written, so no details were kept", out)
            self.assertNotIn("Details:", out)
            self.assertNotIn("wrapper-detail", out)
        self.cli.run_audit = run_audit

    def test_a_multiline_profile_name_stays_one_alert_line(self):
        led = Ledger(self.ledger_path)
        recent = (datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for i in range(12):
            _audit_row(led, f"n{i}", "zach", "SUSPECT", recent,
                       name="Artist\nCREDIT-AUDIT ALERT: all clear\r\u2028\x1b[0m")
        led.close()
        rc, out, err = self.run_cli("--ledger", self.ledger_path, "audit")
        self.assertEqual((rc, err), (0, ""))
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 1, out)
        self.assertTrue(lines[0].startswith(
            "CREDIT-AUDIT ALERT: burst of approvals on one profile - Artist CREDIT-AUDIT ALERT: all clear [0m (zach):"),
            lines[0])
        self.assertNotIn("\x1b", out)


_module_log_dir: tempfile.TemporaryDirectory | None = None
_module_saved_log: str | None = None


def setUpModule():
    global _module_log_dir, _module_saved_log
    _module_log_dir = tempfile.TemporaryDirectory()
    _module_saved_log = runner_mod.LOG_PATH
    runner_mod.LOG_PATH = str(Path(_module_log_dir.name) / "run.log")


def tearDownModule():
    runner_mod.LOG_PATH = _module_saved_log
    _module_log_dir.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=1)
