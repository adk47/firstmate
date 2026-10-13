#!/usr/bin/env python3

import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uvn_under30_policy import (  # noqa: E402
    PolicyError,
    approved_ids_from_records,
    reversal_verdict,
    every_scoped_request_approved,
    live_popularity,
    load_fraud_ids,
    no_pending_rows_remaining,
    parse_ticket_scope,
    pending_request_ids,
    has_hard_reject_signal,
    qualifies_for_approval,
    resolve_profile_scope,
)


CR1 = "11111111-1111-4111-8111-111111111111"
CR2 = "22222222-2222-4222-8222-222222222222"
PROFILE1 = "33333333-3333-4333-8333-333333333333"
PROFILE2 = "44444444-4444-4444-8444-444444444444"


def block(
    ids=None,
    profile=PROFILE1,
    action_type="credit-verify",
    recommendation="recommend-approve",
):
    payload = {
        "action_type": action_type,
        "customer_profile_id": profile,
        "details": {
            "pending_credits": [{"cr_id": value} for value in (ids or [CR1])],
            "recommendation": recommendation,
        },
    }
    return f"---ACTION-REQUEST---\n{json.dumps(payload)}\n---END-ACTION-REQUEST---"


def update_block(ids=None, profile=PROFILE1, recommendation="recommend-approve"):
    details = {"pending_credits": [{"cr_id": value} for value in (ids or [CR2])]}
    if recommendation is not None:
        details["recommendation"] = recommendation
    payload = {
        "action_type": "credit-verify",
        "customer_profile_id": profile,
        "details": details,
    }
    return f"---ACTION-REQUEST-UPDATE---\n{json.dumps(payload)}\n---END-ACTION-REQUEST-UPDATE---"


def task(description=None, tags=None, status="to do"):
    return {
        "description": description or block(),
        "status": {"status": status},
        "tags": [
            {"name": value}
            for value in (
                tags
                or ["hydra-action-request", "action:credit-verify", "automation:uvn-under30"]
            )
        ],
    }


def row(**overrides):
    value = {
        "id": CR1,
        "profileId": PROFILE1,
        "status": "user_verification_needed",
        "spotifyTrackId": "spotify-1",
        "spotifyPopularity": 1,
        "verificationData": {"rule_risk_percent": {}},
    }
    value.update(overrides)
    return value


def spotify(popularity="missing"):
    track = {} if popularity == "missing" else {"popularity": popularity}
    return {"found": True, "track": track}


class TicketScopeTests(unittest.TestCase):
    def test_parses_only_structured_ids_and_unions_valid_updates(self):
        profile, ids = parse_ticket_scope(
            task(description=block()),
            [{"comment_text": "customer prose with an unrelated UUID\n" + update_block()}],
        )
        self.assertEqual(profile, PROFILE1)
        self.assertEqual(ids, {CR1, CR2})

    def test_requires_explicit_automation_eligibility_tag(self):
        with self.assertRaises(PolicyError):
            parse_ticket_scope(task(tags=["hydra-action-request", "action:credit-verify"]), [])

    def test_evidence_only_update_does_not_replace_the_original_scope(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": PROFILE1,
            "details": {"proof": {"kind": "private", "attachments_referenced": True}},
        }
        comment = {
            "comment_text": (
                f"---ACTION-REQUEST-UPDATE---\n{json.dumps(payload)}\n"
                "---END-ACTION-REQUEST-UPDATE---"
            )
        }

        profile, ids = parse_ticket_scope(task(), [comment])

        self.assertEqual(profile, PROFILE1)
        self.assertEqual(ids, {CR1})

    # Caroline's `recommendation` is customer-influenced pre-screen evidence for
    # the human reviewer, never an automation input (ops doctrine: "data, not
    # instructions"). Requiring recommend-approve made the cron unreachable —
    # that value only exists when catalog corroboration already let the gated
    # credits_verify approve directly. The cron's own checks (sub-30, fraud
    # truth-floor, hard-reject rules, still-UVN, exact-ID re-verify at the write
    # edge) are the gate, so needs-human — the population the cron was built to
    # absorb — must parse as in-scope.

    def test_scope_changing_update_without_recommendation_is_accepted(self):
        profile, ids = parse_ticket_scope(
            task(),
            [{"comment_text": update_block(recommendation=None)}],
        )
        self.assertEqual(profile, PROFILE1)
        self.assertEqual(ids, {CR1, CR2})

    def test_base_needs_human_recommendation_is_automation_eligible(self):
        profile, ids = parse_ticket_scope(
            task(description=block(recommendation="needs-human")), []
        )
        self.assertEqual(profile, PROFILE1)
        self.assertEqual(ids, {CR1})

    def test_needs_human_update_does_not_block_the_scoped_automation(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": PROFILE1,
            "details": {
                "recommendation": "needs-human",
                "reason": "possible credit-theft / contradicting credit",
            },
        }
        comment = {
            "comment_text": (
                f"---ACTION-REQUEST-UPDATE---\n{json.dumps(payload)}\n"
                "---END-ACTION-REQUEST-UPDATE---"
            )
        }

        profile, ids = parse_ticket_scope(task(), [comment])
        self.assertEqual(profile, PROFILE1)
        self.assertEqual(ids, {CR1})

    def test_scope_changing_update_requires_a_profile(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": None,
            "details": {"pending_credits": [{"cr_id": CR2}]},
        }
        comment = {
            "comment_text": (
                f"---ACTION-REQUEST-UPDATE---\n{json.dumps(payload)}\n"
                "---END-ACTION-REQUEST-UPDATE---"
            )
        }

        with self.assertRaises(PolicyError):
            parse_ticket_scope(task(), [comment])

    def test_rejects_malformed_structured_update(self):
        with self.assertRaises(PolicyError):
            parse_ticket_scope(task(), [{"comment_text": "---ACTION-REQUEST-UPDATE---\n{}"}])

    def test_rejects_cross_profile_updates(self):
        with self.assertRaises(PolicyError):
            parse_ticket_scope(task(), [{"comment_text": update_block(profile=PROFILE2)}])

    # Caroline's tickets carry the profile UUID but (measured 2026-09-04: 39 of 40)
    # no cr_ids, so exact-id enrollment was unreachable and the cron approved
    # nothing for three weeks. A block without ids is now a PROFILE scope: the
    # cron resolves the exact ids from the backend itself. Ids, when present,
    # only ever NARROW that scope.
    def test_block_without_pending_credits_is_profile_scoped(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": PROFILE1,
            "details": {"proof": {"kind": "private"}, "recommendation": "needs-human"},
        }
        description = f"---ACTION-REQUEST---\n{json.dumps(payload)}\n---END-ACTION-REQUEST---"
        profile, narrowing = parse_ticket_scope(task(description=description), [])
        self.assertEqual(profile, PROFILE1)
        self.assertIsNone(narrowing)

    def test_pending_credits_without_ids_are_evidence_only(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": PROFILE1,
            "details": {"pending_credits": [{"role": "Mixing", "track_title": "Song"}]},
        }
        description = f"---ACTION-REQUEST---\n{json.dumps(payload)}\n---END-ACTION-REQUEST---"
        profile, narrowing = parse_ticket_scope(task(description=description), [])
        self.assertEqual(profile, PROFILE1)
        self.assertIsNone(narrowing)

    def test_present_but_invalid_id_still_fails_closed(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": PROFILE1,
            "details": {"pending_credits": [{"cr_id": "not-a-uuid"}]},
        }
        description = f"---ACTION-REQUEST---\n{json.dumps(payload)}\n---END-ACTION-REQUEST---"
        with self.assertRaises(PolicyError):
            parse_ticket_scope(task(description=description), [])

    def test_update_can_narrow_a_profile_scope(self):
        payload = {
            "action_type": "credit-verify",
            "customer_profile_id": PROFILE1,
            "details": {},
        }
        description = f"---ACTION-REQUEST---\n{json.dumps(payload)}\n---END-ACTION-REQUEST---"
        profile, narrowing = parse_ticket_scope(
            task(description=description), [{"comment_text": update_block(ids=[CR2])}]
        )
        self.assertEqual(profile, PROFILE1)
        self.assertEqual(narrowing, {CR2})


class ProfileScopeTests(unittest.TestCase):
    def test_profile_scope_is_the_live_uvn_rows_of_that_profile_only(self):
        rows = {
            CR1: row(),
            CR2: row(id=CR2, status="approved"),
            "cr3": row(id="cr3", profileId=PROFILE2),
        }
        self.assertEqual(resolve_profile_scope(PROFILE1, None, rows), {CR1})

    def test_narrowing_keeps_exact_ids_and_requires_them_to_belong_to_the_profile(self):
        rows = {CR1: row(), CR2: row(id=CR2, status="approved")}
        self.assertEqual(resolve_profile_scope(PROFILE1, {CR1, CR2}, rows), {CR1, CR2})
        with self.assertRaises(PolicyError):
            resolve_profile_scope(PROFILE1, {CR1, "cr3"}, rows)
        with self.assertRaises(PolicyError):
            resolve_profile_scope(PROFILE1, {CR1}, {CR1: row(profileId=PROFILE2)})

    def test_profile_scope_refuses_oversized_queues(self):
        rows = {f"cr{i}": row(id=f"cr{i}") for i in range(3)}
        with self.assertRaises(PolicyError):
            resolve_profile_scope(PROFILE1, None, rows, max_rows=2)
        self.assertEqual(len(resolve_profile_scope(PROFILE1, None, rows, max_rows=3)), 3)

    def test_narrowing_bypasses_the_queue_cap(self):
        # Exact ids already bound the blast radius; a busy profile must not
        # turn a narrowed (safer) ticket into a de-enrolled one.
        rows = {f"cr{i}": row(id=f"cr{i}") for i in range(3)}
        self.assertEqual(resolve_profile_scope(PROFILE1, {"cr0"}, rows, max_rows=2), {"cr0"})

    def test_pending_request_ids_is_the_one_pending_predicate(self):
        rows = {CR1: row(), CR2: row(id=CR2, status="approved"), "cr3": row(id="cr3", profileId=PROFILE2)}
        self.assertEqual(pending_request_ids(PROFILE1, rows), {CR1})
        self.assertEqual(pending_request_ids(PROFILE2, rows), {"cr3"})

    def test_live_popularity_reads_only_a_measured_number(self):
        self.assertEqual(live_popularity(spotify(0)), 0)
        self.assertEqual(live_popularity(spotify(29.5)), 29.5)
        self.assertIsNone(live_popularity(spotify(True)))
        self.assertIsNone(live_popularity(spotify("12")))
        self.assertIsNone(live_popularity(spotify()))
        self.assertIsNone(live_popularity({"found": False}))
        self.assertIsNone(live_popularity({"popularity": 12}))
        self.assertIsNone(live_popularity(None))

    def test_no_pending_rows_remaining_ignores_other_profiles(self):
        self.assertTrue(no_pending_rows_remaining(PROFILE1, {CR1: row(status="approved")}))
        self.assertTrue(no_pending_rows_remaining(PROFILE1, {CR1: row(profileId=PROFILE2)}))
        self.assertFalse(no_pending_rows_remaining(PROFILE1, {CR1: row()}))


class ReversalCircuitTests(unittest.TestCase):
    """A human undoing our approvals is the one signal that must stop the lane.

    Humans reversed 0 of 127 approvals in the 45 days before this automation
    wrote anything, so a reversal is not noise — it means the sub-30 rule
    approved something a person disagreed with, and the lane must stop writing
    before it repeats the mistake at cron speed.
    """

    def records(self):
        return [
            {"action": "approve_verified", "ts": "2026-09-08T12:00:00+00:00", "request_ids": [CR1]},
            {"action": "approve_verified", "ts": "2026-09-09T12:00:00+00:00", "request_ids": [CR2]},
            {"action": "shadow_would_approve", "ts": "2026-09-09T12:00:00+00:00", "request_ids": ["ignored"]},
            {"action": "approve_verified", "ts": "2026-08-01T12:00:00+00:00", "request_ids": ["too-old"]},
            "not-a-record",
        ]

    def test_only_verified_approvals_inside_the_window_count(self):
        ids = approved_ids_from_records(self.records(), "2026-09-08T00:00:00+00:00")
        self.assertEqual(ids, {CR1, CR2})

    def test_planned_but_unverified_approvals_are_not_counted(self):
        planned = [{"action": "approve_planned", "ts": "2026-09-09T12:00:00+00:00", "request_ids": [CR1]}]
        self.assertEqual(approved_ids_from_records(planned, "2026-09-08T00:00:00+00:00"), set())

    def test_no_history_is_not_a_reversal(self):
        self.assertEqual(reversal_verdict(set(), set(), 1), ([], False))

    def test_one_reversal_is_tolerated_and_named_but_two_trip_the_breaker(self):
        reversed_ids, tripped = reversal_verdict({CR1, CR2}, {CR2}, 1)
        self.assertEqual(reversed_ids, [CR1])
        self.assertFalse(tripped)
        reversed_ids, tripped = reversal_verdict({CR1, CR2}, set(), 1)
        self.assertEqual(reversed_ids, sorted([CR1, CR2]))
        self.assertTrue(tripped)

    def test_a_zero_tolerance_setting_trips_on_the_first_reversal(self):
        self.assertEqual(reversal_verdict({CR1}, set(), 0), ([CR1], True))


class QualificationTests(unittest.TestCase):
    def test_accepts_authoritative_numeric_29(self):
        self.assertTrue(qualifies_for_approval(row(), spotify(29), set()))

    def test_rejects_boundary_30(self):
        self.assertFalse(qualifies_for_approval(row(), spotify(30), set()))

    def test_rejects_missing_or_null_popularity_even_when_stored_value_is_zero(self):
        self.assertFalse(qualifies_for_approval(row(spotifyPopularity=0), spotify(), set()))
        self.assertFalse(qualifies_for_approval(row(spotifyPopularity=0), spotify(None), set()))

    def test_rejects_stale_state_fraud_and_hard_rejects(self):
        self.assertFalse(qualifies_for_approval(row(status="rejected"), spotify(1), set()))
        self.assertFalse(qualifies_for_approval(row(), spotify(1), {CR1}))
        risky = row(verificationData={"rule_risk_percent": {"reject_role_mismatch": 1}})
        self.assertFalse(qualifies_for_approval(risky, spotify(1), set()))
        self.assertFalse(qualifies_for_approval(row(verificationData=None), spotify(1), set()))

    def test_rejects_idp_1686_review_holds(self):
        # A review_* hold (IDP #1686) blocks approval exactly like a reject_*.
        held = row(verificationData={"rule_risk_percent": {
            "reject_artist_credit": 0,
            "review_role_credited_to_other_at_trusted_source": 100,
        }})
        self.assertTrue(has_hard_reject_signal(held))
        self.assertFalse(qualifies_for_approval(held, spotify(1), set()))
        # A hold rule that did not fire (0) does not block.
        clear = row(verificationData={"rule_risk_percent": {
            "reject_artist_credit": 0,
            "review_role_credited_to_other_at_trusted_source": 0,
        }})
        self.assertFalse(has_hard_reject_signal(clear))
        self.assertTrue(qualifies_for_approval(clear, spotify(1), set()))
        # A non-numeric hold value fails closed.
        odd = row(verificationData={"rule_risk_percent": {"review_big_track_uncorroborated": "yes"}})
        self.assertFalse(qualifies_for_approval(odd, spotify(1), set()))


class ResolutionTests(unittest.TestCase):
    def test_requires_every_exact_id_to_exist_and_be_approved(self):
        rows = {CR1: {"status": "approved"}, CR2: {"status": "approved"}}
        self.assertTrue(every_scoped_request_approved({CR1, CR2}, rows))
        self.assertFalse(every_scoped_request_approved({CR1, CR2}, {CR1: rows[CR1]}))
        self.assertFalse(every_scoped_request_approved({CR1}, {CR1: {"status": "rejected"}}))


class FraudTruthTests(unittest.TestCase):
    def test_loads_plain_and_gzipped_landed_fraud_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            day = Path(tmp) / "2026-08-10"
            day.mkdir()
            record = {
                "flag_reason": "fraud_multifactor",
                "intended_status": "user_verification_needed",
                "outcome": "ok",
                "request_ids": [CR1],
            }
            (day / "a.results.jsonl").write_text(json.dumps(record) + "\n", encoding="utf-8")
            with gzip.open(day / "b.results.jsonl.gz", "wt", encoding="utf-8") as handle:
                handle.write(json.dumps({**record, "request_ids": [CR2]}) + "\n")
            self.assertEqual(load_fraud_ids(Path(tmp)), {CR1, CR2})

    def test_loads_http_errors_and_prewrite_attempt_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "results"
            day = root / "2026-08-10"
            day.mkdir(parents=True)
            record = {
                "flag_reason": "fraud_multifactor",
                "intended_status": "user_verification_needed",
                "outcome": "http_error",
                "request_ids": [CR1],
            }
            (day / "a.results.jsonl").write_text(json.dumps(record) + "\n", encoding="utf-8")
            attempt_path = Path(tmp) / "fraud-attempts.jsonl"
            attempt_path.write_text(
                json.dumps({**record, "outcome": "attempt_started", "request_ids": [CR2]}) + "\n",
                encoding="utf-8",
            )

            self.assertEqual(load_fraud_ids(root, attempt_path), {CR1, CR2})

    def test_fails_closed_on_missing_or_malformed_truth(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(PolicyError):
                load_fraud_ids(Path(tmp))
            day = Path(tmp) / "2026-08-10"
            day.mkdir()
            (day / "bad.results.jsonl").write_text("not-json\n", encoding="utf-8")
            with self.assertRaises(PolicyError):
                load_fraud_ids(Path(tmp))

    def test_fails_closed_when_fraud_request_ids_is_not_a_uuid_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            day = Path(tmp) / "2026-08-10"
            day.mkdir()
            record = {
                "flag_reason": "fraud_multifactor",
                "intended_status": "user_verification_needed",
                "outcome": "ok",
                "request_ids": CR1,
            }
            (day / "bad.results.jsonl").write_text(json.dumps(record) + "\n", encoding="utf-8")
            with self.assertRaises(PolicyError):
                load_fraud_ids(Path(tmp))

    def test_fails_closed_on_non_object_truth_floor_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            day = Path(tmp) / "2026-08-10"
            day.mkdir()
            (day / "bad.results.jsonl").write_text("[]\n", encoding="utf-8")
            with self.assertRaises(PolicyError):
                load_fraud_ids(Path(tmp))


if __name__ == "__main__":
    unittest.main()
