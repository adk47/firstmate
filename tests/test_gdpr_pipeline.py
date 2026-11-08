"""GDPR erasure pipeline (scripts/gdpr_pipeline): identity paths A-E + legal_threat, the register store, the intake
parsers, the reversible-hide batch editors, the approved copy, the S/P/M checks and the watchdog.

Locks (Fable gdpr-ruling-for-jan §3, gdpr-ack-v2 §3, firstmate spec gdpr-pipeline-g1):
  - a claim is ONE identity path, never a requirement; unclaimed + name match = C; big-name -> Jan
  - request text never decides a hide: a mismatched name / someone else's claim = ASK; text can only restrict
  - one row per request across channels; the row key is the idempotence test; merging never moves a due date later
  - the hide editors only ADD ids (reversible), extend the strict-equality test set, and refuse an unknown shape
  - sends are locked; a letter carries only verified lines and [D-no]; barred phrases never render
Hermetic: no network, no Trino, no Intercom. Stdlib unittest.
"""
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

try:
    from unittest import mock
except ImportError:  # pragma: no cover
    import mock  # type: ignore
from gdpr_pipeline import approval, checks, copy, hide_batch, identity, intake, send, sources  # noqa: E402
from gdpr_pipeline import store  # noqa: E402
from gdpr_pipeline import run as run_mod  # noqa: E402
from gdpr_pipeline.identity import Page, Requester  # noqa: E402
from gdpr_pipeline.run import Run, backfill_table, page_text  # noqa: E402
from gdpr_pipeline.store import Store, now_iso, parse_iso  # noqa: E402

def _cli():
    """scripts/gdpr-pipeline.py (hyphen, so no plain import). Loading it has no side effects: everything lives under
    main()."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("gdpr_pipeline_cli", os.path.join(HERE, "gdpr-pipeline.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


HERE = os.path.dirname(os.path.abspath(__file__)) + "/../scripts"


ARPAD = "7950a3c4-db2f-49bb-9acf-0d406bfb09ae"
OTHER = "11111111-2222-3333-4444-555555555555"


def page(**kw):
    base = dict(entity_id=ARPAD, name="Laczkovszki Arpad", popularity=0, credit_count=3)
    base.update(kw)
    return Page(**base)


class Identity(unittest.TestCase):
    def test_arpad_is_path_c(self):
        r = Requester(name="Arpad Laczkovszki", email="arpad.laczkovszki@pm.me", verified=True)
        d = identity.decide([page()], r, "privacy_erasure")
        self.assertEqual((d.verdict, d.basis), ("PASS_C", "C"))
        # ...and the SAME name/email from an unverified ticket is an ASK, never a hide
        d2 = identity.decide([page()], Requester(name="Arpad Laczkovszki",
                                                 email="arpad.laczkovszki@pm.me"), "privacy_erasure")
        self.assertEqual(d2.verdict, "ASK_IDENTITY")
        self.assertIn("not verified", d2.pages[0].why)

    def test_email_local_part_alone_counts_for_c(self):
        r = Requester(name="", email="laczkovszkiarpad@pm.me", verified=True)
        self.assertEqual(identity.decide([page()], r, "privacy_erasure").verdict, "PASS_C")

    def test_big_name_goes_to_jan_not_c(self):
        r = Requester(name="Arpad Laczkovszki")
        self.assertEqual(identity.decide([page(popularity=61)], r, "privacy_erasure").verdict, "JAN_BIGNAME")
        self.assertEqual(identity.decide([page(credit_count=50)], r, "privacy_erasure").verdict, "JAN_BIGNAME")

    def test_claim_is_a_path_not_a_requirement(self):
        claimed = page(is_claimed=True, claim_user_ids=frozenset({42}))
        self.assertEqual(identity.decide([claimed], Requester(account_id=42), "privacy_erasure").verdict, "PASS_A")
        # someone ELSE holds the claim -> ASK, even when the name matches
        self.assertEqual(identity.decide([claimed], Requester(name="Arpad Laczkovszki", account_id=7),
                                         "privacy_erasure").verdict, "ASK_IDENTITY")

    def test_path_b_needs_the_accounts_name_to_match(self):
        self.assertEqual(identity.decide([page()], Requester(account_id=9, account_names=("Arpad Laczkovszki",)),
                                         "privacy_erasure").verdict, "PASS_B")
        self.assertEqual(identity.decide([page()], Requester(account_id=9, account_names=("Someone Else",)),
                                         "privacy_erasure").verdict, "ASK_IDENTITY")

    def test_path_d_official_domain_from_our_catalog_only(self):
        p = page(name="Big Label Artist", website="https://www.biglabel.com/artist")
        self.assertEqual(identity.decide([p], Requester(email="legal@biglabel.com", verified=True),
                                         "privacy_erasure").verdict, "PASS_D")
        # QA 21st round: a SIBLING subdomain is a different host. Path D compares exact normalized hosts (only a
        # bare `www.` is equivalent); reducing to the registrable parent let agency.example.com stand in for
        # artist.example.com and put an unrelated profile into a hide batch.
        sib = page(name="Other Person", website="https://artist.example.com/other")
        self.assertEqual(identity.decide([sib], Requester(email="legal@agency.example.com", verified=True),
                                         "privacy_erasure").verdict, "ASK_IDENTITY")
        self.assertEqual(identity.decide([sib], Requester(email="legal@artist.example.com", verified=True),
                                         "privacy_erasure").verdict, "PASS_D")
        self.assertEqual(identity.host_of("https://WWW.Artist.Example.com:443/x?y=1"), "artist.example.com")
        self.assertEqual(identity.host_of("mailto:a@Artist.Example.com"), "artist.example.com")
        self.assertEqual(identity.host_of("not a host"), "")
        # the registrable-domain helper still exists for what it is for, but it is not the identity comparison
        self.assertEqual(identity.domain_of("a.b.example.co.uk"), "example.co.uk")
        # a freemail domain is never an official domain
        p2 = page(name="X Y", website="https://gmail.com")
        self.assertEqual(identity.decide([p2], Requester(email="a@gmail.com", verified=True),
                                         "privacy_erasure").verdict, "ASK_IDENTITY")

    def test_an_unverified_lead_email_never_carries_path_d(self):
        """QA 10th round: an Intercom LEAD types its own address. A self-typed address at the page's own domain is not
        proof of domain control, so D needs a verified sender (authenticated mail, or a logged-in user's address)."""
        p = page(name="Big Label Artist", website="https://www.biglabel.com/artist")
        dec = identity.decide([p], Requester(email="legal@biglabel.com"), "privacy_erasure")
        self.assertEqual(dec.verdict, "ASK_IDENTITY")
        self.assertIn("not verified", dec.pages[0].why)

    def test_mismatched_name_is_ask_never_a_guess(self):
        self.assertEqual(identity.decide([page()], Requester(name="Astra"), "privacy_erasure").verdict, "ASK_IDENTITY")

    def test_mononym_is_not_a_legal_name(self):
        self.assertEqual(identity.decide([page(name="Soggy")], Requester(name="Soggy"), "privacy_erasure").verdict,
                         "ASK_IDENTITY")

    def test_representative_is_asked_for_authorisation(self):
        r = Requester(name="Arpad Laczkovszki", representative=True)
        self.assertEqual(identity.decide([page()], r, "privacy_erasure").verdict, "ASK_AUTH")

    def test_no_link_is_ask_link(self):
        self.assertEqual(identity.decide([], Requester(name="A B"), "privacy_erasure").verdict, "ASK_LINK")

    def test_legal_threat_hides_first_except_big_names(self):
        self.assertEqual(identity.decide([page()], Requester(), "legal_threat").verdict, "LEGAL_HIDE_FIRST")
        self.assertEqual(identity.decide([page(popularity=80)], Requester(), "legal_threat").verdict, "JAN_BIGNAME")

    def test_dmca_stays_claim_first(self):
        self.assertEqual(identity.decide([page()], Requester(name="Arpad Laczkovszki"), "dmca_takedown").verdict,
                         "DMCA_REVIEW")

    def test_unreadable_page_is_unknown_and_wins_the_row(self):
        d = identity.decide([page(), page(entity_id=OTHER, found=False)],
                            Requester(name="Arpad Laczkovszki", verified=True), "privacy_erasure")
        self.assertEqual(d.verdict, "UNKNOWN")
        self.assertEqual([p.verdict for p in d.pages], ["PASS_C", "UNKNOWN"])

    def test_gone_and_hidden(self):
        self.assertEqual(identity.decide([page(gone=True)], Requester(), "privacy_erasure").verdict, "GONE")
        # a page we hid answers 404 to the catalog read as well, so "gone" and "hidden" are both true for OUR OWN
        # hides: the id on the hide list is the stronger, checkable fact and must win (found live 2026-11-04 - 9
        # overdue rows were parked in the GONE pile instead of the confirmation queue)
        both = identity.decide([page(gone=True, hidden=True)], Requester(), "privacy_erasure")
        self.assertEqual(both.verdict, "ALREADY_HIDDEN", "our own hide must never be read as an outside deletion")
        self.assertEqual(identity.decide([page(hidden=True)], Requester(), "privacy_erasure").verdict,
                         "ALREADY_HIDDEN")

    def test_half_a_hide_is_not_gone_and_not_hidden(self):
        """A hide needs BOTH lists and they ship in separate PRs. In that window the page answers 404 everywhere, so
        reading it as GONE hands Jan a deletion to explain that was our own half-finished work; reading it as
        ALREADY_HIDDEN claims a hide that has not happened. Live 2026-11-04: 9 open rows, all PDP-only."""
        d = identity.decide([page(gone=True, half_hidden="pdp")], Requester(), "privacy_erasure")
        self.assertEqual(d.verdict, "HIDDEN_PENDING")
        why = d.pages[0].why
        self.assertIn("PDP sitemap legal_hidden", why, "the message must name the list that holds it")
        self.assertIn("H-DevOps HIDDEN_ENTITY_IDS", why, "and the one that must still be merged")
        self.assertNotEqual(d.verdict, "GONE")
        self.assertEqual(identity.decide([page(half_hidden="hd")], Requester(), "privacy_erasure").verdict,
                         "HIDDEN_PENDING")
        self.assertIn("H-DevOps HIDDEN_ENTITY_IDS", identity.decide(
            [page(half_hidden="hd")], Requester(), "privacy_erasure").pages[0].why)

    def test_intake_passes_the_half_hide_map_as_half_not_as_the_conversation_reader(self):
        """QA finding on #1736, the call-site half: `hidden_now()` returns (ids on BOTH lists, {id: the one list that
        holds it}) and the CLI unpacked it straight into `decide_rows(rows, *hidden_now(run))`, so the MAP landed in
        `conv_reader`. A pushed candidate with a conversation_id then raised `TypeError: 'dict' object is not
        callable`, and one without it silently lost the map and could keep GONE. Driven through the real CLI function,
        because the unit-level predicate was already right - the wiring was not."""
        import tempfile
        cli = _cli_module()
        d = tempfile.mkdtemp()
        store = os.path.join(d, "erasure.sqlite")
        cand = os.path.join(d, "cand.json")
        with open(cand, "w") as f:
            json.dump({"keys": ["intercom:215476650395415"], "channel": "intercom", "class": "privacy_erasure",
                       "received_at": "2026-11-04T01:39:22Z", "conversation_id": "215476650395415",
                       "pages": [{"entity": "profile", "id": ARPAD}]}, f)
        a = type("A", (), {"candidate": cand, "no_decide": False, "store": store})()
        run = Run(Store(store), log=lambda *_: None)
        seen = {}

        def fake_decide_rows(self, rows, hidden, conv_reader=None, prefix_resolver=None, half=None):
            seen.update(hidden=hidden, conv_reader=conv_reader, half=half)

        with mock.patch.object(cli, "hidden_now", lambda r: ({"a" * 36}, {"b" * 36: "hd"})), \
                mock.patch.object(cli.sources, "conversation", lambda cid: {}), \
                mock.patch.object(cli.sources, "resolve_prefixes", lambda ids: {}), \
                mock.patch.object(cli.sources, "processed_claims", lambda ids: {}), \
                mock.patch.object(cli.sources, "resolve_account", lambda *a, **k: (None, "")), \
                mock.patch.object(cli.sources, "page_facts", lambda *a, **k: []), \
                mock.patch.object(Run, "decide_rows", fake_decide_rows), \
                mock.patch("builtins.print", lambda *x, **k: None):
            cli.cmd_intake(run, a)
        self.assertEqual(seen.get("half"), {"b" * 36: "hd"},
                         "the half-hide map must reach decide_rows as `half`")
        self.assertIsNone(seen.get("conv_reader"),
                          "and must never be handed over as the conversation reader")

    def test_a_half_hide_the_catalog_cannot_read_is_still_a_half_hide(self):
        """QA finding on #1736: `page_facts` sets `found=False` when the catalog 404s and the public page does NOT,
        which is exactly the half-hidden shape - so the not-found fallback was swallowing the state the half-hide
        branch exists to name, and a half-applied hide was filed as UNKNOWN instead of HIDDEN_PENDING."""
        d = identity.decide([page(found=False, half_hidden="hd")], Requester(), "privacy_erasure")
        self.assertEqual(d.verdict, "HIDDEN_PENDING",
                         "a half-applied hide must not be reported as an unreadable page")
        self.assertIn("H-DevOps HIDDEN_ENTITY_IDS", d.pages[0].why)
        # and the fallback still does its own job for a page that is NOT on either list
        self.assertEqual(identity.decide([page(found=False)], Requester(), "privacy_erasure").verdict, "UNKNOWN")

    def test_a_row_that_still_needs_a_letter_is_not_downgraded_by_a_pending_page(self):
        d = identity.decide([page(half_hidden="pdp"), page(entity_id=OTHER, found=False)],
                            Requester(name="Arpad Laczkovszki", verified=True), "privacy_erasure")
        self.assertEqual(d.verdict, "UNKNOWN", "the most restrictive page still wins the row")

    def test_half_hidden_says_which_list_is_missing(self):
        hd = {"1" * 36}
        pdp = {"2" * 36}
        self.assertEqual(sources.half_hidden(hd, pdp), {"1" * 36: "hd", "2" * 36: "pdp"})
        self.assertEqual(sources.half_hidden(hd, hd), {}, "both lists -> fully hidden, not pending")
        self.assertEqual(sources.half_hidden(set(), pdp), {"2" * 36: "pdp"})

    def test_mixed_row_keeps_per_page_verdicts(self):
        d = identity.decide([page(), page(entity_id=OTHER, name="Somebody Else")],
                            Requester(name="Arpad Laczkovszki", verified=True), "privacy_erasure")
        self.assertEqual(d.verdict, "ASK_IDENTITY")
        self.assertEqual({p.entity_id: p.verdict for p in d.pages}, {ARPAD: "PASS_C", OTHER: "ASK_IDENTITY"})

    def test_no_requester_on_file_is_unknown_not_ask(self):
        self.assertEqual(identity.decide([page()], Requester(), "privacy_erasure").verdict, "UNKNOWN")

    def test_not_erasure(self):
        self.assertEqual(identity.decide([page()], Requester(), "not_erasure").verdict, "NOT_ERASURE")


class RepresentativeBeatsClaim(unittest.TestCase):
    """QA Critical (round 6): PASS_A returned before the E check, so a request made on someone else's behalf from an
    account holding a processed claim became hide-eligible without the written authorisation path E requires."""

    def test_a_claim_held_by_the_writer_does_not_excuse_authorisation(self):
        from gdpr_pipeline.identity import ASK_AUTH, LEGAL_HIDE_FIRST, PASS_A, decide_page
        page = Page(ARPAD, "profile", True, "Arpad", True, frozenset({42}), 1.0, 0, "", False)
        writer = Requester(name="A P", email="a@pm.me", account_id=42, representative=True)
        self.assertEqual(decide_page(page, writer, "privacy_erasure").verdict, ASK_AUTH)
        # the same claim without the representative flag is still path A
        self.assertEqual(decide_page(page, Requester("A P", "a@pm.me", account_id=42), "privacy_erasure").verdict,
                         PASS_A)
        # legal_threat keeps the captain's hide-first exception, representative or not
        self.assertEqual(decide_page(page, writer, "legal_threat").verdict, LEGAL_HIDE_FIRST)


class Intake(unittest.TestCase):
    def test_class_rules_are_read_from_legal_intake(self):
        self.assertTrue(any(c == "privacy_erasure" for c, _ in intake.RULES))
        self.assertEqual(intake.classify("", "Please delete my data"), "privacy_erasure")
        self.assertEqual(intake.classify("", "my lawyer will contact the CNIL"), "legal_threat")

    def test_representative_text_only_restricts(self):
        self.assertTrue(intake.is_representative("x <a@incogni.com>", ""))
        self.assertTrue(intake.is_representative("", "I am writing on behalf of my client"))
        self.assertFalse(intake.is_representative("Arpad <a@pm.me>", "please delete my data"))

    def _task(self, desc, summary="Customer asked", action="data-deletion", status="to do"):
        ar = {"action_type": action, "customer_email": "", "customer_profile_id": ARPAD,
              "details": {"request_type": "personal_data_erasure"}, "conversation_summary": summary,
              "cs_session_id": "agent:support:intercom:dwjzhcge:conversation:215476650395415"}
        return {"id": "1amvh555f30", "name": "[data-deletion] x", "date_created": "1793544280026",
                "status": {"status": status, "type": "open" if status == "to do" else "done"},
                "tags": [{"name": f"action:{action}"}],
                "custom_fields": [{"name": "Intercom Link", "value":
                                   "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/215476650395415"}],
                "description": desc + "\n---ACTION-REQUEST---\n" + json.dumps(ar) + "\n---END-ACTION-REQUEST---"}

    def test_parse_clickup_ticket(self):
        c = intake.parse_clickup(self._task(f"Profile: https://credits.muso.ai/profile/{ARPAD}"))
        self.assertEqual(c["keys"], ["intercom:215476650395415", "clickup:1amvh555f30"])
        self.assertEqual({p["id"] for p in c["pages"]}, {ARPAD})
        self.assertEqual(c["received_at"], "2026-11-01T14:44:40Z")

    def test_cancel_intent_ticket_is_not_erasure(self):
        c = intake.parse_clickup(self._task("x", summary="Rule fired: cancel_intent. Last user message: cancel my plan"))
        self.assertEqual(intake.ticket_class(c, "Please cancel my Pro plan and refund"), "not_erasure")
        self.assertEqual(intake.ticket_class(c, "cancel and delete my account please"),
                         "cancel_intent_mentions_deletion")

    def test_data_export_is_an_access_request(self):
        c = intake.parse_clickup(self._task("x", action="data-export"))
        self.assertEqual(intake.ticket_class(c, "send me my data"), "privacy_access")

    def test_register_rows(self):
        md = ("| # | received | Intercom | CU | who | request | ack | promised | status |\n|---|---|---|---|---|---|---|---|---|\n"
              "| 16 | 26 Aug | (email) legal@ 1a03cf817af65dcd | - | email-only | legal name | profile f8b294d0 | none | 26 Sep | open |\n"
              "| 36 | 22 Oct ~17:3xZ | support@ 1a164aa9db4fc3b6 + IC 215476518070915 | - | x | erasure | profile 0092c828 | "
              "c | 22 Nov | HIDDEN; TODO: batch PR (with #33 e40d4dae) |\n"
              "| 13 | 20 Oct 19:41Z | 215476481954575 | 869fkctdp | Maxime | URGENT GDPR | acked | 19 Nov | open |\n"
              "- 10-21 21:0xZ #13: firstmate ruled the deletion STANDS. COMPLETED 21 Oct 2026.\n"
              "- 10-23 08:4xZ #16 CONFIRMATION SENT on its due date\n")
        rows = {r["register_no"]: r for r in intake.parse_register(md)}
        self.assertIn("gmail:legal@muso.ai:1a03cf817af65dcd", rows[16]["keys"])
        self.assertEqual(rows[16]["received_at"], "2026-08-26T00:00:00Z")
        self.assertEqual(rows[16]["confirmed"], "2026-10-23T00:00:00Z")
        # another row's page named in passing is never attributed to this row
        self.assertEqual([p["id"] for p in rows[36]["pages"]], ["0092c828"])
        self.assertIn("intercom:215476518070915", rows[36]["keys"])
        self.assertEqual(rows[13]["status"], "closed")


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.s = Store(":memory:")

    def cand(self, **kw):
        c = {"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
             "received_at": "2026-10-01T10:00:00Z", "requester_email": "a@b.co", "pages": [{"entity": "profile", "id": ARPAD}]}
        c.update(kw)
        return c

    def test_due_dates(self):
        rid, how = self.s.upsert(self.cand())
        r = self.s.get(rid)
        self.assertEqual((how, r["due_at"], r["hide_due_at"]), ("created", "2026-10-31T10:00:00Z", "2026-10-02T10:00:00Z"))
        self.assertEqual(r["register_no"], 40)

    def test_key_is_the_idempotence_test(self):
        rid, _ = self.s.upsert(self.cand())
        self.assertEqual(self.s.upsert(self.cand()), (rid, "unchanged"))
        self.assertEqual(len(self.s.all()), 1)

    def test_reconcile_on_catalog_id_and_email_never_ticket_alone(self):
        rid, _ = self.s.upsert(self.cand())
        # 60s earlier: the same customer event seen on another channel, inside the same-event window. (It used to be
        # eleven days earlier, which the symmetric bound now correctly treats as a separate request - see
        # test_an_earlier_dated_distinct_request_is_a_second_request.)
        rid2, how = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:abc"], channel="notices",
                                            received_at="2026-10-01T09:59:00Z"))
        self.assertEqual((rid2, how), (rid, "merged"))
        r = self.s.get(rid)
        self.assertEqual(r["due_at"], "2026-10-31T09:59:00Z")   # the earlier receipt brings the due date FORWARD
        self.assertIn("gmail:notices@muso.ai:abc", r["keys"])
        # a later receipt never moves it back
        self.s.upsert(self.cand(keys=["clickup:z"], received_at="2026-10-30T00:00:00Z"))
        self.assertEqual(self.s.get(rid)["due_at"], "2026-10-31T09:59:00Z")
        # same page, different requester, no shared key -> a separate request
        rid3, how3 = self.s.upsert(self.cand(keys=["intercom:2"], requester_email="other@x.co"))
        self.assertNotEqual(rid3, rid)

    def test_same_notice_to_two_mailboxes_is_one_request(self):
        """One notice, two mailboxes: the copies share the message's own Date. That - not "same pages within three
        days" - is the evidence that proves one event (QA a3e68886a)."""
        pages = [{"entity": "profile", "id": "9ad7c7f3"}]
        rid, _ = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:a"], channel="notices", requester_email="",
                                         pages=pages, received_at="2026-10-01T10:00:00Z"))
        rid2, how = self.s.upsert(self.cand(keys=["gmail:legal@muso.ai:b"], channel="legal", requester_email="",
                                            pages=pages, received_at="2026-10-01T10:00:04Z"))
        self.assertEqual((rid2, how), (rid, "merged"))
        # a copy that arrives a day later is NOT that event: the page set alone never proves one request
        rid3, how3 = self.s.upsert(self.cand(keys=["gmail:legal@muso.ai:c"], channel="legal", requester_email="",
                                             pages=pages, received_at="2026-10-02T09:00:00Z"))
        self.assertEqual(how3, "created")
        self.assertNotEqual(rid3, rid)

    def test_a_prefix_and_its_full_uuid_are_the_same_page_for_a_merge(self):
        """Found live 2026-11-04 (register #376/#377): the notices@ ledger keeps an 8-char id, Intercom keeps the full
        uuid, and the SAME customer event arrived on both channels nine seconds apart. Compared verbatim the page sets
        never intersected, so one request became two rows - two deadlines, two watchdogs, two letters."""
        rid, how = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                           requester_email="gertjan@pm.me", received_at="2026-11-04T01:39:22Z",
                                           pages=[{"entity": "profile", "id": "fc31a861"}]))
        self.assertEqual(how, "created")
        rid2, how2 = self.s.upsert(self.cand(keys=["intercom:215476692845876"], channel="intercom",
                                             requester_email="gertjan@pm.me", received_at="2026-11-04T01:39:31Z",
                                             pages=[{"entity": "profile",
                                                     "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]))
        self.assertEqual((rid2, how2), (rid, "merged"), "one person, one page, one event")
        # and the row now carries the full uuid, not the prefix: the catalog can decide it
        self.assertEqual([p["id"] for p in self.s.get(rid)["pages"]], ["fc31a861-0297-410d-914b-60e8a02ced76"])

    def test_the_other_order_merges_too(self):
        """Which lane runs first is an accident of timing (Intercom searches 3 hours, the mail ledger runs on its own
        cron), so the match must not depend on the row having been written first with the prefix.

        The two receipts are nine seconds apart, as they were live. They used to be three days apart, which the
        same-event bound now (correctly) refuses: a receipt that much later is a new request, not the other delivery
        of this one."""
        rid, _ = self.s.upsert(self.cand(keys=["intercom:215476692845876"], channel="intercom",
                                         received_at="2026-11-04T01:39:22Z",
                                         pages=[{"entity": "profile",
                                                 "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]))
        rid2, how2 = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                             received_at="2026-11-04T01:39:31Z",
                                             pages=[{"entity": "profile", "id": "fc31a861"}]))
        self.assertEqual((rid2, how2), (rid, "merged"), "the prefix must find the row that already holds the full id")

    def test_a_later_request_from_the_same_sender_is_a_second_request(self):
        """QA on #1735, reproduced: notices@ `fc31a861` at 01:39 and a fresh Intercom request for the full uuid at
        06:39 came back (1,'created') then (1,'merged'). A shared page and a shared sender prove the same PERSON, not
        the same EVENT, so the later request lost its own deadline, its own watchdog and its own reply target."""
        rid, how = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                           requester_email="gertjan@pm.me", received_at="2026-11-04T01:39:22Z",
                                           pages=[{"entity": "profile", "id": "fc31a861"}]))
        self.assertEqual(how, "created")
        rid2, how2 = self.s.upsert(self.cand(keys=["intercom:215476692845876"], channel="intercom",
                                             requester_email="gertjan@pm.me", received_at="2026-11-04T06:39:00Z",
                                             pages=[{"entity": "profile",
                                                     "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]))
        self.assertEqual(how2, "created", "five hours later is a new request, not the other delivery of the first")
        self.assertNotEqual(rid2, rid)
        self.assertEqual(self.s.get(rid2)["due_at"], "2026-12-04T06:39:00Z", "the new request keeps its own deadline")

    def test_an_earlier_receipt_inside_the_window_merges_and_pulls_the_due_date_forward(self):
        """The other direction, inside the same-event window: the same customer event found on another channel with a
        slightly earlier date. Merging brings the due date forward, which makes us answer sooner."""
        rid, _ = self.s.upsert(self.cand(keys=["intercom:215476692845876"], channel="intercom",
                                         requester_email="gertjan@pm.me", received_at="2026-11-04T01:39:22Z",
                                         pages=[{"entity": "profile",
                                                 "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]))
        rid2, how2 = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                             requester_email="gertjan@pm.me", received_at="2026-11-04T01:38:40Z",
                                             pages=[{"entity": "profile", "id": "fc31a861"}]))
        self.assertEqual((rid2, how2), (rid, "merged"))
        self.assertEqual(self.s.get(rid)["due_at"], "2026-12-04T01:38:40Z")

    def test_an_earlier_dated_distinct_request_is_a_second_request(self):
        """QA on #1735, the mirror of the later-request case: a one-sided bound let a NEGATIVE difference always
        satisfy `<=`, so a distinct request dated two weeks earlier was swallowed into the newer row. Processing order
        is not evidence of event identity, and moving the due date earlier does not preserve the second request's own
        reply target or watchdog."""
        rid, how = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                           requester_email="gertjan@pm.me", received_at="2026-11-04T01:39:22Z",
                                           pages=[{"entity": "profile", "id": "fc31a861"}]))
        self.assertEqual(how, "created")
        rid2, how2 = self.s.upsert(self.cand(keys=["intercom:215476692845876"], channel="intercom",
                                             requester_email="gertjan@pm.me", received_at="2026-10-20T01:39:22Z",
                                             pages=[{"entity": "profile",
                                                     "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]))
        self.assertEqual(how2, "created", "two weeks earlier is a different request, not the other delivery")
        self.assertNotEqual(rid2, rid)
        self.assertEqual(self.s.get(rid2)["due_at"], "2026-11-19T01:39:22Z",
                         "the earlier request keeps its own, tighter deadline")

    def test_an_earlier_receipt_an_hour_away_is_also_a_second_request(self):
        """The case that separates a symmetric bound from a one-sided one, and the reason the bound is symmetric: an
        hour earlier is still a different request. A one-sided `<=` accepts every negative difference, so this merged
        and the second request lost its own reply target and watchdog."""
        rid, _ = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                         requester_email="gertjan@pm.me", received_at="2026-11-04T01:39:22Z",
                                         pages=[{"entity": "profile", "id": "fc31a861"}]))
        rid2, how2 = self.s.upsert(self.cand(keys=["intercom:215476692845876"], channel="intercom",
                                             requester_email="gertjan@pm.me", received_at="2026-11-04T00:39:22Z",
                                             pages=[{"entity": "profile",
                                                     "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]))
        self.assertEqual(how2, "created", "an hour earlier is a different request, not the other delivery")
        self.assertNotEqual(rid2, rid)
        self.assertEqual(self.s.get(rid)["due_at"], "2026-12-04T01:39:22Z",
                         "and the later one is not rewritten by it")

    def test_a_different_page_under_the_same_sender_is_still_a_second_request(self):
        rid, _ = self.s.upsert(self.cand(keys=["gmail:notices@muso.ai:t1"], channel="notices",
                                         requester_email="x@y.co", pages=[{"entity": "profile", "id": "fc31a861"}]))
        rid2, how2 = self.s.upsert(self.cand(keys=["intercom:9"], channel="intercom", requester_email="x@y.co",
                                             pages=[{"entity": "profile",
                                                     "id": "aaaaaaaa-0000-4000-8000-000000000000"}]))
        self.assertEqual(how2, "created")
        self.assertNotEqual(rid, rid2)

    def test_two_anonymous_threads_about_one_page_are_two_requests(self):
        """QA a3e68886a, reproduced: two support@ threads about the same profile, no sender on the ledger rows.
        Both used to collapse into the first row, so the second request lost its own deadline, its watchdog and its
        own reply target."""
        pages = [{"entity": "profile", "id": "9ad7c7f3"}]
        rid, how = self.s.upsert(self.cand(keys=["gmail:support@muso.ai:thread-a"], channel="support",
                                           requester_email="", pages=pages, received_at="2026-10-01T10:00:00Z"))
        self.assertEqual(how, "created")
        # 30 seconds later: even a near-identical time is not an event key when BOTH rows are anonymous
        rid2, how2 = self.s.upsert(self.cand(keys=["gmail:support@muso.ai:thread-b"], channel="support",
                                             requester_email="", pages=pages, received_at="2026-10-01T10:00:30Z"))
        self.assertEqual(how2, "created", "two threads are two requests until something proves they are one")
        self.assertNotEqual(rid, rid2)
        self.assertEqual([r["register_no"] for r in self.s.all()], [40, 41])
        self.assertEqual({r["received_at"] for r in self.s.all()},
                         {"2026-10-01T10:00:00Z", "2026-10-01T10:00:30Z"}, "each keeps its own clock")
        rid3, _ = self.s.upsert(self.cand(keys=["gmail:legal@muso.ai:c"], channel="legal", requester_email="",
                                          pages=pages, received_at="2026-10-20T09:00:00Z"))
        self.assertNotEqual(rid3, rid)

    def test_restrictive_class_wins_in_either_order(self):
        rid, _ = self.s.upsert(self.cand(keys=["register:4", "clickup:t1"], register_no=4))
        self.s.upsert(self.cand(keys=["intercom:1", "clickup:t1"], **{"class": "cancel_intent_mentions_deletion"}))
        self.assertEqual(self.s.get(rid)["class"], "cancel_intent_mentions_deletion")
        # a later generic erasure candidate never downgrades it again
        self.s.upsert(self.cand(keys=["clickup:t1"]))
        self.assertEqual(self.s.get(rid)["class"], "cancel_intent_mentions_deletion")
        # a misfiled not_erasure ticket never downgrades a register erasure row
        rid2, _ = self.s.upsert(self.cand(keys=["register:9", "clickup:t9"], register_no=9, requester_email=""))
        self.s.upsert(self.cand(keys=["clickup:t9"], requester_email="", **{"class": "not_erasure"}))
        self.assertEqual(self.s.get(rid2)["class"], "privacy_erasure")

    def test_prefix_replaced_by_full_id(self):
        rid, _ = self.s.upsert(self.cand(pages=[{"entity": "profile", "id": ARPAD[:8]}], keys=["register:5"],
                                         register_no=5))
        self.s.upsert(self.cand(keys=["register:5"], pages=[{"entity": "profile", "id": ARPAD}]))
        self.assertEqual([p["id"] for p in self.s.get(rid)["pages"]], [ARPAD])

    def test_events_are_audited(self):
        rid, _ = self.s.upsert(self.cand())
        self.s.update(rid, "decide", identity_verdict="PASS_C")
        self.assertEqual([e["kind"] for e in self.s.events(rid)], ["created", "decide"])


YAML = """          env:
            # 2026-10-24 earlier batch
            - name: HIDDEN_ENTITY_IDS
              value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            - name: PORT
"""
LEGAL = '''LEGAL_HIDDEN_ENTITY_IDS = {
    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa": ("profile", "gdpr-erasure-register-16"),
}

ENTITY_NAMES = ("profile", "track", "album")
'''
TEST = '''ERASURE_PROFILES = {
    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
}


def test_x():
    pass
'''


class HideBatch(unittest.TestCase):
    batch = [{"id": ARPAD, "register_no": 39, "basis": "PASS_C", "due_at": "2026-12-01T14:44:00Z",
              "need": ["hdevops", "pdp"], "request_id": 1}]

    def test_yaml_only_appends(self):
        out, added = hide_batch.edit_hdevops({"p.yaml": YAML}, self.batch, "2026-11-02")
        self.assertEqual(added, [ARPAD])
        self.assertIn(f'value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa,{ARPAD}"', out["p.yaml"])
        self.assertIn("# 2026-11-02 (gdpr-pipeline hide batch", out["p.yaml"])
        self.assertIn("            - name: PORT", out["p.yaml"])
        again, added2 = hide_batch.edit_hdevops(out, self.batch, "2026-11-02")
        self.assertEqual((again, added2), (out, []))

    def test_yaml_shape_refusal(self):
        with self.assertRaises(hide_batch.ShapeError):
            hide_batch.add_to_hidden_yaml(YAML + YAML, [ARPAD], [])

    def test_pdp_list_and_strict_test_extend_together(self):
        lt, tt, added = hide_batch.edit_pdp(LEGAL, TEST, self.batch, "2026-11-02")
        self.assertEqual(added, [ARPAD])
        self.assertIn(f'    "{ARPAD}": ("profile", "gdpr-erasure-register-39"),\n}}', lt)
        self.assertIn(f'    "{ARPAD}",\n}}', tt)
        self.assertNotIn("gdpr-erasure-register-39", TEST)

    def test_plan_takes_only_hide_eligible_profiles_most_overdue_first(self):
        rows = [
            {"id": 1, "status": "open", "register_no": 40, "due_at": "2026-12-01T00:00:00Z", "pages": [],
             "verdict_detail": [{"id": ARPAD, "verdict": "PASS_C"}, {"id": OTHER, "verdict": "ASK_IDENTITY"}]},
            {"id": 2, "status": "open", "register_no": 41, "due_at": "2026-10-01T00:00:00Z", "pages": [],
             "verdict_detail": [{"id": OTHER, "verdict": "LEGAL_HIDE_FIRST"}]},
            {"id": 3, "status": "open", "register_no": 42, "due_at": "2026-09-01T00:00:00Z", "pages": [],
             "verdict_detail": [{"id": "33333333-2222-3333-4444-555555555555", "verdict": "PASS_A"}]},
        ]
        plan = hide_batch.plan(rows, set(), {"33333333-2222-3333-4444-555555555555"},
                               in_flight={"hdevops": {"33333333-2222-3333-4444-555555555555"}})
        # the daily batch is built from identity-PASS pages only; legal hide-first is the captain's call
        self.assertEqual([p["id"] for p in plan], [ARPAD])
        plan = hide_batch.plan(rows, set(), {"33333333-2222-3333-4444-555555555555"},
                               in_flight={"hdevops": {"33333333-2222-3333-4444-555555555555"}}, include_legal=True)
        self.assertEqual([p["id"] for p in plan], [OTHER, ARPAD])
        plan2 = hide_batch.plan(rows, set(), {"33333333-2222-3333-4444-555555555555"}, {})
        self.assertEqual(plan2[0]["need"], ["hdevops"])

    def test_a_page_held_for_the_captains_legal_threat_call_is_not_swept_up_by_another_row(self):
        """Two register rows can carry the SAME page id. Register #126 (legal threat) holds 7871c617 for the captain's
        own hide-first call; register #246 independently decides the same page PASS_A. The batch dedups by PAGE, so
        without this rule #246 would quietly overturn the withdrawal of that id from an earlier batch."""
        rows = [
            {"id": 1, "status": "open", "class": "legal_threat", "register_no": 126, "due_at": "2026-11-22T00:00:00Z",
             "pages": [], "verdict_detail": [{"id": ARPAD, "verdict": "LEGAL_HIDE_FIRST"}]},
            {"id": 2, "status": "open", "class": "privacy_erasure", "register_no": 246, "due_at": "2026-12-02T00:00:00Z",
             "pages": [], "verdict_detail": [{"id": ARPAD, "verdict": "PASS_A"}]},
        ]
        self.assertEqual(hide_batch.plan(rows, set(), set(), {}), [])
        # the captain's GO (include_legal) is what lets it through, and then it is attributed to the row that named it
        self.assertEqual([p["register_no"] for p in hide_batch.plan(rows, set(), set(), {}, include_legal=True)], [126])
        # a page held ONLY by a non-legal row is unaffected by the rule
        rows[0]["class"] = "privacy_erasure"
        self.assertEqual([p["id"] for p in hide_batch.plan(rows, set(), set(), {})], [ARPAD])

    def test_half_opened_batch_is_retried_for_the_missing_half_only(self):
        rows = [{"id": 1, "status": "open", "register_no": 40, "due_at": "2026-12-01T00:00:00Z", "pages": [],
                  "verdict_detail": [{"id": ARPAD, "verdict": "PASS_C"}]}]
        # the H-DevOps PR opened, the PDP one failed: the next run plans the PDP half
        plan = hide_batch.plan(rows, set(), set(), {"hdevops": {ARPAD}, "pdp": set()})
        self.assertEqual([(p["id"], p["need"]) for p in plan], [(ARPAD, ["pdp"])])
        # both halves in flight: nothing to do
        self.assertEqual(hide_batch.plan(rows, set(), set(), {"hdevops": {ARPAD}, "pdp": {ARPAD}}), [])

    def test_no_delete_anywhere(self):
        root = os.path.join(os.path.dirname(__file__), "..", "scripts")
        for f in ["gdpr-pipeline.py"] + [os.path.join("gdpr_pipeline", x) for x in
                                         os.listdir(os.path.join(root, "gdpr_pipeline")) if x.endswith(".py")]:
            with open(os.path.join(root, f)) as fh:
                src = fh.read()
            self.assertNotRegex(src, r'"DELETE"|method="DELETE"|muso-cli"?,\s*"delete', f)


class Entrypoint(unittest.TestCase):
    def test_a_missing_mail_ledger_fails_the_run(self):
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        run = Run(Store(":memory:"), log=lambda *_: None)
        self.assertEqual(cli.load_ledger(run, "/nonexistent/ledger.json"), {})
        self.assertEqual(len(run.errors), 1)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("[]")
        cli.load_ledger(run, f.name)
        self.assertEqual(len(run.errors), 2)
        os.unlink(f.name)
        run2 = Run(Store(":memory:"), log=lambda *_: None)
        self.assertEqual(cli.load_ledger(run2, ""), {})          # skipping a source is explicit
        self.assertEqual(run2.errors, [])

    def test_the_first_run_on_a_fresh_node_can_take_the_lock(self):
        """QA 21st round: hold_lock() runs BEFORE Store() (so an overlapping tick touches no DB at all), which meant
        the very first tick on a fresh node died with FileNotFoundError because /var/lib/hydra-gdpr did not exist
        yet: no intake, no watchdog, on the one run that has to work. The state dir is created by the lock, 0700."""
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_lock", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "fresh", "erasure.sqlite")     # neither dir exists yet
            lock = cli.hold_lock(store)
            self.assertIsNotNone(lock, "the first run must get the lock, not crash")
            try:
                self.assertTrue(os.path.isdir(os.path.join(tmp, "fresh")))
                mode = os.stat(os.path.join(tmp, "fresh")).st_mode & 0o777
                self.assertEqual(mode, 0o700)
                self.assertEqual(cli.hold_lock(store), None, "a second run exits without touching the store")
            finally:
                lock.close()
            # once the first run is gone the lock is free again
            again = cli.hold_lock(store)
            self.assertIsNotNone(again)
            again.close()


def _cli_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "gdpr_cli_copy", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Copy(unittest.TestCase):
    def test_sends_are_unlocked_only_against_both_human_locks(self):
        """The compiled unlock is one lock; the per-run --approved-by allowlist is the other. Unlocking must never
        mean "any caller can send": with the constant True, a non-allowlisted approver still refuses."""
        cli = _cli_module()
        self.assertTrue(copy.PIPELINE_SENDS_APPROVED)
        self.assertIn("Fable", copy.SEND_APPROVAL_REF)
        items = [{"row": 1, "register_no": 39, "text": "approved letter"}]
        d = approval.digest("confirm", items)
        line = f"APPROVE gdpr confirm {d} ruling=fable-ruling-1103-b3/gdpr-confirmation"
        env = {"GDPR_APPROVAL_CHANNEL": "C123", "MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb",
               "GDPR_APPROVER_SEAT": "U0SEATFABLED2"}
        for who in cli.APPROVERS:
            with mock.patch.dict(os.environ, env), \
                    mock.patch.object(approval, "_history",
                                      lambda *a, who=who: [{"user": who, "text": line, "ts": "1"}]), \
                    mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True):
                cli.refuse_send(mock.Mock(send=True, approved_by=who), "confirm", items)
        for who in ("", "U0AGENTBOT", "firstmate"):
            with mock.patch.dict(os.environ, env), self.assertRaises(SystemExit):
                cli.refuse_send(mock.Mock(send=True, approved_by=who), "confirm", items)

    def test_the_cli_accepts_the_sender_seat_as_the_approver(self):
        """029/031: the seat posts the batch approval itself. The CLI's own allowlist pre-check knew only the three
        humans, so it refused the seat id before `verify` (which accepts it) could ever run."""
        cli = _cli_module()
        items = [{"row": 1, "register_no": 39, "text": "approved letter"}]
        d = approval.digest("confirm", items)
        line = f"APPROVE gdpr confirm {d} ruling=fable-ruling-1103-b3/gdpr-confirmation"
        env = {"GDPR_APPROVAL_CHANNEL": "C123", "MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb",
               "GDPR_APPROVER_SEAT": "U0SEATFABLED2"}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(approval, "_history",
                                  lambda *a: [{"user": "U0SEATFABLED2", "text": line, "ts": "1"}]), \
                mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True):
            cli.refuse_send(mock.Mock(send=True, approved_by="U0SEATFABLED2"), "confirm", items)
        for who in ("U0SOMEOTHERBOT", "firstmate"):
            with mock.patch.dict(os.environ, env, clear=True), self.assertRaises(SystemExit):
                cli.refuse_send(mock.Mock(send=True, approved_by=who), "confirm", items)

    def test_letter_has_only_verified_lines_and_d_no(self):
        t = copy.render_confirmation("Arpad", "2026-11-01T14:44:00Z", [f"https://muso.ai/profile/{ARPAD}"],
                                     "", "2026-11-25T00:00:00Z", "")
        self.assertIn("25 November 2026: the pages no longer show your information", t)
        self.assertNotIn("removed from search", t)
        self.assertNotIn("sitemaps", t)
        self.assertIn("restricted internal record", t)
        self.assertNotIn("asked Google", t)
        self.assertNotIn("in progress", t)

    def test_no_verified_line_no_letter(self):
        with self.assertRaises(ValueError):
            copy.render_confirmation("A", "2026-11-01T00:00:00Z", ["x"], "", "", "")

    def test_p_pending_line(self):
        t = copy.render_confirmation("", "2026-11-01T00:00:00Z", ["x"], "2026-11-02T00:00:00Z", "", "")
        self.assertIn("Hello there,", t)
        self.assertIn("The remaining step (removing the pages from public view) is in progress", t)

    def test_asks_are_the_approved_lines_verbatim(self):
        self.assertEqual(copy.ASK["ASK_LINK"],
                         "So we act on the right pages, please reply with the link(s) to the Muso page(s) concerned.")
        self.assertTrue(copy.ASK["ASK_IDENTITY"].startswith("The quickest way: open the page in the Muso app and claim it"))


class Checks(unittest.TestCase):
    def test_sitemap_walk_and_partial_scan_refusal(self):
        files = {
            checks.SITEMAP_INDEX: b'<?xml version="1.0"?><sitemapindex><sitemap><loc>https://s/a.xml</loc></sitemap>'
                                  b'<sitemap><loc>https://s/b.xml</loc></sitemap></sitemapindex>',
            "https://s/a.xml": b"<urlset><url><loc>https://muso.ai/profile/" + OTHER.encode() + b"</loc></url></urlset>",
            "https://s/b.xml": b"<urlset></urlset>",
        }
        res = checks.sitemap_absent([ARPAD, OTHER], fetch=lambda u: (200, {}, files[u]))
        self.assertEqual(res, {ARPAD: True, OTHER: False})
        files["https://s/b.xml"] = None
        with self.assertRaises(checks.Unknown):
            checks.sitemap_absent([ARPAD], fetch=lambda u: (503, {}, b"") if files[u] is None else (200, {}, files[u]))


    def test_a_malformed_autocomplete_response_is_unknown_never_absent(self):
        for body in (b'{"results": []}', b'{"data": null}', b'{"data": {"items": null}}', b'[]', b'not json'):
            with self.assertRaises(checks.Unknown, msg=body):
                checks.search_absent(ARPAD, "Laczkovszki Arpad", fetch=lambda q, b=body: (200, {}, b))
        with self.assertRaises(checks.Unknown):       # an HTTP error is already Unknown
            checks.search_absent(ARPAD, "Laczkovszki Arpad", fetch=lambda q: (502, {}, b"{}"))
        self.assertTrue(checks.search_absent(ARPAD, "Laczkovszki Arpad",
                                             fetch=lambda q: (200, {}, b'{"data": {"items": []}}')))

    def test_a_full_autocomplete_page_is_unknown_never_absent(self):
        """QA 15th round: the autocomplete endpoint ignores limit/offset/page/take and caps its own answer (measured
        30 items for limit=20 AND limit=200). A name with more matches than the cap can hold the target below the
        cut, so a FULL page without the id is "cannot check here", not "not in search" — S is a line of the letter."""
        def body(n, include=False):
            items = [{"id": f"00000000-0000-4000-8000-{i:012d}", "name": "Aaron", "entityType": "profile"}
                     for i in range(n)]
            if include:
                items[-1]["id"] = ARPAD
            return (200, {}, json.dumps({"result": "ok", "code": 200, "data": {"items": items}}).encode())

        cap = checks.AUTOCOMPLETE_CAP
        with self.assertRaises(checks.Unknown) as e:          # 30 items, target not among them
            checks.search_absent(ARPAD, "Aaron", fetch=lambda q: body(cap))
        self.assertIn("cap", str(e.exception))
        self.assertTrue(checks.search_absent(ARPAD, "Aaron", fetch=lambda q: body(cap - 1)))   # short page: real absence
        self.assertFalse(checks.search_absent(ARPAD, "Aaron", fetch=lambda q: body(cap, include=True)))  # found = present

    def test_a_full_page_is_unmeasurable_not_a_failed_read(self):
        """A full page and a missing name are PERMANENT: no retry will ever change them. They must be
        `Unmeasurable` (still an `Unknown`, so no line is ever filled) and not the plain `Unknown` that makes the
        tick exit 2 and page. Measured on node-8 2026-11-06: 31 such rows every tick, 16 tick failures in a day."""
        def body(n):
            items = [{"id": f"00000000-0000-4000-8000-{i:012d}", "name": "Robert"} for i in range(n)]
            return (200, {}, json.dumps({"result": "ok", "code": 200, "data": {"items": items}}).encode())

        with self.assertRaises(checks.Unmeasurable):
            checks.search_absent(ARPAD, "Robert", fetch=lambda q: body(checks.AUTOCOMPLETE_CAP))
        with self.assertRaises(checks.Unmeasurable):
            checks.search_absent(ARPAD, "   ", fetch=lambda q: body(0))
        # A transient read failure stays a plain Unknown, so the tick still reports it and retries.
        with self.assertRaises(checks.Unknown) as e:
            checks.search_absent(ARPAD, "Robert", fetch=lambda q: (502, {}, b"{}"))
        self.assertNotIsInstance(e.exception, checks.Unmeasurable)
        # Unmeasurable IS an Unknown, so every existing `except Unknown` keeps refusing to fill a line.
        self.assertTrue(issubclass(checks.Unmeasurable, checks.Unknown))


class Watchdog(unittest.TestCase):
    def test_pages_three_days_before_due_without_confirmation(self):
        s = Store(":memory:")
        s.upsert({"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-10-05T00:00:00Z", "pages": []})
        s.upsert({"keys": ["intercom:2"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-10-25T00:00:00Z", "pages": []})
        rid3, _ = s.upsert({"keys": ["intercom:3"], "channel": "intercom", "class": "privacy_erasure",
                            "received_at": "2026-10-01T00:00:00Z", "pages": []})
        s.update(rid3, "confirmed", confirmed_at="2026-10-30T00:00:00Z")
        lines = Run(s, log=lambda *_: None).watchdog(datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc))
        self.assertEqual(len(lines), 1)
        self.assertIn("in 2 d", lines[0])
        self.assertIn("<@U038BM16T7W>", page_text(lines))
        self.assertIn("| 40 |", backfill_table(s.all("open"), datetime(2026, 11, 1, tzinfo=timezone.utc)))


class SilentFailures(unittest.TestCase):
    """The four failure modes QA found on 779b360: a green tick that skipped work."""

    def test_a_delayed_tick_catches_up_the_intercom_window(self):
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        d = tempfile.mkdtemp()
        store = os.path.join(d, "erasure.sqlite")
        now = datetime(2026, 11, 2, 18, 0, tzinfo=timezone.utc)
        # no cursor yet: NOTHING has been searched, so the window is the whole lookback — "the last 3 h" is not
        # evidence about anything older, and an older Intercom-only request would otherwise never be registered
        self.assertEqual(cli.intercom_since(store, 3, now),
                         int((now - __import__("datetime").timedelta(days=cli.INTERCOM_MAX_LOOKBACK_DAYS)).timestamp()))
        # a successful run 8 h ago, then the timer slept 9 h: the window starts at the cursor, not 3 h back
        cli.save_intercom_cursor(store, datetime(2026, 11, 2, 9, 0, tzinfo=timezone.utc))
        self.assertEqual(cli.intercom_since(store, 3, now), int(datetime(2026, 11, 2, 9, 0, tzinfo=timezone.utc).timestamp()))
        # a 90-day outage is capped, so Intercom is never asked for years
        cli.save_intercom_cursor(store, datetime(2026, 7, 1, tzinfo=timezone.utc))
        self.assertEqual(cli.intercom_since(store, 3, now),
                         int((now - __import__("datetime").timedelta(days=cli.INTERCOM_MAX_LOOKBACK_DAYS)).timestamp()))

    def test_the_first_scan_registers_an_older_intercom_only_request(self):
        """QA 30th round: `backfill` passed `intercom_hours=None` (no conversation search at all) and the first tick
        started 3 h back, so a customer who asked to be erased on Intercom two days ago — no ClickUp ticket, no ledger
        row, no markdown-register row — was never registered, and the cursor then advanced past them: no 24-hour hide
        alert, no 30-day watchdog. The first pass now scans the whole lookback and only then writes the cursor."""
        import importlib.util
        import tempfile
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_first", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        from gdpr_pipeline import sources
        d = tempfile.mkdtemp()
        store = os.path.join(d, "erasure.sqlite")
        now = datetime(2026, 11, 3, 12, 0, tzinfo=timezone.utc)
        old_at = int(datetime(2026, 11, 1, 9, 0, tzinfo=timezone.utc).timestamp())      # two days before the first run
        conv = {"conversation_id": "215400000000777", "created_at": old_at, "subject": "",
                "author_name": "A P", "author_email": "a@pm.me",
                "customer_text": "please remove my profile muso.ai/profile/" + ARPAD,
                "parts": [{"at": old_at, "text": "please remove my profile muso.ai/profile/" + ARPAD}]}
        seen = {"since": None}

        def search(since):
            seen["since"] = since
            return ["215400000000777"] if since <= old_at else []

        ledger = os.path.join(d, "ledger.json")
        with open(ledger, "w") as f:
            f.write("{}")
        args = type("A", (), {"register": None, "gmail_ledger": ledger, "support_ledger": ledger,
                              "store": store, "cmd": "tick"})()
        run = Run(Store(store), log=lambda *_: None)
        with mock.patch.object(sources, "search_conversations", search), \
                mock.patch.object(sources, "conversation", lambda cid: conv), \
                mock.patch.object(sources, "clickup_tasks", lambda action: []):
            cli.do_intake(run, args, cli.INTERCOM_MAX_LOOKBACK_DAYS * 24, now=now)
        self.assertLessEqual(seen["since"], old_at, "the first scan reaches back past the request")
        rows = Store(store).all("open")
        self.assertEqual([r["row_key"] for r in rows], ["intercom:215400000000777"])
        self.assertEqual(rows[0]["received_at"], "2026-11-01T09:00:00Z")
        self.assertEqual(rows[0]["due_at"], "2026-12-01T09:00:00Z")
        # the cursor is written only after that complete scan, and it may not re-open the window a tick later
        self.assertIsNotNone(cli.intercom_since(store, 3, now))

    def test_a_failed_intercom_read_does_not_advance_the_cursor(self):
        import importlib.util
        import tempfile
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        from gdpr_pipeline import sources
        store = os.path.join(tempfile.mkdtemp(), "erasure.sqlite")
        run = Run(Store(store), log=lambda *_: None)
        with mock.patch.object(sources, "search_conversations", lambda since: []):
            self.assertTrue(run.intake_intercom(0, conv_reader=lambda c: {}))    # an empty search is a success
        with mock.patch.object(sources, "search_conversations",
                               side_effect=sources.Unknown("intercom 503")):
            self.assertFalse(run.intake_intercom(0, conv_reader=lambda c: {}))
        # a conversation that cannot be read is also a failure, so the window is retried rather than skipped
        with mock.patch.object(sources, "search_conversations", lambda since: ["215476650395415"]):
            self.assertFalse(run.intake_intercom(0, conv_reader=mock.Mock(side_effect=sources.Unknown("503"))))
        self.assertEqual(len(run.errors), 2)
        self.assertFalse(os.path.exists(cli._state_path(store, "intercom-cursor.json")))

    def test_watchdog_pages_on_turnover_not_on_a_line_count(self):
        s = Store(":memory:")
        r1, _ = s.upsert({"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                          "received_at": "2026-10-01T00:00:00Z", "pages": []})
        s.upsert({"keys": ["intercom:2"], "channel": "intercom", "class": "privacy_erasure",
                  "received_at": "2026-10-02T00:00:00Z", "pages": []})
        run = Run(s, log=lambda *_: None)
        first = run.watchdog_rows(datetime(2026, 11, 1, 17, 0, tzinfo=timezone.utc))
        self.assertEqual([r for r, _ in first], [40, 41])          # both overdue
        # #40 gets its written confirmation, and a THIRD request becomes due: the count is unchanged at 2
        s.update(r1, "confirmed", confirmed_at="2026-11-10T00:00:00Z")
        rid3, _ = s.upsert({"keys": ["intercom:3"], "channel": "intercom", "class": "privacy_erasure",
                            "received_at": "2026-10-25T00:00:00Z", "pages": []})
        self.assertEqual(s.get(rid3)["register_no"], 42)
        second = run.watchdog_rows(datetime(2026, 11, 22, 17, 0, tzinfo=timezone.utc))
        self.assertEqual([r for r, _ in second], [41, 42])
        self.assertEqual(len(second), len(first))                  # equal count, different content
        self.assertEqual([r for r, _ in second if r not in {x for x, _ in first}], [42])   # <- the page fires

    def test_a_repeat_after_confirmation_is_a_new_request(self):
        s = Store(":memory:")
        cand = {"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                "received_at": "2026-10-01T00:00:00Z", "requester_email": "a@pm.me",
                "pages": [{"entity": "profile", "id": ARPAD}]}
        rid, _ = s.upsert(cand)
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z")
        # same person, same page, a NEW conversation (a fresh request): never inherits confirmed_at
        rid2, how = s.upsert({**cand, "keys": ["intercom:9"], "received_at": "2026-11-01T00:00:00Z"})
        self.assertNotEqual(rid, rid2)
        self.assertEqual(how, "created")
        row = s.get(rid2)
        self.assertEqual(row["confirmed_at"], "")
        self.assertEqual(row["due_at"], "2026-12-01T00:00:00Z")
        # the SAME key is still the same request (idempotence is not weakened)
        rid3, how3 = s.upsert({**cand, "keys": ["intercom:9"], "received_at": "2026-11-01T00:00:00Z"})
        self.assertEqual((rid3, how3), (rid2, "unchanged"))

    def test_a_malformed_support_ledger_row_fails_the_source(self):
        rows = {"thread-1": {"class": "privacy_erasure", "first_seen": "not a date", "thread": "t1", "ids": []},
                "thread-2": {"class": "privacy_erasure", "first_seen": "Mon, 05 Oct 2026 10:00:00 +0000",
                             "ids": []},
                "thread-3": {"class": "privacy_erasure", "first_seen": "Mon, 05 Oct 2026 10:00:00 +0000",
                             "thread": "t3", "ids": []}}
        bad = []
        got = intake.parse_support_ledger(rows, bad)
        self.assertEqual([c["keys"][0] for c in got], ["gmail:support@muso.ai:t3"])
        self.assertEqual(len(bad), 2)                     # bad date AND missing thread are both failures
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        run.intake_gmail({}, rows)
        self.assertEqual(len(run.errors), 2)
        self.assertEqual([r["class"] for r in s.all("open")], ["privacy_erasure"])

    def test_gone_pages_are_marked_removed_outside_process(self):
        from unittest import mock
        from gdpr_pipeline import identity as ident
        s = Store(":memory:")
        rid, _ = s.upsert({"keys": ["register:36"], "channel": "register", "class": "privacy_erasure",
                           "received_at": "2026-10-01T00:00:00Z", "pages": [{"entity": "profile", "id": ARPAD}]})
        run = Run(s, log=lambda *_: None)
        fact = ident.Page(entity_id=ARPAD, name="", popularity=0, credit_count=0, gone=True)
        dec = ident.Decision("GONE", "", [ident.PageVerdict(ARPAD, "GONE", "404 in catalog + public, no merge")])
        with mock.patch.object(ident, "decide", lambda pages, req, cls: dec), \
                mock.patch("gdpr_pipeline.sources.resolve_account", lambda *a, **k: (None, "")), \
                mock.patch("gdpr_pipeline.sources.page_facts", lambda pages, hidden, claims, half=None: {ARPAD: fact}), \
                mock.patch("gdpr_pipeline.sources.processed_claims", lambda ids: {}):
            run.decide_row(s.get(rid), set(), {}, lambda c: {})
        self.assertEqual(s.get(rid)["removed_outside_process"], [ARPAD])
        # the markdown register #36 shape c3 asked for: a page gone with no merge record is visible per row
        self.assertIn("GONE", s.get(rid)["identity_verdict"])
        self.assertTrue(s.get(rid)["action"].startswith("Jan:"))


class TurnoverPagesOnlyFresh(unittest.TestCase):
    def test_a_second_page_same_day_renders_only_the_new_request(self):
        import datetime
        import importlib.util
        import tempfile
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "gdp_entry", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        entry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entry)
        r = mock.Mock()
        r.store.path = os.path.join(tempfile.mkdtemp(), "erasure.sqlite")   # state lives beside the DB
        now = datetime.datetime.now(datetime.timezone.utc)
        r.watchdog_rows.return_value = [(1, "#1 a"), (2, "#2 b")]
        r.hide_due_rows.return_value = []
        r.errors = []
        posts = []
        with mock.patch.object(entry, "slack_post", lambda c: posts.append(c) or True):
            entry.watchdog(r, page=True)                       # both paged
            r.watchdog_rows.return_value = [(1, "#1 a"), (2, "#2 b"), (3, "#3 c")]
            entry.watchdog(r, page=True)                       # only #3 is new
        self.assertIn("#1", posts[0])
        self.assertNotIn("#1", posts[1])      # already paged today: not repeated
        self.assertIn("#3", posts[1])


class BacklogAndDiff(unittest.TestCase):
    """QA round 3 (2026-11-02): a reply on an old conversation, a >40-row backlog, and a mention-only PR."""

    def test_intercom_search_covers_updated_conversations_not_only_new_ones(self):
        from unittest import mock
        from gdpr_pipeline import sources
        seen = []

        def fake_intercom(method, path, body):
            field = body["query"]["field"]
            seen.append(field)
            return ({"conversations": [{"id": "215476650395415" if field == "created_at" else "215400000000001"}],
                     "pages": {"page": 1, "total_pages": 1}})
        with mock.patch.object(sources, "intercom", fake_intercom):
            ids = sources.search_conversations(1793544280)
        self.assertEqual(seen, ["created_at", "updated_at"])          # an old thread answered today is found
        self.assertEqual(sorted(ids), ["215400000000001", "215476650395415"])

    def test_a_second_run_refuses_to_stack_on_the_first(self):
        """Two ticks on top of each other double every read (the decide pass is ~5 network reads per stale row) and
        can page twice for the same rows. The second run exits 0 without touching the store."""
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli3", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        d = tempfile.mkdtemp()
        first = cli.hold_lock(os.path.join(d, "erasure.sqlite"))
        self.assertIsNotNone(first)
        self.assertIsNone(cli.hold_lock(os.path.join(d, "erasure.sqlite")))     # the tick that overlaps loses
        self.assertTrue(os.path.exists(os.path.join(d, "run.lock")))
        first.close()
        third = cli.hold_lock(os.path.join(d, "erasure.sqlite"))
        self.assertIsNotNone(third)                                            # released when the run ends
        third.close()

    def test_a_malformed_search_page_fails_the_read_and_holds_the_cursor(self):
        """QA 19th round: a 200 whose body has no conversations LIST used to read as "empty final page", so the tick
        reported success and advanced its cursor over a window it never actually scanned."""
        from unittest import mock
        from gdpr_pipeline import sources
        bad = [{}, {"conversations": None}, {"conversations": "nope"}, {"data": []},
               {"conversations": [{"no_id": 1}]},
               {"conversations": [{"id": "1"}], "pages": "nope"},
               {"conversations": [{"id": "1"}], "pages": {"next": "nope"}},
               {"conversations": [{"id": "1"}], "pages": {"next": {"starting_after": "same"}}},
               # a NONEMPTY page with no pagination object: nothing proves it is the last page, so it is not one
               {"conversations": [{"id": "1"}]},
               {"conversations": [], "pages": {}},
               # a page object that says it is NOT the last page and carries no cursor
               {"conversations": [{"id": "1"}], "pages": {"page": 1, "total_pages": 3}},
               {"conversations": [{"id": "1"}], "pages": {"page": 1, "total_pages": 3, "next": None}}]
        for body in bad:
            cursor = "same" if body.get("pages") == {"next": {"starting_after": "same"}} else None
            with mock.patch.object(sources, "intercom", lambda *a, body=body, **k: body):
                with self.assertRaises(sources.Unknown, msg=json.dumps(body)):
                    sources._search_page("created_at", 1793544280, cursor)
        # an honest empty result is still a success, and a well-formed page yields its ids + next cursor
        with mock.patch.object(sources, "intercom",
                               lambda *a, **k: {"conversations": [], "pages": {"page": 1, "total_pages": 0}}):
            self.assertEqual(sources._search_page("created_at", 0, None), ([], None))
        # a page-numbered terminal page is a proven end too
        with mock.patch.object(sources, "intercom",
                               lambda *a, **k: {"conversations": [{"id": "7"}], "pages": {"page": 3, "total_pages": 3}}):
            self.assertEqual(sources._search_page("created_at", 0, "prev"), (["7"], None))
        with mock.patch.object(sources, "intercom", lambda *a, **k: {
                "conversations": [{"id": "215476650395415"}],
                "pages": {"page": 1, "total_pages": 2, "next": {"starting_after": "abc"}}}):
            self.assertEqual(sources._search_page("created_at", 0, None), (["215476650395415"], "abc"))
        # end to end through the tick's intake: the failure is reported and the cursor file is never written
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli2", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        store = os.path.join(tempfile.mkdtemp(), "erasure.sqlite")
        run = Run(Store(store), log=lambda *_: None)
        with mock.patch.object(sources, "intercom", lambda *a, **k: {"data": []}):
            self.assertFalse(run.intake_intercom(0, conv_reader=lambda c: {}))
        self.assertEqual(len(run.errors), 1)

    def test_a_backlog_over_forty_pages_every_request(self):
        from gdpr_pipeline.run import page_chunks
        # REALISTIC length: a watchdog line with a full action sentence is ~180 chars, so 41 of them cannot fit
        # in two messages. Nothing may be dropped: every line must appear exactly once across the messages.
        long = "identity ASK_LINK; next: send the approved link line, then the next run decides once the page is "
        lines = [f"#{40 + i} intercom received 2026-10-01, written confirmation OVERDUE (2026-10-31); {long}"
                 for i in range(41)]
        chunks = page_chunks(lines)
        self.assertGreaterEqual(len(chunks), 3)
        joined = "\n".join(chunks)
        for i in range(41):
            self.assertEqual(joined.count(f"#{40 + i} intercom"), 1, f"#{40 + i} must appear exactly once")
        self.assertTrue(all(len(c) <= 4000 for c in chunks))
        self.assertEqual(page_chunks([]), [])
        short = [f"#{40 + i} due" for i in range(95)]
        self.assertEqual("\n".join(page_chunks(short)).count("- #"), 95)

    def test_in_flight_reads_the_hide_list_at_the_pr_head(self):
        """Only an id that the PR's OWN head file puts in HIDDEN_ENTITY_IDS / LEGAL_HIDDEN_ENTITY_IDS counts: a body
        mention, a comment, a reverted plan, the sitemap TEST file, or the same uuid under a DIFFERENT env var in the
        very same manifest suppresses nothing (QA 3rd, 6th and 7th round)."""
        from gdpr_pipeline import hide_batch

        HDO = "k8s/prod/core-services/deployments.yaml"
        PDP = "src/tools/jobs/industry_processing/drivers/calc/sitemap/legal_hidden.py"

        def hdo(value: str, other: str = "") -> str:
            body = f"          env:\n            - name: HIDDEN_ENTITY_IDS\n              value: \"{value}\""
            if other:
                body += f"\n            - name: UNRELATED_IDS\n              value: \"{other}\""
            return f"spec:\n  template:\n{body}\n"

        def pdp(*entries: str) -> str:
            return "LEGAL_HIDDEN_ENTITY_IDS: dict[str, tuple[str, str]] = {\n" + "".join(entries) + "}\n"

        heads = {("Muso-AI/H-DevOps", "a" * 40): hdo("a,b"),
                 ("Muso-AI/H-DevOps", "b" * 40): hdo(f"a,b,{ARPAD}"),
                 # the same uuid, but under a different env name in the SAME file: not the hide list
                 ("Muso-AI/H-DevOps", "c" * 40): hdo("a,b", other=OTHER),
                 # a comment in the sitemap list, and the test file that mentions the id
                 ("Muso-AI/platform-data-processing", "d" * 40): pdp(f"    # {ARPAD} considered and reverted\n"),
                 ("Muso-AI/platform-data-processing", "e" * 40): pdp(f'    X = "{OTHER}",\n'),
                 ("Muso-AI/platform-data-processing", "f" * 40): pdp(
                     f'    "{ARPAD}": ("profile", "gdpr-erasure-register-12"),\n'),
                 # QA review 2026-11-03: a PR whose BASE already carries the id adds nothing to the hide list, so it
                 # must not stand in for the batch that is supposed to add it
                 ("Muso-AI/H-DevOps", "g" * 40): hdo(f"a,b,{ARPAD}")}
        # the PRs' BASE files, on distinct shas (a base is never the head): main without the id, and one branch that
        # already carries it
        bases = {"1" * 40: hdo("a,b"), "2" * 40: pdp(""), "3" * 40: hdo(f"a,b,{ARPAD}")}
        deg = {("Muso-AI/H-DevOps", "a" * 40): 1, ("Muso-AI/H-DevOps", "b" * 40): 2,
               ("Muso-AI/H-DevOps", "c" * 40): 3, ("Muso-AI/platform-data-processing", "d" * 40): 4,
               ("Muso-AI/platform-data-processing", "e" * 40): 5,
               ("Muso-AI/platform-data-processing", "f" * 40): 6, ("Muso-AI/H-DevOps", "g" * 40): 7}
        head_of = {v: k for k, v in deg.items()}
        base_sha = {"b" * 40: "1" * 40, "f" * 40: "2" * 40, "g" * 40: "3" * 40}

        def runner(argv):
            if "/contents/" in argv[-1]:
                repo = argv[-1].split("/contents/")[0].split("repos/")[1]
                sha = argv[-1].split("?ref=")[1]
                if (repo, sha) in heads:
                    return heads[(repo, sha)]
                return bases[sha]
            repo = argv[argv.index("-R") + 1]
            out = []
            for (r, sha), n in deg.items():
                if r != repo:
                    continue
                base = base_sha.get(sha, "0" * 40)
                out.append({"number": n, "headRefOid": sha, "baseRefOid": base})
            return json.dumps(out)
        got = hide_batch.in_flight_ids([ARPAD, OTHER], runner=runner)
        self.assertEqual(got, {"hdevops": {ARPAD}, "pdp": {ARPAD}})
        # the base-already-has-it PR (sha g) is gone from the answer above; prove the pair whose base does NOT have it
        # is the one that counted, and that an empty ask reads nothing
        self.assertEqual(hide_batch.in_flight_ids([], runner=runner), {"hdevops": set(), "pdp": set()})

        def base_only(argv):
            if "/contents/" in argv[-1]:
                return hdo(f"a,b,{ARPAD}")
            return json.dumps([{"number": 7, "headRefOid": "g" * 40, "baseRefOid": "3" * 40}])
        self.assertEqual(hide_batch.in_flight_ids([ARPAD], runner=base_only)["hdevops"], set(),
                         "an id the BASE already carries was not added by this PR: it suppresses nothing")

        def no_base(argv):
            if "/contents/" in argv[-1]:
                return hdo(f"a,b,{ARPAD}")
            return json.dumps([{"number": 8, "headRefOid": "h" * 40}])
        self.assertEqual(hide_batch.in_flight_ids([ARPAD], runner=no_base)["hdevops"], set(),
                         "without a base sha the PR cannot prove it added anything")

    def test_a_new_batch_defers_while_the_previous_pair_is_unmerged(self):
        """A daily batch whose PR nobody merged must NOT open a second pair: both PRs of a batch insert at the same
        point in the same list file, so the second pair is a guaranteed conflict against ids nobody reviewed yet."""
        from gdpr_pipeline import hide_batch
        batch = [{"id": ARPAD, "register_no": 39, "basis": "PASS_C", "due_at": "2026-11-01", "need": ["hdevops", "pdp"]}]
        calls = []

        def runner(argv):
            calls.append(argv)
            if argv[:2] == ["gh", "pr"]:
                repo = argv[argv.index("-R") + 1]
                prior = {"Muso-AI/H-DevOps": [{"number": 4624, "url": "https://github.com/Muso-AI/H-DevOps/pull/4624",
                                               "headRefName": "gdpr-pipeline/hide-20261102-2200"}],
                         "Muso-AI/platform-data-processing": [{"number": 2575, "url": "https://x/2575",
                                                               "headRefName": "gdpr-pipeline/hide-20261102-2200"}]}[repo]
                return json.dumps(prior)
            raise AssertionError(f"nothing should be cloned or pushed while a batch is open: {argv[:3]}")
        res = hide_batch.open_prs(batch, dry_run=False, runner=runner)
        self.assertEqual(res["deferred"], {"hdevops": "https://github.com/Muso-AI/H-DevOps/pull/4624",
                                           "pdp": "https://x/2575"})
        self.assertEqual(res["hdevops"], "")
        self.assertEqual(res["pdp"], "")
        self.assertEqual(res["ids"], [ARPAD])
        self.assertEqual(len(calls), 2)          # one `gh pr list` per repository, and nothing else

    def test_a_human_authored_hide_pr_does_not_defer_the_pipeline(self):
        """Only OUR branch prefix defers. Arpad's hand-written #4619/#2574 are not a pipeline batch."""
        from gdpr_pipeline import hide_batch

        def runner(argv):
            return json.dumps([{"number": 4619, "url": "https://github.com/Muso-AI/H-DevOps/pull/4619",
                                "headRefName": "hide/arpad-1101"}])
        self.assertEqual(hide_batch.open_batch_prs("Muso-AI/H-DevOps", runner=runner), [])

    def test_an_unreadable_head_claims_nothing(self):
        from gdpr_pipeline import hide_batch

        def runner(argv):
            if "/contents/" in argv[-1]:
                raise hide_batch.Unknown("404 no such file at that ref")
            return json.dumps([{"number": 1, "headRefOid": "a" * 40}])
        self.assertEqual(hide_batch.in_flight_ids([ARPAD], runner=runner), {"hdevops": set(), "pdp": set()})
        # QA 22nd round: the REAL runner raises RuntimeError on a nonzero `gh api` (a PR that deleted the hide-list
        # file, a 404 on the head file), and that aborted the whole batch instead of claiming nothing.
        def raising(argv):
            if "/contents/" in argv[-1]:
                raise RuntimeError("gh api .../contents/...: 404 Not Found")
            return json.dumps([{"number": 1, "headRefOid": "a" * 40}])
        self.assertEqual(hide_batch.in_flight_ids([ARPAD], runner=raising), {"hdevops": set(), "pdp": set()})
        # and the batch still plans the eligible page, which is the whole point: nothing is hidden by not planning
        rows = [{"id": 1, "status": "open", "due_at": "2026-11-01T00:00:00Z", "register_no": 39,
                 "verdict_detail": [{"id": ARPAD, "verdict": "PASS_C", "why": ""}],
                 "pages": [{"entity": "profile", "id": ARPAD}]}]
        plan = hide_batch.plan(rows, set(), set(), hide_batch.in_flight_ids([ARPAD], runner=raising))
        self.assertEqual([b["id"] for b in plan], [ARPAD])
        self.assertEqual(plan[0]["need"], ["hdevops", "pdp"])


class ReplyMergesAndSitemapShapes(unittest.TestCase):
    """QA 9th round: a reply on an already-keyed thread must be read (the ASK_LINK answer carries the link), and a
    sitemap 200 that is not a sitemap must fail the check instead of claiming absence."""

    def test_a_reply_on_a_keyed_conversation_adds_the_link(self):
        from unittest import mock
        from gdpr_pipeline import sources
        early = {"conversation_id": "215400000000009", "created_at": 1790000000, "subject": "",
                 "author_name": "A P", "author_email": "a@pm.me", "customer_text": "please delete my data",
                 "parts": [{"at": 1790000000, "text": "please delete my data"}]}
        later = dict(early, customer_text="please delete my data\nhere it is muso.ai/profile/" + ARPAD,
                     parts=early["parts"] + [{"at": 1793600000, "text": "muso.ai/profile/" + ARPAD}])
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        with mock.patch.object(sources, "search_conversations", lambda since: ["215400000000009"]):
            self.assertTrue(run.intake_intercom(0, conv_reader=lambda c: early))
        row = s.all("open")[0]
        self.assertEqual(row["pages"], [])          # nothing to hide yet: ASK_LINK territory
        with mock.patch.object(sources, "search_conversations", lambda since: ["215400000000009"]):
            self.assertTrue(run.intake_intercom(0, conv_reader=lambda c: later))
        row = s.all("open")[0]
        self.assertEqual([p["id"] for p in row["pages"]], [ARPAD])   # the reply's link is on the row now
        self.assertGreater(row["updated_at"], row["decided_at"] or "")   # so the same tick re-decides it

    def test_extra_profile_ownership_counts_as_a_claim(self):
        """The ownership check reads extraprofileids too: a processed claim that carries the target only as an extra
        profile still means that account owns the page (measured 2026-11-02: 0 such rows live, so this is the latent
        case the source query must not drop)."""
        from unittest import mock
        from gdpr_pipeline import sources
        main_pid, extra_pid = ARPAD, OTHER

        def fake_trino(sql):
            if "postgresql_core.public.claiming" not in sql:
                return []
            return [[main_pid, "42", f'["{extra_pid}"]']]      # target as an EXTRA, not the claim's main id

        with mock.patch.object(sources, "trino", fake_trino):
            got = sources.processed_claims([main_pid, extra_pid])
        self.assertEqual(got, {main_pid: {42}, extra_pid: {42}})

    def test_two_post_confirmation_replies_make_two_distinct_requests(self):
        """QA 14th round: reply 1 supplies page A, reply 2 names A again plus B. Each reply becomes its own request
        carrying only what IT introduced — A must not be re-registered on the second one."""
        from gdpr_pipeline.run import Run
        A, B, C = OTHER, ARPAD, "43cf35c4-755e-41ca-9e4c-0cbfbbfa22f7"   # C was on the confirmed row
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000051"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                           "conversation_id": "215400000000051", "pages": [{"entity": "profile", "id": C}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run.merge_reply(s.get(rid), {"subject": "", "customer_text": f"also this one muso.ai/profile/{A}",
                                     "parts": [{"at": 1793544280, "text": f"muso.ai/profile/{A}"}]})
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [A])
        run.merge_reply(s.get(rid), {"subject": "",
                                     "customer_text": f"also this one muso.ai/profile/{A} and muso.ai/profile/{B}",
                                     "parts": [{"at": 1793544280, "text": f"muso.ai/profile/{A}"},
                                               {"at": 1793630680, "text": f"muso.ai/profile/{A} and {B}"}]})
        rows = sorted(s.all("open"), key=lambda r: r["received_at"])
        self.assertEqual(len(rows), 2)
        self.assertEqual([[p["id"] for p in r["pages"]] for r in rows], [[A], [B]])   # A is not duplicated
        self.assertLess(rows[0]["received_at"], rows[1]["received_at"])
        self.assertEqual(len({r["row_key"] for r in rows}), 2)

    def test_a_pure_escalation_after_confirmation_opens_one_row_dated_at_the_threat(self):
        """QA 19th round: confirmed erasure, then "or my attorney will write" with NO new page. The escalation row
        must be dated at the message that carried the threat, and a later unrelated reply ("thanks") must neither
        open a second escalation row nor move the first one's deadline."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000061"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                           "conversation_id": "215400000000061", "pages": [{"entity": "profile", "id": OTHER}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        parts = [{"at": 1793000000, "text": "please delete my data"},
                 {"at": 1793544280, "text": "or my attorney will write about this"}]
        conv = {"subject": "", "created_at": 1793000000, "parts": parts,
                "customer_text": "\n".join(p["text"] for p in parts)}
        run.merge_reply(s.get(rid), conv)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["class"], "legal_threat")
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")     # the threat, not the thread's start
        # the customer says thanks: nothing new, so nothing moves
        later = {"subject": "", "created_at": 1793000000,
                 "parts": parts + [{"at": 1793630680, "text": "thanks"}],
                 "customer_text": "\n".join(p["text"] for p in parts + [{"at": 1793630680, "text": "thanks"}])}
        run.merge_reply(s.get(rid), later)
        rows2 = s.all("open")
        self.assertEqual(len(rows2), 1)
        self.assertEqual(rows2[0]["received_at"], rows[0]["received_at"])
        self.assertEqual(rows2[0]["due_at"], rows[0]["due_at"])
        self.assertEqual(rows2[0]["row_key"], rows[0]["row_key"])

    def test_a_clickup_replay_of_a_pure_escalation_opens_one_row(self):
        """QA 20th round: the ClickUp replay path had the same duplicate as the conversation path -- a confirmed
        erasure whose thread later carries a threat, replayed by the open ticket with a fresh date_updated, minted a
        new escalation row on every ticket edit."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000071", "clickup:86x2"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                           "conversation_id": "215400000000071", "pages": [{"entity": "profile", "id": OTHER}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        conv = {"created_at": 1793000000, "conversation_id": "215400000000071",
                "parts": [{"at": 1793000000, "text": "please delete my data"},
                          {"at": 1793544280, "text": "or my attorney will write"}],
                "customer_text": "please delete my data\nor my attorney will write"}
        ticket = {"id": "86x2", "date_created": "1793000000000", "date_updated": "1793544280000",
                  "status": {"type": "open"}, "description": "---ACTION-REQUEST---\n"
                  '{"action_type":"data-deletion","customer_email":"","customer_profile_id":"","cs_session_id":"",'
                  '"conversation_summary":""}',
                  "custom_fields": [{"name": "Intercom Link",
                                     "value": "https://app.intercom.com/a/inbox/x/inbox/conversation/215400000000071"}],
                  "tags": [{"name": "action:data-deletion"}]}
        run.intake_clickup([ticket], conv_reader=lambda c: conv)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["class"], "legal_threat")
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")
        # the same event seen by the CONVERSATION replay must land on that same row, not on a second one
        run.merge_reply(s.get(rid), conv)
        self.assertEqual(len(s.all("open")), 1)
        self.assertEqual(s.all("open")[0]["received_at"], "2026-11-01T14:44:40Z")
        # a later ticket edit (new date_updated, same words) still opens nothing new
        ticket2 = {**ticket, "date_updated": "1793630680000"}
        run.intake_clickup([ticket2], conv_reader=lambda c: conv)
        self.assertEqual(len(s.all("open")), 1)

    def test_upsert_never_merges_into_a_confirmed_row(self):
        """QA 12th round, reproduced on store.upsert directly: the hourly tick re-ingests the open ClickUp ticket with
        the SAME keys, so a confirmed row used to absorb a newly supplied page while keeping `confirmed_at` — a page
        then reachable by a hide batch but skipped by the 30-day watchdog."""
        s = Store(":memory:")
        rid, how = s.upsert({"keys": ["intercom:215400000000031", "clickup:86x1"], "channel": "intercom",
                             "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                             "pages": [{"entity": "profile", "id": OTHER}]})
        self.assertEqual(how, "created")
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        rid2, how2 = s.upsert({"keys": ["intercom:215400000000031", "clickup:86x1"], "channel": "intercom",
                               "class": "privacy_erasure", "received_at": "2026-11-01T14:44:40Z",
                               "pages": [{"entity": "profile", "id": OTHER},
                                         {"entity": "profile", "id": ARPAD}]})
        self.assertEqual(how2, "created")
        self.assertNotEqual(rid2, rid)
        old, new = s.get(rid), s.get(rid2)
        self.assertTrue(old["confirmed_at"])
        self.assertEqual([p["id"] for p in old["pages"]], [OTHER])       # immutable
        # the new request carries what the customer asked for this time (the old page is re-stated, so it repeats;
        # it is already hidden, so the read-back marks it ALREADY_HIDDEN and it re-enters no batch)
        self.assertEqual([p["id"] for p in new["pages"]], [OTHER, ARPAD])
        self.assertEqual(new["due_at"][:10], "2026-12-01")
        # the same re-ingest twice does not make a third row
        _, how3 = s.upsert({"keys": ["intercom:215400000000031", "clickup:86x1"], "channel": "intercom",
                            "class": "privacy_erasure", "received_at": "2026-11-01T14:44:40Z",
                            "pages": [{"entity": "profile", "id": ARPAD}]})
        self.assertEqual(how3, "unchanged")
        self.assertEqual(len(s.all("open")), 1)

    def test_replaying_the_same_source_after_confirmation_opens_nothing(self):
        """QA 13th round: the hourly tick re-ingests the same unchanged ticket. After a written confirmation that
        replay must be a no-op, not a brand-new request for a customer we already answered."""
        s = Store(":memory:")
        cand = {"keys": ["clickup:86x9"], "channel": "support", "class": "privacy_erasure",
                "received_at": "2026-10-01T00:00:00Z", "pages": [{"entity": "profile", "id": OTHER}]}
        rid, how = s.upsert(cand)
        self.assertEqual(how, "created")
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        for _ in range(3):
            rid2, how2 = s.upsert(dict(cand))
            self.assertEqual((rid2, how2), (rid, "unchanged"))
        self.assertEqual(s.all("open"), [])
        # ...but a genuinely later ask does start a new, watched request
        _, how3 = s.upsert({**cand, "received_at": "2026-11-01T00:00:00Z",
                            "pages": [{"entity": "profile", "id": OTHER}]})
        self.assertEqual(how3, "created")
        self.assertEqual(len(s.all("open")), 1)

    def test_a_listed_but_unverified_hide_still_pages(self):
        """QA 13th round, Critical: ALREADY_HIDDEN means the id is in both config lists. If the deploy failed and the
        public page still answers 200, the hide-deadline alert must keep paging until the read-back passes."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        rid, _ = s.upsert({"keys": ["intercom:215400000000041"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-11-02T00:00:00Z",
                           "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "decide", identity_verdict="ALREADY_HIDDEN",
                 verdict_detail=[{"id": ARPAD, "verdict": "ALREADY_HIDDEN", "why": "both lists"}])
        run = Run(s, log=lambda *_: None)
        now = datetime(2026, 11, 4, tzinfo=timezone.utc)
        self.assertEqual(len(run.hide_due_rows(now)), 1)          # listed, but no read-back yet: still exposed
        self.assertIn("read-back pending", run.hide_due_rows(now)[0][1])
        s.update(rid, "hidden", hidden_at="2026-11-03T09:00:00Z")  # 410 + noindex confirmed
        self.assertEqual(run.hide_due_rows(now), [])

    def test_a_reply_after_the_confirmation_is_a_new_request_row(self):
        """QA 11th round: a confirmed row's 30-day watchdog skips it, so folding a new page into it would hide a page
        nobody watches. The reply becomes its own row, dated at the reply, with its own deadline."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000021"], "channel": "intercom", "class": "privacy_erasure",
                           "received_at": "2026-10-01T00:00:00Z", "pages": [{"entity": "profile", "id": OTHER}],
                           "conversation_id": "215400000000021"})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        conv = {"customer_text": "actually please also remove this one muso.ai/profile/" + ARPAD,
                "subject": "", "parts": [{"at": 1793544280, "text": "please also remove " + ARPAD}]}
        run.merge_reply(s.get(rid), conv)
        old = s.get(rid)
        self.assertEqual([p["id"] for p in old["pages"]], [OTHER])       # the confirmed row did not change
        self.assertTrue(old["confirmed_at"])
        new = [r for r in s.all("open") if r["id"] != rid]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0]["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual([p["id"] for p in new[0]["pages"]], [ARPAD])
        self.assertNotEqual(new[0]["due_at"], old["due_at"])
        # idempotent: the same reply twice does not make a second row
        run.merge_reply(s.get(rid), conv)
        self.assertEqual(len([r for r in s.all("open") if r["id"] != rid]), 1)

    def test_a_ticket_with_no_conversation_is_not_a_trusted_sender(self):
        """QA 11th round: a ClickUp ticket without a conversation is `support` by construction and its `customer_email`
        is requester-typed metadata, so it can never carry path D on the page's own domain (it asks instead)."""
        from gdpr_pipeline.run import Run
        task = {"id": "86d1", "name": "remove my profile", "status": {"status": "in progress"},
                "date_created": "1793400000000", "tags": [{"name": "action:data-deletion"}],
                "description": "profile muso.ai/profile/" + ARPAD +
                '\n---ACTION-REQUEST---{"action_type": "data-deletion", '
                '"customer_email": "legal@biglabel.com"}---END-ACTION-REQUEST---'}
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        page_ = identity.Page(ARPAD, "profile", found=True, name="Big Label Artist", website="https://biglabel.com",
                              popularity=1, credit_count=1)
        with mock.patch.object(sources, "profile_doc", lambda pid: {
                "name": "Big Label Artist", "isClaimed": False, "popularity": 1, "creditCount": 1,
                "links": {"website": "https://biglabel.com"}}), \
             mock.patch.object(sources, "public_status", lambda *a: 200), \
             mock.patch.object(sources, "processed_claims", lambda ids: {p: set() for p in ids}), \
             mock.patch.object(sources, "resolve_account", lambda *a: (None, "")), \
             mock.patch.object(sources, "clickup_tasks", lambda a: [task]):
            run.intake_clickup([task], conv_reader=lambda c: {})
            run.decide_all(set(), stale_hours=0)
        row = s.all("open")[0]
        self.assertFalse(any(pv["verdict"] == "PASS_D" for pv in row["verdict_detail"]))
        self.assertEqual(row["identity_verdict"], "ASK_IDENTITY")
        self.assertTrue(any("not verified" in pv["why"] for pv in row["verdict_detail"]))

    def test_prefix_collision_in_catalog_stays_unknown(self):
        """QA 16th round: a locally known full ID does not prove an 8-char prefix is unique in the catalog. The
        resolver must verify against the catalog and leave ambiguous prefixes unresolved (UNKNOWN), never pick the
        one id this store happens to hold and attribute a request (and a hide) to the wrong page."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        prefix = "abcd1234"
        rid, _ = s.upsert({"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                           "received_at": "2026-11-01T00:00:00Z", "pages": [{"entity": "profile", "id": prefix}]})
        # the catalog holds two profiles under this prefix: resolve_prefixes leaves it out, so nothing may be resolved
        with mock.patch.object(sources, "profile_doc", lambda pid: {"name": "Some Name", "isClaimed": False,
                                                                    "popularity": 1, "creditCount": 1}), \
             mock.patch.object(sources, "public_status", lambda *a: 200), \
             mock.patch.object(sources, "processed_claims", lambda ids: {p: set() for p in ids}), \
             mock.patch.object(sources, "resolve_account", lambda *a: (None, "")), \
             mock.patch.object(sources, "clickup_tasks", lambda a: []):
            run.decide_all(set(), stale_hours=0, prefix_resolver=lambda prefixes: {})
        row = s.all("open")[0]
        self.assertEqual(row["identity_verdict"], "UNKNOWN")
        self.assertTrue(any("8-char id prefix" in pv["why"] for pv in row["verdict_detail"]))

    def test_a_reply_that_escalates_the_class_is_merged(self):
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:1"], "channel": "intercom", "class": "privacy_erasure",
                           "received_at": "2026-11-01T00:00:00Z", "pages": []})
        run.merge_reply(s.get(rid), {"customer_text": "delete it or my attorney will write", "subject": ""})
        self.assertEqual(s.get(rid)["class"], "legal_threat")

    def test_a_sitemap_200_that_is_not_a_sitemap_fails_the_check(self):
        from gdpr_pipeline import checks

        def fetch_html(url, timeout=60):
            return 200, {}, b"<html>temporary error</html>"

        with self.assertRaises(checks.Unknown):
            checks.sitemap_absent([ARPAD], fetch=fetch_html)

        def fetch_empty(url, timeout=60):
            return 200, {}, b""

        with self.assertRaises(checks.Unknown):
            checks.sitemap_absent([ARPAD], fetch=fetch_empty)

        def fetch_index_no_locs(url, timeout=60):
            return 200, {}, b"<?xml version=\"1.0\"?><sitemapindex></sitemapindex>"

        with self.assertRaises(checks.Unknown):
            checks.sitemap_absent([ARPAD], fetch=fetch_index_no_locs)

        def fetch_ok(url, timeout=60):
            if url.endswith("sitemap.xml"):
                return 200, {}, b"<sitemapindex><loc>https://muso.ai/sitemap-1.xml</loc></sitemapindex>"
            return 200, {}, b"<urlset><url><loc>https://muso.ai/profile/other</loc></url></urlset>"

        self.assertEqual(checks.sitemap_absent([ARPAD], fetch=fetch_ok), {ARPAD: True})


class HideDueDeadline(unittest.TestCase):
    """QA 8th round: `hide_due_at` (received + 24 h) was recorded but nothing on the scheduled path acted on it, so a
    PASS request could wait three weeks for the 30-day warning with no alert."""

    def _row(self, **kw):
        base = {"id": 1, "register_no": 7, "status": "open", "class": "privacy_erasure", "channel": "intercom",
                "received_at": "2026-11-02T00:00:00Z", "hide_due_at": "2026-11-03T00:00:00Z",
                "due_at": "2026-12-02T00:00:00Z", "confirmed_at": "", "hidden_at": "", "ask_sent_at": "",
                "identity_verdict": "PASS_C", "action": "",
                "verdict_detail": [{"id": ARPAD, "verdict": "PASS_C", "why": "C"}]}
        base.update(kw)
        return base

    def test_a_pass_row_past_its_24_hours_is_flagged(self):
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        now = datetime(2026, 11, 4, tzinfo=timezone.utc)
        s.db.execute("INSERT INTO erasure_requests(register_no,row_key,channel,class,received_at,due_at,"
                     "hide_due_at,created_at,updated_at) VALUES(7,'intercom:1','intercom','privacy_erasure',"
                     "'2026-11-02T00:00:00Z','2026-12-02T00:00:00Z','2026-11-03T00:00:00Z',"
                     "'2026-11-02T00:00:00Z','2026-11-02T00:00:00Z')")
        s.db.execute("UPDATE erasure_requests SET identity_verdict='PASS_C', verdict_detail=? WHERE register_no=7",
                     (json.dumps([{"id": ARPAD, "verdict": "PASS_C", "why": "C"}]),))
        s.db.commit()
        rows = run.hide_due_rows(now)
        self.assertEqual([reg for reg, _ in rows], [7])
        self.assertIn("24-hour HIDE", rows[0][1])
        # still open the day before the deadline: nothing to page
        self.assertEqual(run.hide_due_rows(datetime(2026, 11, 2, 12, tzinfo=timezone.utc)), [])
        # a hidden page, a GONE page, or a row with no PASS page is never this alert
        s.db.execute("UPDATE erasure_requests SET hidden_at='2026-11-03T09:00:00Z' WHERE register_no=7"); s.db.commit()
        self.assertEqual(run.hide_due_rows(now), [])

    def test_a_legal_hide_first_row_pages_on_the_real_tick_path(self):
        import importlib.util
        import tempfile
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "gdp_entry9", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        entry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entry)
        s = Store(":memory:")
        s.db.execute("INSERT INTO erasure_requests(register_no,row_key,channel,class,received_at,due_at,"
                     "hide_due_at,created_at,updated_at,identity_verdict,verdict_detail) VALUES(9,'intercom:9',"
                     "'intercom','legal_threat','2026-11-02T00:00:00Z','2026-12-02T00:00:00Z',"
                     "'2026-11-03T00:00:00Z','2026-11-02T00:00:00Z','2026-11-02T00:00:00Z','LEGAL_HIDE_FIRST',?)",
                     (json.dumps([{"id": ARPAD, "verdict": "LEGAL_HIDE_FIRST", "why": "legal"}]),))
        s.db.commit()
        run = Run(s, log=lambda *_: None)
        self.assertEqual(len(run.hide_due_rows(datetime(2026, 11, 4, tzinfo=timezone.utc), include_legal=True)), 1)
        r = mock.Mock()
        r.store.path = os.path.join(tempfile.mkdtemp(), "erasure.sqlite")
        r.errors = []
        r.watchdog_rows.return_value = []
        r.hide_due_rows.side_effect = lambda now, include_legal=False: (
            run.hide_due_rows(now, include_legal=include_legal))
        posts = []
        with mock.patch.object(entry, "slack_post", lambda c: posts.append(c) or True), \
                mock.patch.object(entry, "datetime", wraps=datetime) as dt:
            dt.now.return_value = datetime(2026, 11, 4, tzinfo=timezone.utc)
            entry.watchdog(r, page=True)
        self.assertEqual(len(posts), 1)
        self.assertIn("#9", posts[0])
        self.assertIn("HIDE deadline", posts[0])

    def test_the_tick_pages_the_hide_deadline_and_marks_it_paged(self):
        import importlib.util
        import tempfile
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "gdp_entry8", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        entry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(entry)
        r = mock.Mock()
        r.store.path = os.path.join(tempfile.mkdtemp(), "erasure.sqlite")
        r.errors = []
        r.watchdog_rows.return_value = []
        r.hide_due_rows.return_value = [(7, "#7 intercom: the 24-hour HIDE deadline passed")]
        posts = []
        with mock.patch.object(entry, "slack_post", lambda c: posts.append(c) or True):
            entry.watchdog(r, page=True)
        self.assertEqual(len(posts), 1)
        self.assertIn("HIDE deadline", posts[0])
        self.assertIn("#7", posts[0])
        # a second tick the same day does not repeat it
        with mock.patch.object(entry, "slack_post", lambda c: posts.append(c) or True):
            entry.watchdog(r, page=True)
        self.assertEqual(len(posts), 1)


class OldThreadAndFiveHundreds(unittest.TestCase):
    def test_a_reply_on_an_old_thread_dates_the_request_at_the_reply(self):
        from gdpr_pipeline.run import Run, conversation_request_at
        conv = {"conversation_id": "215400000000001", "created_at": 1790000000,       # 2026-09-2x
                "subject": "Re: my account", "author_name": "A P", "author_email": "a@pm.me",
                "customer_text": "hi\nplease delete my data",
                "parts": [{"at": 1790000000, "text": "hi"},
                          {"at": 1793544280, "text": "please delete my data"}]}   # 2026-11-01
        self.assertEqual(conversation_request_at(conv, "privacy_erasure"), 1793544280)
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        from gdpr_pipeline import sources
        from unittest import mock
        with mock.patch.object(sources, "search_conversations", lambda since: ["215400000000001"]):
            self.assertTrue(run.intake_intercom(0, conv_reader=lambda c: conv))
        row = s.all("open")[0]
        # the reply's date, NOT the thread's: due 2026-12-01, so it is not born overdue
        self.assertEqual(row["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual(row["due_at"][:10], "2026-12-01")

    def test_an_OLD_ticket_about_an_old_thread_takes_the_reply_date(self):
        """QA 7th round: the ticket itself is older than the reply and does NOT carry the request ("customer asked
        about their account"), so the reply is the only evidence and the deadline must not be October."""
        from gdpr_pipeline.run import Run
        conv = {"conversation_id": "215400000000003", "created_at": 1790000000,
                "subject": "", "author_name": "A P", "author_email": "a@pm.me",
                "customer_text": "hi\nplease delete my data",
                "parts": [{"at": 1790000000, "text": "hi"},
                          {"at": 1793544280, "text": "please delete my data"}]}
        task = {"id": "86c2", "name": "account question", "status": {"status": "in progress"},
                "date_created": "1788000000000",                       # 2026-08-29, BEFORE the reply
                "tags": [{"name": "action:data-deletion"}],
                "description": "customer asked about their account\n"
                               "https://app.intercom.com/a/inbox/x/conversation/215400000000003"}
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        run.intake_clickup([task], conv_reader=lambda c: conv)
        row = s.all("open")[0]
        self.assertEqual(row["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual(row["due_at"][:10], "2026-12-01")

    def test_a_ticket_that_itself_asks_keeps_its_earlier_date(self):
        # ...but when the ticket's own words ask for the erasure, the earlier date stands: that is when we were told
        from gdpr_pipeline.run import Run
        conv = {"conversation_id": "215400000000004", "created_at": 1790000000, "subject": "",
                "author_name": "A P", "author_email": "a@pm.me",
                "customer_text": "hi", "parts": [{"at": 1790000000, "text": "hi"}]}
        task = {"id": "86c3", "name": "please delete my data", "status": {"status": "in progress"},
                "date_created": "1788000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "https://app.intercom.com/a/inbox/x/conversation/215400000000004"}
        s = Store(":memory:")
        Run(s, log=lambda *_: None).intake_clickup([task], conv_reader=lambda c: conv)
        self.assertEqual(s.all("open")[0]["received_at"][:10], "2026-08-29")

    def test_a_ticket_on_an_old_thread_is_dated_at_the_reply_too(self):
        from gdpr_pipeline.run import Run
        conv = {"conversation_id": "215400000000002", "created_at": 1790000000,      # 2026-09-2x
                "subject": "", "author_name": "A P", "author_email": "a@pm.me",
                "customer_text": "hi\nplease delete my data",
                "parts": [{"at": 1790000000, "text": "hi"},
                          {"at": 1793544280, "text": "please delete my data"}]}
        task = {"id": "86c1", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1793600000000", "tags": [{"name": "action:data-deletion"}],   # 2026-11-02
                "description": "customer asked in Intercom\n"
                               "https://app.intercom.com/a/inbox/x/conversation/215400000000002"}
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        run.intake_clickup([task], conv_reader=lambda c: conv)
        row = s.all("open")[0]
        self.assertEqual(row["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual(row["due_at"][:10], "2026-12-01")

    def test_a_legal_threat_reply_dates_an_erasure_ticket_too(self):
        # the ticket says "privacy", the customer's reply alone classifies as a legal threat: still the reply's date
        from gdpr_pipeline.run import conversation_request_at
        conv = {"created_at": 1790000000, "parts": [
            {"at": 1790000000, "text": "hi"},
            {"at": 1793544280, "text": "delete my data or my attorney will be in touch"}]}
        self.assertEqual(conversation_request_at(conv, "privacy_erasure"), 1793544280)

    def test_ticket_first_replay_after_confirmation_is_dated_at_the_reply(self):
        """QA 17th round, end to end through the ticket path: the ClickUp ticket stays open after we send the written
        confirmation, so every hourly tick replays the WHOLE conversation. Before this fix the replay opened a new
        request dated at the original erasure message with the already-confirmed page attached -- an already-expired
        deadline and a hidden page back in a hide batch. It must instead be dated at the post-confirmation reply and
        carry only the page that reply introduced."""
        from gdpr_pipeline.run import Run
        conv_before = {"conversation_id": "215400000000061", "created_at": 1790000000, "subject": "",
                       "author_name": "A P", "author_email": "a@pm.me",
                       "customer_text": "hi\nplease delete my data muso.ai/profile/" + ARPAD,
                       "parts": [{"at": 1790000000, "text": "hi"},
                                 {"at": 1790000500, "text": "please delete my data muso.ai/profile/" + ARPAD}]}
        conv_after = dict(conv_before,
                          customer_text=conv_before["customer_text"] + "\nalso muso.ai/profile/" + OTHER,
                          parts=conv_before["parts"] + [{"at": 1793544280, "text": "also muso.ai/profile/" + OTHER}])
        task = {"id": "86c9", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1790000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "customer asked in Intercom\n"
                               "https://app.intercom.com/a/inbox/x/conversation/215400000000061"}
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        run.intake_clickup([task], conv_reader=lambda c: conv_before)
        first = s.all("open")[0]
        self.assertEqual([p["id"] for p in first["pages"]], [ARPAD])
        s.update(first["id"], "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        # a tick with nothing new must open NOTHING
        run.intake_clickup([task], conv_reader=lambda c: conv_before)
        self.assertEqual(s.all("open"), [])
        # the post-confirmation reply opens one request: the reply's date, only the page it introduced
        run.intake_clickup([task], conv_reader=lambda c: conv_after)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [OTHER])
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual(rows[0]["due_at"][:10], "2026-12-01")
        # and replaying THAT tick again changes nothing
        run.intake_clickup([task], conv_reader=lambda c: conv_after)
        self.assertEqual(len(s.all("open")), 1)

    def test_an_unrelated_reply_after_the_new_page_does_not_duplicate_it(self):
        """QA 18th round: confirmed A, then a reply asks for B (its own row at the reply's date). The ticket stays open,
        so a later unrelated reply ("thanks") replays the whole thread. It must open NO third row for B, and must not
        move B's deadline to the later message: a new request is dated at the message that INTRODUCED its page."""
        from gdpr_pipeline.run import Run
        conv_a = {"conversation_id": "215400000000071", "created_at": 1790000000, "subject": "",
                  "author_name": "A P", "author_email": "a@pm.me",
                  "customer_text": "please delete muso.ai/profile/" + ARPAD,
                  "parts": [{"at": 1790000500, "text": "please delete muso.ai/profile/" + ARPAD}]}
        conv_b = dict(conv_a, customer_text=conv_a["customer_text"] + "\nand muso.ai/profile/" + OTHER,
                      parts=conv_a["parts"] + [{"at": 1793544280, "text": "and muso.ai/profile/" + OTHER}])
        conv_thanks = dict(conv_b, customer_text=conv_b["customer_text"] + "\nthanks!",
                           parts=conv_b["parts"] + [{"at": 1793630680, "text": "thanks!"}])
        task = {"id": "86d1", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1790000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "https://app.intercom.com/a/inbox/x/conversation/215400000000071"}
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        run.intake_clickup([task], conv_reader=lambda c: conv_a)
        s.update(s.all("open")[0]["id"], "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run.intake_clickup([task], conv_reader=lambda c: conv_b)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [OTHER])
        b_at, b_due = rows[0]["received_at"], rows[0]["due_at"]
        run.intake_clickup([task], conv_reader=lambda c: conv_thanks)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)                       # no third row for B
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [OTHER])
        self.assertEqual((rows[0]["received_at"], rows[0]["due_at"]), (b_at, b_due))   # deadline not moved
        # ...and the same replay did not mint an :again: row off the unconfirmed B row either
        self.assertEqual(len(s.all()), 2)

    def test_one_customer_event_under_two_confirmed_parents_opens_one_request(self):
        """A register row and the mail thread it was reconciled from are two rows for one request, and both can be
        confirmed. A single follow-up then arrives through both parents, so `<parent>:again:<at>` differs and the same
        customer event opened two requests -- two deadlines, two watchdogs, two confirmations. The event is keyed on
        one SOURCE (conversation / mail thread), whichever parent happened to see it first."""
        s = Store(":memory:")
        ev = {"received_at": "2026-11-01T10:00:00Z", "conversation_id": "215476650399999"}
        a, _ = s.upsert({"keys": ["register:19"], "channel": "register", "class": "privacy_erasure",
                         "received_at": "2026-09-01T00:00:00Z", "pages": [{"entity": "profile", "id": ARPAD}]})
        b, _ = s.upsert({"keys": ["intercom:215476650399999"], "channel": "intercom", "class": "privacy_erasure",
                         "received_at": "2026-09-02T00:00:00Z", "conversation_id": "215476650399999",
                         "pages": [{"entity": "profile", "id": ARPAD}]})
        self.assertNotEqual(a, b)
        for rid in (a, b):
            s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        first, how1 = s.upsert({**ev, "keys": ["register:19"], "channel": "register",
                                "class": "privacy_erasure"})
        self.assertEqual(how1, "created")
        second, how2 = s.upsert({**ev, "keys": ["intercom:215476650399999"], "channel": "intercom",
                                 "class": "privacy_erasure"})
        self.assertEqual(second, first, "the same event through the other parent must land on ONE request")
        self.assertNotEqual(how2, "created")
        self.assertEqual(len(s.all("open")), 1)

    def test_one_mail_event_through_two_keys_of_one_row_opens_one_request(self):
        """The mail twin of the rule above, and the shape the live register actually had: a markdown-register row and
        the legal@ thread it was reconciled from are ONE row carrying both keys, so the follow-up arrives twice — once
        through `register:19`, once through `gmail:legal@muso.ai:<thread>`. The new request is keyed on the CONFIRMED
        row's own canonical key, never on whichever key the caller passed first, so both arrivals land on one row.
        (The live store still carries a `register:19:again:<at>` / `gmail:…:again:<at>` pair from a tick that predated
        this rule; it is reconciled by hand, not by the code.)"""
        s = Store(":memory:")
        T = "1a0cd8b4b062d803"
        rid, _ = s.upsert({"keys": ["register:19", f"gmail:legal@muso.ai:{T}"], "channel": "legal",
                           "class": "privacy_erasure", "received_at": "2026-09-23T00:00:00Z",
                           "gmail_thread": T, "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-23T00:00:00Z", status="closed")
        ev = {"received_at": "2026-09-23T09:14:00Z", "gmail_thread": T, "channel": "legal",
              "class": "privacy_erasure", "pages": [{"entity": "profile", "id": ARPAD}]}
        first, how1 = s.upsert({**ev, "keys": [f"gmail:legal@muso.ai:{T}"]})
        self.assertEqual(how1, "created")
        second, how2 = s.upsert({**ev, "keys": ["register:19"]})
        self.assertEqual(second, first, "the same mail event through the other key must land on ONE request")
        self.assertNotEqual(how2, "created")
        self.assertEqual(len(s.all("open")), 1)
        self.assertEqual(s.get(first)["row_key"], "register:19:again:2026-09-23T09:14:00Z",
                         "the new request is keyed on the CONFIRMED row's own key, whichever key arrived first")

    def test_dedupe_finds_and_closes_one_event_opened_under_two_keys(self):
        """The artifact the live register carries: one customer event, two post-confirmation rows (`register:19:again:<at>`
        and `gmail:legal@…:again:<at>`), so two deadlines and two watchdogs for one message. `dedupe` reports the pair
        and, with --apply, points the duplicate's keys at the row it keeps and closes it as `duplicate`."""
        s = Store(":memory:")
        T = "1a0cd8b4b062d803"
        a, _ = s.upsert({"keys": ["register:19:again:2026-09-23T09:14:00Z"], "channel": "legal",
                         "class": "privacy_erasure", "received_at": "2026-09-23T09:14:00Z", "gmail_thread": T,
                         "pages": [{"entity": "profile", "id": ARPAD}]})
        # current code cannot mint the second spelling (the canonical-key + source-reuse rule landed in the 23rd
        # round), so the legacy row is written the way the live register got it: same stamp, same source, own key.
        b = s.db.execute(
            "INSERT INTO erasure_requests(register_no,row_key,channel,class,received_at,due_at,hide_due_at,"
            "gmail_thread,pages,note,status,created_at,updated_at) "
            "VALUES (242,?,?,?,?,?,?,?,?,'customer wrote again after the written confirmation','open',?,?)",
            (f"gmail:legal@muso.ai:{T}:again:2026-09-23T09:14:00Z", "legal", "privacy_erasure",
             "2026-09-23T09:14:00Z", "2026-10-23T09:14:00Z", "2026-09-24T09:14:00Z", T,
             json.dumps([{"entity": "profile", "id": ARPAD}]), "2026-11-03T00:41:51Z", "2026-11-03T00:41:51Z")
        ).lastrowid
        s.db.execute("INSERT INTO erasure_keys(key, request_id) VALUES (?,?)",
                     (f"gmail:legal@muso.ai:{T}:again:2026-09-23T09:14:00Z", b))
        s.db.commit()
        pairs = s.duplicate_events()
        self.assertEqual([(k["id"], d["id"]) for k, d in pairs], [(a, b)])
        s.merge_duplicate(pairs[0][0], pairs[0][1])
        self.assertEqual([r["id"] for r in s.all("open")], [a])
        self.assertEqual(s.get(b)["status"], "duplicate")
        self.assertEqual(s.by_key(f"gmail:legal@muso.ai:{T}:again:2026-09-23T09:14:00Z")["id"], a)
        self.assertIn("duplicate of request", s.get(b)["note"])
        self.assertEqual(s.duplicate_events(), [], "the pair is gone once reconciled, so a second run is a no-op")

    def test_a_post_confirmation_request_is_classified_from_its_own_messages(self):
        """QA 23rd round: the whole thread was classified, so a legal threat written BEFORE the written confirmation
        travelled onto a later, plainly-worded request for an unrelated page. A legal threat is the ONE class that
        hides before identity (10-23), so `hide-batch --include-legal` could have prepared a hide for the wrong
        person. A post-confirmation request is classified from the messages that came after the confirmation."""
        from gdpr_pipeline.run import Run
        threat = "delete muso.ai/profile/" + ARPAD + " or my attorney will write"
        conv_a = {"conversation_id": "215400000000090", "created_at": 1790000000, "subject": "",
                  "author_name": "A P", "author_email": "a@pm.me", "customer_text": threat,
                  "parts": [{"at": 1790000500, "text": threat}]}
        plain_b = "and please remove muso.ai/profile/" + OTHER
        conv_b = dict(conv_a, customer_text=threat + "\n" + plain_b,
                      parts=conv_a["parts"] + [{"at": 1793544280, "text": plain_b}])
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000090"], "channel": "intercom", "class": "legal_threat",
                           "received_at": "2026-09-20T00:00:00Z", "conversation_id": "215400000000090",
                           "requester_name": "A P", "requester_email": "a@pm.me",
                           "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run.merge_reply(s.get(rid), conv_b)
        rows = s.all("open")
        self.assertEqual(len(rows), 1, "the plain follow-up opens exactly one new request")
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [OTHER])
        self.assertEqual(rows[0]["class"], "privacy_erasure",
                         "the pre-confirmation threat must not classify the new request")
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")   # dated at ITS message, not the threat
        # ...and the same through the ClickUp replay path, which classifies the whole thread too
        task = {"id": "86d9", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1790000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "https://app.intercom.com/a/inbox/x/conversation/215400000000091"}
        s2 = Store(":memory:")
        run2 = Run(s2, log=lambda *_: None)
        conv2 = dict(conv_a, conversation_id="215400000000091")
        run2.intake_clickup([task], conv_reader=lambda c: conv2)
        s2.update(s2.all("open")[0]["id"], "confirmed", confirmed_at="2026-10-20", status="closed")
        run2.intake_clickup([task], conv_reader=lambda c: dict(conv_b, conversation_id="215400000000091"))
        rows2 = s2.all("open")
        self.assertEqual(len(rows2), 1)
        self.assertEqual(rows2[0]["class"], "privacy_erasure")
        self.assertEqual([p["id"] for p in rows2[0]["pages"]], [OTHER])
        self.assertEqual(rows2[0]["received_at"], "2026-11-01T14:44:40Z")

    def test_a_threat_about_an_answered_page_does_not_classify_a_later_request(self):
        """QA 24th round: the WHOLE post-confirmation span was classified, so a threat about the ALREADY-ANSWERED page
        followed by a plain request for an unrelated page made the second one a legal-threat (hide-first) row.
        Three messages: erasure ask, confirmation, threat about A, plain request for B -> B is privacy_erasure."""
        from gdpr_pipeline.run import Run
        ask = "please delete muso.ai/profile/" + ARPAD
        threat_a = "muso.ai/profile/" + ARPAD + " or my attorney will write"
        plain_b = "and please remove muso.ai/profile/" + OTHER
        conv = {"conversation_id": "215400000000093", "created_at": 1790000000, "subject": "",
                "author_name": "A P", "author_email": "a@pm.me",
                "customer_text": ask + "\n" + threat_a + "\n" + plain_b,
                "parts": [{"at": 1790000500, "text": ask}, {"at": 1793544280, "text": threat_a},
                          {"at": 1793630680, "text": plain_b}]}
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000093"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-09-20T00:00:00Z",
                           "conversation_id": "215400000000093", "requester_name": "A P",
                           "requester_email": "a@pm.me", "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        # the threat about A opens its own pure-escalation request (that part is right and stays)
        run.merge_reply(s.get(rid), dict(conv, parts=conv["parts"][:2],
                                        customer_text=ask + "\n" + threat_a))
        esc = [r for r in s.all("open") if r["class"] == "legal_threat"]
        self.assertEqual(len(esc), 1)
        self.assertEqual(esc[0]["received_at"], "2026-11-01T14:44:40Z")
        # ...and the plain request for B that FOLLOWS it must not inherit that threat
        run.merge_reply(s.get(rid), conv)
        rows = [r for r in s.all("open") if any(p["id"] == OTHER for p in r["pages"])]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["class"], "privacy_erasure")
        self.assertEqual(rows[0]["received_at"], "2026-11-02T14:44:40Z")
        # the ClickUp replay of the same three messages agrees
        task = {"id": "86da", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1790000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "https://app.intercom.com/a/inbox/x/conversation/215400000000094"}
        s2 = Store(":memory:")
        run2 = Run(s2, log=lambda *_: None)
        conv2 = dict(conv, conversation_id="215400000000094", parts=conv["parts"][:1],
                     customer_text=ask)
        run2.intake_clickup([task], conv_reader=lambda c: conv2)
        s2.update(s2.all("open")[0]["id"], "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run2.intake_clickup([task], conv_reader=lambda c: dict(
            conv, conversation_id="215400000000094",
            customer_text=ask + "\n" + threat_a + "\n" + plain_b))
        b_rows2 = [r for r in s2.all("open") if any(p["id"] == OTHER for p in r["pages"])]
        self.assertEqual(len(b_rows2), 1)
        self.assertEqual(b_rows2[0]["class"], "privacy_erasure")

    def test_a_repeat_ask_for_an_answered_page_opens_a_new_request(self):
        """QA 25th round: a fresh ask for a page we already hid (the page came back, the hide was reverted) was
        DROPPED — the page was already known, so `new_pages` was empty and the unchanged class returned early: the
        customer kept a written confirmation, the page stayed live, and no watchdog was ever watching it again.
        Both entrypoints must open a new request dated at the repeat ask, and stay idempotent on replay."""
        from gdpr_pipeline.run import Run
        ask = "please delete muso.ai/profile/" + ARPAD
        again = "please delete muso.ai/profile/" + ARPAD + " again, it is still up"
        conv = {"conversation_id": "215400000000095", "created_at": 1790000000, "subject": "",
                "author_name": "A P", "author_email": "a@pm.me", "customer_text": ask,
                "parts": [{"at": 1790000500, "text": ask}]}
        later = dict(conv, customer_text=ask + "\n" + again,
                     parts=conv["parts"] + [{"at": 1793544280, "text": again}])
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000095"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-09-20T00:00:00Z",
                           "conversation_id": "215400000000095", "requester_name": "A P",
                           "requester_email": "a@pm.me", "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run.merge_reply(s.get(rid), later)
        rows = s.all("open")
        self.assertEqual(len(rows), 1, "a repeat ask is a new request, not a replay")
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [ARPAD])
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")   # dated at the repeat ask
        self.assertEqual(rows[0]["due_at"][:10], "2026-12-01")
        run.merge_reply(s.get(rid), later)                                  # replaying the thread again: no duplicate
        self.assertEqual(len(s.all("open")), 1)
        # QA 26th round: the FIRST repeat gets confirmed too, then the customer asks a THIRD time. The page is still a
        # page we answered, so without tracking which messages already own a row the scan would return the FIRST
        # repeat's message again and the third ask would land on that closed row: no deadline, no watchdog, again.
        s.update(s.all("open")[0]["id"], "confirmed", confirmed_at="2026-11-02T00:00:00Z", status="closed")
        third = "it is still live, please delete muso.ai/profile/" + ARPAD + " now"
        conv3 = dict(later, customer_text=later["customer_text"] + "\n" + third,
                     parts=later["parts"] + [{"at": 1793720000, "text": third}])
        run.merge_reply(s.get(rid), conv3)
        rows = s.all("open")
        self.assertEqual(len(rows), 1, "the third ask is another NEW request")
        self.assertEqual(rows[0]["received_at"], "2026-11-03T15:33:20Z")
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [ARPAD])
        run.merge_reply(s.get(rid), conv3)                                  # and replaying still adds nothing
        self.assertEqual(len(s.all("open")), 1)
        # QA 27th round: the third ask is a THREAT. Its class must come from ITS message, not from the earlier plain
        # repeat that also names A — otherwise the hide-first exception (10-23) silently never applies to it.
        s.update(s.all("open")[0]["id"], "confirmed", confirmed_at="2026-11-04T00:00:00Z", status="closed")
        threat = "muso.ai/profile/" + ARPAD + " is still up, my attorney will write"
        conv4 = dict(conv3, customer_text=conv3["customer_text"] + "\n" + threat,
                     parts=conv3["parts"] + [{"at": 1793830000, "text": threat}])
        run.merge_reply(s.get(rid), conv4)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["class"], "legal_threat", "the threat is its own message's class")
        self.assertEqual(rows[0]["received_at"], "2026-11-04T22:06:40Z")
        # ...and the ClickUp replay path behaves the same
        task = {"id": "86db", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1790000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "https://app.intercom.com/a/inbox/x/conversation/215400000000096"}
        s2 = Store(":memory:")
        run2 = Run(s2, log=lambda *_: None)
        run2.intake_clickup([task], conv_reader=lambda c: dict(conv, conversation_id="215400000000096"))
        s2.update(s2.all("open")[0]["id"], "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run2.intake_clickup([task], conv_reader=lambda c: dict(later, conversation_id="215400000000096"))
        rows2 = s2.all("open")
        self.assertEqual(len(rows2), 1)
        self.assertEqual(rows2[0]["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual([p["id"] for p in rows2[0]["pages"]], [ARPAD])
        run2.intake_clickup([task], conv_reader=lambda c: dict(later, conversation_id="215400000000096"))
        self.assertEqual(len(s2.all("open")), 1)

    def test_a_repeat_and_a_new_page_in_one_message_keep_both_pages(self):
        """QA 28th round: "delete A again and also B" after A was confirmed dropped A — the repeat branch only fired
        when there was NO new page — so A got no new due date, no hide batch and no watchdog despite the renewed
        request. Both pages belong to the one new request. A page that an OPEN (unconfirmed) request introduced is
        still not re-registered, which is what the QA 14th round test pins."""
        from gdpr_pipeline.run import Run
        ask = "please delete muso.ai/profile/" + ARPAD
        mixed = "please delete muso.ai/profile/" + ARPAD + " again and also muso.ai/profile/" + OTHER
        conv = {"conversation_id": "215400000000097", "created_at": 1790000000, "subject": "",
                "author_name": "A P", "author_email": "a@pm.me", "customer_text": ask,
                "parts": [{"at": 1790000500, "text": ask}]}
        later = dict(conv, customer_text=ask + "\n" + mixed,
                     parts=conv["parts"] + [{"at": 1793544280, "text": mixed}])
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000097"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-09-20T00:00:00Z",
                           "conversation_id": "215400000000097", "requester_name": "A P",
                           "requester_email": "a@pm.me", "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run.merge_reply(s.get(rid), later)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual(sorted(p["id"] for p in rows[0]["pages"]), sorted([ARPAD, OTHER]))
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")
        run.merge_reply(s.get(rid), later)                    # replaying the thread opens nothing new
        self.assertEqual(len(s.all("open")), 1)
        # the ClickUp replay of the same conversation agrees
        task = {"id": "86dc", "name": "data deletion request", "status": {"status": "in progress"},
                "date_created": "1790000000000", "tags": [{"name": "action:data-deletion"}],
                "description": "https://app.intercom.com/a/inbox/x/conversation/215400000000098"}
        s2 = Store(":memory:")
        run2 = Run(s2, log=lambda *_: None)
        run2.intake_clickup([task], conv_reader=lambda c: dict(conv, conversation_id="215400000000098"))
        s2.update(s2.all("open")[0]["id"], "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run2.intake_clickup([task], conv_reader=lambda c: dict(later, conversation_id="215400000000098"))
        rows2 = s2.all("open")
        self.assertEqual(len(rows2), 1)
        self.assertEqual(sorted(p["id"] for p in rows2[0]["pages"]), sorted([ARPAD, OTHER]))
        self.assertEqual(rows2[0]["received_at"], "2026-11-01T14:44:40Z")

    def test_a_mixed_row_reads_back_its_eligible_pages(self):
        """QA 31st round: a request with a PASS page AND an ASK_IDENTITY page served the PASS page 410 + noindex, but an
        all-pages length guard skipped the read-back forever: `hidden_at` stayed empty and the 24-hour hide watchdog
        paged daily about a page that was already down. The read-back is per ELIGIBLE page now, the ASK page stays
        unresolved, and the letter still waits for the whole row."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        PASS_ID, ASK_ID = OTHER, ARPAD
        rid, _ = s.upsert({"keys": ["intercom:215400000000616"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-11-01T00:00:00Z",
                           "conversation_id": "215400000000616",
                           "pages": [{"entity": "profile", "id": PASS_ID}, {"entity": "profile", "id": ASK_ID}]})
        s.update(rid, "decide", identity_verdict="PASS_A", identity_basis="claim", decided_at="2026-11-01T00:00:00Z",
                 verdict_detail=[{"id": PASS_ID, "verdict": "PASS_A", "why": "claim"},
                                 {"id": ASK_ID, "verdict": "ASK_IDENTITY", "why": "name mismatch"}])
        seen, down = [], {PASS_ID}         # the hidden page answers 410 + noindex; the ASK page is untouched

        def checker(entity, pid):
            seen.append(pid)
            return pid in down

        run.mark_hidden(checker=checker)
        row = s.get(rid)
        self.assertEqual(row["hidden_pages"], [PASS_ID])
        self.assertNotEqual(row["hidden_at"], "",
                            "the hide-ELIGIBLE page is down, so the row's hide is complete and the 24-h alert stops")
        seen.clear()
        run.mark_hidden(checker=checker)
        self.assertEqual(seen, [PASS_ID], "410 is not permanent: a completed page is re-checked every run")
        self.assertEqual(s.get(rid)["hidden_at"], row["hidden_at"], "the read-back is not re-stamped")
        # the ASK page later resolves to PASS and its hide merges: it is read back now, without re-checking the page
        # that already passed (and its own 410 is what completes the row's record)
        down.add(ASK_ID)
        s.update(rid, "decide", identity_verdict="PASS_A", verdict_detail=[{"id": PASS_ID, "verdict": "PASS_A"},
                                                                          {"id": ASK_ID, "verdict": "PASS_A"}])
        seen.clear()
        run.mark_hidden(checker=checker)
        self.assertEqual(sorted(seen), sorted([PASS_ID, ASK_ID]), "every eligible page is re-checked")
        self.assertEqual(sorted(s.get(rid)["hidden_pages"]), sorted([PASS_ID, ASK_ID]))

    def test_a_rollback_of_a_hidden_page_pages_again(self):
        """QA 33rd round: 410 is not permanent. A page that read back gone and answers 200 again (a rollback, a bad
        deploy, a config list edited back) has to be detected, has to clear the row's completion marker, and has to
        page its overdue hide deadline again."""
        from gdpr_pipeline.run import Run
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000818"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-10-20T00:00:00Z",
                           "conversation_id": "215400000000818", "pages": [{"entity": "profile", "id": OTHER}]})
        now = datetime(2026, 11, 3, 12, 0, tzinfo=timezone.utc)
        s.update(rid, "decide", identity_verdict="PASS_A", decided_at="2026-10-21T00:00:00Z",
                 verdict_detail=[{"id": OTHER, "verdict": "PASS_A"}])
        run.mark_hidden(checker=lambda e, p: True)
        self.assertNotEqual(s.get(rid)["hidden_at"], "")
        self.assertEqual(run.hide_due_rows(now), [])
        # the page comes back: 200 again
        run.mark_hidden(checker=lambda e, p: False)
        row = s.get(rid)
        self.assertEqual(row["hidden_pages"], [], "a public page is not 'read back gone'")
        self.assertEqual(row["hidden_at"], "", "the completion marker is stale the moment the page is public")
        self.assertEqual([n for n, _ in run.hide_due_rows(now)], [s.get(rid)["register_no"]],
                         "so the 24-hour hide deadline pages again")
        self.assertEqual([e["kind"] for e in s.events(rid) if e["kind"] == "unhidden"], ["unhidden"])

    def test_a_clickup_replay_of_a_closed_row_dates_the_new_request_at_its_reply(self):
        """QA 34th round: the ClickUp replay matched only rows with a written confirmation, so a row a human closed
        (no confirmation) fell through to the ordinary path: the ticket's whole thread dated the new request (October,
        already overdue) and both pages rode into it. An ANSWERED row is matched here too, so the new request carries
        only the page the November reply introduced and is due in December."""
        from gdpr_pipeline.run import Run
        A, B = OTHER, ARPAD
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000072", "clickup:86x3"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                           "conversation_id": "215400000000072", "pages": [{"entity": "profile", "id": A}]})
        s.update(rid, "closed", status="closed")          # closed by a human, no confirmation letter
        s.db.execute("UPDATE erasure_requests SET updated_at='2026-10-26T09:00:00Z' WHERE id=?", (rid,))
        s.db.commit()                                     # closed after the 26 Oct message: only what follows is new
        conv = {"created_at": 1793000000, "conversation_id": "215400000000072",
                "parts": [{"at": 1793000000, "text": f"please delete my data muso.ai/profile/{A}"},   # 25 Oct
                          {"at": 1793544280, "text": f"also this one muso.ai/profile/{B}"}],             # 1 Nov
                "customer_text": f"please delete my data muso.ai/profile/{A}\nalso this one muso.ai/profile/{B}"}
        ticket = {"id": "86x3", "date_created": "1793000000000", "date_updated": "1793544280000",
                  "status": {"type": "open"}, "description": "---ACTION-REQUEST---\n"
                  '{"action_type":"data-deletion","customer_email":"","customer_profile_id":"","cs_session_id":"",'
                  '"conversation_summary":""}',
                  "custom_fields": [{"name": "Intercom Link",
                                     "value": "https://app.intercom.com/a/inbox/x/inbox/conversation/215400000000072"}],
                  "tags": [{"name": "action:data-deletion"}]}
        run.intake_clickup([ticket], conv_reader=lambda c: conv)
        self.assertEqual([p["id"] for p in s.get(rid)["pages"]], [A], "the closed row is not grown")
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual([p["id"] for p in rows[0]["pages"]], [B])
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z", "dated at the reply, not at the thread")
        self.assertEqual(rows[0]["due_at"], "2026-12-01T14:44:40Z")

    def test_a_later_message_on_a_closed_row_opens_a_new_request(self):
        """QA 33rd round: a markdown-register row can be `status=closed` with no written confirmation. A later message
        on that thread used to APPEND its page to the closed row, and every pass filters to open rows - so the request
        was registered nowhere that acts. An answered row is immutable whether it was closed by a confirmation or for
        any other reason."""
        from gdpr_pipeline.run import Run
        A, B = OTHER, ARPAD
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["register:41"], "channel": "register",
                           "class": "privacy_erasure", "received_at": "2026-10-01T00:00:00Z",
                           "conversation_id": "215400000000919", "pages": [{"entity": "profile", "id": A}]})
        s.update(rid, "closed", status="closed")          # closed by a human, no confirmation letter
        self.assertNotEqual(s.get(rid)["status"], "open")
        run.merge_reply(s.get(rid), {"subject": "", "customer_text": f"please also remove muso.ai/profile/{B}",
                                     "parts": [{"at": 1793544280, "text": f"muso.ai/profile/{B}"}]})
        closed_row = s.get(rid)
        self.assertEqual([p["id"] for p in closed_row["pages"]], [A], "the closed row is not grown")
        open_rows = s.all("open")
        self.assertEqual(len(open_rows), 1, "the new request has its own open row")
        self.assertEqual([p["id"] for p in open_rows[0]["pages"]], [B])
        self.assertEqual(open_rows[0]["received_at"], "2026-11-01T14:44:40Z")
        self.assertEqual(open_rows[0]["due_at"], "2026-12-01T14:44:40Z", "with its own 30-day date")

    def test_a_new_page_on_a_hidden_row_still_pages(self):
        """QA 32nd round: a row read back 410 + noindex, then the customer supplied a second profile before the written
        confirmation. `mark_hidden` set `hidden_at` on the first page and the 24-hour alert skipped the whole row, so
        the NEW page sat public with no alert at all. The alert now compares the CURRENT eligible pages with the ids
        that actually read back (`hidden_pages`), never with the row-level marker."""
        from gdpr_pipeline.run import Run
        A, B = OTHER, ARPAD
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000717"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-10-20T00:00:00Z",
                           "conversation_id": "215400000000717", "pages": [{"entity": "profile", "id": A}]})
        now = datetime(2026, 11, 3, 12, 0, tzinfo=timezone.utc)
        detail = [{"id": A, "verdict": "PASS_A"}]
        s.update(rid, "decide", identity_verdict="PASS_A", verdict_detail=detail, decided_at="2026-10-21T00:00:00Z")
        run.mark_hidden(checker=lambda e, p: p == A)
        self.assertNotEqual(s.get(rid)["hidden_at"], "")
        self.assertEqual(run.hide_due_rows(now), [], "the only page of the row is down")
        # a second profile arrives before the confirmation and is still public (200)
        s.update(rid, "reply_merged", pages=[{"entity": "profile", "id": A}, {"entity": "profile", "id": B}])
        s.update(rid, "decide", identity_verdict="PASS_A", decided_at="2026-11-03T11:00:00Z",
                 verdict_detail=detail + [{"id": B, "verdict": "PASS_A"}])
        run.mark_hidden(checker=lambda e, p: p == A)          # B still answers 200
        self.assertEqual(s.get(rid)["hidden_at"], "",
                         "the row is not 'hidden' while a page it now carries is public (QA 35th round)")
        self.assertEqual([n for n, _ in run.hide_due_rows(now)], [s.get(rid)["register_no"]],
                         "a page that turned up after the read-back is not hidden, so the deadline still pages")
        self.assertIn(B[:8], run.hide_due_rows(now)[0][1])
        run.mark_hidden(checker=lambda e, p: True)            # B's hide merges and reads back
        self.assertNotEqual(s.get(rid)["hidden_at"], "", "the marker is set again once EVERY eligible page is down")
        self.assertEqual(run.hide_due_rows(now), [])
        self.assertEqual(sorted(s.get(rid)["hidden_pages"]), sorted([A, B]))

    def test_the_two_deadlines_page_separately(self):
        """QA 24th round: one `paged` set meant the 24-hour HIDE page (which fires first) suppressed the same row's
        30-day written-confirmation warning later the same day: the statutory date was never announced."""
        import importlib.util
        import tempfile
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_wd", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        with tempfile.TemporaryDirectory() as tmp:
            run = Run(Store(os.path.join(tmp, "erasure.sqlite")), log=lambda *_: None)
            posted = []
            with mock.patch.object(cli, "slack_post", lambda text: posted.append(text) or True):
                run.hide_due_rows = lambda now, include_legal=False: [(40, "HIDE line for #40")]
                run.watchdog_rows = lambda now: []
                cli.watchdog(run, page=True)                     # the 24-hour page goes out first
                self.assertEqual(len(posted), 1)
                run.watchdog_rows = lambda now: [(40, "CONFIRM line for #40")]
                cli.watchdog(run, page=True)                     # the 30-day warning for the SAME row is not suppressed
                self.assertEqual(len(posted), 2, "the confirmation warning must still be announced")
                self.assertIn("CONFIRM line for #40", posted[1])
                cli.watchdog(run, page=True)                     # ...and neither repeats within the day
                self.assertEqual(len(posted), 2)
            import json
            state = json.load(open(os.path.join(tmp, "watchdog-last.json")))
            self.assertEqual(sorted(state["paged"]), ["confirm:40", "hide:40"])

    def test_a_real_threat_after_the_confirmation_is_still_hide_first(self):
        """The other half: an ACTUAL escalation after the confirmation keeps its class, and is dated at the message
        that carried the threat, never at an earlier pre-confirmation one."""
        from gdpr_pipeline.run import Run
        ask = "please delete muso.ai/profile/" + ARPAD
        conv = {"conversation_id": "215400000000092", "created_at": 1790000000, "subject": "",
                "author_name": "A P", "author_email": "a@pm.me", "customer_text": ask,
                "parts": [{"at": 1790000500, "text": ask}]}
        threat_b = "also remove muso.ai/profile/" + OTHER + " or my lawyer will write to you"
        later = dict(conv, customer_text=ask + "\n" + threat_b,
                     parts=conv["parts"] + [{"at": 1793544280, "text": threat_b}])
        s = Store(":memory:")
        run = Run(s, log=lambda *_: None)
        rid, _ = s.upsert({"keys": ["intercom:215400000000092"], "channel": "intercom",
                           "class": "privacy_erasure", "received_at": "2026-09-20T00:00:00Z",
                           "conversation_id": "215400000000092", "requester_name": "A P",
                           "requester_email": "a@pm.me", "pages": [{"entity": "profile", "id": ARPAD}]})
        s.update(rid, "confirmed", confirmed_at="2026-10-20T00:00:00Z", status="closed")
        run.merge_reply(s.get(rid), later)
        rows = s.all("open")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["class"], "legal_threat")
        self.assertEqual(rows[0]["received_at"], "2026-11-01T14:44:40Z")
        # a date-only confirmation covers its whole day: a message from that day belongs to the request we answered
        from gdpr_pipeline.run import confirmed_after
        self.assertGreater(confirmed_after("2026-10-20"), 1792368000,
                           "a date-only confirmation covers its whole day")
        self.assertEqual(confirmed_after(""), 0)

    def test_a_public_5xx_is_a_failed_read_not_a_missing_page(self):
        import urllib.error
        from unittest import mock
        from gdpr_pipeline import sources
        err = urllib.error.HTTPError("https://muso.ai/profile/x", 500, "boom", {}, None)
        with mock.patch.object(sources.urllib.request, "urlopen", side_effect=err):
            with self.assertRaises(sources.Unknown):
                sources.public_status("profile", ARPAD)
        err404 = urllib.error.HTTPError("https://muso.ai/profile/x", 404, "gone", {}, None)
        with mock.patch.object(sources.urllib.request, "urlopen", side_effect=err404):
            self.assertEqual(sources.public_status("profile", ARPAD), 404)

    def test_a_catalog_404_with_a_public_500_fails_the_row(self):
        from unittest import mock
        from gdpr_pipeline import sources
        with mock.patch.object(sources, "profile_doc", lambda pid: {}), \
                mock.patch.object(sources, "public_status", side_effect=sources.Unknown("public GET: HTTP 500")):
            with self.assertRaises(sources.Unknown):
                sources.page_facts([{"entity": "profile", "id": ARPAD}], set(), {})


class SafetyFieldsMustBeStated(unittest.TestCase):
    """QA on a3e68886a: `isClaimed` / `popularity` / `creditCount` decide whether path C may pass and whether the
    page is a big name for Jan. Reading a MISSING field as false/0 turned "we do not know" into "unclaimed and
    small", so an incomplete admin answer could auto-hide a page nobody had established was safe to hide."""

    DOC = {"id": ARPAD, "name": "Arpad", "isClaimed": False, "popularity": 3, "creditCount": 7, "links": {}}

    def facts(self, doc):
        from unittest import mock
        from gdpr_pipeline import sources
        with mock.patch.object(sources, "profile_doc", lambda pid: doc):
            return sources.page_facts([{"entity": "profile", "id": ARPAD}], set(), {})[0]

    def test_a_complete_answer_is_unchanged(self):
        p = self.facts(dict(self.DOC))
        self.assertEqual((p.facts_unknown, p.is_claimed, p.popularity, p.credit_count), ("", False, 3.0, 7))

    def test_a_missing_safety_field_is_never_read_as_zero(self):
        for field in ("isClaimed", "popularity", "creditCount"):
            doc = {k: v for k, v in self.DOC.items() if k != field}
            p = self.facts(doc)
            self.assertEqual(p.facts_unknown, field, field)
            v = identity.decide_page(p, Requester(name="Arpad", email="arpad@example.com", verified=True), "privacy_erasure")
            self.assertEqual(v.verdict, identity.UNKNOWN, f"a missing {field} must not let C pass")
            self.assertIn(field, v.why)

    def test_a_null_safety_field_is_unknown_not_zero(self):
        p = self.facts(dict(self.DOC, popularity=None, creditCount=None))
        self.assertEqual(p.facts_unknown, "popularity,creditCount")
        v = identity.decide_page(p, Requester(name="Arpad", email="arpad@example.com", verified=True), "privacy_erasure")
        self.assertEqual(v.verdict, identity.UNKNOWN)

    def test_a_bool_is_not_a_number(self):
        # bool is an int subclass: True must not have read as "1 credit"
        p = self.facts(dict(self.DOC, creditCount=True, popularity=False))
        self.assertEqual(p.facts_unknown, "popularity,creditCount")

    def test_a_wrong_typed_isClaimed_is_unknown(self):
        p = self.facts(dict(self.DOC, **{"isClaimed": "false"}))
        self.assertEqual(p.facts_unknown, "isClaimed")


class CrossChannelDuplicates(unittest.TestCase):
    """`dedupe` must also see one event that arrived on TWO channels, not only the `:again:` respellings. These rows
    are built directly: with the prefix-aware merge in `_match`, `upsert` no longer creates the pair at the front door,
    so the repair tool has to be tested against the rows a pre-fix tick already wrote."""

    def setUp(self):
        self.s = Store(":memory:")

    def row(self, key, channel, received, pages, conv="", thread=""):
        # a distinct placeholder sender per row, so `upsert` cannot merge them for us: these rows stand in for the
        # historic pairs a pre-fix tick wrote, and `unify` then gives them the one real sender they share.
        rid, how = self.s.upsert({"keys": [key], "channel": channel, "class": "privacy_erasure",
                                  "received_at": received, "requester_email": f"{abs(hash(key))}@else.example",
                                  "pages": pages, "conversation_id": conv, "gmail_thread": thread})
        self.assertIn(how, ("created", "unchanged"))
        return rid

    def unify(self, *rids, email="gertjan@pm.me"):
        for rid in rids:
            self.s.update(rid, "test", requester_email=email)

    def test_a_fold_keeps_the_more_restrictive_class(self):
        """QA on #1735: the scanner keeps the row carrying the full uuid, which is not necessarily the row carrying the
        more restrictive class. A notices@ `legal_threat` and the Intercom `privacy_erasure` about it are one event;
        folding the first into the second left the only open row an erasure, so legal-threat handling (Jan, hide
        first, the 24 h deadline) silently disappeared. Same rule as `upsert`: the stricter class wins."""
        threat = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        self.s.db.execute("UPDATE erasure_requests SET class='legal_threat' WHERE id=?", (threat,))
        self.s.db.commit()
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(threat, conv)
        keep, drop = self.s.duplicate_events()[0]
        self.assertEqual(keep["id"], conv, "the row carrying the full uuid is the one we keep")
        self.assertEqual(keep["class"], "privacy_erasure")
        self.assertEqual(drop["class"], "legal_threat")
        self.s.merge_duplicate(keep, drop)
        self.assertEqual(self.s.get(conv)["class"], "legal_threat",
                         "the surviving row must keep the stricter class, not the one it happened to be keyed on")

    def test_a_fold_never_downgrades_the_kept_rows_class(self):
        """The other direction: a stricter kept row must not be relaxed by folding a milder duplicate into it."""
        threat = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        self.s.db.execute("UPDATE erasure_requests SET class='legal_threat' WHERE id=?", (threat,))
        self.s.db.commit()
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(threat, conv)
        self.s.merge_duplicate(self.s.get(threat), self.s.get(conv))
        self.assertEqual(self.s.get(threat)["class"], "legal_threat")

    def test_a_notice_and_the_conversation_about_it_are_one_event(self):
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        pairs = self.s.duplicate_events()
        self.assertEqual(len(pairs), 1, "two channels, one event")
        keep, drop = pairs[0]
        self.assertEqual(keep["id"], conv, "the row carrying the full uuid is the one we keep")
        self.assertEqual(drop["id"], thread)
        self.s.merge_duplicate(keep, drop)
        self.assertEqual(self.s.get(thread)["status"], "duplicate")
        self.assertEqual([p["id"] for p in self.s.get(conv)["pages"]],
                         ["fc31a861-0297-410d-914b-60e8a02ced76"], "the prefix is replaced by its full uuid")

    def test_the_repair_scanner_uses_the_same_page_rule_as_intake(self):
        """QA on #1735: intake merges on ANY shared page, but the scanner required the two prefix sets to be EQUAL, so
        a notice naming page A and the Intercom conversation about it naming A and B stayed two open requests with two
        deadlines and two letters. The repair must read the same overlap rule."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"},
                         {"entity": "profile", "id": "0b7d2e14-1111-4222-8333-944455556666"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        pairs = self.s.duplicate_events()
        self.assertEqual(len(pairs), 1, "a shared page is one event, even when one side names more pages")
        keep, drop = pairs[0]
        self.assertEqual(keep["id"], conv, "the row carrying the full uuid is the one we keep")
        self.assertEqual(drop["id"], thread)

    def test_the_repair_scanner_uses_the_same_window_as_intake(self):
        """QA on #1735: the scanner allowed 300 s while `_match` allowed 120, so a notice at 01:00 and the Intercom
        conversation about it at 01:04 were kept as TWO requests by intake and then folded into one by
        `dedupe --apply` - the fold took away the second request's own reply target and watchdog. A repair may only
        undo what intake would have merged, so the 121-300 s interval must stay two requests."""
        self.assertEqual(store.Store.CROSS_CHANNEL_SECONDS, store.SAME_EVENT_SECONDS,
                         "the repair scanner and intake must share one bound")
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:00:00Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:04:00Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.assertEqual(self.s.duplicate_events(), [],
                         "four minutes apart is two requests; intake kept them apart and the repair must not fold them")

    def test_merging_folds_the_dropped_rows_pages_into_the_one_we_keep(self):
        """Belt and braces for the historic pairs: whichever row is kept, the surviving row must end up with the full
        uuid, because a prefix cannot be looked up in the catalog and would strand the request at UNKNOWN."""
        prefix = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        full = self.row("intercom:2", "intercom", "2026-11-04T02:39:22Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}], conv="2")
        self.s.merge_duplicate(self.s.get(prefix), self.s.get(full))
        self.assertEqual([p["id"] for p in self.s.get(prefix)["pages"]],
                         ["fc31a861-0297-410d-914b-60e8a02ced76"])

    def test_the_earlier_receipt_and_its_deadlines_survive_the_fold(self):
        """QA finding on #1735: the kept row is chosen by KEY SHAPE (a full uuid beats an 8-char prefix), not by time,
        so a duplicate that arrived first would hand the customer a LATER statutory deadline. `due_at` and
        `hide_due_at` are derived from `received_at`, so they move with it - taking the earlier receipt alone would
        leave the row claiming a deadline its own receipt contradicts."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        keep, drop = self.s.duplicate_events()[0]
        self.assertEqual(keep["id"], conv, "precondition: the full-uuid row is the one kept")
        self.s.merge_duplicate(keep, drop)
        merged = self.s.get(conv)
        self.assertEqual(merged["received_at"], "2026-11-04T01:39:22Z",
                         "the surviving row must carry the EARLIEST receipt, not the kept row's later one")
        self.assertEqual(merged["due_at"], self.s.get(thread)["due_at"],
                         "the statutory deadline must follow the receipt it is derived from")
        self.assertEqual(merged["hide_due_at"], self.s.get(thread)["hide_due_at"])

    def test_a_sent_letter_moves_with_the_fold_so_it_cannot_be_sent_twice(self):
        """QA finding on #1735, the serious one: closing the duplicate without moving its `erasure_sends` row left the
        kept row with no record of a letter that had already gone out, so `unsent_letters()` returned it and another
        approved batch could send a SECOND statutory letter for one request."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.s.begin_send(thread, "ask", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        keep, drop = self.s.duplicate_events()[0]
        self.s.merge_duplicate(keep, drop)
        self.assertIsNotNone(self.s.send_record(conv, "ask"),
                             "the surviving row must know the letter already went out")
        self.assertNotIn(conv, self.s.unsent_letters("ask"),
                         "a row whose letter is already out must never be offered to another batch")

    def test_two_letters_for_one_slot_refuse_the_fold_instead_of_guessing(self):
        """When BOTH rows carry a record for the same slot and either may have reached the customer, folding them is a
        person's call: the surviving row must not end up able to send a second statutory letter, and code must not
        silently pick which letter "counts"."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.s.begin_send(thread, "ask", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        self.s.begin_send(conv, "ask", "intercom", "215476692845876", "sha", "U7RP6HKUZ", state="sent")
        keep, drop = self.s.duplicate_events()[0]
        with self.assertRaises(store.MergeRefused) as e:
            self.s.merge_duplicate(keep, drop)
        self.assertIn("second statutory letter", str(e.exception))
        self.assertEqual(self.s.get(drop["id"])["status"], "open",
                         "a refused fold must leave BOTH rows untouched, not half-merged")

    def test_the_sent_stamps_move_with_the_ledger_they_belong_to(self):
        """QA finding on #1735: `send.deliver` writes `confirmed_at` / `ask_sent_at` / `interim_confirm_at` NEXT TO
        the ledger row, so a fold that moved the ledger and not the stamp left the surviving row with a `sent`
        confirmation record and `confirmed_at == ''` - its watchdog stayed armed and a later message from that
        customer was folded into an already-answered request instead of opening a new one."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.s.begin_send(thread, "ask", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        self.s.update(thread, "ask", ask_sent_at="2026-11-04T02:00:00Z", ask_ref="msg-ask")
        self.s.begin_send(thread, "confirm", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        self.s.update(thread, "confirmed", confirmed_at="2026-11-04T03:00:00Z", confirm_ref="msg-confirm")
        self.s.begin_send(thread, "confirm-interim", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        self.s.update(thread, "confirmed", interim_confirm_at="2026-11-04T02:30:00Z",
                      interim_confirm_ref="msg-interim")
        keep, drop = self.s.duplicate_events()[0]
        self.assertEqual(keep["id"], conv, "precondition: the full-uuid row is the one kept")
        self.s.merge_duplicate(keep, drop)
        merged = self.s.get(conv)
        self.assertEqual(merged["confirmed_at"], "2026-11-04T03:00:00Z",
                         "a sent confirmation must take the row out of the watchdog, not just move its ledger row")
        self.assertEqual(merged["confirm_ref"], "msg-confirm")
        self.assertEqual(merged["ask_sent_at"], "2026-11-04T02:00:00Z", "the chase clock must survive the fold")
        self.assertEqual(merged["ask_ref"], "msg-ask")
        self.assertEqual(merged["interim_confirm_at"], "2026-11-04T02:30:00Z")
        self.assertEqual(merged["interim_confirm_ref"], "msg-interim")

    def test_the_earliest_stamp_wins_when_both_rows_carry_one(self):
        """Same doctrine as the earliest receipt: the customer was written to on the FIRST date, and a later stamp
        must not push the confirmation date (or the chase clock) forward."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.s.update(thread, "test", ask_sent_at="2026-11-04T02:00:00Z", ask_ref="early")
        self.s.update(conv, "test", ask_sent_at="2026-11-04T05:00:00Z", ask_ref="late")
        keep, drop = self.s.duplicate_events()[0]
        self.s.merge_duplicate(keep, drop)
        merged = self.s.get(conv)
        self.assertEqual((merged["ask_sent_at"], merged["ask_ref"]), ("2026-11-04T02:00:00Z", "early"))

    def test_a_refused_fold_moves_no_ledger_row_at_all(self):
        """QA finding on #1735: the loop re-pointed `ask` and THEN raised on `confirm`, so a refused fold left the
        dropped row open with its ask slot gone - the next store update commits that pending move and
        `unsent_letters('ask')` offers the dropped row for a second letter, while the CLI reports it untouched."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.s.begin_send(thread, "ask", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        self.s.begin_send(thread, "confirm", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        self.s.begin_send(conv, "confirm", "intercom", "215476692845876", "sha", "U7RP6HKUZ", state="sent")
        keep, drop = self.s.duplicate_events()[0]
        with self.assertRaises(store.MergeRefused):
            self.s.merge_duplicate(keep, drop)
        self.assertIsNotNone(self.s.send_record(drop["id"], "ask"),
                             "a refused fold must not strand the dropped row's ask slot on the kept row")
        self.assertIsNone(self.s.send_record(keep["id"], "ask"),
                          "nothing may move before the whole fold is known to be safe")
        self.assertNotIn(drop["id"], self.s.unsent_letters("ask"),
                         "the dropped row still has its letter; it must not be offered another")

    def test_a_fold_that_fails_halfway_leaves_no_half_moved_ledger(self):
        """QA finding on #1735: `_merge_sends` committed on its own and `update` committed again, so a failure
        between them left the dropped row OPEN with its `ask:sent` record already moved onto the kept row - and
        `unsent_letters('ask')` then offered the open row for a SECOND statutory letter. The fold is one savepoint
        now, so a failure anywhere in it moves nothing."""
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:215476692845876", "intercom", "2026-11-04T01:39:31Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
                        conv="215476692845876")
        self.unify(thread, conv)
        self.s.begin_send(thread, "ask", "mail", "t1", "sha", "U7RP6HKUZ", state="sent")
        keep, drop = self.s.duplicate_events()[0]
        real_update = self.s.update

        def explode(rid, kind, commit=True, **cols):
            if rid == drop["id"] and cols.get("status") == "duplicate":
                raise sqlite3.OperationalError("disk I/O error")
            return real_update(rid, kind, commit=commit, **cols)

        with mock.patch.object(self.s, "update", explode):
            with self.assertRaises(sqlite3.OperationalError):
                self.s.merge_duplicate(keep, drop)
        self.assertEqual(self.s.get(drop["id"])["status"], "open", "a failed fold must not close the dropped row")
        self.assertIsNotNone(self.s.send_record(drop["id"], "ask"),
                             "the dropped row must keep the letter it already sent")
        self.assertIsNone(self.s.send_record(keep["id"], "ask"),
                          "nothing may move onto the kept row when the fold did not complete")
        self.assertNotIn(drop["id"], self.s.unsent_letters("ask"),
                         "the row still has its letter; it must not be offered another")

    def test_applying_every_reported_pair_never_points_a_key_at_a_closed_row(self):
        """QA finding on #1735: `taken` held `id()` of the dicts from the first `self.all()`, but
        `_cross_channel_duplicates` calls `self.all()` again and gets FRESH dicts, so the exclusion never matched and
        one row could appear in two pairs. Applying both left a key pointing at a row the first fold had just
        closed - a re-ingest of that message would land on a dead request."""
        a = self.row("intercom:215476692845876:again:2026-11-04T01:39:22Z", "intercom", "2026-11-04T01:39:22Z",
                     [{"entity": "profile", "id": "fc31a861"}], conv="215476692845876")
        b = self.row("register:19:again:2026-11-04T01:39:22Z", "intercom", "2026-11-04T01:39:22Z",
                     [{"entity": "profile", "id": "fc31a861"}], conv="215476692845876")
        c = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:31Z",
                     [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}], thread="t1")
        self.unify(a, b, c)
        pairs = self.s.duplicate_events()
        self.assertTrue(pairs, "precondition: the fixture must produce at least one pair")
        for keep, drop in pairs:
            self.assertEqual(self.s.get(keep["id"])["status"], "open",
                             f"pair ({keep['id']}, {drop['id']}) keeps a row an earlier fold already closed")
            self.s.merge_duplicate(keep, drop)
        for rid in (a, b, c):
            for key in self.s.get(rid)["keys"]:
                target = self.s.db.execute("SELECT request_id FROM erasure_keys WHERE key=?", (key,)).fetchone()
                self.assertEqual(self.s.get(target[0])["status"], "open",
                                 f"key {key} points at a closed request after the folds")

    def test_a_second_message_hours_later_is_not_a_duplicate(self):
        thread = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:22Z",
                          [{"entity": "profile", "id": "fc31a861"}], thread="t1")
        conv = self.row("intercom:9", "intercom", "2026-11-04T06:39:22Z",
                        [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}], conv="9")
        self.unify(thread, conv)
        self.assertEqual(self.s.duplicate_events(), [], "a later request from the same person is a NEW request")

    def test_two_rows_on_the_same_channel_are_not_treated_as_one(self):
        a = self.row("intercom:1", "intercom", "2026-11-04T01:39:22Z",
                     [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}], conv="1")
        b = self.row("intercom:2", "intercom", "2026-11-04T01:39:30Z",
                     [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}], conv="2")
        self.unify(a, b)
        self.assertEqual(self.s.duplicate_events(), [])

    def test_a_different_page_is_never_a_duplicate(self):
        a = self.row("intercom:1", "intercom", "2026-11-04T01:39:22Z",
                     [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}], conv="1")
        b = self.row("gmail:notices@muso.ai:t1", "notices", "2026-11-04T01:39:25Z",
                     [{"entity": "profile", "id": "aaaaaaaa"}], thread="t1")
        self.unify(a, b)
        self.assertEqual(self.s.duplicate_events(), [])


class Migration(unittest.TestCase):
    def test_an_existing_store_gains_the_new_column(self):
        import sqlite3
        import tempfile
        d = tempfile.mkdtemp()
        p = os.path.join(d, "erasure.sqlite")
        from gdpr_pipeline.store import SCHEMA
        old = "\n".join(line for line in SCHEMA.splitlines() if "removed_outside_process" not in line)
        db = sqlite3.connect(p)
        db.executescript(old)              # the schema as it shipped in 779b360
        db.commit()
        db.close()
        s = Store(p)                      # migrates instead of recreating: the rows are the legal record
        cols = [r[1] for r in s.db.execute("PRAGMA table_info(erasure_requests)")]
        self.assertIn("removed_outside_process", cols)
        self.assertIn("hidden_pages", cols)


if __name__ == "__main__":
    unittest.main()


class SendPath(unittest.TestCase):
    """`confirm --send` / `ask --send`: ONE ledgered letter per request through the approved writers only.

    Locks (Fable driver 2026-11-03 20:1xZ, Fable ruling gdpr-ruling-for-jan §3):
      - the copy is never composed here: the shipped approved text is what goes out, byte for byte
      - every send is claimed in `erasure_sends` BEFORE the writer runs (UNIQUE request+kind), so a retry is a refusal
        and never a second letter; a crash leaves a visible `sending` row
      - every route fails CLOSED: a mailbox gog cannot write, a non-numeric conversation id, an empty thread
      - the gate is two human locks (the compiled unlock + --approved-by) and both are tested
    Hermetic: the adapters are patched; nothing leaves this host.
    """

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)
        self.lines = []

    def row(self, **kw):
        c = {"keys": ["intercom:9"], "channel": "intercom", "class": "privacy_erasure",
             "received_at": "2026-09-01T10:00:00Z", "requester_email": "a@b.co", "conversation_id": "215476650395415",
             "requester_name": "Arpad Laczkovszki",
             "pages": [{"entity": "profile", "id": ARPAD}]}
        c.update(kw)
        rid, _ = self.s.upsert(c)
        return rid, self.s.get(rid)

    def item(self, rid, text="Hello there,\n\nthe approved letter.\n", **kw):
        x = {"row": rid, "register_no": self.s.get(rid)["register_no"], "text": text, "kind": "confirm",
             "channel": "intercom", "to": "215476650395415", "due_at": "2026-10-01T10:00:00Z"}
        x.update(kw)
        return x

    # ---- routing -------------------------------------------------------------------------------------------
    def test_intercom_conversation_is_the_route(self):
        rid, r = self.row()
        self.assertEqual(send.route(r), ("intercom", "215476650395415"))

    def test_support_thread_replies_in_the_thread(self):
        rid, r = self.row(keys=["gmail:support@muso.ai:t1"], channel="support", conversation_id="",
                          gmail_thread="1a176619567e3fe0")
        self.assertEqual(send.route(r), ("mail", "1a176619567e3fe0"))

    def test_a_legal_or_notices_thread_is_refused_with_the_reason(self):
        """legal@ / notices@ are not authed in gog on node-8, so a letter cannot be written FROM that mailbox. The
        refusal still names the mailbox and the fix, but since 073 it is no longer the end of the road: an unwritable
        mailbox hands off to option 2 (a new thread from support@), and the mailbox reason is carried INTO that error
        so nobody has to guess why the thread could not be used. The refusal comes from the HOST's account list, not a
        hardcoded channel test - so authing the mailbox opens the thread route with no code change."""
        rid, r = self.row(keys=["gmail:legal@muso.ai:t1"], channel="legal", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e")
        # BOTH copy gates are OPEN now (lead 2026-11-04 / subject under ruling gdpr-support-from-1104), so this row
        # no longer refuses on copy: it HANDS OFF to option 2. The mailbox reason must still be carried into every
        # refusal this route produces, so pin it on the one that still fires with the gates open - no address -
        # and then close each gate in turn to prove a refusal never loses the mailbox reason on the way out.
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}):
            self.assertEqual(send.route(r), ("mail_new_thread", "a@b.co"),
                             "an unwritable mailbox hands off to a new thread from support@ once both copy GOs exist")
            with self.assertRaises(send.Unknown) as e0:
                send.route({**r, "requester_email": ""})
        self.assertIn("legal@muso.ai", str(e0.exception))
        # NOT "auth it and the route opens": since the 2026-11-06 ruling legal@ is an alias for a person, not an
        # account, so there is nothing to auth. The reason must say that instead of sending an operator after a
        # mailbox that does not exist.
        self.assertIn("alias for a person rather than an account", str(e0.exception))
        self.assertNotIn("auth it and the route opens", str(e0.exception))
        self.assertIn("no requester_email", str(e0.exception))
        # the subject's own gate, still independent of the lead's: closing it keeps the mailbox reason in the message
        with mock.patch.object(copy, "NEW_THREAD_SUBJECT_APPROVED", False), \
                mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        msg = str(e.exception)
        self.assertIn("legal@muso.ai", msg)
        self.assertIn("alias for a person rather than an account", msg)
        self.assertIn("has no GO of its own", msg)
        self.assertIn("NEW_THREAD_SUBJECT_APPROVED", msg)
        with mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", False), \
                mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}):
            with self.assertRaises(send.Unknown) as e2:
                send.route(r)
        self.assertIn("one-line lead copy is not approved yet", str(e2.exception),
                      "an unwritable mailbox must hand off to option 2, not dead-end at the mailbox")

    def test_the_two_copy_gates_are_independent(self):
        """The lead line's GO named the first line and said nothing about the subject, so one constant must not
        release the other. Both orders are pinned: subject-open/lead-shut and lead-open/subject-shut."""
        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="a@b.co")
        with mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", True), \
                mock.patch.object(copy, "NEW_THREAD_SUBJECT_APPROVED", False):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("subject line", str(e.exception))
        with mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", False), \
                mock.patch.object(copy, "NEW_THREAD_SUBJECT_APPROVED", True):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("one-line lead copy", str(e.exception))

    def test_a_class_outside_the_approved_vocabulary_refuses_rather_than_guessing(self):
        """THE GO'S THIRD GUARD: "the request-type phrase must match what they asked for (deletion / access /
        correction / objection) - never characterise it beyond their own words". A rights-holder's DMCA takedown is
        not a deletion request, so it must NOT be described as one. 2 of the rows this route can reach are exactly
        this, and 1 more is a legal threat."""
        for cls in ("dmca_takedown", "legal_threat"):
            rid, r = self.row(**{"keys": [f"register:{cls}"], "channel": "legal", "conversation_id": "",
                                 "gmail_thread": "", "requester_email": "a@b.co", "class": cls})
            with self.approved_copy():
                with self.assertRaises(send.Unknown) as e:
                    send.route(r)
            msg = str(e.exception)
            self.assertIn("no approved request-type phrase", msg)
            self.assertIn(cls, msg)
            self.assertNotIn("deletion request", msg,
                             "the refusal must not itself assert what the person asked for")

    def test_the_approval_digest_covers_the_letter_that_actually_leaves(self):
        """QA finding on this PR: `digest()` hashed the item's ORIGINAL text while `deliver()` added the lead AFTER the
        digest was verified. The approver therefore approved one letter and the customer received another. The digest
        must be computed over the materialised letter, and the bytes sent must be those same bytes."""
        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="a@b.co", received_at="2026-09-01T10:00:00Z")
        bare = "Hello there,\n\nthe approved letter.\n"
        item = self.item(rid, text=bare, channel="notices")
        with self.approved_copy():
            items = send.materialise(self.run, [dict(item)])
        self.assertTrue(items[0]["text"].startswith("You wrote to us at notices@muso.ai on 1 September 2026"),
                        "materialise must produce the FINAL letter, lead included")
        self.assertEqual(items[0]["subject"], "Your Muso.AI data deletion request")
        # the digest of the final letter is NOT the digest of the bare body: that difference is the whole fix
        self.assertNotEqual(approval.digest("ask", items), approval.digest("ask", [dict(item)]))
        seen = {}

        def fake_send(email, text, approved_by, dry_run=False, key="", mailbox="", subject=""):
            seen.update(text=text, subject=subject)
            return "gog-msg-1"
        with self.approved_copy(), mock.patch.object(send, "_mail_send_new_thread", fake_send):
            out = send.deliver(self.run, items[0], "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "sent")
        self.assertEqual(seen["text"], items[0]["text"], "the bytes sent must BE the bytes the digest covered")
        self.assertEqual(seen["subject"], items[0]["subject"])

    def test_an_approval_cannot_leak_across_the_past_due_boundary(self):
        """The progress line is added by `Run.asks()` once the letter is past due - a CLOCK-dependent body change. So a
        batch approved at 09:59 and sent at 10:01 is not the batch that was approved. The digest must move, so the old
        approval refuses instead of releasing a letter nobody read. This is the same class as the date bomb (#1759):
        the letter's content depends on when you look at it."""
        from datetime import timedelta
        rid, r = self.row(keys=["register:90"], gmail_thread="", conversation_id="1")
        self.s.update(rid, "decide", identity_verdict="ASK_IDENTITY", due_at="2026-11-04T10:00:00Z")
        before = self.run.asks(datetime(2026, 11, 4, 9, 59, tzinfo=timezone.utc))
        after = self.run.asks(datetime(2026, 11, 4, 10, 1, tzinfo=timezone.utc))
        self.assertEqual(len(before), 1); self.assertEqual(len(after), 1)
        with self.approved_copy():
            db = approval.digest("ask", send.materialise(self.run, [dict(x) for x in before]))
            da = approval.digest("ask", send.materialise(self.run, [dict(x) for x in after]))
        self.assertNotEqual(db, da, "a letter that became past due gained the progress line, so its digest MUST move - "
                                    "otherwise the earlier approval releases copy nobody approved")

    def test_a_pinned_body_sha_is_checked_against_the_FINAL_letter_not_the_pre_lead_one(self):
        """The hole that only exists when the manifest pin (#1738) and the option-2 lead line (#1749) meet on main.

        A manifest pins the exact body a human approved. For a notices@/legal@ letter that body is NOT what leaves:
        `materialise()` prepends the approved lead line ("You wrote to us at legal@muso.ai on ..."). If the pin is
        checked against the pre-materialisation text, the check passes while the letter that goes out is a different
        one. Measured on the live register: 9 of the pinned 141 gained the lead, their sha no longer matched the pin,
        and `ask --manifest` still accepted the batch.

        Driven through the real CLI so it kills the wiring mutant, not just the function: swapping the nesting to
        `materialise(select_batch(...))` makes the manifest accept the stale pin and this test fails.
        """
        import contextlib as _contextlib
        import hashlib
        import importlib.util
        import io as _io
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_order", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)

        rid, r = self.row(keys=["register:91"], channel="legal", conversation_id="", gmail_thread="",
                          requester_email="a@b.co", received_at="2026-09-01T10:00:00Z")
        bare = "Bare approved body.\n"
        item = self.item(rid, text=bare, channel="legal")

        def run_cli(manifest_sha):
            import tempfile
            f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump({"entries": [{"request_id": str(rid), "register_no": r["register_no"],
                                    "body_sha": manifest_sha}]}, f)
            f.close()
            self.addCleanup(os.unlink, f.name)
            fake_run = mock.MagicMock()
            fake_run.asks.return_value = [dict(item)]
            fake_run.store.get.return_value = r        # materialise() reads the ROW to decide the route
            fake_run.errors = []
            out = _io.StringIO()
            # gog_accounts() caches per process, so a test that ran earlier can leave _ACCOUNTS without legal@ and
            # make this test order-dependent. Pin the host fact explicitly: this is about the PIN, not about gog.
            with self.approved_copy(), \
                    mock.patch.object(send, "_ACCOUNTS",
                                      {"legal@muso.ai": {"gmail"}, "notices@muso.ai": {"gmail"},
                                       "support@muso.ai": {"gmail"}}), \
                    mock.patch.object(send, "_ACCOUNTS_READ", True), \
                    mock.patch.object(cli, "Store", lambda *a, **k: self.s), \
                    mock.patch.object(cli, "Run", lambda *a, **k: fake_run), \
                    mock.patch.object(cli, "hold_lock", lambda *a, **k: mock.MagicMock()), \
                    mock.patch.object(sys, "argv", ["gdpr-pipeline.py", "--store", ":memory:", "ask", "--send",
                                                    "--approved-by", "U7RP6HKUZ", "--manifest", f.name]), \
                    mock.patch.object(approval, "verify", lambda *a, **k: (False, "captured")), \
                    _contextlib.redirect_stdout(out):
                try:
                    cli.main()
                except SystemExit:
                    pass
            return out.getvalue()

        def sha(t):
            return hashlib.sha256(t.encode()).hexdigest()

        # a manifest pinned to the PRE-lead body: the letter on the wire now differs, so it must refuse
        refused = run_cli(sha(bare))
        self.assertIn("the letter BODY changed for 1 request(s)", refused,
                      "the pin must speak for the FINAL letter; accepting it means 9 changed letters ride an old GO")
        # ... and the identical manifest pinned to the FINAL body is accepted, which proves the refusal above is
        # about the lead line and not about the manifest being wrong in some other way.
        with self.approved_copy():                            # the gates the CLI will run under
            final_text, subject, _to = send.final_letter(r, bare)  # the exact wire bytes, from the one source of truth
        self.assertNotEqual(final_text, bare, "precondition: a legal@ letter gains the lead line")
        # materialise() MUTATES the item it is given, so each run needs its own copy or run two would find
        # letter_final already set from run one.
        item = self.item(rid, text=bare, channel="legal")
        fake_run = None
        self.assertNotIn("the letter BODY changed", run_cli(sha(final_text)))
        self.assertIn("captured", run_cli(sha(final_text)))

    def test_the_cli_verifies_the_digest_over_the_MATERIALISED_letters(self):
        """THE WIRING, not just the function. QA's finding was an ORDERING bug: `refuse_send()` verified a digest over
        the bare body, and only `deliver()` added the lead. Calling `materialise()` in isolation cannot prove the CLI
        does it first - a mutant that drops the CLI call leaves every unit test green (verified: it did, 230 passed).
        So drive the real entrypoint and assert what `approval.verify` was handed."""
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)

        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="a@b.co", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Bare body.\n", channel="notices")
        seen = {}

        fake_run = mock.MagicMock()
        fake_run.asks.return_value = [item]
        fake_run.store.get.return_value = r          # materialise() reads the ROW to decide the route
        fake_run.errors = []

        def fake_verify(kind, items, who, approvers):
            seen["text"] = items[0]["text"]
            seen["subject"] = items[0].get("subject")
            return False, "captured for the test"       # refuse, so nothing is sent

        with self.approved_copy(), \
                mock.patch.object(cli, "Store", lambda *a, **k: self.s), \
                mock.patch.object(cli, "Run", lambda *a, **k: fake_run), \
                mock.patch.object(cli, "hold_lock", lambda *a, **k: mock.MagicMock()), \
                mock.patch.object(sys, "argv", ["gdpr-pipeline.py", "--store", ":memory:", "ask",
                                                "--send", "--approved-by", "U7RP6HKUZ"]), \
                mock.patch.object(cli, "oldest_first", lambda xs: list(xs)), \
                mock.patch.object(approval, "verify", fake_verify):
            try:
                cli.main()
            except SystemExit:
                pass
        self.assertIn("text", seen, "approval.verify must have been reached")
        self.assertTrue(seen["text"].startswith("You wrote to us at notices@muso.ai on 1 September 2026"),
                        "the CLI must materialise BEFORE verifying the digest, or the approval covers bytes nobody "
                        "receives (QA finding on #1749)")
        self.assertEqual(seen["subject"], "Your Muso.AI data deletion request")

    def test_editing_the_lead_copy_invalidates_a_standing_approval(self):
        """The lead is customer-facing copy. If its string changes, the letters change, so the digest must change and
        the old approval must stop matching - that is what makes `NEW_THREAD_LEAD_RULING` load-bearing."""
        rid, r = self.row(keys=["register:78"], channel="legal", conversation_id="", gmail_thread="",
                          requester_email="c@d.co", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Body.\n", channel="legal")
        with self.approved_copy():
            before = approval.digest("ask", send.materialise(self.run, [dict(item)]))
        with self.approved_copy(), \
                mock.patch.object(copy, "NEW_THREAD_LEAD", "Hi! We got your note of {date} via {mailbox}. {request_details}."):
            after = approval.digest("ask", send.materialise(self.run, [dict(item)]))
        self.assertNotEqual(before, after, "a changed lead line must not keep a standing approval valid")

    def test_editing_the_subject_invalidates_a_standing_approval(self):
        rid, r = self.row(keys=["register:79"], channel="legal", conversation_id="", gmail_thread="",
                          requester_email="e@f.co", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Body.\n", channel="legal")
        with self.approved_copy():
            before = approval.digest("ask", send.materialise(self.run, [dict(item)]))
        with self.approved_copy(), mock.patch.object(copy, "NEW_THREAD_SUBJECT", "About your Muso.AI request: {request_type}"):
            after = approval.digest("ask", send.materialise(self.run, [dict(item)]))
        self.assertNotEqual(before, after, "a changed SUBJECT must not keep a standing approval valid")

    def test_changing_only_the_recipient_invalidates_a_standing_approval(self):
        """QA finding on #1749: the digest bound kind, row, body and subject but NOT the address a new-thread letter
        is sent to. `requester_email` is a register field a later intake or a hand-edit can change, so an approval cut
        for A still authorised the identical letter to B - one person's erasure request, in our words, delivered to
        somebody else. The body does not change when the address does, so only binding the recipient catches it."""
        rid, r = self.row(keys=["register:82"], channel="legal", conversation_id="", gmail_thread="",
                          requester_email="first@example.com", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Body.\n", channel="legal")
        with self.approved_copy():
            before = approval.digest("ask", send.materialise(self.run, [dict(item)]))
            self.assertEqual(send.materialise(self.run, [dict(item)])[0]["recipient"], "first@example.com")
            self.s.update(rid, "ask", requester_email="second@example.com")
            after = approval.digest("ask", send.materialise(self.run, [dict(item)]))
        self.assertNotEqual(before, after,
                            "a changed RECIPIENT must not keep a standing approval valid - the same letter would go "
                            "to a different person")

    def test_deliver_refuses_a_recipient_the_approval_did_not_name(self):
        """The digest is only half of it: `deliver()` re-reads the row, so it must also refuse when the address it
        would send to is not the one the materialised (approved) item carries. Otherwise a row edited between the
        approval and the send still leaves, and the digest binding would be decoration."""
        rid, r = self.row(keys=["register:83"], channel="legal", conversation_id="", gmail_thread="",
                          requester_email="approved@example.com", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Body.\n", channel="legal")
        with self.approved_copy():
            items = send.materialise(self.run, [dict(item)])
        self.s.update(rid, "ask", requester_email="swapped@example.com")
        sent = []
        with self.approved_copy(), \
                mock.patch.object(send, "_mail_send_new_thread", lambda *a, **k: sent.append(a) or "gog-msg-3"):
            out = send.deliver(self.run, items[0], "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "refused")
        self.assertIn("approved recipient approved@example.com", out["why"])
        self.assertIn("swapped@example.com", out["why"])
        self.assertEqual(sent, [], "nothing may reach the writer when the recipient moved after approval")

    def test_a_batch_with_no_new_thread_rows_keeps_its_old_digest(self):
        """Bound only when present: an in-thread batch must hash exactly as it did before this change, or every
        standing approval would be silently invalidated by a hardening fix."""
        rid, r = self.row()          # intercom
        item = self.item(rid, text="Body.\n")
        items = send.materialise(self.run, [dict(item)])
        self.assertEqual(items[0]["subject"], "")
        # reproduce the OLD digest formula by hand and require equality
        import hashlib
        h = hashlib.sha256(); h.update(b"ask")
        h.update(f"\n{items[0]['register_no']}:{items[0]['row']}:"
                 f"{hashlib.sha256(items[0]['text'].encode()).hexdigest()}".encode())
        self.assertEqual(approval.digest("ask", items), h.hexdigest()[:approval.DIGEST_LEN])

    def test_materialise_does_not_double_prepend_on_deliver(self):
        """`deliver()` applies the lead itself for callers that did not materialise. On an ALREADY materialised item it
        must not prepend again, or the customer gets the line twice and the body differs from the digest."""
        rid, r = self.row(keys=["register:80"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="g@h.co", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Body.\n", channel="notices")
        with self.approved_copy():
            items = send.materialise(self.run, [dict(item)])
        seen = {}

        def fake_send(email, text, approved_by, dry_run=False, key="", mailbox="", subject=""):
            seen.update(text=text)
            return "gog-msg-2"
        with self.approved_copy(), mock.patch.object(send, "_mail_send_new_thread", fake_send):
            send.deliver(self.run, items[0], "ask", "U7RP6HKUZ")
        self.assertEqual(seen["text"].count("You wrote to us at notices@muso.ai"), 1,
                         "the lead must appear exactly once")

    def test_a_refused_row_is_not_given_a_lead_it_cannot_send(self):
        """A row with no email will be ledgered refused. Binding a lead to it would invent an approval for a letter
        that can never leave, and would change the digest of a batch whose content did not really change."""
        rid, r = self.row(keys=["register:81"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="", received_at="2026-09-01T10:00:00Z")
        item = self.item(rid, text="Body.\n", channel="notices")
        with self.approved_copy():
            items = send.materialise(self.run, [dict(item)])
        self.assertEqual(items[0]["text"], "Body.\n")
        self.assertEqual(items[0]["subject"], "")

    def test_the_request_type_follows_the_class_within_the_approved_vocabulary(self):
        """deletion / access / correction / objection, and the rendered line names the one the row actually is.

        BUT the approved SUBJECT is the deletion one (ruling gdpr-support-from-1104): the four-class vocabulary
        supplies the WORD, the GO supplies the right to SAY it. So an access row has a request-type phrase and still
        refuses - 'stays refused until its own subject is written' - rather than shipping the deletion subject."""
        self.assertEqual(copy.new_thread_request_type("privacy_erasure"), "your deletion request")
        self.assertEqual(copy.new_thread_request_type("privacy_access"), "your access request")
        self.assertEqual(copy.new_thread_subject("privacy_erasure"), "Your Muso.AI data deletion request")
        with self.assertRaises(copy.NoApprovedSubject) as e:
            copy.new_thread_subject("privacy_access")
        self.assertIn("privacy_access", str(e.exception))
        self.assertIn("gdpr-support-from-1104", str(e.exception))
        for cls in ("privacy_access", "privacy_correction", "privacy_objection"):
            rid, r = self.row(**{"keys": [f"register:{cls}"], "channel": "notices", "conversation_id": "",
                                 "gmail_thread": "", "requester_email": "a@b.co", "class": cls})
            with self.approved_copy():
                with self.assertRaises(send.Unknown) as e:
                    send.route(r)
            self.assertIn("no approved SUBJECT line", str(e.exception),
                          f"{cls} must refuse on its SUBJECT, not borrow the deletion one")
        rid, r = self.row(**{"keys": ["register:del"], "channel": "notices", "conversation_id": "",
                             "gmail_thread": "", "requester_email": "a@b.co", "class": "privacy_erasure"})
        with self.approved_copy():
            self.assertEqual(send.route(r), ("mail_new_thread", "a@b.co"))

    def test_an_unwritable_notices_thread_routes_to_a_new_thread_once_the_lead_is_approved(self):
        """THE SHAPE THE REGISTER ACTUALLY HAS. On 2026-11-04 every open notices@/legal@ row (48 / 24) carries a
        gmail_thread and none is threadless, so a rule keyed on "no thread" would have unblocked nobody. The
        unwritable mailbox itself is what selects option 2."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="person@example.com")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                self.approved_copy():
            self.assertEqual(send.route(r), ("mail_new_thread", "person@example.com"))

    def test_an_unwritable_notices_thread_with_no_email_names_both_blockers(self):
        """54 of the 72 notices@/legal@ rows carry no requester_email, so "no address" is the COMMON case, not an
        edge. It must read as two separate facts - the thread cannot be written and there is nowhere else to write -
        because the fix for each is different (auth the mailbox vs recover the address from the original message)."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                self.approved_copy():
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        msg = str(e.exception)
        self.assertIn("1a1a436083a51047", msg)
        self.assertIn("no requester_email", msg)
        self.assertIn("recovered from the original", msg)

    def test_an_unreadable_gog_never_routes_an_alias_thread_in_thread(self):
        """UNMEASURABLE IS NOT WRITABLE. `gog auth list -j` failing (no gog, a 30 s timeout, unreadable JSON) used to
        read as "writable", so a notices@/legal@ thread took the in-thread route and `_mail_send` then tried to reply
        in it FROM support@ - a thread support@ does not own. A doomed attempt on a statutory letter, selected by a
        transient read, while the approved new thread from support@ was available the whole time."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="person@example.com")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", None), \
                self.approved_copy():
            self.assertEqual(send.route(r), ("mail_new_thread", "person@example.com"))

    def test_an_unreadable_gog_still_replies_in_our_own_support_thread(self):
        """The one mailbox we may assume we can write when we cannot ask is the one we SEND from: there the writer is
        the backstop and there is no other route to take, so an unreadable discovery must not push support@ rows onto
        the new-thread path (that would be a different letter to a different relationship)."""
        rid, r = self.row(keys=["gmail:support@muso.ai:t1"], channel="support", conversation_id="",
                          gmail_thread="1a176619567e3fe0", requester_email="person@example.com")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", None):
            self.assertEqual(send.route(r), ("mail", "1a176619567e3fe0"))

    def test_an_unreadable_gog_still_names_the_PERMANENT_alias_reason(self):
        """When the thread's owner is an alias, the reason a letter cannot be threaded there is permanent (an alias is
        not an account), so it must be the one reported - not the transient "we could not ask gog". An operator who
        reads the transient reason goes looking for a mailbox that does not exist instead of recovering the address."""
        rid, r = self.row(keys=["gmail:legal@muso.ai:t1"], channel="legal", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e", requester_email="")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", None), \
                self.approved_copy():
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        msg = str(e.exception)
        self.assertIn("alias for a person", msg)
        self.assertIn("no requester_email", msg)
        self.assertNotIn("cannot be determined", msg)

    def test_a_writable_thread_still_wins_over_option_2(self):
        """If the mailbox is ever authed the reply goes in the THREAD, never a new thread. Option 2 is the fallback,
        not the preferred route - otherwise authing the mailbox would change behaviour it should not."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="person@example.com")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"notices@muso.ai": {"gmail"}}), \
                mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", True):
            self.assertEqual(send.route(r), ("mail", "1a1a436083a51047"))

    def test_option_2_does_not_spread_to_other_channels_with_an_unwritable_mailbox(self):
        """Option 2 is ONLY for the two mailboxes 073 named. A third channel keeps the plain mailbox refusal rather
        than quietly acquiring a new-thread route."""
        rid, r = self.row(keys=["gmail:register@muso.ai:t1"], channel="register", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", True):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("no known mailbox", str(e.exception))

    def test_the_same_legal_thread_routes_once_the_mailbox_is_authed(self):
        rid, r = self.row(keys=["gmail:legal@muso.ai:t1"], channel="legal", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}, "legal@muso.ai": {"gmail"}}):
            self.assertEqual(send.route(r), ("mail", "1a073f2a93c21a6e"))
            # The thread is owned by legal@ (that is what makes it replyable in-thread at all), but the letter still
            # leaves from support@ - the two facts are deliberately separate tables.
            self.assertEqual(send.THREAD_MAILBOX_BY_CHANNEL["legal"], "legal@muso.ai")
            self.assertEqual(send.mailbox_of(r), "support@muso.ai")

    def test_a_mailbox_in_gog_without_the_gmail_service_is_still_refused(self):
        """A channel whose thread mailbox IS a real account but lacks the gmail service keeps the plain refusal, and
        keeps the "enable gmail" advice - that advice is true here and false for the two aliases, which is why the
        two cases are phrased differently. `register` is used because notices@/legal@ are aliases now."""
        rid, r = self.row(keys=["gmail:register@muso.ai:t9"], channel="register", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e", requester_email="")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"register@muso.ai": {"calendar", "drive"}}), \
                mock.patch.dict(send.THREAD_MAILBOX_BY_CHANNEL, {"register": "register@muso.ai"}):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("without the gmail service", str(e.exception))

    def test_a_row_with_nothing_to_reply_to_is_refused(self):
        rid, r = self.row(keys=["register:77"], channel="register", conversation_id="", gmail_thread="",
                          requester_email="")
        with self.assertRaises(send.Unknown):
            send.route(r)

    def test_a_non_numeric_conversation_id_is_refused(self):
        rid, r = self.row(conversation_id="conv-abc")
        with self.assertRaises(send.Unknown):
            send.route(r)

    # ---- the ledger ----------------------------------------------------------------------------------------
    def test_one_letter_per_request(self):
        rid, _ = self.row()
        sent = []
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": sent.append(c) or "api-log 12:00Z posted"):
            first = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
            again = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(first["state"], "sent")
        self.assertEqual(again["state"], "skipped")
        self.assertEqual(len(sent), 1, "the ledger's UNIQUE(request+kind) is what stops a second letter")
        rec = self.s.send_record(rid, "confirm")
        self.assertEqual((rec["state"], rec["channel"], rec["target"], rec["ref"]),
                         ("sent", "intercom", "215476650395415", "api-log 12:00Z posted"))

    def test_the_ledger_row_is_written_BEFORE_the_writer_runs(self):
        """A crash mid-send must leave a `sending` row, never a letter the register does not know about."""
        rid, _ = self.row()
        seen = {}

        def boom(conv, text, approved_by, dry_run, key=""):
            seen.update(self.s.send_record(rid, "confirm"))
            raise send.Unknown("writer died halfway")

        with mock.patch.object(send, "_intercom_send", boom):
            out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(seen["state"], "sending")
        self.assertEqual(out["state"], "failed")
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "failed")
        self.assertEqual(len(self.run.errors), 1, "a failed send is an error the run exits 2 on")

    def test_an_ambiguous_failure_is_never_retried(self):
        """r5 finding 1, the double-send. The writer ran and we cannot prove what it did (timeout, dropped
        connection, non-zero exit), so the row is `unknown`: a human reconciles it. A retry would be a second
        statutory letter for one request."""
        rid, _ = self.row()
        calls = []

        def boom(conv, text, approved_by, dry_run=False, key=""):
            calls.append(key)
            raise send.Ambiguous("read timed out after the request was written")

        with mock.patch.object(send, "_intercom_send", boom):
            first = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
            again = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(first["state"], "unknown")
        self.assertEqual(again["state"], "skipped")
        self.assertEqual(len(calls), 1, "the adapter ran ONCE: an ambiguous failure is never retried")
        rec = self.s.send_record(rid, "confirm")
        self.assertEqual(rec["state"], "unknown")
        self.assertIn("AMBIGUOUS", self.run.errors[0][1] if isinstance(self.run.errors[0], tuple)
                      else str(self.run.errors[0]))
        self.assertTrue(rec["idem"], "the letter's id is on the ledger row, for reconciliation")

    def test_a_TIMEOUT_is_never_retried_on_the_intercom_route(self):
        """r5 review of 89c20722d: a timeout is raised BY subprocess.run, so it is raised AFTER the wrapper was
        invoked - but it is a SubprocessError, so it fell into the retryable `failed` handler and the retry sent a
        second letter. Exercised through the REAL `_intercom_send` with only subprocess.run stubbed."""
        rid, _ = self.row()
        calls = []

        def timing_out(cmd, **kw):
            calls.append(cmd)
            raise subprocess.TimeoutExpired(cmd, 120)

        with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                mock.patch.object(send.subprocess, "run", timing_out):
            first = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
            again = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(first["state"], "unknown")
        self.assertEqual(again["state"], "skipped")
        self.assertEqual(len(calls), 1, "the writer ran ONCE across two attempts: one letter, not two")
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "unknown")

    def test_a_TIMEOUT_is_never_retried_on_the_mail_route(self):
        """Same finding through the mail adapter, which needs a readable thread first: the read succeeds, the SEND
        times out, and that timeout is ambiguous because gog already ran."""
        rid, _ = self.row(keys=["gmail:support@muso.ai:t1"], channel="support", conversation_id="",
                          gmail_thread="1a176619567e3fe0")
        thread = {"thread": {"messages": [{"payload": {"headers": [{"name": "Subject",
                                                                    "value": "My Muso profile"}]}}]}}
        sends = []

        def fake_run(cmd, **kw):
            if "get" in cmd:
                return mock.Mock(returncode=0, stdout=json.dumps(thread), stderr="")
            sends.append(cmd)
            raise subprocess.TimeoutExpired(cmd, 180)

        with mock.patch.dict(os.environ, {"GOG_KEYRING_PASSWORD": "x"}), \
                mock.patch.object(send.shutil, "which", lambda n: "/usr/local/bin/gog"), \
                mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(send.subprocess, "run", fake_run):
            first = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
            again = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(first["state"], "unknown")
        self.assertEqual(again["state"], "skipped")
        self.assertEqual(len(sends), 1, "gog gmail send ran ONCE across two attempts")
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "unknown")

    def test_a_TIMED_OUT_thread_read_is_retryable_because_nothing_was_written(self):
        """The mirror, so the fix does not over-correct: the thread READ is the one call where a timeout is safe to
        retry, and the ledger must say why instead of showing a bare `failed`."""
        rid, _ = self.row(keys=["gmail:support@muso.ai:t1"], channel="support", conversation_id="",
                          gmail_thread="1a176619567e3fe0")
        reads = []

        def timing_out(cmd, **kw):
            reads.append(cmd)
            raise subprocess.TimeoutExpired(cmd, 120)

        with mock.patch.dict(os.environ, {"GOG_KEYRING_PASSWORD": "x"}), \
                mock.patch.object(send.shutil, "which", lambda n: "/usr/local/bin/gog"), \
                mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(send.subprocess, "run", timing_out):
            out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        rec = self.s.send_record(rid, "confirm")
        self.assertEqual(out["state"], "failed", "a read timeout is retryable: nothing left the host")
        self.assertEqual(rec["state"], "failed")
        self.assertIn("nothing was written", rec["detail"])
        self.assertEqual(len([c for c in reads if "thread" in c]), 1, "and no send was attempted at all")
        self.assertFalse([c for c in reads if "send" in c], "gog gmail send must not run after a failed read")

    def test_a_definite_failure_is_still_retryable(self):
        """The mirror of the test above: when the writer never ran (a missing token), nothing reached the customer, so
        the row stays retryable - refusing to retry here would strand a request forever."""
        rid, _ = self.row()
        calls = []

        def flaky(conv, text, approved_by, dry_run=False, key=""):
            calls.append(key)
            if len(calls) == 1:
                raise send.Unknown("MUSOAI_INTERCOM_TOKEN is not set")
            return "posted"

        with mock.patch.object(send, "_intercom_send", flaky):
            first = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
            second = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual((first["state"], second["state"]), ("failed", "sent"))
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], calls[1], "a retry of the same letter carries the same id")
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "sent")

    def test_a_send_sets_confirmed_at_and_the_audit_trail(self):
        rid, _ = self.row()
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": "posted"):
            send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        r = self.s.get(rid)
        self.assertTrue(r["confirmed_at"])
        self.assertEqual(r["confirm_ref"], "posted")
        self.assertIn("confirmed", [e["kind"] for e in self.s.events(rid)])

    def test_an_ask_stamps_ask_sent_at(self):
        rid, _ = self.row()
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": "posted"):
            send.deliver(self.run, self.item(rid, text=copy.ASK["ASK_LINK"]), "ask", "U7RP6HKUZ")
        r = self.s.get(rid)
        self.assertTrue(r["ask_sent_at"])
        self.assertEqual(r["ask_ref"], "posted")

    def test_the_body_sha_is_the_copy_that_went_out(self):
        rid, _ = self.row()
        text = copy.ASK["ASK_IDENTITY"]
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": "posted"):
            send.deliver(self.run, self.item(rid, text=text), "ask", "U7RP6HKUZ")
        self.assertEqual(self.s.send_record(rid, "ask")["body_sha"], send.body_sha(text))

    def test_an_unroutable_row_is_ledgered_as_refused_not_silently_skipped(self):
        rid, _ = self.row(keys=["gmail:legal@muso.ai:t1"], channel="legal", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e", requester_email="")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}):
            out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(out["state"], "refused")
        rec = self.s.send_record(rid, "confirm")
        self.assertEqual((rec["state"], rec["channel"]), ("refused", "none"))
        self.assertIn("legal@muso.ai", rec["detail"])
        self.assertIn("no requester_email", rec["detail"],
                      "with both copy GOs open the remaining blocker is the missing address, and it must be named")

    def test_every_channel_sends_from_support_because_the_others_are_aliases(self):
        """Captain, 2026-11-06: "can you use support as your outbound channel please". legal@muso.ai is an alias for
        Aaron and notices@muso.ai is an alias for Kyran - neither is an account this host can sign into, so there is
        nothing to send AS. This pins the wiring into the adapter, which is what actually leaves the building: a
        `mailbox_of` assertion alone would prove the lookup, not the send.

        The OLD rule here was "a legal@ reply leaves from legal@". It was right while legal@ was believed to be an
        account; it is wrong now, and leaving it in place would have made every legal@ letter fail at gog."""
        for channel, thread in (("legal", "1a073f2a93c21a6e"), ("notices", "1a1a436083a51047"),
                                ("support", "1a11c64e6b139977")):
            rid, _ = self.row(keys=[f"gmail:{channel}@muso.ai:{thread}"], channel=channel, conversation_id="",
                              gmail_thread=thread)
            seen = {}

            def fake_mail(thread_id, text, approved_by, dry_run=False, key="", mailbox=""):
                seen.update(thread_id=thread_id, mailbox=mailbox, key=key)
                return "message 1a17 sent"

            with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                    mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"},
                                                          f"{channel}@muso.ai": {"gmail"}}), \
                    mock.patch.object(send, "_mail_send", fake_mail):
                out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
            self.assertEqual(out["state"], "sent", channel)
            self.assertEqual(seen["mailbox"], "support@muso.ai",
                             f"a {channel} letter must leave from support@, the only account we can send as")
            self.assertEqual(seen["thread_id"], thread)

    def test_the_lead_line_still_names_the_mailbox_the_person_wrote_to(self):
        """The send account and the address the person chose are now DIFFERENT, and the lead line exists to name the
        second one. Collapsing the two tables would have made every notices@/legal@ letter open with "you wrote to
        support@muso.ai", which is false and is the one sentence in the letter that has to be true."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="person@example.com",
                          received_at="2026-10-21T18:14:00Z")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                self.approved_copy():
            body, subject, to = send.final_letter(self.s.get(rid), "the body")
        self.assertEqual(to, "person@example.com")
        self.assertIn("notices@muso.ai", body, "the lead names the mailbox the person actually wrote to")
        self.assertNotIn("you wrote to support@muso.ai", body)

    def test_a_dry_run_writes_nothing_at_all(self):
        """Nothing left the host, so there is nothing to guard against: a rehearsal must not consume the one send
        slot (a `refused` row here would make the real send a skip)."""
        rid, _ = self.row()
        out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ", dry_run=True)
        self.assertEqual((out["state"], out["channel"]), ("dry-run", "intercom"))
        self.assertFalse(self.s.get(rid)["confirmed_at"], "a dry run must not date the row")
        self.assertIsNone(self.s.send_record(rid, "confirm"))

    def test_a_refused_route_is_retryable_once_it_is_fixed(self):
        """A `refused` row is retryable by design, and the fix that unblocks it now is recovering the ADDRESS: with
        both copy GOs open, an unwritable legal@ thread routes to a new thread from support@ the moment the row has
        somewhere to send to. That is the same slot reused, not a second letter."""
        rid, _ = self.row(keys=["gmail:legal@muso.ai:t1"], channel="legal", conversation_id="",
                          gmail_thread="1a073f2a93c21a6e", requester_email="")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}):
            self.assertEqual(send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")["state"], "refused")
        # ... the address is recovered from the original message, and the next attempt reuses the slot
        self.s.db.execute("UPDATE erasure_requests SET requester_email='person@example.com' WHERE id=?", (rid,))
        self.s.db.commit()
        seen = {}

        def fake_new_thread(email, text, approved_by, dry_run=False, key="", mailbox="", subject=""):
            seen.update(email=email, subject=subject)
            return "gog-msg-2"

        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(send, "_mail_send_new_thread", fake_new_thread):
            out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(out["state"], "sent")
        self.assertEqual(seen["email"], "person@example.com")
        self.assertEqual(seen["subject"], "Your Muso.AI data deletion request")
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "sent")

    def test_the_watchdog_names_why_a_letter_never_left(self):
        """`no letter sent` covers both "waiting on a decision" and "the pipeline tried and the route refused". The
        second has to say so, or 24 rows read as a broken pipeline and nobody knows the fix is a mailbox."""
        from gdpr_pipeline import send as _send
        rid, _ = self.s.upsert({"keys": ["notices:5"], "channel": "notices", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "x@example.com",
                                "due_at": "2026-10-25T10:00:00Z"})
        self.s.begin_send(rid, "ask", "mail", "thread-1", _send.body_sha("x"), "U0AN41ZBTRU", state="refused",
                          detail="notices@ thread t-1 is in a mailbox gog cannot write on this host")
        line = [ln for _, ln in self.run.watchdog_rows(datetime(2026, 11, 4, tzinfo=timezone.utc)) if f"#{self.s.get(rid)['register_no']} " in ln][0]
        self.assertIn("no letter sent", line)
        self.assertIn("the ask letter is refused", line)
        self.assertIn("mailbox gog cannot write", line)

    def test_the_watchdog_names_why_a_CONFIRMATION_never_left(self):
        """The ask branch above only runs when there is NO ledger record. A confirmation that was attempted and
        refused HAS one, so it took the `letter refused ... via none` path and named no reason at all - the exact
        rows this change exists to explain (QA 11-05)."""
        from gdpr_pipeline import send as _send
        rid, _ = self.s.upsert({"keys": ["notices:7"], "channel": "notices", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "x@example.com",
                                "due_at": "2026-10-25T10:00:00Z"})
        self.s.begin_send(rid, "confirm", "none", "", _send.body_sha("x"), "U0AN41ZBTRU", state="refused",
                          detail="notices@ thread t-1 is in a mailbox gog cannot write on this host")
        line = [ln for _, ln in self.run.watchdog_rows(datetime(2026, 11, 4, tzinfo=timezone.utc)) if f"#{self.s.get(rid)['register_no']} " in ln][0]
        self.assertIn("letter refused", line)
        self.assertIn("mailbox gog cannot write", line)
        self.assertNotIn("no letter sent", line)

    def test_a_sent_confirmation_does_not_carry_a_stale_reason(self):
        """The reason belongs to the ATTEMPT, not to the row: once a later attempt lands, the line must not keep
        quoting the earlier refusal."""
        from gdpr_pipeline import send as _send
        rid, _ = self.s.upsert({"keys": ["notices:8"], "channel": "notices", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "x@example.com",
                                "due_at": "2026-10-25T10:00:00Z"})
        self.s.begin_send(rid, "confirm", "none", "", _send.body_sha("x"), "U0AN41ZBTRU", state="refused",
                          detail="mailbox gog cannot write")
        self.s.claim_send(rid, "confirm", "mail", "t-1", _send.body_sha("x"), "U0AN41ZBTRU")
        self.s.finish_send(rid, "confirm", "sent", ref="posted")
        line = [ln for _, ln in self.run.watchdog_rows(datetime(2026, 11, 4, tzinfo=timezone.utc)) if f"#{self.s.get(rid)['register_no']} " in ln][0]
        self.assertIn("letter sent", line)
        self.assertNotIn("mailbox gog cannot write", line)

    def test_the_watchdog_names_a_row_with_no_route_before_anything_is_attempted(self):
        """A row with neither a conversation nor a thread has no route at all, and nothing has ever been sent, so
        there is no ledger record to quote. The route check runs first, so the page names the blocker on day one
        instead of after a failed attempt.

        This used to use a notices@ row whose thread sat in an unwritable mailbox. That row HAS a route now (#1749
        opens a new thread from support@ for exactly that shape), so the case moved to a channel with no new-thread
        option - see the companion test below for the row that gained one."""
        rid, _ = self.s.upsert({"keys": ["support:6"], "channel": "support", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "x@example.com",
                                "due_at": "2026-10-25T10:00:00Z"})
        self.assertIsNone(self.s.send_record(rid, "ask"))
        line = [ln for _, ln in self.run.watchdog_rows(datetime(2026, 11, 4, tzinfo=timezone.utc)) if f"#{self.s.get(rid)['register_no']} " in ln][0]
        self.assertIn("no route for a letter", line)
        self.assertIn("nothing to reply to", line)

    def test_the_watchdog_does_not_call_a_new_thread_row_unroutable(self):
        """The other half of the same change: a notices@ row whose thread is in a mailbox this host cannot write is
        NOT unroutable any more - #1749 opens a new thread from support@. The page must not tell a human to go fix a
        mailbox that is not the blocker."""
        rid, _ = self.s.upsert({"keys": ["notices:6"], "channel": "notices", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "x@example.com",
                                "gmail_thread": "t-9", "due_at": "2026-10-25T10:00:00Z"})
        line = [ln for _, ln in self.run.watchdog_rows(datetime(2026, 11, 4, tzinfo=timezone.utc)) if f"#{self.s.get(rid)['register_no']} " in ln][0]
        self.assertNotIn("no route for a letter", line)
        self.assertIn("no letter sent", line)

    def test_a_row_with_a_route_still_reads_as_plain_no_letter_sent(self):
        rid, _ = self.s.upsert({"keys": ["intercom:77"], "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "conversation_id": "215476650395999",
                                "due_at": "2026-10-25T10:00:00Z"})
        line = [ln for _, ln in self.run.watchdog_rows(datetime(2026, 11, 4, tzinfo=timezone.utc)) if f"#{self.s.get(rid)['register_no']} " in ln][0]
        self.assertIn("no letter sent", line)
        self.assertNotIn("no route for a letter", line)

    def test_a_claim_that_never_finished_is_never_retried_by_the_pipeline(self):
        """`sending` means the writer may have reached the customer: only a human may clear it."""
        rid, _ = self.row()
        self.s.begin_send(rid, "confirm", "intercom", "1", send.body_sha("x"), "U7RP6HKUZ")
        sent = []
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": sent.append(c) or "posted"):
            out = send.deliver(self.run, self.item(rid), "confirm", "U7RP6HKUZ")
        self.assertEqual(out["state"], "skipped")
        self.assertEqual(sent, [], "a claimed-but-unfinished send is a human's to resolve")
        self.assertIn("unfinished", out["why"])

    # ---- the adapters --------------------------------------------------------------------------------------
    def test_the_intercom_writer_is_invoked_in_purpose_mode_not_as_a_human(self):
        """A statutory letter is not a human request, so the writer is called with `--purpose gdpr-erasure`.

        Until 2026-11-06 this passed the sender seat as BOTH `--requested-by` and `--approved-by`. The writer's human
        allowlist refused every one of those (the seat is a bot), and had it accepted them the audit log would have
        asserted that a named human approved a customer-facing reply - false for an unattended standing-ruling send.
        The purpose mode records `approved_by: system:gdpr-pipeline` and lets the writer check, below us, that the
        erasure register owns the conversation.
        """
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            return mock.Mock(returncode=0, stdout="api-log 6 posted\n", stderr="")

        with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                mock.patch.object(send.subprocess, "run", fake_run):
            ref = send._intercom_send("215476650395415", copy.ASK["ASK_LINK"], "U0AN41ZBTRU", dry_run=False)
        cmd = calls[0]
        self.assertIn("reply", cmd)
        self.assertIn("--customer-facing", cmd)
        self.assertEqual(cmd[cmd.index("--purpose") + 1], "gdpr-erasure")
        self.assertNotIn("--approved-by", cmd, "a purpose write must never name a human approver")
        self.assertNotIn("--requested-by", cmd, "a purpose write must never name a human requester")
        self.assertEqual(cmd[cmd.index("--body") + 1], copy.ASK["ASK_LINK"], "the approved copy, verbatim")
        self.assertEqual(ref, "api-log 6 posted")

    def test_a_post_that_failed_after_the_writer_ran_is_ambiguous_not_a_plain_failure(self):
        """The writer RAN and the POST failed: Intercom may hold the reply. That is `Ambiguous` (never retried), not
        `Unknown` (retryable) - r5 finding 1, the double-send. `POST FAILED (curl rc=...)` is the real output of
        intercom-ops-write.sh:276, i.e. the curl POST at :267 was attempted."""
        with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                mock.patch.object(send.subprocess, "run",
                                  lambda cmd, **kw: mock.Mock(
                                      returncode=1, stdout="",
                                      stderr="POST FAILED (curl rc=7) for https://api.intercom.io/x; the write "
                                             "was logged at /var/log/x but may not have landed.")):
            with self.assertRaises(send.Ambiguous) as e:
                send._intercom_send("1", "text", "U7RP6HKUZ", dry_run=False)
        self.assertIn("POST FAILED", str(e.exception))

    def test_a_writer_REFUSAL_is_retryable_because_nothing_was_posted(self):
        """`REFUSED:` is the writer's own pre-flight refusal, and it is provably pre-send: every `refuse()` call in
        intercom-ops-write.sh is an argument/allowlist/leak check that runs BEFORE the POST (all 15 call sites are
        at lines 155-207; the curl POST is at line 267). Nothing was posted, so this must be `Unknown` (retryable
        once a human fixes the cause), not `Ambiguous`.

        Classifying it as ambiguous wedged 114 rows in `unknown` on 2026-11-06/07 - every one of them
        `REFUSED: U0AN41ZBTRU is not on the Intercom write allowlist` - so the confirm batch approved 20 letters
        and delivered zero, and adding the seat to the allowlist could not unstick a single row."""
        with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                mock.patch.object(send.subprocess, "run",
                                  lambda cmd, **kw: mock.Mock(
                                      returncode=1, stdout="",
                                      stderr="REFUSED: U0AN41ZBTRU is not on the Intercom write allowlist "
                                             "(Aaron U7RP6HKUZ, Jan U038BM16T7W, Nick U0AL3...). Intercom writes "
                                             "need one of them to ask; everyone else is read-only.")):
            with self.assertRaises(send.Unknown) as e:
                send._intercom_send("1", "text", "U7RP6HKUZ", dry_run=False)
        self.assertIn("not on the Intercom write allowlist", str(e.exception))
        # Case-insensitive on purpose: this asserts that the refusal is REPORTED AS PRE-SEND and quotes the writer,
        # not that a particular word is capitalised. The reconcile path (#1820) renders the same fact as "refused
        # BEFORE posting" for emphasis, and pinning the casing made two correct messages disagree in a test.
        self.assertIn("refused before posting", str(e.exception).lower())

    def test_a_FAILED_AUDIT_WRITE_is_failed_not_unknown_through_the_PIPELINE(self):
        """QA #1820 finding 1: the writer-side test was not enough - the whole delivery path has to stay retryable.

        When `intercom-ops-write.sh` cannot write its audit record it exits 2 with `ERROR:`, ABOVE the POST. But bash
        prints its own diagnostic first:

            under-test.sh: line 463: /opt/.../intercom-reply-….json: Permission denied
            ERROR: cannot write the audit record …; refusing to write unlogged. Nothing was posted.

        `msg.startswith("ERROR:")` was False on that stderr, so this was read as Ambiguous, `deliver` recorded
        `unknown`, and a letter nobody received became a human's forever. The prefix is now matched per LINE, and this
        drives `deliver` rather than the writer alone so the LEDGER is what is asserted.
        """
        stderr = ("/opt/hydra/scripts/intercom-ops-write.sh: line 463: /opt/hydra/workspaces/operations/api-logs/"
                  "intercom-reply-215476650395415-20261108T035405Z-1.json: Permission denied\n"
                  "ERROR: cannot write the audit record /opt/hydra/workspaces/operations/api-logs/"
                  "intercom-reply-215476650395415-20261108T035405Z-1.json; refusing to write unlogged. "
                  "Nothing was posted.")
        store = Store(":memory:")
        run = Run(store, log=lambda *_: None)
        rid, _ = store.upsert({"keys": ["intercom:1820"], "channel": "intercom", "class": "privacy_erasure",
                               "received_at": "2026-09-01T10:00:00Z", "requester_email": "a@b.co",
                               "conversation_id": "215476650395415", "requester_name": "A Person",
                               "pages": [{"entity": "profile", "id": ARPAD}]})
        with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                mock.patch.object(send.subprocess, "run",
                                  lambda cmd, **kw: mock.Mock(returncode=2, stdout="", stderr=stderr)):
            out = send.deliver(run, {"row": rid, "text": "We removed your profile.", "register_no": 1},
                               "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "failed", f"a pre-POST writer failure must be retryable, got {out}")
        rec = store.send_record(rid, "ask")
        self.assertEqual(rec["state"], "failed")
        self.assertIn("refused BEFORE posting", rec["detail"])
        # The invariant that matters to the ledger: `failed` can be re-claimed, so the next tick retries it.
        store.claim_send(rid, "ask", "intercom", "215476650395415", send.body_sha("We removed your profile."),
                         "U7RP6HKUZ", "sending")
        self.assertEqual(store.send_record(rid, "ask")["state"], "sending")

    def test_a_BARE_nonzero_exit_without_the_prefix_stays_unknown(self):
        """The discriminator must not have been loosened: a bare 1 is still how `set -e` reports an unexpected
        failure, which may have happened AFTER the POST, so it stays `unknown` and stays a human's."""
        store = Store(":memory:")
        run = Run(store, log=lambda *_: None)
        rid, _ = store.upsert({"keys": ["intercom:1821"], "channel": "intercom", "class": "privacy_erasure",
                               "received_at": "2026-09-01T10:00:00Z", "requester_email": "a@b.co",
                               "conversation_id": "215476650395415", "requester_name": "A Person",
                               "pages": [{"entity": "profile", "id": ARPAD}]})
        with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                mock.patch.object(send.subprocess, "run",
                                  lambda cmd, **kw: mock.Mock(returncode=1, stdout="", stderr="killed")):
            out = send.deliver(run, {"row": rid, "text": "We removed your profile.", "register_no": 1},
                               "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "unknown")
        self.assertIn("after being invoked", store.send_record(rid, "ask")["detail"])

    def test_a_writer_refusal_leaves_the_row_RETRYABLE_not_wedged(self):
        """End to end through the ledger: a `REFUSED:` writer must leave the slot `failed` (retryable), never
        `unknown` (a human's to resolve). This is the difference between a batch that recovers once the allowlist
        is fixed and one that is permanently stalled."""
        import tempfile
        from gdpr_pipeline import store as gstore
        with tempfile.TemporaryDirectory() as td:
            db = gstore.Store(os.path.join(td, "e.sqlite"))
            db.claim_send(1, "confirm", "intercom", "215476751087361", "sha", "U7RP6HKUZ", "sending",
                          idem="k1")
            with mock.patch.dict(os.environ, {"MUSOAI_INTERCOM_TOKEN": "x"}), \
                    mock.patch.object(send.subprocess, "run",
                                      lambda cmd, **kw: mock.Mock(
                                          returncode=1, stdout="",
                                          stderr="REFUSED: U0AN41ZBTRU is not on the Intercom write allowlist")):
                with self.assertRaises(send.Unknown):
                    send._intercom_send("215476751087361", "text", "U7RP6HKUZ", dry_run=False)
            # The caller's generic handler records `failed` for Unknown, which is retryable.
            db.finish_send(1, "confirm", "failed", detail="refused before posting")
            self.assertEqual(db.send_record(1, "confirm")["state"], "failed")
            # Retryability is the whole point: `claim_send` refuses to overwrite a `sending`/`unknown` row and
            # allows `failed`/`refused`. So a second attempt must be ACCEPTED here, and would raise for `unknown`.
            db.claim_send(1, "confirm", "intercom", "215476751087361", "sha2", "U7RP6HKUZ", "sending",
                          idem="k2")
            self.assertEqual(db.send_record(1, "confirm")["state"], "sending")
            # And the contrast: an `unknown` row is NOT retryable.
            db.finish_send(1, "confirm", "unknown", detail="ambiguous")
            with self.assertRaises(sqlite3.IntegrityError):
                db.claim_send(1, "confirm", "intercom", "215476751087361", "sha3", "U7RP6HKUZ", "sending",
                              idem="k3")

    def test_a_missing_intercom_token_fails_before_any_write(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(send.Unknown) as e:
                send._intercom_send("1", "text", "U7RP6HKUZ", dry_run=False)
        self.assertIn("MUSOAI_INTERCOM_TOKEN", str(e.exception))

    def test_mail_reply_uses_the_thread_subject_and_reply_all(self):
        thread = {"thread": {"messages": [{"payload": {"headers": [{"name": "Subject",
                                                                    "value": "My Muso profile"}]}}]}}
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            if "thread" in cmd:
                return mock.Mock(returncode=0, stdout=json.dumps(thread), stderr="")
            return mock.Mock(returncode=0, stdout="message 1a17 sent\n", stderr="")

        with mock.patch.dict(os.environ, {"GOG_KEYRING_PASSWORD": "x"}), \
                mock.patch.object(send.shutil, "which", lambda n: "/usr/local/bin/gog"), \
                mock.patch.object(send.subprocess, "run", fake_run):
            ref = send._mail_send("1a176619567e3fe0", copy.ASK["ASK_LINK"], "U7RP6HKUZ", dry_run=False,
                                  mailbox="notices@muso.ai")
        send_cmd = calls[-1]
        self.assertEqual(send_cmd[send_cmd.index("--subject") + 1], "Re: My Muso profile")
        self.assertIn("--reply-all", send_cmd)
        # the reply leaves from the mailbox that OWNS the thread, not from a constant
        self.assertEqual(send_cmd[send_cmd.index("--account") + 1], "notices@muso.ai")
        self.assertEqual(ref, "message 1a17 sent")

    def test_an_unreadable_mail_thread_fails_instead_of_opening_a_new_one(self):
        with mock.patch.dict(os.environ, {"GOG_KEYRING_PASSWORD": "x"}), \
                mock.patch.object(send.shutil, "which", lambda n: "/usr/local/bin/gog"), \
                mock.patch.object(send.subprocess, "run",
                                  lambda cmd, **kw: mock.Mock(returncode=1, stdout="", stderr="404 notFound")):
            with self.assertRaises(send.Unknown) as e:
                send._mail_send("1a073f2a93c21a6e", "text", "U7RP6HKUZ", dry_run=False)
        self.assertIn("not readable", str(e.exception))

    # ---- the gate ------------------------------------------------------------------------------------------
    def _cli(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_send", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        return cli

    def _gate(self, approved_by="U7RP6HKUZ", send_=True, items=None):
        cli = self._cli()
        items = items if items is not None else [{"row": 1, "register_no": 39, "text": "approved letter"}]
        return cli, mock.Mock(send=send_, approved_by=approved_by), items

    def test_the_gate_refuses_while_the_unlock_is_not_compiled_in(self):
        """The compiled constant is the master switch: turned back to False in a future PR (a rollback), every send
        refuses even for an allowlisted human, without touching an adapter."""
        cli, a, items = self._gate()
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", False), self.assertRaises(SystemExit):
            cli.refuse_send(a, "confirm", items)

    def test_the_gate_refuses_a_non_allowlisted_approver_even_when_unlocked(self):
        cli, a, items = self._gate(approved_by="U0AGENTBOT")
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), self.assertRaises(SystemExit):
            cli.refuse_send(a, "confirm", items)

    def test_the_gate_passes_only_with_the_approvers_slack_message_about_this_batch(self):
        """QA review 2026-11-03: an allowlisted UID is a string any caller can type, so it is not a human lock. The
        gate passes only when that human posted the batch digest; without the message it refuses even though the
        unlock is compiled in and the id is allowlisted."""
        cli, a, items = self._gate()
        d = approval.digest("confirm", items)
        seen = {}

        def history(channel, token, oldest):
            seen.update(channel=channel, token=token, oldest=oldest)
            return [{"user": "U7RP6HKUZ",
                     "text": f"APPROVE gdpr confirm {d} ruling=fable-ruling-1103-b3/gdpr-confirmation",
                     "ts": "1.1"}]

        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_APPROVAL_CHANNEL": "C123",
                                             "MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb"}), \
                mock.patch.object(approval, "_history", history):
            cli.refuse_send(a, "confirm", items)                    # no raise: approved
        self.assertEqual(seen["channel"], "C123")

        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_APPROVAL_CHANNEL": "C123",
                                             "MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb"}), \
                mock.patch.object(approval, "_history", lambda *a: []), self.assertRaises(SystemExit):
            cli.refuse_send(a, "confirm", items)                    # no message -> no send

    def test_no_send_flag_means_no_gate_at_all(self):
        cli, a, items = self._gate(send_=False)
        cli.refuse_send(a, "confirm", items)                        # dry run always allowed

    def test_oldest_deadline_first(self):
        cli = self._cli()
        items = [{"due_at": "2026-11-02T00:00:00Z", "register_no": 5},
                 {"due_at": "2026-09-01T00:00:00Z", "register_no": 9},
                 {"due_at": "2026-10-01T00:00:00Z", "register_no": 7}]
        self.assertEqual([x["register_no"] for x in cli.oldest_first(items)], [9, 7, 5])

    def approved_copy(self):
        """BOTH copy gates open. They are separate constants on purpose (the lead line's GO did not mention the
        subject), so a test that expects a ROUTE has to open both - and the tests that pin one gate refusing on its
        own patch only that one, which is what proves they are independent."""
        return mock.patch.multiple(copy, NEW_THREAD_LEAD_APPROVED=True, NEW_THREAD_SUBJECT_APPROVED=True)

    # ---- option 2: a new thread from support@ (firstmate inbox 073) ------------------------------------------
    def test_a_notices_row_with_no_thread_is_refused_until_the_lead_is_approved(self):
        """Option 2: a notices@/legal@ request with no thread opens a new thread from support@, but its mandatory
        first line is a BODY CHANGE, so it needs its own GO. Until verify-sla-driver-fable-d2 approves the one-line
        variant, the route REFUSES with the reason instead of sending copy nobody approved."""
        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="a@b.co")
        with mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", False):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("one-line lead copy is not approved yet", str(e.exception))
        self.assertIn("verify-sla-driver-fable-d2", str(e.exception))

    def test_a_notices_row_with_no_thread_routes_once_the_lead_is_approved(self):
        """The approved one-line variant opens the route: the reply goes to the person's own address, not to a
        thread that does not exist."""
        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="a@b.co")
        with self.approved_copy():
            self.assertEqual(send.route(r), ("mail_new_thread", "a@b.co"))

    def test_a_notices_row_with_no_thread_and_no_email_is_refused_even_when_approved(self):
        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="")
        with self.approved_copy():
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("there is nowhere to open a new thread to", str(e.exception))

    def test_a_legal_row_with_no_thread_routes_once_the_lead_is_approved(self):
        """legal@ is the other mailbox the ruling names; it must take the same path as notices@."""
        rid, r = self.row(keys=["register:78"], channel="legal", conversation_id="", gmail_thread="",
                          requester_email="c@d.co")
        with self.approved_copy():
            self.assertEqual(send.route(r), ("mail_new_thread", "c@d.co"))

    def test_a_register_row_with_no_thread_still_refuses(self):
        """Option 2 is ONLY for the two mailboxes the ruling names. An unknown channel must not borrow it."""
        rid, r = self.row(keys=["register:77"], channel="register", conversation_id="", gmail_thread="",
                          requester_email="a@b.co")
        with mock.patch.object(copy, "NEW_THREAD_LEAD_APPROVED", True):
            with self.assertRaises(send.Unknown) as e:
                send.route(r)
        self.assertIn("no conversation_id and no gmail_thread", str(e.exception))

    def test_the_lead_is_prepended_to_the_body_before_the_sha_is_taken(self):
        """A changed body must be a different letter: the lead goes into the text BEFORE body_sha/idem_key, so the
        ledger records the digest of the text that actually goes out - not the digest of the bare body."""
        rid, r = self.row(keys=["register:77"], channel="notices", conversation_id="", gmail_thread="",
                          requester_email="a@b.co", received_at="2026-09-01T10:00:00Z")
        seen = {}

        def fake_send(email, text, approved_by, dry_run=False, key="", mailbox="", subject=""):
            seen.update(email=email, text=text, subject=subject, mailbox=mailbox)
            return "gog-msg-1"

        bare = "Hello there,\n\nthe approved letter.\n"
        with self.approved_copy(), \
                mock.patch.object(send, "_mail_send_new_thread", fake_send):
            out = send.deliver(self.run, self.item(rid, text=bare), "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "sent")
        self.assertEqual(seen["email"], "a@b.co")
        self.assertEqual(seen["mailbox"], "support@muso.ai")
        self.assertTrue(seen["text"].startswith("You wrote to us at notices@muso.ai on 1 September 2026"),
                        "the lead must be the FIRST line, and it must name the ADDRESS the person wrote to")
        self.assertEqual(seen["subject"], "Your Muso.AI data deletion request",
                         "the subject is customer-facing copy, so it comes from copy.py where it can be reviewed - "
                         "and it follows the SAME vocabulary as the lead, never a fixed 'deletion' on an access row")
        self.assertTrue(seen["text"].endswith(bare), "the approved body follows the lead unchanged")
        rec = self.s.send_record(rid, "ask")
        self.assertEqual(rec["body_sha"], send.body_sha(seen["text"]))
        self.assertNotEqual(rec["body_sha"], send.body_sha(bare),
                            "the ledger must not record the bare body's digest for a letter carrying the lead")

    def test_an_unwritable_thread_with_an_address_sends_a_new_thread_and_is_not_refused(self):
        """Captain, 2026-11-06, item 5: a row whose thread is in a mailbox we cannot write, WITH a requester_email on
        file, must produce a new thread from support@ and must NOT be recorded as refused.

        `route()` alone does not prove this: the refusal the captain is describing happens in `deliver()`, which
        ledgers `refused` and consumes the slot. So this pins the LEDGER, not just the route."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="person@example.com",
                          received_at="2026-10-21T18:14:00Z")
        seen = {}

        def fake_send(email, text, approved_by, dry_run=False, key="", mailbox="", subject=""):
            seen.update(email=email, mailbox=mailbox, subject=subject, text=text)
            return "gog-msg-1"

        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                self.approved_copy(), \
                mock.patch.object(send, "_mail_send_new_thread", fake_send):
            out = send.deliver(self.run, self.item(rid), "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "sent", "an unwritable thread with an address is NOT a refusal")
        self.assertEqual(seen["email"], "person@example.com")
        self.assertEqual(seen["mailbox"], "support@muso.ai", "the new thread leaves from support@")
        rec = self.s.send_record(rid, "ask")
        self.assertEqual(rec["state"], "sent")
        self.assertEqual(rec["channel"], "mail_new_thread")
        self.assertEqual(rec["target"], "person@example.com")

    def test_a_missing_address_refuses_naming_the_address_not_the_mailbox(self):
        """Captain, 2026-11-06, item 5: a row with no address must still refuse, and the message must say the ADDRESS
        is missing rather than that the mailbox is unwritable. Those are different problems with different fixes -
        auth a mailbox vs recover an address - and an operator reading the wrong one chases the wrong thing."""
        rid, r = self.row(keys=["gmail:notices@muso.ai:t9"], channel="notices", conversation_id="",
                          gmail_thread="1a1a436083a51047", requester_email="")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                self.approved_copy():
            out = send.deliver(self.run, self.item(rid), "ask", "U7RP6HKUZ")
        self.assertEqual(out["state"], "refused")
        detail = self.s.send_record(rid, "ask")["detail"]
        self.assertIn("no requester_email", detail)
        self.assertIn("recovered from the original", detail)
        self.assertNotIn("auth it and the route opens", detail,
                         "the mailbox is not the blocker here; naming it sends the operator to the wrong fix")

    def test_a_new_thread_is_not_replied_all(self):
        """`--reply-all` is meaningless on a thread that does not exist yet; the new-thread writer must pass --to and
        must NOT pass --thread-id.

        It also must send as the mailbox it was HANDED. A mutant that hardcodes `--account MAIL_ACCOUNT` here survived
        every other test in this class, because today's only caller happens to pass support@ anyway - so the parameter
        is pinned here rather than left to the caller's good behaviour."""
        seen = {}

        def fake_run(cmd, **kw):
            seen["cmd"] = cmd
            return type("R", (), {"returncode": 0, "stdout": "msg-1\n", "stderr": ""})()

        with mock.patch.object(send.shutil, "which", lambda _: "/usr/bin/gog"), \
                mock.patch.dict(os.environ, {"GOG_KEYRING_PASSWORD": "k"}), \
                mock.patch.object(send.subprocess, "run", fake_run):
            send._mail_send_new_thread("a@b.co", "body", "U7RP6HKUZ", dry_run=False,
                                       mailbox="seat@example.com",
                                       subject="Your Muso.AI data deletion request")
        cmd = seen["cmd"]
        self.assertIn("--to", cmd)
        self.assertIn("a@b.co", cmd)
        self.assertNotIn("--thread-id", cmd)
        self.assertNotIn("--reply-all", cmd)
        self.assertEqual(cmd[cmd.index("--account") + 1], "seat@example.com",
                         "the writer must send as the mailbox it was given, not as a module constant")


class NoStaleLockClaim(unittest.TestCase):
    """r5 finding 3: the systemd unit comment still told an operator sends were locked, which is exactly the sort of
    comment that gets believed during an incident."""

    def test_the_tick_unit_comment_does_not_claim_sends_are_locked(self):
        p = os.path.join(os.path.dirname(__file__), "..", "scripts", "install-aux-units.sh")
        text = open(p).read()
        block = p and text[text.index("# ─── GDPR erasure pipeline"):text.index("GDPRTICKSVC")]
        self.assertNotIn("sends are locked", block)
        self.assertIn("APPROVE gdpr", block, "and say what a HUMAN send does need")

    def test_the_tick_unit_comment_states_the_one_thing_that_authorises_an_unattended_send(self):
        """2026-11-04 (Fable decision B26 Q1): the tick now sends, which replaces the old "the tick cannot send" line.
        The comment must carry the CONDITION instead of a prohibition, because an operator reading "the tick sends on
        its due dates" without "only under a standing ruling, after the veto window" is the misreading that would get
        a statutory letter sent by a cron nobody armed on purpose."""
        p = os.path.join(os.path.dirname(__file__), "..", "scripts", "install-aux-units.sh")
        block = open(p).read()
        block = block[block.index("# ─── GDPR erasure pipeline"):block.index("GDPRTICKSVC")]
        for need in ("standing: true", "not_before", "veto", "verify_standing", "PIPELINE_SENDS_APPROVED"):
            self.assertIn(need, block, f"the unit comment must state {need}")

    def test_the_tick_unit_send_is_capped_and_named_to_a_resolved_seat(self):
        """The brake and the identity, structurally: `--send` without `--limit` would send the whole standing set on
        the first tick, and `--approved-by` typed inline would let a rotated seat edit live in a unit file."""
        p = os.path.join(os.path.dirname(__file__), "..", "scripts", "install-aux-units.sh")
        text = open(p).read()
        # the SERVICE body, not the comment block: the ExecStart line lives past the GDPRTICKSVC heredoc marker
        block = text[text.index("# ─── GDPR erasure pipeline"):text.index("GDPRTICKTMR")]
        self.assertIn("--send", block)
        self.assertRegex(block, r"--send[^\n]*--limit \d+", "a send without a cap sends the whole register at once")
        # ESCAPED, and that is the whole point: the heredoc is unquoted, so an unescaped `$GDPR_SENDER_SEAT` is
        # expanded by the INSTALLER's shell at write time. The variable is not set there (it is set by the unit's own
        # `Environment=` line for systemd to expand), so under `set -u` the write aborted and every deploy refused at
        # Step 5c on 2026-11-06 - and the truncated 0-byte unit took the live tick down with it.
        self.assertIn("--approved-by \\$GDPR_SENDER_SEAT", block,
                      "the seat must survive to the unit for systemd to expand; unescaped it kills the deploy")
        self.assertNotIn("--approved-by $GDPR_SENDER_SEAT", block,
                         "an unescaped seat is expanded by the installer, where it is unset")
        self.assertIn("Environment=GDPR_SENDER_SEAT=", block)


class WatchdogDistinguishesInterim(unittest.TestCase):
    """The alert's job is to say whether a letter LEFT. An interim letter is not the confirmation the deadline is
    about, but reporting "no letter sent" while one is out there is the wrong fact."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self, **kw):
        c = {"keys": ["intercom:77"], "channel": "intercom", "class": "privacy_erasure",
             "received_at": "2026-09-01T10:00:00Z", "due_at": "2026-10-01T10:00:00Z", "conversation_id": "1",
             "identity_verdict": "PASS_A", "action": "hide first",
             "pages": [{"entity": "profile", "id": ARPAD}]}
        c.update(kw)
        rid, _ = self.s.upsert(c)
        return rid

    def line(self, rid, now):
        return [l for _, l in self.run.watchdog_rows(now) if f"#{self.s.get(rid)['register_no']} " in l][0]

    def test_an_interim_letter_is_named_instead_of_no_letter_sent(self):
        rid = self.row()
        self.s.update(rid, "confirmed", interim_confirm_at="2026-10-02T00:00:00Z")
        line = self.line(rid, datetime(2026, 10, 3, tzinfo=timezone.utc))
        self.assertIn("interim letter sent 2026-10-02", line)
        self.assertIn("final letter NOT sent", line)
        self.assertNotIn("no letter sent", line)

    def test_a_row_with_nothing_sent_still_says_so(self):
        rid = self.row()
        line = self.line(rid, datetime(2026, 10, 3, tzinfo=timezone.utc))
        self.assertIn("no letter sent", line)


class CandidateIntake(unittest.TestCase):
    """The intake contract the notices@/legal@ reader lane asked for (inbox 035): a pushed request must land with the
    EMAIL's own date, and a kind the register cannot act on must be REFUSED loudly rather than recorded and then
    filtered out by every pass - a lane that pushes `kind=name_removal` and sees "created" would believe the request
    is registered and watched."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_intake", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)
        self.s = Store(":memory:")

    def cand(self, **kw):
        c = {"keys": ["gmail:notices@muso.ai:aaaabbbbccccdddd"], "channel": "notices", "class": "privacy_erasure",
             "received_at": "2026-11-01T09:14:00Z",
             "pages": [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}]}
        c.update(kw)
        return c

    def test_a_pushed_notices_row_is_dated_by_the_email(self):
        rid, how = self.s.upsert(self.cand())
        r = self.s.get(rid)
        self.assertEqual(how, "created")
        self.assertEqual((r["channel"], r["class"]), ("notices", "privacy_erasure"))
        self.assertEqual(r["received_at"], "2026-11-01T09:14:00Z")
        self.assertEqual(r["due_at"][:10], "2026-12-01", "30 days from the EMAIL, not from the push")
        self.assertEqual(r["hide_due_at"][:10], "2026-11-02", "24 hours from the EMAIL")
        self.assertEqual(r["pages"], [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}])

    def test_the_same_push_twice_is_one_request(self):
        self.s.upsert(self.cand())
        rid, how = self.s.upsert(self.cand())
        self.assertEqual(how, "unchanged")
        self.assertEqual(len(self.s.all()), 1, "the row key is the idempotence test")

    def test_the_pushed_vocabulary_maps_a_lanes_kinds_onto_real_classes(self):
        """A notices@ name-removal or an objection to a public listing is privacy_erasure here; a data-export is
        privacy_access. There is no `objection`/`name_removal` class, and adding one is a copy+identity decision."""
        self.assertIn("privacy_erasure", self.cli.CANDIDATE_CLASSES)
        self.assertIn("privacy_access", self.cli.CANDIDATE_CLASSES)
        for invented in ("name_removal", "objection", "defamation", "takedown_request"):
            self.assertNotIn(invented, self.cli.CANDIDATE_CLASSES)

    def test_read_candidate_refuses_an_unknown_class_and_an_unknown_field(self):
        import tempfile
        cases = [
            ({"class": "objection"}, "not one the register can act on"),
            ({"kind": "name_removal"}, "unknown field"),
            ({"received_at": "2026-11-01"}, "the EMAIL's own date"),
            ({"keys": []}, "keys is empty"),
            ({"channel": "fax"}, "not in"),
        ]
        for patch, why in cases:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(self.cand(**patch), f)
            try:
                with self.assertRaises(SystemExit) as e:
                    self.cli.read_candidate(f.name)
                self.assertIn(why, str(e.exception), patch)
            finally:
                os.unlink(f.name)

    def test_a_good_candidate_is_accepted(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(self.cand(), f)
        try:
            got = self.cli.read_candidate(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(got[0]["class"], "privacy_erasure")
        self.assertEqual(got[0]["pages"], self.cand()["pages"])

    # ---- the ledger path, for a lane that writes into the shared ledgers instead of pushing a candidate ----
    def test_an_unknown_class_in_the_notices_ledger_is_a_source_failure(self):
        bad = []
        cands = intake.parse_gmail_ledger({"notices@muso.ai|t1": {
            "alias": "notices@muso.ai", "class": "name_removal", "thread": "1a17", "first_msg": 1760000000}},
            errors=bad)
        self.assertEqual(cands, [])
        self.assertEqual(len(bad), 1)
        self.assertIn("name_removal", bad[0])
        self.assertIn("NOT registered", bad[0])

    def test_a_known_non_erasure_class_is_still_skipped_quietly(self):
        bad = []
        cands = intake.parse_gmail_ledger({"notices@muso.ai|t1": {
            "alias": "notices@muso.ai", "class": "spam", "thread": "1a17", "first_msg": 1760000000}},
            errors=bad)
        self.assertEqual((cands, bad), ([], []), "spam is a class we know and is not an erasure request")

    def test_every_erasure_class_is_in_the_known_ledger_vocabulary(self):
        self.assertTrue(set(intake.ERASURE_CLASSES) <= set(intake.LEDGER_CLASSES))


class TwoConfirmationLetters(unittest.TestCase):
    """r5 finding 2: an interim confirmation ("the remaining step is in progress") and the final one ("the pages no
    longer show your information") are TWO letters in one request's life. Sharing one slot let the interim stamp
    `confirmed_at`, after which the final letter - the one that closes a statutory request - could never send."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self):
        rid, _ = self.s.upsert({"keys": ["intercom:9"], "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "conversation_id": "215476650395415",
                                "requester_name": "Arpad Laczkovszki", "due_at": "2026-10-01T10:00:00Z",
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        self.s.update(rid, "decide", identity_verdict="PASS_A", action="hide first",
                      verdict_detail=[{"id": ARPAD, "verdict": "PASS_A", "why": "claim"}], hidden_at="2026-10-02T00:00:00Z")
        return rid

    def item(self, rid, slot):
        return {"row": rid, "register_no": self.s.get(rid)["register_no"], "text": "letter", "slot": slot,
                "due_at": "2026-10-01T10:00:00Z"}

    def test_the_interim_letter_does_not_consume_the_final_slot(self):
        rid = self.row()
        sent = []
        with mock.patch.object(send, "_intercom_send",
                               lambda c, t, a, dry_run=False, key="": sent.append(t) or "posted"):
            interim = send.deliver(self.run, self.item(rid, "confirm-interim"), "confirm", "U7RP6HKUZ",
                                   slot="confirm-interim")
            final = send.deliver(self.run, self.item(rid, "confirm"), "confirm", "U7RP6HKUZ", slot="confirm")
        self.assertEqual((interim["state"], final["state"]), ("sent", "sent"))
        self.assertEqual(len(sent), 2, "two different letters, not a re-send")
        row = self.s.get(rid)
        self.assertTrue(row["interim_confirm_at"], "the interim letter is on the record")
        self.assertTrue(row["confirmed_at"], "and the final letter is what closes the request")
        self.assertEqual(self.s.send_record(rid, "confirm-interim")["state"], "sent")
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "sent")

    def test_the_interim_letter_alone_leaves_the_row_open(self):
        rid = self.row()
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": "posted"):
            send.deliver(self.run, self.item(rid, "confirm-interim"), "confirm", "U7RP6HKUZ", slot="confirm-interim")
        row = self.s.get(rid)
        self.assertEqual(row["confirmed_at"], "", "confirmed_at is what takes the row out of the confirmation queue")
        self.assertTrue(row["interim_confirm_at"])

    def test_the_interim_letter_goes_out_once(self):
        rid = self.row()
        sent = []
        with mock.patch.object(send, "_intercom_send",
                               lambda c, t, a, dry_run=False, key="": sent.append(t) or "posted"):
            first = send.deliver(self.run, self.item(rid, "confirm-interim"), "confirm", "U7RP6HKUZ",
                                 slot="confirm-interim")
            again = send.deliver(self.run, self.item(rid, "confirm-interim"), "confirm", "U7RP6HKUZ",
                                 slot="confirm-interim")
        self.assertEqual((first["state"], again["state"]), ("sent", "skipped"))
        self.assertEqual(len(sent), 1)

    def test_a_row_is_not_confirmed_until_its_final_letter_sends(self):
        """The queue itself: a row with an interim letter sent must still be offered, and the final one only when P
        is public-gone."""
        rid = self.row()
        fact = identity.Page(entity_id=ARPAD, name="Arpad Laczkovszki", popularity=0, credit_count=0, gone=True)
        now = datetime(2026, 10, 2, tzinfo=timezone.utc)
        with mock.patch.object(send, "_intercom_send", lambda c, t, a, dry_run=False, key="": "posted"):
            send.deliver(self.run, self.item(rid, "confirm-interim"), "confirm", "U7RP6HKUZ", slot="confirm-interim")
        with mock.patch("gdpr_pipeline.checks.public_gone", lambda e, i: False), \
                mock.patch("gdpr_pipeline.checks.search_absent", lambda i, n: True), \
                mock.patch("gdpr_pipeline.checks.sitemap_absent", lambda ids: None), \
                mock.patch.object(self.run, "_page_name", lambda i: "Arpad"):
            items = self.run.confirmations(now, m_result={})
        self.assertEqual([x["slot"] for x in items], ["confirm-interim"],
                         "the final letter is not ready while the pages are still public")
        self.assertEqual(items[0]["P"], False)

    def test_an_unmeasurable_row_is_not_a_run_error_but_a_transient_one_is(self):
        """The tick exits 2 (and pages) on `run.errors`. A row that can never be checked here must not be one of
        them, or the page fires every day for ever and a real failure hides behind it. It must still not be
        confirmed: it drops out of the batch and the watchdog keeps naming it."""
        rid = self.row()
        now = datetime(2026, 10, 2, tzinfo=timezone.utc)

        def boom(*_a):
            raise checks.Unmeasurable("S check: 'Robert' returned the full autocomplete page (30 items, cap 30)")

        with mock.patch("gdpr_pipeline.checks.public_gone", lambda e, i: True), \
                mock.patch("gdpr_pipeline.checks.search_absent", boom), \
                mock.patch.object(self.run, "_page_name", lambda i: "Robert"):
            items = self.run.confirmations(now, m_result={})
        self.assertEqual(items, [], "an unmeasurable row is never confirmed")
        self.assertEqual(self.run.errors, [], "and it is not a failed read")

        def transient(*_a):
            raise checks.Unknown("S check: autocomplete HTTP 502")

        with mock.patch("gdpr_pipeline.checks.public_gone", lambda e, i: True), \
                mock.patch("gdpr_pipeline.checks.search_absent", transient), \
                mock.patch.object(self.run, "_page_name", lambda i: "Robert"):
            self.run.confirmations(now, m_result={})
        self.assertEqual(len(self.run.errors), 1, "a genuinely unreadable row still fails the run")
        self.assertIn("S/P read-back", self.run.errors[0])


class SendApproval(unittest.TestCase):
    """Fable r5 + 030: a digest MENTION is not an approval. The approval is a structured record - one top-level Slack
    message exactly `APPROVE gdpr <kind> <digest> ruling=<id>`, from an allowlisted human or the one approved sender
    seat, whose ruling id exists in the rulings ledger for that kind and has not expired. Everything here is
    fail-closed, and every spoof Fable named is a test."""

    ALLOW = ("U7RP6HKUZ", "U038BM16T7W")
    SEAT = "U0SEATFABLED2"
    ENV = {"GDPR_APPROVAL_CHANNEL": "C0BSY512MQT", "MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb-test",
           "GDPR_APPROVER_SEAT": "U0SEATFABLED2"}

    def setUp(self):
        import tempfile
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump({"rulings": [
            {"id": "r-ask", "kind": "ask", "expires": "2027-01-01T00:00:00Z"},
            {"id": "r-confirm", "kind": "confirm", "expires": "2027-01-01T00:00:00Z"},
            {"id": "r-ask-old", "kind": "ask", "expires": "2026-01-01T00:00:00Z"},
            {"id": "r-confirm-not-ask", "kind": "confirm", "expires": "2027-01-01T00:00:00Z"}]}, self.tmp)
        self.tmp.close()
        self.ledger = self.tmp.name
        self.addCleanup(lambda: __import__("os").unlink(self.ledger))

    def items(self, text="approved letter", n=2):
        return [{"row": i, "register_no": 100 + i, "text": f"{text} {i}"} for i in range(n)]

    def line(self, kind="confirm", items=None, ruling="r-confirm"):
        return f"APPROVE gdpr {kind} {approval.digest(kind, items or self.items())} ruling={ruling}"

    def _verify(self, msgs, approver="U7RP6HKUZ", items=None, kind="confirm", env=None):
        got = [dict(m) for m in msgs]
        with mock.patch.dict(os.environ, {**self.ENV, "GDPR_RULINGS_LEDGER": self.ledger,
                                          **(env or {})}, clear=True):
            return approval.verify(kind, items or self.items(), approver, self.ALLOW,
                                   history=lambda ch, tok, oldest: got)

    def test_the_digest_binds_the_batch_not_the_approver(self):
        a = self.items()
        self.assertEqual(approval.digest("confirm", a), approval.digest("confirm", list(a)))
        self.assertNotEqual(approval.digest("confirm", a), approval.digest("ask", a))
        self.assertNotEqual(approval.digest("confirm", a), approval.digest("confirm", self.items("different")))
        self.assertNotEqual(approval.digest("confirm", a), approval.digest("confirm", a[:1]),
                            "dropping a letter is a different batch, so a stale approval cannot cover it")
        self.assertNotEqual(approval.digest("confirm", a), approval.digest("confirm", a[::-1]),
                            "reordering is a different batch, so the digest covers order")
        self.assertEqual(len(approval.digest("confirm", a)), approval.DIGEST_LEN)

    def test_the_exact_grammar_from_an_allowlisted_human_is_the_unlock(self):
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": self.line(), "ts": "1.1"}])
        self.assertTrue(ok, why)

    def test_whitespace_runs_collapse_but_nothing_else_is_forgiven(self):
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": "  APPROVE  gdpr   confirm "
                                 + approval.digest("confirm", self.items()) + "   ruling=r-confirm  ", "ts": "1"}])
        self.assertTrue(ok, why)

    def test_a_negation_is_not_an_approval(self):
        """Fable r5 ran this against the previous head and it allowed the send."""
        text = f"do not approve gdpr confirm {approval.digest('confirm', self.items())} yet, I want to check the register first"
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": text, "ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("not the approval grammar", why)

    def test_a_question_is_not_an_approval(self):
        text = f"what does digest {approval.digest('confirm', self.items())} cover?"
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": text, "ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("not the approval grammar", why)

    def test_a_mention_with_the_grammar_inside_other_text_is_not_an_approval(self):
        text = "here you go: " + self.line()
        ok, _ = self._verify([{"user": "U7RP6HKUZ", "text": text, "ts": "1"}])
        self.assertFalse(ok)

    def test_a_pasted_dry_run_block_is_not_an_approval(self):
        """030: the dry run prints the digest only, so even pasting it cannot manufacture an approval."""
        note = approval.note("confirm", self.items())
        self.assertIn(approval.digest("confirm", self.items()), note)
        self.assertNotIn("APPROVE", note.upper())
        ok, _ = self._verify([{"user": "U7RP6HKUZ", "text": note, "ts": "1"}])
        self.assertFalse(ok)

    def test_a_quoted_message_is_not_an_approval(self):
        text = "> APPROVE gdpr confirm " + approval.digest("confirm", self.items()) + " ruling=r-confirm"
        ok, _ = self._verify([{"user": "U7RP6HKUZ", "text": text, "ts": "1"}])
        self.assertFalse(ok)

    def test_a_code_block_is_not_an_approval(self):
        text = "```" + self.line() + "```"
        ok, _ = self._verify([{"user": "U7RP6HKUZ", "text": text, "ts": "1"}])
        self.assertFalse(ok)

    def test_a_threaded_reply_is_not_an_approval(self):
        """030: said in the channel, not in a comment on someone else's message."""
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": self.line(), "ts": "2", "thread_ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("threaded reply", why)

    def test_a_deleted_message_is_not_an_approval(self):
        ok, _ = self._verify([{"user": "U7RP6HKUZ", "text": self.line(), "ts": "1", "deleted": True}])
        self.assertFalse(ok)

    def test_someone_elses_approval_is_not_ours(self):
        ok, why = self._verify([{"user": "U038BM16T7W", "text": self.line(), "ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("no message from that approver", why)

    def test_a_wrong_ruling_id_refuses(self):
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": self.line(ruling="r-nope"), "ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("no such ruling id", why)

    def test_a_ruling_for_another_kind_refuses(self):
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": self.line(kind="ask", ruling="r-confirm-not-ask"),
                                 "ts": "1"}], kind="ask")
        self.assertFalse(ok)
        self.assertIn("approves 'confirm', not 'ask'", why)

    def test_an_expired_ruling_refuses(self):
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": self.line(kind="ask", ruling="r-ask-old"), "ts": "1"}],
                               kind="ask")
        self.assertFalse(ok)
        self.assertIn("expired", why)

    def test_the_batch_digest_must_match_exactly(self):
        ok, _ = self._verify([{"user": "U7RP6HKUZ",
                               "text": "APPROVE gdpr confirm deadbeefdeadbeef ruling=r-confirm", "ts": "1"}])
        self.assertFalse(ok)
        # one letter changed in the batch invalidates the approval
        ok, _ = self._verify([{"user": "U7RP6HKUZ", "text": self.line(), "ts": "1"}], items=self.items("edited"))
        self.assertFalse(ok)

    def test_the_sender_seat_is_accepted_with_its_ledger_ruling(self):
        """029: the captain's single-sender-seat rule. The seat is a Slack user id we resolve, and the ruling must
        exist in the ledger - a flag on the command line is not enough."""
        ok, why = self._verify([{"user": self.SEAT, "text": self.line(), "ts": "1"}], approver=self.SEAT)
        self.assertTrue(ok, why)

    def test_the_seat_without_a_valid_ruling_refuses(self):
        ok, why = self._verify([{"user": self.SEAT, "text": self.line(ruling="r-nope"), "ts": "1"}], approver=self.SEAT)
        self.assertFalse(ok)
        self.assertIn("no such ruling id", why)

    def test_a_bot_not_on_the_allowlist_and_not_the_seat_refuses_before_reading_slack(self):
        called = []
        ok, why = self._verify([{"user": "U0AGENTBOT", "text": self.line(), "ts": "1"}], approver="U0AGENTBOT",
                               env={})
        self.assertFalse(ok)
        self.assertIn("neither an allowlisted human", why)
        self.assertEqual(called, [])

    def test_without_a_bot_token_the_approval_cannot_be_read_so_it_refuses(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            ok, why = approval.verify("confirm", self.items(), "U7RP6HKUZ", self.ALLOW,
                                      history=lambda *a: [{"user": "U7RP6HKUZ", "text": self.line(), "ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("bot token", why)
        self.assertEqual(approval.DEFAULT_CHANNEL, "C0ADV2W76G4", "the default is #clio_devops, where the watchdog pages")

    def test_an_empty_channel_is_switched_off_not_a_default(self):
        """Fable r5 finding 3: the previous `or DEFAULT_CHANNEL` made the empty-string refusal unreachable."""
        ok, why = self._verify([{"user": "U7RP6HKUZ", "text": self.line(), "ts": "1"}],
                               env={"GDPR_APPROVAL_CHANNEL": ""})
        self.assertFalse(ok)
        self.assertIn("switched off", why)

    def test_an_unset_channel_uses_the_default_and_the_scan_is_time_boxed(self):
        seen = {}
        d = approval.digest("confirm", self.items())
        now = datetime(2026, 11, 4, 0, 0, tzinfo=timezone.utc)

        def history(ch, tok, oldest):
            seen.update(channel=ch, oldest=oldest)
            return [{"user": "U7RP6HKUZ", "text": f"APPROVE gdpr confirm {d} ruling=r-confirm", "ts": "1"}]
        with mock.patch.dict(os.environ, {"MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb",
                                          "GDPR_RULINGS_LEDGER": self.ledger,
                                          "GDPR_APPROVER_SEAT": self.SEAT}, clear=True):
            ok, why = approval.verify("confirm", self.items(), "U7RP6HKUZ", self.ALLOW, now=now, history=history)
        self.assertTrue(ok, why)
        self.assertEqual(seen["channel"], approval.DEFAULT_CHANNEL)
        self.assertEqual(seen["oldest"], int((now - timedelta(hours=approval.TTL_HOURS)).timestamp()))

    def test_an_unreadable_history_is_a_refusal_not_a_pass(self):
        def boom(ch, tok, oldest):
            raise approval.Unverifiable("Slack refused conversations.history: missing_scope")
        ok, why = self._verify([], env={}) if False else (None, None)
        with mock.patch.dict(os.environ, {**self.ENV, "GDPR_RULINGS_LEDGER": self.ledger}, clear=True):
            ok, why = approval.verify("confirm", self.items(), "U7RP6HKUZ", self.ALLOW, history=boom)
        self.assertFalse(ok)
        self.assertIn("missing_scope", why)

    def test_a_missing_ledger_refuses_rather_than_guessing(self):
        with mock.patch.dict(os.environ, {**self.ENV, "GDPR_RULINGS_LEDGER": "/nonexistent/ledger.json"}, clear=True):
            ok, why = approval.verify("confirm", self.items(), "U7RP6HKUZ", self.ALLOW,
                                      history=lambda *a: [{"user": "U7RP6HKUZ", "text": self.line(), "ts": "1"}])
        self.assertFalse(ok)
        self.assertIn("does not exist", why)

    def test_the_refusal_names_what_was_actually_scanned(self):
        ok, why = self._verify([])
        self.assertFalse(ok)
        self.assertIn("scanned 0 message(s)", why)
        self.assertIn("C0BSY512MQT", why)

    def test_the_shipped_ledger_covers_the_copy_the_pipeline_actually_sends(self):
        """A ruling missing from the shipped ledger makes every send of that kind refuse in production, and the failure
        would look like "the human did not approve". So the ledger itself is tested."""
        led = approval.rulings(os.path.join(os.path.dirname(__file__), "..", "policies", "gdpr-send-rulings.json"))
        self.assertIn("fable-ruling-1103-d2/gdpr-identity-ask", led)
        self.assertIn("fable-ruling-1103-d2/gdpr-progress-line", led)
        self.assertIn("fable-ruling-1103-b3/gdpr-confirmation", led)
        self.assertIn("gdpr-support-from-1104", led, (
            "the new-thread route's ruling id MUST be in the shipped ledger: the approval line names a ruling id and "
            "approval.verify looks it up by kind, so a GO that is in the code but not in the ledger refuses every "
            "send at the last gate - after the merge, after the deploy, and looking exactly like 'the human did not "
            "approve'"))
        for rid, r in led.items():
            self.assertIn(r["kind"], ("ask", "confirm"), rid)
            self.assertTrue(r.get("source"), f"{rid} must say where the ruling came from")
            self.assertTrue(r.get("expires"), rid)

    def test_the_class_scoped_subject_ruling_resolves_in_the_ledger_for_its_own_class(self):
        """The subject gate cites a ruling id; that id must exist, be an `ask` ruling and be unexpired, or the GO is
        decorative. Checked at the ruling's own approved_at so the assertion does not rot on the calendar."""
        led = approval.rulings(os.path.join(os.path.dirname(__file__), "..", "policies", "gdpr-send-rulings.json"))
        rec = led.get(copy.NEW_THREAD_SUBJECT_RULING)
        self.assertIsNotNone(rec, f"{copy.NEW_THREAD_SUBJECT_RULING} is cited by copy.new_thread_subject but absent")
        self.assertEqual(rec["kind"], "ask")
        at = datetime.fromisoformat(str(rec["approved_at"]).replace("Z", "+00:00")) + timedelta(minutes=1)
        self.assertEqual(approval._ruling_ok(rec, "ask", at), "")
        # and the scope is stated where a human signing an approval would read it
        self.assertIn("CLASS-SCOPED", rec["source"])
        self.assertIn("privacy_erasure", rec["source"])

    def test_the_dry_run_prints_the_digest_only_never_an_accept_string(self):
        text = approval.note("confirm", self.items())
        d = approval.digest("confirm", self.items())
        self.assertIn(d, text)
        self.assertNotIn("APPROVE gdpr", text.upper())


class ScheduledSends(unittest.TestCase):
    """Fable decision 11-04 B26 Q1 ("unlock both lines; the register sends on its due dates") with Aaron's 24 h veto.

    The unattended path cannot post a 2-hour Slack message per batch, so what authorises it is a REVIEWED LEDGER ENTRY
    with `standing: true`. Every case below is a way that could quietly become "may send forever": a ruling promoted
    without the field, a veto window ignored, another identity executing it, a kind borrowed from another letter, an
    expiry ignored - and the one thing that must NOT change, that the interactive approval is not loosened by any of
    this.
    """

    WHO = "U0SEAT1111"
    OTHER = "U7RP6HKUY"
    NOW = datetime(2026, 11, 6, 12, 0, tzinfo=timezone.utc)

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        self._write([])
        self.addCleanup(lambda: os.remove(self._path))

    @property
    def _path(self):
        return self._tmp.name

    def _write(self, rulings):
        self._tmp.seek(0)
        self._tmp.truncate()
        json.dump({"rulings": rulings}, self._tmp)
        self._tmp.flush()

    def _standing(self, **over):
        row = {"id": "stand-ask", "kind": "ask", "standing": True, "expires": "2026-12-05T21:30:00Z",
               "not_before": "2026-11-05T21:30:00Z", "approved_by": self.WHO, "copy_sha": copy.fingerprint(),
               "classes": ["privacy_erasure"]}
        row.update(over)
        return row

    def items(self):
        return [{"row": 1, "register_no": 271, "text": "an approved letter", "class": "privacy_erasure"}]

    def check(self, kind="ask", who=None, now=None):
        return approval.verify_standing(kind, self.items(), approved_by=who or self.WHO,
                                        now=now or self.NOW, path=self._path)

    # ---------------------------------------------------------------- the refusals
    def test_a_ruling_without_the_standing_field_never_authorises_an_unattended_send(self):
        """The field is the whole safety property: the three ask/confirm rulings that already exist must not silently
        become standing ones, so a valid ruling whose ONLY difference is the missing field refuses."""
        self._write([{"id": "r-ask", "kind": "ask", "expires": "2026-12-05T21:30:00Z"}])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("standing", why)

    def test_the_veto_window_is_a_clock_and_the_refusal_names_the_instant(self):
        """Aaron's 24 h veto (decision 11-04) is expressed as `not_before`, not as a human remembering to flip a flag.
        Before that instant every scheduled send refuses - and says WHEN it starts, so nobody has to guess."""
        self._write([self._standing()])
        ok, why = self.check(now=datetime(2026, 11, 5, 21, 0, tzinfo=timezone.utc))
        self.assertFalse(ok)
        self.assertIn("2026-11-05T21:30:00+00:00", why)
        self.assertIn("veto", why)

    def test_the_standing_ruling_binds_the_identity_that_runs_it(self):
        """A standing ruling is not a blank cheque for whoever runs the unit: it names the approver, and executing it
        under another (even allowlisted) identity refuses."""
        self._write([self._standing()])
        ok, why = self.check(who=self.OTHER)
        self.assertFalse(ok)
        self.assertIn(self.WHO, why)
        self.assertIn(self.OTHER, why)

    def test_a_standing_ruling_is_scoped_to_its_kind(self):
        """An `ask` authorisation never sends a `confirm`: the two letters make different claims to the customer."""
        self._write([self._standing()])
        ok, why = self.check(kind="confirm")
        self.assertFalse(ok)
        self.assertIn("confirm", why)

    def test_an_expired_standing_ruling_stops_sending(self):
        self._write([self._standing(expires="2026-11-01T00:00:00Z")])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("expired", why)

    def test_a_standing_ruling_with_an_unreadable_not_before_is_not_trusted(self):
        self._write([self._standing(not_before="soon")])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("not_before", why)

    def test_a_naive_not_before_is_refused_by_name_instead_of_crashing_the_tick(self):
        """QA finding on #1779: `datetime.fromisoformat("2026-11-05T21:30:00")` PARSES - it just returns an
        offset-naive datetime - and comparing that to the tick's UTC-aware `now` raises TypeError. A crash is not a
        refusal: the hourly unit dies before the letters after it and repeats the same failure every run, so the
        whole scheduled path stops on a typo in a ledger field. A ruling that does not say WHICH clock it means
        cannot be relied on, so it is refused by name."""
        self._write([self._standing(not_before="2026-11-05T21:30:00")])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("not_before", why)
        self.assertIn("timezone", why)

    def test_a_naive_expires_is_refused_by_name_instead_of_crashing_the_tick(self):
        """The same naive/aware comparison sits on `expires` in `_ruling_ok`, which every non-standing ruling goes
        through - so the crash was reachable from the ordinary approval path too, not just the standing one."""
        self._write([self._standing(expires="2026-12-05T21:30:00")])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("expires", why)
        self.assertIn("timezone", why)

    def test_a_naive_expires_on_an_ordinary_ruling_is_refused_not_raised(self):
        """`_ruling_ok` is the path a plain (non-standing) ruling takes, and `verify` calls it from the send gate
        itself - so a TypeError there is an unhandled crash in the unit, not a refusal the operator can read."""
        why = approval._ruling_ok({"id": "r-ask", "kind": "ask", "expires": "2026-12-05T21:30:00"},
                                  "ask", self.NOW)
        self.assertIn("timezone", why)
        self.assertIn("r-ask", why)

    def test_a_standing_ruling_without_a_veto_window_is_not_trusted(self):
        """QA finding on #1779: `if nb:` skipped the veto gate when the field was ABSENT, so a standing ruling that
        simply omitted `not_before` started sending the moment it merged - the 24 h veto silently gone. Absent is a
        refusal, not "already elapsed"."""
        row = self._standing()
        del row["not_before"]
        self._write([row])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("not_before", why)
        self.assertIn("veto", why)

    def test_a_standing_ruling_without_an_approver_is_not_trusted(self):
        """Same fail-open shape one field over: `if want:` skipped the identity match when `approved_by` was absent,
        so the grant could be executed by ANY identity - including one that is not allowlisted."""
        row = self._standing()
        del row["approved_by"]
        self._write([row])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("approved_by", why)

    def test_a_standing_ruling_without_a_copy_identity_is_not_trusted(self):
        """A month-long unattended grant must name the WORDS it was cut for. Without `copy_sha` it authorises whatever
        the tree happens to render, so editing an approved sentence would ride the old grant."""
        row = self._standing()
        del row["copy_sha"]
        self._write([row])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("copy_sha", why)

    def test_editing_approved_copy_invalidates_the_standing_grant(self):
        """THE finding, end to end: the grant is live, the copy changes, and the scheduled send must REFUSE rather
        than deliver text nobody approved. Driven through `scheduled_send`, not just the predicate, because the
        predicate being right is worthless if the tick does not consult it."""
        cli = self._cli()
        self._write([self._standing()])
        a = mock.Mock(send=True, approved_by=self.WHO, limit=0, manifest="")
        item = {"row": 1, "register_no": 271, "channel": "intercom", "to": "x@example.com", "text": "letter",
                "class": "privacy_erasure"}
        run = mock.Mock()
        run.asks.return_value = [item]
        run.confirmations.return_value = []
        out = []
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.object(copy, "LINK_LINE", "So we act on the right pages, please reply with the link(s)."), \
                mock.patch.dict(os.environ, {"GDPR_RULINGS_LEDGER": self._path}, clear=True), \
                mock.patch.object(cli.approval, "seat_id", lambda: self.WHO), \
                mock.patch.object(cli.send, "materialise", lambda r, items: items), \
                mock.patch.object(cli.send, "deliver", mock.Mock(side_effect=AssertionError("must not deliver"))), \
                mock.patch("builtins.print", lambda *x, **k: out.append(" ".join(str(i) for i in x))):
            cli.scheduled_send(run, a, self.NOW)
        self.assertTrue(any("REFUSED" in line and "copy" in line for line in out), out)

    def test_the_first_wave_cap_counts_letters_that_reach_a_writer(self):
        """QA finding on #1779: the cap was applied to the SELECTION, so 25 permanently-refused rows (no address,
        unapproved copy) occupied the window on every tick and row 26 was never attempted - even past its statutory
        deadline. The brake is on how many customers get mail, so a refusal must not spend it."""
        cli = self._cli()
        self._write([self._standing()])
        a = mock.Mock(send=True, approved_by=self.WHO, limit=2, manifest="")
        refused = [{"row": i, "register_no": 100 + i, "channel": "notices", "to": "", "text": "letter",
                    "class": "privacy_erasure", "refuse": "no requester_email"} for i in range(1, 4)]
        due = {"row": 9, "register_no": 200, "channel": "intercom", "to": "x@example.com", "text": "letter",
               "class": "privacy_erasure"}
        run = mock.Mock()
        run.asks.return_value = refused + [due]
        run.confirmations.return_value = []
        sent = []
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_RULINGS_LEDGER": self._path}, clear=True), \
                mock.patch.object(cli.approval, "seat_id", lambda: self.WHO), \
                mock.patch.object(cli.send, "materialise", lambda r, items: items), \
                mock.patch.object(cli.send, "deliver",
                                  lambda r, x, kind, who, slot=None: sent.append(x["register_no"]) or
                                  {"state": "refused" if x.get("refuse") else "sent", "why": x.get("refuse")}), \
                mock.patch("builtins.print", lambda *x, **k: None):
            cli.scheduled_send(run, a, self.NOW)
        self.assertIn(200, sent, "a refused prefix must not starve the row behind it")

    def test_a_ruling_without_classes_authorises_nothing(self):
        """QA finding on #1779: a kind-only grant is not enough. `copy.ASK` is erasure copy and a dmca_takedown or
        legal_threat row reaches the same ASK_LINK verdict, so the grant has to name the REQUESTS it covers."""
        row = self._standing()
        del row["classes"]
        self._write([row])
        ok, why = self.check()
        self.assertFalse(ok)
        self.assertIn("names no `classes`", why)

    def test_a_batch_carrying_a_class_the_ruling_does_not_name_is_refused(self):
        self._write([self._standing()])
        ok, why = approval.verify_standing(
            "ask", [{"row": 1, "register_no": 271, "text": "x", "class": "dmca_takedown"}],
            approved_by=self.WHO, now=self.NOW, path=self._path)
        self.assertFalse(ok)
        self.assertIn("dmca_takedown", why)
        self.assertIn("no standing ruling covers", why)

    def test_a_future_dated_ruling_does_not_widen_the_selection(self):
        """QA finding on #1779: `standing_classes` used to union classes from rulings that had not passed their veto
        window or did not name the running identity. A future-dated `legal_threat` grant then widened the batch, and
        verification refused the WHOLE thing because no single ruling covered it - so the due erasure letters did not
        send. Selection and verification now read the same eligibility list."""
        self._write([self._standing(),
                     self._standing(id="stand-legal", classes=["legal_threat"],
                                    not_before="2027-01-01T00:00:00Z")])
        self.assertEqual(approval.standing_classes("ask", self.WHO, now=self.NOW, path=self._path),
                         {"privacy_erasure"})
        ok, why = self.check()
        self.assertTrue(ok, why)

    def test_two_eligible_rulings_together_authorise_a_mixed_batch(self):
        """The other half: when BOTH grants are live, a batch carrying both classes is authorised by the pair rather
        than refused because neither one alone covers it."""
        self._write([self._standing(), self._standing(id="stand-legal", classes=["legal_threat"])])
        self.assertEqual(approval.standing_classes("ask", self.WHO, now=self.NOW, path=self._path),
                         {"privacy_erasure", "legal_threat"})
        ok, why = approval.verify_standing(
            "ask", [{"row": 1, "register_no": 271, "text": "x", "class": "privacy_erasure"},
                    {"row": 2, "register_no": 272, "text": "y", "class": "legal_threat"}],
            approved_by=self.WHO, now=self.NOW, path=self._path)
        self.assertTrue(ok, why)
        self.assertIn("together authorise", why)

    def test_an_overdue_non_erasure_row_never_reaches_the_scheduled_send(self):
        """The end-to-end shape of the finding: a past-due dmca_takedown row with an ASK_LINK verdict used to be
        selected by `run.asks` and delivered under the erasure standing grant, so the rights-holder was told "the
        deletion request you made on {date} is in progress". It must be refused at the letter level AND the batch
        must not be authorised at the grant level."""
        cli = self._cli()
        self._write([self._standing()])
        a = mock.Mock(send=True, approved_by=self.WHO, limit=0, manifest="")
        item = {"row": 1, "register_no": 271, "channel": "notices", "to": "legal@example.com",
                "text": "letter", "class": "dmca_takedown",
                "refuse": run_mod.ask_refusal("dmca_takedown", True)}
        self.assertIn("ERASURE copy", item["refuse"])
        run = mock.Mock()
        run.asks.return_value = [item]
        run.confirmations.return_value = []
        sent, out = [], []
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_RULINGS_LEDGER": self._path}, clear=True), \
                mock.patch.object(cli.approval, "seat_id", lambda: self.WHO), \
                mock.patch.object(cli.send, "materialise", lambda r, items: items), \
                mock.patch.object(cli.send, "deliver",
                                  lambda r, x, kind, who, slot=None: sent.append(x["register_no"]) or
                                  {"state": "refused", "why": x.get("refuse")}), \
                mock.patch("builtins.print", lambda *x, **k: out.append(" ".join(str(i) for i in x))):
            cli.scheduled_send(run, a, self.NOW)
        self.assertEqual(sent, [], "a non-erasure row must not be delivered under the erasure grant")
        self.assertTrue(any("left out - class not in the standing grant" in line for line in out), out)

    def test_a_mixed_batch_still_sends_the_erasure_letters(self):
        """The other half of the same fix, and the reason the selection is narrowed instead of the batch refused:
        refusing everything because a takedown notice shares the batch would leave the statutory breaches unsent."""
        cli = self._cli()
        self._write([self._standing()])
        a = mock.Mock(send=True, approved_by=self.WHO, limit=0, manifest="")
        erasure = {"row": 1, "register_no": 271, "channel": "intercom", "to": "x@example.com",
                   "text": "letter", "class": "privacy_erasure"}
        takedown = {"row": 2, "register_no": 272, "channel": "notices", "to": "legal@example.com",
                    "text": "letter", "class": "dmca_takedown"}
        run = mock.Mock()
        run.asks.return_value = [erasure, takedown]
        run.confirmations.return_value = []
        sent = []
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_RULINGS_LEDGER": self._path}, clear=True), \
                mock.patch.object(cli.approval, "seat_id", lambda: self.WHO), \
                mock.patch.object(cli.send, "materialise", lambda r, items: items), \
                mock.patch.object(cli.send, "deliver",
                                  lambda r, x, kind, who, slot=None: sent.append(x["register_no"]) or
                                  {"state": "sent", "ref": "m1"}), \
                mock.patch("builtins.print", lambda *x, **k: None):
            cli.scheduled_send(run, a, self.NOW)
        self.assertEqual(sent, [271], "the erasure letter must still go; only the takedown is left out")

    def test_no_ledger_means_no_scheduled_send(self):
        ok, why = approval.verify_standing("ask", self.items(), approved_by=self.WHO, now=self.NOW,
                                           path="/nonexistent/ledger.json")
        self.assertFalse(ok)
        self.assertIn("does not exist", why)

    # ---------------------------------------------------------------- the authorisation
    def test_a_live_standing_ruling_authorises_the_send_it_names(self):
        self._write([self._standing()])
        ok, why = self.check()
        self.assertTrue(ok, why)
        self.assertIn("stand-ask", why)
        self.assertIn(approval.digest("ask", self.items()), why)

    def _cli(self):
        sys.argv = ["gdpr-pipeline.py"]
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "gdpr_cli_sched", os.path.join(os.path.dirname(__file__), "..", "scripts", "gdpr-pipeline.py"))
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        return cli

    def test_the_scheduled_pass_skips_the_kind_instead_of_killing_the_tick(self):
        """The tick has already done intake/decide/mark_hidden when the send pass runs, so an unauthorised send must
        SKIP and say why - raising there would throw away the hour's register work along with the send. Proven by
        driving the real CLI function with no standing ruling and asserting it returns instead of exiting."""
        cli = self._cli()
        a = mock.Mock(send=True, approved_by=self.WHO, limit=0, manifest="")
        run = mock.Mock()
        run.asks.return_value = [{"row": 1, "register_no": 271, "channel": "intercom",
                                 "to": "x@example.com", "text": "letter", "class": "privacy_erasure"}]
        run.confirmations.return_value = []
        out = []
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_RULINGS_LEDGER": self._path}, clear=True), \
                mock.patch.object(cli.approval, "seat_id", lambda: self.WHO), \
                mock.patch.object(cli.send, "materialise", lambda r, items: items), \
                mock.patch.object(cli.send, "deliver", mock.Mock(side_effect=AssertionError("must not deliver"))), \
                mock.patch("builtins.print", lambda *x, **k: out.append(" ".join(str(i) for i in x))):
            cli.scheduled_send(run, a, self.NOW)                    # no standing ruling -> skip, no raise
        self.assertTrue(any("REFUSED" in line and "standing" in line for line in out), out)

    def test_the_scheduled_pass_delivers_under_the_live_standing_ruling(self):
        cli = self._cli()
        self._write([self._standing()])
        a = mock.Mock(send=True, approved_by=self.WHO, limit=0, manifest="")
        item = {"row": 1, "register_no": 271, "channel": "intercom", "to": "x@example.com", "text": "letter",
                "class": "privacy_erasure"}
        run = mock.Mock()
        run.asks.return_value = [item]
        run.confirmations.return_value = []
        sent = []
        with mock.patch.object(copy, "PIPELINE_SENDS_APPROVED", True), \
                mock.patch.dict(os.environ, {"GDPR_RULINGS_LEDGER": self._path}, clear=True), \
                mock.patch.object(cli.approval, "seat_id", lambda: self.WHO), \
                mock.patch.object(cli.send, "materialise", lambda r, items: items), \
                mock.patch.object(cli.send, "deliver",
                                  lambda r, x, kind, who, slot=None: sent.append((kind, who, slot)) or
                                  {"state": "sent", "ref": "m1"}), \
                mock.patch("builtins.print", lambda *x, **k: None):
            cli.scheduled_send(run, a, self.NOW)
        self.assertEqual(sent, [("ask", self.WHO, None)], "the approved kind must be delivered exactly once")

    def test_a_standing_ruling_never_weakens_the_human_approval_path(self):
        """The separation that makes the two paths trustworthy: the SAME ledger with a live standing ruling does not
        let the interactive gate pass without the human's Slack message."""
        self._write([self._standing()])
        env = {"GDPR_RULINGS_LEDGER": self._path, "GDPR_APPROVAL_CHANNEL": "C0ADV2W76G4",
               "MUSO_SLACK_BOT_TOKEN_DEVOPS": "xoxb-test"}
        with mock.patch.dict(os.environ, env, clear=True):
            ok, why = approval.verify("ask", self.items(), "U7RP6HKUZ", ("U7RP6HKUZ",),
                                      history=lambda ch, tok, oldest: [])
        self.assertFalse(ok)
        self.assertIn("no message", why)


class CopyIdentity(unittest.TestCase):
    """`copy.fingerprint()` is what a STANDING ruling names, and a standing grant runs unattended for a month.

    So the fingerprint has to cover the whole customer-facing surface, not just the constants somebody remembered to
    list: the MAPPING the sender reads (`copy.ASK[kind]`) and the RENDERERS that assemble a letter. A grant that
    survives an edit to either one authorises words nobody approved - the exact failure the digest exists to prevent,
    one level up (QA finding on #1779).
    """

    def test_a_mapping_only_edit_moves_the_fingerprint(self):
        """`run.py` sends `copy.ASK[kind]`, so repointing the mapping changes the outgoing letter while every constant
        in `_COPY_IDENTITY` stays byte-identical. Before this was covered, the grant still passed."""
        before = copy.fingerprint()
        with mock.patch.dict(copy.ASK, {"ASK_LINK": "a different sentence nobody approved"}):
            self.assertNotEqual(copy.fingerprint(), before, "a mapping-only edit must move the identity")
        self.assertEqual(copy.fingerprint(), before, "and it must move back when the edit is undone")

    def test_a_mapping_that_points_at_a_new_constant_moves_the_fingerprint(self):
        """The subtler shape: the constants are untouched and only the mapping's target changes."""
        before = copy.fingerprint()
        with mock.patch.dict(copy.ASK, {"ASK_AUTH": copy.LINK_LINE}):
            self.assertNotEqual(copy.fingerprint(), before)

    def test_a_renderer_edit_moves_the_fingerprint(self):
        """A constant can be untouched while the function that assembles it into a letter changes what the recipient
        reads. Hashing the renderers' BEHAVIOUR (bytecode + constants + names) catches that."""
        before = copy.fingerprint()
        real = copy.render_confirmation

        def render_confirmation(*a, **kw):
            return real(*a, **kw) + "\nOne more line nobody approved."

        with mock.patch.object(copy, "render_confirmation", render_confirmation):
            self.assertNotEqual(copy.fingerprint(), before)

    def test_a_transitive_formatter_moves_the_fingerprint(self):
        """`human_date` is called by `progress_line`, `new_thread_lead` and `render_confirmation`, so changing its
        format changes every customer-facing body while the renderers themselves are untouched (QA finding on
        #1779). It is in `_COPY_RENDERERS` for that reason."""
        before = copy.fingerprint()
        with mock.patch.object(copy, "human_date", lambda iso: iso[:10]):
            self.assertNotEqual(copy.fingerprint(), before)

    def test_the_new_thread_assembler_is_inside_the_fingerprint(self):
        """QA finding on #1779: the new-thread body used to be assembled in `send.final_letter`, outside this module,
        so an edit there added a customer-facing line while both standing rulings' `copy_sha` still matched. The
        assembly now lives in `copy.new_thread_letter`, which `_COPY_RENDERERS` covers."""
        before = copy.fingerprint()
        real = copy.new_thread_letter

        def new_thread_letter(*a, **kw):
            body, subject = real(*a, **kw)
            return body + "\n\nOne more line nobody approved.", subject

        with mock.patch.object(copy, "new_thread_letter", new_thread_letter):
            self.assertNotEqual(copy.fingerprint(), before)

    def test_final_letter_adds_no_text_of_its_own(self):
        """The structural half of the same finding: `send.final_letter` may decide WHETHER to assemble and who the
        recipient is, but every customer-facing byte must come from `copy.new_thread_letter`. If somebody adds a
        disclosure line back into the sender, this fails even though the fingerprint would not move."""
        row = {"channel": "notices", "class": "privacy_erasure", "received_at": "2026-11-03T10:00:00Z",
               "conversation_id": "", "gmail_thread": "1a11677c51f6533d", "requester_email": "a@example.com"}
        with mock.patch.object(send, "route", return_value=("mail_new_thread", "a@example.com")):
            body, subject, to = send.final_letter(row, "the approved ask")
        want_body, want_subject = copy.new_thread_letter("notices@muso.ai", "2026-11-03T10:00:00Z",
                                                         "privacy_erasure", "the approved ask")
        self.assertEqual(body, want_body)
        self.assertEqual(subject, want_subject)
        self.assertEqual(to, "a@example.com")

    def test_no_renderer_reaches_a_helper_outside_the_fingerprint(self):
        """The class of bug, not the instance: a hand-maintained list is how `human_date` was missed, so the list is
        CHECKED against the renderers' own bytecode. A new helper fails here instead of shipping under a live grant."""
        self.assertEqual(copy._transitive_helpers(), set(), (
            "these functions are reached by a renderer but are not in copy._COPY_RENDERERS, so editing one would "
            "change a customer-facing letter without moving copy.fingerprint()"))

    def test_a_comment_only_edit_does_not_move_the_identity(self):
        """The other direction, and it matters: if a comment typo forced a re-cut, people would re-cut without
        reading, which is how a grant stops meaning anything. Behaviour, not text."""
        def a(x):
            # one comment
            return x + 1

        def b(x):
            # a different comment, and a blank line

            return x + 1

        def c(x):
            return x + 2

        self.assertEqual(copy._code_identity(a), copy._code_identity(b))
        self.assertNotEqual(copy._code_identity(a), copy._code_identity(c), "a real change must move it")

    def test_the_shipped_standing_rulings_name_the_copy_this_tree_renders(self):
        """The ledger is the only thing the send gate trusts, so a stale `copy_sha` there refuses EVERY scheduled
        letter - and it would look like 'the human did not approve'. Re-cut with `gdpr-pipeline.py copy-sha`."""
        led = approval.rulings(os.path.join(os.path.dirname(__file__), "..", "policies", "gdpr-send-rulings.json"))
        standing = {rid: r for rid, r in led.items() if r.get("standing")}
        self.assertTrue(standing, "the scheduled path has no standing ruling at all")
        for rid, r in standing.items():
            self.assertEqual(r.get("copy_sha"), copy.fingerprint(), (
                f"{rid} names copy_sha {r.get('copy_sha')!r} but this tree renders {copy.fingerprint()!r}; re-cut it "
                f"with `gdpr-pipeline.py copy-sha` in the same PR that changed the copy"))


class PastDueAskCopy(unittest.TestCase):
    """A request already past its statutory date owes the customer an acknowledgement that the erasure is under way,
    plus the ask (23:2xZ delegated ruling item 3). The words are legal copy, so while they are unapproved the letter
    is REFUSED and ledgered - never sent missing the sentence the ruling requires, and never sent with wording nobody
    reviewed."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def _ask_row(self, verdict="ASK_LINK", due="2026-10-01T00:00:00Z"):
        keys = [f"intercom:{due}"]
        rid, _ = self.s.upsert({"keys": keys, "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-09-20T10:00:00Z", "requester_email": "a@b.co",
                                "conversation_id": "215476650395415", "requester_name": "Arpad Laczkovszki",
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        self.s.update(rid, "decide", identity_verdict=verdict, due_at=due)
        return rid

    def test_past_due_ask_carries_the_progress_line_and_refuses_while_unapproved(self):
        """The constant is TRUE today (approved by Fable, `fable-ruling-1103-d2/gdpr-progress-line`). This pins it OFF
        to prove the rollback direction: unapproved copy REFUSES rather than sending a shortened letter."""
        rid = self._ask_row()
        with mock.patch.object(copy, "PROGRESS_LINE_APPROVED", False):
            x = self.run.asks(datetime(2026, 11, 4, tzinfo=timezone.utc))[0]
            self.assertTrue(x["past_due"])
            self.assertTrue(x["text"].startswith("Thank you for your patience."), x["text"])
            self.assertTrue(x["text"].endswith(copy.ASK["ASK_LINK"]), "the approved ask line, verbatim, after it")
            self.assertIn("20 September 2026", x["text"])
            self.assertIn("in progress", x["text"])
            self.assertIn("PROGRESS_LINE_APPROVED", x["refuse"])
            # refused, ledgered, retryable - not a silent skip and not a shortened send
            got = send.deliver(self.run, x, "ask", "U7RP6HKUZ", dry_run=True)
        self.assertEqual(got["state"], "refused")
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "refused")

    def test_approving_the_copy_sends_the_same_letter(self):
        rid = self._ask_row()
        with mock.patch.object(copy, "PROGRESS_LINE_APPROVED", True):
            x = self.run.asks(datetime(2026, 11, 4, tzinfo=timezone.utc))[0]
            self.assertEqual(x["refuse"], "")
            self.assertTrue(x["text"].startswith("Thank you for your patience."))

    def test_a_row_not_yet_due_gets_the_plain_approved_ask(self):
        rid = self._ask_row(due="2026-12-20T00:00:00Z")
        x = self.run.asks(datetime(2026, 11, 4, tzinfo=timezone.utc))[0]
        self.assertFalse(x["past_due"])
        self.assertEqual(x["text"], copy.ASK["ASK_LINK"])
        self.assertEqual(x["refuse"], "")


class LetterWatchdog(unittest.TestCase):
    """The durable alarm Fable asked for on 2026-11-03: a decided erasure with no letter > 24 h past its deadline is
    named AS SUCH. Before this, the watchdog line said "OVERDUE" whether or not a letter had gone out, so 97 decided
    requests could sit past their statutory date with every alert reading as if the work was done."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def decided(self, due_past_days=0, verdict="PASS_A"):
        rid, _ = self.s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "a@b.co",
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        self.s.update(rid, "decide", identity_verdict=verdict, action="hide first",
                      verdict_detail=[{"id": ARPAD, "verdict": verdict, "why": "x"}])
        return rid

    def lines(self, now):
        return [ln for _, ln in self.run.watchdog_rows(now)]

    def test_a_recent_letter_says_so(self):
        rid = self.decided()
        self.s.begin_send(rid, "confirm", "intercom", "1", send.body_sha("x"), "U7RP6HKUZ")
        self.s.finish_send(rid, "confirm", "sent", ref="posted")
        ln = self.lines(datetime(2026, 10, 31, 12, tzinfo=timezone.utc))[0]
        self.assertIn("letter sent", ln)
        self.assertNotIn("no letter sent", ln)

    def test_no_letter_past_the_deadline_is_named(self):
        self.decided()
        ln = self.lines(datetime(2026, 10, 31, 12, tzinfo=timezone.utc))[0]
        self.assertIn("no letter sent, 30 d past the deadline", ln)

    def test_a_failed_send_is_not_a_letter(self):
        rid = self.decided()
        self.s.begin_send(rid, "confirm", "intercom", "1", send.body_sha("x"), "U7RP6HKUZ")
        self.s.finish_send(rid, "confirm", "failed", detail="writer died")
        ln = self.lines(datetime(2026, 11, 5, 12, tzinfo=timezone.utc))[0]
        self.assertIn("letter failed", ln)

    def test_the_alarm_is_on_the_due_date_line_not_a_second_page(self):
        self.decided()
        now = datetime(2026, 11, 5, 12, tzinfo=timezone.utc)
        lines = self.lines(now)
        self.assertEqual(len(lines), 1, "one page per request, carrying both facts")
        self.assertIn("OVERDUE", lines[0])
        self.assertIn("no letter sent, 35 d past the deadline", lines[0])


class ConversationReadIntegrity(unittest.TestCase):
    """QA r-lens on 29b9d98, three Important findings. Each one is a way the pipeline could act on something the
    customer never said, or fail to notice they said it."""

    def conv(self, source_type="user", n_parts=2, total=None, body="Please delete my profile muso.ai/dj/arpad-laczkovszki"):
        parts = [{"author": {"type": "user"}, "body": f"part {i}", "created_at": 1_760_000_000 + i}
                 for i in range(n_parts)]
        obj = {"conversation_parts": parts, "total_count": n_parts if total is None else total}
        return {"id": "9", "created_at": 1_760_000_000,
                "source": {"type": "conversation", "subject": "Deletion",
                           "body": body, "author": {"type": source_type, "name": "Caroline", "email": "support@muso.ai"}},
                "conversation_parts": obj,
                "contacts": {"contacts": [{"id": "c1"}]}}

    def read(self, cv, contact=None, pager=None):
        """`pager(before)` is the page the API returns for `parts_created_before=<before>`; default is an empty one,
        which is the floor (nothing older than the oldest part we hold)."""
        contact = {"id": "c1", "external_id": "auth0|abc", "email": "them@example.com", "name": "They"}

        def fake(m, p, b=None):
            if p.startswith("/contacts/"):
                return contact
            if "parts_created_before=" in p:
                before = int(p.split("parts_created_before=")[1])
                return {"conversation_parts": {"conversation_parts": pager(before) if pager else []}}
            return cv

        with mock.patch.object(sources, "intercom", fake):
            return sources._conversation("9")

    def test_a_customer_authored_source_is_the_customers_words(self):
        out = self.read(self.conv())
        self.assertIn("delete my profile", out["customer_text"])
        self.assertEqual((out["author_name"], out["author_email"]), ("Caroline", "support@muso.ai"))

    def test_an_admin_initiated_conversation_is_NOT_a_customer_request(self):
        """Our own outbound "we will delete your profile <link>" must never register as their erasure request: the
        class, the page ids and the requester all come from customer-authored text only."""
        out = self.read(self.conv(source_type="admin"))
        self.assertNotIn("delete my profile", out["customer_text"])
        self.assertEqual((out["author_name"], out["author_email"]), ("", ""),
                         "an admin's name/email is not the requester's identity")
        self.assertEqual(out["source_author_type"], "admin")
        self.assertIn("part 0", out["customer_text"])

    def test_an_admin_source_with_no_customer_parts_is_not_a_request(self):
        out = self.read(self.conv(source_type="teammate", n_parts=0))
        self.assertEqual(out["customer_text"], "")

    def test_an_admin_subject_cannot_classify_a_thread_the_customer_only_replied_to(self):
        """The subject drives `classify()`. An admin-opened thread titled "Delete my profile" plus a customer reply
        that only supplies a URL would otherwise be an erasure request they never made."""
        out = self.read(self.conv(source_type="admin", n_parts=1, body="Delete my profile?"))
        self.assertEqual(out["subject"], "", "an admin's subject is not the customer's request")
        self.assertEqual(intake.classify(out["subject"], out["customer_text"]), "other")

    def test_a_customer_subject_still_classifies(self):
        out = self.read(self.conv(source_type="user", n_parts=0))
        self.assertEqual(out["subject"], "Deletion")
        self.assertEqual(intake.classify(out["subject"], out["customer_text"]), "privacy_erasure")

    def test_a_capped_part_history_fails_the_read_closed(self):
        """Intercom returns at most 500 parts. A partial history cannot prove an older erasure request is absent, so
        the read must fail (exit 2) instead of dating the request from whatever survived and advancing the cursor."""
        with self.assertRaises(sources.Unknown) as e:
            self.read(self.conv(n_parts=500, total=812))
        self.assertIn("parts", str(e.exception))

    def test_a_capped_history_is_walked_back_to_the_opening_message(self):
        """`total_count` counts the parts IN THE RESPONSE, so a 600-part thread arrives as 500 parts with
        total_count=500 - sitting at the cap is the only signal there is. It used to fail closed and ask for a human;
        `parts_created_before` (accepted on the 2.11 we pin, verified against a live 763-part thread) walks back by
        time window instead, so the request that sat in the dropped part is read rather than lost."""
        cv = self.conv(n_parts=500, total=500)
        cv["created_at"] = 1_759_000_000          # the thread opened before its oldest surviving part

        def pager(before):
            if before == 1_760_000_000:
                return [{"id": "old1", "author": {"type": "user"}, "body": "please delete me",
                         "created_at": 1_759_999_000}]
            return []

        out = self.read(cv, pager=pager)
        self.assertIn("please delete me", out["customer_text"], "the dropped part held the request")
        self.assertEqual(len(out["parts"]), 502, "the customer source body + 500 parts + the one walked back to")

    def test_a_conversation_of_exactly_the_cap_reads_normally(self):
        """The floor: the oldest part we hold IS the conversation's opening, so there is nothing to walk back to and
        no extra call is made. A 500-part thread is not automatically a truncated one."""
        out = self.read(self.conv(n_parts=500, total=500))
        self.assertEqual(len(out["parts"]), 501)

    def test_a_walk_that_never_reaches_the_opening_message_still_fails_closed(self):
        """The bound is a page count, so a thread that keeps returning fresh parts without reaching its own
        `created_at` is a refusal - never a silently truncated read dated from what survived."""
        cv = self.conv(n_parts=500, total=500)
        cv["created_at"] = 1_000_000_000
        n = [0]

        def pager(before):
            n[0] += 1
            return [{"id": f"p{n[0]}", "author": {"type": "user"}, "body": "x", "created_at": before - 1}]

        with self.assertRaises(sources.Unknown) as e:
            self.read(cv, pager=pager)
        self.assertIn("reconcile by hand", str(e.exception))
        self.assertEqual(n[0], sources.MAX_PART_PAGES, "the walk is bounded, not unbounded")

    def test_a_full_page_of_parts_we_already_hold_is_not_the_floor(self):
        """QA finding on #1779. `parts_created_before` is INCLUSIVE and returns the 500 most recent parts at or
        before the instant, so when 500 recent parts share one timestamp the page comes back FULL and adds nothing
        new. That used to be read as "nothing older exists" and set `complete=True`; with no usable `total_count`
        the later check could not catch it, so intake advanced from a partial history and a request in the unseen
        part was dropped. A full page that adds nothing is a refusal, not a floor."""
        cv = self.conv(n_parts=500, total=500)
        cv["created_at"] = 1_759_000_000
        held = cv["conversation_parts"]["conversation_parts"]
        for i, p in enumerate(held):
            p["id"] = f"p{i}"
            p["created_at"] = 1_760_000_000          # every part shares one instant
        del cv["conversation_parts"]["total_count"]  # and there is no count to fall back on

        def pager(before):
            # the inclusive window hands back the same 500 parts, sitting at the cap
            return [dict(p) for p in held]

        with self.assertRaises(sources.Unknown) as e:
            self.read(cv, pager=pager)
        self.assertIn("reconcile by hand", str(e.exception))

    def test_a_short_page_that_adds_nothing_is_still_the_floor(self):
        """The other side of the same test: a page BELOW the cap that adds nothing means the API had nothing older,
        so the history is complete and the read must not be refused. Without this, the fix above would turn every
        ordinary capped thread into a manual reconciliation."""
        cv = self.conv(n_parts=500, total=500)
        cv["created_at"] = 1_759_000_000
        held = cv["conversation_parts"]["conversation_parts"]
        for i, p in enumerate(held):
            p["id"] = f"p{i}"
            p["created_at"] = 1_760_000_000

        def pager(before):
            return [dict(p) for p in held[:3]]      # below the cap: the API has nothing more

        out = self.read(cv, pager=pager)
        self.assertEqual(len(out["parts"]), 501, "the customer source body + its 500 parts")

    def test_a_capped_conversation_with_no_created_at_fails_closed(self):
        """No `created_at` means no floor to walk back to, so completeness cannot be proven."""
        cv = self.conv(n_parts=500, total=500)
        del cv["created_at"]
        with self.assertRaises(sources.Unknown) as e:
            self.read(cv)
        self.assertIn("created_at", str(e.exception))

    def test_a_part_with_no_created_at_is_not_a_floor(self):
        """A part we cannot date is a part we cannot place in the walk, so it is a refusal - never a floor.

        `min(int(p.get("created_at") or 0) ...)` reads a MISSING timestamp as 0, and 0 is older than every
        conversation, so the walk's `before <= created_at` test was satisfied on its FIRST iteration and a
        truncated history was declared complete. Intercom omits `created_at` on some part types, and the 500-part
        cap means the part holding the request is exactly the one being walked back to - so this dropped the
        request silently and reported "no request" for a conversation that has one.
        """
        cv = self.conv(n_parts=500, total=500)
        cv["created_at"] = 1_759_000_000          # the thread opened before its oldest surviving part
        for p in cv["conversation_parts"]["conversation_parts"]:
            del p["created_at"]                  # the API did not date any of them
        calls = []

        def pager(before):
            calls.append(before)
            return []

        with self.assertRaises(sources.Unknown) as e:
            self.read(cv, pager=pager)
        self.assertIn("carry no `created_at`", str(e.exception))
        self.assertEqual(calls, [], "the walk must refuse BEFORE spending a page on a floor it cannot trust")

    def test_a_fetched_page_with_an_untimestamped_part_is_not_a_floor(self):
        """The same defect one page in: a walked-back page whose parts are partly undated used to set `before` to 0
        and stop the walk one page early, so the request in the page beyond it was never read."""
        cv = self.conv(n_parts=500, total=500)
        cv["created_at"] = 1_759_000_000

        def pager(before):
            return [{"id": "old1", "author": {"type": "user"}, "body": "please delete me"},
                    {"id": "old2", "author": {"type": "user"}, "body": "x", "created_at": 1_759_999_000}]

        with self.assertRaises(sources.Unknown) as e:
            self.read(cv, pager=pager)
        self.assertIn("carry no `created_at`", str(e.exception))

    def test_just_under_the_cap_reads_normally(self):
        out = self.read(self.conv(n_parts=499, total=499))
        self.assertEqual(len(out["parts"]), 500, "the customer source body + its 499 parts, all readable")

    def test_a_response_without_total_count_still_reads(self):
        cv = self.conv()
        del cv["conversation_parts"]["total_count"]
        self.assertEqual(len(self.read(cv)["parts"]), 3)


class StaleDecisionRevision(unittest.TestCase):
    """QA 29b9d98 finding: `updated_at > decided_at` is a wall-clock test at second precision, so a page added in the
    SAME SECOND as the decision kept the old verdict - and could not enter the hide batch - for 20 hours."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self, verdict="PASS_A"):
        rid, _ = self.s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "a@b.co",
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        # `decided_at` is NOW, never a hardcoded date: `decide_all(stale_hours=20)` compares it against the wall
        # clock, so a frozen stamp makes these tests EXPIRE - 2026-11-04 16:00Z, exactly 20h after the old
        # 2026-11-03T20:00:00Z, `test_an_unchanged_row_is_not_re_decided` went red on main and on every branch.
        # NOW also keeps this row's meaning: it was decided in the SAME SECOND its page arrived.
        self.s.update(rid, "decide", identity_verdict=verdict, action="hide first",
                      verdict_detail=[{"id": ARPAD, "verdict": verdict, "why": "x"}], decided_at=now_iso())
        self.s.mark_decided(rid)
        return rid

    def test_an_unchanged_row_is_not_re_decided(self):
        self.row()
        seen = []
        with mock.patch.object(self.run, "decide_row", lambda r, *a: seen.append(r["id"])):
            self.run.decide_all(set(), stale_hours=20)
        self.assertEqual(seen, [])

    def test_a_change_inside_the_same_second_is_still_a_change(self):
        rid = self.row()
        # same second as `decided_at`, and the page arrives after the verdict was pinned
        self.s.upsert({"keys": ["intercom:5"], "channel": "intercom", "class": "privacy_erasure",
                       "received_at": "2026-09-01T10:00:00Z", "pages": [{"entity": "profile", "id": "41e1de13"}]})
        self.assertGreater(self.s.get(rid)["rev"], self.s.get(rid)["decided_rev"])
        seen = []
        with mock.patch.object(self.run, "decide_row", lambda r, *a: seen.append(r["id"])):
            self.run.decide_all(set(), stale_hours=20)
        self.assertEqual(seen, [rid])

    def test_the_decision_pins_the_revision_it_read(self):
        rid = self.row()
        self.assertEqual(self.s.get(rid)["rev"], self.s.get(rid)["decided_rev"])

    def test_the_refresh_settles_the_clock_arm_so_the_next_tick_skips_the_row(self):
        """Fable r5 finding 4: `decided_at` was written only when the verdict CHANGED, so a stable row decided 21h ago
        was re-selected on every tick forever. A refresh must move `decided_at` forward."""
        from gdpr_pipeline import identity as ident
        rid = self.row()
        old = (datetime.now(timezone.utc) - timedelta(hours=21)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.s.db.execute("UPDATE erasure_requests SET decided_at=?, decided_rev=rev WHERE id=?", (old, rid))
        self.s.db.commit()
        fact = ident.Page(entity_id=ARPAD, name="Arpad Laczkovszki", popularity=0, credit_count=0, gone=False)
        dec = ident.Decision("PASS_A", "claim", [ident.PageVerdict(ARPAD, "PASS_A", "claim")])
        with mock.patch.object(ident, "decide", lambda pages, req, cls: dec), \
                mock.patch("gdpr_pipeline.sources.resolve_account", lambda *a, **k: (None, "")), \
                mock.patch("gdpr_pipeline.sources.page_facts", lambda pages, hidden, claims, half=None: {ARPAD: fact}), \
                mock.patch("gdpr_pipeline.sources.processed_claims", lambda ids: {}):
            self.run.decide_row(self.s.get(rid), set(), {}, lambda cid: {}, stale_hours=20)
        self.assertGreater(parse_iso(self.s.get(rid)["decided_at"]), parse_iso(old),
                           "the refresh moved decided_at forward, so the next tick's clock arm does not select it")

    def test_a_run_with_no_clock_refresh_does_not_touch_decided_at(self):
        """`stale_hours = 0` is "no clock arm", not "refresh everything": the revision arm is what selects there."""
        from gdpr_pipeline import identity as ident
        rid = self.row()
        old = "2026-11-02T00:00:00Z"
        self.s.db.execute("UPDATE erasure_requests SET decided_at=?, decided_rev=rev WHERE id=?", (old, rid))
        self.s.db.commit()
        fact = ident.Page(entity_id=ARPAD, name="Arpad Laczkovszki", popularity=0, credit_count=0, gone=False)
        dec = ident.Decision("PASS_A", "claim", [ident.PageVerdict(ARPAD, "PASS_A", "claim")])
        with mock.patch.object(ident, "decide", lambda pages, req, cls: dec), \
                mock.patch("gdpr_pipeline.sources.resolve_account", lambda *a, **k: (None, "")), \
                mock.patch("gdpr_pipeline.sources.page_facts", lambda pages, hidden, claims, half=None: {ARPAD: fact}), \
                mock.patch("gdpr_pipeline.sources.processed_claims", lambda ids: {}):
            self.run.decide_row(self.s.get(rid), set(), {}, lambda cid: {})
        kinds = [e["kind"] for e in self.s.events(rid)]
        self.assertNotIn("refresh", kinds, "stale_hours=0 is 'no clock arm': it must not write a refresh event")
        # and with a 20-hour window the same row DOES get one, which is what settles the clock arm
        self.s.db.execute("UPDATE erasure_requests SET decided_at=? WHERE id=?", (old, rid))   # 2 days stale
        self.s.db.commit()
        with mock.patch.object(ident, "decide", lambda pages, req, cls: dec), \
                mock.patch("gdpr_pipeline.sources.resolve_account", lambda *a, **k: (None, "")), \
                mock.patch("gdpr_pipeline.sources.page_facts", lambda pages, hidden, claims, half=None: {ARPAD: fact}), \
                mock.patch("gdpr_pipeline.sources.processed_claims", lambda ids: {}):
            self.run.decide_row(self.s.get(rid), set(), {}, lambda cid: {}, stale_hours=20)
        self.assertIn("refresh", [e["kind"] for e in self.s.events(rid)])

    def test_a_re_decision_that_changes_nothing_still_pins(self):
        """Otherwise a row whose columns already match the new verdict (or a rules change that confirms the old one)
        stays `rev > decided_rev` and is re-decided on EVERY tick, which is how a one-time re-decision pass turns
        into a permanent catalog/Trino hammer."""
        from gdpr_pipeline import identity as ident
        rid = self.row()
        self.s.db.execute("UPDATE erasure_requests SET decided_rev = -1 WHERE id=?", (rid,))
        self.s.db.commit()
        fact = ident.Page(entity_id=ARPAD, name="Arpad Laczkovszki", popularity=0, credit_count=0, gone=False)
        dec = ident.Decision("PASS_A", "claim", [ident.PageVerdict(ARPAD, "PASS_A", "claim")])
        with mock.patch.object(ident, "decide", lambda pages, req, cls: dec), \
                mock.patch("gdpr_pipeline.sources.resolve_account", lambda *a, **k: (None, "")), \
                mock.patch("gdpr_pipeline.sources.page_facts", lambda pages, hidden, claims, half=None: {ARPAD: fact}), \
                mock.patch("gdpr_pipeline.sources.processed_claims", lambda ids: {}):
            self.run.decide_row(self.s.get(rid), set(), {}, lambda cid: {})
        self.assertEqual(self.s.get(rid)["decided_rev"], self.s.get(rid)["rev"])


class DecidedRevMigration(unittest.TestCase):
    """A one-time schema addition must not leave old verdicts standing: they were computed by the rules this change
    corrects (an admin-authored source body counted as the customer's words)."""

    def test_a_pre_migration_store_re_decides_every_decided_row_once(self):
        import tempfile
        d = tempfile.mkdtemp()
        path = os.path.join(d, "erasure.sqlite")
        old = sqlite3.connect(path)
        old.executescript("""
            CREATE TABLE erasure_requests (id INTEGER PRIMARY KEY, register_no INTEGER, row_key TEXT, channel TEXT,
              class TEXT, received_at TEXT, due_at TEXT, hide_due_at TEXT, requester_name TEXT, requester_email TEXT,
              contact_id TEXT, conversation_id TEXT, gmail_thread TEXT, clickup_ids TEXT, pages TEXT,
              identity_verdict TEXT DEFAULT '', identity_basis TEXT DEFAULT '', verdict_detail TEXT DEFAULT '[]',
              decided_at TEXT DEFAULT '', action TEXT DEFAULT '', ask_kind TEXT DEFAULT '', ask_sent_at TEXT DEFAULT '',
              ask_ref TEXT DEFAULT '', hide_pr TEXT DEFAULT '[]', hidden_at TEXT DEFAULT '',
              removed_outside_process TEXT DEFAULT '[]', hidden_pages TEXT DEFAULT '[]', confirmed_at TEXT DEFAULT '',
              confirm_ref TEXT DEFAULT '', status TEXT DEFAULT 'open', note TEXT DEFAULT '',
              created_at TEXT, updated_at TEXT);
            CREATE TABLE erasure_keys (key TEXT PRIMARY KEY, request_id INTEGER);
            CREATE TABLE erasure_events (id INTEGER PRIMARY KEY, request_id INTEGER, at TEXT, kind TEXT, detail TEXT);
        """)
        old.execute("INSERT INTO erasure_requests(register_no,row_key,channel,class,received_at,due_at,hide_due_at,"
                    "pages,identity_verdict,decided_at,status,created_at,updated_at) VALUES "
                    "(7,'intercom:5','intercom','privacy_erasure','2026-09-01T10:00:00Z','2026-10-01T10:00:00Z',"
                    "'2026-09-02T10:00:00Z','[]','PASS_A','2026-11-01T10:00:00Z','open','2026-09-01T10:00:00Z',"
                    "'2026-11-01T10:00:00Z')")
        old.commit()
        old.close()

        s = Store(path)
        r = s.all("open")[0]
        self.assertEqual((r["rev"], r["decided_rev"]), (0, -1),
                         "a decided row is marked changed exactly once, so the next tick re-decides it")
        s.mark_decided(r["id"])
        self.assertEqual(s.get(r["id"])["decided_rev"], 0, "and it pins afterwards, so it is not re-decided forever")


class FrozenBatchManifest(unittest.TestCase):
    """Firstmate ruling 2026-11-04: an approval binds a FROZEN batch, never "whatever is open at send time".

    The live case it was written for: 141 letters were approved (digest 2ac206a275d2b0d2), then the hourly intake
    created register #381 and the same command rendered 142 letters with a different digest - so the approval no
    longer named anything sendable. A manifest names the rows, so intake lands in the NEXT batch.
    """

    def item(self, no, due):
        return {"register_no": no, "due_at": due, "kind": "ask", "text": f"letter {no}", "to": f"user{no}@example.com"}

    def args(self, **kw):
        import argparse
        base = dict(send=False, approved_by="", limit=0, manifest="", sitemap=False)
        base.update(kw)
        return argparse.Namespace(**base)

    def manifest(self, rows):
        import tempfile
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(rows, f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_a_manifest_sends_exactly_the_approved_rows_and_new_intake_cannot_touch_them(self):
        cli = _cli()
        old = [self.item(329, "2025-10-20"), self.item(323, "2026-05-05"), self.item(58, "2026-09-01")]
        path = self.manifest([329, 323, 58])
        approved = cli.select_batch(self.args(manifest=path), "ask", old)
        self.assertEqual([x["register_no"] for x in approved], [329, 323, 58])       # oldest deadline first
        digest = approval.digest("ask", approved)
        # the hourly tick creates a new request; the full set re-cuts, the manifest does not
        fresh = old + [self.item(381, "2026-12-04")]
        self.assertEqual(approval.digest("ask", cli.select_batch(self.args(manifest=path), "ask", fresh)), digest)
        self.assertNotEqual(approval.digest("ask", cli.select_batch(self.args(), "ask", fresh)), digest)
        self.assertEqual(len(cli.select_batch(self.args(), "ask", fresh)), 4)      # no manifest = whatever is open

    def test_limit_is_the_moving_selector_this_exists_to_replace(self):
        cli = _cli()
        a = [self.item(1, "2026-01-01"), self.item(2, "2026-02-01")]
        b = a + [self.item(3, "2025-12-01")]                       # an OLDER request arrives than anything approved
        self.assertEqual([x["register_no"] for x in cli.select_batch(self.args(limit=2), "ask", a)], [1, 2])
        self.assertEqual([x["register_no"] for x in cli.select_batch(self.args(limit=2), "ask", b)], [3, 1])

    def test_a_manifest_row_that_is_no_longer_sendable_refuses_loudly(self):
        cli = _cli()
        path = self.manifest([329, 323, 999])                      # 999 was sent / closed / re-decided since
        with self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=path), "ask",
                             [self.item(329, "2025-10-20"), self.item(323, "2026-05-05")])
        self.assertEqual(e.exception.code, 1)

    def test_two_selectors_are_refused(self):
        cli = _cli()
        with self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=self.manifest([1]), limit=5), "ask", [self.item(1, "2026-01-01")])
        self.assertEqual(e.exception.code, 1)

    def test_an_empty_or_unreadable_manifest_refuses(self):
        cli = _cli()
        with self.assertRaises(SystemExit):
            cli.select_batch(self.args(manifest=self.manifest([])), "ask", [self.item(1, "2026-01-01")])
        with self.assertRaises(SystemExit):
            cli.select_batch(self.args(manifest="/nonexistent/manifest.json"), "ask", [self.item(1, "2026-01-01")])
        bad = os.path.join(os.path.dirname(self.manifest([1])), "bad.json")
        open(bad, "w").write("329\nnot-a-number\n")
        self.addCleanup(os.unlink, bad)
        with self.assertRaises(SystemExit):
            cli.select_batch(self.args(manifest=bad), "ask", [self.item(329, "2025-10-20")])

    def test_a_plain_text_manifest_is_accepted(self):
        cli = _cli()
        f = "/tmp/manifest-plain-{}.txt".format(os.getpid())
        open(f, "w").write("329\n#323\n\n58\n")
        self.addCleanup(os.unlink, f)
        got = cli.select_batch(self.args(manifest=f), "ask",
                               [self.item(329, "2025-10-20"), self.item(323, "2026-05-05"), self.item(58, "2026-09-01")])
        self.assertEqual([x["register_no"] for x in got], [329, 323, 58])

    def test_a_register_number_named_twice_still_sends_one_letter(self):
        # a manifest is a hand-built file; a duplicated line must not become two statutory letters to one person
        cli = _cli()
        got = cli.select_batch(self.args(manifest=self.manifest([329, 58, 329])), "ask",
                               [self.item(329, "2025-10-20"), self.item(58, "2026-09-01")])
        self.assertEqual([x["register_no"] for x in got], [329, 58])

    def pinned(self, items):
        import hashlib, tempfile
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump([{"request_id": x["row"], "register_no": x["register_no"],
                    "body_sha": hashlib.sha256((x["text"] or "").encode()).hexdigest()} for x in items],
                  f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def live(self, no, due, text):
        return {"register_no": no, "row": f"row-{no}", "due_at": due, "kind": "ask", "text": text,
                "to": f"user{no}@example.com"}

    def test_a_manifest_that_mixes_the_two_forms_is_refused_not_silently_shortened(self):
        # QA r1 on #1738: a file naming #329 AND {"request_id": "row-58", ...} populated both `nums` and `rows`, and
        # the row branch discarded `nums`, so the rendered batch contained only row-58. An operator could then approve
        # the digest of an INCOMPLETE batch while having named #329 in the file. Dropping a named request is the
        # silent-removal failure the pin exists to prevent, so the mixed form is refused by name.
        import io, contextlib, json, tempfile
        cli = _cli()
        items = [self.live(329, "2025-10-20", "letter A"), self.live(58, "2026-09-01", "letter B")]
        sha_b = __import__("hashlib").sha256(b"letter B").hexdigest()
        path = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump([329, {"request_id": "row-58", "register_no": 58, "body_sha": sha_b}], path)
        path.close()
        self.addCleanup(os.unlink, path.name)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=path.name), "ask", items)
        self.assertEqual(e.exception.code, 1)
        msg = out.getvalue()
        self.assertIn("mixes the two entry forms", msg)
        self.assertIn("1 bare register number", msg)
        self.assertIn("Use ONE form", msg)

    def test_a_row_form_entry_without_body_sha_is_refused(self):
        # Same failure family: a row-shaped entry that carries no body_sha LOOKS pinned but skips the copy-change
        # proof, so a rewording after the GO would ride the old approval. A list of rows is supported; a list of
        # half-pinned rows is not.
        import io, contextlib, json, tempfile
        cli = _cli()
        items = [self.live(329, "2025-10-20", "letter A")]
        path = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump([{"request_id": "row-329", "register_no": 329}], path)
        path.close()
        self.addCleanup(os.unlink, path.name)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=path.name), "ask", items)
        self.assertEqual(e.exception.code, 1)
        self.assertIn("carries no body_sha", out.getvalue())
        self.assertIn("Add body_sha", out.getvalue())

    def test_the_pinned_form_register_no_does_not_count_as_a_bare_number(self):
        # the diptych risk of the fix: a pinned entry carries `register_no` for the human reading the file, and
        # folding it into the bare-number list would make EVERY valid pinned manifest look mixed.
        cli = _cli()
        frozen = [self.live(329, "2025-10-20", "letter A"), self.live(58, "2026-09-01", "letter B")]
        got = cli.select_batch(self.args(manifest=self.pinned(frozen)), "ask", frozen)
        self.assertEqual([x["register_no"] for x in got], [329, 58])

    def test_a_pinned_batch_file_selects_by_row_and_body_and_survives_intake(self):
        # firstmate ruling 2026-11-04: the GO names the frozen set; the file carries the row AND the body it was
        # approved with, so the run - not a person - can tell an intake addition from a copy change
        cli = _cli()
        frozen = [self.live(329, "2025-10-20", "letter A"), self.live(58, "2026-09-01", "letter B")]
        path = self.pinned(frozen)
        got = cli.select_batch(self.args(manifest=path), "ask", frozen)
        self.assertEqual([x["register_no"] for x in got], [329, 58])
        digest = approval.digest("ask", got)
        added = frozen + [self.live(381, "2026-12-04", "letter C")]         # the hourly tick creates a request
        self.assertEqual(approval.digest("ask", cli.select_batch(self.args(manifest=path), "ask", added)), digest)

    def test_a_changed_body_refuses_because_copy_is_approved_per_body(self):
        cli = _cli()
        frozen = [self.live(329, "2025-10-20", "letter A")]
        path = self.pinned(frozen)
        edited = [self.live(329, "2025-10-20", "letter A, reworded after the GO")]
        with self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=path), "ask", edited)
        self.assertEqual(e.exception.code, 1)

    def test_a_pinned_row_that_is_gone_refuses(self):
        cli = _cli()
        path = self.pinned([self.live(329, "2025-10-20", "letter A")])
        with self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=path), "ask", [self.live(58, "2026-09-01", "letter B")])
        self.assertEqual(e.exception.code, 1)

    def test_a_pinned_row_named_twice_still_renders_one_letter(self):
        cli = _cli()
        one = self.live(329, "2025-10-20", "letter A")
        path = self.pinned([one, one])
        self.assertEqual(len(cli.select_batch(self.args(manifest=path), "ask", [one])), 1)

    def test_a_batch_document_verifies_its_own_recorded_digest(self):
        # the pinned file names the ruling and the digest it was cut for; the run checks its own rendering against
        # that claim instead of trusting the filename
        cli = _cli()
        import hashlib, tempfile
        frozen = [self.live(329, "2025-10-20", "letter A"), self.live(58, "2026-09-01", "letter B")]
        entries = [{"request_id": x["row"], "register_no": x["register_no"],
                    "body_sha": hashlib.sha256(x["text"].encode()).hexdigest()} for x in frozen]
        doc = {"ruling": "fable-ruling-1103-d2/gdpr-identity-ask", "kind": "ask", "letters": 2,
               "digest": approval.digest("ask", cli.select_batch(self.args(), "ask", frozen)), "entries": entries}
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f); f.close(); self.addCleanup(os.unlink, f.name)
        got = cli.select_batch(self.args(manifest=f.name), "ask", frozen)
        self.assertEqual([x["register_no"] for x in got], [329, 58])
        # a file whose recorded digest does not match what it renders is refused, not silently sent
        doc["digest"] = "0" * 16
        f2 = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f2); f2.close(); self.addCleanup(os.unlink, f2.name)
        with self.assertRaises(SystemExit) as e:
            cli.select_batch(self.args(manifest=f2.name), "ask", frozen)
        self.assertEqual(e.exception.code, 1)

    def test_a_partially_sent_batch_says_so_instead_of_just_refusing(self):
        # the operator has to be able to tell "a send died at letter N" from "the register moved": the first is
        # benign-but-needs-a-re-pin, the second means the approval no longer names anything
        import io, contextlib, tempfile, sqlite3
        from gdpr_pipeline.store import Store
        cli = _cli()
        td = tempfile.mkdtemp()
        store = Store(os.path.join(td, "e.sqlite"))
        rid, _ = store.upsert({"keys": ["intercom:9"], "channel": "intercom", "class": "privacy_erasure",
                               "received_at": "2026-09-01T10:00:00Z", "conversation_id": "215476650395415",
                               "requester_name": "Arpad Laczkovszki", "due_at": "2026-10-01T10:00:00Z"})
        store.begin_send(rid, "ask", "intercom", "1", "sha", "U0AN41ZBTRU", state="sending")
        store.finish_send(rid, "ask", "sent", detail="ok")
        run = Run(store)
        path = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump([{"request_id": str(rid), "register_no": 1, "body_sha": "0" * 64}], path)
        path.close()
        self.addCleanup(os.unlink, path.name)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
            cli.select_batch(self.args(manifest=path.name), "ask", [], run)
        self.assertIn("already carry a ledger record", out.getvalue())
        self.assertIn("re-pin the unsent rows", out.getvalue())

    def test_both_send_commands_accept_a_manifest(self):
        src = open(os.path.join(HERE, "gdpr-pipeline.py")).read()
        # The ORDER is part of the requirement, not an implementation detail: select_batch checks each pinned
        # body_sha against the text it is HANDED, so materialise must be its ARGUMENT, never its wrapper. Nesting it
        # the other way (`send.materialise(run, select_batch(...))`) validates the pin against the pre-lead body and
        # silently accepts 9 changed letters (measured on the live register). This assertion pins the inside-ness.
        self.assertIn('select_batch(a, "ask", send.materialise(run, run.asks(now)), run)', src)
        self.assertIn('select_batch(a, "confirm", send.materialise(run, run.confirmations(now, m_result=m_result)), '
                      'run)', src)
        self.assertNotIn('send.materialise(run, select_batch(', src)
        self.assertIn('p.add_argument("--manifest"', src)


class ResolveWedgedSends(unittest.TestCase):
    """`gdpr-pipeline.py resolve`: the operator path for a send the sender could not finish.

    The live case it was written for (2026-11-07): 114 `erasure_sends` rows sat in `unknown`, every one of them a
    `REFUSED:` from `intercom-ops-write.sh` -- provably pre-send, because every `refuse()` call site is an
    argument/allowlist/leak check that runs before the curl POST. `send.deliver` classified any non-zero writer exit
    as `Ambiguous`, the ledger records that as `unknown`, and `unknown` is never retried and is "a human's to
    resolve". There was no operator path at all, so the confirm batch was approved and delivered ZERO of 20 while
    each row was blocked by an earlier claim nobody could clear.

    The guards are the point: a resolution needs a reason and a person, it APPENDS to the audit ledger instead of
    overwriting the writer's own words, and a batch may only ever cover rows whose evidence is a writer refusal.
    """

    REFUSAL = ("intercom-ops-write.sh exited rc 1 after being invoked: REFUSED: U0AN41ZBTRU is not on the "
               "Intercom write allowlist (Aaron U7RP6HKUZ, Jan U038BM16T7W, Nick U0AL36NADEY).")
    WHY = ("provably pre-send — writer refused before the curl POST; nothing was posted, so a retry is safe")

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self, n=1, **kw):
        c = {"keys": [f"intercom:{n}"], "channel": "intercom", "class": "privacy_erasure",
             "received_at": "2026-09-01T10:00:00Z", "requester_email": f"a{n}@b.co",
             "conversation_id": f"21547665039541{n}", "requester_name": "Arpad Laczkovszki",
             "pages": [{"entity": "profile", "id": ARPAD}]}
        c.update(kw)
        rid, _ = self.s.upsert(c)
        return rid

    # A writer that RAN and failed: `intercom-ops-write.sh:276` prints this after the curl POST, so the letter may
    # be out there. This is the genuinely ambiguous case, and the one a person must decide individually.
    AMBIGUOUS = "intercom-ops-write.sh exited rc 1 after being invoked: POST FAILED (curl rc=7)"

    def wedged(self, n=1, kind="ask", detail=None, state="unknown", ambiguous=False):
        rid = self.row(n)
        if detail is None:
            detail = self.AMBIGUOUS if ambiguous else self.REFUSAL
        self.s.begin_send(rid, kind, "intercom", f"21547665039541{n}", "sha", "U7RP6HKUZ",
                          state=state, detail=detail)
        return rid

    def args(self, **kw):
        import argparse
        base = dict(row=[], rows="", all_refused=False, kind="", state="failed", why=self.WHY,
                    by="adk47", force=False, apply=False)
        base.update(kw)
        return argparse.Namespace(**base)

    def resolve(self, **kw):
        cli = _cli()
        return cli.cmd_resolve(self.run, self.args(**kw))

    # ---- the happy path ------------------------------------------------------------------------------------
    def test_a_refused_batch_resolves_to_failed_and_the_slot_is_retryable_again(self):
        rid = self.wedged()
        self.assertEqual(self.resolve(all_refused=True, apply=True), 0)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "failed")
        # The whole point: `claim_send` reuses a `failed` slot, so the next tick can send. It raises on `unknown`.
        self.s.claim_send(rid, "ask", "intercom", "215476650395411", "sha2", "U7RP6HKUZ")
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")

    def test_the_resolution_APPENDS_to_the_audit_ledger_and_keeps_the_writers_own_words(self):
        rid = self.wedged()
        self.resolve(all_refused=True, apply=True)
        ev = [r for r in self.s.db.execute(
            "SELECT detail FROM erasure_events WHERE request_id=? AND kind='send-resolved'", (rid,))]
        self.assertEqual(len(ev), 1)
        d = json.loads(ev[0][0])
        self.assertEqual((d["from"], d["to"], d["slot"]), ("unknown", "failed", "ask"))
        self.assertEqual(d["by"], "adk47")
        self.assertEqual(d["why"], self.WHY)
        self.assertIn("REFUSED:", d["evidence"])
        # The writer's own `detail` is NOT overwritten by the resolution: the evidence stays readable on the row.
        self.assertIn("REFUSED:", self.s.send_record(rid, "ask")["detail"])

    def test_a_dry_run_writes_nothing(self):
        rid = self.wedged()
        self.assertEqual(self.resolve(all_refused=True), 0)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        self.assertEqual(list(self.s.db.execute("SELECT count(*) FROM erasure_events WHERE kind='send-resolved'"))[0][0], 0)

    def test_an_individual_row_resolves_without_all_refused(self):
        rid = self.wedged()
        self.assertEqual(self.resolve(row=[rid], apply=True), 0)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "failed")

    def test_rows_accepts_a_comma_list(self):
        a, b = self.wedged(1), self.wedged(2)
        self.assertEqual(self.resolve(rows=f"{a}, {b}", apply=True), 0)
        self.assertEqual([self.s.send_record(r, "ask")["state"] for r in (a, b)], ["failed", "failed"])

    # ---- the guards ----------------------------------------------------------------------------------------
    def test_a_blank_why_is_refused(self):
        rid = self.wedged()
        self.assertEqual(self.resolve(all_refused=True, why="   ", apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_a_resolution_with_no_person_is_refused(self):
        rid = self.wedged()
        with mock.patch.dict(os.environ, {"GDPR_RESOLVER": "", "GDPR_SENDER_SEAT": "", "USER": ""}):
            self.assertEqual(self.resolve(all_refused=True, by="", apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_all_refused_state_sent_is_refused_because_a_refusal_is_provably_pre_send(self):
        rid = self.wedged()
        self.assertEqual(self.resolve(all_refused=True, state="sent", apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_force_cannot_be_combined_with_all_refused(self):
        rid = self.wedged()
        self.assertEqual(self.resolve(all_refused=True, force=True, apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_a_genuinely_ambiguous_row_is_not_swept_into_a_batch(self):
        """A POST that may have landed is a question about whether a letter went out. A person may still resolve it,
        but only by naming that row and saying why -- never by sharing a batch reason with the refusals."""
        rid = self.wedged(detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED (curl rc=7)")
        self.assertEqual(self.resolve(all_refused=True, apply=True), 0)      # nothing matched the batch
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        # ...and an explicit --row without --force is refused, naming the evidence.
        self.assertEqual(self.resolve(row=[rid], apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        # ...and WITH --force it resolves, because a person looked.
        self.assertEqual(self.resolve(row=[rid], force=True, state="sent", why="checked the thread: the letter is "
                                                                              "there", apply=True), 0)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sent")

    def test_a_sent_row_is_not_a_question(self):
        rid = self.row()
        self.s.begin_send(rid, "ask", "intercom", "x", "sha", "U7RP6HKUZ", state="sent")
        self.assertEqual(self.resolve(row=[rid], force=True, apply=True), 0)   # nothing resolvable -> no-op
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sent")

    def test_the_store_refuses_a_sent_row_and_a_blank_reason_directly(self):
        rid = self.row()
        self.s.begin_send(rid, "ask", "intercom", "x", "sha", "U7RP6HKUZ", state="sent")
        with self.assertRaises(store.SendNotResolvable):
            self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47")
        rid2 = self.wedged(2)
        with self.assertRaises(store.SendNotResolvable):
            self.s.resolve_send(rid2, "ask", "failed", "  ", "adk47")
        with self.assertRaises(store.SendNotResolvable):
            self.s.resolve_send(rid2, "ask", "failed", self.WHY, "")
        with self.assertRaises(store.SendNotResolvable):
            self.s.resolve_send(rid2, "ask", "unknown", self.WHY, "adk47")     # not a resolution state

    # ---- the evidence test itself --------------------------------------------------------------------------
    def test_is_writer_refusal_reads_the_writers_own_first_word(self):
        self.assertTrue(store.is_writer_refusal(self.REFUSAL))
        self.assertTrue(store.is_writer_refusal("REFUSED: bare"))
        # A `REFUSED:` that is not the writer's first word is not evidence of a refusal.
        self.assertFalse(store.is_writer_refusal(
            "intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED (curl rc=7) REFUSED: no"))
        self.assertFalse(store.is_writer_refusal("intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED"))
        self.assertFalse(store.is_writer_refusal(""))
        self.assertFalse(store.is_writer_refusal(None))

    def test_a_manual_sent_resolution_writes_the_row_level_stamp_too(self):
        """QA #1848 finding 1: a `sent` ledger row with no stamp is a letter the register believes it never sent. The
        row stays in the confirmation queue and a later customer message is folded into an already-answered request."""
        rid = self.wedged(kind="confirm", detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        self.assertEqual(self.s.get(rid)["confirmed_at"], "")
        self.assertEqual(self.resolve(row=[rid], kind="confirm", force=True, state="sent",
                                      why="checked the thread: the final letter is there", apply=True), 0)
        self.assertEqual(self.s.send_record(rid, "confirm")["state"], "sent")
        row = self.s.get(rid)
        self.assertNotEqual(row["confirmed_at"], "", "a manual `sent` must stamp confirmed_at like the sender does")
        self.assertIn("resolved by adk47", row["confirm_ref"])
        # ...and the row is out of the confirmation queue, which is what `confirmed_at` means.
        self.assertNotIn(rid, [x["row"] for x in self.run.confirmations(
            datetime.now(timezone.utc), s_check=lambda *a: True, p_check=lambda *a: True)])

    def test_a_manual_sent_resolution_stamps_the_ask_and_the_interim_slots_too(self):
        ask = self.wedged(1, kind="ask", detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        interim = self.wedged(2, kind="confirm-interim",
                              detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        self.assertEqual(self.resolve(row=[ask], kind="ask", force=True, state="sent", why="in the thread",
                                      apply=True), 0)
        self.assertEqual(self.resolve(row=[interim], kind="confirm-interim", force=True, state="sent",
                                      why="in the thread", apply=True), 0)
        self.assertNotEqual(self.s.get(ask)["ask_sent_at"], "")
        self.assertNotEqual(self.s.get(interim)["interim_confirm_at"], "")
        # The interim letter must NOT consume the final slot: `confirmed_at` is what closes the request.
        self.assertEqual(self.s.get(interim)["confirmed_at"], "")

    def test_force_resolves_exactly_one_send(self):
        """QA #1848 finding 2: `--force` is the "a person looked at THIS letter" escape hatch. Two ambiguous sends
        under one reason is not evidence for either, and omitting --kind can select several slots on one row."""
        a = self.wedged(1, detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        b = self.wedged(2, detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        self.assertEqual(self.resolve(rows=f"{a},{b}", force=True, state="sent", why="checked one thread",
                                      apply=True), 2)
        self.assertEqual([self.s.send_record(r, "ask")["state"] for r in (a, b)], ["unknown", "unknown"])
        # ...and one row with two resolvable slots is two sends, so it is refused as well.
        c = self.wedged(3, kind="ask", detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        self.s.begin_send(c, "confirm", "intercom", "x", "sha", "U7RP6HKUZ", state="unknown",
                          detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED")
        self.assertEqual(self.resolve(row=[c], force=True, state="sent", why="checked one thread", apply=True), 2)
        self.assertEqual([self.s.send_record(c, k)["state"] for k in ("ask", "confirm")], ["unknown", "unknown"])
        # ...and naming the one slot resolves it.
        self.assertEqual(self.resolve(row=[c], kind="confirm", force=True, state="sent", why="checked the thread",
                                      apply=True), 0)
        self.assertEqual(self.s.send_record(c, "confirm")["state"], "sent")
        self.assertEqual(self.s.send_record(c, "ask")["state"], "unknown")

    def test_a_refused_row_cannot_be_resolved_to_sent(self):
        """QA #1848 r2 finding 1: a writer REFUSAL is provably pre-send, so `sent` is a lie about a statutory letter.

        The batch guard (`--all-refused --state sent`) is not enough: a single `--row N --state sent` would record a
        letter that never left the host as delivered, stamp the row as answered, and suppress the retry that would
        actually send it. The refusal lives in the STORE so a direct call cannot get around it either.
        """
        rid = self.wedged()
        self.assertEqual(self.resolve(row=[rid], state="sent", apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        self.assertFalse(self.s.get(rid).get("ask_sent_at"))
        with self.assertRaises(store.SendNotResolvable) as ctx:
            self.s.resolve_send(rid, "ask", "sent", self.WHY, "adk47")
        self.assertIn("REFUSED by the writer", str(ctx.exception))
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        # ...and `failed` is the honest resolution, which is what makes the slot retryable again.
        self.assertEqual(self.resolve(row=[rid], state="failed", apply=True), 0)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "failed")

    def test_a_failed_audit_write_leaves_the_send_unresolved(self):
        """QA #1848 r2 finding 2: the state, the stamp and the `send-resolved` event are ONE transaction.

        `stamp_sent` used to commit on its own, so a `sent` resolution whose audit insert then failed left a
        delivered letter with no person or reason on record -- the unaudited write this subcommand exists to prevent.
        """
        # A genuinely ambiguous row: the writer ran and we cannot prove it did not post, so `sent` is a legitimate
        # resolution and the transaction is what is under test.
        rid = self.wedged(detail="intercom-ops-write.sh exited rc 7 after being invoked: POST FAILED (curl rc=7)")
        real = self.s.db

        class _Boom:
            """Delegates everything to the real connection but fails the audit insert."""

            def __getattr__(self, name):
                return getattr(real, name)

            def execute(self, sql, *a, **kw):
                # Only the `send-resolved` audit row fails. `update()` writes its own `erasure_events` row through
                # the same statement, so matching on the SQL alone would abort the stamp before it could commit and
                # the test would pass for the wrong reason.
                if (sql.lstrip().startswith("INSERT INTO erasure_events") and a and a[0]
                        and a[0][2] == "send-resolved"):
                    raise sqlite3.OperationalError("database or disk is full")
                return real.execute(sql, *a, **kw)

        self.s.db = _Boom()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                self.s.resolve_send(rid, "ask", "sent", self.WHY, "adk47")
        finally:
            self.s.db = real
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        self.assertFalse(self.s.get(rid).get("ask_sent_at"))
        self.assertEqual([r for r in self.s.db.execute(
            "SELECT 1 FROM erasure_events WHERE request_id=? AND kind='send-resolved'", (rid,))], [])

    def test_a_resolution_does_not_overwrite_a_newer_send_attempt(self):
        """QA #1848 r3 finding 1: the write is a compare-and-swap on the attempt that was READ.

        The race: two `--all-refused --apply` runs select the same `unknown` refusal; the first marks it `failed`,
        the sender reclaims it as `sending`, and the second run -- which read the OLD evidence -- unconditionally
        writes `failed` over that newer attempt. The next tick can then send while the first retry is still in
        flight, which is two statutory letters to one person.
        """
        rid = self.wedged()
        real = self.s.db
        fired = []

        class _Racing:
            """Lets the sender reclaim the slot between our read and our write."""

            def __getattr__(self, name):
                return getattr(real, name)

            def execute(self, sql, *a, **kw):
                if sql.lstrip().startswith("UPDATE erasure_sends SET state=?") and not fired:
                    fired.append(1)
                    real.execute("UPDATE erasure_sends SET state='sending', detail='' "
                                 "WHERE request_id=? AND kind=?", (rid, "ask"))
                    real.commit()
                return real.execute(sql, *a, **kw)

        self.s.db = _Racing()
        try:
            with self.assertRaises(store.SendNotResolvable) as ctx:
                self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47")
        finally:
            self.s.db = real
        self.assertIn("changed while it was being resolved", str(ctx.exception))
        # The newer attempt survives, and no audit row claims a resolution that never happened.
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")
        self.assertEqual([r for r in self.s.db.execute(
            "SELECT 1 FROM erasure_events WHERE request_id=? AND kind='send-resolved'", (rid,))], [])

    def test_a_reclaim_between_selection_and_resolution_is_refused(self):
        """QA #1848 r4: the write is bound to the attempt the CALLER selected, not to a fresh read.

        The CAS on a fresh read is not enough. Two `--all-refused --apply` runs select the same old `unknown`
        refusal; the first marks it `failed`, the sender reclaims it as `sending` with empty detail, and the second
        run re-reads that NEW attempt -- which is still resolvable -- so a fresh-read CAS succeeds and marks the
        in-flight attempt `failed`. The next tick then sends a duplicate statutory letter.
        """
        rid = self.wedged()
        selected = self.s.resolvable_sends(refused_only=True)
        self.assertEqual([r["request_id"] for r in selected], [rid])
        # The sender reclaims the slot after the operator's selection.
        self.s.db.execute("UPDATE erasure_sends SET state='sending', detail='' WHERE request_id=? AND kind=?",
                          (rid, "ask"))
        self.s.db.commit()
        with self.assertRaises(store.SendNotResolvable) as ctx:
            self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47",
                                expect=(selected[0]["state"], selected[0].get("detail") or "",
                                        int(selected[0].get("attempt") or 0)))
        self.assertIn("changed while it was being resolved", str(ctx.exception))
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")

    def test_the_cli_binds_the_write_to_the_attempt_it_selected(self):
        """The same race, driven through `cmd_resolve`: the batch selects, the sender reclaims, the write is refused."""
        rid = self.wedged()
        real = self.s.resolvable_sends

        def select_then_reclaim(**kw):
            rows = real(**kw)
            self.s.db.execute("UPDATE erasure_sends SET state='sending', detail='' "
                              "WHERE request_id=? AND kind=?", (rid, "ask"))
            self.s.db.commit()
            return rows

        self.s.resolvable_sends = select_then_reclaim
        try:
            self.assertEqual(self.resolve(all_refused=True, apply=True), 2)
        finally:
            del self.s.resolvable_sends
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")
        self.assertEqual([r for r in self.s.db.execute(
            "SELECT 1 FROM erasure_events WHERE request_id=? AND kind='send-resolved'", (rid,))], [])

    def test_a_stale_selection_cannot_cross_a_full_retry_cycle(self):
        """QA #1848 r5: state and detail can return to the same values, so the CAS needs the per-attempt identity.

        The ABA cycle: select `unknown` with an ambiguous writer error; resolve it to `failed`; the sender retries
        and the retry fails the SAME way, so the row is `unknown` with the same detail again; then apply the OLD
        selection. Without `at` in the CAS that stale write succeeds and marks the newer attempt resolved -- and if
        the second POST actually delivered, the next retry sends a duplicate statutory letter.
        """
        rid = self.wedged(ambiguous=True)
        stale = self.s.resolvable_sends()[0]
        self.assertEqual(stale["state"], "unknown")
        # 1. the first resolution lands
        self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47",
                            expect=(stale["state"], stale.get("detail") or "", int(stale.get("attempt") or 0)))
        # 2. the sender retries and the retry fails the same way -> same state, same detail, NEW attempt
        self.s.claim_send(rid, "ask", channel="intercom", target="c1", body_sha="b", approved_by="seat")
        self.s.finish_send(rid, "ask", "unknown", detail=stale.get("detail") or "")
        now = self.s.send_record(rid, "ask")
        self.assertEqual((now["state"], now["detail"]), (stale["state"], stale.get("detail")))
        self.assertNotEqual(now["attempt"], stale["attempt"])
        # 3. the stale selection must not match
        with self.assertRaises(store.SendNotResolvable) as ctx:
            self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47",
                                expect=(stale["state"], stale.get("detail") or "", int(stale.get("attempt") or 0)))
        self.assertIn("changed while it was being resolved", str(ctx.exception))
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_a_sending_row_whose_writer_may_still_be_running_is_not_resolvable(self):
        """QA #1848 r6: `sending` has no recorded outcome AND no evidence the writer stopped.

        Resolving it makes the slot retryable while the original POST may still be in flight, and the customer gets
        two statutory letters. The writer is bounded at 45s (`intercom-ops-write.sh`), so the row only becomes an
        orphan a person may resolve once that bound is comfortably past.
        """
        rid = self.wedged(state="sending", detail="")
        with self.assertRaises(store.SendNotResolvable) as caught:
            self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47",
                                expect=("sending", "", 0))
        self.assertIn("may still be running", str(caught.exception))
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")
        # and the CLI refuses it too, rather than relying on that one caller
        self.assertEqual(self.resolve(row=[rid], kind="ask", force=True, apply=True), 2)
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")

    def test_a_sending_row_past_the_writers_bound_is_an_orphan_a_person_may_resolve(self):
        """The other half: a claim older than the writer's own bound has provably stopped, so it MUST be recoverable,
        or a crash mid-POST wedges the slot forever."""
        rid = self.wedged(state="sending", detail="")
        old = (datetime.now(timezone.utc)
               - timedelta(seconds=self.s.SENDING_QUIESCENT_S + 60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.s.db.execute("UPDATE erasure_sends SET at=? WHERE request_id=? AND kind='ask'", (old, rid))
        self.s.db.commit()
        prior = self.s.send_record(rid, "ask")
        self.assertEqual(self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47",
                                             expect=(prior["state"], prior.get("detail") or "",
                                                     int(prior.get("attempt") or 0)))["to"], "failed")
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "failed")

    def test_the_writers_bound_is_what_the_quiescence_window_is_derived_from(self):
        """A guard whose number nobody can trace back to evidence is a guess. Pin the two together: the writer's
        own `timeout` must be far inside the window, or the window stops proving anything."""
        src = (pathlib.Path(__file__).resolve().parents[1] / "scripts" / "intercom-ops-write.sh").read_text()
        m = re.search(r'"\$TIMEOUT_BIN"\s+(\d+)\s+"\$CURL_BIN"', src)
        self.assertIsNotNone(m, "the writer's curl timeout is no longer where this window assumes it is")
        self.assertLessEqual(int(m.group(1)) * 2, store.Store.SENDING_QUIESCENT_S)

    def test_the_cli_refuses_a_stale_selection_across_a_retry_cycle(self):
        """The same ABA cycle driven through `cmd_resolve`, which is where the operator actually hits it.

        The `--row` path selects with `send_record`, so that is what has to be interleaved -- patching
        `resolvable_sends` would never fire and the test would pass on the evidence guard instead of on the CAS.
        """
        rid = self.wedged(ambiguous=True)
        real = self.s.send_record
        stale = {}

        def select_then_cycle(r, k):
            """The operator's selection, then a whole retry cycle, then the STALE snapshot is handed back."""
            rec = real(r, k)
            if rec is not None and not stale:
                stale.update(rec)
                self.s.send_record = real
                try:
                    # another operator run resolves attempt 1 to `failed`
                    self.s.resolve_send(rid, "ask", "failed", self.WHY, "adk47",
                                        expect=(rec["state"], rec.get("detail") or "",
                                                int(rec.get("attempt") or 0)))
                    # the sender retries and the retry fails the SAME way -> attempt 2, same state, same detail
                    self.s.claim_send(rid, "ask", channel="intercom", target="c1", body_sha="b",
                                      approved_by="seat")
                    self.s.finish_send(rid, "ask", "unknown", detail=rec.get("detail") or "")
                finally:
                    self.s.send_record = select_then_cycle
            return rec

        self.s.send_record = select_then_cycle
        try:
            # `--force` because this row's evidence is a POST that may have landed: a person names it individually.
            self.assertEqual(self.resolve(row=[rid], kind="ask", force=True, apply=True), 2)
        finally:
            del self.s.send_record
        # The newer attempt is untouched, and the only resolution on record is the one for attempt 1.
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")
        events = [json.loads(r[0]) for r in self.s.db.execute(
            "SELECT detail FROM erasure_events WHERE request_id=? AND kind='send-resolved'", (rid,))]
        self.assertEqual([e["attempt"] for e in events], [1])

    def test_the_prefix_is_the_one_the_writer_actually_prints(self):
        """Pinned to the shell script, not to a copy of the string: a rename on one side would otherwise silently
        turn every refusal back into an unresolvable `unknown`."""
        path = os.path.join(HERE, "intercom-ops-write.sh")
        with open(path) as f:
            src = f.read()
        self.assertIn(f"printf '{store.REFUSED_PREFIX} %s\\n'", src)


class PreflightRefusalIsNotAmbiguous(unittest.TestCase):
    """A refusal the writer raises ABOVE its POST is not an ambiguous send.

    `unknown` is the never-retried state: it says "a letter may be out there, a human resolves this". That is the
    right answer for a timeout or a dropped connection. It is the WRONG answer for a pre-flight refusal, which the
    writer raises in its validation block before it posts anything - nothing reached the customer, so the letter is
    retryable, and recording it `unknown` strands a statutory request forever.

    This is not hypothetical: the first live send tick (2026-11-06 14:12Z) refused 40 letters because the sender seat
    is not on the writer's human allowlist, and every one of them was recorded `unknown`. The discriminator is the
    writer's own exit-code contract (scripts/intercom-ops-write.sh header): 1 = refusal, 2 = usage/environment error,
    4 = post failed or wrong part_type, and `refuse()`/`die()` are the only producers of 1 and 2 and are only ever
    called above the POST.
    """

    def setUp(self):
        self._env = os.environ.get(send.SEND_LOCK_ENV)
        os.environ[send.SEND_LOCK_ENV] = "test-token"
        self._run = subprocess.run

    def tearDown(self):
        if self._env is None:
            os.environ.pop(send.SEND_LOCK_ENV, None)
        else:
            os.environ[send.SEND_LOCK_ENV] = self._env
        subprocess.run = self._run

    def writer(self, rc, stderr="", stdout=""):
        def fake(cmd, **kw):
            return subprocess.CompletedProcess(cmd, rc, stdout=stdout, stderr=stderr)
        subprocess.run = fake

    def test_a_refusal_is_retryable(self):
        self.writer(1, stderr="REFUSED: U0AN41ZBTRU is not on the Intercom write allowlist (Aaron, Jan, Nick).\n")
        with self.assertRaises(send.Unknown) as e:
            send._intercom_send("215476650395415", "body", "U0AN41ZBTRU", dry_run=False)
        self.assertIn("refused BEFORE posting", str(e.exception))
        self.assertIn("not on the Intercom write allowlist", str(e.exception))

    def test_a_usage_error_is_retryable(self):
        self.writer(2, stderr="ERROR: MUSOAI_INTERCOM_TOKEN is not set.\n")
        with self.assertRaises(send.Unknown):
            send._intercom_send("215476650395415", "body", "U0AN41ZBTRU", dry_run=False)

    def test_a_post_failure_stays_ambiguous(self):
        """rc 4 means the POST was attempted: the customer may have the letter, so this is never a retry."""
        self.writer(4, stderr="POST FAILED (curl rc=28) for https://api.intercom.io/...\n")
        with self.assertRaises(send.Ambiguous):
            send._intercom_send("215476650395415", "body", "U0AN41ZBTRU", dry_run=False)

    def test_a_bare_nonzero_exit_stays_ambiguous(self):
        """A 1 with no REFUSED: prefix is how `set -e` reports an unexpected failure, and that one may have posted."""
        self.writer(1, stderr="")
        with self.assertRaises(send.Ambiguous):
            send._intercom_send("215476650395415", "body", "U0AN41ZBTRU", dry_run=False)

    def test_a_success_is_a_receipt(self):
        self.writer(0, stdout="POSTED comment conversation=215476650395415 part=42\n")
        self.assertEqual(send._intercom_send("215476650395415", "body", "U0AN41ZBTRU", dry_run=False),
                         "POSTED comment conversation=215476650395415 part=42")


class ReconcileStrandedLetters(unittest.TestCase):
    """`reconcile` moves a stranded `unknown` row back to retryable ONLY when the detail proves nothing was posted."""

    # The exact detail the live ledger holds for the 40 letters the 2026-11-06 tick stranded. Pinned verbatim: the
    # reconcile has to recognise rows written BEFORE the distinction existed, or the fix only helps future ticks.
    LIVE_DETAIL = ("intercom-ops-write.sh exited rc 1 after being invoked: REFUSED: U0AN41ZBTRU is not on the "
                   "Intercom write allowlist (Aaron U7RP6HKUZ, Jan U038BM16T7W, Nick U0AL36NADEY). Intercom writes "
                   "need one of them to ask; everyone else is read-only. Do not post; say who can authorize it.")

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self, key, conv="215476650395415", email="a@b.co"):
        rid, _ = self.s.upsert({"keys": [key], "channel": "intercom", "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": email,
                                "conversation_id": conv, "requester_name": "Arpad Laczkovszki",
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        return rid

    def unknown(self, rid, detail, kind="ask", conv="215476650395415"):
        self.s.begin_send(rid, kind, "intercom", conv, "sha", "U0AN41ZBTRU", "unknown", detail=detail)

    def test_the_live_ledger_detail_is_recognised(self):
        self.assertTrue(send.preflight_refusal(self.LIVE_DETAIL))

    def test_the_new_detail_is_recognised(self):
        self.assertTrue(send.preflight_refusal(
            "intercom-ops-write.sh refused BEFORE posting (rc 1): REFUSED: not on the allowlist"))

    def test_a_timeout_is_not_provable(self):
        self.assertFalse(send.preflight_refusal(
            "intercom-ops-write.sh timed out after 120s with the reply built: it may be posted, so this is never a "
            "retry"))

    def test_a_post_failure_is_not_provable(self):
        self.assertFalse(send.preflight_refusal(
            "intercom-ops-write.sh exited rc 4 after being invoked: POST FAILED (curl rc=28)"))

    def test_a_dry_run_writes_nothing(self):
        rid = self.row("intercom:1")
        self.unknown(rid, self.LIVE_DETAIL)
        out = send.reconcile_stranded(self.run, apply=False)
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0]["provable"])
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_apply_moves_only_the_provable_rows(self):
        provable = self.row("intercom:1")
        ambiguous = self.row("intercom:2", conv="215476650395416", email="c@d.co")
        self.unknown(provable, self.LIVE_DETAIL)
        self.unknown(ambiguous, "intercom-ops-write.sh timed out after 120s with the reply built",
                     conv="215476650395416")
        out = send.reconcile_stranded(self.run, apply=True)
        self.assertEqual(sum(1 for r in out if r["provable"]), 1)
        self.assertEqual(self.s.send_record(provable, "ask")["state"], "failed")
        self.assertEqual(self.s.send_record(ambiguous, "ask")["state"], "unknown")

    def test_a_reconciled_row_is_retryable(self):
        """The whole point: `failed` is retryable, `unknown` is not. `claim_send` is the gate that decides."""
        rid = self.row("intercom:1")
        self.unknown(rid, self.LIVE_DETAIL)
        with self.assertRaises(sqlite3.IntegrityError):
            self.s.claim_send(rid, "ask", "intercom", "215476650395415", "sha2", "U0AN41ZBTRU", "sending")
        send.reconcile_stranded(self.run, apply=True)
        self.s.claim_send(rid, "ask", "intercom", "215476650395415", "sha2", "U0AN41ZBTRU", "sending")
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sending")

    def test_the_original_detail_survives_the_move(self):
        rid = self.row("intercom:1")
        self.unknown(rid, self.LIVE_DETAIL)
        send.reconcile_stranded(self.run, apply=True)
        detail = self.s.send_record(rid, "ask")["detail"]
        self.assertIn("reconciled", detail)
        self.assertIn("not on the Intercom write allowlist", detail)

    def test_a_sent_row_is_never_touched(self):
        rid = self.row("intercom:1")
        self.s.begin_send(rid, "ask", "intercom", "215476650395415", "sha", "U0AN41ZBTRU", "sent")
        self.assertEqual(send.reconcile_stranded(self.run, apply=True), [])
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "sent")

    def test_a_closed_register_row_is_not_re_queued(self):
        """The register is re-read: a request that is already finished needs no letter, and re-queueing it would
        send a statutory notice about a request that is closed."""
        rid = self.row("intercom:1")
        self.unknown(rid, self.LIVE_DETAIL)
        self.s.update(rid, "confirmed", status="closed")
        out = send.reconcile_stranded(self.run, apply=True)
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0]["provable"])
        self.assertFalse(out[0]["open"])
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "unknown")

    def test_an_open_register_row_is_re_queued(self):
        rid = self.row("intercom:1")
        self.unknown(rid, self.LIVE_DETAIL)
        out = send.reconcile_stranded(self.run, apply=True)
        self.assertTrue(out[0]["open"])
        self.assertEqual(self.s.send_record(rid, "ask")["state"], "failed")


class WriterExitCodeContract(unittest.TestCase):
    """`send.py` reads the Intercom writer's exit codes to decide retryable-vs-stranded. Pin the contract it reads.

    The distinction is only sound while two things stay true in `scripts/intercom-ops-write.sh`: 1 means refusal and 2
    means usage/environment error, and EVERY `refuse()`/`die()` call sits above the POST. If a future edit adds a
    `refuse` after the POST, or renumbers the codes, a refusal would be read as "nothing was posted" when something
    was - and the retry is a second statutory letter. This test is the tripwire, not the prose.
    """

    WRITER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "scripts", "intercom-ops-write.sh")

    def lines(self):
        with open(self.WRITER) as fh:
            return fh.read().splitlines()

    def test_the_documented_codes_are_the_ones_send_py_reads(self):
        header = "\n".join(self.lines())
        self.assertIn("Exit codes: 0 ok · 1 refusal · 2 usage/environment error · 4 post failed", header)
        self.assertEqual(send.WRITER_PREFLIGHT_RC, {1: "REFUSED:", 2: "ERROR:"})

    def test_refuse_and_die_print_the_prefixes_send_py_matches(self):
        body = "\n".join(self.lines())
        self.assertIn("refuse() { printf 'REFUSED: %s\\n' \"$*\" >&2; exit 1; }", body)
        self.assertIn("die()    { printf 'ERROR: %s\\n' \"$*\" >&2; exit 2; }", body)

    def test_the_store_agrees_with_the_sender_about_what_is_pre_send(self):
        """TWO modules answer "was anything posted?" and they must not drift.

        `send.WRITER_PREFLIGHT_RC` decides what the writer's exit MEANS at send time; `store.is_writer_refusal`
        decides what a recorded `detail` PROVES later, when `resolve --row` refuses to mark a letter `sent` and
        `resolvable_sends(refused_only=True)` picks the rows a batch may touch. If one accepted `REFUSED:` and the
        other `ERROR:`, a `die()` row would be retryable by the sender and un-resolvable by the operator - the
        operator would be told a letter may be out when the writer never reached the POST.
        """
        self.assertEqual(tuple(send.WRITER_PREFLIGHT_RC.values()), store.PRE_SEND_PREFIXES)

    def test_a_die_error_is_recognised_as_pre_send_by_both(self):
        detail = ("intercom-ops-write.sh exited rc 2 after being invoked: ERROR: the API token is not set; "
                  "refusing to build an unauthenticated request")
        self.assertTrue(send.preflight_refusal(detail))
        self.assertTrue(store.is_writer_refusal(detail))

    def test_the_store_reads_the_writers_own_first_word_only(self):
        # A `REFUSED:` that merely APPEARS in quoted customer text is not evidence. The predicate reads the first
        # word after the wrapper's `after being invoked: `, so this must not be treated as a pre-send fact.
        self.assertFalse(store.is_writer_refusal(
            "intercom-ops-write.sh exited rc 4 after being invoked: POST FAILED (curl rc=28); "
            "the response body said REFUSED: something"))

    def test_every_refusal_is_above_the_post(self):
        lines = self.lines()
        post = [i for i, ln in enumerate(lines) if "-sS -X POST" in ln]
        self.assertEqual(len(post), 1, "expected exactly one POST in the writer")
        after = [ln for ln in lines[post[0] + 1:] if re.search(r"(^|[;&|]\s*)(refuse|die)\s", ln)]
        self.assertEqual(after, [], f"a refusal after the POST would be read as 'nothing was posted': {after}")

    def test_the_claim_is_consumed_between_the_audit_record_and_the_post(self):
        """The third ordering fact this contract depends on, and the one QA #1820 found broken.

        A consume BEFORE the audit record means a failed jq/mkdir/redirect strands a letter that was never sent: the
        bare exit 1 is indistinguishable from a dropped connection, so `deliver` records `unknown`, and `unknown`
        is never retried. Pin the order in the source, because no happy-path test can see it.
        """
        lines = self.lines()
        record = [i for i, ln in enumerate(lines) if ln.strip().startswith('> "$LOG_FILE"')]
        consume = [i for i, ln in enumerate(lines) if 'purpose_consume_claim "$PURPOSE" "$CONVERSATION"' in ln]
        post = [i for i, ln in enumerate(lines) if "-sS -X POST" in ln]
        self.assertEqual((len(record), len(consume), len(post)), (1, 1, 1))
        self.assertLess(record[0], consume[0], "the audit record must be written BEFORE the claim is consumed")
        self.assertLess(consume[0], post[0], "the claim must be consumed BEFORE the POST")


class TheTickHealsStrandedLetters(unittest.TestCase):
    """The tick re-queues provable pre-flight refusals before it sends, so a stranded letter heals on its own.

    The failure this repairs was not only the wrong state: it was that 40 letters sat in `unknown` for a day because
    the repair was a command somebody had to remember to run. Wiring it into the tick is what makes the repair
    actually happen, so the wiring is what this pins.
    """

    CLI = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "gdpr-pipeline.py")

    def tick_block(self):
        with open(self.CLI) as fh:
            src = fh.read()
        start = src.index('if a.cmd == "tick":')
        return src[start:src.index('elif a.cmd == "dedupe":', start)]

    def test_the_tick_reconciles_before_it_sends(self):
        block = self.tick_block()
        self.assertIn("send.reconcile_stranded(run, apply=True)", block)
        self.assertLess(block.index("reconcile_stranded"), block.index("scheduled_send"),
                        "a reconcile after the send would leave this tick's own refusals stranded until the next one")

    def test_the_tick_reconcile_is_inside_the_send_guard(self):
        """A tick without --send must not write: the reconcile is a write, so it lives under the same guard."""
        block = self.tick_block()
        guard = block.index('if getattr(a, "send", False):')
        self.assertLess(guard, block.index("reconcile_stranded"))

    def test_the_tick_reconcile_only_moves_provable_open_rows(self):
        block = self.tick_block()
        self.assertIn('r["provable"] and r["open"]', block)


class RecoverMissingAddresses(unittest.TestCase):
    """Captain, 2026-11-06, item 3: the 69 rows that could not be answered are two problems - a code half (a new
    thread from support@, in `route`) and a data half (no address to open one to). This is the data half.

    The rule that matters most here is item 4: recovering an address must NEVER become a way to send a second
    statutory letter. So every test that applies also asserts the send ledger is untouched."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self, key, channel="notices", conv="", thread="", email=""):
        rid, _ = self.s.upsert({"keys": [key], "channel": channel, "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": email,
                                "conversation_id": conv, "gmail_thread": thread,
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        return rid

    def test_the_intercom_contact_email_is_recovered(self):
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415")
        with mock.patch.object(sources, "conversation",
                               lambda c: {"author_email": "", "contact_email": "person@example.com"}):
            rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual([(r["id"], r["email"], r["source"]) for r in rows],
                         [(rid, "person@example.com", "intercom")])
        self.assertEqual(self.s.get(rid)["requester_email"], "person@example.com")

    def test_the_customer_authored_source_email_wins_over_the_contact(self):
        """The address the person WROTE FROM is the one to answer; the contact record can be a different address
        (a work address on the Intercom contact, a personal one in the message)."""
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415")
        with mock.patch.object(sources, "conversation",
                               lambda c: {"author_email": "wrote@example.com", "contact_email": "contact@example.com"}):
            send.recover_addresses(self.run, apply=True)
        self.assertEqual(self.s.get(rid)["requester_email"], "wrote@example.com")

    def test_a_support_thread_is_read_for_the_sender(self):
        rid = self.row("gmail:support@muso.ai:t1", channel="support", thread="1a11c64e6b139977")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(send, "thread_sender", lambda t, m: "person@example.com"):
            rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual(rows[0]["email"], "person@example.com")
        self.assertEqual(rows[0]["source"], "gmail:support@muso.ai")
        self.assertEqual(self.s.get(rid)["requester_email"], "person@example.com")

    def test_a_notices_thread_is_reported_unrecoverable_and_never_guessed(self):
        """notices@ and legal@ are aliases for people, not accounts (captain, 2026-11-06), so their threads cannot be
        read on this host. The honest answer is "not recoverable from here" - inventing an address would send a
        statutory letter to a stranger."""
        rid = self.row("gmail:notices@muso.ai:t1", channel="notices", thread="19d85f50b5fbea79")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(send, "thread_sender", side_effect=AssertionError("must not read an alias")):
            rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual(rows[0]["email"], "")
        self.assertIn("cannot read", rows[0]["why"])
        self.assertIn("notices@muso.ai", rows[0]["why"])
        self.assertEqual(self.s.get(rid)["requester_email"], "")

    def test_a_row_with_neither_a_conversation_nor_a_thread_says_so(self):
        self.row("register:77", channel="register")
        rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual(rows[0]["email"], "")
        self.assertIn("neither a conversation nor a thread", rows[0]["why"])

    def test_an_existing_address_is_never_overwritten(self):
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415", email="already@example.com")
        with mock.patch.object(sources, "conversation",
                               lambda c: {"author_email": "other@example.com", "contact_email": ""}):
            rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual(rows, [], "a row that already has an address is not examined at all")
        self.assertEqual(self.s.get(rid)["requester_email"], "already@example.com")

    def test_a_claimed_unknown_letter_stays_claimed_and_unknown(self):
        """Captain, item 4, and the reason this is a test rather than a comment: the whole point of recovering an
        address is to send a letter, so the one thing that must not happen is a second one to somebody who may
        already have the first."""
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415")
        self.s.begin_send(rid, "ask", "intercom", "215476650395415", "sha", "U0AN41ZBTRU", "unknown",
                          detail="intercom-ops-write.sh timed out after 120s with the reply built")
        with mock.patch.object(sources, "conversation",
                               lambda c: {"author_email": "person@example.com", "contact_email": ""}):
            send.recover_addresses(self.run, apply=True)
        self.assertEqual(self.s.get(rid)["requester_email"], "person@example.com")
        rec = self.s.send_record(rid, "ask")
        self.assertEqual(rec["state"], "unknown", "recovering an address must not re-open a claimed letter")
        self.assertEqual(rec["target"], "215476650395415")

    def test_a_dry_run_writes_nothing(self):
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415")
        with mock.patch.object(sources, "conversation",
                               lambda c: {"author_email": "person@example.com", "contact_email": ""}):
            rows = send.recover_addresses(self.run, apply=False)
        self.assertEqual(rows[0]["email"], "person@example.com")
        self.assertEqual(self.s.get(rid)["requester_email"], "")

    def test_a_closed_row_is_not_examined(self):
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415")
        self.s.update(rid, "confirmed", status="closed")
        with mock.patch.object(sources, "conversation", side_effect=AssertionError("must not read a closed row")):
            self.assertEqual(send.recover_addresses(self.run, apply=True), [])

    def test_the_sender_is_the_first_message_that_is_not_ours(self):
        """Two shapes, both measured on the live register. A thread we replied to ENDS with our address, so the last
        message is wrong. A thread WE opened STARTS with our address, so the first message is wrong too. The only
        correct answer is the first message that came from somebody else."""
        replied_to = {"messages": [
            {"payload": {"headers": [{"name": "From", "value": "Person <person@example.com>"}]}},
            {"payload": {"headers": [{"name": "From", "value": "Muso Support <support@muso.ai>"}]}},
        ]}
        self.assertEqual(send._sender_of(replied_to), "person@example.com")
        we_opened = {"messages": [
            {"payload": {"headers": [{"name": "From", "value": "Muso Support <support@muso.ai>"}]}},
            {"payload": {"headers": [{"name": "From", "value": "Person <person@example.com>"}]}},
        ]}
        self.assertEqual(send._sender_of(we_opened), "person@example.com")

    def test_a_thread_that_is_entirely_ours_has_no_requester_address(self):
        thread = {"messages": [
            {"payload": {"headers": [{"name": "From", "value": "Muso Support <support@muso.ai>"}]}},
            {"payload": {"headers": [{"name": "From", "value": "Muso Support <support@muso.ai>"}]}},
        ]}
        with self.assertRaises(send.Unknown) as e:
            send._sender_of(thread)
        self.assertIn("OUR mailboxes", str(e.exception))

    def test_a_thread_with_no_from_header_is_unknown_not_empty(self):
        with self.assertRaises(send.Unknown):
            send._sender_of({"messages": [{"payload": {"headers": []}}]})


class RecoveryNeverRecordsOurOwnAddress(unittest.TestCase):
    """Measured on the live register, 2026-11-06: 10 of the 19 addresses the first recovery pass found were
    `support@muso.ai`. The thread's first message was OURS. Recording that as the requester would open the next
    statutory letter to ourselves - worse than having no address, because it looks like progress."""

    def setUp(self):
        self.s = Store(":memory:")
        self.run = Run(self.s, log=lambda *_: None)

    def row(self, key, channel="support", conv="", thread=""):
        rid, _ = self.s.upsert({"keys": [key], "channel": channel, "class": "privacy_erasure",
                                "received_at": "2026-09-01T10:00:00Z", "requester_email": "",
                                "conversation_id": conv, "gmail_thread": thread,
                                "pages": [{"entity": "profile", "id": ARPAD}]})
        return rid

    def test_our_own_address_from_a_thread_is_not_recorded(self):
        rid = self.row("gmail:support@muso.ai:t1", thread="1a11c64e6b139977")
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}}), \
                mock.patch.object(send, "thread_sender", side_effect=send.Unknown(
                    "thread 1a11c64e6b139977: its first message is from support@muso.ai, which is one of OUR "
                    "mailboxes, so the requester's own address is not in this thread")):
            rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual(rows[0]["email"], "")
        self.assertIn("OUR mailboxes", rows[0]["why"])
        self.assertEqual(self.s.get(rid)["requester_email"], "")

    def test_our_own_address_from_a_conversation_is_not_recorded(self):
        rid = self.row("intercom:1", channel="intercom", conv="215476650395415")
        with mock.patch.object(sources, "conversation",
                               lambda c: {"author_email": "support@muso.ai", "contact_email": ""}):
            rows = send.recover_addresses(self.run, apply=True)
        self.assertEqual(rows[0]["email"], "")
        self.assertIn("OUR mailboxes", rows[0]["why"])
        self.assertEqual(self.s.get(rid)["requester_email"], "")

    def test_is_ours_covers_every_mailbox_we_own(self):
        with mock.patch.object(send, "_ACCOUNTS_READ", True), \
                mock.patch.object(send, "_ACCOUNTS", {"support@muso.ai": {"gmail"}, "ak@muso.ai": {"gmail"}}):
            for addr in ("support@muso.ai", "notices@muso.ai", "legal@muso.ai", "ak@muso.ai", "SUPPORT@MUSO.AI"):
                self.assertTrue(send._is_ours(addr), addr)
            for addr in ("person@example.com", "blake.khakhria@gmail.com", ""):
                self.assertFalse(send._is_ours(addr) and addr, addr)
