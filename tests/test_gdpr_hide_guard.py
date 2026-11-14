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
    return {"claim_id": claim_id, "account": account, "reason": "", "created": T0, "processed_later": True,
            "links": {"instagram": "https://instagram.com/the.artist", "weblinks": []}}


# The profile under test as the live admin profile reads now: a streaming-sourced page that links the instagram
# account `reviewed_claim` names. A claim link is evidence only against this (`sources.link_matches_profile`).
LINKED = {"raws": ["spotify:9", "tidal:2"], "created": T0 - 86400,
          "identity": sources.ProfileIdentity(social=frozenset({("instagram", "the.artist")}))}


def linked(ids):
    return {i: LINKED for i in ids}


def instant_claim(account=OWNER, claim_id="c2"):
    return {"claim_id": claim_id, "account": account, "reason": "created by user", "created": T0, "links": "",
            "processed_later": False}


SITE = "https://www.artist-site.example/"      # the website the profile under test carries
HOST = "artist-site.example"                    # ... and the sender host a path-D pass on it rested on


def entry(n, basis="PASS_A", account=OWNER, request_id=1, register_no=500, entity="profile", owner=None,
          recorded=True, sender_host=HOST):
    """(batch entry, the stored page decision it was planned from)."""
    b = {"id": pid(n), "entity": entity, "register_no": register_no, "basis": basis,
         "due_at": "2026-12-01T00:00:00Z", "need": ["hdevops", "pdp"], "request_id": request_id}
    d = {"id": pid(n), "verdict": basis, "why": "test", "rules": identity.RULES_V}
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
                            source_reader=linked if srcs is None else (
                                lambda ids: {i: srcs[i] for i in ids if i in srcs}),
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
                                              10.0, 5, checked_claim_user_ids=frozenset({OWNER}))], OWNER,
                                claim_reader=lambda ids: claims, source_reader=linked)
        pv = identity.decide_page(p, identity.Requester(name="x", email="x@example.org", account_id=OWNER),
                                 "legal_threat")
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("PASS_A", OWNER, pid(1)))
        (d,) = judge([entry(1, basis=pv.verdict, account=pv.account_id, owner=pv.owner_page)], claims)
        self.assertEqual((d["outcome"], d["proof"], d["claim_id"]), ("admitted", "reviewed_claim", "c1"))

    def test_a_takedown_from_the_claim_holder_enters_as_path_a(self):
        """A verified DMCA claimant is an owner's request too: the identity step's pass has to carry the account and
        the profile the guard re-reads, or `judge` holds it as NOT_RECORDED and the hide never happens."""
        claims = {pid(1): [reviewed_claim()]}
        (p,) = hide_guard.prove([identity.Page(pid(1), "profile", True, "An Artist", True, frozenset({OWNER}),
                                              10.0, 5, checked_claim_user_ids=frozenset({OWNER}))], OWNER,
                                claim_reader=lambda ids: claims, source_reader=linked)
        pv = identity.decide_page(p, identity.Requester(name="x", email="x@example.org", account_id=OWNER),
                                  "dmca_takedown")
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("PASS_A", OWNER, pid(1)))
        (d,) = judge([entry(1, basis=pv.verdict, account=pv.account_id, owner=pv.owner_page)], claims)
        self.assertEqual((d["outcome"], d["reason"], d["proof"], d["claim_id"]),
                         ("admitted", "", "reviewed_claim", "c1"))

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
                                          claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids},
                                          source_reader=linked)
        self.assertEqual([r["id"] for r in stale], [1])
        done = [entry(1)]
        self.assertEqual(hide_guard.needs_redecide(rows_for(done), [b for b, _ in done],
                                                  claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids},
                                                  source_reader=linked),
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
                                                  claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids},
                                                  source_reader=linked), [])

    def test_a_claim_processed_the_moment_it_was_made_cannot_replace_the_reviewed_one(self):
        """The pass was recorded on a claim processed after it was made. That claim is deleted, and the account still
        holds another with the same matching link and no `reason`, processed the second it was filed: nobody looked
        at it, the identity step would ask, and the guard holds the page on a multi-source profile the same way."""
        pairs = [entry(1)]
        rows = rows_for(pairs)
        instant = dict(reviewed_claim(claim_id="c9"), processed_later=False)
        self.assertFalse(hide_guard.reviewed(instant, LINKED))
        for claim in (instant, {k: v for k, v in instant.items() if k != "processed_later"},
                      dict(instant, processed_later="true")):               # only the reader's own True counts
            (d,) = judge(pairs, {pid(1): [claim]})
            self.assertEqual((d["outcome"], d["proof"], d["reason"]), ("held", "", hide_guard.UNVERIFIED), claim)
        self.assertEqual(hide_guard.needs_redecide(rows, [b for b, _ in pairs],
                                                  claim_reader=lambda ids: {i: [instant] for i in ids},
                                                  source_reader=linked), rows)
        # while the reviewed claim is still there, the instant one beside it changes nothing
        (d,) = judge(pairs, {pid(1): [instant, reviewed_claim()]})
        self.assertEqual((d["outcome"], d["proof"], d["claim_id"]), ("admitted", "reviewed_claim", "c1"))

    def test_a_proof_that_fails_now_is_not_passed_by_a_takedown_or_a_legal_threat(self):
        """`page_facts` called the claim checked; the live read does not (its link names nobody's account now). The
        failed proof takes the account out of the checked set too, so the two classes that read that set first ask
        instead of passing a page the guard would only hold in silence."""
        changed = dict(reviewed_claim(), links={"weblinks": ["https://www.youtube.com/shorts/abc123"]})
        page = identity.Page(pid(1), "profile", True, "An Artist", True, frozenset({OWNER}), 10.0, 5,
                             checked_claim_user_ids=frozenset({OWNER}))
        (p,) = hide_guard.prove([page], OWNER, claim_reader=lambda ids: {pid(1): [changed]}, source_reader=linked)
        self.assertEqual((p.claim_user_ids, p.checked_claim_user_ids, p.claim_unproven),
                         (frozenset(), frozenset(), frozenset({OWNER})))
        who = identity.Requester(name="x", email="x@example.org", account_id=OWNER)
        got = {cls: identity.decide_page(p, who, cls).verdict
               for cls in ("dmca_takedown", "legal_threat", "privacy_erasure")}
        self.assertEqual(got, {"dmca_takedown": "DMCA_REVIEW", "legal_threat": "ASK_IDENTITY",
                               "privacy_erasure": "ASK_IDENTITY"})
        self.assertIn("link", identity.decide_page(p, who, "dmca_takedown").why)       # says why, not "no claim"
        # and the proof that still holds keeps passing all three
        (ok,) = hide_guard.prove([page], OWNER, claim_reader=lambda ids: {pid(1): [reviewed_claim()]},
                                 source_reader=linked)
        self.assertEqual({cls: identity.decide_page(ok, who, cls).verdict
                          for cls in ("dmca_takedown", "legal_threat", "privacy_erasure")},
                         dict.fromkeys(("dmca_takedown", "legal_threat", "privacy_erasure"), "PASS_A"))

    def test_a_recorded_pass_whose_claim_no_longer_names_the_profile_is_decided_again(self):
        """The pass was recorded while the claim linked the profile's own account. The claimant has since replaced
        the link with a page that is nobody's account: the guard holds the page, and the row goes back to the
        identity step, which asks for the tie instead of leaving the hold in silence."""
        pairs = [entry(1)]
        rows = rows_for(pairs)
        changed = dict(reviewed_claim(), links={"weblinks": ["https://www.youtube.com/shorts/abc123"]})
        (d,) = judge(pairs, {pid(1): [changed]})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.UNVERIFIED))
        self.assertEqual(hide_guard.needs_redecide(rows, [b for b, _ in pairs],
                                                  claim_reader=lambda ids: {i: [changed] for i in ids},
                                                  source_reader=linked), rows)

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
                         source_reader=linked,
                         site_reader=lambda ids: asked.append(list(ids)) or {i: SITE for i in ids})
        self.assertEqual(asked, [[pid(2)]])

    def test_every_own_site_row_is_decided_again_at_batch_time_admitted_or_not(self):
        """Whether the sender is verified is read from the conversation, and only the identity step reads it: a
        path-D row goes back through that step on every batch, also when its website still matches."""
        for now_site in (SITE, "https://somebody-else.example/"):
            pairs = [entry(1, basis="PASS_D", account=None), entry(2, request_id=2)]
            stale = hide_guard.needs_redecide(rows_for(pairs), [b for b, _ in pairs],
                                              claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids},
                                              source_reader=linked,
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
        self.assertTrue(hide_guard.reviewed(reviewed_claim(), LINKED))
        c = dict(reviewed_claim(), reason="bulk import")
        self.assertFalse(hide_guard.reviewed(c, LINKED))
        self.assertFalse(hide_guard.reviewed(dict(reviewed_claim(), links={"weblinks": [], "instagram": ""}), LINKED))
        self.assertFalse(hide_guard.reviewed(dict(reviewed_claim(), links=None), LINKED))

    def test_a_claim_link_counts_only_when_it_names_an_account_or_artist_the_profile_itself_names(self):
        """Ruling 2026-11-14: ownership evidence is an account or profile URL on a recognised platform that matches
        the profile, never just any page-shaped link. The guard reads the claim and the profile again at batch time,
        so a claim whose links were changed after the pass is weighed on what it carries now."""
        spotify_id = "4Z8W4fKeB5YxbusRsdQVPb"
        profile = dict(LINKED, identity=sources.ProfileIdentity(
            spotify=frozenset({spotify_id}), apple=frozenset({"1234567"}),
            social=frozenset({("instagram", "the.artist"), ("youtube", "theartist"), ("tiktok", "the.artist"),
                              ("twitter", "theartist")})))
        matching = [{"weblinks": [f"https://open.spotify.com/artist/{spotify_id}"]},
                    {"weblinks": ["https://music.apple.com/us/artist/the-artist/1234567"]},
                    {"weblinks": ["https://www.youtube.com/@TheArtist"]},
                    {"instagram": "instagram.com/the.artist/"},
                    {"weblinks": ["https://www.tiktok.com/@the.artist"]},
                    {"twitter": "https://x.com/theartist"}]
        not_matching = [{"weblinks": ["https://www.google.com/search?q=the+artist"]},     # a page, not an account
                        {"weblinks": ["https://www.youtube.com/shorts/abc123"]},          # somebody's video
                        {"weblinks": ["https://www.youtube.com/watch?v=abc123"]},
                        {"weblinks": ["https://www.artist-site.example/"]},               # a website is not a platform
                        {"weblinks": ["https://open.spotify.com/artist/0000000000000000000000"]},   # another artist
                        {"weblinks": ["https://music.apple.com/us/artist/other/7654321"]},
                        {"instagram": "https://instagram.com/somebody.else"},             # another account
                        {"instagram": "https://instagram.com/p/abc123"},                  # a post
                        {"weblinks": ["https://www.tiktok.com/@somebody.else"]},
                        {"twitter": "https://x.com/somebody_else"},
                        {"weblinks": ["abcd"]}]                                           # four characters: the old rule
        for links in matching:
            claim = dict(reviewed_claim(), links=links)
            self.assertTrue(hide_guard.reviewed(claim, profile), links)
            (d,) = judge([entry(1)], {pid(1): [claim]}, {pid(1): profile})
            self.assertEqual((d["outcome"], d["proof"], d["reason"]), ("admitted", "reviewed_claim", ""), links)
        for links in not_matching:
            claim = dict(reviewed_claim(), links=links)
            self.assertFalse(hide_guard.reviewed(claim, profile), links)
            (d,) = judge([entry(1)], {pid(1): [claim]}, {pid(1): profile})
            self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.UNVERIFIED), links)

    def test_a_claim_is_no_evidence_against_a_profile_that_names_no_account(self):
        """Nothing to compare with is not a match: the page is held, never admitted on the link alone."""
        bare = {"raws": ["spotify:9"], "created": T0 - 86400, "identity": sources.ProfileIdentity()}
        for src in (bare, {"raws": ["spotify:9"], "created": T0 - 86400}):
            self.assertFalse(hide_guard.reviewed(reviewed_claim(), src))
            (d,) = judge([entry(1)], {pid(1): [reviewed_claim()]}, {pid(1): src})
            self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.UNVERIFIED))
        self.assertFalse(hide_guard.reviewed(reviewed_claim(), None))
        (d,) = judge([entry(1)], {pid(1): [reviewed_claim()]}, {})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_FOUND))

    def test_a_profile_core_does_not_return_is_held_not_admitted(self):
        (d,) = judge([entry(1)], {pid(1): [instant_claim()]}, {})
        self.assertEqual((d["outcome"], d["reason"]), ("held", hide_guard.NOT_FOUND))

    def test_the_profile_is_read_for_every_claim_the_requester_holds_and_for_no_other(self):
        """A link is evidence only against the profile's own accounts, so a reviewed claim needs the profile too.
        A page the requester holds no claim on is refused without a read."""
        asked = []
        hide_guard.judge(*self._two(), [], NOW,
                         claim_reader=lambda ids: {pid(1): [reviewed_claim()], pid(2): [instant_claim()]},
                         source_reader=lambda ids: asked.append(list(ids)) or {pid(1): LINKED, pid(2): self.OWN})
        self.assertEqual(asked, [[pid(1), pid(2)]])
        asked.clear()
        got = hide_guard.judge(*self._two(), [], NOW,
                               claim_reader=lambda ids: {pid(1): [reviewed_claim(STRANGER)], pid(2): []},
                               source_reader=lambda ids: asked.append(list(ids)) or {})
        self.assertEqual((asked, [d["reason"] for d in got]), ([], [hide_guard.NOT_HOLDER] * 2))

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

    def page(self, n=1, holders=(OWNER,), checked=None, **kw):
        """A page as `sources.page_facts` hands it to the identity step: `checked` is what the page's own facts made
        of the claim's links, so a test that wants a claim to be evidence says so here (absent is never a pass)."""
        return identity.Page(pid(n), "profile", True, "An Artist", True, frozenset(holders), 10.0, 5,
                             checked_claim_user_ids=frozenset(holders) if checked is None else frozenset(checked),
                             **kw)

    def prove(self, facts, account=OWNER, claims=None, srcs=None):
        return hide_guard.prove(facts, account,
                                claim_reader=lambda ids: {i: (claims or {}).get(i, []) for i in ids},
                                source_reader=linked if srcs is None else (
                                    lambda ids: {i: srcs[i] for i in ids if i in srcs}))

    def verdict(self, page, account=OWNER, cls="privacy_erasure"):
        return identity.decide_page(page, identity.Requester(name="x", email="x@example.org", account_id=account),
                                    cls)

    def test_a_reviewed_claim_still_passes(self):
        (p,) = self.prove([self.page()], claims={pid(1): [reviewed_claim()]})
        pv = self.verdict(p)
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("PASS_A", OWNER, pid(1)))

    def test_an_instant_claim_on_the_accounts_own_profile_is_asked(self):
        """Ruling 2026-11-13: an instant claim is not a verified claimant, whatever the profile's sources look like.
        The guard does not strip it (it is the account's own new profile), and the identity step asks for the tie."""
        (p,) = self.prove([self.page(checked=())], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.OWN})
        self.assertEqual(p.claim_unproven, frozenset())
        pv = self.verdict(p)
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("ASK_IDENTITY", None, ""))
        self.assertIn("carries no verification links", pv.why)

    def test_an_unverified_claim_on_a_merged_profile_is_asked_and_told_why(self):
        (p,) = self.prove([self.page(checked=())], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.MERGED})
        self.assertEqual((p.claim_user_ids, p.claim_unproven), (frozenset(), frozenset({OWNER})))
        pv = self.verdict(p)
        self.assertEqual((pv.verdict, pv.account_id, pv.owner_page), ("ASK_IDENTITY", None, ""))
        self.assertIn("made without verification", pv.why)

    def test_a_takedown_on_an_unverified_claim_does_not_pass(self):
        (p,) = self.prove([self.page(checked=())], claims={pid(1): [instant_claim()]}, srcs={pid(1): self.MERGED})
        self.assertEqual(self.verdict(p, cls="dmca_takedown").verdict, "DMCA_REVIEW")

    def test_somebody_elses_claim_stays_on_the_page(self):
        (p,) = self.prove([self.page(holders=(OWNER, STRANGER), checked=(STRANGER,))],
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
        reviewed = identity.Page(pid(7), "track", name="A Song", popularity=1.0, item_read=True,
                                 artists=(self.page(),))
        (t,) = self.prove([reviewed], claims={pid(1): [reviewed_claim()]})
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

    def decide(self, claim, srcs, cls="privacy_erasure", checked=None, holders=frozenset({OWNER})):
        s = Store(":memory:")
        self.addCleanup(s.db.close)
        rid, _ = s.upsert({"keys": ["register:901"], "channel": "register", "class": cls,
                           "received_at": "2026-11-01T00:00:00Z", "requester_email": "owner@example.org",
                           "pages": [{"id": pid(1)}]})
        # what `sources.page_facts` hands the identity step: the claim's links are evidence only when they match the
        # page's own facts, which a fixture supplies by making a reviewed claim the checked one (`checked=()` says no)
        if checked is None:
            checked = ({pid(1): frozenset({OWNER})}
                       if OWNER in holders and hide_guard.reviewed(claim, LINKED) else {})
        facts = lambda pages, hid, cl, half=None, items=False: [                               # noqa: E731
            identity.Page(p["id"], "profile", True, "An Artist", True, frozenset(cl.get(p["id"], ())), 10.0, 5,
                          checked_claim_user_ids=frozenset(checked.get(p["id"], ())))
            for p in pages]
        with mock.patch.object(sources, "resolve_account", lambda *a, **k: (OWNER, "unique account email")), \
                mock.patch.object(sources, "account_names", lambda ids: {}), \
                mock.patch.object(sources, "processed_claims", lambda ids: {i: set(holders) for i in ids}), \
                mock.patch.object(sources, "claim_proofs", lambda ids: {i: [claim] for i in ids}), \
                mock.patch.object(sources, "profile_sources", lambda ids: {i: srcs or LINKED for i in ids}), \
                mock.patch.object(sources, "page_facts", facts):
            Run(s, log=lambda *_: None).decide_row(s.get(rid), set(), {}, lambda c: {})
        return s.get(rid)

    def test_a_pass_records_the_account_and_the_profile_it_rests_on(self):
        row = self.decide(reviewed_claim(), None)
        self.assertEqual(row["verdict_detail"][0] | {"why": ""},
                         {"id": pid(1), "verdict": "PASS_A", "why": "", "rules": identity.RULES_V,
                          "account": OWNER, "owner_page": pid(1)})
        self.assertEqual(hide_guard.needs_redecide(
            [row], [{"id": pid(1), "basis": "PASS_A", "request_id": row["id"]}],
            claim_reader=lambda ids: {i: [reviewed_claim()] for i in ids}, source_reader=linked),
                         [])

    def test_the_requesters_own_claim_that_proves_nothing_gets_the_ownership_ask_not_claim_the_page(self):
        """The five-requester case, through the real `hide_guard.prove` on an unverified `claim_proofs` answer: the
        proof takes the account off `claim_user_ids`, and the gates must still know the claim is the requester's."""
        unverified = {
            "processed the moment it was made": instant_claim(),
            "processed later, no link": {**reviewed_claim(), "links": ""},
            "processed later, a link to somebody else":
                {**reviewed_claim(), "links": {"instagram": "https://instagram.com/someone.else"}},
        }
        for name, claim in unverified.items():
            with self.subTest(name):
                row = self.decide(claim, None)
                self.assertEqual(row["verdict_detail"][0]["verdict"], "ASK_IDENTITY")
                self.assertEqual((row["gates"]["need"], row["gates"]["tie"]),
                                 (dsar.NEED_CLAIM_EVIDENCE, {"pass": False, "pages": {pid(1): dsar.CLAIM_UNCHECKED}}))
        # a reviewed claim is a tie and owes nothing; a page claimed by ANOTHER account is still "claim or authority"
        self.assertEqual(self.decide(reviewed_claim(), None)["gates"]["need"], dsar.NEED_NONE)
        other = self.decide(reviewed_claim(account=OWNER + 1), None, holders={OWNER + 1})
        self.assertEqual((other["verdict_detail"][0]["verdict"], other["gates"]["need"]),
                         ("ASK_IDENTITY", dsar.NEED_CLAIM_OR_AUTHORITY))

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
                         {"id": pid(1), "verdict": "PASS_D", "why": "", "rules": identity.RULES_V,
                          "owner_page": pid(1), "sender_host": HOST})
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
        # the claim is the requester's own, so what is owed is evidence for it (ruling 2026-11-13 21:56Z), not
        # "claim the page": this read `claim_or_authority` while the gates looked for the claim where the proof
        # had just taken it away
        self.assertEqual(row["gates"]["need"], dsar.NEED_CLAIM_EVIDENCE)
        self.assertEqual(hide_batch.plan([row], set(), set(), {}), [])

    def test_a_takedown_or_a_legal_threat_whose_live_proof_fails_is_decided_not_passed_and_never_planned(self):
        """Decide, then the guard: `page_facts` still calls the claim checked, the live claim no longer links the
        profile's account. Neither class records a pass, so no hide is planned and nothing waits behind a guard
        hold; the legal threat is asked for the tie, the takedown goes to its claim-first review."""
        changed = dict(reviewed_claim(), links={"weblinks": ["https://www.youtube.com/shorts/abc123"]})
        stale_checked = {pid(1): frozenset({OWNER})}
        want = {"dmca_takedown": "DMCA_REVIEW", "legal_threat": "ASK_IDENTITY", "privacy_erasure": "ASK_IDENTITY"}
        for cls, verdict in want.items():
            row = self.decide(changed, None, cls=cls, checked=stale_checked)
            (pv,) = row["verdict_detail"]
            self.assertEqual((row["identity_verdict"], pv["verdict"]), (verdict, verdict), cls)
            self.assertNotIn("owner_page", pv, cls)
            self.assertEqual(hide_batch.plan([row], set(), set(), {}), [], cls)
            self.assertEqual(hide_batch.plan([row], set(), set(), {}, include_legal=True), [], cls)
        self.assertEqual(self.decide(changed, None, cls="legal_threat", checked=stale_checked)["ask_kind"],
                         "ASK_IDENTITY")
        # the same rows with the proof intact pass and are planned
        for cls in want:
            row = self.decide(reviewed_claim(), None, cls=cls, checked=stale_checked)
            self.assertEqual(row["verdict_detail"][0]["verdict"], "PASS_A", cls)
            self.assertEqual([b["id"] for b in hide_batch.plan([row], set(), set(), {})], [pid(1)], cls)


class Readers(unittest.TestCase):
    def test_profile_sources_reads_the_live_profile(self):
        doc = {"rawProfiles": [{"id": "abc", "source": "muso", "name": "n", "url": None}],
               "createdAt": "2026-11-13T01:42:21.790000"}
        with mock.patch.object(sources, "profile_doc", lambda p: doc if p == pid(1) else None):
            got = sources.profile_sources([pid(1), pid(2), "not-an-id"])
        self.assertEqual(got, {pid(1): {"raws": ["muso:abc"], "created": 1794534141,
                                        "identity": sources.ProfileIdentity()}})

    def test_profile_sources_names_the_accounts_the_profile_itself_links(self):
        doc = {"rawProfiles": [{"id": "4Z8W4fKeB5YxbusRsdQVPb", "source": "spotify", "name": "n",
                                "url": "https://open.spotify.com/artist/4Z8W4fKeB5YxbusRsdQVPb"}],
               "createdAt": "2026-11-13T01:42:21.790000", "spotifyId": "4Z8W4fKeB5YxbusRsdQVPb",
               "links": {"instagram": "https://www.instagram.com/The.Artist/", "website": "https://artist-site.example"}}
        with mock.patch.object(sources, "profile_doc", lambda p: doc):
            named = sources.profile_sources([pid(1)])[pid(1)]["identity"]
        self.assertEqual((named.spotify, named.apple, named.social),
                         (frozenset({"4Z8W4fKeB5YxbusRsdQVPb"}), frozenset(), frozenset({("instagram", "the.artist")})))

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
        row = ["77", pid(1), str(OWNER), "", "created by user", '{"weblinks":["https://a.example"]}', str(T0), "false"]
        with mock.patch.object(sources, "trino", lambda sql: [row]):
            got = sources.claim_proofs([pid(1), pid(2)])
        self.assertEqual(got[pid(1)], [{"claim_id": "77", "account": OWNER, "reason": "created by user",
                                        "links": {"weblinks": ["https://a.example"]}, "created": T0,
                                        "processed_later": False}])
        self.assertEqual(got[pid(2)], [])
        for later, want in (("true", True), ("false", False), ("", False), ("NULL", False)):
            with mock.patch.object(sources, "trino", lambda sql: [row[:7] + [later]]):
                self.assertIs(sources.claim_proofs([pid(1)])[pid(1)][0]["processed_later"], want, later)
        for bad in (row[:6], row[:7], row[:2] + [""] + row[3:], row[:5] + ["{not json"] + row[6:]):
            with mock.patch.object(sources, "trino", lambda sql: [bad]), self.assertRaises(sources.Unknown):
                sources.claim_proofs([pid(1)])

    def test_a_claim_filed_on_an_extra_profile_counts_for_that_profile(self):
        row = ["78", pid(9), str(OWNER), f'["{pid(2)}"]', "", "", str(T0), "true"]
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
            ([entry(1, basis="PASS_B")], {pid(1): [reviewed_claim()]}, None, ()),
            ([entry(1, basis="LEGAL_HIDE_FIRST", account=None)], {}, None, ()),
            ([entry(1, recorded=False)], {pid(1): [reviewed_claim()]}, None, ()),
            ([entry(1, account=STRANGER)], {pid(1): [reviewed_claim(OWNER)]}, None, ()),
            ([entry(1)], {pid(1): [instant_claim()]}, {pid(1): {"raws": ["muso:1", "tidal:2"], "created": T0}}, ()),
            ([entry(1)], {pid(1): [instant_claim()]}, {}, ()),
            ([entry(1)], {pid(1): [reviewed_claim()]}, None, burst),
            ([entry(1)], {pid(1): [reviewed_claim()]}, None, register),
            ([entry(1, basis="PASS_D", account=None)], {}, None, ()),
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
                                source_reader=linked)

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
                mock.patch.object(sources, "profile_sources", linked), \
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
