"""credit_review/established_claimant.py: the rule's three bars, the hold reading, and that it writes nothing."""
from __future__ import annotations

import credit_test_env  # noqa: F401 - first: test logs never reach the production run.log
import contextlib
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from credit_review import established_claimant as ec  # noqa: E402

POLICY = {"mode": "shadow", "min_profile_approved": 100, "max_profile_rejected_share": 0.01}

#: The validator approved it and holds nothing.
CLEAN = {"is_approved": True, "total_risk_percent": 12.0, "rule_risk_percent": {"track_credit": 10},
         "hold_reason_codes": []}
#: The validator declined it on the weighted score alone: no hold rule fired.
DECLINED = {"is_approved": False, "total_risk_percent": 100.0, "rule_risk_percent": {"track_credit": 60},
            "hold_reason_codes": ["risk_score_at_or_above_threshold"]}

ARTIST_A, ARTIST_B = "artistA", "artistB"


def rid(n: int) -> str:
    return str(uuid.UUID(int=n))


def pid(n: int) -> str:
    return str(uuid.UUID(int=0xABC000 + n))


def pg(roles) -> str:
    return "{" + ",".join(f'"{r}"' for r in roles) + "}"


def req(n, *, status="user_verification_needed", user="7", profile=1, roles=("Mastering",),
        artists=(ARTIST_A,), vd=CLEAN, via="validator", meta=None, popularity=12):
    return {"id": rid(n), "status": status, "user": user, "profile": pid(profile),
            "roles": list(roles), "artists": list(artists), "vd": vd, "via": via,
            "meta": meta or {}, "popularity": popularity}


def history(profile=1, *, user="7", approved=100, rejected=0, start=10_000,
            roles=("Mastering",), artists=(ARTIST_A,), via="validator"):
    """A profile's decided requests: ``approved`` approvals and ``rejected`` rejections."""
    out = [req(start + i, status="approved", user=user, profile=profile, roles=roles,
               artists=artists, via=via) for i in range(approved)]
    out += [req(start + approved + i, status="rejected", user=user, profile=profile,
                roles=roles, artists=artists) for i in range(rejected)]
    return out


class Replica:
    """The core replica, as far as the module's five statements go. Records every statement."""

    def __init__(self, requests):
        self.requests = list(requests)
        self.calls: list[str] = []
        #: request ids whose status reads as approved on the verdict read (decided meanwhile)
        self.decided_meanwhile: set[str] = set()
        #: request ids soft-deleted between the two reads
        self.deleted: set[str] = set()
        #: request ids the verdict read does not return at all
        self.missing: set[str] = set()

    @staticmethod
    def _pending(r):
        return r["status"] in ec.PENDING_STATUSES

    @staticmethod
    def _part(vd, key):
        if not isinstance(vd, dict) or key not in vd:
            return ""
        return json.dumps(vd[key])

    def __call__(self, sql: str):
        self.calls.append(sql)
        uuids = re.findall(r"UUID '([0-9a-f-]{36})'", sql)
        if sql == ec.COUNT_SQL:
            counts: dict[str, int] = {}
            for r in self.requests:
                if self._pending(r):
                    counts[r["status"]] = counts.get(r["status"], 0) + 1
            return [[s, str(n)] for s, n in counts.items()]
        if "HAVING count_if" in sql:
            floor = int(re.search(r"count_if\(status = 'approved'\) >= (\d+)", sql).group(1))
            out = []
            for profile in sorted({r["profile"] for r in self.requests}):
                rows = [r for r in self.requests if r["profile"] == profile]
                approved = sum(1 for r in rows if r["status"] == "approved")
                rejected = sum(1 for r in rows if r["status"] == "rejected")
                if approved >= floor and any(self._pending(r) for r in rows):
                    out.append([profile, str(approved), str(rejected)])
            return out
        if "profileid IN (" in sql:
            return [[r["id"], r["user"], r["profile"], r["status"], pg(r["roles"]), "|".join(r["artists"])]
                    for r in self.requests if self._pending(r) and r["profile"] in uuids]
        if "userid IN (" in sql:
            users = set(re.search(r"userid IN \(([^)]*)\)", sql).group(1).split(", "))
            groups: dict[tuple, list[str]] = {}
            for r in self.requests:
                if r["status"] == "approved" and r["user"] in users:
                    groups.setdefault((r["user"], pg(r["roles"]), "|".join(r["artists"]), r["via"]), []).append(r["id"])
            return [[u, c, a, v, min(ids)] for (u, c, a, v), ids in groups.items()]
        if "WHERE id IN (" in sql:
            out = []
            for r in self.requests:
                if r["id"] not in uuids or r["id"] in self.missing:
                    continue
                status = "approved" if r["id"] in self.decided_meanwhile else r["status"]
                vd = r["vd"]
                if isinstance(vd, str):          # a part that does not parse
                    parts = ["{not json"] + [""] * (len(ec.VERDICT_PARTS) - 1)
                else:
                    parts = [self._part(vd, key) for key in ec.VERDICT_PARTS]
                out.append([r["id"], status, "true" if r["id"] in self.deleted else "false",
                            "true" if vd is None else "false", *parts,
                            self._part(r["meta"], "fraudRemoval"), self._part(r["meta"], "precedentRevert"),
                            "true" if "proofRequest" in r["meta"] else "false",
                            "" if r["popularity"] is None else str(r["popularity"])])
            return out
        raise AssertionError(f"a statement the module is not known to send:\n{sql}")


def decide(replica, policy=POLICY):
    rows, funnel = ec.run(replica, policy)
    return {r["request_id"]: r for r in rows}, funnel


class PolicyTests(unittest.TestCase):
    def test_the_checked_in_policy_is_shadow_at_the_ruled_thresholds(self):
        self.assertEqual(ec.load_policy(), POLICY)

    def test_any_other_mode_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "p.json"
            for mode in ("live", "canary", "", None):
                path.write_text(json.dumps({**POLICY, "mode": mode}))
                with self.subTest(mode=mode), self.assertRaises(ec.EstablishedClaimantError):
                    ec.load_policy(path)

    def test_an_unreadable_or_malformed_policy_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "p.json"
            with self.assertRaises(ec.EstablishedClaimantError):
                ec.load_policy(path)                      # absent
            for text in ("{", "[]", json.dumps({**POLICY, "min_profile_approved": "100"}),
                         json.dumps({**POLICY, "min_profile_approved": True}),
                         json.dumps({**POLICY, "min_profile_approved": 0}),
                         json.dumps({**POLICY, "max_profile_rejected_share": 1.5}),
                         json.dumps({"mode": "shadow"})):
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(ec.EstablishedClaimantError):
                    ec.load_policy(path)

    def test_the_profile_bar_at_its_edges(self):
        for approved, rejected, want in ((100, 0, True), (99, 0, False), (100, 1, True),
                                         (100, 2, False), (198, 2, True), (197, 2, False),
                                         (596, 1, True), (5000, 51, False)):
            with self.subTest(approved=approved, rejected=rejected):
                self.assertEqual(ec.profile_passes(approved, rejected, POLICY), want)


class DecideTests(unittest.TestCase):
    """One established request, one verdict, one answer."""

    def _one(self, vd, *, removed=False, roles=("Mastering",)):
        return ec.decide(vd, removed, list(roles))

    def test_validator_approved_and_nothing_held_is_the_only_approve(self):
        self.assertEqual(self._one(CLEAN), ("approve", ec.APPROVE_REASON, []))

    def test_a_request_the_validator_declined_is_an_ask_never_an_approve(self):
        for risk in (100.0, 60.0, 35.0, 0.0):
            with self.subTest(risk=risk):
                outcome, reason, bars = self._one({**DECLINED, "total_risk_percent": risk})
                self.assertEqual((outcome, reason), ("ask", ec.BAR_DECLINED))
                self.assertIn(ec.BAR_DECLINED, bars)

    def test_no_recorded_decision_is_not_an_approval(self):
        for vd in ({"rule_risk_percent": {}}, {"rule_risk_percent": {}, "is_approved": None},
                   {"rule_risk_percent": {}, "is_approved": "true"},
                   {"rule_risk_percent": {}, "is_approved": 1}):
            with self.subTest(vd=vd):
                self.assertEqual(self._one(vd)[:2], ("ask", ec.BAR_UNDECIDED))

    def test_a_hold_a_document_can_clear_is_an_ask_even_when_the_validator_approved(self):
        vd = {**CLEAN, "rule_risk_percent": {"review_big_track_without_trusted_credit": 30}}
        self.assertEqual(self._one(vd), ("ask", ec.BAR_ASKABLE, [ec.BAR_ASKABLE]))

    def test_a_hold_no_document_clears_bars_the_request_and_asks_nobody(self):
        cases = [
            ("fraud hold", {"fraud_hold": {"decision": "hold"}}, "hold:fraud"),
            ("held submitter", {"rule_risk_percent": {"review_held_submitter": 30}}, "hold:fraud"),
            ("role credited to another at a trusted source",
             {"rule_risk_percent": {"review_role_credited_to_other_at_trusted_source": 30}},
             "hold:impersonation"),
            ("Ops tombstone", {"rule_risk_percent": {"review_operations_tombstone": 30}}, "hold:legal"),
            ("credit already on the profile",
             {"rule_risk_percent": {"review_duplicate_of_approved_credit": 30}}, "hold:already_held"),
            ("an auto-reject rule", {"rule_risk_percent": {"reject_publisher_label_credit": 100}},
             "hold:band_c"),
            ("evaluation error", {"rule_errors": {"_hold_on_error": "rule crashed"}}, "hold:unmeasured"),
            ("hourly velocity, not an editing role",
             {"rule_risk_percent": {"review_hourly_velocity_profile": 30}}, "hold:band_c_velocity"),
        ]
        for name, extra, want in cases:
            for base in (CLEAN, DECLINED):
                with self.subTest(name=name, approved=base["is_approved"]):
                    vd = {**base, **extra,
                          "rule_risk_percent": {**base["rule_risk_percent"],
                                                **extra.get("rule_risk_percent", {})}}
                    outcome, reason, bars = self._one(vd)
                    self.assertEqual((outcome, reason), ("barred", want))
                    self.assertIn(want, bars)

    def test_a_velocity_hold_on_an_editing_role_is_an_ask(self):
        vd = {**CLEAN, "rule_risk_percent": {"review_hourly_velocity_profile": 30}}
        self.assertEqual(self._one(vd, roles=("Editorial",))[:2], ("ask", ec.BAR_ASKABLE))

    def test_a_hold_code_cores_guard_does_not_stop_bars_an_approved_request(self):
        """2026-11-13: ``track_pending_capture`` at risk 100, approved 17 minutes later."""
        vd = {**CLEAN, "hold_reason_codes": ["track_pending_capture"]}
        self.assertEqual(self._one(vd), ("barred", ec.BAR_UNCOVERED, [ec.BAR_UNCOVERED]))

    def test_that_code_on_a_declined_request_leaves_it_an_ask(self):
        vd = {**DECLINED, "hold_reason_codes": ["track_pending_capture"]}
        self.assertEqual(self._one(vd)[:2], ("ask", ec.BAR_DECLINED))

    def test_no_verdict_and_an_unreadable_one_approve_nothing_and_ask_nobody(self):
        self.assertEqual(self._one(None), ("barred", ec.BAR_NO_VERDICT, [ec.BAR_NO_VERDICT]))
        for vd in ("unreadable:rule_risk_percent", [], {}, {"is_approved": True},
                   {**CLEAN, "rule_risk_percent": "n/a"},
                   {**CLEAN, "fraud_hold": "hold"}):
            with self.subTest(vd=vd):
                self.assertEqual(self._one(vd)[:2], ("barred", ec.BAR_UNMEASURED))

    def test_an_earlier_removal_or_revert_bars_whatever_the_verdict_says(self):
        self.assertEqual(self._one(CLEAN, removed=True), ("barred", ec.BAR_REMOVED, [ec.BAR_REMOVED]))
        outcome, reason, bars = self._one(DECLINED, removed=True)
        self.assertEqual((outcome, reason), ("barred", ec.BAR_REMOVED))
        self.assertEqual(bars, [ec.BAR_REMOVED, ec.BAR_DECLINED])

    def test_no_shape_of_verdict_that_is_not_validator_approved_is_ever_approved(self):
        extras = [{}, {"fraud_hold": {"decision": "pass"}}, {"hold_reason_codes": None},
                  {"hold_reason_codes": []}, {"rule_errors": {}}, {"total_risk_percent": 0}]
        for approved in (False, None, "true", 0, 1, [], "yes"):
            for extra in extras:
                vd = {"rule_risk_percent": {"track_credit": 0}, "is_approved": approved, **extra}
                with self.subTest(vd=vd):
                    self.assertNotEqual(self._one(vd)[0], "approve")


class EstablishedTests(unittest.TestCase):
    """Which pending requests the claimant's own record covers."""

    def _decide_one(self, target, extra=()):
        replica = Replica([*history(), *extra, target])
        rows, funnel = decide(replica)
        return rows.get(target["id"]), funnel

    def test_same_user_same_role_same_artist_on_a_passing_profile_is_established(self):
        row, funnel = self._decide_one(req(1))
        self.assertEqual(row["outcome"], "approve")
        self.assertEqual(row["anchors"], {"Mastering": rid(10_000)})
        self.assertEqual(funnel["established"], 1)

    def test_a_new_artist_is_not_established(self):
        row, funnel = self._decide_one(req(1, artists=(ARTIST_B,)))
        self.assertIsNone(row)
        self.assertEqual((funnel["on_eligible_profile"], funnel["established"]), (1, 0))

    def test_one_shared_artist_among_several_is_enough(self):
        row, _ = self._decide_one(req(1, artists=(ARTIST_B, ARTIST_A)))
        self.assertEqual(row["outcome"], "approve")

    def test_a_role_the_user_holds_nowhere_is_not_established(self):
        self.assertIsNone(self._decide_one(req(1, roles=("Producer",)))[0])

    def test_every_claimed_role_needs_its_own_credit(self):
        self.assertIsNone(self._decide_one(req(1, roles=("Mastering", "Producer")))[0])
        held = history(start=20_000, approved=1, roles=("Producer",))
        row, _ = self._decide_one(req(1, roles=("Mastering", "Producer")), held)
        self.assertEqual(row["outcome"], "approve")
        self.assertEqual(sorted(row["anchors"]), ["Mastering", "Producer"])

    def test_the_role_must_be_held_with_that_artist_not_with_another(self):
        held = history(start=20_000, approved=1, roles=("Producer",), artists=(ARTIST_B,))
        self.assertIsNone(self._decide_one(req(1, roles=("Producer",)), held)[0])

    def test_another_users_credit_on_the_same_profile_establishes_nobody(self):
        self.assertIsNone(self._decide_one(req(1, user="8"))[0])

    def test_one_users_record_does_not_establish_another_user_beside_it(self):
        """Both users have a pending request on the profile; only one holds the credit."""
        replica = Replica([*history(), req(1), req(2, user="8")])
        rows, funnel = decide(replica)
        self.assertEqual(sorted(rows), [rid(1)])
        self.assertEqual((funnel["on_eligible_profile"], funnel["established"]), (2, 1))

    def test_a_request_with_no_user_no_role_or_no_artist_is_counted_and_not_matched(self):
        for kwargs, key in (({"user": ""}, "no_user"), ({"roles": ()}, "no_roles"),
                            ({"artists": ()}, "no_artist_ids")):
            with self.subTest(key=key):
                row, funnel = self._decide_one(req(1, **kwargs))
                self.assertIsNone(row)
                self.assertEqual(funnel[key], 1)

    def test_a_profile_under_either_bar_is_not_read_at_all(self):
        for approved, rejected in ((99, 0), (100, 2)):
            with self.subTest(approved=approved, rejected=rejected):
                replica = Replica([*history(approved=approved, rejected=rejected), req(1)])
                rows, funnel = decide(replica)
                self.assertEqual((rows, funnel["eligible_profiles"], funnel["on_eligible_profile"]), ({}, 0, 0))
                self.assertFalse(any("profileid IN (" in sql for sql in replica.calls))

    def test_the_record_that_establishes_may_sit_on_another_profile_of_the_same_user(self):
        other = history(profile=2, start=20_000, approved=1, roles=("Producer",))
        row, _ = self._decide_one(req(1, roles=("Producer",)), other)
        self.assertEqual(row["outcome"], "approve")

    def test_a_basis_that_is_only_precedent_v1_is_named_on_the_row(self):
        held = history(start=20_000, approved=1, roles=("Producer",), via="precedent_v1")
        row, funnel = self._decide_one(req(1, roles=("Producer",)), held)
        self.assertEqual(row["basis_via"], ["precedent_v1"])
        self.assertEqual(funnel["approve_basis_only_precedent_v1"], 1)


class RunTests(unittest.TestCase):
    def _mixed(self):
        return Replica([
            *history(),
            req(1),                                                    # approve
            req(2, vd=DECLINED),                                       # ask
            req(3, status="unverified",
                vd={**CLEAN, "rule_risk_percent": {"review_hourly_velocity_profile": 30}}),   # barred
            req(4, vd=None),                                           # barred: no verdict
            req(5, meta={"fraudRemoval": {"at": "2026-10-01"}}),       # barred: removed before
            req(6, artists=(ARTIST_B,)),                               # not established
            *history(profile=2, user="9", approved=10, start=30_000),
            req(7, user="9", profile=2),                               # profile under the bar
        ])

    def test_the_funnel_counts_each_step_and_each_bar(self):
        rows, funnel = decide(self._mixed())
        self.assertEqual(funnel["pending"], 7)
        self.assertEqual(funnel["pending_by_status"], {"unverified": 1, "user_verification_needed": 6})
        self.assertEqual(funnel["eligible_profiles"], 1)
        self.assertEqual(funnel["on_eligible_profile"], 6)
        self.assertEqual(funnel["established"], 5)
        self.assertEqual(funnel["decided"], 5)
        self.assertEqual(funnel["outcomes"], {"approve": 1, "ask": 1, "barred": 3})
        self.assertEqual(funnel["bars"], {ec.BAR_DECLINED: 1, ec.BAR_NO_VERDICT: 1, ec.BAR_REMOVED: 1,
                                          "hold:band_c_velocity": 1})
        self.assertEqual(funnel["reasons"], {
            "approve:" + ec.APPROVE_REASON: 1, "ask:" + ec.BAR_DECLINED: 1,
            "barred:" + ec.BAR_NO_VERDICT: 1, "barred:" + ec.BAR_REMOVED: 1,
            "barred:hold:band_c_velocity": 1})
        self.assertEqual((funnel["approve_users"], funnel["approve_profiles"]), (1, 1))
        self.assertEqual({k: v["outcome"] for k, v in rows.items()},
                         {rid(1): "approve", rid(2): "ask", rid(3): "barred", rid(4): "barred",
                          rid(5): "barred"})

    def test_a_precedent_revert_bars_like_a_fraud_removal(self):
        rows, _ = decide(Replica([*history(), req(1, meta={"precedentRevert": {"by": "x"}})]))
        self.assertEqual((rows[rid(1)]["outcome"], rows[rid(1)]["reason"]), ("barred", ec.BAR_REMOVED))

    def test_no_declined_request_is_approved_whatever_the_record_behind_it(self):
        requests = [*history(approved=5000)]
        for n in range(1, 41):
            requests.append(req(n, vd={**DECLINED, "total_risk_percent": float(n % 5) * 25}))
        rows, funnel = decide(Replica(requests))
        self.assertEqual(funnel["outcomes"], {"approve": 0, "ask": 40, "barred": 0})
        self.assertTrue(all(r["validator_approved"] is False for r in rows.values()))

    def test_two_runs_over_the_same_data_are_byte_identical(self):
        first, _ = ec.run(self._mixed(), POLICY)
        second, _ = ec.run(self._mixed(), POLICY)
        self.assertEqual(ec.serialize(first), ec.serialize(list(reversed(second))))
        self.assertEqual([r["request_id"] for r in first], sorted(r["request_id"] for r in first))

    def test_a_request_decided_between_the_two_reads_is_counted_and_not_decided(self):
        replica = self._mixed()
        replica.decided_meanwhile = {rid(1)}
        rows, funnel = decide(replica)
        self.assertNotIn(rid(1), rows)
        self.assertEqual((funnel["left_pending_between_reads"], funnel["outcomes"]["approve"]), (1, 0))

    def test_a_request_deleted_between_the_two_reads_is_counted_and_not_decided(self):
        replica = self._mixed()
        replica.deleted = {rid(1)}
        rows, funnel = decide(replica)
        self.assertNotIn(rid(1), rows)
        self.assertEqual((funnel["left_pending_between_reads"], funnel["outcomes"]["approve"]), (1, 0))
        self.assertEqual(funnel["verdict_row_not_returned"], 0)

    def test_a_verdict_row_the_replica_does_not_return_is_counted_never_assumed(self):
        replica = self._mixed()
        replica.missing = {rid(1)}
        rows, funnel = decide(replica)
        self.assertNotIn(rid(1), rows)
        self.assertEqual(funnel["verdict_row_not_returned"], 1)

    def test_a_verdict_part_that_does_not_parse_is_unmeasured(self):
        rows, _ = decide(Replica([*history(), req(1, vd="broken")]))
        self.assertEqual((rows[rid(1)]["outcome"], rows[rid(1)]["reason"]), ("barred", ec.BAR_UNMEASURED))

    def test_a_json_null_part_is_read_as_null_not_as_absent(self):
        rows, _ = decide(Replica([*history(), req(1, vd={**CLEAN, "hold_reason_codes": None,
                                                              "fraud_hold": None})]))
        self.assertEqual(rows[rid(1)]["outcome"], "approve")

    def test_every_statement_is_bounded_and_none_joins(self):
        requests = []
        for p in range(1, 451):                    # 450 passing profiles, one user each
            requests += history(profile=p, user=str(1000 + p), approved=100, start=p * 1000)
            requests.append(req(900_000 + p, user=str(1000 + p), profile=p))
        replica = Replica(requests)
        rows, funnel = decide(replica)
        self.assertEqual((funnel["eligible_profiles"], funnel["outcomes"]["approve"]), (450, 450))
        for sql in replica.calls:
            self.assertNotIn(" JOIN ", sql.upper())
            self.assertLessEqual(len(re.findall(r"UUID '", sql)), ec.CHUNK)
            users = re.search(r"userid IN \(([^)]*)\)", sql)
            if users:
                self.assertLessEqual(len(users.group(1).split(", ")), ec.CHUNK)
        # one count, one profile read, then three reads of 450 ids at CHUNK a statement
        self.assertEqual(len(replica.calls), 2 + 3 * -(-450 // ec.CHUNK))

    def test_an_id_that_is_not_an_id_never_reaches_a_statement(self):
        class Odd(Replica):
            def __call__(self, sql):
                rows = super().__call__(sql)
                if "HAVING count_if" in sql:
                    rows.append(["x'); DROP TABLE credit_requests; --", "500", "0"])
                return rows
        replica = Odd([*history(), req(1)])
        with self.assertRaises(ec.EstablishedClaimantError):
            ec.run(replica, POLICY)
        self.assertFalse(any("DROP TABLE" in sql for sql in replica.calls))

    def test_a_count_that_is_not_a_number_stops_the_run(self):
        class Odd(Replica):
            def __call__(self, sql):
                rows = super().__call__(sql)
                return [[r[0], "many", r[2]] for r in rows] if "HAVING count_if" in sql else rows
        with self.assertRaises(ec.EstablishedClaimantError):
            ec.run(Odd([*history(), req(1)]), POLICY)


class CoreGuardTests(unittest.TestCase):
    """What core's guard would say is recorded on an approve, and decides nothing."""

    def _one(self, **kwargs):
        rows, funnel = decide(Replica([*history(), req(1, **kwargs)]))
        return rows[rid(1)], funnel

    def test_an_approve_core_would_allow_says_so(self):
        row, funnel = self._one(vd={**CLEAN, "band_hint": "A"})
        self.assertEqual((row["outcome"], row["core_guard"]), ("approve", []))
        self.assertEqual((funnel["approve_core_guard"], funnel["approve_core_would_refuse"]),
                         ({"allowed": 1}, 0))

    def test_a_band_b_hint_and_a_proof_request_are_named_and_the_row_stays_an_approve(self):
        row, funnel = self._one(vd={**CLEAN, "band_hint": "B"},
                                meta={"proofRequest": {"at": "2026-11-01"}})
        self.assertEqual(row["outcome"], "approve")
        self.assertEqual(row["core_guard"], ["proof_required", "validator_band_hint", "proof_requested"])
        self.assertEqual(funnel["approve_core_would_refuse"], 1)
        self.assertEqual(funnel["approve_core_guard"],
                         {"proof_required": 1, "proof_requested": 1, "validator_band_hint": 1})

    def test_a_proof_request_whose_value_is_null_still_counts(self):
        row, _ = self._one(meta={"proofRequest": None})
        self.assertEqual(row["core_guard"], ["proof_required", "proof_requested"])

    def test_a_high_risk_profile_is_named(self):
        row, _ = self._one(vd={**CLEAN, "profile_risk_level": "critical"})
        self.assertEqual(row["core_guard"], ["proof_required", "profile_risk"])

    def test_only_an_approve_carries_the_reading(self):
        row, funnel = self._one(vd={**DECLINED, "band_hint": "B"})
        self.assertEqual((row["outcome"], row["core_guard"]), ("ask", None))
        self.assertEqual((funnel["approve_core_guard"], funnel["approve_core_would_refuse"]), ({}, 0))

    def test_the_popularity_of_each_approve_is_counted_by_band(self):
        requests = [*history()]
        for n, pop in enumerate((None, 0, 1, 29, 30, 59, 60, 100), start=1):
            requests.append(req(n, popularity=pop))
        rows, funnel = decide(Replica(requests))
        self.assertEqual(funnel["approve_popularity"],
                         {"0": 1, "1-29": 2, "30-59": 2, "60+": 2, "unknown": 1})
        self.assertIsNone(rows[rid(1)]["popularity"])


class NoWriterTests(unittest.TestCase):
    def test_a_run_reaches_no_client_that_can_write(self):
        """The run succeeds with every writer path made to raise: it uses none of them."""
        from credit_review import verify_notify
        replica = Replica([*history(), req(1), req(2, vd=DECLINED)])
        called: list[str] = []

        def boom(name):
            def fail(*args, **kwargs):
                called.append(name)
                raise AssertionError(f"the run reached {name}")
            return fail

        with tempfile.TemporaryDirectory() as td, \
                unittest.mock.patch.object(verify_notify, "trino", replica), \
                unittest.mock.patch.object(subprocess, "run", boom("subprocess.run")), \
                unittest.mock.patch.object(subprocess, "Popen", boom("subprocess.Popen")), \
                unittest.mock.patch.object(os, "system", boom("os.system")), \
                unittest.mock.patch.object(sqlite3, "connect", boom("sqlite3.connect")), \
                unittest.mock.patch.object(urllib.request, "urlopen", boom("urllib.request.urlopen")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ec._main(["run", "--out", td]), 0)
        self.assertEqual(called, [])

    def test_a_run_writes_its_two_files_and_nothing_else(self):
        from credit_review import verify_notify
        replica = Replica([*history(), req(1), req(2, vd=DECLINED)])
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "run"
            with unittest.mock.patch.object(verify_notify, "trino", replica), \
                    contextlib.redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(ec._main(["run", "--out", str(out)]), 0)
            self.assertEqual(sorted(p.name for p in out.iterdir()), ["decisions.jsonl", "funnel.json"])
            self.assertEqual(sorted(p.name for p in Path(td).iterdir()), ["run"])
            rows = [json.loads(line) for line in (out / "decisions.jsonl").read_text().splitlines()]
            self.assertEqual([r["outcome"] for r in rows], ["approve", "ask"])
            funnel = json.loads((out / "funnel.json").read_text())
            self.assertEqual(funnel, json.loads(stdout.getvalue()))
            self.assertEqual(funnel["mode"], "shadow")

    def test_a_read_that_did_not_finish_is_a_failed_run(self):
        from credit_review import verify_notify
        replica = Replica([*history(), req(1)])
        replica.missing = {rid(1)}
        with tempfile.TemporaryDirectory() as td, \
                unittest.mock.patch.object(verify_notify, "trino", replica), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ec._main(["run", "--out", td]), 1)

    def test_a_policy_asking_for_another_mode_runs_nothing(self):
        from credit_review import verify_notify
        replica = Replica([*history(), req(1)])
        with tempfile.TemporaryDirectory() as td:
            policy = Path(td) / "p.json"
            policy.write_text(json.dumps({**POLICY, "mode": "live"}))
            with unittest.mock.patch.object(verify_notify, "trino", replica), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ec._main(["run", "--out", td, "--policy", str(policy)]), 2)
            self.assertEqual(replica.calls, [])
            self.assertEqual(sorted(p.name for p in Path(td).iterdir()), ["p.json"])


class TickTests(unittest.TestCase):
    """The scheduled pass: it publishes a whole answer or none, and nobody has to start it."""

    def setUp(self):
        from credit_review import verify_notify
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.state = Path(self._td.name) / "state"
        self.kill = Path(self._td.name) / "established-claimant.disabled"
        self.replica = Replica([*history(), req(1), req(2, vd=DECLINED)])
        self.stamps = iter(f"202611{d:02d}T032000Z" for d in range(1, 29))
        for target, name, value in ((ec, "STATE_DIR", str(self.state)), (ec, "KILL_FILE", str(self.kill)),
                                    (ec, "_stamp", lambda: next(self.stamps)),
                                    (verify_notify, "trino", lambda sql: self.replica(sql))):
            patcher = unittest.mock.patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _tick(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ec._main(["tick"])
        return code, out.getvalue(), err.getvalue()

    def _latest(self):
        return os.readlink(self.state / "latest")

    def test_a_pass_publishes_its_two_files_and_points_latest_at_them(self):
        code, out, _ = self._tick()
        self.assertEqual(code, 0)
        self.assertEqual(ec.published(), ["20261101T032000Z"])
        self.assertEqual(self._latest(), "runs/20261101T032000Z")
        run_dir = self.state / "latest"
        self.assertEqual(sorted(p.name for p in run_dir.iterdir()), ["decisions.jsonl", "funnel.json"])
        rows = [json.loads(line) for line in (run_dir / "decisions.jsonl").read_text().splitlines()]
        self.assertEqual([r["outcome"] for r in rows], ["approve", "ask"])
        printed = json.loads(out)
        self.assertEqual(printed["published"], "20261101T032000Z")
        self.assertEqual(printed["funnel"], json.loads((run_dir / "funnel.json").read_text()))
        self.assertEqual(sorted(p.name for p in self.state.iterdir()), ["latest", "runs"])

    def test_the_next_pass_needs_nothing_done_between_them(self):
        """Two passes in a row, nothing touched in between: the second sees the new data."""
        self.assertEqual(self._tick()[0], 0)
        self.replica.requests.append(req(3))
        self.assertEqual(self._tick()[0], 0)
        self.assertEqual(ec.published(), ["20261101T032000Z", "20261102T032000Z"])
        self.assertEqual(self._latest(), "runs/20261102T032000Z")
        first = (self.state / "runs/20261101T032000Z/decisions.jsonl").read_text().splitlines()
        second = (self.state / "latest/decisions.jsonl").read_text().splitlines()
        self.assertEqual((len(first), len(second)), (2, 3))

    def test_a_pass_whose_read_did_not_finish_publishes_nothing_and_fails(self):
        self.assertEqual(self._tick()[0], 0)
        self.replica.missing = {rid(1)}
        code, out, err = self._tick()
        self.assertEqual(code, 1)
        self.assertIn("nothing published", err)
        self.assertIsNone(json.loads(out)["published"])
        self.assertEqual(ec.published(), ["20261101T032000Z"])
        self.assertEqual(self._latest(), "runs/20261101T032000Z")
        self.assertEqual(sorted(p.name for p in (self.state / "runs").iterdir()), ["20261101T032000Z"])

    def test_a_replica_that_does_not_answer_publishes_nothing_and_fails(self):
        self.assertEqual(self._tick()[0], 0)

        class Down(Exception):
            pass

        def down(sql):
            raise Down("replica unreachable")
        self.replica = down
        with self.assertRaises(Down):
            self._tick()
        self.assertEqual(ec.published(), ["20261101T032000Z"])
        self.assertEqual(self._latest(), "runs/20261101T032000Z")
        self.assertEqual(sorted(p.name for p in (self.state / "runs").iterdir()), ["20261101T032000Z"])

    def test_the_first_pass_ever_that_fails_leaves_no_latest(self):
        self.replica.missing = {rid(1)}
        self.assertEqual(self._tick()[0], 1)
        self.assertFalse((self.state / "latest").exists())
        self.assertEqual(ec.published(), [])

    def test_the_stop_switch_reads_nothing_and_is_not_a_failure(self):
        self.kill.write_text("")
        code, out, err = self._tick()
        self.assertEqual((code, out), (0, ""))
        self.assertIn("nothing read", err)
        self.assertEqual(self.replica.calls, [])
        self.assertFalse(self.state.exists())
        self.assertEqual(ec.tick(self.replica, POLICY), (0, {"skipped": f"{self.kill} is present",
                                                              "published": None}))
        self.kill.unlink()                       # gone again: the next pass runs by itself
        self.assertEqual(self._tick()[0], 0)
        self.assertEqual(ec.published(), ["20261101T032000Z"])

    def test_old_passes_are_pruned_and_the_newest_are_kept(self):
        for _ in range(ec.KEEP_RUNS + 3):
            self.assertEqual(self._tick()[0], 0)
        kept = ec.published()
        self.assertEqual(len(kept), ec.KEEP_RUNS)
        self.assertEqual(kept[-1], f"202611{ec.KEEP_RUNS + 3:02d}T032000Z")
        self.assertEqual(kept[0], "20261104T032000Z")
        self.assertEqual(self._latest(), "runs/" + kept[-1])

    def test_what_a_killed_pass_left_behind_is_cleared_and_never_read_as_a_pass(self):
        left = self.state / "runs" / ".tmp-20261030T032000Z"
        left.mkdir(parents=True)
        (left / "decisions.jsonl").write_text("half a file")
        self.assertEqual(ec.published(), [])
        self.assertEqual(self._tick()[0], 0)
        self.assertFalse(left.exists())
        self.assertEqual(ec.published(), ["20261101T032000Z"])

    def test_a_pass_never_overwrites_one_already_published(self):
        self.assertEqual(self._tick()[0], 0)
        self.stamps = iter(["20261101T032000Z"])
        code, _, err = self._tick()
        self.assertEqual(code, 2)
        self.assertIn("already published", err)

    def test_the_scheduled_pass_reaches_no_client_that_can_write(self):
        called: list[str] = []

        def boom(name):
            def fail(*args, **kwargs):
                called.append(name)
                raise AssertionError(f"the pass reached {name}")
            return fail

        with unittest.mock.patch.object(subprocess, "run", boom("subprocess.run")), \
                unittest.mock.patch.object(subprocess, "Popen", boom("subprocess.Popen")), \
                unittest.mock.patch.object(os, "system", boom("os.system")), \
                unittest.mock.patch.object(sqlite3, "connect", boom("sqlite3.connect")), \
                unittest.mock.patch.object(urllib.request, "urlopen", boom("urllib.request.urlopen")):
            self.assertEqual(self._tick()[0], 0)
        self.assertEqual(called, [])

    def test_a_policy_that_is_not_shadow_stops_the_pass_before_any_read(self):
        policy = Path(self._td.name) / "p.json"
        policy.write_text(json.dumps({**POLICY, "mode": "live"}))
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ec._main(["tick", "--policy", str(policy)]), 2)
        self.assertEqual(self.replica.calls, [])
        self.assertFalse(self.state.exists())


class EntryScriptTests(unittest.TestCase):
    """What the timer runs is a file, so it is run as one."""

    SCRIPT = ROOT / "scripts" / "established-claimant.py"

    def _run(self, *argv):
        return subprocess.run([sys.executable, "-I", str(self.SCRIPT), *argv],
                              capture_output=True, text=True, timeout=60, check=False)

    def test_it_loads_as_a_file_and_says_what_it_is(self):
        done = self._run("--help")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("established-claimant.timer", done.stdout)

    def test_an_argument_it_does_not_know_runs_nothing(self):
        done = self._run("--apply")
        self.assertEqual(done.returncode, 2)
        self.assertIn("unknown argument", done.stderr)

    def test_with_no_argument_it_runs_the_scheduled_pass(self):
        text = self.SCRIPT.read_text()
        namespace: dict = {"__name__": "not_main", "__file__": str(self.SCRIPT)}
        exec(compile(text, str(self.SCRIPT), "exec"), namespace)  # noqa: S102 - our own entry script
        seen: list[list[str]] = []
        with unittest.mock.patch.object(ec, "_main", lambda argv: seen.append(argv) or 0), \
                unittest.mock.patch.object(sys, "argv", [str(self.SCRIPT)]):
            namespace["__name__"] = "__main__"
            with self.assertRaises(SystemExit) as stop:
                exec(compile(text, str(self.SCRIPT), "exec"), namespace)  # noqa: S102
        self.assertEqual((stop.exception.code, seen), (0, [["tick"]]))


if __name__ == "__main__":
    unittest.main()
