#!/usr/bin/env python3
"""The claim document ladder (scripts/claim_verify/doc_ladder.py + doc_sources.py) and the one
page-id rule it shares (scripts/lib/page_identity.py). Hermetic: no network, no Trino, temp stores."""
import copy
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

    def test_unreadable_reasons(self):
        cases = {
            "no_bytes_on_file": doc(extraction=None, extract_status="", has_bytes=False),
            "not_extracted": doc(extraction=None, extract_status="", has_bytes=True),
            "extraction_failed": doc(extract_status="error", extraction=extraction(ok=False, error="no readable text")),
            "degraded_extraction": doc(extraction=extraction(degraded=True)),
            "empty_extraction": doc(extraction=extraction(credits=[], tracks=[], issuer={}, signatory={})),
        }
        for reason, d in cases.items():
            with self.subTest(reason=reason):
                got = decide(docs=[d])
                self.assertEqual((got.outcome, got.reason), (L.UNREADABLE, reason))

    def test_ok_false_is_never_read_even_when_it_names_everyone(self):
        got = decide(docs=[doc(extraction=extraction(ok=False))])
        self.assertEqual((got.outcome, got.reason), (L.UNREADABLE, "extraction_failed"))

    def test_an_extraction_that_is_not_an_object_is_unreadable(self):
        for body in ("approved", ["approved"], 1):
            with self.subTest(body=body):
                self.assertEqual(decide(docs=[doc(extraction=body)]).outcome, L.UNREADABLE)

    def test_parsed_but_empty_is_never_approved_for_any_claim_facts(self):
        """Even a claim whose every other fact is clean."""
        empty = extraction(credits=[], tracks=[], issuer=None, signatory=None, doc_type="split_sheet")
        self.assertEqual(decide(docs=[doc(extraction=empty)]).outcome, L.UNREADABLE)


class NamePredicateTests(unittest.TestCase):
    def test_claimant_not_named(self):
        got = decide(claim(claimant_names=["Someone Else"]))
        self.assertEqual((got.outcome, got.reason), (L.REVIEW, "claimant_not_named"))

    def test_claimant_with_no_name_on_the_account(self):
        for names in ([], ["  "], ["---"]):
            with self.subTest(names=names):
                self.assertEqual(decide(claim(claimant_names=names)).reason, "claimant_name_unknown")

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
        self.assertEqual((got.outcome, got.reason), (L.REVIEW, "profile_not_named"))

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

    def test_profile_not_in_catalog_and_catalog_unread_are_different_reasons(self):
        self.assertEqual(decide(claim(decline_snapshot=None, profile_in_catalog=False, releases=None)).reason,
                         "profile_not_in_catalog")
        self.assertEqual(decide(claim(decline_snapshot=None, profile_in_catalog=None, releases=None)).reason,
                         "catalog_unreadable")

    def test_one_name_for_both_is_recorded(self):
        got = decide(claim(profile={"name": "Jane Doe", "popularity": 1, "creditCount": 1}))
        self.assertEqual(got.outcome, L.APPROVED)
        self.assertTrue(next(g for g in got.gates if g.name == "names_profile").detail["same_as_claimant"])


class DocTypeTests(unittest.TestCase):
    def test_types_a_claim_class_does_not_accept_go_to_a_person(self):
        for kind in ("credits_page", "email", "email_screenshot", "receipt", "other", ""):
            with self.subTest(kind=kind):
                got = decide(docs=[doc(extraction=extraction(doc_type=kind))])
                self.assertEqual((got.outcome, got.reason), (L.REVIEW, "doc_type_not_accepted"))

    def test_every_accepted_type_passes_for_its_class(self):
        for cls, kinds in POLICY["accepted_doc_types"].items():
            for kind in kinds:
                with self.subTest(cls=cls, kind=kind):
                    c = claim(core={"profileType": cls})
                    self.assertEqual(decide(c, [doc(extraction=extraction(doc_type=kind))]).outcome, L.APPROVED)

    def test_an_organization_is_not_claimed_on_a_split_sheet(self):
        self.assertEqual(decide(claim(core={"profileType": "organization"})).reason, "doc_type_not_accepted")

    def test_unknown_claim_class(self):
        self.assertEqual(decide(claim(profile_type="venue")).reason, "claim_class_unknown")

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

    def test_a_class_the_policy_does_not_list_goes_to_a_person(self):
        pol = {**POLICY, "refuse_on_contradiction": []}
        got = decide(claim(snap_kw={"deceased": frozenset({PID})}), policy=pol)
        self.assertEqual((got.outcome, got.reason), (L.REVIEW, "contradiction:deceased_self_claim"))

    def test_the_policy_refuses_only_classes_the_decline_rule_can_produce(self):
        body = (ROOT / "scripts/claim_verify/decline_rules.py").read_text()
        for cls in POLICY["refuse_on_contradiction"]:
            self.assertIn(f'"{cls}"', body)

    def test_the_contradiction_is_the_decline_rules_own_answer(self):
        c = claim(snap_kw={"deceased": frozenset({PID})})
        self.assertEqual(dr.reproduce(c["decline_snapshot"]).contradiction, "deceased_self_claim")

    def test_profile_already_held_by_another_account(self):
        got = decide(claim(core={"pk_profile_other_claims": [{"userId": 99, "status": "processed"}]}))
        self.assertEqual((got.outcome, got.reason), (L.REVIEW, "profile_already_claimed"))
        got = decide(claim(core={"pk_profile_other_claims": [{"userId": 99, "status": "rejected"}]}))
        self.assertEqual(got.outcome, L.APPROVED)

    def test_bound_code(self):
        self.assertEqual(decide(claim(code_found_other_claims=None)).reason, "bound_code_unmeasured")
        got = decide(claim(code_found_other_claims=[8]))
        self.assertEqual((got.outcome, got.reason), (L.REVIEW, "bound_code_other_claim"))

    def test_releases(self):
        self.assertEqual(decide(claim(releases=None)).reason, "releases_unmeasured")
        self.assertEqual(decide(claim(releases={})).reason, "releases_unmeasured")
        self.assertEqual(decide(claim(releases={SHA: {"named": 3, "on_profile": 0}})).reason,
                         "releases_not_on_profile")
        self.assertEqual(decide(claim(releases={SHA: {"named": 0, "on_profile": 0}})).reason, "no_release_named")

    def test_without_the_release_requirement_only_a_contradiction_stops(self):
        pol = {**POLICY, "require_release_on_profile": False}
        self.assertEqual(decide(claim(releases={SHA: {"named": 0, "on_profile": 0}}), policy=pol).outcome, L.APPROVED)
        self.assertEqual(decide(claim(releases={SHA: {"named": 2, "on_profile": 0}}), policy=pol).reason,
                         "releases_not_on_profile")

    def test_catalog_unread_is_not_a_pass(self):
        c = claim(decline_snapshot=None)
        c["profile_in_catalog"] = True
        self.assertEqual(decide(c).outcome, L.REVIEW)


class CleanTests(unittest.TestCase):
    def test_blocking_verdicts_and_reuse(self):
        for d, reason in ((doc(blocking_verdicts=["forged"]), "document_forged"),
                          (doc(blocking_verdicts=["contradicted"]), "document_contradicted"),
                          (doc(blocking_verdicts=["contradicted", "forged"]), "document_forged"),
                          (doc(other_filers=1), "document_reused")):
            with self.subTest(reason=reason):
                got = decide(docs=[d])
                self.assertEqual((got.outcome, got.reason), (L.REVIEW, reason))

    def test_big_profile_uses_the_claim_sides_own_thresholds(self):
        for prof in ({"name": "Nova Kane", "popularity": dr.BIG_POPULARITY, "creditCount": 1},
                     {"name": "Nova Kane", "popularity": 1, "creditCount": dr.BIG_CREDITS}):
            with self.subTest(prof=prof):
                self.assertEqual(decide(claim(profile=prof)).reason, "big_profile")
        small = {"name": "Nova Kane", "popularity": dr.BIG_POPULARITY - 1, "creditCount": dr.BIG_CREDITS - 1}
        self.assertEqual(decide(claim(profile=small)).outcome, L.APPROVED)

    def test_profile_size_unread_is_not_small(self):
        self.assertEqual(decide(claim(profile={"name": "Nova Kane", "popularity": None, "creditCount": None})).reason,
                         "catalog_unreadable")

    def test_account_hold(self):
        self.assertEqual(decide(claim(account_hold=True)).reason, "account_hold")
        self.assertEqual(decide(claim(account_hold=None)).reason, "account_hold_unmeasured")
        self.assertEqual(decide(claim(account_hold="no")).reason, "account_hold_unmeasured")


class ManyDocumentsTests(unittest.TestCase):
    B = "b" * 64

    def both(self, first, second):
        c = claim(releases={SHA: {"named": 1, "on_profile": 1}, self.B: {"named": 1, "on_profile": 1}})
        return decide(c, [first, second])

    def test_the_best_document_decides(self):
        got = self.both(doc(extraction=None, extract_status=""), doc(self.B))
        self.assertEqual((got.outcome, got.source_sha256), (L.APPROVED, self.B))
        self.assertEqual([d["outcome"] for d in got.documents], [L.UNREADABLE, L.APPROVED])

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
                self.assertEqual((got.outcome, got.reason), (L.REVIEW, reason))
                self.assertEqual(got.gates[-1].name, "clean_across_documents")


class ReasonCodeTests(unittest.TestCase):
    def test_every_reason_has_exactly_one_outcome_and_only_one_approves(self):
        self.assertLessEqual(set(L.REASONS.values()), set(L.OUTCOMES))
        self.assertEqual([r for r, o in L.REASONS.items() if o == L.APPROVED], ["document_names_claimant_and_profile"])
        self.assertNotIn(L.REFUSED, L.REASONS.values(), "a refusal exists only through a policy-listed contradiction")

    def test_every_reason_in_the_code_is_registered(self):
        body = (ROOT / "scripts/claim_verify/doc_ladder.py").read_text()
        used = set(re.findall(r'_fail\(name, "([a-z_]+)"', body)) | set(L.BLOCKING.values()) | set(L.POISON)
        self.assertLessEqual(used, set(L.REASONS))
        self.assertEqual(set(L.REASONS) - used - {"document_names_claimant_and_profile", "not_extracted",
                                                  "no_bytes_on_file"}, set())

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

    def test_split_counts_and_skips(self):
        snap = snapshot([claim(), claim(claim_id=8, user_id=12), claim(claim_id=9, status="processed"),
                         claim(claim_id=10, claimant_names=["Nobody Here"])])
        decisions, skipped = L.plan(snap, POLICY)
        self.assertEqual(skipped, {"no_document": 1, "not_open": 1})
        s = L.split(d for d, _ in decisions)
        self.assertEqual((s["claims_decided"], s["auto_decided"], s["needs_human_review"], s["unreadable"]),
                         (2, 1, 1, 0))
        self.assertEqual(s["by_outcome"][L.REVIEW]["reasons"], {"claimant_not_named": 1})

    def test_the_outcome_and_the_evidence_are_in_the_decision_key(self):
        import dataclasses
        a = decide()
        self.assertEqual(a.key, decide().key)
        for field, other in (("outcome", L.REVIEW), ("reason", "account_hold"), ("source_sha256", "b" * 64),
                             ("extraction_sha256", "c" * 64), ("policy_sha256", "d" * 64), ("claim_id", 8)):
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

    def test_a_review_is_superseded_by_a_new_document(self):
        self.assertEqual(self.run_(snapshot([claim()], {"11": [doc(extraction=extraction(doc_type="other"))]})),
                         {"decided": 1})
        self.assertEqual(self.row()["outcome"], L.REVIEW)
        self.assertEqual(self.run_(snapshot()), {"superseded": 1})
        self.assertEqual(self.row()["outcome"], L.APPROVED)
        self.assertEqual(self.events(), ["decided", "superseded"])
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_an_approval_is_not_replaced_and_the_drift_is_logged_once(self):
        self.run_(snapshot())
        key = self.row()["decision_key"]
        held = snapshot([claim(account_hold=True)])
        self.assertEqual(self.run_(held), {"drift": 1})
        self.assertEqual(self.run_(held), {"drift": 1})
        self.assertEqual((self.row()["outcome"], self.row()["decision_key"]), (L.APPROVED, key))
        self.assertEqual(self.events(), ["decided", "drift"])

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
        self.assertEqual(self.run_(snapshot()), {"released": 1}, "the same decision does not come back by itself")
        self.assertEqual(self.run_(snapshot([claim(account_hold=True)])), {"redecided": 1})
        self.assertEqual((self.row()["state"], self.row()["outcome"], self.row()["state_by"]), ("shadow", L.REVIEW, ""))
        self.assertEqual(self.events(), ["decided", "released", "redecided"])

    def test_the_queue_is_what_a_person_works_with_the_reason_on_every_row(self):
        self.run_(snapshot([claim(), claim(claim_id=8, claimant_names=["Nobody Here"]),
                            claim(claim_id=9, account_hold=True)]), at="2026-11-12T00:00:00Z")
        rows = L.queue(self.db)
        self.assertEqual([(r["claim_id"], r["reason"], r["stopped_at"]) for r in rows],
                         [(8, "claimant_not_named", "names_claimant"), (9, "account_hold", "clean")])
        self.assertTrue(all(r["reason"] and r["source_sha256"] == SHA and r["documents_on_file"] == 1 for r in rows))
        self.assertEqual([r["claim_id"] for r in L.queue(self.db, L.APPROVED)], [7])
        L.release(self.db, 8, by="nick", why="worked")
        self.assertEqual([r["claim_id"] for r in L.queue(self.db)], [9], "a released row has left the queue")
        with self.assertRaises(ValueError):
            L.queue(self.db, "maybe")

    def state(self, claim_id=7):
        r = self.row(claim_id)
        return r["state"], r["state_by"], r["state_reason"]

    def test_a_claim_that_left_the_population_leaves_the_queue(self):
        review = claim(claimant_names=["Nobody Here"])
        self.assertEqual(self.run_(snapshot([review])), {"decided": 1})
        self.assertEqual([r["claim_id"] for r in L.queue(self.db)], [7])
        self.assertEqual(self.run_(snapshot([]), at="2026-11-13T00:00:00Z"), {"retired": 1})
        self.assertEqual(L.queue(self.db), [], "a closed claim is nobody's work")
        self.assertEqual(self.state(), ("retired", "claim-doc-ladder", "claim_not_open_or_no_document"))
        self.assertEqual(self.row()["state_at"], "2026-11-13T00:00:00Z")
        self.assertEqual((self.row()["outcome"], self.row()["reason"]), (L.REVIEW, "claimant_not_named"),
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
                self.assertEqual(L.queue(db, L.APPROVED), [], "an approved row is retired like any other")

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
        self.assertEqual([r["claim_id"] for r in L.queue(self.db)], [7])
        self.assertEqual(self.events(), ["decided", "retired", "reopened"])
        self.assertEqual(self.run_(snapshot([review])), {"unchanged": 1})

    def test_a_retired_approval_does_not_outlive_a_changed_claim(self):
        # a standing approval is never replaced (drift); a retired one does not stand, so the claim
        # that comes back is decided on what is true now
        self.run_(snapshot())
        self.run_(snapshot([]))
        self.assertEqual(self.run_(snapshot([claim(account_hold=True)])), {"reopened": 1})
        self.assertEqual((self.row()["outcome"], self.row()["reason"], self.state()[0]),
                         (L.REVIEW, "account_hold", "shadow"))
        self.assertEqual(self.events(), ["decided", "retired", "reopened"])
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_a_released_row_is_not_retired(self):
        self.run_(snapshot())
        L.release(self.db, 7, by="nick", why="sampled wrong")
        self.assertEqual(self.run_(snapshot([])), {})
        self.assertEqual(self.state(), ("released", "nick", "sampled wrong"))

    def test_a_store_made_before_the_retired_state_is_refused(self):
        path = os.path.join(self.tmp.name, "old.sqlite")
        old = sqlite3.connect(path)
        old.executescript(L.SCHEMA.replace(", 'retired')", ")"))
        old.close()
        with self.assertRaisesRegex(RuntimeError, "retired"):
            L.open_store(path)

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
                    "INSERT INTO claim_doc_decisions SELECT * FROM claim_doc_decisions"):
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)

    def test_an_unreadable_decision_needs_no_extraction_but_still_a_document(self):
        self.run_(snapshot([claim()], {"11": [doc(extraction=None, extract_status="")]}))
        r = self.row()
        self.assertEqual((r["outcome"], r["reason"], r["extraction_sha256"], r["source_sha256"]),
                         (L.UNREADABLE, "not_extracted", "", SHA))
        self.assertEqual(L.verify(self.db)["mismatch"], [])


class PolicyTests(unittest.TestCase):
    def test_a_malformed_policy_is_an_error_never_a_default(self):
        bad = [{}, {**POLICY, "version": "cdl-0"}, {**POLICY, "min_confidence": 0}, {**POLICY, "min_confidence": True},
               {**POLICY, "accepted_doc_types": {}}, {**POLICY, "accepted_doc_types": {"artist": []}},
               {**POLICY, "refuse_on_contradiction": "deceased_self_claim"},
               {**POLICY, "require_release_on_profile": "yes"}, []]
        for pol in bad:
            with self.subTest(pol=str(pol)[:60]), self.assertRaises(L.PolicyError):
                L.check_policy(pol)
        with self.assertRaises(L.PolicyError):
            L.load_policy("/nonexistent/policy.json")


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


if __name__ == "__main__":
    unittest.main()
