"""Pipeline steps over the store. Each step is idempotent and fails closed (a failed read leaves the row as it was
and makes the run exit non-zero)."""
from __future__ import annotations

import json
import os
import re
from datetime import datetime, timedelta, timezone

from gdpr_pipeline import access, copy, copy_gate, dsar, hide_guard, identity, intake, sources
from gdpr_pipeline import send as letter_send     # 'send' is a local in watchdog_rows: the ledger record for a row
from gdpr_pipeline.store import Store, _dedupe_pages, now_iso, parse_iso

SLACK_CHANNEL = "C0BBTAVP44X"       # #cs_priority (same channel + bot as legal-intake and the legal watchdog)
JAN = "U038BM16T7W"
WARN_DAYS = 3
ASK_CHASE_DAYS = 7
LETTER_GRACE_HOURS = 24      # a letter the register has NOT sent, this long past its deadline, is named as such
HIDE_TICK_HOURS = (0, 6, 12, 18)   # gdpr-hide-batch.timer: OnCalendar=*-*-* 00,06,12,18:20:00 UTC
HIDE_TICK_MINUTE = 20


ERASURE_FAMILY = ("privacy_erasure", "legal_threat")


def ask_refusal(cls: str, past_due: bool, kind: str = "") -> str:
    """Why this row's identity ask must NOT leave, or "" when it may.

    Three independent reasons, and the class one is checked FIRST because it is the one that would otherwise be
    invisible: `copy.ASK` is erasure copy, so a `dmca_takedown` or `legal_threat` row that reaches the same
    `ASK_LINK` verdict would be told "the deletion request you made on {date} is in progress" - a statement about a
    request the person never made. The class gate is `copy.ASK_APPROVED_CLASSES`, which is part of
    `copy.fingerprint()`, so widening it without a ruling also invalidates the standing grant."""
    if cls not in copy.ASK_APPROVED_CLASSES:
        return (f"the identity-ask copy is ERASURE copy and class {cls!r} has no approved ask of its own "
                f"(copy.ASK_APPROVED_CLASSES = {list(copy.ASK_APPROVED_CLASSES)}): the letter would tell them about "
                f"a deletion request they did not make, so it needs its own approved words and its own ruling")
    if past_due and not copy.PROGRESS_LINE_APPROVED:
        return ("past-due ask copy is not approved yet (copy.PROGRESS_LINE_APPROVED = False): the ruling requires "
                "the letter to say the erasure is in progress, and those words are Fable's to approve")
    if cls in dsar.STATUTORY and kind in dsar.ASK_WORDING_SUPERSEDED:
        # The third reason is about the WORDS, and it is why this is a refusal in the ledger and not a row left off
        # the list: `dsar.older_ask` decides whether the ask is listed from the gate's verdict alone, the same for
        # every ask, and this row is listed. What cannot leave is the sentence. Editing it here would change
        # `copy.fingerprint()` and with it every standing ruling, which is the reviewer's to re-cut, not a fix's.
        return ("the identity step tells the requester that a name 'as it appears on your ID' is enough, and the "
                "captain's 2026-11-12 ruling made that untrue (a name match ties nobody to a page, and no code path "
                "passes one): the letter would promise what the next step refuses. It needs replacement words and "
                "their ruling; until then the request's first message is the ladder's reviewed acknowledgement, "
                f"and the clock names it after {dsar.NO_FIRST_MESSAGE_HOURS} h without one")
    return ""


def _part_asks_for(text: str, cls: str) -> bool:
    """Does THIS part's own words carry the class? Not the same question for an access duty.

    A combined part ("send me a copy of my data and delete my profile") classifies as the ERASURE, because that is
    the more urgent duty. Keying the access duty off `classify` alone therefore never matched the very part that
    asked for the copy, and the access row fell through to the thread's creation date - dating a Nov 8 request from
    a Nov 1 thread and shortening its statutory clock by a week (QA #1858 r7). Ask the access question directly."""
    if cls == "privacy_access":
        return intake.requests_access("", text)
    return intake.classify("", text) == cls


def conversation_request_at(conv: dict, cls: str) -> int:
    """The epoch of the FIRST customer part whose own words ask for the removal (the request's date).

    Exact class first, then any part in the same erasure family: a ticket filed as privacy_erasure whose customer
    reply also says "or I'll speak to my lawyer" classifies as legal_threat alone, and using the thread's creation
    date there would put the deadline in the past on the day the row is born. Falls back to the conversation's
    creation only when no single part matches at all (the class came from subject + body together)."""
    parts = conv.get("parts") or []
    for part in parts:
        if _part_asks_for(part["text"], cls):
            return int(part["at"])
    if cls in ERASURE_FAMILY:
        for part in parts:
            if intake.classify("", part["text"]) in ERASURE_FAMILY:
                return int(part["at"])
    return int(conv.get("created_at") or 0)


def escalation_part_at(conv: dict, cls: str, after: int = 0) -> int:
    """The epoch of the FIRST customer message whose own words carry THIS (more restrictive) class, or 0.

    A pure escalation (a legal threat with no new page) is dated at the message that INTRODUCED the threat, never at
    whatever the customer said last: the ticket stays open, so an unrelated later reply ("thanks") would otherwise
    move the deadline a day later on every tick and mint a fresh escalation row each time. `after` scopes the search
    to the messages that came after a written confirmation: a threat from BEFORE it belongs to the request we already
    answered, and must never date (or justify) a later one."""
    for part in conv.get("parts") or []:
        if int(part.get("at") or 0) > after and intake.classify("", part.get("text") or "") == cls:
            return int(part.get("at") or 0)
    return 0


def confirmed_after(confirmed_at: str) -> int:
    """The epoch a message must be LATER than to count as a new request after a written confirmation.

    `confirmed_at` can be a date (the register's `CONFIRMATION SENT` column, the sender's own date) or a full
    timestamp. A date-only value covers that whole DAY, so the window starts at its last second: a message from the
    same day is treated as part of the request we just answered, never as the start of a new one. Erring the other
    way would read a pre-confirmation threat as a post-confirmation one and hand a legal-threat row a hide-first path
    it never earned."""
    at = (confirmed_at or "").strip()
    if not at:
        return 0
    if len(at) <= 10:
        dt = datetime.strptime(at, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1) \
            - timedelta(seconds=1)
    else:
        dt = parse_iso(at)
    return int(dt.timestamp())


CLASS_RANK = ("not_erasure", "privacy_access", "privacy_erasure", "dmca_takedown",
              "cancel_intent_mentions_deletion", "legal_threat")


def repeat_ask_at(conv: dict, after: int, known_ids: set[str],
                  claimed: set[int] = frozenset()) -> tuple[int, list[dict]]:
    """(epoch, pages) of the first post-confirmation customer message that names a page this conversation already
    knows and that no row has been opened for yet. A repeat ask is a REAL request with its own deadline: dropping it
    left the customer whose page came back (or whose hide was reverted) holding a written confirmation with nobody
    watching.

    `claimed` is the set of message times this conversation already owns a row for. It is what makes a SECOND repeat
    work: after the first repeat has its own (by then confirmed) row, the page is still "known", so without this the
    scan would return the first repeat's message again and every later ask would land on its closed row."""
    for part in conv.get("parts") or []:
        at = int(part.get("at") or 0)
        if at <= after or at in claimed:
            continue
        pages = [p for p in intake.pages_in(part.get("text") or "") if p["id"] in known_ids]
        if pages:
            return at, pages
    return 0, []


def message_class(conv: dict, at: int, pages: list[dict], base_class: str) -> str:
    """The class of the ONE customer message that makes a post-confirmation request — the message at `at`.

    Never the whole thread (that carried an answered legal threat onto a brand-new request) and never the whole
    post-confirmation span either: "delete A or my attorney writes" about an already-answered page followed by a
    plain request for another page would otherwise classify the second one as a threat, and a threat is the ONE class
    that hides before identity (10-23). Symmetrically, a later THREAT must not be read off an earlier plain repeat:
    the class belongs to the message that opens the request. A message that introduces a page on an erasure thread is
    an erasure request even when its own words do not trip the classifier ("and please remove …"), and it never
    inherits the answered request's class."""
    text = ""
    for part in conv.get("parts") or []:
        if int(part.get("at") or 0) == at:
            text = part.get("text") or ""
            break
    cls = intake.classify("", text) if text else ""
    if pages:
        return cls if cls in ERASURE_FAMILY else "privacy_erasure"
    return cls if cls in CLASS_RANK else base_class


def escalation_after(conv: dict, after: int, base_class: str) -> int:
    """The epoch of the first post-confirmation message that is MORE restrictive than the one we answered — a pure
    escalation (a threat with no new page) is the only way such a request can exist. 0 when there is none."""
    for part in conv.get("parts") or []:
        at = int(part.get("at") or 0)
        if at <= after:
            continue
        cls = intake.classify("", part.get("text") or "")
        if cls in CLASS_RANK and base_class in CLASS_RANK and CLASS_RANK.index(cls) > CLASS_RANK.index(base_class):
            return at
    return 0


def introducing_part_at(conv: dict, pages: list[dict]) -> int:
    """The epoch of the FIRST customer message that names one of these pages (0 when no part does).

    A new request is dated at the message that INTRODUCED the page, never at whatever the customer said last: the
    ticket stays open after the confirmation, so an unrelated later reply ("thanks") would otherwise move the
    deadline a day later on every tick and mint a fresh request each time."""
    want = {p["id"] for p in pages}
    for part in conv.get("parts") or []:
        if want & {p["id"] for p in intake.pages_in(part.get("text") or "")}:
            return int(part.get("at") or 0)
    return 0


def next_hide_tick(now: datetime) -> str:
    """The next routine hide-batch run (HH:20Z): the next scheduled run, not a promise that it judges a given page
    (only pages in its batch reach the guard)."""
    for hour in HIDE_TICK_HOURS:
        at = now.replace(hour=hour, minute=HIDE_TICK_MINUTE, second=0, microsecond=0)
        if at > now:
            return at.strftime("%H:%MZ")
    return (now + timedelta(days=1)).replace(hour=HIDE_TICK_HOURS[0], minute=HIDE_TICK_MINUTE, second=0,
                                             microsecond=0).strftime("%H:%MZ")


class Run:
    def __init__(self, store: Store, log=print):
        self.store, self.log, self.errors = store, log, []

    def fail(self, what: str, exc: Exception) -> None:
        self.errors.append(f"{what}: {exc}")
        self.log(f"ERROR {what}: {exc}")

    # ---------------------------------------------------------------- intake
    def intake_register(self, md: str) -> None:
        for c in intake.parse_register(md):
            if c["class"] == "not_erasure":
                continue
            c["keys"] += [f"clickup:{t}" for t in c["clickup_ids"]]
            # A row is closed below, by a write of its own with its event, never by its insert: created closed, a
            # row was out of every pass before anything could ask whether its requester had been answered.
            closed, c["status"] = c["status"] == "closed", "open"
            rid, how = self.store.upsert(c)
            row = self.store.get(rid)
            if c.get("confirmed") and not row["confirmed_at"]:
                self.store.update(rid, "confirmed", confirmed_at=c["confirmed"],
                                  confirm_ref="markdown register: CONFIRMATION SENT")
                row = self.store.get(rid)
            if closed and row["status"] == "open":
                # The markdown register closes a row; it cannot close a statutory request nobody has answered. That
                # is how register #13 left every pass with its requester never told (`reopen_unanswered`).
                if row["class"] in dsar.STATUTORY and not dsar.final_response_at(row, self.store.sends(rid)):
                    self.log(f"register #{c['register_no']}: closed on the markdown register with no final response "
                             "on record, so it stays open")
                else:
                    self.store.update(rid, "closed", status="closed", note="closed on the markdown register")
            self.log(f"register #{c['register_no']}: {how}")

    def intake_gmail(self, ledger: dict, support_ledger: dict | None = None) -> None:
        bad: list[str] = []
        support = intake.parse_support_ledger(support_ledger, bad) if support_ledger else []
        for msg in bad:                     # a malformed row is a source failure (exit 2), never a quiet skip
            self.fail("support ledger", ValueError(msg))
        notices_bad: list[str] = []
        cands = intake.parse_gmail_ledger(ledger, errors=notices_bad) + support
        for msg in notices_bad:             # an UNKNOWN class from notices@/legal@ is a source failure, not a skip
            self.fail("notices@/legal@ ledger", ValueError(msg))
        for c in cands:
            rid, how = self.store.upsert(c)
            if how != "unchanged":
                self.log(f"{c['keys'][0]}: {how} (row {rid})")

    def intake_clickup(self, tasks: list[dict], conv_reader=None) -> None:
        conv_reader = conv_reader or sources.conversation
        for t in tasks:
            if not intake.is_open_task(t):
                continue
            c = intake.parse_clickup(t)
            conv = {}
            if c["conversation_id"]:
                try:
                    conv = conv_reader(c["conversation_id"])
                except sources.Unknown as exc:
                    self.fail(f"clickup {t['id']} conversation {c['conversation_id']}", exc)
                    continue
            text = conv.get("customer_text") or c["ticket_text"]
            c["class"] = intake.ticket_class(c, text)
            # A ticket whose conversation already has an ANSWERED row (a written confirmation, OR a row a human closed
            # for another reason — every pass filters to open rows) is being replayed with the whole thread: both the
            # answered pages and whatever the customer added afterwards. Dating that replay from the first erasure
            # message gives the new request the ORIGINAL deadline (already past) and puts already-answered pages back
            # into a hide batch. The new request is dated at the message that opened it and carries only the pages that
            # message introduced.
            confirmed_row = next((row for key in c["keys"] for row in [self.store.by_key(key)]
                                  if row and (row.get("confirmed_at") or row["status"] != "open")), None)
            if confirmed_row:
                c["pages"] += intake.pages_in(text)
                # Judge "new" against EVERY row of this conversation, not just the confirmed original: a reply that
                # asked for B already opened its own row, and an unrelated later reply would otherwise re-register B
                # (a second row, a second deadline, a second watchdog for one request).
                have = {q["id"] for sib in self.store.all() if c["conversation_id"]
                        and sib["conversation_id"] == c["conversation_id"] for q in sib["pages"]}
                have |= {q["id"] for q in confirmed_row["pages"]}
                c["pages"] = [p for p in _dedupe_pages(c["pages"]) if p["id"] not in have]
                # The class of the NEW request comes from the messages that came AFTER the confirmation: the thread
                # still carries what we already answered, and an old legal threat must not turn a plain erasure
                # request for another page into a hide-first row.
                after = confirmed_after(confirmed_row["confirmed_at"] or "")
                if not after:
                    # Closed WITHOUT a written confirmation: there is no confirmation date, so "after we answered this"
                    # is when the row was last touched (closing it). Without an anchor, `after=0` reads the thread's
                    # ORIGINAL request as a repeat ask and folds pages the customer already had answered back in.
                    after = int(parse_iso(confirmed_row["updated_at"]).timestamp())
                rep_at, at_msg = 0, 0
                rep_at, rep_pages = repeat_ask_at(
                    conv, after, self._answered_pages(c["conversation_id"], confirmed_row),
                    self._claimed_epochs(c["conversation_id"]))
                if c["pages"]:
                    at_msg = introducing_part_at(conv, c["pages"])
                if rep_at:
                    # A repeat ask for a page we already answered is a NEW request (new deadline), never a replay, and
                    # it can arrive together with a brand-new page: both belong to this request (see merge_reply).
                    c["pages"] = _dedupe_pages(rep_pages + c["pages"])
                    at_msg = at_msg or rep_at
                if not at_msg:
                    at_msg = escalation_after(conv, after, confirmed_row["class"])
                # Same rule as the conversation path: the class comes from the message that MAKES the new request.
                if at_msg:
                    c["class"] = message_class(conv, at_msg, c["pages"], confirmed_row["class"])
                rank = CLASS_RANK
                escalates = (c["class"] in rank and confirmed_row["class"] in rank
                             and rank.index(c["class"]) > rank.index(confirmed_row["class"]))
                if not c["pages"] and not escalates:
                    continue      # same thread, nothing new: replaying it opens no request at all
                at = at_msg or introducing_part_at(conv, c["pages"])
                if not at and escalates:
                    # A pure escalation (a threat with no new page) is dated at the message that carried it, exactly
                    # like the conversation replay: the TICKET stays open, so dating it from date_updated would mint
                    # a fresh escalation row on every unrelated ticket edit.
                    at = escalation_part_at(conv, c["class"], after=after)
                if at:
                    c["received_at"] = intake.iso_s(at)
                elif t.get("date_updated"):
                    c["received_at"] = intake.iso_ms(t["date_updated"])   # the page came in on the ticket itself
            else:
                if conv.get("created_at"):
                    # The same rule as the unticketed pass: a request that is a REPLY on an older conversation is
                    # dated at the reply, never at the thread's creation. The ticket is evidence too: when the
                    # TICKET's own words ask for the erasure, its earlier date stands (that is when we were told).
                    # When the ticket carries no request of its own the conversation is the only evidence, and the
                    # reply's date wins even if the ticket is older ("customer asked about their account" filed in
                    # August must not date a November erasure request to August).
                    at = intake.iso_s(conversation_request_at(conv, c["class"]))
                    if intake.classify("", c["ticket_text"]) in ERASURE_FAMILY:
                        c["received_at"] = min(c["received_at"], at)
                    else:
                        c["received_at"] = at
                c["pages"] += intake.pages_in(text)
            c["requester_name"] = conv.get("author_name") or conv.get("contact_name") or c["requester_name"]
            c["requester_email"] = conv.get("author_email") or conv.get("contact_email") or c["requester_email"]
            c["contact_id"] = conv.get("contact_id", "")
            if c["class"] == "not_erasure":
                c["status"] = "open"           # kept visible on the register until a person agrees, then closed
            rid, how = self.store.upsert(c)
            if how != "unchanged":
                self.log(f"clickup {t['id']}: {how} (row {rid}, {c['class']})")

    def _answered_pages(self, conv_id: str, confirmed_row: dict) -> set[str]:
        """The page ids a WRITTEN CONFIRMATION already covers on this conversation. A repeat ask is an ask for one of
        these, and only these: a page that an OPEN post-confirmation request merely introduced is that request's
        business, so naming it again in a later message must not re-register it (QA 14th round) while a page we already
        answered and confirmed keeps its renewed deadline (QA 28th round)."""
        out = {p["id"] for p in confirmed_row["pages"]}
        for sib in self.store.all() if conv_id else []:
            if sib["conversation_id"] == conv_id and sib["confirmed_at"]:
                out.update(p["id"] for p in sib["pages"])
        return out

    def _claimed_epochs(self, conv_id: str) -> set[int]:
        """The customer-message times this conversation already has a row for. A message that owns a row is answered
        (or being answered) and must not open a second one when the thread is re-ingested."""
        out: set[int] = set()
        for sib in self.store.all() if conv_id else []:
            if sib["conversation_id"] != conv_id:
                continue
            try:
                out.add(int(parse_iso(sib["received_at"]).timestamp()))
            except (TypeError, ValueError):
                continue
        return out

    def merge_reply(self, row: dict, conv: dict) -> None:
        """Fold a later customer message on a registered conversation into its row: newly supplied page links, and a
        more restrictive class. `update()` bumps updated_at, so the same tick's decide pass re-reads the row and the
        new pages reach the hide batch instead of waiting for the ASK to be answered twice.

        A row that has a WRITTEN CONFIRMATION is immutable: its 30-day watchdog skips it, so folding a new page into
        it would hide a page nobody is watching for. A later message there is a NEW request, with its own row, its
        own deadline and its own watchdog. The same holds for a row that is CLOSED without a confirmation (a
        markdown-register row closed for another reason): every pass filters to open rows, so folding a page into it
        would register a request nothing acts on."""
        text = conv.get("customer_text") or ""
        rank = ("not_erasure", "privacy_access", "privacy_erasure", "dmca_takedown",
                "cancel_intent_mentions_deletion", "legal_threat")
        cls = intake.classify(conv.get("subject", ""), text)
        answered = bool(row.get("confirmed_at")) or row["status"] != "open"
        after = confirmed_after(row.get("confirmed_at") or "")
        # Scope to the pages this customer event INTRODUCES, judged against every row of this conversation — the
        # confirmed original AND any post-confirmation request it already started. Comparing against the confirmed
        # row alone re-registers page A from an earlier reply when a second reply names A again plus B (duplicate
        # hide/watchdog work and contradictory records).
        have = {q["id"] for sib in self.store.all() if sib["conversation_id"] == row["conversation_id"]
                for q in sib["pages"]}
        have |= {q["id"] for q in row.get("pages") or []}
        new_pages = [p for p in intake.pages_in(text) if p["id"] not in have]
        rep_at, at_msg = 0, 0
        if after:
            rep_at, rep_pages = repeat_ask_at(conv, after, self._answered_pages(row["conversation_id"], row),
                                              self._claimed_epochs(row["conversation_id"]))
            if new_pages:
                at_msg = introducing_part_at(conv, new_pages)
            if rep_at:
                # A repeat ask for a page we already answered is a NEW request with a new deadline, and a repeat can
                # arrive WITH a brand-new page ("delete A again and also B"): both belong to this request, so A keeps
                # its renewed deadline instead of being dropped for being "already known". The date stays the one that
                # introduced the request's page(s); the repeat message's own time is only used when there is no such
                # page, so a later threat about an ALREADY-answered page cannot upgrade the row.
                new_pages = _dedupe_pages(rep_pages + new_pages)
                at_msg = at_msg or rep_at
            if not at_msg:
                at_msg = escalation_after(conv, after, row["class"])
            # A post-confirmation request is classified from the message that MAKES it (see message_class).
            cls = message_class(conv, at_msg, new_pages, row["class"]) if at_msg else row["class"]
        escalate = (cls in rank and row["class"] in rank and rank.index(cls) > rank.index(row["class"]))
        if not new_pages and not escalate:
            return
        if answered:
            # The store turns a hit on an ANSWERED row into its own request (key `<row key>:again:<request time>`):
            # one implementation for this and for the hourly re-ingest of the same ticket. The time is the message
            # that INTRODUCED the page, else the one that introduced the escalation (a pure escalation has no new
            # page), and only then the last customer message -- so an unrelated later reply neither re-dates the new
            # request nor mints a second escalation row on every tick.
            at = at_msg or introducing_part_at(conv, new_pages)
            if not at and escalate:
                # ONLY a real escalation is dated by its own message: asking for the introducing part of a class
                # that is not an escalation would match the EARLIER part with that class and fold a genuinely new
                # request back into a row it does not belong to.
                at = escalation_part_at(conv, cls, after=after)
            at = at or intake.last_customer_part_at(conv)
            if not new_pages and not at:
                return
            rid, how = self.store.upsert({
                "keys": [row["row_key"]], "channel": row["channel"],
                "class": cls if cls in ERASURE_FAMILY else (
                    "privacy_erasure" if new_pages else row["class"]),
                "received_at": intake.iso_s(at),
                "conversation_id": row["conversation_id"],
                "requester_name": row["requester_name"], "requester_email": row["requester_email"],
                "contact_id": row["contact_id"], "pages": new_pages})
            self.log(f"intercom {row['conversation_id']}: message on an answered row ("
                     f"{'confirmed' if row.get('confirmed_at') else 'closed, ' + row['status']}) is a NEW request "
                     f"({how}, row {rid}, {len(new_pages)} new page(s))")
            return
        changes: dict = {}
        pages = _dedupe_pages((row.get("pages") or []) + new_pages)
        if pages != (row.get("pages") or []):
            changes["pages"] = pages
        if escalate:
            changes["class"] = cls
        self.store.update(row["id"], "reply_merged", **changes)
        self.log(f"intercom {row['conversation_id']}: later customer message merged ({sorted(changes)})")

    def intake_intercom(self, since_epoch: int, conv_reader=None) -> bool:
        """Conversations created since `since_epoch` whose customer words match the erasure / legal rules and that
        no row holds yet (Caroline's ticket normally brings them in; this catches the ones she did not file).
        True when the search and every conversation read succeeded: only then may the caller advance its cursor
        (a failed read keeps the window open so the next tick retries it instead of skipping it)."""
        conv_reader = conv_reader or sources.conversation
        errs = len(self.errors)
        try:
            ids = sources.search_conversations(since_epoch)
        except sources.Unknown as exc:
            self.fail("intercom search", exc)
            return False
        for cid in ids:
            row = self.store.by_key(f"intercom:{cid}")
            if row is not None:
                # An already-keyed conversation is NOT a reason to skip the read: the customer often answers our
                # ASK_LINK on the same thread ("here is my profile"), or escalates ("or my attorney will write").
                # Skipping left the row ASK_LINK forever while its deadline ran.
                try:
                    conv = conv_reader(cid)
                except sources.Unknown as exc:
                    self.fail(f"intercom {cid}", exc)
                    continue
                try:
                    self.merge_reply(row, conv)
                except sources.Unknown as exc:
                    self.fail(f"intercom {cid}", exc)
                    continue
                # `merge_reply` folds pages and raises the class; it does not know about the SECOND duty. Without
                # this an access-only reply on an open erasure thread left the Art. 15 half with no row and no
                # 30-day clock (QA #1858 r6). Same helper as the fresh path, so the two cannot drift.
                self.file_access_duty(cid, conv, existing=row)
                continue
            try:
                conv = conv_reader(cid)
            except sources.Unknown as exc:
                self.fail(f"intercom {cid}", exc)
                continue
            cls = intake.classify(conv.get("subject", ""), conv.get("customer_text", ""))
            if cls not in ("privacy_erasure", "legal_threat"):
                continue
            # A reply on an OLD thread is a request as of the REPLY, not the thread's creation: the due date must
            # not arrive already expired because the conversation started last month.
            at = conversation_request_at(conv, cls)
            rid, how = self.store.upsert({
                "keys": [f"intercom:{cid}"], "channel": "intercom", "class": cls, "conversation_id": cid,
                "received_at": intake.iso_s(at), "requester_name": conv.get("author_name") or "",
                "requester_email": conv.get("author_email") or conv.get("contact_email") or "",
                "contact_id": conv.get("contact_id", ""), "pages": intake.pages_in(conv.get("customer_text", ""))})
            self.log(f"intercom {cid}: {how} (row {rid}, {cls})")
            self.file_access_duty(cid, conv)
        return len(self.errors) == errs

    def file_access_duty(self, cid: str, conv: dict, existing: dict | None = None) -> None:
        """File the Art. 15 half of a message that asks for BOTH a copy and deletion (QA #1847).

        The register tracks one class per row, so without a second candidate the access half is silently
        untracked and nobody owes the customer an answer to it. Filed on the same thread, so `upsert` mints the
        `:access` key and the two duties get two rows with their own clocks. Idempotent: the key is the test, so a
        replay is `unchanged`. Called from BOTH the fresh and the already-keyed conversation paths - an
        access-only reply on an open erasure thread owes exactly the same duty as a combined first message."""
        subject, text = conv.get("subject", ""), conv.get("customer_text", "")
        if not intake.requests_access(subject, text):
            return
        # The duty is owed when EITHER this message carries the erasure demand or the thread we already hold does.
        # An access-ONLY reply on an open erasure row is exactly that case: `classify` answers `privacy_access`, so
        # a gate of "this message is an erasure request" would skip the very reply that owes the copy (QA #1858 r6).
        cls = intake.classify(subject, text)
        if (cls not in intake.ERASURE_CLASSES
                and ((existing or {}).get("class") or "") not in intake.ERASURE_CLASSES):
            return
        # Dated by the ACCESS question, never by `cls`: the message's own class is the erasure, so asking for the
        # erasure's first part dates the copy from the deletion and shortens its clock (QA #1858 r7).
        at = conversation_request_at(conv, "privacy_access")
        arid, ahow = self.store.upsert({
            "keys": [f"intercom:{cid}"], "channel": "intercom", "class": "privacy_access",
            "conversation_id": cid, "received_at": intake.iso_s(at),
            "requester_name": conv.get("author_name") or "",
            "requester_email": conv.get("author_email") or conv.get("contact_email") or "",
            "contact_id": conv.get("contact_id", ""),
            "pages": intake.pages_in(text)})
        self.log(f"intercom {cid}: {ahow} (row {arid}, privacy_access - the message also asks for a copy)")

    # ---------------------------------------------------------------- identity
    def decide_all(self, hidden: set[str], conv_reader=None, stale_hours: float = 0,
                   prefix_resolver=None, half: dict[str, str] | None = None) -> None:
        """Decide every open row (stale_hours=0), or only rows never decided, UNKNOWN, changed since their last
        decision, or decided more than `stale_hours` ago (the hourly tick)."""
        conv_reader = conv_reader or sources.conversation
        prefix_resolver = prefix_resolver or sources.resolve_prefixes
        now = datetime.now(timezone.utc)
        # "Changed since we decided it" is a REVISION comparison, not a clock one: `updated_at`/`decided_at` are
        # second-precision, so a page added in the same second as the decision used to keep the stale verdict until
        # the 20-hour refresh (and could not enter the hide batch in between).
        # A statutory row with no identity chain on it (`gates.v`) is owed no ladder message at all (`dsar.owed`), so
        # it is selected NOW and not at its next 20-hour refresh: on 2026-11-12 the chain shipped at 21:32Z and 244
        # open requests decided earlier that day sat outside the ladder for up to 20 hours, 94 of them among the
        # requests nobody had ever written to.
        rows = [r for r in self.store.all("open") if not stale_hours or not r["decided_at"]
                or r["identity_verdict"] == identity.UNKNOWN or r["rev"] > r["decided_rev"]
                or (r["class"] in dsar.STATUTORY and not (r.get("gates") or {}).get("v"))
                or now - parse_iso(r["decided_at"]) > timedelta(hours=stale_hours)]
        prefixes = sorted({p["id"] for r in rows for p in r["pages"] if len(p["id"]) == 8})
        resolved: dict[str, str] = {}
        self.prefixes_read = True       # the catalog answered the prefix lookup (or there was none to ask)
        if prefixes:
            # NEVER resolve a prefix from what this store happens to hold: a second catalog profile can share the
            # 8-char prefix and be absent from our rows/hide lists, so "the only one we know" is not "unique".
            # Uniqueness must come from the catalog itself; a collision there leaves the prefix unresolved (UNKNOWN).
            try:
                resolved.update(prefix_resolver(prefixes))
            except sources.Unknown as exc:
                self.prefixes_read = False
                self.fail("prefix resolution", exc)
        for r in rows:
            try:
                self.decide_row(r, hidden, resolved, conv_reader, stale_hours, half)
            except sources.Unknown as exc:
                self.fail(f"decide row {r['id']} (#{r['register_no']})", exc)
                self.chain_unread(r)

    def chain_unread(self, r: dict) -> None:
        """A statutory request whose identity reads failed still gets its acknowledgement.

        The decision is NOT made (the run has already failed loud, and the row is decided on a later run). What is
        written is the identity chain in its "nothing could be read" form, and only where the row has none: need
        `unknown`, which the ladder acknowledges with the date and asks nothing. Without it a source that is down
        for a day keeps every request that arrived that day outside the ladder, and the first message waits on a
        read instead of on the request. It never replaces a chain a real read wrote."""
        if r["class"] not in dsar.STATUTORY or (r.get("gates") or {}).get("v"):
            return
        self.store.update(r["id"], "chain_unread",
                          gates=dsar.gates(r["class"], None, "", False, [], max(len(r["pages"]), 1)))

    def reopen_unanswered(self) -> list[int]:
        """Reopen every statutory request that is closed with no final response on record. Returns register numbers.

        A closed status with nothing sent is the state the ladder exists to make impossible (`dsar.clock_rows` names
        it as `closed_without_response`), and naming it sent nobody anything: every pass reads open rows only, so
        the requester of register #13 (closed on the markdown register on 2026-11-01, its pages already gone) was
        owed no message by any path. Open again, the request is decided, acknowledged and answered like any other.
        A duplicate is not a closed request (its answer is the kept row's). The inverse is one write:
        `status='closed'` on the row, and the `reopened` event keeps who reopened it and why."""
        out = []
        for r in self.store.all("closed"):
            if r["class"] not in dsar.STATUTORY or dsar.final_response_at(r, self.store.sends(r["id"])):
                continue
            self.store.update(r["id"], "reopened", status="open",
                              note="closed with no final response on record: reopened by code")
            self.log(f"register #{r['register_no']}: reopened (closed with no final response on record)")
            out.append(r["register_no"])
        return sorted(out)

    def decide_rows(self, rows: list[dict], hidden: set[str], conv_reader=None, prefix_resolver=None,
                    half: dict[str, str] | None = None) -> None:
        """Decide exactly these rows (a pushed intake candidate), not the whole open register: an `intake` call must
        not re-write 374 unrelated decisions as a side effect of recording one request."""
        conv_reader = conv_reader or sources.conversation
        prefix_resolver = prefix_resolver or sources.resolve_prefixes
        prefixes = sorted({p["id"] for r in rows for p in r["pages"] if len(p["id"]) == 8})
        resolved: dict[str, str] = {}
        self.prefixes_read = True       # the catalog answered the prefix lookup (or there was none to ask)
        if prefixes:
            try:
                resolved.update(prefix_resolver(prefixes))
            except sources.Unknown as exc:
                self.prefixes_read = False
                self.fail("prefix resolution", exc)
        for r in rows:
            try:
                self.decide_row(self.store.get(r["id"]) or r, hidden, resolved, conv_reader, half=half)
            except sources.Unknown as exc:
                self.fail(f"decide row {r['id']} (#{r['register_no']})", exc)

    def decide_row(self, r: dict, hidden: set[str], resolved: dict[str, str], conv_reader,
                   stale_hours: float = 0, half: dict[str, str] | None = None) -> None:
        cls = r["class"]
        pages, seen = [], set()
        for p in r["pages"]:
            q = {**p, "id": resolved.get(p["id"], p["id"])}
            if q["id"] not in seen and not any(len(q["id"]) == 8 and x.startswith(q["id"]) for x in seen):
                seen.add(q["id"])
                pages.append(q)
        conv = conv_reader(r["conversation_id"]) if r["conversation_id"] else {}
        name, email, trusted, rep = requester_of(r, conv)
        gates = None        # the DSAR identity chain; statutory classes only
        if cls == "privacy_access":
            dec = identity.Decision("ACCESS", "", [])
            action = "Art. 15 access request: captain/counsel answer (no hide); due date tracked"
            # The row's verdict stays ACCESS (nothing is hidden for an access request). The identity chain is still
            # owed: who is asking, and whether they are tied to the page they name. A read that fails here is an
            # UNKNOWN in the chain, never a pass and never a failed decision for the row.
            try:
                acc, how = sources.resolve_account(conv.get("external_id", ""), email, trusted)
                prof_ids = [p["id"] for p in pages if p.get("entity", "profile") == "profile" and len(p["id"]) == 36]
                claims = sources.processed_claims(prof_ids) if prof_ids else {}
                req = identity.Requester(name=name, email=email, account_id=acc, account_names=(),
                                         representative=rep, verified=bool(trusted))
                # The claim is read FIRST here, from the claims read itself: `decide_page` answers "already hidden"
                # before it looks at who is asking (and a hidden page's facts carry no claim), while for an access
                # request a hidden page still has to be tied to the person before anything about it is told to them.
                pvs = [{"id": p.entity_id,
                        "verdict": identity.PASS_A if acc is not None and acc in claims.get(p.entity_id, ())
                        else identity.decide_page(p, req, "privacy_erasure").verdict}
                       for p in sources.page_facts(pages, hidden, claims, half)]
                gates = dsar.gates(cls, acc, how, rep, pvs, len(pages),
                                   prefixes_read=getattr(self, "prefixes_read", False))
            except sources.Unknown as exc:
                self.log(f"row {r['id']} (#{r['register_no']}): identity chain not readable this run ({exc})")
                gates = dsar.gates(cls, None, "", rep, [], max(len(pages), 1))
        elif cls == "cancel_intent_mentions_deletion":
            dec = identity.Decision(identity.JAN_REVIEW, "", [])
            action = "Jan: cancel-intent ticket that mentions deletion (read the customer's words)"
        else:
            acc, how = sources.resolve_account(conv.get("external_id", ""), email, trusted)
            names = sources.account_names([acc]).get(acc, ()) if acc is not None else ()
            prof_ids = [p["id"] for p in pages if p.get("entity", "profile") == "profile" and len(p["id"]) == 36]
            claims = sources.processed_claims(prof_ids) if prof_ids else {}
            # The item gate (a track / album passes through its ONE artist's profile: identity.decide_item) reads
            # the catalog only where a read can change the answer. A DMCA item can only pass on the requesting
            # ACCOUNT's processed claim, so without an account there is nothing to look up and the page stays with a
            # person at no cost - register #171 alone carries 36 item pages.
            items = ((cls in ("privacy_erasure", "legal_threat") or (cls == "dmca_takedown" and acc is not None))
                     and any((p.get("entity") or "profile") in sources.ITEM_ENTITIES for p in pages))
            facts = (sources.page_facts(pages, hidden, claims, half, items=True) if items
                     else sources.page_facts(pages, hidden, claims, half))
            # A processed claim is a tie only when it shows the page is the account's (hide_guard.prove): the
            # requester's own unverified claim is taken off the page here, so the decision ASKS instead of passing.
            facts = hide_guard.prove(facts, acc)
            req = identity.Requester(name=name, email=email, account_id=acc, account_names=names, representative=rep,
                                     verified=bool(trusted))
            dec = identity.decide(facts, req, cls)
            action = ""
            if cls in dsar.STATUTORY:
                gates = dsar.gates(cls, acc, how, rep, [{"id": pv.entity_id, "verdict": pv.verdict}
                                                        for pv in dec.pages], len(pages),
                                   prefixes_read=getattr(self, "prefixes_read", False))
        # `account` / `owner_page` / `sender_host` are written only on a pass (identity.PageVerdict): they are what
        # the hide guard reads the proof again from. A row decided before they existed lacks them, and the guard
        # re-decides it.
        detail = [{"id": pv.entity_id, "verdict": pv.verdict, "why": pv.why,
                   **({"account": pv.account_id} if pv.account_id is not None else {}),
                   **({"owner_page": pv.owner_page} if pv.owner_page else {}),
                   **({"sender_host": pv.sender_host} if pv.sender_host else {})} for pv in dec.pages]
        # A page that answers 404 in the catalog AND publicly, with no merge record, was removed by something
        # other than the hide process (register #36's class). Marked per row so the Jan item can cite the store.
        gone = sorted({d["id"] for d in detail if d["verdict"] == identity.GONE})
        action = action or identity.action_for(dec.verdict, detail)
        changes = {"identity_verdict": dec.verdict, "identity_basis": dec.basis, "verdict_detail": detail,
                   "action": action}
        if gone != sorted(r.get("removed_outside_process") or []):
            changes["removed_outside_process"] = gone
        if gates is not None:
            changes["gates"] = gates
        if _dedupe_pages(pages) != r["pages"]:
            changes["pages"] = _dedupe_pages(pages)
        if name and not r["requester_name"]:
            changes["requester_name"] = name
        if email and not r["requester_email"]:
            changes["requester_email"] = email
        if any(r.get(k) != v for k, v in changes.items()):
            changes["decided_at"] = now_iso()
            if dec.verdict.startswith("ASK_"):
                changes["ask_kind"] = dec.verdict
            self.store.update(r["id"], "decide", **changes)
        # The CLOCK arm of the tick's selection (`now - decided_at > stale_hours`) only settles if a refresh writes
        # `decided_at` too: otherwise a stable row decided 21h ago is re-selected on EVERY tick forever, and the 20-hour
        # refresh becomes an hourly full pass over the whole register at ~5 reads a row, ahead of the watchdog arms.
        # Its own event kind, so the register keeps the fact that this was a refresh and not a verdict change.
        # `stale_hours = 0` means the clock arm is OFF for this run (the revision arm still selects); only a positive
        # stale_hours makes age a reason to refresh. `or 1e9` turned 0 into "never", so a run that asked for no clock
        # refresh still wrote one on every row.
        if stale_hours:
            refresh_at = datetime.now(timezone.utc)
            if not r["decided_at"] or refresh_at - parse_iso(r["decided_at"]) > timedelta(hours=stale_hours):
                self.store.update(r["id"], "refresh", decided_at=now_iso())
        # Pin the revision we decided FROM even when the verdict and the row are unchanged: otherwise a row whose
        # decision did not alter anything (or whose columns already matched a re-decision after a rules change) stays
        # `rev > decided_rev` forever and is re-decided on every tick.
        self.store.mark_decided(r["id"])

    # ---------------------------------------------------------------- hidden read-back
    def mark_hidden(self, checker=None) -> None:
        """hidden_at = the first run where EVERY hide-eligible page answers 410 + noindex (P).

        Every eligible page is re-checked on every run, because 410 is not permanent: the ids recorded in
        `hidden_pages` are the CURRENT answer, and a page that comes back to 200 clears `hidden_at` again. The read-back
        is per ELIGIBLE page, never gated on the whole row: a request that carries a PASS page next to
        an ASK_IDENTITY (or a Jan track/album) page serves the PASS page 410 + noindex the moment its hide PR merges,
        and the ASK page stays unresolved by design. Requiring every page of the row put that row off the read-back
        forever — `hidden_at` stayed empty and the 24-hour hide watchdog paged every day about a page that was already
        down. The ids that read back gone are recorded on the row (`hidden_pages`), so a later run re-checks only what
        is left and a letter still waits for the whole row (`confirmations`)."""
        from gdpr_pipeline import checks
        checker = checker or checks.public_gone
        for r in self.store.all("open"):
            todo = [d["id"] for d in r["verdict_detail"]
                    if d["verdict"] in identity.HIDE_ELIGIBLE + (identity.ALREADY_HIDDEN,)]
            if not todo:
                continue
            had = sorted(r.get("hidden_pages") or [])
            done = []
            try:
                for i in todo:
                    ent = next((p["entity"] for p in r["pages"] if p["id"] == i), "profile")
                    if checker(ent, i):
                        done.append(i)
            except sources.Unknown as exc:
                self.fail(f"P read-back row {r['id']}", exc)
                continue
            done = sorted(done)
            if done != had:
                self.store.update(r["id"], "hidden_pages", hidden_pages=done)
            missing = [i for i in todo if i not in done]
            if r["hidden_at"] and missing:
                # The marker means "this request is hidden", so it may only stand while EVERY current eligible page is
                # down. Two ways it stops being true: a page that read back gone answers 200 again (a rollback, a bad
                # deploy, a config list edited back), or the customer supplies another page before the written
                # confirmation. Either way the row is public again: clear the marker (a legal register that dates the
                # whole request before its newest page is wrong) and let the 24-hour alert fire.
                self.store.update(r["id"], "unhidden", hidden_at="")
                self.log(f"row {r['id']}: {r['hidden_at']} no longer holds for {missing}; hidden_at cleared, "
                         f"alert restored")
            if all(i in done for i in todo) and not r["hidden_at"]:
                # `hidden_at` = every hide-ELIGIBLE page of this row read back gone. A page still waiting on identity
                # (ASK) or on Jan (a track/album) is not eligible and does not hold the read-back hostage; it also
                # never lets a LETTER out, because `confirmations()` still requires the whole row to be eligible.
                self.store.update(r["id"], "hidden", hidden_at=now_iso(), hidden_pages=sorted(done))

    # ---------------------------------------------------------------- asks + confirmations (render; send locked)
    def older_ask_held(self, r: dict, kind: str, now: datetime) -> str:
        """Why the older ask stands down for this row now, or '' (`dsar.older_ask`; '' for a class the ladder does
        not own). Asked when the batch is listed AND again by `send.deliver` on the row as it is at send time: a
        batch approved an hour ago must not put a second first message beside a ladder message sent since."""
        if r.get("class") not in dsar.STATUTORY:
            return ""
        msgs = self.store.messages(r["id"])
        first = min((e["at"] for e in self.store.events(r["id"]) if e["kind"] == "dsar_authored"),
                    default="") if msgs else ""
        return dsar.older_ask(r, kind, self.store.sends(r["id"]), msgs, first, now)

    def asks(self, now: datetime | None = None) -> list[dict]:
        """The identity asks owed, one per row. A row past its statutory date carries the past-due opening line as
        well (the ruling requires it); while that copy is not approved the item carries a `refuse` reason, so the
        letter is REFUSED and ledgered rather than sent without the sentence the ruling says it must have.

        A row whose CLASS the ask copy was not written for carries a `refuse` reason too, and for the same reason:
        `copy.ASK` is erasure copy, and a `dmca_takedown` or `legal_threat` row reaches the same `ASK_LINK` verdict.
        Sending it would tell a rights-holder that "the deletion request you made" is in progress (QA finding on
        #1779). Refused, not dropped: the ledger records why, and the row stays visible in the batch.

        For a statutory request this ask stands down ONLY where the copy gate holds a ladder letter for THAT request
        (`dsar.older_ask`, over the table `dsar.OLDER_ASK_STANDS_DOWN`): one that is out or approved, or one in the
        review queue, and that one for no longer than `dsar.FALLBACK_HOURS`. Refused, a gate that could not answer,
        no answer on record, no letter at all: the ask is listed here exactly as before the ladder existed. The
        identity step is listed by that same table and then refused for its words (`ask_refusal`), in the ledger.
        `dsar.owed` is the other half: no acknowledgement once an ask went."""
        now = now or datetime.now(timezone.utc)
        out = []
        for r in self.store.all("open"):
            kind = r["identity_verdict"]
            if kind in copy.ASK and not r["ask_sent_at"]:
                if self.older_ask_held(r, kind, now):
                    continue
                past_due = parse_iso(r["due_at"]) <= now
                text = copy.ASK[kind]
                if past_due:
                    text = copy.progress_line(r["received_at"]) + "\n\n" + text
                out.append({"row": r["id"], "register_no": r["register_no"], "channel": r["channel"],
                            "to": r["conversation_id"] or r["requester_email"] or r["gmail_thread"], "kind": kind,
                            "text": text, "due_at": r["due_at"], "received_at": r["received_at"],
                            "class": r["class"], "past_due": past_due,
                            "refuse": ask_refusal(r["class"], past_due, kind)})
        return out

    def confirmations(self, now: datetime, horizon_days: int = WARN_DAYS, s_check=None, p_check=None,
                      m_result: dict | None = None) -> list[dict]:
        """Letters for rows due within `horizon_days` (or already hidden), lines filled only by THIS run's checks."""
        from gdpr_pipeline import checks
        s_check, p_check = s_check or checks.search_absent, p_check or checks.public_gone
        out = []
        for r in self.store.all("open"):
            if r["confirmed_at"] or r["class"] not in ("privacy_erasure", "legal_threat", "dmca_takedown"):
                continue
            due = parse_iso(r["due_at"])
            if not (r["hidden_at"] or due - now <= timedelta(days=horizon_days)):
                continue
            ids = [d["id"] for d in r["verdict_detail"]
                   if d["verdict"] in identity.HIDE_ELIGIBLE + (identity.ALREADY_HIDDEN,)]
            if not ids or len(ids) != len(r["verdict_detail"]):
                continue                     # a row with an ASK / Jan page is not confirmed as done
            today = now.strftime("%Y-%m-%dT%H:%M:%SZ")
            try:
                p = all(p_check("profile", i) for i in ids)
                names = {}
                s = all(s_check(i, names.get(i) or self._page_name(i)) for i in ids)
            except checks.Unmeasurable as exc:
                # NOT a run error. This row cannot be checked here and no retry will change that (no page name, or
                # a name with more matches than the autocomplete cap can show), so counting it as a failed read made
                # the tick exit 2 and page every day for a condition that can never clear. The row is still not
                # confirmed: it drops out of this batch and `watchdog_rows` keeps naming it, which is the queue a
                # person works. A genuinely unreadable row still goes through `fail` below.
                self.log(f"row {r['id']} #{r['register_no']}: not confirmable here ({exc})")
                continue
            except sources.Unknown as exc:
                self.fail(f"S/P read-back row {r['id']}", exc)
                continue
            m = bool(m_result) and all(m_result.get(i) for i in ids)
            try:
                text = copy.render_confirmation(r["requester_name"].split(" ")[0] if r["requester_name"] else "",
                                                r["received_at"], [f"https://muso.ai/profile/{i}" for i in ids],
                                                today if s else "", today if p else "", today if m else "")
            except ValueError as exc:
                self.log(f"row {r['id']} #{r['register_no']}: no letter yet ({exc})")
                continue
            # The SLOT, not the copy: an interim letter (P not yet public-gone) and the final letter are two letters
            # in one request's life, so they must not share one ledger slot (r5 finding 2).
            out.append({"row": r["id"], "register_no": r["register_no"], "due_at": r["due_at"], "S": s, "P": p,
                        "M": m, "to": r["conversation_id"] or r["requester_email"] or r["gmail_thread"],
                        "channel": r["channel"], "received_at": r["received_at"], "text": text,
                        "class": r["class"],
                        "slot": "confirm" if p else "confirm-interim"})
        return out

    def _page_name(self, pid: str) -> str:
        doc = sources.profile_doc(pid)
        return str((doc or {}).get("name") or "")

    # ---------------------------------------------------------------- watchdog
    def watchdog_rows(self, now: datetime) -> list[tuple[int, str]]:
        """(register_no, line) to page: due_at - 3 d (7 d for an erasure or access request) reached without
        confirmed_at; an ASK sent > 7 d ago with no
        answer. The register number is the identity of the page content, so the caller pages on TURNOVER (a new
        request became due) and not on a line COUNT that one request clearing can leave unchanged."""
        out = []
        for r in self.store.all("open"):
            if r["class"] not in ("privacy_erasure", "legal_threat", "dmca_takedown", "privacy_access"):
                continue
            due = parse_iso(r["due_at"])
            # A statutory request is paged from 7 days out, the same window as the firstmate clock line
            # (`dsar.ALARM_DAYS`): that line is carried by a check registered outside this repo, so this page, which
            # deploys with the tick, must not be the narrower of the two (QA review of #1908).
            warn = dsar.ALARM_DAYS if r["class"] in dsar.STATUTORY else WARN_DAYS
            if not r["confirmed_at"] and now >= due - timedelta(days=warn):
                state = "OVERDUE" if now > due else f"due in {(due - now).days} d"
                # Whether a letter actually LEFT, and when -- separate from whether the date has passed. The two used
                # to be the same claim in this line, and on 2026-11-03 they were not: 97 decided rows were "overdue"
                # with zero letters sent, because `confirm --send` had no adapter. `confirmed_at` is only set by a
                # send, so a row can sit overdue-and-silent with nothing in the alert saying so.
                send = self.store.send_record(r["id"], "confirm")
                if not send:
                    letter = "no letter sent"
                elif send["state"] == "sent":
                    letter = f"letter sent {send['at'][:10]} via {send['channel']}"
                else:
                    # An ATTEMPTED confirmation is neither "no letter sent" nor a letter: the ledger record makes
                    # `send` non-None, so the no-ledger branch below never runs for it and the page used to read
                    # "letter refused <date> via none" with no reason and no fix (QA 11-05). The detail is the
                    # whole point of the record, so it rides the line, bounded like the ask branch's.
                    why = (send.get("detail") or "").strip()
                    letter = (f"letter {send['state']} {send['at'][:10]} via {send['channel']}"
                              + (f" ({why[:160]}{' …' if len(why) > 160 else ''})" if why else ""))
                if send is None and r.get("interim_confirm_at"):
                    # An interim letter ("the remaining step is in progress") is NOT the confirmation this deadline
                    # is about, but saying "no letter sent" would hide that something already went to the customer.
                    letter = (f"interim letter sent {r['interim_confirm_at'][:10]}, final letter NOT sent")
                elif send is None and now - due > timedelta(hours=LETTER_GRACE_HOURS):
                    letter = f"no letter sent, {(now - due).days} d past the deadline"
                if send is None:
                    # "no letter sent" is true of two very different rows: one waiting on a decision, and one that
                    # cannot be answered at all (a mailbox gog cannot write, or no reply target on file). Left
                    # implicit, 24 of the live rows read like a broken pipeline when the fix is a mailbox auth or a
                    # ruling. Two sources, cheapest first: an attempt already in the ledger, then the route itself.
                    tried = self.store.send_record(r["id"], "ask")
                    if tried and tried.get("state") in ("refused", "failed", "unknown", "sending"):
                        why = (tried.get("detail") or "").strip()
                        letter += (f"; the {tried['kind']} letter is {tried['state']}"
                                   + (f" ({why[:160]}{' …' if len(why) > 160 else ''})" if why else ""))
                    elif tried is None:
                        try:
                            letter_send.route(r)    # pure: a capability check on this host, no network
                        except letter_send.Unknown as e:
                            why = str(e).strip()
                            letter += f"; no route for a letter ({why[:160]}{' …' if len(why) > 160 else ''})"
                        except Exception:               # a route() defect must never break the page
                            pass
                out.append((r["register_no"], f"#{r['register_no']} {r['channel']} received {r['received_at'][:10]}, "
                                              f"written confirmation {state} ({r['due_at'][:10]}); {letter}; "
                                              f"identity {r['identity_verdict'] or '-'}; next: {r['action'] or '-'}"))
            if r["ask_sent_at"] and now - parse_iso(r["ask_sent_at"]) > timedelta(days=ASK_CHASE_DAYS) \
                    and r["identity_verdict"].startswith("ASK_"):
                out.append((r["register_no"], f"#{r['register_no']} identity ASK sent {r['ask_sent_at'][:10]} has no "
                                              f"answer for {ASK_CHASE_DAYS} d: second ask once, then the 'could not "
                                              f"confirm' line"))
        return out

    def hide_due_rows(self, now: datetime, include_legal: bool = False) -> list[tuple[int, str, bool]]:
        """(register_no, line, needs_action) for requests whose 24-hour HIDE deadline has passed and whose page is
        not hidden.

        `hide_due_at` is received + 24 h (the ruling's first step). The batch itself is a human-merged PR, so this
        is the alert that keeps the deadline from passing in silence: without it the hourly tick runs green until
        the 30-day warning three weeks later.

        `needs_action` is True only when a pending page can actually enter the batch PR (the guard admitted it). A
        page the guard HOLDS is reported as held, with what the hold needs; a page the guard has never judged names
        the next routine run, which judges only pages in its batch (a legal page only on `hide-batch --include-legal`,
        which no timer runs); a page on both hide lists waits for its read-back. None of those three is a person's
        queue."""
        from gdpr_pipeline import identity as _id
        from gdpr_pipeline.identity import GONE, IDENTITY_PASS, LEGAL_HIDE_FIRST
        eligible = IDENTITY_PASS + ((LEGAL_HIDE_FIRST,) if include_legal else ())
        holds = hide_guard.latest(self.store.events_of_kind(hide_guard.EVENT))
        out = []
        for r in self.store.all("open"):
            if not r["hide_due_at"] or parse_iso(r["hide_due_at"]) > now:
                continue
            # The alert is about the CURRENT eligible pages, judged against what actually read back — never against the
            # row-level `hidden_at` marker. A customer who supplies a second profile before the written confirmation
            # turns a completed row back into a public page, and skipping the row on `hidden_at` left that page with no
            # 24-hour alert at all (a merged PR whose deploy failed is the same shape). Rows completed before
            # `hidden_pages` existed carry the marker and no ids: their completion was set by the OLD all-pages guard,
            # which was stricter, so an empty list + `hidden_at` means "everything eligible then was down".
            done = set(r.get("hidden_pages") or [])
            if r["hidden_at"] and not done:
                done = {pv["id"] for pv in r["verdict_detail"]
                        if pv["verdict"] in eligible + (_id.ALREADY_HIDDEN,)}
            # ALREADY_HIDDEN means the id is in BOTH config lists — the hide is only real once the public page
            # answers 410 + noindex. Until the read-back passes, the page still belongs in the alert.
            pending = [(pv["id"], pv["verdict"]) for pv in r["verdict_detail"]
                       if pv["verdict"] in eligible or pv["verdict"] == "ALREADY_HIDDEN"]
            pending = [(pid, v) for pid, v in pending if pid not in done]
            if not pending:
                continue
            shown = ", ".join(f"{pid[:8]} {v}" if v != "ALREADY_HIDDEN" else f"{pid[:8]} listed, read-back pending"
                              for pid, v in pending[:3])   # the PAGE verdict, not the row's
            states = []
            for pid, v in pending:
                d = holds.get((r["id"], pid))
                if d is None:
                    if v == _id.ALREADY_HIDDEN:
                        states.append(("readback", ""))
                    elif v == LEGAL_HIDE_FIRST:
                        states.append(("unjudged_legal", ""))
                    else:
                        states.append(("unjudged", ""))
                elif d.get("outcome") == hide_guard.HELD:
                    states.append(("held", d.get("reason") or ""))
                else:
                    states.append(("admitted", ""))
            kinds = {k for k, _ in states}
            cannot = "admitted" not in kinds
            why = sorted({w for k, w in states if k == "held"})
            parts = []
            if not cannot:
                parts.append("open/merge the hide batch PR")
            if why:
                parts.append("held by the hide guard (" + ", ".join(why) + "): this page cannot enter the batch PR - "
                             + "; ".join(hide_guard.NEXT[w] for w in why)
                             + ("; no person is sent after it" if cannot else ""))
            if "unjudged" in kinds:
                parts.append(f"not yet judged by the hide guard: the next hide-batch run ({next_hide_tick(now)}) "
                             f"judges a page that is in its batch")
            if "unjudged_legal" in kinds:
                parts.append("not yet judged by the hide guard: a legal page enters it only on "
                             "`hide-batch --include-legal`, which no timer runs")
            if "readback" in kinds:
                parts.append("listed in both hide lists, waiting for the public page to answer 410 (read-back)")
            out.append((r['register_no'],
                        f"#{r['register_no']} {r['channel']} received {r['received_at'][:10]}: the 24-hour HIDE "
                        f"deadline passed ({r['hide_due_at'][:10]}) and {len(pending)} page(s) are not hidden yet "
                        f"({shown}{', ...' if len(pending) > 3 else ''}); row identity {r['identity_verdict']}; "
                        f"next: {'; '.join(parts)}",
                        not cannot))
        return out

    def watchdog(self, now: datetime) -> list[str]:
        return [line for _, line in self.watchdog_rows(now)]

    # ---------------------------------------------------------------- the DSAR ladder (gdpr_pipeline/dsar.py)
    def dsar_states(self) -> int:
        """Record each statutory request's DERIVED state; an event only when it changes. Returns how many moved.

        The state is never an input to anything: it is what the recorded facts say, written down so the register
        shows it and the trail has the date of every transition."""
        moved = 0
        for r in self.store.all():
            if r["class"] not in dsar.STATUTORY or r["status"] == "duplicate":
                continue
            st = dsar.state_of(r, self.store.sends(r["id"]))
            if st != (r.get("dsar_state") or ""):
                self.store.db.execute("UPDATE erasure_requests SET dsar_state=?, dsar_state_at=? WHERE id=?",
                                      (st, now_iso(), r["id"]))
                self.store.event(r["id"], "dsar_state", was=r.get("dsar_state") or "", now=st)
                self.store.db.commit()
                moved += 1
        return moved

    def dsar_owed(self, now: datetime, copy_doc: dict | None = None) -> list[dict]:
        """The ladder message each open statutory request is owed right now, oldest due date first, with its exact
        body rendered and linted. Reads only; nothing is authored, queued or sent.

        An item whose body cannot be rendered or fails the lint carries `problem` and no text: it is reported and
        never authored, so a broken variant is a loud line and not a held message nobody can approve."""
        copy_doc = copy_doc or dsar.load_copy()
        out = []
        # Art. 12(3) "number of the requests": how many open statutory requests each requester has. A requester is
        # the Intercom contact, else the address; a row with neither counts alone.
        who = lambda r: r.get("contact_id") or (r.get("requester_email") or "").strip().lower()   # noqa: E731
        per_requester: dict[str, int] = {}
        for r in self.store.all("open"):
            if (r["class"] in dsar.STATUTORY and who(r)
                    and not dsar.final_response_at(r, self.store.sends(r["id"]))):
                per_requester[who(r)] = per_requester.get(who(r), 0) + 1
        # No answer date is stated, and no date is moved, for an answer code cannot produce today (`answerable_now`).
        try:
            access_ok = not access.standing_gaps(access.load_manifest())
        except access.ManifestError:
            access_ok = False
        for r in self.store.all("open"):
            if r["class"] not in dsar.STATUTORY:
                continue
            sends = self.store.sends(r["id"])
            want = dsar.owed(r, sends, now, open_from_requester=per_requester.get(who(r), 1),
                             answerable=answerable_now(r, access_ok))
            if not want:
                continue
            prior = self.store.send_record(r["id"], want["slot"])
            if prior and prior["state"] in ("sent", "sending", "unknown"):
                continue        # this slot is spent or in flight; `deliver` would stand down on it anyway
            item = {"row": r["id"], "register_no": r["register_no"], "class": r["class"], "channel": r["channel"],
                    "due_at": dsar.due(r).strftime("%Y-%m-%dT%H:%M:%SZ"), "received_at": r["received_at"],
                    "need": dsar.need_of(r), "copy_sha": copy_doc["_sha256"], **want, "text": "", "problem": ""}
            try:
                body = dsar.render(copy_doc, want["variant"], want["facts"])
                item["problem"] = dsar.lint(body, want["kind"], want["facts"], r,
                                            late=want["variant"].startswith("late_"))
                if not item["problem"]:
                    item["text"] = body
            except dsar.CopyError as exc:
                item["problem"] = str(exc)
            out.append(item)
        out.sort(key=lambda x: (x["due_at"], x["register_no"]))
        return out

    def dsar_author(self, now: datetime, limit: int = 0, checker=None) -> list[dict]:
        """Freeze the body of every message owed and put it up for review. Sends nothing.

        A body already on record for the slot is KEPT while it is still the message owed (`dsar.stale`): the hash
        under review must be the hash that is later sent, so a held message is not re-authored every hour. The gate
        is asked once per held body per run; asking is what queues it for the reviewer."""
        checker = checker or copy_gate.check
        out = []
        for item in self.dsar_owed(now):
            if limit and len(out) >= limit:
                break
            rid, slot = item["row"], item["slot"]
            if item["problem"]:
                self.fail(f"dsar #{item['register_no']} {item['variant']}", Exception(item["problem"]))
                continue
            msg = self.store.message(rid, slot)
            if msg and msg["state"] == "sent":
                continue
            if not msg or dsar.stale(msg, item, self.store.get(rid), now):
                msg = self.store.put_message(rid, slot, item["kind"], item["variant"], item["text"],
                                             copy_gate.body_sha(item["text"]), item["copy_sha"], item["facts"],
                                             item["next_contact_at"], item.get("effects"))
            ans = checker(msg["kind"], msg["body"], variant=msg["variant"], slot=slot)
            changed = (msg["gate_result"], msg["verdict_id"]) != (ans.result, ans.verdict_id)
            self.store.update_message(rid, slot, "dsar_gate" if changed else "",
                                      state="approved" if ans.ok else "held", **ans.as_cols())
            out.append({**item, "text": msg["body"], "variant": msg["variant"], "body_sha": msg["body_sha"],
                        "gate": ans.result, "gate_reason": ans.reason, "verdict_id": ans.verdict_id,
                        "approved": ans.ok})
        return out

    def dsar_send(self, now: datetime, limit: int = 0, dry_run: bool = False, checker=None) -> list[dict]:
        """Author, then send every message whose exact body the reviewer approved. `send.deliver` asks the gate again
        on the bytes it is about to send; this method never decides that a message may go."""
        results = []
        for item in self.dsar_author(now, checker=checker):
            if not item["approved"]:
                results.append({**item, "state": "held", "why": f"copy gate {item['gate']}: {item['gate_reason']}"})
                continue
            if limit and sum(1 for x in results if x.get("state") == "sent") >= limit:
                break
            out = letter_send.deliver(self, {"row": item["row"], "register_no": item["register_no"],
                                             "text": item["text"]},
                                      item["kind"], "gate:pending", dry_run=dry_run, slot=item["slot"])
            results.append({**item, **out})
        return results

    def dsar_clock(self, now: datetime) -> dict:
        return dsar.clock_rows(self.store.all(), self.store.sends, now)

    def dsar_trail(self, register_no: int) -> dict | None:
        """Everything on record for one request, in order: what was received, what was checked, every message with
        its hash and verdict, every send attempt. Built only from the store, so it can be rebuilt at any time."""
        row = next((r for r in self.store.all() if r["register_no"] == register_no), None)
        if not row:
            return None
        sends = self.store.sends(row["id"])
        return {
            "register_no": row["register_no"], "class": row["class"], "channel": row["channel"],
            "received_at": row["received_at"], "due_at": dsar.due(row).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "extended_until": row.get("extended_until") or "", "state": dsar.state_of(row, sends),
            "register_status": row["status"],
            "checked": {"decided_at": row["decided_at"], "identity_verdict": row["identity_verdict"],
                        "identity_basis": row["identity_basis"], "gates": row.get("gates") or {},
                        "pages": row["verdict_detail"]},
            "messages": [{k: m[k] for k in ("slot", "kind", "variant", "body", "body_sha", "copy_sha", "facts",
                                            "state", "gate_result", "gate_reason", "verdict_id", "verdict_sha256",
                                            "reviewer_model", "reviewed_at", "rubric", "authored_at", "updated_at")}
                         for m in self.store.messages(row["id"])],
            "sends": [{k: s.get(k, "") for k in ("kind", "channel", "body_sha", "approved_by", "state", "ref",
                                                  "detail", "at", "attempt")} for s in sends],
            "stamps": {k: row.get(k) or "" for k in ("ack_sent_at", "ack_ref", "ask_sent_at", "status_sent_at",
                                                     "status_ref", "next_contact_at", "interim_confirm_at",
                                                     "confirmed_at", "confirm_ref", "hidden_at")},
            # The Art. 15 copies built for this request: hash, size and counts. Never a value from the copy.
            "access_answers": [{k: a[k] for k in ("sha256", "bytes", "complete", "summary", "manifest_sha",
                                                  "produced_at")} for a in self.store.access_answers(row["id"])],
            "events": [{"at": e["at"], "kind": e["kind"], "detail": e["detail"]}
                       for e in self.store.events(row["id"])],
        }

    # ---- the Art. 15 answer (gdpr_pipeline/access.py)

    def _access_account(self, row: dict, conv_reader) -> tuple[int | None, str]:
        """(account id, '') for the account this requester controls NOW, or (None, why not). Read fresh each time:
        a copy of an account's data is built and sent only for the person who controls that account."""
        if row["class"] != "privacy_access":
            return None, f"#{row['register_no']} is {row['class']}, not an access request"
        if row["status"] != "open":
            return None, f"#{row['register_no']} is {row['status']}"
        try:
            conv = conv_reader(row["conversation_id"]) if row["conversation_id"] else {}
            _name, email, trusted, rep = requester_of(row, conv)
            if rep:
                return None, ("written on someone else's behalf: an authority document is needed, and no coded "
                              "check for one exists yet")
            acc, _how = sources.resolve_account(conv.get("external_id", ""), email, trusted)
        except sources.Unknown as exc:
            return None, f"the requester's account could not be read this run ({type(exc).__name__})"
        if acc is None:
            return None, "account control is not shown: the requester is not signed in to, or writing from, one account"
        return acc, ""

    def access_build(self, register_no: int, record: bool = False, conv_reader=None, reader=None,
                     manifest: dict | None = None) -> dict:
        """Build the copy of the personal data for one access request. Reads only, unless `record`: then the copy
        is written beside the register (0600) and its hash and counts go on the trail. Returns counts and the hash,
        never a value from the copy. Sends nothing."""
        row = next((r for r in self.store.all() if r["register_no"] == register_no), None)
        if not row:
            return {"state": "not_built", "why": f"no request #{register_no} in the register"}
        acc, why = self._access_account(row, conv_reader or sources.conversation)
        if acc is None:
            return {"state": "not_built", "register_no": register_no, "why": why}
        manifest = manifest or access.load_manifest()
        try:
            doc = access.collect(manifest, acc, reader or sources.trino_wide,
                                 register=access.register_view(row, self.store.sends(row["id"])))
        except (sources.Unknown, ValueError) as exc:
            return {"state": "not_built", "register_no": register_no,
                    "why": f"the database could not be read ({type(exc).__name__}): nothing is known, nothing built"}
        raw, sha = access.package(doc)
        out = {"state": "built", "register_no": register_no, "recorded": False,
               **access.summary(doc, sha, len(raw))}
        if record:
            self.store.put_access_answer(row["id"], acc, raw, sha, access.summary(doc, sha, len(raw)))
            out["recorded"] = True
        return out

    def access_deliver(self, register_no: int, now: datetime, dry_run: bool = False, conv_reader=None,
                       checker=None, mailer=None, email_reader=None) -> dict:
        """Send the recorded copy as the final response to an access request, or say every reason it is held.

        Sent only when ALL hold: the newest recorded copy is complete, its file is the recorded bytes, the requester
        controls that account now, the copy is fresh, and the cover message has a verdict on its exact bytes. The
        only recipient is the sign-in address on the account, READ AGAIN HERE: a copy is up to 24 h old, and an
        address changed since the build makes it held until it is rebuilt (QA review of #1908). One send per
        request, claimed before the mailer runs; an ambiguous failure is `unknown` and is never retried."""
        row = next((r for r in self.store.all() if r["register_no"] == register_no), None)
        if not row:
            return {"state": "held", "why": [f"no request #{register_no} in the register"]}
        rid = row["id"]
        prior = self.store.send_record(rid, dsar.KIND_ACCESS)
        if prior and prior["state"] in ("sent", "sending", "unknown"):
            return {"state": "skipped", "register_no": register_no, "why": [f"already {prior['state']}"]}
        acc, why_acc = self._access_account(row, conv_reader or sources.conversation)
        answers = self.store.access_answers(rid)
        answer = answers[-1] if answers else None
        raw = None
        if answer and answer["path"]:
            try:
                with open(answer["path"], "rb") as fh:
                    raw = fh.read()
            except OSError:
                raw = None
        age = ((now - parse_iso(answer["produced_at"])).total_seconds() / 3600) if answer else 0.0
        email_now = None
        if acc is not None:
            try:
                email_now = (email_reader or sources.account_email)(acc)
            except sources.Unknown:
                email_now = None        # unread is held, never "unchanged"
        why = access.undeliverable(answer, raw, acc, age, email_now)
        if why_acc and acc is None:
            why.append(why_acc)
        if why:
            return {"state": "held", "register_no": register_no, "why": why}
        copy_doc = dsar.load_copy()
        facts = {"received": dsar.human_date(parse_iso(row["received_at"]))}
        subject = (copy_doc.get("subjects") or {}).get(dsar.ACCESS_VARIANT, "")
        body = dsar.render(copy_doc, dsar.ACCESS_VARIANT, facts)
        problem = dsar.lint(body, dsar.KIND_ACCESS, facts, row) or ("" if subject else "no subject for the cover message")
        if problem:
            return {"state": "held", "register_no": register_no, "why": [f"cover message: {problem}"]}
        msg = self.store.message(rid, dsar.KIND_ACCESS)
        if not msg or msg["body"] != body:
            msg = self.store.put_message(rid, dsar.KIND_ACCESS, dsar.KIND_ACCESS, dsar.ACCESS_VARIANT, body,
                                         copy_gate.body_sha(body), copy_doc["_sha256"], facts, "")
        ans = (checker or copy_gate.check)(dsar.KIND_ACCESS, body, variant=dsar.ACCESS_VARIANT,
                                           slot=dsar.KIND_ACCESS, subject=subject)
        self.store.update_message(rid, dsar.KIND_ACCESS, "dsar_gate" if ans.result != msg.get("gate_result") else "",
                                  state="approved" if ans.ok else "held", **ans.as_cols())
        if not ans.ok:
            return {"state": "held", "register_no": register_no, "why": [f"copy gate {ans.result}: {ans.reason}"]}
        email = email_now       # equal to the address in the copy, or `undeliverable` held it above
        out = {"state": "would_send", "register_no": register_no, "sha256": answer["sha256"],
               "body_sha": copy_gate.body_sha(body), "verdict_id": ans.verdict_id}
        if dry_run:
            return out
        key = letter_send.idem_key(rid, dsar.KIND_ACCESS, body + answer["sha256"])
        self.store.claim_send(rid, dsar.KIND_ACCESS, "mail_attach", email, copy_gate.body_sha(body),
                              f"gate:{ans.verdict_id}", "sending", detail=f"copy sha256 {answer['sha256']}", idem=key)
        try:
            ref = (mailer or letter_send._mail_send_attachment)(email, body, key, subject, answer["path"])
        except letter_send.Ambiguous as exc:
            self.store.finish_send(rid, dsar.KIND_ACCESS, "unknown", detail=str(exc))
            self.fail(f"access answer #{register_no} (AMBIGUOUS: not retried, reconcile by hand)", exc)
            return {**out, "state": "unknown"}
        except (letter_send.Unknown, OSError) as exc:
            self.store.finish_send(rid, dsar.KIND_ACCESS, "failed", detail=str(exc))
            self.fail(f"access answer #{register_no}", exc)
            return {**out, "state": "failed"}
        self.store.finish_send(rid, dsar.KIND_ACCESS, "sent", ref=ref, detail=f"copy sha256 {answer['sha256']}")
        self.store.stamp_sent(rid, dsar.KIND_ACCESS, dsar.KIND_ACCESS, ref)
        self.store.update_message(rid, dsar.KIND_ACCESS, "dsar_sent", state="sent")
        return {**out, "state": "sent"}


def requester_of(r: dict, conv: dict) -> tuple[str, str, bool, bool]:
    """(name, email, trusted, representative) for one request: who is asking, as far as a read can show.

    Provenance, never the channel name: `notices`/`legal` rows come from a message we fetched ourselves, and an
    Intercom contact we can see is a logged-in user or wrote by mail. A ClickUp ticket with no conversation is
    `support` by construction and its `customer_email` is ticket metadata a requester can type, so it proves nothing
    and must not carry D (or account-email B). ONE function, so the identity decision and the Art. 15 copy can never
    disagree about who the requester is."""
    name = conv.get("author_name") or conv.get("contact_name") or r["requester_name"]
    email = conv.get("author_email") or conv.get("contact_email") or r["requester_email"]
    trusted = (conv.get("source_type") == "email" or conv.get("contact_role") == "user"
               or (r["channel"] in ("notices", "legal") and not r["conversation_id"]))
    rep = intake.is_representative(f"{name} <{email}>", conv.get("customer_text", ""))
    return name, email, bool(trusted), rep


def answerable_now(r: dict, access_ok: bool) -> bool:
    """Can code alone produce this request's final response today? Only then does a message state an answer date
    or move the date (firstmate 2026-11-12: "no promise we cannot hold").

      * access: only while a COMPLETE copy can be built (`access.standing_gaps` is empty).
      * erasure: only when every page named is already hidden (`ALREADY_HIDDEN`), which is the one case where the
        final confirmation needs nothing but this pipeline's own read-backs. A page that still needs its hide merged
        waits on a person, and a page that is already off the site (`GONE`) has no approved final wording, so
        neither gets a date from us: the update gives the next-contact date instead.
    """
    if r["class"] == "privacy_access":
        return access_ok
    verdicts = [d.get("verdict") for d in r.get("verdict_detail") or []]
    return bool(verdicts) and all(v == identity.ALREADY_HIDDEN for v in verdicts)


PAGE_CHUNK = 40
SLACK_TEXT_LIMIT = 3500          # chat.postMessage truncates near 4000 chars; 40 escaped lines stay well under


def page_chunks(lines: list[str], head: str | None = None) -> list[str]:
    """The Slack messages for `lines`, in order: greedy packing under SLACK_TEXT_LIMIT (a hard cap of PAGE_CHUNK
    lines per message), so EVERY line lands in exactly one message.

    The caller records a request as paged only when every chunk posted: a 41st due request must never be dropped
    from the alert (and then suppressed for the rest of the day) because a message was too long to send."""
    def esc(s: str) -> str:
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if not lines:
        return []
    # No person is mentioned: a statutory date is an alarm, not somebody's queue (captain 2026-11-12). The alarm that
    # NAMES each request goes to firstmate (`gdpr-pipeline.py dsar clock`, read by scripts/gdpr-dsar-clock-check.sh);
    # this channel post is the record beside it.
    base = head or (f":hourglass: *GDPR erasure register: {len(lines)} request(s) at or past due - 3 d "
                    f"without a written confirmation*")
    head_for = lambda n, total: base + (f" (part {n}/{total})" if total > 1 else "")   # noqa: E731
    budget = SLACK_TEXT_LIMIT - len(head_for(9, 9)) - 1
    groups, cur, size = [], [], 0
    for line in lines:
        item = "- " + esc(line)
        if cur and (size + 1 + len(item) > budget or len(cur) >= PAGE_CHUNK):
            groups.append(cur)
            cur, size = [], 0
        cur.append(line)
        size += (1 if size else 0) + len(item)
    if cur:
        groups.append(cur)
    return [head_for(n, len(groups)) + "\n" + "\n".join("- " + esc(x) for x in part)
            for n, part in enumerate(groups, 1)]


def page_text(lines: list[str]) -> str:
    """The single message for the first chunk (kept for the bots' previews and the tests)."""
    return (page_chunks(lines) or [""])[0]


def backfill_table(rows: list[dict], now: datetime) -> str:
    """The backfill report (id, received, due, identity verdict, action), most overdue first."""
    def flag(r):
        d = (parse_iso(r["due_at"]) - now).total_seconds() / 86400
        return "PAST" if d < 0 else ("<=3d" if d <= 3 else "")
    out = ["| reg # | keys | class | received | due (30 d) | | identity verdict | basis | pages (verdict) | action |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (r["due_at"], r["register_no"])):
        keys = ", ".join(k.replace("intercom:", "IC ").replace("clickup:", "CU ").replace("gmail:", "")
                         .replace("@muso.ai", "@").replace("register:", "reg ") for k in r["keys"])
        pages = "; ".join(f"{d['id'][:8]} {d['verdict']}" for d in r["verdict_detail"]) or (
            ", ".join(p["id"][:8] for p in r["pages"]) or "-")
        out.append(f"| {r['register_no']} | {keys} | {r['class']} | {r['received_at'][:16].replace('T', ' ')} | "
                   f"{r['due_at'][:10]} | {flag(r)} | {r['identity_verdict'] or '-'} | {r['identity_basis'] or '-'} | "
                   f"{pages} | {r['action'] or '-'} |")
    return "\n".join(out)
