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

import hashlib
import types

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

# The classes the ASK copy was written for. `ASK` is ERASURE copy: LINK_LINE asks for "the Muso page(s) concerned"
# and PROGRESS_LINE says "The deletion request you made on {received} is in progress". A `dmca_takedown` or
# `legal_threat` row carries the same `ASK_LINK` verdict, so a kind-only gate sent erasure words to a rights-holder's
# takedown notice and to a legal threat - and 15 of those rows were already past their date, so the FIRST unattended
# tick would have said it to them (QA finding on #1779; measured on the live register 2026-11-06: 5 dmca_takedown and
# 30 legal_threat rows carry ASK_LINK, 15 of them past due).
#
# Adding a class here releases customer-facing copy, so it is added in the PR that carries that class's ruling -
# never in advance, and never by widening the tuple during a bug fix. Same rule as
# NEW_THREAD_SUBJECT_APPROVED_CLASSES, and for the same reason.
ASK_APPROVED_CLASSES = ("privacy_erasure",)

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


# OPTION 2 (firstmate inbox 073, 2026-11-04T08:52Z): when a request arrived at notices@ or legal@ and there is no
# thread to reply on, the answer opens a NEW thread from support@. That is a different letter to a different
# relationship, so its FIRST LINE must name the request the person actually made: the mailbox they wrote to and the
# date they wrote. This is a BODY CHANGE, not a re-cut, so it needs its own GO: send the ONE-LINE variant below to
# verify-sla-driver-fable-d2 and set NEW_THREAD_LEAD_APPROVED = True in the PR that carries that ruling. While it is
# False, `send.route` REFUSES a notices@/legal@ row with no thread and names this constant, so nothing goes out with
# copy nobody approved.
#
# The line is NOT in MAILBOX_BY_CHANNEL's support@ form: it names the mailbox the PERSON chose, because the whole
# point of the line is that we noticed which door they knocked on.
NEW_THREAD_LEAD = ("You wrote to us at {mailbox} on {date} about {request_details}.")
# The SUBJECT is customer-facing copy too, and it is new: the ruling named the first line, not the subject. It travels
# in the same GO (it is the same message), so it lives next to the lead rather than being typed inside the adapter
# where nobody would review it.
NEW_THREAD_SUBJECT = "Your Muso.AI data {request_type} request"
# BOTH are gated, and by SEPARATE constants on purpose.
#
# The lead line was approved by legal-finalize-fable-k1 on 2026-11-04 (ruling id NEW_THREAD_LEAD_RULING).
# The GO did NOT mention the subject - and silence is not approval for copy that goes to a customer - so the subject
# kept its own gate and the send refused naming it. Flipping one must not silently release the other.
#
# THE SUBJECT'S OWN GO (firstmate 099, ruling [key=gdpr-support-from-1104], relayed verbatim): "SUBJECT GO under this
# ruling: 'Your Muso.AI data deletion request' for the deletion class ONLY ... an access/correction/objection row never
# gets a 'deletion' subject and stays refused until its own subject is written; flip NEW_THREAD_SUBJECT_APPROVED=True
# in the same PR citing this key". So the GO is real but it is CLASS-SCOPED: the approved subject is the deletion one,
# and a row whose request type is access / correction / objection REFUSES rather than borrowing words whose GO does
# not cover them. A subject is the one line a person reads before anything else; getting it wrong misdescribes what
# they asked for in the same way the lead's third guard forbids, one field over.
NEW_THREAD_LEAD_APPROVED = True
NEW_THREAD_SUBJECT_APPROVED = True
NEW_THREAD_LEAD_RULING = "legal-finalize-fable-k1/2026-11-04-new-thread-lead"
NEW_THREAD_SUBJECT_RULING = "gdpr-support-from-1104"
# The classes whose subject has a GO. NOT a formality: adding a class here releases customer-facing copy, so the row
# is added in the PR that carries that class's ruling - never in advance, and never by widening a tuple during a bug
# fix. `privacy_erasure` is the deletion class; the other three stay refused until each gets its own GO.
NEW_THREAD_SUBJECT_APPROVED_CLASSES = ("privacy_erasure",)
# THE REQUEST TYPE MUST BE THEIR OWN WORDS (the GO's third guard: "never characterise it beyond their own words").
# The approved vocabulary is these four and nothing else, so a class that does not map onto one REFUSES rather than
# being described as something the person never asked for. On 2026-11-04 that is not hypothetical: of the rows this
# route could reach, 2 are dmca_takedown and 1 is legal_threat, and calling a rights-holder's takedown notice a
# "deletion request" would be a false statement to the person who sent it.
NEW_THREAD_REQUEST_TYPE = {
    "privacy_erasure": "your deletion request",
    "privacy_access": "your access request",
    "privacy_correction": "your correction request",
    "privacy_objection": "your objection request",
}


class NoApprovedRequestType(ValueError):
    """The row's class is outside the approved vocabulary, so any phrase would characterise it. Refuse, never guess."""


class NoApprovedSubject(ValueError):
    """The class HAS a request-type phrase but its subject has no GO. Refuse - a sentence nobody approved is still
    copy nobody approved, and the one-line subject is the first thing the recipient reads."""


def new_thread_request_type(cls: str) -> str:
    """The phrase for `{request_details}`, from the approved four - or raise, naming what the row actually is."""
    try:
        return NEW_THREAD_REQUEST_TYPE[cls]
    except KeyError:
        raise NoApprovedRequestType(
            f"class {cls!r} has no approved request-type phrase, so this letter would have to describe the request in "
            f"words the person did not use. The approved vocabulary is {sorted(NEW_THREAD_REQUEST_TYPE)}; teach it the "
            f"class with the owner's GO, or the letter does not leave") from None


def new_thread_subject(cls: str) -> str:
    """The subject for a new thread, derived from the SAME vocabulary as the lead.

    Derived, not fixed: a single "data deletion request" subject on a row whose class is privacy_access would put the
    wrong request in the inbox line - the same mischaracterisation the lead's third guard forbids, one field over.

    Derived AND gated: the derivation says what the subject WOULD say, `NEW_THREAD_SUBJECT_APPROVED_CLASSES` says
    whether anybody approved saying it. Ruling gdpr-support-from-1104 approved the deletion subject only, so an
    access/correction/objection row raises here instead of shipping a line whose GO does not cover it."""
    request_type = new_thread_request_type(cls)
    if cls not in NEW_THREAD_SUBJECT_APPROVED_CLASSES:
        raise NoApprovedSubject(
            f"class {cls!r} has no approved SUBJECT line: ruling {NEW_THREAD_SUBJECT_RULING} covers the deletion "
            f"subject only (approved classes: {list(NEW_THREAD_SUBJECT_APPROVED_CLASSES)}). The line would read "
            f"{NEW_THREAD_SUBJECT.format(request_type=request_type.removeprefix('your ').removesuffix(' request'))!r}, "
            f"which no owner has approved for this class - write and approve it before this letter leaves")
    kind = request_type.removeprefix("your ").removesuffix(" request")   # "deletion"
    return NEW_THREAD_SUBJECT.format(request_type=kind)


def new_thread_lead(mailbox: str, received_iso: str, request_details: str = "your deletion request") -> str:
    """The mandatory first line when we open a new thread from support@ for a notices@/legal@ request.

    `mailbox` is the address the PERSON wrote to (notices@muso.ai / legal@muso.ai), never support@ - the line exists
    so the person can see we know which door they used. `request_details` is what they asked for, in their words.
    """
    return NEW_THREAD_LEAD.format(mailbox=mailbox, date=human_date(received_iso), request_details=request_details)


def new_thread_letter(mailbox: str, received_iso: str, cls: str, text: str) -> tuple[str, str]:
    """(body, subject) for a letter that opens a NEW thread from support@ - the whole customer-facing assembly.

    This lives HERE, not in `send.py`, because `copy.fingerprint()` is what a month-long standing ruling names and it
    can only cover what this module owns. It used to be assembled in `send.final_letter`, so an edit there could add
    or change a customer-facing line while both standing rulings' `copy_sha` still matched and the unattended tick
    sent wording the grant never named (QA finding on #1779, verified by inserting a disclosure line and watching
    `copy-sha` stay put). `send.final_letter` now only decides WHETHER to assemble and who the recipient is; every
    byte of the letter is produced here, and `_COPY_RENDERERS` covers this function's behaviour."""
    lead = new_thread_lead(mailbox, received_iso, new_thread_request_type(cls))
    return lead + "\n\n" + text, new_thread_subject(cls)


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


# ---------------------------------------------------------------- the copy identity a STANDING ruling binds
# A standing ruling authorises an UNATTENDED send for a month. The interactive path does not need this: a human reads
# the digest and approves the batch they can see. A standing grant is cut once and then runs by itself, so it has to
# name the WORDS it was cut for - otherwise editing any approved sentence (or flipping a copy gate) leaves the grant
# live and the tick keeps sending text nobody approved, which is the exact failure the digest exists to prevent, one
# level up (QA finding on #1779).
#
# The tuple is the whole customer-facing surface, in a fixed order, and it includes the GATES: flipping
# NEW_THREAD_LEAD_APPROVED changes what a recipient receives without changing a single string, so a fingerprint over
# strings alone would miss it. Adding a constant here is part of adding copy.
_COPY_IDENTITY = (
    "LINK_LINE",
    "IDENTITY_STEP",
    "AUTH_LINE",
    "PROGRESS_LINE",
    "CONFIRM_HEAD",
    "LINE_S",
    "LINE_P",
    "LINE_M",
    "NEXT_HEAD",
    "LINE_D_NO",
    "LINE_P_PENDING",
    "CONFIRM_TAIL",
    "NEW_THREAD_LEAD",
    "NEW_THREAD_SUBJECT",
    "NEW_THREAD_REQUEST_TYPE",
    "PIPELINE_SENDS_APPROVED",
    "PROGRESS_LINE_APPROVED",
    "NEW_THREAD_LEAD_APPROVED",
    "NEW_THREAD_SUBJECT_APPROVED",
    "NEW_THREAD_SUBJECT_APPROVED_CLASSES",
    "ASK_APPROVED_CLASSES",
    # The MAPPING the sender actually reads, not just the constants it was built from. `run.py` sends
    # `copy.ASK[kind]`, so a mapping-only edit (repointing ASK["ASK_LINK"] at a different string, or at a new
    # constant) changes the outgoing letter while every constant above stays byte-identical - the grant would still
    # pass and send words its `copy_sha` never covered (QA finding on #1779).
    "ASK",
)

# The RENDERERS, hashed by BEHAVIOUR rather than by text. A constant can be untouched while the function that
# assembles it into a letter changes what the recipient reads (a dropped line, a reordered slot, a new default), and
# that is the same hole one level down. Hashing the source would also move on a comment typo, which trains people to
# re-cut without reading - the opposite of what the grant is for, so this hashes bytecode + constants + names.
_COPY_RENDERERS = (
    "render_confirmation",
    "progress_line",
    "new_thread_lead",
    "new_thread_subject",
    "new_thread_request_type",
    "new_thread_letter",
    # TRANSITIVE, and the reason this list is checked rather than trusted: every letter above formats its dates
    # through `human_date`, so changing that one function's format changes every customer-facing body while the
    # renderers themselves are untouched (QA finding on #1779). `_transitive_helpers` walks the renderers' bytecode
    # so the NEXT helper of this shape fails CI instead of shipping under a live grant.
    "human_date",
)


def _transitive_helpers() -> set[str]:
    """The module-level functions a renderer reaches that are NOT already in `_COPY_RENDERERS` - i.e. the gap.

    The fingerprint is only as good as its coverage, and a hand-maintained list is exactly how `human_date` was
    missed. This is the mechanical answer: walk each renderer's `co_names`, follow anything that resolves to a
    function defined HERE, and repeat. A test asserts the result is EMPTY, so the next helper of this shape fails CI
    instead of shipping under a live grant."""
    seen: set[str] = set()
    todo = list(_COPY_RENDERERS)
    while todo:
        name = todo.pop()
        fn = globals().get(name)
        if not isinstance(fn, types.FunctionType):
            continue
        for ref in fn.__code__.co_names:
            target = globals().get(ref)
            if (isinstance(target, types.FunctionType) and target.__module__ == __name__
                    and ref not in seen and ref not in _COPY_RENDERERS):
                seen.add(ref)
                todo.append(ref)
    return seen


def _code_identity(fn) -> str:
    """A function's behaviour: its bytecode, names and constants, recursively into nested code objects.

    Comments and whitespace do not move it; anything that could change the rendered words does."""
    h = hashlib.sha256()

    def walk(code) -> None:
        h.update(code.co_code)
        h.update(repr(code.co_names).encode())
        h.update(repr(code.co_varnames).encode())
        for const in code.co_consts:
            if isinstance(const, types.CodeType):
                walk(const)
            else:
                h.update(repr(const).encode())

    walk(fn.__code__)
    return h.hexdigest()[:16]


def fingerprint() -> str:
    """The identity of the approved copy in THIS tree. A standing ruling records it; a mismatch refuses the send.

    Re-cut it with `gdpr-pipeline.py copy-sha` in the PR that changes any approved sentence, and put the new value in
    the ruling - which is a reviewed commit, so the words and the grant move together or not at all."""
    h = hashlib.sha256()
    for name in _COPY_IDENTITY:
        # Read the CURRENT module attribute, not a snapshot taken at import: the fingerprint has to answer "what does
        # this tree render NOW", so a patched or edited constant must move it.
        value = globals()[name]
        # A mapping is hashed SORTED: the identity is the mapping, not the order somebody happened to type it in.
        rendered = repr(sorted(value.items())) if isinstance(value, dict) else repr(value)
        h.update(f"{name}={rendered}\n".encode())
    for name in _COPY_RENDERERS:
        h.update(f"{name}()={_code_identity(globals()[name])}\n".encode())
    return h.hexdigest()[:16]
