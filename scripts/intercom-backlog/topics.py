"""Topic of a customer-last conversation from its LATEST customer message, with the billing veto.

QA (hydra#1379 thread on census.py): a thread opened about credits whose latest customer message asks for
a refund must not stay `credit`, or a credit status line could answer a money question. So the latest
customer text decides first:
  - legal words in it                       -> "legal"   (captain / counsel)
  - billing words in it (TOPIC_BILLING_RE)  -> "billing" (captain; never a credit/claim/merge line)
  - otherwise its own topic, when it has one; else the opening message's topic.
"credit card" / "credit note" / "store credit" are billing phrases, never credit words (comm_state.on_topic).

TOPIC_BILLING_RE is the shared hydra pattern (credit_review/comm_state.py, verify-ask-wiring-h2 #1418). Until
#1418 is on main the identical pattern is used from BILLING_PATTERN below; tests pin the two equal whenever
comm_state carries it.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

BILLING_PATTERN = (r"\b(refund\w*|charge[sd]?|chargeback|invoice\w*|billing|billed|payment\w*|subscription\w*|"
                   r"paypal|card)\b")
try:  # the shared pattern when present
    from credit_review.comm_state import TOPIC_BILLING_RE  # noqa: E402
except (ImportError, AttributeError):
    TOPIC_BILLING_RE = re.compile(BILLING_PATTERN)

LEGAL_RE = re.compile(r"\b(lawyer|attorney|legal action|cease and desist|c&d|dmca|lawsuit|sue you|court|"
                      r"copyright infringement|takedown notice|gdpr|cnil|data protection)\b", re.I)
NOT_CREDIT = re.compile(r"credit[ -]?cards?|credit notes?|store credit", re.I)


def latest_topic(opening_topic, latest, topic_of):
    """Pure. topic_of = census.topic_of. latest = (final customer part, recent customer parts joined), or a
    plain string (treated as both), or None (not read) -> 'unread' (held, never sent).

    QA (hydra#1379): the topic comes from the FINAL customer part only ("my credit is wrong" then "I cannot
    sign in" is account). Legal and billing words in the recent parts still win (the safe direction: they route
    to the captain). A final part with no topic of its own is "other", never the opening's topic; the opening
    decides only when the customer never wrote again (the caller does not call this then)."""
    if latest is None:
        return "unread"
    final, recent = (latest, latest) if isinstance(latest, str) else latest
    raw_final, raw_recent = (final or "").lower(), (recent or final or "").lower()
    if LEGAL_RE.search(raw_final) or LEGAL_RE.search(raw_recent):
        return "legal"
    # on the raw text: "credit card" IS a billing phrase
    if TOPIC_BILLING_RE.search(raw_final) or TOPIC_BILLING_RE.search(raw_recent):
        return "billing"
    return topic_of(NOT_CREDIT.sub(" ", raw_final))  # ...and never a credit word


def billing_veto(text):
    """True when a credit/claim/merge reading must not apply: the text carries billing words."""
    return bool(text) and bool(TOPIC_BILLING_RE.search(text.lower()))
