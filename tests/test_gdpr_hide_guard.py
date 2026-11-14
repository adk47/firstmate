"""The hide guard (scripts/gdpr_pipeline/hide_guard.py): what it admits, what it holds, and what it never does.

What these tests lock:
  - a requester who does not hold the profile's claim gets no hide, whatever the stored verdict says;
  - a name match and a legal or takedown request are held;
  - a claim nobody reviewed counts only on the profile its own account created;
  - one requester gets 3 profiles in 24 hours and the register 20; the rest are held, paged once, offered again;
  - a proof that could not be READ stops the run before the open PR is touched (never "not the owner");
  - every admit and hold is an audit row, written when it changes; a dry run writes nothing.

Hermetic: stdlib unittest, an in-memory register, no network.
"""
import contextlib
import io
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__)) + "/../scripts"
sys.path.insert(0, HERE)

from gdpr_pipeline import dsar, hide_batch, hide_guard, identity, sources  # noqa: E402
from gdpr_pipeline.run import Run  # noqa: E402
from gdpr_pipeline.store import Store  # noqa: E402

NOW = datetime(2026, 11, 13, 21, 0, 0, tzinfo=timezone.utc)
OWNER, STRANGER = 80419, 55555
T0 = 1_760_000_000      # when the claim under test was filed (epoch s)


def pid(n: int) -> str:
    return f"{n:08d}-aaaa-4bbb-8ccc-dddddddddddd"


def reviewed_claim(account=OWNER, claim_id="c1"):
    return {"claim_id": claim_id, "account": account, "reason": "", "created": T0,
            "links": {"instagram": "https://instagram.com/the.artist", "weblinks": []}}


def instant_claim(account=OWNER, claim_id="c2"):
    return {"claim_id": claim_id, "account": account, "reason": "created by user", "created": T0, "links": ""}


SITE = "https://www.artist-site.example/"      # the website the profile under test carries
HOST = "artist-site.example"                    # ... and the sender host a path-D pass on it rested on


def entry(n, basis="PASS_A", account=OWNER, request_id=1, register_no=500, entity="profile", owner=None,
          recorded=True, sender_host=HOST):
    """(batch entry, the stored page decision it was planned from)."""
    b = {"id": pid(n), "entity": entity, "register_no": register_no, "basis": basis,
         "due_at": "2026-12-01T00:00:00Z", "need": ["hdevops", "pdp"], "request_id": request_id}
    d = {"id": pid(n), "verdict": basis, "why": "test"}
    if recorded:
        d["owner_page"] = owner or pid(n)
        if account is not None:
            d["account"] = account
        if basis == "PASS_D" and sender_host:
            d["sender_host"] = sender_host
    return b, d


def rows_for(pairs, email="someone@example.org"):
    rows: dict[int, dict] = {}
    for b, d in pairs:
        r = rows.setdefault(b["request_id"], {"id": b["request_id"], "register_no": b["register_no"],
                                              "requester_email": email, "verdict_detail": []})
        r["verdict_detail"].append(d)
    return list(rows.values())


def judge(pairs, claims=None, srcs=None, history=(), now=NOW, email="someone@example.org", sites=None):
    claims = claims or {}
    return hide_guard.judge([b for b, _ in pairs], rows_for(pairs, email), list(history), now,
                            claim_reader=lambda ids: {i: claims.get(i, []) for i in ids},
                            source_reader=lambda ids: {i: srcs[i] for i in ids if i in (srcs or {})},
                            site_reader=lambda ids: {i: sites[i] for i in ids if i in (sites or {})})


def unreadable(_ids):
    raise sources.Unknown("replica timed out")


class Ownership(unittest.TestCase):
    def test_the_account_holding_a_reviewed_claim_is_admitted(self):
        (d,) = judge([entry(1)], {pid(1): [reviewed_claim()]})
        self.assertEqual((d["outcome"], d["proof"], d["claim_id"], d["reason"]),
                         ("admitted", "reviewed_claim", "c1", ""))

    def test_a_requester_who_is_not_the_claim_holder_is_refused(self):
        """The stored verdict says PASS_A for account STRANGER; the claim on the profile is OWNER's."""
        (d,) = judge([entry(1, account=STRANGER)], {pid(1): [reviewed_claim(OWNER)]})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_HOLDER))

    def test_a_pass_on_a_profile_nobody_claims_now_is_refused(self):
        (d,) = judge([entry(1)], {pid(1): []})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_HOLDER))

    def test_a_name_match_is_held(self):
        for basis in ("PASS_B", "PASS_C"):
            (d,) = judge([entry(1, basis=basis)], {pid(1): [reviewed_claim()]})
            self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NAME_ONLY), basis)

    def test_a_legal_request_without_ownership_is_held(self):
        (d,) = judge([entry(1, basis="LEGAL_HIDE_FIRST", account=None)])
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.LEGAL))

    def test_a_legal_request_from_the_claim_holder_enters_as_path_a(self):
        """From the writer's own shape: the identity step decides a legal threat from the account holding the claim as
        PASS_A, and the guard admits that entry as it admits any path A."""
        claims = {pid(1): [reviewed_claim()]}
        (p,) = hide_guard.prove([identity.Page(pid(1), "profile", True, "An Artist", True, frozenset({OWNER}),
                                              10.0, 5)], OWNER,
                                claim_reader=lambda ids: claims, source_reader=lambda ids: {})
        pv = identity.decide_page(p, identity.Requester(name="x", email="x@example.org", account_id=OWNER),
                                 "legal_threat")
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("PASS_A", OWNER, pid(1)))
        (d,) = judge([entry(1, basis=pv.verdict, account=pv.account_id, owner=pv.owner_page)], claims)
        self.assertEqual((d["outcome"], d["proof"], d["claim_id"]), ("admitted", "reviewed_claim", "c1"))

    def test_a_legal_page_is_held_whatever_its_own_basis_says(self):
        """An owner's legal request is decided as path A above, so a legal basis in the batch means no ownership was
        established: the guard holds it and names the ask."""
        for account in (None, STRANGER):
            (d,) = judge([entry(1, basis="LEGAL_HIDE_FIRST", account=account)],
                         {pid(1): [reviewed_claim(OWNER)]})
            self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.LEGAL), account)
        self.assertIn("claim", hide_guard.NEXT[hide_guard.LEGAL])

    def test_a_verdict_the_guard_does_not_know_is_held(self):
        (d,) = judge([entry(1, basis="PASS_Z")])
        self.assertEqual(d["outcome"], "held")

    def test_a_pass_that_does_not_record_its_account_and_profile_is_held_and_listed_for_a_new_decision(self):
        pairs = [entry(1, recorded=False)]
        (d,) = judge(pairs, {pid(1): [reviewed_claim()]})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_RECORDED))
        stale = hide_guard.needs_redecide(rows_for(pairs), [b for b, _ in pairs],
                                          claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids})
        self.assertEqual([r["id"] for r in stale], [1])
        done = [entry(1)]
        self.assertEqual(hide_guard.needs_redecide(rows_for(done), [b for b, _ in done],
                                                  claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids}),
                         [])

    def test_a_recorded_pass_whose_claim_is_gone_is_decided_again(self):
        """The row says PASS_A for account 80419; core no longer has that account's claim (deleted, or the profile
        gained sources after an unreviewed one). Left alone it is held in silence, and nobody asks the requester."""
        pairs = [entry(1)]
        rows = rows_for(pairs)
        stale = hide_guard.needs_redecide(rows, [b for b, _ in pairs],
                                          claim_reader=lambda ids: {i: [] for i in ids})
        self.assertEqual(stale, rows)
        self.assertEqual(hide_guard.needs_redecide(rows, [b for b, _ in pairs],
                                                  claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids}), [])

    def test_a_legal_hide_first_row_is_not_decided_again_on_every_run(self):
        """A legal page with no owner match decides the same way every time: re-deciding it would spend a full
        identity pass per run and still ask nothing (the legal ask is the captain's copy, not the erasure ask)."""
        pairs = [entry(1, basis="LEGAL_HIDE_FIRST", account=None)]
        self.assertEqual(hide_guard.needs_redecide(rows_for(pairs), [b for b, _ in pairs],
                                                  claim_reader=lambda ids: {i: [] for i in ids}), [])

    def test_the_artists_own_site_is_admitted_without_a_claim(self):
        (d,) = judge([entry(1, basis="PASS_D", account=None)], sites={pid(1): SITE})
        self.assertEqual((d["outcome"], d["proof"]), ("admitted", "own_site"))
        self.assertNotIn("sender_host", d)      # compared, never carried onto the event

    def test_a_stale_own_site_pass_is_held_when_the_profiles_website_moved(self):
        """The stored verdict says the sender's host WAS the profile's website. The profile's site was changed or
        corrected since: nothing ties the sender to the profile now, so the old answer hides nothing."""
        for now_site in ("https://somebody-else.example/", "https://agency.artist-site.example/", "", "not a host"):
            (d,) = judge([entry(1, basis="PASS_D", account=None)], sites={pid(1): now_site})
            self.assertEqual((d["outcome"], d["reason"], d["proof"]), ("held", hide_guard.SITE_MOVED, ""), now_site)

    def test_an_own_site_pass_is_the_exact_host_and_never_a_free_mail_host(self):
        for site in ("artist-site.example", "http://WWW.Artist-Site.example/about?x=1"):
            (d,) = judge([entry(1, basis="PASS_D", account=None)], sites={pid(1): site})
            self.assertEqual(d["outcome"], "admitted", site)
        (d,) = judge([entry(1, basis="PASS_D", account=None, sender_host="gmail.com")],
                     sites={pid(1): "https://gmail.com/"})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.SITE_MOVED))

    def test_an_own_site_pass_whose_profile_core_does_not_return_is_held(self):
        (d,) = judge([entry(1, basis="PASS_D", account=None)], sites={})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_FOUND))

    def test_an_own_site_pass_that_did_not_record_the_sender_host_is_held_and_decided_again(self):
        pairs = [entry(1, basis="PASS_D", account=None, sender_host="")]
        (d,) = judge(pairs, sites={pid(1): SITE})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_RECORDED))
        stale = hide_guard.needs_redecide(rows_for(pairs), [b for b, _ in pairs], site_reader=lambda ids: {})
        self.assertEqual([r["id"] for r in stale], [1])

    def test_a_website_that_cannot_be_read_stops_the_run_and_is_not_a_hold(self):
        pairs = [entry(1, basis="PASS_D", account=None)]
        with self.assertRaises(sources.Unknown):
            hide_guard.judge([b for b, _ in pairs], rows_for(pairs), [], NOW, site_reader=unreadable)

    def test_the_website_is_read_only_for_own_site_passes(self):
        asked = []
        judge([entry(1)], {pid(1): [reviewed_claim()]})
        hide_guard.judge(*(lambda ps: ([b for b, _ in ps], rows_for(ps)))([entry(1), entry(2, basis="PASS_D",
                                                                                           account=None)]),
                         [], NOW, claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids},
                         site_reader=lambda ids: asked.append(list(ids)) or {i: SITE for i in ids})
        self.assertEqual(asked, [[pid(2)]])

    def test_every_own_site_row_is_decided_again_at_batch_time_admitted_or_not(self):
        """Whether the sender is verified is read from the conversation, and only the identity step reads it: a
        path-D row goes back through that step on every batch, also when its website still matches."""
        for now_site in (SITE, "https://somebody-else.example/"):
            pairs = [entry(1, basis="PASS_D", account=None), entry(2, request_id=2)]
            stale = hide_guard.needs_redecide(rows_for(pairs), [b for b, _ in pairs],
                                              claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids},
                                              site_reader=lambda ids: {i: now_site for i in ids})
            self.assertEqual([r["id"] for r in stale], [1], now_site)

    def test_a_track_is_weighed_on_its_artists_profile(self):
        """The claim is on the artist (owner_page), not on the track id."""
        (d,) = judge([entry(7, entity="track", owner=pid(1))], {pid(1): [reviewed_claim()]})
        self.assertEqual((d["outcome"], d["owner_page"]), ("admitted", pid(1)))
        (d,) = judge([entry(7, entity="track", owner=pid(1), account=STRANGER)], {pid(1): [reviewed_claim()]})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_HOLDER))


class UnreviewedClaims(unittest.TestCase):
    OWN = {"raws": ["muso:1111"], "created": T0 + 2}

    def test_an_instant_claim_counts_on_the_profile_that_account_created(self):
        (d,) = judge([entry(1)], {pid(1): [instant_claim()]}, {pid(1): self.OWN})
        self.assertEqual((d["outcome"], d["proof"], d["claim_id"]), ("admitted", "own_profile", "c2"))

    def test_an_instant_claim_does_not_count_once_other_sources_are_merged_in(self):
        """Measured 2026-11-13: an unreviewed claim reached a profile with three Tidal sources through a merge."""
        merged = {"raws": ["muso:1111", "tidal:22", "tidal:33", "tidal:44"], "created": T0 + 2}
        (d,) = judge([entry(1)], {pid(1): [instant_claim()]}, {pid(1): merged})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.UNVERIFIED))

    def test_an_instant_claim_does_not_count_on_a_profile_that_existed_before_it(self):
        old = {"raws": ["muso:1111"], "created": T0 - 3 * 365 * 86400}
        (d,) = judge([entry(1)], {pid(1): [instant_claim()]}, {pid(1): old})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.UNVERIFIED))

    def test_an_instant_claim_does_not_count_on_a_streaming_sourced_profile(self):
        (d,) = judge([entry(1)], {pid(1): [instant_claim()]}, {pid(1): {"raws": ["spotify:9"], "created": T0}})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.UNVERIFIED))

    def test_a_claim_with_a_reason_nobody_has_seen_is_not_a_reviewed_claim(self):
        c = dict(reviewed_claim(), reason="bulk import")
        self.assertFalse(hide_guard.reviewed(c))
        self.assertFalse(hide_guard.reviewed(dict(reviewed_claim(), links={"weblinks": [], "instagram": ""})))
        self.assertFalse(hide_guard.reviewed(dict(reviewed_claim(), links=None)))

    def test_a_profile_core_does_not_return_is_held_not_admitted(self):
        (d,) = judge([entry(1)], {pid(1): [instant_claim()]}, {})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_FOUND))

    def test_the_profile_is_read_only_for_claims_that_need_it(self):
        asked = []
        hide_guard.judge(*self._two(), [], NOW,
                         claim_reader=lambda ids: {pid(1): [reviewed_claim()], pid(2): [instant_claim()]},
                         source_reader=lambda ids: asked.append(list(ids)) or {pid(2): self.OWN})
        self.assertEqual(asked, [[pid(2)]])

    @staticmethod
    def _two():
        pairs = [entry(1), entry(2)]
        return [b for b, _ in pairs], rows_for(pairs)


class Unreadable(unittest.TestCase):
    def test_claims_that_cannot_be_read_raise_and_decide_nothing(self):
        pairs = [entry(1)]
        with self.assertRaises(sources.Unknown):
            hide_guard.judge([b for b, _ in pairs], rows_for(pairs), [], NOW, claim_reader=unreadable)

    def test_a_profile_missing_from_the_claim_answer_is_unread_not_unclaimed(self):
        pairs = [entry(1)]
        with self.assertRaises(sources.Unknown):
            hide_guard.judge([b for b, _ in pairs], rows_for(pairs), [], NOW, claim_reader=lambda ids: {})

    def test_a_profile_that_cannot_be_read_raises(self):
        pairs = [entry(1)]
        with self.assertRaises(sources.Unknown):
            hide_guard.judge([b for b, _ in pairs], rows_for(pairs), [], NOW,
                             claim_reader=lambda ids: {pid(1): [instant_claim()]}, source_reader=unreadable)


class TheIdentityStepAsks(unittest.TestCase):
    """`prove` is the same rule applied where the verdict is made, so a requester whose claim does not show
    ownership is ASKED by the identity step instead of waiting behind a hold nobody tells them about."""
    MERGED = {"raws": ["muso:1111", "tidal:22"], "created": T0}
    OWN = {"raws": ["muso:1111"], "created": T0 + 1}

    def page(self, n=1, holders=(OWNER,), **kw):
        return identity.Page(pid(n), "profile", True, "An Artist", True, frozenset(holders), 10.0, 5, **kw)

    def prove(self, facts, account=OWNER, claims=None, srcs=None):
        return hide_guard.prove(facts, account,
                                claim_reader=lambda ids: {i: (claims or {}).get(i, []) for i in ids},
                                source_reader=lambda ids: {i: srcs[i] for i in ids if i in (srcs or {})})

    def verdict(self, page, account=OWNER, cls="privacy_erasure"):
        return identity.decide_page(page, identity.Requester(name="x", email="x@example.org", account_id=account),
                                    cls)

    def test_a_reviewed_claim_still_passes(self):
        (p,) = self.prove([self.page()], claims={pid(1): [reviewed_claim()]})
        pv = self.verdict(p)
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("PASS_A", OWNER, pid(1)))

    def test_an_instant_claim_on_the_accounts_own_profile_still_passes(self):
        (p,) = self.prove([self.page()], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.OWN})
        self.assertEqual(self.verdict(p).verdict, "PASS_A")

    def test_an_unverified_claim_on_a_merged_profile_is_asked_and_told_why(self):
        (p,) = self.prove([self.page()], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.MERGED})
        self.assertEqual((p.claim_user_ids, p.claim_unproven), (frozenset(), frozenset({OWNER})))
        pv = self.verdict(p)
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("ASK_IDENTITY", None, ""))
        self.assertIn("without verification", pv.why)

    def test_a_takedown_on_an_unverified_claim_does_not_pass(self):
        (p,) = self.prove([self.page()], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.MERGED})
        self.assertEqual(self.verdict(p, cls="dmca_takedown").verdict, "DMCA_REVIEW")

    def test_somebody_elses_claim_stays_on_the_page(self):
        (p,) = self.prove([self.page(holders=(OWNER, STRANGER))],
                          claims={pid(1): [instant_claim(OWNER), reviewed_claim(STRANGER, "c9")]},
                          srcs={pid(1): self.MERGED})
        self.assertEqual(p.claim_user_ids, frozenset({STRANGER}))
        self.assertEqual(self.verdict(p, account=STRANGER).verdict, "PASS_A")

    def test_a_track_is_weighed_on_its_artist(self):
        track = identity.Page(pid(7), "track", name="A Song", popularity=1.0, item_read=True,
                              artists=(self.page(),))
        (t,) = self.prove([track], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.MERGED})
        self.assertEqual(t.artists[0].claim_user_ids, frozenset())
        self.assertNotEqual(self.verdict(t).verdict, "PASS_A")
        (t,) = self.prove([track], claims={pid(1): [reviewed_claim()]})
        self.assertEqual(self.verdict(t).verdict, "PASS_A")

    def test_nothing_is_read_for_a_requester_who_holds_no_claim(self):
        facts = [self.page(holders=(STRANGER,)), identity.Page(pid(2), found=False)]
        self.assertIs(hide_guard.prove(facts, OWNER, claim_reader=unreadable, source_reader=unreadable), facts)
        self.assertIs(hide_guard.prove(facts, None, claim_reader=unreadable, source_reader=unreadable), facts)

    def test_nothing_is_read_for_a_page_the_hide_lists_already_hold(self):
        """A hidden or half-hidden page is decided from the config lists before the claim is looked at, so a read
        there cannot change the verdict - it could only fail the run (`sources.Unknown`) over a proof nobody uses."""
        for kw in ({"hidden": True}, {"half_hidden": "pdp"}):
            facts = [self.page(**kw)]
            self.assertIs(hide_guard.prove(facts, OWNER, claim_reader=unreadable, source_reader=unreadable), facts)

    def test_a_proof_that_cannot_be_read_is_not_an_ask(self):
        with self.assertRaises(sources.Unknown):
            hide_guard.prove([self.page()], OWNER, claim_reader=unreadable)
        with self.assertRaises(sources.Unknown):
            self.prove([self.page()], claims={pid(1): [instant_claim()]}, srcs={})      # core returned no profile
        with self.assertRaises(sources.Unknown):
            hide_guard.prove([self.page()], OWNER, claim_reader=lambda ids: {pid(1): [instant_claim()]},
                             source_reader=unreadable)

    def test_a_profile_missing_from_the_claim_answer_is_unread_not_an_ask(self):
        """A claim answer that leaves a profile out did not come back whole. Read as "no claim", it would turn the
        owner of the second page into somebody who is asked to prove it."""
        with self.assertRaises(sources.Unknown):
            hide_guard.prove([self.page(1), self.page(2)], OWNER,
                             claim_reader=lambda ids: {pid(1): [reviewed_claim()]},
                             source_reader=lambda ids: {i: self.MERGED for i in ids})


class DecideRow(unittest.TestCase):
    """Through Run.decide_row: what lands on the register row."""

    def decide(self, claim, srcs):
        s = Store(":memory:")
        self.addCleanup(s.db.close)
        rid, _ = s.upsert({"keys": ["register:901"], "channel": "register", "class": "privacy_erasure",
                           "received_at": "2026-11-01T00:00:00Z", "requester_email": "owner@example.org",
                           "pages": [{"id": pid(1)}]})
        facts = lambda pages, hid, cl, half=None, items=False: [                               # noqa: E731
            identity.Page(p["id"], "profile", True, "An Artist", True, frozenset(cl.get(p["id"], ())), 10.0, 5)
            for p in pages]
        with mock.patch.object(sources, "resolve_account", lambda *a, **k: (OWNER, "unique account email")), \
                mock.patch.object(sources, "account_names", lambda ids: {}), \
                mock.patch.object(sources, "processed_claims", lambda ids: {i: {OWNER} for i in ids}), \
                mock.patch.object(sources, "claim_proofs", lambda ids: {i: [claim] for i in ids}), \
                mock.patch.object(sources, "profile_sources", lambda ids: {i: srcs for i in ids}), \
                mock.patch.object(sources, "page_facts", facts):
            Run(s, log=lambda *_: None).decide_row(s.get(rid), set(), {}, lambda c: {})
        return s.get(rid)

    def test_a_pass_records_the_account_and_the_profile_it_rests_on(self):
        row = self.decide(reviewed_claim(), None)
        self.assertEqual(row["verdict_detail"][0] | {"why": ""},
                         {"id": pid(1), "verdict": "PASS_A", "why": "", "account": OWNER, "owner_page": pid(1)})
        self.assertEqual(hide_guard.needs_redecide(
            [row], [{"id": pid(1), "basis": "PASS_A", "request_id": row["id"]}],
            claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids}),
                         [])

    def test_a_pass_whose_claim_was_deleted_is_put_back_for_a_new_decision(self):
        row = self.decide(reviewed_claim(), None)
        stale = hide_guard.needs_redecide([row], [{"id": pid(1), "basis": "PASS_A", "request_id": row["id"]}],
                                          claim_reader=lambda ids: {i: [] for i in ids})
        self.assertEqual([r["id"] for r in stale], [row["id"]])

    def decide_d(self, website, source_type="email"):
        """A verified sender with no account and no claim, writing from `mgmt@artist-site.example`."""
        s = Store(":memory:")
        self.addCleanup(s.db.close)
        rid, _ = s.upsert({"keys": ["intercom:902"], "channel": "intercom", "class": "privacy_erasure",
                           "received_at": "2026-11-01T00:00:00Z", "requester_email": f"mgmt@{HOST}",
                           "conversation_id": "902", "pages": [{"id": pid(1)}]})
        facts = lambda pages, hid, cl, half=None, items=False: [                               # noqa: E731
            identity.Page(p["id"], "profile", True, "An Artist", False, frozenset(), 10.0, 5, website)
            for p in pages]
        conv = {"source_type": source_type, "author_email": f"mgmt@{HOST}", "author_name": "Management"}
        with mock.patch.object(sources, "resolve_account", lambda *a, **k: (None, "")), \
                mock.patch.object(sources, "account_names", lambda ids: {}), \
                mock.patch.object(sources, "processed_claims", lambda ids: {}), \
                mock.patch.object(sources, "claim_proofs", unreadable), \
                mock.patch.object(sources, "profile_sources", unreadable), \
                mock.patch.object(sources, "page_facts", facts):
            Run(s, log=lambda *_: None).decide_row(s.get(rid), set(), {}, lambda c: conv)
        return s.get(rid)

    def test_an_own_site_pass_records_the_sender_host_the_guard_compares(self):
        row = self.decide_d(SITE)
        self.assertEqual(row["verdict_detail"][0] | {"why": ""},
                         {"id": pid(1), "verdict": "PASS_D", "why": "", "owner_page": pid(1), "sender_host": HOST})
        (b,) = hide_batch.plan([row], set(), set(), {})
        for now_site, want in ((SITE, ("admitted", "")), ("https://new-owner.example/", ("held",
                                                                                       hide_guard.SITE_MOVED))):
            (d,) = hide_guard.judge([b], [row], [], NOW, site_reader=lambda ids: {i: now_site for i in ids})
            self.assertEqual((d["outcome"], d["reason"]), want, now_site)

    def test_an_own_site_row_decided_again_after_the_website_moved_is_asked(self):
        """What the batch-time re-decision does with the stale pass: the identity step reads the site, no path
        passes, and the row carries the ask instead of a pass the guard keeps holding."""
        row = self.decide_d("https://new-owner.example/")
        self.assertEqual((row["identity_verdict"], row["ask_kind"]), ("ASK_IDENTITY", "ASK_IDENTITY"))
        self.assertNotIn("sender_host", row["verdict_detail"][0])
        self.assertEqual(hide_batch.plan([row], set(), set(), {}), [])

    def test_an_own_site_row_whose_sender_is_not_verified_is_asked(self):
        row = self.decide_d(SITE, source_type="conversation")
        self.assertEqual(row["identity_verdict"], "ASK_IDENTITY")
        self.assertEqual(hide_batch.plan([row], set(), set(), {}), [])

    def test_an_unverified_claim_on_a_merged_profile_is_decided_ask_and_the_chain_asks_for_the_tie(self):
        row = self.decide(instant_claim(), {"raws": ["muso:1", "tidal:2"], "created": T0})
        self.assertEqual((row["identity_verdict"], row["ask_kind"]), ("ASK_IDENTITY", "ASK_IDENTITY"))
        self.assertNotIn("owner_page", row["verdict_detail"][0])
        self.assertEqual(row["gates"]["tie"]["pass"], False)
        self.assertEqual(row["gates"]["need"], dsar.NEED_CLAIM_OR_AUTHORITY)
        self.assertEqual(hide_batch.plan([row], set(), set(), {}), [])


class Readers(unittest.TestCase):
    def test_profile_sources_reads_the_live_profile(self):
        doc = {"rawProfiles": [{"id": "abc", "source": "muso", "name": "n", "url": None}],
               "createdAt": "2026-11-13T01:42:21.790000"}
        with mock.patch.object(sources, "profile_doc", lambda p: doc if p == pid(1) else None):
            got = sources.profile_sources([pid(1), pid(2), "not-an-id"])
        self.assertEqual(got, {pid(1): {"raws": ["muso:abc"], "created": 1794534141}})

    def test_a_profile_answer_without_sources_or_a_date_is_unread(self):
        for doc in ({"createdAt": "2026-11-13T01:42:21"}, {"rawProfiles": [{"id": "a"}], "createdAt": "2026-11-13"},
                    {"rawProfiles": [], "createdAt": None}, {"rawProfiles": [], "createdAt": "soon"}):
            with mock.patch.object(sources, "profile_doc", lambda p: doc), self.assertRaises(sources.Unknown):
                sources.profile_sources([pid(1)])

    def test_profile_sites_reads_the_website_on_the_live_profile(self):
        docs = {pid(1): {"links": {"website": SITE, "instagram": None}}, pid(2): {"links": {"website": None}},
                pid(3): {"links": None}, pid(4): {"name": "An Artist"}}
        with mock.patch.object(sources, "profile_doc", docs.get):
            got = sources.profile_sites([pid(1), pid(2), pid(3), pid(4), pid(5), "not-an-id"])
        self.assertEqual(got, {pid(1): SITE, pid(2): "", pid(3): "", pid(4): ""})

    def test_a_website_that_is_not_text_is_unread(self):
        for doc in ({"links": ["https://a.example"]}, {"links": {"website": {"url": SITE}}}, {"links": "x"}):
            with mock.patch.object(sources, "profile_doc", lambda p: doc), self.assertRaises(sources.Unknown):
                sources.profile_sites([pid(1)])

    def test_claim_proofs_parses_the_claim_and_never_guesses(self):
        row = ["77", pid(1), str(OWNER), "", "created by user", '{"weblinks":["https://a.example"]}', str(T0)]
        with mock.patch.object(sources, "trino", lambda sql: [row]):
            got = sources.claim_proofs([pid(1), pid(2)])
        self.assertEqual(got[pid(1)], [{"claim_id": "77", "account": OWNER, "reason": "created by user",
                                        "links": {"weblinks": ["https://a.example"]}, "created": T0}])
        self.assertEqual(got[pid(2)], [])
        for bad in (row[:6], row[:2] + [""] + row[3:], row[:5] + ["{not json"] + row[6:]):
            with mock.patch.object(sources, "trino", lambda sql: [bad]), self.assertRaises(sources.Unknown):
                sources.claim_proofs([pid(1)])

    def test_a_claim_filed_on_an_extra_profile_counts_for_that_profile(self):
        row = ["78", pid(9), str(OWNER), f'["{pid(2)}"]', "", "", str(T0)]
        with mock.patch.object(sources, "trino", lambda sql: [row]):
            got = sources.claim_proofs([pid(2)])
        self.assertEqual([c["claim_id"] for c in got[pid(2)]], ["78"])
        self.assertIsNone(got[pid(2)][0]["links"])


def admitted_event(n, requester, at, request_id=1):
    return {"request_id": request_id, "at": at.strftime("%Y-%m-%dT%H:%M:%SZ"), "kind": hide_guard.EVENT,
            "detail": {"page": pid(n), "owner_page": pid(n), "outcome": "admitted", "reason": "",
                       "requester": requester}}


class Caps(unittest.TestCase):
    def _burst(self, n, **kw):
        pairs = [entry(i) for i in range(1, n + 1)]
        return judge(pairs, {pid(i): [reviewed_claim()] for i in range(1, n + 1)}, **kw)

    def test_a_burst_from_one_requester_is_held_past_three(self):
        out = self._burst(5)
        self.assertEqual([d["outcome"] for d in out], ["admitted"] * 3 + ["held"] * 2)
        self.assertEqual({d["reason"] for d in out[3:]}, {hide_guard.REQUESTER_CAP})
        self.assertTrue(all(not d["proof"] and not d["claim_id"] for d in out[3:]))

    def test_the_cap_counts_what_was_admitted_earlier_in_the_day(self):
        earlier = [admitted_event(n, f"account:{OWNER}", NOW - timedelta(hours=5)) for n in (91, 92)]
        out = self._burst(3, history=earlier)
        self.assertEqual([d["outcome"] for d in out], ["admitted", "held", "held"])

    def test_a_held_page_is_admitted_once_the_day_has_passed(self):
        earlier = [admitted_event(n, f"account:{OWNER}", NOW - timedelta(hours=25)) for n in (91, 92, 93)]
        self.assertEqual([d["outcome"] for d in self._burst(3, history=earlier)], ["admitted"] * 3)

    def test_a_page_already_admitted_stays_admitted_and_spends_nothing(self):
        """The whole set is offered on every run: an id admitted yesterday must not be dropped from the PR today."""
        earlier = [admitted_event(n, f"account:{OWNER}", NOW - timedelta(hours=1)) for n in (1, 2, 3)]
        out = self._burst(4, history=earlier)
        self.assertEqual([d["outcome"] for d in out], ["admitted"] * 3 + ["held"])

    def test_two_pages_of_one_artist_spend_one(self):
        pairs = [entry(1), entry(71, entity="track", owner=pid(1)), entry(72, entity="album", owner=pid(1)),
                 entry(2), entry(3), entry(4)]
        out = judge(pairs, {pid(i): [reviewed_claim()] for i in (1, 2, 3, 4)})
        self.assertEqual([d["outcome"] for d in out], ["admitted"] * 5 + ["held"])

    def test_the_register_admits_twenty_in_a_day(self):
        pairs = [entry(i, account=1000 + i, request_id=i, register_no=500 + i) for i in range(1, 23)]
        out = judge(pairs, {pid(i): [reviewed_claim(1000 + i)] for i in range(1, 23)})
        self.assertEqual([d["outcome"] for d in out], ["admitted"] * 20 + ["held"] * 2)
        self.assertEqual({d["reason"] for d in out[20:]}, {hide_guard.GLOBAL_CAP})

    def test_a_page_held_for_ownership_spends_no_cap(self):
        pairs = [entry(1, account=STRANGER), entry(2, account=STRANGER), entry(3, account=STRANGER),
                 entry(4, account=STRANGER)]
        out = judge(pairs, {pid(i): [reviewed_claim(OWNER)] for i in range(1, 5)})
        self.assertEqual({d["reason"] for d in out}, {hide_guard.NOT_HOLDER})

    def test_requesters_without_an_account_are_told_apart_by_address_and_never_printed(self):
        a = hide_guard.requester_key({"id": 1, "requester_email": "Artist@Own-Site.example"}, {})
        b = hide_guard.requester_key({"id": 2, "requester_email": "artist@own-site.example "}, {})
        self.assertEqual(a, b)
        self.assertNotIn("own-site", a)
        self.assertEqual(hide_guard.requester_key({"id": 9, "requester_email": ""}, {}), "request:9")

    def test_every_hold_the_guard_issues_carries_what_it_needs(self):
        """Driven through `judge`: every reason it actually returns has advice, and every advice row is reachable
        (a reason nobody can produce is a table entry an operator would be reading for nothing)."""
        burst = [admitted_event(n, f"account:{OWNER}", NOW - timedelta(hours=1)) for n in (91, 92, 93)]
        register = [admitted_event(100 + n, f"account:{1000 + n}", NOW - timedelta(hours=1), request_id=100 + n)
                    for n in range(1, 21)]
        cases = [
            ([entry(1, basis="PASS_B")], {pid(1): [reviewed_claim()]}, {}, ()),
            ([entry(1, basis="LEGAL_HIDE_FIRST", account=None)], {}, {}, ()),
            ([entry(1, recorded=False)], {pid(1): [reviewed_claim()]}, {}, ()),
            ([entry(1, account=STRANGER)], {pid(1): [reviewed_claim(OWNER)]}, {}, ()),
            ([entry(1)], {pid(1): [instant_claim()]}, {pid(1): {"raws": ["muso:1", "tidal:2"], "created": T0}}, ()),
            ([entry(1)], {pid(1): [instant_claim()]}, {}, ()),
            ([entry(1)], {pid(1): [reviewed_claim()]}, {}, burst),
            ([entry(1)], {pid(1): [reviewed_claim()]}, {}, register),
            ([entry(1, basis="PASS_D", account=None)], {}, {}, ()),
        ]
        seen = {}
        for pairs, claims, srcs, history in cases:
            (d,) = judge(pairs, claims, srcs, history=history, sites={pid(1): "https://somebody-else.example/"})
            self.assertEqual(d["outcome"], "held", d)
            self.assertTrue((hide_guard.NEXT.get(d["reason"]) or "").strip(), d["reason"])
            seen[d["reason"]] = hide_guard.NEXT[d["reason"]]
        self.assertEqual(set(seen), set(hide_guard.NEXT))


class Recorded(unittest.TestCase):
    """Against a real register: the audit rows, the dry run, and the alert."""

    def setUp(self):
        self.s = Store(":memory:")
        self.addCleanup(self.s.db.close)

    def request(self, n, pairs):
        rid, _ = self.s.upsert({"keys": [f"register:{900 + n}"], "channel": "register", "class": "privacy_erasure",
                                "received_at": "2026-11-01T00:00:00Z", "requester_email": "owner@example.org",
                                "requester_name": "A Name", "pages": [{"id": b["id"]} for b, _ in pairs]})
        self.s.update(rid, "decide", verdict_detail=[d for _, d in pairs])
        row = self.s.get(rid)
        return row, [dict(b, request_id=rid, register_no=row["register_no"]) for b, _ in pairs]

    def guard(self, batch, rows, claims, write=True, now=None):
        return hide_guard.guard(batch, rows, self.s, write=write, now=now,
                                claim_reader=lambda ids: {i: claims.get(i, []) for i in ids},
                                source_reader=lambda ids: {})

    def test_a_non_owner_is_dropped_from_the_batch_and_the_refusal_is_on_the_record(self):
        row, batch = self.request(1, [entry(1, account=STRANGER), entry(2)])
        admitted, _ = self.guard(batch, [row], {pid(1): [reviewed_claim(OWNER)], pid(2): [reviewed_claim(OWNER)]})
        self.assertEqual([b["id"] for b in admitted], [pid(2)])
        ev = {e["detail"]["page"]: e["detail"] for e in self.s.events_of_kind(hide_guard.EVENT)}
        self.assertEqual((ev[pid(1)]["outcome"], ev[pid(1)]["reason"], ev[pid(1)]["requester"]),
                         ("held", hide_guard.NOT_HOLDER, f"account:{STRANGER}"))
        self.assertEqual((ev[pid(2)]["outcome"], ev[pid(2)]["proof"], ev[pid(2)]["claim_id"]),
                         ("admitted", "reviewed_claim", "c1"))

    def test_an_unchanged_decision_writes_no_second_row(self):
        row, batch = self.request(1, [entry(1)])
        claims = {pid(1): [reviewed_claim()]}
        self.guard(batch, [row], claims)
        self.guard(batch, [row], claims)
        self.assertEqual(len(self.s.events_of_kind(hide_guard.EVENT)), 1)
        self.guard(batch, [row], {pid(1): []})        # the claim is gone: that is a new row
        kinds = [(e["detail"]["outcome"], e["detail"]["reason"]) for e in self.s.events_of_kind(hide_guard.EVENT)]
        self.assertEqual(kinds, [("admitted", ""), ("held", hide_guard.NOT_HOLDER)])

    def test_a_dry_run_records_nothing_and_spends_no_cap(self):
        row, batch = self.request(1, [entry(i) for i in range(1, 6)])
        claims = {pid(i): [reviewed_claim()] for i in range(1, 6)}
        admitted, _ = self.guard(batch, [row], claims, write=False)
        self.assertEqual(len(admitted), 3)
        self.assertEqual(self.s.events_of_kind(hide_guard.EVENT), [])
        admitted, _ = self.guard(batch, [row], claims, write=True)
        self.assertEqual(len(admitted), 3)

    def test_a_burst_is_held_paged_once_and_admitted_the_next_day(self):
        row, batch = self.request(1, [entry(i) for i in range(1, 6)])
        claims = {pid(i): [reviewed_claim()] for i in range(1, 6)}
        now = datetime.now(timezone.utc)
        admitted, decisions = self.guard(batch, [row], claims, now=now)
        self.assertEqual([b["id"] for b in admitted], [pid(1), pid(2), pid(3)])
        alert = hide_guard.to_page(decisions, self.s.events_of_kind(hide_guard.PAGED), now)
        self.assertEqual([d["page"] for d in alert], [pid(4), pid(5)])
        text = hide_guard.page_text(alert)
        self.assertIn(f"account:{OWNER}: 2 held", text)
        self.assertIn(f"#{row['register_no']}", text)
        self.assertNotIn("@", text)
        self.assertNotIn("A Name", text)
        hide_guard.mark_paged(self.s, alert)
        # the next run, same day: still held, still the same three, nobody paged again
        admitted, decisions = self.guard(batch, [row], claims, now=now + timedelta(hours=6))
        self.assertEqual([b["id"] for b in admitted], [pid(1), pid(2), pid(3)])
        self.assertEqual(hide_guard.to_page(decisions, self.s.events_of_kind(hide_guard.PAGED),
                                            now + timedelta(hours=6)), [])
        # a day later the two are admitted and the first three are still in the set
        admitted, _ = self.guard(batch, [row], claims, now=now + timedelta(hours=25))
        self.assertEqual(len(admitted), 5)

    def test_an_ownership_hold_is_not_paged(self):
        row, batch = self.request(1, [entry(1, account=STRANGER)])
        _, decisions = self.guard(batch, [row], {pid(1): [reviewed_claim(OWNER)]})
        self.assertEqual(hide_guard.to_page(decisions, [], datetime.now(timezone.utc)), [])


def _cli():
    import importlib.util
    spec = importlib.util.spec_from_file_location("gdpr_pipeline_cli_guard", os.path.join(HERE, "gdpr-pipeline.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class HideBatchCommand(unittest.TestCase):
    """`gdpr-pipeline.py hide-batch --open-prs` end to end, with the two repositories and the replica faked."""

    def setUp(self):
        self.cli = _cli()
        self.s = Store(":memory:")
        self.addCleanup(self.s.db.close)
        self.opened: list[list[str]] = []
        self.posts: list[str] = []
        self.claims: dict[str, list[dict]] = {}
        self.slack_ok = True

    def request(self, n, pairs, cls="privacy_erasure"):
        rid, _ = self.s.upsert({"keys": [f"register:{900 + n}"], "channel": "register", "class": cls,
                                "received_at": "2026-11-01T00:00:00Z", "requester_email": f"r{n}@example.org",
                                "pages": [{"id": b["id"]} for b, _ in pairs]})
        self.s.update(rid, "decide", verdict_detail=[d for _, d in pairs])
        return rid

    def run_cli(self, *args, claim_reader=None):
        def open_prs(batch, dry_run=True, **_):
            self.opened.append([b["id"] for b in batch])
            return {"blocked_items": [], "kept": {}, "superseded": {}, "close_failed": [], "unreadable": {},
                    "opened": {}, "hdevops": "", "pdp": ""}

        def post(text):
            self.posts.append(text)
            return self.slack_ok

        reader = claim_reader or (lambda ids: {i: self.claims.get(i, []) for i in ids})
        out = io.StringIO()
        with mock.patch.object(self.cli, "Store", lambda *a, **k: self.s), \
                mock.patch.object(self.cli, "hold_lock", lambda *a, **k: mock.MagicMock()), \
                mock.patch.object(self.cli, "KILL", "/nonexistent/gdpr-pipeline.disabled"), \
                mock.patch.object(self.cli, "slack_post", post), \
                mock.patch.object(sources, "hidden_lists", lambda: (set(), set())), \
                mock.patch.object(sources, "claim_proofs", reader), \
                mock.patch.object(sources, "profile_sources", lambda ids: {}), \
                mock.patch.object(hide_batch, "in_flight_ids", lambda ids, **k: {}), \
                mock.patch.object(hide_batch, "own_added", lambda **k: {"hdevops": set(), "pdp": set()}), \
                mock.patch.object(hide_batch, "open_prs", open_prs), \
                mock.patch.object(sys, "argv", ["gdpr-pipeline.py", "--store", ":memory:", "hide-batch", *args]), \
                contextlib.redirect_stdout(out):
            rc = self.cli.main()
        return rc, out.getvalue()

    def test_a_non_owner_request_is_refused_and_the_owner_is_prepared(self):
        self.request(1, [entry(1, account=STRANGER)])
        self.request(2, [entry(2)])
        self.claims = {pid(1): [reviewed_claim(OWNER)], pid(2): [reviewed_claim(OWNER)]}
        # the held row is decided again (hide_guard.needs_redecide); that pass is another test's subject
        with mock.patch.object(self.cli.Run, "decide_rows", lambda run, rows, *a, **k: None):
            rc, out = self.run_cli("--open-prs")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.opened, [[pid(2)]])
        self.assertIn(f"{pid(1)} PASS_A: {hide_guard.NOT_HOLDER}", out)
        self.assertEqual(self.posts, [])

    def test_a_legal_request_is_held_even_on_the_include_legal_run(self):
        self.request(1, [entry(1, basis="LEGAL_HIDE_FIRST", account=None)], cls="legal_threat")
        rc, out = self.run_cli("--open-prs", "--include-legal")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.opened, [[]])
        self.assertIn(hide_guard.LEGAL, out)

    def test_a_burst_is_refused_and_paged(self):
        self.request(1, [entry(i) for i in range(1, 6)])
        self.claims = {pid(i): [reviewed_claim()] for i in range(1, 6)}
        rc, out = self.run_cli("--open-prs")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.opened, [[pid(1), pid(2), pid(3)]])
        self.assertEqual(len(self.posts), 1)
        self.assertIn("2 page(s) held over the daily cap", self.posts[0])
        self.assertNotIn("@", self.posts[0])
        self.run_cli("--open-prs")
        self.assertEqual(len(self.posts), 1, "the same hold is paged once a day, not once a run")
        self.assertEqual(self.opened[-1], [pid(1), pid(2), pid(3)])

    def test_an_alert_that_was_not_delivered_fails_the_run_and_is_posted_again(self):
        self.request(1, [entry(i) for i in range(1, 6)])
        self.claims = {pid(i): [reviewed_claim()] for i in range(1, 6)}
        self.slack_ok = False
        rc, _ = self.run_cli("--open-prs")
        self.assertEqual(rc, 2)
        self.assertEqual(self.s.events_of_kind(hide_guard.PAGED), [])
        self.slack_ok = True
        rc, _ = self.run_cli("--open-prs")
        self.assertEqual((rc, len(self.posts)), (0, 2))

    def test_unreadable_claims_stop_the_run_before_the_open_pr_is_touched(self):
        self.request(1, [entry(1)])
        rc, out = self.run_cli("--open-prs", claim_reader=unreadable)
        self.assertEqual(rc, 2, out)
        self.assertEqual(self.opened, [])
        self.assertEqual(self.s.events_of_kind(hide_guard.EVENT), [])

    def test_a_dry_run_shows_the_holds_and_records_nothing(self):
        self.request(1, [entry(1, account=STRANGER)])
        self.claims = {pid(1): [reviewed_claim(OWNER)]}
        rc, out = self.run_cli()
        self.assertEqual(rc, 0, out)
        self.assertIn(hide_guard.NOT_HOLDER, out)
        self.assertEqual(self.s.events_of_kind(hide_guard.EVENT), [])
        self.assertEqual(self.posts, [])

    def test_a_pass_decided_before_the_proof_was_recorded_is_decided_again_first(self):
        rid = self.request(1, [entry(1, recorded=False)])
        self.claims = {pid(1): [reviewed_claim()]}
        calls = []

        def redecide(run, rows, hidden, **_):
            calls.append([r["id"] for r in rows])
            self.s.update(rid, "decide", verdict_detail=[entry(1)[1]])

        with mock.patch.object(self.cli.Run, "decide_rows", redecide):
            rc, out = self.run_cli("--open-prs")
        self.assertEqual((rc, calls, self.opened), (0, [[rid]], [[pid(1)]]), out)


if __name__ == "__main__":
    unittest.main()
