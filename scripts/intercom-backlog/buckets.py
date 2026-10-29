#!/usr/bin/env python3
"""Non-credit topic buckets for customer-last conversations (captain 2026-10-29 21:3xZ: "are we
handling every person waiting on us?"). READ-ONLY: reads a triage file (triage.py) and writes a
PII-free projection (id, bucket, band, age, paid, waiting_since, topic, action). No text leaves the
host; the excerpt is used only in-process to pick the bucket. Credit / claim / merge conversations
are owned by verify-program-lead-fable-l1 (reply_due) and are counted, not bucketed.

Buckets (first match wins; legal and money first so they never land in a self-serve bucket):
  legal          C&D, attorney, lawsuit, DMCA, GDPR/erasure -> captain / counsel
  billing-money  refund, charged, double charge, chargeback -> captain (money)
  billing-cancel cancel / end subscription, downgrade
  plaque-order   plaque, order, shipping, tracking, address
  account-access log in, password, locked, 2FA, verification email
  account-email  change email / sign-in email
  account-delete delete my account / profile, remove my data
  profile-edit   rename, photo, bio, picture, genre, display name
  stats          streams, analytics, numbers, chart, data missing
  howto          how do I / can I / where is / feature question
  business       partnership, API, label deal, investor, advertise
  auto-noise     auto-reply, out of office, newsletter replies, thanks-only, no text
  other          anything else

Usage (node-8): python3 buckets.py <triage.jsonl> [--min-hours 48] > slim.jsonl
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TAG_RE = re.compile(r"<[^>]+>")
CUSTOMER = ("user", "lead", "contact")

CREDIT_TOPICS = ("credit", "claim", "merge")
BUCKETS = [
    ("social-noise", r"(mentioned you in their story|shared an instagram post|a new message from instagram|"
                     r"shared a post|reacted to your|npx |binance|crypto|campaign optimi[sz]ation|"
                     r"biggest influencers|seo service|guest post)"),
    ("legal", r"\b(lawyer|attorney|legal action|cease and desist|c&d|dmca|lawsuit|sue|court|gdpr|erasure|"
              r"right to be forgotten|data protection|cnil|trademark|copyright)\b"),
    ("billing-money", r"\b(refund|refunded|charged|charge me|double charge|charged twice|chargeback|money back|"
                      r"overcharged|billing error|unauthori[sz]ed (charge|payment))\b"),
    ("billing-cancel", r"\b(cancel|cancell?ation|unsubscribe from (pro|the plan)|end (my )?subscription|downgrade|"
                       r"stop (my )?subscription|auto.?renew)\b"),
    ("plaque-order", r"\b(plaque|plaques|plakette|order|shipping|shipment|tracking|delivery|dhl|ups|fedex|address)\b"),
    ("account-email", r"\b(change (my )?(e-?mail|sign.?in)|new e-?mail|email address (change|update)|"
                      r"update (my )?e-?mail)\b"),
    ("account-access", r"\b(log ?in|login|sign ?in|password|locked out|can'?t access|2fa|verification (code|email)|"
                       r"reset link)\b"),
    ("account-delete", r"\b(delete (my )?(account|profile|data)|remove (my )?(account|profile|data)|close my account|"
                       r"deactivate)\b"),
    ("profile-edit", r"\b(rename|change (my )?(profile )?name|display name|profile (photo|picture|image)|avatar|"
                     r"\bbio\b|genre|artist name|picture)\b"),
    ("merge-like", r"\b(merge|merged|duplicate|consolidat|two profiles|same person|rolled into|combine)\b"),
    ("removal-like", r"\b(remove|removal|delete|not me|not mine|wrong (person|artist)|isn'?t me|another .{0,20}same name)\b"),
    ("credit-like", r"\b(credits?|credited|verification|verify|verificat|proof|split sheet|song|songs|track|tracks|"
                    r"release|album|discography|producer|songwriter|writer|engineer|mix|master)\b"),
    ("subscription", r"\b(subscription|my plan|pro plan|upgrade|business pro|lite)\b"),
    ("escalation", r"\b(human|real person|phone|call me|nobody|no one|no answer|still no|still not|weeks? now|"
                   r"months? now|again and again|ignored|insufferable|terrible|scam)\b"),
    ("stats", r"\b(streams?|analytics|numbers|chart|charts|plays|views|data (is )?(missing|wrong)|spotify|"
              r"shazam|tiktok|youtube|apple music|milestone)\b"),
    ("business", r"\b(partnership|partner|api|label deal|investor|invest|advertis|sponsor|collaborat|"
                 r"business inquiry|pricing for (labels|companies)|enterprise)\b"),
    ("howto", r"\b(how (do|can|to)|can i|where (is|do|can)|is it possible|what is|does muso|help me)\b"),
    ("auto-noise", r"\b(auto.?reply|automatic reply|out of (the )?office|i am away|on vacation|do not reply|"
                   r"no.?reply|unsubscribe|this mailbox|delivery status notification|undeliverable)\b"),
]
BUCKET_RE = [(n, re.compile(p, re.I)) for n, p in BUCKETS]
# A thanks-only message: at most 14 words, every word from this vocabulary (any language we see often).
THANKS_WORDS = frozenset("""thanks thank thx ty you u so very much a lot again ok okay okey great perfect perfecto
perfeito cool awesome noted got it sounds good appreciate i really youre you're the best have nice good day night
take care gracias muchas merci beaucoup danke obrigado obrigada grazie mille amazing wonderful excellent will do
yes yeah yep alright all right bye cheers love it much appreciated helpful thankyou tysm brilliant its it's
too evening that's that all for now kk""".split())
# The customer's last message carries no request: a Messenger quick-reply button, a greeting, or only an
# email address (they answered "what's your email?" and nobody came back).
NO_DETAIL = re.compile(r"^\W*(issue with my profile|another question|other|hello|hi|hey|hola|ol[aá]|bonjour|hallo|"
                       r"ciao|good (morning|afternoon|evening)|how ?are you( doing)?|[\w.+-]+@[\w-]+\.[\w.]+|"
                       r"esse e-?mail|this email)\W*$", re.I)


def is_thanks(text):
    words = [w for w in re.split(r"[^\w']+", (text or "").lower()) if w]
    if not words and (text or "").strip():
        return True  # an emoji-only reaction
    return 0 < len(words) <= 14 and all(w in THANKS_WORDS for w in words)


def bucket_of(text, last=None):
    """last = the customer's LAST message: a thanks-only last message means the thread is satisfied,
    whatever came before (c3's satisfied-close class)."""
    t = " ".join((text or "").split())
    if last is not None and is_thanks(last):
        return "thanks-only"
    if not t or is_thanks(t):
        return "thanks-only"
    if last is not None and NO_DETAIL.match(" ".join(last.split())) and not any(
            rx.search(t) for n, rx in BUCKET_RE if n not in ("howto", "auto-noise")):
        return "no-detail"
    for name, rx in BUCKET_RE:
        if rx.search(t):
            return name
    return "other"


def customer_text(token, cid, last_n=3):
    """The customer's last few messages (the Messenger first message is often a quick-reply button such as
    "Another question" or "Issue with my profile", which says nothing). In-process only; never printed."""
    req = urllib.request.Request(f"https://api.intercom.io/conversations/{cid}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/json", "Intercom-Version": "2.11"})
    for i in range(4):
        try:
            with urllib.request.urlopen(req, timeout=50) as r:
                doc = json.load(r)
            break
        except (urllib.error.HTTPError, urllib.error.URLError):
            if i == 3:
                return None
            time.sleep(2 ** i)
    src = doc.get("source") or {}
    texts = [(src.get("subject") or "") + " " + (src.get("body") or "")]
    for part in (doc.get("conversation_parts") or {}).get("conversation_parts") or []:
        if (part.get("author") or {}).get("type") in CUSTOMER and part.get("body"):
            texts.append(part["body"])
    clean = [" ".join(TAG_RE.sub(" ", t).split()) for t in texts]
    return clean[-1], " ".join(clean[-last_n:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("triage")
    ap.add_argument("--min-hours", type=float, default=48)
    ap.add_argument("--fetch", action="store_true", help="bucket on the customer's last messages (Intercom GETs)")
    ap.add_argument("--out", help="ALSO write the sender's input here (0600; carries user id and contact email "
                                  "for the shared-ledger key, never text). stdout stays PII-free.")
    a = ap.parse_args()
    now = time.time()
    rows = []
    for line in open(a.triage):
        r = json.loads(line)
        if (now - r["waiting_since"]) / 3600 >= a.min_hours:
            r["credit"] = r.get("topic") in CREDIT_TOPICS or str(r.get("action", "")).startswith(("gate-", "claim-"))
            rows.append(r)
    texts = {}
    if a.fetch:
        token = os.environ["MUSOAI_INTERCOM_TOKEN"]
        todo = [r["id"] for r in rows if not r["credit"]]
        with ThreadPoolExecutor(max_workers=6) as ex:
            for cid, t in zip(todo, ex.map(lambda c: customer_text(token, c), todo)):
                texts[cid] = t
    full = None
    if a.out:
        full = os.fdopen(os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w")
    for r in rows:
        hours = (now - r["waiting_since"]) / 3600
        got = texts.get(r["id"])
        last, t = got if got else (None, (r.get("subject") or "") + " " + (r.get("excerpt") or ""))
        b = "credit-owned-l1" if r["credit"] else bucket_of(t, last)
        slim = {"id": r["id"], "bucket": b, "band": r["band"], "age_days": round(hours / 24, 1),
                "paid": bool(r.get("paid")), "waiting_since": r["waiting_since"],
                "topic": r.get("topic"), "action": r.get("action"), "assignee": r.get("admin_assignee_id")}
        print(json.dumps(slim))
        if full:
            full.write(json.dumps(dict(slim, user_id=r.get("user_id"), email=r.get("email") or "",
                                       contact_id=r.get("contact_id"))) + "\n")
    if full:
        full.close()


if __name__ == "__main__":
    sys.exit(main())
