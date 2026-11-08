"""Behavioral tests for scripts/legal-intake.py (notices@ / legal@ intake -> #cs_priority page).

2026-10-23 (MUS-18475 / MUS-18508, Jan Delmo via Buzz): one DMCA notice sent from two
addresses (david@demandage.com and demandage@gmail.com, 36 s apart, same four Muso profiles)
paged #cs_priority twice, the page showed only "(@demandage.com)" instead of the sender's
address, and it tagged Nick although Jan owns legal intake. These tests lock:

  - the page shows the full sender address (angle brackets escaped), like the rights-holder page;
  - the page tags Jan only;
  - the same notice from a second address is collapsed to a threaded reply (tagging Jan to confirm, MUS-20040) under
    the first page, ONLY when Muso ids link the two (no ids = two unrelated takedowns);
  - the ledger stores a hash of the subject, never the subject.

Hermetic: google client libraries are stubbed in sys.modules before the module loads, Gmail and
Slack are fakes, the ledger lives in a temp dir. Never skipped.
"""
import base64
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest

for _name in ("google", "google.oauth2", "google.oauth2.service_account",
              "googleapiclient", "googleapiclient.discovery"):
    sys.modules.setdefault(_name, types.ModuleType(_name))
sys.modules["google.oauth2"].service_account = sys.modules["google.oauth2.service_account"]
sys.modules["googleapiclient.discovery"].build = lambda *a, **k: None

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "legal-intake.py"
_spec = importlib.util.spec_from_file_location("legal_intake", _SCRIPT)
li = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(li)

# Real fixtures from the live ledger (legal@:1a16724626a9c50f / :1a16724ec8f18019).
PROFILES = ("7ea2bc87", "a9126433", "c0f0a65e", "e42f2131")
BODY = "Please remove: " + " ".join(f"https://muso.ai/profile/{p}-aaaa" for p in PROFILES)
SUBJECT = "DMCA Notice"
FIRST_MSG = 1761000000000


def thread(frm, subject=SUBJECT, body=BODY, internal=FIRST_MSG):
    data = base64.urlsafe_b64encode(body.encode()).decode()
    return {"messages": [{"internalDate": str(internal), "payload": {
        "mimeType": "text/plain", "body": {"data": data},
        "headers": [{"name": "From", "value": frm}, {"name": "Subject", "value": subject}]}}]}


class FakeGmail:
    def __init__(self, threads):
        self.data = threads

    def users(self):
        return self

    def messages(self):
        return self

    def threads(self):
        return self

    def labels(self):
        return self

    def list(self, **kw):
        self._r = {"messages": [{"threadId": t} for t in self.data]}
        return self

    def get(self, userId, id, format):
        self._r = self.data[id]
        return self

    def execute(self):
        return self._r


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = self.tmp.name
        self.saved = {k: getattr(li, k) for k in
                      ("HOME", "LEDGER", "REGISTER_IDS", "ACK_START", "PAGE_START", "BOXES",
                       "svc", "slack_token", "post_page")}
        li.HOME, li.LEDGER = home, f"{home}/ledger.json"
        li.REGISTER_IDS, li.ACK_START = f"{home}/register-ids.txt", f"{home}/ack-start.txt"
        li.PAGE_START = f"{home}/page-start.txt"
        pathlib.Path(li.PAGE_START).write_text("1")
        li.BOXES = [("kyran@muso.ai", "legal@muso.ai")]
        li.slack_token = lambda: "xoxb-test"
        self.posts = []

        def fake_post(token, text_, thread_ts=None):
            self.posts.append({"text": text_, "thread_ts": thread_ts})
            return f"1761000{len(self.posts):03d}.000100"
        li.post_page = fake_post
        self.addCleanup(lambda: [setattr(li, k, v) for k, v in self.saved.items()])

    def run_intake(self, threads, args=("--page",), code=0):
        li.svc = lambda subject, scope: FakeGmail(threads)
        argv, sys.argv = sys.argv, ["legal-intake.py", *args]
        try:
            with self.assertRaises(SystemExit) as cm:
                li.main()
        finally:
            sys.argv = argv
        self.assertEqual(cm.exception.code, code)
        return json.load(open(li.LEDGER))


class ANegatedDeletionIsNotADemand(unittest.TestCase):
    """QA #1847 Critical: the combined rule reads deletion WORDS, and a word can be negated.

    "Please send me a copy of my data. Do not delete my profile." matched the combined rule, classified
    privacy_erasure, and the pipeline could take the HIDE path against an explicit instruction not to delete
    anything. A regex cannot tell a demand from a refusal, so the match is checked for a negator.
    """

    def test_a_copy_request_that_REFUSES_deletion_is_an_access_request(self):
        self.assertEqual(li.classify("", "Please send me a copy of my data. Do not delete my profile."),
                         "privacy_access")

    def test_a_copy_request_that_REFUSES_deletion_in_other_words(self):
        for body in ("I do not want you to remove my name, just send me a copy of my personal data.",
                     "Never delete my account - I only want a copy of my personal data.",
                     "Send me my data without deleting my profile.",
                     "No deletion please, I need a copy of my data for my solicitor."):
            self.assertEqual(li.classify("", body), "privacy_access", body)

    def test_a_genuine_combined_request_is_still_an_erasure_request(self):
        # The deletion half must keep its ranking, or the customer's erasure obligation disappears - the
        # exact loss the combined rule exists to prevent.
        self.assertEqual(li.classify("", "Send me a copy of my personal data and delete my profile."),
                         "privacy_erasure")

    def test_ONE_affirmative_mention_survives_another_negated_one(self):
        self.assertEqual(li.classify("", "Do not delete my tracks, but please delete my profile."),
                         "privacy_erasure")
        self.assertTrue(li.affirmative_deletion("do not delete my tracks, but please delete my profile"))
        # ... and the same must survive the WITHDRAWAL rule, which looks at negators before deletion words: the
        # affirmative demand is the intent, so this is not a withdrawal.
        self.assertFalse(li.withdrawn_in_body("Do not delete my tracks, but please delete my profile."))

    def test_a_plain_deletion_request_is_unchanged(self):
        self.assertEqual(li.classify("", "Please delete my profile."), "privacy_erasure")
        self.assertEqual(li.classify("", "Send me a copy of my data under Article 15."), "privacy_access")

    def test_the_negator_only_reaches_the_phrase_it_is_next_to(self):
        # A negator in an EARLIER sentence must not disarm a later demand: "I have not heard back. Delete my
        # profile." is still a deletion request.
        self.assertTrue(li.affirmative_deletion(
            "i have not heard back from you at all about this, so please delete my profile now"))
        self.assertEqual(li.classify("", "I have not heard back. Please delete my profile."),
                         "privacy_erasure")


class AWithdrawalInTheCurrentMessageUnwinsTheInheritedSubject(unittest.TestCase):
    """QA #1847: a reply inherits the thread subject. `Re: GDPR Article 17 erasure request` supplied deletion
    vocabulary the customer was no longer asking for, so a withdrawal still classified as an erasure and the register
    reported it as already handled - invisible, and the pipeline would still hide the page."""

    SUBJECT = "Re: GDPR Article 17 erasure request"

    def test_a_body_that_refuses_deletion_is_not_an_erasure_whatever_the_subject_says(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        for body in ("Do not delete my profile. I withdraw my request.",
                     "Please do not delete anything, I have changed my mind.",
                     "I take back my request to remove my profile - do not delete it."):
            for classify in (li.classify, pipeline_intake.classify):
                self.assertNotEqual(classify(self.SUBJECT, body), "privacy_erasure",
                                    f"{body!r} via {classify.__module__}")

    def test_a_body_that_STILL_asks_for_deletion_wins_over_its_subject_too(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        body = "On reflection please delete my profile and all my data."
        for classify in (li.classify, pipeline_intake.classify):
            self.assertEqual(classify(self.SUBJECT, body), "privacy_erasure")

    def test_a_body_that_says_nothing_about_deletion_still_uses_the_subject(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        # Any update?" says nothing about deletion, so the inherited subject is all we have. It must not be
        # silently reclassified - that would turn a live erasure thread into `other`.
        body = "Any update on this?"
        for classify in (li.classify, pipeline_intake.classify):
            self.assertEqual(classify(self.SUBJECT, body), "privacy_erasure")

    def test_requests_access_is_the_dual_duty_test(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        self.assertTrue(li.requests_access("", "Send me a copy of my personal data and delete my profile."))
        self.assertTrue(pipeline_intake.requests_access("", "Send me a copy of my personal data and delete my "
                                                            "profile."))
        self.assertFalse(li.requests_access("", "Please delete my profile."))
        self.assertFalse(pipeline_intake.requests_access("", "Please delete my profile."))


class ABareWithdrawalVerbIsASignalButNeverAClass(unittest.TestCase):
    """QA #1847 r5. "I withdraw my request. Please stop processing it." names the request in the inherited
    subject, so the deletion vocabulary is not in the body and `withdrawn_in_body` cannot see it. The bare verb
    is still a signal -- but only a caller that can SEE the open row may act on it. `classify` must not, or
    every "I withdraw my complaint" becomes a privacy signal, and a bare withdrawal says nothing about which
    duty is being cancelled."""

    def test_the_bare_verb_is_a_signal_in_BOTH_copies(self):
        """`gdpr_pipeline.intake` is the copy the bridge imports, `legal-intake` is the source it is read from."""
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        for mod in (li, pipeline_intake):
            for body in ("I withdraw my request. Please stop processing it.",
                         "Please take back my request.",
                         "I have changed my mind."):
                self.assertTrue(mod.withdrawal_signal(body), (mod.__name__, body))

    def test_an_ordinary_reply_is_not_a_signal(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        for mod in (li, pipeline_intake):
            for body in ("Any update on this?", "Thanks, that is fine.", ""):
                self.assertFalse(mod.withdrawal_signal(body), (mod.__name__, body))

    def test_classify_does_not_act_on_the_bare_verb_alone(self):
        """The broad signal is not a class. "Please cancel my subscription" carries the verb and must stay
        with the rules; only an EXPLICIT withdrawal of a request reclassifies (QA #1847 r7)."""
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(mod.classify("Re: GDPR Article 17 erasure request",
                                              "Please cancel my subscription."), "privacy_erasure")

    def test_classify_DOES_act_on_an_explicit_withdrawal_of_a_request(self):
        """QA #1847 r7 Critical. With the request named, classify must not hand the hide path a fresh
        erasure: "I withdraw my erasure request." names no negation, so `withdrawn_in_body` missed it and a
        thread whose row was already closed minted a new erasure row."""
        for mod in self.copies():
            for body in ("I withdraw my erasure request.",
                         "I withdraw my request. Please stop processing it.",
                         "I take back my request to remove my profile.",
                         "Please retract my deletion request."):
                with self.subTest(copy=mod.__name__, body=body):
                    self.assertNotEqual(
                        mod.classify("Re: GDPR Article 17 erasure request", body), "privacy_erasure", body)

    def test_a_withdrawal_of_SOMETHING_ELSE_does_not_cancel_a_deletion_demand(self):
        """QA #1847 r8 Important. "I withdraw my complaint" withdraws a duty we do not track; the deletion
        after the semicolon is a live Art. 17 demand and must still file. The old rule short-circuited on the
        word "complaint", returned `other`, and the customer got no erasure row, no hide clock, no statutory
        deadline, and a human page that said nothing new had been filed."""
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(
                    mod.classify("", "I withdraw my complaint; please delete my profile."),
                    "privacy_erasure")
                # and the same thing under the thread's own subject, which is how it actually arrives
                self.assertEqual(
                    mod.classify("Re: GDPR Article 17 erasure request",
                                 "I withdraw my complaint; please delete my profile."),
                    "privacy_erasure")

    def test_only_a_demand_in_a_LATER_CLAUSE_survives_the_withdrawal(self):
        """The phrase being WITHDRAWN is not a new demand. "I take back my request to remove my profile"
        names the deletion as the object of the withdrawal, in the same clause, so it still cancels."""
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                for body in ("I withdraw my erasure request.",
                             "I withdraw my request. Please stop processing it.",
                             "I take back my request to remove my profile.",
                             "Please retract my deletion request.",
                             "I take back my request to remove my profile - do not delete it."):
                    self.assertTrue(mod.withdrawal_cancels(body), body)
                    self.assertEqual(mod.classify("", body), "other", body)
                for body in ("I withdraw my complaint; please delete my profile.",
                             "I withdraw my complaint, please delete my profile.",
                             "I cancel my complaint - please delete my profile.",
                             # QA #1847 r9 Important: a coordinated imperative joined by "and" is a
                             # demand in its own clause, not the object of the withdrawal.
                             "I withdraw my complaint and please delete my profile.",
                             "I withdraw my erasure request and delete my profile."):
                    self.assertFalse(mod.withdrawal_cancels(body), body)

    def test_a_coordinated_imperative_after_AND_still_files(self):
        """QA #1847 r9 Important. `classify("Re: complaint", "I withdraw my complaint and please delete my
        profile.")` returned `other` on r9 while the comma and semicolon versions filed -- the conjunction
        was the only difference, so the erasure row, the hide clock and the statutory deadline were dropped."""
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(
                    mod.classify("Re: complaint", "I withdraw my complaint and please delete my profile."),
                    "privacy_erasure")
                # ... and a negated deletion after the "and" still cancels.
                self.assertTrue(mod.withdrawal_cancels(
                    "I withdraw my erasure request and do not delete anything."))

    def test_a_withdrawal_that_is_really_a_deletion_demand_stays_an_erasure(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(
                    mod.classify("Re: Article 17 erasure request",
                                 "I want to cancel my subscription and delete my profile."),
                    "privacy_erasure")

    @staticmethod
    def copies():
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        return (li, pipeline_intake)


class TheTwoClassifiersAgree(unittest.TestCase):
    """The pipeline reads legal-intake.py's RULES as LITERALS, so it carries its own `classify`.

    Two copies drifting is how the negation half of the rule could land in one and not the other: the vocabulary
    would agree while the pipeline still took the hide path for a customer who said "do not delete my profile".
    Pinned on a corpus, not by inspection.
    """

    CORPUS = (
        "",
        "Please send me a copy of my data. Do not delete my profile.",
        "I do not want you to remove my name, just send me a copy of my personal data.",
        "Never delete my account - I only want a copy of my personal data.",
        "Send me my data without deleting my profile.",
        "No deletion please, I need a copy of my data for my solicitor.",
        "Send me a copy of my personal data and delete my profile.",
        "Do not delete my tracks, but please delete my profile.",
        "Please delete my profile.",
        "Send me a copy of my data under Article 15.",
        "I have not heard back. Please delete my profile.",
        "Remove my profile and my tracks, this is a GDPR erasure request.",
        "Do not delete my profile.",
        "Do not delete my profile, but send me a copy of my personal data.",
        "This is a GDPR request about my personal data.",
        "DMCA takedown for this page",
        "unsubscribe",
    )

    def test_legal_intake_and_the_pipeline_classify_identically(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402  (import order: needs the stub)
        for body in self.CORPUS:
            self.assertEqual(li.classify("", body), pipeline_intake.classify("", body), body)

    def test_a_STANDALONE_refusal_is_not_an_erasure_request_in_EITHER_copy(self):
        # QA #1847 r3: the negation guard covered only the combined rule, so "Do not delete my profile" matched
        # the GENERIC erasure rule and could still take the hide path. Every erasure path is guarded now.
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        for body in ("Do not delete my profile.",
                     "Please do not delete my profile or my tracks.",
                     "Never delete my account."):
            for classify in (li.classify, pipeline_intake.classify):
                self.assertEqual(classify("", body), "other", f"{body!r} via {classify.__module__}")

    def test_a_refusal_that_also_asks_for_a_copy_is_an_access_request(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        body = "Do not delete my profile, but send me a copy of my personal data."
        self.assertEqual(li.classify("", body), "privacy_access")
        self.assertEqual(pipeline_intake.classify("", body), "privacy_access")

    def test_a_message_with_NO_deletion_phrase_is_untouched(self):
        # The generic rule also fires on "gdpr"/"personal data" alone. Those must keep classifying erasure, or a
        # plain erasure request would fall to `other` and page a human for nothing.
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        for body in ("This is a GDPR request about my personal data.",
                     "I am exercising my right to be forgotten."):
            self.assertEqual(li.classify("", body), "privacy_erasure", body)
            self.assertEqual(pipeline_intake.classify("", body), "privacy_erasure", body)

    def test_neither_copy_takes_the_hide_path_on_a_NEGATED_deletion(self):
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        body = "Please send me a copy of my data. Do not delete my profile."
        self.assertEqual(li.classify("", body), "privacy_access")
        self.assertEqual(pipeline_intake.classify("", body), "privacy_access")


class Page(unittest.TestCase):
    def render(self, frm):
        h0 = {"from": frm, "subject": SUBJECT}
        return li.page_text("legal@muso.ai", "dmca_takedown", h0, ["profile:7ea2bc87"], {"thread": "t1"})

    def test_page_shows_full_sender_address(self):
        t = self.render("David E Sarabia <david@demandage.com>")
        self.assertIn("David E Sarabia &lt;david@demandage.com&gt;", t)
        self.assertNotIn("(@demandage.com)", t)

    def test_page_shows_bare_address_when_no_display_name(self):
        self.assertIn("From: demandage@gmail.com\n", self.render("demandage@gmail.com"))

    def test_long_display_name_never_pushes_address_off_the_page(self):
        t = self.render("X" * 300 + " <david@demandage.com>")
        self.assertIn("&lt;david@demandage.com&gt;", t)

    def test_page_mentions_jan_only(self):
        t = self.render("David E Sarabia <david@demandage.com>")
        self.assertIn("<@U038BM16T7W>", t)
        self.assertNotIn("<@U0AL36NADEY>", t)


class NoticeKey(unittest.TestCase):
    def test_subject_normalisation(self):
        ids = ["profile:7ea2bc87"]
        base = li.notice_key("dmca_takedown", "DMCA Notice", ids)
        self.assertEqual(base, li.notice_key("dmca_takedown", "Re: Fwd: DMCA Notice", ids))
        self.assertEqual(base, li.notice_key("dmca_takedown", "  RE: re:  dmca   notice ", ids))
        self.assertNotEqual(base, li.notice_key("privacy_erasure", "DMCA Notice", ids))
        self.assertNotEqual(base, li.notice_key("dmca_takedown", "DMCA Notice", ["profile:00000000"]))


class Collapse(Harness):
    def two_threads(self, body2=BODY):
        return {"a1": thread("David E Sarabia <david@demandage.com>"),
                "b2": thread("demandage@gmail.com", body=body2, internal=FIRST_MSG + 36000)}

    def test_collapse_same_notice_two_addresses(self):
        led = self.run_intake(self.two_threads())
        self.assertEqual(len(self.posts), 2)  # one real page + one threaded note
        first_ts = led["legal@muso.ai:a1"]["paged"]
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)
        note = self.posts[1]
        self.assertEqual(note["thread_ts"], first_ts)
        self.assertIn("<@U038BM16T7W>", note["text"])  # MUS-20040: the note is actionable, Jan is told
        self.assertNotIn("<@U0AL36NADEY>", note["text"])
        self.assertIn("demandage@gmail.com", note["text"])
        self.assertIn("david@demandage.com", note["text"])
        self.assertIn("b2", note["text"])  # Gmail thread id
        self.assertIn("a1", note["text"])
        self.assertIsNone(self.posts[0]["thread_ts"])

    def test_collapse_note_is_actionable_for_a_different_rights_holder(self):
        """MUS-20040 / hydra#1361 bot round 2: same class + subject + ids can still be two rights
        holders. The collapse stays (no second top-level page) but the threaded note must tell Jan
        to confirm, name both senders and both Gmail threads, and never say nothing is needed
        ("or keep the second page actionable when identity is uncertain")."""
        led = self.run_intake({
            "a1": thread("Rights Holder A <claims@labela.com>"),
            "b2": thread("Other Owner <legal@labelb.org>", body=BODY + "\nWe are a different company.",
                         internal=FIRST_MSG + 36000)})
        first_ts = led["legal@muso.ai:a1"]["paged"]
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)
        notes = [p for p in self.posts if p["thread_ts"]]
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["thread_ts"], first_ts)
        text = notes[0]["text"]
        self.assertIn("<@U038BM16T7W>", text)
        self.assertNotIn("<@U0AL36NADEY>", text)
        self.assertIn("claims@labela.com", text)
        self.assertIn("legal@labelb.org", text)
        self.assertIn("a1", text)
        self.assertIn("b2", text)
        self.assertNotIn("no new action needed", text)

    def test_no_collapse_when_ids_empty(self):
        no_ids = "Please take down my song"
        led = self.run_intake({"a1": thread("a@x.com", body=no_ids),
                               "b2": thread("b@y.com", body=no_ids, internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.posts), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
        self.assertTrue(all(p["thread_ts"] is None for p in self.posts))

    def _post_failing_threads(self, top_level_ok=True):
        """Slack fake: every threaded post raises; top-level posts succeed only if top_level_ok."""
        def post(token, text_, thread_ts=None):
            self.posts.append({"text": text_, "thread_ts": thread_ts})
            if thread_ts or not top_level_ok:
                raise RuntimeError("slack down")
            return f"1761000{len(self.posts):03d}.000100"
        li.post_page = post

    def test_failed_threaded_note_falls_back_to_a_full_page(self):
        """MUS-20075 / hydra#1361 bot round 3: a failed note must never be ledgered as paged
        (the note is the only actionable signal for a possibly-different rights holder), so the
        thread gets a full top-level page instead of going permanently silent."""
        self._post_failing_threads()
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            led = self.run_intake(self.two_threads())
        paged = led["legal@muso.ai:b2"]["paged"]
        self.assertFalse(str(paged).startswith("dup-of"))
        self.assertRegex(paged, r"^\d+\.\d+$")
        top = [p for p in self.posts if p["thread_ts"] is None]
        self.assertEqual(len(top), 2)  # first page + the fallback page for b2
        self.assertIn("demandage@gmail.com", top[1]["text"])
        self.assertIn("<@U038BM16T7W>", top[1]["text"])
        self.assertIn("PAGE NOTE FAILED", out.getvalue())

    def test_all_posts_failing_leaves_paged_unset_and_retries_next_run(self):
        """Nothing confirmed => exit 2, no `paged`; the next healthy run posts the note."""
        self.run_intake({"a1": thread("David E Sarabia <david@demandage.com>")})
        first_ts = json.load(open(li.LEDGER))["legal@muso.ai:a1"]["paged"]
        self._post_failing_threads(top_level_ok=False)
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            led = self.run_intake(self.two_threads(), code=2)
        self.assertNotIn("paged", led["legal@muso.ai:b2"])
        li.post_page = lambda token, text_, thread_ts=None: (
            self.posts.append({"text": text_, "thread_ts": thread_ts}) or "1761999999.000100")
        self.posts.clear()
        led = self.run_intake(self.two_threads())
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)
        self.assertEqual([p["thread_ts"] for p in self.posts], [first_ts])

    def test_run_without_page_flag_does_not_poison_the_ledger(self):
        """The dup-of marker may only be written from a confirmed note: a run with no --page
        used to write it anyway, so every later paging run skipped the note."""
        self.run_intake({"a1": thread("David E Sarabia <david@demandage.com>")})
        first_ts = json.load(open(li.LEDGER))["legal@muso.ai:a1"]["paged"]
        led = self.run_intake(self.two_threads(), args=())
        self.assertNotIn("paged", led["legal@muso.ai:b2"])
        led = self.run_intake(self.two_threads())
        self.assertEqual(led["legal@muso.ai:b2"]["paged"], "dup-of:" + first_ts)

    def test_ledger_row_carries_no_subject_text(self):
        led = self.run_intake(self.two_threads())
        for row in led.values():
            self.assertRegex(row["notice_key"], r"^[0-9a-f]{16}$")
            self.assertNotIn("DMCA Notice", json.dumps(row))


class SameSenderDistinctClaims(Harness):
    """hydra#1361 bot round 4 / MUS-20138: the same-sender req_key arm let a second, DIFFERENT claim
    from one sender inherit the first claim's acked/paged markers (no ack, no page). Two rows that
    BOTH carry ids with different notice_key are distinct claims. MUS-20285: identity is strict
    notice_key equality, so id-less notices with different subjects and legacy rows (no notice_key)
    never suppress a new claim; the same notice (same key, ids or not) still collapses."""

    def setUp(self):
        super().setUp()
        pathlib.Path(li.ACK_START).write_text("1")
        self.acks = []

        def fake_ack(to, subj, body):
            self.acks.append(to)
            return f"ack{len(self.acks)}"
        saved_ack = li.send_ack
        li.send_ack = fake_ack
        self.addCleanup(lambda: setattr(li, "send_ack", saved_ack))

    def body(self, *profiles):
        return "Please remove: " + " ".join(f"https://muso.ai/profile/{p}-aaaa" for p in profiles)

    def go(self, threads):
        return self.run_intake(threads, args=("--page", "--ack"))

    def test_distinct_same_sender_claims_each_get_ack_and_page(self):
        day = 86400000
        led = self.go({
            "a1": thread("Rights Holder <claims@labela.com>", subject="DMCA Notice song one",
                         body=self.body("11111111")),
            "b2": thread("Rights Holder <claims@labela.com>", subject="DMCA Notice song two",
                         body=self.body("22222222"), internal=FIRST_MSG + day)})
        self.assertEqual(len(self.acks), 2)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
            self.assertFalse(str(led[k]["ack_ref"]).startswith("dup-of"))

    def test_same_sender_two_mailboxes_same_notice_still_one_ack_one_page(self):
        led = self.go({"a1": thread("claims@labela.com"),
                       "b2": thread("claims@labela.com", internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len(self.posts), 1)
        self.assertTrue(led["legal@muso.ai:b2"]["ack_ref"].startswith("dup-of:"))
        self.assertTrue(led["legal@muso.ai:b2"]["paged"].startswith("dup-of:"))

    def test_same_sender_no_ids_same_subject_still_one_ack_one_page(self):
        led = self.go({
            "a1": thread("claims@labela.com", subject="DMCA Notice", body="Please take down my song"),
            "b2": thread("claims@labela.com", subject="Re: DMCA Notice", body="Please take down my song",
                         internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len(self.posts), 1)
        self.assertTrue(led["legal@muso.ai:b2"]["ack_ref"].startswith("dup-of:"))
        self.assertTrue(led["legal@muso.ai:b2"]["paged"].startswith("dup-of:"))

    def test_same_sender_no_ids_same_subject_different_bodies_each_get_ack_and_page(self):
        """hydra#1361 bot NO-GO @1936d320d: two different ID-less claims under one generic subject
        must not collapse; the body fingerprint in notice_key keeps them apart."""
        led = self.go({
            "a1": thread("claims@labela.com", subject="DMCA Notice", body="Please take down my song Alpha"),
            "b2": thread("claims@labela.com", subject="DMCA Notice", body="Please take down my track Beta",
                         internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 2)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
            self.assertFalse(str(led[k]["ack_ref"]).startswith("dup-of"))

    def test_notice_key_unchanged_when_ids_present(self):
        """With linked ids the key is the pre-fingerprint format, so the cross-sender arm and
        existing ledger rows keep matching whatever the body says."""
        import hashlib
        old = hashlib.sha256("dmca_takedown|dmca notice|profile:abc".encode()).hexdigest()[:16]
        a = li.notice_key("dmca_takedown", "DMCA Notice", ["profile:abc"], "x")
        self.assertEqual(a, li.notice_key("dmca_takedown", "DMCA Notice", ["profile:abc"], "y"))
        self.assertEqual(a, old)

    def test_same_sender_no_ids_different_subjects_each_get_ack_and_page(self):
        led = self.go({
            "a1": thread("claims@labela.com", subject="DMCA Notice one", body="Please take down my song"),
            "b2": thread("claims@labela.com", subject="DMCA Notice two", body="Please take down my track",
                         internal=FIRST_MSG + 36000)})
        self.assertEqual(len(self.acks), 2)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 2)
        for k in ("legal@muso.ai:a1", "legal@muso.ai:b2"):
            self.assertFalse(str(led[k]["paged"]).startswith("dup-of"))
            self.assertFalse(str(led[k]["ack_ref"]).startswith("dup-of"))

    def test_legacy_sibling_without_notice_key_does_not_suppress_a_new_claim(self):
        """MUS-20285: a row written before notice_key existed cannot prove identity, so the new
        thread is acked and paged rather than silently collapsed."""
        first = self.go({"a1": thread("claims@labela.com")})
        row = first["legal@muso.ai:a1"]
        del row["notice_key"]
        json.dump(first, open(li.LEDGER, "w"))
        self.acks.clear(); self.posts.clear()
        # List only b2: main() re-stamps notice_key on every row it visits, so a1 must stay
        # unlisted (outside the run window, inside the 3-day dedupe window) to remain legacy.
        led = self.go({"b2": thread("claims@labela.com", subject="Re: DMCA Notice", internal=FIRST_MSG + 36000)})
        self.assertNotIn("notice_key", led["legal@muso.ai:a1"])
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len([p for p in self.posts if p["thread_ts"] is None]), 1)
        self.assertFalse(led["legal@muso.ai:b2"]["ack_ref"].startswith("dup-of:"))
        self.assertFalse(str(led["legal@muso.ai:b2"]["paged"]).startswith("dup-of:"))

    def test_ack_goes_to_the_parsed_from_address_not_one_in_the_display_name(self):
        """hydra#1361 bot NO-GO @85b2ce9d9: the ack recipient came from a regex over the raw From
        header, so an address inside a quoted display name won over the real sender."""
        self.go({"a1": thread('"victim@example.org" <actual@lawfirm.com>')})
        self.assertEqual(self.acks, ["actual@lawfirm.com"])

    def test_no_ack_check_reads_the_parsed_address_not_the_display_name(self):
        self.go({"a1": thread('"press@muso.ai" <actual@lawfirm.com>')})
        self.assertEqual(self.acks, ["actual@lawfirm.com"])

    def test_automated_sender_by_parsed_address_still_gets_no_ack(self):
        self.go({"a1": thread("Label Notices <no-reply@labela.com>")})
        self.assertEqual(self.acks, [])

    def three_siblings(self):
        return {"a1": thread("claims@labela.com"),
                "b2": thread("claims@labela.com", internal=FIRST_MSG + 36000),
                "c3": thread("claims@labela.com", internal=FIRST_MSG + 72000)}

    def test_label_failure_after_ack_and_page_does_not_resend(self):
        """hydra#1361 bot NO-GO @25fd96a: the label call ran after the ack and the page but before the
        row was ledgered, so a label failure lost the confirmed markers and every 15-min run re-sent both."""
        class LabelFailsGmail(FakeGmail):
            def create(self, **kw):
                self._r = {"id": "L1"}
                return self

            def modify(self, **kw):
                raise RuntimeError("label boom")
        threads = {"a1": thread("claims@labela.com")}
        li.svc = lambda subject, scope: LabelFailsGmail(threads)
        args = ("--page", "--ack", "--label")

        def run():
            argv, sys.argv = sys.argv, ["legal-intake.py", *args]
            try:
                with self.assertRaises(SystemExit) as cm:
                    import contextlib, io
                    with contextlib.redirect_stdout(io.StringIO()):
                        li.main()
            finally:
                sys.argv = argv
            self.assertEqual(cm.exception.code, 2)
            return json.load(open(li.LEDGER))["legal@muso.ai:a1"]
        row = run()
        self.assertTrue(row["acked"])
        self.assertRegex(row["paged"], r"^\d+\.\d+$")
        self.assertEqual((len(self.acks), len(self.posts)), (1, 1))
        run()
        self.assertEqual((len(self.acks), len(self.posts)), (1, 1))

    def test_sibling_pick_uses_the_confirmed_ack_not_the_first_match(self):
        """hydra#1361 bot NO-GO @25fd96a: the first matching sibling was the only one consulted, so
        a1's failed ack hid b2's confirmed one and c3 sent a second ack."""
        results = iter([""])
        ok = []

        def flaky_ack(to, subj, body):
            mid = next(results, None)
            if mid is None:
                mid = f"ack{len(ok) + 1}"
                ok.append(mid)
            return mid
        li.send_ack = flaky_ack
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            led = self.run_intake(self.three_siblings(), args=("--page", "--ack"), code=2)
        self.assertEqual(ok, ["ack1"])
        self.assertEqual(led["legal@muso.ai:c3"]["ack_ref"], "dup-of:" + led["legal@muso.ai:b2"]["ack_ref"])

    def test_sibling_pick_uses_the_confirmed_page_not_the_first_match(self):
        """hydra#1361 bot NO-GO @25fd96a: a1's failed page hid b2's confirmed one, so c3 missed it
        and posted a 'different sender' note for the same sender."""
        calls = []

        def flaky_page(token, text_, thread_ts=None):
            calls.append(thread_ts)
            if len(calls) == 1:
                return ""
            self.posts.append({"text": text_, "thread_ts": thread_ts})
            return f"1761000{len(self.posts):03d}.000100"
        li.post_page = flaky_page
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            led = self.run_intake(self.three_siblings(), args=("--page", "--ack"), code=2)
        self.assertEqual([p["thread_ts"] for p in self.posts], [None])
        self.assertEqual(led["legal@muso.ai:c3"]["paged"], "dup-of:" + led["legal@muso.ai:b2"]["paged"])


class SendAckExecution(unittest.TestCase):
    """MUS-18508 QA-bot Critical: send_ack built a bash -c string, so a crafted inbound
    subject/sender (`$(...)`, backticks, quotes) could run host commands. It must pass an
    argument vector: no shell string, attacker text only ever as separate argv elements."""

    def _run(self, to, subject):
        import subprocess
        from unittest import mock
        seen = {}

        def fake_run(argv, **kw):
            seen["argv"], seen["kw"] = argv, kw
            return types.SimpleNamespace(stdout='{"messageId": "m1"}')

        with tempfile.TemporaryDirectory() as home, \
                mock.patch.object(li, "HOME", home), \
                mock.patch.object(subprocess, "run", fake_run):
            self.assertEqual(li.send_ack(to, subject, "body"), "m1")
        return seen

    def test_hostile_subject_and_address_are_argv_elements_not_shell_text(self):
        subject = 'Re: $(touch /tmp/pwn) `id` "; rm -rf / #'
        to = 'x@y.com" ; $(id) #'
        seen = self._run(to, subject)
        argv = seen["argv"]
        self.assertIn(subject, argv)
        self.assertIn(to, argv)
        # the only shell text is a fixed constant: no attacker byte may appear in it
        shell_text = [a for a in argv if a.startswith("set -a")]
        self.assertEqual(len(shell_text), 1)
        self.assertNotIn("touch", shell_text[0])
        self.assertNotIn("$(id)", shell_text[0])
        self.assertFalse(seen["kw"].get("shell"))


if __name__ == "__main__":
    unittest.main()




class AnInheritedSubjectDoesNotCreateAnAccessDuty(unittest.TestCase):
    """QA #1847 r6: on a REPLY the subject belongs to the old message.

    "Re: Article 15 access request" answered with "Please delete my profile." is a deletion. Counting the
    inherited subject filed a privacy_access row and a deadline nobody asked for, and could queue an
    unwanted access response off a closed row.
    """

    SUBJECT = "Re: Article 15 access request"

    @staticmethod
    def copies():
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        return (li, pipeline_intake)

    def test_a_deletion_only_reply_does_not_ask_for_a_copy(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertFalse(mod.requests_access(self.SUBJECT, "Please delete my profile."))

    def test_a_genuine_combined_reply_still_owes_both(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertTrue(mod.requests_access(
                    self.SUBJECT, "Please delete my profile and send me a copy of my personal data."))

    def test_an_access_only_reply_still_owes_the_copy(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertTrue(mod.requests_access(self.SUBJECT, "Here is what you asked for; please proceed."))

    def test_a_body_silent_about_both_duties_falls_back_to_the_subject(self):
        # A first message, or a bare "any update?" on a thread that really is an access request.
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertTrue(mod.requests_access(self.SUBJECT, "Any update on this?"))
                self.assertFalse(mod.requests_access("Re: my account", "Any update on this?"))

    def test_a_deletion_in_the_body_wins_over_the_inherited_access_subject(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertFalse(mod.requests_access(self.SUBJECT, "I want my profile removed."))
                self.assertFalse(mod.requests_access(self.SUBJECT, "Exercise my right to be forgotten."))

    def test_the_two_copies_agree(self):
        cases = [
            (self.SUBJECT, "Please delete my profile."),
            (self.SUBJECT, "Please delete my profile and send me a copy of my personal data."),
            (self.SUBJECT, "Any update on this?"),
            ("Re: my account", "Any update on this?"),
            ("Re: GDPR Article 17 erasure request", "I am exercising my right to be forgotten."),
            ("Re: GDPR Article 17 erasure request", "I withdraw my request."),
        ]
        for subject, body in cases:
            with self.subTest(body=body):
                self.assertEqual(li.requests_access(subject, body),
                                 self.copies()[1].requests_access(subject, body))


class AnInheritedErasureSubjectDoesNotStartAnErasure(unittest.TestCase):
    """QA #1847 r6 Critical: the mirror of the access case.

    "Re: Article 17 erasure request" answered with "Please send me a copy of my data." is an access-only
    reply. The inherited subject supplied the affirmative deletion phrase, so the whole message read as
    erasure and the hide path could run against a customer who asked, in this message, only for a copy.
    """

    SUBJECT = "Re: Article 17 erasure request"
    ACCESS_BODY = "Please send me a copy of my data."

    @staticmethod
    def copies():
        from gdpr_pipeline import intake as pipeline_intake    # noqa: E402
        return (li, pipeline_intake)

    def test_an_access_only_reply_is_an_ACCESS_request_not_an_erasure(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(mod.classify(self.SUBJECT, self.ACCESS_BODY), "privacy_access")

    def test_the_same_body_under_a_FRESH_erasure_subject_is_still_an_erasure(self):
        """The subject is the current message's own words, so it counts: a first contact that says
        "Article 17 erasure request" in the subject and asks for a copy in the body is mixed."""
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(mod.classify("Article 17 erasure request", self.ACCESS_BODY),
                                 "privacy_erasure")

    def test_a_deletion_in_the_reply_body_still_wins_over_the_subject(self):
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(mod.classify(self.SUBJECT, "Please delete my profile."), "privacy_erasure")
                self.assertEqual(mod.classify(self.SUBJECT, "Delete my profile and send me a copy of my data."),
                                 "privacy_erasure")

    def test_a_reply_silent_about_access_still_inherits_the_erasure(self):
        """A bare "Any update?" on an erasure thread is still an erasure thread; the body says nothing, so
        the subject is the only evidence there is."""
        for mod in self.copies():
            with self.subTest(copy=mod.__name__):
                self.assertEqual(mod.classify(self.SUBJECT, "Any update?"), "privacy_erasure")

    def test_reply_prefixes_are_recognised_in_every_form(self):
        for mod in self.copies():
            for prefix in ("Re:", "RE:", "re:", "Re :", "Fwd:", "FW:", "Re: Re:", "AW:", "SV:"):
                with self.subTest(copy=mod.__name__, prefix=prefix):
                    self.assertTrue(mod.inherited_subject(f"{prefix} Article 17 erasure request"))
            for fresh in ("Article 17 erasure request", "GDPR erasure", ""):
                with self.subTest(copy=mod.__name__, fresh=fresh):
                    self.assertFalse(mod.inherited_subject(fresh))

    def test_the_two_copies_agree(self):
        cases = [
            (self.SUBJECT, self.ACCESS_BODY),
            ("Article 17 erasure request", self.ACCESS_BODY),
            (self.SUBJECT, "Please delete my profile."),
            (self.SUBJECT, "Delete my profile and send me a copy of my data."),
            (self.SUBJECT, "Any update?"),
            ("Re: Article 15 access request", "Please delete my profile."),
        ]
        for subject, body in cases:
            with self.subTest(body=body):
                self.assertEqual(li.classify(subject, body),
                                 self.copies()[1].classify(subject, body))
