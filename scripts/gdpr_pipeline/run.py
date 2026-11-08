"""Pipeline steps over the store. Each step is idempotent and fails closed (a failed read leaves the row as it was
and makes the run exit non-zero)."""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone

from gdpr_pipeline import copy, identity, intake, sources
from gdpr_pipeline import send as letter_send     # 'send' is a local in watchdog_rows: the ledger record for a row
from gdpr_pipeline.store import Store, _dedupe_pages, now_iso, parse_iso

SLACK_CHANNEL = "C0BBTAVP44X"       # #cs_priority (same channel + bot as legal-intake and the legal watchdog)
JAN = "U038BM16T7W"
WARN_DAYS = 3
ASK_CHASE_DAYS = 7
LETTER_GRACE_HOURS = 24      # a letter the register has NOT sent, this long past its deadline, is named as such


ERASURE_FAMILY = ("privacy_erasure", "legal_threat")


def ask_refusal(cls: str, past_due: bool) -> str:
    """Why this row's identity ask must NOT leave, or "" when it may.

    Two independent reasons, and the class one is checked FIRST because it is the one that would otherwise be
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
    return ""


def conversation_request_at(conv: dict, cls: str) -> int:
    """The epoch of the FIRST customer part whose own words ask for the removal (the request's date).

    Exact class first, then any part in the same erasure family: a ticket filed as privacy_erasure whose customer
    reply also says "or I'll speak to my lawyer" classifies as legal_threat alone, and using the thread's creation
    date there would put the deadline in the past on the day the row is born. Falls back to the conversation's
    creation only when no single part matches at all (the class came from subject + body together)."""
    parts = conv.get("parts") or []
    for part in parts:
        if intake.classify("", part["text"]) == cls:
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
            rid, how = self.store.upsert(c)
            row = self.store.get(rid)
            if c["status"] == "closed" and row["status"] != "closed":
                self.store.update(rid, "closed", status="closed", note="closed on the markdown register")
            if c.get("confirmed") and not row["confirmed_at"]:
                self.store.update(rid, "confirmed", confirmed_at=c["confirmed"],
                                  confirm_ref="markdown register: CONFIRMATION SENT")
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
        at = conversation_request_at(conv, cls)
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
        rows = [r for r in self.store.all("open") if not stale_hours or not r["decided_at"]
                or r["identity_verdict"] == identity.UNKNOWN or r["rev"] > r["decided_rev"]
                or now - parse_iso(r["decided_at"]) > timedelta(hours=stale_hours)]
        prefixes = sorted({p["id"] for r in rows for p in r["pages"] if len(p["id"]) == 8})
        resolved: dict[str, str] = {}
        if prefixes:
            # NEVER resolve a prefix from what this store happens to hold: a second catalog profile can share the
            # 8-char prefix and be absent from our rows/hide lists, so "the only one we know" is not "unique".
            # Uniqueness must come from the catalog itself; a collision there leaves the prefix unresolved (UNKNOWN).
            try:
                resolved.update(prefix_resolver(prefixes))
            except sources.Unknown as exc:
                self.fail("prefix resolution", exc)
        for r in rows:
            try:
                self.decide_row(r, hidden, resolved, conv_reader, stale_hours, half)
            except sources.Unknown as exc:
                self.fail(f"decide row {r['id']} (#{r['register_no']})", exc)

    def decide_rows(self, rows: list[dict], hidden: set[str], conv_reader=None, prefix_resolver=None,
                    half: dict[str, str] | None = None) -> None:
        """Decide exactly these rows (a pushed intake candidate), not the whole open register: an `intake` call must
        not re-write 374 unrelated decisions as a side effect of recording one request."""
        conv_reader = conv_reader or sources.conversation
        prefix_resolver = prefix_resolver or sources.resolve_prefixes
        prefixes = sorted({p["id"] for r in rows for p in r["pages"] if len(p["id"]) == 8})
        resolved: dict[str, str] = {}
        if prefixes:
            try:
                resolved.update(prefix_resolver(prefixes))
            except sources.Unknown as exc:
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
        name = conv.get("author_name") or conv.get("contact_name") or r["requester_name"]
        email = conv.get("author_email") or conv.get("contact_email") or r["requester_email"]
        # Provenance, never the channel name: `notices`/`legal` rows come from a message we fetched ourselves, and an
        # Intercom contact we can see is a logged-in user or wrote by mail. A ClickUp ticket with no conversation is
        # `support` by construction and its `customer_email` is ticket metadata a requester can type, so it proves
        # nothing and must not carry D (or account-email B).
        trusted = (conv.get("source_type") == "email" or conv.get("contact_role") == "user"
                   or (r["channel"] in ("notices", "legal") and not r["conversation_id"]))
        rep = intake.is_representative(f"{name} <{email}>", conv.get("customer_text", ""))
        if cls == "privacy_access":
            dec = identity.Decision("ACCESS", "", [])
            action = "Art. 15 access request: captain/counsel answer (no hide); due date tracked"
        elif cls == "cancel_intent_mentions_deletion":
            dec = identity.Decision(identity.JAN_REVIEW, "", [])
            action = "Jan: cancel-intent ticket that mentions deletion (read the customer's words)"
        else:
            acc, how = sources.resolve_account(conv.get("external_id", ""), email, trusted)
            names = sources.account_names([acc]).get(acc, ()) if acc is not None else ()
            prof_ids = [p["id"] for p in pages if p.get("entity", "profile") == "profile" and len(p["id"]) == 36]
            claims = sources.processed_claims(prof_ids) if prof_ids else {}
            facts = sources.page_facts(pages, hidden, claims, half)
            req = identity.Requester(name=name, email=email, account_id=acc, account_names=names, representative=rep,
                                     verified=bool(trusted))
            dec = identity.decide(facts, req, cls)
            action = ""
        detail = [{"id": pv.entity_id, "verdict": pv.verdict, "why": pv.why} for pv in dec.pages]
        # A page that answers 404 in the catalog AND publicly, with no merge record, was removed by something
        # other than the hide process (register #36's class). Marked per row so the Jan item can cite the store.
        gone = sorted({d["id"] for d in detail if d["verdict"] == identity.GONE})
        action = action or identity.action_for(dec.verdict, detail)
        changes = {"identity_verdict": dec.verdict, "identity_basis": dec.basis, "verdict_detail": detail,
                   "action": action}
        if gone != sorted(r.get("removed_outside_process") or []):
            changes["removed_outside_process"] = gone
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
    def asks(self, now: datetime | None = None) -> list[dict]:
        """The identity asks owed, one per row. A row past its statutory date carries the past-due opening line as
        well (the ruling requires it); while that copy is not approved the item carries a `refuse` reason, so the
        letter is REFUSED and ledgered rather than sent without the sentence the ruling says it must have.

        A row whose CLASS the ask copy was not written for carries a `refuse` reason too, and for the same reason:
        `copy.ASK` is erasure copy, and a `dmca_takedown` or `legal_threat` row reaches the same `ASK_LINK` verdict.
        Sending it would tell a rights-holder that "the deletion request you made" is in progress (QA finding on
        #1779). Refused, not dropped: the ledger records why, and the row stays visible in the batch."""
        now = now or datetime.now(timezone.utc)
        out = []
        for r in self.store.all("open"):
            kind = r["identity_verdict"]
            if kind in copy.ASK and not r["ask_sent_at"]:
                past_due = parse_iso(r["due_at"]) <= now
                text = copy.ASK[kind]
                if past_due:
                    text = copy.progress_line(r["received_at"]) + "\n\n" + text
                out.append({"row": r["id"], "register_no": r["register_no"], "channel": r["channel"],
                            "to": r["conversation_id"] or r["requester_email"] or r["gmail_thread"], "kind": kind,
                            "text": text, "due_at": r["due_at"], "received_at": r["received_at"],
                            "class": r["class"], "past_due": past_due,
                            "refuse": ask_refusal(r["class"], past_due)})
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
        """(register_no, line) to page: due_at - 3 d reached without confirmed_at; an ASK sent > 7 d ago with no
        answer. The register number is the identity of the page content, so the caller pages on TURNOVER (a new
        request became due) and not on a line COUNT that one request clearing can leave unchanged."""
        out = []
        for r in self.store.all("open"):
            if r["class"] not in ("privacy_erasure", "legal_threat", "dmca_takedown", "privacy_access"):
                continue
            due = parse_iso(r["due_at"])
            if not r["confirmed_at"] and now >= due - timedelta(days=WARN_DAYS):
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

    def hide_due_rows(self, now: datetime, include_legal: bool = False) -> list[tuple[int, str]]:
        """(register_no, line) for requests whose 24-hour HIDE deadline has passed and whose page is not hidden.

        `hide_due_at` is received + 24 h (the ruling's first step). The batch itself is a human-merged PR, so this
        is the alert that keeps the deadline from passing in silence: without it the hourly tick runs green until
        the 30-day confirmation warning three weeks later."""
        from gdpr_pipeline import identity as _id
        from gdpr_pipeline.identity import GONE, IDENTITY_PASS, LEGAL_HIDE_FIRST
        eligible = IDENTITY_PASS + ((LEGAL_HIDE_FIRST,) if include_legal else ())
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
            out.append((r['register_no'],
                        f"#{r['register_no']} {r['channel']} received {r['received_at'][:10]}: the 24-hour HIDE "
                        f"deadline passed ({r['hide_due_at'][:10]}) and {len(pending)} page(s) are not hidden yet "
                        f"({shown}{', ...' if len(pending) > 3 else ''}); row identity {r['identity_verdict']}; "
                        f"next: open/merge the hide batch PR"))
        return out

    def watchdog(self, now: datetime) -> list[str]:
        return [line for _, line in self.watchdog_rows(now)]


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
    base = head or (f"<@{JAN}> :hourglass: *GDPR erasure register: {len(lines)} request(s) at or past due - 3 d "
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
