"""Identity decision for one erasure request: gdpr-ack-v2 §3, paths A-E + legal_threat. PURE (no I/O).

The table this implements (Fable, `gdpr-ack-v2-and-arpad-1101.md` §3; implement, never re-derive):

  A claim           the requesting account holds a PROCESSED claim on the profile
  B account email   the Intercom contact resolves to exactly one Muso account (identity_resolver r5, or the
                    sender address equals exactly one account email) AND that account's name matches the page
  C unclaimed name  the page is unclaimed and its display name equals the requester's name (name-fold
                    compare; the sender name and the email local part count) -- big-name or high-credit pages
                    (popularity >= 60 or >= 50 credits) go to Jan instead
  D official domain the sender's domain is the page's own website domain from OUR catalog (found
                    independently of the request: the request text is never an input)
  E representative  written authorisation from the data subject -- a person cannot be verified by code,
                    so a representative is ASKed for it and a reply carrying one goes to Jan
  legal_threat      hide first, identity after (10-23 exception) -- except a big-name page, which goes to Jan

A claim is ONE path, never a requirement (Aaron 1 Nov; claim-first is the DMCA rule).

Prompt-injection rule (firstmate spec): the request text only says WHICH pages the request is about; it never
decides that a page is hidden. Every page is decided on its own by the rules above from the core replica, the
catalog and the Intercom contact. A name or claim that does not match is ASK, never a guess. The legal name is
read from the sender name and email only, never from free text in the message.
"""
from __future__ import annotations

import itertools
import re
import unicodedata
from dataclasses import dataclass, field

BIG_POPULARITY = 60
BIG_CREDITS = 50

# Verdicts per page. PASS_* and LEGAL_HIDE_FIRST make the page hide-eligible; everything else does not.
PASS_A, PASS_B, PASS_C, PASS_D = "PASS_A", "PASS_B", "PASS_C", "PASS_D"
LEGAL_HIDE_FIRST = "LEGAL_HIDE_FIRST"
ALREADY_HIDDEN = "ALREADY_HIDDEN"
ASK_LINK, ASK_IDENTITY, ASK_AUTH = "ASK_LINK", "ASK_IDENTITY", "ASK_AUTH"
JAN_BIGNAME, JAN_REVIEW = "JAN_BIGNAME", "JAN_REVIEW"
DMCA_REVIEW = "DMCA_REVIEW"
GONE = "GONE"
NOT_ERASURE = "NOT_ERASURE"
UNKNOWN = "UNKNOWN"
HIDE_ELIGIBLE = (PASS_A, PASS_B, PASS_C, PASS_D, LEGAL_HIDE_FIRST)
IDENTITY_PASS = (PASS_A, PASS_B, PASS_C, PASS_D)     # the daily batch takes these; legal hide-first is the captain's

FREEMAIL = frozenset("""gmail.com googlemail.com yahoo.com yahoo.fr yahoo.co.uk hotmail.com hotmail.fr outlook.com live.com
msn.com icloud.com me.com mac.com aol.com gmx.de gmx.net gmx.com web.de proton.me protonmail.com pm.me mail.com
yandex.ru yandex.com mail.ru orange.fr free.fr laposte.net libero.it qq.com 163.com naver.com zoho.com
tutanota.com hey.com fastmail.com""".split())


@dataclass
class Page:
    """What the catalog / core replica say about one page the request is about (never the request text)."""
    entity_id: str
    entity: str = "profile"                 # profile | track | album
    found: bool = True                      # False: the catalog read failed or 404 -> UNKNOWN, never "no page"
    name: str = ""
    is_claimed: bool = False
    claim_user_ids: frozenset = frozenset()  # accounts holding a PROCESSED claim
    popularity: float = 0
    credit_count: int = 0
    website: str = ""
    hidden: bool = False                    # already in HIDDEN_ENTITY_IDS AND the sitemap legal_hidden list
    gone: bool = False                      # the catalog AND the public page both answer 404 (deleted / merged)
    facts_unknown: str = ""                 # comma-joined SAFETY fields the catalog did not state (isClaimed, …):
                                            # absence is not "unclaimed and small", so no path may pass


@dataclass
class Requester:
    name: str = ""
    email: str = ""
    account_id: int | None = None           # resolved by identity_resolver r5 / unique account email
    account_names: tuple = ()               # that account's firstname+lastname / fullname
    representative: bool = False            # privacy service, lawyer, manager writing for someone else
    verified: bool = False                  # the address is PROVEN ours: authenticated mail sender, or a logged-in
                                            # account's own address. A self-typed Lead email proves nothing, so it
                                            # can never carry path D on its own.


@dataclass
class PageVerdict:
    entity_id: str
    verdict: str
    why: str


@dataclass
class Decision:
    verdict: str                            # the row verdict (most restrictive page wins; see ROW_ORDER)
    basis: str                              # A/B/C/D/legal joined by '+'; '' when no path passed
    pages: list = field(default_factory=list)


def fold_tokens(s: str) -> list[str]:
    s = unicodedata.normalize("NFKD", str(s or ""))
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return [t for t in re.split(r"[^a-z0-9]+", s) if t and not t.isdigit()]


def names_equal(a: str, b: str) -> bool:
    """Same multiset of folded name tokens, at least two of them (a legal name, not a mononym)."""
    ta, tb = fold_tokens(a), fold_tokens(b)
    return len(ta) >= 2 and sorted(ta) == sorted(tb)


def local_part_equals(email: str, page_name: str) -> bool:
    """The email local part spells the page's name: arpad.laczkovszki / laczkovszkiarpad == 'Laczkovszki Arpad'."""
    local = (email or "").split("@")[0]
    lt = [re.sub(r"\d+$", "", t) for t in fold_tokens(local)]
    lt = [t for t in lt if t]
    pt = fold_tokens(page_name)
    if len(pt) < 2 or not lt or len(pt) > 4:
        return False
    if len(lt) >= 2:
        return sorted(lt) == sorted(pt)
    return any(lt[0] == "".join(p) for p in itertools.permutations(pt))


def host_of(s: str) -> str:
    """The exact normalized HOST of an email or a URL: lowercase, scheme/path/port/user stripped, leading `www.`
    dropped (the ONLY equivalence path D is allowed to make). `agency.example.com` stays `agency.example.com`.

    A registrable-domain reduction here would let a verified sender at `agency.example.com` pass path D against a
    catalog website at `artist.example.com` and put an unrelated profile into a hide batch, so the comparison below
    uses this function, never a parent domain."""
    s = (s or "").lower().strip()
    s = re.sub(r"^[a-z]+://", "", s).split("/")[0].split("@")[-1].split(":")[0]
    s = re.sub(r"^www\.", "", s)
    return s if "." in s and not s.startswith(".") and not s.endswith(".") else ""


def domain_of(s: str) -> str:
    """The registrable domain (`a.b.example.co.uk` -> `example.co.uk`). NOT an identity comparison: see host_of."""
    s = host_of(s)
    parts = [x for x in s.split(".") if x]
    if len(parts) >= 3 and parts[-2] in ("co", "com", "org", "net") and len(parts[-1]) == 2:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:]) if len(parts) >= 2 else ""


def big_name(p: Page) -> bool:
    return (p.popularity or 0) >= BIG_POPULARITY or (p.credit_count or 0) >= BIG_CREDITS


def decide_page(p: Page, r: Requester, cls: str) -> PageVerdict:
    def v(verdict: str, why: str) -> PageVerdict:
        return PageVerdict(p.entity_id, verdict, why)

    if not p.found:
        if len(p.entity_id) == 8:
            return v(UNKNOWN, "only an 8-char id prefix is on file and no catalog profile matches it uniquely: the "
                              "full link must be read from the mail thread")
        return v(UNKNOWN, "catalog read failed or the page was not found: re-read next run, never assumed absent")
    if p.gone:
        return v(GONE, "the catalog and the public page both answer 404: removed outside the hide process "
                       "(deleted or merged); a person confirms what happened before any letter")
    if p.hidden:
        return v(ALREADY_HIDDEN, "already in HIDDEN_ENTITY_IDS and the sitemap legal_hidden list")
    if p.entity != "profile":
        return v(JAN_REVIEW, f"a {p.entity} page: identity paths A-D are about profiles; Jan decides the scope")
    if p.facts_unknown:
        # Fail closed on the fields that decide whether C may pass and whether this is a big name for Jan. Reading a
        # missing field as False/0 turned "we do not know if it is claimed" into "unclaimed", and "unknown
        # popularity" into "not a big name" - an automatic hide on facts the catalog never stated (QA a3e68886a).
        return v(UNKNOWN, f"the catalog answer did not state {p.facts_unknown} for this page: claimed status and "
                          f"the big-name exclusion cannot be established, so no path may pass; re-read next run")
    if cls == "dmca_takedown":
        if r.account_id is not None and r.account_id in p.claim_user_ids:
            return v(PASS_A, "DMCA claim-first: the requesting account holds the processed claim")
        return v(DMCA_REVIEW, "DMCA/takedown is claim-first (captain 10-23): the requester holds no processed claim")
    if cls == "legal_threat":
        if big_name(p):
            return v(JAN_BIGNAME, f"legal threat on a big-name page (popularity {p.popularity}, {p.credit_count} credits)")
        return v(LEGAL_HIDE_FIRST, "legal threat: hide first, identity after (10-23 exception); the captain owns the reply")
    if not (r.name or r.email or r.account_id is not None):
        return v(UNKNOWN, "no requester on file (the mail ledger keeps no sender): the thread must be read before "
                          "any identity path can be tried")
    # E comes BEFORE A: a claim held by the ACCOUNT that is writing does not authorise a request made for someone
    # else (v2 §3: a representative needs the data subject's written authorisation). Only legal_threat above is
    # exempt, by the captain's hide-first rule.
    if r.representative:
        return v(ASK_AUTH, "E: writing for someone else -> ask for the data subject's written authorisation")
    if r.account_id is not None and r.account_id in p.claim_user_ids:
        return v(PASS_A, f"A: account {r.account_id} holds the processed claim on the page")
    if p.is_claimed or p.claim_user_ids:
        return v(ASK_IDENTITY, "the page is claimed by an account that is not the requester's: mismatch = ASK")
    if r.account_id is not None and any(names_equal(n, p.name) for n in r.account_names):
        return v(PASS_B, f"B: the contact resolves to account {r.account_id}, whose name matches the page")
    if names_equal(r.name, p.name) or local_part_equals(r.email, p.name):
        if big_name(p):
            return v(JAN_BIGNAME, f"C would pass, but a big-name page (popularity {p.popularity}, "
                                  f"{p.credit_count} credits) goes to Jan")
        # The name/email on a ticket without a conversation is requester-typed metadata: without verified sender
        # provenance an unrelated unclaimed profile could be named and hidden. Verify before C can pass.
        if not r.verified:
            return v(ASK_IDENTITY, "C would pass on the requester's name/email, but the sender is not verified: "
                                   "ask for a written authorisation from that address")
        return v(PASS_C, "C: unclaimed page whose display name equals the requester's name (name-fold)")
    sd, wd = host_of(r.email), host_of(p.website)
    if sd and wd and sd not in FREEMAIL and sd == wd:
        if r.verified:
            return v(PASS_D, f"D: verified sender host {sd} is the page's own website host in our catalog")
        return v(ASK_IDENTITY, f"D would pass on the address host {sd}, but the sender is not verified: "
                               f"ask for a written authorisation from that address")
    return v(ASK_IDENTITY, "no path passed: the name does not match and there is no claim, account or domain")


# Row verdict: the most restrictive page wins, so a PASS page never carries an ASK page with it in the row
# summary. The hide batch still takes every hide-eligible PAGE of a mixed row (decide per page, act per page).
ROW_ORDER = (UNKNOWN, NOT_ERASURE, ASK_LINK, JAN_BIGNAME, JAN_REVIEW, GONE, DMCA_REVIEW, ASK_AUTH, ASK_IDENTITY,
             LEGAL_HIDE_FIRST, PASS_A, PASS_B, PASS_D, PASS_C, ALREADY_HIDDEN)
BASIS = {PASS_A: "A", PASS_B: "B", PASS_C: "C", PASS_D: "D", LEGAL_HIDE_FIRST: "legal"}


def decide(pages: list[Page], r: Requester, cls: str) -> Decision:
    if cls not in ("privacy_erasure", "legal_threat", "dmca_takedown"):
        return Decision(NOT_ERASURE, "", [])
    if not pages:
        return Decision(ASK_LINK, "", [])
    pv = [decide_page(p, r, cls) for p in pages]
    row = min((x.verdict for x in pv), key=ROW_ORDER.index)
    bases = sorted({BASIS[x.verdict] for x in pv if x.verdict in BASIS})
    return Decision(row, "+".join(bases), pv)


# What the pipeline does next for a row verdict (the backfill table's "action" column).
ACTION = {
    UNKNOWN: "re-read next run (a failed read is never a verdict)",
    NOT_ERASURE: "not an erasure request (misfiled ticket): no hide, no letter",
    ASK_LINK: "ASK: link line",
    ASK_IDENTITY: "ASK: confirm-it's-you (v2 step 1)",
    ASK_AUTH: "ASK: written authorisation",
    JAN_BIGNAME: "Jan: big-name / high-credit page",
    JAN_REVIEW: "Jan: scope (non-profile page)",
    DMCA_REVIEW: "copyright review (claim-first)",
    GONE: "Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter",
    LEGAL_HIDE_FIRST: "captain: legal threat, hide first (hide-batch --include-legal), identity after",
    PASS_A: "hide batch", PASS_B: "hide batch", PASS_C: "hide batch", PASS_D: "hide batch",
    ALREADY_HIDDEN: "verify S/P/M, confirm by due date",
}


def action_for(verdict: str, detail: list[dict]) -> str:
    """ACTION, made specific where the row cannot move without a person reading the thread."""
    if verdict == UNKNOWN and any(d["verdict"] == UNKNOWN and (d["why"].startswith("only an 8-char")
                                                              or d["why"].startswith("no requester"))
                                  for d in detail):
        return ("read the mail thread: the full page link and the sender are not on file (the Gmail readers are "
                "disabled since 31 Oct), then the next run decides")
    return ACTION[verdict]
