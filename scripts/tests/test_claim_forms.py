#!/usr/bin/env python3
"""The claim forms (scripts/claim_verify/forms.py) and the intake they are supplied through
(claim_verify/doc_ladder.py `claim_doc_supplies`, read by claim_verify/doc_sources.py).

What is pinned here is the captain's rule and nothing else: an offer we cannot check is worse than
no offer, so a claim is only ever asked for a form whose facts were read, the document is the last
rung of every ordering, a supplied form that does not settle is checked against facts we hold and
never against the claimant's word, and the verdict row says which form settled it.

Hermetic: no network, no Trino, temp stores.
"""
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from claim_verify import decline_rules as dr  # noqa: E402
from claim_verify import doc_ladder as L  # noqa: E402
from claim_verify import doc_sources as S  # noqa: E402
from claim_verify import forms  # noqa: E402

PID = "aaaaaaaa-1111-2222-3333-444444444444"
OTHER = "bbbbbbbb-1111-2222-3333-444444444444"
SHA = "a" * 64
POLICY = L.load_policy()
COPY = L.load_ask_copy()
CLASSES = sorted(POLICY["accepted_doc_types"])


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


def claim(profile_type="artist", profile=None, holdings=(), code_found="unset", **over):
    core = {"id": 7, "userId": 11, "profileId": PID, "profileType": profile_type, "reason": None,
            "status": "pending", "createdAt": "2026-10-01T00:00:00Z",
            "verificationLinks": {}, "pk_profile_other_claims": list(holdings),
            "email_domain": "novakane.com", "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True}
    c = {"claim_id": 7, "user_id": 11, "profile_id": PID, "profile_type": profile_type,
         "status": "pending", "claimant_names": ["Jane Doe"], "paid": True, "account_hold": False,
         "code_found_other_claims": [], "profile_in_catalog": True,
         "releases": {SHA: {"named": 1, "on_profile": 1}},
         "decline_snapshot": dr.snapshot(core, profile or {"name": "Nova Kane", "popularity": 12,
                                                          "creditCount": 40}),
         "code_found_other_claims": [] if code_found == "unset" else code_found,
         "form_facts": {}, "supplied_forms": ()}
    c.update(over)
    return c


def snapshot(claims, documents=None):
    return {"version": L.VERSION, "read_at": "2026-11-16T00:00:00Z", "claims": claims,
            "documents": documents if documents is not None else {}, "sources": {}}


# ------------------------------------------------------------------------------------------------
# Which form a class is asked in: the offer, and what it must never be
# ------------------------------------------------------------------------------------------------

class OfferTests(unittest.TestCase):
    def test_an_organization_with_a_published_domain_is_asked_for_an_address_from_it(self):
        facts = {"profile_hosts": ["brightlabel.com"],
                 "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@brightlabel.com"),
                 "account_email_domain": "brightlabel.com",
                 "account_email_confirmed": True}
        self.assertEqual(forms.offered("company_authority", "organization", facts), forms.FORM_EMAIL)

    def test_an_unconfirmed_account_mailbox_is_never_offered_the_email(self):
        # the offer must not ask for an answer that can never pass: without a confirmed mailbox the
        # document rung is the ask
        facts = {"profile_hosts": ["brightlabel.com"],
                 "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@brightlabel.com"),
                 "account_email_confirmed": False}
        self.assertEqual(forms.offered("company_authority", "organization", facts), forms.FORM_DOCUMENT)

    def test_a_confirmed_mailbox_at_a_domain_the_profile_does_not_publish_is_never_offered(self):
        """No answer could satisfy the form: the only address there could be is at gmail, which the
        check refuses as free mail and as not the profile's domain, so the offer is the document."""
        facts = {"profile_hosts": ["brightlabel.com"],
                 "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@gmail.com"),
                 "account_email_domain": "gmail.com",
                 "account_email_confirmed": True}
        self.assertEqual(forms.offered("company_authority", "organization", facts), forms.FORM_DOCUMENT)

    def test_the_offer_and_the_check_agree_on_every_host_it_offers_over(self):
        for host, domain in (("brightlabel.com", "brightlabel.com"),
                             ("brightlabel.com", "mail.brightlabel.com"),
                             ("brightlabel.com", "instagram.com"),
                             ("brightlabel.com", "notbrightlabel.com")):
            with self.subTest(host=host, domain=domain):
                facts = {"profile_hosts": [host],
                         "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, f"jane@{domain}"),
                         "account_email_domain": domain,
                         "account_email_confirmed": True}
                got = forms.check(forms.FORM_EMAIL, f"jane@{domain}", facts)
                self.assertEqual(forms.offered("company_authority", "organization", facts) == forms.FORM_EMAIL,
                                 got.ok is True)

    def test_an_account_mailbox_we_did_not_read_is_never_offered_the_email(self):
        facts = {"profile_hosts": ["brightlabel.com"], "account_email_confirmed": None}
        self.assertEqual(forms.offered("company_authority", "organization", facts), forms.FORM_DOCUMENT)

    def test_a_person_is_asked_for_a_document_because_no_form_they_could_send_is_checkable_yet(self):
        facts = {"profile_titles": ["night drive"]}
        self.assertEqual(forms.offered("proof_naming_claimant", "artist", facts), forms.FORM_DOCUMENT)

    def test_a_form_whose_facts_were_not_read_is_never_offered(self):
        self.assertEqual(forms.offered("proof_naming_claimant", "artist", {}), forms.FORM_DOCUMENT)

    def test_an_unread_host_never_offers_an_email(self):
        self.assertEqual(forms.offered("company_authority", "organization", {"profile_hosts": None}),
                         forms.FORM_DOCUMENT)

    def test_a_number_we_hold_no_source_for_is_never_offered(self):
        # nothing publishes a profile phone to us today, so `checkable` says no and the phone ask is
        # never delivered even where the table names it
        self.assertEqual(forms.offered("company_authority", "organization",
                                       {"profile_hosts": ["brightlabel.com"], "profile_phones": None,
                                        "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@brightlabel.com"),
                                        "account_email_domain": "brightlabel.com",
                                        "account_email_confirmed": True}),
                         forms.FORM_EMAIL)

    def test_the_document_is_the_last_rung_and_always_answerable(self):
        for cls in CLASSES:
            for ask_key in L.ASKS:
                if ask_key == L.NO_ASK:
                    continue
                with self.subTest(cls=cls, ask=ask_key):
                    self.assertEqual(forms.offered(ask_key, cls, {}), forms.FORM_DOCUMENT)

    def test_a_class_no_form_was_reviewed_for_is_asked_for_the_document(self):
        facts = {"profile_hosts": ["brightlabel.com"], "profile_titles": ["night drive"],
                 "profile_phones": ["+15551234567"]}
        for ask_key, by_class in forms.FORMS_BY_ASK.items():
            with self.subTest(ask=ask_key):
                self.assertEqual(forms.offered(ask_key, "venue", facts), forms.FORM_DOCUMENT)

    def test_a_form_already_supplied_and_refused_is_never_asked_for_again(self):
        facts = {"profile_hosts": ["brightlabel.com"]}
        self.assertEqual(forms.offered("company_authority", "organization", facts,
                                       exclude=(forms.FORM_EMAIL,)), forms.FORM_DOCUMENT)

    def test_every_form_the_table_can_choose_has_words_on_file(self):
        for ask_key, by_class in forms.FORMS_BY_ASK.items():
            for cls, order in by_class.items():
                for form in order:
                    if form == forms.FORM_DOCUMENT or not forms.checkable(form, L.ALL_FACTS):
                        continue
                    with self.subTest(cls=cls, ask=ask_key, form=form):
                        self.assertTrue(L.ask_text(ask_key, cls, POLICY, COPY, form=form))

    def test_a_form_no_source_can_check_has_reserved_words_and_never_a_delivered_line(self):
        reserved = COPY["reserved_form_asks"]["company_authority"]["phone_number"]
        self.assertTrue(reserved.strip())
        with self.assertRaises(L.PolicyError):
            L.ask_text("company_authority", "organization", POLICY, COPY, form=forms.FORM_PHONE)

    def test_a_class_is_only_ever_offered_a_form_that_can_settle_it(self):
        facts = {"profile_hosts": ["brightlabel.com"], "profile_titles": ["night drive"],
                 "profile_phones": ["+15551234567"]}
        for cls in CLASSES:
            for ask_key in L.ASKS:
                if ask_key == L.NO_ASK:
                    continue
                with self.subTest(cls=cls, ask=ask_key):
                    self.assertIn(forms.offered(ask_key, cls, facts), forms.forms_of(ask_key, cls))


# ------------------------------------------------------------------------------------------------
# What each form's check makes of what was supplied
# ------------------------------------------------------------------------------------------------

class EmailCheckTests(unittest.TestCase):
    def facts(self, **over):
        f = {"profile_hosts": ["novakane.com"], "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True}
        f.update(over)
        return f

    def test_the_accounts_own_address_at_a_published_domain_settles_it(self):
        got = forms.check(forms.FORM_EMAIL, "Jane@NovaKane.com", self.facts())
        self.assertIs(got.ok, True)

    def test_another_local_part_at_the_same_domain_never_settles(self):
        got = forms.check(forms.FORM_EMAIL, "madeup@novakane.com", self.facts())
        self.assertEqual((got.ok, got.reason), (False, "email_not_the_accounts_address"))

    def test_an_unread_account_address_is_unmeasured_never_approved(self):
        got = forms.check(forms.FORM_EMAIL, "jane@novakane.com", self.facts(account_email_sha256=None))
        self.assertEqual((got.ok, got.reason), (None, "account_email_unread"))

    def test_the_accounts_address_alone_never_settles_when_the_profile_does_not_publish_it(self):
        got = forms.check(forms.FORM_EMAIL, "jane@novakane.com", self.facts(profile_hosts=["other.com"]))
        self.assertEqual((got.ok, got.reason), (False, "email_domain_not_the_profiles"))

    def test_a_free_mail_account_address_never_settles(self):
        got = forms.check(forms.FORM_EMAIL, "jane@gmail.com",
                          self.facts(account_email_sha256=forms.value_digest(forms.FORM_EMAIL, "jane@gmail.com"), profile_hosts=["gmail.com"]))
        self.assertEqual((got.ok, got.reason), (False, "email_at_free_mail"))

    def test_a_platform_account_address_never_settles(self):
        got = forms.check(forms.FORM_EMAIL, "jane@instagram.com",
                          self.facts(account_email_sha256=forms.value_digest(forms.FORM_EMAIL, "jane@instagram.com"), profile_hosts=["instagram.com"]))
        self.assertEqual((got.ok, got.reason), (False, "email_at_a_shared_host"))

    def test_an_address_on_another_domain_never_settles(self):
        got = forms.check(forms.FORM_EMAIL, "jane@elsewhere.com", self.facts())
        self.assertIs(got.ok, False)

    def test_an_unread_host_is_unmeasured(self):
        got = forms.check(forms.FORM_EMAIL, "jane@novakane.com", self.facts(profile_hosts=None))
        self.assertIsNone(got.ok)

    def test_a_profile_that_publishes_no_website_is_measured_and_refuses(self):
        got = forms.check(forms.FORM_EMAIL, "jane@novakane.com", self.facts(profile_hosts=[]))
        self.assertEqual((got.ok, got.reason), (False, "email_domain_not_the_profiles"))

    def test_an_address_that_does_not_parse_is_refused_at_intake(self):
        got = forms.check(forms.FORM_EMAIL, "jane at novakane", self.facts())
        self.assertIs(got.ok, False)


class PhoneCheckTests(unittest.TestCase):
    def test_a_supplied_number_is_a_measured_no_because_no_source_can_check_it(self):
        got = forms.check(forms.FORM_PHONE, "+15551234567", {"profile_phones": ["+15551234567"]})
        self.assertEqual((got.ok, got.reason), (False, "no_source_can_check_this_form"))

    def test_a_phone_is_never_offered_however_many_facts_we_hold(self):
        facts = {"profile_phones": ["+15551234567"], "profile_hosts": [], "profile_titles": ["night drive"]}
        self.assertEqual(forms.offered("company_authority", "organization", facts), forms.FORM_DOCUMENT)

    def test_a_number_that_is_not_a_number_is_refused(self):
        got = forms.check(forms.FORM_PHONE, "call me", {"profile_phones": None})
        self.assertIs(got.ok, False)

    def test_a_number_that_looks_like_one_is_still_refused_for_having_no_source(self):
        got = forms.check(forms.FORM_PHONE, "+15551234567", {})
        self.assertEqual((got.ok, got.reason), (False, "no_source_can_check_this_form"))


class CollaboratorCheckTests(unittest.TestCase):
    """A collaborator's word is what settles it, and nothing here can ask for that word: the form is
    recognised and recorded, and every supplied one is a measured NO naming that gap."""

    def test_a_credited_muso_user_is_still_not_a_settlement_without_their_word(self):
        got = forms.check(forms.FORM_COLLABORATOR, f"https://muso.ai/profile/{OTHER}",
                          {"claimed_profile_id": PID, "profile_titles": ["night drive"],
                           "collaborators": {OTHER: {"in_catalog": True, "held_by_account": True,
                                                     "titles": ["night drive"]}}})
        self.assertEqual((got.ok, got.reason), (False, "collaborator_attestation_not_recorded"))

    def test_a_collaborator_is_never_offered(self):
        facts = {"profile_titles": ["night drive"], "collaborators": {OTHER: {"in_catalog": True,
                                                                            "held_by_account": True,
                                                                            "titles": ["night drive"]}}}
        self.assertEqual(forms.offered("proof_naming_claimant", "artist", facts), forms.FORM_DOCUMENT)

    def test_the_collaborator_words_are_reserved_and_never_delivered(self):
        self.assertTrue(COPY["reserved_form_asks"]["proof_naming_claimant"]["collaborator_proof"].strip())
        with self.assertRaises(L.PolicyError):
            L.ask_text("proof_naming_claimant", "artist", POLICY, COPY, form=forms.FORM_COLLABORATOR)

    def test_a_reference_that_is_not_a_muso_profile_link_is_refused(self):
        got = forms.check(forms.FORM_COLLABORATOR, "my friend Dave", {})
        self.assertIs(got.ok, False)


class NormalisationTests(unittest.TestCase):
    def test_an_address_is_lower_cased_and_trimmed(self):
        self.assertEqual(forms.normalise(forms.FORM_EMAIL, "  Jane@NovaKane.COM "), ("jane@novakane.com", ""))

    def test_a_number_keeps_only_the_plus_and_its_digits(self):
        self.assertEqual(forms.normalise(forms.FORM_PHONE, "+1 (555) 123-4567")[0], "+15551234567")

    def test_a_too_short_number_is_refused_by_name(self):
        self.assertTrue(forms.normalise(forms.FORM_PHONE, "+1555")[1])

    def test_a_collaborator_link_is_normalised_to_the_profile_id(self):
        self.assertEqual(forms.normalise(forms.FORM_COLLABORATOR, f"https://muso.ai/profile/{OTHER}")[0], OTHER)

    def test_a_document_is_never_supplied_as_a_form(self):
        with self.assertRaises(ValueError):
            forms.normalise(forms.FORM_DOCUMENT, "a.pdf")

    def test_a_document_is_read_by_the_ladders_own_gates(self):
        with self.assertRaises(ValueError):
            forms.check(forms.FORM_DOCUMENT, "a.pdf", {})

    def test_the_digest_names_the_form_and_the_value_and_never_the_value_alone(self):
        a = forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com")
        self.assertEqual(a, forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"))
        self.assertNotEqual(a, forms.value_digest(forms.FORM_EMAIL, "jane@novakane.org"))


# ------------------------------------------------------------------------------------------------
# Intake: what was supplied is stored once, checked next pass, and the verdict row says which form
# ------------------------------------------------------------------------------------------------

class IntakeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name
        self.path = os.path.join(tmp.name, "decisions.sqlite")
        self.db = L.open_store(self.path)
        self.addCleanup(self.db.close)

    def test_a_supplied_address_is_stored_normalised_with_its_digest(self):
        row = L.supply(self.db, 7, forms.FORM_EMAIL, " Jane@NovaKane.com ", supplied_at="2026-11-16T01:00:00Z")
        self.assertEqual((row["value"], row["form"]), ("jane@novakane.com", forms.FORM_EMAIL))

    def test_a_supplied_form_is_read_back_for_the_claims_owner(self):
        L.supply(self.db, 7, forms.FORM_EMAIL, "jane@novakane.com")
        got = S.supplies(self.path, [7])
        self.assertEqual([r["form"] for r in got[7]], [forms.FORM_EMAIL])

    def test_a_store_that_has_taken_no_form_reads_as_nothing_supplied(self):
        self.assertEqual(S.supplies(os.path.join(self.tmp, "absent.sqlite"), [7]), {})

    def test_a_document_is_declined_at_the_intake(self):
        with self.assertRaises(ValueError):
            L.supply(self.db, 7, forms.FORM_DOCUMENT, "a.pdf")

    def test_a_malformed_value_is_declined_at_the_intake_and_never_stored(self):
        with self.assertRaises(ValueError):
            L.supply(self.db, 7, forms.FORM_EMAIL, "jane at novakane")
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM claim_doc_supplies").fetchone()[0], 0)

    def test_a_supplied_form_is_append_only(self):
        L.supply(self.db, 7, forms.FORM_EMAIL, "jane@novakane.com")
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("UPDATE claim_doc_supplies SET value = 'x@y.com'")

    def test_the_verdict_row_says_which_form_settled_the_claim(self):
        c = claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com",
                                   "supplied_at": "2026-11-16T01:00:00Z"}],
                  form_facts={"profile_hosts": ["novakane.com"], "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True})
        L.run(snapshot([c]), POLICY, self.db, at="2026-11-16T02:00:00Z")
        row = L.standing(self.db, L.APPROVED)[0]
        self.assertEqual((row["outcome"], row["form"]), (L.APPROVED, forms.FORM_EMAIL))

    def test_the_row_carries_the_digest_and_never_the_address(self):
        c = claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com"}],
                  form_facts={"profile_hosts": ["novakane.com"], "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True})
        L.run(snapshot([c]), POLICY, self.db, at="2026-11-16T02:00:00Z")
        row = L.standing(self.db, L.APPROVED)[0]
        self.assertEqual(row["form_value_sha256"], forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"))
        self.assertNotIn("novakane.com", str(row))

    def test_a_document_settled_row_says_nothing_about_a_form(self):
        c = claim()
        L.run(snapshot([c], {"11": [doc()]}), POLICY, self.db, at="2026-11-16T02:00:00Z")
        row = L.standing(self.db, L.APPROVED)[0]
        self.assertEqual((row["form"], row["ask_form"]), ("", ""))

    def test_a_form_that_does_not_settle_asks_in_a_form_that_still_can(self):
        c = claim(profile_type="organization",
                  supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@gmail.com"}],
                  form_facts={"profile_hosts": ["brightlabel.com"]})
        L.run(snapshot([c]), POLICY, self.db, at="2026-11-16T02:00:00Z")
        row = L.standing(self.db, L.REFUSED)[0]
        self.assertEqual((row["ask"], row["ask_form"]), ("company_authority", forms.FORM_DOCUMENT))

    def test_a_claim_with_a_form_and_no_document_is_decided_at_all(self):
        c = claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com"}],
                  form_facts={"profile_hosts": None})
        decisions, skipped = L.plan(snapshot([c]), POLICY)
        self.assertEqual((len(decisions), skipped), (1, {"no_evidence": 0, "not_open": 0}))

    def test_a_form_whose_facts_are_unread_waits_on_the_reader_and_never_refuses(self):
        c = claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com"}], form_facts={})
        decisions, _ = L.plan(snapshot([c]), POLICY)
        self.assertEqual((decisions[0][0].outcome, decisions[0][0].route), (L.AWAITING, "doc-sources"))

    def test_a_form_the_class_never_accepts_is_refused_with_the_form_that_can_settle_it(self):
        c = claim(profile_type="venue", supplied_forms=[{"form": forms.FORM_PHONE, "value": "+15551234567"}],
                  form_facts={"profile_phones": ["+15551234567"]})
        decisions, _ = L.plan(snapshot([c]), POLICY)
        self.assertEqual(decisions[0][0].outcome, L.REFUSED)


class ClaimHoldTests(unittest.TestCase):
    """A supplied form that checks out is not an approval on its own: the claim-side holds a document
    must clear stop a form too, and a poisoned document poisons the form path."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = os.path.join(tmp.name, "decisions.sqlite")
        self.db = L.open_store(self.path)
        self.addCleanup(self.db.close)

    def email_claim(self, **over):
        return claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com"}],
                     form_facts={"profile_hosts": ["novakane.com"], "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True}, **over)

    def decision(self, c, docs=None):
        decisions, _ = L.plan(snapshot([c], docs), POLICY)
        return decisions[0][0]

    def test_a_clean_claim_on_a_supplied_address_is_approved(self):
        got = self.decision(self.email_claim())
        self.assertEqual((got.outcome, got.form), (L.APPROVED, forms.FORM_EMAIL))

    def test_a_contradicted_claim_is_not_approved_by_an_address(self):
        c = self.email_claim(holdings=[{"userId": 12, "status": "processed"}])
        got = self.decision(c)
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "profile_already_claimed"))

    def test_a_bound_code_another_claim_found_is_not_approved_by_an_address(self):
        got = self.decision(self.email_claim(code_found=[8]))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "bound_code_other_claim"))

    def test_an_unread_bound_code_waits_and_is_not_approved_by_an_address(self):
        got = self.decision(self.email_claim(code_found=None))
        self.assertEqual((got.outcome, got.reason), (L.AWAITING, "bound_code_unmeasured"))

    def test_a_big_profile_is_not_approved_by_an_address(self):
        got = self.decision(self.email_claim(profile={"name": "Nova Kane", "popularity": 10 ** 7,
                                                      "creditCount": 10 ** 6}))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "big_profile"))

    def test_a_held_account_is_not_approved_by_an_address(self):
        got = self.decision(self.email_claim(account_hold=True))
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "account_hold"))

    def test_a_hold_refusal_carries_the_ask_the_reason_table_names(self):
        got = self.decision(self.email_claim(code_found=[8]))
        self.assertEqual(got.ask, L.REASONS["bound_code_other_claim"].ask)

    def test_a_poisoned_document_poisons_the_address_too(self):
        got = self.decision(self.email_claim(),
                            {"11": [doc(blocking_verdicts=["forged"])]})
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "document_forged"))

    def test_a_contradicted_document_poisons_the_address_too(self):
        got = self.decision(self.email_claim(),
                            {"11": [doc(blocking_verdicts=["contradicted"])]})
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "document_contradicted"))

    def test_a_document_filed_by_another_account_poisons_the_address_too(self):
        got = self.decision(self.email_claim(), {"11": [doc(other_filers=1)]})
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "document_reused"))

    def test_a_supplied_phone_is_refused_at_once_and_never_left_waiting(self):
        c = claim(profile_type="organization", supplied_forms=[{"form": forms.FORM_PHONE,
                                                               "value": "+15551234567"}],
                  form_facts={"profile_hosts": [], "profile_phones": None})
        got = self.decision(c)
        self.assertEqual((got.outcome, got.reason), (L.REFUSED, "form_supplied_does_not_settle"))


class FactReaderTests(unittest.TestCase):
    """`doc_sources.form_facts`: the bound on live reads must not starve an address supplier, must
    rotate what it leaves out, and must keep each collaborator's facts under its own reference."""

    def run_reader(self):
        """The replica as the reader sees it: quoted CSV rows, returned whatever the statement's own
        spelling is (a prefix match, an `in (...)`, either way this profile is the answer)."""
        def trino(sql):
            if "matvw_profile_credit" in sql:
                return f'"{OTHER}","Night Drive"'
            return f'"{OTHER}"'
        return trino

    def facts(self, claims, known, titles, sites, **kw):
        return S.form_facts(self.run_reader(), claims, known, titles, sites=sites, **kw)

    def test_a_claimant_who_supplied_an_address_is_read_even_past_the_budget(self):
        c1 = claim(claim_id=1, profile_id=PID, supplied_forms=[{"form": forms.FORM_EMAIL, "value": "a@x.com"}])
        c2 = claim(claim_id=2, profile_id=OTHER, supplied_forms=[])
        sites = lambda ids: {p: "" for p in ids}          # noqa: E731
        facts, spent = self.facts([c1, c2], {PID, OTHER}, {}, sites, budget=1)
        self.assertIsNotNone(facts[1]["profile_hosts"])
        self.assertIsNone(facts[2]["profile_hosts"])

    def test_a_claim_left_out_of_the_budget_is_counted(self):
        c1 = claim(claim_id=1, profile_id=PID)
        c2 = claim(claim_id=2, profile_id=OTHER)
        sites = lambda ids: {p: "" for p in ids}          # noqa: E731
        _, spent = self.facts([c1, c2], {PID, OTHER}, {}, sites, budget=1)
        self.assertEqual(spent["over_bound"], 1)

    def test_a_claim_whose_profile_was_read_is_not_counted_over_bound(self):
        # two claims on one profile: the address supplier forces the read, so the second claim's
        # facts are read too and it stayed out of nothing
        c1 = claim(claim_id=1, profile_id=PID,
                   supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com"}])
        c2 = claim(claim_id=2, profile_id=PID)
        sites = lambda ids: {PID: "https://novakane.com"}   # noqa: E731
        facts, spent = self.facts([c1, c2], {PID}, {}, sites, budget=1)
        self.assertEqual(facts[1]["profile_hosts"], facts[2]["profile_hosts"])
        self.assertEqual(spent["over_bound"], 0)

    def test_the_next_pass_reads_the_ones_left_out(self):
        c1 = claim(claim_id=1, profile_id=PID)
        c2 = claim(claim_id=2, profile_id=OTHER)
        sites = lambda ids: {p: "" for p in ids}          # noqa: E731
        _, spent = self.facts([c1, c2], {PID, OTHER}, {}, sites, budget=1, rotate=[])
        self.assertEqual(spent["hosts_asked"], [PID])
        _, spent = self.facts([c1, c2], {PID, OTHER}, {}, sites, budget=1, rotate=[PID])
        self.assertEqual(spent["hosts_asked"], [OTHER])

    def test_a_website_read_as_empty_is_measured_and_not_unread(self):
        sites = lambda ids: {PID: ""}                     # noqa: E731
        facts, _ = self.facts([claim(claim_id=1)], {PID}, {}, sites)
        self.assertEqual(facts[1]["profile_hosts"], [])

    def test_a_profile_left_out_of_the_answer_is_unread(self):
        sites = lambda ids: {}                            # noqa: E731
        facts, spent = self.facts([claim(claim_id=1)], {PID}, {}, sites)
        self.assertIsNone(facts[1]["profile_hosts"])
        self.assertEqual(spent["hosts_unread"], 1)

    def test_the_accounts_mailbox_is_read_for_a_claim_that_supplied_nothing(self):
        """The offer needs the mailbox BEFORE a form arrives: asking for an address the account cannot
        prove would ask for an answer that can never pass."""
        def trino(sql):
            if "postgresql_core.public.users" in sql:
                return '"11","jane@novakane.com","true"'
            return f'"{OTHER}"'
        facts, _ = S.form_facts(trino, [claim(claim_id=1, supplied_forms=[])], {PID}, {},
                                sites=lambda ids: {PID: "https://novakane.com"})
        self.assertIs(facts[1]["account_email_confirmed"], True)
        self.assertEqual(facts[1]["account_email_sha256"],
                         forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"))

    def test_an_unconfirmed_account_mailbox_reads_as_false_not_unread(self):
        def trino(sql):
            if "postgresql_core.public.users" in sql:
                return '"11","jane@novakane.com","false"'
            return f'"{OTHER}"'
        facts, _ = S.form_facts(trino, [claim(claim_id=1)], {PID}, {},
                                sites=lambda ids: {PID: "https://novakane.com"})
        self.assertIs(facts[1]["account_email_confirmed"], False)

    def test_a_users_read_that_fails_leaves_the_mailbox_unread_never_unconfirmed(self):
        def trino(sql):
            if "postgresql_core.public.users" in sql:
                raise RuntimeError("replica down")
            return f'"{OTHER}"'
        facts, _ = S.form_facts(trino, [claim(claim_id=1)], {PID}, {},
                                sites=lambda ids: {PID: "https://novakane.com"})
        self.assertIsNone(facts[1]["account_email_confirmed"])
        self.assertIsNone(facts[1]["account_email_sha256"])

    def test_a_failed_batch_read_is_unread_and_never_no_website(self):
        def sites(ids):
            raise RuntimeError("admin api down")
        facts, spent = self.facts([claim(claim_id=1)], {PID}, {}, sites)
        self.assertIsNone(facts[1]["profile_hosts"])
        self.assertEqual(spent["hosts_unread"], 1)

    def test_a_profile_the_catalog_does_not_have_is_measured_as_credited_on_nothing(self):
        facts, _ = self.facts([claim(claim_id=1)], set(), {}, lambda ids: {})   # noqa: E731
        self.assertEqual(facts[1]["profile_titles"], [])

    def test_each_collaborator_carries_its_own_facts(self):
        third = "cccccccc-1111-2222-3333-444444444444"
        c = claim(supplied_forms=[{"form": forms.FORM_COLLABORATOR, "value": OTHER},
                                  {"form": forms.FORM_COLLABORATOR, "value": third}])
        facts, spent = self.facts([c], {PID}, {PID: {"night drive"}}, lambda ids: {})
        self.assertEqual(facts[7]["collaborators"][OTHER], {"in_catalog": True, "held_by_account": True,
                                                           "titles": ["night drive"]})
        self.assertIs(facts[7]["collaborators"][third]["in_catalog"], False)
        self.assertEqual(spent["collaborators_read"], 2)      # both refs read, one resolves

    def test_a_profile_held_by_an_account_is_read_from_the_claims_core(self):
        def run(sql):
            return f'"{OTHER}"' if "claiming" in sql else (f'"{OTHER}","Night Drive"' if "matvw" in sql else f'"{OTHER}"')
        got = S.collaborator_facts(run, [OTHER])
        self.assertIs(got[OTHER]["held_by_account"], True)

    def test_a_profile_nobody_has_claimed_is_not_held(self):
        def run(sql):
            return "" if "claiming" in sql else (f'"{OTHER}","Night Drive"' if "matvw" in sql else f'"{OTHER}"')
        got = S.collaborator_facts(run, [OTHER])
        self.assertIs(got[OTHER]["held_by_account"], False)

    def test_a_holder_read_that_fails_is_unmeasured_never_unheld(self):
        def run(sql):
            if "claiming" in sql:
                raise RuntimeError("replica down")
            return f'"{OTHER}","Night Drive"' if "matvw" in sql else f'"{OTHER}"'
        got = S.collaborator_facts(run, [OTHER])
        self.assertIsNone(got[OTHER]["held_by_account"])

    def test_a_truncated_collaborator_id_is_matched_the_one_page_identity_way(self):
        c = claim(supplied_forms=[{"form": forms.FORM_COLLABORATOR, "value": OTHER[:8]}])
        facts, _ = self.facts([c], {PID}, {PID: {"night drive"}}, lambda ids: {})
        self.assertEqual(facts[7]["collaborators"][OTHER[:8]]["titles"], ["night drive"])


class StoredDecisionTests(unittest.TestCase):
    """The stored decision names the form and its digest, never the address: the value lives on the
    supply row, and `verify` puts it back to re-derive the decision."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = os.path.join(tmp.name, "decisions.sqlite")
        self.db = L.open_store(self.path)
        self.addCleanup(self.db.close)
        self.address = "jane@novakane.com"
        L.supply(self.db, 7, forms.FORM_EMAIL, self.address, supplied_at="2026-11-16T01:00:00Z")
        c = claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": self.address,
                                   "supplied_at": "2026-11-16T01:00:00Z"}],
                  form_facts={"profile_hosts": ["novakane.com"], "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True})
        L.run(snapshot([c]), POLICY, self.db, at="2026-11-16T02:00:00Z")

    def test_the_stored_row_holds_no_address(self):
        row = self.db.execute("SELECT inputs_json, gates_json FROM claim_doc_decisions").fetchone()
        self.assertNotIn(self.address, row[0])
        self.assertNotIn(self.address, row[1])
        self.assertNotIn("novakane.com", row[1])

    def test_the_stored_inputs_keep_the_forms_digest(self):
        inputs = self.db.execute("SELECT inputs_json FROM claim_doc_decisions").fetchone()[0]
        self.assertIn(forms.value_digest(forms.FORM_EMAIL, self.address), inputs)

    def test_the_decision_is_still_re_derived_from_the_supply_row(self):
        self.assertEqual(L.verify(self.db)["mismatch"], [])

    def test_a_decision_with_no_supply_row_cannot_be_derived(self):
        with tempfile.TemporaryDirectory() as tmp:          # a store that never took the supply
            db = L.open_store(os.path.join(tmp, "d.sqlite"))
            self.addCleanup(db.close)
            c = claim(supplied_forms=[{"form": forms.FORM_EMAIL, "value": "jane@novakane.com"}],
                      form_facts={"profile_hosts": ["novakane.com"], "account_email_sha256": forms.value_digest(forms.FORM_EMAIL, "jane@novakane.com"), "account_email_confirmed": True})
            L.run(snapshot([c]), POLICY, db, at="2026-11-16T02:00:00Z")
            self.assertEqual([m["claim_id"] for m in L.verify(db)["mismatch"]], [7])
            with self.assertRaises(L.NotReproducible):
                L.reproduce(db, 7)


class StoredCollaboratorDecisionTests(unittest.TestCase):
    """A supplied collaborator is recorded and refused, never approved (nothing can ask that user to
    confirm), and the stored decision names the id by digest only: `verify` re-reads the value from
    the supply row to re-derive the same verdict."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db = L.open_store(os.path.join(tmp.name, "decisions.sqlite"))
        self.addCleanup(self.db.close)
        L.supply(self.db, 7, forms.FORM_COLLABORATOR, OTHER, supplied_at="2026-11-16T01:00:00Z")
        c = claim(supplied_forms=[{"form": forms.FORM_COLLABORATOR, "value": OTHER,
                                   "supplied_at": "2026-11-16T01:00:00Z"}],
                  form_facts={"claimed_profile_id": PID, "profile_titles": ["night drive"], "collaborators": {
                      OTHER: {"in_catalog": True, "held_by_account": True, "titles": ["night drive"]}}})
        decisions, _ = L.plan(snapshot([c]), POLICY)
        got = decisions[0][0]
        self.assertEqual((got.outcome, got.form), (L.REFUSED, forms.FORM_COLLABORATOR))
        self.assertEqual(got.reason, "form_supplied_does_not_settle")
        L.run(snapshot([c]), POLICY, self.db, at="2026-11-16T02:00:00Z")

    def test_the_stored_row_holds_no_collaborator_id(self):
        row = self.db.execute(
            "SELECT inputs_json, gates_json, form_value_sha256 FROM claim_doc_decisions").fetchone()
        self.assertNotIn(OTHER, row[0])
        self.assertNotIn(OTHER, row[1])
        self.assertEqual(row[2], forms.value_digest(forms.FORM_COLLABORATOR, OTHER))

    def test_the_stored_inputs_keep_the_collaborators_facts_under_its_digest(self):
        inputs = json.loads(self.db.execute("SELECT inputs_json FROM claim_doc_decisions").fetchone()[0])
        self.assertEqual(inputs["claim"]["form_facts"]["collaborators"], {
            forms.value_digest(forms.FORM_COLLABORATOR, OTHER): {"in_catalog": True, "held_by_account": True,
                                                                "titles": ["night drive"]}})

    def test_the_decision_is_still_re_derived_from_the_supply_row(self):
        self.assertEqual(L.verify(self.db)["mismatch"], [])


class StoreMigrationTests(unittest.TestCase):
    """A store the ladder wrote before the forms keeps its rows: the columns are added in place, and
    a row says nothing about a form, which is exactly what 'a document settled it' means."""

    def test_the_form_columns_are_added_to_a_store_that_predates_them(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "d.sqlite")
        db = L.open_store(path)
        L.run(snapshot([claim()], {"11": [doc()]}), POLICY, db, at="2026-11-16T02:00:00Z")
        if sqlite3.sqlite_version_info < (3, 35, 0):
            self.skipTest("DROP COLUMN needs sqlite 3.35")
        for col in [c[0] for c in L.FORM_COLUMNS]:
            db.execute(f"ALTER TABLE claim_doc_decisions DROP COLUMN {col}")
        db.commit()
        db.close()
        db = L.open_store(path)
        self.addCleanup(db.close)
        self.assertEqual([r["claim_id"] for r in L.standing(db, L.APPROVED)], [7])


if __name__ == "__main__":
    unittest.main()
