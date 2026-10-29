"""C6 claim declines as code (claim_verify/decline_rules): d2's 17 as fixtures (14 decline / 3 hold), the G59 trio
as the related-profiles negative, every rail, and the tray accepted by the executor's own loader. Hermetic."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from claim_verify import decline_rules as dr  # noqa: E402
from credit_review import claim_executor as cx  # noqa: E402

FIX = json.loads((Path(__file__).resolve().parent / "fixtures" / "c6_decline_claims.json").read_text())
DECEASED = frozenset(FIX["deceased"])
SHARED = {frozenset({a, b}): n for a, b, n in FIX["shared_tracks"]}
ROWS = {r["claim"]["id"]: r for r in FIX["rows"]}
ALLOW = {"decision": "allow", "band": "green", "watch": False}


def ctx():
    claims = [r["claim"] for r in FIX["rows"]]
    profiles = {r["claim"]["profileId"]: r["profile"] for r in FIX["rows"]}
    return claims, profiles


def run(row, **over):
    claims, profiles = ctx()
    kw = {"user_claims": claims, "profiles": profiles, "deceased": DECEASED, "shared_tracks": SHARED}
    kw.update(over)
    return dr.decide(row["claim"], row["profile"], row["gate"], **kw)


def org_claim(**kw):
    claim = {"id": 9000001, "userId": 9000001, "profileId": "00000000-0000-0000-0000-000000000001",
             "profileType": "organization", "reason": "company claim on add", "status": "pending",
             "createdAt": "2026-10-20T00:00:00+00:00", "email_domain": "gmail.com",
             "verificationLinks": {"role": "Producer"}, "pk_profile_other_claims": []}
    claim.update(kw)
    return claim


class Fixtures(unittest.TestCase):
    def test_d2_17_is_14_decline_3_hold_and_the_g59_trio_stays(self):
        got = {cid: run(r).decision for cid, r in ROWS.items()}
        want = {cid: r["expect"] for cid, r in ROWS.items()}
        self.assertEqual(got, want)
        self.assertEqual(sum(1 for d in got.values() if d == "decline"), 14)
        self.assertEqual(sum(1 for d in got.values() if d == "hold"), 3)

    def test_each_decline_names_an_executor_class_and_evidence(self):
        for cid, r in ROWS.items():
            d = run(r)
            if d.decision == "decline":
                self.assertIn(d.contradiction, cx.CONTRADICTIONS, cid)
                self.assertGreaterEqual(len(d.evidence), 20, cid)
                self.assertTrue(d.rule_id.startswith(dr.RULES_VERSION + ":"), cid)

    def test_classes_of_the_14(self):
        cls = {cid: run(r).contradiction for cid, r in ROWS.items() if r["expect"] == "decline"}
        self.assertEqual(cls[1614355], "deceased_self_claim")
        self.assertEqual({cls[1604304], cls[1610051]}, {"test_account"})
        self.assertEqual(cls[1608918], "contradicted_by_own_claims")       # Bob Gaudio <-> Pinkfong, 0 shared
        for cid in (1608834, 1609413, 1610840, 1614946, 1619131, 1617173, 1618974, 1620572, 1610276):
            self.assertEqual(cls[cid], "individual_claims_company", cid)


class Rails(unittest.TestCase):
    def test_big_name_does_not_block_a_contradicted_decline(self):
        r = ROWS[1614946]                                                    # Atlantic Records, pop 96
        self.assertGreaterEqual(r["profile"]["popularity"], 90)
        self.assertEqual(run(r).decision, "decline")

    def test_held_account_goes_to_the_tray_even_when_contradicted(self):
        r = ROWS[1608834]
        for gate in ({"decision": "hold", "band": "red", "watch": False}, {**ALLOW, "watch": True}, None,
                     {"decision": "unknown"}):
            d = dr.decide(r["claim"], r["profile"], gate, deceased=DECEASED, shared_tracks=SHARED)
            self.assertEqual((d.decision, d.contradiction), ("hold", "individual_claims_company"), gate)

    def test_created_by_user_is_never_declined(self):
        r = ROWS[1608834]
        d = dr.decide({**r["claim"], "reason": "created by user"}, r["profile"], ALLOW)
        self.assertEqual(d.decision, "none")

    def test_only_open_claims(self):
        r = ROWS[1608834]
        for st in ("processed", "rejected", "intent_pending"):
            self.assertEqual(dr.decide({**r["claim"], "status": st}, r["profile"], ALLOW).decision, "none", st)

    def test_a_name_or_popularity_alone_never_declines(self):
        big = {"name": "Universal Music Group", "popularity": 99, "creditCount": 900000}
        for c in (org_claim(verificationLinks={"role": "Owner"}),                       # owner role, no prior rejects
                  org_claim(email_domain="umusic.com"),                                 # company domain
                  org_claim(reason=None, profileType="artist")):                        # not a company claim
            self.assertEqual(dr.decide(c, big, ALLOW).decision, "none", c)

    def test_individual_role_on_a_small_unknown_org_stays(self):
        small = {"name": "Basement Tapes LLC", "popularity": 12, "creditCount": 40}
        self.assertEqual(dr.decide(org_claim(), small, ALLOW).decision, "none")

    def test_named_major_is_an_exact_name_not_a_prefix(self):
        for name in ("Spotify Fan Club", "The Spotify Fans", "Rocnation Fans", "BMI Studios Collective"):
            self.assertEqual(dr.decide(org_claim(), {"name": name, "popularity": 5, "creditCount": 3}, ALLOW).decision,
                             "none", name)
        self.assertEqual(dr.decide(org_claim(), {"name": "BMI, Inc.", "popularity": 5}, ALLOW).decision, "decline")

    def test_named_major_with_low_catalog_popularity_declines(self):
        self.assertEqual(dr.decide(org_claim(), {"name": "BMI", "popularity": 52, "creditCount": 466}, ALLOW).decision,
                         "decline")

    def test_two_prior_other_user_rejections_count_even_for_an_owner_role(self):
        c = org_claim(verificationLinks={"role": "Owner"},
                      pk_profile_other_claims=[{"userId": 1, "status": "rejected"}, {"userId": 2, "status": "rejected"}])
        self.assertEqual(dr.decide(c, {"name": "RCA Records", "popularity": 95}, ALLOW).decision, "decline")
        anon = org_claim(verificationLinks={"role": "Owner"},
                         pk_profile_other_claims=[{"userId": None, "status": "rejected"}] * 2)   # QA #1506 repro
        self.assertEqual(dr.decide(anon, {"name": "BMI", "popularity": 52}, ALLOW).decision, "none")
        one = org_claim(verificationLinks={"role": "Owner"},
                        pk_profile_other_claims=[{"userId": 5, "status": "rejected"}] * 2)       # one user twice
        self.assertEqual(dr.decide(one, {"name": "BMI", "popularity": 52}, ALLOW).decision, "none")
        own = org_claim(verificationLinks={"role": "Owner"},
                        pk_profile_other_claims=[{"userId": 9000001, "status": "rejected"}] * 3)
        self.assertEqual(dr.decide(own, {"name": "RCA Records", "popularity": 95}, ALLOW).decision, "none")

    def test_own_claims_needs_a_proven_unrelated_pair(self):
        r = ROWS[1608918]
        self.assertEqual(run(r, shared_tracks={}).decision, "none")          # unknown relatedness never declines
        pair = frozenset({r["claim"]["profileId"], ROWS[1607654]["claim"]["profileId"]})
        self.assertEqual(run(r, shared_tracks={pair: 3}).decision, "none")   # any shared recording = related
        self.assertEqual(run(r).decision, "decline")

    def test_test_account_by_staff_address_but_not_for_a_muso_account(self):
        c = {**org_claim(email_domain="gmail.com"), "profileType": "artist", "reason": None,
             "verificationLinks": {"weblinks": "https://admin@muso.ai"}}
        self.assertEqual(dr.decide(c, {"name": "X", "popularity": 3}, ALLOW).contradiction, "test_account")
        self.assertEqual(dr.decide({**c, "email_domain": "muso.ai"}, {"name": "X", "popularity": 3}, ALLOW).decision,
                         "none")

    def test_deceased_needs_the_facts_entry(self):
        r = ROWS[1614355]
        self.assertEqual(run(r, deceased=frozenset()).decision, "none")


class LiveSnapshots(unittest.TestCase):
    PID = "35e96343-94d2-4e76-89c5-3b269cf02070"

    def fake(self, catalog=True):
        def run(sql):
            if "from postgresql_core.public.claiming c left join" in sql:
                return ('"1607654","1398875","%s","organization","company claim on add","pending",'
                        '"2026-09-09T10:00:00.000Z","gmail.com","{""role"":""other""}"\n' % self.PID)
            if "where deletedat is null and userid in" in sql:
                return '"1607654","1398875","%s","pending","2026-09-09T10:00:00.000Z"\n' % self.PID
            if "lower(profileid) in" in sql:
                return '"%s","1398875","pending"\n' % self.PID
            if "catalog_profile" in sql:
                return '"%s","Pinkfong","80","5361"\n' % self.PID if catalog else ""
            raise AssertionError(sql)
        return run

    def test_builds_a_snapshot_the_rule_declines(self):
        snaps = dr.live_snapshots([1607654], self.fake(), deceased=frozenset())
        d = dr.reproduce(snaps[1607654])
        self.assertEqual((d.decision, d.contradiction), ("decline", "individual_claims_company"))
        self.assertEqual(snaps[1607654]["claim"]["verificationLinks"], {"role": "other"})
        self.assertEqual(snaps[1607654]["claim"]["pk_profile_other_claims"], [])          # own claim excluded

    def test_a_claim_the_catalog_cannot_read_is_absent(self):
        self.assertEqual(dr.live_snapshots([1607654], self.fake(catalog=False), deceased=frozenset()), {})

    def test_deceased_comes_from_the_policy_not_the_tray(self):
        snaps = dr.live_snapshots([1607654], self.fake())                                  # repo policy file
        self.assertFalse(snaps[1607654]["deceased"])


class TrayAndSql(unittest.TestCase):
    def test_tray_round_trips_through_the_executor_loader(self):
        claims = {cid: r["claim"] for cid, r in ROWS.items()}
        all_claims, profiles = ctx()
        decisions = [run(r) for r in ROWS.values()]
        snaps = {d.claim_id: dr.snapshot(ROWS[d.claim_id]["claim"], ROWS[d.claim_id]["profile"], user_claims=all_claims,
                                         profiles=profiles, deceased=DECEASED, shared_tracks=SHARED)
                 for d in decisions if d.decision == "decline"}
        with self.assertRaises(ValueError):
            dr.build_tray(decisions, claims)                                   # a row must be reproducible
        tray = dr.build_tray(decisions, claims, snapshots=snaps)
        for r in tray["rows"]:                                                 # every snapshot reproduces its row
            again = dr.reproduce(r["facts"])
            self.assertEqual((again.decision, again.contradiction, again.rule_id),
                             ("decline", r["contradiction"], r["ruling_id"]), r["claim_id"])
        self.assertEqual(len(tray["rows"]), 14)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(tray, f)
        loaded = cx.load_claim_tray(f.name)
        self.assertEqual(sorted(r.claim_id for r in loaded.rows),
                         sorted(cid for cid, r in ROWS.items() if r["expect"] == "decline"))
        self.assertTrue(all(r.ruling_id.startswith(dr.RULES_VERSION) for r in loaded.rows))

    def test_candidate_pairs_and_sql(self):
        claims, profiles = ctx()
        pairs = dr.candidate_pairs(claims, profiles)
        self.assertIn(frozenset({ROWS[1608918]["claim"]["profileId"], ROWS[1607654]["claim"]["profileId"]}), pairs)
        sql = dr.shared_tracks_sql(set().union(*pairs))
        self.assertIn("matvw_profile_credit", sql)
        with self.assertRaises(ValueError):
            dr.shared_tracks_sql(["x'; drop table t; --", "00000000-0000-0000-0000-000000000001"])


if __name__ == "__main__":
    unittest.main()
