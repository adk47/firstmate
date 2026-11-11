#!/usr/bin/env python3
"""The approve anchor is verified against a source the caller does not control.

Before this, ``is_scale_drain_approval`` accepted a caller-supplied digest on trust: any
caller who could invoke the wrapper could approve an arbitrary UUID by writing a
well-formed ``drain-signal:...`` string. These tests pin the two verifications that make
the digest a claim the API or the proof store has to confirm.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
import functools
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from credit_review import verify_anchor as va  # noqa: E402

TARGET = "11111111-1111-4111-8111-111111111111"
ANCHOR = "22222222-2222-4222-8222-222222222222"
PROFILE = "33333333-3333-4333-8333-333333333333"
PROOF = "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f"
#: The role ``request()`` claims by default, and that role's claim key in the proof store.
ROLE = "Mixing Engineer"
CLAIM = f"{TARGET}#{ROLE}"
BOTH = ("Composer", "Producer")


def request(rid, *, status="user_verification_needed", user="u1", track="t1",
            roles=("Mixing Engineer",)):
    return {"id": rid, "status": status, "userId": user, "trackId": track,
            "credits": list(roles), "profileId": PROFILE}


class FakeAdmin:
    """One GET for the profile, exactly as the real verifier issues it."""

    def __init__(self, items):
        self.items = items
        self.calls = []

    def get(self, path, params=None):
        self.calls.append((path, dict(params or {})))
        return {"items": self.items}


class PrecedentTests(unittest.TestCase):
    def _verify(self, items, **kw):
        admin = FakeAdmin(items)
        va.verify_precedent(admin, kw.pop("request_id", TARGET), kw.pop("anchor", ANCHOR),
                            kw.pop("profile", PROFILE))
        return admin

    def test_an_approved_anchor_for_the_same_claim_verifies(self):
        admin = self._verify([request(TARGET), request(ANCHOR, status="approved")])
        # ONE GET for the whole profile, not one per request
        self.assertEqual(len(admin.calls), 1)
        self.assertEqual(admin.calls[0][1]["profilesIds"], PROFILE)

    def test_an_unapproved_anchor_is_refused(self):
        for status in ("unverified", "user_verification_needed", "rejected", ""):
            with self.subTest(status=status):
                with self.assertRaises(va.Refused):
                    self._verify([request(TARGET), request(ANCHOR, status=status)])

    def test_an_anchor_for_a_different_claimant_is_refused(self):
        """The class-level match that let one account approve another (hydra#1883)."""
        with self.assertRaises(va.Refused) as ctx:
            self._verify([request(TARGET), request(ANCHOR, status="approved", user="u2")])
        self.assertIn("claimant", str(ctx.exception))

    def test_an_anchor_for_a_different_track_is_refused(self):
        with self.assertRaises(va.Refused) as ctx:
            self._verify([request(TARGET), request(ANCHOR, status="approved", track="t2")])
        self.assertIn("track", str(ctx.exception))

    def test_an_anchor_for_different_roles_is_refused(self):
        with self.assertRaises(va.Refused) as ctx:
            self._verify([request(TARGET),
                          request(ANCHOR, status="approved", roles=("Mastering Engineer",))])
        self.assertIn("roles", str(ctx.exception))

    def test_role_order_does_not_matter(self):
        self._verify([request(TARGET, roles=("A", "B")),
                      request(ANCHOR, status="approved", roles=("B", "A"))])

    def test_an_anchor_not_on_the_profile_is_refused(self):
        with self.assertRaises(va.Refused):
            self._verify([request(TARGET)])

    def test_a_target_not_on_the_profile_is_refused(self):
        """A caller who lies about the profile id gets nothing: the target is not there."""
        with self.assertRaises(va.Refused) as ctx:
            self._verify([request(ANCHOR, status="approved")])
        self.assertIn("not on profile", str(ctx.exception))

    def test_an_already_decided_target_is_refused(self):
        """The gate never re-writes a decided request, whichever way it was decided. The
        two ways are told apart (``AlreadyWritten`` is the one a crashed write of our own
        looks like), and BOTH are refusals."""
        with self.assertRaises(va.Refused) as ctx:
            self._verify([request(TARGET, status="approved"),
                          request(ANCHOR, status="approved")])
        self.assertIsInstance(ctx.exception, va.AlreadyWritten)
        self.assertIn("already approved", str(ctx.exception))
        with self.assertRaises(va.Refused) as ctx:
            self._verify([request(TARGET, status="rejected"),
                          request(ANCHOR, status="approved")])
        self.assertNotIsInstance(ctx.exception, va.AlreadyWritten)
        self.assertIn("not pending", str(ctx.exception))

    def test_a_duplicate_close_of_an_already_rejected_target_is_already_written(self):
        """For a close, the status the write sets is ``rejected`` - so that is the one
        that reads as 'already written', and ``approved`` is the one that does not."""
        with self.assertRaises(va.AlreadyWritten):
            va.verify_duplicate(FakeAdmin([request(TARGET, status="rejected"),
                                           request(ANCHOR, status="approved")]),
                                TARGET, ANCHOR, PROFILE)
        with self.assertRaises(va.Refused) as ctx:
            va.verify_duplicate(FakeAdmin([request(TARGET, status="approved"),
                                           request(ANCHOR, status="approved")]),
                                TARGET, ANCHOR, PROFILE)
        self.assertNotIsInstance(ctx.exception, va.AlreadyWritten)

    def test_a_missing_profile_id_is_refused(self):
        with self.assertRaises(va.Refused):
            va.verify_precedent(FakeAdmin([]), TARGET, ANCHOR, "")

    def test_an_unreadable_list_is_unavailable_not_a_pass(self):
        class Broken:
            def get(self, path, params=None):
                return {"nope": True}
        with self.assertRaises(va.Unavailable):
            va.verify_precedent(Broken(), TARGET, ANCHOR, PROFILE)


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.store = str(Path(self.td.name) / "proof.sqlite")
        db = sqlite3.connect(self.store)
        db.executescript("""
            CREATE TABLE verdicts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              proof_id TEXT NOT NULL, analyzer_version TEXT NOT NULL,
              contact_h TEXT NOT NULL, track_key TEXT NOT NULL, verdict TEXT NOT NULL,
              reasons_json TEXT, context_json TEXT, created_at TEXT NOT NULL,
              request_id TEXT NOT NULL DEFAULT '');
        """)
        db.commit()
        db.close()

    def tearDown(self):
        self.td.cleanup()

    def _vp(self, request_id=TARGET, roles=(ROLE,), store=None):
        """The store check, against the roles the live request claims."""
        va.verify_proof(request_id, PROOF, store or self.store, list(roles))

    def _add(self, verdict, request_id=CLAIM, created_at="2026-11-01T00:00:00Z", proof=PROOF):
        db = sqlite3.connect(self.store)
        db.execute("INSERT INTO verdicts (proof_id, analyzer_version, contact_h, track_key,"
                   " verdict, created_at, request_id) VALUES (?,?,?,?,?,?,?)",
                   (proof, "v1", "h", "k", verdict, created_at, request_id))
        db.commit()
        db.close()

    def test_a_genuine_verdict_for_this_request_verifies(self):
        self._add("GENUINE")
        self._vp()

    def test_a_soft_verdict_is_refused(self):
        for verdict in ("PLAUSIBLE", "UNDETERMINED", "INCONCLUSIVE", ""):
            with self.subTest(verdict=verdict):
                db = sqlite3.connect(self.store)
                db.execute("DELETE FROM verdicts")
                db.commit()
                db.close()
                self._add(verdict)
                with self.assertRaises(va.Refused):
                    self._vp()

    def test_the_newest_verdict_wins_even_when_it_is_soft(self):
        """A newer PLAUSIBLE must clear an older GENUINE (hydra#1883 review)."""
        self._add("GENUINE", created_at="2026-11-01T00:00:00Z")
        self._add("PLAUSIBLE", created_at="2026-11-02T00:00:00Z")
        with self.assertRaises(va.Refused):
            self._vp()

    def test_a_verdict_for_another_request_is_refused(self):
        """The verdict is looked up by REQUEST, so another request's proof proves nothing."""
        self._add("GENUINE", request_id="44444444-4444-4444-8444-444444444444")
        with self.assertRaises(va.Refused) as ctx:
            self._vp()
        self.assertIn("no verdict recorded for request", str(ctx.exception))

    def test_an_unbound_verdict_is_refused(self):
        """QA review 2: the real schema defaults request_id to '', so an old GENUINE row
        with no bound request used to verify ANY pending target. It must not."""
        self._add("GENUINE", request_id="")
        with self.assertRaises(va.Refused):
            self._vp()

    def test_a_newer_verdict_for_a_different_proof_is_refused(self):
        """QA review 2: a newer PLAUSIBLE for another proof must not be bypassed by
        anchoring an older GENUINE proof id."""
        self._add("GENUINE", created_at="2026-11-01T00:00:00Z")
        db = sqlite3.connect(self.store)
        db.execute("INSERT INTO verdicts (proof_id, analyzer_version, contact_h, track_key,"
                   " verdict, created_at, request_id) VALUES (?,?,?,?,?,?,?)",
                   ("b" * 64, "v1", "h", "k", "PLAUSIBLE", "2026-11-02T00:00:00Z", CLAIM))
        db.commit()
        db.close()
        with self.assertRaises(va.Refused) as ctx:
            self._vp()
        self.assertIn("newest verdict for claim", str(ctx.exception))

    def test_an_unknown_proof_is_refused(self):
        with self.assertRaises(va.Refused):
            self._vp()

    # ── the store's real key: one verdict per CLAIM, "<request>#<Role>" ──────
    def test_claim_keyed_verdicts_for_this_request_verify(self):
        """Every bound row in production is keyed ``<request uuid>#<Role>`` and none by
        the bare request id, so the bare lookup refused every proof approve there was."""
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        self._add("VERIFIED", request_id=f"{TARGET}#Producer")
        self._vp(roles=BOTH)

    def test_one_soft_claim_refuses_the_whole_request(self):
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        self._add("SUSPECT", request_id=f"{TARGET}#Producer")
        with self.assertRaises(va.Refused) as ctx:
            self._vp(roles=BOTH)
        self.assertIn(f"claim {TARGET}#Producer", str(ctx.exception))
        self.assertIn("not an approval", str(ctx.exception))

    def test_a_claim_approved_on_another_proof_refuses_the_request(self):
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        self._add("GENUINE", request_id=f"{TARGET}#Producer", proof="b" * 64)
        with self.assertRaises(va.Refused) as ctx:
            self._vp(roles=BOTH)
        self.assertIn("not the anchored", str(ctx.exception))

    def test_the_newest_verdict_wins_per_claim(self):
        self._add("GENUINE", request_id=f"{TARGET}#Composer", created_at="2026-11-01T00:00:00Z")
        self._add("GENUINE", request_id=f"{TARGET}#Producer", created_at="2026-11-01T00:00:00Z")
        self._vp(roles=BOTH)
        self._add("PLAUSIBLE", request_id=f"{TARGET}#Producer", created_at="2026-11-02T00:00:00Z")
        with self.assertRaises(va.Refused):
            self._vp(roles=BOTH)
        # and a newer approval of that claim restores it
        self._add("GENUINE", request_id=f"{TARGET}#Producer", created_at="2026-11-03T00:00:00Z")
        self._vp(roles=BOTH)

    def test_another_requests_claims_are_not_read(self):
        """The match is the id and then ``#``: an id that merely starts the same, a
        different request, and a pattern character in the id all find nothing."""
        other = "44444444-4444-4444-8444-444444444444"
        self._add("GENUINE", request_id=f"{other}#Composer")
        self._add("GENUINE", request_id=f"{TARGET}0#Composer")
        self._add("GENUINE", request_id=f"x{TARGET}#Composer")
        for asked in (TARGET, TARGET[:-1] + "_", "%", TARGET[:8]):
            with self.subTest(asked=asked):
                with self.assertRaises(va.Refused) as ctx:
                    self._vp(asked, roles=("Composer",))
                self.assertIn("no verdict recorded", str(ctx.exception))

    def test_an_empty_request_id_matches_nothing(self):
        self._add("GENUINE", request_id="#Composer")
        self._add("GENUINE", request_id="")
        with self.assertRaises(va.Refused):
            self._vp("")

    def test_a_missing_store_is_unavailable_not_a_pass(self):
        with self.assertRaises(va.Unavailable):
            self._vp(store=str(Path(self.td.name) / "absent.sqlite"))

    # ── coverage: the store says what it holds; the LIVE request says what is claimed ──
    def test_a_claimed_role_with_no_verdict_on_file_refuses_the_request(self):
        """QA review 6 of hydra#1883. Composer+Producer, one GENUINE Composer verdict and
        no Producer row at all: nothing on file refuses, and the write approves BOTH."""
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        with self.assertRaises(va.Refused) as ctx:
            self._vp(roles=BOTH)
        self.assertIn("claims producer with no verdict on file", str(ctx.exception))
        # the control: the same store, a request that claims only what is on file
        self._vp(roles=("Composer",))
        # and the missing verdict arriving is what releases it
        self._add("GENUINE", request_id=f"{TARGET}#Producer")
        self._vp(roles=BOTH)

    def test_coverage_is_by_role_whatever_its_case_or_spacing(self):
        self._add("GENUINE", request_id=f"{TARGET}#Sound Design")
        self._vp(roles=(" sound design ",))
        self._vp(roles=("SOUND DESIGN",))
        with self.assertRaises(va.Refused):
            self._vp(roles=("Sound Designer",))

    def test_a_verdict_on_a_role_the_request_does_not_claim_must_still_approve(self):
        """Extra claims on file are not ignored: a refused role the request has since
        dropped is still a refused document."""
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        self._add("FORGED_LIKELY", request_id=f"{TARGET}#Producer")
        with self.assertRaises(va.Refused) as ctx:
            self._vp(roles=("Composer",))
        self.assertIn("not an approval", str(ctx.exception))

    def test_a_whole_request_verdict_does_not_stand_in_for_a_role(self):
        """A row keyed by the bare request id is held to the rule, but it covers no role:
        otherwise one row approves whatever the request claims."""
        self._add("GENUINE", request_id=TARGET)
        with self.assertRaises(va.Refused) as ctx:
            self._vp()
        self.assertIn("with no verdict on file", str(ctx.exception))
        self._add("GENUINE")
        self._vp()
        # ...and it is still held to the rule: a soft one refuses the request
        self._add("SUSPECT", request_id=TARGET, created_at="2026-11-02T00:00:00Z")
        with self.assertRaises(va.Refused):
            self._vp()

    def test_a_request_claiming_no_role_needs_the_unknown_claim(self):
        self._add("GENUINE", request_id=f"{TARGET}#unknown")
        self._vp(roles=())
        with self.assertRaises(va.Refused):
            self._vp(roles=("Composer",))

    def test_roles_that_were_not_read_are_not_roles_that_are_empty(self):
        """None is 'nobody read the request', and that is not a pass."""
        self._add("GENUINE")
        for unread in (None, "Mixing Engineer"):
            with self.subTest(unread=unread):
                with self.assertRaises(va.Unavailable):
                    va.verify_proof(TARGET, PROOF, self.store, unread)


class LiveProofTests(ProofTests):
    """``verify("proof_verdict")``: the store check, fed from the LIVE request.

    Inherits every store case above and re-runs it through the admin read, so nothing the
    store check refuses is let through by the path the wrapper actually calls.
    """

    def _vp(self, request_id=TARGET, roles=(ROLE,), store=None):
        admin = FakeAdmin([request(request_id, roles=tuple(roles))])
        va.verify("proof_verdict", PROOF, request_id, PROFILE, admin=admin,
                  store_path=store or self.store)
        self.assertEqual(admin.calls, [("/admin/credit-requests",
                                        {"profilesIds": PROFILE, "limit": 200, "page": 1})])

    def test_an_empty_request_id_matches_nothing(self):
        self._add("GENUINE", request_id="#Composer")
        with self.assertRaises(va.Refused):
            va.verify("proof_verdict", PROOF, "", PROFILE, admin=FakeAdmin([]),
                      store_path=self.store)

    def test_another_requests_claims_are_not_read(self):
        """Through the live path an id that is not on the profile never reaches the
        store at all."""
        self._add("GENUINE", request_id=f"{ANCHOR}#Composer")
        with self.assertRaises(va.Refused) as ctx:
            va.verify("proof_verdict", PROOF, TARGET, PROFILE,
                      admin=FakeAdmin([request(ANCHOR, roles=("Composer",))]),
                      store_path=self.store)
        self.assertIn("is not on profile", str(ctx.exception))

    def test_the_roles_come_from_the_live_request_not_the_caller(self):
        """The attack: a plan (or a digest) that says the request claims only Composer.
        Nothing the caller passes names a role, so the API's answer is the only one."""
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        with self.assertRaises(va.Refused) as ctx:
            self._vp(roles=BOTH)
        self.assertIn("claims producer with no verdict on file", str(ctx.exception))

    def test_a_proof_approve_needs_a_profile_to_read_the_request_through(self):
        self._add("GENUINE")
        admin = FakeAdmin([request(TARGET)])
        with self.assertRaises(va.Refused) as ctx:
            va.verify("proof_verdict", PROOF, TARGET, "", admin=admin,
                      store_path=self.store)
        self.assertIn("no profile id", str(ctx.exception))
        self.assertEqual(admin.calls, [])

    def test_a_request_that_is_no_longer_pending_is_not_approved_on_its_proof(self):
        self._add("GENUINE")
        for status, exc in (("approved", va.AlreadyWritten), ("rejected", va.Refused)):
            with self.subTest(status=status):
                with self.assertRaises(exc):
                    va.verify("proof_verdict", PROOF, TARGET, PROFILE,
                              admin=FakeAdmin([request(TARGET, status=status)]),
                              store_path=self.store)

    def test_an_unreadable_request_list_is_unavailable(self):
        self._add("GENUINE")

        class Broken:
            def get(self, path, params=None):
                return {"nope": 1}
        with self.assertRaises(va.Unavailable):
            va.verify("proof_verdict", PROOF, TARGET, PROFILE, admin=Broken(),
                      store_path=self.store)


class DispatchTests(unittest.TestCase):
    def test_an_unknown_rule_is_refused(self):
        with self.assertRaises(va.Refused):
            va.verify("ask", ANCHOR, TARGET, PROFILE, admin=FakeAdmin([]))

    def test_the_cli_exit_codes_are_distinct(self):
        self.assertEqual(va.main(["--rule", "ask", "--anchor", ANCHOR,
                                  "--request-id", TARGET]), 1)
        with mock.patch.object(va, "pinned_admin",
                               return_value=FakeAdmin([request(TARGET)])):
            self.assertEqual(va.main(["--rule", "proof_verdict", "--anchor", PROOF,
                                      "--request-id", TARGET, "--profile-id", PROFILE,
                                      "--proof-store", "/nonexistent/proof.sqlite"]), 2)

    def test_the_digests_dash_is_no_profile_and_never_a_filter_value(self):
        """``-`` is how the digest spells "no profile". It must not be sent to the API as
        ``profilesIds=-``; with no profile there is nothing to read the request through."""
        admin = FakeAdmin([request(TARGET)])
        with mock.patch.object(va, "pinned_admin", return_value=admin):
            for rule, anchor in (("proof_verdict", PROOF), ("precedent", ANCHOR),
                                 ("duplicate", ANCHOR)):
                with self.subTest(rule=rule):
                    self.assertEqual(va.main(["--rule", rule, "--anchor", anchor,
                                              "--request-id", TARGET,
                                              "--profile-id", "-"]), 1)
        self.assertEqual(admin.calls, [])


def fabricating_admin_script(root: Path) -> tuple[Path, Path]:
    """A caller's 'admin script': it answers call-batch with the target pending and the
    anchor APPROVED for the same claim, and leaves a marker when it runs."""
    marker = root / "fabricator-ran"
    script = root / "fake-admin.sh"
    row = json.dumps({"id": "one", "http_status": 200, "body": {"data": {"items": [
        request(TARGET), request(ANCHOR, status="approved")]}}})
    script.write_text("#!/usr/bin/env bash\n"
                      f": > {marker}\n"
                      "cat >/dev/null\n"
                      f"printf '%s\\n' '{row}'\n")
    script.chmod(0o755)
    return script, marker


PLANNED_AT = "2026-11-11T12:00:00.000000Z"
AFTER = "2026-11-11T12:00:03.000Z"       # the backend stamped it after our intent
BEFORE = "2026-11-10T09:00:00.000Z"      # ...or a day before we ever planned it


def decided(rid, status, updated_at=AFTER, **kw):
    return {**request(rid, status=status, **kw), "updatedAt": updated_at}


class ReconcileTests(unittest.TestCase):
    """QA review 5 of hydra#1883: a write that landed and was never confirmed.

    The gate refuses a request that is no longer pending, so a crash between the API call
    and the ledger commit left a row nothing could ever record. ``reconcile`` is the read
    that settles it, and the whole of its job is to tell OUR write from somebody else's
    decision - so most of these are the cases where the answer must NOT be 'landed'.
    """

    def _reconcile(self, items, rule="precedent", planned_at=PLANNED_AT, profile=PROFILE,
                   **kw):
        self.admin = FakeAdmin(items)
        return va.reconcile(rule, kw.pop("anchor", ANCHOR), TARGET, profile,
                            planned_at=planned_at, admin=self.admin, **kw)

    def test_a_write_that_landed_after_the_intent_is_ours(self):
        verdict = self._reconcile([decided(TARGET, "approved"),
                                   request(ANCHOR, status="approved")])
        self.assertEqual(verdict, va.LANDED)
        # one read of the claimant's profile, and nothing else
        self.assertEqual(len(self.admin.calls), 1)
        self.assertEqual(self.admin.calls[0][1]["profilesIds"], PROFILE)

    def test_a_still_pending_request_did_not_land(self):
        for status in va.PENDING_STATUSES:
            with self.subTest(status=status):
                self.assertEqual(
                    self._reconcile([request(TARGET, status=status),
                                     request(ANCHOR, status="approved")]),
                    va.NOT_LANDED)

    def test_a_request_approved_before_the_intent_is_somebody_elses(self):
        """It was already approved when we planned to approve it, so the gate refused our
        write and the approval is not ours to claim."""
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile([decided(TARGET, "approved", BEFORE),
                             request(ANCHOR, status="approved")])
        self.assertEqual(ctx.exception.reason_code, "decided_before_intent")

    def test_the_clock_tolerance_is_seconds_not_minutes(self):
        just_inside = "2026-11-11T11:59:56.000Z"     # 4s before the intent
        just_outside = "2026-11-11T11:59:54.000Z"    # 6s before it
        self.assertEqual(self._reconcile([decided(TARGET, "approved", just_inside),
                                          request(ANCHOR, status="approved")]), va.LANDED)
        with self.assertRaises(va.Elsewhere):
            self._reconcile([decided(TARGET, "approved", just_outside),
                             request(ANCHOR, status="approved")])
        self.assertLessEqual(va.CLOCK_SKEW_SECONDS, 5)

    def test_an_approval_our_anchor_could_not_have_made_is_somebody_elses(self):
        """Approved, and after our intent - but the anchor this decision cites is not an
        approved request for the same claim, so the gate would have refused our write.
        Whoever approved it, it was not this decision."""
        cases = (request(ANCHOR, status="unverified"),
                 request(ANCHOR, status="approved", user="u2"),
                 request(ANCHOR, status="approved", track="t2"),
                 request(ANCHOR, status="approved", roles=("Mastering Engineer",)))
        for anchor in cases:
            with self.subTest(anchor=anchor):
                with self.assertRaises(va.Elsewhere) as ctx:
                    self._reconcile([decided(TARGET, "approved"), anchor])
                self.assertEqual(ctx.exception.reason_code, "anchor_unverified")
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile([decided(TARGET, "approved")])     # the anchor is not there
        self.assertEqual(ctx.exception.reason_code, "anchor_unverified")

    def test_a_request_decided_the_other_way_is_never_ours(self):
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile([decided(TARGET, "rejected"), request(ANCHOR, status="approved")])
        self.assertEqual(ctx.exception.reason_code, "target_rejected")
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile([decided(TARGET, "approved"), request(ANCHOR, status="approved")],
                            rule="duplicate")
        self.assertEqual(ctx.exception.reason_code, "target_approved")

    def test_a_duplicate_close_that_landed_is_ours(self):
        for original in ("approved", "rejected"):
            with self.subTest(original=original):
                self.assertEqual(
                    self._reconcile([decided(TARGET, "rejected"),
                                     request(ANCHOR, status=original)], rule="duplicate"),
                    va.LANDED)
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile([decided(TARGET, "rejected"),
                             request(ANCHOR, status="unverified")], rule="duplicate")
        self.assertEqual(ctx.exception.reason_code, "anchor_unverified")

    def test_what_cannot_be_read_is_neither_landed_nor_abandoned(self):
        """Unavailable, every time: an unread request is not a verdict in either
        direction, and the caller leaves the intent open."""
        anchor = request(ANCHOR, status="approved")
        no_stamp = request(TARGET, status="approved")                  # no updatedAt
        cases = {
            "no updatedAt": dict(items=[no_stamp, anchor]),
            "unparseable updatedAt": dict(items=[decided(TARGET, "approved", "soon"), anchor]),
            "target not in the read": dict(items=[anchor]),
            "a status that is not a decision": dict(items=[decided(TARGET, "processing"), anchor]),
            "no status at all": dict(items=[decided(TARGET, ""), anchor]),
            "no profile id": dict(items=[decided(TARGET, "approved"), anchor], profile=""),
            "no planned_at": dict(items=[decided(TARGET, "approved"), anchor], planned_at=""),
            "unparseable planned_at": dict(items=[decided(TARGET, "approved"), anchor],
                                           planned_at="yesterday"),
        }
        for name, kw in cases.items():
            with self.subTest(case=name):
                with self.assertRaises(va.Unavailable):
                    self._reconcile(kw.pop("items"), **kw)

    def test_an_unreadable_list_is_unavailable(self):
        class Broken:
            def get(self, path, params=None):
                return {"count": 0}
        with self.assertRaises(va.Unavailable):
            va.reconcile("precedent", ANCHOR, TARGET, PROFILE, planned_at=PLANNED_AT,
                         admin=Broken())

    def test_a_rule_that_writes_nothing_cannot_be_reconciled(self):
        with self.assertRaises(va.Refused):
            self._reconcile([decided(TARGET, "approved")], rule="ask")

    def test_reconcile_reads_through_the_pinned_source_or_not_at_all(self):
        """No ``admin`` argument means the pinned wrapper, and a redirect is refused -
        the reconcile read gets no softer a source than the gate's own."""
        with tempfile.TemporaryDirectory() as td:
            script, marker = fabricating_admin_script(Path(td))
            with mock.patch.dict(os.environ, {va.ADMIN_SCRIPT_ENV: str(script)}):
                with self.assertRaises(va.Refused) as ctx:
                    va.reconcile("precedent", ANCHOR, TARGET, PROFILE, planned_at=PLANNED_AT)
            self.assertNotIsInstance(ctx.exception, va.Elsewhere)
            self.assertIn(va.ADMIN_SCRIPT_ENV, str(ctx.exception))
            self.assertFalse(marker.exists())


class ReconcileProofTests(ProofTests):
    """The proof rule has no anchor on the profile: its evidence is the proof store."""

    def _reconcile(self, target):
        return va.reconcile("proof_verdict", PROOF, TARGET, PROFILE, planned_at=PLANNED_AT,
                            admin=FakeAdmin([target]), store_path=self.store)

    def test_a_landed_proof_approve_is_ours_when_the_verdict_still_stands(self):
        self._add("GENUINE")
        self.assertEqual(self._reconcile(decided(TARGET, "approved")), va.LANDED)

    def test_a_proof_approve_the_store_does_not_support_is_somebody_elses(self):
        self._add("PLAUSIBLE")
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile(decided(TARGET, "approved"))
        self.assertEqual(ctx.exception.reason_code, "anchor_unverified")

    def test_a_proof_approve_missing_a_claimed_role_is_somebody_elses(self):
        """The gate would have refused this write (a claimed role has no verdict), so an
        approved request in that state was not approved by this decision."""
        self._add("GENUINE", request_id=f"{TARGET}#Composer")
        with self.assertRaises(va.Elsewhere) as ctx:
            self._reconcile(decided(TARGET, "approved", roles=BOTH))
        self.assertEqual(ctx.exception.reason_code, "anchor_unverified")
        self.assertIn("with no verdict on file", str(ctx.exception))

    def test_an_unreadable_proof_store_is_unavailable_not_abandoned(self):
        self.store = str(Path(self.td.name) / "absent.sqlite")
        with self.assertRaises(va.Unavailable):
            self._reconcile(decided(TARGET, "approved"))


class PinnedAdminSourceTests(unittest.TestCase):
    """QA review 4 of hydra#1883, finding 1: the verifier built ``BatchAdmin()`` with no
    script, and ``BatchAdmin`` takes ``CREDIT_REVIEW_ADMIN_SCRIPT`` from the environment
    the wrapper passes down. A caller could therefore choose the program whose output
    the verifier treats as the admin API. The source is pinned; an override is DENIED."""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.script, self.marker = fabricating_admin_script(Path(self.td.name))

    def _env(self, value):
        return mock.patch.dict(os.environ, {va.ADMIN_SCRIPT_ENV: value})

    def test_the_pin_is_this_trees_operations_wrapper(self):
        expected = (SCRIPTS.parent / "workspaces/operations/skills/muso-ops-admin/scripts"
                    / "muso-admin-api.sh")
        self.assertEqual(Path(va.ADMIN_SCRIPT), expected.resolve())
        self.assertTrue(expected.is_file())
        # derived from the verifier's own location: under /opt/hydra it is the deployed
        # wrapper, and nothing in the environment contributes to it
        self.assertTrue(va.ADMIN_SCRIPT.startswith(str(Path(va.__file__).resolve().parents[2])))

    def test_the_fabricated_response_would_verify_if_it_were_read(self):
        """The attack is real: this is what honouring the override used to do."""
        from credit_review import batch_admin
        va.verify_precedent(batch_admin.BatchAdmin(script=str(self.script)),
                            TARGET, ANCHOR, PROFILE)
        self.assertTrue(self.marker.exists())

    def test_a_caller_supplied_admin_script_is_denied_for_a_precedent(self):
        with self._env(str(self.script)):
            with self.assertRaises(va.Refused) as ctx:
                va.verify("precedent", ANCHOR, TARGET, PROFILE)
        self.assertIn("CREDIT_REVIEW_ADMIN_SCRIPT", str(ctx.exception))
        self.assertFalse(self.marker.exists(), "the caller's admin script was executed")

    def test_a_caller_supplied_admin_script_is_denied_for_a_duplicate(self):
        with self._env(str(self.script)):
            with self.assertRaises(va.Refused) as ctx:
                va.verify("duplicate", ANCHOR, TARGET, PROFILE)
        self.assertIn("CREDIT_REVIEW_ADMIN_SCRIPT", str(ctx.exception))
        self.assertFalse(self.marker.exists())

    def test_an_empty_or_dangling_override_is_denied_too(self):
        for value in ("", "/nonexistent/muso-admin-api.sh", "muso-admin-api.sh"):
            with self.subTest(value=value), self._env(value):
                with self.assertRaises(va.Refused):
                    va.pinned_admin()

    def test_a_symlink_to_another_script_is_denied(self):
        link = Path(self.td.name) / "muso-admin-api.sh"
        link.symlink_to(self.script)
        with self._env(str(link)):
            with self.assertRaises(va.Refused):
                va.pinned_admin()

    def test_the_pinned_path_itself_is_not_a_redirect(self):
        link = Path(self.td.name) / "canonical.sh"
        link.symlink_to(va.ADMIN_SCRIPT)
        for value in (va.ADMIN_SCRIPT, str(link)):
            with self.subTest(value=value), self._env(value):
                self.assertEqual(va.pinned_admin().script, va.ADMIN_SCRIPT)

    def test_without_an_override_the_client_reads_the_pinned_wrapper(self):
        with mock.patch.dict(os.environ):
            os.environ.pop(va.ADMIN_SCRIPT_ENV, None)
            self.assertEqual(va.pinned_admin().script, va.ADMIN_SCRIPT)

    def test_a_missing_pinned_wrapper_is_unavailable_not_a_pass(self):
        with mock.patch.dict(os.environ):
            os.environ.pop(va.ADMIN_SCRIPT_ENV, None)
            with mock.patch.object(va, "ADMIN_SCRIPT", str(Path(self.td.name) / "gone.sh")):
                with self.assertRaises(va.Unavailable):
                    va.pinned_admin()

    def test_the_batch_client_is_loaded_from_the_verifiers_own_directory(self):
        loaded = va._batch_admin()
        self.assertEqual(Path(loaded.__file__).resolve(),
                         Path(va.__file__).resolve().parent / "batch_admin.py")


class ScriptEntrypointTests(unittest.TestCase):
    """QA review 4, finding 2: the wrapper runs this FILE, not this package. Every test
    above imports the module, which is exactly how ``from . import batch_admin`` shipped
    broken. These execute ``python3 -I <path>`` the way ``muso-admin-api.sh`` does, from
    a working directory and a PYTHONPATH that would both mislead a path-based import.
    (The successful verify through ``bash <wrapper>`` is
    ``test_scale_drain.RealEntrypointTests``.)"""

    VERIFIER = SCRIPTS / "credit_review" / "verify_anchor.py"

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.root = Path(self.td.name)
        self.script, self.marker = fabricating_admin_script(self.root)

    def _run(self, *args, env=None):
        base = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(self.root),
                "PYTHONPATH": str(self.root)}
        return subprocess.run([sys.executable, "-I", str(self.VERIFIER), *args],
                              capture_output=True, text=True, cwd=self.root,
                              env={**base, **(env or {})}, check=False)

    def test_both_wrappers_execute_the_verifier_as_an_isolated_script(self):
        for wrapper in ("skills-all/muso-ops-admin/scripts/muso-admin-api.sh",
                        "workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"):
            text = (SCRIPTS.parent / wrapper).read_text()
            self.assertIn('python3 -I "$drain_verifier"', text, wrapper)
            self.assertIn('python3 -I "$dup_verifier"', text, wrapper)
            for line in text.splitlines():
                if "_verifier\"" in line and "python3" in line:
                    self.assertNotIn("PYTHONPATH", line, f"{wrapper}: {line.strip()}")

    def test_the_script_runs_with_no_package_context(self):
        proc = self._run("--rule", "ask", "--anchor", ANCHOR, "--request-id", TARGET)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertNotIn("ImportError", proc.stderr)
        self.assertIn("not auto-approvable", proc.stderr)

    def _api_env(self, items):
        """The network, and only the network: a ``curl`` on PATH answering as
        core-backend does (the seam ``muso-admin-api-call-batch.bats`` uses). The
        verifier and the pinned wrapper it reads through are the real files."""
        (self.root / "bin").mkdir(exist_ok=True)
        log = self.root / "curl.log"
        log.write_text("")
        body = self.root / "items.json"
        body.write_text(json.dumps({"data": {"items": items}}))
        stub = self.root / "bin/curl"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            f'printf \'%s\\n\' "$*" >> {log}\n'
            'case "$*" in\n'
            f'    *"-X GET"*"/admin/credit-requests?"*) cat {body}; printf \'\\n200\' ;;\n'
            '    *) printf \'{"error":"unexpected request"}\\n500\' ;;\n'
            "esac\n")
        stub.chmod(0o755)
        (self.root / "codex-health.sh").write_text("codex_health_gate() { return 0; }\n")
        (self.root / "token-cache").write_text(f"{int(time.time())}\ndummy-token\n")
        return log, {
            "PATH": f"{self.root / 'bin'}:/usr/local/bin:/usr/bin:/bin",
            "MUSO_API_URL": "https://example.invalid",
            "MUSO_ADMIN_EMAIL": "test@example.com",
            "MUSO_ADMIN_PASSWORD": "unused",
            "MUSO_OPS_STATE_DIR": str(self.root / "state"),
            "OPS_RUNLOG_DIR": str(self.root / "runlogs"),
            "CV_RESULTS_PATH": str(self.root / "results.jsonl"),
            "ADMIN_TOKEN_CACHE_PATH": str(self.root / "token-cache"),
            "CODEX_HEALTH_LIB": str(self.root / "codex-health.sh"),
        }

    def test_the_admin_backed_rules_verify_when_run_as_a_script(self):
        """The two rules that need the batch client are the two that raised ImportError.
        Run as the wrapper runs them, they read the claimant's profile through the pinned
        wrapper and exit 0."""
        cases = (("precedent", request(TARGET), request(ANCHOR, status="approved")),
                 ("duplicate", request(TARGET, status="unverified"),
                  request(ANCHOR, status="approved")))
        for rule, target, anchor in cases:
            with self.subTest(rule=rule):
                log, env = self._api_env([target, anchor])
                proc = self._run("--rule", rule, "--anchor", ANCHOR, "--request-id", TARGET,
                                 "--profile-id", PROFILE, env=env)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertNotIn("ImportError", proc.stderr)
                reads = [ln for ln in log.read_text().splitlines() if "-X GET" in ln]
                self.assertEqual(len(reads), 1, reads)
                self.assertIn(f"profilesIds={PROFILE}", reads[0])

    def test_the_script_refuses_what_the_api_does_not_confirm(self):
        """The twin: same invocation, the API reports the anchor still pending."""
        for rule in ("precedent", "duplicate"):
            with self.subTest(rule=rule):
                log, env = self._api_env([request(TARGET, status="unverified"),
                                          request(ANCHOR, status="unverified")])
                proc = self._run("--rule", rule, "--anchor", ANCHOR, "--request-id", TARGET,
                                 "--profile-id", PROFILE, env=env)
                self.assertEqual(proc.returncode, 1, proc.stderr)
                self.assertNotIn("Traceback", proc.stderr)
                self.assertEqual(len([ln for ln in log.read_text().splitlines()
                                      if "-X GET" in ln]), 1)

    def test_a_claim_keyed_proof_verifies_when_run_as_a_script(self):
        """The proof rule, executed as the wrapper executes it, against a store keyed the
        way the real one is. (The wrapper never passes ``--proof-store``; the store it
        reads is the verifier's constant.)"""
        store = str(self.root / "proof.sqlite")
        db = sqlite3.connect(store)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT, proof_id TEXT,"
                   " verdict TEXT, created_at TEXT, request_id TEXT NOT NULL DEFAULT '')")
        db.executemany("INSERT INTO verdicts (proof_id, verdict, created_at, request_id)"
                       " VALUES (?,?,?,?)",
                       [(PROOF, "GENUINE", "2026-11-01T00:00:00Z", f"{TARGET}#Composer"),
                        (PROOF, "GENUINE", "2026-11-01T00:00:00Z", f"{TARGET}#Producer")])
        db.commit()
        args = ("--rule", "proof_verdict", "--anchor", PROOF, "--request-id", TARGET,
                "--profile-id", PROFILE, "--proof-store", store)
        log, env = self._api_env([request(TARGET, roles=BOTH)])
        self._run = functools.partial(self._run, env=env)
        proc = self._run(*args)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # the roles were read from the API, through the pinned wrapper: one GET
        self.assertEqual(len([ln for ln in log.read_text().splitlines()
                              if "-X GET" in ln]), 1)
        # the same store, and the API says the request claims a third role: refused
        self._api_env([request(TARGET, roles=(*BOTH, "Lyricist"))])
        proc = self._run(*args)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("claims lyricist with no verdict on file", proc.stderr)
        self._api_env([request(TARGET, roles=BOTH)])
        db.execute("INSERT INTO verdicts (proof_id, verdict, created_at, request_id)"
                   " VALUES (?,?,?,?)", (PROOF, "SUSPECT", "2026-11-02T00:00:00Z",
                                         f"{TARGET}#Producer"))
        db.commit()
        db.close()
        proc = self._run(*args)
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("not an approval", proc.stderr)

    def test_the_gate_says_already_written_apart_from_refused(self):
        """Exit 3, not exit 1: the request already holds the status this write sets. The
        wrapper refuses on any non-zero code, so this loosens nothing - it is how the
        drain's operator tells 'a write of ours that was never confirmed' from 'a
        decision that is not ours to overwrite' without reading prose."""
        cases = (("precedent", "approved", 3), ("precedent", "rejected", 1),
                 ("duplicate", "rejected", 3), ("duplicate", "approved", 1))
        for rule, target_status, code in cases:
            with self.subTest(rule=rule, target=target_status):
                log, env = self._api_env([request(TARGET, status=target_status),
                                          request(ANCHOR, status="approved")])
                proc = self._run("--rule", rule, "--anchor", ANCHOR, "--request-id", TARGET,
                                 "--profile-id", PROFILE, env=env)
                self.assertEqual(proc.returncode, code, proc.stderr)
                self.assertNotIn("Traceback", proc.stderr)
                self.assertEqual("nothing to write" in proc.stderr, code == 3, proc.stderr)

    def test_a_caller_supplied_admin_script_is_denied_at_the_entrypoint(self):
        """The API would confirm this approve; the redirect attempt alone refuses it, and
        neither the caller's script nor the API is consulted."""
        for rule in ("precedent", "duplicate"):
            with self.subTest(rule=rule):
                log, env = self._api_env([request(TARGET, status="unverified"),
                                          request(ANCHOR, status="approved")])
                proc = self._run("--rule", rule, "--anchor", ANCHOR, "--request-id", TARGET,
                                 "--profile-id", PROFILE,
                                 env={**env, "CREDIT_REVIEW_ADMIN_SCRIPT": str(self.script)})
                self.assertEqual(proc.returncode, 1, proc.stderr)
                self.assertNotIn("Traceback", proc.stderr)
                self.assertIn("CREDIT_REVIEW_ADMIN_SCRIPT", proc.stderr)
                self.assertFalse(self.marker.exists())
                self.assertEqual(log.read_text(), "")

    def test_the_script_loads_the_real_batch_client_not_one_on_the_path(self):
        hostile = self.root / "hostile-imported"
        payload = f"open({str(hostile)!r}, 'w').close()\n"
        (self.root / "credit_review").mkdir()
        for name in ("batch_admin.py", "credit_review/__init__.py",
                     "credit_review/batch_admin.py"):
            (self.root / name).write_text(payload)
        code = ("import runpy, sys\n"
                f"ns = runpy.run_path({str(self.VERIFIER)!r})\n"
                "print(ns['_batch_admin']().__file__)\n")
        proc = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True,
                              text=True, cwd=self.root, check=False,
                              env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(self.root)})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(Path(proc.stdout.strip()).resolve(),
                         SCRIPTS / "credit_review" / "batch_admin.py")
        self.assertFalse(hostile.exists())


if __name__ == "__main__":
    unittest.main()
