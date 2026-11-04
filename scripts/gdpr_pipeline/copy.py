"""Approved customer copy, VERBATIM. Nothing here is composed; the pipeline only picks a fixed text and fills slots.

Sources (never edit a sentence here without the owner's ruling landing in a PR):
  LINK_LINE      `gdpr-ruling-for-jan.md` §1 (Jan's identity line) = §2 "if no profile link was given"
  IDENTITY_STEP  `gdpr-ack-v2-and-arpad-1101.md` §2 step 1 (the confirm-it's-you paths, claim first)
  AUTH_LINE      `gdpr-ruling-for-jan.md` §2 (writing on behalf of someone else)
  CONFIRMATION   `data/cs-systemic-issues-lane-c1/erasure-confirmation-template.md`, APPROVED by firstmate 943
                 (2026-10-22): lines S/P/M only after the same run's check passes; [D-no] in every letter until
                 the captain clears a batch from legal hold 1350; the G line is left out until the captain has
                 done the Search Console removals.

SENDS ARE UNLOCKED (2026-11-03, Fable under the captain's delegation - see SEND_APPROVAL_REF). The copy and the
adapters are unchanged; what changed is that the pipeline may now send, under three standing limits that are code, not
convention: one letter per (request, kind) in `erasure_sends`, an allowlisted human's `--approved-by` on every run
(U7RP6HKUZ / U038BM16T7W / U0AL36NADEY), and refusal - never a silent skip - for any route we cannot address.
"""
from __future__ import annotations

# Flipped by the PR that carries the GO, never edited casually: this constant is the difference between a dry run and
# a letter to a customer. The gate is TWO locks - this one AND an allowlisted human's --approved-by per run.
PIPELINE_SENDS_APPROVED = True
SEND_APPROVAL_REF = (
    "Fable ruling B3 (data/verify-sla-driver-fable-d2/rulings-blockers-1103-20Z.md, 2026-11-03 20:1xZ): g1 wires "
    "confirm/ask through the approved sender adapter; copy = the already-approved erasure-confirmation template "
    "(firstmate 943) + gdpr-ack-v2 §2 step 1 / gdpr-ruling-for-jan §1-2 ask lines, verbatim. Extended the same night "
    "by the 23:2xZ delegated ruling (ops-lead re-measure, captain's delegation to Fable): unlock the send path, "
    "oldest-overdue first, one letter per user, ledgered; nothing ever via Klaviyo. The ASK copy itself was then "
    "approved by the same seat under its own id (`fable-ruling-1103-d2/gdpr-identity-ask`), so every letter a run "
    "sends must name a ruling id that exists in `policies/gdpr-send-rulings.json` - see copy.PROGRESS_LINE_APPROVED "
    "and gdpr_pipeline/approval.py.")

LINK_LINE = "So we act on the right pages, please reply with the link(s) to the Muso page(s) concerned."

IDENTITY_STEP = (
    "The quickest way: open the page in the Muso app and claim it \u2014 that proves it on the spot. Or reply from "
    "the email address on your Muso account, if you have one. If neither applies, send the link to the page and "
    "the name on it as it appears on your ID; for a page that carries your name, that is enough. If you are "
    "writing for someone else, send their written authorisation."
)

AUTH_LINE = ("Because you are writing on behalf of someone else, please send us their written authorisation to act "
             "for them.")

ASK = {"ASK_LINK": LINK_LINE, "ASK_IDENTITY": IDENTITY_STEP, "ASK_AUTH": AUTH_LINE}

# A request that is ALREADY past its statutory date owes the customer one more thing: an acknowledgement that the
# deletion is under way (not a fresh promise) plus the ask itself (23:2xZ delegated ruling, item 3). APPROVED AS
# WRITTEN by Fable 2026-11-03T23:40Z, approval id `fable-ruling-1103-d2/gdpr-progress-line` (firstmate inbox 027); the
# ledger record lives in `policies/gdpr-send-rulings.json`. It is used ONLY on a request past its 30-day date; the plain
# ask is unchanged. While this was False a past-due ask REFUSED rather than sending a shortened letter, because asking
# with no acknowledgement of a month of silence reads as if we just received the request.
PROGRESS_LINE_APPROVED = True
PROGRESS_LINE = ("Thank you for your patience. The deletion request you made on {received} is in progress: we are "
                 "confirming which pages belong to you so that nothing is missed, and we are keeping a restricted "
                 "internal record while we finish.")


def progress_line(received_iso: str) -> str:
    """The past-due opening line, with the request's own date in it. Verbatim apart from that slot."""
    return PROGRESS_LINE.replace("{received}", human_date(received_iso))

CONFIRM_HEAD = "Hello {name},\n\nAs promised, here is where your request of {received} stands. It concerns: {links}.\n\nWhat we have done:\n"
LINE_S = "- {date}: removed from search on Muso, so these pages no longer appear in our search or suggestions.\n"
LINE_P = ("- {date}: the pages no longer show your information to the public. Anyone opening them, including search "
          "engines, now gets a \"page gone\" response and an instruction not to index it.\n")
LINE_M = "- {date}: removed from our sitemaps, so we no longer point search engines to them.\n"
NEXT_HEAD = "\nWhat happens next:\n"
LINE_D_NO = ("- We are keeping a restricted internal record while we complete our review. It is not visible to the "
             "public, and we will confirm on this thread when the review is finished.\n")
LINE_P_PENDING = ("- The remaining step (removing the pages from public view) is in progress. We will confirm on this "
                  "thread once it is complete.\n")
CONFIRM_TAIL = ("\nIf you see any page about you that we have missed, reply to this email with the link and we will "
                "add it to your request.\n\nMuso.AI Support")

BARRED = ("business day", "deleted on request", "we will delete", "may be recreated", "article 17", "art. 17",
          "it's public information")


def human_date(iso: str) -> str:
    from datetime import datetime
    d = datetime.strptime(iso[:10], "%Y-%m-%d")
    return f"{d.day} {d.strftime('%B %Y')}"


def render_confirmation(name: str, received_at: str, links: list[str], s_date: str, p_date: str, m_date: str) -> str:
    """The approved letter with ONLY the verified lines. P missing -> the 'in progress' line instead.
    No verified line at all -> refuse: a letter whose 'What we have done' is empty is not the approved letter."""
    if not (s_date or p_date or m_date):
        raise ValueError("no verified S/P/M line: nothing to confirm yet")
    body = CONFIRM_HEAD.format(name=name or "there", received=human_date(received_at), links=", ".join(links))
    if s_date:
        body += LINE_S.format(date=human_date(s_date))
    if p_date:
        body += LINE_P.format(date=human_date(p_date))
    if m_date:
        body += LINE_M.format(date=human_date(m_date))
    body += NEXT_HEAD + LINE_D_NO
    if not p_date:
        body += LINE_P_PENDING
    body += CONFIRM_TAIL
    low = body.lower()
    hit = [b for b in BARRED if b in low]
    if hit:
        raise ValueError(f"barred phrase in a rendered letter: {hit}")
    return body
