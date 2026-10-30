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


def latest_topic(opening_topic, latest_text, topic_of):
    """Pure. topic_of = census.topic_of. latest_text None (not read) -> 'unread' (held, never sent)."""
    if latest_text is None:
        return "unread"
    raw = latest_text.lower()
    if LEGAL_RE.search(raw):
        return "legal"
    if TOPIC_BILLING_RE.search(raw):  # on the raw text: "credit card" IS a billing phrase
        return "billing"
    own = topic_of(NOT_CREDIT.sub(" ", raw))  # ...and never a credit word
    return own if own != "other" else opening_topic


def billing_veto(text):
    """True when a credit/claim/merge reading must not apply: the text carries billing words."""
    return bool(text) and bool(TOPIC_BILLING_RE.search(text.lower()))
