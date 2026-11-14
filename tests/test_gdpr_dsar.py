"""The DSAR ladder (scripts/gdpr_pipeline/dsar.py, copy_gate.py and their wiring in run.py / send.py / store.py).

Locks (captain 2026-11-12):
  - the date a requester is told is never later than either reading of "one month" (Art. 12(3)); an extension counts
    only when recorded, and never past three months
  - identity is the chain account control -> tie to the page -> authority document; a name match is not a tie and no
    variant asks for an identity document
  - a request reaches `closed` only on a recorded final response
  - one message owed at a time: acknowledgement, a status update at the halfway point, then updates past the date
  - NO VERDICT, NO SEND: a ladder message reaches a writer only on a reviewer approval of its exact bytes under the
    GDPR rubric; pending, refused, a missing gate, a gate that cannot run and an approval of anything else all hold
  - the body is frozen when authored, so the hash under review is the hash that is sent
  - the clock names every request inside 7 days of its date or past it, and names no person
Hermetic: no network, no Intercom, no gate process. Stdlib unittest.
"""
import hashlib
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

try:
    from unittest import mock
except ImportError:  # pragma: no cover
    import mock  # type: ignore
from gdpr_pipeline import access, copy, copy_gate, dsar, identity, send, sources  # noqa: E402
from gdpr_pipeline.run import Run, page_text  # noqa: E402
from gdpr_pipeline.store import Store  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE = "7950a3c4-db2f-49bb-9acf-0d406bfb09ae"


def _reviewed(account):
    """A claim filed against an existing profile and processed with the claimant's links: the kind the identity
    step counts as a tie (hide_guard.prove)."""
    return {"claim_id": f"claim-{account}", "account": account, "reason": "", "created": 1_760_000_000,
            "processed_later": True, "links": {"instagram": "https://instagram.com/the.artist"}}


def _linked(ids):
    """The live profile for those claims: it links the instagram account the claim names, which is what makes the
    link evidence (`hide_guard.reviewed`)."""
    return {i: {"raws": ["spotify:9"], "created": 1_750_000_000,
                "identity": sources.ProfileIdentity(social=frozenset({("instagram", "the.artist")}))} for i in ids}


def utc(*a):
    return datetime(*a, tzinfo=timezone.utc)


NOW = utc(2026, 11, 12, 12, 0)


def REAL():
    """The store stamps what it writes with the real clock, so a wait measured from a stamp is measured from this."""
    return datetime.now(timezone.utc)


def approve(kind, body, variant="", slot="", subject="", runner=None):
    return copy_gate.Answer(True, "approved", "", copy_gate.body_sha(body), "v-" + copy_gate.body_sha(body)[:8],
                            "ab" * 32, "mac-pool/claude-fable-5-1", "2026-11-12T02:00:00Z", "gdpr")


def pending(kind, body, variant="", slot="", subject="", runner=None):
    return copy_gate.Answer(False, "pending", "copy_review_pending", copy_gate.body_sha(body))


def refuse(kind, body, variant="", slot="", subject="", runner=None):
    return copy_gate.Answer(False, "refused", "copy_review_refused", copy_gate.body_sha(body))


def gate_error(kind, body, variant="", slot="", subject="", runner=None):
    return copy_gate.Answer(False, "error", "the copy gate did not answer in 60s", copy_gate.body_sha(body))


class Clock(unittest.TestCase):
    def test_the_date_is_never_later_than_either_reading_of_one_month(self):
        cases = {"2026-11-11T22:17:02Z": "2026-12-11",      # 30-day month: the calendar month and 30 days agree
                 "2026-01-31T10:00:00Z": "2026-02-28",      # one calendar month clamps to the end of February
                 "2026-10-05T00:00:00Z": "2026-11-04",      # 31-day month: 30 days is the earlier date
                 "2024-01-31T00:00:00Z": "2024-02-29"}
        for received, want in cases.items():
            d = dsar.statutory_due(received)
            self.assertEqual(d.strftime("%Y-%m-%d"), want, received)
            r = dsar._parse(received)
            self.assertLessEqual(d, dsar.add_months(r, 1))
            self.assertLessEqual(d, r + timedelta(days=30))

    def test_an_extension_counts_only_when_recorded_and_never_past_three_months(self):
        row = {"received_at": "2026-11-11T00:00:00Z"}
        self.assertEqual(dsar.due(row), dsar.statutory_due(row["received_at"]))
        row["extended_until"] = "2027-01-20T00:00:00Z"
        self.assertEqual(dsar.due(row), utc(2027, 1, 20))
        row["extended_until"] = "2028-01-01T00:00:00Z"
        self.assertEqual(dsar.due(row), utc(2027, 2, 11), "two FURTHER months is the furthest an extension reaches")
        row["extended_until"] = "2026-11-12T00:00:00Z"
        self.assertEqual(dsar.due(row), dsar.statutory_due(row["received_at"]), "an extension never shortens the date")
        row["extended_until"] = "soon"
        self.assertEqual(dsar.due(row), dsar.statutory_due(row["received_at"]), "malformed is ignored, not trusted")


class Gates(unittest.TestCase):
    def g(self, cls="privacy_erasure", acc=7, rep=False, verdicts=(), named=None):
        pv = [{"id": f"p{i}", "verdict": v} for i, v in enumerate(verdicts)]
        return dsar.gates(cls, acc, "account email" if acc is not None else "", rep, pv,
                          len(pv) if named is None else named)

    def test_a_claim_or_the_artists_own_site_is_the_tie(self):
        for v in ("PASS_A", "PASS_D"):
            g = self.g(verdicts=[v])
            self.assertEqual((g["account"]["pass"], g["tie"]["pass"], g["need"]), (True, True, "none"), v)
        self.assertEqual(self.g(verdicts=["PASS_A"])["tie"]["pages"], {"p0": "claim"})
        self.assertEqual(self.g(verdicts=["PASS_D"])["tie"]["pages"], {"p0": "own_site"})

    def test_an_untied_page_needs_a_claim_or_evidence_of_authority_not_an_identity_document(self):
        g = self.g(verdicts=["PASS_A", "ASK_IDENTITY"])
        self.assertEqual((g["tie"]["pass"], g["need"]), (False, "claim_or_authority"))
        self.assertTrue(g["authority"]["needed"])
        self.assertFalse(g["authority"]["on_file"], "nothing records a document yet: never read as received")

    def test_a_page_the_requester_already_claimed_with_no_evidence_gets_the_ownership_ask(self):
        """Ruling 2026-11-13 (inbox 003): a requester whose own claim carries no evidence is asked for a link or a
        label / management document. "Claim the page" would ask for what they have already done."""
        pv = [{"id": "p0", "verdict": "ASK_IDENTITY", "own_claim": True}]
        g = dsar.gates("privacy_erasure", 7, "account email", False, pv, 1)
        self.assertEqual((g["tie"]["pass"], g["tie"]["pages"], g["need"]),
                         (False, {"p0": "claim_unchecked"}, "claim_evidence"))
        self.assertTrue(g["authority"]["needed"])
        # one such page among others is enough; a page somebody else claimed keeps the older ask
        mixed = pv + [{"id": "p1", "verdict": "ASK_IDENTITY"}]
        self.assertEqual(dsar.gates("privacy_erasure", 7, "account email", False, mixed, 2)["need"], "claim_evidence")
        other = [{"id": "p1", "verdict": "ASK_IDENTITY", "own_claim": False}]
        self.assertEqual(dsar.gates("privacy_erasure", 7, "account email", False, other, 1)["need"],
                         "claim_or_authority")
        # the mark never turns a pass into an ask, and a representative is still asked for authority first
        tied = [{"id": "p0", "verdict": "PASS_A", "own_claim": True}]
        self.assertEqual(dsar.gates("privacy_erasure", 7, "account email", False, tied, 1)["need"], "none")
        self.assertEqual(dsar.gates("privacy_erasure", 7, "account email", True, pv, 1)["need"], "authority")

    def test_a_page_already_off_the_site_ties_nobody(self):
        # live dry run 2026-11-12: 71 hidden or gone pages were counted as gate-2 passes; 12 pages were tied by a claim
        for v, how in (("ALREADY_HIDDEN", "hidden"), ("HIDDEN_PENDING", "hidden"), ("GONE", "gone")):
            g = self.g(verdicts=[v])
            self.assertEqual((g["tie"]["pass"], g["tie"]["pages"], g["need"]), (None, {"p0": how}, "none"), v)
            self.assertFalse(g["authority"]["needed"])
            # an access request: a hidden page still has to be tied to the person before it is talked about
            g = self.g(cls="privacy_access", verdicts=[v])
            self.assertEqual((g["tie"]["pass"], g["tie"]["pages"], g["need"]), (None, {"p0": "unknown"}, "unknown"), v)
        g = self.g(verdicts=["PASS_A", "GONE"])
        self.assertEqual((g["tie"]["pass"], g["need"]), (True, "none"), "the page still up is tied by the claim")
        g = self.g(verdicts=["ALREADY_HIDDEN", "ASK_IDENTITY"])
        self.assertEqual((g["tie"]["pass"], g["need"]), (False, "claim_or_authority"))

    def test_an_id_prefix_no_page_carries_is_a_link_to_ask_for_only_when_the_catalog_answered(self):
        pv = [{"id": "7950a3c4", "verdict": "UNKNOWN"}]
        g = dsar.gates("privacy_erasure", 7, "account email", False, pv, 1, prefixes_read=True)
        self.assertEqual((g["tie"]["pass"], g["tie"]["pages"], g["need"]), (False, {"7950a3c4": "no_link"}, "link"))
        g = dsar.gates("privacy_erasure", 7, "account email", False, pv, 1)
        self.assertEqual((g["tie"]["pass"], g["need"]), (None, "unknown"), "a lookup that failed is not a fact")
        full = [{"id": PROFILE, "verdict": "UNKNOWN"}]
        g = dsar.gates("privacy_erasure", 7, "account email", False, full, 1, prefixes_read=True)
        self.assertEqual(g["need"], "unknown", "a full id whose read failed is re-read, never asked for again")
        g = dsar.gates("privacy_erasure", 7, "account email", True, pv, 1, prefixes_read=True)
        self.assertEqual(g["need"], "authority", "a representative is asked for authority first")

    def test_need_precedence(self):
        self.assertEqual(self.g(rep=True, verdicts=["PASS_A"])["need"], "authority")
        self.assertEqual(self.g(verdicts=[])["need"], "link")
        self.assertEqual(self.g(cls="privacy_access", verdicts=[])["need"], "none")
        self.assertEqual(self.g(cls="privacy_access", acc=None, verdicts=[])["need"], "account")
        self.assertEqual(self.g(verdicts=["UNKNOWN"])["need"], "unknown")
        self.assertEqual(self.g(verdicts=["JAN_REVIEW", "ASK_IDENTITY"])["need"], "claim_or_authority")

    def test_a_read_that_failed_is_unknown_never_a_pass(self):
        g = self.g(verdicts=["PASS_A"], named=2)
        self.assertEqual((g["tie"]["pass"], g["need"]), (None, "unknown"))
        self.assertEqual(dsar.need_of({}), "unknown", "a row never through the gates is unknown, not 'nothing needed'")
        self.assertEqual(dsar.need_of({"gates": {"need": "anything"}}), "unknown")


class Decide(unittest.TestCase):
    """`Run.decide_row` is where the chain is computed and recorded. Sources are stubbed; the decision code is real."""
    OTHER = "11111111-2222-3333-4444-555555555555"

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *a, **k: None)

    def add(self, cls="privacy_erasure", pages=(PROFILE,), email="arpad@example.com"):
        n = len(self.s.all()) + 1       # a conversation of its own: two requests in one thread are one row
        rid, how = self.s.upsert({"keys": [f"intercom:2154766503954{n:02d}"], "channel": "intercom", "class": cls,
                                  "received_at": f"2026-11-{n:02d}T00:00:00Z", "requester_name": "Laczkovszki Arpad",
                                  "requester_email": email, "conversation_id": f"2154766503954{n:02d}",
                                  "pages": [{"id": i, "entity": "profile"} for i in pages]})
        self.assertEqual(how, "created")
        return rid

    def decide(self, rid, account=7, claims=None, hidden=(), resolver=None, facts=None, conv=None, checked=None):
        claims = claims or {}
        evidence = claims if checked is None else checked

        def page_facts(pages, hid, cl, half=None, items=False):
            if facts is not None:
                return facts(pages)
            return [identity.Page(p["id"], found=len(p["id"]) == 36, name="Laczkovszki Arpad", hidden=p["id"] in hid,
                                  is_claimed=bool(cl.get(p["id"])), claim_user_ids=frozenset(cl.get(p["id"], ())),
                                  checked_claim_user_ids=frozenset(evidence.get(p["id"], ())))
                    for p in pages]

        conv = conv or {"contact_role": "user", "external_id": "ext-1", "customer_text": "please remove my page"}
        with mock.patch.object(sources, "resolve_account",
                               lambda ext, email, trusted: (account, "external_id (professional id)" if account else "")), \
                mock.patch.object(sources, "account_names", lambda ids: {i: ("Laczkovszki Arpad",) for i in ids}), \
                mock.patch.object(sources, "processed_claims", lambda ids: {i: claims[i] for i in ids if i in claims}), \
                mock.patch.object(sources, "claim_proofs", lambda ids: {i: [_reviewed(u) for u in claims.get(i, ())]
                                                                        for i in ids}), \
                mock.patch.object(sources, "profile_sources", _linked), \
                mock.patch.object(sources, "page_facts", page_facts):
            self.run.decide_rows([self.s.get(rid)], set(hidden), conv_reader=lambda cid: conv,
                                 prefix_resolver=resolver or (lambda prefixes: {}))
        return self.s.get(rid)

    def test_a_claim_by_the_requesting_account_passes_both_gates(self):
        row = self.decide(self.add(), claims={PROFILE: {7}})
        g = row["gates"]
        self.assertEqual(row["identity_verdict"], "PASS_A")
        self.assertEqual((g["v"], g["account"], g["tie"], g["need"]),
                         (1, {"pass": True, "how": "external_id (professional id)"},
                          {"pass": True, "pages": {PROFILE: "claim"}}, "none"))

    def test_the_account_name_matching_the_page_is_asked_to_claim_it(self):
        row = self.decide(self.add())
        self.assertEqual(row["identity_verdict"], "ASK_IDENTITY")
        self.assertEqual((row["gates"]["account"]["pass"], row["gates"]["tie"]["pass"], row["gates"]["need"]),
                         (True, False, "claim_or_authority"))
        self.assertEqual(dsar.owed(row, [], NOW)["variant"], "ack_claim_or_authority")

    def test_the_requesters_own_claim_with_no_evidence_is_asked_for_ownership_not_to_claim_again(self):
        row = self.decide(self.add(), claims={PROFILE: {7}}, checked={})
        self.assertEqual(row["identity_verdict"], "ASK_IDENTITY")
        self.assertEqual((row["gates"]["tie"], row["gates"]["need"]),
                         ({"pass": False, "pages": {PROFILE: "claim_unchecked"}}, "claim_evidence"))
        self.assertEqual(dsar.owed(row, [], NOW)["variant"], "ack_claim_evidence")
        # somebody else's unchecked claim is not the requester's: the older ask stands
        row = self.decide(self.add(), claims={PROFILE: {99}}, checked={})
        self.assertEqual(row["gates"]["need"], "claim_or_authority")

    def test_a_page_claimed_by_another_account_is_not_a_tie(self):
        row = self.decide(self.add(), claims={PROFILE: {99}})
        self.assertEqual((row["gates"]["tie"]["pass"], row["gates"]["need"]), (False, "claim_or_authority"))

    def test_a_hidden_page_needs_nothing_for_erasure_and_is_no_gate_two_pass(self):
        row = self.decide(self.add(), hidden=[PROFILE])
        self.assertEqual(row["identity_verdict"], "ALREADY_HIDDEN")
        self.assertEqual((row["gates"]["tie"], row["gates"]["need"]),
                         ({"pass": None, "pages": {PROFILE: "hidden"}}, "none"))

    def test_an_access_request_keeps_its_verdict_and_still_goes_through_the_chain(self):
        row = self.decide(self.add(cls="privacy_access"), claims={PROFILE: {7}})
        self.assertEqual(row["identity_verdict"], "ACCESS")
        self.assertEqual((row["gates"]["account"]["pass"], row["gates"]["tie"], row["gates"]["need"]),
                         (True, {"pass": True, "pages": {PROFILE: "claim"}}, "none"))
        # a hidden page: the claim is still what ties it, and without one nothing about the page is settled
        row = self.decide(self.add(cls="privacy_access"), claims={PROFILE: {7}}, hidden=[PROFILE])
        self.assertEqual(row["gates"]["tie"], {"pass": True, "pages": {PROFILE: "claim"}})
        row = self.decide(self.add(cls="privacy_access"), hidden=[PROFILE])
        self.assertEqual((row["gates"]["tie"]["pass"], row["gates"]["need"]), (None, "unknown"))
        # no page named: the account is the whole question
        row = self.decide(self.add(cls="privacy_access", pages=()))
        self.assertEqual(row["gates"]["need"], "none")
        row = self.decide(self.add(cls="privacy_access", pages=()), account=None)
        self.assertEqual((row["gates"]["account"]["pass"], row["gates"]["need"]), (False, "account"))

    def test_an_access_request_whose_reads_fail_is_unknown_and_the_row_is_still_decided(self):
        def boom(pages):
            raise sources.Unknown("admin API 503")
        row = self.decide(self.add(cls="privacy_access"), facts=boom)
        self.assertEqual(row["identity_verdict"], "ACCESS")
        self.assertEqual((row["gates"]["account"]["pass"], row["gates"]["tie"]["pass"], row["gates"]["need"]),
                         (False, None, "unknown"))
        self.assertEqual(self.run.errors, [])

    def test_someone_writing_for_another_person_is_asked_for_authority(self):
        conv = {"contact_role": "user", "external_id": "ext-1",
                "customer_text": "I am writing on behalf of my client, as their manager, to request removal"}
        row = self.decide(self.add(), claims={PROFILE: {7}}, conv=conv)
        self.assertEqual(row["gates"]["need"], "authority")
        self.assertTrue(row["gates"]["authority"]["needed"])

    def test_an_id_prefix_is_asked_for_as_a_link_only_when_the_catalog_answered(self):
        row = self.decide(self.add(pages=("7950a3c4",)))
        self.assertEqual((row["gates"]["tie"]["pages"], row["gates"]["need"]), ({"7950a3c4": "no_link"}, "link"))

        def down(prefixes):
            raise sources.Unknown("trino down")
        row = self.decide(self.add(pages=("11111111",)), resolver=down)
        self.assertEqual(row["gates"]["need"], "unknown")
        self.assertIn("prefix resolution", self.run.errors[0])

    def test_a_class_outside_the_statute_records_no_chain(self):
        row = self.decide(self.add(cls="legal_threat"))
        self.assertEqual(row["gates"], {})
        self.assertIsNone(dsar.owed(row, [], NOW))


class State(unittest.TestCase):
    def test_states_follow_the_recorded_facts(self):
        row = {"class": "privacy_erasure", "gates": {"need": "link"}}
        self.assertEqual(dsar.state_of(row, []), "received")
        row["ack_sent_at"] = "2026-11-12T00:00:00Z"
        self.assertEqual(dsar.state_of(row, []), "identity_check")
        row["gates"] = {"need": "none"}
        self.assertEqual(dsar.state_of(row, []), "in_progress")
        row["confirmed_at"] = "2026-11-20T00:00:00Z"
        self.assertEqual(dsar.state_of(row, [{"state": "sending"}]), "responded")
        self.assertEqual(dsar.state_of(row, [{"state": "sent"}]), "closed")

    def test_no_request_is_closed_without_a_recorded_response(self):
        """Exhaustive over every stamp except the final response: none of them reaches a terminal state."""
        stamps = ("ack_sent_at", "ask_sent_at", "status_sent_at", "interim_confirm_at", "hidden_at")
        for mask in range(2 ** len(stamps)):
            row = {"class": "privacy_erasure", "status": "closed", "gates": {"need": "none"}}
            for i, s in enumerate(stamps):
                if mask >> i & 1:
                    row[s] = "2026-11-12T00:00:00Z"
            for sends in ([], [{"state": "sent"}], [{"state": "refused"}]):
                self.assertNotIn(dsar.state_of(row, sends), ("responded", "closed"), row)

    def test_a_register_row_closed_with_nothing_sent_is_named_not_dropped(self):
        rows = [{"id": 1, "register_no": 41, "class": "privacy_access", "status": "closed",
                 "received_at": "2026-10-01T00:00:00Z"}]
        clock = dsar.clock_rows(rows, lambda _: [], NOW)
        self.assertEqual(clock["closed_without_response"], [41])
        self.assertIn("closed with no recorded response: #41", dsar.clock_line(clock))


class Copy(unittest.TestCase):
    FACTS = {"received": "11 November 2026", "due": "11 December 2026", "next": "26 November 2026"}

    def setUp(self):
        self.doc = dsar.load_copy()

    def test_every_need_has_an_acknowledgement_a_status_update_and_a_late_update(self):
        for need in dsar.NEEDS:
            for prefix, kind in (("ack_", "ack"), ("status_", "status"), ("late_", "status")):
                v = self.doc["variants"].get(prefix + need)
                self.assertTrue(v and v["enabled"] is True, prefix + need)
                self.assertEqual(v["kind"], kind)

    def test_every_enabled_variant_renders_clean_and_carries_dates_only(self):
        for vid, v in self.doc["variants"].items():
            if v.get("enabled") is not True:
                continue
            body = dsar.render(self.doc, vid, self.FACTS)
            self.assertEqual(dsar.lint(body, v["kind"], self.FACTS, late=vid.startswith("late_")), "", vid)
            self.assertNotIn("http", body.lower(), vid)
            self.assertNotIn("@", body, vid)
            if v["kind"] in ("ack", "extension"):
                self.assertIn("11 December 2026", body, f"{vid}: states the date the answer is owed by")
            elif v["kind"] == "access":
                self.assertIn(self.FACTS["received"], body, f"{vid}: names the request it answers")
                for date in (self.FACTS["due"], self.FACTS["next"]):
                    self.assertNotIn(date, body, f"{vid}: the cover of an answer promises no further date")
            else:
                self.assertIn(self.FACTS["next"], body, f"{vid}: a status update says when they hear next")

    def test_no_variant_asks_for_an_identity_document(self):
        """Art. 12(6): more information only on reasonable doubt. The copy never asks for a passport or an ID; where
        the word appears it is to say one is NOT needed."""
        for name, text in self.doc["blocks"].items():
            low = text.lower()
            for word in ("passport", "identity document", "id card", "driving licence", "driver's license"):
                if word in low:
                    self.assertIn("do not need", low, f"block {name} mentions {word!r}")
            self.assertNotIn("name as it appears", low, name)
        self.assertIn("do not need to send a passport", self.doc["blocks"]["need_claim_or_authority"])

    def test_the_ownership_ask_asks_for_a_matching_link_or_a_label_document_and_nothing_else(self):
        """Rulings 2026-11-13 (inbox 002, 003): proof that a page is someone's is a matching link or a label /
        management document. It is never an identity document, and it never tells a claimant to claim the page."""
        block = self.doc["blocks"]["need_claim_evidence"]
        low = block.lower()
        for must in ("confirm that the page is yours", "spotify or apple music artist page",
                     "official social account that matches the profile", "label or management",
                     "do not need to send a passport"):
            self.assertIn(must, low)
        for never in ("claim the page", "claim it", "sign in", "name as it appears"):
            self.assertNotIn(never, low)
        for prefix in ("ack_", "status_", "late_"):
            blocks = self.doc["variants"][prefix + "claim_evidence"]["blocks"]
            self.assertIn("need_claim_evidence", blocks)
            self.assertNotIn("need_claim_or_authority", blocks)
        late = dsar.render(self.doc, "late_claim_evidence", self.FACTS)
        self.assertNotIn("nothing", late.lower(), "the letter that corrects 'nothing is needed' must not repeat it")
        self.assertIn("we need something from you", late)

    def test_a_late_update_says_late_and_sorry_once_and_gives_no_reason(self):
        """Decision 2026-11-12 (inbox 004): 'we are late, we are sorry, here is the actual date you will get your
        answer. No excuse, no admission of unlawful processing ... do not name internal causes.'"""
        for need in dsar.NEEDS:
            body = dsar.render(self.doc, f"late_{need}", self.FACTS)
            low = body.lower()
            self.assertIn("we are late", low, need)
            self.assertEqual(len(dsar.APOLOGY_RE.findall(body)), 1, f"late_{need}: one apology, not a refrain")
            for word in ("because", "due to", "unlawful", "breach", "volume", "staff", "system", "backlog"):
                self.assertNotIn(word, low, f"late_{need} explains or admits: {word!r}")
            self.assertNotEqual(dsar.lint(body.replace("and we are sorry", "and that is that"), "status", self.FACTS,
                                          late=True), "", "a late update with no apology is not sent")
        self.assertIn("When you will have our answer: by 26 November 2026", dsar.render(self.doc, "late_none", self.FACTS))
        for need in dsar.NEEDS:
            if need != dsar.NEED_NONE:
                self.assertNotIn("have our answer", dsar.render(self.doc, f"late_{need}", self.FACTS),
                                 f"late_{need}: no answer date is promised while the answer waits on something")

    def test_a_late_update_with_no_answer_we_can_produce_states_no_answer_date(self):
        body = dsar.render(self.doc, dsar.LATE_NO_DATE_VARIANT, self.FACTS)
        self.assertEqual(dsar.lint(body, "status", self.FACTS, late=True), "")
        self.assertIn("We are late in answering it, and we are sorry.", body)
        self.assertIn("What we need from you: nothing.", body)
        self.assertIn("When you will hear from us next: by 26 November 2026", body)
        self.assertNotIn("have our answer", body, "a date for an answer nothing can produce is a promise we cannot hold")

    def test_nothing_apologises_except_an_update_to_a_request_past_its_date(self):
        for vid, v in self.doc["variants"].items():
            if v["enabled"] is True and not vid.startswith("late_"):
                self.assertIsNone(dsar.APOLOGY_RE.search(dsar.render(self.doc, vid, self.FACTS)), vid)
        self.assertIn("apology", dsar.lint("Hello,\n\nSorry. By 11 December 2026.", "ack", self.FACTS))
        for word in ("unlawful", "breach", "backlog", "high volume", "technical issues"):
            self.assertIn("barred", dsar.lint(f"We are late, sorry, {word}. 26 November 2026", "status", self.FACTS,
                                              late=True), word)

    def test_the_extension_notice_quotes_the_rule_states_the_ground_and_the_new_date(self):
        v = self.doc["variants"]["extension_number"]
        self.assertIs(v["enabled"], True)
        self.assertEqual((v["kind"], v["ground"]), ("extension", "number"))
        body = dsar.render(self.doc, "extension_number", self.FACTS)
        self.assertIn(self.doc["blocks"]["ext_rule"], body)
        self.assertIn("more than one open request from you", body)
        self.assertIn("by 11 December 2026", body)
        for word in ("late", "sorry", "complex", "complexity of your"):
            self.assertNotIn(word, body.replace(self.doc["blocks"]["ext_rule"], "").replace("at the latest", "").lower(),
                             f"an extension notice is not a lateness notice and claims one ground: {word!r}")

    def test_the_legal_positions_are_locked_and_quote_the_rule(self):
        # complexity is a judgement no code makes; a refusal is not sent at all (default: comply)
        for vid in ("extension_complexity", "denial"):
            self.assertIs(self.doc["variants"][vid]["enabled"], False)
            with self.assertRaises(dsar.CopyError):
                dsar.render(self.doc, vid, self.FACTS)
        self.assertNotIn("extension", self.doc["variants"], "no extension notice without a named ground")
        self.assertIn("may be extended by two further months where necessary, taking into account the complexity "
                      "and number of the requests", self.doc["blocks"]["ext_rule"])
        self.assertIn("the possibility of lodging a complaint with a supervisory authority and seeking a judicial "
                      "remedy", self.doc["blocks"]["denial_rule"])

    def test_no_customer_wording_accuses_anyone(self):
        for name, text in self.doc["blocks"].items():
            self.assertIsNone(dsar.BARRED_RE.search(text), name)

    def test_the_lint_refuses_what_must_never_go_out(self):
        body = dsar.render(self.doc, "ack_none", self.FACTS)
        self.assertIn("deadline", dsar.lint(body.replace("11 December 2026", "soon"), "ack", self.FACTS))
        self.assertIn("hears next", dsar.lint("We are working on it.", "status", self.FACTS))
        self.assertIn("unfilled", dsar.lint(body + " {next}", "ack", self.FACTS))
        self.assertIn("barred", dsar.lint(body + " We flagged this as fraud.", "ack", self.FACTS))
        self.assertIn("requester's name", dsar.lint(body + " Dear Arpad Laczkovszki", "ack", self.FACTS,
                                                    {"requester_name": "Arpad Laczkovszki"}))
        self.assertIn("requester's email", dsar.lint(body + " a@b.example", "ack", self.FACTS,
                                                     {"requester_email": "a@b.example"}))
        self.assertEqual(dsar.lint("", "ack", self.FACTS), "empty body")

    def test_a_broken_copy_file_is_an_error_not_a_message(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "copy.json"
            with self.assertRaises(dsar.CopyError):
                dsar.load_copy(p)
            p.write_text("{not json")
            with self.assertRaises(dsar.CopyError):
                dsar.load_copy(p)
            p.write_text(json.dumps({"blocks": {"a": "Hello {due}"}, "variants": {
                "x": {"enabled": True, "kind": "ack", "blocks": ["a"]},
                "y": {"enabled": True, "kind": "ack", "blocks": ["missing"]}}}))
            doc = dsar.load_copy(p)
            with self.assertRaises(dsar.CopyError):
                dsar.render(doc, "x", {})
            with self.assertRaises(dsar.CopyError):
                dsar.render(doc, "y", self.FACTS)
            with self.assertRaises(dsar.CopyError):
                dsar.render(doc, "nope", self.FACTS)


class Ladder(unittest.TestCase):
    def row(self, **kw):
        base = {"class": "privacy_erasure", "status": "open", "received_at": "2026-11-11T00:00:00Z",
                "gates": {"v": 1, "need": "claim_or_authority"}}
        base.update(kw)
        return base

    def test_a_new_request_is_owed_an_acknowledgement_that_states_the_date(self):
        w = dsar.owed(self.row(), [], NOW)
        self.assertEqual((w["kind"], w["slot"], w["variant"]), ("ack", "ack", "ack_claim_or_authority"))
        self.assertEqual(w["facts"], {"received": "11 November 2026", "due": "11 December 2026"})

    def test_nothing_is_owed_to_a_class_outside_the_statute_or_a_finished_request(self):
        for cls in ("legal_threat", "dmca_takedown", "cancel_intent_mentions_deletion", "not_erasure"):
            self.assertIsNone(dsar.owed(self.row(**{"class": cls}), [], NOW), cls)
        self.assertIsNone(dsar.owed(self.row(status="duplicate"), [], NOW))
        self.assertIsNone(dsar.owed(self.row(confirmed_at="2026-11-12T00:00:00Z"), [], NOW))

    def test_a_request_not_yet_through_the_identity_chain_is_owed_nothing_yet(self):
        # a row decided before the chain existed: what it needs is not known, so no message claims to know
        for g in ({}, {"need": "none"}, None):
            self.assertIsNone(dsar.owed(self.row(gates=g), [], NOW), g)
            self.assertIsNone(dsar.owed(self.row(gates=g, received_at="2026-09-01T00:00:00Z"), [], NOW), g)

    def test_a_letter_in_the_send_ledger_counts_even_when_the_row_carries_no_stamp(self):
        # live dry run 2026-11-12: #265 had a `sent` ask in the ledger (2026-11-08) and no ask_sent_at on the row; a
        # stamps-only reading owed it a first acknowledgement. 24 open requests were in that shape.
        row = self.row(received_at="2026-10-17T02:47:25Z")                 # due 2026-11-16, 3.6 d ahead
        now = utc(2026, 11, 12, 12, 0)
        self.assertEqual(dsar.owed(row, [], now)["kind"], "ack", "with nothing sent it is owed the acknowledgement")
        ask = {"kind": "ask", "state": "sent", "at": "2026-11-08T18:07:59Z"}
        self.assertIsNone(dsar.owed(row, [ask], now), "asked 4 d ago: no first message, and quiet for 7 d")
        self.assertEqual(dsar.contacted_at(row, [ask]), "2026-11-08T18:07:59Z")
        self.assertEqual(dsar.state_of(row, [ask]), dsar.IDENTITY_CHECK)
        late = dsar.owed(row, [ask], utc(2026, 11, 16, 12, 0))
        self.assertEqual((late["kind"], late["variant"]), ("status", "late_claim_or_authority"))
        # a letter that MAY be out blocks a second first-message as well; one that provably did not go does not
        for state, expect in (("sending", None), ("unknown", None), ("refused", "ack"), ("failed", "ack")):
            w = dsar.owed(row, [{"kind": "ask", "state": state, "at": "2026-11-12T11:00:00Z"}], now)
            self.assertEqual(w and w["kind"], expect, state)
        self.assertIsNone(dsar.owed(row, [{"kind": "ack", "state": "sent", "at": "2026-11-12T11:00:00Z"}], now))

    def test_no_acknowledgement_promises_an_answer_by_a_date_it_is_too_near_to_keep(self):
        # live dry run 2026-11-12: #52, received 13 October, would have been told "you will have our answer by
        # 12 November" one hour before that date
        # ... and the late update says "we are late", which is not true an hour before the date either: a request
        # first reached inside the runway is owed nothing until its date, then the late update
        near = self.row(received_at="2026-10-13T04:18:33Z")
        self.assertIsNone(dsar.owed(near, [], utc(2026, 11, 12, 3, 17)))
        w = dsar.owed(near, [], utc(2026, 11, 12, 4, 19))
        self.assertEqual((w["kind"], w["variant"]), ("status", "late_claim_or_authority"))
        self.assertNotIn("due", w["facts"])
        self.assertEqual(w["facts"]["next"], "26 November 2026")
        three_days = self.row(received_at="2026-10-16T00:00:00Z")           # due 15 November
        self.assertEqual(dsar.owed(three_days, [], utc(2026, 11, 12))["kind"], "ack", "exactly three days left")
        self.assertIsNone(dsar.owed(three_days, [], utc(2026, 11, 12, 0, 1)))
        self.assertEqual(dsar.owed(three_days, [], utc(2026, 11, 15))["variant"], "late_claim_or_authority")
        # told "by the date" already (an acknowledgement went out): nothing more until the date itself
        acked = self.row(received_at="2026-10-16T00:00:00Z", ack_sent_at="2026-10-16T01:00:00Z",
                         status_sent_at="2026-10-31T00:00:00Z", next_contact_at="2026-11-15T00:00:00Z")
        self.assertIsNone(dsar.owed(acked, [], utc(2026, 11, 14)))
        self.assertEqual(dsar.owed(acked, [], utc(2026, 11, 15))["variant"], "late_claim_or_authority")

    def test_a_request_already_asked_is_not_acknowledged_a_second_time(self):
        self.assertIsNone(dsar.owed(self.row(ask_sent_at="2026-11-11T12:00:00Z"), [], NOW))

    def test_one_status_update_at_the_halfway_point(self):
        acked = self.row(ack_sent_at="2026-11-11T01:00:00Z")
        self.assertIsNone(dsar.owed(acked, [], utc(2026, 11, 25)), "before halfway: nothing")
        w = dsar.owed(acked, [], utc(2026, 11, 26, 1))
        self.assertEqual((w["kind"], w["slot"], w["variant"]), ("status", "status", "status_claim_or_authority"))
        self.assertEqual(w["facts"]["next"], "11 December 2026")
        self.assertIsNone(dsar.owed({**acked, "status_sent_at": "2026-11-26T02:00:00Z"}, [], utc(2026, 12, 5)))
        # never two unprompted messages inside a week
        late_ack = self.row(ack_sent_at="2026-11-24T00:00:00Z")
        self.assertIsNone(dsar.owed(late_ack, [], utc(2026, 11, 27)))
        self.assertIsNotNone(dsar.owed(late_ack, [], utc(2026, 12, 2)))

    # ---- the ownership ask goes at once (ruling 2026-11-13, inbox 003 point 3)
    EVIDENCE = {"v": 1, "need": "claim_evidence"}

    def test_the_ownership_ask_goes_at_once_whatever_the_ladder_last_said(self):
        # #469's shape: past its date, told "nothing is needed" that morning, next contact promised in 14 days
        told = self.row(received_at="2026-09-24T13:06:13Z", gates=self.EVIDENCE,
                        status_sent_at="2026-11-13T06:35:00Z", next_contact_at="2026-11-27T06:35:00Z")
        sent = [{"kind": "status", "state": "sent", "at": "2026-11-13T06:35:00Z"}]
        now = utc(2026, 11, 13, 22, 0)
        w = dsar.owed(told, sent, now)
        self.assertEqual((w["kind"], w["slot"], w["variant"]), ("status", "status-2", "late_claim_evidence"))
        self.assertEqual(w["effects"], {"ownership_ask_at": "sent"})
        self.assertEqual(w["facts"], {"received": "24 September 2026", "next": "27 November 2026"})
        # the same request under the older need waits for its promised contact: only this need jumps the queue
        self.assertIsNone(dsar.owed({**told, "gates": {"v": 1, "need": "claim_or_authority"}}, sent, now))
        # #465's shape: asked two days ago, date still ahead, halfway point not reached
        asked = self.row(received_at="2026-11-11T15:40:16Z", gates=self.EVIDENCE, ask_sent_at="2026-11-11T16:32:00Z")
        w = dsar.owed(asked, [], now)
        self.assertEqual((w["kind"], w["slot"], w["variant"]), ("status", "status", "status_claim_evidence"))
        self.assertEqual(w["facts"]["next"], "11 December 2026")
        self.assertEqual(w["effects"], {"ownership_ask_at": "sent"})
        self.assertNotIn("due", w["facts"])

    def test_the_ownership_ask_is_sent_once_and_stands_down_for_a_letter_that_may_be_out(self):
        now = utc(2026, 11, 13, 22, 0)
        asked = self.row(received_at="2026-11-11T15:40:16Z", gates=self.EVIDENCE, ask_sent_at="2026-11-11T16:32:00Z")
        gone = {**asked, "ownership_ask_at": "2026-11-13T22:30:00Z", "status_sent_at": "2026-11-13T22:30:00Z"}
        self.assertIsNone(dsar.owed(gone, [], utc(2026, 11, 14, 22, 0)), "sent: the ordinary schedule applies again")
        for state in ("sending", "unknown"):
            flight = [{"kind": "status", "state": state, "at": "2026-11-13T21:00:00Z"}]
            self.assertIsNone(dsar.owed(asked, flight, now), state)
        for state in ("refused", "failed"):
            tried = [{"kind": "status", "state": state, "at": "2026-11-13T21:00:00Z"}]
            self.assertEqual(dsar.owed(asked, tried, now)["variant"], "status_claim_evidence", state)

    def test_a_request_nobody_has_written_to_gets_the_ownership_ask_in_its_first_message(self):
        fresh = self.row(gates=self.EVIDENCE)
        w = dsar.owed(fresh, [], NOW)
        self.assertEqual((w["kind"], w["slot"], w["variant"]), ("ack", "ack", "ack_claim_evidence"))
        self.assertEqual(w["effects"], {"ownership_ask_at": "sent"})
        # inside the last three days no acknowledgement can promise the date: the ask still goes, as an update
        near = self.row(received_at="2026-10-13T04:18:33Z", gates=self.EVIDENCE)
        w = dsar.owed(near, [], utc(2026, 11, 11, 12, 0))
        self.assertEqual((w["kind"], w["variant"]), ("status", "status_claim_evidence"))
        self.assertEqual(w["facts"]["next"], "12 November 2026")
        # no other need writes the date
        self.assertEqual(dsar.owed(self.row(), [], NOW)["effects"], {})

    def test_past_the_date_there_is_no_acknowledgement_only_an_update_with_the_next_contact(self):
        old = self.row(received_at="2026-09-01T00:00:00Z")
        w = dsar.owed(old, [], NOW)
        self.assertEqual((w["kind"], w["variant"]), ("status", "late_claim_or_authority"))
        self.assertNotIn("due", w["facts"], "a deadline that has passed is never stated as one")
        self.assertEqual(w["facts"]["next"], "26 November 2026")
        self.assertEqual(w["next_contact_at"], "2026-11-26T12:00:00Z")
        self.assertEqual(w["effects"], {}, "the answer waits on the requester: no answer date is promised")

    def test_a_late_request_we_need_nothing_for_is_told_its_answer_date_and_the_date_is_recorded(self):
        old = self.row(received_at="2026-09-01T00:00:00Z", gates={"v": 1, "need": "none"})
        w = dsar.owed(old, [], NOW)
        self.assertEqual((w["kind"], w["variant"]), ("status", "late_none"))
        self.assertEqual(w["facts"]["next"], "26 November 2026")
        self.assertEqual(w["effects"], {"answer_promised_at": "2026-11-26T12:00:00Z"})
        self.assertEqual(dsar.LATE_ANSWER_DAYS, 14, "the answer date a late update states is a promise, not a tuning")

    # ---- Art. 12(3) extension: only on a ground that is a recorded fact, only inside the first month
    def ext_row(self, **kw):
        base = {"received_at": "2026-10-16T12:00:00Z", "gates": {"v": 1, "need": "none"},     # due 2026-11-15T12:00Z
                "ack_sent_at": "2026-10-16T13:00:00Z"}
        base.update(kw)
        return self.row(**base)

    NEED = {"extension_need": "21 open requests from this requester; each page needs its hide merged",
            "extension_need_ruling": "ruling-x"}

    def test_an_extension_is_owed_only_on_a_recorded_need_for_several_requests_near_the_date(self):
        w = dsar.owed(self.ext_row(**self.NEED), [], NOW, open_from_requester=2, answerable=False)
        self.assertEqual((w["kind"], w["slot"], w["variant"]), ("extension", "extension", "extension_number"))
        self.assertEqual(w["facts"], {"received": "16 October 2026", "due": "15 December 2026"})
        self.assertEqual(w["effects"], {"extended_until": "2026-12-15T12:00:00Z", "extension_reason": "number",
                                        "extension_ruling": "ruling-x"})
        self.assertLessEqual(dsar._parse(w["effects"]["extended_until"]), dsar.extension_limit("2026-10-16T12:00:00Z"))
        # one request is not a number: it gets the ordinary in-time update, and its date stands
        for alone in (dsar.owed(self.ext_row(**self.NEED), [], NOW, open_from_requester=1, answerable=False),
                      dsar.owed(self.ext_row(**self.NEED), [], NOW, answerable=False)):
            self.assertEqual((alone["kind"], alone["variant"], alone["effects"]), ("status", "status_none", {}))
        early = dsar.owed(self.ext_row(**self.NEED), [], utc(2026, 11, 1), open_from_requester=5, answerable=False)
        self.assertNotEqual((early or {}).get("kind"), "extension", "not before the date is inside the alarm window")

    def test_a_count_of_requests_near_the_date_is_not_a_need_for_more_time(self):
        """QA review of #1908: two requests due tomorrow were sent extension notices on count and proximity alone,
        though the answer could go at once. "May be extended ... where necessary": the need is a recorded fact with
        the ruling that found it, or no date moves."""
        for row in (self.ext_row(),
                    self.ext_row(extension_need=self.NEED["extension_need"]),
                    self.ext_row(extension_need_ruling="ruling-x"),
                    self.ext_row(extension_need="  ", extension_need_ruling="ruling-x")):
            for answerable in (True, False):
                w = dsar.owed(row, [], NOW, open_from_requester=9, answerable=answerable)
                self.assertEqual((w["kind"], w["variant"], w["effects"]), ("status", "status_none", {}))
        # ... and where code can send the answer today, the answer goes: no time is needed, whatever is recorded
        w = dsar.owed(self.ext_row(**self.NEED), [], NOW, open_from_requester=9, answerable=True)
        self.assertEqual((w["kind"], w["variant"], w["effects"]), ("status", "status_none", {}))
        tomorrow = self.ext_row(**self.NEED, received_at="2026-10-14T12:00:00Z")
        self.assertIsNone(dsar.owed(tomorrow, [], NOW, open_from_requester=2, answerable=True))

    def test_no_answer_date_and_no_extension_for_an_answer_code_cannot_produce(self):
        # An access request while no complete copy can be built: late and sorry, the next contact, no answer date.
        old = self.row(**{"class": "privacy_access"}, received_at="2026-09-01T00:00:00Z", gates={"v": 1, "need": "none"})
        w = dsar.owed(old, [], NOW, answerable=False)
        self.assertEqual((w["kind"], w["variant"]), ("status", dsar.LATE_NO_DATE_VARIANT))
        self.assertEqual(w["effects"], {}, "no answer date is recorded, so the clock cannot be told one was kept")
        self.assertEqual(w["next_contact_at"], "2026-11-26T12:00:00Z")
        self.assertEqual(dsar.owed(old, [], NOW)["variant"], "late_none", "an answer code can produce keeps its date")
        # ... and with no need recorded the date is not moved for it either: the ordinary in-time update
        near = dsar.owed(self.ext_row(), [], NOW, open_from_requester=4, answerable=False)
        self.assertEqual((near["kind"], near["variant"], near["effects"]), ("status", "status_none", {}))
        # while the answer waits on the requester nothing changes: the variant is the need's own
        waiting = self.row(received_at="2026-09-01T00:00:00Z", gates={"v": 1, "need": "link"})
        self.assertEqual(dsar.owed(waiting, [], NOW, answerable=False)["variant"], "late_link")

    def test_an_extension_never_covers_lateness_already_incurred(self):
        late = dsar.owed(self.ext_row(**self.NEED, received_at="2026-09-01T00:00:00Z"), [], NOW,
                         open_from_requester=9, answerable=False)
        self.assertEqual((late["kind"], late["variant"]), ("status", dsar.LATE_NO_DATE_VARIANT),
                         "past the date the requester is told we are late; the date is not moved after the fact")
        on_the_date = dsar.owed(self.ext_row(**self.NEED), [], utc(2026, 11, 15, 12, 0), open_from_requester=9,
                                answerable=False)
        self.assertNotEqual((on_the_date or {}).get("kind"), "extension")

    def test_an_extension_is_never_owed_while_the_answer_waits_on_the_requester_or_twice(self):
        for need in dsar.NEEDS:
            if need == dsar.NEED_NONE:
                continue
            w = dsar.owed(self.ext_row(**self.NEED, gates={"v": 1, "need": need}), [], NOW, open_from_requester=4,
                          answerable=False)
            self.assertNotEqual((w or {}).get("kind"), "extension", need)
        again = dsar.owed(self.ext_row(**self.NEED, extended_until="2026-12-15T12:00:00Z"), [], NOW,
                          open_from_requester=4, answerable=False)
        self.assertNotEqual((again or {}).get("kind"), "extension", "the date moves once")

    def test_a_refusal_is_never_owed(self):
        # default: comply. Nothing in the ladder selects a refusal, whatever the request looks like.
        for need in dsar.NEEDS:
            for received in ("2026-11-11T00:00:00Z", "2026-10-16T12:00:00Z", "2026-09-01T00:00:00Z", "2024-01-04T00:00:00Z"):
                for n in (1, 2, 50):
                    w = dsar.owed(self.row(received_at=received, gates={"v": 1, "need": need}), [], NOW, n)
                    self.assertNotEqual((w or {}).get("kind"), "denial")
                    self.assertFalse(((w or {}).get("variant") or "").startswith("denial"))

    def test_past_the_date_updates_repeat_ahead_of_each_promise_until_the_final_response(self):
        sent = [{"kind": "status", "state": "sent"}]
        old = self.row(received_at="2026-09-01T00:00:00Z", status_sent_at="2026-11-12T12:00:00Z",
                       next_contact_at="2026-11-26T12:00:00Z")
        self.assertIsNone(dsar.owed(old, sent, utc(2026, 11, 20)))
        w = dsar.owed(old, sent, utc(2026, 11, 25, 13))
        self.assertEqual((w["slot"], w["variant"]), ("status-2", "late_claim_or_authority"))
        self.assertIsNone(dsar.owed({**old, "confirmed_at": "2026-11-21T00:00:00Z"}, sent, utc(2026, 11, 25, 13)))
        # asked four days ago and now past the date: wait out the quiet week first
        asked = self.row(received_at="2026-09-01T00:00:00Z", ask_sent_at="2026-11-08T00:00:00Z")
        self.assertIsNone(dsar.owed(asked, [], NOW))
        self.assertIsNotNone(dsar.owed(asked, [], utc(2026, 11, 15, 1)))

    def test_a_held_body_is_kept_while_it_is_still_the_message_owed(self):
        want = dsar.owed(self.row(), [], NOW)
        msg = {"variant": want["variant"], "slot": want["slot"], "next_contact_at": want["next_contact_at"],
               "facts": dict(want["facts"])}
        self.assertFalse(dsar.stale(msg, want, self.row(), NOW + timedelta(days=5)))
        self.assertTrue(dsar.stale({**msg, "variant": "ack_link"}, want, self.row(), NOW))
        late = dsar.owed(self.row(received_at="2026-09-01T00:00:00Z"), [], NOW)
        held = {"variant": late["variant"], "slot": late["slot"], "next_contact_at": late["next_contact_at"],
                "facts": dict(late["facts"])}
        self.assertFalse(dsar.stale(held, late, {}, NOW + timedelta(days=10)))
        self.assertTrue(dsar.stale(held, late, {}, NOW + timedelta(days=12)),
                        "a promise two days out is too near to send: author it again with a new date")

    def held(self, want, copy_doc):
        return {"variant": want["variant"], "slot": want["slot"], "next_contact_at": want["next_contact_at"],
                "facts": dict(want["facts"]), "body": dsar.render(copy_doc, want["variant"], want["facts"])}

    def test_a_held_body_whose_date_is_no_longer_the_date_is_authored_again(self):
        """QA review of #1908: a held acknowledgement was kept on variant and slot alone, so a request folded into
        an earlier one (receipt moves back) or given an extension kept a body stating the old deadline, and an
        approval arriving later would have sent it."""
        doc = dsar.load_copy()
        first = self.row(received_at="2026-11-11T00:00:00Z")
        want = dsar.owed(first, [], NOW)
        msg = self.held(want, doc)
        self.assertIn("11 December 2026", msg["body"])
        earlier = self.row(received_at="2026-11-09T00:00:00Z")                 # duplicate folding moved the receipt
        now_owed = dsar.owed(earlier, [], NOW)
        self.assertEqual((now_owed["variant"], now_owed["slot"]), (want["variant"], want["slot"]))
        self.assertEqual(now_owed["facts"]["due"], "9 December 2026")
        self.assertTrue(dsar.stale(msg, now_owed, earlier, NOW), "the held body states a deadline that has moved")
        self.assertFalse(dsar.stale(msg, want, first, NOW))

    def test_a_held_status_update_follows_a_date_an_extension_moved(self):
        doc = dsar.load_copy()
        row = self.row(received_at="2026-10-20T00:00:00Z", ack_sent_at="2026-10-20T01:00:00Z", gates={"v": 1, "need": "none"})
        at = utc(2026, 11, 8)
        want = dsar.owed(row, [], at)
        self.assertEqual((want["kind"], want["facts"]["next"]), ("status", "19 November 2026"))
        msg = self.held(want, doc)
        moved = {**row, "extended_until": "2026-11-25T00:00:00Z"}
        now_owed = dsar.owed(moved, [], at)
        self.assertEqual(now_owed["facts"]["next"], "25 November 2026")
        self.assertTrue(dsar.stale(msg, now_owed, moved, at))

    def test_a_held_body_that_is_no_longer_the_wording_is_authored_again(self):
        doc = dsar.load_copy()
        want = dsar.owed(self.row(), [], NOW)
        msg = self.held(want, doc)
        same = {**want, "text": msg["body"]}
        self.assertFalse(dsar.stale(msg, same, self.row(), NOW))
        self.assertTrue(dsar.stale(msg, {**want, "text": msg["body"].replace("Hello,", "Hello there,")}, self.row(), NOW))

    def test_a_held_late_update_is_kept_across_days_and_replaced_when_what_it_states_changes(self):
        doc = dsar.load_copy()
        row = self.row(received_at="2026-09-01T00:00:00Z")
        want = dsar.owed(row, [], NOW)
        msg = self.held(want, doc)
        later = NOW + timedelta(days=4)
        again = dsar.owed(row, [], later)
        again["text"] = dsar.render(doc, again["variant"], again["facts"])
        self.assertNotEqual(again["facts"]["next"], want["facts"]["next"], "a late update's next date moves every day")
        self.assertNotEqual(again["text"], msg["body"])
        self.assertFalse(dsar.stale(msg, again, row, later), "the date alone moving is not a reason: the hash under "
                                                             "review must stay the hash that is sent")
        moved = {**row, "received_at": "2026-08-20T00:00:00Z"}
        other = dsar.owed(moved, [], later)
        other["text"] = dsar.render(doc, other["variant"], other["facts"])
        self.assertTrue(dsar.stale(msg, other, moved, later), "the request date it states has changed")
        reworded = {**again, "text": again["text"].replace("Hello,", "Hello there,")}
        self.assertTrue(dsar.stale(msg, reworded, row, later))

    def test_a_final_response_in_the_send_ledger_is_a_final_response_with_or_without_its_stamp(self):
        """Measured on the live register 2026-11-12: 7 open erasure requests had a `sent` final confirmation in the
        ledger and no `confirmed_at`. Each was owed "we are late, and we are sorry" for an answer it already had."""
        row = self.row(received_at="2026-09-01T00:00:00Z", gates={"v": 1, "need": "none"})
        self.assertEqual(dsar.owed(row, [], NOW)["variant"], "late_none")
        final = [{"kind": "confirm", "state": "sent", "at": "2026-11-08T05:18:10Z"}]
        self.assertEqual(dsar.final_response_at(row, final), "2026-11-08T05:18:10Z")
        self.assertIsNone(dsar.owed(row, final, NOW))
        self.assertEqual(dsar.state_of(row, final), "closed")
        self.assertEqual(dsar.final_response_at({**row, "class": "privacy_access"},
                                                [{"kind": "access", "state": "sent", "at": "2026-11-10T00:00:00Z"}]),
                         "2026-11-10T00:00:00Z")
        for not_final in ([{"kind": "confirm-interim", "state": "sent", "at": "2026-11-08T05:18:10Z"}],
                          [{"kind": "confirm", "state": "unknown", "at": "2026-11-08T05:18:10Z"}],
                          [{"kind": "confirm", "state": "refused", "at": "2026-11-08T05:18:10Z"}],
                          [{"kind": "ask", "state": "sent", "at": "2026-11-01T00:00:00Z"}]):
            self.assertEqual(dsar.final_response_at(row, not_final), "", not_final)
        clock = dsar.clock_rows([{**row, "id": 1, "register_no": 3}], lambda _: final, NOW)
        self.assertEqual((clock["open"], clock["alarm"]), (0, []))


class Alarm(unittest.TestCase):
    def rows(self):
        mk = lambda i, n, cls, received, **kw: {"id": i, "register_no": n, "class": cls, "status": "open",  # noqa: E731
                                                "received_at": received, "gates": {"need": "none"}, **kw}
        return [mk(1, 468, "privacy_erasure", "2024-01-04T12:27:35Z"),
                mk(2, 141, "privacy_access", "2026-10-14T00:00:00Z"),          # due 2026-11-13: inside the window
                mk(3, 500, "privacy_erasure", "2026-11-11T00:00:00Z"),          # 29 days left: not named
                mk(4, 501, "privacy_erasure", "2026-09-01T00:00:00Z", confirmed_at="2026-09-20T00:00:00Z"),
                mk(5, 502, "legal_threat", "2026-09-01T00:00:00Z"),
                mk(6, 503, "privacy_erasure", "2026-09-01T00:00:00Z", status="duplicate")]

    def test_every_request_inside_seven_days_or_past_its_date_is_named_oldest_first(self):
        clock = dsar.clock_rows(self.rows(), lambda _: [], NOW)
        self.assertEqual([x["register_no"] for x in clock["alarm"]], [468, 141])
        self.assertEqual((clock["open"], clock["past_due"], clock["due_within_window"]), (3, 1, 1))
        self.assertEqual(clock["oldest_open"]["register_no"], 468)
        line = dsar.clock_line(clock)
        self.assertIn("#468 (1012 d past)", line)
        self.assertIn("#141 (due in 0 d)", line)
        self.assertNotIn("<@", line, "the clock names requests, never a person")

    def test_the_line_names_every_request_inside_the_window_however_many(self):
        """QA review of #1908: the line named 12 and said "and N more", so with 190 inside the window 178 were not
        named. A request the alarm does not name waits for somebody to go and look."""
        def mk(i):
            return {"id": i, "register_no": 1000 + i, "class": "privacy_erasure", "status": "open",
                    "received_at": "2026-09-01T00:00:00Z", "gates": {"v": 1, "need": "none"},
                    "ack_sent_at": "2026-09-02T00:00:00Z", "answer_promised_at": "2026-11-01T00:00:00Z"}
        clock = dsar.clock_rows([mk(i) for i in range(190)], lambda _: [], NOW)
        line = dsar.clock_line(clock)
        self.assertEqual(len(clock["alarm"]), 190)
        for i in range(190):
            self.assertEqual(line.count(f"#{1000 + i} ("), 1, i)
            self.assertEqual(line.count(f"#{1000 + i}"), 2, "and named again: the answer date we stated has passed")
        self.assertNotIn(" more", line)
        self.assertNotIn("\n", line)
        self.assertNotIn("no first message", line, "every one of them has been written to")

    def test_a_request_nobody_has_written_to_after_two_days_is_named_once(self):
        """Past its date AND never written to: named in the window, and only counted in the second list. Not yet
        near its date and never written to: named there, because nothing else would name it."""
        def mk(i, received):
            return {"id": i, "register_no": 600 + i, "class": "privacy_erasure", "status": "open",
                    "received_at": received, "gates": {"v": 1, "need": "link"}}
        rows = [mk(1, "2026-09-01T00:00:00Z"), mk(2, "2026-11-09T00:00:00Z"), mk(3, "2026-11-11T00:00:00Z"),
                {**mk(4, "2026-11-09T00:00:00Z"), "ask_sent_at": "2026-11-09T01:00:00Z"}]
        clock = dsar.clock_rows(rows, lambda _: [], NOW)
        self.assertEqual(clock["no_first_message"], [601, 602])
        line = dsar.clock_line(clock)
        self.assertTrue(line.endswith("; no first message after 48 h: #602 (and 1 of those named above)"), line)
        self.assertEqual(line.count("#601"), 1)
        for n in (603, 604):
            self.assertNotIn(f"#{n}", line, "a day old, or already asked")
        only = dsar.clock_line(dsar.clock_rows(rows[1:], lambda _: [], NOW))
        self.assertTrue(only.endswith("Oldest first: none; no first message after 48 h: #602"), only)
        # a send that MAY be out is a message: never a second alarm on top of an unresolved send
        maybe = dsar.clock_rows(rows[1:2], lambda _: [{"kind": "ask", "state": "unknown", "at": ""}], NOW)
        self.assertEqual(maybe["no_first_message"], [])

    def test_nothing_inside_the_window_is_silence(self):
        clock = dsar.clock_rows([self.rows()[2]], lambda _: [], NOW)
        self.assertEqual(dsar.clock_line(clock), "")

    def test_a_held_message_shows_in_the_alarm_with_its_reason(self):
        sends = [{"kind": "ack", "state": "refused", "detail": "copy gate pending: copy_review_pending"}]
        clock = dsar.clock_rows(self.rows()[:1], lambda _: sends, NOW)
        self.assertIn("copy gate pending", clock["alarm"][0]["held"])


class CopyGate(unittest.TestCase):
    """The adapter: only a verified approval of these bytes under the GDPR rubric is an approval."""
    BODY = "Hello,\n\nWe received your request."

    def ask(self, rc, answer, kind="ack"):
        out = answer if isinstance(answer, str) else json.dumps(answer)
        with mock.patch.object(copy_gate, "GATE", pathlib.Path(__file__)):
            return copy_gate.check(kind, self.BODY, variant="ack_none", slot="ack", runner=lambda argv, stdin: (rc, out))

    def test_an_approval_under_another_subject_is_not_an_approval_of_this_message(self):
        """QA review of #1908: with a subject, the subject hash was not compared at all, so a reworded subject line
        rode the verdict given for the old one."""
        def ask(subject, answer):
            with mock.patch.object(copy_gate, "GATE", pathlib.Path(__file__)):
                return copy_gate.check("access", self.BODY, variant="access_answer", slot="access", subject=subject,
                                       runner=lambda argv, stdin: (0, json.dumps(answer)))
        signed = self.good(campaign="gdpr-access", subject_sha256=copy_gate.body_sha("The copy you asked for"))
        self.assertTrue(ask("The copy you asked for", signed).ok)
        for subject in ("The copy you asked for!", "", "Something else entirely"):
            a = ask(subject, signed)
            self.assertFalse(a.ok, subject)
            self.assertIn("different subject hash", a.reason)
        self.assertFalse(ask("The copy you asked for", self.good(campaign="gdpr-access")).ok, "signed with no subject")

    def good(self, **kw):
        base = {"result": "approved", "body_sha256": copy_gate.body_sha(self.BODY), "rubric": "gdpr",
                "campaign": "gdpr-ack", "verdict_id": "v-1", "verdict_sha256": "cd" * 32,
                "reviewer_model": "mac-pool/claude-fable-5-1", "reviewed_at": "2026-11-12T02:00:00Z",
                "subject_sha256": copy_gate.body_sha("")}
        base.update(kw)
        return base

    def test_an_approval_of_these_bytes_under_the_gdpr_rubric_passes(self):
        a = self.ask(0, self.good())
        self.assertTrue(a.ok)
        self.assertEqual((a.result, a.verdict_id, a.rubric, a.body_sha256),
                         ("approved", "v-1", "gdpr", copy_gate.body_sha(self.BODY)))

    def test_everything_else_holds(self):
        cases = {
            "pending": (3, {"result": "pending", "reason": "copy_review_pending"}),
            "refused": (1, {"result": "refused", "reason": "copy_review_refuse:v-2"}),
            "rewrite": (1, {"result": "refused", "reason": "copy_review_rewrite:v-3"}),
            "gate error": (2, {"result": "error", "reason": "copy_gate_error:rubric 'gdpr' unreadable"}),
            "approved with a failing exit": (1, self.good()),
            "another body": (0, self.good(body_sha256="0" * 64)),
            "the default rubric": (0, self.good(rubric="default")),
            "no rubric named": (0, self.good(rubric="")),
            "another campaign": (0, self.good(campaign="decline")),
            "no verdict id": (0, self.good(verdict_id="")),
            "no statement hash": (0, self.good(verdict_sha256="")),
            "a subject nobody sent": (0, self.good(subject_sha256="1" * 64)),
            "no subject hash at all": (0, {k: v for k, v in self.good().items() if k != "subject_sha256"}),
            "unreadable output": (0, "Traceback (most recent call last):"),
            "no output": (0, ""),
            "a list": (0, "[]"),
        }
        for name, (rc, ans) in cases.items():
            a = self.ask(rc, ans)
            self.assertFalse(a.ok, name)
            self.assertNotEqual(a.result, "approved", name)
            self.assertTrue(a.reason, name)

    def test_a_missing_gate_or_one_that_cannot_run_holds(self):
        with mock.patch.object(copy_gate, "GATE", pathlib.Path("/nonexistent/outbound_copy/gate.py")):
            a = copy_gate.check("ack", self.BODY)
        self.assertEqual((a.ok, a.result), (False, "error"))
        self.assertIn("not installed", a.reason)

        def slow(argv, stdin):
            raise subprocess.TimeoutExpired(argv, 60)

        def broken(argv, stdin):
            raise OSError("exec format error")

        for runner in (slow, broken):
            with mock.patch.object(copy_gate, "GATE", pathlib.Path(__file__)):
                a = copy_gate.check("ack", self.BODY, runner=runner)
            self.assertEqual((a.ok, a.result), (False, "error"))
        self.assertFalse(copy_gate.check("confirm", self.BODY).ok, "a kind with no campaign is never approved")

    def test_the_gate_path_and_the_campaign_are_not_the_callers_to_choose(self):
        self.assertEqual(copy_gate.GATE, ROOT / "scripts" / "outbound_copy" / "gate.py")
        src = (ROOT / "scripts" / "gdpr_pipeline" / "copy_gate.py").read_text()
        self.assertNotIn("os.environ", src, "no environment variable may select the gate, the store or the rubric")
        seen = {}

        def runner(argv, stdin):
            seen["argv"], seen["stdin"] = argv, json.loads(stdin)
            return 3, json.dumps({"result": "pending", "reason": "copy_review_pending"})

        with mock.patch.object(copy_gate, "GATE", pathlib.Path(__file__)):
            copy_gate.check("status", self.BODY, variant="late_none", slot="status-2", runner=runner)
        self.assertEqual(seen["argv"][1:], ["-I", str(pathlib.Path(__file__)), "check", "--campaign", "gdpr-status",
                                            "--copy", "late_none", "--kind", "status-2"])
        self.assertEqual(seen["stdin"], {"subject": "", "body": self.BODY})


class Wiring(unittest.TestCase):
    """Store + Run + send.deliver, with the writer and the gate process replaced."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)
        self.posted = []

    def writer(self):
        return mock.patch.object(send, "_intercom_send",
                                 lambda c, t, a, dry_run=False, key="": self.posted.append((c, t, a)) or "api-log posted")

    def request(self, n=1, cls="privacy_erasure", received="2026-11-11T00:00:00Z", need="claim_or_authority", **kw):
        rid, _ = self.s.upsert({"keys": [f"intercom:{n}"], "channel": "intercom", "class": cls,
                                "received_at": received, "pages": []})
        kw.setdefault("requester_email", "arpad@example.com")
        self.s.update(rid, "decide", conversation_id=f"2154766503954{n:02d}", gates={"v": 1, "need": need},
                      requester_name="Arpad Laczkovszki", **kw)
        return rid

    def mail_request(self, n=1, channel="notices", email="arpad@example.com", received="2026-11-11T00:00:00Z"):
        """A deletion request written to notices@ / legal@: a thread this host can never reply in, and an address."""
        rid, _ = self.s.upsert({"keys": [f"gmail:{channel}@:{n}"], "channel": channel, "class": "privacy_erasure",
                                "received_at": received, "pages": []})
        self.s.update(rid, "decide", gmail_thread=f"1a15058a85f5f6{n:02d}", gates={"v": 1, "need": "link"},
                      requester_email=email)
        return rid

    def mailer(self):
        """The new-thread writer and the host's mail accounts (support@ only: notices@ / legal@ are aliases)."""
        def post(email, text, approved_by, dry_run=False, key="", mailbox="", subject=""):
            self.posted.append((email, text, subject, mailbox, approved_by))
            return "thread_id 1a1d5c0696b7b61a"
        return (mock.patch.object(send, "_mail_send_new_thread", post),
                mock.patch.object(send, "gog_accounts", lambda: {"support@muso.ai": {"gmail"}}))

    # ---- the store
    def test_a_live_store_from_before_the_ladder_migrates_in_place(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "erasure.sqlite")
            s = Store(path)
            rid, _ = s.upsert({"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                               "received_at": "2026-11-01T00:00:00Z", "pages": []})
            s.db.close()
            db = sqlite3.connect(path)
            for col in ("gates", "ack_sent_at", "ack_ref", "status_sent_at", "status_ref", "next_contact_at",
                        "dsar_state", "dsar_state_at", "extended_until", "extension_reason", "extension_ruling",
                        "answer_promised_at", "ownership_ask_at"):
                db.execute(f"ALTER TABLE erasure_requests DROP COLUMN {col}")
            db.execute("DROP TABLE dsar_messages")
            db.commit()
            db.close()
            again = Store(path)
            row = again.get(rid)
            self.assertEqual((row["gates"], row["ack_sent_at"], row["extended_until"]), ({}, "", ""))
            self.assertEqual(row["answer_promised_at"], "")
            self.assertEqual(row["ownership_ask_at"], "")
            self.assertEqual(again.messages(rid), [])

    def test_a_message_table_from_the_first_ladder_gains_the_effects_column(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "erasure.sqlite")
            Store(path).db.close()
            db = sqlite3.connect(path)
            db.execute("ALTER TABLE dsar_messages DROP COLUMN effects")
            db.commit()
            db.close()
            again = Store(path)
            self.assertIn("effects", {r[1] for r in again.db.execute("PRAGMA table_info(dsar_messages)")})

    def test_the_page_that_deploys_with_the_tick_covers_the_same_seven_days_as_the_clock(self):
        """QA review of #1908: the firstmate clock line is carried by a check registered outside this repo, so on its
        own this PR deployed no alarm at 7 days. The Slack page runs from the hourly tick; a statutory request is on
        it from 7 days out, and it names no person."""
        now = utc(2026, 11, 12, 12, 0)
        six = self.request(1, received="2026-10-19T12:00:00Z", need="none")                     # due in 6 d
        eight = self.request(2, received="2026-10-21T12:00:00Z", need="none")                   # due in 8 d
        other = self.request(3, cls="dmca_takedown", received="2026-10-19T12:00:00Z")           # 6 d, not statutory
        paged = {reg: line for reg, line in self.run.watchdog_rows(now)}
        self.assertIn(self.s.get(six)["register_no"], paged)
        self.assertNotIn(self.s.get(eight)["register_no"], paged)
        self.assertNotIn(self.s.get(other)["register_no"], paged, "the other classes keep their 3 days")
        self.assertFalse(any("<@" in line for line in paged.values()), "the page names a request, never a person")
        self.assertEqual(dsar.ALARM_DAYS, 7)

    # ---- what a SENT message commits us to
    def test_the_date_moves_only_when_the_extension_notice_has_been_sent(self):
        now = utc(2026, 11, 12, 12, 0)
        gone = [{"id": "p1", "verdict": "GONE"}]       # not an answer code can send today
        a = self.request(1, received="2026-10-16T12:00:00Z", need="none", contact_id="c-1",
                         ack_sent_at="2026-10-16T13:00:00Z", verdict_detail=gone)
        b = self.request(2, received="2026-11-10T12:00:00Z", need="none", contact_id="c-1",
                         ack_sent_at="2026-11-10T13:00:00Z", verdict_detail=gone)
        other = self.request(3, received="2026-10-16T12:00:00Z", need="none", contact_id="c-2",
                             ack_sent_at="2026-10-16T13:00:00Z", verdict_detail=gone,
                             extension_need="x", extension_need_ruling="ruling-y")
        owed = {x["row"]: x for x in self.run.dsar_owed(now)}
        self.assertEqual(owed[a]["variant"], "status_none", "two requests near the date, and no need recorded")
        self.s.update(a, "extension_need", extension_need="two open requests; each page is already off the site",
                      extension_need_ruling="ruling-x")
        owed = {x["row"]: x for x in self.run.dsar_owed(now)}
        self.assertEqual(owed[a]["variant"], "extension_number")
        self.assertNotIn(b, owed, "the second request is not near its date")
        self.assertEqual(owed[other]["variant"], "status_none", "a requester with one request gets no extension")
        self.s.update(other, "test", status_sent_at="2026-11-11T12:00:00Z")      # leave the extension the only one owed
        with self.writer():
            held = self.run.dsar_send(now, checker=pending)
        self.assertEqual([x["state"] for x in held], ["held"])
        self.assertEqual(self.s.get(a)["extended_until"], "", "held: the requester has not been told, the date stands")
        self.assertEqual(dsar.due(self.s.get(a)), utc(2026, 11, 15, 12, 0))
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            sent = self.run.dsar_send(now, checker=approve)
        self.assertEqual([x["state"] for x in sent], ["sent"])
        row = self.s.get(a)
        self.assertEqual((row["extended_until"], row["extension_reason"], row["extension_ruling"]),
                         ("2026-12-15T12:00:00Z", "number", "ruling-x"))
        self.assertEqual(dsar.due(row), utc(2026, 12, 15, 12, 0))
        self.assertEqual(self.posted[0][0], row["conversation_id"])
        self.assertIn("by 15 December 2026", self.posted[0][1])
        self.assertEqual((row["interim_confirm_at"], row["confirmed_at"]), ("", ""),
                         "an extension notice is not a response")
        self.assertEqual([x["variant"] for x in self.run.dsar_owed(now) if x["row"] == a], [], "and it is sent once")

    def test_a_sent_ownership_ask_records_the_date_it_went_and_moves_no_statutory_date(self):
        """Ruling 2026-11-13 (inbox 003 point 4): the register notes when the ownership ask went out; the statutory
        date is not moved."""
        now = utc(2026, 11, 13, 22, 0)
        rid = self.request(1, received="2026-09-24T13:06:13Z", need="claim_evidence")
        self.s.claim_send(rid, "status", "intercom", "c", "0" * 64, "gate:x", "sending")
        self.s.finish_send(rid, "status", "sent", ref="x")
        self.s.update(rid, "status", status_sent_at="2026-11-13T06:35:00Z", next_contact_at="2026-11-27T06:35:00Z")
        before = self.s.get(rid)
        self.assertEqual(before["ownership_ask_at"], "")
        with self.writer(), mock.patch.object(copy_gate, "check", pending), \
                mock.patch.object(self.s, "person_contacted_on", lambda row, day: None):
            held = self.run.dsar_send(now, checker=pending)
        self.assertEqual([x["state"] for x in held], ["held"])
        self.assertEqual(self.s.get(rid)["ownership_ask_at"], "", "an ask that was only authored is not a sent ask")
        with self.writer(), mock.patch.object(copy_gate, "check", approve), \
                mock.patch.object(self.s, "person_contacted_on", lambda row, day: None):
            out = self.run.dsar_send(now, checker=approve)
        self.assertEqual([(x["state"], x["variant"], x["slot"]) for x in out],
                         [("sent", "late_claim_evidence", "status-2")])
        body = self.posted[0][1]
        self.assertIn("To finish this request we need to confirm that the page is yours.", body)
        self.assertIn("You do not need to send a passport or any other identity document.", body)
        self.assertNotIn("claim the page", body.lower())
        after = self.s.get(rid)
        self.assertRegex(after["ownership_ask_at"], r"^20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertNotEqual(after["ownership_ask_at"], "sent", "the date it went, not the placeholder")
        for col in ("due_at", "received_at", "extended_until", "extension_reason", "answer_promised_at"):
            self.assertEqual(after[col], before[col], f"{col}: an ownership ask moves no date")
        self.assertEqual(dsar.due(after), dsar.due(before))
        events = [e for e in self.s.events(rid) if e["kind"] == "dsar_effect"]
        self.assertEqual(len(events), 1, "the note is on the row's own trail")
        self.assertIn("ownership_ask_at", events[0]["detail"])
        with self.writer(), mock.patch.object(copy_gate, "check", approve), \
                mock.patch.object(self.s, "person_contacted_on", lambda row, day: None):
            self.assertEqual(self.run.dsar_send(now, checker=approve), [], "once")

    def test_a_sent_late_update_records_the_answer_date_and_the_clock_names_it_when_it_passes(self):
        now = utc(2026, 11, 12, 12, 0)
        rid = self.request(1, received="2026-09-01T00:00:00Z", need="none",
                           verdict_detail=[{"id": "p1", "verdict": "ALREADY_HIDDEN"}])
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            out = self.run.dsar_send(now, checker=approve)
        self.assertEqual([x["state"] for x in out], ["sent"])
        self.assertIn("We are late in answering it, and we are sorry.", self.posted[0][1])
        self.assertIn("When you will have our answer: by 26 November 2026", self.posted[0][1])
        self.assertEqual(self.s.get(rid)["answer_promised_at"], "2026-11-26T12:00:00Z")
        rows = self.s.all("open")
        before = dsar.clock_rows(rows, self.s.sends, utc(2026, 11, 20))
        after = dsar.clock_rows(rows, self.s.sends, utc(2026, 11, 27))
        self.assertEqual((before["promises_missed"], after["promises_missed"]), ([], [self.s.get(rid)["register_no"]]))
        self.assertIn("an answer date we stated has passed", dsar.clock_line(after))

    def test_a_late_erasure_request_is_told_an_answer_date_only_when_code_alone_can_answer_it(self):
        """firstmate 2026-11-12: "no promise we cannot hold". Live dry run the same day: 64 late erasure requests
        needed nothing from the requester, and most named a page already off the site (GONE), which has no coded
        final response. A date stated to those is a date nothing here can keep."""
        now = utc(2026, 11, 12, 12, 0)
        rows = {
            "hidden": self.request(1, received="2026-09-01T00:00:00Z", need="none",
                                   verdict_detail=[{"id": "p1", "verdict": "ALREADY_HIDDEN"}]),
            "gone": self.request(2, received="2026-09-01T00:00:00Z", need="none",
                                 verdict_detail=[{"id": "p2", "verdict": "GONE"}]),
            "to_merge": self.request(3, received="2026-09-01T00:00:00Z", need="none",
                                     verdict_detail=[{"id": "p3", "verdict": "PASS_A"}]),
            "mixed": self.request(4, received="2026-09-01T00:00:00Z", need="none",
                                  verdict_detail=[{"id": "p4", "verdict": "ALREADY_HIDDEN"},
                                                  {"id": "p5", "verdict": "GONE"}]),
            "no_page": self.request(5, received="2026-09-01T00:00:00Z", need="none"),
        }
        owed = {x["row"]: x for x in self.run.dsar_owed(now)}
        self.assertEqual(owed[rows["hidden"]]["variant"], "late_none")
        self.assertEqual(list(owed[rows["hidden"]]["effects"]), ["answer_promised_at"])
        for name in ("gone", "to_merge", "mixed", "no_page"):
            got = owed[rows[name]]
            self.assertEqual((got["variant"], got["effects"]), (dsar.LATE_NO_DATE_VARIANT, {}), name)
            self.assertNotIn("have our answer", got["text"], name)

    def test_a_late_access_request_is_told_no_answer_date_while_no_complete_copy_can_be_built(self):
        now = utc(2026, 11, 12, 12, 0)
        self.assertTrue(access.standing_gaps(access.load_manifest()), "the shipped manifest has open gaps today")
        acc = self.request(1, cls="privacy_access", received="2026-09-01T00:00:00Z", need="none")
        era = self.request(2, received="2026-09-01T00:00:00Z", need="none", verdict_detail=[{"id": "p1", "verdict": "ALREADY_HIDDEN"}])
        owed = {x["row"]: x for x in self.run.dsar_owed(now)}
        self.assertEqual((owed[acc]["variant"], owed[acc]["effects"], owed[acc]["problem"]),
                         (dsar.LATE_NO_DATE_VARIANT, {}, ""))
        self.assertNotIn("have our answer", owed[acc]["text"])
        self.assertEqual(owed[era]["variant"], "late_none", "every page hidden: the confirmation is code's to send")
        whole = {**access.load_manifest(), "information_notice": {"text": "approved"}, "column_review": {"reviewed": True}}
        whole["systems"] = [{**x, "covered": True} for x in whole["systems"]]
        self.assertEqual(access.standing_gaps(whole), [])
        with mock.patch.object(access, "load_manifest", lambda *a: whole):
            self.assertEqual({x["row"]: x["variant"] for x in self.run.dsar_owed(now)}[acc], "late_none")
        with mock.patch.object(access, "load_manifest", mock.Mock(side_effect=access.ManifestError("gone"))):
            self.assertEqual({x["row"]: x["variant"] for x in self.run.dsar_owed(now)}[acc], dsar.LATE_NO_DATE_VARIANT,
                             "a manifest that cannot be read is not a manifest with no gaps")

    def test_a_message_can_write_only_the_columns_a_message_may_commit(self):
        rid = self.request()
        self.s.put_message(rid, "status", "status", "late_none", "b", copy_gate.body_sha("b"), "c", {}, "",
                           {"answer_promised_at": "2026-11-26T12:00:00Z", "confirmed_at": "2026-11-12T00:00:00Z",
                            "status": "closed"})
        self.assertEqual(self.s.message(rid, "status")["effects"], {"answer_promised_at": "2026-11-26T12:00:00Z"})
        self.s.stamp_sent(rid, "status", "status", "r1")
        row = self.s.get(rid)
        self.assertEqual((row["answer_promised_at"], row["confirmed_at"], row["status"]),
                         ("2026-11-26T12:00:00Z", "", "open"))

    def test_each_kind_stamps_its_own_column(self):
        rid = self.request()
        self.s.stamp_sent(rid, "ack", "ack", "r1")
        self.s.stamp_sent(rid, "status", "status-2", "r2")
        row = self.s.get(rid)
        self.assertTrue(row["ack_sent_at"] and row["status_sent_at"])
        self.assertEqual((row["ack_ref"], row["status_ref"]), ("r1", "r2"))
        self.assertEqual((row["interim_confirm_at"], row["confirmed_at"], row["ask_sent_at"]), ("", "", ""),
                         "a ladder message must never read as a confirmation or an ask")

    def test_a_sent_body_cannot_be_re_authored(self):
        rid = self.request()
        self.s.put_message(rid, "ack", "ack", "ack_none", "body one", copy_gate.body_sha("body one"), "c", {}, "")
        self.s.put_message(rid, "ack", "ack", "ack_link", "body two", copy_gate.body_sha("body two"), "c", {}, "")
        self.assertEqual(self.s.message(rid, "ack")["body"], "body two")
        replaced = [e for e in self.s.events(rid) if e["kind"] == "dsar_authored"]
        self.assertEqual(len(replaced), 2, "a replaced body stays in the event trail")
        self.s.update_message(rid, "ack", state="sent")
        with self.assertRaises(sqlite3.IntegrityError):
            self.s.put_message(rid, "ack", "ack", "ack_none", "body three", "x", "c", {}, "")
        with self.assertRaises(ValueError):
            self.s.update_message(rid, "ack", body="edited after review")

    # ---- NO VERDICT, NO SEND
    def test_a_message_without_a_verdict_does_not_send(self):
        rid = self.request()
        with self.writer():
            out = self.run.dsar_send(NOW, checker=pending)
        self.assertEqual([x["state"] for x in out], ["held"])
        self.assertEqual(self.posted, [])
        msg = self.s.message(rid, "ack")
        self.assertEqual((msg["state"], msg["gate_result"], msg["verdict_id"]), ("held", "pending", ""))
        self.assertEqual(self.s.get(rid)["ack_sent_at"], "")
        self.assertIsNone(self.s.send_record(rid, "ack"), "a held message never takes the send slot")

    def test_deliver_asks_the_gate_itself_and_holds_on_anything_but_an_approval(self):
        """The author step said approved; the gate at the send says otherwise. The send is what counts."""
        rid = self.request()
        for name, answer in (("pending", pending),
                             ("refused", lambda *a, **k: copy_gate.Answer(False, "refused", "copy_review_refuse:v-9",
                                                                          "x")),
                             ("error", lambda *a, **k: copy_gate.Answer(False, "error", "the copy gate is not "
                                                                        "installed", "x"))):
            with self.writer(), mock.patch.object(copy_gate, "check", answer):
                out = self.run.dsar_send(NOW, checker=approve)
            self.assertEqual(out[0]["state"], "held", name)
            self.assertEqual(self.posted, [], name)
            rec = self.s.send_record(rid, "ack")
            self.assertEqual((rec["state"], rec["channel"], rec["approved_by"]), ("refused", "none", "gate:none"), name)
            self.assertIn("copy gate", rec["detail"])
            self.assertEqual(self.s.message(rid, "ack")["state"], "held", name)
            self.assertEqual(self.s.get(rid)["ack_sent_at"], "", name)

    def test_the_real_adapter_with_no_gate_installed_holds(self):
        """No stub for the gate at all: on a tree without scripts/outbound_copy/gate.py nothing is sent."""
        rid = self.request()
        with self.writer(), mock.patch.object(copy_gate, "GATE", pathlib.Path("/nonexistent/gate.py")):
            out = self.run.dsar_send(NOW)
        self.assertEqual((out[0]["state"], self.posted), ("held", []))
        self.assertIn("not installed", self.s.message(rid, "ack")["gate_reason"])

    def test_text_that_is_not_the_authored_body_is_refused_before_the_gate_is_asked(self):
        rid = self.request()
        self.run.dsar_author(NOW, checker=approve)
        asked = []
        with self.writer(), mock.patch.object(copy_gate, "check", lambda *a, **k: asked.append(a) or approve(*a, **k)):
            out = send.deliver(self.run, {"row": rid, "register_no": 40, "text": "Any other words."}, "ack", "U7RP6HKUZ")
            none = send.deliver(self.run, {"row": rid, "register_no": 40, "text": "Any other words."}, "status",
                                "U7RP6HKUZ", slot="status-7")
        self.assertEqual((out["state"], none["state"], self.posted, asked), ("refused", "refused", [], []))
        self.assertIn("not the authored body", out["why"])

    def test_a_gated_slot_cannot_be_reached_under_another_kind(self):
        for kind, slot in (("ack", "ack"), ("status", "status"), ("confirm", "ack"), ("ask", "status-3"),
                           ("extension", "extension"), ("denial", "denial")):
            self.assertTrue(send.is_gated(kind, slot), (kind, slot))
        for kind, slot in (("ask", "ask"), ("confirm", "confirm"), ("confirm", "confirm-interim")):
            self.assertFalse(send.is_gated(kind, slot), (kind, slot))

    # ---- a request that can only be answered in a new mail thread (notices@ / legal@)
    def test_the_reviewer_is_asked_about_a_new_thread_letter_as_it_goes_on_the_wire(self):
        rid = self.mail_request()
        asked = []

        def recording(kind, body, variant="", slot="", subject="", runner=None):
            asked.append((body, subject))
            return approve(kind, body, variant, slot, subject)
        post, accounts = self.mailer()
        with post, accounts, mock.patch.object(copy_gate, "check", recording):
            out = self.run.dsar_send(NOW, checker=recording)
        frozen = self.s.message(rid, "ack")["body"]
        lead = "You wrote to us at notices@muso.ai on 11 November 2026 about your deletion request."
        wire, subject = lead + "\n\n" + frozen, "Your Muso.AI data deletion request"
        # the author step and the send step put the same pair to the gate, and it is the letter that left
        self.assertEqual(asked, [(wire, subject), (wire, subject)])
        self.assertEqual([x["state"] for x in out], ["sent"])
        self.assertEqual([p[:4] for p in self.posted], [("arpad@example.com", wire, subject, "support@muso.ai")])
        self.assertTrue(self.posted[0][4].startswith("gate:v-"))
        self.assertFalse(frozen.startswith("You wrote"))        # the row on record stays the authored body
        gate = [e for e in self.s.events(rid) if e["kind"] == "dsar_gate"]
        self.assertIn(copy_gate.body_sha(wire), json.dumps(gate))
        self.assertIn(subject, json.dumps(gate))

    def test_a_verdict_on_the_body_alone_does_not_send_a_new_thread_letter(self):
        rid = self.mail_request()

        def body_only(kind, body, variant="", slot="", subject="", runner=None):
            return pending(kind, body) if subject or body.startswith("You wrote") else approve(kind, body)
        post, accounts = self.mailer()
        with post, accounts, mock.patch.object(copy_gate, "check", body_only):
            out = self.run.dsar_send(NOW, checker=body_only)
        self.assertEqual(([x["state"] for x in out], self.posted), (["held"], []))
        self.assertEqual(self.s.message(rid, "ack")["gate_result"], "pending")

    def test_a_new_thread_letter_for_a_class_with_no_approved_subject_is_refused(self):
        rid = self.mail_request()
        self.s.update(rid, "decide", **{"class": "privacy_access"})
        post, accounts = self.mailer()
        with post, accounts, mock.patch.object(copy_gate, "check", approve):
            out = self.run.dsar_send(NOW, checker=approve)
        self.assertEqual(self.posted, [])
        self.assertEqual([x["state"] for x in out], ["refused"])

    def test_a_letter_that_cannot_be_assembled_is_reported_and_the_other_rows_are_still_authored(self):
        """`route()` refuses a class with no approved new-thread subject before the author step asks for the wire
        form, so today the two cannot disagree. If they ever do, `copy.new_thread_letter` raises a `ValueError` and
        the author step must record THAT request and carry on: a held row is retryable, but an exception would
        leave every other request of the hour with no reviewed message."""
        bad = self.mail_request(1)                                    # notices@: the wire form is a new thread
        self.s.update(bad, "decide", **{"class": "privacy_access"})   # ... whose subject has no GO
        good = self.request(2)
        real = send.route

        def route(row):
            if row.get("id") == bad:
                return "mail_new_thread", row.get("requester_email")
            return real(row)
        with mock.patch.object(send, "route", route):
            out = self.run.dsar_author(NOW, checker=approve)
        self.assertEqual([x["row"] for x in out], [good], "the ordinary row is authored and put up for review")
        self.assertTrue(all(x["approved"] for x in out))
        self.assertEqual(self.s.message(good, "ack")["state"], "approved")
        self.assertEqual(self.s.message(bad, "ack")["gate_result"], "", "no verdict is bound to a letter nobody can assemble")
        self.assertEqual([e for e in self.s.events(bad) if e["kind"] == "dsar_gate"], [])
        self.assertEqual(len(self.run.errors), 1)
        self.assertIn("no approved SUBJECT", self.run.errors[0])

    # ---- one message per person per UTC day
    def test_a_second_request_from_the_same_person_waits_for_another_day(self):
        first, second, other = self.request(1), self.request(2), self.request(3, requester_email="b@example.com")
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            out = {x["row"]: x for x in self.run.dsar_send(NOW, checker=approve)}
        self.assertEqual([out[r]["state"] for r in (first, second, other)], ["sent", "held", "sent"])
        self.assertIn("one message per person per UTC day", out[second]["why"])
        self.assertEqual((len(self.posted), self.s.send_record(second, "ack")), (2, None))   # the slot stays free
        # the day after, the ledger holds nothing for that day and the held message goes
        self.s.db.execute("UPDATE erasure_sends SET at='2026-11-10T09:00:00Z'")
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            again = {x["row"]: x for x in self.run.dsar_send(NOW, checker=approve)}
        self.assertEqual((again[second]["state"], len(self.posted)), ("sent", 3))

    def test_a_letter_that_may_be_out_counts_as_the_days_message(self):
        first, second = self.request(1), self.request(2)
        self.s.claim_send(first, "ask", "intercom", "215476650395401", "0" * 64, "U1", "unknown")
        self.assertEqual(self.s.person_contacted_on(self.s.get(second), datetime.now(timezone.utc).strftime("%Y-%m-%d"))["kind"], "ask")
        self.s.finish_send(first, "ask", "refused")
        self.assertIsNone(self.s.person_contacted_on(self.s.get(second), datetime.now(timezone.utc).strftime("%Y-%m-%d")))

    def test_an_older_identity_ask_waits_for_another_day_after_a_ladder_letter(self):
        first = self.request(1)
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            self.assertEqual([x["state"] for x in self.run.dsar_send(NOW, checker=approve)], ["sent"])
        asked = self.request(2, need="link")
        item = {"row": asked, "register_no": self.s.get(asked)["register_no"], "channel": "intercom",
                "to": self.s.get(asked)["conversation_id"], "kind": "ASK_LINK", "text": copy.ASK["ASK_LINK"],
                "class": "privacy_erasure"}
        with self.writer():
            held = send.deliver(self.run, item, "ask", "U1")
        self.assertEqual((held["state"], len(self.posted)), ("held", 1), "one message to that person today")
        self.assertIn("one message per person per UTC day", held["why"])
        self.assertIsNone(self.s.send_record(asked, "ask"), "nothing was refused: the ask slot stays free")
        self.assertEqual(self.s.get(asked)["ask_sent_at"], "")
        # the next day the ledger holds nothing for that person today
        self.s.db.execute("UPDATE erasure_sends SET at='2026-11-11T09:00:00Z'")
        with self.writer():
            again = send.deliver(self.run, item, "ask", "U1")
        self.assertEqual((again["state"], len(self.posted)), ("sent", 2))

    # ---- ... and the day is reserved WITH the claim, not by a read before it
    def another_worker_claims_after_the_first_read(self, store, other, kind="ask"):
        """The race, made deterministic: the early read answers "no letter today", and before this worker reaches
        its own claim another worker claims a letter to the same person on a different request."""
        real, seen = store.person_contacted_on, []

        def read(row, day):
            got = real(row, day)
            if not seen:
                store.claim_send(other, kind, "intercom", "215476650395499", "0" * 64, "gate:other", "sending")
            seen.append(got)
            return got
        return mock.patch.object(store, "person_contacted_on", read), seen

    def test_a_ladder_letter_is_held_when_another_worker_claimed_the_person_after_the_early_read(self):
        first, other = self.request(1), self.request(2)
        racing, seen = self.another_worker_claims_after_the_first_read(self.s, other)
        with self.writer(), mock.patch.object(copy_gate, "check", approve), racing:
            out = {x["row"]: x for x in self.run.dsar_send(NOW, checker=approve)}
        self.assertIsNone(seen[0], "the early read saw nothing: only the claim's own read can hold this letter")
        self.assertEqual(out[first]["state"], "held")
        self.assertIn("one message per person per UTC day", out[first]["why"])
        self.assertEqual(self.posted, [], "no letter left for a person another worker is already writing to")
        self.assertIsNone(self.s.send_record(first, "ack"), "nothing was claimed: the slot stays free")

    def test_an_identity_ask_is_held_when_another_worker_claimed_the_person_after_the_early_read(self):
        asked, other = self.request(1, need="link"), self.request(2)
        item = {"row": asked, "register_no": self.s.get(asked)["register_no"], "channel": "intercom",
                "to": self.s.get(asked)["conversation_id"], "kind": "ASK_LINK", "text": copy.ASK["ASK_LINK"],
                "class": "privacy_erasure"}
        racing, seen = self.another_worker_claims_after_the_first_read(self.s, other, kind="confirm")
        with self.writer(), racing:
            held = send.deliver(self.run, item, "ask", "U1")
        self.assertEqual((seen[0], held["state"], self.posted), (None, "held", []))
        self.assertIn("one message per person per UTC day", held["why"])
        self.assertIsNone(self.s.send_record(asked, "ask"))
        self.assertEqual(self.s.get(asked)["ask_sent_at"], "")

    def test_workers_on_different_requests_from_one_person_claim_one_letter_between_them(self):
        """Real connections, real threads: the unique key is per request, so only the write lock stands between
        eight workers and eight letters to one person."""
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "erasure.sqlite")
            seed = Store(path)
            rows = {}
            for n in range(1, 9):
                rid, _ = seed.upsert({"keys": [f"intercom:{n}"], "channel": "intercom", "class": "privacy_erasure",
                                      "received_at": "2026-11-11T00:00:00Z", "pages": []})
                seed.update(rid, "decide", conversation_id=f"2154766503954{n:02d}", requester_email="arpad@example.com")
                rows[rid] = seed.get(rid)
            seed.db.close()
            start, opening, got = threading.Barrier(len(rows)), threading.Lock(), {}

            def worker(rid):
                with opening:
                    mine = Store(path)
                try:
                    start.wait(timeout=30)
                    got[rid] = mine.claim_send_for_person(rows[rid], rid, "ack", "intercom", "c", "0" * 64, "gate:x")
                except Exception as exc:        # a worker that could not answer is a failed test, not a held one
                    got[rid] = exc
                finally:
                    mine.db.close()
            threads = [threading.Thread(target=worker, args=(rid,)) for rid in rows]
            for th in threads:
                th.start()
            for th in threads:
                th.join(timeout=60)
            claimed = [rid for rid, answer in got.items() if answer is None]
            self.assertEqual((len(got), len(claimed)), (8, 1), got)
            winner = rows[claimed[0]]["register_no"]
            for rid, answer in got.items():
                if rid != claimed[0]:
                    self.assertEqual((answer["register_no"], answer["kind"], answer["state"]), (winner, "ack", "sending"))
            check = Store(path)
            self.addCleanup(check.db.close)
            self.assertEqual(check.db.execute("SELECT COUNT(*) FROM erasure_sends").fetchone()[0], 1)

    def test_a_held_claim_leaves_no_open_transaction_and_an_already_claimed_slot_still_refuses(self):
        first, second = self.request(1), self.request(2)
        self.assertIsNone(self.s.claim_send_for_person(self.s.get(first), first, "ack", "intercom", "c", "0" * 64, "gate:x"))
        held = self.s.claim_send_for_person(self.s.get(second), second, "ack", "intercom", "c", "0" * 64, "gate:x")
        self.assertEqual((held["kind"], held["state"], self.s.db.in_transaction), ("ack", "sending", False))
        self.assertIsNone(self.s.send_record(second, "ack"))
        # the same request's own slot is still the double-send guard: a claim over a letter that may be out raises
        self.s.db.execute("UPDATE erasure_sends SET at='2026-11-10T09:00:00Z'")
        self.s.db.commit()
        with self.assertRaises(sqlite3.IntegrityError):
            self.s.claim_send_for_person(self.s.get(first), first, "ack", "intercom", "c", "0" * 64, "gate:x")
        self.assertFalse(self.s.db.in_transaction)

    # ---- the approved path, end to end
    def test_an_approved_acknowledgement_sends_once_with_the_verdict_on_the_ledger(self):
        rid = self.request()
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            first = self.run.dsar_send(NOW, checker=approve)
            again = self.run.dsar_send(NOW + timedelta(hours=1), checker=approve)
        self.assertEqual([x["state"] for x in first], ["sent"])
        self.assertEqual(again, [], "nothing more is owed an hour later")
        self.assertEqual(len(self.posted), 1)
        conv, body, by = self.posted[0]
        sha = copy_gate.body_sha(body)
        self.assertIn("11 December 2026", body)
        self.assertNotIn("Arpad", body)
        msg, rec, row = self.s.message(rid, "ack"), self.s.send_record(rid, "ack"), self.s.get(rid)
        self.assertEqual((msg["state"], msg["body_sha"], msg["verdict_id"], msg["rubric"], msg["gate_result"]),
                         ("sent", sha, "v-" + sha[:8], "gdpr", "approved"))
        self.assertEqual((rec["state"], rec["body_sha"], rec["approved_by"]), ("sent", sha, by))
        self.assertEqual(by, "gate:v-" + sha[:8], "the authorisation on record is the verdict, not a person")
        self.assertTrue(row["ack_sent_at"])
        self.assertEqual(row["next_contact_at"], "2026-12-11T00:00:00Z")
        self.assertEqual(dsar.state_of(row, self.s.sends(rid)), "identity_check")

    def test_the_hash_under_review_is_the_hash_that_is_sent(self):
        rid = self.request()
        self.run.dsar_author(NOW, checker=pending)
        held = self.s.message(rid, "ack")
        self.run.dsar_author(NOW + timedelta(days=3), checker=pending)
        self.assertEqual(self.s.message(rid, "ack")["body_sha"], held["body_sha"])
        self.assertEqual(self.s.message(rid, "ack")["authored_at"], held["authored_at"], "not re-authored each run")
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            self.run.dsar_send(NOW + timedelta(days=4), checker=approve)
        self.assertEqual(copy_gate.body_sha(self.posted[0][1]), held["body_sha"])

    def test_a_changed_need_replaces_the_held_body_and_keeps_the_old_hash_in_the_trail(self):
        rid = self.request(need="link")
        self.run.dsar_author(NOW, checker=pending)
        first = self.s.message(rid, "ack")
        self.s.update(rid, "decide", gates={"v": 1, "need": "none"})
        self.run.dsar_author(NOW, checker=pending)
        second = self.s.message(rid, "ack")
        self.assertEqual((first["variant"], second["variant"]), ("ack_link", "ack_none"))
        self.assertNotEqual(first["body_sha"], second["body_sha"])
        self.assertIn(first["body_sha"], json.dumps(self.s.events(rid)))

    def test_the_cap_counts_messages_that_reached_a_writer(self):
        for n in (1, 2, 3):
            self.request(n, requester_email=f"p{n}@example.com")
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            out = self.run.dsar_send(NOW, limit=2, checker=approve)
        self.assertEqual((len(self.posted), [x["state"] for x in out]), (2, ["sent", "sent"]))

    def test_past_due_requests_go_first(self):
        self.request(1)
        old = self.request(2, received="2026-09-01T00:00:00Z")
        owed = self.run.dsar_owed(NOW)
        self.assertEqual((owed[0]["row"], owed[0]["variant"], owed[0]["kind"]), (old, "late_claim_or_authority", "status"))

    def test_a_dry_run_asks_nothing_and_writes_nothing(self):
        rid = self.request()
        self.run.dsar_author(NOW, checker=approve)
        with self.writer(), mock.patch.object(copy_gate, "check", side_effect=AssertionError("asked")):
            out = self.run.dsar_send(NOW, dry_run=True, checker=approve)
        self.assertEqual((out[0]["state"], self.posted), ("dry-run", []))
        self.assertIsNone(self.s.send_record(rid, "ack"))

    def test_a_body_that_fails_the_lint_is_reported_and_never_authored(self):
        rid = self.request()
        bad = dsar.load_copy()
        bad["blocks"]["ack_open"] += " We flagged it."
        with mock.patch.object(dsar, "load_copy", lambda path=None: bad):
            out = self.run.dsar_author(NOW, checker=approve)
        self.assertEqual(out, [])
        self.assertIsNone(self.s.message(rid, "ack"))
        self.assertTrue(any("barred" in e for e in self.run.errors))

    # ---- the ladder and the older letters
    def test_the_ladder_takes_over_the_ask_for_a_statutory_request_only(self):
        a = self.request(1, identity_verdict="ASK_LINK", need="link")
        b = self.request(2, cls="dmca_takedown", identity_verdict="ASK_LINK")
        self.assertEqual({x["row"] for x in self.run.asks(NOW)}, {a, b})
        self.assertEqual([x["row"] for x in self.run.dsar_owed(NOW)], [a], "a takedown gets no ladder message")
        # once the ladder has authored the request's message, the older ask stands down while the review is awaited
        self.run.dsar_author(NOW, checker=pending)
        self.assertEqual({x["row"] for x in self.run.asks(REAL())}, {b})

    def test_a_ladder_message_nobody_reviews_does_not_leave_the_request_with_no_first_contact(self):
        """QA on #1908: with the gate installed and no review round running, the ladder authors and holds, and the
        older ask used to stand down for good. Now it waits `FALLBACK_HOURS` for the review and then goes."""
        a = self.request(1, identity_verdict="ASK_LINK", need="link")
        self.run.dsar_author(NOW, checker=pending)
        self.assertEqual(self.s.message(a, "ack")["state"], "held")
        soon = REAL() + timedelta(hours=dsar.FALLBACK_HOURS - 1)
        late = REAL() + timedelta(hours=dsar.FALLBACK_HOURS + 1)
        self.assertEqual(self.run.asks(soon), [], "the review is given a day")
        listed = self.run.asks(late)
        self.assertEqual([x["row"] for x in listed], [a], "after a day unreviewed the older ask is the first contact")
        self.assertIn("link", listed[0]["text"].lower())
        self.assertNotIn("your ID", listed[0]["text"], "the fallback is never the identity step")
        # and once that ask has gone, the ladder owes no acknowledgement: one first message, not two
        self.s.claim_send(a, "ask", "intercom", "1", "0" * 64, "U7RP6HKUZ", "sending")
        self.s.finish_send(a, "ask", "sent", ref="x")
        self.assertEqual([x for x in self.run.dsar_owed(NOW) if x["kind"] == "ack"], [])

    def test_the_fallback_never_goes_beside_a_reviewed_or_sent_ladder_message(self):
        a = self.request(1, identity_verdict="ASK_LINK", need="link")
        self.run.dsar_author(NOW, checker=approve)
        late = REAL() + timedelta(days=30)
        self.assertEqual(self.s.message(a, "ack")["state"], "approved")
        self.assertEqual(self.run.asks(late), [], "an approved message is about to go: no second first message")
        b = self.request(2, identity_verdict="ASK_LINK", need="link")
        self.s.claim_send(b, "ack", "intercom", "2", "0" * 64, "gate:x", "sending")
        self.assertEqual(self.run.asks(late), [], "a claimed acknowledgement may be out")
        self.s.finish_send(b, "ack", "unknown")
        self.assertEqual(self.run.asks(late), [], "unknown is 'may have been sent'")

    def test_the_identity_step_is_listed_like_any_ask_and_refused_for_its_words_in_the_ledger(self):
        """Its wording says a name "as it appears on your ID ... is enough". Under the 2026-11-12 ruling a name match
        ties nobody to a page, so the letter would promise what the next step refuses. The request is not left off
        the list for that (the list follows the gate's verdict, the same for every ask): it is listed, and the words
        are refused on the record, the way an ask for a class with no approved copy is."""
        a = self.request(1, received="2026-10-14T12:00:00Z", identity_verdict="ASK_IDENTITY")   # due in 2 days
        b = self.request(2, cls="dmca_takedown", identity_verdict="ASK_LINK")
        c = self.request(3, identity_verdict="ASK_IDENTITY")
        self.assertEqual(self.run.dsar_owed(NOW)[0]["row"], c)
        listed = {x["row"]: x for x in self.run.asks(NOW)}
        self.assertEqual(set(listed), {a, b, c}, "no ladder letter for any of them: every one is listed")
        for rid in (a, c):
            self.assertIn("2026-11-12 ruling", listed[rid]["refuse"])
            self.assertIn("as it appears on your ID", listed[rid]["refuse"])
        self.run.dsar_author(NOW, checker=pending)
        self.assertEqual({x["row"] for x in self.run.asks(REAL())}, {a, b}, "c's letter is in the review queue")
        self.assertEqual({x["row"] for x in self.run.asks(REAL() + timedelta(days=30))}, {a, b, c})
        # delivering it posts nothing and writes the refusal where the trail and the next run can read it
        with self.writer():
            out = send.deliver(self.run, listed[a], "ask", "U7RP6HKUZ")
        self.assertEqual((out["state"], self.posted), ("refused", []))
        self.assertEqual(self.s.send_record(a, "ask")["state"], "refused")
        self.assertIn("2026-11-12 ruling", self.s.send_record(a, "ask")["detail"])
        self.assertFalse(dsar.first_contact_made(self.s.get(a), self.s.sends(a)), "a refusal is not a first message")
        self.assertIn(f"#{self.s.get(a)['register_no']} (", dsar.clock_line(self.run.dsar_clock(NOW)))

    def test_a_request_the_ladder_owes_nothing_yet_still_gets_the_older_ask_for_a_link(self):
        """Inside 3 days of its date the ladder authors nothing (an acknowledgement would promise a date it cannot
        keep). The ask for a link promises nothing, so it is the first contact rather than silence."""
        a = self.request(1, received="2026-10-14T12:00:00Z", identity_verdict="ASK_LINK", need="link")   # due in 2 days
        self.assertEqual(self.run.dsar_owed(NOW), [], "inside the runway: the ladder waits for the date")
        self.run.dsar_author(NOW, checker=pending)
        self.assertEqual(self.s.messages(a), [])
        self.assertEqual({x["row"] for x in self.run.asks(NOW)}, {a})

    def test_a_request_with_no_owed_letter_gets_the_older_ask_unchanged_while_the_gate_holds_other_letters(self):
        """The case firstmate named on QA finding 2 of #1908. The gate is installed, the ladder has run this tick and
        its letters for OTHER requests wait for a verdict (or were refused one, or the gate could not answer). A
        request the ladder owes nothing must get the older ask exactly as it did before the ladder existed: same row,
        same kind, same bytes."""
        owed = self.request(1, identity_verdict="ASK_LINK", need="link")
        runway = self.request(2, received="2026-10-14T12:00:00Z", identity_verdict="ASK_LINK", need="link")
        agent = self.request(3, received="2026-10-14T12:00:00Z", identity_verdict="ASK_AUTH", need="authority")
        late = self.request(4, received="2026-09-01T00:00:00Z", identity_verdict="ASK_LINK", need="link")
        before = {x["row"]: x for x in self.run.asks(NOW)}
        self.assertEqual(set(before), {owed, runway, agent, late}, "before the ladder runs: every one is asked")
        # Two reads, each against a baseline taken at ITS OWN instant, so the ladder is the only thing between them.
        # The older ask words itself by the request's date (copy.PROGRESS_LINE once it has passed), ladder or none:
        # read at the real clock against the baseline above, this test failed for every PR from 2026-11-13T12:00Z,
        # the moment `runway` and `agent` (received 14 October) reached their date.
        at = REAL()
        before_at = {x["row"]: x for x in self.run.asks(at)}

        for name, checker in (("pending", pending), ("refused", refuse), ("error", gate_error)):
            with self.subTest(verdict=name):
                self.run.dsar_author(NOW, checker=checker)
                self.assertEqual(self.s.message(owed, "ack")["state"], "held")
                self.assertEqual(self.s.messages(runway), [], "inside 3 d of its date the ladder owes it nothing")
                self.assertEqual(self.s.messages(agent), [])
                after, after_at = ({x["row"]: x for x in self.run.asks(t)} for t in (NOW, at))
                for rid in (runway, agent):
                    self.assertEqual(after[rid], before[rid], "no owed letter: the older ask, unchanged")
                    self.assertEqual(after_at[rid], before_at[rid], "and unchanged at the clock the store stamps with")
                self.assertEqual(dsar.ladder_letter(self.s.get(runway), self.s.sends(runway), []), "")
                # the two the ladder authored for follow the verdict on THEIR letter, and nothing else
                for rid in (owed, late):
                    self.assertTrue(self.s.messages(rid))
                    self.assertEqual(rid in after, name != "pending", (name, rid))

    def test_each_gate_verdict_decides_the_older_ask_for_the_request_it_is_about(self):
        """End to end through the store, one request per verdict the gate can give: the ask is listed or not by the
        verdict on that request's own letter. Only a letter the gate approved or has in its queue stands it down."""
        want = {"approved": (approve, False), "pending": (pending, False), "refused": (refuse, True),
                "error": (gate_error, True)}
        rows = {name: self.request(n, identity_verdict="ASK_LINK", need="link")
                for n, name in enumerate(want, start=1)}
        by_body = {}

        def checker(kind, body, variant="", slot="", subject="", runner=None):
            return by_body[body](kind, body, variant=variant, slot=slot)

        for name, rid in rows.items():          # every request has its own date, so its own body
            self.s.update(rid, "decide", received_at=f"2026-11-{6 + list(rows).index(name):02d}T00:00:00Z")
        for item in self.run.dsar_owed(NOW):
            by_body[item["text"]] = want[next(n for n, r in rows.items() if r == item["row"])][0]
        self.assertEqual(len(by_body), len(want))
        self.run.dsar_author(NOW, checker=checker)
        listed = {x["row"] for x in self.run.asks(REAL())}
        for name, (_, goes) in want.items():
            with self.subTest(verdict=name):
                msg = self.s.message(rows[name], "ack")
                self.assertEqual(msg["gate_result"], name)
                self.assertEqual(dsar.ladder_letter(self.s.get(rows[name]), [], [msg]), name)
                self.assertEqual(rows[name] in listed, goes)
        # missing: the letter is authored and the gate was never asked about it (a run that died in between)
        gone = self.request(9, identity_verdict="ASK_LINK", need="link")
        self.s.put_message(gone, "ack", "ack", "ack_link", "x", copy_gate.body_sha("x"), "c", {}, "", {})
        self.assertEqual(self.s.message(gone, "ack")["gate_result"], "")
        self.assertIn(gone, {x["row"] for x in self.run.asks(REAL())})

    def test_a_request_whose_only_ask_is_the_superseded_identity_step_is_named_by_the_clock(self):
        """Not the ladder's doing: the captain's 2026-11-12 ruling made the letter untrue. So that such a request is
        never quiet AND unseen, the clock names every statutory request nobody has written to after 48 h."""
        a = self.request(1, received="2026-11-10T11:59:00Z", identity_verdict="ASK_IDENTITY")     # 48 h and a minute
        b = self.request(2, received="2026-11-10T12:01:00Z", identity_verdict="ASK_IDENTITY")     # a minute short
        self.assertEqual([bool(x["refuse"]) for x in self.run.asks(NOW)], [True, True], "listed, words refused")
        clock = self.run.dsar_clock(NOW)
        self.assertEqual(clock["alarm"], [], "neither is near its date")
        self.assertEqual(clock["no_first_message"], [self.s.get(a)["register_no"]])
        line = dsar.clock_line(clock)
        self.assertIn(f"no first message after 48 h: #{self.s.get(a)['register_no']}", line)
        self.assertNotIn(f"#{self.s.get(b)['register_no']}", line)
        self.assertIn("NOT running", dsar.clock_unread("", clock, NOW), "and an unread clock is loud for it too")
        # one message of ours, of any kind, and it is no longer named
        self.s.claim_send(a, "ack", "intercom", "1", "0" * 64, "gate:x", "sending")
        self.s.finish_send(a, "ack", "sent", ref="x")
        self.assertEqual(self.run.dsar_clock(NOW)["no_first_message"], [])
        self.assertEqual(dsar.clock_line(self.run.dsar_clock(NOW)), "")

    def test_an_ask_listed_before_the_ladder_wrote_is_not_sent_after_it(self):
        """A batch is listed, approved, and sent later. The row is read again at send."""
        a = self.request(1, identity_verdict="ASK_LINK", need="link")
        item = self.run.asks(NOW)[0]
        self.s.claim_send(a, "ack", "intercom", "1", "0" * 64, "gate:x", "sending")
        self.s.finish_send(a, "ack", "sent", ref="x")
        out = send.deliver(self.run, item, "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "skipped")
        self.assertIn("the ladder has written", out["why"])
        self.assertIsNone(self.s.send_record(a, "ask"), "nothing was claimed: the slot stays free")

    def test_the_due_date_page_names_no_person(self):
        self.request(1, received="2026-10-05T00:00:00Z")
        lines = self.run.watchdog(utc(2026, 11, 3))
        self.assertTrue(lines)
        self.assertNotIn("<@", page_text(lines))

    # ---- state and trail
    def test_the_state_is_recorded_with_an_event_only_when_it_changes(self):
        rid = self.request()
        self.assertEqual(self.run.dsar_states(), 1)
        self.assertEqual(self.s.get(rid)["dsar_state"], "received")
        self.assertEqual(self.run.dsar_states(), 0)
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            self.run.dsar_send(NOW, checker=approve)
        self.assertEqual(self.run.dsar_states(), 1)
        self.s.update(rid, "confirmed", confirmed_at="2026-11-20T00:00:00Z")
        self.run.dsar_states()
        states = [e["detail"] for e in self.s.events(rid) if e["kind"] == "dsar_state"]
        self.assertEqual([json.loads(d)["now"] for d in states], ["received", "identity_check", "closed"])

    def test_the_trail_rebuilds_what_was_received_checked_and_sent_from_the_store_alone(self):
        rid = self.request()
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            self.run.dsar_send(NOW, checker=approve)
        no = self.s.get(rid)["register_no"]
        trail = self.run.dsar_trail(no)
        self.assertEqual((trail["received_at"], trail["due_at"], trail["state"]),
                         ("2026-11-11T00:00:00Z", "2026-12-11T00:00:00Z", "identity_check"))
        self.assertEqual(trail["checked"]["gates"]["need"], "claim_or_authority")
        m = trail["messages"][0]
        self.assertEqual(copy_gate.body_sha(m["body"]), m["body_sha"])
        self.assertEqual((m["state"], m["gate_result"], m["rubric"]), ("sent", "approved", "gdpr"))
        self.assertTrue(m["verdict_id"] and m["verdict_sha256"] and m["reviewer_model"] and m["reviewed_at"])
        self.assertEqual(trail["sends"][0]["body_sha"], m["body_sha"])
        self.assertEqual(trail["sends"][0]["approved_by"], "gate:" + m["verdict_id"])
        kinds = [e["kind"] for e in trail["events"]]
        for k in ("created", "dsar_authored", "dsar_gate", "ack", "dsar_sent"):
            self.assertIn(k, kinds)
        self.assertIsNone(self.run.dsar_trail(99999))
        json.dumps(trail)


class OlderAsk(unittest.TestCase):
    """dsar.older_ask: one row of `OLDER_ASK_STANDS_DOWN` per thing the ladder can have for a request, and a test
    for each. The ask stands down only where the gate holds a letter that is going to this request."""

    ROW = {"class": "privacy_erasure", "ack_sent_at": "", "status_sent_at": ""}
    AT = utc(2026, 11, 12, 12, 0)
    FRESH, OLD = "2026-11-12T11:00:00Z", "2026-11-01T00:00:00Z"
    KINDS = ("ASK_LINK", "ASK_AUTH", "ASK_IDENTITY")

    def why(self, kind="ASK_LINK", row=None, sends=(), msgs=(), first=""):
        return dsar.older_ask(row or self.ROW, kind, list(sends), list(msgs), first, self.AT)

    def held(self, gate_result, authored_at=None):
        return [{"state": "held", "gate_result": gate_result, "authored_at": authored_at or self.FRESH}]

    def goes(self, **kw):
        for kind in self.KINDS:
            self.assertEqual(self.why(kind, **kw), "", kind)

    def stands_down(self, text, **kw):
        for kind in self.KINDS:
            self.assertIn(text, self.why(kind, **kw), kind)

    # ---- the table itself
    def test_the_table_decides_every_value_the_ladder_can_have_and_nothing_else_does(self):
        import inspect
        self.assertEqual(dsar.OLDER_ASK_STANDS_DOWN, {"sent": True, "approved": True, "pending": True,
                                                      "refused": False, "error": False, "missing": False, "": False})
        # every answer the copy gate can give is a key, so no verdict is undecided
        for verdict in (copy_gate.APPROVED, copy_gate.PENDING, copy_gate.REFUSED, copy_gate.ERROR):
            self.assertIn(verdict, dsar.OLDER_ASK_STANDS_DOWN)
        # `ladder_letter` returns nothing outside the table, whatever is in the rows
        seen = set()
        for row in (self.ROW, {**self.ROW, "ack_sent_at": self.OLD}, {**self.ROW, "status_sent_at": self.OLD}):
            for sends in ([], [{"kind": "ack", "state": "unknown"}], [{"kind": "ask", "state": "sent"}]):
                for state in ("held", "approved", "sent", "retired", ""):
                    for got in ("approved", "pending", "refused", "error", "", "something-new"):
                        seen.add(dsar.ladder_letter(row, sends, [{"state": state, "gate_result": got}]))
                seen.add(dsar.ladder_letter(row, sends, []))
        self.assertEqual(seen, set(dsar.OLDER_ASK_STANDS_DOWN))
        # there is no run-wide flag and no ask kind in the decision: the request's own rows, and the table
        self.assertEqual(list(inspect.signature(dsar.ladder_letter).parameters), ["row", "sends", "msgs"])
        src = inspect.getsource(dsar.older_ask)
        code = src[src.index('"""', src.index('"""') + 3) + 3:]
        self.assertNotIn("kind", code)
        self.assertIn("OLDER_ASK_STANDS_DOWN[letter]", code)
        self.assertNotIn("ladder_ran", src + (ROOT / "scripts" / "gdpr_pipeline" / "run.py").read_text())
        self.assertFalse(hasattr(dsar, "OLDER_ASK_RETIRED"))

    # ---- one test per verdict
    def test_approved_stands_down(self):
        """The gate approved these exact bytes: the letter goes on this send, and the ask would be a second one."""
        for state in ("approved", "sent"):
            msgs = [{"state": state, "gate_result": "approved", "authored_at": self.OLD}]
            self.assertEqual(dsar.ladder_letter(self.ROW, [], msgs), "approved")
            self.stands_down("reviewed message", msgs=msgs, first=self.OLD)

    def test_sent_or_may_have_been_sent_stands_down(self):
        self.stands_down("has written", row={**self.ROW, "ack_sent_at": self.OLD})
        self.stands_down("has written", row={**self.ROW, "status_sent_at": self.OLD})
        for kind in ("ack", "status", "status-2", "extension", "access"):
            for state in ("sent", "sending", "unknown"):
                self.stands_down("has written", sends=[{"kind": kind, "state": state}])
            for state in ("refused", "failed"):
                self.goes(sends=[{"kind": kind, "state": state}])

    def test_pending_stands_down_and_for_a_day_at_most(self):
        """In the review queue: the one case where the gate holds a letter that has not been decided."""
        self.assertEqual(dsar.FALLBACK_HOURS, 24)
        self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held("pending")), "pending")
        self.stands_down("under 24 h", msgs=self.held("pending"), first="2026-11-11T12:00:01Z")
        self.goes(msgs=self.held("pending"), first="2026-11-11T12:00:00Z")
        self.stands_down("under 24 h", msgs=self.held("pending"))       # no authoring event: the message's own time
        # a body re-authored every day must not push the fallback out for ever: the FIRST authoring is the start
        self.goes(msgs=self.held("pending", self.FRESH), first=self.OLD)
        # a wait nobody can measure is not a wait
        self.goes(msgs=[{"state": "held", "gate_result": "pending", "authored_at": ""}])

    def test_refused_proceeds_at_once(self):
        """The reviewer said no. No letter is coming for this request, so nothing is being waited for."""
        self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held("refused")), "refused")
        self.goes(msgs=self.held("refused"), first=self.FRESH)

    def test_error_proceeds_at_once(self):
        """The gate could not answer (not installed, timed out, unreadable): it holds nothing for this request."""
        self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held("error")), "error")
        self.goes(msgs=self.held("error"), first=self.FRESH)
        # an answer this code does not know, and an "approved" on a row that is still held, are errors too
        for odd in ("something-new", "approved"):
            self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held(odd)), "error", odd)
            self.goes(msgs=self.held(odd), first=self.FRESH)

    def test_missing_proceeds_at_once(self):
        """Authored, and no gate answer on record: nobody is reviewing it."""
        self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held("")), "missing")
        self.assertEqual(dsar.ladder_letter(self.ROW, [], [{"state": "held"}]), "missing")
        self.goes(msgs=self.held(""), first=self.FRESH)

    def test_no_letter_proceeds_as_before_the_ladder_existed(self):
        self.assertEqual(dsar.ladder_letter(self.ROW, [], []), "")
        self.goes()
        self.assertEqual(dsar.ladder_letter(self.ROW, [{"kind": "ask", "state": "sent"}], []), "")
        self.goes(sends=[{"kind": "ask", "state": "refused"}, {"kind": "confirm-interim", "state": "sent"}])

    def test_with_two_held_letters_the_request_waits_only_while_one_of_its_own_is_in_the_queue(self):
        both = self.held("refused") + self.held("pending")
        self.assertEqual(dsar.ladder_letter(self.ROW, [], both), "pending")
        self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held("refused") + self.held("error")), "refused")
        self.assertEqual(dsar.ladder_letter(self.ROW, [], self.held("error") + self.held("")), "error")
        self.assertEqual(dsar.ladder_letter(self.ROW, [], both + [{"state": "approved"}]), "approved")
        self.assertEqual(dsar.ladder_letter(self.ROW, [{"kind": "ack", "state": "unknown"}], both), "sent")

    def test_the_words_of_an_ask_are_a_separate_question_answered_in_the_ledger(self):
        from gdpr_pipeline import copy as ask_copy, run as run_mod
        self.assertEqual(dsar.ASK_WORDING_SUPERSEDED, ("ASK_IDENTITY",))
        self.assertIn("privacy_erasure", ask_copy.ASK_APPROVED_CLASSES)
        for cls in dsar.STATUTORY:
            if cls in ask_copy.ASK_APPROVED_CLASSES:
                self.assertIn("2026-11-12 ruling", run_mod.ask_refusal(cls, False, "ASK_IDENTITY"))
                for kind in ("ASK_LINK", "ASK_AUTH"):
                    self.assertEqual(run_mod.ask_refusal(cls, False, kind), "", kind)
        self.assertEqual(run_mod.ask_refusal("privacy_erasure", False), "", "the old two-argument call still reads")


class ClockReader(unittest.TestCase):
    """The firstmate check is registered in a firstmate home, on a box no deploy reaches. What deploys with the clock
    unit makes a check that is absent, stopped or out of date loud."""

    AT = utc(2026, 11, 12, 12, 0)
    INSIDE = {"alarm": [{"register_no": 468}, {"register_no": 141}], "alarm_days": 7}

    def test_an_empty_window_is_never_a_line(self):
        self.assertEqual(dsar.clock_unread("", {"alarm": []}, self.AT), "")

    def test_a_clock_read_in_the_last_day_is_silence_and_an_unread_one_is_a_line(self):
        self.assertEqual(dsar.CLOCK_UNREAD_HOURS, 26)
        self.assertEqual(dsar.clock_unread("2026-11-12T11:00:00Z", self.INSIDE, self.AT), "")
        self.assertEqual(dsar.clock_unread("2026-11-11T10:00:01Z", self.INSIDE, self.AT), "")
        stale = dsar.clock_unread("2026-11-11T10:00:00Z", self.INSIDE, self.AT)
        self.assertIn("NOT running", stale)
        self.assertIn("2 statutory", stale)
        self.assertIn("in 26 h", stale)
        self.assertNotIn("<@", stale, "it names no person")
        self.assertIn("ever", dsar.clock_unread("", self.INSIDE, self.AT))
        self.assertIn("NOT running", dsar.clock_unread("not a time", self.INSIDE, self.AT))
        self.assertIn("scripts/gdpr-dsar-clock-register.sh", stale, "the page names the one command that fixes it")

    def test_a_clock_read_by_a_check_that_is_not_the_deployed_one_is_a_line(self):
        """A registration binds a firstmate home to the check's bytes on the day it was run. When the check changes
        and deploys, the home goes on running the old one: it reads, so the 26 h test is quiet, and what it tells
        firstmate is the old check's idea of the clock. The check sends its sha256 with every read."""
        fresh, new, old = "2026-11-12T11:55:00Z", "a" * 64, "b" * 64
        self.assertEqual(dsar.clock_unread(fresh, self.INSIDE, self.AT, read_sha=new, deployed_sha=new), "")
        line = dsar.clock_unread(fresh, self.INSIDE, self.AT, read_sha=old, deployed_sha=new)
        self.assertIn("not the one deployed", line)
        self.assertIn("bbbbbbbbbbbb", line)
        self.assertIn("aaaaaaaaaaaa", line)
        self.assertIn("scripts/gdpr-dsar-clock-register.sh", line)
        self.assertNotIn("<@", line)
        # a reader that sent no identity is a registration from before the check carried one: stale by definition
        self.assertIn("no identity", dsar.clock_unread(fresh, self.INSIDE, self.AT, read_sha="", deployed_sha=new))
        # nobody reading at all is the louder fact, and is what is said
        self.assertIn("NOT running", dsar.clock_unread("", self.INSIDE, self.AT, read_sha=old, deployed_sha=new))
        # nothing named, nothing said; and a caller that cannot read the deployed check has nothing to compare
        self.assertEqual(dsar.clock_unread(fresh, {"alarm": []}, self.AT, read_sha=old, deployed_sha=new), "")
        self.assertEqual(dsar.clock_unread(fresh, self.INSIDE, self.AT, read_sha=old, deployed_sha=""), "")

    def cli(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gdpr_cli_clock", ROOT / "scripts" / "gdpr-pipeline.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_the_tick_pages_once_a_day_until_the_check_reads_the_clock(self):
        import contextlib
        import io
        cli = self.cli()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        s = Store(os.path.join(tmp.name, "erasure.sqlite"))
        s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-10-14T00:00:00Z", "pages": []})
        run = Run(s, log=lambda *_: None)
        posted = []
        with mock.patch.object(cli, "slack_post", lambda text: posted.append(text) or True), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertIn("NOT running", cli.clock_reader_watch(run, self.AT, page=False))
            self.assertEqual(posted, [], "no page without --page")
            cli.clock_reader_watch(run, self.AT, page=True)
            cli.clock_reader_watch(run, self.AT + timedelta(hours=1), page=True)
            self.assertEqual(len(posted), 1, "once a day")
            cli.clock_reader_watch(run, self.AT + timedelta(days=1), page=True)
            self.assertEqual(len(posted), 2, "and again the next day while nobody reads it")
            deployed = cli.clock_check_sha()
            self.assertEqual(deployed, hashlib.sha256((ROOT / "scripts" / "gdpr-dsar-clock-check.sh")
                                                      .read_bytes()).hexdigest())
            cli.clock_read_stamp(s.path, "firstmate", self.AT + timedelta(days=1), deployed)
            self.assertEqual(cli.clock_reader_watch(run, self.AT + timedelta(days=1, hours=1), page=True), "")
            self.assertEqual(len(posted), 2)
            reads = json.loads(pathlib.Path(tmp.name, cli.CLOCK_READS).read_text())
            self.assertEqual(reads, {"firstmate": "2026-11-13T12:00:00Z", "firstmate_sha": deployed})
            # the same reader a day later with other bytes (the home was not registered again after the check
            # changed): it is reading, and it is paged about all the same, once that day
            cli.clock_read_stamp(s.path, "firstmate", self.AT + timedelta(days=2), "c" * 64)
            line = cli.clock_reader_watch(run, self.AT + timedelta(days=2, minutes=1), page=True)
            self.assertIn("not the one deployed", line)
            cli.clock_reader_watch(run, self.AT + timedelta(days=2, minutes=2), page=True)
            self.assertEqual(len(posted), 3)
            # and what a reader sends is recorded only when it is a sha256: nothing else reaches the page
            cli.clock_read_stamp(s.path, "firstmate", self.AT + timedelta(days=2), "`rm -rf`")
            self.assertEqual(json.loads(pathlib.Path(tmp.name, cli.CLOCK_READS).read_text())["firstmate_sha"], "")

    def test_a_page_that_did_not_post_is_an_error_and_is_tried_again(self):
        import contextlib
        import io
        cli = self.cli()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        s = Store(os.path.join(tmp.name, "erasure.sqlite"))
        s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-10-14T00:00:00Z", "pages": []})
        run = Run(s, log=lambda *_: None)
        tries = []
        with mock.patch.object(cli, "slack_post", lambda text: tries.append(text) and False), \
                contextlib.redirect_stdout(io.StringIO()):
            cli.clock_reader_watch(run, self.AT, page=True)
            cli.clock_reader_watch(run, self.AT + timedelta(hours=1), page=True)
        self.assertEqual(len(tries), 2, "an undelivered page must not buy a day of silence")
        self.assertIn("clock-unread page failed", run.errors)

    def watch(self, store_path: str, kill: str) -> tuple[int, str, list]:
        """`gdpr-pipeline.py dsar clock --watch` as gdpr-dsar-clock.service runs it."""
        import contextlib
        import io
        cli = self.cli()
        posted, out = [], io.StringIO()
        with mock.patch.object(cli, "slack_post", lambda text: posted.append(text) or True), \
                mock.patch.object(cli, "KILL", kill), \
                mock.patch.object(cli, "hold_lock", lambda path: self.fail("the clock took the run lock")), \
                mock.patch.object(sys, "argv", ["gdpr-pipeline.py", "--store", store_path, "dsar", "clock", "--watch"]), \
                contextlib.redirect_stdout(out):
            rc = cli.main()
        return rc, out.getvalue(), posted

    def test_the_hourly_unit_prints_the_line_and_pages_when_firstmate_is_not_reading_it(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "erasure.sqlite")
        s = Store(path)
        s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-01-14T00:00:00Z", "pages": []})
        s.db.commit()
        nokill = os.path.join(tmp.name, "no-kill-file")
        rc, out, posted = self.watch(path, nokill)
        self.assertEqual(rc, 0)
        self.assertIn("GDPR clock: 1 statutory request(s) past their date", out, "the journal carries the line")
        self.assertEqual(len(posted), 1)
        self.assertIn("NOT running", posted[0])
        self.assertEqual(self.watch(path, nokill)[2], [], "once a day")
        # firstmate's check reads the clock: no page, and the line is still printed
        self.cli().clock_read_stamp(path, "firstmate", datetime.now(timezone.utc), self.cli().clock_check_sha())
        pathlib.Path(tmp.name, "clock-unread-last.json").unlink()
        rc, out, posted = self.watch(path, nokill)
        self.assertEqual((rc, posted), (0, []))
        self.assertIn("GDPR clock: 1 statutory", out)

    def test_the_kill_file_silences_the_units_page_and_never_the_read(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "erasure.sqlite")
        s = Store(path)
        s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-01-14T00:00:00Z", "pages": []})
        s.db.commit()
        kill = os.path.join(tmp.name, "gdpr-pipeline.disabled")
        pathlib.Path(kill).write_text("")
        rc, out, posted = self.watch(path, kill)
        self.assertEqual((rc, posted), (0, []))
        self.assertIn("GDPR clock: 1 statutory", out, "a kill file stops pages and writes, never the clock")
        self.assertIn("NOT running", out, "and the journal still says nobody is reading it")

    def test_an_empty_clock_still_leaves_a_line_in_the_journal(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "erasure.sqlite")
        Store(path).db.commit()
        rc, out, posted = self.watch(path, os.path.join(tmp.name, "none"))
        self.assertEqual((rc, posted), (0, []))
        self.assertIn("nothing inside 7 d of its date (0 open)", out, "an hour with nothing to say is still an hour read")

    def test_only_the_line_the_check_reads_leaves_the_mark(self):
        src = (ROOT / "scripts" / "gdpr-pipeline.py").read_text()
        self.assertIn('choices=("", "firstmate")', src)
        self.assertEqual(src.count("clock_read_stamp(run.store.path, a.read_by, now, a.reader_sha)"), 1)
        self.assertEqual(src.count("clock_read_stamp("), 2, "the definition and that one call")


class LadderOnAHostWithNoGate(unittest.TestCase):
    """Merged is not deployed, and this PR can reach node-8 before the gate does. Then the ladder authors nothing, so
    the older ask (which stands down only for a request the ladder has authored a message for) keeps running."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gdpr_cli_dsar", ROOT / "scripts" / "gdpr-pipeline.py")
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)
        rid, _ = self.s.upsert({"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-11-11T00:00:00Z", "pages": []})
        self.s.update(rid, "decide", conversation_id="215476650395401", gates={"v": 1, "need": "link"},
                      identity_verdict="ASK_LINK", ask_kind="link")
        self.rid = rid

    def ladder(self, gate, kill="/nonexistent/kill"):
        import contextlib
        import io
        out = io.StringIO()
        with mock.patch.object(copy_gate, "GATE", pathlib.Path(gate)), mock.patch.object(self.cli, "DSAR_KILL", kill), \
                mock.patch.object(copy_gate, "check", pending), contextlib.redirect_stdout(out):
            self.cli.dsar_ladder(self.run, NOW, 25, send_them=True)
        return out.getvalue()

    def test_with_no_gate_nothing_is_authored_and_the_older_ask_is_not_stood_down(self):
        said = self.ladder("/nonexistent/outbound_copy/gate.py")
        self.assertIn("held, the copy gate is not installed", said)
        self.assertEqual(self.s.messages(self.rid), [], "nothing authored, so nothing stands the older ask down")
        self.assertEqual(self.run.errors, [], "a host without the gate is a held ladder, not a failed tick")

    def test_with_the_gate_present_the_ladder_authors_and_holds_for_a_verdict(self):
        said = self.ladder(__file__)
        self.assertIn("1 message(s) owed: 1 held", said)
        self.assertEqual([m["state"] for m in self.s.messages(self.rid)], ["held"])

    def test_the_kill_file_wins_over_everything(self):
        said = self.ladder(__file__, kill=__file__)
        self.assertIn("disabled", said)
        self.assertEqual(self.s.messages(self.rid), [])


SCHEMA = [("users", "id", "bigint"), ("users", "email", "varchar(100)"), ("users", "fullname", "varchar"),
          ("users", "password", "varchar"), ("users", "misc", "json"),
          ("orders", "id", "bigint"), ("orders", "userid", "bigint"), ("orders", "total", "decimal(10,2)"),
          ("orders", "approvedby", "bigint"),
          ("teams", "id", "bigint"), ("teams", "email", "varchar"), ("teams", "name", "varchar")]
MANIFEST = {
    "v": 1, "row_ceiling": 3, "discovery_columns": ["userid", "user_id", "email"],
    "secret_like": "pass|token|secret",
    "withheld_reasons": {"credential": "a secret", "another_person": "someone else", "unreviewed": "not reviewed"},
    "ignored": {}, "information_notice": {"text": "the Art. 15(1) information, as approved"},
    "column_review": {"reviewed": True},
    "systems": [{"id": "core", "holds": "the account", "covered": True}],
    "sources": [{"table": "users", "keys": [{"column": "id", "by": "account_id"}], "withheld": {"password": "credential"}},
                {"table": "orders", "keys": [{"column": "userid", "by": "account_id"}],
                 "withheld": {"approvedby": "another_person"}},
                {"table": "teams", "keys": [{"column": "email", "by": "account_email"}]}],
    "_sha256": "m" * 64,
}


REBUILT = {"users": [["7", "ana@example.org", "Ana Rebuilt", '{"a":1}']],
           "orders": [["2", "7", "9.99"], ["1", "7", "5.00"]],
           "teams": [["4", "ana@example.org", "Ana's team"]]}


def replica(schema=None, tables=None, fail=()):
    """A fake of the read-only replica: answers the schema read and each source read, and records every query."""
    schema = SCHEMA if schema is None else schema
    tables = tables if tables is not None else {
        "users": [["7", "ana@example.org", "Ana Line\\nTwo", '{"a":1}']],
        "orders": [["2", "7", "9.99"], ["1", "7", "5.00"]],
        "teams": [["4", "ana@example.org", "Ana's team"]]}
    seen = []

    def read(sql):
        seen.append(sql)
        if "information_schema" in sql:
            return [list(x) for x in schema]
        table = sql.split("postgresql_core.public.")[1].split(" ")[0]
        if table in fail:
            raise sources.Unknown(f"trino failed on: {sql}")
        return [list(r) for r in tables.get(table, [])]
    read.seen = seen
    return read


class AccessCopy(unittest.TestCase):
    """The Art. 15 copy: every row keyed to ONE account, and an honest account of what it does not cover."""

    def test_the_copy_holds_the_accounts_rows_and_leaves_out_what_is_withheld(self):
        read = replica()
        doc = access.collect(MANIFEST, 7, read)
        self.assertTrue(doc["complete"], doc["incomplete"])
        by = {s["table"]: s for s in doc["sections"]}
        self.assertEqual(by["users"]["columns"], ["id", "email", "fullname", "misc"])
        self.assertEqual(by["users"]["withheld"], {"password": "credential"})
        self.assertEqual(by["users"]["rows"], [["7", "ana@example.org", "Ana Line\nTwo", '{"a":1}']],
                         "a value with a line break comes back whole")
        self.assertEqual(by["orders"]["withheld"], {"approvedby": "another_person"})
        self.assertEqual(len(by["orders"]["rows"]), 2)
        self.assertEqual(by["teams"]["rows"], [["4", "ana@example.org", "Ana's team"]])
        for sql in read.seen[1:]:
            self.assertNotIn("password", sql, "a withheld column is never read at all")
            self.assertNotIn("approvedby", sql)
            self.assertTrue("= 7" in sql or "'ana@example.org'" in sql, "every read is bound to this one account")
        self.assertIn("json_format(misc)", read.seen[1])

    def test_the_same_data_gives_the_same_bytes_and_hash(self):
        a = access.package(access.collect(MANIFEST, 7, replica()))
        tables = {"users": [["7", "ana@example.org", "Ana", "{}"]], "orders": [["1", "7", "5.00"], ["2", "7", "9.99"]]}
        b = access.package(access.collect(MANIFEST, 7, replica(tables=tables)))
        c = access.package(access.collect(MANIFEST, 7, replica(tables={**tables, "orders": tables["orders"][::-1]})))
        self.assertEqual(b, c, "row order from the database does not change the hash")
        self.assertNotEqual(a[1], b[1])
        self.assertEqual(json.loads(b[0])["kind"], access.KIND)

    def test_a_source_that_did_not_read_is_unknown_and_the_copy_is_incomplete(self):
        doc = access.collect(MANIFEST, 7, replica(fail=("orders",)))
        orders = next(s for s in doc["sections"] if s["table"] == "orders")
        self.assertEqual((orders["state"], orders["rows"]), (access.UNKNOWN, []))
        self.assertFalse(doc["complete"])
        self.assertTrue(any(x.startswith("orders:") for x in doc["incomplete"]))
        self.assertNotIn("ana@example.org", orders["reason"], "a reason never quotes the query's literals")
        self.assertNotIn("= 7", orders["reason"])

    def test_an_account_keyed_table_nobody_listed_makes_the_copy_incomplete(self):
        schema = SCHEMA + [("new_thing", "id", "bigint"), ("new_thing", "user_id", "bigint")]
        doc = access.collect(MANIFEST, 7, replica(schema=schema))
        self.assertFalse(doc["complete"])
        self.assertIn("new_thing: holds an account key and is not in the manifest", doc["incomplete"])

    def test_a_secret_looking_column_nobody_ruled_on_is_never_read(self):
        schema = SCHEMA + [("orders", "card_token", "varchar")]
        read = replica(schema=schema)
        doc = access.collect(MANIFEST, 7, read)
        orders = next(s for s in doc["sections"] if s["table"] == "orders")
        self.assertEqual(orders["withheld"]["card_token"], "unreviewed")
        self.assertFalse(any("card_token" in sql for sql in read.seen[1:]))
        self.assertFalse(doc["complete"])
        self.assertIn("orders.card_token: not reviewed for inclusion", doc["incomplete"])

    def test_more_rows_than_the_ceiling_is_not_a_silent_cut(self):
        rows = [[str(i), "7", "1.00"] for i in range(4)]
        doc = access.collect(MANIFEST, 7, replica(tables={"users": [["7", "a@b.org", "A", "{}"]], "orders": rows}))
        orders = next(s for s in doc["sections"] if s["table"] == "orders")
        self.assertEqual((orders["state"], orders["rows"]), (access.TOO_LARGE, []))
        self.assertFalse(doc["complete"])

    def test_an_uncovered_system_or_a_missing_information_text_makes_the_copy_incomplete(self):
        m = {**MANIFEST, "systems": MANIFEST["systems"] + [{"id": "intercom", "holds": "support", "covered": False}]}
        self.assertIn("intercom: not covered (support)", access.collect(m, 7, replica())["incomplete"])
        m = {**MANIFEST, "information_notice": {"text": ""}}
        doc = access.collect(m, 7, replica())
        self.assertEqual(doc["incomplete"], ["the Art. 15(1) information has no approved text"])
        for review in ({}, {"reviewed": False}, {"reviewed": "yes"}):
            doc = access.collect({**MANIFEST, "column_review": review}, 7, replica())
            self.assertEqual(doc["incomplete"],
                             ["the included columns have not been reviewed for other people's data (Art. 15(4))"])

    def test_no_account_row_or_two_is_unknown_never_an_empty_copy(self):
        for users in ([], [["7", "a@b.org", "A", "{}"], ["7", "c@d.org", "C", "{}"]]):
            doc = access.collect(MANIFEST, 7, replica(tables={"users": users}))
            self.assertEqual(doc["sections"][0]["state"], access.UNKNOWN)
            self.assertFalse(doc["complete"])

    def test_a_schema_that_cannot_be_read_builds_nothing(self):
        with self.assertRaises(ValueError):
            access.collect(MANIFEST, 7, replica(schema=[("orders", "id", "bigint")]))

    def test_the_summary_carries_counts_and_never_a_value(self):
        doc = access.collect(MANIFEST, 7, replica())
        raw, sha = access.package(doc)
        text = json.dumps(access.summary(doc, sha, len(raw)))
        for value in ("ana@example.org", "Ana", "9.99"):
            self.assertNotIn(value, text)
        self.assertEqual(json.loads(text)["rows"], 4)

    def test_the_shipped_manifest_loads_and_states_its_own_gaps(self):
        m = access.load_manifest()
        self.assertEqual(len(m["_sha256"]), 64)
        users = next(s for s in m["sources"] if s["table"] == "users")
        self.assertEqual({users["withheld"][c] for c in ("password", "twofactor")}, {"credential"})
        self.assertEqual(m["information_notice"]["text"], "",
                         "the Art. 15(1) text is a legal statement: it is recorded by a reviewed change, not written here")
        self.assertTrue(any(not x["covered"] for x in m["systems"]))
        self.assertIs(m["column_review"]["reviewed"], False, "the column list was written from names, and says so")
        self.assertIn("shall not adversely affect the rights and freedoms of others",
                      m["withheld_reasons"]["another_person"], "the ground for leaving a field out quotes the rule")

    def test_a_manifest_that_withholds_without_a_stated_reason_is_refused(self):
        bad = json.loads(json.dumps({k: v for k, v in MANIFEST.items() if k != "_sha256"}))
        bad["sources"][0]["withheld"] = {"password": "because"}
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "m.json"
            p.write_text(json.dumps(bad))
            with self.assertRaises(access.ManifestError):
                access.load_manifest(p)


class WideReplicaRead(unittest.TestCase):
    """Found on the live replica 2026-11-12: four of the first ten copies lost `user_action_log` to the CSV
    reader's default field limit. The copy reported it as unread (correct), but a copy that can never read a
    source can never be complete."""

    def setUp(self):
        import csv
        import subprocess
        from gdpr_pipeline import sources
        self.csv, self.sources, self.subprocess = csv, sources, subprocess
        self.limit = csv.field_size_limit()
        self.real = subprocess.run
        self.long = "x" * (self.limit + 10)

        class Done:
            returncode, stderr = 0, ""
            stdout = f'"7","{self.long}"\n'
        subprocess.run = lambda *a, **k: Done()

    def tearDown(self):
        self.subprocess.run = self.real
        self.csv.field_size_limit(self.limit)

    def test_a_field_wider_than_the_reader_takes_is_unknown_and_never_a_raw_error(self):
        with self.assertRaises(self.sources.Unknown) as ctx:
            self.sources.trino("SELECT 1")
        self.assertIn("wider than the reader takes", str(ctx.exception))

    def test_the_copy_reads_whole_values_and_leaves_the_readers_limit_as_it_found_it(self):
        self.assertEqual(self.sources.trino_wide("SELECT 1"), [["7", self.long]])
        self.assertEqual(self.csv.field_size_limit(), self.limit)

    def test_the_copy_is_built_through_the_wide_read(self):
        src = (ROOT / "scripts" / "gdpr_pipeline" / "run.py").read_text()
        self.assertIn("reader or sources.trino_wide", src)
        self.assertNotIn("reader or sources.trino,", src)


class AccessAnswer(unittest.TestCase):
    """Build, record and deliver, through Run: who the copy is for, and every reason it is held."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.store = Store(os.path.join(self.dir.name, "erasure.sqlite"))
        self.run = Run(self.store, log=lambda *_: None)
        rid, _ = self.store.upsert({
            "keys": ["intercom:900"], "channel": "intercom", "class": "privacy_access",
            "received_at": "2026-11-01T12:00:00Z", "requester_name": "Ana Example",
            "requester_email": "typed@elsewhere.example", "conversation_id": "900", "pages": []})
        self.row = self.store.get(rid)
        self.no = self.row["register_no"]
        self.conv = lambda _id: {"contact_role": "user", "external_id": "ext-7", "contact_email": "ana@example.org",
                                 "customer_text": "please send me my data"}
        self._resolve = sources.resolve_account
        sources.resolve_account = lambda ext, email, trusted: (7, "external_id (test)") if ext == "ext-7" else (None, "")
        self.addCleanup(lambda: setattr(sources, "resolve_account", self._resolve))
        self.sent = []
        self.email_now = "ana@example.org"      # what the account's sign-in address reads as at send time

    def read_email(self, acc):
        if self.email_now is None:
            raise sources.Unknown("replica down")
        return self.email_now

    def mailer(self, email, text, key, subject, attach):
        self.sent.append({"to": email, "text": text, "subject": subject, "attach": attach,
                          "bytes": pathlib.Path(attach).read_bytes()})
        return "msg-1"

    def build(self, manifest=MANIFEST, record=True, **kw):
        return self.run.access_build(self.no, record=record, conv_reader=self.conv, reader=replica(**kw),
                                     manifest=manifest)

    def deliver(self, checker=approve, now=None, dry_run=False):
        # The copy's age is measured from the store's own clock, so "now" is the real one unless a test moves it.
        now = now or datetime.now(timezone.utc)
        return self.run.access_deliver(self.no, now, dry_run=dry_run, conv_reader=self.conv, checker=checker,
                                       mailer=self.mailer, email_reader=self.read_email)

    def test_a_build_that_is_not_recorded_writes_nothing(self):
        out = self.build(record=False)
        self.assertEqual((out["state"], out["recorded"], out["rows"], out["complete"]), ("built", False, 4, True))
        self.assertEqual(self.store.access_answers(self.row["id"]), [])
        self.assertFalse(os.path.exists(os.path.join(self.dir.name, "access")))

    def test_a_recorded_copy_is_a_private_file_and_the_trail_holds_counts_only(self):
        out = self.build()
        (ans,) = self.store.access_answers(self.row["id"])
        self.assertEqual(ans["sha256"], out["sha256"])
        self.assertEqual(os.stat(ans["path"]).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(os.path.dirname(ans["path"])).st_mode & 0o777, 0o700)
        trail = json.dumps(self.run.dsar_trail(self.no)["access_answers"]) + json.dumps(
            [e for e in self.store.events(self.row["id"]) if e["kind"] == "access_built"])
        self.assertIn(out["sha256"], trail)
        self.assertNotIn("ana@example.org", trail)
        self.assertNotIn(ans["path"], json.dumps(self.run.dsar_trail(self.no)["access_answers"]))

    def test_no_copy_is_built_without_account_control_or_for_a_representative_or_another_class(self):
        self.conv = lambda _id: {"contact_role": "lead", "contact_email": "ana@example.org", "customer_text": "hi"}
        out = self.build()
        self.assertEqual(out["state"], "not_built")
        self.assertIn("account control is not shown", out["why"])
        self.conv = lambda _id: {"contact_role": "user", "external_id": "ext-7",
                                 "customer_text": "I am writing on behalf of my client as their attorney"}
        self.assertIn("authority document", self.build()["why"])
        self.store.update(self.row["id"], "test", **{"class": "privacy_erasure"})
        self.assertIn("not an access request", self.build()["why"])
        self.assertEqual(self.store.access_answers(self.row["id"]), [])

    def test_a_complete_fresh_approved_copy_goes_to_the_accounts_own_address_once_and_closes_the_request(self):
        built = self.build()
        self.assertEqual(self.deliver(dry_run=True)["state"], "would_send")
        self.assertEqual(self.sent, [])
        out = self.deliver()
        self.assertEqual(out["state"], "sent")
        (m,) = self.sent
        self.assertEqual(m["to"], "ana@example.org", "the sign-in address, never the address the request was typed from")
        self.assertEqual(hashlib.sha256(m["bytes"]).hexdigest(), built["sha256"])
        self.assertIn("1 November 2026", m["text"])
        row = self.store.get(self.row["id"])
        self.assertTrue(row["confirmed_at"], "the copy is the final response")
        self.assertEqual(dsar.state_of(row, self.store.sends(row["id"])), "closed")
        send_row = self.store.send_record(row["id"], "access")
        self.assertEqual((send_row["state"], send_row["approved_by"]), ("sent", "gate:" + out["verdict_id"]))
        self.assertIn(built["sha256"], send_row["detail"])
        self.assertEqual(self.deliver()["state"], "skipped")
        self.assertEqual(len(self.sent), 1)

    def test_an_incomplete_copy_is_never_sent(self):
        m = {**MANIFEST, "systems": MANIFEST["systems"] + [{"id": "intercom", "holds": "support", "covered": False}]}
        self.assertFalse(self.build(manifest=m)["complete"])
        out = self.deliver()
        self.assertEqual(out["state"], "held")
        self.assertIn("not complete", out["why"][0])
        self.assertEqual(self.sent, [])
        self.assertFalse(self.store.get(self.row["id"])["confirmed_at"])

    def test_no_verdict_no_send(self):
        self.build()
        out = self.deliver(checker=pending)
        self.assertEqual(out["state"], "held")
        self.assertIn("copy gate pending", out["why"][0])
        self.assertEqual(self.sent, [])
        self.assertIsNone(self.store.send_record(self.row["id"], "access"))

    def test_a_file_changed_after_it_was_recorded_is_never_sent(self):
        self.build()
        (ans,) = self.store.access_answers(self.row["id"])
        with open(ans["path"], "ab") as fh:
            fh.write(b" ")
        out = self.deliver()
        self.assertEqual(out["state"], "held")
        self.assertIn("the file is not the bytes that were recorded", out["why"])

    def test_a_copy_too_large_to_attach_is_held_with_the_reason_and_never_posted_to_fail(self):
        self.build()
        real = access.ATTACH_MAX_BYTES
        access.ATTACH_MAX_BYTES = 10
        try:
            out = self.deliver()
        finally:
            access.ATTACH_MAX_BYTES = real
        self.assertEqual(out["state"], "held")
        self.assertTrue(any("more than a mail attachment takes" in w for w in out["why"]), out)
        self.assertEqual(self.sent, [])
        self.assertIsNone(self.store.send_record(self.row["id"], "access"))
        self.assertLess(access.ATTACH_MAX_BYTES * 4 / 3, 25 * 1024 * 1024)

    OLD = "2026-11-10T09:00:00Z"

    def age_the_copy(self):
        self.store.db.execute("UPDATE access_answers SET produced_at=?", (self.OLD,))
        self.store.db.commit()

    def test_a_stale_copy_is_rebuilt_before_it_is_sent_and_the_old_bytes_never_go(self):
        first = self.build()
        self.age_the_copy()
        dry = self.deliver(dry_run=True)
        self.assertTrue(any("rebuild it first" in w for w in dry["why"]), dry)
        self.assertEqual(self.sent, [], "a dry run rebuilds nothing and sends nothing")
        with mock.patch.object(access, "load_manifest", lambda *a, **k: MANIFEST), \
                mock.patch.object(sources, "trino_wide", replica(tables=REBUILT)):
            out = self.deliver()
        self.assertEqual(out["state"], "sent")
        (m,) = self.sent
        sent_sha = hashlib.sha256(m["bytes"]).hexdigest()
        self.assertEqual(sent_sha, out["sha256"])
        self.assertNotEqual(sent_sha, first["sha256"], "the copy sent is the rebuilt one, not the stale bytes")
        self.assertEqual(self.store.access_answers(self.row["id"])[-1]["sha256"], sent_sha)
        self.assertLessEqual(len(self.store.access_answers(self.row["id"])), 2)

    def test_a_requester_who_lost_the_account_is_held(self):
        self.build()
        sources.resolve_account = lambda ext, email, trusted: (8, "external_id (test)")
        out = self.deliver()
        self.assertTrue(any("does not control this account now" in w for w in out["why"]), out)
        self.assertEqual(self.sent, [])

    def cli(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gdpr_cli_access", ROOT / "scripts" / "gdpr-pipeline.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        return cli

    def tick(self, now, manifest=MANIFEST, tables=None, loader=None, kill="/nonexistent/gdpr-dsar-ladder.disabled"):
        """`gdpr-pipeline.py tick`'s access pass, on the fake replica and the approved gate."""
        import contextlib
        import io
        out = io.StringIO()
        read = replica(**{"tables": tables}) if tables else replica()
        cli = self.cli()
        with mock.patch.object(access, "load_manifest", loader or (lambda *a, **k: manifest)), \
                mock.patch.object(cli, "DSAR_KILL", kill), \
                mock.patch.object(sources, "trino_wide", read), \
                mock.patch.object(sources, "conversation", self.conv), \
                mock.patch.object(sources, "account_email", self.read_email), \
                mock.patch.object(copy_gate, "check", approve), \
                mock.patch.object(send, "_mail_send_attachment", self.mailer), \
                contextlib.redirect_stdout(out):
            cli.access_owed_send(self.run, now)
        return out.getvalue()

    def ladder_ask(self):
        rid, _ = self.store.upsert({"keys": ["intercom:902"], "channel": "intercom", "class": "privacy_erasure",
                                    "received_at": "2026-11-02T00:00:00Z", "requester_email": "ana@example.org",
                                    "conversation_id": "902", "pages": []})
        row = self.store.get(rid)
        return {"row": rid, "register_no": row["register_no"], "channel": "intercom", "to": "902",
                "kind": "ASK_LINK", "text": copy.ASK["ASK_LINK"], "class": "privacy_erasure"}

    def test_a_day_held_answer_is_owed_on_the_row_and_the_tick_rebuilds_and_delivers_it_next_day(self):
        first = self.build()
        other, _ = self.store.upsert({"keys": ["intercom:901"], "channel": "intercom", "class": "privacy_erasure",
                                      "received_at": "2026-11-02T00:00:00Z", "requester_email": "ana@example.org",
                                      "conversation_id": "901", "pages": []})
        self.store.claim_send(other, "ack", "intercom", "901", "0" * 64, "gate:x", "sending")
        self.store.finish_send(other, "ack", "sent", ref="api-log posted")
        held = self.deliver()
        self.assertEqual((held["state"], self.sent), ("held", []))
        self.assertTrue(self.store.get(self.row["id"])["access_owed_at"],
                        "the debt is recorded on the row the tick reads, not only in a log line")
        # the next UTC day: the letter is yesterday's and the recorded copy is past its freshness window
        self.store.db.execute("UPDATE erasure_sends SET at=?", (self.OLD,))
        self.store.db.commit()
        self.age_the_copy()
        said = self.tick(datetime.now(timezone.utc), tables=REBUILT)
        self.assertIn("access owed: 1", said)
        self.assertEqual(len(self.sent), 1)
        sent_sha = hashlib.sha256(self.sent[0]["bytes"]).hexdigest()
        self.assertNotEqual(sent_sha, first["sha256"], "the stale copy is never the one sent")
        self.assertEqual(self.store.access_answers(self.row["id"])[-1]["sha256"], sent_sha,
                         "the tick rebuilt the copy before sending it, with no operator command")
        self.assertFalse(self.store.get(self.row["id"])["access_owed_at"], "the debt is cleared once it is delivered")

    def test_the_operator_kill_switch_stops_the_owed_answer_and_it_goes_on_the_first_tick_after(self):
        """Ruling 2026-11-14: the owed-access send honours the operator kill switch, the same as every other send.
        With the file present nothing is rebuilt, claimed or sent and the debt stays on the row; removed, the same
        tick pass delivers it."""
        self.build()
        other, _ = self.store.upsert({"keys": ["intercom:901"], "channel": "intercom", "class": "privacy_erasure",
                                      "received_at": "2026-11-02T00:00:00Z", "requester_email": "ana@example.org",
                                      "conversation_id": "901", "pages": []})
        self.store.claim_send(other, "ack", "intercom", "901", "0" * 64, "gate:x", "sending")
        self.store.finish_send(other, "ack", "sent", ref="api-log posted")
        self.assertEqual(self.deliver()["state"], "held")
        self.store.db.execute("UPDATE erasure_sends SET at=?", (self.OLD,))
        self.store.db.commit()
        self.age_the_copy()
        before = (self.store.get(self.row["id"]), len(self.store.access_answers(self.row["id"])),
                  self.store.db.execute("SELECT COUNT(*) FROM erasure_sends").fetchone()[0])
        with tempfile.TemporaryDirectory() as d:
            kill = os.path.join(d, "gdpr-dsar-ladder.disabled")
            open(kill, "w").close()
            said = self.tick(datetime.now(timezone.utc), tables=REBUILT, kill=kill)
            self.assertEqual(said.strip(), f"access owed: disabled ({kill})")
            self.assertEqual(self.sent, [])
            after = (self.store.get(self.row["id"]), len(self.store.access_answers(self.row["id"])),
                     self.store.db.execute("SELECT COUNT(*) FROM erasure_sends").fetchone()[0])
            self.assertEqual(after, before, "a stopped pass rebuilds nothing, claims nothing and keeps the debt")
            os.unlink(kill)
            said = self.tick(datetime.now(timezone.utc), tables=REBUILT, kill=kill)
        self.assertIn("access owed: 1", said)
        self.assertEqual(len(self.sent), 1)
        self.assertFalse(self.store.get(self.row["id"])["access_owed_at"])

    def test_a_second_held_tick_neither_bumps_the_revision_nor_adds_an_event(self):
        self.build()
        other, _ = self.store.upsert({"keys": ["intercom:901"], "channel": "intercom", "class": "privacy_erasure",
                                      "received_at": "2026-11-02T00:00:00Z", "requester_email": "ana@example.org",
                                      "conversation_id": "901", "pages": []})
        self.store.claim_send(other, "ack", "intercom", "901", "0" * 64, "gate:x", "sending")
        self.store.finish_send(other, "ack", "sent", ref="api-log posted")
        self.deliver()
        self.store.update(self.row["id"], "access_owed", access_owed_at=self.OLD)
        first = self.store.get(self.row["id"])
        events = len(self.store.events(self.row["id"]))

        self.assertEqual(self.deliver()["state"], "held")
        again = self.store.get(self.row["id"])
        self.assertEqual(again["access_owed_at"], self.OLD,
                         "the mark keeps the day the answer first became owed")
        self.assertEqual(again["rev"], first["rev"], "a repeated hold is not a new change to the row")
        self.assertEqual(len(self.store.events(self.row["id"])), events)

    def owed_row(self, n=903, email="bob@example.org"):
        rid, _ = self.store.upsert({"keys": [f"intercom:{n}"], "channel": "intercom", "class": "privacy_access",
                                    "received_at": "2026-11-02T00:00:00Z", "requester_email": email,
                                    "conversation_id": str(n), "pages": []})
        self.store.update(rid, "access_owed", access_owed_at=self.OLD)
        return self.store.get(rid)

    def test_a_row_that_fails_to_rebuild_is_reported_and_still_owed_and_the_ladder_still_sends(self):
        """A read that raises inside the owed pass is contained on that row: the failure is recorded, the debt stays
        on the row for the next tick, nothing is claimed or sent for it, and the same tick's ladder still sends
        another requester's letter."""
        self.build()
        self.store.update(self.row["id"], "access_owed", access_owed_at=self.OLD)
        self.age_the_copy()
        ask = self.ladder_ask()
        self.store.update(ask["row"], "decide", gates={"v": 1, "need": "link"})

        def loader(*_a, **_k):
            raise access.ManifestError("the replica could not be read")
        said = self.tick(datetime.now(timezone.utc), loader=loader)
        self.assertIn(f"access #{self.no} -> failed", said)
        self.assertIn("still owed", said)
        self.assertTrue(any(f"#{self.no}" in e for e in self.run.errors), self.run.errors)
        self.assertTrue(self.store.get(self.row["id"])["access_owed_at"], "the debt stays for the next tick")
        self.assertEqual(self.sent, [], "a row that failed claims nothing")
        self.assertIsNone(self.store.send_record(self.row["id"], dsar.KIND_ACCESS))
        with mock.patch.object(copy_gate, "GATE", pathlib.Path(__file__)), \
                mock.patch.object(copy_gate, "check", approve), \
                mock.patch.object(send, "_intercom_send",
                                  lambda c, t, a, dry_run=False, key="": "api-log posted"):
            self.cli().dsar_ladder(self.run, datetime.now(timezone.utc), 25, send_them=True)
        self.assertEqual((self.store.send_record(ask["row"], "ack") or {}).get("state"), "sent",
                         "the tick goes on to the ladder")

    def test_two_owed_rows_are_each_contained_so_one_failure_does_not_strand_the_other(self):
        first = self.build()
        second = self.owed_row()
        self.store.update(self.row["id"], "access_owed", access_owed_at=self.OLD)
        self.conv = lambda cid: {"contact_role": "user", "external_id": f"ext-{cid}",
                                 "contact_email": "ana@example.org", "customer_text": "please send me my data"}
        sources.resolve_account = lambda ext, email, trusted: (int(str(ext).split("-")[1]), "external_id (test)")
        built = self.run.access_build(second["register_no"], record=True, conv_reader=self.conv, reader=replica(),
                                     manifest=MANIFEST)
        self.assertEqual(built["state"], "built")
        self.age_the_copy()
        calls = {"n": 0}

        def loader(*_a, **_k):
            calls["n"] += 1
            if calls["n"] == 1:
                raise access.ManifestError("the replica could not be read")
            return MANIFEST
        said = self.tick(datetime.now(timezone.utc), loader=loader)
        self.assertIn(f"access #{self.no} -> failed", said)
        self.assertIn("access owed: 2", said)
        self.assertEqual(len(self.sent), 1, "the second owed answer is still delivered")
        self.assertTrue(self.store.get(self.row["id"])["access_owed_at"])
        self.assertFalse(self.store.get(second["id"])["access_owed_at"])
        self.assertNotEqual(hashlib.sha256(self.sent[0]["bytes"]).hexdigest(), first["sha256"])

    def test_an_owed_answer_whose_rebuild_is_incomplete_sends_nothing(self):
        self.build()
        self.store.update(self.row["id"], "access_owed", access_owed_at=self.OLD)
        self.age_the_copy()
        m = {**MANIFEST, "systems": MANIFEST["systems"] + [{"id": "intercom", "holds": "support", "covered": False}]}
        said = self.tick(datetime.now(timezone.utc), manifest=m)
        self.assertIn("access owed: 1", said)
        self.assertEqual(self.sent, [], "an incomplete rebuilt copy is never sent")
        self.assertTrue(self.store.get(self.row["id"])["access_owed_at"], "it is still owed, for the next tick")
        self.assertIsNone(self.store.send_record(self.row["id"], dsar.KIND_ACCESS))

    def test_a_statutory_answer_takes_the_day_from_an_ordinary_ladder_letter(self):
        self.build()
        self.store.update(self.row["id"], "access_owed", access_owed_at=self.OLD)
        item = self.ladder_ask()
        with mock.patch.object(send, "_intercom_send", lambda conv, text, who, dry_run, key="": "api-log posted"):
            self.tick(datetime.now(timezone.utc))
            self.assertEqual(len(self.sent), 1, "the access answer goes first, in the same tick")
            held = send.deliver(self.run, item, "ask", "U1")
            self.assertEqual((held["state"], len(self.sent)), ("held", 1), "the letter is the one held")
            self.assertIn("one message per person per UTC day", held["why"])
            self.assertIsNone(self.store.send_record(item["row"], "ask"), "nothing was refused: the slot stays free")
            self.store.db.execute("UPDATE erasure_sends SET at='2026-11-10T09:00:00Z'")
            self.store.db.commit()
            again = send.deliver(self.run, item, "ask", "U1")
        self.assertEqual(again["state"], "sent", "the held letter is offered again on the next day")

    def test_a_copy_is_never_sent_to_an_address_the_account_no_longer_has(self):
        """QA review of #1908 (critical): the copy is up to 24 h old and carried its own recipient. An account whose
        sign-in address changed after the build is still the same account by id, so the identity check passed and
        the whole copy went to the old address."""
        self.build()
        for now_reads, expect in (("new@example.org", "not the one this copy was built for"),
                                  ("Ana@example.org", "not the one this copy was built for"),
                                  ("", "not the one this copy was built for"),
                                  (None, "could not be read now")):
            self.email_now = now_reads
            for dry in (True, False):
                out = self.deliver(dry_run=dry)
                self.assertEqual(out["state"], "held", (now_reads, dry))
                self.assertTrue(any(expect in w for w in out["why"]), out)
        self.assertEqual(self.sent, [])
        self.assertIsNone(self.store.send_record(self.row["id"], "access"))
        self.email_now = "ana@example.org"
        self.assertEqual(self.deliver()["state"], "sent")
        self.assertEqual([m["to"] for m in self.sent], ["ana@example.org"])

    def test_the_address_is_read_from_the_account_and_from_nowhere_else(self):
        from gdpr_pipeline import sources as real
        seen = []

        def trino(sql):
            seen.append(sql)
            return self.rows
        with mock.patch.object(real, "trino", trino):
            self.rows = [["  ana@example.org "]]
            self.assertEqual(real.account_email(7), "ana@example.org")
            self.assertIn("WHERE id = 7", seen[-1])
            for rows in ([], [["a@b.org"], ["c@d.org"]], [["a", "b"]]):
                self.rows = rows
                with self.assertRaises(real.Unknown):
                    real.account_email(7)

    def test_an_ambiguous_send_is_unknown_and_never_retried(self):
        self.build()

        def boom(*_a):
            raise send.Ambiguous("timed out")
        out = self.run.access_deliver(self.no, datetime.now(timezone.utc), conv_reader=self.conv, checker=approve,
                                      mailer=boom, email_reader=self.read_email)
        self.assertEqual(out["state"], "unknown")
        self.assertEqual(self.deliver()["state"], "skipped")
        self.assertFalse(self.store.get(self.row["id"])["confirmed_at"])

    def test_the_answer_waits_its_turn_behind_a_ladder_letter_to_the_same_person(self):
        self.build()
        other, _ = self.store.upsert({"keys": ["intercom:901"], "channel": "intercom", "class": "privacy_erasure",
                                      "received_at": "2026-11-02T00:00:00Z", "requester_email": "ana@example.org",
                                      "conversation_id": "901", "pages": []})
        self.store.claim_send(other, "ack", "intercom", "901", "0" * 64, "gate:x", "sending")
        self.store.finish_send(other, "ack", "sent", ref="api-log posted")
        held = self.deliver()
        self.assertEqual((held["state"], self.sent), ("held", []), "one message to that person today")
        self.assertIn("one message per person per UTC day", held["why"][0])
        self.assertIsNone(self.store.send_record(self.row["id"], dsar.KIND_ACCESS),
                          "nothing was refused: the answer slot stays free")
        # the next day the ledger holds nothing for that person today, so the answer goes
        self.store.db.execute("UPDATE erasure_sends SET at='2026-11-10T09:00:00Z'")
        self.assertEqual(self.deliver()["state"], "sent")
        self.assertEqual(len(self.sent), 1)
        self.assertTrue(self.store.send_record(self.row["id"], dsar.KIND_ACCESS) is not None)

    def test_the_answer_is_held_when_another_worker_claimed_the_person_after_the_early_read(self):
        self.build()
        other, _ = self.store.upsert({"keys": ["intercom:901"], "channel": "intercom", "class": "privacy_erasure",
                                      "received_at": "2026-11-02T00:00:00Z", "requester_email": "ana@example.org",
                                      "conversation_id": "901", "pages": []})
        real, seen = self.store.person_contacted_on, []

        def read(row, day):
            got = real(row, day)
            if not seen:        # the other worker's claim lands after this worker's early read
                self.store.claim_send(other, "ack", "intercom", "901", "0" * 64, "gate:other", "sending")
            seen.append(got)
            return got
        with mock.patch.object(self.store, "person_contacted_on", read):
            held = self.deliver()
        self.assertEqual((seen[0], held["state"], self.sent), (None, "held", []))
        self.assertIn("one message per person per UTC day", held["why"][0])
        self.assertIsNone(self.store.send_record(self.row["id"], dsar.KIND_ACCESS), "the answer slot stays free")


class Rubric(unittest.TestCase):
    """The gate picks the rubric from the campaign by its own table; this lane ships the file it looks for."""

    def test_the_gdpr_rubric_is_where_the_gate_looks_for_it(self):
        self.assertEqual(copy_gate.RUBRIC_FAMILY, "gdpr")
        path = ROOT / "policies" / f"outbound-copy-rubric-{copy_gate.RUBRIC_FAMILY}.md"
        text = path.read_text(encoding="utf-8")
        for campaign in copy_gate.CAMPAIGN.values():
            self.assertIn(f"`{campaign}`", text, f"the rubric does not say what a {campaign} message must do")
        self.assertEqual(set(copy_gate.CAMPAIGN), set(dsar.GATED_KINDS))

    def test_the_rubric_forbids_identity_documents_and_requires_the_deadline(self):
        text = (ROOT / "policies" / "outbound-copy-rubric-gdpr.md").read_text(encoding="utf-8").lower()
        self.assertIn("must not ask for a passport", text)
        self.assertIn("an acknowledgement must state the date by which we will answer", text)
        self.assertIn("if you are unsure, do not approve", text)

    def test_the_rubric_allows_the_ownership_ask_the_copy_makes(self):
        """A reviewer following rule 2 as it stood refuses a letter that asks for a link to an artist page: the rule
        listed everything a message may ask for, and that was not on it."""
        text = " ".join((ROOT / "policies" / "outbound-copy-rubric-gdpr.md").read_text(encoding="utf-8").split())
        self.assertIn("a link to their own artist page on Spotify or Apple Music or to an official social account "
                      "that matches the profile", text)
        self.assertIn("a document from their label or management that names them", text)
        self.assertIn("never an identity document", text)


    def test_the_rubric_allows_the_new_thread_lead_and_subject_that_the_code_sends(self):
        """Rule 8 bars an email address in the text. The one opening line and subject a new-thread letter carries
        name our own mailbox, so the rubric says so in the words `copy.py` produces: a reviewer following a rubric
        that is silent on them refuses the only letter 42 requests could receive."""
        from gdpr_pipeline import copy as letter_copy
        text = " ".join((ROOT / "policies" / "outbound-copy-rubric-gdpr.md").read_text(encoding="utf-8").split())
        self.assertIn(letter_copy.new_thread_subject("privacy_erasure"), text)
        lead = letter_copy.new_thread_lead("notices@muso.ai", "2026-11-11T00:00:00Z", "your deletion request")
        self.assertIn(lead.replace("11 November 2026", "<date>"), text)
        self.assertIn("legal@muso.ai", text)
        for ruling in (letter_copy.NEW_THREAD_LEAD_RULING, letter_copy.NEW_THREAD_SUBJECT_RULING):
            self.assertIn(ruling, text)
        self.assertEqual(letter_copy.NEW_THREAD_SUBJECT_APPROVED_CLASSES, ("privacy_erasure",))


class ClockCheck(unittest.TestCase):
    """scripts/gdpr-dsar-clock-check.sh: one line wakes firstmate, silence means nothing is inside the window."""

    SCRIPT = ROOT / "scripts" / "gdpr-dsar-clock-check.sh"
    LINE = ("GDPR clock: 1 statutory request(s) past their date, 1 due within 7 d, of 3 open. "
            "Oldest first: #468 (1012 d past), #141 (due in 0 d)")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = pathlib.Path(self.tmp.name)
        (self.dir / "bin").mkdir()
        ssh = self.dir / "bin" / "ssh"
        # ONE call: the stub records its last argument (the remote command) and answers with the rc it is given
        ssh.write_text('#!/bin/sh\nfor a; do last=$a; done\nprintf "%s\\n" "$last" >> "$FAKE_CALLS"\n'
                       'cat "$FAKE_OUT" 2>/dev/null\nexit "$(cat "$FAKE_RC")"\n')
        ssh.chmod(0o755)

    def check(self, out: str, rc: int = 0) -> str:
        (self.dir / "out").write_text(out)
        (self.dir / "rc").write_text(str(rc))
        env = {**os.environ, "PATH": f"{self.dir / 'bin'}:{os.environ['PATH']}",
               "FAKE_OUT": str(self.dir / "out"), "FAKE_RC": str(self.dir / "rc"),
               "FAKE_CALLS": str(self.dir / "calls"),
               "GDPR_CLOCK_STATE": str(self.dir / "state"), "GDPR_CLOCK_HOST": "root@node.invalid"}
        p = subprocess.run(["bash", str(self.SCRIPT)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def test_an_empty_window_is_silence(self):
        self.assertEqual(self.check(""), "")

    def test_a_request_inside_the_window_is_one_line_naming_it_and_is_not_repeated_within_the_day(self):
        self.assertEqual(self.check(self.LINE + "\n"), self.LINE)
        self.assertEqual(self.check(self.LINE + "\n"), "")
        # only the day count moved (each request's count rolls over at its own time of day): still the same alarm
        self.assertEqual(self.check(self.LINE.replace("1012 d past", "1013 d past") + "\n"), "")

    def test_a_changed_set_pages_again_and_an_emptied_window_re_arms_the_alarm(self):
        self.check(self.LINE + "\n")
        grown = self.LINE.replace("#141 (due in 0 d)", "#141 (due in 0 d), #142 (due in 6 d)")
        self.assertEqual(self.check(grown + "\n"), grown)
        self.assertEqual(self.check(""), "")
        self.assertEqual(self.check(grown + "\n"), grown)

    def test_a_clock_that_cannot_be_read_is_a_line_not_silence(self):
        out = self.check("", rc=255)
        self.assertIn("could not be read", out)
        self.assertIn("rc 255", out)
        self.assertEqual(self.check("", rc=255), "", "the same failure is not repeated within the day")
        self.assertEqual(self.check(self.LINE + "\n"), self.LINE, "and a recovered clock pages what it found")

    def test_a_host_the_clock_is_not_deployed_on_says_so_and_is_not_an_unread_clock(self):
        """The check is registered before the deploy. The remote command tests for the clock's file first and answers
        97 when it is not there: a different line, because firstmate does a different thing about it."""
        out = self.check("", rc=97)
        self.assertIn("not deployed", out)
        self.assertNotIn("could not be read", out)
        self.assertEqual(self.check("", rc=97), "", "once a day")
        # deployed and the command failed, or the host could not be asked at all: the unread case
        (self.dir / "state" / "last").unlink()
        self.assertIn("could not be read", self.check("", rc=2))
        (self.dir / "state" / "last").unlink()
        self.assertIn("could not be read", self.check("", rc=255))

    def test_it_is_one_round_trip_inside_the_watchers_limit(self):
        """firstmate's watcher gives a check 30 s and reads a killed check as silence. Two ssh calls with a 15 s
        connect timeout each could be killed mid-way on a slow host, and a killed alarm says nothing."""
        self.check(self.LINE + "\n")
        calls = (self.dir / "calls").read_text().splitlines()
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("test -f /opt/hydra/scripts/gdpr_pipeline/dsar.py || exit 97; ", calls[0])
        own = hashlib.sha256(self.SCRIPT.read_bytes()).hexdigest()
        self.assertTrue(calls[0].endswith(
            f"gdpr-pipeline.py dsar clock --line --read-by firstmate --reader-sha {own}"), calls[0])
        text = self.SCRIPT.read_text()
        self.assertIn("ConnectTimeout=8", text)
        self.assertEqual(text.count("ssh -o"), 1)

    def test_a_request_nobody_has_written_to_is_a_line_and_a_new_one_pages_again(self):
        quiet = ("GDPR clock: 0 statutory request(s) past their date, 0 due within 7 d, of 2 open. "
                 "Oldest first: none; no first message after 48 h: #501")
        self.assertEqual(self.check(quiet + "\n"), quiet)
        self.assertEqual(self.check(quiet + "\n"), "")
        self.assertEqual(self.check(quiet + ", #502\n"), quiet + ", #502")

    def test_the_check_tells_the_host_it_read_the_clock_and_with_which_bytes(self):
        text = self.SCRIPT.read_text()
        self.assertIn("dsar clock --line --read-by firstmate --reader-sha", text)
        # the watcher runs a private COPY of the registered check: the identity is the bytes run, whatever the path
        copy_path = self.dir / ".fm-custom-check.abc123"
        copy_path.write_bytes(self.SCRIPT.read_bytes())
        (self.dir / "out").write_text("")
        (self.dir / "rc").write_text("0")
        env = {**os.environ, "PATH": f"{self.dir / 'bin'}:{os.environ['PATH']}", "FAKE_OUT": str(self.dir / "out"),
               "FAKE_RC": str(self.dir / "rc"), "FAKE_CALLS": str(self.dir / "calls"),
               "GDPR_CLOCK_STATE": str(self.dir / "state"), "GDPR_CLOCK_HOST": "root@node.invalid"}
        subprocess.run(["bash", str(copy_path)], env=env, check=True, capture_output=True, timeout=30)
        sent = (self.dir / "calls").read_text().split()[-1]
        self.assertEqual(sent, hashlib.sha256(self.SCRIPT.read_bytes()).hexdigest())


class ClockRegistration(unittest.TestCase):
    """scripts/gdpr-dsar-clock-register.sh: the repository puts its own check into a firstmate home and can be asked
    whether a home has these bytes. The home here is a stand-in with the two tools a real one has."""

    SCRIPT = ROOT / "scripts" / "gdpr-dsar-clock-register.sh"
    CHECK = ROOT / "scripts" / "gdpr-dsar-clock-check.sh"
    ID = "a0-gdpr-dsar-clock"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name) / "fm"
        (self.home / "bin").mkdir(parents=True)
        (self.home / "state").mkdir()
        # what the home's own tools do, reduced to it: bind <id>.check.sh to its sha256, or remove both files
        (self.home / "bin" / "fm-check-register.sh").write_text(
            '#!/usr/bin/env bash\nset -eu\ns="$FM_HOME/state"\n[ -f "$s/$1.check.sh" ] || exit 1\n'
            '[ "$(stat -c %a "$s/$1.check.sh")" = 700 ] || exit 1\n'
            'printf "fm-custom-check-v1\\n%s\\n" "$(sha256sum "$s/$1.check.sh" | cut -d" " -f1)" > "$s/$1.check-trust"\n'
            'echo "registered: state/$1.check.sh"\n')
        (self.home / "bin" / "fm-check-unregister.sh").write_text(
            '#!/usr/bin/env bash\nset -eu\nrm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"\n')
        for f in (self.home / "bin").iterdir():
            f.chmod(0o755)

    def run_it(self, *args, home=None, env_home=True):
        env = {k: v for k, v in os.environ.items() if k != "FM_HOME"}
        if env_home:
            env["FM_HOME"] = str(home or self.home)
        return subprocess.run(["bash", str(self.SCRIPT), *args], env=env, capture_output=True, text=True, timeout=30)

    def sha(self):
        return hashlib.sha256(self.CHECK.read_bytes()).hexdigest()

    def test_it_installs_the_check_and_binds_it_to_its_bytes(self):
        p = self.run_it()
        self.assertEqual(p.returncode, 0, p.stderr)
        dest = self.home / "state" / f"{self.ID}.check.sh"
        self.assertEqual(dest.read_bytes(), self.CHECK.read_bytes())
        self.assertEqual(oct(dest.stat().st_mode & 0o777), "0o700")
        self.assertEqual((self.home / "state" / f"{self.ID}.check-trust").read_text().split(),
                         ["fm-custom-check-v1", self.sha()])
        self.assertIn(self.sha(), p.stdout)
        self.assertIn("--unregister", p.stdout, "it says how to take itself back")
        self.assertEqual(self.run_it().returncode, 0, "run again: the same state")
        self.assertEqual([f.name for f in (self.home / "state").iterdir() if f.name.startswith(".")], [],
                         "nothing half-written is left behind")

    def test_check_says_whether_a_home_has_these_bytes(self):
        p = self.run_it("--check")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not registered", p.stderr)
        self.run_it()
        self.assertEqual(self.run_it("--check").returncode, 0)
        # the home's copy is older than the check (the check changed after it was registered)
        dest = self.home / "state" / f"{self.ID}.check.sh"
        dest.write_bytes(self.CHECK.read_bytes() + b"# older\n")
        p = self.run_it("--check")
        self.assertEqual(p.returncode, 1)
        self.assertIn("stale", p.stderr)
        # the bytes are right and the trust record names others: the watcher would refuse to run it
        dest.write_bytes(self.CHECK.read_bytes())
        (self.home / "state" / f"{self.ID}.check-trust").write_text("fm-custom-check-v1\n" + "0" * 64 + "\n")
        p = self.run_it("--check")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not bound", p.stderr)
        self.assertEqual(self.run_it().returncode, 0, "and installing again repairs both")
        self.assertEqual(self.run_it("--check").returncode, 0)

    def test_the_id_it_registers_under_runs_first_and_the_earlier_id_is_retired(self):
        """The watcher runs a home's checks in name order and ends the sweep at the first with a line. Registered as
        `gdpr-dsar-clock`, 57th of 94, the check was not run once in two and a half hours (2026-11-12)."""
        text = self.SCRIPT.read_text()
        self.assertIn(f'ID="{self.ID}"', text)
        self.assertLess(self.ID, "a0-pipeline-alerts-relay", "ahead of the first check in the home that day")
        old = self.home / "state" / "gdpr-dsar-clock.check.sh"
        old.write_text("#!/bin/sh\n")
        (self.home / "state" / "gdpr-dsar-clock.check-trust").write_text("fm-custom-check-v1\nx\n")
        p = self.run_it()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("retired the earlier id: gdpr-dsar-clock", p.stdout)
        self.assertFalse(old.exists())
        self.assertFalse((self.home / "state" / "gdpr-dsar-clock.check-trust").exists())
        # --check refuses a home that still runs both: two checks, one of them the old bytes, is two lines a day
        old.write_text("#!/bin/sh\n")
        self.assertIn("earlier id", self.run_it("--check").stderr)

    def test_unregister_takes_it_back(self):
        self.run_it()
        self.assertEqual(self.run_it("--unregister").returncode, 0)
        self.assertEqual(list((self.home / "state").iterdir()), [])

    def test_it_guesses_no_home_and_refuses_one_that_is_not_a_firstmate_home(self):
        p = self.run_it(env_home=False)
        self.assertEqual(p.returncode, 1)
        self.assertIn("no firstmate home", p.stderr)
        p = self.run_it(home=self.tmp.name)
        self.assertEqual(p.returncode, 1)
        self.assertIn("state is not a directory", p.stderr)
        (self.home / "bin" / "fm-check-register.sh").unlink()
        p = self.run_it()
        self.assertEqual(p.returncode, 1)
        self.assertIn("not a firstmate home", p.stderr)
        self.assertEqual(list((self.home / "state").iterdir()), [], "refused before anything was written")
        self.assertEqual(self.run_it("--fm-home").returncode, 2)
        self.assertEqual(self.run_it("--nonsense").returncode, 2)

    def test_the_cli_line_is_what_the_check_carries(self):
        s = Store(":memory:")
        rid, _ = s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                           "received_at": "2026-10-14T00:00:00Z", "pages": []})
        line = dsar.clock_line(Run(s, log=lambda *_: None).dsar_clock(NOW))
        self.assertIn(f"#{s.get(rid)['register_no']} (due in", line)
        self.assertNotIn("<@", line)


class FirstReply(unittest.TestCase):
    """The first message is due 24 hours after a request arrives, and nothing may keep a request from being owed one.

    Measured on the live register 2026-11-13T02:10Z: 168 open statutory requests had no message after 48 h and one
    (#13) was closed with nothing sent. Three things in this repository kept them quiet, and each has a test here:
    a row decided before the identity chain existed waited up to 20 h to be decided again, a request whose identity
    reads failed got no chain at all, and a closed row is read by no pass. (The fourth, a reviewer host that skipped
    every statutory letter and reported a clean round, is pinned in scripts/tests/test_outbound_copy_gate.py.)"""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)
        self.posted = []

    def writer(self):
        return mock.patch.object(send, "_intercom_send",
                                 lambda c, t, a, dry_run=False, key="": self.posted.append((c, t, a)) or "api-log posted")

    def add(self, n=1, cls="privacy_erasure", received="2026-11-11T00:00:00Z"):
        """A request of its own: its own thread, requester and page (two that share them are one row)."""
        rid, how = self.s.upsert({"keys": [f"intercom:2154766503954{n:02d}"], "channel": "intercom", "class": cls,
                                  "received_at": received, "requester_name": "Laczkovszki Arpad",
                                  "requester_email": f"arpad{n}@example.com",
                                  "conversation_id": f"2154766503954{n:02d}",
                                  "pages": [{"id": f"{n:08d}-db2f-49bb-9acf-0d406bfb09ae", "entity": "profile"}]})
        self.assertEqual(how, "created")
        return rid

    def tick_decide(self, account=7, fail=False):
        """One `decide_all` as the hourly tick runs it (20-hour refresh), with the sources stubbed."""
        def resolve_account(ext, email, trusted):
            if fail:
                raise sources.Unknown("core replica: connection refused")
            return account, "external_id (professional id)"

        def page_facts(pages, hid, cl, half=None, items=False):
            return [identity.Page(p["id"], found=True, name="Laczkovszki Arpad", hidden=False,
                                  is_claimed=bool(cl.get(p["id"])), claim_user_ids=frozenset(cl.get(p["id"], ())),
                                  checked_claim_user_ids=frozenset(cl.get(p["id"], ())))
                    for p in pages]

        conv = {"contact_role": "user", "external_id": "ext-1", "customer_text": "please remove my page"}
        with mock.patch.object(sources, "resolve_account", resolve_account), \
                mock.patch.object(sources, "account_names", lambda ids: {i: ("Laczkovszki Arpad",) for i in ids}), \
                mock.patch.object(sources, "processed_claims", lambda ids: {i: {7} for i in ids}), \
                mock.patch.object(sources, "claim_proofs", lambda ids: {i: [_reviewed(7)] for i in ids}), \
                mock.patch.object(sources, "profile_sources", _linked), \
                mock.patch.object(sources, "page_facts", page_facts):
            self.run.decide_all(set(), conv_reader=lambda cid: conv, stale_hours=20,
                                prefix_resolver=lambda prefixes: {})

    def decided_before_the_chain(self, rid):
        """The row as the live register held 244 of them: decided an hour ago, unchanged since, no chain on it."""
        self.s.update(rid, "decide", identity_verdict="PASS_A", gates={},
                      decided_at=(REAL() - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.s.mark_decided(rid)

    # ---- nothing keeps a request outside the ladder
    def test_a_request_with_no_identity_chain_is_decided_on_the_next_tick_not_at_its_20_hour_refresh(self):
        erasure, takedown = self.add(1), self.add(2, cls="dmca_takedown")
        for rid in (erasure, takedown):
            self.decided_before_the_chain(rid)
        self.assertIsNone(dsar.owed(self.s.get(erasure), [], NOW), "no chain: the ladder owes it nothing")
        self.tick_decide()
        row = self.s.get(erasure)
        self.assertEqual((row["gates"]["v"], row["gates"]["need"]), (1, "none"))
        self.assertEqual(dsar.owed(row, [], NOW)["variant"], "ack_none")
        # the arm is for statutory classes only: every other fresh decision still waits for its refresh
        self.assertEqual([e["kind"] for e in self.s.events(takedown)].count("decide"), 1)
        # and it settles: a row that has its chain is not selected again an hour later
        before = len(self.s.events(erasure))
        self.tick_decide()
        self.assertEqual(len(self.s.events(erasure)), before)

    def test_a_request_whose_identity_reads_failed_is_still_owed_its_acknowledgement(self):
        rid = self.add(received="2026-11-12T09:00:00Z")
        self.tick_decide(fail=True)
        row = self.s.get(rid)
        self.assertTrue(self.run.errors, "the failed read still fails the run: it is not a decision")
        self.assertEqual((row["decided_at"], row["identity_verdict"]), ("", ""), "and nothing was decided")
        self.assertEqual((row["gates"]["v"], row["gates"]["need"], row["gates"]["account"]["pass"]),
                         (1, "unknown", False))
        want = dsar.owed(row, [], NOW)
        self.assertEqual((want["kind"], want["variant"]), ("ack", "ack_unknown"))
        # a second failed run writes nothing more, and the read that works replaces the placeholder
        events = len(self.s.events(rid))
        self.tick_decide(fail=True)
        self.assertEqual(len(self.s.events(rid)), events)
        self.tick_decide()
        self.assertEqual(self.s.get(rid)["gates"]["need"], "none")

    def test_a_failed_read_never_replaces_a_chain_a_real_read_wrote_and_touches_no_other_class(self):
        tied, takedown = self.add(1), self.add(2, cls="dmca_takedown")
        self.tick_decide()
        chain = self.s.get(tied)["gates"]
        self.assertEqual(chain["need"], "none")
        self.run.chain_unread(self.s.get(tied))
        self.assertEqual(self.s.get(tied)["gates"], chain)
        self.run.chain_unread(self.s.get(takedown))
        self.assertEqual(self.s.get(takedown)["gates"], {})

    # ---- the send is recorded against its row with the date it was due and the date it went
    def test_an_acknowledgement_inside_24_hours_records_when_it_was_due_and_when_it_went(self):
        received = (REAL() - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        rid = self.add(received=received)
        self.tick_decide()
        with self.writer(), mock.patch.object(copy_gate, "check", approve):
            out = self.run.dsar_send(REAL(), checker=approve)
        self.assertEqual([o["state"] for o in out], ["sent"])
        self.assertEqual(len(self.posted), 1)
        sent = [json.loads(e["detail"]) for e in self.s.events(rid) if e["kind"] == "dsar_sent"]
        self.assertEqual(len(sent), 1)
        d = sent[0]
        self.assertEqual((d["message"], d["variant"], d["slot"], d["first_message"]), ("ack", "ack_none", "ack", True))
        self.assertEqual(d["received_at"], received)
        self.assertEqual(dsar._parse(d["first_reply_due_at"]), dsar._parse(received) + timedelta(hours=24))
        self.assertEqual(dsar._parse(d["statutory_due_at"]), dsar.due(self.s.get(rid)))
        self.assertLess(abs((dsar._parse(d["sent_at"]) - REAL()).total_seconds()), 120)
        self.assertEqual(d["first_reply_late_hours"], 0.0)
        # read back from the register: the request is no longer one nobody has written to
        clock = self.run.dsar_clock(REAL() + timedelta(days=3))
        self.assertEqual((clock["first_reply_overdue"], clock["no_first_message"]), ([], []))
        # the trail carries it, and it holds dates only
        trail = self.run.dsar_trail(self.s.get(rid)["register_no"])
        self.assertIn("first_reply_due_at", next(e["detail"] for e in trail["events"] if e["kind"] == "dsar_sent"))
        self.assertNotIn("arpad", json.dumps(sent).lower())

    def test_a_first_message_that_went_late_says_how_late_and_a_later_message_is_not_a_first_one(self):
        row = {"id": 1, "class": "privacy_erasure", "status": "open", "received_at": "2026-10-01T00:00:00Z"}
        late = dsar.send_dates(row, [], utc(2026, 11, 13, 0, 0))
        self.assertEqual((late["first_message"], late["first_reply_due_at"], late["first_reply_late_hours"]),
                         (True, "2026-10-02T00:00:00Z", 42 * 24.0))
        self.assertEqual((late["statutory_due_at"], late["sent_at"]), ("2026-10-31T00:00:00Z", "2026-11-13T00:00:00Z"))
        asked = [{"kind": "ask", "state": "sent", "at": "2026-10-03T00:00:00Z"}]
        later = dsar.send_dates(row, asked, utc(2026, 11, 13, 0, 0))
        self.assertFalse(later["first_message"])
        self.assertNotIn("first_reply_due_at", later)
        # a send that MAY be out is a first contact too: the next message is never counted as the first
        self.assertFalse(dsar.send_dates(row, [{"kind": "ack", "state": "unknown", "at": ""}],
                                         utc(2026, 11, 13, 0, 0))["first_message"])

    def test_the_clock_measures_the_24_hour_target_and_keeps_the_48_hour_list_it_pages_on(self):
        mk = lambda i, hours, **kw: {"id": i, "register_no": i, "class": "privacy_erasure", "status": "open",  # noqa: E731
                                     "received_at": dsar._iso(NOW - timedelta(hours=hours)),
                                     "gates": {"v": 1, "need": "none"}, **kw}
        rows = [mk(1, 60), mk(2, 30), mk(3, 10), mk(4, 60, ack_sent_at=dsar._iso(NOW - timedelta(hours=50)))]
        clock = dsar.clock_rows(rows, lambda _: [], NOW)
        self.assertEqual((clock["first_reply_hours"], clock["first_reply_overdue"]), (24, [1, 2]))
        self.assertEqual((clock["no_first_message_hours"], clock["no_first_message"]), (48, [1]))
        self.assertEqual(dsar.first_reply_due(rows[2]), NOW + timedelta(hours=14))
        # a ledger row counts like a stamp: the 24 live requests whose ask is only in the ledger are not "quiet"
        ledger = dsar.clock_rows(rows, lambda rid: [{"kind": "ask", "state": "sent", "at": "2026-11-11T00:00:00Z"}]
                                 if rid == 2 else [], NOW)
        self.assertEqual(ledger["first_reply_overdue"], [1])

    # ---- a closed request nobody answered
    def test_a_statutory_request_closed_with_no_final_response_is_reopened_and_then_acknowledged(self):
        unanswered = self.add(1, received="2026-10-20T19:41:00Z")
        confirmed = self.add(2, received="2026-10-20T00:00:00Z")
        ledgered = self.add(3, cls="privacy_access", received="2026-10-20T00:00:00Z")
        takedown = self.add(4, cls="dmca_takedown", received="2026-10-20T00:00:00Z")
        dup = self.add(5, received="2026-10-20T00:00:00Z")
        self.s.update(unanswered, "closed", status="closed", note="closed on the markdown register")
        self.s.update(confirmed, "confirmed", confirmed_at="2026-10-23T00:00:00Z", status="closed")
        self.s.claim_send(ledgered, "access", "intercom", "c", "ab" * 32, "gate:v-1", state="sending")
        self.s.finish_send(ledgered, "access", "sent", ref="r")
        self.s.update(ledgered, "closed", status="closed")
        self.s.update(takedown, "closed", status="closed")
        self.s.update(dup, "merged", status="duplicate")
        no = self.s.get(unanswered)["register_no"]
        now = utc(2026, 11, 13, 2, 0)
        self.assertEqual(self.run.dsar_clock(now)["closed_without_response"], [no])
        self.assertIsNone(dsar.owed({**self.s.get(unanswered), "gates": {"v": 1, "need": "none"}}, [], now),
                          "closed: no pass reads it, which is why naming it on the clock sent nobody anything")

        self.assertEqual(self.run.reopen_unanswered(), [no])
        self.assertEqual({rid: self.s.get(rid)["status"] for rid in (unanswered, confirmed, ledgered, takedown, dup)},
                         {unanswered: "open", confirmed: "closed", ledgered: "closed", takedown: "closed",
                          dup: "duplicate"})
        reopened = [json.loads(e["detail"]) for e in self.s.events(unanswered) if e["kind"] == "reopened"]
        self.assertEqual(len(reopened), 1)
        self.assertIn("no final response", reopened[0]["note"])
        self.assertEqual(self.run.reopen_unanswered(), [], "once: an open row is not reopened again")

        self.tick_decide()
        clock = self.run.dsar_clock(now)
        self.assertEqual(clock["closed_without_response"], [])
        self.assertIn(no, clock["no_first_message"], "and it is counted with the others until its message goes")
        want = dsar.owed(self.s.get(unanswered), [], now)
        self.assertEqual((want["kind"], want["facts"]["due"]), ("ack", "19 November 2026"))

    def test_the_markdown_register_cannot_close_a_statutory_request_nobody_answered(self):
        md = ("| # | received | Intercom | CU | who | request | ack | promised | status |\n"
              "|---|---|---|---|---|---|---|---|---|\n"
              "| 13 | 20 Oct 19:41Z | 215476481954575 | 869fkctdp | Maxime | URGENT GDPR erasure | acked | 19 Nov | open |\n"
              "| 16 | 26 Aug | 215476481954576 | - | x | GDPR erasure | profile f8b294d0 | 26 Sep | completed |\n"
              "- 10-21 21:0xZ #13: firstmate ruled the deletion STANDS. COMPLETED 21 Oct 2026.\n"
              "- 10-23 08:4xZ #16 CONFIRMATION SENT on its due date\n")
        self.run.intake_register(md)
        rows = {r["register_no"]: r for r in self.s.all()}
        self.assertEqual((rows[13]["class"], rows[16]["class"]), ("privacy_erasure", "privacy_erasure"))
        self.assertEqual((rows[13]["status"], rows[13]["confirmed_at"]), ("open", ""))
        self.assertEqual((rows[16]["status"], rows[16]["confirmed_at"]), ("closed", "2026-10-23T00:00:00Z"))
        self.run.intake_register(md)        # and a second read of the same file does not close it either
        self.assertEqual(self.s.get(rows[13]["id"])["status"], "open")
        self.assertEqual(self.run.dsar_clock(utc(2026, 11, 13))["closed_without_response"], [])

    def test_the_tick_reopens_before_it_decides_so_the_request_is_acknowledged_in_the_same_run(self):
        src = (ROOT / "scripts" / "gdpr-pipeline.py").read_text()
        tick = src[src.index('if a.cmd in ("backfill", "tick"):'):]
        self.assertLess(tick.index("run.reopen_unanswered()"), tick.index("run.decide_all("))
        self.assertLess(tick.index("run.decide_all("), tick.index("dsar_ladder(run, now, a.ladder_limit"))


if __name__ == "__main__":
    unittest.main()
