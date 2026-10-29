#!/usr/bin/env python3
"""credit_review.identity_resolver (r5, Fable [key=x2-sample-1027]): an Intercom external_id resolves to
an account when it is the professional id, the Auth0 subject, a processed-claim profile or the
representation profile of EXACTLY ONE account; 0 or >1 owners, or a reverted claim by another account,
refuse. Pinned on the real shape of the intercom-id-reconcile-x2 census (234 conversations, ids
synthetic: fixtures/x2_presented_identity_census.json). No network, no replica."""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import identity_resolver as IR  # noqa: E402

FIXTURE = ROOT / "scripts" / "tests" / "fixtures" / "x2_presented_identity_census.json"


def in_list(sql: str, after: str) -> list[str]:
    m = re.search(re.escape(after) + r" IN \(([^)]*)\)", sql)
    return [x.strip().strip("'") for x in m.group(1).split(",")] if m else []


class Replica:
    """Answers exactly the resolver's queries from users [{id, pro, auth, rep}] and claims
    [{profile, user, status, deleted}]; anything else is a test failure."""

    def __init__(self, users, claims):
        self.users, self.claims, self.sql = users, claims, []

    def __call__(self, sql):
        self.sql.append(sql)
        if "FROM postgresql_core.public.claiming WHERE CAST(profileid AS varchar) IN" in sql:
            assert "deletedat IS NULL" in sql and "userid IS NOT NULL" in sql
            vals = set(in_list(sql, "CAST(profileid AS varchar)"))
            return [[c["profile"], str(c["user"]), c["status"]] for c in self.claims
                    if c["profile"] in vals and c["user"] is not None and not c["deleted"]]
        if "FROM postgresql_core.public.claiming WHERE userid IN" in sql:
            ids = {int(x) for x in re.search(r"userid IN \(([^)]*)\)", sql).group(1).split(",")}
            return [[str(c["user"]), c["profile"]] for c in self.claims
                    if c["user"] in ids and c["status"] == "processed" and not c["deleted"]]
        if "CAST(representationprofileid AS varchar) IN" in sql:
            pros, reps = set(in_list(sql, "neptuneprofessionalid")), set(in_list(sql, "CAST(representationprofileid AS varchar)"))
            auths = set(in_list(sql, "auth0userid"))
            return [[str(u["id"]), u.get("pro"), u.get("auth"), u.get("rep")] for u in self.users
                    if (u.get("pro") and u["pro"] in pros) or (u.get("rep") and u["rep"] in reps)
                    or (u.get("auth") and u["auth"] in auths)]
        if "neptuneprofessionalid FROM postgresql_core.public.users WHERE id IN" in sql:
            ids = {int(x) for x in re.search(r"WHERE id IN \(([^)]*)\)", sql).group(1).split(",")}
            return [[str(u["id"]), u.get("rep"), u.get("pro")] for u in self.users if u["id"] in ids]
        raise AssertionError(sql)


class DecideTests(unittest.TestCase):
    def test_exactly_one_owner_resolves_and_says_how(self):
        r = IR.decide("p1", {7: {IR.PRESENTED_PROFILE}}, set())
        self.assertEqual((r.account_id, r.matched_by, r.why), (7, IR.PRESENTED_PROFILE, ""))
        r = IR.decide("p1", {7: {IR.PRESENTED_PROFILE, IR.PROFESSIONAL_ID}}, set())
        self.assertEqual(r.matched_by, IR.PROFESSIONAL_ID)

    def test_zero_or_several_owners_refuse(self):
        self.assertIsNone(IR.decide("p1", {}, set()).account_id)
        r = IR.decide("p1", {7: {IR.PRESENTED_PROFILE}, 8: {IR.PROFESSIONAL_ID}}, set())
        self.assertIsNone(r.account_id)
        self.assertIn("2 Muso accounts", r.why)

    def test_a_reverted_claim_by_another_account_refuses(self):
        r = IR.decide("p1", {7: {IR.PRESENTED_PROFILE}}, {9})
        self.assertIsNone(r.account_id)
        self.assertIn("reverted", r.why)
        self.assertEqual(IR.decide("p1", {7: {IR.PRESENTED_PROFILE}}, {7}).account_id, 7, "its own reverted claim is no conflict")

    def test_malformed_ids_never_resolve(self):
        for x in ("", "has space", "a@b.com", "x" * 200):
            self.assertIsNone(IR.decide(x, {7: {IR.PROFESSIONAL_ID}}, set()).account_id, x)


class ReplicaRuleTests(unittest.TestCase):
    def test_only_processed_not_deleted_claims_with_a_user_confer_identity(self):
        rep = Replica([], [{"profile": "p1", "user": 7, "status": "processed", "deleted": False},
                           {"profile": "p2", "user": 7, "status": "pending", "deleted": False},
                           {"profile": "p3", "user": 7, "status": "rejected", "deleted": False},
                           {"profile": "p4", "user": 7, "status": "processed", "deleted": True},
                           {"profile": "p5", "user": None, "status": "processed", "deleted": False}])
        got = IR.resolve(["p1", "p2", "p3", "p4", "p5"], rep)
        self.assertEqual({x: r.account_id for x, r in got.items()}, {"p1": 7, "p2": None, "p3": None, "p4": None, "p5": None})

    def test_representation_profile_and_professional_id_and_auth0(self):
        rep = Replica([{"id": 7, "pro": "pro7", "auth": "auth0|sub7", "rep": "r7"}], [])
        got = IR.resolve(["pro7", "r7", "sub7", "auth0|sub7"], rep)
        self.assertEqual({x: (r.account_id, r.matched_by) for x, r in got.items()},
                         {"pro7": (7, IR.PROFESSIONAL_ID), "r7": (7, IR.PRESENTED_PROFILE),
                          "sub7": (7, IR.AUTH0_SUBJECT), "auth0|sub7": (7, IR.AUTH0_SUBJECT)})

    def test_a_profile_one_account_claimed_and_another_represents_is_ambiguous(self):
        rep = Replica([{"id": 8, "rep": "p1"}], [{"profile": "p1", "user": 7, "status": "processed", "deleted": False}])
        self.assertIsNone(IR.resolve(["p1"], rep)["p1"].account_id)

    def test_presented_ids_are_the_accounts_own_and_exclude_shared_ones(self):
        rep = Replica([{"id": 7, "pro": "pro7", "rep": "r7"}, {"id": 8, "pro": "pro8", "rep": "shared"}],
                      [{"profile": "c7", "user": 7, "status": "processed", "deleted": False},
                       {"profile": "shared", "user": 7, "status": "processed", "deleted": False},
                       {"profile": "rv", "user": 7, "status": "processed", "deleted": False},
                       {"profile": "rv", "user": 9, "status": "reverted", "deleted": False},
                       {"profile": "pro7", "user": 7, "status": "processed", "deleted": False}])
        self.assertEqual(IR.presented_ids([7, 8], rep), {"7": ["c7", "r7"], "8": []})


class CensusTests(unittest.TestCase):
    """The 234 'no account' conversations of 2026-10-27 (fixture). The headline numbers are the ones the
    report measured with a different script (127 email links corroborated by a processed claim or the
    representation profile, before the deleted-claim / reverted-claim / ambiguity refusals)."""

    @classmethod
    def setUpClass(cls):
        cls.fx = json.loads(FIXTURE.read_text())
        cls.rep = Replica(cls.fx["users"], cls.fx["claims"])
        cls.res = IR.resolve([r["ext"] for r in cls.fx["rows"]], cls.rep)

    def test_fixture_shape(self):
        rows = self.fx["rows"]
        self.assertEqual(len(rows), 234)
        self.assertEqual(sum(r["email_link"] == "link" for r in rows), 142)   # 143 links, one with an empty id
        self.assertFalse(any(u.get("pro") for u in self.fx["users"]), "by construction no id is a professional id")

    def test_resolver_against_the_verified_email_link(self):
        out: dict[str, int] = {}
        for r in self.fx["rows"]:
            res = self.res[r["ext"]]
            if r["email_link"] == "link":
                k = ("same" if res.account_id == r["email_account"] else "other" if res.account_id
                     else "ambiguous" if "Muso accounts own" in res.why else "reverted" if "reverted" in res.why else "none")
            else:
                k = "refused_but_resolves" if res.account_id else "refused_none"
            out[k] = out.get(k, 0) + 1
        self.assertEqual(out, {"same": 119, "other": 1, "ambiguous": 2, "reverted": 2, "none": 18,
                               "refused_but_resolves": 4, "refused_none": 88})

    def test_every_resolution_is_backed_by_a_live_processed_claim_or_the_representation(self):
        claims = {(c["profile"], c["user"]) for c in self.fx["claims"] if c["status"] == "processed" and not c["deleted"]}
        reps = {(u["rep"], u["id"]) for u in self.fx["users"] if u.get("rep")}
        for x, r in self.res.items():
            if r.account_id is not None:
                self.assertEqual(r.matched_by, IR.PRESENTED_PROFILE)
                self.assertTrue((x, r.account_id) in claims or (x, r.account_id) in reps, x)


if __name__ == "__main__":
    unittest.main()
