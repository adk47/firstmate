"""The send path: one ledgered letter per request, through the approved writers only.

The copy is NOT composed here. `deliver` carries `copy.ASK[...]` / `copy.render_confirmation(...)` verbatim, so the
only thing this module decides is WHERE a letter goes and whether it may go at all.

Routing is by what the register actually recorded, and every route fails CLOSED:

  conversation_id (numeric)        -> scripts/intercom-ops-write.sh reply --customer-facing --approved-by <human>
                                      (the wrapper is the deterministic gate: pinned Caroline identity, internal-leak
                                      refusal, api-log row written BEFORE the POST, part_type checked after)
  gmail_thread on a known chan.   -> gog gmail send --account <THE MAILBOX THAT OWNS THE THREAD> --thread-id <t>
                                      --reply-all. The account is per ROW, not a constant: a reply must leave from the
                                      mailbox the thread lives in, or gog refuses the thread (or, worse, answers from
                                      the wrong address). Hardcoding support@ is why "just auth the mailbox" was not
                                      enough on its own - the code pinned the account too.
  notices@/legal@                  -> mail_new_thread: open a NEW thread from support@ to the row's own address,
  with an UNWRITABLE mailbox          whose first line names the request the person actually made (inbox 073). The
                                      thread usually EXISTS - every open notices@/legal@ row carried one on
                                      2026-11-04 - it just lives in a mailbox this host cannot write, and a reply
                                      from the wrong address is a different letter to a different relationship.
                                      Needs the approved lead AND an address on the row, and refuses naming WHICH
                                      of the two is missing.
  anything else                    -> Unknown:  no conversation id and no thread, so a letter would have to open a
                                      NEW thread with copy nobody approved. Naming that is the point: a silent skip
                                      would leave the row looking "written to" when nothing left the building.

WHY A LEDGER ROW BEFORE THE WRITE
`erasure_sends` is UNIQUE(request_id, kind), so a second attempt for the same request is a refusal rather than a
second letter, and the row is written in state `sending` BEFORE the adapter runs (the same posture as
intercom-ops-write.sh's api-log-before-POST). A crash between the two leaves a `sending` row a human can see; the
alternative -- write after the fact -- leaves a letter the register does not know about.

The gate (`copy.PIPELINE_SENDS_APPROVED`) and the human allowlist are enforced in the CLI, not here, so this module
can be exercised in full by the tests without a live send.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess

from . import copy
from .store import now_iso

INTERCOM_WRITER = "intercom-ops-write.sh"      # resolved next to the CLI (scripts/), never hand-typed
MAIL_ACCOUNT = "support@muso.ai"        # the fallback mailbox for a row whose channel is not in the table below
# THE ACCOUNT EVERY LETTER IS SENT FROM, per channel. Captain, 2026-11-06: "can you use support as your outbound
# channel please". legal@muso.ai is an alias for Aaron and notices@muso.ai is an alias for Kyran - neither is a mailbox
# this host can sign into and neither is a separate account, so there is nothing to send AS. The table stays (the
# channel concept is real, and `route` still needs to know which channels' threads live somewhere we cannot write)
# but every entry is support@. See THREAD_MAILBOX_BY_CHANNEL below for the ownership question, which is a different
# fact and must not be collapsed with this one.
MAILBOX_BY_CHANNEL = {"support": "support@muso.ai", "notices": "support@muso.ai", "legal": "support@muso.ai"}
# The mailbox that OWNS a thread, per channel - a fact about where the thread LIVES, not about who we send as. Because
# notices@/legal@ are aliases rather than accounts, a thread in one is never writable, which is exactly what `route`
# needs to know to open a new thread from support@ instead of refusing.
THREAD_MAILBOX_BY_CHANNEL = {"support": "support@muso.ai", "notices": "notices@muso.ai", "legal": "legal@muso.ai"}
GOG_ENV = ("GOG_KEYRING_PASSWORD",)     # gog cannot read its keyring without it
SEND_LOCK_ENV = "MUSOAI_INTERCOM_TOKEN"

# The Intercom writer's exit-code contract, from its own header: 0 ok · 1 refusal · 2 usage/environment error ·
# 4 post failed or wrong part_type. `refuse()` and `die()` are the ONLY producers of 1 and 2, and every call to them
# sits in the validation block ABOVE the POST (scripts/intercom-ops-write.sh: the POST is the only thing after them),
# so a 1 carrying "REFUSED:" or a 2 carrying "ERROR:" is PROOF that nothing was posted. Anything else stays
# ambiguous: a bare 1 is also how `set -e` reports an unexpected failure, and that one may have posted.
WRITER_PREFLIGHT_RC = {1: "REFUSED:", 2: "ERROR:"}
# The writer's machine-authorization class (scripts/intercom-ops-write.sh PURPOSE_TABLE). A purpose write carries no
# human id and is bounded by the register that must own the conversation.
INTERCOM_PURPOSE = "gdpr-erasure"
# The two shapes a pre-flight refusal is recorded in `erasure_sends.detail`: the one this module writes now, and the
# one it wrote before the distinction existed (rows already in the live ledger). `reconcile` reads BOTH, so the 40
# letters the 2026-11-06 tick stranded are recoverable without hand-editing the store.
_PREFLIGHT_DETAIL = re.compile(
    re.escape(INTERCOM_WRITER) + r" (?:refused BEFORE posting \(rc [12]\)|exited rc [12] after being invoked): "
    r"(?:REFUSED|ERROR):")


def preflight_refusal(detail: str) -> bool:
    """True when a recorded `unknown` detail PROVES the writer refused before it posted anything.

    This is the discriminator `reconcile` uses to move a stranded row from `unknown` (never retried, a human's to
    resolve) back to `failed` (retryable). It is deliberately narrow: only the writer's own pre-POST refusal text
    matches, so a timeout, a dropped connection or a bare non-zero exit stays ambiguous and stays a human's."""
    return bool(_PREFLIGHT_DETAIL.search(detail or ""))


class Unknown(Exception):
    """A route the pipeline cannot take, raised BEFORE the writer runs: nothing was sent, so a retry is safe once a
    human fixes the cause. The caller records it as `refused`/`failed`; it is never a silent skip."""


class Ambiguous(Exception):
    """The writer RAN and we cannot prove what it did: a timeout, a dropped connection, a non-zero exit after the
    request was built. The customer may have the letter, so this is NEVER a retry (Fable r5 finding 1: a retry after
    an ambiguous POST is two statutory letters for one request). It is recorded as `unknown` and a human reconciles."""


def body_sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


NEW_THREAD_CHANNELS = ("notices", "legal")   # the two mailboxes firstmate inbox 073 names, and only those
# Mailboxes that are ALIASES for a person, not accounts (captain, 2026-11-06: legal@ is Aaron, notices@ is Kyran).
# Nothing can ever be authed for one, so "auth it and the route opens" is false advice for them and must not be said:
# an operator who reads it goes looking for a mailbox that does not exist instead of recovering the address.
ALIAS_MAILBOXES = ("notices@muso.ai", "legal@muso.ai")


def _why_not_the_old_thread(channel: str, thread: str, why: str) -> str:
    """The reason a thread cannot be replied in, phrased for the fix that actually exists."""
    mailbox = THREAD_MAILBOX_BY_CHANNEL.get(channel, "")
    if mailbox in ALIAS_MAILBOXES:
        return (f"its thread {thread} is in {mailbox}, which is an alias for a person rather than an account "
                f"(captain, 2026-11-06), so this host can never reply in it")
    return f"its thread {thread} is in a mailbox this host cannot write ({why})"


def _new_thread(row: dict, why_not_the_old_thread: str) -> tuple[str, str]:
    """Option 2: a new thread from support@ to the person's own address.

    Three things can still make this impossible, and each must be SAID rather than silently skipped: a piece of copy
    has no GO yet (the lead line, or the subject); the row carries no address to send to (53 of the 70 notices@/
    legal@ rows on 2026-11-04 have no requester_email, so "no address" is the common case, not an edge); or the row's
    class is outside the approved request-type vocabulary, where any phrase would characterise the request in words
    the person did not use. They have different fixes, so they get different messages."""
    channel = row.get("channel")
    requester_email = str(row.get("requester_email") or "").strip()
    if not copy.NEW_THREAD_LEAD_APPROVED:
        raise Unknown(f"{channel} request needs a new thread from support@ ({why_not_the_old_thread}), but the "
                      f"one-line lead copy is not approved yet (copy.NEW_THREAD_LEAD_APPROVED = False): send the "
                      f"one-line variant to verify-sla-driver-fable-d2 for its GO before sending")
    if not copy.NEW_THREAD_SUBJECT_APPROVED:
        # SEPARATE from the lead on purpose: the GO named the first line and said nothing about the subject, and
        # silence is not an owner's approval for copy that reaches a customer.
        raise Unknown(f"{channel} request needs a new thread from support@ ({why_not_the_old_thread}), but the "
                      f"subject line {copy.NEW_THREAD_SUBJECT!r} has no GO of its own "
                      f"(copy.NEW_THREAD_SUBJECT_APPROVED = False): it is customer-facing copy the lead ruling did "
                      f"not cover, so it needs the owner's GO before sending")
    try:
        copy.new_thread_request_type(row.get("class") or "")
    except copy.NoApprovedRequestType as exc:
        raise Unknown(f"{channel} request ({why_not_the_old_thread}): {exc}") from None
    # THE SUBJECT'S GO IS CLASS-SCOPED (ruling gdpr-support-from-1104): it approved "Your Muso.AI data deletion
    # request" for the deletion class and said an access/correction/objection row "stays refused until its own
    # subject is written". The request-type check above only proves the class is in the approved FOUR - this one
    # proves this class's SUBJECT was approved, so a privacy_access row cannot ship the deletion subject or a derived
    # line nobody has read. Deliberately a separate refusal: 'this class cannot be described' and 'this class's
    # subject has no GO' have different fixes.
    cls = row.get("class") or ""
    try:
        copy.new_thread_subject(cls)
    except copy.NoApprovedSubject as exc:
        raise Unknown(f"{channel} request ({why_not_the_old_thread}): {exc}") from None
    if not requester_email:
        raise Unknown(f"{channel} request: {why_not_the_old_thread}, and the row has no requester_email, so there is "
                      f"nowhere to open a new thread to either. The address has to be recovered from the original "
                      f"message and recorded on the row before this letter can leave")
    return "mail_new_thread", requester_email


def route(row: dict) -> tuple[str, str]:
    """(kind, target) for this request, or Unknown with the reason a human needs to fix."""
    conv = str(row.get("conversation_id") or "").strip()
    if conv:
        if not conv.isdigit():
            raise Unknown(f"conversation_id {conv!r} is not a numeric Intercom id")
        return "intercom", conv
    thread = str(row.get("gmail_thread") or "").strip()
    channel = row.get("channel")
    requester_email = str(row.get("requester_email") or "").strip()
    if thread:
        if channel not in THREAD_MAILBOX_BY_CHANNEL:
            raise Unknown(f"{channel} thread {thread} has no known mailbox, so a reply would have to guess "
                          f"which account owns it; add the channel to THREAD_MAILBOX_BY_CHANNEL")
        owner = THREAD_MAILBOX_BY_CHANNEL[channel]
        ok, why = mailbox_writable(owner)
        if ok is True:
            return "mail", thread
        # UNMEASURABLE IS NOT WRITABLE. `gog auth list -j` failing (no gog, a 30 s timeout, unreadable JSON) used to
        # read as "writable", so a notices@/legal@ thread took the in-thread route and `_mail_send` then tried to
        # reply in it FROM support@ - a thread support@ does not own. That is a doomed attempt on a statutory letter,
        # selected by a transient read, when the approved new thread from support@ was available the whole time. The
        # only mailbox we may assume we can write when we cannot ask is the one we SEND from: there the writer is the
        # backstop and there is no other route to take. For any other owner the route that is safe under BOTH
        # readings is the new thread, so an unreadable discovery can never pick the customer-facing route.
        if ok is None and owner == mailbox_of(row):
            return "mail", thread
        # The thread EXISTS and is perfectly replying-to, but it lives in a mailbox this host cannot write.
        # That is not "no thread" - it is the mailbox gap itself, and option 2 exists for exactly this shape: the
        # register's notices@/legal@ rows ALL carry a thread (48 notices / 24 legal on 2026-11-04, 0 without), so a
        # rule keyed on "no thread" would have unblocked nobody. Do not fall through to a different refusal.
        if channel in NEW_THREAD_CHANNELS:
            return _new_thread(row, _why_not_the_old_thread(channel, thread, why))
        raise Unknown(f"{channel} thread {thread}: {why}")

    # OPTION 2 (firstmate inbox 073): a notices@/legal@ request opens a NEW thread from support@. The copy carries a
    # mandatory first line naming the mailbox the person used and the date they wrote; that line is a BODY CHANGE, so
    # it has its own GO. While NEW_THREAD_LEAD_APPROVED is False this REFUSES with the reason rather than sending copy
    # nobody approved - and it never falls back to a support@ thread silently, because that would be a different
    # letter to a different relationship.
    if channel in NEW_THREAD_CHANNELS:
        return _new_thread(row, "the row has no gmail_thread to reply in")

    raise Unknown(f"no conversation_id and no gmail_thread (requester_email "
                  f"{row.get('requester_email') or '-'}): there is nothing to reply to, so a letter would have to "
                  f"open a new thread with copy nobody approved")


def _env_missing(names: tuple[str, ...]) -> str:
    return ", ".join(n for n in names if not os.environ.get(n))


def _with_key(key: str) -> dict:
    """Hand the letter's id to the writer through its ENVIRONMENT, not its argv: neither the Intercom writer nor gog
    has an idempotency flag, and inventing one would make every real send fail on "unknown argument" (checked:
    `gog gmail send --help` has no --header, and intercom-ops-write.sh dies on an unknown flag). The ledger row is the
    actual double-send guard; the id is what a human reconciling an `unknown` row goes looking for."""
    env = dict(os.environ)
    if key:
        env["MUSO_LETTER_ID"] = key
    return env


def idem_key(rid: int, kind: str, text: str) -> str:
    """The identity of ONE letter: this request, this kind of letter, this exact body. Recorded on the ledger row and
    handed to the writer, so a retry is recognisable as a retry of the same letter rather than a second one."""
    return hashlib.sha256(f"{rid}:{kind}:{body_sha(text)}".encode()).hexdigest()[:32]


def _intercom_send(conv: str, text: str, approved_by: str, dry_run: bool, key: str = "") -> str:
    """Post the approved copy as a customer-facing Intercom reply through the wrapper that gates it.

    The writer is called in its PURPOSE mode, not with a human's Slack id. A statutory erasure letter is not a human
    request: it is an obligation with its own clock, and the writer's human allowlist exists to stop a bot writing to
    the inbox as if somebody asked. Passing a human id here (the shape this used until 2026-11-06) made the writer's
    audit log assert that a named human approved a customer-facing reply - false for an unattended standing-ruling
    send - and the writer refused it anyway, because the sender seat is a bot. `--purpose gdpr-erasure` records
    `approved_by: system:gdpr-pipeline` and lets the writer check, below us, that the erasure register owns the
    conversation. `approved_by` stays in the signature because the LEDGER still records the standing ruling's
    approver: that is the authorization chain, and it is a different fact from who posted."""
    writer = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), INTERCOM_WRITER)
    if not os.path.exists(writer):
        raise Unknown(f"{INTERCOM_WRITER} is not installed next to the pipeline: refusing to hand-compose a reply")
    if dry_run:
        # The token is checked only where it is used: a dry run posts NOTHING, so requiring production credentials to
        # rehearse a batch would only stop an operator from rehearsing on a host that has no Intercom identity.
        return "dry-run"
    missing = _env_missing((SEND_LOCK_ENV,))
    if missing:
        raise Unknown(f"{missing} is not set: the Intercom writer cannot authenticate (the gateway exports it "
                      f"from /etc/openclaw/main.env)")
    cmd = ["bash", writer, "reply", "--conversation", conv, "--purpose", INTERCOM_PURPOSE,
           "--customer-facing", "--body", text]

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120, env=_with_key(key))
    except subprocess.TimeoutExpired as exc:
        # A timeout is raised BY subprocess.run, i.e. AFTER the wrapper was invoked, so it is a member of the
        # ambiguous family and not of the "nothing happened" one. Left to the generic handler it became `failed`,
        # which is retryable, and the retry is the second statutory letter (proved on the real route: 2 letters).
        raise Ambiguous(f"{INTERCOM_WRITER} timed out after {exc.timeout}s with the reply built: it may be posted, "
                        f"so this is never a retry") from exc
    if out.returncode != 0:
        msg = (out.stderr or out.stdout).strip()
        # A pre-flight refusal is NOT ambiguous: the writer refused in its validation block, above the POST, so
        # nothing reached the customer and the row must stay retryable. Recording it as `unknown` (which the pipeline
        # never retries) is how 40 statutory letters were stranded on 2026-11-06 - every one of them refused for a
        # reason a human could fix, and none of them posted.
        # The prefix is looked for at the START OF ANY LINE, not at the start of the blob, because bash prints its
        # own diagnostic for a failed redirection BEFORE the script's `die` runs:
        #
        #     under-test.sh: line 463: /opt/.../intercom-reply-….json: Permission denied
        #     ERROR: cannot write the audit record …; refusing to write unlogged. Nothing was posted.
        #
        # `msg.startswith("ERROR:")` was False on that stderr, so a failed AUDIT WRITE - provably before the POST,
        # the writer says so itself - was classified Ambiguous, recorded `unknown`, and never retried. The exit CODE
        # already narrows this to 1 or 2, which only `refuse()` and `die()` produce, so finding the prefix on any
        # line is still proof and not a loosening (QA #1820 finding 1).
        prefix = WRITER_PREFLIGHT_RC.get(out.returncode)
        said = next((ln.strip() for ln in msg.splitlines() if ln.strip().startswith(prefix or "\0")), "")
        if prefix and said:
            raise Unknown(f"{INTERCOM_WRITER} refused BEFORE posting (rc {out.returncode}): {said[:300]}")
        # The writer already ran: Intercom may hold the reply. Ambiguous, never a retry.
        raise Ambiguous(f"{INTERCOM_WRITER} exited rc {out.returncode} after being invoked: {msg[:300]}")
    return (out.stdout.strip().splitlines() or ["posted"])[-1][:300]


def _subject_of(thread: dict) -> str:
    msgs = thread.get("messages") or []
    if not msgs:
        raise Unknown("the mail thread has no messages, so there is no subject to reply on")
    for h in (msgs[0].get("payload") or {}).get("headers") or []:
        if str(h.get("name", "")).lower() == "subject":
            s = str(h.get("value", "")).strip()
            return s if s.lower().startswith("re:") else "Re: " + s
    raise Unknown("the mail thread carries no Subject header")


_ACCOUNTS: dict | None = None
_ACCOUNTS_READ = False


def gog_accounts() -> dict[str, set[str]] | None:
    """{email: services} that gog can actually act as on THIS host, or None when that cannot be determined.

    The mailbox that owns a thread is a register fact (MAILBOX_BY_CHANNEL); whether this host can WRITE that mailbox is
    a host fact, and it must be asked rather than assumed. It used to be a hardcoded "only support@ is authed", which
    meant authing another mailbox would change nothing without a code edit - and the code would still have sent from
    support@ anyway. `gog auth list -j` is the authoritative answer and it is read ONCE per process.

    None (gog missing, unreadable, or no JSON) is NOT "nothing is authed": claiming a route we cannot prove would make
    a dry run promise letters that cannot leave, so the caller refuses on None only when a specific mailbox was asked
    about... see `mailbox_writable`."""
    global _ACCOUNTS, _ACCOUNTS_READ
    if _ACCOUNTS_READ:
        return _ACCOUNTS
    _ACCOUNTS_READ = True
    gog = shutil.which("gog")
    if not gog:
        return None
    try:
        out = subprocess.run([gog, "auth", "list", "-j"], capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            return None
        doc = json.loads(out.stdout or "{}")
        _ACCOUNTS = {a.get("email", ""): set(a.get("services") or []) for a in doc.get("accounts") or []}
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None
    return _ACCOUNTS


def mailbox_writable(mailbox: str) -> tuple[bool | None, str]:
    """(True writable / False not writable / None cannot be determined here, why). Gmail service present means the
    account can act on mail at all; `_mail_send` fails closed later if the stored grant turns out to be read-only.

    None is a THIRD state, not a synonym for True. It used to return True so "the writer will be the one to refuse",
    which is only sound for the mailbox we send from: for any other mailbox it silently selected the in-thread route
    on a transient read failure, and the writer then refused a letter that had an approved route. Callers must decide
    what an unmeasurable host fact means for THEIR route; `route()` treats it as not-writable unless the thread's
    owner is the account we send from."""
    acct = gog_accounts()
    if acct is None:
        return None, (f"whether {mailbox} is writable cannot be determined on this host: `gog auth list -j` was "
                      f"missing, timed out or returned unreadable JSON")
    if mailbox not in acct:
        return False, (f"{mailbox} is not an account gog holds on this host "
                       f"({', '.join(sorted(acct)) or 'none'}); auth it and the route opens with no code change")
    if "gmail" not in acct[mailbox]:
        return False, (f"{mailbox} is in gog but without the gmail service ({', '.join(sorted(acct[mailbox]))}); "
                       f"enable gmail for it and the route opens with no code change")
    return True, ""


def mailbox_of(row: dict) -> str:
    """The account this row's letter is SENT FROM. `route` has already refused an unknown channel.

    Not the account that owns the thread: since the 2026-11-06 ruling every channel sends from support@, and a thread
    in a mailbox we cannot write never reaches `_mail_send` at all - `route` sends it to a new thread instead."""
    return MAILBOX_BY_CHANNEL.get(row.get("channel") or "", MAIL_ACCOUNT)


def _mail_send(thread_id: str, text: str, approved_by: str, dry_run: bool, key: str = "",
               mailbox: str = MAIL_ACCOUNT) -> str:
    """Reply in the customer's own thread, FROM THE MAILBOX THAT OWNS IT (per-row, not a constant)."""
    missing = _env_missing(GOG_ENV)
    if missing:
        raise Unknown(f"{missing} is not set: gog cannot unlock its keyring (the gateway exports it from "
                      f"/etc/openclaw/main.env)")
    gog = shutil.which("gog")
    if not gog:
        raise Unknown("gog is not on PATH: no mail leaves this host without it")
    try:
        got = subprocess.run([gog, "gmail", "thread", "get", thread_id, "--account", mailbox, "-j"],
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as exc:
        # NOT ambiguous: this is a read, nothing has been written, so retrying is correct. Classified `Unknown`
        # explicitly so the ledger says "the thread read timed out" instead of showing a bare `failed`.
        raise Unknown(f"thread {thread_id}: the gog read timed out after {exc.timeout}s; nothing was written, "
                      f"so this is retryable") from exc
    if got.returncode != 0:
        raise Unknown(f"thread {thread_id} is not readable in {mailbox} ({(got.stderr or got.stdout).strip()[:200]}): "
                      f"replying there would open a new thread under copy nobody approved")
    try:
        thread = json.loads(got.stdout or "{}").get("thread") or {}
    except json.JSONDecodeError:
        raise Unknown(f"thread {thread_id}: gog returned unparseable JSON")
    subject = _subject_of(thread)
    if dry_run:
        return "dry-run"
    cmd = [gog, "gmail", "send", "--account", mailbox, "--thread-id", thread_id, "--reply-all",
           "--subject", subject, "--body", text]

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180, env=_with_key(key))
    except subprocess.TimeoutExpired as exc:
        raise Ambiguous(f"gog gmail send timed out after {exc.timeout}s with the message built: it may be in the "
                        f"thread, so this is never a retry") from exc
    if out.returncode != 0:
        # gog already ran: the message may be in the thread. Ambiguous, never a retry.
        raise Ambiguous(f"gog gmail send exited rc {out.returncode} after being invoked: "
                        f"{(out.stderr or out.stdout).strip()[:300]}")
    return (out.stdout.strip().splitlines() or ["sent"])[-1][:300]


def _mail_send_new_thread(email: str, text: str, approved_by: str, dry_run: bool, key: str = "",
                          mailbox: str = MAIL_ACCOUNT, subject: str = "") -> str:
    """Open a NEW thread to the requester's own address, from the support@ seat (option 2, firstmate 073).

    Deliberately separate from `_mail_send`: there is no thread to read a subject from, and `--reply-all` would be
    meaningless. The body arrives ALREADY carrying the approved one-line lead - `deliver` prepends it before the body
    sha is taken, so a lead that changed after approval cannot be sent under the approved digest."""
    missing = _env_missing(GOG_ENV)
    if missing:
        raise Unknown(f"{missing} is not set: gog cannot unlock its keyring (the gateway exports it from "
                      f"/etc/openclaw/main.env)")
    gog = shutil.which("gog")
    if not gog:
        raise Unknown("gog is not on PATH: no mail leaves this host without it")
    if not subject:
        raise Unknown("a new thread needs a subject and none was supplied")
    if dry_run:
        return "dry-run"
    cmd = [gog, "gmail", "send", "--account", mailbox, "--to", email, "--subject", subject, "--body", text]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180, env=_with_key(key))
    except subprocess.TimeoutExpired as exc:
        raise Ambiguous(f"gog gmail send timed out after {exc.timeout}s with the message built: it may be sent, "
                        f"so this is never a retry") from exc
    if out.returncode != 0:
        raise Ambiguous(f"gog gmail send exited rc {out.returncode} after being invoked: "
                        f"{(out.stderr or out.stdout).strip()[:300]}")
    return (out.stdout.strip().splitlines() or ["sent"])[-1][:300]


def adapter(name: str):
    """Resolved at CALL time (not a module-level dict) so a test can patch one writer and the real code path
    still runs; a module-level dict freezes the function object and makes that patch a no-op."""
    return {"intercom": _intercom_send, "mail": _mail_send, "mail_new_thread": _mail_send_new_thread}[name]


def final_letter(row: dict, text: str) -> tuple[str, str, str]:
    """(body, subject, to) EXACTLY as they will go on the wire - ONE source of truth for the approval digest and the
    send.

    QA finding on this PR: `approval.digest()` hashed the item's ORIGINAL `text`, while `deliver()` added the lead and
    derived the subject only afterwards. So the batch a human approved was not the batch that left the host: opening
    the subject gate, or editing either copy string, changed the outbound letter while leaving the approved digest
    untouched. The whole point of the digest (inbox 061/065: an approval binds a FROZEN batch, and a changed body needs
    a FRESH approval) is defeated if the hash and the sender disagree about what the body IS.

    Returning the pair - rather than each caller deriving its own - is what makes them agree by construction: the CLI
    materialises items with this before hashing them, and `deliver()` sends what it returns. A pure function, no store
    access, so it cannot drift between the two call sites.

    The RECIPIENT is the third element, and it is bound for the same reason the subject is (QA finding on #1749): a
    new-thread letter is addressed to `requester_email`, and that address is a register field a later intake or a
    hand-edit can change. Hashing only the body meant an approval cut for A still authorised the same letter to B - the
    original request, in our words, delivered to somebody else. `to` is empty for every other route, so an in-thread
    reply's digest is byte-identical to before and a standing approval is not disturbed.

    A row whose route REFUSES gets its text back unchanged with no subject and no recipient: it will be ledgered
    `refused` at send time, and binding a lead to a letter that cannot leave would only invent an approval for
    nothing.

    This function decides WHETHER to assemble and WHO the recipient is. It assembles NOTHING: every customer-facing
    byte comes from `copy.new_thread_letter`, because `copy.fingerprint()` is what a month-long standing ruling names
    and it can only cover what `copy.py` owns. Assembling here meant an edit to this function could add a line while
    both standing rulings' `copy_sha` still matched (QA finding on #1779). `test_final_letter_adds_no_text_of_its_own`
    pins that."""
    try:
        channel, target = route(row)
    except Unknown:
        return text, "", ""
    if channel != "mail_new_thread":
        return text, "", ""
    # The mailbox the PERSON wrote to, never the one we send from: the lead line exists to name the address they
    # chose, and under the 2026-11-06 ruling that is no longer the same address the letter leaves from.
    written_to = THREAD_MAILBOX_BY_CHANNEL.get(row.get("channel"), row.get("channel") or "")
    body, subject = copy.new_thread_letter(written_to, row.get("received_at", ""), row.get("class") or "", text)
    return body, subject, target


def materialise(run, items: list[dict]) -> list[dict]:
    """Rewrite each item to the letter that will actually be sent, BEFORE the approval digest is computed.

    This is the fix for the ordering hole: the human approves the digest of these bytes, and `deliver()` sends these
    bytes - so changing the lead, the subject or the RECIPIENT changes the digest and the old approval stops matching.
    `letter_final` marks the item so `deliver()` does not prepend the lead a second time."""
    for x in items:
        body, subject, to = final_letter(run.store.get(x["row"]) or {}, x["text"])
        x["text"], x["subject"], x["recipient"], x["letter_final"] = body, subject, to, True
    return items


def deliver(run, item: dict, kind: str, approved_by: str, dry_run: bool = False, slot: str | None = None) -> dict:
    """Send ONE approved letter for `item` (a row from Run.asks / Run.confirmations) and ledger it.

    `slot` is the ledger slot; it defaults to `kind`. It exists because a confirmation has TWO letters in its life: an
    INTERIM one, sent while the pages are not yet off the public view ("the remaining step is in progress"), and the
    FINAL one that says they no longer show the information. One slot for both meant the interim consumed the single
    `confirm` slot and stamped `confirmed_at`, so the final letter - the one that actually closes a statutory request -
    could never send (Fable r5 finding 2). The interim now lives in `confirm-interim` and does not stamp `confirmed_at`.

    Returns {"state": sent|failed|refused|skipped|unknown|dry-run, ...}. The invariants:
      - `sent` is final: a request that already has a sent letter in this slot is reported, never sent again.
      - `sending`/`unknown` are NOT retryable by the pipeline: the writer may have reached the customer, so a human
        resolves it. `unknown` is specifically the AMBIGUOUS case (timeout, dropped connection, non-zero exit after the
        writer ran): retrying it is how one request gets two statutory letters.
      - `failed` / `refused` ARE retryable (a mailbox got authed, a writer flaked before it ran), reusing the slot.
      - `dry-run` writes nothing at all: nothing left the host, so there is nothing to guard against."""
    rid = item["row"]
    slot = slot or kind
    who = f"#{item['register_no']}"
    prior = run.store.send_record(rid, slot)
    if prior and prior["state"] == "sent":
        run.log(f"{who} row {rid}: {slot} already sent on {prior['at'][:10]} via {prior['channel']} "
                f"({prior['target']}); not sent again")
        return {"state": "skipped", "why": f"already sent {prior['at'][:10]}", "ledger": prior}
    if prior and prior["state"] in ("sending", "unknown"):
        run.log(f"{who} row {rid}: a {slot} was claimed on {prior['at']} and is {prior['state']} - a letter may "
                f"already be out; a human resolves this row, the pipeline will not send a second one")
        return {"state": "skipped", "why": f"claimed {prior['at']} and {prior['state']} - unfinished, a letter may "
                                          f"be out", "ledger": prior}

    if item.get("refuse"):
        # A letter the register knows it must not send yet (unapproved copy the ruling requires). Ledgered as
        # `refused`, so it is retryable - once the copy is approved the same slot sends it - and never a silent skip.
        run.store.claim_send(rid, slot, "none", "", body_sha(item["text"]), approved_by, "refused",
                             detail=item["refuse"], idem=idem_key(rid, slot, item["text"]))
        run.log(f"{who} row {rid}: not sent ({item['refuse']})")
        return {"state": "refused", "why": item["refuse"]}

    row = run.store.get(rid) or {}
    try:
        channel, target = route(row)
    except Unknown as exc:
        run.store.claim_send(rid, slot, "none", "", body_sha(item["text"]), approved_by, "refused", detail=str(exc),
                             idem=idem_key(rid, slot, item["text"]))
        run.log(f"{who} row {rid}: not sent ({exc})")
        return {"state": "refused", "why": str(exc)}

    # OPTION 2 (firstmate 073): a new thread from support@. The mandatory first line is part of the BODY, so it must be
    # in the text BEFORE the body sha and the idem key are computed: a changed body is a different letter, and the
    # approved digest has to be the digest of the text that actually goes out.
    #
    # It is applied HERE through the same `final_letter()` the approval digest uses, and skipped when the caller has
    # already materialised the item - otherwise the lead would be prepended twice and the letter would differ from the
    # one the digest covered.
    if item.get("letter_final"):
        body, subject = item["text"], item.get("subject", "")
        # The approval covered a RECIPIENT as well as bytes. `route()` is re-read here (the row may have moved since
        # materialise), so the two must still agree: sending to an address the approval did not name is the same
        # failure as sending a body nobody approved, and it is the one that leaks a request to a third party.
        approved_to = item.get("recipient") or ""
        routed_to = target if channel == "mail_new_thread" else ""
        if approved_to != routed_to:
            why = (f"the approved recipient {approved_to or '(none)'} is not the one this row routes to now "
                   f"({routed_to or '(none)'}): the address changed after the batch was approved, so this needs a "
                   f"fresh approval rather than a letter to somebody the approval never named")
            run.store.claim_send(rid, slot, "none", "", body_sha(item["text"]), approved_by, "refused",
                                 detail=why, idem=idem_key(rid, slot, item["text"]))
            run.log(f"{who} row {rid}: not sent ({why})")
            return {"state": "refused", "why": why}
    else:
        body, subject, _to = final_letter(row, item["text"])
    if channel == "mail_new_thread":
        # route() already refused a class outside the approved vocabulary; an exception here would mean the two checks
        # disagree, so let it be a refusal, never a letter with a guessed request type in it.
        try:
            copy.new_thread_request_type(row.get("class") or "")
        except copy.NoApprovedRequestType as exc:
            run.store.claim_send(rid, slot, "none", "", body_sha(item["text"]), approved_by, "refused",
                                 detail=str(exc), idem=idem_key(rid, slot, item["text"]))
            run.log(f"{who} row {rid}: not sent ({exc})")
            return {"state": "refused", "why": str(exc)}
        item["text"] = body
        extra = {"mailbox": MAIL_ACCOUNT, "subject": subject}
    elif channel == "mail":
        extra = {"mailbox": mailbox_of(row)}
    else:
        extra = {}

    if dry_run:
        return {"state": "dry-run", "channel": channel, "target": target}

    key = idem_key(rid, slot, item["text"])
    # CLAIM BEFORE SEND, carrying the letter's id: from here on a second attempt sees a claim and stands down.
    run.store.claim_send(rid, slot, channel, target, body_sha(item["text"]), approved_by, "sending", idem=key)
    try:
        ref = adapter(channel)(target, item["text"], approved_by, dry_run=False, key=key, **extra)
    except Ambiguous as exc:
        # The writer ran. We cannot prove the customer did not get it, so this is NEVER a retry.
        detail = str(exc)[:500]
        run.store.finish_send(rid, slot, "unknown", detail=detail)
        run.fail(f"{kind} row {rid} via {channel} (AMBIGUOUS: not retried, reconcile by hand)", Exception(detail))
        return {"state": "unknown", "why": detail, "idem": key}
    except (Unknown, subprocess.SubprocessError, OSError) as exc:
        detail = str(exc)[:500]
        run.store.finish_send(rid, slot, "failed", detail=detail)
        run.fail(f"{kind} row {rid} via {channel}", Exception(detail))
        return {"state": "failed", "why": detail}

    run.store.finish_send(rid, slot, "sent", ref=ref)
    # The row-level stamp lives in the store so a MANUAL resolution to `sent` writes the same one: the interim letter
    # records itself and nothing else, because `confirmed_at` is what takes the row out of the confirmation queue and
    # only the FINAL letter may do that.
    run.store.stamp_sent(rid, kind, slot, ref)
    return {"state": "sent", "channel": channel, "target": target, "ref": ref, "idem": key, "slot": slot}


def reconcile_stranded(run, apply: bool = False) -> list[dict]:
    """Reclassify `unknown` ledger rows whose recorded detail PROVES the writer refused before posting.

    `unknown` means "a letter may be out there, a human resolves it, the pipeline will never retry". That is the
    right answer for a timeout or a dropped connection. It is the WRONG answer for a pre-flight refusal, which the
    writer raises in its validation block ABOVE the POST: nothing was posted, so the row is retryable, and leaving it
    `unknown` strands a statutory letter forever. On 2026-11-06 the first live send tick refused 40 letters this way
    (the sender seat is not on the writer's human allowlist) and every one of them was recorded `unknown`.

    The register is re-read for every row: a letter is only re-queued while its request is still OPEN. A row that was
    closed (hidden and confirmed by another path, or withdrawn) needs no letter, and re-queueing it would send a
    statutory notice about a request that is already finished.

    Returns one dict per row examined, so a dry run prints exactly what `--apply` would move. Nothing is written
    unless `apply` is true, and a row whose detail does not match the pre-POST signature is reported and left alone.
    """
    out = []
    for rec in run.store.unknown_sends():
        detail = rec.get("detail") or ""
        provable = preflight_refusal(detail)
        req = run.store.get(rec["request_id"])
        open_row = bool(req) and (req.get("status") or "open") == "open"
        out.append({"request_id": rec["request_id"], "kind": rec["kind"], "channel": rec["channel"],
                    "target": rec["target"], "at": rec["at"], "provable": provable,
                    "open": open_row, "detail": detail})
        if provable and open_row and apply:
            run.store.reclassify_send(
                rec["request_id"], rec["kind"], "failed",
                f"reconciled {now_iso()}: the writer refused BEFORE posting, so nothing reached the customer and "
                f"this letter is retryable. Original detail: {detail}")
    return out


_ADDRESS = re.compile(r"[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def _address_in(value: str) -> str:
    """The bare address out of a From header (`Kyran <kyran@muso.ai>` -> `kyran@muso.ai`)."""
    m = _ADDRESS.search(value or "")
    return m.group(0) if m else ""


def _sender_of(thread: dict) -> str:
    """The address the person wrote FROM: the first From in the thread that is not one of OURS.

    Not simply the first message. Measured on the live register: 11 support@ rows are threads WE opened, so their
    first message is ours and the customer's address is further down. Not the last message either - a thread we
    replied to ends with our own address. The only correct answer is the first message that came from somebody else,
    and a thread with no such message has no requester address in it at all.
    """
    msgs = thread.get("messages") or []
    if not msgs:
        raise Unknown("the mail thread has no messages, so there is no sender to read")
    seen = []
    for m in msgs:
        for h in (m.get("payload") or {}).get("headers") or []:
            if str(h.get("name", "")).lower() != "from":
                continue
            addr = _address_in(str(h.get("value", "")))
            if not addr:
                raise Unknown(f"a From header in the thread carries no address "
                              f"({str(h.get('value', ''))[:80]})")
            if not _is_ours(addr):
                return addr
            seen.append(addr)
    raise Unknown(f"every message in the thread is from one of OUR mailboxes "
                  f"({', '.join(sorted(set(seen))) or 'none'}), so the requester's own address is not in it")


def _is_ours(addr: str) -> bool:
    """Is this address one of OUR mailboxes rather than the requester's?

    Measured on the live register: 10 of the 19 addresses the first recovery pass found were `support@muso.ai` - the
    thread's first message was OURS (an outbound thread, or a thread whose customer message is not first). Recording
    that as the requester would open the next statutory letter to ourselves, which is worse than having no address:
    it looks like progress and it is a letter to nobody.
    """
    a = (addr or "").strip().lower()
    if not a:
        return True
    ours = {MAIL_ACCOUNT.lower()} | {m.lower() for m in MAILBOX_BY_CHANNEL.values()} \
        | {m.lower() for m in THREAD_MAILBOX_BY_CHANNEL.values()}
    ours |= {m.lower() for m in (gog_accounts() or {})}
    return a in ours


def thread_sender(thread_id: str, mailbox: str) -> str:
    """Read one thread and return the requester's address. A READ: nothing is written, so a failure is retryable."""
    missing = _env_missing(GOG_ENV)
    if missing:
        raise Unknown(f"{missing} is not set: gog cannot unlock its keyring")
    gog = shutil.which("gog")
    if not gog:
        raise Unknown("gog is not on PATH: no thread can be read on this host")
    try:
        got = subprocess.run([gog, "gmail", "thread", "get", thread_id, "--account", mailbox, "-j"],
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as exc:
        raise Unknown(f"thread {thread_id}: the gog read timed out after {exc.timeout}s") from exc
    if got.returncode != 0:
        raise Unknown(f"thread {thread_id} is not readable in {mailbox} "
                      f"({(got.stderr or got.stdout).strip()[:200]})")
    try:
        thread = json.loads(got.stdout or "{}").get("thread") or {}
    except json.JSONDecodeError:
        raise Unknown(f"thread {thread_id}: gog returned unparseable JSON")
    return _sender_of(thread)


def recover_addresses(run, apply: bool = False) -> list[dict]:
    """Find the requester address for OPEN rows that have none (captain, 2026-11-06, item 3).

    Two problems were tangled in the 69 rows that could not be answered: the code half (a thread in a mailbox we
    cannot write needs a new thread from support@) and the data half (the row has no address to open one to). This is
    the data half. Sources, in order, and each one is a fact the person themselves supplied:

      1. the Intercom conversation - the contact's email, or the email on a CUSTOMER-authored source message;
      2. the Gmail thread, read from the mailbox that owns it - but only when this host can actually read that
         mailbox, which today means support@. notices@ and legal@ are aliases for people, not accounts, so their
         threads are not readable here and are reported as such rather than guessed at.

    NEVER touches `erasure_sends`. A row already claimed and `unknown` stays claimed and unknown: changing the
    outbound mailbox must not become a way to send a second statutory letter to someone who may already have one
    (captain, item 4). This writes `requester_email`, which is a register fact, and nothing else.

    Returns one dict per row examined so a dry run prints exactly what `--apply` would fill.
    """
    from . import sources

    out = []
    for row in run.store.all(status="open"):
        if (row.get("requester_email") or "").strip():
            continue
        rid, channel = row["id"], row.get("channel") or ""
        email, source, why = "", "", ""
        conv = (row.get("conversation_id") or "").strip()
        thread = (row.get("gmail_thread") or "").strip()
        if conv:
            try:
                cv = sources.conversation(conv)
                email = (cv.get("author_email") or cv.get("contact_email") or "").strip()
                source = "intercom"
                if email and _is_ours(email):
                    why = (f"conversation {conv} resolves to {email}, which is one of OUR mailboxes, so the "
                           f"requester's own address is not in it")
                    email = ""
                elif not email:
                    why = f"conversation {conv} carries no email on the contact or the customer's own message"
            except Exception as exc:                      # noqa: BLE001 - any read failure is "not recovered"
                why = f"conversation {conv} could not be read: {str(exc)[:160]}"
        if not email and thread:
            owner = THREAD_MAILBOX_BY_CHANNEL.get(channel, "")
            ok, not_ok = mailbox_writable(owner) if owner else (False, f"{channel} has no known thread mailbox")
            if ok:
                try:
                    email = thread_sender(thread, owner)
                    source = f"gmail:{owner}"
                except Exception as exc:                  # noqa: BLE001
                    why = str(exc)[:200]
            else:
                why = (f"its thread {thread} is in {owner}, which this host cannot read "
                       f"({not_ok}); the address is not recoverable from here")
        if not email and not why:
            why = "the row has neither a conversation nor a thread to read an address out of"
        out.append({"id": rid, "channel": channel, "email": email, "source": source, "why": why})
        if email and apply:
            run.store.update(rid, "address_recovered", requester_email=email)
    return out
