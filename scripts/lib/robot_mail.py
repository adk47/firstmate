"""Shared robot-mail predicate for the two Intercom legal watchdogs (MUS-18980).

One module, imported by scripts/intercom-rights-holder-watchdog.py and (through it)
scripts/intercom-legal-unanswered-watchdog.py — never two copies of the marker lists.

`is_robot_mail(subject, body, sender_email) -> (bool, reason)` is DEMOTE-only: a robot hit
never silences a conversation, the caller digests it (no @mention) instead of paging.

  * BODY markers demote regardless of sender (they carry the whole 2026-10-23 TuneCore
    Zendesk auto-reply storm, 19 of 19 in the 90-day backtest, MUS-18487).
  * A DSN SUBJECT demotes only when the sender is ALSO a robot. In 90 days 54 of 5,691
    conversations carried a DSN subject and 0 had a robot sender (all human forwards), so a
    subject alone would reach human-authored mail, which must still page. This arm fires 0 of
    5,691 in the backtest; it is covered by a synthetic control test, not by measurement.
"""
import re

ROBOT_BODY_MARKERS = (
    "automatic reply",
    "auto-reply",
    "has not received your inquiry",
    "no longer taking new questions",
    "out of office",
)
# The Zendesk footer is a PAIR: both strings together, never either alone.
ZENDESK_FOOTER_PAIR = ("delivered by zendesk", "type your reply above this line")

DSN_SUBJECT_RX = re.compile(
    r"delivery status notification|undeliverable|mail delivery failed", re.IGNORECASE)
ROBOT_SENDER_RX = re.compile(
    r"mailer-daemon|postmaster|no-?reply|do-?not-?reply@", re.IGNORECASE)

REASON_BODY = "robot:auto-reply-body"
REASON_DSN = "robot:dsn+robot-sender"


def is_robot_mail(subject, body, sender_email):
    """(True, reason code) when the message is machine-generated, else (False, None)."""
    text = " ".join((body or "").split()).lower()
    if any(m in text for m in ROBOT_BODY_MARKERS) or all(m in text for m in ZENDESK_FOOTER_PAIR):
        return True, REASON_BODY
    if DSN_SUBJECT_RX.search(subject or "") and ROBOT_SENDER_RX.search(sender_email or ""):
        return True, REASON_DSN
    return False, None
