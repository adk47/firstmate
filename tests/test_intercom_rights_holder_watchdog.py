"""Behavioral tests for scripts/intercom-rights-holder-watchdog.py.

The 2026-10-09 miss: Sony Music Labels emailed notices@muso.ai with a 24 h
deadline, it reached Intercom (conv 215476320739784), and nothing alerted. This
watchdog is deterministic (no LLM) and Intercom-sourced. These tests lock:

  - the sender-domain matcher anchors on `@` / `.` — `notsonymusic.com` must NOT
    match `sonymusic.*`;
  - keyword matching is word-anchored (no `illegally`-style stem hits) and the
    lists are DATA (file + env override), not code;
  - the Slack text escapes every interpolated field and names the ticket id or
    a bold NO TICKET FILED, and never claims "no ticket" when the lookup failed;
  - ORDERING (CTO ruling R6): confirmed Slack post first, then the Intercom tag,
    then the ledger. A failed post leaves the conversation untagged and the
    ledger unwritten, so it retries next tick.

Stdlib unittest + stubs only — no network.
"""
import importlib.util
import os
import pathlib
import tempfile
import unittest

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "intercom-rights-holder-watchdog.py"
)
_spec = importlib.util.spec_from_file_location("intercom_rights_holder_watchdog", _SCRIPT)
wd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wd)

DOMAINS = ["sonymusic.*", "sme.co.jp", "ascap.com", "# comment"]
KEYWORDS = ["urgent", "correction request", "DMCA", "GDPR", "at once", "至急", "訂正"]
SONY_ID = "215476320739784"


def make_conv(cid=SONY_ID, email="a.b@sonymusic.com", subject="Name correction", body="",
              tags=(), name="Sony Music", author_type="user", delivered_as="customer_initiated"):
    return {
        "id": cid,
        "created_at": 1000,
        "updated_at": 1000,
        "tags": {"tags": [{"name": n} for n in tags]},
        "source": {"subject": subject, "body": body,
                   "delivered_as": delivered_as,
                   "author": {"email": email, "name": name, "type": author_type}},
    }


class DomainMatch(unittest.TestCase):
    def test_exact_and_subdomain_and_wildcard_tld(self):
        for email in ("x@sonymusic.com", "x@sonymusic.co.jp", "x@mail.sonymusic.co.jp",
                      "X@SONYMUSIC.DE", "x@sme.co.jp", "x@ascap.com"):
            self.assertIsNotNone(wd.match_domain(email, DOMAINS), email)

    def test_notsonymusic_does_not_match(self):
        # The boundary test the card names: a substring match would page on this.
        for email in ("x@notsonymusic.com", "x@mysme.co.jp",
                      "x@notascap.com", "x@ascap.com.evil.io"):
            self.assertIsNone(wd.match_domain(email, DOMAINS), email)

    def test_comments_and_blanks_ignored_and_no_email(self):
        self.assertIsNone(wd.match_domain("", DOMAINS))
        self.assertIsNone(wd.match_domain("not-an-email", DOMAINS))
        self.assertIsNone(wd.match_domain("x@comment", DOMAINS))


class KeywordMatch(unittest.TestCase):
    def test_hits_case_insensitive_in_subject_or_body(self):
        self.assertEqual(wd.match_keyword("URGENT: fix", "", KEYWORDS), "urgent")
        self.assertEqual(wd.match_keyword("hi", "This is a Correction Request.", KEYWORDS),
                         "correction request")
        self.assertEqual(wd.match_keyword("", "削除ではなく訂正をお願いします", KEYWORDS), "訂正")

    def test_word_anchored(self):
        self.assertIsNone(wd.match_keyword("", "an insurgent band, gdprx", KEYWORDS))

    def test_regex_and_subject_only_entries(self):
        kws = [r"re:\blegal (notice|counsel|department)\b", "subject:takedown"]
        self.assertIsNotNone(wd.match_keyword("", "From our legal department", kws))
        self.assertIsNone(wd.match_keyword("", "my legal name is X", kws))
        self.assertIsNotNone(wd.match_keyword("Takedown please", "", kws))
        self.assertIsNone(wd.match_keyword("hello", "no takedown here", kws))


class Classify(unittest.TestCase):
    def test_sony_conversation_flagged_by_domain(self):
        m = wd.classify(make_conv(), DOMAINS, KEYWORDS)
        self.assertEqual((m["kind"], m["rule"]), ("domain", "sonymusic.*"))

    def test_keyword_only(self):
        m = wd.classify(make_conv(email="a@gmail.com", subject="urgent help"), DOMAINS, KEYWORDS)
        self.assertEqual((m["kind"], m["rule"]), ("keyword", "urgent"))

    def test_our_own_outbound_message_is_never_classified(self):
        # 215472970001347: our admin-initiated message said "within 24 hours" and paged.
        for author_type in ("admin", "bot", None):
            c = make_conv(email="a@gmail.com", subject="Your refund", author_type=author_type,
                          delivered_as="admin_initiated", body="we reply within 24 hours")
            self.assertIsNone(wd.classify(c, DOMAINS, KEYWORDS), author_type)
        c = make_conv(author_type="admin", delivered_as="admin_initiated")  # even a Sony address
        self.assertIsNone(wd.classify(c, DOMAINS, KEYWORDS))

    def test_lead_author_is_classified(self):
        self.assertIsNotNone(wd.classify(make_conv(author_type="lead"), DOMAINS, KEYWORDS))

    def test_nothing(self):
        self.assertIsNone(wd.classify(make_conv(email="a@gmail.com", subject="hello"),
                                      DOMAINS, KEYWORDS))

    def test_html_body_is_stripped_before_matching(self):
        c = make_conv(email="a@gmail.com", subject="x", body="<p>GD<b>PR</b> request</p>")
        self.assertEqual(wd.classify(c, DOMAINS, KEYWORDS)["rule"], "GDPR")


class DataFiles(unittest.TestCase):
    def test_shipped_lists_load_and_cover_card_domains(self):
        doms = wd.load_list(wd.DEFAULT_DOMAINS_FILE)
        for email in ("a@sonymusic.co.jp", "a@sme.co.jp", "a@umusic.com", "a@wmg.com",
                      "a@gema.de", "a@jasrac.or.jp"):
            self.assertIsNotNone(wd.match_domain(email, doms), email)
        self.assertIsNone(wd.match_domain("a@notsonymusic.com", doms))

    def test_env_override(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# mine\nfoo.example\n")
        try:
            os.environ["RIGHTS_HOLDER_DOMAINS_FILE"] = f.name
            self.assertEqual(wd.load_domains(), ["foo.example"])
        finally:
            del os.environ["RIGHTS_HOLDER_DOMAINS_FILE"]
            os.unlink(f.name)

    def test_shipped_urgent_is_subject_only(self):
        # MUS-7213 Option A: body boilerplate ("urgent refund") must not page.
        kws = wd.load_list(wd.DEFAULT_KEYWORDS_FILE)
        self.assertIsNone(wd.match_keyword("Refund", "this is urgent, please refund", kws))
        self.assertEqual(wd.match_keyword("URGENT: name fix", "", kws), "subject:urgent")

    def test_shipped_keywords_catch_card_terms(self):
        kws = wd.load_list(wd.DEFAULT_KEYWORDS_FILE)
        for text in ("DMCA notice", "cease and desist", "within 24 hours please", "至急", "削除"):
            self.assertIsNotNone(wd.match_keyword("", text, kws), text)


class Render(unittest.TestCase):
    def render(self, conv=None, ticket=("none", None)):
        conv = conv or make_conv()
        return wd.render_alert(conv, wd.classify(conv, DOMAINS, KEYWORDS), ticket,
                               ["U0AL36NADEY", "U038BM16T7W"], "dwjzhcge")

    def test_fields_and_mentions(self):
        t = self.render()
        for needle in ("<@U0AL36NADEY>", "<@U038BM16T7W>", "a.b@sonymusic.com", "Name correction",
                       "domain", "sonymusic.*",
                       f"https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/{SONY_ID}"):
            self.assertIn(needle, t)

    def test_default_mentions_page_jan_only(self):
        ids = [s for s in wd.DEFAULT_MENTION_IDS.split(",") if s.strip()]
        conv = make_conv()
        t = wd.render_alert(conv, wd.classify(conv, DOMAINS, KEYWORDS), ("none", None), ids, "dwjzhcge")
        self.assertIn("<@U038BM16T7W>", t)
        self.assertNotIn("<@U0AL36NADEY>", t)

    def test_no_ticket_is_bold(self):
        self.assertIn("*NO TICKET FILED*", self.render(ticket=("none", None)))

    def test_ticket_id_shown(self):
        t = self.render(ticket=("found", "869abc123"))
        self.assertIn("869abc123", t)
        self.assertNotIn("NO TICKET FILED", t)

    def test_unknown_lookup_never_says_no_ticket(self):
        t = self.render(ticket=("unknown", None))
        self.assertNotIn("NO TICKET FILED", t)
        self.assertIn("lookup failed", t)

    def test_untrusted_text_escaped(self):
        c = make_conv(subject="x > y & <@U1 <!channel", name="<!here>")
        t = self.render(conv=c)
        self.assertNotIn("<!here>", t)
        self.assertNotIn("<!channel", t)
        self.assertIn("x &gt; y &amp; &lt;@U1 &lt;!channel", t)


class Ordering(unittest.TestCase):
    """CTO ruling R6: post -> tag -> ledger; a failed post must not suppress a retry."""

    def setUp(self):
        self.calls = []
        self.ledger = {}

    def run_one(self, post_ok=True, tag_ok=True, conv=None):
        def post(text):
            self.calls.append("post")
            if not post_ok:
                raise RuntimeError("slack down")
        def tag(cid):
            self.calls.append("tag")
            if not tag_ok:
                raise RuntimeError("intercom down")
        def save(ledger):
            self.calls.append("ledger")
        return wd.alert_one(conv or make_conv(), wd.classify(make_conv(), DOMAINS, KEYWORDS),
                            ("none", None), post=post, tag=tag, ledger=self.ledger,
                            save_ledger=save, now=5000, mention_ids=["U1"], workspace_id="w")

    def test_order_post_tag_ledger(self):
        self.assertTrue(self.run_one())
        self.assertEqual(self.calls, ["post", "tag", "ledger"])
        self.assertEqual(self.ledger[SONY_ID], 5000)

    def test_failed_post_leaves_untagged_and_ledger_unwritten(self):
        self.assertFalse(self.run_one(post_ok=False))
        self.assertEqual(self.calls, ["post"])
        self.assertEqual(self.ledger, {})

    def test_failed_tag_still_writes_ledger_after_confirmed_post(self):
        # The page went out: never re-page it just because the tag failed.
        self.assertTrue(self.run_one(tag_ok=False))
        self.assertEqual(self.calls, ["post", "tag", "ledger"])

    def test_already_pinged_tag_or_ledger_skips(self):
        self.assertTrue(wd.already_handled(make_conv(tags=["priority-pinged"]), {}))
        self.assertTrue(wd.already_handled(make_conv(), {SONY_ID: 1}))
        self.assertFalse(wd.already_handled(make_conv(), {}))


class MaintenanceGuard(unittest.TestCase):
    """Live runs stand down during a planned maintenance window (drift gate:
    scripts/tests/maintenance-guard-drift.bats); --dry-run is read-only and never blocked."""

    def setUp(self):
        self.ran = []
        self._orig = (wd.run, wd._maintenance_active)
        wd.run = lambda args: self.ran.append(args) or 0
        os.environ["RIGHTS_HOLDER_SKIP_HOST_GUARD"] = "1"
        self.lock = tempfile.NamedTemporaryFile()
        os.environ["RIGHTS_HOLDER_LOCKFILE"] = self.lock.name

    def tearDown(self):
        wd.run, wd._maintenance_active = self._orig
        os.environ.pop("RIGHTS_HOLDER_SKIP_HOST_GUARD", None)
        os.environ.pop("RIGHTS_HOLDER_LOCKFILE", None)

    def _main(self, argv):
        import sys
        old = sys.argv
        sys.argv = ["x"] + argv
        try:
            return wd.main()
        finally:
            sys.argv = old

    def test_live_run_refuses_during_maintenance(self):
        wd._maintenance_active = lambda: True
        self.assertEqual(self._main([]), 0)
        self.assertEqual(self.ran, [])

    def test_live_run_proceeds_outside_maintenance(self):
        wd._maintenance_active = lambda: False
        self._main([])
        self.assertEqual(len(self.ran), 1)

    def test_dry_run_ignores_maintenance(self):
        wd._maintenance_active = lambda: True
        self._main(["--dry-run"])
        self.assertEqual(len(self.ran), 1)


class ShippedListsCatchDspTakedowns(unittest.TestCase):
    """The committed data files, through the real loaders + matchers (firstmate 961)."""

    def setUp(self):
        os.environ.pop("RIGHTS_HOLDER_DOMAINS_FILE", None)
        os.environ.pop("RIGHTS_HOLDER_KEYWORDS_FILE", None)
        self.domains, self.keywords = wd.load_domains(), wd.load_keywords()

    def test_dsp_distributor_and_label_senders_page(self):
        for addr in ("noreply@spotify.com", "legal@tidal.com", "copyright@distrokid.com",
                     "x@mail.tunecore.com", "ops@ninjatune.net", "copyright@dittomusic.com",
                     "x@repostnetwork.com"):
            self.assertIsNotNone(wd.match_domain(addr, self.domains), addr)

    def test_lookalikes_and_apple_do_not_page(self):
        for addr in ("x@notspotify.com", "x@spotify.com.evil.io", "no_reply@email.apple.com", "x@apple.com"):
            self.assertIsNone(wd.match_domain(addr, self.domains), addr)

    def test_takedown_wording_pages_but_a_credit_fix_does_not(self):
        self.assertIsNotNone(wd.match_keyword("Release update", "your track was taken down", self.keywords))
        self.assertIsNotNone(wd.match_keyword("Hi", "it was removed from Spotify in 2021", self.keywords))
        self.assertIsNone(wd.match_keyword("Hi", "please remove the wrong credit from my profile", self.keywords))


if __name__ == "__main__":
    unittest.main()
