#!/usr/bin/env python3
"""notices@ / legal@ intake, DRY-RUN / label-only (firstmate 906; Fable removals design §B3, package P7).

Runs on node-8 (service-account key there). Every 15 min from node-1 cron.

  legal-intake.py [--since-days N] [--label] [--ack] [--report]

--ack (captain-approved copy pack A-D, 916.3): one templated ack per NEW thread (first message after
ack-start.txt), from support@ via gog, English, never for legal_threat / spam / other, never to
@muso.ai or no-reply senders; ledgered (acked, ack_ref); a failed send is not ledgered and exits 2.

- Reads deliveredto:notices@muso.ai (mailbox kyran@) and deliveredto:legal@muso.ai (mailbox aaron@).
- Classifies each THREAD (deterministic keyword lists): dmca_takedown, privacy_erasure,
  legal_threat (regulator / counsel / formal notice / C&D), security, credit_dispute, spam, other.
- Links Muso ids (profile/track/album uuid prefixes) found in the bodies; flags any already on
  the cs removal register (dedupe by id prefix).
- Ledger: /root/fmc1-intake/ledger.json (root-only): one row per thread, first/last seen,
  class, ids, replied-by-us flag. Never stores bodies.
- --label: ADDS Gmail labels "OpenClaw/<class>" (+ "OpenClaw/unanswered" when no reply from
  @muso.ai / Intercom in the thread). Never removes labels, never archives, never marks read,
  NEVER sends anything (the ack copy pack is not approved), never touches a legal_threat
  thread beyond its label.
- Exit 2 if a mailbox cannot be read (a check that cannot complete must not look clean).
- REFUSES while /etc/hydra/gmail-readers.disabled exists (the shared freeze for every Gmail reader, firstmate 10-31).
  This reader is not support@ - it reads notices@/legal@ - but the freeze is about the Gmail API, not one mailbox,
  and a reader that keeps calling it during a freeze is exactly what the file exists to prevent. It exits 2 rather
  than reporting a clean pass it did not perform, so its absence from the ledger reads as "frozen", never "no
  requests". Missing this gate was found on 2026-11-04 while driving the erasure register: the file had existed
  since 2026-11-03 14:47 and this script was still reading mailboxes.
"""
import hashlib, json, os, re, sys, time, base64, html, subprocess, datetime, email.utils, urllib.request
from google.oauth2 import service_account
from googleapiclient.discovery import build

# ONE kill file for every Gmail reader, imported rather than re-declared so the path cannot drift (see
# credit_verify/proof/gmail_kill.py: the constant is never an env var, because a kill path the environment can move
# is a bypass). Called as a function so tests can repoint the module attribute.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from credit_verify.proof import gmail_kill

KEY = "/root/.config/gogcli/sa-YUBtdXNvLmFp.json"
HOME = "/root/fmc1-intake"
LEDGER = f"{HOME}/ledger.json"
REGISTER_IDS = f"{HOME}/register-ids.txt"  # id prefixes already on the cs register (pushed by the lane)
ACK_START = f"{HOME}/ack-start.txt"   # epoch ms; only threads whose FIRST message is after it get an ack
PAGE_START = f"{HOME}/page-start.txt"  # epoch ms; only threads whose FIRST message is after it page #cs_priority
PAGE_CLASSES = ("dmca_takedown", "legal_threat", "privacy_erasure", "security")
SLACK_CHANNEL = "C0BBTAVP44X"  # #cs_priority (same channel + bot as the hydra rights-holder watchdog)
SLACK_MENTIONS = ("U038BM16T7W",)  # Jan (owns legal intake; Nick removed 2026-10-23, MUS-18475)
# DSP / distributor / label senders (firstmate 961): a takedown from these is a rights-holder takedown even if the
# wording misses the keyword rules. Boundary match on the sender's domain.
DSP_SENDER = re.compile(r"@(?:[\w-]+\.)*(spotify\.com|tidal\.com|apple\.com|distrokid\.com|tunecore\.com|cdbaby\.com|believe\.com|"
                        r"believedigital\.com|theorchard\.com|ingrooves\.com|awal\.com|unitedmasters\.com|amuse\.io|ditto\.fm|"
                        r"routenote\.com|symphonicdistribution\.com|emubands\.com|landr\.com|onerpm\.com|fuga\.com|repost\.network|"
                        r"vydia\.com|sonosuite\.com|ninjatune\.net)>?\s*$", re.I)
PRIVACY_SERVICES = re.compile(r"(incogni|yoursuspect|removeyourmedia|optery|deleteme|kanary|privacybee|onerep)", re.I)
NO_ACK_FROM = re.compile(r"(@muso\.ai|no-?reply|mailer-daemon|postmaster|notifications?@)", re.I)
# Copy pack APPROVED by the captain 2026-10-21 20:5xZ (firstmate 916.3): A privacy, B DMCA, C credit, D security.
# E (legal threat) only after the captain's packet, by a human; F spam/other = no ack.
ACK = {
 "privacy_erasure": "Hello,\n\nThank you for your request of {received}. We have recorded it as a request to remove your personal data and the public pages that refer to you{links}. As a first step, we are removing these pages from search on Muso, and we will complete your request and confirm in writing by {due}.\n{extra}\nMuso.AI Support",
 "dmca_takedown": "Hello,\n\nThank you for your notice of {received}{links_about}. We have recorded it and are reviewing it under our copyright process. We will reply on this thread once it has been reviewed. If you have not already included it, please add the statement that you are the rights holder or authorised to act for them, and your contact details.\n\nMuso.AI Support",
 "credit_dispute": "Hello,\n\nThank you for your message about {about}. We have passed it to our credits team, who will review it and reply on this thread. Nothing else is needed from you right now.\n\nMuso.AI Support",
 "security": "Hello,\n\nThank you for your report about \"{subject}\". We have passed it to our engineering team, who will verify it. We will let you know on this thread once it has been reviewed.\n\nMuso.AI Support",
}


def send_ack(to, subject, body):
    """gog from support@ (node-8). Returns the Gmail message id, or '' on failure."""
    os.umask(0o077)
    f = f"{HOME}/ack-body-{os.getpid()}.txt"
    open(f, "w").write(body)
    try:
        # Fixed shell text only; inbound-controlled values travel as argv, never inside a shell string.
        argv = ["bash", "-c", 'set -a; . /etc/openclaw/main.env; set +a; exec gog "$@"', "gog",
                "gmail", "send", "--account", "support@muso.ai", "--to", to,
                "--subject", subject, "--body-file", f, "--json"]
        out = subprocess.run(argv, capture_output=True, text=True, timeout=120).stdout
        return (json.loads(out or "{}").get("messageId") or "")
    except Exception:
        return ""
    finally:
        os.unlink(f)


BOXES = [("kyran@muso.ai", "notices@muso.ai"), ("aaron@muso.ai", "legal@muso.ai")]

RULES = [
    ("legal_threat", r"\b(cnil|ico\b|data protection authority|supervisory authority|attorney|lawyer|avocat|counsel|legal action|lawsuit|court|subpoena|mise en demeure|formal notice|cease and desist|cease & desist|saisine)\b"),
    ("security", r"\b(vulnerabilit|security researcher|bug bounty|xss|csrf|session (fixation|invalidat)|exploit)"),
    ("dmca_takedown", r"\b(dmca|takedown|take down|taken down|copyright infringement|copyright-protected|infring|content removal|removed from (spotify|tidal|apple music|all stores|stores|dsps?))"),
    # A request that asks for BOTH a copy and a deletion is an ERASURE request with an access
    # component, not an access request. Taking only the access path drops the deletion entirely:
    # the pipeline's ACCESS decision performs no hide and sets no hide deadline, so the customer's
    # erasure obligation disappears (QA 2026-11-08). This rule must sit ABOVE privacy_access, and
    # its erasure half is deliberately the DELETION vocabulary only -- not the generic
    # "gdpr|privacy|personal data" terms, which every access request also contains. `[\s\S]`
    # rather than `.` because classify() searches the subject and body joined by a newline.
    ("privacy_erasure", r"(?=[\s\S]*\b(article ?15\b|art\.? ?15\b|right of access|subject access request|copy of (my|the|all) (personal )?data|access (to )?(my|the) (personal )?data|export (my|all my|the) (personal )?data|send me (a copy of )?(my|all my) (personal )?data|what (personal )?data (do )?you (hold|have|store|keep)))(?=[\s\S]*\b(erasure|effacement|right to be forgotten|article ?17|art\.? ?17|delete my (profile|data|account)|remove my (profile|name|data)))"),
    # ACCESS BEFORE ERASURE, and it has to be: every access request says "GDPR" and "personal data",
    # so without this rule an Art.15 request ("send me a copy of my data") classified as
    # privacy_erasure and the pipeline HID the requester's pages -- destroying data for someone who
    # only asked to see it. Measured 2026-11-07: all four access phrasings below returned
    # privacy_erasure. The rule is deliberately narrow (it needs an access verb or "Article 15"),
    # so "delete my data" and "remove my profile" still fall through to privacy_erasure.
    ("privacy_access", r"\b(article ?15\b|art\.? ?15\b|right of access|subject access request|copy of (my|the|all) (personal )?data|access (to )?(my|the) (personal )?data|export (my|all my|the) (personal )?data|send me (a copy of )?(my|all my) (personal )?data|what (personal )?data (do )?you (hold|have|store|keep))"),
    ("privacy_erasure", r"\b(gdpr|rgpd|lgpd|ccpa|tdpsa|erasure|effacement|right to be forgotten|article 17|art\. ?17|personal data|données personnelles|privacy|delete my (profile|data|account)|remove my (profile|name|data)|data protection)"),
    ("credit_dispute", r"\b(credit|credits|profile|merge|misattribut|wrong (artist|name))"),
    ("spam", r"\b(unsubscribe|for your (grammy|consideration)|newsletter|webinar|seo|backlinks|testflight)"),
]
ID_RE = re.compile(r"muso\.ai/(profile|track|album)/([0-9a-f]{8})[0-9a-f-]*")


def svc(subject, scope):
    c = service_account.Credentials.from_service_account_file(KEY, scopes=[f"https://www.googleapis.com/auth/{scope}"], subject=subject)
    return build("gmail", "v1", credentials=c, cache_discovery=False)


def text(p):
    if p.get("mimeType") == "text/plain" and p.get("body", {}).get("data"):
        return base64.urlsafe_b64decode(p["body"]["data"] + "==").decode("utf8", "replace")
    for q in p.get("parts") or []:
        r = text(q)
        if r:
            return r
    if p.get("mimeType") == "text/html" and p.get("body", {}).get("data"):
        return re.sub(r"<[^>]+>", " ", html.unescape(base64.urlsafe_b64decode(p["body"]["data"] + "==").decode("utf8", "replace")))
    return ""


# The deletion vocabulary, on its own, so a match can be checked for a NEGATOR in front of it (QA #1847
# Critical). "Do not delete my profile" says the opposite of "delete my profile", and a regex that only
# looks for the words cannot tell them apart.
_DELETION_PHRASE = (r"(?:erasure|effacement|right to be forgotten|article ?17|art\.? ?17|"
                    r"delete my (?:profile|data|account)|remove my (?:profile|name|data))")
_DELETION_RX = re.compile(_DELETION_PHRASE)
# The access vocabulary, kept separate from RULES for the same reason: the combined rule is recognised by BOTH
# vocabularies being present, not by a pattern object's identity. Every entry in RULES must stay a plain string
# literal, because scripts/gdpr_pipeline/intake.py re-reads that list with ast.literal_eval.
_ACCESS_RX = re.compile(
    r"(?:article ?15\b|art\.? ?15\b|right of access|subject access request|"
    r"copy of (?:my|the|all) (?:personal )?data|access (?:to )?(?:my|the) (?:personal )?data|"
    r"export (?:my|all my|the) (?:personal )?data|"
    r"send me (?:a copy of )?(?:my|all my) (?:personal )?data|"
    r"what (?:personal )?data (?:do )?you (?:hold|have|store|keep))")
# Within this many characters BEFORE the phrase. Wide enough for "please do not delete my profile" and
# "without removing my name", narrow enough that a negator in the previous sentence is not read as
# negating this one.
# A withdrawal is often not phrased as "delete my profile". "Please do not delete anything" names the ACT without
# naming the object, so the scoped vocabulary above cannot see it - and the inherited subject carried the rest.
# Inflected on purpose: "I want my profile removed" names the duty even though the word is not "remove".
# A bare `remove\b` missed it, so `requests_access` fell through to the inherited subject and filed an
# access row nothing asked for (QA #1847 r6).
_BARE_DELETION_RX = re.compile(r"\b(?:delet\w*|eras\w*|remov\w*|removal)\b")
_NEGATOR_RX = re.compile(r"\b(?:do not|don'?t|never|without|no need to|not|no)\b")
# "I withdraw my erasure request" NAMES the request it is withdrawing, so the scoped deletion vocabulary sees an
# affirmative mention ("my erasure request") that is really the thing being taken back. A withdrawal verb next to a
# negated deletion is the intent.
_WITHDRAW_RX = re.compile(r"\b(?:withdraw\w*|take back|taking back|retract\w*|cancel\w*|"
                          r"no longer (?:want|wish|need)|changed my mind)\b")
_NEGATOR_WINDOW = 40
# Statement boundaries for the copy-request test: sentence punctuation, contrast words, and a spaced dash
# (people write "--", "-" or an em dash between two instructions).
_ACCESS_STATEMENT_RX = re.compile(r"(?:[;,.!?]|\bbut\b|\bhowever\b|\balthough\b|\s[-\u2013\u2014]+\s)")
# Where one clause ends and the next begins. A negator does not reach past one of these: "do not delete my
# tracks, BUT please delete my profile" is a deletion request, and so is "I have not heard back. Please
# delete my profile." Without this the window is just characters, and a negator in the previous clause
# disarmed the demand in the next one.
_CLAUSE_BREAK_RX = re.compile(r"(?:[,;.!?]|\bbut\b|\bhowever\b|\balthough\b|\bso\b|\bthen\b)")
# A withdrawal needs its own break set: a spaced dash separates two demands just as well as a semicolon, and
# "I cancel my complaint - please delete my profile." is the same shape as the semicolon version (QA #1847 r8).
# Kept separate so widening it here cannot move the negation windows the deletion/access rules depend on.
_WITHDRAWAL_BREAK_RX = re.compile(r"(?:[,;.!?]|\s[-\u2013\u2014]\s|\band\b|\bbut\b|\bhowever\b|\balthough\b|\bso\b|\bthen\b)")


_WITHDRAWAL_OF_RX = re.compile(
    r"\b(?:withdraw\w*|withdrew|take\s+back|taking\s+back|retract\w*|cancel\w*)\s+"
    r"(?:my\s+|the\s+|this\s+|that\s+|our\s+)?"
    r"(?:erasure|deletion|request|demand|application|complaint)\b")


def withdrawal_of_request(body: str) -> bool:
    """Does this message explicitly withdraw a REQUEST? (QA #1847 r7 Critical.)

    "I withdraw my erasure request." names no negation, so `withdrawn_in_body` did not see it; the inherited
    "Re: Article 17 erasure request" subject then carried the deletion phrase and a withdrawal on a thread
    whose row was already closed filed a FRESH erasure row, so the hide path could act against the very
    instruction that cancelled it.

    Deliberately narrow: the verb must be followed by a request noun. "I want to cancel my subscription and
    delete my profile" is a deletion demand, not a withdrawal, and must stay an erasure.
    """
    return bool(_WITHDRAWAL_OF_RX.search((body or "").lower()))


def withdrawal_cancels(body: str) -> bool:
    """Does the withdrawal in this message cancel the WHOLE message? (QA #1847 r8 Important.)

    `withdrawal_of_request` answers "is a request being withdrawn"; it cannot tell whether anything else is
    being ASKED. "I withdraw my complaint; please delete my profile." withdraws a complaint we do not track
    and then makes a live Art. 17 demand -- the demand survives the withdrawal. The old rule short-circuited
    on the word "complaint" and returned `other`, so the deletion got no erasure row, no 24-hour hide clock,
    no statutory response deadline, and the digest paged a human saying nothing new had been filed.

    Only a demand in a LATER CLAUSE survives. "I take back my request to remove my profile." names the
    deletion as the OBJECT of the withdrawal, in the same clause, so the whole message is a withdrawal.
    """
    text = (body or "").lower()
    m = _WITHDRAWAL_OF_RX.search(text)
    if m is None:
        return True
    after = text[m.end():]
    for dm in _DELETION_RX.finditer(after):
        # Same clause as the withdrawal verb: this phrase is what is being withdrawn, not a new demand.
        if not _WITHDRAWAL_BREAK_RX.search(after[:dm.start()]):
            continue
        clause = after[max(0, dm.start() - _NEGATOR_WINDOW):dm.start()]
        breaks = list(_WITHDRAWAL_BREAK_RX.finditer(clause))
        if breaks:
            clause = clause[breaks[-1].end():]
        if not _NEGATOR_RX.search(clause):
            return False
    return True


def affirmative_access(s: str) -> bool:
    """Is there a copy request in here that is NOT negated? (QA #1847 r7 Important.)

    `_ACCESS_RX.search` alone matched "Do not send me a copy of my data; please delete my profile." and the
    dual-duty paths then filed a privacy_access row and deadline for a response the customer explicitly
    refused. One affirmative mention is enough, exactly like the deletion rule.
    """
    # A negator belongs to the phrase it precedes. "Never delete my account - I only want a copy of my
    # personal data." is an affirmative copy request, but a flat window before "copy" reaches back over
    # "never" and negates it. So the window stops at the last clause break AND at the end of the last
    # deletion mention inside it: a negator that already did its work on a deletion cannot also negate the
    # copy request that follows.
    for m in _ACCESS_RX.finditer(s):
        start = max(0, m.start() - _NEGATOR_WINDOW)
        clause = s[start:m.start()]
        breaks = list(_CLAUSE_BREAK_RX.finditer(clause))
        if breaks:
            clause = clause[breaks[-1].end():]
        cut = 0
        for rx in (_DELETION_RX, _BARE_DELETION_RX):
            for dm in rx.finditer(clause):
                cut = max(cut, dm.end())
        clause = clause[cut:]
        if not _NEGATOR_RX.search(clause):
            return True
    return False


def affirmative_deletion(s: str) -> bool:
    """Is there a deletion demand in here that is NOT negated?

    One affirmative mention is enough: "do not delete my tracks, but delete my profile" is a deletion
    request. The bug this closes is the opposite case - every mention negated - where the combined rule
    still classified the message as privacy_erasure and the pipeline could take the HIDE path against an
    explicit instruction not to delete anything (QA #1847 Critical, reproduced with
    "Please send me a copy of my data. Do not delete my profile.").
    """
    for m in _DELETION_RX.finditer(s):
        clause = s[max(0, m.start() - _NEGATOR_WINDOW):m.start()]
        # Keep only the text after the LAST clause break: the negator has to be in THIS clause to negate it.
        breaks = list(_CLAUSE_BREAK_RX.finditer(clause))
        if breaks:
            clause = clause[breaks[-1].end():]
        if not _NEGATOR_RX.search(clause):
            return True
    return False


def withdrawn_in_body(body: str) -> bool:
    """The customer's CURRENT message refuses deletion, whatever the subject line still says.

    A reply inherits the thread's subject, so `Re: GDPR Article 17 erasure request` supplies deletion vocabulary the
    customer is no longer asking for. With the body `Do not delete my profile. I withdraw my request.` the subject
    alone kept the message classified as an erasure and the register reported it as already handled - so a withdrawal
    was invisible and the pipeline would still hide the page (QA #1847).
    """
    b = (body or "").lower()
    if not b:
        return False
    # A NEGATOR immediately before a deletion word IS the withdrawal. Testing "no affirmative deletion anywhere"
    # instead would reclassify every legitimate request whose object the scoped vocabulary does not name -
    # "please delete my tracks" has no `delete my (profile|data|account)` match, and 14 tests caught exactly that.
    negated = False
    for m in _BARE_DELETION_RX.finditer(b):
        clause = b[max(0, m.start() - _NEGATOR_WINDOW):m.start()]
        breaks = list(_CLAUSE_BREAK_RX.finditer(clause))
        if breaks:
            clause = clause[breaks[-1].end():]
        if _NEGATOR_RX.search(clause):
            negated = True
            break
    if not negated:
        return False
    # A negated deletion settles it UNLESS the body also contains an affirmative demand - and even then an explicit
    # withdrawal verb ("I take back my request to remove my profile") outranks that mention, because the mention names
    # the request being withdrawn.
    return True if _WITHDRAW_RX.search(b) else not affirmative_deletion(b)


def withdrawal_signal(body: str) -> bool:
    """The CURRENT message withdraws, whether or not it also names a deletion.

    `withdrawn_in_body` needs a NEGATED DELETION WORD, so it cannot see "I withdraw my request. Please stop
    processing it." -- the verb is there, the deletion word is not, because the request being withdrawn is named
    in the inherited subject (QA #1847 r5).

    `classify` must NOT act on this: on its own "I withdraw my complaint" is not a privacy signal, and a bare
    withdrawal verb says nothing about WHICH duty is being cancelled. Only a caller that can see the open row
    may act on it, which is the support@ triage bridge.
    """
    return bool(_WITHDRAW_RX.search((body or "").lower()))


def requests_access(subject: str, body: str) -> bool:
    """Does the CURRENT message ask for a copy, in addition to whatever else it asks for?

    On a reply the subject belongs to the OLD message: "Re: Article 15 access request" answered with
    "Please delete my profile." is a deletion, not a fresh Art.15 demand. Reading the inherited subject
    here created an access duty and deadline nobody asked for (QA #1847 r6). The subject is consulted only
    when the body is silent about which duty it wants.
    """
    b = (body or "").lower()
    if affirmative_access(b):
        return True
    if _DELETION_RX.search(b) or _BARE_DELETION_RX.search(b):
        return False
    return affirmative_access(f"{subject or ''}\n{b}".lower())


_INHERITED_SUBJECT_RX = re.compile(r"^\s*(?:(?:re|fw|fwd|aw|sv)\s*:\s*)+", re.IGNORECASE)


def inherited_subject(subject: str) -> bool:
    """Is this subject carried over from an earlier message rather than written for this one?

    Every mail client prefixes a reply ("Re:", "RE:", "Fwd:", "AW:" for German Outlook, "SV:" for Swedish).
    When it is, the subject describes the request the thread STARTED with, so it cannot on its own say what
    the message we are reading asks for.
    """
    return bool(_INHERITED_SUBJECT_RX.match(subject or ""))


def classify(subject, body):
    s = f"{subject}\n{body}".lower()
    # The body outranks the inherited subject: a refusal in the message we are reading is the current intent.
    if withdrawn_in_body(body) or withdrawal_of_request(body):
        if affirmative_access(body.lower()):
            return "privacy_access"
        if withdrawal_cancels(body):
            return "other"
        # A withdrawal that names a duty we do not track, followed by a live demand in its own clause,
        # cancels nothing we hold. Fall through so the rules file that demand (QA #1847 r8).
    # An INHERITED subject cannot start a duty on its own (QA #1847 r6 Critical). "Re: Article 17 erasure
    # request" answered with "Please send me a copy of my data." is an access-only reply, but the subject
    # supplied the affirmative deletion phrase and the whole message read as erasure -- so the hide path
    # could run against a customer who asked, in this message, only for a copy. When the subject is a reply
    # and the BODY makes no affirmative deletion demand, the body decides.
    b = body.lower()
    if inherited_subject(subject) and not affirmative_deletion(b) and affirmative_access(b):
        return "privacy_access"
    for cls, rx in RULES:
        if not re.search(rx, s):
            continue
        # The COMBINED rule (an access phrase AND an erasure phrase) must sit above privacy_access so a
        # genuinely mixed request keeps its deletion half. But it must not fire when every deletion mention
        # is negated: that message asks for a COPY and explicitly refuses deletion, so the access reader
        # owns it and nothing may be hidden.
        # EVERY erasure path, not just the combined one (QA #1847 r3: "Do not delete my profile" matches the
        # generic erasure rule too). A message that mentions deletion only to refuse it is not an erasure
        # request at all: if it also asks for a copy it is an access request, and if it does neither it is a
        # human's to read. A message with NO deletion phrase keeps whatever the rules said, so nothing else moves.
        if cls == "privacy_erasure" and _DELETION_RX.search(s) and not affirmative_deletion(s):
            return "privacy_access" if affirmative_access(s) else "other"
        return cls
    return "other"


def slack_token():
    """The operations bot token from node-8's /etc/openclaw/main.env (never printed)."""
    for line in open("/etc/openclaw/main.env"):
        if line.startswith("MUSO_SLACK_BOT_TOKEN_OPERATIONS="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def esc(s):
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


REPLY_PREFIX = re.compile(r"^\s*(?:re|fwd?|aw|tr)\s*:\s*", re.I)


def notice_key(cls, subject, ids, body=""):
    """Same notice sent from several addresses: class + normalised subject + linked Muso ids; with no
    ids, also a fingerprint of the first message body (two ID-less claims under one generic subject
    are two notices). A hash, never the subject or body (the ledger holds no message content)."""
    subj = subject or ""
    while REPLY_PREFIX.match(subj):
        subj = REPLY_PREFIX.sub("", subj, count=1)
    subj = " ".join(subj.split()).lower()
    raw = f"{cls}|{subj}|{','.join(ids)}"
    if not ids:
        raw += "|" + " ".join((body or "").split()).lower()
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def page_text(alias, cls, h0, ids, row):
    name, addr = email.utils.parseaddr(h0.get("from", ""))
    mention = " ".join(f"<@{m}>" for m in SLACK_MENTIONS)
    label = {"dmca_takedown": "Takedown / copyright", "legal_threat": "LEGAL threat (no auto-ack; captain)",
             "privacy_erasure": "Privacy / GDPR erasure", "security": "Security report"}[cls]
    ack = ("auto-ack sent" if row.get("acked") else ("no ack (legal: captain)" if cls == "legal_threat" else "no ack yet"))
    muso = ", ".join(i for i in ids[:6]) or "none linked"
    return (f"{mention}  :rotating_light: *{alias} inbound: {label}*\n"
            f"From: {esc(f'{name[:60]} <{addr}>' if name else addr)}\nSubject: {esc(h0.get('subject', ''))[:140]}\n"
            f"Muso ids: {esc(muso)} · on removal register: {'yes' if row.get('on_register') else 'NO'} · {ack}\n"
            f"Gmail thread `{row['thread']}` (cs-systemic intake; this mailbox does NOT reach Intercom)")


def post_page(token, text_, thread_ts=None):
    payload = {"channel": SLACK_CHANNEL, "text": text_, "unfurl_links": False}
    if thread_ts:
        payload["thread_ts"] = thread_ts
    req = urllib.request.Request("https://slack.com/api/chat.postMessage",
                                 data=json.dumps(payload).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json; charset=utf-8"})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    return r.get("ts") if r.get("ok") else ""


def ensure_label(g, name, cache):
    if name in cache:
        return cache[name]
    for l in g.users().labels().list(userId="me").execute().get("labels", []):
        cache[l["name"]] = l["id"]
    if name not in cache:
        cache[name] = g.users().labels().create(userId="me", body={"name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"}).execute()["id"]
    return cache[name]


def frozen() -> int:
    """0 = go, 2 = refuse. FIRST thing main() does, before a token, a ledger read or any Gmail call.

    The path and the check are read from the shared module at CALL time, so this refuses on exactly the file the other
    readers refuse on - a second copy of the constant in this file is how a freeze gets a hole.
    """
    if gmail_kill.gmail_readers_disabled():
        print(f"ERROR frozen: {gmail_kill.GMAIL_READERS_KILL} exists, so every Gmail reader is stopped. This reader "
              f"reads "
              f"notices@/legal@ through the same API, so it refuses instead of reporting a clean run it did not "
              f"perform: nothing was read, nothing was labelled, nothing was acked, the ledger is untouched.")
        return 2
    return 0


def main():
    _frozen = frozen()
    if _frozen:
        sys.exit(_frozen)
    days = int(sys.argv[sys.argv.index("--since-days") + 1]) if "--since-days" in sys.argv else 2
    do_label = "--label" in sys.argv
    do_ack = "--ack" in sys.argv
    ack_start = int(open(ACK_START).read().strip()) if os.path.exists(ACK_START) else 0
    do_page = "--page" in sys.argv
    page_start = int(open(PAGE_START).read().strip()) if os.path.exists(PAGE_START) else 0
    stok = slack_token() if do_page else ""
    if do_page and not stok:
        print("ERROR page: no Slack token")
        failed_page_token = True
    else:
        failed_page_token = False
    os.makedirs(HOME, exist_ok=True)
    os.umask(0o077)
    ledger = json.load(open(LEDGER)) if os.path.exists(LEDGER) else {}
    reg = set(open(REGISTER_IDS).read().split()) if os.path.exists(REGISTER_IDS) else set()
    failed = 0
    new = 0
    for mailbox, alias in BOXES:
        try:
            g = svc(mailbox, "gmail.modify" if do_label else "gmail.readonly")
            tids, page = set(), None
            while True:
                r = g.users().messages().list(userId="me", q=f"deliveredto:{alias} newer_than:{days}d", maxResults=100, pageToken=page).execute()
                tids.update(m["threadId"] for m in r.get("messages", []))
                page = r.get("nextPageToken")
                if not page:
                    break
            labels = {}
            for tid in sorted(tids):
                t = g.users().threads().get(userId="me", id=tid, format="full").execute()
                msgs = t["messages"]
                h0 = {x["name"].lower(): x["value"] for x in msgs[0]["payload"]["headers"]}
                bodies = " ".join(text(m["payload"]) for m in msgs)
                # "replied by us" = a message FROM us TO someone outside muso.ai. An internal forward (e.g. to
                # Jan) is not a reply: on 10-20 a DMCA forward to jan@ marked the notice answered and it was never acked.
                def _h(m):
                    return {x["name"].lower(): x["value"] for x in m["payload"]["headers"]}
                ours = any(re.search(r"@muso\.ai|intercom", _h(m).get("from", ""), re.I)
                           and re.search(r"@(?!muso\.ai)[\w-]+\.", _h(m).get("to", "") + "," + _h(m).get("cc", ""), re.I)
                           for m in msgs[1:])
                cls = classify(h0.get("subject", ""), bodies)
                if cls not in ("legal_threat", "dmca_takedown") and DSP_SENDER.search(h0.get("from", "")) and \
                        re.search(r"\b(remov|take ?down|taken down|withdraw|delete|copyright)", h0.get("subject", "") + " " + bodies[:3000], re.I):
                    cls = "dmca_takedown"
                ids = sorted({f"{k}:{v}" for k, v in ID_RE.findall(bodies)})
                key = f"{alias}:{tid}"
                row = ledger.get(key) or {"first_seen": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime())}
                if key not in ledger:
                    new += 1
                row.update({"alias": alias, "thread": tid, "class": cls, "msgs": len(msgs), "replied_by_us": ours,
                            "first_msg": msgs[0].get("internalDate"), "last_msg": msgs[-1].get("internalDate"),
                            "ids": ids, "on_register": any(i.split(":")[1] in reg for i in ids),
                            "last_seen": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime())})
                # Ledgered before any side effect: row is mutated in place, so a later failure (e.g. the label
                # call) still persists the confirmed acked/paged markers instead of re-sending next run.
                ledger[key] = row
                # Both dedupe arms below need the notice identity (hash of class + normalised subject + ids;
                # ID-less notices also hash the FIRST message body, never `bodies`, which grows with replies).
                nkey = notice_key(cls, h0.get("subject", ""), ids, text(msgs[0]["payload"]))
                row["notice_key"] = nkey
                # One ack + one page per REQUEST, not per thread: the same sender writing to notices@ AND legal@
                # (notices@ is also auto-forwarded to aaron@) or sending twice within 3 days is one request.
                # 2026-10-23: a DMCA sender got 4 identical acks + 4 pages before this key existed.
                name2, sender_raw = email.utils.parseaddr(h0.get("from", ""))
                sender_addr = sender_raw.lower()
                req_key = f"{sender_addr}|{cls}"
                fm = int(msgs[0].get("internalDate", 0))
                # A sibling is the same request only if it is the same notice (same notice_key). When identity
                # is uncertain we page (MUS-20285): a row with a different key, or a legacy row written before
                # notice_key existed, never suppresses a new claim; a duplicate beats a silent legal notice.
                siblings = [r for k, r in ledger.items() if k != key and r.get("req_key") == req_key
                            and abs(int(r.get("first_msg") or 0) - fm) < 3 * 86400000
                            and r.get("notice_key") == nkey]
                row["req_key"] = req_key
                # Each decision inherits from a sibling holding the CONFIRMED marker, not just the first match
                # (hydra#1361 bot NO-GO @25fd96a): a failed ack/page on an earlier sibling must not hide a later success.
                ack_sib = next((r for r in siblings if r.get("acked")), None)
                page_sib = next((r for r in siblings if r.get("paged")), None)
                if ack_sib is not None and not row.get("acked"):
                    row["acked"] = True; row["ack_ref"] = "dup-of:" + str(ack_sib.get("ack_ref"))
                if page_sib is not None and not row.get("paged"):
                    row["paged"] = "dup-of:" + str(page_sib.get("paged"))
                # Second arm: the SAME notice from a different address (2026-10-23: david@demandage.com and
                # demandage@gmail.com, 36 s apart, same four profiles). Needs linked Muso ids: without them
                # two senders with the same subject are two unrelated takedowns.
                nsib = None
                if ids and not row.get("paged"):
                    nsib = next((r for k, r in ledger.items() if k != key and r.get("notice_key") == nkey
                                 and abs(int(r.get("first_msg") or 0) - fm) < 3 * 86400000
                                 and r.get("paged") and not str(r.get("paged")).startswith("dup-of:")), None)
                if nsib is not None:
                    note_ts = ""
                    if do_page and stok:
                        mention = " ".join(f"<@{m}>" for m in SLACK_MENTIONS)
                        earlier = (nsib.get("req_key") or "|").rsplit("|", 1)[0] or "earlier sender"
                        # Same class + subject + ids can still be two rights holders: keep the second page
                        # actionable (MUS-20040) instead of claiming nothing is needed.
                        note = (f"{mention} Same subject + same Muso ids, different sender - confirm this is the same claim, "
                                f"or handle it separately.\n"
                                f"Earlier: {esc(earlier)} (thread `{nsib.get('thread')}`)\n"
                                f"New: {esc(f'{name2[:60]} <{sender_addr}>' if name2 else sender_addr)} (thread `{tid}`)\n"
                                f"Not paged again; nothing was auto-closed.")
                        try:
                            note_ts = post_page(stok, note, thread_ts=nsib["paged"])
                        except Exception:
                            note_ts = ""
                    if note_ts:
                        row["paged"] = "dup-of:" + str(nsib["paged"])
                    elif do_page and stok:
                        # The note is the only actionable signal for a possibly-different rights holder
                        # (MUS-20040), so a failed note is never ledgered as paged (MUS-20075): leaving
                        # `paged` unset makes the page block below post a full top-level page for this
                        # thread (which counts its own failure: the run exits 2 and the 15-min cron retries).
                        # A post that landed but returned no ts can therefore page twice; for a legal
                        # notice a duplicate is the right trade against silence.
                        print(f"PAGE NOTE FAILED {alias.split('@')[0]} {tid}; falling back to a full page")
                if do_ack and not row.get("acked") and cls in ACK and ack_start and int(msgs[0].get("internalDate", 0)) > ack_start:
                    frm = h0.get("from", "")
                    to = email.utils.parseaddr(frm)[1]
                    if re.fullmatch(r"[\w.+-]+@[\w-]+\.[\w.]+", to) and not NO_ACK_FROM.search(to):
                        rec = datetime.datetime.utcfromtimestamp(int(msgs[0]["internalDate"]) / 1000)
                        due = (rec + datetime.timedelta(days=30)).strftime("%-d %B %Y")
                        links = ", ".join("https://muso.ai/" + i.replace(":", "/") + "…" for i in ids[:6])
                        extra = ("\nBecause you are writing on behalf of someone else, please send us their written authorisation to act for them.\n"
                                 if PRIVACY_SERVICES.search(frm + " " + bodies[:2000]) else
                                 ("\nSo we act on the right pages, please reply with the link(s) to the Muso page(s) concerned.\n" if not ids else ""))
                        body = ACK[cls].format(received=rec.strftime("%-d %B %Y"), due=due, links=(" (" + links + ")") if ids else "",
                                               extra=extra, links_about=(" about " + links) if ids else "",
                                               about=links if ids else "your Muso profile", subject=h0.get("subject", "")[:120])
                        subj = h0.get("subject", "")
                        mid = send_ack(to, subj if subj.lower().startswith("re:") else "Re: " + subj, body)
                        row["acked"] = bool(mid); row["ack_ref"] = mid
                        print(f"ACK {'sent' if mid else 'FAILED'} {alias.split('@')[0]} {tid} {cls} {mid}")
                        if not mid:
                            failed += 1
                if (do_page and stok and not row.get("paged") and cls in PAGE_CLASSES and page_start
                        and int(msgs[0].get("internalDate", 0)) > page_start
                        and not re.search(r"@muso\.ai", h0.get("from", ""), re.I)):  # DSP noreply senders DO page
                    try:
                        ts = post_page(stok, page_text(alias, cls, h0, ids, {**row, "thread": tid}))
                    except Exception:
                        ts = ""
                    if ts:
                        row["paged"] = ts  # only a CONFIRMED post is ledgered; a failed one retries next run
                        print(f"PAGE sent {alias.split('@')[0]} {tid} {cls}")
                    else:
                        failed += 1
                        print(f"PAGE FAILED {alias.split('@')[0]} {tid} {cls}")
                if do_label:
                    want = [ensure_label(g, f"OpenClaw/{cls}", labels)]
                    if not ours:
                        want.append(ensure_label(g, "OpenClaw/unanswered", labels))
                    g.users().threads().modify(userId="me", id=tid, body={"addLabelIds": want}).execute()
                    row["labelled"] = True
        except Exception as e:
            failed += 1
            print(f"ERROR {alias}: {str(e)[:160]}")
    if failed_page_token:
        failed += 1
    json.dump(ledger, open(LEDGER, "w"))
    if "--report" in sys.argv or new:
        from collections import Counter
        c = Counter((r["alias"].split("@")[0], r["class"]) for r in ledger.values())
        un = Counter((r["alias"].split("@")[0], r["class"]) for r in ledger.values() if not r["replied_by_us"])
        offreg = sum(1 for r in ledger.values() if r["class"] in ("privacy_erasure", "dmca_takedown", "legal_threat") and not r["on_register"])
        print(f"intake: {len(ledger)} threads ({new} new); by class {dict(c)}; unanswered {dict(un)}; removal/legal threads NOT on register: {offreg}; labels={'on' if do_label else 'off'}")
    sys.exit(2 if failed else 0)


if __name__ == "__main__":
    main()
