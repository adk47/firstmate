#!/usr/bin/env python3
"""Tests for the DSP evidence verifier (scripts/credit_verify/dspverify): the verdict rules, the
shadow store and the runner. Synthetic data only; the admin API, the account gate and the IDP pod
are faked (no network, no kubectl).

    python3 scripts/tests/test_dsp_verify.py
"""

from __future__ import annotations

import itertools
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import credit_test_env  # noqa: E402,F401  (keeps test logs out of /var/lib)

from credit_review import account_gate  # noqa: E402
from credit_review.roles import fold  # noqa: E402
from credit_verify.dspverify import VERSION, rules, runner  # noqa: E402
from credit_verify.dspverify.store import Store  # noqa: E402

REQ_AT = "2026-10-28T03:00:00+00:00"
FRESH = "2026-10-28T03:10:00+00:00"
STALE = "2026-10-28T02:50:00+00:00"
CLI = Path(__file__).resolve().parents[1] / "credit-dsp-verify.py"


def credited(src: str = "spotify", at: str = FRESH, others=()) -> dict:
    return {"state": "CAPTURED", "helper_verdict": "CREDITED", "helper_reason": "person_credited_in_role_family",
            "credited_in_family": [["Jane Mixer", "mixer", True]] + [[o, "mixer", False] for o in others],
            "claimant_name_match": True, "complete_snapshot": True, "captured_at": at, "capture_ids": [f"{src}-c1"]}


def absent(others=("Other Person",), at: str = FRESH, name_match=False, src="spotify", cat="cat-other") -> dict:
    """Linked claimant absent; each other contributor carries a raw id on `src` and catalog id `cat`
    (None = no catalog profile links it)."""
    return {"state": "CAPTURED", "helper_verdict": "NOT_CREDITED", "helper_reason": "person_absent_from_complete_snapshot",
            "credited_in_family": [[o, "mixer", False, f"{src}:{fold(o)}", cat and f"{cat}-{fold(o)}"] for o in others],
            "credited_total": len(set(others)), "unresolved_in_family": [], "claimant_name_match": name_match,
            "complete_snapshot": True, "captured_at": at}


def not_linked(src: str, name_match=False, at: str = FRESH) -> dict:
    return {"state": "CAPTURED", "helper_verdict": "UNKNOWN", "helper_reason": f"person_not_linked_on_{src}",
            "credited_in_family": [["Jane Mixer", "mixer", False]] if name_match else [],
            "claimant_name_match": name_match, "complete_snapshot": True, "captured_at": at}


NO_REC = {"state": "NO_RECORDING", "helper_verdict": "UNKNOWN", "helper_reason": "no_tidal_recording_on_track"}
WAITING = {"state": "WAITING", "helper_verdict": "WAITING", "helper_reason": "waiting_for_fresh_capture"}


def packet(roles=("Mixing",), sources=None, **kw) -> dict:
    sources = sources if sources is not None else {r: {"spotify": credited(), "tidal": credited("tidal")}
                                                   for r in roles}
    p = {"request_id": "11111111-1111-1111-1111-111111111111", "user_id": 42, "profile_id": "prof-1",
         "profile_name": "Jane Mixer", "profile_type": "person", "track_id": "trk-1", "roles": list(roles),
         "popularity": 20, "artist_popularity": 40, "profile_credit_count": 30,
         "verification_data": {"rule_risk_percent": {"risk_score_at_or_above_threshold": 40,
                                                     "score:collaborations": 80}, "total_risk_percent": 45},
         "capture": {"request_id": "cap-1", "requested_at": REQ_AT,
                     "roles": {r: {"sources": s} for r, s in sources.items()}},
         "gate": {"decision": "allow", "band": "green", "reasons": []},
         "flags": {"watchlist": False, "deny_user": False, "deny_profile": False, "idp_hold": False},
         "duplicate_of": None, "name_collisions": 0}
    p.update(kw)
    return p


class RoleClassification(unittest.TestCase):
    def test_one_person_roles(self):
        for r in ("Mixing", "Mastering", "Remastering", "Bass", "Bass Guitar", "Drums", "Drummer", "Mix Engineer",
                  "Immersive Mixing"):
            self.assertTrue(rules.one_person_role(r), r)
        for r in ("Producer", "Composer", "Guitar", "Bassoon", "Double Bass", "Synth Bass", "Drum Programming",
                  "Recording Engineer", "Vocals"):
            self.assertFalse(rules.one_person_role(r), r)

    def test_role_kinds(self):
        self.assertEqual(rules.role_kind("Record Label"), "org")
        self.assertEqual(rules.role_kind("Publisher"), "org")
        self.assertEqual(rules.role_kind("Video Director"), "not_dsp")
        self.assertEqual(rules.role_kind("A&R"), "not_dsp")
        self.assertEqual(rules.role_kind("Photography"), "not_dsp")
        self.assertEqual(rules.role_kind("Vocal Editing"), "editorial")
        self.assertEqual(rules.role_kind("Mixing"), "person_dsp")
        self.assertEqual(rules.role_kind("Producer"), "person_dsp")

    def test_validator_fraud_rules(self):
        vd = {"rule_risk_percent": {"reject_high_velocity_profile": 100, "reject_publisher_label_credit": 100,
                                    "risk_score_at_or_above_threshold": 50, "score:profile_credit": 90,
                                    "reject_high_pop_name_mismatch": 0}}
        self.assertEqual(rules.validator_fraud_rules(vd), ["reject_high_velocity_profile"])


class Approve(unittest.TestCase):
    def test_both_dsps_by_id_approves(self):
        v = rules.verify(packet())
        self.assertEqual(v.verdict, rules.APPROVE, v.reason)
        self.assertEqual(v.approve_roles, ["Mixing"])
        self.assertEqual(v.anchor, "both")
        self.assertGreaterEqual(v.confidence, 0.9)
        self.assertEqual(v.version, VERSION)

    def test_single_dsp_never_approves(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": credited(), "tidal": NO_REC}}))
        self.assertEqual(v.verdict, rules.WAIT)
        self.assertEqual(v.reason_class, "single_dsp_anchor")
        self.assertEqual(v.anchor, "single")
        self.assertEqual(v.need, "second_dsp_anchor")

    def test_stale_capture_never_counts(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": credited(at=STALE), "tidal": credited("tidal")}}))
        self.assertNotEqual(v.verdict, rules.APPROVE)
        self.assertEqual(v.roles[0]["spotify"]["state"], rules.S_UNKNOWN)

    def test_no_capture_never_approves(self):
        p = packet()
        p["capture"] = None
        v = rules.verify(p)
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "no_fresh_capture"))

    def test_helper_credited_without_id_pair_is_unknown(self):
        bad = credited()
        bad["credited_in_family"] = [["Jane Mixer", "mixer", False]]
        v = rules.verify(packet(sources={"Mixing": {"spotify": bad, "tidal": credited("tidal")}}))
        self.assertNotEqual(v.verdict, rules.APPROVE)

    def test_role_edit_only_credited_roles(self):
        v = rules.verify(packet(roles=("Mixing", "Producer"), sources={
            "Mixing": {"spotify": credited(), "tidal": credited("tidal")},
            "Producer": {"spotify": absent(("Big Producer",)), "tidal": absent(("Big Producer",))}}))
        self.assertEqual(v.verdict, rules.APPROVE)
        self.assertEqual(v.approve_roles, ["Mixing"])
        self.assertEqual(v.role_edit_roles, ["Producer"])
        self.assertLess(v.confidence, 0.9)

    def test_tidal_every_country(self):
        allc = {"countries": {"US": credited("tidal"), "GB": credited("tidal"), "DE": credited("tidal")}}
        self.assertEqual(rules.verify(packet(sources={"Mixing": {"spotify": credited(), "tidal": allc}})).verdict,
                         rules.APPROVE)
        split = {"countries": {"US": credited("tidal"), "GB": absent()}}
        v = rules.verify(packet(sources={"Mixing": {"spotify": credited(), "tidal": split}}))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "dsp_conflict"))
        unk = {"countries": {"US": credited("tidal"), "GB": {"state": "CAPTURE_ERROR"}}}
        self.assertNotEqual(rules.verify(packet(sources={"Mixing": {"spotify": credited(), "tidal": unk}})).verdict,
                            rules.APPROVE)

    def test_editorial_only_under_pop_30(self):
        src = {"Vocal Editing": {"spotify": credited(), "tidal": credited("tidal")}}
        self.assertEqual(rules.verify(packet(roles=("Vocal Editing",), sources=src, popularity=10)).verdict,
                         rules.APPROVE)
        v = rules.verify(packet(roles=("Vocal Editing",), sources=src, popularity=40))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "editorial_role"))


class Guards(unittest.TestCase):
    def blocked(self, **kw) -> rules.Verdict:
        v = rules.verify(packet(**kw))
        self.assertEqual(v.verdict, rules.WAIT, v.reason)
        self.assertEqual(v.reason_class, "anchored_but_blocked")
        return v

    def test_gate(self):
        self.assertIn("gate_hold", self.blocked(gate={"decision": "hold", "reasons": ["unanchored 40"]}).reason)
        self.blocked(gate={"decision": "unknown"})
        self.blocked(gate=None)
        self.blocked(gate={"decision": "allow", "band": "red"})
        v = rules.verify(packet(gate={"decision": "allow", "band": "amber"}))
        self.assertEqual(v.verdict, rules.APPROVE)
        self.assertLess(v.confidence, 0.9)

    def test_big_track_and_unknown_popularity(self):
        self.blocked(popularity=60)
        self.blocked(popularity=None)
        self.blocked(artist_popularity=90)
        self.blocked(profile_credit_count=250)

    def test_unknown_artist_popularity_or_credit_count_blocks(self):
        # QA @274a979: unknowns fail closed; a None artist popularity passes only when every linked
        # artist was read and there are none.
        self.blocked(artist_popularity=None)
        self.blocked(artist_popularity=None, artists_known=False)
        self.assertEqual(rules.verify(packet(artist_popularity=None, artists_known=True)).verdict, rules.APPROVE)
        self.blocked(profile_credit_count=None)

    def test_unknown_duplicate_check_blocks(self):
        self.blocked(duplicate_unknown=True)
        p = packet()
        del p["duplicate_of"]
        self.assertEqual(rules.verify(p).reason_class, "anchored_but_blocked")

    def test_flagged(self):
        self.blocked(flags={"watchlist": True})
        self.blocked(flags={"deny_user": True})
        self.blocked(flags={"watchlist": False, "deny_user": False, "deny_profile": False, "idp_hold": True})
        p = packet()
        del p["flags"]
        self.assertEqual(rules.verify(p).reason_class, "anchored_but_blocked")

    def test_every_guard_flag_must_be_explicit(self):
        # QA @dfe29fd: only an explicit False clears a guard.
        self.assertIn("flags_unknown", self.blocked(flags={}).reason)
        for k in rules.GUARD_FLAGS:
            for val in ("missing", None, 0, "false"):
                f = {g: False for g in rules.GUARD_FLAGS}
                if val == "missing":
                    del f[k]
                else:
                    f[k] = val
                self.assertIn(f"flags_unknown: {k}", self.blocked(flags=f).reason)

    def test_validator_fraud_rule_blocks_but_risk_score_and_source_rules_do_not(self):
        self.blocked(verification_data={"rule_risk_percent": {"reject_high_velocity_profile": 100}})
        ok = rules.verify(packet(verification_data={"rule_risk_percent": {
            "risk_score_at_or_above_threshold": 80, "reject_artist_credit": 100}}))
        self.assertEqual(ok.verdict, rules.APPROVE)

    def test_common_name(self):
        self.blocked(profile_name="Freezy")                       # one token: common even at 0
        self.blocked(profile_name="Ivan Garcia", name_collisions=3)
        # QA @8487d4f: unknown collisions block every name, not only one-token names.
        self.blocked(profile_name="John Smith", name_collisions=None)
        p = packet(profile_name="John Smith")
        del p["name_collisions"]
        self.assertEqual(rules.verify(p).reason_class, "anchored_but_blocked")

    def test_validator_findings_unknown_block(self):
        self.assertIn("validator_unknown", self.blocked(verification_data=None).reason)
        self.blocked(verification_data={})
        self.blocked(verification_data={"rule_risk_percent": "oops"})

    def test_duplicate(self):
        v = rules.verify(packet(duplicate_of="22222222-2222-2222-2222-222222222222"))
        self.assertEqual(v.verdict, rules.DUPLICATE)


class Decline(unittest.TestCase):
    def test_one_person_role_contradicted_on_both(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(), "tidal": absent(src="tidal")}}))
        self.assertEqual(v.verdict, rules.DECLINE, v.reason)
        self.assertEqual(v.decline_roles, ["Mixing"])

    def test_decline_ignores_approval_guards(self):
        # Guards only stand in front of an APPROVE; a contradiction is evidence either way.
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(), "tidal": absent(src="tidal")}}, popularity=80))
        self.assertEqual(v.verdict, rules.DECLINE)

    def test_multi_person_role_never_declines(self):
        v = rules.verify(packet(roles=("Producer",), sources={"Producer": {"spotify": absent(), "tidal": absent(src="tidal")}}))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "others_only"))

    def test_same_name_different_people_never_declines(self):
        # QA @80c295a: identity is the catalog profile holding both raw ids, never the name.
        for tidal in (absent(src="tidal", cat="cat-elsewhere"), absent(src="tidal", cat=None)):
            v = rules.verify(packet(sources={"Mixing": {"spotify": absent(), "tidal": tidal}}))
            self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "one_person_identity_unproven"))
        legacy = absent()
        legacy["credited_in_family"] = [["Other Person", "mixer", False]]      # no ids at all
        v = rules.verify(packet(sources={"Mixing": {"spotify": legacy, "tidal": legacy}}))
        self.assertNotEqual(v.verdict, rules.DECLINE)

    def test_clipped_or_uncounted_contributor_list_never_declines(self):
        # QA @ba10b8e: 25 rows of one other person, a 26th of somebody else, list clipped to 25.
        for side in ("spotify", "tidal"):
            r = {"spotify": absent(), "tidal": absent(src="tidal")}
            r[side]["credited_total"] = 2                     # a second contributor exists off the list
            v = rules.verify(packet(sources={"Mixing": r}))
            self.assertNotEqual(v.verdict, rules.DECLINE, side)
            r = {"spotify": absent(), "tidal": absent(src="tidal")}
            del r[side]["credited_total"]                     # no total: completeness unproven
            self.assertNotEqual(rules.verify(packet(sources={"Mixing": r})).verdict, rules.DECLINE, side)
        many = absent()
        many["credited_in_family"] = many["credited_in_family"] * 25    # duplicates of ONE person still decline
        self.assertEqual(rules.verify(packet(sources={"Mixing": {"spotify": many, "tidal": absent(src="tidal")}}))
                         .verdict, rules.DECLINE)

    def test_missing_state_or_completeness_is_unknown(self):
        # QA @2d6833a: only an explicit CAPTURED state anchors; only complete_snapshot True declines.
        for side in ("spotify", "tidal"):
            for val in ("missing", None, "", "SOMETHING"):
                r = {"spotify": credited(), "tidal": credited("tidal")}
                if val == "missing":
                    del r[side]["state"]
                else:
                    r[side]["state"] = val
                self.assertNotEqual(rules.verify(packet(sources={"Mixing": r})).verdict, rules.APPROVE, (side, val))
            for val in ("missing", None, False, "true"):
                r = {"spotify": absent(), "tidal": absent(src="tidal")}
                if val == "missing":
                    del r[side]["complete_snapshot"]
                else:
                    r[side]["complete_snapshot"] = val
                self.assertNotEqual(rules.verify(packet(sources={"Mixing": r})).verdict, rules.DECLINE, (side, val))

    def test_unresolved_contributor_never_declines(self):
        # QA @8c5a44f: same resolved other mixer on both DSPs plus an unresolved Mixing credit.
        for side in ("spotify", "tidal"):
            r = {"spotify": absent(), "tidal": absent(src="tidal")}
            r[side]["unresolved_in_family"] = [["Some Mixer", "mixer"]]
            v = rules.verify(packet(sources={"Mixing": r}))
            self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "one_person_identity_unproven"), side)
            r = {"spotify": absent(), "tidal": absent(src="tidal")}
            del r[side]["unresolved_in_family"]                # not reported: completeness unproven
            self.assertNotEqual(rules.verify(packet(sources={"Mixing": r})).verdict, rules.DECLINE, side)

    def test_one_source_is_not_enough(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(), "tidal": NO_REC}}))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "one_source_contradiction"))

    def test_different_others_is_a_conflict(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(("A Person",)), "tidal": absent(("B Person",))}}))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "one_person_conflict"))

    def test_nobody_in_role(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(()), "tidal": absent(())}}))
        self.assertEqual(v.reason_class, "nobody_in_role")

    def test_stale_absence_never_declines(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(at=STALE), "tidal": absent()}}))
        self.assertNotEqual(v.verdict, rules.DECLINE)

    def test_partial_contradiction_waits_with_decline_roles(self):
        v = rules.verify(packet(roles=("Mixing", "Producer"), sources={
            "Mixing": {"spotify": absent(), "tidal": absent(src="tidal")},
            "Producer": {"spotify": not_linked("spotify"), "tidal": NO_REC}}))
        self.assertEqual(v.verdict, rules.WAIT)
        self.assertEqual(v.decline_roles, ["Mixing"])
        self.assertTrue(any(s.startswith("partly_contradicted") for s in v.signals))


class WaitClasses(unittest.TestCase):
    def test_name_only_needs_link(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": not_linked("spotify", name_match=True),
                                                    "tidal": NO_REC}}))
        self.assertEqual((v.verdict, v.reason_class, v.need), (rules.WAIT, "needs_profile_link", "link_profile"))

    def test_not_linked(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": not_linked("spotify"), "tidal": NO_REC}}))
        self.assertEqual((v.reason_class, v.need), ("person_not_linked", "link_profile"))

    def test_link_mismatch(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": absent(("Jane Mixer",), name_match=True),
                                                    "tidal": NO_REC}}))
        self.assertEqual((v.reason_class, v.need), ("link_mismatch", "fix_profile_link"))

    def test_window_closed_is_unknown_not_pending(self):
        closed = {"state": "NO_FRESH_CAPTURE", "helper_verdict": "WAITING", "helper_reason": "waiting_for_fresh_capture"}
        v = rules.verify(packet(sources={"Mixing": {"spotify": credited(), "tidal": closed}}))
        self.assertEqual(v.reason_class, "single_dsp_anchor")
        self.assertEqual(v.roles[0]["tidal"]["state"], rules.S_UNKNOWN)

    def test_not_linked_is_never_pending(self):
        waiting_unlinked = {"state": "WAITING", "helper_verdict": "UNKNOWN", "helper_reason": "person_not_linked_on_tidal"}
        v = rules.verify(packet(sources={"Mixing": {"spotify": not_linked("spotify"), "tidal": waiting_unlinked}}))
        self.assertEqual(v.reason_class, "person_not_linked")

    def test_pending(self):
        v = rules.verify(packet(sources={"Mixing": {"spotify": WAITING, "tidal": credited("tidal")}}))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "capture_pending"))

    def test_not_dsp_role(self):
        v = rules.verify(packet(roles=("Video Director",), sources={}))
        self.assertEqual((v.reason_class, v.need), ("not_dsp_verifiable", "org_or_label_letter"))

    def test_org_lane(self):
        strings = [{"kind": "release_copyright_p", "string": "℗ 2024 Controlled Substance, LLC"}]
        v = rules.verify(packet(roles=("Record Label",), sources={}, profile_type="organization",
                                profile_name="Substance Controlled LLC", label_strings=strings))
        self.assertEqual((v.verdict, v.reason_class), (rules.WAIT, "org_label_anchor"))
        self.assertEqual(v.evidence["org"]["org_string_match"], "match")
        v = rules.verify(packet(roles=("Record Label",), sources={}, profile_type="organization",
                                profile_name="Other Label", label_strings=strings))
        self.assertEqual(v.reason_class, "org_not_on_label_strings")
        v = rules.verify(packet(roles=("Record Label",), sources={}, profile_type="organization",
                                profile_name="Records Music LLC", label_strings=strings))
        self.assertEqual(v.reason_class, "org_string_missing")    # generic-only name never matches
        v = rules.verify(packet(roles=("Publisher",), sources={}, profile_type="person", profile_name="Jane Mixer"))
        self.assertEqual(v.reason_class, "org_role_on_person_profile")

    def test_malformed(self):
        self.assertEqual(rules.verify({"request_id": "x", "roles": []}).reason_class, "malformed")


class UnknownNeverApproves(unittest.TestCase):
    """Exhaustive over per-source readings: APPROVE only when BOTH DSPs credit the linked id in a
    fresh capture; DECLINE only when both are complete, fresh, and name the same one other person."""

    def test_combinations(self):
        readings = {"credited": credited(), "credited_stale": credited(at=STALE), "absent": absent(),
                    "absent_other": absent(("B Person",)), "absent_stale": absent(at=STALE),
                    "not_linked": not_linked("spotify"), "name_only": not_linked("spotify", True),
                    "no_rec": NO_REC, "waiting": WAITING, "error": {"state": "CAPTURE_ERROR"},
                    "no_fresh": {"state": "NO_FRESH_CAPTURE"}, "missing": None,
                    "credited_no_state": {k: v for k, v in credited().items() if k != "state"},
                    "absent_no_complete": {k: v for k, v in absent().items() if k != "complete_snapshot"},
                    "absent_incomplete": {**absent(), "complete_snapshot": False},
                    "incomplete": {"state": "CAPTURED", "helper_verdict": "UNKNOWN",
                                   "helper_reason": "incomplete_credit_snapshot", "captured_at": FRESH}}
        for (a, ra), (b, rb) in itertools.product(readings.items(), repeat=2):
            v = rules.verify(packet(sources={"Mixing": {"spotify": ra, "tidal": rb}}))
            if v.verdict == rules.APPROVE:
                self.assertEqual((a, b), ("credited", "credited"))
            if v.verdict == rules.DECLINE:
                self.assertIn((a, b), {("absent", "absent"), ("absent_other", "absent_other")})


class Selection(unittest.TestCase):
    def test_trino_selector_and_scoped_reads(self):
        sql_seen = []

        def query(sql):
            sql_seen.append(sql)
            return '"00000000-0000-0000-0000-000000000001","prof-1","trk-9"\n"bad","x"\n'
        sel = runner.trino_open_requests(query)
        self.assertEqual(sel(("unverified",), None, 10), [{"id": "00000000-0000-0000-0000-000000000001",
                                                           "profile_id": "prof-1", "track_id": "trk-9"}])
        self.assertIn("status IN ('unverified')", sql_seen[-1])
        sel(runner.OPEN_STATUSES, {"00000000-0000-0000-0000-000000000001", "x; drop"}, 5)
        self.assertIn("uuid '00000000-0000-0000-0000-000000000001'", sql_seen[-1])
        self.assertNotIn("drop", sql_seen[-1])
        self.assertEqual(sel(runner.OPEN_STATUSES, {"nope"}, 5), [])
        # Every admin list read carries a profile filter (the wrapper refuses unscoped limit > 200).
        admin = FakeAdmin([req(1), req(2)])
        rows = runner.pending_requests(admin, fake_select(admin), ("unverified",), None, 10)
        self.assertEqual(len(rows), 2)


class NoStarvation(unittest.TestCase):
    def test_skipped_requests_never_starve_newer_ones(self):
        # QA @b1c4798: oldest-first LIMIT ran before the open-capture/recent-verdict skip.
        tmp = tempfile.mkdtemp()
        store = Store(os.path.join(tmp, "s.sqlite"))
        reqs = []
        for i in range(1, 10):
            r = req(1)
            r["id"] = f"00000000-0000-0000-0000-00000000000{i}"
            r["trackId"], r["createdAt"] = f"trk-{i}", f"2026-10-0{i}T00:00:00Z"
            reqs.append(r)
        fa = FakeAdmin(reqs)
        d = runner.Deps(admin=fa, select=fake_select(fa), capture=FakePod(),
                        gate=lambda uid: account_gate.GateResult("allow", (), {"band": "green"}),
                        paying=frozenset(), watch_user_ids=frozenset(), watch_profile_ids=frozenset(),
                        now=lambda: datetime(2026, 10, 28, 3, 20, tzinfo=timezone.utc))
        seen = set()
        for _ in range(3):
            st = runner.submit(store, d, max_requests=3)
            self.assertEqual(st.requests, 3)
            got = {x for c in store.open_captures() for x in json.loads(c["request_ids_json"])}
            seen |= got
        self.assertEqual(len(seen), 9)
        self.assertEqual(runner.submit(store, d, max_requests=3).requests, 0)


class PaidFirstBeforeLimit(unittest.TestCase):
    def test_paid_request_beyond_the_window_is_selected_first(self):
        # QA @fba5057: 4 free requests fill a window of 3; the newest request is a paying user's.
        tmp = tempfile.mkdtemp()
        store = Store(os.path.join(tmp, "s.sqlite"))
        reqs = []
        for i in range(1, 6):
            r = req(1, uid=100 + i)
            r["id"] = f"00000000-0000-0000-0000-00000000000{i}"
            r["trackId"], r["createdAt"] = f"trk-{i}", f"2026-10-0{i}T00:00:00Z"
            reqs.append(r)
        fa = FakeAdmin(reqs)
        d = runner.Deps(admin=fa, select=fake_select(fa), capture=FakePod(),
                        gate=lambda uid: account_gate.GateResult("allow", (), {"band": "green"}),
                        paying=frozenset({105}), watch_user_ids=frozenset(), watch_profile_ids=frozenset(),
                        now=lambda: datetime(2026, 10, 28, 3, 20, tzinfo=timezone.utc))
        runner.submit(store, d, max_requests=3)
        got = {x for c in store.open_captures() for x in json.loads(c["request_ids_json"])}
        self.assertIn(reqs[4]["id"], got)
        self.assertEqual(len(got), 3)

    def test_trino_selector_orders_paid_first_in_sql(self):
        seen = []
        sel = runner.trino_open_requests(lambda q: seen.append(q) or "")
        sel(("unverified",), None, 10, frozenset({7, 3}))
        self.assertIn("ORDER BY CASE WHEN cr.userid IN (3,7) THEN 0 ELSE 1 END, cr.createdat LIMIT 10", seen[-1])
        sel(("unverified",), None, 10, None)
        self.assertIn("ORDER BY cr.createdat LIMIT 10", seen[-1])


class PodHelpers(unittest.TestCase):
    """Pure helpers of pod_driver.py (the pod-only parts need the IDP image)."""

    def test_count_collisions(self):
        from types import SimpleNamespace as NS

        from credit_verify.dspverify import pod_driver as pd

        def doc(pk, name, deleted=False, merged=None):
            return NS(pk=pk, name=name, deleted=NS(is_deleted=deleted), merged=NS(merged_to_id=merged))
        docs = [doc("me", "John Smith"), doc("a", "JOHN SMITH"), doc("b", "John Smith Band"),
                doc("c", "Jóhn Smith", deleted=True), doc("d", "John  Smith", merged="x")]
        search = lambda phrase, limit: docs[:limit]  # noqa: E731
        self.assertEqual(pd.count_collisions(search, "me", "John Smith"), 1)
        self.assertEqual(pd.count_collisions(search, "zz", "Jöhn Smith"), 2)
        # QA @c690573: more hits than the cap is UNKNOWN, never a known zero.
        many = [doc(str(i), "John Smith Trio") for i in range(10)]
        self.assertIsNone(pd.count_collisions(lambda p, limit: many[:limit], "me", "John Smith", cap=5))
        self.assertEqual(pd.count_collisions(lambda p, limit: many[:limit], "me", "John Smith", cap=10), 0)

        def boom(p, limit):
            raise RuntimeError("mongo down")
        self.assertIsNone(pd.count_collisions(boom, "me", "John Smith"))
        self.assertIsNone(pd.count_collisions(search, "me", ""))


class FakeAdmin:
    def __init__(self, requests: list[dict]):
        self.requests = {r["id"]: r for r in requests}
        self.paths: list[str] = []

    def get(self, path, params=None):
        self.paths.append(path)
        if path == "/admin/credit-requests":
            assert params.get("profilesIds") or params.get("trackId"), "unscoped admin list read"
            assert "," not in (params.get("profilesIds") or ""), "core answers 500 to several profilesIds"
            st, pids = params.get("status"), set((params.get("profilesIds") or "").split(",")) - {""}
            tid = params.get("trackId")
            items = [r for r in self.requests.values() if r["status"] == st and (not pids or r["profileId"] in pids)
                     and (not tid or r["trackId"] == tid)]
            lim = params.get("limit", 200)
            return {"items": items[(params["page"] - 1) * lim:params["page"] * lim]}
        if path.startswith("/admin/track/"):
            return {"popularity": 20, "artists": [], "label": "Indie Label"}
        if path.startswith("/admin/profile/"):
            return {"name": "Jane Mixer", "creditCount": 12, "type": "person"}
        raise AssertionError(path)


def fake_select(admin):
    def select(statuses, only, limit, paying=None):
        rows = sorted((r for r in admin.requests.values() if r["status"] in statuses
                       and (only is None or r["id"].lower() in only)),
                      key=lambda r: (0 if paying and r["userId"] in paying else 1, r["createdAt"]))
        return [{"id": r["id"], "profile_id": r["profileId"], "track_id": r["trackId"]} for r in rows][:limit]
    return select


class FakePod:
    def __init__(self, idp_hold_ids=(), reading=None, collisions=0):
        self.collisions = collisions
        self.calls: list[tuple[str, list]] = []
        self.idp_hold_ids = None if idp_hold_ids is None else list(idp_hold_ids)
        self.reading = reading or (lambda t: {"spotify": credited(), "tidal": credited("tidal")})

    def __call__(self, mode, items):
        self.calls.append((mode, items))
        if mode == "submit":
            return [{"key": it["key"], "request_id": "cap-" + it["key"], "requested_at": REQ_AT, "targets": 2}
                    for it in items]
        out = []
        for it in items:
            tracks = {f"{t['track_id']}|{t['profile_id']}": {"person_name": "Jane Mixer",
                                                             "name_collisions": self.collisions,
                                                             "recording_facts": {"isrcs": [{"source": "spotify",
                                                                                            "isrc": "USAAA2600001"}],
                                                                                 "label_lines": []},
                                                             "roles": {
                r: {"sources": self.reading(t)} for r in t["roles"]}} for t in it["tracks"]}
            out.append({"key": it["key"], "request_id": it["request_id"], "tracks": tracks,
                        "idp_hold_ids": self.idp_hold_ids})
        return out


def req(i: int, status="unverified", uid=42) -> dict:
    return {"id": f"00000000-0000-0000-0000-00000000000{i}", "status": status, "userId": uid,
            "profileId": "prof-1", "trackId": f"trk-{i}", "credits": ["Mixing"], "createdAt": f"2026-10-0{i}T00:00:00Z",
            "verificationData": {"rule_risk_percent": {}}, "spotifyTrackTitle": f"Song {i}",
            "profile": {"name": "Jane Mixer"}}


class RunnerAndStore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = Store(os.path.join(self.tmp, "dsp.sqlite"))

    def deps(self, admin, pod, gate_decision="allow"):
        return runner.Deps(admin=admin, select=fake_select(admin), capture=pod,
                           gate=lambda uid: account_gate.GateResult(gate_decision, (), {"band": "green"}),
                           deny_user_ids=frozenset(), deny_profile_ids=frozenset(), paying=frozenset({42}),
                           watch_user_ids=frozenset(), watch_profile_ids=frozenset(),
                           now=lambda: datetime(2026, 10, 28, 3, 20, tzinfo=timezone.utc))

    def test_submit_then_verify_logs_shadow_verdicts_and_only_reads_core(self):
        admin = FakeAdmin([req(1), req(2), req(3, status="approved")])
        pod = FakePod()
        d = self.deps(admin, pod)
        st = runner.submit(self.store, d)
        self.assertEqual((st.requests, st.groups), (2, 1))
        # A second submit files nothing new while the capture is open.
        self.assertEqual(runner.submit(self.store, d).requests, 0)
        admin.requests[req(2)["id"]]["status"] = "approved"      # decided elsewhere meanwhile
        st, out = runner.verify(self.store, d)
        self.assertEqual(st.requests, 1)
        self.assertEqual(out[0]["verdict"], rules.APPROVE, out[0]["reason"])
        latest = self.store.latest()
        self.assertEqual(len(latest), 1)
        self.assertEqual(latest[0]["mode"], "shadow")
        self.assertEqual(latest[0]["paid"], 1)
        self.assertEqual(json.loads(latest[0]["approve_roles"]), ["Mixing"])
        self.assertTrue(all(p.startswith("/admin/") for p in admin.paths))
        self.assertFalse(any("conditional-status" in p for p in admin.paths))
        self.assertEqual(self.store.open_captures(), [])           # every reading final -> closed
        self.assertEqual(self.store.summary()["by_verdict"], {"APPROVE": 1})

    def test_gate_hold_never_approves_in_the_runner(self):
        admin = FakeAdmin([req(1)])
        d = self.deps(admin, FakePod(), gate_decision="hold")
        runner.submit(self.store, d)
        _, out = runner.verify(self.store, d)
        self.assertEqual(out[0]["verdict"], rules.WAIT)

    def test_pod_failure_keeps_capture_open(self):
        admin = FakeAdmin([req(1)])
        pod = FakePod()
        d = self.deps(admin, pod)
        runner.submit(self.store, d)

        def broken(mode, items):
            raise RuntimeError("no catalog-admin pod Running")
        st, out = runner.verify(self.store, self.deps(admin, broken))
        self.assertEqual(out, [])
        self.assertTrue(st.errors)
        self.assertEqual(len(self.store.open_captures()), 1)

    def test_admin_failure_after_read_keeps_capture_open(self):
        # QA @274a979: a capture closes only after its verdicts are persisted.
        admin = FakeAdmin([req(1)])
        d = self.deps(admin, FakePod())
        runner.submit(self.store, d)
        real = admin.get

        def flaky(path, params=None):
            if path == "/admin/credit-requests" and params.get("status") == "unverified":
                raise runner.admin_api.AdminError("HTTP 503")
            return real(path, params)
        admin.get = flaky
        st, out = runner.verify(self.store, d)
        self.assertEqual(out, [])
        self.assertTrue(st.errors)
        self.assertEqual(len(self.store.open_captures()), 1)
        admin.get = real
        _, out = runner.verify(self.store, d)
        self.assertEqual([v["verdict"] for v in out], [rules.APPROVE])
        self.assertEqual(self.store.open_captures(), [])

    def test_duplicate_lookup_failure_never_approves(self):
        admin = FakeAdmin([req(1)])
        d = self.deps(admin, FakePod())
        runner.submit(self.store, d)
        real = admin.get

        def flaky(path, params=None):
            if path == "/admin/credit-requests" and params.get("status") == "approved":
                raise runner.admin_api.AdminError("HTTP 503")
            return real(path, params)
        admin.get = flaky
        _, out = runner.verify(self.store, d)
        self.assertEqual(out[0]["verdict"], rules.WAIT)
        self.assertIn("duplicate_unknown", out[0]["reason"])

    def test_duplicate_found_by_runner(self):
        dup = req(1, status="approved")
        dup["id"] = "99999999-9999-9999-9999-999999999999"
        admin = FakeAdmin([req(1), dup])
        d = self.deps(admin, FakePod())
        runner.submit(self.store, d)
        _, out = runner.verify(self.store, d)
        self.assertEqual(out[0]["verdict"], rules.DUPLICATE)

    def test_same_track_two_profiles_keep_their_own_reading(self):
        # QA @dfe29fd: one user, one track, two profiles; only prof-1 is credited by id.
        r1, r2 = req(1), req(2)
        r2["trackId"], r2["profileId"] = r1["trackId"], "prof-2"

        def reading(t):
            if t["profile_id"] == "prof-1":
                return {"spotify": credited(), "tidal": credited("tidal")}
            return {"spotify": not_linked("spotify"), "tidal": not_linked("tidal")}
        admin = FakeAdmin([r1, r2])
        d = self.deps(admin, FakePod(reading=reading))
        runner.submit(self.store, d)
        _, out = runner.verify(self.store, d)
        got = {v["request_id"]: v["verdict"] for v in out}
        self.assertEqual(got, {r1["id"]: rules.APPROVE, r2["id"]: rules.WAIT})

    def test_idp_hold_unknown_or_held_never_approves(self):
        for ids, needle in ((None, "flags_unknown: idp_hold"), (["42"], "flagged_idp_hold")):
            store = Store(os.path.join(self.tmp, f"idp-{needle[:5]}.sqlite"))
            d = self.deps(FakeAdmin([req(1)]), FakePod(idp_hold_ids=ids))
            runner.submit(store, d)
            _, out = runner.verify(store, d)
            self.assertEqual(out[0]["verdict"], rules.WAIT)
            self.assertIn(needle, out[0]["reason"])

    def test_runner_passes_name_collisions_and_unknown_validator(self):
        for pod, mutate, needle in ((FakePod(collisions=None), None, "collisions unknown"),
                                    (FakePod(collisions=2), None, "2 other catalog profiles"),
                                    (FakePod(), "vd", "validator_unknown")):
            r = req(1)
            if mutate == "vd":
                r.pop("verificationData")
            store = Store(os.path.join(self.tmp, f"nc-{needle[:6]}.sqlite"))
            d = self.deps(FakeAdmin([r]), pod)
            runner.submit(store, d)
            _, out = runner.verify(store, d)
            self.assertEqual(out[0]["verdict"], rules.WAIT)
            self.assertIn(needle, out[0]["reason"])

    def test_watchlist_not_read_never_approves(self):
        d = self.deps(FakeAdmin([req(1)]), FakePod())
        d.watch_user_ids = None
        runner.submit(self.store, d)
        _, out = runner.verify(self.store, d)
        self.assertIn("flags_unknown: watchlist", out[0]["reason"])

    def test_oversized_evidence_is_refused_not_truncated(self):
        from credit_verify.dspverify import store as store_mod
        old = store_mod.MAX_JSON
        store_mod.MAX_JSON = 500
        try:
            with self.assertRaises(ValueError):
                runner.verify_packets([packet()], self.store)
        finally:
            store_mod.MAX_JSON = old
        runner.verify_packets([packet()], self.store)
        ev = self.store.latest()[0]["evidence_json"]
        self.assertIn("roles", json.loads(ev))           # complete, parseable JSON

    def test_store_is_append_only_and_shadow_only(self):
        runner.verify_packets([packet()], self.store)
        db = sqlite3.connect(self.store.path)
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("UPDATE dsp_verdicts SET verdict='DECLINE'")
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("DELETE FROM dsp_verdicts")
        cols = [r[1] for r in db.execute("PRAGMA table_info(dsp_verdicts)")]
        row = dict(zip(cols, db.execute("SELECT * FROM dsp_verdicts").fetchone()))
        row.pop("id")
        row["mode"] = "apply"
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute(f"INSERT INTO dsp_verdicts ({','.join(row)}) VALUES ({','.join('?' * len(row))})",
                       list(row.values()))

    def test_cli_verify_packets(self):
        path = os.path.join(self.tmp, "p.jsonl")
        Path(path).write_text("\n".join(json.dumps(p) for p in (packet(), packet(popularity=70))), encoding="utf-8")
        env = {**os.environ, "CREDIT_DSP_VERIFY_STORE": os.path.join(self.tmp, "cli.sqlite")}
        p = subprocess.run([sys.executable, str(CLI), "verify-packets", path], capture_output=True, text=True,
                           env=env, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        got = [json.loads(ln)["verdict"] for ln in p.stdout.splitlines()]
        self.assertEqual(got, [rules.APPROVE, rules.WAIT])

    def test_cli_kill_switch(self):
        ks = os.path.join(self.tmp, "off")
        Path(ks).write_text("", encoding="utf-8")
        env = {**os.environ, "CREDIT_DSP_VERIFY_KILL_SWITCH": ks,
               "CREDIT_DSP_VERIFY_STORE": os.path.join(self.tmp, "k.sqlite")}
        for cmd in ("submit", "verify", "run"):
            p = subprocess.run([sys.executable, str(CLI), cmd], capture_output=True, text=True, env=env, timeout=60)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("kill switch", p.stderr)


from credit_verify.dspverify import anchor  # noqa: E402

NOW = datetime(2026, 10, 28, 4, 0, tzinfo=timezone.utc)


def approve_packet(**kw) -> dict:
    base = {"isrcs": ["USAAA2600001"],
            "recording_facts": {"isrcs": [{"source": "spotify", "isrc": "USAAA2600001"}], "label_lines": []}}
    base.update(kw)
    return packet(**base)


class Anchors(unittest.TestCase):
    def test_dsp_anchor_built_from_the_verifiers_own_evidence(self):
        p = approve_packet()
        v = rules.verify(p).as_dict()
        rec = anchor.build(p, v, ruling_id="l12-tray2", now=NOW)
        self.assertEqual((rec["schema"], rec["kind"], rec["roles"], rec["both_read"]),
                         ("dsp-anchor/1", "dsp_anchor", ["Mixing"], True))
        self.assertEqual(rec["isrcs"], ["USAAA2600001"])
        self.assertEqual(rec["metadata"], {"ruling_id": "l12-tray2"})          # metadata only
        for b in rec["role_evidence"]["Mixing"]["sources"]:
            self.assertEqual(b["state"], "CAPTURED")
            self.assertTrue(any(h["is_claimant_linked_id"] for h in b["role_holders"]))
        self.assertEqual(rec["record_sha256"], anchor.record_sha256(rec))
        self.assertEqual(rec["capture_request_id"], "cap-1")

    def test_refusals(self):
        p = approve_packet()
        v = rules.verify(p).as_dict()
        wait = approve_packet(sources={"Mixing": {"spotify": credited(), "tidal": NO_REC}})
        cases = [
            (wait, rules.verify(wait).as_dict(), "not APPROVE"),
            (wait, v, "not APPROVE"),                                  # a stored APPROVE never beats its packet
            (p, {**v, "verdict": "WAIT"}, "not APPROVE"),
            (p, {**v, "approve_roles": ["Mixing", "Producer"]}, "does not match"),
            (p, {**v, "reason_class": "something_else"}, "does not match"),
            (approve_packet(isrcs=[]), v, "no ISRC"),
        ]
        for pk, vd, needle in cases:
            with self.assertRaises(anchor.AnchorRefused) as cm:
                anchor.build(pk, vd, now=NOW)
            self.assertIn(needle, str(cm.exception))
        with self.assertRaises(anchor.AnchorRefused) as cm:           # stale capture
            anchor.build(p, v, now=datetime(2026, 10, 30, tzinfo=timezone.utc))
        self.assertIn("older than", str(cm.exception))

    def org_packet(self, **kw):
        lines = [{"source": "spotify", "release_id": "spotify:r1", "kind": "copyright_p",
                  "string": "(P) 2024 Controlled Substance, LLC"}]
        base = dict(roles=("Record Label",), sources={}, profile_type="organization",
                    profile_name="Substance Controlled LLC", org_claim_processed=True,
                    label_strings=[{"kind": "core_label", "string": "Controlled Substance LLC"}],
                    recording_facts={"isrcs": [{"isrc": "USAAA2600001"}], "label_lines": lines,
                                     "read_at": "2026-10-28T03:20:00+00:00", "label_lines_fresh": False})
        base.update(kw)
        return approve_packet(**base)

    def test_label_line_anchor(self):
        p = self.org_packet()
        v = rules.verify(p).as_dict()
        self.assertEqual(v["reason_class"], "org_label_anchor")
        rec = anchor.build(p, v, ruling_id="org-label-anchor", now=NOW)
        self.assertEqual((rec["kind"], rec["roles"], rec["label_lines_fresh"]), ("dsp_label_line", ["Record Label"], False))
        self.assertEqual(rec["label_lines"][0]["kind"], "copyright_p")
        for stored in ({**v, "verdict": "DECLINE"}, {**v, "verdict": "APPROVE"}, {**v, "approve_roles": ["x"]}):
            with self.assertRaises(anchor.AnchorRefused) as cm:   # QA @b6159bd: stored verdict drift
                anchor.build(p, stored, now=NOW)
            self.assertIn("does not match", str(cm.exception))
        for kw, needle in ((dict(org_claim_processed=None), "processed claim"),
                           (dict(recording_facts={"isrcs": [{"isrc": "X"}], "label_lines": []}), "not on the catalog"),
                           (dict(gate={"decision": "hold"}), "guards block")):
            p2 = self.org_packet(**kw)
            with self.assertRaises(anchor.AnchorRefused) as cm:
                anchor.build(p2, rules.verify(p2).as_dict(), now=NOW)
            self.assertIn(needle, str(cm.exception))


class TrayAnchors(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = Store(os.path.join(self.tmp, "dsp.sqlite"))

    def test_tray_rows_get_records_only_where_the_verifier_approves(self):
        good, bad = req(1), req(2)
        admin = FakeAdmin([good, bad])

        def reading(t):
            if t["track_id"] == good["trackId"]:
                return {"spotify": credited(), "tidal": credited("tidal")}
            return {"spotify": credited(), "tidal": NO_REC}
        d = runner.Deps(admin=admin, select=fake_select(admin), capture=FakePod(reading=reading),
                        gate=lambda uid: account_gate.GateResult("allow", (), {"band": "green"}),
                        paying=frozenset(), watch_user_ids=frozenset(), watch_profile_ids=frozenset(),
                        now=lambda: datetime(2026, 10, 28, 3, 20, tzinfo=timezone.utc))
        tray = {"tray": "t2", "action": "approve", "rows": [
            {"request_id": good["id"], "ruling_id": "l12-t2", "roles": ["Mixing"]},
            {"request_id": bad["id"], "ruling_id": "l12-t2"},
            {"request_id": "00000000-0000-0000-0000-0000000000ff", "ruling_id": "l12-t2"}]}
        st = runner.submit(self.store, d, only={r["request_id"] for r in runner.tray_rows(tray)})
        self.assertEqual(st.requests, 2)
        runner.verify(self.store, d)
        _, out = runner.build_anchors(self.store, tray, now=NOW)
        got = {o["request_id"]: o["outcome"] for o in out}
        self.assertEqual(got, {good["id"]: "built", bad["id"]: "refused", "00000000-0000-0000-0000-0000000000ff": "refused"})
        rows = self.store.anchors()
        self.assertEqual(len(rows), 3)
        built = json.loads(next(r for r in rows if r["outcome"] == "built")["record_json"])
        self.assertEqual(built["metadata"]["ruling_id"], "l12-t2")
        db = sqlite3.connect(self.store.path)
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("UPDATE dsp_anchors SET outcome='written'")
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("DELETE FROM dsp_anchors")

    def test_supplied_packets_never_anchor(self):
        # QA @3b7f0b4: a packet logged through verify-packets --log is not this job's capture.
        p = approve_packet(request_id="11111111-1111-1111-1111-111111111111")
        runner.verify_packets([p], self.store)
        self.assertEqual(self.store.latest_for(p["request_id"])["verdict"], rules.APPROVE)
        tray = {"action": "approve", "rows": [{"request_id": p["request_id"], "ruling_id": "x"}]}
        _, out = runner.build_anchors(self.store, tray, now=NOW)
        self.assertEqual(out[0]["outcome"], "refused")
        self.assertIn("never anchor", out[0]["reason"])
        # Same through the CLI path that logs packets.
        path = os.path.join(self.tmp, "p.jsonl")
        Path(path).write_text(json.dumps(p), encoding="utf-8")
        tpath = os.path.join(self.tmp, "t.json")
        Path(tpath).write_text(json.dumps(tray), encoding="utf-8")
        env = {**os.environ, "CREDIT_DSP_VERIFY_STORE": os.path.join(self.tmp, "cli.sqlite"),
               "CREDIT_DSP_VERIFY_KILL_SWITCH": os.path.join(self.tmp, "nope"),
               "CREDIT_VERIFY_KILL_SWITCH": os.path.join(self.tmp, "nope2")}
        subprocess.run([sys.executable, str(CLI), "verify-packets", path, "--log"], env=env, check=True,
                       capture_output=True, timeout=60)
        r = subprocess.run([sys.executable, str(CLI), "anchors", "--tray", tpath], env=env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(json.loads(r.stdout.splitlines()[0])["outcome"], "refused", r.stderr)

    def test_tray_reads_user_verification_needed_rows(self):
        # A junk/approve tray row is often UVN: tray mode reads every open status; the cron does not.
        r = req(1, status="user_verification_needed")
        fa = FakeAdmin([r])
        d = runner.Deps(admin=fa, select=fake_select(fa), capture=FakePod(),
                        gate=lambda uid: account_gate.GateResult("allow", (), {"band": "green"}),
                        paying=frozenset(), watch_user_ids=frozenset(), watch_profile_ids=frozenset(),
                        now=lambda: datetime(2026, 10, 28, 3, 20, tzinfo=timezone.utc))
        self.assertEqual(runner.submit(self.store, d).requests, 0)
        self.assertEqual(runner.submit(self.store, d, only={r["id"]}).requests, 1)
        _, out = runner.verify(self.store, d)
        self.assertEqual([v["verdict"] for v in out], [rules.APPROVE])

    def test_tray_reads_approved_rows_cron_does_not(self):
        # Fable validator-wrong-16: were already-approved rows anchored? Shadow evidence only.
        r = req(1, status="approved")
        fa = FakeAdmin([r])
        d = runner.Deps(admin=fa, select=fake_select(fa), capture=FakePod(),
                        gate=lambda uid: account_gate.GateResult("allow", (), {"band": "green"}),
                        paying=frozenset(), watch_user_ids=frozenset(), watch_profile_ids=frozenset(),
                        now=lambda: datetime(2026, 10, 28, 3, 20, tzinfo=timezone.utc))
        self.assertEqual(runner.submit(self.store, d).requests, 0)
        self.assertEqual(runner.submit(self.store, d, only={r["id"]}).requests, 1)
        _, out = runner.verify(self.store, d)
        self.assertEqual(len(out), 1)

    def test_reject_tray_builds_nothing(self):
        self.assertEqual(runner.tray_rows({"action": "reject", "rows": [{"request_id": "x"}]}), [])

    def test_cli_write_is_refused(self):
        path = os.path.join(self.tmp, "tray.json")
        Path(path).write_text(json.dumps({"action": "approve", "rows": []}), encoding="utf-8")
        env = {**os.environ, "CREDIT_DSP_VERIFY_STORE": os.path.join(self.tmp, "w.sqlite"),
               "CREDIT_DSP_VERIFY_KILL_SWITCH": os.path.join(self.tmp, "nope")}
        p = subprocess.run([sys.executable, str(CLI), "anchors", "--tray", path, "--write"], capture_output=True,
                           text=True, env=env, timeout=60)
        self.assertEqual(p.returncode, 2)
        self.assertIn("no server-side anchor endpoint", p.stderr)



class PodDriverSource(unittest.TestCase):
    def test_claimant_holder_carries_the_request_profile_id(self):
        # core #11010 claimantMatch: a linked holder matches only when its profile_id is the request's profileId.
        src = (Path(__file__).resolve().parents[1] / "credit_verify/dspverify/pod_driver.py").read_text()
        self.assertIn('t["profile_id"] if mine_id else catalog_of(p[0])', src)

if __name__ == "__main__":
    unittest.main()
