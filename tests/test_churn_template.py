"""The send-gateway template is the SAME copy as the lane's, and CI proves it.

`scripts/winback_fix_template.py` emits the `wb_fix_1` drop-in for muso-messaging from
`policies/winback-fix.json`. That is only safe if the gateway's Django-subset renderer produces
the identical sentence the lane's own renderer produces for the same user - otherwise the copy
Fable reviewed is not the copy a customer receives, and the review means nothing.

So each variant is rendered twice: once through the emitted template with send-gateway's
substitution rules, once through `scripts/churn/render.py`. The bodies must match exactly.
"""

import json
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from churn import render  # noqa: E402
import winback_fix_template as tpl  # noqa: E402

POLICY = json.loads((ROOT / "policies" / "winback-fix.json").read_text())

# One evidence bundle per cause class: what the read-back hands the renderer.
EVIDENCE = {
    "credits_not_approved": {"credits_approved": 3, "credits_declined": 1},
    "proof_sent_no_update": {"credits_approved": 2},
    "merge_claim_stuck": {"merge_claim_result": "merge"},
    "analytics_stale_wrong": {"platform": "Spotify"},
    "billing_confusion": {"refund_amount": "49.00"},
    "other": {"human_reply": (
        "You were right that these are the same profile and I am sorry it took us so long to sort "
        "out. I merged the duplicate into the account you log in with, moved every credit across, "
        "and checked that the second profile no longer appears in search results for your name "
        "anywhere on the platform, so everything now sits on the account you actually use."
    )},
}


def gateway_render(template, values):
    """send-gateway's substitution for the placeholders this template uses (render.js semantics)."""
    out = template
    for key, value in values.items():
        out = out.replace("{{ first_name }}" if key == "first_name" else f"{{{{ event.{key} }}}}", str(value))
    out = re.sub(r"\{%\s*(?:unsubscribe_url|manage_preferences_url)\s*%\}", "https://muso.ai/x", out)
    return out


class SeenTicket:
    """The attributes render.render() reads off a churn.tickets.Ticket."""

    def __init__(self, cause_class, evidence):
        self.ticket_id = "t" * 24
        self.user_id = "1001"
        self.primary_class = cause_class
        self.readback = evidence
        self.candidate = {"plan": "muso_team_pro_graduated_monthly", "reason": "cancellation_requested"}
        self.cancel_at = 1_700_000_000.0


def candidate(cause_class, evidence):
    return SeenTicket(cause_class, evidence)


def lane_values(rendered, cause_class):
    """The values the lane puts in the hand-off manifest for this body."""
    return {
        "first_name": "Nadia",
        "cause_noun": POLICY["cause_nouns"][cause_class],
        "fix_line": rendered.fix_line,
        "plan_noun": rendered.plan_noun,
        "pro_ended_date": rendered.pro_ended_date,
        "offer_line": rendered.offer_line,
    }


class TemplateParityTest(unittest.TestCase):
    def test_every_variant_renders_identically_through_both_renderers(self):
        skeleton = tpl.body_text(POLICY)
        copy_only = skeleton.rsplit("\n\nYou're getting this", 1)[0]
        for cause_class, evidence in EVIDENCE.items():
            rendered = render.render(ticket=candidate(cause_class, evidence), policy=POLICY,
                                     recipient={"first_name": "Nadia"},
                                     human_reply=evidence.get("human_reply"))
            self.assertIsNone(rendered.ineligible_reason, f"{cause_class}: {rendered.ineligible_reason}")
            via_gateway = gateway_render(copy_only, lane_values(rendered, cause_class))
            self.assertEqual(
                via_gateway, rendered.body,
                f"{cause_class}: the gateway template and the lane disagree - one of them was edited alone",
            )

    def test_the_template_carries_every_placeholder_the_lane_supplies(self):
        text = tpl.body_text(POLICY)
        for name in ("{{ first_name }}", "{{ event.cause_noun }}", "{{ event.fix_line }}",
                     "{{ event.plan_noun }}", "{{ event.pro_ended_date }}", "{{ event.offer_line }}"):
            self.assertIn(name, text)

    def test_no_unconverted_python_placeholder_survives(self):
        text = tpl.body_text(POLICY)
        self.assertNotRegex(text.replace("{{", "").replace("}}", ""), r"\{[a-z_]+\}")

    def test_the_marketing_footer_is_present(self):
        text = tpl.body_text(POLICY)
        self.assertIn("{% unsubscribe_url %}", text)
        self.assertIn("{% manage_preferences_url %}", text)


class TemplateEntryTest(unittest.TestCase):
    def test_it_ships_disabled(self):
        entry = tpl.native_entry(POLICY)
        self.assertFalse(entry["enabled"])
        self.assertIsNone(POLICY["template"]["fable_go_ref"])

    def test_it_is_a_marketing_template_with_the_person_sender(self):
        entry = tpl.native_entry(POLICY)
        self.assertEqual(entry["class"], "marketing")
        self.assertEqual(entry["subdomain"], "news")
        self.assertEqual(entry["reply_to"], "support@muso.ai")
        self.assertEqual(entry["from_name"], "Aaron | Muso.AI")
        self.assertEqual(entry["subject"], POLICY["template"]["subject"])

    def test_the_paths_match_the_files_emit_writes(self):
        import tempfile
        out = tempfile.mkdtemp()
        entry = tpl.emit(POLICY, out)
        root = pathlib.Path(out)
        self.assertTrue((root / entry["text"]).exists())
        self.assertTrue((root / entry["html"]).exists())
        self.assertTrue((root / f"{POLICY['template']['key']}.native-entry.json").exists())

    def test_the_body_survives_the_same_guard_as_a_message(self):
        from churn import guards

        class Probe:
            subject = POLICY["template"]["subject"]
            variant = "template"
            coupon = None

        probe = Probe()
        probe.body = tpl.body_text(POLICY)
        verdict = guards.check_rendered(probe, POLICY)
        self.assertTrue(verdict.ok, verdict.reason())


if __name__ == "__main__":
    unittest.main()
