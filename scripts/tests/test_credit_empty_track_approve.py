"""ET1 `empty_track_approve` - the emptiness predicate, pinned case by case.

Run directly (the way PR Validation runs most suites): `python3 scripts/tests/test_credit_empty_track_approve.py`
"""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import empty_track_approve as ET  # noqa: E402

M = ET

TRACK = "8e25c662-dd62-40b1-ae3a-ff2c0b0b1f98"
TRACK2 = "11111111-2222-3333-4444-555555555555"
REQ = "aaaaaaaa-0000-0000-0000-000000000001"
ISRC = "USRC17607839"


def _load_none(users=(), profiles=()):
    from credit_review.watchlist import Watchlist
    return Watchlist(user_ids=frozenset(users), profile_ids=frozenset(profiles), fraud_user_ids=frozenset(),
                     fraud_profile_ids=frozenset(), email_sha256=frozenset(), name_sha256=frozenset(),
                     email_domains=frozenset())


#: A watchlist that was READ and names nobody - the only thing that can stand for "no hit".
EMPTY_WATCH = _load_none()


class ALLOWED:
    """A measured green account: the gate allowed it AND it named the band it graded (a bare allow does not)."""

    allowed = True
    decision = "allow"
    payload = {"band": "green"}
    reasons = ()


class AMBER:
    allowed = True
    decision = "allow"
    payload = {"band": "amber"}
    reasons = ()


class BANDLESS:
    """The gate allowed it and named no band: `account_gate.watch_refusal` reads that as an unmeasured account."""

    allowed = True
    decision = "allow"
    payload = {}
    reasons = ()


class RELEASED_RED:
    allowed = True
    decision = "allow"
    payload = {"band": "released_red"}
    reasons = ()


class GREEN_WATCHED:
    """Green band, but the account carries a watch: still not a green we may approve on."""

    allowed = True
    decision = "allow"
    payload = {"band": "green", "watch": "watch"}
    reasons = ()


class NOTALLOWED:
    allowed = False
    decision = "reject"
    payload = {}
    reasons = ("credit history",)


def allow(_uid):
    return ALLOWED()


def no_hold(_uid):
    return []


def live_track(credits=0, collaborators=0, isrcs=(ISRC,), spotify=(), deleted=False, merged=False):
    return ET.TrackRecord(track_id=TRACK, isrcs=tuple(isrcs), spotify_ids=tuple(spotify), credits=credits,
                          collaborators=collaborators, deleted=deleted, merged=merged)


def facts(status="user_verification_needed", rules=None, roles=("Composer",), is_approved="true", uid=7,
          track_id=TRACK, profile_id="bbbbbbbb-0000-0000-0000-000000000002", deleted=False, verdict="default",
          isrc=ISRC):
    """A request's facts. `rules` builds the validator's measured verdict; `verdict=` overrides it wholesale
    (None = verificationdata we could not read, the fail-closed case)."""
    vd = {"rule_risk_percent": dict(rules or {})} if verdict == "default" else verdict
    return ET.RequestFacts(status=status, user_id=uid, profile_id=profile_id, track_id=track_id,
                           isrc=isrc, roles=None if roles is None else tuple(roles), verdict=vd,
                           is_approved=is_approved, deleted=deleted)


def run(f=None, track=None, watch="empty", gate=allow, hold=no_hold, paid=frozenset({7}), ids=None):
    f = f if f is not None else facts()
    rid = f"{REQ}"
    loaded = EMPTY_WATCH if watch == "empty" else watch
    return ET.evaluate(ids if ids is not None else [rid],
                       {rid: f},
                       {TRACK: live_track() if track is None else track},
                       gate, hold, paid, loaded)


def decision(rows):
    return rows[0].decision if rows else "none"


def code(rows):
    return rows[0].reason_code if rows else "none"


class EmptinessTests(unittest.TestCase):
    """A real catalog track with zero credits is approved; any credit on that track ends it."""

    def test_real_isrc_and_zero_credits_approves(self):
        rows, _ = run()
        self.assertEqual(decision(rows), "approve")

    def test_one_credit_on_the_same_track_never_approves(self):
        rows, _ = run(track=live_track(credits=1, collaborators=1))
        self.assertEqual(decision(rows), "hold")

    def test_one_credit_reason_names_the_count(self):
        rows, _ = run(track=live_track(credits=1, collaborators=1))
        self.assertEqual(code(rows), "track_has_credits")

    def test_a_track_with_fifty_credits_never_approves(self):
        rows, _ = run(track=live_track(credits=50, collaborators=50))
        self.assertEqual(decision(rows), "hold")

    def test_real_spotify_id_and_zero_credits_approves(self):
        rows, _ = run(track=live_track(isrcs=(), spotify=("3n3Ppam7vgaVa1iaRUc9Lp",)))
        self.assertEqual(decision(rows), "approve")

    def test_no_identifier_is_held(self):
        rows, _ = run(track=live_track(isrcs=(), spotify=()))
        self.assertEqual(code(rows), "track_identifier_placeholder")

    def test_placeholder_isrc_is_held(self):
        rows, _ = run(track=live_track(isrcs=("000000000000",)))
        self.assertEqual(code(rows), "track_identifier_placeholder")

    def test_short_isrc_is_held(self):
        rows, _ = run(track=live_track(isrcs=("USRC17",)))
        self.assertEqual(code(rows), "track_identifier_placeholder")

    def test_a_missing_track_record_is_held(self):
        rows = ET.evaluate([REQ], {REQ: facts()}, {}, allow, no_hold, frozenset({7}))[0]
        self.assertEqual(code(rows), "track_unread")

    def test_a_track_document_without_a_credit_list_is_held(self):
        rows, _ = run(track=ET.TrackRecord(track_id=TRACK, isrcs=(ISRC,), credits=None))
        self.assertEqual(code(rows), "track_credits_unknown")

    def test_a_deleted_track_is_held(self):
        rows, _ = run(track=live_track(deleted=True))
        self.assertEqual(code(rows), "track_deleted")

    def test_a_merged_track_is_held(self):
        rows, _ = run(track=live_track(merged=True))
        self.assertEqual(code(rows), "track_merged")

    def test_a_collaborator_count_above_the_empty_credit_list_is_held(self):
        rows, _ = run(track=live_track(credits=0, collaborators=3))
        self.assertEqual(code(rows), "track_has_credits")


class WhereTheCreditsAreReadTests(unittest.TestCase):
    """Condition 2 is core's own track document. The analytics replicas look like they answer it and do not."""

    def test_a_track_document_with_five_credits_is_never_empty(self):
        doc = {"id": TRACK, "isrcs": ["QT66C2615710"], "credits": [{"profileSourceCount": 1}] * 5}
        self.assertEqual(ET.empty_track(ET.track_record(doc, TRACK)), "track_has_credits:5")

    def test_the_credit_count_comes_from_the_document_not_a_replica(self):
        doc = {"id": TRACK, "isrcs": ["QT66C2615710"], "credits": []}
        self.assertEqual(ET.track_record(doc, TRACK).credits, 0)

    def test_a_document_with_no_credit_list_is_unknown_not_empty(self):
        doc = {"id": TRACK, "isrcs": ["QT66C2615710"]}
        self.assertIsNone(ET.track_record(doc, TRACK).credits)
        self.assertEqual(ET.empty_track(ET.track_record(doc, TRACK)), "track_credits_unknown")

    def test_the_replica_counts_are_not_a_decision_input(self):
        source = (ROOT / "scripts" / "credit_review" / "empty_track_approve.py").read_text()
        start = source.index("def evaluate(")
        decide = source[start:source.index("\n# ──", start)] + source[start:source.index("\ndef ", start + 1)]
        self.assertNotIn("track_credit_counts", decide)
        self.assertNotIn("profile_track", decide)
        self.assertNotIn("profile_v3_tracks", decide)

    def test_the_replica_helper_says_what_it_is(self):
        doc = ET.track_credit_counts.__doc__ or ""
        self.assertIn("NOT the track's credits", doc)

    def test_a_bare_isrc_string_is_one_identifier(self):
        self.assertEqual(ET.real_isrc("ae-a2m-2605231"), "AEA2M2605231")

    def test_a_bare_placeholder_string_is_no_identifier(self):
        self.assertIsNone(ET.real_isrc("000000000000"))


class FailClosedTests(unittest.TestCase):
    """An input we could not read is NOT an input that said no. Each of these was a fail-open in review."""

    def test_a_null_roles_column_never_approves(self):
        # the reviewer's finding: coalesce(cast(credits as varchar), '') turned a NULL roles column into '' ->
        # _pg_array('') -> () -> "no role conflict" -> a shadow approve on an otherwise eligible row.
        rows, _ = run(facts(roles=None))
        self.assertEqual(decision(rows), "hold")
        self.assertEqual(code(rows), "roles_unread")

    def test_a_malformed_roles_column_never_approves(self):
        # `{Composer, "Primary Artist"}` parses; `garbled` is not PostgreSQL array syntax at all, so the roles we
        # did not read must not read as "this claim names no conflicting role" (QA review, 2026-11-16).
        self.assertIsNone(ET._pg_array("garbled"))
        self.assertEqual(ET._pg_array("{Composer}"), ("Composer",))
        self.assertEqual(ET._pg_array("{}"), ())
        rows, _ = run(f=facts(roles=None, rules={}), track=live_track())
        self.assertEqual(code(rows), "roles_unread")

    def test_the_scan_to_decision_path_holds_a_malformed_roles_row(self):
        rec = ["aaaaaaaa-0000-0000-0000-000000000001", "user_verification_needed", "7",
               "bbbbbbbb-0000-0000-0000-000000000002", TRACK, ISRC, "garbled",
               json.dumps({"rule_risk_percent": {}}), "true", "false"]
        parsed = ET._rows_to_facts([rec])
        self.assertIsNone(list(parsed.values())[0].roles)
        rows, _ = ET.evaluate(list(parsed), parsed, {TRACK: live_track()}, allow, no_hold, None, EMPTY_WATCH)
        self.assertEqual(rows[0].reason_code, "roles_unread")

    def test_a_null_roles_column_is_held_by_the_scan_to_decision_path(self):
        # the same row, read the way the rule actually reads it: a replica record with an empty credits column.
        rec = [REQ, "user_verification_needed", "7", "bbbbbbbb-0000-0000-0000-000000000002", TRACK, ISRC,
               "", '{"rule_risk_percent": {}}', "true", "false"]
        got = ET._rows_to_facts([rec])
        self.assertIsNone(got[REQ].roles)
        rows, _ = run(got[REQ])
        self.assertEqual(decision(rows), "hold")
        self.assertEqual(code(rows), "roles_unread")

    def test_an_empty_roles_array_is_a_measured_answer(self):
        # '{}' is a claim that names no roles, which is a fact, not an unread column: the validator's rules decide.
        rec = [REQ, "user_verification_needed", "7", "bbbbbbbb-0000-0000-0000-000000000002", TRACK, ISRC,
               "{}", '{"rule_risk_percent": {}}', "true", "false"]
        got = ET._rows_to_facts([rec])
        self.assertEqual(got[REQ].roles, ())
        rows, _ = run(got[REQ])
        self.assertEqual(decision(rows), "approve")

    def test_an_unreadable_watchlist_never_approves(self):
        rows, _ = run(watch=None)
        self.assertEqual(decision(rows), "hold")
        self.assertEqual(code(rows), "watchlist_unread")

    def test_an_unreadable_watchlist_holds_every_row_not_only_some(self):
        rows, _ = run(watch=None)
        self.assertEqual(len(rows), 1)
        self.assertEqual([r.decision for r in rows], ["hold"])

    def test_local_clean_selects_nothing_when_the_watchlist_is_unreadable(self):
        self.assertEqual(ET.local_clean({REQ: facts()}, None), {})

    def test_a_missing_verdict_never_approves(self):
        rows, _ = run(f=facts(verdict=None))
        self.assertEqual(decision(rows), "hold")
        self.assertEqual(code(rows), "validator_rules_unread")

    def test_a_malformed_rules_map_never_approves(self):
        rows, _ = run(f=facts(verdict={"rule_risk_percent": "not a map"}))
        self.assertEqual(code(rows), "validator_rules_unread")

    def test_a_verdict_that_is_not_an_object_never_approves(self):
        rows, _ = run(f=facts(verdict=["reject_artist_credit"]))
        self.assertEqual(code(rows), "validator_rules_unread")

    def test_a_rule_errors_hold_on_error_never_approves(self):
        rows, _ = run(f=facts(verdict={"rule_risk_percent": {}, "rule_errors": {"_hold_on_error": 1}}))
        self.assertEqual(code(rows), "validator_conflict")

    def test_an_unparseable_verdict_column_is_not_read_as_no_rules(self):
        self.assertIsNone(ET._verdict("not json"))
        self.assertIsNone(ET._verdict(""))
        self.assertEqual(ET._verdict('{"rule_risk_percent": {}}'), {"rule_risk_percent": {}})

    def test_local_clean_keeps_a_request_that_carries_no_isrc(self):
        # condition 1 lets core's track document supply the Spotify id, so the prefilter must not drop it first
        kept = ET.local_clean({REQ: facts(isrc=None)}, EMPTY_WATCH)
        self.assertEqual(list(kept), [REQ])

    def test_a_spotify_only_empty_track_is_found_and_approved(self):
        track = live_track(isrcs=(), spotify=("3n3Ppam7vgaVa1iaRUc9Lp",))
        self.assertEqual(ET.empty_track(track), "")
        rows, _ = run(f=facts(isrc=None), track=track)
        self.assertEqual(decision(rows), "approve")
        self.assertEqual(rows[0].evidence["track_identifier"], "3n3Ppam7vgaVa1iaRUc9Lp")


class ClaimantTests(unittest.TestCase):
    """The other three conditions, each of which holds a row even on a genuinely empty track."""

    def test_watchlisted_user_is_held_even_at_zero_credits(self):
        rows, _ = run(watch=_watch())
        self.assertEqual(decision(rows), "hold")

    def test_watchlisted_user_reason_is_the_watchlist(self):
        rows, _ = run(watch=_watch())
        self.assertEqual(code(rows), "watchlist_user")

    def test_watchlisted_profile_is_held(self):
        rows, _ = run(watch=_watch(users=(), profiles=("bbbbbbbb-0000-0000-0000-000000000002",)))
        self.assertEqual(code(rows), "watchlist_profile")

    def test_r8_account_hold_is_held_even_at_zero_credits(self):
        rows, _ = run(hold=lambda uid: ["R8"])
        self.assertEqual(decision(rows), "hold")

    def test_r8_account_hold_reason_is_the_hold(self):
        rows, _ = run(hold=lambda uid: ["R8"])
        self.assertEqual(code(rows), "R8_account_hold")

    def test_an_unreadable_account_hold_is_held(self):
        def boom(_uid):
            raise RuntimeError("ledger unreadable")
        rows, _ = run(hold=boom)
        self.assertEqual(code(rows), "account_hold_unknown")

    def test_a_rejected_account_gate_is_held(self):
        rows, _ = run(gate=lambda uid: NOTALLOWED)
        self.assertEqual(code(rows), "account_gate_reject")

    def test_an_amber_account_gate_is_held(self):
        # an allow is not a green: the gate's own `watch_refusal` names the amber band, and an amber account is a
        # fraud watch, whatever else is true of the request.
        rows, _ = run(gate=lambda uid: AMBER)
        self.assertEqual(code(rows), "account_not_green")

    def test_an_allow_that_names_no_band_is_held(self):
        rows, _ = run(gate=lambda uid: BANDLESS)
        self.assertEqual(code(rows), "account_not_green")

    def test_a_released_red_account_is_held(self):
        rows, _ = run(gate=lambda uid: RELEASED_RED)
        self.assertEqual(code(rows), "account_not_green")

    def test_a_green_account_under_a_watch_is_held(self):
        rows, _ = run(gate=lambda uid: GREEN_WATCHED)
        self.assertEqual(code(rows), "account_not_green")

    def test_a_measured_green_account_is_not_held_by_the_gate(self):
        rows, _ = run(gate=lambda uid: ALLOWED)
        self.assertEqual(code(rows), "")

    def test_an_unreadable_account_gate_is_held(self):
        def boom(_uid):
            raise RuntimeError("gate down")
        rows, _ = run(gate=boom, ids=[REQ])
        self.assertEqual(code(rows), "account_gate_unknown")

    def test_a_reject_rule_holds_at_zero_credits(self):
        rows, _ = run(f=facts(rules={"reject_artist_credit": 100.0}))
        self.assertEqual(code(rows), "reject_rule")

    def test_a_review_hold_at_thirty_holds_at_zero_credits(self):
        rows, _ = run(f=facts(rules={"review_profile_velocity_volume": 30.0}))
        self.assertEqual(code(rows), "review_hold")

    def test_a_review_rule_below_the_hold_threshold_does_not_hold(self):
        rows, _ = run(f=facts(rules={"review_profile_velocity_volume": 10.0}))
        self.assertEqual(decision(rows), "approve")

    def test_the_one_person_role_rule_holds_at_the_hold_threshold(self):
        rows, _ = run(f=facts(roles=("Mixing Engineer",),
                              rules={"review_role_credited_to_other_at_trusted_source": 30.0}))
        self.assertEqual(code(rows), "review_hold")
        self.assertIn("review_role_credited_to_other_at_trusted_source", rows[0].reason)

    def test_the_one_person_role_rule_holds_at_one_hundred(self):
        rows, _ = run(f=facts(roles=("Mixing Engineer",),
                              rules={"review_role_credited_to_other_at_trusted_source": 100.0}))
        self.assertEqual(decision(rows), "hold")

    def test_an_organization_role_holds(self):
        rows, _ = run(f=facts(roles=("Record Label",)))
        self.assertEqual(code(rows), "organization_role")

    def test_a_closed_request_is_skipped_not_decided(self):
        rows, skipped = run(f=facts(status="approved"))
        self.assertEqual(rows, [])
        self.assertEqual(sum(skipped.values()), 1)

    def test_a_deleted_request_is_skipped_not_decided(self):
        rows, skipped = run(f=facts(deleted=True))
        self.assertEqual(rows, [])
        self.assertEqual(sum(skipped.values()), 1)

    def test_an_unverified_request_is_in_scope(self):
        rows, _ = run(f=facts(status="unverified"))
        self.assertEqual(decision(rows), "approve")

    def test_approves_sort_before_holds_and_paid_first(self):
        f_a, f_b = facts(uid=8, track_id=TRACK), facts(uid=7, track_id=TRACK2)
        other = f"bbbbbbbb-0000-0000-0000-00000000000{'3'}"
        rows, _ = ET.evaluate([REQ, other], {REQ: f_a, other: f_b},
                              {TRACK: live_track(), TRACK2: live_track(credits=4)},
                              allow, no_hold, frozenset({8}), EMPTY_WATCH)
        self.assertEqual([r.decision for r in rows], ["approve", "hold"])

    def test_a_gate_is_read_once_per_user(self):
        calls = []

        def counted(uid):
            calls.append(uid)
            return ALLOWED()
        other = "bbbbbbbb-0000-0000-0000-000000000003"
        ET.evaluate([REQ, other], {REQ: facts(), other: facts()}, {TRACK: live_track()}, counted, no_hold,
                    frozenset(), EMPTY_WATCH)
        self.assertEqual(len(calls), 1)


def _watch(users=(7,), profiles=()):
    from credit_review.watchlist import Watchlist
    return Watchlist(user_ids=frozenset(users), profile_ids=frozenset(profiles), fraud_user_ids=frozenset(),
                     fraud_profile_ids=frozenset(), email_sha256=frozenset(), name_sha256=frozenset(),
                     email_domains=frozenset())


class RefusalTests(unittest.TestCase):
    """Nothing arms. The policy switch is one stop; the absent writer is the other."""

    def test_a_policy_that_turns_the_rule_on_still_refuses_for_want_of_a_writer(self):
        why = ET.apply_refusal({"apply_enabled": True, "approved_by": "fable", "approval_ref": "GO-1"}, ())
        self.assertEqual(why, ET.NO_WRITER)

    def test_the_shipped_policy_is_off(self):
        pol = ET.policy(str(ROOT / "policies" / "credit-empty-track-approve.json"))
        self.assertIs(pol.get("apply_enabled"), False)

    def test_the_shipped_policy_has_no_approval_on_file(self):
        pol = ET.policy(str(ROOT / "policies" / "credit-empty-track-approve.json"))
        self.assertFalse(pol.get("approved_by"))
        self.assertFalse(pol.get("approval_ref"))

    def test_the_shipped_policy_names_this_rule(self):
        pol = ET.policy(str(ROOT / "policies" / "credit-empty-track-approve.json"))
        self.assertEqual(pol.get("rule"), ET.RULE_ID)

    def test_a_kill_file_refuses(self):
        with tempfile.NamedTemporaryFile() as fh:
            self.assertIn("kill file", ET.apply_refusal({"apply_enabled": True, "approved_by": "x",
                                                         "approval_ref": "y"}, (fh.name,)))

    def test_no_writer_predicate_exists_in_this_module(self):
        self.assertFalse([n for n in dir(ET) if n.startswith("apply_") and n != "apply_refusal"])


class LedgerTests(unittest.TestCase):
    """This rule records in its OWN table, and never in the decider's `decisions`."""

    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.now = datetime(2026, 11, 16, 3, 0, tzinfo=timezone.utc)

    def test_a_shadow_run_records_its_rows_in_its_own_table(self):
        rows, _ = run()
        out = ET.record(self.db, "run-1", "shadow", rows, self.now)
        self.assertEqual(out["approve"], 1)

    def test_it_never_writes_the_decider_table(self):
        ET.record(self.db, "run-1", "shadow", run()[0], self.now)
        tables = {r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertIn("empty_track_decisions", tables)

    def test_the_decider_table_is_not_created(self):
        ET.record(self.db, "run-1", "shadow", run()[0], self.now)
        tables = {r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertNotIn("decisions", tables)

    def test_a_later_run_decides_the_request_again(self):
        # A run never records the same request twice, but a LATER run must be able to answer again: a stale approve
        # that a credit has since contradicted must not be able to stand (QA review, 2026-11-16).
        rows, _ = run()
        ET.record(self.db, "run-1", "shadow", rows, self.now)
        out = ET.record(self.db, "run-2", "shadow", rows, self.now)
        self.assertEqual(out["duplicate"], 0)
        self.assertEqual(out["approve"], 1)

    def test_the_same_run_does_not_record_a_request_twice(self):
        rows, _ = run()
        first, _ = run()
        ET.record(self.db, "run-1", "shadow", rows, self.now)
        out = ET.record(self.db, "run-1", "shadow", first, self.now)
        self.assertEqual(out["duplicate"], 1)
        self.assertEqual(out["approve"], 0)

    def test_a_hold_records_its_reason_code(self):
        out = ET.record(self.db, "run-1", "shadow", run(track=live_track(credits=2))[0], self.now)
        self.assertEqual(out["hold"], {"track_has_credits": 1})

    def test_the_row_carries_its_conditions(self):
        ET.record(self.db, "run-1", "shadow", run()[0], self.now)
        ev = json.loads(self.db.execute("SELECT evidence_json FROM empty_track_decisions").fetchone()[0])
        self.assertEqual(ev["conditions"], list(ET.CONDITIONS))
        self.assertEqual(ev["track_credits"], 0)


class DocumentReadTests(unittest.TestCase):
    """The admin track document, as core returns it."""

    def test_the_live_shape_reads_as_an_empty_track(self):
        doc = {"id": TRACK, "title": "x", "isrcs": [ISRC], "spotifyIds": ["3n3Ppam7vgaVa1iaRUc9Lp"],
               "collaboratorsCount": 0, "credits": [], "merged": None, "deleted": None}
        self.assertEqual(ET.empty_track(ET.track_record(doc, TRACK)), "")

    def test_a_document_with_credits_reads_as_credited(self):
        doc = {"id": TRACK, "isrcs": [ISRC], "credits": [{"child": "c"}, {"child": "d"}], "collaboratorsCount": 2}
        self.assertEqual(ET.empty_track(ET.track_record(doc, TRACK)), "track_has_credits:2")

    def test_an_empty_document_is_not_an_empty_track(self):
        with self.assertRaises(ValueError):
            ET.track_record({}, TRACK)

    def test_a_document_for_another_track_is_a_moved_track_hold(self):
        # core redirects a merged-away track id to its survivor: the request points at an id that no longer exists,
        # so an empty credit list here belongs to the WRONG id and is a hold, never an approval.
        doc = {"id": TRACK2, "isrcs": [ISRC], "credits": [], "collaboratorsCount": 0}
        rec = ET.track_record(doc, TRACK)
        self.assertEqual(rec.moved_to, TRACK2)
        self.assertEqual(ET.empty_track(rec), f"track_moved:{TRACK2}")

    def test_a_document_for_its_own_track_is_not_moved(self):
        doc = {"id": TRACK, "isrcs": [ISRC], "credits": [], "collaboratorsCount": 0}
        self.assertEqual(ET.track_record(doc, TRACK).moved_to, "")
        self.assertEqual(ET.empty_track(ET.track_record(doc, TRACK)), "")

    def test_a_non_object_document_is_refused(self):
        with self.assertRaises(ValueError):
            ET.track_record([], TRACK)


if __name__ == "__main__":
    unittest.main()
