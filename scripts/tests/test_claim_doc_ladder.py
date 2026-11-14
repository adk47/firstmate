#!/usr/bin/env python3
"""The claim document ladder (scripts/claim_verify/doc_ladder.py + doc_sources.py) and the one
page-id rule it shares (scripts/lib/page_identity.py). Hermetic: no network, no Trino, temp stores."""
import copy
from collections import Counter
import csv
import io
import json
import os
import re
import sqlite3
import stat
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from claim_verify import decline_rules as dr  # noqa: E402
from claim_verify import doc_ladder as L  # noqa: E402
from claim_verify import doc_sources as S  # noqa: E402
from lib import page_identity  # noqa: E402
from ops_intake import lens_sources  # noqa: E402

PID = "aaaaaaaa-1111-2222-3333-444444444444"
SHA = "a" * 64
POLICY = L.load_policy()
COPY = L.load_ask_copy()


def ask(decision, policy=POLICY):
    """The words a claimant would be sent for this decision, through the ladder's own renderer."""
    cls = next((g.detail.get("claim_class") for g in decision.gates if "claim_class" in g.detail), "artist")
    return L.ask_text(decision.ask, cls, policy, COPY)


def extraction(**over):
    ex = {"ok": True, "degraded": False, "doc_type": "split_sheet",
          "issuer": {"name": "Big Label", "type": "label", "confidence": 0.9},
          "signatory": {"name": None, "title": None, "confidence": 0.0},
          "credits": [{"person": "Jane Doe", "role": "writer", "track": "Night Drive", "confidence": 0.95},
                      {"person": "Nova Kane", "role": "artist", "track": "Night Drive", "confidence": 0.9}],
          "tracks": [{"title": "Night Drive", "isrc": None, "confidence": 0.9}], "error": None}
    ex.update(over)
    return ex


def doc(sha=SHA, **over):
    d = {"intake_id": f"11:{sha[:8]}", "source_sha256": sha, "received_at": "2026-11-01T00:00:00Z",
         "subject": "credit", "has_bytes": True, "extract_status": "ok", "extraction": extraction(),
         "extractor": "dv-4", "blocking_verdicts": [], "other_filers": 0}
    d.update(over)
    return d


def claim(profile=None, **over):
    core = {"id": 7, "userId": 11, "profileId": PID, "profileType": "artist", "reason": None, "status": "pending",
            "createdAt": "2026-10-01T00:00:00Z", "email_domain": "example.org", "verificationLinks": {},
            "pk_profile_other_claims": []}
    core.update(over.pop("core", {}))
    snap_kw = over.pop("snap_kw", {})
    c = {"claim_id": 7, "user_id": 11, "profile_id": PID, "profile_type": core["profileType"],
         "status": core["status"], "claimant_names": ["Jane Doe"], "paid": True, "account_hold": False,
         "code_found_other_claims": [], "profile_in_catalog": True,
         "releases": {SHA: {"named": 1, "on_profile": 1}},
         "decline_snapshot": dr.snapshot(core, profile or {"name": "Nova Kane", "popularity": 12, "creditCount": 40},
                                         **snap_kw)}
    c.update(over)
    return c


def decide(c=None, docs=None, policy=POLICY):
    return L.decide_claim(L.ClaimFacts.from_dict(c or claim()), [L.DocFacts.from_dict(d) for d in (docs or [doc()])],
                          policy)


def snapshot(claims=None, documents=None):
    return {"version": L.VERSION, "read_at": "2026-11-12T00:00:00Z",
            "claims": claims if claims is not None else [claim()],
            "documents": documents if documents is not None else {"11": [doc()]}, "sources": {}}


class PageIdentityTests(unittest.TestCase):
    def test_equality_and_truncated_prefix_of_eight(self):
        self.assertTrue(page_identity.same_page(PID, PID))
        self.assertTrue(page_identity.same_page(PID, PID[:8]))
        self.assertTrue(page_identity.same_page(PID[:8], PID))
        self.assertTrue(page_identity.same_page(PID, PID[:13]))

    def test_a_shorter_run_never_matches(self):
        self.assertFalse(page_identity.same_page(PID, PID[:7]))
        self.assertFalse(page_identity.same_page(PID, ""))
        self.assertFalse(page_identity.same_page("", ""))
        self.assertFalse(page_identity.same_page(PID, "bbbbbbbb"))

    def test_matched_keeps_the_asked_order(self):
        self.assertEqual(page_identity.matched(PID, ["zz", PID[:8], PID, PID[:7]]), [PID[:8], PID])
        self.assertEqual(page_identity.matched("", [PID]), [])

    def test_norm(self):
        self.assertEqual(page_identity.norm("  AAAAaaaa-1111 "), "aaaaaaaa-1111")
        self.assertEqual(page_identity.norm(None), "")

    def test_ops_intake_reads_the_same_rule(self):
        """One rule: lens_sources has no spelling of its own left."""
        asked = [PID[:8], PID[:7], PID, "other"]
        self.assertEqual(lens_sources._matched_asked(PID, asked), page_identity.matched(PID, asked))
        body = (ROOT / "scripts/ops_intake/lens_sources.py").read_text()
        self.assertNotIn(">= 8", body)
        self.assertNotIn("startswith(page_id)", body)


class ReadableTests(unittest.TestCase):
    def test_all_predicates_pass(self):
        d = decide()
        self.assertEqual((d.outcome, d.reason), (L.APPROVED, "document_names_claimant_and_profile"))
        self.assertEqual([g.name for g in d.gates], [g.__name__[5:] for g in L.LADDER])
        self.assertTrue(all(g.ok for g in d.gates))
        self.assertEqual(d.source_sha256, SHA)
        self.assertEqual(d.extraction_sha256, L.sha256_of(extraction()))

    def test_no_document_no_decision(self):
        self.assertIsNone(L.decide_claim(L.ClaimFacts.from_dict(claim()), [], POLICY))

    def test_a_claim_that_is_not_open_is_not_decided(self):
        for status in ("processed", "rejected", "closed"):
            self.assertIsNone(decide(claim(status=status)))

    def test_a_document_we_have_not_read_is_ours_no_verdict_and_no_ask(self):
        failed = extraction(ok=False, error="http 503")
        cases = {
            "no bytes": (doc(extraction=None, extract_status="", has_bytes=False), "no_bytes_on_file", "byte-restore"),
            "never read": (doc(extraction=None, extract_status="", has_bytes=True), "not_extracted", "doc-verify"),
            "failed, retried": (doc(extract_status="error", extraction=failed), "extraction_failed", "doc-verify"),
            "degraded, retried": (doc(extraction=extraction(degraded=True)), "extraction_failed", "doc-verify"),
        }
        for why, (d, reason, route) in cases.items():
            with self.subTest(why=why):
                got = decide(docs=[d])
                self.assertEqual(got.outcome, L.AWAITING)
                self.assertEqual(got.reason, reason)
                self.assertEqual(got.route, route)
                self.assertEqual(got.ask, "")
                self.assertNotIn(got.outcome, L.VERDICTS)
                self.assertNotIn(got.outcome, L.ASKED)

    def test_a_read_doc_verify_will_not_make_again_asks_for_a_copy_and_refuses_nothing(self):
        gone = extraction(ok=False, error="no readable text")
        ours = extraction(ok=False, error="sandbox failed: oom")
        cases = {
            "document_not_readable": doc(extract_status="error", extraction=gone, read_final=True),
            "extraction_gave_up": doc(extract_status="error", extraction=ours, read_final=True, tooling_error=True),
            "empty_extraction": doc(extraction=extraction(credits=[], tracks=[], issuer={}, signatory={})),
        }
        for reason, d in cases.items():
            with self.subTest(reason=reason):
                got = decide(docs=[d])
                self.assertEqual(got.outcome, L.RESEND)
                self.assertEqual(got.reason, reason)
                self.assertEqual(got.ask, "readable_copy")
                self.assertEqual(got.route, "")

    def test_whose_failure_it_was_changes_the_reason_and_never_the_ask(self):
        body = extraction(ok=False, error="x")
        ours = decide(docs=[doc(extract_status="error", extraction=body, read_final=True, tooling_error=True)])
        theirs = decide(docs=[doc(extract_status="error", extraction=body, read_final=True)])
        self.assertNotEqual(ours.reason, theirs.reason)
        self.assertEqual(ours.ask, theirs.ask)
        self.assertEqual(ask(ours), ask(theirs))

    def test_a_failed_read_is_final_only_on_doc_verifys_word(self):
        body = extraction(ok=False, error="no readable text")
        for flag in (False, None, "yes", 1):
            with self.subTest(read_final=flag):
                got = decide(docs=[doc(extract_status="error", extraction=body, read_final=flag)])
                self.assertEqual(got.outcome, L.AWAITING)
                self.assertEqual(got.reason, "extraction_failed")

    def test_ok_false_is_never_read_even_when_it_names_everyone(self):
        got = decide(docs=[doc(extraction=extraction(ok=False))])
        self.assertEqual((got.outcome, got.reason), (L.AWAITING, "extraction_failed"))
        got = decide(docs=[doc(extraction=extraction(ok=False), read_final=True)])
        self.assertEqual((got.outcome, got.reason), (L.RESEND, "document_not_readable"))

    def test_an_extraction_that_is_not_an_object_is_never_a_verdict(self):
        for body in ("approved", ["approved"], 1):
            with self.subTest(body=body):
                self.assertEqual(decide(docs=[doc(extraction=body)]).outcome, L.AWAITING)
                self.assertEqual(decide(docs=[doc(extraction=body, read_final=True)]).outcome, L.RESEND)

    def test_parsed_but_empty_is_never_approved_for_any_claim_facts(self):
        """Even a claim whose every other fact is clean."""
        empty = extraction(credits=[], tracks=[], issuer=None, signatory=None, doc_type="split_sheet")
        self.assertEqual(decide(docs=[doc(extraction=empty)]).outcome, L.RESEND)

    def test_an_empty_document_of_a_kind_this_claim_never_accepts_is_refused_on_its_kind(self):
        """A credits page proves nothing to claim on, whatever it said: asking for a readable copy of a
        kind we never accept sends the claimant in a circle."""
        empty = extraction(credits=[], tracks=[], issuer={}, signatory={}, doc_type="credits_page")
        got = decide(docs=[doc(extraction=empty)])
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "doc_type_not_accepted",
                                                              "accepted_document_type"))
        self.assertEqual(got.route, "")
        self.assertTrue(ask(got))


class NamePredicateTests(unittest.TestCase):
    def test_claimant_not_named(self):
        got = decide(claim(claimant_names=["Someone Else"]))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "claimant_not_named"))
        self.assertEqual(got.ask, "proof_naming_claimant")

    def test_claimant_with_no_name_on_the_account(self):
        for names in ([], ["  "], ["---"]):
            with self.subTest(names=names):
                got = decide(claim(claimant_names=names))
                self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "claimant_name_unknown", "account_name"))

    def test_a_shared_first_name_is_not_the_claimant(self):
        self.assertEqual(decide(claim(claimant_names=["Jane"])).reason, "claimant_not_named")

    def test_word_order_and_case_do_not_matter(self):
        self.assertEqual(decide(claim(claimant_names=["DOE, jane"])).outcome, L.APPROVED)

    def test_a_name_the_extractor_was_not_sure_of_names_nobody(self):
        ex = extraction()
        ex["credits"][0]["confidence"] = 0.59
        self.assertEqual(decide(docs=[doc(extraction=ex)]).reason, "claimant_not_named")
        for bad in (float("nan"), "0.99", True, 7, None):
            ex["credits"][0]["confidence"] = bad
            with self.subTest(confidence=bad):
                self.assertEqual(decide(docs=[doc(extraction=ex)]).reason, "claimant_not_named")

    def test_profile_not_named(self):
        ex = extraction()
        ex["credits"] = ex["credits"][:1]
        got = decide(docs=[doc(extraction=ex)])
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "profile_not_named"))
        self.assertEqual(got.ask, "proof_naming_profile")

    def test_profile_named_by_page_id_under_the_shared_rule(self):
        ex = extraction()
        ex["credits"] = ex["credits"][:1]
        ex["issuer"] = {"name": f"https://credits.muso.ai/profile/{PID[:8]}", "type": "other", "confidence": 0.1}
        got = decide(docs=[doc(extraction=ex)])
        self.assertEqual(got.outcome, L.APPROVED)
        self.assertEqual([g.detail.get("by") for g in got.gates if g.name == "names_profile"], ["page_id"])

    def test_another_profiles_page_id_names_nothing(self):
        ex = extraction()
        ex["credits"] = ex["credits"][:1]
        ex["issuer"] = {"name": "https://credits.muso.ai/profile/bbbbbbbb-1111-2222-3333-444444444444",
                        "type": "other", "confidence": 0.9}
        self.assertEqual(decide(docs=[doc(extraction=ex)]).reason, "profile_not_named")

    def test_profile_refs_come_only_from_a_profile_url(self):
        ex = L.normalise(extraction(error=f"saw {PID} and muso.ai/profile/{PID[:7]}"), SHA)
        self.assertEqual(ex.profile_refs, ())
        ex = L.normalise(extraction(error=f"MUSO.AI/profile/{PID.upper()}"), SHA)
        self.assertEqual(ex.profile_refs, (PID,))

    def test_profile_not_in_catalog_is_asked_and_catalog_unread_is_ours(self):
        got = decide(claim(decline_snapshot=None, profile_in_catalog=False, releases=None))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "profile_not_in_catalog", "claimed_profile_link"))
        got = decide(claim(decline_snapshot=None, profile_in_catalog=None, releases=None))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.AWAITING, "catalog_unreadable", ""))
        self.assertEqual(got.route, "doc-sources")

    def test_one_name_for_both_is_recorded(self):
        got = decide(claim(profile={"name": "Jane Doe", "popularity": 1, "creditCount": 1}))
        self.assertEqual(got.outcome, L.APPROVED)
        self.assertTrue(next(g for g in got.gates if g.name == "names_profile").detail["same_as_claimant"])


class DocTypeTests(unittest.TestCase):
    def test_a_type_the_claim_class_does_not_accept_is_refused_and_the_ask_names_the_types(self):
        for kind in ("credits_page", "email", "email_screenshot", "receipt", "other", ""):
            with self.subTest(kind=kind):
                got = decide(docs=[doc(extraction=extraction(doc_type=kind))])
                self.assertEqual((got.outcome, got.reason), (L.REFUSED, "doc_type_not_accepted"))
                self.assertEqual(got.ask, "accepted_document_type")
        said = ask(decide(docs=[doc(extraction=extraction(doc_type="other"))]))
        for kind in POLICY["accepted_doc_types"]["artist"]:
            with self.subTest(named=kind):
                self.assertIn(COPY["doc_type_labels"][kind], said)
        org = ask(decide(claim(core={"profileType": "organization"})))
        self.assertNotIn(COPY["doc_type_labels"]["split_sheet"], org)
        self.assertIn(COPY["doc_type_labels"]["contract"], org)

    def test_every_accepted_type_passes_for_its_class(self):
        for cls, kinds in POLICY["accepted_doc_types"].items():
            for kind in kinds:
                with self.subTest(cls=cls, kind=kind):
                    c = claim(core={"profileType": cls})
                    self.assertEqual(decide(c, [doc(extraction=extraction(doc_type=kind))]).outcome, L.APPROVED)

    def test_an_organization_is_not_claimed_on_a_split_sheet(self):
        self.assertEqual(decide(claim(core={"profileType": "organization"})).reason, "doc_type_not_accepted")

    def test_a_class_the_policy_does_not_name_is_held_to_what_every_class_accepts(self):
        """Not a stop of its own: the strictest list decides, and the gate records the class was unknown."""
        every = [k for k in POLICY["accepted_doc_types"]["artist"] if k in POLICY["accepted_doc_types"]["organization"]]
        self.assertEqual(L.accepted_types(POLICY, "venue"), (every, False))
        self.assertEqual(L.accepted_types(POLICY, "artist"), (POLICY["accepted_doc_types"]["artist"], True))
        got = decide(claim(profile_type="venue"))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "doc_type_not_accepted"))
        self.assertIs(got.gates[-1].detail["claim_class_known"], False)
        self.assertNotIn(COPY["doc_type_labels"]["split_sheet"], ask(got))
        got = decide(claim(profile_type="venue"), [doc(extraction=extraction(doc_type="contract"))])
        self.assertEqual(got.outcome, L.APPROVED)

    def test_the_shipped_policy_names_only_doc_verify_types_and_no_credits_page(self):
        from credit_verify.docverify import extract
        for cls, kinds in POLICY["accepted_doc_types"].items():
            self.assertLessEqual(set(kinds), set(extract.DOC_TYPES), cls)
            self.assertNotIn("credits_page", kinds, "a public page shows nothing about who holds the account")
            self.assertNotIn("other", kinds)
        self.assertEqual(POLICY["min_confidence"], extract.MIN_CONFIDENCE)
        self.assertIs(POLICY["require_release_on_profile"], True)


class ContradictionTests(unittest.TestCase):
    def test_a_contradiction_a_document_cannot_cure_is_a_refusal_with_its_class(self):
        got = decide(claim(snap_kw={"deceased": frozenset({PID})}))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "contradiction:deceased_self_claim"))
        got = decide(claim(core={"email_domain": "cloudtestlabaccounts.com"}))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "contradiction:test_account"))

    def test_every_class_the_decline_rule_can_produce_has_an_ask_and_no_other(self):
        from credit_review import claim_executor
        self.assertEqual(set(L.CONTRADICTION_ASKS), set(claim_executor.CONTRADICTIONS))
        self.assertLessEqual(set(L.CONTRADICTION_ASKS.values()), set(L.ASKS))

    def test_a_contradiction_no_document_cures_asks_for_nothing_and_says_so(self):
        got = decide(claim(snap_kw={"deceased": frozenset({PID})}))
        self.assertEqual(got.ask, L.NO_ASK)
        self.assertEqual(ask(got), "")

    def test_a_contradiction_class_with_no_ask_cannot_be_recorded(self):
        stop = L._fail("no_contradiction", "contradiction", contradiction="something_new")
        with self.assertRaisesRegex(ValueError, "something_new"):
            L.ask_of(stop)

    def test_the_contradiction_is_the_decline_rules_own_answer(self):
        c = claim(snap_kw={"deceased": frozenset({PID})})
        self.assertEqual(dr.reproduce(c["decline_snapshot"]).contradiction, "deceased_self_claim")

    def test_profile_already_held_by_another_account(self):
        got = decide(claim(core={"pk_profile_other_claims": [{"userId": 99, "status": "processed"}]}))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "profile_already_claimed", L.NO_ASK))
        got = decide(claim(core={"pk_profile_other_claims": [{"userId": 99, "status": "rejected"}]}))
        self.assertEqual(got.outcome, L.APPROVED)

    def test_bound_code(self):
        got = decide(claim(code_found_other_claims=None))
        self.assertEqual((got.outcome, got.reason, got.route), (L.AWAITING, "bound_code_unmeasured", "doc-sources"))
        got = decide(claim(code_found_other_claims=[8]))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "bound_code_other_claim", "claim_code_on_page"))

    def test_releases(self):
        for unread in (None, {}):
            got = decide(claim(releases=unread))
            self.assertEqual((got.outcome, got.reason, got.ask), (L.AWAITING, "releases_unmeasured", ""))
        got = decide(claim(releases={SHA: {"named": 3, "on_profile": 0}}))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "releases_not_on_profile", "release_on_profile"))
        got = decide(claim(releases={SHA: {"named": 0, "on_profile": 0}}))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "no_release_named", "release_on_profile"))

    def test_without_the_release_requirement_only_a_contradiction_stops(self):
        pol = {**POLICY, "require_release_on_profile": False}
        self.assertEqual(decide(claim(releases={SHA: {"named": 0, "on_profile": 0}}), policy=pol).outcome, L.APPROVED)
        self.assertEqual(decide(claim(releases={SHA: {"named": 2, "on_profile": 0}}), policy=pol).reason,
                         "releases_not_on_profile")

    def test_catalog_unread_is_not_a_pass(self):
        c = claim(decline_snapshot=None)
        c["profile_in_catalog"] = True
        self.assertEqual(decide(c).outcome, L.AWAITING)


class CleanTests(unittest.TestCase):
    def test_blocking_verdicts_and_reuse(self):
        for d, reason, want in ((doc(blocking_verdicts=["forged"]), "document_forged", "document_from_issuer"),
                                (doc(blocking_verdicts=["contradicted"]), "document_contradicted", "document_from_issuer"),
                                (doc(blocking_verdicts=["contradicted", "forged"]), "document_forged",
                                 "document_from_issuer"),
                                (doc(other_filers=1), "document_reused", "own_document")):
            with self.subTest(reason=reason):
                got = decide(docs=[d])
                self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, reason, want))

    def test_big_profile_uses_the_claim_sides_own_thresholds(self):
        for prof in ({"name": "Nova Kane", "popularity": dr.BIG_POPULARITY, "creditCount": 1},
                     {"name": "Nova Kane", "popularity": 1, "creditCount": dr.BIG_CREDITS}):
            with self.subTest(prof=prof):
                got = decide(claim(profile=prof))
                self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "big_profile", "claim_code_on_page"))
        small = {"name": "Nova Kane", "popularity": dr.BIG_POPULARITY - 1, "creditCount": dr.BIG_CREDITS - 1}
        self.assertEqual(decide(claim(profile=small)).outcome, L.APPROVED)

    def test_profile_size_unread_is_not_small(self):
        got = decide(claim(profile={"name": "Nova Kane", "popularity": None, "creditCount": None}))
        self.assertEqual((got.outcome, got.reason), (L.AWAITING, "catalog_unreadable"))

    def test_account_hold(self):
        got = decide(claim(account_hold=True))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "account_hold", L.NO_ASK))
        for unread in (None, "no"):
            got = decide(claim(account_hold=unread))
            self.assertEqual((got.outcome, got.reason, got.route),
                             (L.AWAITING, "account_hold_unmeasured", "doc-sources"))


class ManyDocumentsTests(unittest.TestCase):
    B = "b" * 64

    def both(self, first, second):
        c = claim(releases={SHA: {"named": 1, "on_profile": 1}, self.B: {"named": 1, "on_profile": 1}})
        return decide(c, [first, second])

    def test_the_best_document_decides(self):
        got = self.both(doc(extraction=None, extract_status=""), doc(self.B))
        self.assertEqual((got.outcome, got.source_sha256), (L.APPROVED, self.B))
        self.assertEqual([d["outcome"] for d in got.documents], [L.AWAITING, L.APPROVED])

    def test_a_document_still_ours_to_read_keeps_the_claim_from_being_asked_anything(self):
        """The unread document may be the one that proves the claim."""
        refused = doc(extraction=extraction(doc_type="other"))
        for unread in (doc(self.B, extraction=None, extract_status=""),
                       doc(self.B, extraction=None, extract_status="", has_bytes=False),
                       doc(self.B, extract_status="error", extraction=extraction(ok=False, error="http 500"))):
            with self.subTest(reason=unread["extract_status"] or unread["has_bytes"]):
                got = self.both(refused, unread)
                self.assertEqual(got.outcome, L.AWAITING)
                self.assertEqual(got.ask, "")
                self.assertEqual(got.source_sha256, self.B)
                self.assertEqual([d["outcome"] for d in got.documents], [L.REFUSED, L.AWAITING])

    def test_what_a_read_document_lacked_is_asked_before_a_copy_of_an_unreadable_one(self):
        gone = doc(self.B, extract_status="error", extraction=extraction(ok=False, error="no readable text"),
                   read_final=True)
        got = self.both(doc(extraction=extraction(doc_type="other")), gone)
        self.assertEqual((got.outcome, got.ask, got.source_sha256), (L.REFUSED, "accepted_document_type", SHA))

    def test_order_of_the_documents_does_not_change_the_decision(self):
        a, b = doc(extraction=extraction(doc_type="other")), doc(self.B, extraction=None, extract_status="")
        self.assertEqual(self.both(a, b).key, self.both(b, a).key)

    def test_among_equals_the_document_that_got_furthest_gives_the_reason(self):
        got = self.both(doc(extraction=extraction(credits=[{"person": "X Y", "confidence": 0.9}])),
                        doc(self.B, extraction=extraction(doc_type="other")))
        self.assertEqual((got.reason, got.source_sha256), ("doc_type_not_accepted", self.B))

    def test_a_bad_document_stops_a_clean_one_from_approving(self):
        for bad, reason in ((doc(self.B, blocking_verdicts=["forged"]), "document_forged"),
                            (doc(self.B, other_filers=2, extraction=None, extract_status=""), "document_reused")):
            with self.subTest(reason=reason):
                got = self.both(doc(), bad)
                self.assertEqual((got.outcome, got.reason), (L.REFUSED, reason))
                self.assertEqual(got.ask, L.REASONS[reason].ask)
                self.assertEqual(got.gates[-1].name, "clean_across_documents")


class ReasonCodeTests(unittest.TestCase):
    def test_every_reason_has_exactly_one_outcome_and_only_one_approves(self):
        self.assertLessEqual({r.outcome for r in L.REASONS.values()}, set(L.OUTCOMES))
        self.assertEqual([k for k, r in L.REASONS.items() if r.outcome == L.APPROVED],
                         ["document_names_claimant_and_profile"])

    def test_no_outcome_is_a_persons_to_work(self):
        self.assertEqual(set(L.OUTCOMES), {L.APPROVED, L.REFUSED, L.RESEND, L.AWAITING})
        for gone in ("REVIEW", "UNREADABLE", "TERMINAL", "queue"):
            with self.subTest(name=gone):
                self.assertFalse(hasattr(L, gone))
        for word in ("needs_human_review", "unreadable"):
            with self.subTest(word=word):
                self.assertNotIn(word, L.OUTCOMES)

    def test_every_reason_says_who_moves_next_the_claimant_or_a_job(self):
        """The table a new reason cannot get past: an ask for the claimant, or a job for us; never neither."""
        for key, r in L.REASONS.items():
            with self.subTest(reason=key):
                if r.outcome == L.APPROVED:
                    self.assertEqual((r.ask, r.route), ("", ""))
                elif r.outcome in L.ASKED:
                    self.assertTrue(r.ask)
                    self.assertEqual(r.route, "")
                    self.assertTrue(r.ask in L.ASKS or key == "contradiction")
                else:
                    self.assertEqual(r.outcome, L.AWAITING)
                    self.assertEqual(r.ask, "")
                    self.assertIn(r.route, L.ROUTES)

    def test_a_reason_with_neither_an_ask_nor_a_job_fails_the_import_check(self):
        for bad in (L.Reason(L.REFUSED), L.Reason(L.RESEND, ask="no_such_ask"), L.Reason(L.AWAITING),
                    L.Reason(L.AWAITING, route="a person"), L.Reason(L.REFUSED, ask="readable_copy", route="doc-verify"),
                    L.Reason("needs_human_review", ask="readable_copy"), L.Reason(L.APPROVED, ask="readable_copy"),
                    L.Reason(L.RESEND, ask=L.NO_ASK)):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                L._check_reasons({**L.REASONS, "a_new_reason": bad})
        L._check_reasons(L.REASONS)

    def test_only_a_refusal_no_document_cures_asks_for_nothing(self):
        quiet = {k for k, r in L.REASONS.items() if r.ask == L.NO_ASK}
        self.assertEqual(quiet, {"profile_already_claimed", "account_hold"})
        self.assertNotIn(L.NO_ASK, [r.ask for r in L.REASONS.values() if r.outcome == L.RESEND])

    def test_every_reason_in_the_code_is_registered(self):
        body = (ROOT / "scripts/claim_verify/doc_ladder.py").read_text()
        used = set(re.findall(r'_fail\(name, "([a-z_]+)"', body)) | set(L.BLOCKING.values()) | set(L.POISON)
        self.assertLessEqual(used, set(L.REASONS))
        self.assertEqual(set(L.REASONS) - used - {"document_names_claimant_and_profile", "not_extracted",
                                                  "no_bytes_on_file", "extraction_gave_up", "document_not_readable"},
                         set())

    def test_an_unregistered_reason_cannot_be_given(self):
        with self.assertRaises(ValueError):
            L._fail("x", "because")

    def test_a_refusal_is_never_bare(self):
        got = decide(claim(snap_kw={"deceased": frozenset({PID})}))
        self.assertRegex(got.reason, r"^contradiction:[a-z_]+$")

    def test_the_ladder_reaches_no_model_and_no_network(self):
        body = (ROOT / "scripts/claim_verify/doc_ladder.py").read_text()
        for banned in ("urllib", "subprocess", "model_chain", "requests", "socket", "openrouter", "judge"):
            self.assertNotIn(banned, body.split('"""', 2)[2], banned)


class PlanTests(unittest.TestCase):
    def test_plan_is_sorted_and_byte_identical_twice(self):
        c2 = claim(claim_id=3, claimant_names=["Nobody Here"])
        snap = snapshot([claim(), c2])
        a = [L.canonical(d.as_dict()) for d, _ in L.plan(snap, POLICY)[0]]
        b = [L.canonical(d.as_dict()) for d, _ in L.plan(copy.deepcopy(snap), POLICY)[0]]
        self.assertEqual(a, b)
        self.assertEqual([json.loads(x)["claim_id"] for x in a], [3, 7])

    def test_a_paying_claimant_is_decided_first_whatever_the_dates_say(self):
        """Two claims, one paid. The unpaid one has the lower claim id and the older document; the
        paid one is still decided first, and recorded first."""
        old, new = "1" * 64, "2" * 64
        unpaid = claim(claim_id=3, user_id=21, paid=False, releases={old: {"named": 1, "on_profile": 1}})
        paid = claim(claim_id=9, user_id=22, paid=True, releases={new: {"named": 1, "on_profile": 1}})
        docs = {"21": [doc(old, received_at="2026-01-01T00:00:00Z")],
                "22": [doc(new, received_at="2026-11-13T00:00:00Z")]}
        for order in ([unpaid, paid], [paid, unpaid]):
            with self.subTest(first=order[0]["claim_id"]):
                decisions = [d for d, _ in L.plan(snapshot(order, docs), POLICY)[0]]
                self.assertEqual([(d.claim_id, d.paid) for d in decisions], [(9, True), (3, False)])
        with tempfile.TemporaryDirectory() as tmp:
            db = L.open_store(os.path.join(tmp, "d.sqlite"))
            self.addCleanup(db.close)
            L.run(snapshot([unpaid, paid], docs), POLICY, db)
            self.assertEqual([r[0] for r in db.execute("SELECT claim_id FROM claim_doc_events ORDER BY rowid")],
                             [9, 3])
            self.assertEqual([(r["claim_id"], r["paid"]) for r in L.standing(db, L.APPROVED)],
                             [(9, True), (3, False)])

    def test_only_a_measured_paid_flag_is_paid_and_ids_break_the_tie(self):
        self.assertEqual(sorted([(None, 1), (False, 2), (True, 30), (True, 4), ("yes", 5), (1, 6)],
                                key=lambda x: L.paid_first(*x)),
                         [(True, 4), (True, 30), (None, 1), (False, 2), ("yes", 5), (1, 6)])
        mixed = [claim(claim_id=n, user_id=11, paid=p) for n, p in ((5, None), (4, False), (6, True), (2, True))]
        self.assertEqual([d.claim_id for d, _ in L.plan(snapshot(mixed), POLICY)[0]], [2, 6, 4, 5])

    def test_split_counts_and_skips(self):
        snap = snapshot([claim(), claim(claim_id=8, user_id=12), claim(claim_id=9, status="processed"),
                         claim(claim_id=10, claimant_names=["Nobody Here"])])
        decisions, skipped = L.plan(snap, POLICY)
        self.assertEqual(skipped, {"no_document": 1, "not_open": 1})
        s = L.split(d for d, _ in decisions)
        self.assertEqual((s["claims"], s["verdicts"], s["asked"], s["awaiting_read"]), (2, 2, 1, 0))
        self.assertEqual(s["by_outcome"][L.REFUSED]["reasons"], {"claimant_not_named": 1})
        self.assertEqual(s["asks"], {"proof_naming_claimant": 1})
        self.assertEqual(s["awaiting_by_route"], {})
        self.assertNotIn("needs_human_review", L.canonical(s))

    def test_the_outcome_and_the_evidence_are_in_the_decision_key(self):
        import dataclasses
        a = decide()
        self.assertEqual(a.key, decide().key)
        for field, other in (("outcome", L.REFUSED), ("reason", "account_hold"), ("source_sha256", "b" * 64),
                             ("extraction_sha256", "c" * 64), ("policy_sha256", "d" * 64), ("claim_id", 8),
                             ("ask", "readable_copy"), ("route", "doc-verify")):
            with self.subTest(field=field):
                self.assertNotEqual(a.key, dataclasses.replace(a, **{field: other}).key)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = L.open_store(os.path.join(self.tmp.name, "d.sqlite"))
        self.addCleanup(self.db.close)

    def run_(self, snap, at="2026-11-12T00:00:00Z"):
        return L.run(snap, POLICY, self.db, at=at)["recorded"]

    def row(self, claim_id=7):
        return self.db.execute("SELECT * FROM claim_doc_decisions WHERE claim_id = ?", (claim_id,)).fetchone()

    def events(self):
        return [r[0] for r in self.db.execute("SELECT event FROM claim_doc_events ORDER BY id")]

    def test_one_decision_per_claim_and_a_rerun_changes_nothing(self):
        self.assertEqual(self.run_(snapshot()), {"decided": 1})
        self.assertEqual(self.run_(snapshot(), at="2026-11-13T00:00:00Z"), {"unchanged": 1})
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM claim_doc_decisions").fetchone()[0], 1)
        self.assertEqual(self.row()["decided_at"], "2026-11-12T00:00:00Z")
        self.assertEqual(self.events(), ["decided"])

    def test_the_extraction_is_stored_under_both_hashes(self):
        self.run_(snapshot())
        got = self.db.execute("SELECT source_sha256, extraction_sha256, extraction_json FROM claim_doc_extractions"
                              ).fetchall()
        self.assertEqual(len(got), 1)
        self.assertEqual((got[0][0], got[0][1]), (SHA, L.sha256_of(extraction())))
        self.assertEqual(L.sha256_of(json.loads(got[0][2])), got[0][1])
        self.assertEqual(self.row()["extraction_sha256"], got[0][1])

    def test_every_recorded_decision_is_rederived(self):
        self.run_(snapshot([claim(), claim(claim_id=8, claimant_names=["Nobody Here"])]))
        self.assertEqual(L.verify(self.db), {"reproduced": 2, "mismatch": []})
        self.assertEqual(L.reproduce(self.db, 7).key, self.row()["decision_key"])

    def test_a_changed_extraction_is_not_reproducible(self):
        self.run_(snapshot())
        self.db.execute("DROP TRIGGER claim_doc_extractions_no_update")
        self.db.execute("UPDATE claim_doc_extractions SET extraction_json = ?", (L.canonical(extraction(ok=False)),))
        with self.assertRaises(L.NotReproducible):
            L.reproduce(self.db, 7)
        self.assertEqual([m["claim_id"] for m in L.verify(self.db)["mismatch"]], [7])

    def test_changed_inputs_that_decide_differently_are_a_mismatch(self):
        self.run_(snapshot())
        inputs = json.loads(self.row()["inputs_json"])
        inputs["claim"]["account_hold"] = True
        self.db.execute("UPDATE claim_doc_decisions SET inputs_json = ?", (L.canonical(inputs),))
        self.assertEqual(L.verify(self.db)["mismatch"], [{"claim_id": 7, "why": "re-derived decision differs"}])

    def test_a_refusal_is_superseded_by_a_new_document(self):
        self.assertEqual(self.run_(snapshot([claim()], {"11": [doc(extraction=extraction(doc_type="other"))]})),
                         {"decided": 1})
        self.assertEqual((self.row()["outcome"], self.row()["ask"]), (L.REFUSED, "accepted_document_type"))
        self.assertEqual(self.run_(snapshot()), {"superseded": 1})
        self.assertEqual((self.row()["outcome"], self.row()["ask"]), (L.APPROVED, ""))
        self.assertEqual(self.events(), ["decided", "superseded"])
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_a_read_we_could_not_make_does_not_overturn_an_approval_and_is_logged_once(self):
        self.run_(snapshot())
        key = self.row()["decision_key"]
        unread = snapshot([claim(account_hold=None)])
        self.assertEqual(self.run_(unread), {"drift": 1})
        self.assertEqual(self.run_(unread), {"drift": 1})
        self.assertEqual((self.row()["outcome"], self.row()["decision_key"]), (L.APPROVED, key))
        self.assertEqual(self.events(), ["decided", "drift"])

    def test_a_measured_refusal_replaces_an_approval(self):
        """No row waits on a release: what is true now is what stands."""
        self.run_(snapshot())
        self.assertEqual(self.run_(snapshot([claim(account_hold=True)])), {"superseded": 1})
        self.assertEqual((self.row()["outcome"], self.row()["reason"], self.row()["ask"]),
                         (L.REFUSED, "account_hold", L.NO_ASK))
        self.assertEqual(self.run_(snapshot()), {"superseded": 1})
        self.assertEqual(self.row()["outcome"], L.APPROVED)
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_a_document_read_at_last_replaces_the_row_that_waited_for_it(self):
        waiting = snapshot([claim()], {"11": [doc(extraction=None, extract_status="")]})
        self.assertEqual(self.run_(waiting), {"decided": 1})
        self.assertEqual((self.row()["outcome"], self.row()["route"], self.row()["ask"]),
                         (L.AWAITING, "doc-verify", ""))
        self.assertEqual(self.run_(snapshot([claim(claimant_names=["Nobody Here"])])), {"superseded": 1})
        self.assertEqual((self.row()["outcome"], self.row()["route"], self.row()["ask"]),
                         (L.REFUSED, "", "proof_naming_claimant"))

    def test_release_is_the_revert_and_keeps_the_record(self):
        self.run_(snapshot())
        with self.assertRaises(ValueError):
            L.release(self.db, 7, by=" ", why="x")
        self.assertTrue(L.release(self.db, 7, by="nick", why="sampled wrong", at="2026-11-13T00:00:00Z"))
        self.assertFalse(L.release(self.db, 7, by="nick", why="again"))
        self.assertFalse(L.release(self.db, 999, by="nick", why="nothing there"))
        r = self.row()
        self.assertEqual((r["state"], r["state_by"], r["state_reason"], r["outcome"]),
                         ("released", "nick", "sampled wrong", L.APPROVED))
        self.assertEqual(self.run_(snapshot()), {"redecided": 1}, "the next pass decides it again: nobody is waited on")
        self.assertEqual((self.row()["state"], self.row()["outcome"], self.row()["state_by"]), ("shadow", L.APPROVED, ""))
        self.assertEqual(self.events(), ["decided", "released", "redecided"])

    def test_a_released_row_is_decided_on_what_is_true_now(self):
        self.run_(snapshot())
        L.release(self.db, 7, by="nick", why="sampled wrong")
        self.assertEqual(self.run_(snapshot([claim(account_hold=True)])), {"redecided": 1})
        self.assertEqual((self.row()["state"], self.row()["outcome"]), ("shadow", L.REFUSED))

    def test_the_standing_list_says_who_moves_next_on_every_row(self):
        self.run_(snapshot([claim(), claim(claim_id=8, claimant_names=["Nobody Here"]),
                            claim(claim_id=9, account_hold=True), claim(claim_id=10, account_hold=None)]),
                  at="2026-11-12T00:00:00Z")
        rows = L.standing(self.db)
        self.assertEqual([(r["claim_id"], r["reason"], r["stopped_at"], r["ask"]) for r in rows],
                         [(8, "claimant_not_named", "names_claimant", "proof_naming_claimant"),
                          (9, "account_hold", "clean", L.NO_ASK)])
        for r in rows:
            with self.subTest(claim_id=r["claim_id"]):
                self.assertEqual(r["source_sha256"], SHA)
                self.assertEqual(r["documents_on_file"], 1)
                self.assertEqual(r["claim_class"], "artist")
                self.assertEqual(r["route"], "")
        waiting = L.standing(self.db, L.AWAITING)
        self.assertEqual([(r["claim_id"], r["route"], r["ask"]) for r in waiting], [(10, "doc-sources", "")])
        self.assertEqual([r["claim_id"] for r in L.standing(self.db, L.APPROVED)], [7])
        self.assertEqual(L.standing(self.db, L.RESEND), [])
        for gone in ("maybe", "needs_human_review", "unreadable"):
            with self.subTest(outcome=gone), self.assertRaises(ValueError):
                L.standing(self.db, gone)

    def state(self, claim_id=7):
        r = self.row(claim_id)
        return r["state"], r["state_by"], r["state_reason"]

    def test_a_claim_that_left_the_population_leaves_the_standing_list(self):
        review = claim(claimant_names=["Nobody Here"])
        self.assertEqual(self.run_(snapshot([review])), {"decided": 1})
        self.assertEqual([r["claim_id"] for r in L.standing(self.db)], [7])
        self.assertEqual(self.run_(snapshot([]), at="2026-11-13T00:00:00Z"), {"retired": 1})
        self.assertEqual(L.standing(self.db), [], "a closed claim is owed no ask")
        self.assertEqual(self.state(), ("retired", "claim-doc-ladder", "claim_not_open_or_no_document"))
        self.assertEqual(self.row()["state_at"], "2026-11-13T00:00:00Z")
        self.assertEqual((self.row()["outcome"], self.row()["reason"]), (L.REFUSED, "claimant_not_named"),
                         "what was decided is kept")
        self.assertEqual(self.run_(snapshot([]), at="2026-11-14T00:00:00Z"), {}, "retired once, not every pass")
        self.assertEqual(self.events(), ["decided", "retired"])
        self.assertEqual(L.verify(self.db), {"reproduced": 1, "mismatch": []})

    def test_every_way_out_of_the_population_retires_the_row(self):
        gone = {"absent from the read": snapshot([]),
                "no longer open": snapshot([claim(status="processed")]),
                "no document on file any more": snapshot([claim()], {})}
        for why, later in gone.items():
            with self.subTest(why=why):
                db = L.open_store(os.path.join(self.tmp.name, f"{len(why)}.sqlite"))
                self.addCleanup(db.close)
                L.run(snapshot(), POLICY, db)
                self.assertEqual(L.run(later, POLICY, db)["recorded"], {"retired": 1})
                self.assertEqual(L.standing(db, L.APPROVED), [], "an approved row is retired like any other")

    def test_only_the_absent_claim_is_retired(self):
        self.run_(snapshot([claim(), claim(claim_id=8, claimant_names=["Nobody Here"])]))
        self.assertEqual(self.run_(snapshot([claim()])), {"unchanged": 1, "retired": 1})
        self.assertEqual((self.state(7)[0], self.state(8)[0]), ("shadow", "retired"))

    def test_a_retired_row_stands_again_when_the_claim_is_back(self):
        review = claim(claimant_names=["Nobody Here"])
        self.run_(snapshot([review]))
        self.run_(snapshot([]))
        self.assertEqual(self.run_(snapshot([review]), at="2026-11-15T00:00:00Z"), {"reopened": 1})
        self.assertEqual(self.state(), ("shadow", "", ""))
        self.assertEqual([r["claim_id"] for r in L.standing(self.db)], [7])
        self.assertEqual(self.events(), ["decided", "retired", "reopened"])
        self.assertEqual(self.run_(snapshot([review])), {"unchanged": 1})

    def test_a_retired_approval_does_not_outlive_a_changed_claim(self):
        # a retired row does not stand, so the claim that comes back is decided on what is true now
        self.run_(snapshot())
        self.run_(snapshot([]))
        self.assertEqual(self.run_(snapshot([claim(account_hold=True)])), {"reopened": 1})
        self.assertEqual((self.row()["outcome"], self.row()["reason"], self.state()[0]),
                         (L.REFUSED, "account_hold", "shadow"))
        self.assertEqual(self.events(), ["decided", "retired", "reopened"])
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_a_released_row_is_not_retired(self):
        self.run_(snapshot())
        L.release(self.db, 7, by="nick", why="sampled wrong")
        self.assertEqual(self.run_(snapshot([])), {})
        self.assertEqual(self.state(), ("released", "nick", "sampled wrong"))

    CDL1 = ("CREATE TABLE claim_doc_decisions (claim_id INTEGER PRIMARY KEY, outcome TEXT NOT NULL CHECK (outcome IN "
            "('approved', 'refused', 'needs_human_review', 'unreadable')), reason TEXT NOT NULL, "
            "state TEXT NOT NULL DEFAULT 'shadow')")

    def older_store(self, name="old.sqlite"):
        path = os.path.join(self.tmp.name, name)
        old = sqlite3.connect(path)
        old.execute(self.CDL1)
        old.execute("INSERT INTO claim_doc_decisions VALUES (7, 'needs_human_review', 'claimant_not_named', 'shadow')")
        old.execute("INSERT INTO claim_doc_decisions VALUES (8, 'unreadable', 'not_extracted', 'shadow')")
        old.commit()
        old.close()
        return path

    def test_an_older_ladders_decisions_are_set_aside_whole_and_every_claim_is_decided_again(self):
        """The deployed store holds `needs_human_review` rows: none may stand under this ladder."""
        db = L.open_store(self.older_store())
        self.addCleanup(db.close)
        kept = db.execute(f"SELECT claim_id, outcome FROM {L.ARCHIVE_TABLE} ORDER BY claim_id").fetchall()
        self.assertEqual([tuple(r) for r in kept], [(7, "needs_human_review"), (8, "unreadable")])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM claim_doc_decisions").fetchone()[0], 0)
        self.assertEqual(L.run(snapshot([claim(claimant_names=["Nobody Here"])]), POLICY, db)["recorded"],
                         {"decided": 1})
        got = db.execute("SELECT outcome, ask FROM claim_doc_decisions WHERE claim_id = 7").fetchone()
        self.assertEqual(tuple(got), (L.REFUSED, "proof_naming_claimant"))
        self.assertEqual(L.standing(db, L.AWAITING), [])

    def test_setting_an_older_table_aside_happens_once(self):
        path = self.older_store()
        L.open_store(path).close()
        db = L.open_store(path)
        self.addCleanup(db.close)
        self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {L.ARCHIVE_TABLE}").fetchone()[0], 2)
        self.assertIs(L.archive_older_decisions(db), False)

    def test_a_second_older_table_is_an_error_never_an_overwrite(self):
        path = self.older_store()
        L.open_store(path).close()
        raw = sqlite3.connect(path)
        raw.execute("DROP TABLE claim_doc_decisions")
        raw.execute(self.CDL1)
        raw.commit()
        raw.close()
        with self.assertRaisesRegex(RuntimeError, "cannot be reconciled"):
            L.open_store(path)

    def test_a_read_only_open_of_an_older_store_says_so_and_changes_nothing(self):
        path = self.older_store()
        with self.assertRaisesRegex(SystemExit, "older ladder"):
            L.open_store_ro(path)
        old = sqlite3.connect(path)
        self.addCleanup(old.close)
        self.assertEqual(old.execute("SELECT COUNT(*) FROM claim_doc_decisions").fetchone()[0], 2)
        self.assertIsNone(old.execute("SELECT 1 FROM sqlite_master WHERE name = ?", (L.ARCHIVE_TABLE,)).fetchone())

    def test_events_and_extractions_are_append_only(self):
        self.run_(snapshot())
        for sql in ("UPDATE claim_doc_events SET event = 'x'", "DELETE FROM claim_doc_events",
                    "UPDATE claim_doc_extractions SET extractor = 'x'", "DELETE FROM claim_doc_extractions"):
            with self.subTest(sql=sql), self.assertRaises(sqlite3.DatabaseError):
                self.db.execute(sql)

    def test_the_schema_refuses_what_the_ladder_must_never_write(self):
        self.run_(snapshot())
        for sql in ("UPDATE claim_doc_decisions SET reason = ''",
                    "UPDATE claim_doc_decisions SET source_sha256 = ''",
                    "UPDATE claim_doc_decisions SET extraction_sha256 = ''",
                    "UPDATE claim_doc_decisions SET outcome = 'maybe'",
                    "UPDATE claim_doc_decisions SET outcome = 'needs_human_review'",
                    "UPDATE claim_doc_decisions SET outcome = 'unreadable'",
                    "UPDATE claim_doc_decisions SET ask = 'readable_copy'",
                    "UPDATE claim_doc_decisions SET route = 'doc-verify'",
                    "UPDATE claim_doc_decisions SET outcome = 'refused'",
                    "UPDATE claim_doc_decisions SET outcome = 'resend'",
                    "UPDATE claim_doc_decisions SET outcome = 'awaiting_read'",
                    "UPDATE claim_doc_decisions SET outcome = 'awaiting_read', route = 'doc-verify', ask = 'x'",
                    "INSERT INTO claim_doc_decisions SELECT * FROM claim_doc_decisions"):
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)

    def test_a_row_we_owe_a_read_needs_no_extraction_but_still_a_document_and_a_job(self):
        self.run_(snapshot([claim()], {"11": [doc(extraction=None, extract_status="")]}))
        r = self.row()
        self.assertEqual((r["outcome"], r["reason"], r["extraction_sha256"], r["source_sha256"]),
                         (L.AWAITING, "not_extracted", "", SHA))
        self.assertEqual((r["ask"], r["route"]), ("", "doc-verify"))
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_a_resend_is_recorded_with_its_ask_and_rederives(self):
        gone = doc(extract_status="error", extraction=extraction(ok=False, error="no readable text"), read_final=True)
        self.run_(snapshot([claim()], {"11": [gone]}))
        r = self.row()
        self.assertEqual((r["outcome"], r["reason"], r["ask"], r["route"]),
                         (L.RESEND, "document_not_readable", "readable_copy", ""))
        self.assertEqual(L.verify(self.db), {"reproduced": 1, "mismatch": []})


class PolicyTests(unittest.TestCase):
    def test_a_malformed_policy_is_an_error_never_a_default(self):
        bad = [{}, {**POLICY, "version": "cdl-0"}, {**POLICY, "min_confidence": 0}, {**POLICY, "min_confidence": True},
               {**POLICY, "version": "cdl-1"},
               {**POLICY, "accepted_doc_types": {}}, {**POLICY, "accepted_doc_types": {"artist": []}},
               {**POLICY, "require_release_on_profile": "yes"}, []]
        for pol in bad:
            with self.subTest(pol=str(pol)[:60]), self.assertRaises(L.PolicyError):
                L.check_policy(pol)
        with self.assertRaises(L.PolicyError):
            L.load_policy("/nonexistent/policy.json")

    def test_the_policy_no_longer_chooses_which_contradictions_go_to_a_person(self):
        self.assertNotIn("refuse_on_contradiction", POLICY)
        self.assertEqual(POLICY["version"], L.VERSION)


class AskCopyTests(unittest.TestCase):
    """policies/claim-doc-asks.json: the words for each ask. Recorded only; nothing here sends."""

    def test_every_ask_the_ladder_can_record_has_words_and_there_is_no_other(self):
        self.assertEqual(set(COPY["asks"]), set(L.ASKS) - {L.NO_ASK})
        self.assertEqual(COPY["version"], L.ASK_COPY_VERSION)

    def test_every_reason_reaches_words_or_a_job_through_the_real_renderer(self):
        """reason -> ask -> the sentence, for every reason and every claim class the policy names."""
        for cls in list(POLICY["accepted_doc_types"]) + ["venue"]:
            for key, r in L.REASONS.items():
                asks = sorted(set(L.CONTRADICTION_ASKS.values())) if key == "contradiction" else [r.ask]
                for a in asks:
                    with self.subTest(cls=cls, reason=key, ask=a):
                        if r.outcome not in L.ASKED:
                            self.assertEqual(a, "")
                            continue
                        said = L.ask_text(a, cls, POLICY, COPY)
                        self.assertEqual(said == "", a == L.NO_ASK)
                        self.assertNotIn("{", said)

    def test_no_reason_code_and_no_refusal_reaches_the_claimant(self):
        internal = set(L.REASONS) | set(L.CONTRADICTION_ASKS) | set(L.ASKS) | set(L.OUTCOMES) | set(L.ROUTES)
        words = ("refus", "reject", "denied", "declin", "forg", "fraud", "fake", "suspicio", "contradict", "reused",
                 "impersonat", "hold", "review", "team", "agent", "staff", "someone", "a person")
        for cls in POLICY["accepted_doc_types"]:
            for a in COPY["asks"]:
                said = L.ask_text(a, cls, POLICY, COPY).lower()
                for code in internal:
                    with self.subTest(ask=a, code=code):
                        self.assertNotIn(code, said)
                for word in words:
                    with self.subTest(ask=a, word=word):
                        self.assertNotIn(word, said)

    def test_the_resend_ask_is_for_a_clear_copy_or_a_link(self):
        """Firstmate 2026-11-14: a copy we could not read gets this ask, in these words, not a general one."""
        for cls in POLICY["accepted_doc_types"]:
            with self.subTest(cls=cls):
                words = L.ask_text("readable_copy", cls, POLICY, COPY)
                self.assertIn("Please send a clear copy of it, or a link to it.", words)
                self.assertNotRegex(words, r"(?i)\b(you|your) (sent|file|upload)")      # no blame for the copy
        self.assertEqual({r.ask for r in L.REASONS.values() if r.outcome == L.RESEND}, {"readable_copy"})

    def test_an_ask_says_what_to_send(self):
        for a, text in COPY["asks"].items():
            with self.subTest(ask=a):
                self.assertRegex(text.lower(), r"\b(send|add|place|put)\b")

    def test_no_ask_names_an_identity_document(self):
        for cls in POLICY["accepted_doc_types"]:
            for a in COPY["asks"]:
                with self.subTest(cls=cls, ask=a):
                    self.assertIsNone(L.IDENTITY_DOCUMENT.search(L.ask_text(a, cls, POLICY, COPY)))

    def test_copy_that_asks_for_an_identity_document_does_not_load(self):
        asks, labels = COPY["asks"], COPY["doc_type_labels"]
        for words in ("Please send a copy of your passport.", "Please send your driver's license.",
                      "Please send a photo ID.", "Please send a government-issued ID.", "Please send your ID.",
                      "Please send your national identity card.", "Please send a selfie holding the document.",
                      "Please send proof of identity.", "Please send a utility bill."):
            with self.subTest(words=words), self.assertRaisesRegex(L.PolicyError, "identity document"):
                L.check_ask_copy({**COPY, "asks": {**asks, "proof_naming_claimant": words}})
        with self.assertRaisesRegex(L.PolicyError, "identity document"):
            L.check_ask_copy({**COPY, "doc_type_labels": {**labels, "letter": "a copy of your passport"}})

    def test_the_identity_rule_does_not_stop_the_words_an_ask_needs(self):
        for words in ("a royalty or distributor statement from your own account", "the Muso.AI link",
                      "written the way it is on your Muso.AI account", "valid for the profile", "paid invoice"):
            with self.subTest(words=words):
                self.assertIsNone(L.IDENTITY_DOCUMENT.search(words))

    def test_the_type_ask_names_exactly_the_types_the_class_accepts(self):
        for cls, kinds in POLICY["accepted_doc_types"].items():
            said = L.ask_text("accepted_document_type", cls, POLICY, COPY)
            for kind, label in COPY["doc_type_labels"].items():
                with self.subTest(cls=cls, kind=kind):
                    self.assertEqual(label in said, kind in kinds)

    def test_every_accepted_type_has_words(self):
        for cls, kinds in POLICY["accepted_doc_types"].items():
            self.assertLessEqual(set(kinds), set(COPY["doc_type_labels"]), cls)
        short = {**COPY, "doc_type_labels": {"contract": "a contract"}}
        with self.assertRaises(L.PolicyError):
            L.ask_text("accepted_document_type", "artist", POLICY, short)

    def test_a_copy_file_with_a_missing_or_an_extra_ask_is_an_error_never_a_default(self):
        asks = COPY["asks"]
        less = {k: v for k, v in asks.items() if k != "readable_copy"}
        bad = [{}, [], {**COPY, "version": "cda-0"}, {**COPY, "asks": less},
               {**COPY, "asks": {**asks, "ask_a_person": "We will have someone look."}},
               {**COPY, "asks": {**asks, L.NO_ASK: "Nothing."}},
               {**COPY, "asks": {**asks, "readable_copy": "  "}},
               {**COPY, "asks": {**asks, "accepted_document_type": "Please send a document."}},
               {**COPY, "doc_type_labels": {"contract": ""}}, {**COPY, "doc_type_labels": None}]
        for copy_ in bad:
            with self.subTest(copy=str(copy_)[:60]), self.assertRaises(L.PolicyError):
                L.check_ask_copy(copy_)
        with self.assertRaises(L.PolicyError):
            L.load_ask_copy("/nonexistent/asks.json")

    def test_an_ask_the_ladder_does_not_have_cannot_be_rendered(self):
        with self.assertRaises(ValueError):
            L.ask_text("ask_a_person", "artist", POLICY, COPY)

    def test_the_ask_is_recorded_by_name_so_rewording_it_re_decides_nothing(self):
        """The words a claimant reads are not an input to a decision: the row and the key hold the ask's
        name, and reworded copy renders different words for the same decision."""
        got = decide(claim(claimant_names=["Nobody Here"]))
        self.assertEqual((got.outcome, got.reason, got.ask), (L.REFUSED, "claimant_not_named", "proof_naming_claimant"))
        reworded = {**COPY, "asks": {**COPY["asks"], got.ask: "Say it differently."}}
        self.assertEqual(L.ask_text(got.ask, "artist", POLICY, reworded), "Say it differently.")
        self.assertNotEqual(L.ask_text(got.ask, "artist", POLICY, COPY), "Say it differently.")
        self.assertEqual(decide(claim(claimant_names=["Nobody Here"])).key, got.key)


class NoPersonTests(unittest.TestCase):
    """Captain 2026-11-13: no verification path ends at a person."""

    def test_every_route_names_a_job_that_exists_and_runs_that_work(self):
        """A route promises a read, so it names a job: a cron in cron-jobs.json that runs that script
        and subcommand, or the timer unit that starts the ladder's own pass. No route is exempt, and
        a route added without one flips the count below. Whether a cron is switched on is not this
        test's: it is read live (`job_state`), because a job can ship unarmed."""
        jobs = json.loads((ROOT / "cron-jobs.json").read_text(encoding="utf-8"))["jobs"]
        enabled = {j.get("name"): (j.get("payload") or {}).get("argv") or [] for j in jobs}
        self.assertEqual(set(L.ROUTES), {"doc-verify", "byte-restore", "doc-sources"})
        for name, route in L.ROUTES.items():
            with self.subTest(route=name):
                self.assertTrue((ROOT / route.script).is_file(), route.script)
                self.assertEqual(bool(route.cron), not route.unit)
                if not route.cron:
                    continue
                self.assertIn(route.cron, enabled, f"{route.cron} is not a cron in cron-jobs.json")
                argv = enabled[route.cron]
                self.assertTrue(any(str(x).endswith("/" + route.script) for x in argv), argv)
                self.assertTrue(all(a in argv for a in route.argv), argv)

    def test_the_byte_restore_job_ships_switched_off_and_the_ladder_says_so(self):
        """Firstmate 2026-11-14: an hourly production job never arrives armed as a side effect of a
        merge. The cron is in the file, off, and the rows waiting on it are reported with the job's
        real state: a route never reads as work in progress while nothing runs it."""
        jobs = {j["name"]: j for j in json.loads((ROOT / "cron-jobs.json").read_text(encoding="utf-8"))["jobs"]}
        self.assertIs(jobs["credit-doc-verify-blob-backfill"]["enabled"], False)
        self.assertEqual(L.job_state("byte-restore"), L.JOB_DISABLED)
        self.assertEqual(L.job_state("doc-verify"), L.JOB_ENABLED)
        self.assertEqual(L.job_state("doc-sources"), L.JOB_TIMER)

    def test_a_job_state_that_cannot_be_read_is_never_enabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cron-jobs.json")
            self.assertEqual(L.job_state("byte-restore", path), L.JOB_UNREAD)            # no file
            for body, want in (("{not json", L.JOB_UNREAD), ("[]", L.JOB_UNREAD), ('{"jobs": null}', L.JOB_UNREAD),
                               ('{"jobs": []}', L.JOB_MISSING),
                               ('{"jobs": [{"name": "credit-doc-verify-blob-backfill"}]}', L.JOB_DISABLED),
                               ('{"jobs": [{"name": "credit-doc-verify-blob-backfill", "enabled": "true"}]}',
                                L.JOB_DISABLED),
                               ('{"jobs": [{"name": "credit-doc-verify-blob-backfill", "enabled": true}]}',
                                L.JOB_ENABLED)):
                with self.subTest(body=body):
                    Path(path).write_text(body, encoding="utf-8")
                    self.assertEqual(L.job_state("byte-restore", path), want)

    def test_a_row_waiting_on_a_switched_off_job_is_reported_as_waiting_on_a_switched_off_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = L.open_store(os.path.join(tmp, "d.sqlite"))
            self.addCleanup(db.close)
            snap = snapshot([claim()], {"11": [doc(extraction=None, extract_status="", has_bytes=False)]})
            L.run(snap, POLICY, db, at="2026-11-01T00:00:00Z")
            off = os.path.join(tmp, "off.json")
            Path(off).write_text('{"jobs": [{"name": "credit-doc-verify-blob-backfill", "enabled": false}]}')
            on = os.path.join(tmp, "on.json")
            Path(on).write_text('{"jobs": [{"name": "credit-doc-verify-blob-backfill", "enabled": true}]}')
            now = datetime(2026, 11, 2, tzinfo=timezone.utc)
            self.assertEqual([(r["route"], r["reason"], r["n"], r["job"])
                              for r in L.awaiting_age(db, now=now, cron_jobs=off)],
                             [("byte-restore", "no_bytes_on_file", 1, L.JOB_DISABLED)])
            self.assertEqual([r["job"] for r in L.awaiting_age(db, now=now, cron_jobs=on)], [L.JOB_ENABLED])
            # the shipped file: off
            self.assertEqual([r["job"] for r in L.awaiting_age(db, now=now)], [L.JOB_DISABLED])

    def test_a_route_with_no_scheduled_job_cannot_be_registered(self):
        """The registration check is the guard, not the prose: a route naming neither schedule fails."""
        with self.assertRaises(ValueError):
            L._check_routes({"gmail": L.Route("gmail-fetch reads it, some day", "scripts/credit-doc-verify.py")})
        with self.assertRaises(ValueError):
            L._check_routes({"both": L.Route("two schedules", "scripts/credit-doc-verify.py", cron="a", unit="b")})

    def test_the_timer_route_runs_the_pass_that_unit_starts(self):
        """claim-doc-ladder.timer starts the launcher with no argv; that path is the read the
        `doc-sources` route promises, executed here through the real launcher."""
        import runpy
        route = L.ROUTES["doc-sources"]
        self.assertEqual((route.unit, route.script, route.argv), ("claim-doc-ladder.timer", "scripts/claim-doc-ladder.py", ()))
        seen = []
        real = S.main
        S.main = lambda argv: seen.append(list(argv)) or 0
        self.addCleanup(setattr, S, "main", real)
        self.addCleanup(setattr, sys, "argv", sys.argv)
        sys.argv = [str(ROOT / route.script)]
        with self.assertRaises(SystemExit) as exit:
            runpy.run_path(str(ROOT / route.script), run_name="__main__")
        self.assertEqual((exit.exception.code, seen), (0, [["--tick"]]))

    def test_the_routes_the_ladder_owes_itself_are_the_ones_that_show_an_age(self):
        """The ladder does not read a document: a route that names the ladder's own pass is only honest
        because that pass re-reads the fact and the row keeps the day it was decided."""
        self.assertEqual(L.ROUTES["doc-sources"].unit, "claim-doc-ladder.timer")
        src = {code for code, reason in L.REASONS.items() if reason.route == "doc-sources"}
        self.assertEqual(src, {"catalog_unreadable", "bound_code_unmeasured", "releases_unmeasured",
                               "account_hold_unmeasured"})
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        db = L.open_store(os.path.join(tmp.name, "d.sqlite"))
        self.addCleanup(db.close)
        snap = snapshot([claim(account_hold=None)])
        self.assertEqual(L.run(snap, POLICY, db, at="2026-11-01T00:00:00Z")["recorded"], {"decided": 1})
        self.assertEqual(L.run(snap, POLICY, db, at="2026-11-09T00:00:00Z")["recorded"], {"unchanged": 1})
        self.assertEqual([(r["route"], r["reason"], r["n"], r["oldest"], r["age_hours"]) for r in
                          L.awaiting_age(db, now=datetime(2026, 11, 13, tzinfo=timezone.utc))],
                         [("doc-sources", "account_hold_unmeasured", 1, "2026-11-01T00:00:00Z", 288.0)])

    def test_every_decision_any_fact_can_produce_is_one_of_the_four_and_says_who_moves(self):
        """Each fact the ladder reads, broken one at a time, through the real `decide_claim`."""
        failed = extraction(ok=False, error="http 503")
        claims = [claim(), claim(claimant_names=[]), claim(claimant_names=["Nobody Here"]),
                  claim(decline_snapshot=None, profile_in_catalog=False, releases=None),
                  claim(decline_snapshot=None, profile_in_catalog=None, releases=None), claim(profile_type="venue"),
                  claim(snap_kw={"deceased": frozenset({PID})}), claim(core={"email_domain": "cloudtestlabaccounts.com"}),
                  claim(core={"pk_profile_other_claims": [{"userId": 99, "status": "processed"}]}),
                  claim(code_found_other_claims=None), claim(code_found_other_claims=[8]), claim(releases=None),
                  claim(releases={SHA: {"named": 3, "on_profile": 0}}), claim(releases={SHA: {"named": 0, "on_profile": 0}}),
                  claim(profile={"name": "Nova Kane", "popularity": dr.BIG_POPULARITY, "creditCount": 1}),
                  claim(profile={"name": "Nova Kane", "popularity": None, "creditCount": None}),
                  claim(account_hold=True), claim(account_hold=None)]
        docs = [doc(), doc(extraction=None, extract_status=""), doc(extraction=None, extract_status="", has_bytes=False),
                doc(extract_status="error", extraction=failed), doc(extract_status="error", extraction=failed, read_final=True),
                doc(extract_status="error", extraction=failed, read_final=True, tooling_error=True),
                doc(extraction=extraction(credits=[], tracks=[], issuer={}, signatory={})),
                doc(extraction=extraction(doc_type="credits_page")),
                doc(extraction=extraction(credits=[{"person": "Jane Doe", "role": "writer", "confidence": 0.95}])),
                doc(blocking_verdicts=["forged"]), doc(blocking_verdicts=["contradicted"]), doc(other_filers=1)]
        seen = set()
        for c in claims:
            for d in docs:
                got = decide(c, [d])
                seen.add(got.reason.split(":")[0])
                with self.subTest(reason=got.reason):
                    self.assertIn(got.outcome, L.OUTCOMES)
                    self.assertEqual(got.outcome in L.ASKED, bool(got.ask))
                    self.assertEqual(got.outcome == L.AWAITING, bool(got.route))
                    self.assertEqual(got.outcome == L.APPROVED, not got.ask and not got.route)
                    self.assertIn(got.route, set(L.ROUTES) | {""})
                    self.assertIn(got.ask, set(L.ASKS) | {""})
        self.assertEqual(seen, set(L.REASONS), "every reason in the table was reached by a real decision")


def trino_out(rows):
    """Rows as trino-query.sh prints them: every field quoted, so `decline_rules._rows` keeps the line."""
    buf = io.StringIO()
    csv.writer(buf, quoting=csv.QUOTE_ALL).writerows(rows)
    return "Query 2026 done\n" + buf.getvalue()


class SourcesTests(unittest.TestCase):
    U2 = "c" * 64

    def setUp(self):
        self.proof = sqlite3.connect(":memory:")
        self.proof.execute("CREATE TABLE proof_intake (intake_id TEXT, user_id INTEGER, subject TEXT, "
                           "file_sha256 TEXT, file_path TEXT, received_at TEXT)")
        self.docs = sqlite3.connect(":memory:")
        self.docs.execute("CREATE TABLE dv_steps (id INTEGER PRIMARY KEY AUTOINCREMENT, proof_id TEXT, step TEXT, "
                          "status TEXT, detail_json TEXT, version TEXT)")
        self.docs.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, proof_id TEXT, "
                          "request_id TEXT, role TEXT, outcome TEXT, version TEXT)")
        self.addCleanup(self.proof.close)
        self.addCleanup(self.docs.close)

    def intake(self, uid, sha, path="/blobs/x", at="2026-11-01T00:00:00Z", subject="credit"):
        self.proof.execute("INSERT INTO proof_intake VALUES (?,?,?,?,?,?)",
                           (f"{uid}:{sha[:8]}", uid, subject, sha, path, at))

    def step(self, sha, status, body, version="dv-4", step="extract"):
        self.docs.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES (?,?,?,?,?)",
                          (sha, step, status, json.dumps(body), version))

    def outcome(self, sha, request, role, outcome, version="dv-4"):
        self.docs.execute("INSERT INTO dv_outcomes (proof_id, request_id, role, outcome, version) VALUES (?,?,?,?,?)",
                          (sha, request, role, outcome, version))

    def test_open_claims_counts_a_claim_with_no_account_and_keeps_a_nameless_one(self):
        out = trino_out([["7", "11", PID, "artist", "pending", "Jane", "Doe", ""],
                         ["8", "", PID, "organization", "pending", "", "", ""],
                         ["9", "12", PID, "artist", "reverted", "", "", ""],
                         ["10", "13", PID, "artist", "pending", "Jane", "Doe", "Jane Q Doe"]])
        claims, no_account = S.open_claims(lambda sql: out)
        self.assertEqual(no_account, [8])
        self.assertEqual([(c["claim_id"], c["claimant_names"]) for c in claims],
                         [(7, ["Jane Doe"]), (9, []), (10, ["Jane Q Doe", "Jane Doe"])])

    def test_open_claims_reads_only_open_live_claims_with_a_left_join(self):
        seen = []
        S.open_claims(lambda sql: seen.append(sql) or trino_out([["8", "", PID, "organization", "pending", "", "", ""]]))
        self.assertIn("left join postgresql_core.public.users", seen[0])
        self.assertIn("c.deletedat is null", seen[0])
        self.assertIn("('pending','reverted')", seen[0])

    def test_a_read_with_no_rows_is_an_error_not_an_empty_population(self):
        # the pass retires what the snapshot does not hold: "nothing answered" must not retire everything
        with self.assertRaisesRegex(RuntimeError, "no rows"):
            S.open_claims(lambda sql: trino_out([]))
        with self.assertRaisesRegex(RuntimeError, "proof_intake read: no rows"):
            self.build()

    def test_a_short_row_is_an_error_not_a_skipped_claim(self):
        with self.assertRaises(RuntimeError):
            S.open_claims(lambda sql: trino_out([["7", "11", PID]]))

    def test_documents_carry_the_newest_answer_of_the_current_version(self):
        self.intake(11, SHA)
        self.step(SHA, "ok", extraction(doc_type="invoice"))
        self.step(SHA, "ok", extraction(doc_type="contract"))
        self.step(SHA, "provider_down", {"ok": False})
        self.step(SHA, "ok", extraction(doc_type="letter"), version="dv-3")
        self.step(SHA, "ok", {"chars": 9}, step="text")
        got = S.documents(self.proof, self.docs, [11])["11"]
        self.assertEqual(len(got), 1)
        self.assertEqual((got[0]["extract_status"], got[0]["extraction"]["doc_type"], got[0]["source_sha256"]),
                         ("ok", "contract", SHA))

    def test_documents_without_a_read_or_without_bytes(self):
        self.intake(11, SHA, path=None)
        self.intake(11, self.U2, at="2026-11-02T00:00:00Z")
        self.step(self.U2, "error", {"ok": False, "error": "no readable text"})
        a, b = S.documents(self.proof, self.docs, [11])["11"]
        self.assertEqual((a["has_bytes"], a["extract_status"], a["extraction"]), (False, "", None))
        self.assertEqual((b["has_bytes"], b["extract_status"]), (True, "error"))

    def one(self, uid=11):
        return S.documents(self.proof, self.docs, [uid])[str(uid)][0]

    def decided(self, d):
        got = decide(docs=[d])
        return got.outcome, got.reason, got.ask, got.route

    def test_a_document_doc_verify_never_answered_about_is_not_final(self):
        self.intake(11, SHA)
        self.step(SHA, "provider_down", {"ok": False, "error": "http 503"})
        d = self.one()
        self.assertIs(d["read_final"], False)
        self.assertIs(d["tooling_error"], False)
        self.assertEqual(self.decided(d), (L.AWAITING, "not_extracted", "", "doc-verify"))

    def test_a_read_that_answered_is_final(self):
        self.intake(11, SHA)
        self.step(SHA, "ok", extraction())
        d = self.one()
        self.assertIs(d["read_final"], True)
        self.assertIs(d["tooling_error"], False)
        self.assertEqual(self.decided(d)[0], L.APPROVED)

    def test_a_failure_doc_verify_still_retries_is_ours_and_asks_nothing(self):
        """The rule is doc-verify's own (`runner.extract_settled`): a transient failure, attempts left."""
        from credit_verify.docverify import runner
        self.intake(11, SHA)
        for _ in range(runner.MAX_EXTRACT_ATTEMPTS - 1):
            self.step(SHA, "error", {"ok": False, "error": "http 503 from the provider"})
        d = self.one()
        self.assertIs(d["read_final"], False)
        self.assertEqual(self.decided(d), (L.AWAITING, "extraction_failed", "", "doc-verify"))

    def test_out_of_attempts_on_our_own_tooling_asks_for_a_copy_and_records_it_was_ours(self):
        from credit_verify.docverify import runner
        self.intake(11, SHA)
        for _ in range(runner.MAX_EXTRACT_ATTEMPTS):
            self.step(SHA, "error", {"ok": False, "error": "http 503 from the provider"})
        d = self.one()
        self.assertIs(d["read_final"], True)
        self.assertIs(d["tooling_error"], True)
        self.assertEqual(self.decided(d), (L.RESEND, "extraction_gave_up", "readable_copy", ""))

    def test_a_document_with_nothing_to_read_asks_for_a_copy_and_records_it_was_the_file(self):
        self.intake(11, SHA)
        self.step(SHA, "error", {"ok": False, "error": "no readable text in the document"})
        d = self.one()
        self.assertIs(d["read_final"], True)
        self.assertIs(d["tooling_error"], False)
        self.assertEqual(self.decided(d), (L.RESEND, "document_not_readable", "readable_copy", ""))

    def test_bytes_we_lost_are_recorded_as_ours(self):
        for error in ("document not located", "sandbox failed: oom"):
            with self.subTest(error=error):
                self.docs.execute("DELETE FROM dv_steps")
                self.proof.execute("DELETE FROM proof_intake")
                self.intake(11, SHA)
                self.step(SHA, "error", {"ok": False, "error": error})
                d = self.one()
                self.assertIs(d["tooling_error"], True)
                self.assertEqual(self.decided(d)[1], "extraction_gave_up")

    def test_a_later_good_read_ends_the_resend(self):
        self.intake(11, SHA)
        self.step(SHA, "error", {"ok": False, "error": "no readable text in the document"})
        self.step(SHA, "ok", extraction())
        self.assertEqual(self.decided(self.one())[0], L.APPROVED)

    def test_a_stored_extraction_that_is_not_json_is_ours(self):
        self.intake(11, SHA)
        self.docs.execute("INSERT INTO dv_steps (proof_id, step, status, detail_json, version) VALUES (?,?,?,?,?)",
                          (SHA, "extract", "error", "{not json", "dv-4"))
        d = self.one()
        self.assertIs(d["tooling_error"], True)
        self.assertNotIn(self.decided(d)[0], L.VERDICTS)

    def test_whose_failure_it_was_is_doc_verifys_own_rule_not_a_second_copy(self):
        """The two questions are doc-verify's, answered by its own code: what its tooling-error list and
        `runner.extract_settled` say about an answer is exactly what the document carries."""
        from types import SimpleNamespace
        from credit_verify.docverify import gate, runner
        for error in ("document not located", "sandbox failed: oom", "http 503 from the provider",
                      "no readable text in the document", "the provider said no"):
            for attempts in (1, runner.MAX_EXTRACT_ATTEMPTS):
                with self.subTest(error=error, attempts=attempts):
                    self.docs.execute("DELETE FROM dv_steps")
                    self.proof.execute("DELETE FROM proof_intake")
                    self.intake(11, SHA)
                    for _ in range(attempts):
                        self.step(SHA, "error", {"ok": False, "error": error})
                    d = self.one()
                    self.assertEqual(d["tooling_error"], error.startswith(gate.TOOLING_ERRORS))
                    self.assertEqual(d["read_final"], runner.extract_settled(SimpleNamespace(db=self.docs), SHA))

    def test_a_role_once_blocked_and_never_rejudged_still_blocks(self):
        self.intake(11, SHA)
        self.outcome(SHA, "r1", "Writer", "forged")
        self.outcome(SHA, "r1", "Producer", "contradicted")
        self.outcome(SHA, "r1", "Producer", "verified")
        self.outcome(SHA, "r2", "Writer", "contradicted", version="dv-3")
        self.assertEqual(S.documents(self.proof, self.docs, [11])["11"][0]["blocking_verdicts"], ["forged"])

    def test_the_same_bytes_from_another_account_are_counted(self):
        self.intake(11, SHA)
        self.intake(12, SHA)
        self.intake(13, SHA.upper())
        self.assertEqual(S.documents(self.proof, self.docs, [11])["11"][0]["other_filers"], 2)

    def test_named_titles_use_doc_verifys_one_title_rule(self):
        ex = extraction(tracks=[{"title": "Night Drive (feat. Someone)", "confidence": 0.9},
                                {"title": "NIGHT  DRIVE", "confidence": 0.9}, {"title": "Love", "confidence": 0.9},
                                {"title": "Unsure", "confidence": 0.2}, {"title": None, "confidence": 0.9}, "x"])
        keys = S.named_titles(ex, 0.6)
        self.assertEqual(len(keys), 2)
        self.assertEqual(S.named_titles(None, 0.6), set())
        titles = S.profile_titles(lambda sql: trino_out([[PID, "Night Drive"], [PID, "Love Again"]]), [PID])
        self.assertEqual(len(keys & titles[PID]), 1, '"Love" is not "Love Again"')

    def build(self, listed=({}, ""), held=(set(), ""), snapshots=None, known=(PID,)):
        def run(sql):
            if "claiming c left join" in sql:
                return trino_out([["7", "11", PID, "artist", "pending", "Jane", "Doe", ""],
                                  ["8", "12", PID, "artist", "pending", "No", "Docs", ""],
                                  ["9", "", PID, "organization", "pending", "", "", ""]])
            if "matvw_profile_credit" in sql:
                return trino_out([[p, "Night Drive"] for p in known])
            if "catalog_profile" in sql:
                return trino_out([[p] for p in known])
            raise AssertionError(sql)
        core = {"id": 7, "userId": 11, "profileId": PID, "profileType": "artist", "reason": None, "status": "pending",
                "createdAt": None, "email_domain": "example.org"}
        snaps = snapshots or (lambda ids, run: {7: dr.snapshot(core, {"name": "Nova Kane", "popularity": 1,
                                                                    "creditCount": 1})})
        return S.build(run, self.proof, self.docs, listed=listed, held=held, snapshots=snaps, min_confidence=0.6)

    def test_build_keeps_only_claims_with_a_document_and_counts_the_rest(self):
        self.intake(11, SHA)
        self.step(SHA, "ok", extraction())
        snap = self.build()
        self.assertEqual([c["claim_id"] for c in snap["claims"]], [7])
        self.assertEqual(list(snap["documents"]), ["11"])
        src = snap["sources"]
        self.assertEqual((src["open_claims"], src["open_claims_without_account"], src["open_claims_with_document"],
                          src["open_claims_without_document"], src["documents"]), (3, 1, 1, 1, 1))
        c = snap["claims"][0]
        self.assertEqual((c["account_hold"], c["code_found_other_claims"], c["releases"]),
                         (False, [], {SHA: {"named": 1, "on_profile": 1}}))
        decisions, _ = L.plan(snap, POLICY)
        self.assertEqual([(d.claim_id, d.outcome) for d, _ in decisions], [(7, L.APPROVED)])

    def test_an_unread_source_is_recorded_as_unread_never_as_clean(self):
        self.intake(11, SHA)
        self.step(SHA, "ok", extraction())
        snap = self.build(listed=(None, "the claim list is 40.0h old (limit 30h)"), held=(None, "holds_stale"))
        c = snap["claims"][0]
        self.assertIsNone(c["account_hold"])
        self.assertIsNone(c["code_found_other_claims"])
        self.assertEqual(snap["sources"]["claim_list"], "the claim list is 40.0h old (limit 30h)")
        self.assertEqual(snap["sources"]["account_holds"], "holds_stale")
        self.assertEqual(L.plan(snap, POLICY)[0][0][0].reason, "bound_code_unmeasured")

    def test_held_account_and_a_code_found_for_another_claim_on_the_profile(self):
        self.intake(11, SHA)
        self.step(SHA, "ok", extraction())
        listed = {7: {"claim_id": 7, "profile_id": PID, "code_found": False, "paid": True},
                  21: {"claim_id": 21, "profile_id": PID.upper(), "code_found": True},
                  22: {"claim_id": 22, "profile_id": "other", "code_found": True}}
        c = self.build(listed=(listed, ""), held=({"11"}, ""))["claims"][0]
        self.assertEqual((c["account_hold"], c["code_found_other_claims"], c["paid"]), (True, [21], True))

    def test_a_profile_the_catalog_does_not_have(self):
        self.intake(11, SHA)
        self.step(SHA, "ok", extraction())
        snap = self.build(snapshots=lambda ids, run: {}, known=())
        c = snap["claims"][0]
        self.assertEqual((c["profile_in_catalog"], c["decline_snapshot"], c["releases"]), (False, None, None))
        self.assertEqual(snap["sources"]["profile_not_in_catalog"], 1)
        self.assertEqual(L.plan(snap, POLICY)[0][0][0].reason, "profile_not_in_catalog")

    def test_a_failed_read_raises(self):
        self.intake(11, SHA)

        def boom(ids, run):
            raise RuntimeError("trino failed rc=1")
        with self.assertRaises(RuntimeError):
            self.build(snapshots=boom)


class TickTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = os.path.join(self.tmp.name, "state")
        self.kill = os.path.join(self.tmp.name, "kill")

    def tick(self, read):
        return S.tick(self.state, POLICY, read, kill_file=self.kill)

    def test_a_pass_records_rederives_and_leaves_private_files(self):
        rc, summary = self.tick(snapshot)
        self.assertEqual(rc, 0)
        self.assertEqual((summary["recorded"], summary["reproduced"], summary["not_reproducible"]),
                         ({"decided": 1}, 1, []))
        for name in ("snapshot.json", "latest.json"):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.state, name)).st_mode), 0o600, name)
        latest = Path(self.state, "latest.json").read_text()
        self.assertNotIn("Jane", latest)
        self.assertNotIn("Nova", latest)
        rc, summary = self.tick(snapshot)
        self.assertEqual((rc, summary["recorded"]), (0, {"unchanged": 1}))

    def test_a_pass_retires_the_claim_that_is_gone_and_says_so(self):
        self.tick(snapshot)
        rc, summary = self.tick(lambda: snapshot([]))
        self.assertEqual((rc, summary["recorded"], summary["reproduced"]), (0, {"retired": 1}, 1))

    def test_the_stop_switch_reads_nothing_and_records_nothing(self):
        Path(self.kill).write_text("")

        def read():
            raise AssertionError("read while stopped")
        self.assertEqual(self.tick(read), (0, {"stopped": self.kill}))
        self.assertFalse(os.path.exists(self.state))

    def test_a_read_that_does_not_answer_records_nothing(self):
        def read():
            raise RuntimeError("trino failed rc=1")
        with self.assertRaises(RuntimeError):
            self.tick(read)
        self.assertFalse(os.path.exists(self.state))

    def test_a_decision_that_cannot_be_rederived_fails_the_pass(self):
        self.tick(snapshot)
        db = sqlite3.connect(os.path.join(self.state, "decisions.sqlite"))
        inputs = json.loads(db.execute("SELECT inputs_json FROM claim_doc_decisions").fetchone()[0])
        inputs["claim"]["account_hold"] = True
        db.execute("UPDATE claim_doc_decisions SET inputs_json = ?", (L.canonical(inputs),))
        db.commit()
        db.close()
        rc, summary = self.tick(snapshot)
        self.assertEqual((rc, summary["not_reproducible"]), (1, [7]))

    def test_the_entrypoint_loads_as_a_file(self):
        import subprocess
        p = subprocess.run([sys.executable, str(ROOT / "scripts/claim-doc-ladder.py"), "--help"],
                           capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_the_summary_counts_who_moves_next_and_has_no_person_bucket(self):
        unread = claim(claim_id=8, user_id=12)
        snap = snapshot([claim(claimant_names=["Nobody Here"]), unread],
                        {"11": [doc()], "12": [doc(extraction=None, extract_status="")]})
        rc, summary = self.tick(lambda: snap)
        self.assertEqual(rc, 0)
        split = summary["split"]
        self.assertEqual((split["claims"], split["verdicts"], split["asked"], split["awaiting_read"]), (2, 1, 1, 1))
        self.assertEqual(split["asks"], {"proof_naming_claimant": 1})
        self.assertEqual(split["awaiting_by_route"], {"doc-verify": 1})
        self.assertEqual([(r["route"], r["reason"], r["n"]) for r in summary["awaiting"]],
                         [("doc-verify", "not_extracted", 1)])
        self.assertEqual(json.loads(Path(self.state, "latest.json").read_text())["awaiting"][0]["n"], 1)
        self.assertEqual(set(json.loads(Path(self.state, "latest.json").read_text())["split"]["by_outcome"]),
                         set(L.OUTCOMES))

    def test_the_list_command_prints_the_ask_in_words_through_the_real_entrypoint(self):
        import subprocess
        self.tick(lambda: snapshot([claim(claimant_names=["Nobody Here"])]))
        store = os.path.join(self.state, "decisions.sqlite")
        p = subprocess.run([sys.executable, str(ROOT / "scripts/claim-doc-ladder.py"), "list", "--store", store],
                           capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = [json.loads(line) for line in p.stdout.splitlines()]
        self.assertEqual([(r["claim_id"], r["ask"]) for r in rows], [(7, "proof_naming_claimant")])
        self.assertEqual(rows[0]["ask_text"], COPY["asks"]["proof_naming_claimant"])
        self.assertNotIn("claimant_not_named", rows[0]["ask_text"])
        self.assertNotIn("age_hours", rows[0])
        gone = subprocess.run([sys.executable, str(ROOT / "scripts/claim-doc-ladder.py"), "queue", "--store", store],
                              capture_output=True, text=True, check=False)
        self.assertNotEqual(gone.returncode, 0, "the person's worklist command is gone")

    def test_the_list_command_shows_how_long_a_row_we_owe_the_read_of_has_waited(self):
        import subprocess
        self.tick(lambda: snapshot([claim(account_hold=None)]))
        store = os.path.join(self.state, "decisions.sqlite")
        p = subprocess.run([sys.executable, str(ROOT / "scripts/claim-doc-ladder.py"), "list", "--store", store,
                            "--outcome", "awaiting_read"], capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = [json.loads(line) for line in p.stdout.splitlines()]
        self.assertEqual([(r["route"], r["ask"]) for r in rows], [("doc-sources", "")])
        self.assertIsInstance(rows[0]["age_hours"], float)
        self.assertNotIn("ask_text", rows[0])


# The split the deployed ladder (cdl-1) recorded on node-8, 2026-11-13T20:42Z, over the 219 open claims
# with a document on file: what each claim stopped on. The real rows hold names and never leave node-8,
# so the fixture rebuilds the same shape from synthetic facts.
MEASURED = {"document_names_claimant_and_profile": 1,
            "claimant_not_named": 58, "profile_not_in_catalog": 27, "doc_type_not_accepted": 14,
            "profile_not_named": 12, "no_release_named": 2, "releases_not_on_profile": 1,      # 114 needs_human_review
            "not_extracted": 63, "no_bytes_on_file": 32, "extraction_failed": 8, "empty_extraction": 1}  # 104 unreadable
# cdl-1 did not record whether doc-verify would read a failed document again, so the 8 are split
# here by assumption, one of each kind at least: still retried, out of attempts, nothing to read.
FAILED_AS = (["retried"] * 2) + (["gave_up"] * 2) + (["no_text"] * 4)


# The 153 claims the claim proof ask leaves out because the claimant has a document on file and a
# standing ladder row (node-8, 2026-11-13T23:20Z, measured by claims-no-doc-ask-p1): 153 claims of
# 120 people, 36 of them paid. Same shape, synthetic facts.
MEASURED_153 = {"document_names_claimant_and_profile": 2,
                "claimant_not_named": 62, "profile_not_in_catalog": 26, "doc_type_not_accepted": 14,
                "profile_not_named": 10, "no_release_named": 4, "releases_not_on_profile": 2,   # 118 needs_human_review
                "empty_extraction": 13, "no_bytes_on_file": 10, "extraction_failed": 6, "not_extracted": 4}  # 33
# As above, the 6 are split by assumption: the deployed ladder did not record which kind each was.
FAILED_AS_153 = (["retried"] * 2) + (["gave_up"] * 2) + (["no_text"] * 2)
# Which 36 are paid was not measured per outcome, so they are spread evenly: 4 of every 17.
PAID_153 = frozenset(n for n in range(1, 154) if n % 17 < 4)


def measured_population(measured=MEASURED, failed_as=FAILED_AS, paid=None):
    claims, documents, n = [], {}, 0
    for reason, count in measured.items():
        for i in range(count):
            n += 1
            sha = f"{n:064x}"
            c_over, d_over = {"releases": {sha: {"named": 1, "on_profile": 1}}}, {}
            if reason == "claimant_not_named":
                c_over["claimant_names"] = ["Nobody Here"]
            elif reason == "profile_not_in_catalog":
                c_over.update(decline_snapshot=None, profile_in_catalog=False, releases=None)
            elif reason == "doc_type_not_accepted":
                d_over["extraction"] = extraction(doc_type=("credits_page", "other", "email")[i % 3])
            elif reason == "profile_not_named":
                d_over["extraction"] = extraction(credits=[{"person": "Jane Doe", "role": "writer", "confidence": 0.95}])
            elif reason == "no_release_named":
                c_over["releases"] = {sha: {"named": 0, "on_profile": 0}}
            elif reason == "releases_not_on_profile":
                c_over["releases"] = {sha: {"named": 2, "on_profile": 0}}
            elif reason == "not_extracted":
                d_over.update(extraction=None, extract_status="")
            elif reason == "no_bytes_on_file":
                d_over.update(extraction=None, extract_status="", has_bytes=False)
            elif reason == "extraction_failed":
                kind = failed_as[i]
                error = {"retried": "http 503", "gave_up": "http 503", "no_text": "no readable text"}[kind]
                d_over.update(extract_status="error", extraction=extraction(ok=False, error=error),
                              read_final=kind != "retried", tooling_error=kind == "gave_up")
            elif reason == "empty_extraction":
                d_over["extraction"] = extraction(credits=[], tracks=[], issuer={}, signatory={})
            if paid is not None:
                c_over["paid"] = n in paid
            claims.append(claim(claim_id=n, user_id=1000 + n, **c_over))
            documents[str(1000 + n)] = [doc(sha, **d_over)]
    return snapshot(claims, documents)


class MeasuredPopulationTests(unittest.TestCase):
    """The 219 documented claims, in the shape measured, through plan -> run -> verify -> list."""

    @classmethod
    def setUpClass(cls):
        cls.snap = measured_population()
        cls.decisions = [d for d, _ in L.plan(cls.snap, POLICY)[0]]
        cls.split = L.split(cls.decisions)

    def by(self, outcome):
        return [d for d in self.decisions if d.outcome == outcome]

    def test_the_fixture_is_the_measured_split(self):
        self.assertEqual(sum(MEASURED.values()), 219)
        self.assertEqual(len(FAILED_AS), MEASURED["extraction_failed"])
        self.assertEqual(len(self.snap["claims"]), 219)
        self.assertEqual(len(self.decisions), 219)

    def test_no_claim_ends_at_a_person(self):
        self.assertEqual({d.outcome for d in self.decisions} - set(L.OUTCOMES), set())
        said = L.canonical([d.as_dict() for d in self.decisions]) + L.canonical(self.split)
        self.assertNotIn("needs_human_review", said)
        self.assertNotIn("unreadable", said)
        self.assertEqual(self.split["claims"], 219)
        self.assertEqual(self.split["verdicts"] + len(self.by(L.RESEND)) + self.split["awaiting_read"], 219)

    def test_every_claim_a_person_was_handed_is_refused_with_what_to_send(self):
        refused = self.by(L.REFUSED)
        self.assertEqual(len(refused), 114)
        self.assertEqual(self.split["by_outcome"][L.REFUSED]["reasons"],
                         {k: MEASURED[k] for k in ("claimant_not_named", "profile_not_in_catalog", "doc_type_not_accepted",
                                                   "profile_not_named", "no_release_named", "releases_not_on_profile")})
        for d in refused:
            with self.subTest(claim_id=d.claim_id, reason=d.reason):
                said = ask(d)
                self.assertTrue(said)
                self.assertNotIn(d.reason, said)
                self.assertEqual(d.route, "")

    def test_the_asks_are_the_specific_ones(self):
        asks = dict(self.split["asks"])
        self.assertEqual(asks.pop("readable_copy"), 7)
        self.assertEqual(asks, {"proof_naming_claimant": 58, "claimed_profile_link": 27, "accepted_document_type": 14,
                                "proof_naming_profile": 12, "release_on_profile": 3})

    def test_a_document_we_have_not_read_gets_no_verdict_and_no_ask(self):
        waiting = self.by(L.AWAITING)
        self.assertEqual(len(waiting), 63 + 32 + 2)
        self.assertEqual(self.split["awaiting_by_route"], {"doc-verify": 65, "byte-restore": 32})
        for d in waiting:
            with self.subTest(claim_id=d.claim_id):
                self.assertEqual(d.ask, "")
                self.assertNotIn(d.outcome, L.VERDICTS)
                self.assertIn(d.route, L.ROUTES)

    def test_a_document_that_cannot_be_read_is_asked_for_again_and_never_refused(self):
        resend = self.by(L.RESEND)
        self.assertEqual(len(resend), 6 + 1)
        self.assertEqual({d.ask for d in resend}, {"readable_copy"})
        self.assertEqual(sorted({d.reason for d in resend}),
                         ["document_not_readable", "empty_extraction", "extraction_gave_up"])
        unread = {"not_extracted", "no_bytes_on_file", "extraction_failed", "extraction_gave_up",
                  "document_not_readable", "empty_extraction"}
        self.assertEqual([d.reason for d in self.by(L.REFUSED) if d.reason in unread], [])

    def test_the_one_approval_still_approves(self):
        self.assertEqual([d.reason for d in self.by(L.APPROVED)], ["document_names_claimant_and_profile"])

    def test_recorded_rederived_and_listed_with_nobody_left_over(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = L.open_store(os.path.join(tmp, "d.sqlite"))
            self.addCleanup(db.close)
            self.assertEqual(L.run(self.snap, POLICY, db)["recorded"], {"decided": 219})
            self.assertEqual(L.verify(db), {"reproduced": 219, "mismatch": []})
            listed = {o: L.standing(db, o) for o in L.OUTCOMES}
            self.assertEqual({o: len(rows) for o, rows in listed.items()},
                             {L.APPROVED: 1, L.REFUSED: 114, L.RESEND: 7, L.AWAITING: 97})
            self.assertEqual(sum(len(rows) for rows in listed.values()), 219)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM claim_doc_decisions WHERE ask = '' AND route = '' "
                                        "AND outcome != 'approved'").fetchone()[0], 0)
            self.assertEqual(L.run(self.snap, POLICY, db)["recorded"], {"unchanged": 219})

    def test_when_doc_verify_reads_what_it_owes_the_claim_gets_its_verdict_or_its_ask(self):
        """The 97 are not parked: the job's answer is all the next pass needs."""
        snap = copy.deepcopy(self.snap)
        for docs in snap["documents"].values():
            for d in docs:
                if d["extraction"] is None or d["extract_status"] == "error":
                    d.update(extraction=extraction(), extract_status="ok", has_bytes=True, read_final=True,
                             tooling_error=False)
        after = L.split(d for d, _ in L.plan(snap, POLICY)[0])
        self.assertEqual(after["awaiting_read"], 0)
        self.assertEqual(after["by_outcome"][L.APPROVED]["n"], 1 + 63 + 32 + 8)


class HeldBackPopulationTests(unittest.TestCase):
    """The 153 claims with a document on file that the claim proof ask leaves out: 118 the deployed
    ladder parked for a person, 33 it called unreadable, 2 it approved. 36 are paid."""

    @classmethod
    def setUpClass(cls):
        cls.snap = measured_population(MEASURED_153, FAILED_AS_153, PAID_153)
        cls.decisions = [d for d, _ in L.plan(cls.snap, POLICY)[0]]
        cls.split = L.split(cls.decisions)

    def by(self, outcome):
        return [d for d in self.decisions if d.outcome == outcome]

    def test_the_fixture_is_the_measured_split(self):
        self.assertEqual(sum(MEASURED_153.values()), 153)
        self.assertEqual(len(PAID_153), 36)
        self.assertEqual(len(FAILED_AS_153), MEASURED_153["extraction_failed"])
        self.assertEqual(len(self.decisions), 153)

    def test_the_36_paid_claims_are_decided_before_every_other_claim(self):
        self.assertEqual([d.paid for d in self.decisions], [True] * 36 + [False] * 117)
        self.assertEqual({d.claim_id for d in self.decisions[:36]}, set(PAID_153))
        for part in (self.decisions[:36], self.decisions[36:]):
            ids = [d.claim_id for d in part]
            self.assertEqual(ids, sorted(ids))

    def test_none_of_the_118_ends_at_a_person(self):
        refused = self.by(L.REFUSED)
        self.assertEqual(len(refused), 118)
        self.assertEqual(self.split["by_outcome"][L.REFUSED]["reasons"],
                         {k: v for k, v in MEASURED_153.items()
                          if k in ("claimant_not_named", "profile_not_in_catalog", "doc_type_not_accepted",
                                   "profile_not_named", "no_release_named", "releases_not_on_profile")})
        for d in refused:
            self.assertIn(d.ask, L.ASKS)
            self.assertNotEqual(d.ask, L.NO_ASK)
            self.assertEqual(d.route, "")
        self.assertNotIn("needs_human_review", L.canonical([d.as_dict() for d in self.decisions]))
        self.assertTrue({d.outcome for d in self.decisions} <= set(L.OUTCOMES))

    def test_the_33_split_into_copies_we_could_not_read_and_reads_we_still_owe(self):
        """A copy doc-verify has finished with and could not read is the claimant's move: the
        clear-copy-or-link ask. A document we have not read yet is ours, and asks for nothing."""
        resend, awaiting = self.by(L.RESEND), self.by(L.AWAITING)
        self.assertEqual(len(resend) + len(awaiting), 33)
        self.assertEqual({d.ask for d in resend}, {"readable_copy"})
        self.assertEqual(dict(Counter(d.reason for d in resend)),
                         {"empty_extraction": 13, "extraction_gave_up": 2, "document_not_readable": 2})
        self.assertEqual(dict(Counter((d.reason, d.route) for d in awaiting)),
                         {("no_bytes_on_file", "byte-restore"): 10, ("not_extracted", "doc-verify"): 4,
                          ("extraction_failed", "doc-verify"): 2})
        for d in awaiting:
            self.assertEqual(d.ask, "")
            self.assertNotIn(d.outcome, L.VERDICTS)

    def test_the_2_approvals_are_written_to_the_store_and_not_only_eligible(self):
        """Written means a row in the ladder's own store, with both hashes and its `decided` event.
        Nothing here writes to core: that executor does not exist."""
        with tempfile.TemporaryDirectory() as tmp:
            db = L.open_store(os.path.join(tmp, "d.sqlite"))
            self.addCleanup(db.close)
            self.assertEqual(L.run(self.snap, POLICY, db)["recorded"], {"decided": 153})
            rows = db.execute("SELECT claim_id, reason, state, source_sha256, extraction_sha256, ask, route "
                              "FROM claim_doc_decisions WHERE outcome = 'approved' ORDER BY claim_id").fetchall()
            self.assertEqual([(r[0], r[1], r[2], r[5], r[6]) for r in rows],
                             [(1, "document_names_claimant_and_profile", "shadow", "", ""),
                              (2, "document_names_claimant_and_profile", "shadow", "", "")])
            for r in rows:
                self.assertEqual(len(r[3]), 64)
                self.assertEqual(len(r[4]), 64)
            self.assertEqual([r[0] for r in db.execute(
                "SELECT event FROM claim_doc_events WHERE claim_id IN (1, 2) ORDER BY rowid")], ["decided"] * 2)
            self.assertEqual(L.verify(db), {"reproduced": 153, "mismatch": []})
            self.assertEqual({o: len(L.standing(db, o)) for o in L.OUTCOMES},
                             {L.APPROVED: 2, L.REFUSED: 118, L.RESEND: 17, L.AWAITING: 16})
            for outcome in L.OUTCOMES:
                paid = [r["paid"] for r in L.standing(db, outcome)]
                self.assertEqual(paid, sorted(paid, reverse=True), outcome)             # paid first in every list
            waiting = Counter()
            for r in L.awaiting_age(db):
                waiting[(r["route"], r["job"])] += r["n"]
            self.assertEqual(dict(waiting), {("byte-restore", L.JOB_DISABLED): 10, ("doc-verify", L.JOB_ENABLED): 6})


if __name__ == "__main__":
    unittest.main()
