"""Unit tests for the wb_fix_1 copy renderer and the send-time guard chain.

The interesting assertions are the refusals. A renderer that can produce a body without the
read-back's numbers is a machine for telling a paying customer something that is not true, and
that is precisely the complaint this campaign answers (report 0.2, ruling R2).
"""

import copy
import json
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from churn import guards, model, render  # noqa: E402

POLICY = json.loads((ROOT / "policies" / "winback-fix.json").read_text())


class Ticket:
    def __init__(self, cause="credits_not_approved", evidence=None, plan="muso_team_pro_graduated_monthly",
                 reason="cancellation_requested", discount=None, cancel_at=1_700_000_000.0, user_id="1001", lane=None):
        self.ticket_id = "t" * 24
        self.user_id = user_id
        self.primary_class = cause
        self.lane = lane or model.CREDIT_REVIEW
        self.mrr_cents = 4900
        self.tier = "T2-open-told-wait"
        self.cancel_at = cancel_at
        self.candidate = {"plan": plan, "reason": reason, "discount": discount}
        self.readback = evidence or {}


GOOD = {
    "credits_not_approved": {"credits_approved": 3, "credits_declined": 0},
    "proof_sent_no_update": {"credits_approved": 2},
    "merge_claim_stuck": {"merge_claim_result": "merge"},
    "analytics_stale_wrong": {"platform": "Spotify"},
    "billing_confusion": {"refund_amount": "49.00"},
    "other": {"human_reply": "You were right about the duplicate profile, and I merged it into the one "
                             "you log in with so every credit now sits on a single page, and the "
                             "duplicate no longer appears in search results when anyone looks for "
                             "your name."},
}


def render_one(cause, evidence=None, **kw):
    ticket = Ticket(cause=cause, evidence=evidence if evidence is not None else GOOD[cause], **kw)
    return render.render(ticket=ticket, policy=POLICY, recipient={"first_name": "Sam"})


class RenderTest(unittest.TestCase):
    def test_every_cause_class_renders_and_passes_the_guard(self):
        for cause in model.CLASSES:
            rendered = render_one(cause)
            self.assertTrue(rendered.eligible, f"{cause}: {rendered.ineligible_reason}")
            verdict = guards.check_rendered(rendered, POLICY)
            self.assertTrue(verdict.ok, f"{cause}: {verdict.reason()}")
            self.assertNotIn("{", rendered.body)

    def test_credits_line_names_the_count_and_hides_nothing(self):
        rendered = render_one("credits_not_approved", {"credits_approved": 3, "credits_declined": 1})
        self.assertIn("3 of your pending credits are now approved", rendered.fix_line)
        self.assertIn("and 1 was declined", rendered.fix_line)
        plural = render_one("credits_not_approved", {"credits_approved": 2, "credits_declined": 3}).fix_line
        self.assertIn("and 3 were declined", plural)

    def test_zero_approved_credits_is_ineligible_not_a_fix(self):
        rendered = render_one("credits_not_approved", {"credits_approved": 0, "credits_declined": 2})
        self.assertFalse(rendered.eligible)
        self.assertIn("no approved credit", rendered.ineligible_reason)

    def test_documents_with_no_approved_credit_is_ineligible(self):
        rendered = render_one("proof_sent_no_update", {"credits_approved": 0})
        self.assertFalse(rendered.eligible)

    def test_merge_needs_the_readback_to_say_which_outcome_happened(self):
        self.assertFalse(render_one("merge_claim_stuck", {}).eligible)
        self.assertFalse(render_one("merge_claim_stuck", {"merge_claim_result": "maybe"}).eligible)
        self.assertIn("your profile claim is processed",
                      render_one("merge_claim_stuck", {"merge_claim_result": "claim"}).fix_line)

    def test_analytics_needs_the_platform(self):
        self.assertFalse(render_one("analytics_stale_wrong", {}).eligible)

    def test_a_policy_gap_is_fixable_and_a_user_dead_end_is_not(self):
        # The difference decides whether a ticket survives to be sent after a policy edit: a
        # missing slug or link is OUR gap, an approved-credit count of zero is that user's.
        policy = copy.deepcopy(POLICY)
        policy["offers"]["offer_url"] = ""
        ticket = Ticket(cause="credits_not_approved", evidence=GOOD["credits_not_approved"])
        gap = render.render(ticket=ticket, policy=policy, recipient={"first_name": "Sam"})
        self.assertFalse(gap.eligible)
        self.assertTrue(gap.ineligible_fixable)
        self.assertIn("offer_url", gap.ineligible_reason)
        dead_end = render_one("credits_not_approved", {"credits_approved": 0, "credits_declined": 2})
        self.assertFalse(dead_end.eligible)
        self.assertFalse(dead_end.ineligible_fixable)

    def test_billing_needs_a_money_amount(self):
        self.assertFalse(render_one("billing_confusion", {}).eligible)
        self.assertFalse(render_one("billing_confusion", {"refund_amount": "some"}).eligible)
        self.assertIn("$49.00", render_one("billing_confusion", {"refund_amount": "49.00"}).fix_line)

    def test_the_amount_is_the_dollars_the_person_recorded(self):
        # The task instruction says `stripe_refund_amount: 49.00`, i.e. DOLLARS. A cents reading
        # turned a $49 refund into "$0.49" in the one sentence that proves we refunded the money.
        self.assertIn("$49.00", render_one("billing_confusion", {"refund_amount": "49.00"}).fix_line)
        big = render_one("billing_confusion", {"refund_amount": "4900"}).fix_line
        self.assertIn("$4900", big)
        self.assertNotIn("$49.00", big)  # no /100: 4900 dollars is 4900 dollars

    def test_other_quote_skips_the_greeting_and_names_the_fix(self):
        # The reviewer's trace: support replies start "Hi Nadia, thanks for waiting." Quoting that
        # sentence tells the customer nothing about what was fixed, which is the one thing R2
        # requires the message to say.
        reply = ("Hi Nadia, thanks for waiting. Sorry for the delay here. I checked with the team and "
                 "your two profiles are merged, with all four credits on the one you log in with, and "
                 "the duplicate no longer appears in search results when anyone looks for your name "
                 "on the platform today.")
        rendered = render_one("other", {"human_reply": reply})
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertIn("your two profiles are merged", rendered.fix_line)
        self.assertNotIn("Hi Nadia", rendered.fix_line)
        self.assertNotIn("thanks for waiting", rendered.fix_line)

    def test_other_needs_an_answer_not_only_a_pleasantry(self):
        rendered = render_one("other", {"human_reply": "Hi Nadia, thanks so much for waiting. "
                                                        "I hope this note finds you well."})
        self.assertFalse(rendered.eligible)
        # Recoverable: the reply can be re-worded, so this is our gap and the ticket stays
        # sendable. A terminal mark_ineligible would close out a user who was actually answered.
        self.assertTrue(rendered.ineligible_fixable)
        self.assertIn("names the fix", rendered.ineligible_reason)

    def test_a_fifty_word_answer_quotes_its_fix_sentence(self):
        # The human's ruling: the 40-word bar is on the WHOLE reply; the one sentence we quote
        # only has to name the fix. Applying the 40-word bar to the sentence killed every normal
        # multi-sentence answer.
        reply = ("Hi Nadia, thanks for waiting. I checked with the team and your duplicate profile "
                 "has been merged into the one you log in with, so all of your credits now sit on a "
                 "single page and the duplicate no longer appears in search results. Sorry again "
                 "for the delay here.")
        rendered = render_one("other", {"human_reply": reply})
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertIn("your duplicate profile has been merged", rendered.fix_line)
        self.assertNotIn("thanks for waiting", rendered.fix_line)

    def test_other_quotes_one_sentence_of_the_human_reply(self):
        rendered = render_one("other")
        self.assertIn("You were right about the duplicate profile", rendered.fix_line)
        self.assertTrue(rendered.fix_line.startswith("“"))
        self.assertFalse(render_one("other", {}).eligible)
        # The template supplies the full stop: a quoted reply that kept its own would render
        # "so.”.", which is a typo in a message about how carefully we handled their case.
        self.assertNotIn('.”.', rendered.body)
        self.assertIn('”.', rendered.body)

    def test_raising_the_quoted_sentence_floor_actually_raises_it(self):
        # The floor used to be clamped and then taken from the reply's own 40-word gate, so the
        # quote bar could not be tuned at all. It is its own policy number now, and raising it
        # has to change the outcome - while leaving the whole-reply gate alone.
        reply = ("You were right about the duplicate profile, and I merged it into the one you log in "
                 "with so every credit now sits on a single page.")
        ticket = Ticket(cause="other", evidence={"human_reply": reply})
        low = copy.deepcopy(POLICY)
        low["guards"]["human_reply_sentence_min_words"] = 8
        self.assertTrue(render.render(ticket=ticket, policy=low,
                                      recipient={"first_name": "Sam"}).eligible)
        high = copy.deepcopy(POLICY)
        high["guards"]["human_reply_sentence_min_words"] = 40
        rendered = render.render(ticket=ticket, policy=high, recipient={"first_name": "Sam"})
        self.assertFalse(rendered.eligible)
        self.assertTrue(rendered.ineligible_fixable)
        self.assertIn("names the fix", rendered.ineligible_reason)
        # The reply floor is a DIFFERENT gate and must not move the quote.
        reply_floor = copy.deepcopy(POLICY)
        reply_floor["guards"]["human_reply_min_words"] = 120
        self.assertTrue(render.render(ticket=ticket, policy=reply_floor,
                                      recipient={"first_name": "Sam"}).eligible)

    def test_monthly_offer_uses_the_existing_coupon_and_its_expiry(self):
        rendered = render_one("credits_not_approved")
        self.assertEqual(rendered.coupon, "WB_M2_MONTH1")
        self.assertIn("$1", rendered.offer_line)
        self.assertIn("January 31, 2027", rendered.offer_line)

    def test_annual_offer_uses_the_annual_coupon(self):
        rendered = render_one("credits_not_approved", plan="muso_pro_annual")
        self.assertEqual(rendered.coupon, "WB_M2_ANNUAL40")
        self.assertIn("$72", rendered.offer_line)
        self.assertEqual(rendered.plan_noun, "Muso Pro")

    def test_payment_failed_gets_a_restart_line_and_no_coupon(self):
        rendered = render_one("credits_not_approved", reason="payment_failed")
        self.assertIsNone(rendered.coupon)
        self.assertIn("restart", rendered.offer_line)
        # No coupon to apply, so no offer slug: a dead offer= link would be worse than none.
        self.assertNotIn("offer=", rendered.offer_url)
        self.assertIn("muso.ai/", rendered.offer_url)

    def test_every_offer_sentence_carries_a_working_muso_link(self):
        for kwargs in ({}, {"plan": "muso_pro_annual"}, {"reason": "payment_failed"}):
            rendered = render_one("credits_not_approved", **kwargs)
            self.assertIn("muso.ai/", rendered.offer_line, kwargs)
            self.assertIn(rendered.offer_url, rendered.body, kwargs)
            self.assertTrue(guards.check_rendered(rendered, POLICY).ok, kwargs)
        regional = render_one("credits_not_approved", discount="Regional Discount 40%")
        # The GO is recorded, but the coupon was not re-checked at send: no price statement.
        self.assertTrue(regional.eligible, regional.ineligible_reason)
        self.assertNotIn("regional discount still applies", regional.offer_line)

    def test_a_body_that_promises_a_link_without_one_is_refused(self):
        rendered = render_one("credits_not_approved")
        rendered.body = rendered.body.replace(rendered.offer_url, "our pricing page")
        result = guards.check_rendered(rendered, POLICY)
        self.assertFalse(result.ok)
        self.assertIn("link", result.reason())

    def test_regional_price_sentence_waits_for_its_own_go(self):
        # The suffix states a PRICE. The template GO covers the six FIX_LINE variants, not a
        # seventh sentence, so without its own recorded GO this user gets no message at all.
        policy = copy.deepcopy(POLICY)
        policy["offers"]["regional_suffix"]["fable_go_ref"] = None
        ticket = Ticket(cause="credits_not_approved", evidence=GOOD["credits_not_approved"],
                        discount="Regional Discount 40%")
        rendered = render.render(ticket=ticket, policy=policy, recipient={"first_name": "Sam"})
        self.assertFalse(rendered.eligible)
        self.assertTrue(rendered.ineligible_fixable)  # a policy gap, never this user's dead end
        self.assertIn("not approved", rendered.ineligible_reason)
        self.assertEqual(rendered.body, "")
        self.assertEqual(rendered.offer_line, "")
        self.assertEqual(rendered.coupon, None)

    def test_regional_user_keeps_their_country_coupon_once_its_go_is_recorded(self):
        policy = copy.deepcopy(POLICY)
        policy["offers"]["regional_suffix"]["fable_go_ref"] = "FABLE-GO-REGIONAL-1"
        ticket = Ticket(cause="credits_not_approved", evidence=GOOD["credits_not_approved"],
                        discount="Regional Discount 40%")
        rendered = render.render(ticket=ticket, policy=policy, recipient={"first_name": "Sam"},
                                 regional_coupon="held")
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertIn("regional discount still applies", rendered.offer_line)
        self.assertEqual(rendered.coupon, "WB_M2_MONTH1")
        self.assertTrue(guards.check_rendered(rendered, policy).ok)

    def test_a_lapsed_country_coupon_drops_the_sentence_and_still_sends(self):
        # The sentence asserts a price. A coupon that lapsed between list build and send makes it
        # false, so it is dropped - but the fix message itself is still owed to this user.
        ticket = Ticket(cause="credits_not_approved", evidence=GOOD["credits_not_approved"],
                        discount="Regional Discount 40%")
        rendered = render.render(ticket=ticket, policy=POLICY, recipient={"first_name": "Sam"},
                                 regional_coupon="lapsed")
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertNotIn("regional discount still applies", rendered.offer_line)
        self.assertIn("dropped (coupon lapsed at send)", " ".join(rendered.notes))
        self.assertTrue(guards.check_rendered(rendered, POLICY).ok)

    def test_an_unverified_coupon_drops_the_sentence_and_still_sends(self):
        ticket = Ticket(cause="credits_not_approved", evidence=GOOD["credits_not_approved"],
                        discount="Regional Discount 40%")
        rendered = render.render(ticket=ticket, policy=POLICY, recipient={"first_name": "Sam"},
                                 regional_coupon="unverified")
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertNotIn("regional discount still applies", rendered.offer_line)
        self.assertTrue(guards.check_rendered(rendered, POLICY).ok)

    def test_the_ended_plan_date_is_the_one_we_hold(self):
        rendered = render_one("credits_not_approved", cancel_at=1_706_745_600.0)  # 2024-02-01 UTC
        self.assertEqual(rendered.pro_ended_date, "February 1, 2024")
        self.assertIn("cancelled your Muso Pro on February 1, 2024", rendered.body)

    def test_a_cancellation_request_is_not_described_as_the_plan_ending(self):
        # cancel_at is the cancel REQUEST: a user who cancelled on Nov 2 keeps access to Nov 30.
        # Telling them the plan ended on Nov 2 is a false statement about their own account.
        rendered = render_one("credits_not_approved", cancel_at=1_706_745_600.0)
        self.assertNotIn("ended on", rendered.body)
        self.assertIn("cancelled your Muso Pro on February 1, 2024", rendered.body)

    def test_first_name_falls_back_to_there(self):
        self.assertEqual(render.first_name(""), "there")
        self.assertEqual(render.first_name("Sam"), "Sam")
        self.assertEqual(render.first_name("Sam Smith"), "Sam")
        self.assertEqual(render.first_name("1234"), "there")
        self.assertEqual(render.first_name("<script>"), "there")

    def test_body_never_claims_a_date_we_do_not_hold(self):
        rendered = render_one("credits_not_approved")
        found = re.findall(r"\b(?:January|February|March|April|May|June|July|August|September|October|"
                           r"November|December) \d{1,2}, \d{4}\b", rendered.body)
        self.assertEqual(sorted(found), sorted({rendered.pro_ended_date, "January 31, 2027"}))


class GuardTest(unittest.TestCase):
    def test_forbidden_vendor_names_block(self):
        for word in ("Klaviyo", "JAXSTA"):
            self.assertFalse(guards.check(f"A body that mentions {word} in passing. " * 6, POLICY).ok)

    def test_forward_promises_block(self):
        body = ("Thanks for waiting, we will get back to you with an answer as soon as the team can look at "
                "this properly and confirm what happened to the credits that were sitting on your profile.")
        verdict = guards.check(body, POLICY)
        self.assertFalse(verdict.ok)
        self.assertIn("forward-promise", verdict.reason())

    def test_unfilled_placeholder_blocks(self):
        body = ("Hi {first_name}, we fixed the thing you were waiting on and it is now showing on your "
                "profile so you can see it yourself without asking us again.")
        self.assertIn("placeholder", guards.check(body, POLICY).reason())

    def test_internal_vocabulary_blocks(self):
        body = ("Hi Sam, your ticket in the credit review queue was moved to the head of the lane and the "
                "decider approved it, so the credits are on your profile now and nothing else changed today.")
        self.assertFalse(guards.check(body, POLICY).ok)

    def test_non_muso_links_block(self):
        body = ("Hi Sam, we fixed the thing you waited on and you can see it at "
                "https://example.com/account right now, with nothing else about your plan changing at all.")
        self.assertIn("non-muso link", guards.check(body, POLICY).reason())

    def test_thin_and_wall_of_text_block(self):
        self.assertFalse(guards.check("Fixed it.", POLICY).ok)
        self.assertFalse(guards.check("muso " * 400, POLICY).ok)

    def test_a_dirty_quote_is_blamed_on_the_user_who_wrote_it(self):
        # `other` quotes a sentence a support agent already sent, so a violation that lives inside
        # the quote is that answer's problem: one agent's wording must not stall the campaign.
        rendered = render_one("other", {"human_reply": "You were right that the credits were stuck, "
                                                       "and the threshold signal is now updated on "
                                                       "your account with both credits approved, so "
                                                       "the two pending requests now show as approved "
                                                       "when you open your profile page on the website."})
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertFalse(guards.check_rendered(rendered, POLICY).ok)
        self.assertEqual(guards.quoted_fragment_fault(rendered, POLICY),
                         "the human answer we would quote names something we cannot send")

    def test_a_quote_that_says_this_link_is_not_blamed_for_the_missing_url(self):
        # The link-claim rule is body-scoped: the offer line supplies the URL, and a single quoted
        # sentence can never carry it. Blaming the quote would close this user's ticket forever.
        rendered = render_one("other", {"human_reply": "I have updated your profile and you can check it "
                                                       "at this link to see all of your credits in one "
                                                       "place now, and the duplicate profile no longer "
                                                       "appears when anyone searches for your name "
                                                       "anywhere on the platform."})
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertTrue(guards.check_rendered(rendered, POLICY).ok,
                        guards.check_rendered(rendered, POLICY).reason())
        self.assertIsNone(guards.quoted_fragment_fault(rendered, POLICY))

    def test_a_quote_that_promises_a_deadline_is_blamed_on_the_user_who_wrote_it(self):
        rendered = render_one("other", {"human_reply": "Your credits are approved and I guarantee the "
                                                       "numbers will update within 2 days so you can see "
                                                       "everything on your profile again, and the "
                                                       "duplicate profile will be gone from search "
                                                       "results by then as well for good today."})
        self.assertTrue(rendered.eligible, rendered.ineligible_reason)
        self.assertEqual(guards.quoted_fragment_fault(rendered, POLICY),
                         "the human answer we would quote names something we cannot send")

    def test_a_dirty_skeleton_is_blamed_on_the_copy(self):
        policy = copy.deepcopy(POLICY)
        policy["template"]["body"] = [*policy["template"]["body"],
                                       "This note comes from our churn lane."]
        ticket = Ticket(cause="credits_not_approved", evidence=GOOD["credits_not_approved"])
        rendered = render.render(ticket=ticket, policy=policy, recipient={"first_name": "Sam"})
        self.assertFalse(guards.check_rendered(rendered, policy).ok)
        self.assertIsNone(guards.quoted_fragment_fault(rendered, policy))


class PolicyTest(unittest.TestCase):
    def test_template_is_disabled_until_the_go_is_recorded(self):
        template = POLICY["template"]
        self.assertFalse(template["enabled"])
        self.assertIsNone(template["fable_go_ref"])

    def test_an_armed_policy_carries_a_go_for_every_sentence_it_ships(self):
        # The template GO is the GO on the six FIX_LINE variants. The regional suffix states a
        # price, so arming the campaign must never ship it on the strength of that one GO.
        suffix = POLICY["offers"]["regional_suffix"]
        if POLICY["template"]["enabled"]:
            self.assertTrue(str(suffix.get("fable_go_ref") or "").strip())
        self.assertTrue(suffix["requires_fable_go"])

    def test_offers_are_the_approved_set_and_nothing_new(self):
        offers = POLICY["offers"]
        self.assertEqual(offers["monthly"]["coupon"], "WB_M2_MONTH1")
        # The live slags in muso-messaging contracts/email/coupons.json. The previous copy of this
        # file said WB_M1_ANNUAL40, which is not a coupon the send-gateway knows: the annual offer
        # would have been refused at send time (or, worse, silently gone out without the discount).
        self.assertEqual(offers["annual"]["coupon"], "WB_M2_ANNUAL40")
        self.assertEqual(offers["annual"]["slug"], "wb-m2-annual40")
        self.assertEqual(offers["monthly"]["slug"], "wb-m2-month1")
        self.assertIsNone(offers["payment_failed"]["coupon"])

    def test_every_placeholder_in_the_copy_is_one_the_renderer_fills(self):
        filled = {"first_name", "cause_noun", "fix_line", "plan_noun", "pro_ended_date", "offer_line"}
        text = " ".join([POLICY["template"]["subject"], *POLICY["template"]["body"]])
        self.assertEqual(set(re.findall(r"\{([a-z_]+)\}", text)), filled)

    def test_every_cause_class_has_a_fix_line(self):
        for cause in model.CLASSES:
            self.assertTrue(str(POLICY["fix_lines"].get(cause) or "").strip(), cause)


if __name__ == "__main__":
    unittest.main()
