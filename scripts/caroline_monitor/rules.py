#!/usr/bin/env python3
"""The ONE place the Caroline monitor's reading rules live.

Two readers, both pure functions of a reduced thread record (`collect.reduce_thread`):

  * `classify(thread) -> shape id` — what the customer was asking for. Ordered rules, first
    match wins. The monitor counts shapes with it and the fix loop keys its register on the
    same ids, so a shape is never defined twice.
  * `read_events(thread) -> [[timestamp, code], ...]` — what happened: the customer wrote,
    Caroline replied, she said a person is coming, parked it on a queue line, promised a date,
    refused with a reason, a human was assigned, a human replied.

Neither is ground truth. They are regexes over text, and their precision is MEASURED by hand
labels (`calibrate.py`; the numbers live in `data/caroline-monitor/calibration.json`). Any
change here bumps RULES_VERSION, which invalidates the fact cache and the calibration together:
a rule set nobody has labelled must say so.

No network, no clock, no state: everything a rule needs is passed in.
"""
import hashlib
import html
import re
from collections import namedtuple

RULES_VERSION = "2026-11-14.1"

# ----------------------------------------------------------------------------------------------
# Who is who. Ids are Intercom admin ids; the policy file can override them (k1 introduces an AI
# queue, and a new bot id must not start counting as "a human was assigned").
# ----------------------------------------------------------------------------------------------
CAROLINE_ADMIN_ID = "5763097"
OPERATOR_BOT_ID = "4359478"
DEFAULT_NON_HUMAN_ADMINS = (CAROLINE_ADMIN_ID, OPERATOR_BOT_ID)
CUSTOMER_AUTHOR_TYPES = ("user", "lead", "contact")

# ----------------------------------------------------------------------------------------------
# Shapes. The ids follow the caroline-intent-mining-m1 taxonomy so the two reports stay
# comparable. `family` only groups rows in the report.
# ----------------------------------------------------------------------------------------------
Shape = namedtuple("Shape", "id family title")

SHAPES = (
    Shape("robot_mail", "other", "Robots and stray mail"),
    Shape("legal_notice", "exempt", "Legal notice, DMCA, impersonation, security report"),
    Shape("gdpr_erasure", "exempt", "GDPR erasure / delete my data"),
    Shape("claim_conflict", "profile", "Someone else claimed my profile"),
    Shape("refund_dispute", "money", "Refund or charge dispute"),
    Shape("cancel_subscription", "money", "Cancel subscription"),
    Shape("plaque_order", "money", "Plaque order"),
    Shape("artist_link", "profile", "Connect a Spotify/Tidal artist link"),
    Shape("declined_why", "verification", "Why was my request declined"),
    Shape("proof_what_needed", "verification", "Asks what is needed / which credit"),
    Shape("proof_sent", "verification", "Sends proof for a credit"),
    Shape("claim_code_added", "verification", "Claim: I added the code"),
    Shape("request_status", "verification", "Asks where a request stands"),
    Shape("request_withdraw_correct", "verification", "Withdraws or corrects own pending request"),
    Shape("claim_start_problem", "verification", "Claim: how to start / a problem claiming"),
    Shape("merge_split", "profile", "Merge or split profiles"),
    Shape("credit_wrong", "profile", "A credit is wrong / not mine"),
    Shape("track_fix_takedown", "profile", "Track or album fix / takedown"),
    Shape("credit_add_howto", "verification", "How to add a missing credit"),
    Shape("profile_edit", "profile", "Profile edit (name, photo, bio)"),
    Shape("billing_question", "money", "Billing or plan question"),
    Shape("stats_wrong", "other", "Stats / streams / score look wrong"),
    Shape("account_access", "other", "Account access / email change"),
    Shape("app_bug", "other", "App or product bug"),
    Shape("api_support", "other", "API support"),
    Shape("partnership", "other", "Partnership / business proposal"),
    Shape("human_request", "other", 'Bare "give me a human"'),
    Shape("product_question", "other", "General product question"),
    Shape("thanks_empty", "other", "Thanks only / greeting only / empty"),
    Shape("other", "other", "Unclassified (the discovery input)"),
)
SHAPE_IDS = tuple(s.id for s in SHAPES)
SHAPE_BY_ID = {s.id: s for s in SHAPES}

ASK_MESSAGES = 3   # customer messages read for the ask: people open with "Hi" and then say it
ASK_CAP = 1500     # characters of ask text the rules see

_WS = re.compile(r"\s+")
# Where a mail client starts quoting the message being replied to. Everything after it is OUR
# text coming back, and classifying on it would file every reply under the email it answers.
_QUOTE_TAIL = re.compile(
    r"(\bon [a-z]{3},? [^|]{0,80}?\bwrote:"
    r"|\bel [a-zé]{3},? [^|]{0,80}?\bescribi[oó]:"
    r"|\bil giorno [^|]{0,80}?\bha scritto:"
    r"|\ble [a-zé]{3}\.? [^|]{0,80}?\ba [eé]crit ?:"
    r"|\bam [a-z]{2}\.?,? [^|]{0,80}?\bschrieb [^|]{0,80}?:"
    r"|(caroline from )?muso\.ai (<|&lt;|\(<)?\[email\][^|]{0,60}?(wrote|escribi[oó]|kirjoitti|napsal|escreveu|ha scritto)[^|]{0,40}?:"
    r"|-{2,} ?original message ?-{2,}"
    r"|we require more details to process your credit submission"
    r"|our records show \d+ credit requests?"
    r")",
    re.I,
)
_SIGNATURE_NOISE = re.compile(
    r"(sent from (my )?(iphone|ipad|outlook[^|]{0,20}|android[^|]{0,20}|samsung[^|]{0,30}|proton[^|]{0,20})"
    r"|get outlook for (ios|android)|enviado desde mi iphone|envoy[eé] de mon iphone"
    r"|lähetetty iphonesta|inviato da iphone|von meinem iphone gesendet|enviado do meu iphone)",
    re.I,
)
_ATTACH = re.compile(r"\[image\]|\[attachment\]|\[file\]", re.I)


def norm(text):
    """Lowercased, entity-decoded, straight-quoted, single-spaced text."""
    text = html.unescape(text or "")
    text = text.replace("\u2019", "'").replace("\u2018", "'").replace("\u201c", '"')
    text = text.replace("\u201d", '"').replace("\u2013", "-").replace("\u2014", "-")
    text = text.replace("\u200b", " ")
    return _WS.sub(" ", text).strip().lower()


def _strip_quote(text):
    m = _QUOTE_TAIL.search(text)
    return text[: m.start()] if m else text


AskView = namedtuple("AskView", "subject text raw attachments outbound source_type messages")


def ask_view(thread):
    """What the customer asked, as the rules see it.

    `outbound` is True when WE started the thread (a campaign or a staff email): the customer's
    first reply is the ask, and the subject is ours, so it says what they are answering.
    """
    source = thread.get("source") or {}
    subject = norm(source.get("subject"))
    customer_source = source.get("at") in CUSTOMER_AUTHOR_TYPES
    bits, attachments = [], 0
    if customer_source:
        body = norm(source.get("body"))
        attachments += int(source.get("att") or 0)
        if body:
            bits.append(body)
    for part in thread.get("parts") or []:
        if len(bits) >= ASK_MESSAGES:
            break
        if part.get("at") in CUSTOMER_AUTHOR_TYPES and part.get("t") == "comment":
            body = norm(part.get("body"))
            attachments += int(part.get("att") or 0)
            if body:
                bits.append(body)
    raw = " | ".join(bits)
    stripped = " | ".join(b for b in (_strip_quote(x).strip() for x in bits) if b)
    attachments += len(_ATTACH.findall(stripped))
    text = _SIGNATURE_NOISE.sub(" ", _ATTACH.sub(" ", stripped))
    text = _WS.sub(" ", text).strip()[:ASK_CAP]
    return AskView(subject, text, raw[:ASK_CAP], attachments, not customer_source,
                   source.get("type") or "", len(bits))


def _rx(pattern):
    return re.compile(pattern, re.I)


# --- signals shared by several rules ----------------------------------------------------------
# Subjects of the mails WE send that ask for proof. A reply to one is about proof by construction.
PROOF_MAIL_SUBJECT = _rx(
    r"additional information required for credit submission"
    r"|documents? (still )?needed to verify"
    r"|one thing we still need"
    r"|about the documents? for"
    r"|your muso verification documents"
    r"|your muso credit requests?: (an update|status)"
    r"|we added your .{0,80}credit"
)
CLAIM_MAIL_SUBJECT = _rx(r"^(re: ?)*(confirming )?your claim on ")
ROBOT_SUBJECT = _rx(
    r"delivery status notification|undeliverable|mail delivery (failed|subsystem)|failure notice"
    r"|has not received your inquiry|this ticket has been closed|automatic reply|auto[- ]?reply"
    r"|out of office|autoreply|respuesta autom[aá]tica|we'd love your feedback|rsvp to"
    r"|\binvit(ed|ation)\b.*\b(party|event|webinar)|\bnewsletter\b|your (order|package|shipment) (has|is)"
    r"|request received:|\[ticket"
    r"|thank you for (contacting|your (email|message|inquiry))|we('ve| have) received your (request|message|email)"
)
ROBOT_BODY = _rx(
    r"type your reply above this line|has not received your inquiry|no longer taking new questions"
    r"|automatic reply|auto-?reply|out of office|this is an automated (message|email|response)"
    r"|do not reply to this (email|message)|this mailbox is (not|un)monitored|delivery to the following recipient"
    r"|message (could not|couldn't) be delivered|address (not found|couldn't be found)"
    r"|you('re| are) invited|view (&|and) rsvp|view (this email )?in (your )?browser"
    r"|this email was sent to you because|\bwebinar\b|limited[- ]time offer|\bseo\b|guest post|backlinks?"
    r"|view in testflight|a request \(#\d+\) with [^|]{0,60} has been created"
)
# A forward of somebody else's machine mail: the customer wrote nothing of their own.
ROBOT_FORWARD = _rx(
    r"^-{5,} ?forwarded message ?-{5,} from: [^|]{0,200}subject: (fwd?: |re: )*"
    r"(delivery status notification|hello, |important: |this ticket|request received|new comment on)"
)
ASKS_WHAT = _rx(
    r"\bwhat (kind|type|sort)s? of (document|proof|evidence|info)"
    r"|\bwhat (document|proof|evidence|info|information|else|exactly|more)\b[^|.?]{0,40}\b(need|needed|require|want|send|provide|missing)"
    r"|\bwhat (do|should|can|must|would) (i|we|you) (need|have|send|provide|do|submit|want|require|upload)"
    r"|\bwhat('s| is| are) (needed|required|missing|still needed|the (problem|issue))"
    r"|\bwhich (credit|song|track|one|request|submission|document|release|album)s?\b"
    r"|\bwhat (credit|song|track|request|submission)s?\b[^|.?]{0,40}(need|are you|is this|referring|talking)"
    r"|\b(don'?t|do not|didn'?t) (understand|know what|get what)|\bnot sure what\b|\bi'?m confused\b|\bunclear\b"
    r"|\bnever (been asked|received|got)\b|\bwhat does this mean\b|\bwhy (do|am|are|is|did) (i|you|we|this)\b[^|.?]{0,40}(need|asked|required|verif)"
    r"|\bshould i (send|upload|submit|provide)|\bis (this|that|it) (enough|ok|okay|sufficient|acceptable)\??$"
    r"|\bcan you (give|show|tell) me (an )?example|\bhow (do|can|should) i (send|upload|submit|provide|verify|prove)"
    r"|\bqu[eé] (documentos?|necesit|tipo de|debo|tengo que)|\bcu[aá]l(es)? (cr[eé]dito|canci[oó]n|documento)"
)
SENDS_PROOF = _rx(
    r"\b(here('s| is| are)|attached|attaching|i('ve| have)? (attached|sent|included|uploaded)|please (find|see)|see (attached|below|screenshot)|sending)\b"
    r"|\b(screenshot|proof|invoice|contract|split ?sheet|label copy|statement|work order|session (file|folder)s?|stems|receipt|registration|liner notes|booklet|evidence)\b"
    r"|\b(adjunt|aqu[ií] (est[aá]|tienes|les|te)|comparto|captura|prueba|evidencia|comprobante)"
    r"|https?://(open\.spotify|tidal|music\.apple|www\.youtube|youtu\.be|www\.instagram|instagram|soundcloud|genius|www\.discogs|[a-z0-9-]+\.bandcamp)"
)
CREDIT_WORD = r"(credit|cr[eé]dito|submission|request|verification|verif|song|track|role)"


def _is_verification_reply(view):
    return view.outbound and bool(PROOF_MAIL_SUBJECT.search(view.subject)) or (
        bool(PROOF_MAIL_SUBJECT.search(view.subject)) and view.subject.startswith("re"))


def _r_robot(v):
    if PROOF_MAIL_SUBJECT.search(v.subject) or CLAIM_MAIL_SUBJECT.search(v.subject):
        return False  # a reply to OUR mail quotes our footer; that is not a robot
    if ROBOT_SUBJECT.search(v.subject):
        return True
    return bool(ROBOT_BODY.search(v.text) or ROBOT_FORWARD.search(v.raw))


_LEGAL = _rx(
    r"\bdmca\b|cease and desist|copyright (infringement|claim|violation|strike)|\binfring(e|ing|ement)\b"
    r"|\b(my |our )?(lawyer|attorney|solicitor|legal (team|counsel|department|action|notice|representative))\b"
    r"|\bformal (notice|complaint)\b|\blawsuit\b|\bsue\b|\bdefamat|\bimpersonat|suplantaci[oó]n|\bidentity theft\b"
    r"|\bvoice clon|clonaci[oó]n|\bsecurity (vulnerability|issue|report|researcher)\b|\bbug bounty\b|\bresponsible disclosure\b"
    r"|\bsubpoena\b|\bcourt order\b|\btrademark\b|\bdata protection (authority|officer)\b|\bregulator\b"
)
_GDPR = _rx(
    r"\bgdpr\b|\bccpa\b|right to (erasure|be forgotten)|\b(erasure|erase)\b|\bart(icle|\.)? ?1[57]\b"
    r"|\b(delete|remove|erase|deactivate|close)\b[^|.]{0,30}\b(my|our|the) (account|data|personal (data|information)|information|profile|page|legal name|name)\b"
    r"|\b(delete|remove)\b[^|.]{0,40}\bfrom (your|the) (servers?|database|site|website|platform)\b"
    r"|\bdid(n'?t| not) (give|consent)|\bwithout my (consent|permission)\b|\bpersonal data\b|\bopt[- ]out\b"
    r"|\b(eliminar|borrar|supprimer|löschen)\b[^|.]{0,30}\b(mi|mis|mon|mes|mein|meine) (cuenta|datos|perfil|compte|donn[eé]es|profil|konto|daten)"
)
_CLAIM_CONFLICT = _rx(
    r"\b(someone|somebody|another (person|user)|a stranger|some(one| other) else)\b[^|.]{0,40}\b(has |have )?claimed\b"
    r"|\bclaimed by (someone|somebody|another|a different)\b|\b(already|wrongly|falsely) claimed\b"
    r"|\b(not me|wasn'?t me|isn'?t me)\b[^|.]{0,30}\bclaim|\bclaimed my (profile|page|account)\b"
)
_REFUND = _rx(
    r"\brefund|\breembols|\brembours|\bmoney back\b|\bcharge ?back\b|\bdispute\b[^|.]{0,20}\bcharge"
    r"|\b(charged|billed|debited)\b[^|.]{0,40}\b(twice|again|without|after|even though|but|wrong|incorrect|still)\b"
    r"|\b(unauthori[sz]ed|unexpected|unknown|double|wrong) (charge|payment|transaction)\b|\bdidn'?t (authori[sz]e|sign up|subscribe)\b"
    r"|\bcharged me\b|\bwas charged\b|\bgot charged\b|\bbeen charged\b"
)
_CANCEL = _rx(
    r"\b(cancel|cancell?ing|cancell?ation|cancelar|annuler|k[uü]ndigen)\b[^|.]{0,60}\b(subscription|membership|plan|pro\b|premium|business|trial|account|renew|suscripci[oó]n|abonnement|abo|membres[ií]a)"
    r"|\b(subscription|membership|plan|trial|suscripci[oó]n)\b[^|.]{0,40}\b(cancel|cancell?ed|cancell?ing|cancelar)"
    r"|^(please )?cancel( it| this| my| membership| subscription)?\.?$|\bhelp cancell?ing\b|\b(stop|turn off|disable)\b[^|.]{0,30}\b(renew|auto-?renew|billing|subscription)"
    r"|\bunsubscribe\b[^|.]{0,30}\b(pro|premium|plan|business)\b|\bdon'?t want to (renew|be charged|continue)"
)
_PLAQUE = _rx(r"\bplaques?\b|\bplaca\b|\bbillion streams? (club|award)|\baward (order|plaque)\b|\bframed\b")
_ARTIST_LINK = _rx(
    r"connect an? (spotify|tidal)( or tidal)? artist (link|profile)"
    r"|\b(connect|link|attach|add)\b[^|.]{0,40}\b(my )?(spotify|tidal|apple music)\b[^|.]{0,30}\b(artist|profile|page|account|link)\b"
    r"|\bmy artist link:"
)
_DECLINED = _rx(
    r"\b(why|how come|reason)\b[^|?]{0,80}\b(reject|declin|denied|deny|refus|not (approved|accepted|verified)|removed my request|closed)"
    r"|\b(reject|declin|denied)\w*\b[^|?]{0,60}\b(why|reason|explain|how come)\b|\bpor qu[eé]\b[^|?]{0,60}\b(rechaz|deneg)"
    r"|\b(was|were|got|been|is|are) (rejected|declined|denied)\b"
)
_CODE_ADDED = _rx(
    r"\b(added|add|put|placed|pasted|posted|included|have|has|is|with)\b[^|.]{0,40}\b(the |my |a |verification )?code\b[^|.]{0,60}\b(bio|description|about|profile|spotify|instagram|website|page|youtube|soundcloud)"
    r"|\bcode\b[^|.]{0,30}\b(is|in|on|to)\b[^|.]{0,20}\b(my )?(bio|spotify|instagram|profile|description|website|page)\b"
    r"|\bi('ve| have)? (added|put|placed|posted) (the|my|that) code\b|\bc[oó]digo\b[^|.]{0,40}\b(bio|perfil|descripci[oó]n|instagram|spotify)"
)
_STATUS = _rx(
    r"\b(status|update|progress|news|estado|actualizaci[oó]n)\b[^|]{0,80}\b" + CREDIT_WORD
    + r"|\b" + CREDIT_WORD + r"s?\b[^|]{0,80}\b(still|yet)\b[^|]{0,30}\b(pending|in review|under review|waiting|processing|not (approved|verified|showing|accepted|been))"
    r"|\bstill (pending|in review|under review|waiting|processing|no (answer|response|reply|update))\b"
    r"|\b(how long|when (will|is|are|do|can))\b[^|?]{0,80}\b(verif|review|approv|take|credit|request|claim|pending|hear|process)"
    r"|\b(been|waiting|waited|it'?s been)\b[^|.]{0,30}\b(day|week|month|d[ií]a|semana|mes)s?\b"
    r"|\b(any|an|no) (update|news|response|answer|reply)\b|\b(pending|in review|under review|en revisi[oó]n|pendiente)s?\b"
    r"|\bhaven'?t (heard|received|gotten|got)\b|\bnobody (answered|replied|responded)\b|\bfollowing up\b|\bfollow[- ]up on\b|\bchecking in\b"
    r"|\bcu[aá]nto (tiempo|tarda)|\btodav[ií]a\b[^|.]{0,40}\b(pendiente|revisi[oó]n|esperando)"
    r"|\btaking so long\b|\bnobody (has )?(confirmed|approved|reviewed|checked)\b|\bwhen can i expect\b|\bhave you checked\b"
    r"|\bpush my credits through\b|\b\d+(st|nd|rd|th) time\b"
)
_WITHDRAW = _rx(
    r"\b(by mistake|mistaken(ly)?|accidentally|by accident|by error|por error|wrong (role|credit|song|track|request|one))\b"
    r"|\b(withdraw|retract|cancel|delete|remove)\b[^|.]{0,40}\b(my |the |this |that )?(pending |credit |open )?(request|submission|claim)s?\b"
    r"|\b(misspell?ed|typo)\b|\bsubmitted\b[^|.]{0,30}\b(wrong|twice|duplicate)\b|\badded\b[^|.]{0,30}\b(wrong|twice|mistaken)"
)
_CLAIM = _rx(
    r"\bclaim(ing|ed)?\b[^|.]{0,50}\b(profile|page|account|label|artist|name)\b|\b(profile|page|account)\b[^|.]{0,40}\bclaim"
    r"|\b(can'?t|cannot|unable to|how (do|can) i|trying to|want to|need to|would like to)\b[^|.]{0,20}\bclaim\b"
    r"|\b(can'?t|cannot|couldn'?t) (find|see|locate|create)\b[^|.]{0,30}\b(my |a |new )?(profile|page|profil|name)\b"
    r"|\b(create|make|set up|start)\b[^|.]{0,20}\b(a |an |my |new )?(artist |producer |new )?profile\b"
    r"|\bverif(y|ying|ication)\b[^|.]{0,20}\b(my )?(profile|account|identity|page)\b|\bverification code\b"
    r"|\breclamar\b[^|.]{0,40}\b(perfil|p[aá]gina|cuenta)|\bno (encuentro|puedo encontrar)\b[^|.]{0,20}\bperfil"
)
_MERGE = _rx(
    r"\bmerg(e|ed|ing)\b|\bduplicate(d)? (profile|page|account|artist)s?\b|\b(two|2|three|3|multiple|several|both|another) (profile|page|account)s\b"
    r"|\b(combine|consolidate|unify|fusion|fusionar|unir|juntar)\b[^|.]{0,40}\b(profile|page|account|credit|perfil|cuenta)"
    r"|\bsplit\b[^|.]{0,30}\b(profile|page|credits)\b|\b(same|different|other|another|second|old|new) (name|profile|page|alias|spelling)\b[^|.]{0,60}\b(profile|credits?|under|link|together|one)\b"
    r"|\b(all|my) credits? (under|on|in|into|to) (one|the same|a single|my (main|other))\b|\blink\b[^|.]{0,30}\bwith\b[^|.]{0,40}\b(account|profile|credits)"
    r"|\banother\b[^|.]{0,40}\b(on here|with (my|the same) name)\b|\b(alias|aka|a\.k\.a|also known as|stage name|otro perfil|dos perfiles)\b"
    r"|\b(is|are) (a )?duplicates? of\b|\bduplicad[oa]s?\b|\b\d+ perfiles\b|\b(mismo|stesso|m[eê]me) nom(bre|e)?\b|\bsame name as (me|mine)\b"
)
_CREDIT_WRONG = _rx(
    r"\b(not|isn'?t|aren'?t|are not|is not|weren'?t|wasn'?t) (mine|my (credit|song|track|work)s?|me\b)"
    r"|\b(didn'?t|did not|never) (work|play|produce|write|mix|master|perform|record|contribut|collaborat)"
    r"|\b(remove|delete|take off|take down|get rid of)\b[^|.]{0,50}\b(credit|role|collaborator|from (my|his|her|their|the) (profile|page|credits))"
    r"|\b(wrong|incorrect|false|fake|erroneous)(ly)? (credit|role|attribut|listed|assigned)|\bcredited (with|on|as|for)\b[^|.]{0,60}\b(wrong|not|didn'?t|incorrect|mistake)"
    r"|\bnot a collaborator\b|\b(getting|being) credited with my\b|\bshown (like|as) mine\b|\bno (son|es) m[ií]"
    r"|\b(quitar|eliminar|remover|enlever|supprimer)\b[^|.]{0,40}\bcr[eé]dit"
    r"|\buntag (myself|me)\b|\bcredited incorrectly\b|\bcredits?\b[^|.]{0,60}\b(removed|taken off)\b|\bhasn'?t been removed\b"
    r"|\bnon mi appartengono\b|\bne m'appartiennent pas\b|\bno me pertenecen\b|\b(don'?t|do not) know who\b|\bshouldn'?t be (in|on) (my|the) (catalog|profile|credits)\b|\bget rid of\b"
)
_TRACK_FIX = _rx(
    r"\btake ?down\b|\b(remove|delete|hide)\b[^|.]{0,40}\b(my |the |this |these |our |all )?(song|track|album|release|music|ep|single)s?\b"
    r"|\b(wrong|incorrect|missing|old|update|change|fix|correct)\b[^|.]{0,30}\b(artwork|cover|title|track ?list|release date|isrc|upc|album|label name|artist name on)\b"
    r"|\b(song|track|album|release)s?\b[^|.]{0,50}\b(not (showing|appearing|on muso|listed|there)|missing|isn'?t (showing|on|there|appearing)|doesn'?t (show|appear)|yet to show)"
    r"|\bcredits? (on muso(\.ai)? )?(are|is) out of date\b|\bcredit correction\b|\bcan'?t (view|see|find) my (new )?(song|track|album|release)"
    r"|\badded\b[^|.]{0,30}\b(song|track|release)s?\b[^|.]{0,40}\b(catalog|not show|yet to)"
    r"|\bshould be called\b|\b(song|track|album)\b[^|.]{0,20}\b(is|are) under (a |the )?(different|wrong|another)\b"
    r"|\b(is|are) supposed to be\b|\bil manque\b[^|.]{0,30}\b(morceaux|titres)"
    r"|\b(track|song|album|release)\b[^|.]{0,20}\b(doesn'?t|does not|doest|don'?t) (appear|show)\b|\bno longer (be )?visible\b"
    r"|\bnot displaying\b|\bmissing the artist\b"
)
_ADD_CREDIT = _rx(
    r"\b(how|where)\b[^|?]{0,40}\b(add|submit|request|claim|get)\b[^|?]{0,30}\bcredits?\b"
    r"|\b(add|adding|submit|agregar|a[ñn]adir)\b[^|.]{0,30}\b(a |my |new |missing |un |mi |mis )?(credit|cr[eé]dito)s?\b"
    r"|\bcredits? (are |is )?(missing|not (showing|listed|there|appearing))\b|\bmissing credits?\b"
    r"|\b(isn'?t|not|aren'?t) (showing|listed|credited|appearing)\b[^|.]{0,30}\b(on|for) (a|the|my|this) (song|track)"
    r"|\bclaim\b[^|.]{0,30}\b(credit|song)s?\b|\breclamar\b[^|.]{0,30}\bcr[eé]ditos?"
    r"|\b(give|get) me my credits?\b|\bcredits? (associated|linked|added) to (me|my)\b|\baggiungere i crediti\b"
    r"|\b(can'?t|cannot|no puedo|don'?t see)\b[^|.]{0,30}\b(add|agregar)\b|\badd (track|credit) button\b|\badd\b[^|.]{0,20}\bplacements?\b"
)
_PROFILE_EDIT = _rx(
    r"\b(change|update|edit|fix|correct|replace|remove|cambiar|actualizar)\b[^|.]{0,40}\b(my |the |our )?(profile )?(name|photo|picture|pic|image|avatar|bio|biography|username|display name|handle|spelling|nombre|foto|links?|social)\b"
    r"|\b(old|wrong|incorrect|someone else'?s|misspell?ed) (name|photo|picture|pic|image|bio)\b|\bprofile (picture|photo|pic|image)\b"
    r"|\bmy (old )?name still (appears|shows)\b|\bpic comes? up\b|\b(edit|update) (my )?profile\b"
)
_BILLING = _rx(
    r"\b(invoice|receipt|billing|payment method|credit card|debit card|paypal|vat|tax id|factura|recibo)\b"
    r"|\b(price|pricing|cost|how much|discount|promo(tion)? code|coupon|student|upgrade|downgrade|free trial|trial)\b"
    r"|\b(pro|premium|business|paid) (plan|subscription|membership|account|version|tier|features?)\b|\bsubscription\b|\bsuscripci[oó]n\b"
    r"|\b(pay|paid|payment|pago)\b"
)
_STATS = _rx(
    r"\b(stream|streams|streaming numbers?|stats?|statistics|score|rank(ing)?|chart|charts|numbers?|count|totals?|analytics|listeners|plays)\b[^|.]{0,60}\b(wrong|incorrect|drop|dropped|decrease|down|lower|missing|not (updat|match|right|accurate|correct)|off|inaccurate|update|different|went|lost|stuck|mismatch)"
    r"|\b(wrong|incorrect|drop|dropped|lost|missing|inaccurate|lower)\b[^|.]{0,40}\b(stream|streams|stats?|score|rank(ing)?|numbers?|count|totals?|points)\b"
    r"|\bmuso score\b|\bscore dropped\b|\bstream (count|total)s?\b|\breproducciones\b"
)
_ACCESS = _rx(
    r"\b(log ?in|log ?on|logged out|sign ?in|signing in|sign ?up|password|contrase[ñn]a|iniciar sesi[oó]n|2fa|two[- ]factor|locked out|magic link)\b"
    r"|\b(change|update|switch|cambiar)\b[^|.]{0,30}\b(my |the |account )?(e-?mail|correo)\b|\b(can'?t|cannot|unable to) (access|get into|open) (my )?(account|profile)\b"
    r"|\b(access|recover|reset)\b[^|.]{0,20}\b(my )?(account|cuenta)\b|\bwrong (e-?mail|account)\b|\bgoogle (sign|login|account)\b"
    r"|\be-?mail add?ress? change\b|\blog ?out\b|\bnicht anmelden\b"
)
_BUG = _rx(
    r"\b(bug|glitch|crash|crashes|crashing|freez|frozen|broken|not working|doesn'?t work|isn'?t working|won'?t (load|open|work|let)|not loading|blank (page|screen)|white screen|stuck)\b"
    r"|\b(error|something went wrong|gives me (an )?error|unavailable)\b|\b(app|website|site|page|button|tab)\b[^|.]{0,30}\b(issue|problem|fail)"
    r"|\bcan'?t (acc?ess|open|use|click|tap|press|upload)\b|\bno (funciona|carga|me deja)\b"
)
_API = _rx(r"\bapi\b|\bapi key\b|\bendpoint\b|\bwebhook\b|\bdeveloper (access|docs|account)\b|\brate limit\b")
_PARTNER = _rx(
    r"\bpartner(ship)?\b|\bcollaborat(e|ion) (with|between) (muso|your (company|team|platform))|\bsponsor|\bbusiness (proposal|opportunity|development)\b"
    r"|\b(press|media|interview|podcast) (inquiry|request)\b|\binvest(or|ment)\b|\blicens(e|ing) your data\b|\bwhite[- ]label\b|\bintegrat(e|ion) (with|muso)"
)
_HUMAN = _rx(
    r"\b(talk|speak|chat|connect|get|reach|contact|hablar)\b[^|.]{0,30}\b(to |with |a |an |al? )?(human|person|real (person|human|one)|someone real|agent|representative|rep\b|staff|support team|persona|humano|live (agent|person|support))"
    r"|\b(human|real person|live agent|representative) (please|pls|support|help)\b|^(human|agent|representative|real person|person)\.?$"
    r"|\b(are you|is this) (a )?(bot|robot|ai|human|real)\b|\bnot a bot\b"
    r"|\b(speak|talk) (with|to) some ?one\b|\boperator?\b|\bliv(e)? support\b"
)
_QUESTION = _rx(
    r"\?|\b(how (do|does|can|to|would|is|are)|what (is|are|does|do)|where (is|are|can|do)|can (i|you|we)|could (i|you)|is (it|there)|does (muso|it|this)|do you|c[oó]mo|puedo|d[oó]nde)\b"
    r"|\b(export|download|csv|xml|pdf|embed|widget|share|feature|notification|settings)\b"
)
_THANKS = _rx(
    r"^(hi+|hey+|hello+|hola+|heyy+|yo+|ok(ay)?|k|thanks?( you)?( so much| very much)?|thank u|thx|ty|gracias|merci|danke|great|perfect|cool|awesome|alright|sounds good|got it|noted|yes|no|sure|good (morning|afternoon|evening)|one question|help|hi there|hello there|[^a-z0-9]*)"
    r"( (caroline|team|muso|guys|there))?[ !.,|:)❤️🙏👍]*$"
)
_PROOF_CHAT = _rx(
    r"\b(proof|evidence|verification needed|additional information|document(s|ation)?|prueba|evidencia)\b[^|]{0,120}\b" + CREDIT_WORD
    + r"|\b" + CREDIT_WORD + r"s?\b[^|]{0,120}\b(proof|evidence|invoice|contract|split ?sheet|screenshot|document(s|ation)?|label copy|prueba)\b"
    r"|\b(submit|send|sending|provide|upload|drop|here('s| is| are))\b[^|.]{0,30}\b(proof|evidence|document|invoice|screenshot|contract|split ?sheet)"
    r"|\b(asked|told|email(ed)?|mail)\b[^|.]{0,60}\b(provide|send|additional information|verif|proof|document)"
    r"|\bpending credit\b[^|]{0,80}\b(link|here|proof|sent)\b|\bverification needed\b"
    r"|\b(credit|cr[eé]dito)s?\b[^|.]{0,60}\b(need|needs|require|requires|por|para) (verification|verificar|verificaci[oó]n)"
    r"|\bverif(y|icar|ication)\b[^|.]{0,40}\b(my |mis |algunos |some |the )?(credit|cr[eé]dito|rights)s?\b"
    r"|\b(confirming|showing|shows|proving|proves)\b[^|.]{0,40}\b(my|me as)\b[^|.]{0,60}\b(role|credit|producer|engineer|writer|mix|master)"
    r"|\b(sent|send|asked for|requires?|needs?) (additional |addition |more )?(verification|info(rmation)?)\b"
    r"|\bcredit verification\b|\bverif+y my (song|track)s?\b"
)


def _r_proof_what(v):
    if _is_verification_reply(v):
        return bool(ASKS_WHAT.search(v.text)) and not _sends_something(v)
    return bool(_PROOF_CHAT.search(v.text) and ASKS_WHAT.search(v.text) and not v.attachments)


def _sends_something(v):
    """An attachment or a link to a public source is a document, whatever the words around it."""
    return bool(v.attachments) or bool(re.search(r"https?://(?!muso\.ai)", v.text))


def _r_proof_sent(v):
    if _is_verification_reply(v):
        return True  # the default reply to a "we need proof" mail; the exits above took the rest
    return bool(_PROOF_CHAT.search(v.text))


_ASKS_ANYTHING = _rx(r"\?|\b(how|what|where|why|can'?t|cannot|problem|issue|error|doesn'?t|not working|help)\b")


def _r_claim_code(v):
    # A reply to "confirming your claim on X" (the mail that hands out the code) that asks
    # nothing is the customer saying the code is in place.
    if v.outbound and CLAIM_MAIL_SUBJECT.search(v.subject) and not _ASKS_ANYTHING.search(v.text):
        return True
    return bool(_CODE_ADDED.search(v.text))


def _r_claim(v):
    return bool(CLAIM_MAIL_SUBJECT.search(v.subject) or _CLAIM.search(v.text))


def _r_human(v):
    # BARE: the ask is the request for a person and little else. A thread that names its
    # problem and also asks for a human was classified by its problem above.
    return bool(_HUMAN.search(v.text)) and len(v.text) <= 160


def _r_thanks(v):
    if not v.text or _THANKS.match(v.text):
        return True
    return len(v.text) <= 25 and not _QUESTION.search(v.text)


def _text(rx):
    return lambda v: bool(rx.search(v.text))


def _text_or_subject(rx):
    return lambda v: bool(rx.search(v.text) or rx.search(v.subject))


# ORDER IS THE RULE. Read top to bottom: the first predicate that holds names the shape.
#   1. things that must never be auto-answered on substance (robots, legal, erasure, conflicts)
#   2. money, because a refund ask inside a proof thread is still a refund ask
#   3. the product-prefilled opener (exact, cheap)
#   4. verification, most specific first
#   5. profile and catalog
#   6. everything else, ending in the two residual buckets
RULES = (
    ("robot_mail", _r_robot),
    ("legal_notice", _text_or_subject(_LEGAL)),
    ("gdpr_erasure", _text_or_subject(_GDPR)),
    ("claim_conflict", _text(_CLAIM_CONFLICT)),
    ("refund_dispute", _text_or_subject(_REFUND)),
    ("cancel_subscription", _text_or_subject(_CANCEL)),
    ("plaque_order", _text_or_subject(_PLAQUE)),
    ("artist_link", _text(_ARTIST_LINK)),
    ("declined_why", _text(_DECLINED)),
    ("proof_what_needed", _r_proof_what),
    ("proof_sent", _r_proof_sent),
    ("claim_code_added", _r_claim_code),
    ("request_withdraw_correct", _text(_WITHDRAW)),
    ("request_status", _text(_STATUS)),
    ("claim_start_problem", _r_claim),
    ("merge_split", _text(_MERGE)),
    ("credit_wrong", _text(_CREDIT_WRONG)),
    ("track_fix_takedown", _text_or_subject(_TRACK_FIX)),
    ("credit_add_howto", _text(_ADD_CREDIT)),
    ("profile_edit", _text(_PROFILE_EDIT)),
    ("billing_question", _text_or_subject(_BILLING)),
    ("stats_wrong", _text(_STATS)),
    ("account_access", _text_or_subject(_ACCESS)),
    ("app_bug", _text(_BUG)),
    ("api_support", _text(_API)),
    ("partnership", _text_or_subject(_PARTNER)),
    ("human_request", _r_human),
    ("thanks_empty", _r_thanks),
    ("product_question", _text(_QUESTION)),
)


def classify_view(view):
    for shape_id, predicate in RULES:
        if predicate(view):
            return shape_id
    return "other"


def classify(thread):
    """The shape id of a thread. Always one of SHAPE_IDS."""
    return classify_view(ask_view(thread))


# ----------------------------------------------------------------------------------------------
# What Caroline said. Matched on her own comment text, lowercased by norm().
# ----------------------------------------------------------------------------------------------
# A PERSON PROMISE: she tells the customer a person or "the team" will take this over, look at it
# or come back to them. It is true only if a human is actually assigned.
PERSON_PROMISE = _rx(
    r"pulling in a teammate|\bteammate (will|to|is)\b|\bloop(ing)? in\b[^.]{0,30}\b(team|teammate|colleague)"
    r"|\b(they|our team|the team|someone|a teammate|a specialist|a colleague|a member of (our|the) team|our (support|verification|catalog|billing) team)"
    r"('ll| will) (follow up|review|take|be in touch|get back|reach out|look into|contact|respond|reply|help|handle|check|investigate)"
    r"|\b(flagged|passed|forwarded|escalated|sent|handed|routed|raised)\b (it|this|that|them|your\b[^.]{0,80}?|the\b[^.]{0,80}?)\s*\b(for|to|with|over to) (our|the) (\w+ )?team\b"
    # Found by the hand labels (11 of 50 threads read as "no hand-off" carried one of these):
    r"|\bi('ve| have) (flagged|escalated|raised) (your|the|this|that|it|them)\b"
    r"|\bi('ve| have) submitted (your|the|a)\b[^.]{0,60}\brequest\b|\bto your existing request so (that )?(our|the) team\b"
    r"|\bso (that )?(our|the) team can\b|\byou'll hear from (us|the team|our team)\b"
    r"|\bte responderemos\b|\b(a|con) (nuestro|el) equipo\b|\bj'ai (signalé|transmis)\b|\b(à|a) notre équipe\b"
    r"|\bfor a priority look\b|\bgets to the team\b|\bi'll pass (it|this|that|them|those) on\b"
    r"|\bhear back within\b|\bresponse within\b|\bfor manual review\b|\bteam will (see|take|pick)\b"
    r"|\bleave the review with the team\b|\bte responder[aá]n\b|\bun compa[ñn]ero\b|\bnuestro equipo (te|lo|la|va)\b"
    r"|\bwe('ll| will) follow up (here|right here|with you)\b|\bfollow up right here\b"
)
# The merge paragraph ends "Profiles claimed by someone else ... are handled differently: I'll pass
# those on." That is a conditional in an explanation, not a promise about this thread.
PERSON_PROMISE_EXCLUDE = _rx(r"are handled differently: i'll pass those on")
# A QUEUE LINE: she says it is with the team / in a queue and names no person and no state.
QUEUE_LINE = _rx(
    r"goes to the verification team|in the verification queue|review in the order requests arrive"
    r"|will email you when yours has been reviewed|we'll message you here as soon as|we are continuing to review"
    r"|we will follow up here once|we'll be in touch|we'll update you|the outcome comes to this conversation"
    # the approved honesty lines (answer-bank.ts, firstmate inbox 010/011 2026-11-14): an owed
    # follow-up we must keep, naming no person. The old "gets to the team" line stays in
    # PERSON_PROMISE because already-answered threads carry it.
    r"|i have recorded this and will update you here|i will update you here as soon as there is news"
)
# A DATE PROMISE: one of the four things Caroline must never do. "within N business days",
# "by Friday", "usually within a day". Counted on its own; it pages.
DATE_PROMISE = _rx(
    r"\bwithin (\d+|one|two|three|four|five|a|an|a few|a couple of)( to \d+| ?- ?\d+)? ?(business |working )?(day|hour|week)s?\b"
    r"|\bin (\d+|one|two|three|a few|a couple of)( to \d+| ?- ?\d+)? (business |working )?(day|hour|week)s\b"
    r"|\bby (monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|end of (the )?(day|week))\b"
    r"|\b(today|tomorrow) (at|by|before)\b|\bwithin (24|48|72) ?h"
)
# Not promises: the statutory clock in the approved GDPR acknowledgement (the law's, not ours),
# and a sentence that REFUSES a date ("I can't promise a response by Friday" is the right answer).
DATE_PROMISE_EXCLUDE = _rx(
    r"within one month of today"
    r"|\b(can't|cannot|can not|won't|will not|unable to|not able to|don't want to|no puedo)\b"
    r"[^.!?]{0,40}\b(promise|guarantee|commit|give|confirm|offer|prometer|garantizar)\b[^.!?]*"
)
# A REFUSAL with a reason and a way back: the approved shape for the exemptions. Not a hand-off.
REFUSAL_LINE = _rx(
    r"a request is closed when the supporting information|you can submit it again with your supporting documents"
    r"|i can't (see|share|tell you)\b[^.]{0,80}\b(review|how|why|where|source|who)|i can't (give|offer) (you )?(legal|a legal)"
    r"|i can't (promise|guarantee|give you|commit to)\b[^.!?]{0,60}\b(date|time|timeline|timeframe|by|within|when)\b"
    r"|that's not something i can (share|confirm|speak to)"
    r"|once a page is hidden it stays hidden"
)

# Event codes. A thread is reduced to a time-ordered list of (timestamp, code); nothing else about
# it is kept. Every metric is a question about which codes happened before a cut-off, so the same
# thread can be read "as of now" and "as of 48 hours after it opened" from one record.
EV_CUSTOMER = "c"        # the customer wrote (or sent a file)
EV_CAROLINE = "a"        # Caroline replied
EV_HUMAN_REPLY = "h"     # a human admin replied
EV_PROMISE = "p"         # Caroline said a person / the team is coming
EV_QUEUE = "q"           # Caroline parked it on a queue line
EV_DATE = "d"            # Caroline promised a date or a day count
EV_REFUSAL = "r"         # Caroline refused with a reason and a way back
EV_HUMAN_ASSIGNED = "A"  # the thread was assigned to a human admin
EV_GUARD = "g"           # the output guard replaced a reply with the hand-off line
EVENT_CODES = (EV_CUSTOMER, EV_CAROLINE, EV_HUMAN_REPLY, EV_PROMISE, EV_QUEUE, EV_DATE,
               EV_REFUSAL, EV_HUMAN_ASSIGNED, EV_GUARD)

# The tag plugins/intercom writes when caroline-output-guard.ts blocks a reply (a promise, a
# reveal, a legal position, off-topic) and sends the hand-off line in its place. It marks a
# hand-off the guard FORCED, which no read tool will remove: only a refusal line can.
GUARD_TAG = "ai:output-guard"
_REPLY_PART_TYPES = ("comment", "open", "assignment", "assign_and_reopen", "close")


def _is_human_target(kind, target_id, non_human, staffed):
    target_id = str(target_id or "")
    if kind == "admin":
        return target_id not in non_human
    return kind == "team" and target_id in staffed


def read_events(thread, non_human_admins=DEFAULT_NON_HUMAN_ADMINS, staffed_teams=()):
    """The thread as a sorted list of [timestamp, code]. No judgement and no clock.

    A human assignment is an assignment part whose target is an ADMIN that is not Caroline and
    not an automation id, or a TEAM listed in `staffed_teams`. That list is empty today on
    purpose: the default team Intercom stamps on every new thread is not a person being assigned,
    so a team counts only once the register names it as a queue people actually work
    (`monitor.staffed_team_ids`). When the final admin assignee is a human
    but no assignment part names one (a thread whose parts were truncated), the assignment is
    dated at `updated_at`: late on purpose, so an unseen assignment can never make a hand-off
    look covered earlier than we can show it was.
    Notes are internal and are never a reply. Automation parts (reply-time expectations, bot
    comments) are never a reply either.
    """
    non_human = set(str(x) for x in non_human_admins) | {"", "0", "None"}
    staffed = set(str(x) for x in staffed_teams)
    created = int(thread.get("created_at") or 0)
    events = []
    source = thread.get("source") or {}
    if source.get("at") in CUSTOMER_AUTHOR_TYPES:
        events.append([created, EV_CUSTOMER])
    saw_human_assignment = False
    for part in thread.get("parts") or []:
        kind, author_type = part.get("t"), part.get("at")
        author_id = str(part.get("aid") or "")
        body = (part.get("body") or "").strip()
        ts = int(part.get("ts") or created)
        target = part.get("asg")
        if target and _is_human_target(target.get("type"), target.get("id"), non_human, staffed):
            events.append([ts, EV_HUMAN_ASSIGNED])
            saw_human_assignment = True
        if author_type in CUSTOMER_AUTHOR_TYPES:
            if kind == "comment" and (body or part.get("att")):
                events.append([ts, EV_CUSTOMER])
            continue
        if author_type != "admin" or kind not in _REPLY_PART_TYPES or not body:
            continue
        if author_id == CAROLINE_ADMIN_ID:
            events.append([ts, EV_CAROLINE])
            text = norm(body)
            if PERSON_PROMISE.search(PERSON_PROMISE_EXCLUDE.sub(" ", text)):
                events.append([ts, EV_PROMISE])
            if QUEUE_LINE.search(text):
                events.append([ts, EV_QUEUE])
            if DATE_PROMISE.search(DATE_PROMISE_EXCLUDE.sub(" ", text)):
                events.append([ts, EV_DATE])
            if REFUSAL_LINE.search(text):
                events.append([ts, EV_REFUSAL])
        elif author_id not in non_human:
            events.append([ts, EV_HUMAN_REPLY])
    if GUARD_TAG in (thread.get("tags") or []):
        # Dated when the tag was applied; a record without the stamp is dated at `updated_at`.
        applied = int((thread.get("tag_at") or {}).get(GUARD_TAG) or 0)
        events.append([applied or int(thread.get("updated_at") or created), EV_GUARD])
    final_human = (_is_human_target("admin", thread.get("admin_assignee_id"), non_human, staffed)
                   or _is_human_target("team", thread.get("team_assignee_id"), non_human, staffed))
    if final_human and not saw_human_assignment:
        events.append([int(thread.get("updated_at") or created), EV_HUMAN_ASSIGNED])
    events.sort(key=lambda e: e[0])
    return events


def reader_version(non_human_admins=DEFAULT_NON_HUMAN_ADMINS, staffed_teams=()):
    """The rule set PLUS who counts as a person. Stored on every fact, so changing either one
    invalidates what was read under the old answer instead of mixing the two."""
    who = ",".join(sorted(str(x) for x in non_human_admins)) + "|" + ",".join(
        sorted(str(x) for x in staffed_teams))
    return f"{RULES_VERSION}+{hashlib.sha256(who.encode()).hexdigest()[:8]}"


def thread_facts(thread, non_human_admins=DEFAULT_NON_HUMAN_ADMINS, staffed_teams=()):
    """Everything the monitor keeps about a thread. No text, no contact, no subject."""
    source = thread.get("source") or {}
    return {
        "id": str(thread.get("id")),
        "created_at": int(thread.get("created_at") or 0),
        "updated_at": int(thread.get("updated_at") or 0),
        "open": bool(thread.get("open")),
        "shape": classify(thread),
        "outbound": source.get("at") not in CUSTOMER_AUTHOR_TYPES,
        "events": read_events(thread, non_human_admins, staffed_teams),
        "rules": reader_version(non_human_admins, staffed_teams),
    }
