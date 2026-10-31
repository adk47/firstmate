#!/usr/bin/env python3
"""Tests for the profile-link proposals (scripts/credit_verify/dspverify/link_proposal.py), SHADOW.

Synthetic data only: a real V9 store (dspverify.store.Store) is filled through the verifier's own
rules.verify + Store.add_verdict, then read READ-ONLY by the proposal rules. No network, no Trino.

    python3 scripts/tests/test_link_proposal.py
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import credit_test_env  # noqa: E402,F401  (keeps test logs out of /var/lib)

from credit_verify.dspverify import link_proposal as lp  # noqa: E402
from credit_verify.dspverify import rules  # noqa: E402
from credit_verify.dspverify.store import Store  # noqa: E402

REQ_AT = "2026-10-30T03:00:00+00:00"
FRESH = "2026-10-30T03:10:00+00:00"
STALE = "2026-10-30T02:50:00+00:00"
CLI = Path(__file__).resolve().parents[1] / "credit-dsp-verify.py"
PID = "37b3c835-0000-4000-8000-000000000001"
OTHER = "aaaaaaaa-0000-4000-8000-000000000002"
SP, TI = "spotify:4MmIXgChI3XONkstE6LmmY", "tidal:9001"


def rd(src: str, cid: str | None = None, *, name="Marlon DS", holder=None, not_linked=True, by_id=False,
       at=FRESH, state="CAPTURED", extra=()) -> dict:
    """One reading. cid None = the claimant's name is not credited under an id on this DSP."""
    fam = [[n, "Producer", False, i, h] for n, i, h in extra]
    if by_id:
        fam.append([name, "Producer", True, f"{src}:linked", PID])
    elif cid:
        fam.append([name, "Producer", False, cid, holder])
    return {"state": state, "helper_verdict": "UNKNOWN" if not_linked else "NOT_CREDITED",
            "helper_reason": f"person_not_linked_on_{src}" if not_linked else "person_absent_from_complete_snapshot",
            "credited_in_family": fam, "credited_total": len(fam), "unresolved_in_family": [],
            "claimant_name_match": bool(cid), "complete_snapshot": True, "captured_at": at,
            "capture_ids": [f"{src}-c1"]}


def pkt(n: int, sp=None, ti=None, *, roles=("Producer",), title=None, isrcs=None, **kw) -> dict:
    sp = sp if sp is not None else rd("spotify", SP)
    ti = ti if ti is not None else rd("tidal", TI)
    p = {"request_id": f"req-{n:04d}", "user_id": 42, "profile_id": PID, "profile_name": "Marlon DS",
         "profile_type": "person", "track_id": f"trk-{n}", "track_title": title or f"Song {n}",
         "isrcs": isrcs if isrcs is not None else [f"USAAA26{n:05d}"], "roles": list(roles),
         "popularity": 20, "artist_popularity": 30, "artists_known": True, "profile_credit_count": 12,
         "verification_data": {"rule_risk_percent": {}, "total_risk_percent": 10},
         "capture": {"request_id": f"cap-{n}", "requested_at": REQ_AT, "read_at": FRESH, "person_name": "Marlon DS",
                     "roles": {r: {"sources": {"spotify": sp, "tidal": ti}} for r in roles}},
         "gate": {"decision": "allow", "band": "green", "reasons": []},
         "flags": {"watchlist": False, "deny_user": False, "deny_profile": False, "idp_hold": False},
         "duplicate_of": None, "duplicate_unknown": False, "name_collisions": 0}
    p.update(kw)
    return p


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="link-proposal-test-")
        self.store_path = os.path.join(self.tmp, "dsp-verify.sqlite")
        self.ledger = os.path.join(self.tmp, "ledger.sqlite3")
        self.store = Store(self.store_path)
        self.n_run = 0

    def tearDown(self):
        self.store.db.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def put(self, *packets, kind="verify", register_capture=True):
        """Log packets the way a V9 verify run does (own capture filed in dsp_captures)."""
        self.n_run += 1
        run = f"{kind}-{self.n_run}"
        self.store.start_run(run, kind)
        for p in packets:
            if register_capture:
                self.store.add_capture(run, f"{p['user_id']}#1", p["user_id"], [p["request_id"]],
                                       [{"track_id": p["track_id"], "profile_id": p["profile_id"]}],
                                       {"request_id": p["capture"]["request_id"], "requested_at": REQ_AT})
            v = rules.verify(p).as_dict()
            self.store.add_verdict(run, v, p, True)

    def outcomes(self, claim=None):
        db = lp.open_ro(self.store_path)
        try:
            return lp.decide_all(lp.own_captured_verdicts(db), claim)
        finally:
            db.close()

    def one(self, claim=None) -> lp.Outcome:
        out = self.outcomes(claim)
        self.assertEqual(len(out), 1, out)
        return out[0]

    def rows(self):
        if not os.path.exists(self.ledger):
            return []
        db = sqlite3.connect(self.ledger)
        db.row_factory = sqlite3.Row
        try:
            return [dict(r) for r in db.execute("SELECT * FROM link_proposals ORDER BY id")]
        finally:
            db.close()


class Proposes(Fixture):
    def test_fixture_is_the_v9_needs_profile_link_shape(self):
        v = rules.verify(pkt(1))
        self.assertEqual((v.verdict, v.reason_class, v.need), ("WAIT", "needs_profile_link", "link_profile"))

    def test_two_independent_agreeing_tracks_propose_both_dsps(self):
        self.put(pkt(1), pkt(2))
        o = self.one()
        self.assertEqual((o.result, o.reason, o.confidence), ("proposal", "two_tracks", 0.9))
        self.assertEqual(sorted((p["dsp"], p["contributor_id"], p["partner"]) for p in o.proposals),
                         [("spotify", SP, TI), ("tidal", TI, SP)])
        c = lp.run(self.store_path, self.ledger)
        self.assertEqual(c["proposal_rows"], 2)
        rows = self.rows()
        self.assertEqual({r["mode"] for r in rows}, {"shadow"})
        self.assertEqual({r["kind"] for r in rows}, {"link_proposal"})
        self.assertEqual({r["rule_version"] for r in rows}, {lp.RULE_VERSION})
        ev = json.loads(rows[0]["evidence_json"])
        self.assertEqual(sorted(t["track_id"] for t in ev["tracks"]), ["trk-1", "trk-2"])
        self.assertEqual(ev["tracks"][0]["spotify"]["contributor_id"], SP)
        self.assertEqual(json.loads(rows[0]["request_ids"]), ["req-0001", "req-0002"])

    def test_three_tracks_raise_confidence(self):
        self.put(pkt(1), pkt(2), pkt(3))
        self.assertEqual(self.one().confidence, 0.95)

    def test_one_track_needs_a_processed_claim_of_the_same_account(self):
        self.put(pkt(1, roles=("Producer", "Executive Producer")))
        self.assertEqual((self.one().result, self.one().reason), ("refused", "one_track"))
        seen = []

        def claim(uid, pid):
            seen.append((uid, pid))
            return True
        o = self.one(claim)
        self.assertEqual((o.result, o.reason, o.confidence), ("proposal", "track_plus_claim", 0.85))
        self.assertEqual(seen[-1], (42, PID))
        for answer in (None, False, 1, "yes"):        # unknown / no claim / not an explicit True
            self.assertEqual(self.one(lambda u, p, a=answer: a).reason, "one_track", answer)

    def test_already_linked_dsp_counts_as_agreement_and_only_the_other_is_proposed(self):
        self.put(pkt(1, sp=rd("spotify", by_id=True, not_linked=False)),
                 pkt(2, sp=rd("spotify", by_id=True, not_linked=False)))
        o = self.one()
        self.assertEqual(o.result, "proposal")
        self.assertEqual([(p["dsp"], p["contributor_id"], p["partner"]) for p in o.proposals], [("tidal", TI, None)])

    def test_catalog_already_holds_the_id_on_the_presented_profile_is_linked_not_a_proposal(self):
        self.put(pkt(1, sp=rd("spotify", SP, holder=PID)), pkt(2, sp=rd("spotify", SP, holder=PID)))
        o = self.one()
        self.assertEqual([p["dsp"] for p in o.proposals], ["tidal"])

    def test_approve_and_other_verdicts_are_not_link_questions(self):
        out = lp.decide_all([{"verdict": v, "id": 1, "request_id": "x", "packet": pkt(1)}
                             for v in ("APPROVE", "DECLINE", "DUPLICATE")])
        self.assertEqual(out, [])


class Evidence(Fixture):
    def test_two_runs_never_add_up_to_same_run_agreement(self):
        # QA @469c0eb0: run 1 credits only Spotify, run 2 only Tidal, on each of two tracks (two requests per
        # track). No capture shows both DSPs, so there is no agreeing track.
        def other(n, **kw):
            p = pkt(n, **kw)
            p["request_id"], p["capture"]["request_id"] = f"req-b{n}", f"cap-b{n}"
            return p
        self.put(pkt(1, ti=rd("tidal")), pkt(2, ti=rd("tidal")))
        self.put(other(1, sp=rd("spotify")), other(2, sp=rd("spotify")))
        o = self.one()
        self.assertEqual((o.result, o.reason), ("refused", "single_dsp"))
        self.assertEqual(len(o.evidence), 4)

    def test_two_runs_that_each_agree_still_count_once_per_track(self):
        def other(n, **kw):
            p = pkt(n, **kw)
            p["request_id"], p["capture"]["request_id"] = f"req-b{n}", f"cap-b{n}"
            return p
        self.put(pkt(1), other(1))          # one track, two agreeing captures: still one track
        self.assertEqual(self.one().reason, "one_track")

    def test_same_isrc_under_two_track_ids_is_one_track(self):
        self.put(pkt(1, isrcs=["USX"]), pkt(2, isrcs=["USX", "USY"]))
        self.assertEqual(self.one().reason, "one_track")

    def test_versions_of_one_song_are_one_track(self):
        self.put(pkt(1, title="Lights"), pkt(2, title="Lights (Remix)"))
        self.assertEqual(self.one().reason, "one_track")
        self.assertEqual(lp.base_title("Lights - Live at X"), "lights")

    def test_a_valid_independent_pair_is_found_even_when_the_first_track_blocks_both(self):
        # QA @fd852612: track 1 {A,B} 'Alpha', track 2 {A} 'Beta', track 3 {C} 'Alpha'. Track 1 shares an ISRC
        # with 2 and a title with 3; 2 and 3 are independent and must qualify.
        self.put(pkt(1, isrcs=["A", "B"], title="Alpha"), pkt(2, isrcs=["A"], title="Beta"),
                 pkt(3, isrcs=["C"], title="Alpha"))
        o = self.one()
        self.assertEqual((o.result, o.reason, o.confidence), ("proposal", "two_tracks", 0.9))
        self.assertEqual(sorted(t["track_id"] for t in o.evidence), ["trk-2", "trk-3"])

    def test_the_largest_independent_set_sets_the_confidence(self):
        self.put(pkt(1, isrcs=["A", "B"], title="Alpha"), pkt(2, isrcs=["A"], title="Beta"),
                 pkt(3, isrcs=["C"], title="Alpha"), pkt(4, isrcs=["D"], title="Gamma"))
        o = self.one()
        self.assertEqual((o.reason, o.confidence), ("two_tracks", 0.95))
        self.assertEqual(sorted(t["track_id"] for t in o.evidence), ["trk-2", "trk-3", "trk-4"])

    def test_independent_set_against_a_brute_force_oracle(self):
        # Any independent pair exists <=> at least 2 come back, and what comes back is pairwise independent.
        import itertools
        import random
        rng = random.Random(1542)

        def indep(a, b):
            return a.track_id != b.track_id and not (a.isrcs & b.isrcs) and lp.base_title(a.title) != lp.base_title(b.title)
        for _ in range(2000):
            ts = [lp.Track(f"t{rng.randint(0, 4)}", rng.choice(["a", "b", "c", "d (Remix)"]),
                           frozenset(rng.sample("ABCDEF", rng.randint(0, 2))), verdict_ids={i})
                  for i in range(rng.randint(1, 7))]
            pool = [t for t in ts if t.isrcs]
            pair = any(indep(a, b) for a, b in itertools.combinations(pool, 2))
            got = lp.independent_tracks(ts)
            self.assertEqual(pair, len(got) >= 2, ts)
            self.assertTrue(all(indep(a, b) for a, b in itertools.combinations(got, 2)), got)

    def test_a_track_without_catalog_isrcs_is_never_evidence(self):
        self.put(pkt(1), pkt(2, isrcs=[]))
        self.assertEqual(self.one().reason, "one_track")

    def test_one_dsp_only_never_proposes(self):
        self.put(pkt(1, ti=rd("tidal")), pkt(2, ti=rd("tidal")))
        self.assertEqual((self.one().result, self.one().reason), ("refused", "single_dsp"))

    def test_both_dsps_must_agree_on_the_same_track(self):
        self.put(pkt(1, ti=rd("tidal")), pkt(2, sp=rd("spotify")), pkt(3, ti=rd("tidal")))
        self.assertEqual(self.one().reason, "single_dsp")

    def test_stale_capture_never_counts(self):
        self.put(pkt(1, sp=rd("spotify", SP, at=STALE)), pkt(2, sp=rd("spotify", SP, at=REQ_AT)))
        self.assertEqual(self.one().reason, "single_dsp")

    def test_not_captured_states_never_count(self):
        for st in ("WAITING", "CAPTURE_ERROR", "NO_FRESH_CAPTURE", "", None):
            self.assertEqual(lp.observe("spotify", rd("spotify", SP, state=st), lp._ts(REQ_AT), "marlon ds",
                                        PID).status, lp.NONE, st)

    def test_name_is_never_enough_an_id_is_required(self):
        r = rd("spotify", SP)
        r["credited_in_family"] = [["Marlon DS", "Producer", False]]          # name only, no raw id
        self.assertEqual(lp.observe("spotify", r, lp._ts(REQ_AT), "marlon ds", PID).status, lp.NONE)
        r["credited_in_family"] = [["Marlon DS", "Producer", False, "tidal:123456789", None]]   # wrong namespace
        self.assertEqual(lp.observe("spotify", r, lp._ts(REQ_AT), "marlon ds", PID).status, lp.NONE)
        r["credited_in_family"] = [["Marlon D.S. Jr", "Producer", False, SP, None]]    # not the exact name
        self.assertEqual(lp.observe("spotify", r, lp._ts(REQ_AT), "marlon ds", PID).status, lp.NONE)

    def test_folded_name_matches_accents_and_punctuation(self):
        r = rd("spotify", SP, name="Marlón-DS")
        self.assertEqual(lp.observe("spotify", r, lp._ts(REQ_AT), "marlon ds", PID).status, lp.CANDIDATE)


class Dedupe(Fixture):
    def test_id_held_by_another_profile_is_a_merge_handoff_with_no_row(self):
        self.put(pkt(1, sp=rd("spotify", SP, holder=OTHER)), pkt(2))
        o = self.one()
        self.assertEqual(o.result, "handoff_merge")
        c = lp.run(self.store_path, self.ledger)
        self.assertEqual((c["proposal_rows"], c["tray_rows"]), (0, 0))
        self.assertEqual(c["handoff_merge"], [{"profile_id": PID, "request_ids": ["req-0001", "req-0002"],
                                               "held": [[SP, OTHER]]}])
        self.assertEqual(self.rows(), [])

    def test_dedupe_runs_before_the_name_and_guard_refusals(self):
        self.put(pkt(1, sp=rd("spotify", SP, holder=OTHER), name_collisions=3,
                     flags={"watchlist": True, "deny_user": False, "deny_profile": False, "idp_hold": False}))
        self.assertEqual(self.one().result, "handoff_merge")


class Tray(Fixture):
    def test_link_mismatch_is_a_tray_row_never_a_relink(self):
        self.put(pkt(1, sp=rd("spotify", SP, not_linked=False)), pkt(2))
        o = self.one()
        self.assertEqual((o.result, o.reason), ("tray", "link_mismatch"))
        lp.run(self.store_path, self.ledger)
        rows = self.rows()
        self.assertEqual([(r["kind"], r["reason"], r["contributor_id"]) for r in rows],
                         [("link_tray", "link_mismatch", "")])

    def test_mismatch_wins_over_held(self):
        self.put(pkt(1, sp=rd("spotify", SP, not_linked=False, holder=OTHER)))
        o = self.one()
        self.assertEqual((o.result, o.reason, o.detail["held_by"]), ("tray", "link_mismatch", [OTHER]))

    def test_two_ids_under_the_exact_name_in_one_reading(self):
        self.put(pkt(1, sp=rd("spotify", SP, extra=[("Marlon DS", "spotify:other", None)])), pkt(2))
        self.assertEqual((self.one().result, self.one().reason), ("tray", "id_conflict"))

    def test_a_linked_credit_never_masks_a_second_exact_name_id(self):
        # QA @469c0eb0: the linked Spotify id plus another Spotify id under the exact name is a conflict, not
        # "linked"; it must never let the Tidal candidates through as a proposal.
        sp = rd("spotify", by_id=True, not_linked=False, extra=[("Marlon DS", "spotify:second", None)])
        self.assertEqual(lp.observe("spotify", sp, lp._ts(REQ_AT), "marlon ds", PID).status, lp.AMBIGUOUS)
        self.put(pkt(1, sp=sp), pkt(2, sp=sp))
        o = self.one()
        self.assertEqual((o.result, o.reason), ("tray", "id_conflict"))

    def test_the_linked_id_listed_again_under_the_exact_name_is_still_linked(self):
        sp = rd("spotify", by_id=True, not_linked=False, extra=[("Marlon DS", "spotify:linked", PID)])
        self.assertEqual(lp.observe("spotify", sp, lp._ts(REQ_AT), "marlon ds", PID).status, lp.LINKED)
        other = rd("spotify", by_id=True, not_linked=False, extra=[("Someone Else", "spotify:x", None)])
        self.assertEqual(lp.observe("spotify", other, lp._ts(REQ_AT), "marlon ds", PID).status, lp.LINKED)

    def test_linked_on_one_role_and_a_candidate_on_another_is_a_conflict(self):
        # QA @03870cdb: within one capture, role A credits the linked Spotify id and role B credits a different,
        # unheld exact-name Spotify id. The profile is linked there: never a proposal for either DSP.
        def two_roles(n):
            p = pkt(n, roles=("Producer", "Mixing"))
            p["capture"]["roles"]["Producer"]["sources"]["spotify"] = rd("spotify", by_id=True, not_linked=False)
            return p
        self.put(two_roles(1), two_roles(2))
        o = self.one()
        self.assertEqual((o.result, o.reason, o.detail["linked_and_candidate"]), ("tray", "id_conflict", ["spotify"]))

    def test_linked_in_one_verdict_and_a_candidate_in_another_is_a_conflict(self):
        self.put(pkt(1, sp=rd("spotify", by_id=True, not_linked=False)), pkt(2), pkt(3))
        self.assertEqual((self.one().result, self.one().reason), ("tray", "id_conflict"))

    def test_different_ids_across_tracks(self):
        self.put(pkt(1), pkt(2, sp=rd("spotify", "spotify:different")))
        self.assertEqual((self.one().result, self.one().reason), ("tray", "id_conflict"))

    def test_tidal_countries_disagreeing(self):
        ti = {"countries": {"US": rd("tidal", TI), "GB": rd("tidal", "tidal:777")}}
        self.put(pkt(1, ti=ti), pkt(2))
        self.assertEqual(self.one().reason, "id_conflict")

    def test_tidal_countries_disagreeing_the_same_way_on_every_track(self):
        ti = {"countries": {"US": rd("tidal", TI), "GB": rd("tidal", "tidal:777")}}
        self.put(pkt(1, ti=ti), pkt(2, ti=ti))
        self.assertEqual(self.one().reason, "id_conflict")

    def test_tidal_countries_agreeing_or_silent(self):
        ti = {"countries": {"US": rd("tidal", TI), "GB": rd("tidal", TI), "DE": rd("tidal", TI, state="WAITING")}}
        self.put(pkt(1, ti=ti), pkt(2))
        self.assertEqual(self.one().result, "proposal")

    def test_tray_rows_are_written_once(self):
        self.put(pkt(1, sp=rd("spotify", SP, not_linked=False)))
        lp.run(self.store_path, self.ledger)
        c = lp.run(self.store_path, self.ledger)
        self.assertEqual((c["tray_rows"], c["already_recorded"]), (0, 1))
        self.assertEqual(len(self.rows()), 1)


class Refuses(Fixture):
    def check(self, reason, *packets):
        self.put(*packets)
        o = self.one()
        self.assertEqual((o.result, o.reason), ("refused", reason), o.detail)
        lp.run(self.store_path, self.ledger)
        self.assertEqual(self.rows(), [])

    def test_common_name_collisions(self):
        self.check("common_name", pkt(1, name_collisions=1), pkt(2))

    def test_unknown_collisions_are_common(self):
        self.check("common_name", pkt(1, name_collisions=None), pkt(2))

    def test_one_token_name(self):
        one = {"profile_name": "Marlon", "sp": rd("spotify", SP, name="Marlon"), "ti": rd("tidal", TI, name="Marlon")}
        a, b = pkt(1, **one), pkt(2, **one)
        for p in (a, b):
            p["capture"]["person_name"] = "Marlon"
        self.check("common_name", a, b)

    def test_capture_matched_another_name(self):
        p = pkt(1)
        p["capture"]["person_name"] = "Marlon Davis Smith"
        self.check("common_name", p, pkt(2))

    def test_big_track(self):
        self.check("big_name", pkt(1, popularity=60), pkt(2))

    def test_unknown_popularity_is_big(self):
        self.check("big_name", pkt(1, popularity=None), pkt(2))

    def test_big_artist(self):
        self.check("big_name", pkt(1), pkt(2, artist_popularity=60))

    def test_unknown_artist_popularity_is_big(self):
        self.check("big_name", pkt(1, artist_popularity=None, artists_known=False), pkt(2))

    def test_missing_artist_popularity_is_big_even_when_artists_are_known(self):
        # QA @03870cdb: V9 reads artists_known + None as "no linked artist"; a link refuses it.
        self.check("big_name", pkt(1, artist_popularity=None, artists_known=True), pkt(2))

    def test_big_profile(self):
        self.check("big_name", pkt(1, profile_credit_count=200), pkt(2, profile_credit_count=200))

    def test_watchlisted(self):
        f = {"watchlist": True, "deny_user": False, "deny_profile": False, "idp_hold": False}
        self.check("guard", pkt(1, flags=f), pkt(2))

    def test_unknown_flag(self):
        f = {"watchlist": False, "deny_user": None, "deny_profile": False, "idp_hold": False}
        self.check("guard", pkt(1), pkt(2, flags=f))

    def test_gate_hold(self):
        self.check("guard", pkt(1, gate={"decision": "hold", "band": "amber", "reasons": ["x"]}), pkt(2))

    def test_red_band(self):
        self.check("guard", pkt(1, gate={"decision": "allow", "band": "red", "reasons": []}), pkt(2))

    def test_two_accounts_present_the_profile(self):
        self.check("multiple_accounts", pkt(1), pkt(2, user_id=43))

    def test_not_a_person(self):
        self.check("not_person", pkt(1, profile_type="organization"), pkt(2))

    def test_nothing_credited_under_an_id(self):
        self.check("no_candidate", pkt(1, sp=rd("spotify"), ti=rd("tidal")))


class StoreContract(Fixture):
    def test_supplied_packet_verdicts_are_never_read(self):
        self.put(pkt(1), pkt(2), kind="packets", register_capture=False)
        self.assertEqual(self.outcomes(), [])

    def test_a_later_supplied_packet_verdict_never_replaces_the_own_capture_verdict(self):
        self.put(pkt(1), pkt(2))
        self.put(pkt(1, popularity=70), pkt(2, popularity=70), kind="packets")
        self.assertEqual(self.one().result, "proposal")

    def test_a_verify_verdict_whose_capture_this_store_did_not_file_is_not_read(self):
        self.put(pkt(1), pkt(2), register_capture=False)
        self.assertEqual(self.outcomes(), [])

    def test_only_the_latest_own_verdict_per_request_stands(self):
        self.put(pkt(1), pkt(2))
        self.put(pkt(1, popularity=70))          # re-verified: now big
        self.assertEqual(self.one().reason, "big_name")

    def test_the_v9_store_is_opened_read_only_and_never_changed(self):
        self.put(pkt(1), pkt(2))
        before = Path(self.store_path).read_bytes()
        lp.run(self.store_path, self.ledger)
        self.assertEqual(Path(self.store_path).read_bytes(), before)
        db = lp.open_ro(self.store_path)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("INSERT INTO dsp_runs (run_id, kind, started_at, version) VALUES ('x','verify','t','dsp-1')")
        db.close()

    def test_a_missing_store_is_an_error_never_no_candidates(self):
        with self.assertRaises(FileNotFoundError):
            lp.run(os.path.join(self.tmp, "nope.sqlite"), self.ledger)

    def test_the_ledger_is_append_only_and_shadow_only(self):
        self.put(pkt(1), pkt(2))
        lp.run(self.store_path, self.ledger)
        db = sqlite3.connect(self.ledger)
        for sql in ("UPDATE link_proposals SET contributor_id='x'", "DELETE FROM link_proposals"):
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute(sql)
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("INSERT INTO link_proposals (run_id, decided_at, kind, mode, rule_version, dsp_version,"
                       " profile_id, reason, request_ids, verdict_ids, evidence_json, evidence_sha256)"
                       " VALUES ('r','t','link_proposal','apply','link-1','dsp-1','p','x','[]','[]','{}','s')")
        db.close()

    def test_hourly_reruns_record_each_proposal_once(self):
        self.put(pkt(1), pkt(2))
        lp.run(self.store_path, self.ledger)
        c = lp.run(self.store_path, self.ledger)
        self.assertEqual((c["proposal_rows"], c["already_recorded"]), (0, 2))
        self.assertEqual(len(self.rows()), 2)

    def test_dry_run_writes_nothing(self):
        self.put(pkt(1), pkt(2))
        c = lp.run(self.store_path, self.ledger, dry_run=True)
        self.assertEqual(c["by_result"], {"proposal": 1})
        self.assertFalse(os.path.exists(self.ledger))

    def test_the_decider_tables_are_untouched(self):
        # The proposals sit beside the decider's `decisions`, never in it: decide.py recently_decided and
        # every latest-decision-per-request reader would otherwise read a link proposal as a credit decision.
        from credit_review import decide
        db = sqlite3.connect(self.ledger)
        decide.ensure_schema(db)
        db.close()
        self.put(pkt(1), pkt(2))
        lp.run(self.store_path, self.ledger)
        db = sqlite3.connect(self.ledger)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM decisions").fetchone()[0], 0)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM decision_outcomes").fetchone()[0], 0)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM link_proposals").fetchone()[0], 2)
        db.close()


class Labels(Fixture):
    def setUp(self):
        super().setUp()
        self.put(pkt(1), pkt(2))
        lp.run(self.store_path, self.ledger)
        self.db = lp.open_ledger(self.ledger)
        self.later = datetime.now(timezone.utc) + timedelta(hours=25)

    def tearDown(self):
        self.db.close()
        super().tearDown()

    def test_blind_queue_hides_basis_and_confidence(self):
        q = lp.blind_queue(self.db)
        self.assertEqual(len(q), 2)
        for row in q:
            self.assertFalse({"reason", "confidence", "basis"} & set(row))
            self.assertEqual(len(row["tracks"]), 2)
            self.assertEqual(row["tracks"][0]["credit"], "Producer")

    def test_bar_needs_24h_every_label_and_zero_wrong(self):
        ids = [str(r["proposal_id"]) for r in lp.blind_queue(self.db)]
        good = {i: "correct" for i in ids}
        self.assertTrue(lp.score(self.db, good, now=self.later)["bar_met"])
        self.assertFalse(lp.score(self.db, good)["bar_met"])                                   # < 24 h
        self.assertFalse(lp.score(self.db, {ids[0]: "correct"}, now=self.later)["bar_met"])   # one unlabelled
        s = lp.score(self.db, {**good, ids[1]: "wrong"}, now=self.later)
        self.assertEqual((s["bar_met"], s["wrong"], s["wrong_ids"]), (False, 1, [int(ids[1])]))
        self.assertFalse(lp.score(self.db, {**good, ids[0]: "unsure"}, now=self.later)["bar_met"])
        with self.assertRaises(ValueError):
            lp.score(self.db, {ids[0]: "probably"}, now=self.later)

    def test_no_proposals_never_meets_the_bar(self):
        empty = lp.open_ledger(os.path.join(self.tmp, "empty.sqlite3"))
        self.assertFalse(lp.score(empty, {}, now=self.later)["bar_met"])
        empty.close()


class Cli(Fixture):
    def cli(self, *args, ok=(0,)):
        env = dict(os.environ, CREDIT_DSP_VERIFY_KILL_SWITCH=os.path.join(self.tmp, "kill"),
                   CREDIT_VERIFY_KILL_SWITCH=os.path.join(self.tmp, "kill2"))
        r = subprocess.run([sys.executable, str(CLI), "--store", self.store_path, *args], capture_output=True,
                           text=True, env=env, timeout=60)
        self.assertIn(r.returncode, ok, r.stderr)
        return r

    def test_run_queue_score(self):
        self.put(pkt(1), pkt(2))
        r = self.cli("link-proposals", "--ledger", self.ledger, "--no-claim-lookup")
        self.assertEqual(r.stdout.strip(), "NO_REPLY")
        q = [json.loads(ln) for ln in self.cli("link-queue", "--ledger", self.ledger).stdout.splitlines()]
        self.assertEqual(len(q), 2)
        labels = os.path.join(self.tmp, "labels.json")
        Path(labels).write_text(json.dumps({str(x["proposal_id"]): "correct" for x in q}))
        r = self.cli("link-score", "--ledger", self.ledger, "--labels", labels, ok=(1,))   # < 24 h: not met
        self.assertFalse(json.loads(r.stdout)["bar_met"])

    def test_kill_switch(self):
        self.put(pkt(1), pkt(2))
        Path(self.tmp, "kill").write_text("")
        r = self.cli("link-proposals", "--ledger", self.ledger, "--no-claim-lookup")
        self.assertEqual(r.stdout.strip(), "NO_REPLY")
        self.assertFalse(os.path.exists(self.ledger))


if __name__ == "__main__":
    unittest.main(verbosity=1)
