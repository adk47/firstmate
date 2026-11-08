"""Intake parsers: one per channel, one candidate shape (cs-systemic-c3 `register-intercom-intake-1101.md`). PURE.

Channels and their row keys (the key is the idempotence test, store.erasure_keys):
  Intercom data-deletion tickets (ClickUp list 901000600160, tag action:data-deletion; Caroline files one per
      request)                                    -> intercom:<conversation_id> (+ clickup:<task_id>)
  Intercom conversations (search, erasure class)  -> intercom:<conversation_id>
  notices@ / legal@ (legal-intake ledger)         -> gmail:<alias>:<thread>
  support@ (support-intake ledger)                -> gmail:support@muso.ai:<thread>
  the markdown register (rows 1-39)               -> register:<n> (+ the channel key it names)

The class predicate is QUOTED from scripts/legal-intake.py (its RULES / PRIVACY_SERVICES literals are read
from that file's AST, so there is exactly one copy and it is never paraphrased here).
"""
from __future__ import annotations

import ast
import json
import re
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
URL_ID_RE = re.compile(r"(?:muso\.ai|credits\.muso\.ai)/(profile|track|album)/(" + UUID + ")", re.I)
CONV_RE = re.compile(r"/conversation/(\d{12,18})")
SESSION_CONV_RE = re.compile(r":conversation:(\d{12,18})")
ACTION_RE = re.compile(r"---ACTION-REQUEST---\s*(\{.*?\})\s*---END-ACTION-REQUEST---", re.S)
EMAIL_RE = re.compile(r"^[\w.+-]+@[\w-]+(\.[\w-]+)+$")
LEGAL_INTAKE = Path(__file__).resolve().parents[1] / "legal-intake.py"
ERASURE_CLASSES = ("privacy_erasure", "legal_threat", "dmca_takedown")
# Every class the upstream mail ledgers legitimately carry. A class OUTSIDE this set is not "not an erasure" - it is a
# class this pipeline has never seen, and filtering it out silently is how a collaborating lane's new kind (a notices@
# `objection`, a name-removal) disappears while the tick stays green. A row that is not reliably classifiable is a
# SOURCE FAILURE (exit 2), never a silent skip. Counted live on 2026-11-04: ledger.json + support-ledger.json carry
# exactly these.
LEDGER_CLASSES = ERASURE_CLASSES + ("privacy_access", "not_erasure", "cancel_intent_mentions_deletion",
                                    "credit_dispute", "other", "security", "spam")
# Phrases that make a request MORE restrictive (ask for authorisation), never less: text can only hold a hide.
REPRESENTATIVE_RE = re.compile(r"\b(on behalf of|my client|our client|i represent|we represent|acting for|"
                               r"power of attorney|authori[sz]ed (agent|representative))\b", re.I)


def _legal_intake_literals() -> tuple[list[tuple[str, str]], str]:
    tree = ast.parse(LEGAL_INTAKE.read_text())
    rules, privacy = None, None
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name == "RULES":
                rules = ast.literal_eval(node.value)
            elif name == "PRIVACY_SERVICES" and isinstance(node.value, ast.Call):
                privacy = ast.literal_eval(node.value.args[0])
    if not rules or not privacy:
        raise RuntimeError("legal-intake.py RULES / PRIVACY_SERVICES not found: refusing to classify")
    return rules, privacy


RULES, _PRIVACY = _legal_intake_literals()
PRIVACY_SERVICES = re.compile(_PRIVACY, re.I)


# The negation half of the combined rule, pinned equal to scripts/legal-intake.py by
# tests/test_legal_intake.py::TheTwoClassifiersAgree. This module re-reads legal-intake.py's RULES as literals so
# the two can never disagree about the VOCABULARY; the vocabulary alone cannot tell a demand from a refusal, so the
# rule is also applied here. Without this half the pipeline kept the hide path for
# "Please send me a copy of my data. Do not delete my profile." - a regex match turning an explicit instruction NOT
# to delete into an instruction to delete (QA #1847 Critical).
_DELETION_RX = re.compile(r"(?:erasure|effacement|right to be forgotten|article ?17|art\.? ?17|"
                          r"delete my (?:profile|data|account)|remove my (?:profile|name|data))")
_ACCESS_RX = re.compile(r"(?:article ?15\b|art\.? ?15\b|right of access|subject access request|"
                        r"copy of (?:my|the|all) (?:personal )?data|access (?:to )?(?:my|the) (?:personal )?data|"
                        r"export (?:my|all my|the) (?:personal )?data|"
                        r"send me (?:a copy of )?(?:my|all my) (?:personal )?data|"
                        r"what (?:personal )?data (?:do )?you (?:hold|have|store|keep))")
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
    """Is there a deletion demand in here that is NOT negated? One affirmative mention is enough."""
    for m in _DELETION_RX.finditer(s):
        clause = s[max(0, m.start() - _NEGATOR_WINDOW):m.start()]
        breaks = list(_CLAUSE_BREAK_RX.finditer(clause))
        if breaks:
            clause = clause[breaks[-1].end():]
        if not _NEGATOR_RX.search(clause):
            return True
    return False


def withdrawn_in_body(body: str) -> bool:
    """A reply inherits the thread subject, so `Re: Article 17 erasure request` supplies deletion vocabulary the
    customer is no longer asking for. The body we are reading outranks it (QA #1847)."""
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

    `withdrawn_in_body` needs a negated deletion word, which cannot see "I withdraw my request. Please stop
    processing it." -- the withdrawal verb is there and the deletion word is not, because the request being
    withdrawn is named in the inherited subject (QA #1847 r5 Critical).

    `classify` must NOT act on this: on its own "I withdraw my complaint" is not a privacy signal, and a bare
    withdrawal verb says nothing about which duty is being cancelled. Only a caller that can SEE the open row
    may act on it, which is the support@ bridge.
    """
    return bool(_WITHDRAW_RX.search((body or "").lower()))


def requests_access(subject: str, body: str) -> bool:
    """Does the CURRENT message ask for a copy? A combined request owes two duties (QA #1847).

    On a reply the subject is the OLD message's, so "Re: Article 15 access request" with a body of "Please
    delete my profile." is a deletion, not a fresh Art.15 demand. Counting the inherited subject filed an
    access row and a deadline the customer never asked for, and could queue an unwanted access response off
    a closed row (QA #1847 r6).

    The subject is consulted only when the body is itself silent about which duty it wants -- a first
    message, or a bare "any update?" on a thread that really is an access request.
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


def classify(subject: str, body: str) -> str:
    """legal-intake.py classify(), same RULES, same order, same negation rule."""
    s = f"{subject}\n{body}".lower()
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
        # The COMBINED rule (access phrase AND deletion phrase) outranks privacy_access so a genuinely mixed
        # request keeps its deletion half. It must stand down when every deletion mention is negated.
        # EVERY erasure path, not just the combined one (QA #1847 r3: "Do not delete my profile" matches the
        # generic erasure rule too). A message that mentions deletion only to refuse it is not an erasure
        # request at all: if it also asks for a copy it is an access request, and if it does neither it is a
        # human's to read. A message with NO deletion phrase keeps whatever the rules said, so nothing else moves.
        if cls == "privacy_erasure" and _DELETION_RX.search(s) and not affirmative_deletion(s):
            return "privacy_access" if affirmative_access(s) else "other"
        return cls
    return "other"


def is_representative(sender: str, text: str) -> bool:
    return bool(PRIVACY_SERVICES.search(sender or "") or PRIVACY_SERVICES.search((text or "")[:4000])
                or REPRESENTATIVE_RE.search((text or "")[:4000]))


def pages_in(text: str) -> list[dict]:
    return [{"entity": e.lower(), "id": i.lower()} for e, i in URL_ID_RE.findall(text or "")]


def iso_ms(ms) -> str:
    return datetime.fromtimestamp(int(ms) / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_s(s) -> str:
    return datetime.fromtimestamp(int(s), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cf(task: dict, name: str):
    for f in task.get("custom_fields") or []:
        if f.get("name") == name:
            return f.get("value")
    return None


def is_open_task(task: dict) -> bool:
    return (task.get("status") or {}).get("type") not in ("done", "closed")


def parse_clickup(task: dict) -> dict:
    """A data-deletion (or data-export) ticket -> candidate. The conversation, when there is one, is the request;
    the ticket is a secondary index (c3 handoff §5)."""
    desc = task.get("description") or task.get("text_content") or ""
    ar: dict = {}
    m = ACTION_RE.search(desc)
    if m:
        try:
            ar = json.loads(m.group(1))
        except json.JSONDecodeError:
            ar = {}
    conv = ""
    for src in (_cf(task, "Intercom Link") or "", desc, str(ar.get("cs_session_id") or "")):
        mm = CONV_RE.search(src) or SESSION_CONV_RE.search(src)
        if mm:
            conv = mm.group(1)
            break
    det = ar.get("details") if isinstance(ar.get("details"), dict) else {}
    pages = pages_in(desc) + pages_in(_cf(task, "Muso URL") or "")
    for key, ent in (("profiles", "profile"), ("tracks", "track"), ("albums", "album")):
        for i in det.get(key) or []:
            if re.fullmatch(UUID, str(i).lower()):
                pages.append({"entity": ent, "id": str(i).lower()})
    for i in (_cf(task, "Profile ID"), ar.get("customer_profile_id")):
        if i and re.fullmatch(UUID, str(i).strip().lower()):
            pages.append({"entity": "profile", "id": str(i).strip().lower()})
    email = str(ar.get("customer_email") or _cf(task, "User Email") or "").strip()
    if not EMAIL_RE.match(email) or email.endswith("@unknown"):
        email = ""
    name = ""
    mm = re.search(r"^Customer:\s*[^\s(]*\s*\(([^)]{2,80})\)", desc, re.M)
    if mm:
        name = mm.group(1).strip()
    summary = str(ar.get("conversation_summary") or "")
    action = str(ar.get("action_type") or "")
    tags = {t.get("name") for t in task.get("tags") or []}
    keys = ([f"intercom:{conv}"] if conv else []) + [f"clickup:{task['id']}"]
    return {
        "keys": keys, "channel": "intercom" if conv else "support",
        "clickup_ids": [task["id"]], "conversation_id": conv, "pages": pages,
        "requester_email": email, "requester_name": name,
        "received_at": iso_ms(task["date_created"]),
        "received_date_hint": str(det.get("received_date") or ""),
        "cancel_intent": summary.startswith("Rule fired: cancel_intent"),
        "request_type": str(det.get("request_type") or ""),
        "action_type": action or next((t.split(":", 1)[1] for t in tags if t and t.startswith("action:")), ""),
        "ticket_text": f"{task.get('name', '')}\n{summary}\n{det.get('customer_verbatim_request') or ''}",
    }


def last_customer_part_at(conv: dict) -> int:
    """The epoch of the conversation's LAST customer message (a new request's received_at), or its creation time."""
    parts = conv.get("parts") or []
    return int(parts[-1]["at"]) if parts and parts[-1].get("at") else int(conv.get("created_at") or 0)


def ticket_class(c: dict, customer_text: str) -> str:
    """Class of a data-deletion / data-export ticket, from the customer's own words (legal-intake RULES).

    - data-export -> privacy_access (Art. 15: no hide; a register row with a due date, captain/counsel answer)
    - a cancel_intent escalation the router filed as data-deletion: not an erasure request -- unless the customer's
      text itself matches the erasure rule, which a person reads (class kept, and the row goes to Jan)
    - legal words -> legal_threat; takedown words -> dmca_takedown; otherwise privacy_erasure (the ticket type).
    """
    if c.get("action_type") == "data-export":
        return "privacy_access"
    cls = classify("", customer_text)
    if c.get("cancel_intent"):
        return "cancel_intent_mentions_deletion" if cls == "privacy_erasure" else "not_erasure"
    if cls in ("legal_threat", "dmca_takedown"):
        return cls
    return "privacy_erasure"


def parse_gmail_ledger(ledger: dict, alias_filter=("notices@muso.ai", "legal@muso.ai"),
                       errors: list | None = None) -> list[dict]:
    """legal-intake ledger rows (ids are 8-char prefixes; no bodies) -> candidates for the erasure classes.

    A row of an UNKNOWN class is appended to `errors` - a source failure the run exits 2 on - because the alternative
    is a notices@/legal@ request vanishing while the tick reads green. A class we know and that is simply not an
    erasure request is skipped as before."""
    out = []
    for key, r in sorted(ledger.items()):
        alias = r.get("alias") or key.split(":")[0]
        if alias not in alias_filter:
            continue
        if r.get("class") not in LEDGER_CLASSES:
            if errors is not None:
                errors.append(f"{alias} row {key} ({r.get('class')}): not a class this pipeline knows "
                              f"({', '.join(LEDGER_CLASSES)}); the request is NOT registered - map its kind onto an "
                              f"erasure class or teach the pipeline the class")
            continue
        if r.get("class") not in ERASURE_CLASSES:
            continue
        sender = (r.get("req_key") or "|").rsplit("|", 1)[0]
        pages = []
        for i in r.get("ids") or []:
            ent, _, pid = str(i).partition(":")
            if ent in ("profile", "track", "album") and re.fullmatch(r"[0-9a-f]{8}", pid):
                pages.append({"entity": ent, "id": pid})
        keys = [f"gmail:{alias}:{r['thread']}"] + ([f"notice:{r['notice_key']}"] if r.get("notice_key") else [])
        out.append({
            "keys": keys, "channel": alias.split("@")[0],
            "class": r["class"], "gmail_thread": r["thread"],
            "received_at": iso_ms(r.get("first_msg") or 0), "requester_email": sender if EMAIL_RE.match(sender) else "",
            "pages": pages, "replied_by_us": bool(r.get("replied_by_us")), "acked": bool(r.get("acked")),
        })
    return out


def parse_support_ledger(ledger: dict, errors: list | None = None) -> list[dict]:
    """support@ ledger rows. A row of an erasure class with no usable `first_seen` (or no thread) is a SOURCE
    FAILURE appended to `errors`, never a silent skip: dropping it would leave the request unregistered and
    unwatchdogged while the tick exits green."""
    out = []
    for key, r in sorted(ledger.items()):
        if r.get("class") not in LEDGER_CLASSES:
            if errors is not None:
                errors.append(f"support ledger row {key} ({r.get('class')}): not a class this pipeline knows; the "
                              f"request is NOT registered")
            continue
        if r.get("class") not in ERASURE_CLASSES:
            continue
        try:
            rec = parsedate_to_datetime(r.get("first_seen")).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (TypeError, ValueError):
            if errors is not None:
                errors.append(f"support ledger row {key} ({r.get('class')}): first_seen "
                              f"{r.get('first_seen')!r} is not a date; the request is NOT registered")
            continue
        if not r.get("thread"):
            if errors is not None:
                errors.append(f"support ledger row {key} ({r.get('class')}): no thread id; the row key cannot be "
                              f"built, so the request is NOT registered")
            continue
        pages = []
        for i in r.get("ids") or []:      # support-intake writes {kind, id, on_register}; legal-intake 'kind:id'
            ent, pid = (i.get("kind") or "profile", str(i.get("id") or "")) if isinstance(i, dict) else \
                (str(i).partition(":")[0] if ":" in str(i) else "profile", str(i).split(":")[-1])
            if ent in ("profile", "track", "album") and re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f-]{27})?", pid.lower()):
                pages.append({"entity": ent, "id": pid.lower()})
        out.append({"keys": [f"gmail:support@muso.ai:{r['thread']}"], "channel": "support", "class": r["class"],
                    "gmail_thread": r["thread"], "received_at": rec, "requester_email": "", "pages": pages})
    return out


# ---- the markdown register (data/cs-systemic-issues-lane-c1/removal-erasure-register.md)

MONTHS = {m: i for i, m in enumerate(("jan feb mar apr may jun jul aug sep oct nov dec").split(), 1)}
GMAIL_REF_RE = re.compile(r"\b(notices|legal|support)@(?:muso\.ai)?\s+([0-9a-f]{16})\b")
IC_RE = re.compile(r"\b(2154\d{11})\b")
CU_RE = re.compile(r"\b(869[0-9a-z]{6}|1am[0-9a-z]{8})\b")
PREFIX_RE = re.compile(r"\b(" + UUID + r"|[0-9a-f]{8})\b")
CROSS_REF_RE = re.compile(r"#\d{1,3}\)?\s+[0-9a-f]{8}\b")


def _register_date(cell: str, year: int = 2026) -> str:
    m = re.search(r"(\d{1,2})\s+([A-Za-z]{3})[a-z]*(?:\s+(?:~)?(\d{1,2}):(\d{2}))?", cell)
    if not m:
        return ""
    mon = MONTHS.get(m.group(2).lower())
    if not mon:
        return ""
    hh, mm = (int(m.group(3)), int(m.group(4))) if m.group(3) else (0, 0)
    return f"{year:04d}-{mon:02d}-{int(m.group(1)):02d}T{hh:02d}:{mm:02d}:00Z"


def _register_class(text: str) -> str:
    t = text.lower()
    if "security report" in t:
        return "not_erasure"
    t = re.sub(r"false legal_threat match[^|]*", "", t)
    if re.search(r"cnil|cease-and-desist|cease and desist|legal threat|legal_threat|copyright claim", t):
        return "legal_threat"
    if re.search(r"dmca|takedown", t) and not re.search(r"gdpr|erasure", t):
        return "dmca_takedown"
    return "privacy_erasure"


def parse_register(md: str) -> list[dict]:
    """Every numbered row of the markdown register -> candidate (open and closed; status says which)."""
    rows: dict[int, dict] = {}
    for line in md.splitlines():
        m = re.match(r"^\|\s*(\d{1,3})\s*\|(.*)\|\s*$", line)
        if not m:
            continue
        n = int(m.group(1))
        cells = [c.strip() for c in m.group(2).split("|")]
        if not cells or not _register_date(cells[0]):
            continue                                   # the 10-21 status sub-table reuses '#'; skip it
        text = " | ".join(cells)
        keys = [f"register:{n}"]
        ic = IC_RE.findall(cells[1] if len(cells) > 1 else "")
        conv = ic[0] if ic else ""
        if conv:
            keys.append(f"intercom:{conv}")
        gm = GMAIL_REF_RE.findall(text)
        for alias, thread in gm:
            keys.append(f"gmail:{alias}@muso.ai:{thread}")
        pages = []
        # "(batched with #33 e40d4dae)" names ANOTHER row's page: never attribute it to this row.
        own = CROSS_REF_RE.sub(" ", " ".join(cells[2:]))
        for i in PREFIX_RE.findall(own):
            pages.append({"entity": "album" if f"album {i}" in text else ("track" if f"track {i}" in text else "profile"),
                          "id": i})
        status_cell = cells[-1].lower()
        closed = bool(re.search(r"\bcompleted\b|^acked \(d\)", status_cell))
        rows[n] = {"keys": keys, "register_no": n, "channel": "intercom" if conv else (gm[0][0] if gm else "register"),
                   "class": _register_class(text), "received_at": _register_date(cells[0]),
                   "conversation_id": conv, "gmail_thread": gm[0][1] if gm else "",
                   "clickup_ids": CU_RE.findall(text), "pages": pages, "status": "closed" if closed else "open",
                   "confirmed": ""}
    # UPDATE lines below the table: completion and sent confirmations.
    for line in md.splitlines():
        for n in re.findall(r"#(\d{1,3})\b[^\n]*?\bCOMPLETED\b", line):
            if int(n) in rows:
                rows[int(n)]["status"] = "closed"
        m = re.match(r"^- (\d{2})-(\d{2}) [^#]*#(\d{1,3}) CONFIRMATION SENT", line)
        if m and int(m.group(3)) in rows:
            rows[int(m.group(3))]["confirmed"] = f"2026-{m.group(1)}-{m.group(2)}T00:00:00Z"
    return [rows[n] for n in sorted(rows)]
