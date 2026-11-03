#!/usr/bin/env python3
"""Where is this user in the conversation, right now? The send-time communication-state check (captain 2026-10-28
18:2xZ, hard precondition before any go-live batch: "make sure we dont communicate again if someone sent in proof
already - think about each com status"). READ-ONLY. The gate calls it immediately before every real send of a
go-live campaign (credit-hold-status, claim-proof-pending, merge-pending, the R1 receipt), so a reply or a filing
that lands between the list cut and the send cancels the note. Nothing is read from a cached list.

The loop, latest state wins and we never step backwards:
    asked -> replied -> acknowledged -> checked -> decided -> told

Rules (exit 3 = HOLD with the reasons; nothing is sent or claimed):
  L14a / L14b ("please wait for that message before sending anything"): never to a user who has ANY document or
     reply on file: a proof_intake row, a dv_outcomes row, a proof-on-file entry (Intercom / support@ / core
     verification), a ledger note we tagged as carrying proof or a reply, or an Intercom part the user wrote (any
     attachment ever, or any message after our last ask). Never to a user we already acknowledged (R1 sent), and
     never about a request that is already decided. Those users get R1 (receipt) or nothing.
  R1 (receipt): never once a request it names is decided or told (approved / rejected / approval notice).
  every go-live line: never within 7 days of ANY other note from the verify gate to the user (any campaign), nor
     of an admin / Caroline comment in the conversation the note would go into (R5).
  R1 into a filing conversation (p1 on the batch-1 dry run, 18:5xZ): never when the customer's last part there is
     more than 30 days old (R6: a stale thread gets nothing; the document is still filed and read), nor when our
     last line there closed the matter ("sorted", "resolved", ...; R7).
  every go-live line: never to a user the production fraud lens holds or the watchlist / deny list names (R8),
     read at send time, not only at the list cut.
  L11c (proof-need-ask; p1 ruling 096): sent ONLY at state 'checked' for the document it names (a dv_outcomes row
     with a need code for need.doc_sha on the request); held when anything newer arrived after that document (a
     proof_intake row, an Intercom customer message or attachment), when the request is decided or told, and by
     the 7-day rule (which also makes it the >= 7-day 'checked' follow-up after a receipt). R6/R7 apply to its
     filing conversation. A document on file never holds it: it is why the ask goes.
Unreadable store, replica or Intercom read = UNKNOWN (exit 2): the gate sends nothing.

CLI:  comm_state.py check --campaign C --user-id N --request-ids a,b [--contact-id X]
      -> {"hold": bool, "state": "...", "reasons": [...]}   exit 0 send / 3 hold / 2 unknown
"""
from __future__ import annotations

import argparse
import csv
import html
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

LEDGER = os.environ.get("COMM_STATE_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
PROOF_STORE = os.environ.get("COMM_STATE_PROOF_STORE", "/var/lib/hydra-credit-verify/proof.sqlite")
DV_STORE = os.environ.get("COMM_STATE_DV_STORE", "/var/lib/hydra-credit-verify/doc-verify.sqlite")
PROOF_ON_FILE = os.environ.get("COMM_STATE_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")
TRINO = os.environ.get("COMM_STATE_TRINO", "/opt/hydra/scripts/trino-query.sh")
INTERCOM = "https://api.intercom.io"
# The lines that must never reach someone who already sent proof or replied: the "wait for our message" notes and
# the uvn-status proof ask (captain 03:2xZ: L14a retired, its audience gets the ask; p1 115 / l1 [key=l14a-retire-ask]:
# sent only at state none / asked-with-no-reply).
# merge-claim-first is a wait line (r5 NO-GO @eb751806 + QA #1566): proof on file, a reply or a decision holds it.
WAIT_LINES = ("credit-hold-status", "claim-proof-pending", "uvn-status", "claim-proof-ask", "merge-claim-first")
RECEIPT = "status-doc-received"
NEED_ASK = "proof-need-ask"
ASKABLE_NEEDS = ("readable_document", "counterparty_signed_or_registered", "issuer_email_from_official_domain",
                 "distributor_dashboard_with_code")   # the gate holds the last two at send
# The "nothing else is needed" family (message-book-1029 A2/A3/C3/C4/D3; Fable [key=message-book-1029], captain 'just
# go'): only ever to a user who owes NOTHING. Checked at send with one replica read + the ledger + the hold list.
REVIEW_FIRED = r'"review_[a-z_]+":\s*[1-9]'


def nothing_else(campaign: str, copy: str) -> bool:
    return campaign in ("status-team-review", "claim-status") or (campaign == RECEIPT and copy in ("docrecv", "docrecvq"))

ASKS = ("verify-live", "retro-past", "uvn-status", "gap-ask", "proof-need-ask", "claim-proof-ask")
TELL_NOTES = ("removal-notice", "takeback-notice", "withdrawal-confirm")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
CONV_CAP = 60
STALE_THREAD_DAYS = 30
RESOLVED = re.compile(r"\b(all sorted|sorted now|it'?s sorted|now sorted|resolved|all set|taken care of|fixed now|"
                      r"closing this|closed this|marked as resolved)\b", re.I)
POLICIES = os.environ.get("COMM_STATE_POLICIES", "/opt/hydra/policies")
ACCOUNT_HOLDS = os.environ.get("COMM_STATE_ACCOUNT_HOLDS", "/opt/firstmate/fraud-lens/out/account_holds.jsonl")
ACCOUNT_HOLDS_MAX_AGE = 72 * 3600
# [key=r8-hold-due] (r5/p1 10-31): the lens's per-user hold KIND, from its hourly scan. Asks ignore a hold held ONLY by
# unanchored volume (it holds approvals, never the ask that resolves it); everything else holds on R8_hard.
ACCOUNT_BANDS = os.environ.get("COMM_STATE_ACCOUNT_BANDS", "/opt/firstmate/fraud-lens/out/account_bands.json")
ACCOUNT_BANDS_MAX_AGE = 3 * 3600
HOLD_VOLUME = "R8_approval_hold_volume"
HOLD_HARD = "R8_account_hold"
Query = Callable[[str], "list[list[str]]"]
Intercom = Callable[[str, str, dict | None], dict]


class Unknown(RuntimeError):
    pass


def _ts(v: Any) -> str:
    s = str(v or "").strip().replace(" UTC", "").replace(" ", "T")
    return s[:19] if len(s) >= 19 else ""


def trino(sql: str) -> list[list[str]]:
    try:
        p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=300, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unknown(f"replica read did not run: {type(exc).__name__}") from exc
    if p.returncode:
        raise Unknown(f"replica read failed: {p.stderr.strip()[-160:]}")
    return list(csv.reader(io.StringIO("\n".join(ln for ln in p.stdout.splitlines() if ln.startswith('"')))))


def intercom(method: str, path: str, body: dict | None = None) -> dict:
    tok = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if not tok:
        raise Unknown("no Intercom token")
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(4):
        req = urllib.request.Request(INTERCOM + path, data=data, method=method, headers={
            "Authorization": f"Bearer {tok}", "Accept": "application/json", "Content-Type": "application/json",
            "Intercom-Version": "2.11"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as exc:
            if exc.code == 429 and attempt < 3:
                time.sleep(3 * (attempt + 1))
                continue
            raise Unknown(f"Intercom {method} {path.split('?')[0]} -> {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            raise Unknown(f"Intercom {method} unreadable: {type(exc).__name__}") from exc
    raise Unknown("Intercom rate-limited")


def _ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def store_facts(uid: int, keys: list[str] | tuple[str, ...] = (), since: str = "") -> dict[str, Any]:
    """Documents on file for this user in our own stores. p1 198 / Fable 199 (rule): only a document that could be
    proof of the NAMED requests counts - one that arrived on/after the oldest named request was created (`since`,
    ISO UTC; empty = unknown = every document counts, fail closed) or one tied to a named request."""
    out: dict[str, Any] = {"docs": [], "acked": "", "notes_7d": [], "told_notes": [], "last_ask": "", "last_sent": None,
                          # the Intercom contact our newest note went to: the render-time read needs it to see the files
                          # the customer sent us (QA #1660 b), and it must be the contact the send-time check reads
                          "last_contact": "", "_contact_at": 0.0}
    want0 = {str(k).lower() for k in keys}
    try:
        db = _ro(PROOF_STORE)
        cols = {r[1] for r in db.execute("PRAGMA table_info(proof_intake)")}
        cand = "coalesce(candidate_request_ids_json, '[]')" if "candidate_request_ids_json" in cols else "'[]'"
        for at, cj in db.execute(f"SELECT received_at, {cand} FROM proof_intake WHERE user_id=?", (uid,)):
            try:
                named = {str(x).lower() for x in json.loads(cj or "[]")}
            except ValueError:
                named = set()
            # p1 203: filed against a named request, or arrived on/after the oldest named request was created
            if not since or named & want0 or not _ts(at) or _ts(at) >= since:
                out["docs"].append("proof_intake")
                break
    except sqlite3.Error as exc:
        raise Unknown(f"proof_intake unreadable: {exc}") from exc
    if os.path.exists(DV_STORE):
        try:
            for (rid,) in _ro(DV_STORE).execute("SELECT lower(request_id) FROM dv_outcomes WHERE user_id=?", (uid,)):
                if not since or rid in want0:
                    out["docs"].append("dv_outcomes")
                    break
        except sqlite3.Error as exc:
            raise Unknown(f"doc-verify store unreadable: {exc}") from exc
    try:
        with open(PROOF_ON_FILE, encoding="utf-8") as fh:
            entries = json.load(fh).get("entries") or []
    except (OSError, ValueError) as exc:
        raise Unknown(f"proof-on-file unreadable: {exc}") from exc
    srcs = sorted({str(e.get("source") or "?") for e in entries if str(e.get("user_id")) == str(uid)
                   and (not since or str(e.get("request_id") or "").lower() in want0
                        or not _ts(str(e.get("proof_at") or "")) or _ts(str(e.get("proof_at"))) >= since)})
    if srcs:
        out["docs"].append("proof_on_file:" + "+".join(srcs))
    try:
        db = _ro(LEDGER)
        rows = db.execute("SELECT campaign, kind, status, coalesce(sent_at, created_at), last_reply_at, proof_tagged_at, day, "
                          "coalesce(request_ids_json, '[]'), message_id, coalesce(contact_id, '') "
                          "FROM verify_messages WHERE account_id=?", (str(uid),)).fetchall()
    except sqlite3.Error as exc:
        raise Unknown(f"verify ledger unreadable: {exc}") from exc
    week = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d")
    want = {str(k).lower() for k in keys}
    for camp, kind, status, at, _reply, tagged, day, ids_json, msg_id, contact in rows:
        if status not in ("sent", "attempted"):
            continue
        # a TEXT reply is never 'replied' (Fable 199); a tagged proof (attachments after our note) is
        if _ts(tagged) and (not since or _ts(tagged) >= since):
            out["docs"].append(f"ledger_reply:{camp}")
        if camp == RECEIPT:
            out["acked"] = max(out["acked"], _ts(at))
        if camp in ASKS and kind == "initial":
            out["last_ask"] = max(out["last_ask"], _ts(at))
        # A removal / take-back / withdrawal note "told" only the requests it named (QA #1460): an old note about
        # credit A never marks a new request B as told.
        if camp in TELL_NOTES:
            try:
                named = {str(r).lower() for r in json.loads(ids_json or "[]")}
            except ValueError:
                named = set()
            if named & want:
                out["told_notes"].append(camp)
        if str(day or "") >= week:
            out["notes_7d"].append(camp)
        # the newest note we sent this user, whatever its campaign: the [key=mcf-wait-lines] waiver needs its CLASS and
        # its Intercom message id (QA #1660 a: the waiver matches the part by ID, never by a timestamp window - a manual
        # admin part posted seconds after our ledgered status would otherwise be read as that status)
        if _ts(at) and (out["last_sent"] is None or _ts(at) > out["last_sent"][1]):
            out["last_sent"] = (camp, _ts(at), str(msg_id or ""))
        # the newest note that NAMES a contact (older rows may predate the column): the render-time read searches this
        # customer's Intercom conversations, so a blank here means the fact cannot be read - never 'nothing on file'
        if contact and (not out.get("_contact_at") or _ts(at) > out["_contact_at"]):
            out["last_contact"], out["_contact_at"] = str(contact), _ts(at)
    out.pop("_contact_at", None)
    return out


def core_facts(uid: int, keys: list[str], query: Query) -> dict[str, Any]:
    """Decided / told state of the named requests (credits) and the user's latest core ask marker."""
    out: dict[str, Any] = {"decided": [], "told": [], "last_ask": "", "created": ""}
    rows = query("SELECT lower(CAST(id AS varchar)), status, "
                 "coalesce(json_extract_scalar(metadata, '$.approvedNotice.noticeSentAt'), ''), "
                 "coalesce(json_extract_scalar(metadata, '$.proofRequest.noticeSentAt'), ''), "
                 "CAST(createdat AS varchar) "
                 f"FROM postgresql_core.public.credit_requests WHERE userid = {int(uid)} AND deletedat IS NULL")
    want = {k.lower() for k in keys}
    created: list[str] = []
    for row in rows:
        if len(row) not in (4, 5):
            raise Unknown("unexpected replica row shape")
        rid, status, notice, ask = row[:4]
        if rid in want:
            created.append(_ts(row[4]) if len(row) == 5 else "")
        out["last_ask"] = max(out["last_ask"], _ts(ask))
        if rid in want:
            if status in ("approved", "rejected"):
                out["decided"].append(rid)
            if _ts(notice):
                out["told"].append(rid)
    claims = [k.split("-", 1)[1] for k in keys if k.startswith("claim-") and k.split("-", 1)[1].isdigit()]
    if claims:
        for row in query("SELECT CAST(id AS varchar), status FROM postgresql_core.public.claiming "
                         f"WHERE userid = {int(uid)} AND id IN ({','.join(claims)})"):
            if len(row) != 2:
                raise Unknown("unexpected replica row shape")
            if row[1] not in ("pending", "processing"):
                out["decided"].append(f"claim-{row[0]}")
    # the oldest named request's creation (ISO UTC); empty when any named request's date is unknown (fail closed)
    out["created"] = min(created) if created and all(created) else ""
    return out


# who answers for us in Intercom: a teammate, a bot, or a team inbox (one set for every 'did we answer' check; QA #1509)
SUPPORT_AUTHORS = ("admin", "bot", "team")
URL_RE = re.compile(r"https?://([^/\s?#:]+)", re.I)
# a shared-document link = a URL whose HOST is one of these providers or a subdomain of one (QA #1508: matched on the
# parsed hostname - 'sandbox.com/help' or 'drive.google.com.evil.example' are not documents)
DOC_HOSTS = ("drive.google.com", "docs.google.com", "dropbox.com", "onedrive.live.com", "1drv.ms", "icloud.com",
             "wetransfer.com", "we.tl", "box.com", "sharepoint.com")


def has_doc_link(text: str) -> bool:
    for host in URL_RE.findall(text or ""):
        h = host.lower().rstrip(".")
        if any(h == d or h.endswith("." + d) for d in DOC_HOSTS):
            return True
    return False


def documents_on_file(uid: int, core: dict[str, Any], st: dict[str, Any], contact_id: str, ic: Intercom) -> list[str]:
    """THE documents-on-file fact for a wait-line campaign: our own stores (`st['docs']`) PLUS the files the customer
    sent us in Intercom. One function because the fact has exactly one meaning (QA #1660 b): the render read
    (`proof-on-file`, which decides whether the acknowledgement sentence can appear) and the send-time check both call
    it, so they cannot drift. `contact_id` empty = the customer's Intercom contact is unknown = the fact cannot be
    read (`intercom_facts` raises Unknown), never a silent "nothing on file"."""
    return st["docs"] + intercom_facts(contact_id, max(st["last_ask"], core["last_ask"]), ic, core["created"])


def intercom_facts(contact_id: str, last_ask: str, ic: Intercom, since: str = "", *, attach_since: float | None = None,
                   filing: tuple[str, float] | None = None, text_after_ask: bool = False) -> list[str]:
    """An attachment (or a shared-document link) the user sent us in Intercom on/after `since` (the oldest named
    request's creation; empty = any time) - or on/after `attach_since` (epoch) when given. Fable 199: a text message
    is never 'replied' ... except for the per-need ask (`text_after_ask`, L11c p1 096): ANY customer message after
    `last_ask` (the document's arrival) holds it - a correction or a question about that document is news.
    `filing` = (conversation, epoch) of the document's OWN part (proof_intake.received_at is that part's created_at):
    exactly that part is not news; every other customer part from that second on is."""
    since_epoch = datetime.fromisoformat(since).replace(tzinfo=timezone.utc).timestamp() if since else None
    if attach_since is not None:
        since_epoch = attach_since
    ask_epoch = (datetime.fromisoformat(last_ask).replace(tzinfo=timezone.utc).timestamp()
                 if text_after_ask and last_ask else None)
    if not contact_id:
        raise Unknown("no Intercom contact to read")
    found: list[str] = []
    res = ic("POST", "/conversations/search", {"query": {"field": "contact_ids", "operator": "=", "value": contact_id},
                                              "pagination": {"per_page": CONV_CAP}})
    convs = res.get("conversations")
    if not isinstance(convs, list):
        raise Unknown("conversation search unreadable")
    if (res.get("total_count") or len(convs)) > CONV_CAP:
        return ["intercom:more_conversations_than_checked"]   # in doubt: treat as having replied
    for c in convs:
        cid = str(c.get("id") or "")
        if not cid.isdigit():
            raise Unknown("conversation id unreadable")
        conv = ic("GET", f"/conversations/{cid}?display_as=plaintext", None)
        # the opening message's time: Intercom may leave source.created_at out and date the opening on the
        # conversation itself (QA #1508; the shell gate reads the top-level date too) - unknown only when neither is set
        src = dict(conv.get("source") or {})
        if not src.get("created_at"):          # absent, null or 0: the conversation's own date (QA #1508)
            src["created_at"] = conv.get("created_at") or c.get("created_at")
        parts = [src] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
        # proof_intake keeps no Intercom part id (provenance is a cache path or an attachment index), so the filing
        # part is recognised only when it is the ONE customer attachment part of the filing conversation in that
        # second; a second one in the same second (a correction) makes it ambiguous and the ask holds (QA round 4)
        same_second = sum(1 for p in parts if filing and cid == filing[0] and p.get("attachments")
                          and (p.get("author") or {}).get("type") in ("user", "lead", "contact")
                          and int(p.get("created_at") or 0) == int(filing[1]))
        for p in parts:
            if (p.get("author") or {}).get("type") not in ("user", "lead", "contact"):
                continue
            if filing and p.get("attachments") and cid == filing[0] and int(p.get("created_at") or 0) == int(filing[1]) \
                    and same_second == 1:
                continue                                  # the filing event itself (the ONLY such part: fail closed)
            fresh = since_epoch is None or not p.get("created_at") or p["created_at"] >= since_epoch
            # an attachment with no readable time counts (fail closed; b1 C3)
            if p.get("attachments") and fresh:
                found.append(f"intercom_attachment:{cid}")
            # a text reply is not 'replied' - but a LINK to a shared document is a document (b1 on #1508)
            elif fresh and has_doc_link(p.get("body") or ""):
                found.append(f"intercom_document_link:{cid}")
            # the per-need ask only: any customer message after the document (text included) is news
            # (same SECOND included, QA #1418 06:34Z: Intercom times are whole seconds, so a correction sent with the
            # filing attachment shares its second - any customer text part other than the filing part counts)
            elif ask_epoch is not None and int(p.get("created_at") or 0) >= int(ask_epoch) and (p.get("body") or "").strip():
                found.append(f"intercom_reply_after_ask:{cid}")
    return sorted(set(found))


def thread_facts(conversation: str, ic: Intercom, now: float | None = None,
                 extra: dict[str, Any] | None = None) -> list[str]:
    """R5 / R6 / R7 on the conversation the note would go into (R6/R7 apply to R1 only; see decide).
    `extra`, when given, receives the LAST customer-visible part ({ours, at}) - an internal note is not a message the
    customer received, so it never counts (r5 [key=mcf-wait-lines] 2)."""
    if not conversation:
        return []
    if not conversation.isdigit():
        raise Unknown("conversation id unreadable")
    now = now or time.time()
    conv = ic("GET", f"/conversations/{conversation}?display_as=plaintext", None)
    if str(conv.get("id") or "") != conversation:
        raise Unknown("conversation unreadable")
    parts = [conv.get("source") or {}] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
    out: list[str] = []
    admin = [p for p in parts if (p.get("author") or {}).get("type") in SUPPORT_AUTHORS
             and (p.get("part_type") or "comment") not in ("note",) and (p.get("body") or "").strip()]
    if any((p.get("created_at") or 0) >= now - 7 * 86400 for p in admin):
        out.append("R5_admin_comment_7d")
    cust = [p.get("created_at") or 0 for p in parts if (p.get("author") or {}).get("type") in ("user", "lead", "contact")]
    if not cust or max(cust) < now - STALE_THREAD_DAYS * 86400:
        out.append("R6_stale_thread")
    if str(conv.get("state") or "").lower() == "closed" or conv.get("open") is False:
        out.append("R7_thread_closed")            # r5: a closed conversation is not a delivery target
    if admin:
        last = max(admin, key=lambda p: p.get("created_at") or 0)
        if RESOLVED.search(last.get("body") or "") and (last.get("created_at") or 0) >= max(cust or [0]):
            out.append("R7_thread_resolved")
    if extra is not None:
        visible = [p for p in parts if (p.get("part_type") or "comment") != "note" and (p.get("body") or "").strip()]
        if visible:
            last = max(visible, key=lambda p: p.get("created_at") or 0)
            # `id` is the part's identity: for a part we posted it IS the ledger's message_id (verified against prod
            # conversations), so the waiver below matches a send, not a moment in time (QA #1660 a)
            extra["last_part"] = {"ours": (last.get("author") or {}).get("type") in SUPPORT_AUTHORS,
                                  "at": float(last.get("created_at") or 0),
                                  "id": str(last.get("id") or "")}
    cparts = [p for p in parts if (p.get("author") or {}).get("type") in ("user", "lead", "contact")]
    if cparts and RESOLVED.search(max(cparts, key=lambda p: p.get("created_at") or 0).get("body") or ""):
        out.append("R7_thread_resolved")          # the customer's own last word: it is sorted
    return sorted(set(out))


def _bands_users(path: str, now: float) -> dict[str, Any] | None:
    """The lens's current scan, per user id - or None when it is missing, unreadable, older than 3 h or future-dated."""
    try:
        age = now - os.path.getmtime(path)
        if age > ACCOUNT_BANDS_MAX_AGE or age < -300:
            return None
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        users = doc.get("users")
    except (OSError, ValueError, AttributeError):
        return None
    return users if isinstance(users, dict) else None


def _scan_failed(path: str) -> set[str] | None:
    """The users the lens's scan could NOT read (failed_chunks_users); None when that list is absent or malformed (the
    scan's completeness is then unknown, so an absence proves nothing)."""
    try:
        with open(path, encoding="utf-8") as fh:
            failed = json.load(fh).get("failed_chunks_users")
    except (OSError, ValueError, AttributeError):
        return None
    return {str(u) for u in failed} if isinstance(failed, list) else None


_ABSENT = object()


def held_user_ids(holds_path: str | None = None, bands_path: str | None = None, now: float | None = None) -> set[str]:
    """[key=r8-release-row] (r5 + p1 10-31): THE one reader of the fraud lens's account-hold ledger - every reader (asks,
    stale-velocity revalidate, validator-reject close, owing_proof, receipts) goes through it; none parses the file.
    A user's hold state is their LATEST row by `at`: approval_hold = held; release = clear ONLY when the lens's current
    scan agrees (account_bands.json fresh and the user not `hold` in it) - disagreement, or a missing / unreadable /
    stale band, = held. A row with an unreadable `at` or an unknown kind holds that user. The ledger itself missing,
    unreadable, older than 72 h or future-dated = Unknown (no reader may treat 'no file' as 'nobody held')."""
    holds_path, bands_path, now = holds_path or ACCOUNT_HOLDS, bands_path or ACCOUNT_BANDS, now or time.time()
    try:
        age = now - os.path.getmtime(holds_path)
        latest: dict[str, tuple[datetime, int, str]] = {}
        doubtful: set[str] = set()
        with open(holds_path, encoding="utf-8") as fh:
            for i, ln in enumerate(fh):
                if not ln.strip():
                    continue
                row = json.loads(ln)
                uid, kind = str(row.get("user_id")), row.get("kind") or "approval_hold"
                try:
                    at = datetime.fromisoformat(str(row.get("at") or "").replace("Z", "+00:00"))
                    at = at if at.tzinfo else at.replace(tzinfo=timezone.utc)
                except ValueError:
                    doubtful.add(uid)
                    continue
                if kind not in ("approval_hold", "release"):
                    doubtful.add(uid)
                if uid not in latest or (at, i) >= latest[uid][:2]:
                    latest[uid] = (at, i, kind)
    except (OSError, ValueError, AttributeError) as exc:
        raise Unknown(f"account holds unreadable: {exc}") from exc
    if age > ACCOUNT_HOLDS_MAX_AGE:
        raise Unknown(f"account holds are {int(age // 3600)}h old (> 72h)")
    if age < -300:      # a future mtime (> 5 min ahead): its age is unknowable (QA #1456 on G8)
        raise Unknown("account holds mtime is in the future; age unknown")
    bands = _bands_users(bands_path, now)
    failed = _scan_failed(bands_path) if bands is not None else None
    held = set(doubtful)
    for uid, (_, _, kind) in latest.items():
        if kind != "release":
            held.add(uid)
            continue
        # QA #1570: only a VALID agreement confirms the release - the scan says decision 'allow', or the user is absent
        # from a COMPLETE scan (failed_chunks_users readable and not naming them). A present but malformed entry (null,
        # an unknown decision), a scan whose completeness is unknown, or 'hold' = held.
        cur = bands.get(uid, _ABSENT) if bands is not None else None
        agrees = (isinstance(cur, dict) and cur.get("decision") == "allow") or \
                 (cur is _ABSENT and failed is not None and uid not in failed)
        if not agrees:
            held.add(uid)
    return held


def account_hold_facts(uid: int, now: float | None = None) -> list[str]:
    """R8 (r5): is this user held (held_user_ids), and the hold's kind; the ledger stale or unreadable = UNKNOWN."""
    now = now or time.time()
    return [hold_kind(uid, now)] if str(uid) in held_user_ids(now=now) else []


def hold_kind(uid: int, now: float | None = None) -> str:
    """The kind of a held user's hold: HOLD_VOLUME only when the lens's CURRENT scan (account_bands.json, at most 3 h
    old) says this user is held and the kind is R8_approval_hold_volume; anything else - hard, an unknown kind, the
    user absent, the file missing, unreadable, stale or future-dated - is HOLD_HARD (fail-closed: held for everything).
    Either kind is truthy, so every approval-side reader keeps holding."""
    bands = _bands_users(ACCOUNT_BANDS, now or time.time())
    if bands is None:
        return HOLD_HARD
    row = bands.get(str(uid)) or {}
    return HOLD_VOLUME if isinstance(row, dict) and row.get("decision") == "hold" and row.get("hold_kind") == HOLD_VOLUME \
        else HOLD_HARD


# merge-claim-first resolves a volume-only hold the same way the asks do (Fable [key=r8-hold-due]; QA #1566): it reads
# the CURRENT scan's kind through hold_kind() - stale / unreadable / unknown / hard = R8_account_hold, which holds it.
# It is not in ASKS: it is not a credit ask (no last_ask, no owes:open_ask).
VOLUME_PASS_CAMPAIGNS = ("merge-claim-first",)

# r5 fable-copy-1103-r5/mcf-proof-ack (2026-11-03 13:5xZ): merge-claim-first is the ONE campaign whose copy ACKNOWLEDGES
# the documents on file, so proof on file stops being a hold for it and becomes a REQUIRED RENDER FACT instead: the
# sentence is rendered from that fact, read fresh per recipient, and a missing/unreadable fact is a refusal in the gate
# (mcf_proof_unreadable) - never a body without the sentence, never a rendered blank.
MERGE_CLAIM_FIRST = "merge-claim-first"

# r5 (2) [key=mcf-wait-lines] 2026-11-03: the 7-day recency hold is WAIVED for merge-claim-first only when nothing is
# left open on the customer's side - the LAST customer-visible part in that conversation is OURS and its class is a
# status/receipt/admin comment. Our own earlier ASK (including a merge-claim ask) is not a status: the 7-day rule stands.
LAST_PART_WAIVER_CAMPAIGN = MERGE_CLAIM_FIRST
STATUS_CLASSES = (RECEIPT, "status-team-review", "email-changed", "email-changed-dup", "credit-hold-status",
                  "merge-pending")



def fraud_facts(uid: int, query: Query) -> list[str]:
    """R8: the production fraud lens (holds, velocity, single-signal) + watchlist + the decider's deny list."""
    from credit_review import fraud_lens  # noqa: PLC0415  (read at send time)
    try:
        v = fraud_lens.default_lens(query, watchlist_path=os.path.join(POLICIES, "fraud-watchlist.json"),
                                    holds_path=os.path.join(POLICIES, "fraud-lens-holds.json"))([uid])[uid]
        with open(os.path.join(POLICIES, "credit-trust-decide.json"), encoding="utf-8") as fh:
            deny = {int(x) for x in (json.load(fh).get("deny_user_ids") or []) if str(x).isdigit()}
    except (ValueError, OSError, KeyError) as exc:
        raise Unknown(f"fraud lens unreadable: {exc}") from exc
    out = account_hold_facts(uid)
    if v.held:
        out.append("R8_fraud_lens_held")
    if v.watch:
        out.append("R8_watchlist")
    if uid in deny:
        out.append("R8_deny_list")
    return out


def newer_intake(doc_at: str, arrivals: list[Any] | tuple[Any, ...], named: set[str] | frozenset[str] = frozenset()) -> bool:
    """L11c 'anything newer holds' (QA #1418): did ANY intake of this user arrive after the named document? The ONE
    predicate shared by the send-time check (need_facts) and the batch builder's selection (need_asks.payloads).
    An arrival is (received_at, intake_id) (a bare time = a pre-intake-id row). QA #1513: whole-second times cannot
    order two intakes of the same second, so a DIFFERENT intake (not one the message names) in the SAME second as the
    named document counts as newer too."""
    t = _ts(doc_at)
    for a in arrivals:
        at, iid = (a[0], str(a[1] or "")) if isinstance(a, (list, tuple)) else (a, "")
        ts = _ts(at)
        if ts > t or (ts == t and iid and iid not in named):
            return True
    return False


def need_facts(uid: int, keys: list[str], doc_sha: str, doc_at: str, need_code: str = "",
               doc_map: dict[str, str] | None = None, doc_intakes: dict[str, str] | None = None) -> dict[str, Any]:
    """L11c: was EVERY named request checked with a need code, and did anything arrive after the NEWEST named document
    (doc_sha / doc_at; Fable [key=l11c-plural] (c))?"""
    out: dict[str, Any] = {"checked": False, "newer": [], "unchecked": []}
    # the NAMED documents (QA #1418 round 4): doc_sha may list every document the message names, comma-separated
    named = {s.strip().lower() for s in (doc_sha or "").split(",") if re.fullmatch(r"[0-9a-fA-F]{64}", s.strip())}
    if not named or not doc_at:
        raise Unknown("proof-need-ask needs the newest named document (doc sha and arrival time)")
    # r5 / QA #1418: each request is judged ONLY on its own document (need.doc_map); several named documents with no
    # per-request map cannot be judged
    doc_map = {str(k).lower(): str(v).lower() for k, v in (doc_map or {}).items()}
    if len(named) > 1 and not doc_map:
        raise Unknown("several named documents and no per-request document map")
    # QA #1418 / b1 272: each named document is bound to the EXACT intake doc-verify read (need.doc_intakes, from
    # dv_outcomes.intake_id). A same-sha re-upload is a different intake; it never borrows the earlier intake's read.
    doc_intakes = {str(k).lower(): str(v) for k, v in (doc_intakes or {}).items() if str(v)}
    try:
        pdb = _ro(PROOF_STORE)
        pcols = {r[1] for r in pdb.execute("PRAGMA table_info(proof_intake)")}
        # an intake store without intake ids names each arrival by its row (still one id per arrival, never per file)
        pid_col = "coalesce(intake_id, '')" if "intake_id" in pcols else "'rowid:' || rowid"
        intakes = list(pdb.execute(
            f"SELECT lower(file_sha256), received_at, {pid_col} FROM proof_intake WHERE user_id=? "
            "ORDER BY received_at, rowid", (uid,)))
    except sqlite3.Error as exc:
        raise Unknown(f"need facts unreadable: {exc}") from exc
    earliest: dict[str, str] = {}
    for sha, _at, iid in intakes:
        earliest.setdefault(sha, iid)

    def bound(proof: str, row_intake: str) -> bool:
        want = doc_intakes.get(proof)
        if not want:
            return False                              # no named intake for this document: unbound, never checked
        # a pre-intake-id read (empty dv intake_id) belongs to the file's FIRST arrival only
        return row_intake == want if row_intake else want == earliest.get(proof)
    try:
        if os.path.exists(DV_STORE):
            db = _ro(DV_STORE)
            dcols = {r[1] for r in db.execute("PRAGMA table_info(dv_outcomes)")}
            iid_col = "coalesce(intake_id, '')" if "intake_id" in dcols else "''"
            doc_state: dict[str, bool] = {}               # named document -> still an askable need on every bound read
            for k in keys:
                # the unit is (request, DOCUMENT) (p1 156, b1 153): the request is askable when SOME document's LATEST row
                # for it is still an unverifiable need. A document re-checked since the cut no longer counts (r5 / QA
                # #1418), and a dashboard or verified read of ANOTHER document does not cancel this one.
                # the latest row per (document, INTAKE): a later read of another intake of the same file is its own unit
                rows = db.execute(f"SELECT proof_id, outcome, coalesce(need, ''), {iid_col} FROM dv_outcomes d WHERE "
                                  "user_id=? AND lower(request_id)=? AND id = (SELECT e.id FROM dv_outcomes e WHERE "
                                  "e.user_id=d.user_id AND lower(e.request_id)=lower(d.request_id) AND e.proof_id=d.proof_id "
                                  f"AND {iid_col.replace('intake_id', 'e.intake_id')} = {iid_col.replace('intake_id', 'd.intake_id')} "
                                  "ORDER BY e.at DESC, e.id DESC LIMIT 1)", (uid, k.lower())).fetchall()
                # ... on a document THIS message names (QA #1418 round 4: another document's row never stands in for
                # the named one), and that latest row's need is the one this message is about (round 3)
                if not doc_map:
                    own = named
                elif doc_map.get(k.lower()) in named:
                    own = {doc_map[k.lower()]}
                else:
                    own = set()                       # unmapped, or mapped to a document the message does not name
                if not any(str(p).lower() in own and o == "unverifiable" and n in ASKABLE_NEEDS
                           and (not need_code or n == need_code) and bound(str(p).lower(), str(ri)) for p, o, n, ri in rows):
                    out["unchecked"].append(k)
                for p, o, n, ri in rows:
                    pl = str(p).lower()
                    if pl in named and bound(pl, str(ri)):
                        ok = o == "unverifiable" and n in ASKABLE_NEEDS and (not need_code or n == need_code)
                        doc_state[pl] = doc_state.get(pl, True) and ok
            # QA #1418 (23:39Z): EVERY document the message names - not only each request's newest - must still be an
            # askable need on its latest bound read; one re-checked since the cut (or never read on a named request)
            # makes "the documents ... can't be checked" false: hold
            for pl in (sorted(named) if not out["unchecked"] else []):    # (a request already failing holds anyway)
                if not doc_state.get(pl, False):
                    out["unchecked"].append(f"named_document_rechecked:{pl[:8]}")
            out["checked"] = bool(keys) and not out["unchecked"]
        # by ARRIVAL, not content (QA #1418): any intake of this user that arrived after the newest named document,
        # even the same file again, means they sent us something since - the ask waits
        # QA #1418: the comparison point must BE the arrival of a named document's OWN (bound) intake - a doc_at that
        # matches another intake (a same-sha re-upload) could make that re-upload look already read; it holds
        if not any(sha in named and _ts(at) == _ts(doc_at) and doc_intakes.get(sha) == iid for sha, at, iid in intakes):
            out["newer"].append("doc_at_not_the_arrival_of_the_named_intake")
        if newer_intake(doc_at, [(at, iid) for _sha, at, iid in intakes], set(doc_intakes.values())):
            out["newer"].append("newer_document:proof_intake")
    except sqlite3.Error as exc:
        raise Unknown(f"need facts unreadable: {exc}") from exc
    return out


def wait_line_waived(campaign: str, st: dict[str, Any], last_part: dict[str, Any] | None) -> bool:
    """r5 [key=mcf-wait-lines] (2), in code: waive our 7-day recency hold for merge-claim-first ONLY when the last
    customer-visible part IS the newest note in our own ledger - matched by the part's ID against the ledger's
    message_id (QA #1660 a) - and that note's class is a status/receipt (STATUS_CLASSES). An earlier ask of ours -
    including a merge-claim ask - is never a status, so the 7-day rule stands.

    The match is IDENTITY, never a timestamp window: a human admin part posted seconds after our ledgered status is a
    different message, and under a `gap <= N seconds` rule it was read as that status and waived both 7-day holds -  a
    customer who owed us a reply could be messaged. No last part, no ledger row, no id on either side, or an id that
    differs = no waiver (fail closed)."""
    if campaign != LAST_PART_WAIVER_CAMPAIGN or not last_part or not last_part.get("ours"):
        return False
    sent = st.get("last_sent")
    if not sent:
        return False
    camp, _at, msg_id = sent
    if camp not in STATUS_CLASSES:
        return False
    part_id = str(last_part.get("id") or "")
    return bool(part_id) and part_id == str(msg_id or "")


def decide(campaign: str, copy: str, st: dict[str, Any], core: dict[str, Any], ic_found: list[str],
           thread: list[str] | None = None, fraud: list[str] | None = None,
           need: dict[str, Any] | None = None, last_part: dict[str, Any] | None = None) -> tuple[str, list[str]]:
    """(state, hold reasons) - empty reasons = send."""
    docs = st["docs"] + ic_found
    decided = sorted(set(core["decided"]))
    told = sorted(set(core["told"])) + st["told_notes"]
    state = ("told" if told else "decided" if decided else "acknowledged" if st["acked"] else
             "replied" if docs else "asked" if (st["last_ask"] or core["last_ask"]) else "none")
    why: list[str] = list(fraud or [])
    thread = thread or []
    waived = wait_line_waived(campaign, st, last_part)
    if st["notes_7d"] and not waived:
        why.append("messaged_7d:" + "+".join(sorted(set(st["notes_7d"]))))
    if "R5_admin_comment_7d" in thread and not waived:
        why.append("messaged_7d:R5_admin_comment_in_thread")
    if campaign in WAIT_LINES:
        # r5 fable-copy-1103-r5/mcf-proof-ack: merge-claim-first's copy acknowledges the documents on file, so for it
        # proof on file is a RENDER FACT (the gate refuses when it cannot read one) and not a hold. Every other wait
        # line keeps the hold - the sentence exists only for that one approved copy.
        if docs and campaign != MERGE_CLAIM_FIRST:
            why.append("proof_on_file:" + ",".join(sorted(set(docs)))[:300])
        if st["acked"]:
            why.append("already_acknowledged")
        if decided or told:
            why.append("decided_or_told")
    elif campaign == NEED_ASK:
        nd = need or {"checked": False, "newer": []}
        if not nd["checked"]:
            why.append("not_checked:" + ",".join((nd.get("unchecked") or ["no dv_outcomes need row"])[:5]))
        newer = sorted(set(nd["newer"] + ic_found))
        if newer:
            why.append("newer_after_document:" + ",".join(newer)[:300])
        if decided or told:
            why.append("decided_or_told")
        # a CLOSED filing thread is not a hold here: the gate sends the ask by email instead (l1 [key=l11c-asks])
        why += [t for t in thread if t in ("R6_stale_thread", "R7_thread_resolved")]
        if not why:
            state = "checked"
    elif campaign == RECEIPT and copy in ("docrecvr", "docrecvn", "docrecvq", "docrecv"):
        if decided or told:
            why.append("decided_or_told:" + ",".join((decided + told)[:5]))
        why += [t for t in thread if t in ("R6_stale_thread", "R7_thread_resolved", "R7_thread_closed")]
    return state, why


def approval_path_exempt(uid: int, query: Query) -> bool:
    """r5 / p1 [h2 452] (b): a user whose EVERY open UVN row is one the approval path admits (uvn_status's own
    approval_path_admits - the same predicate, never a copy: validator-approved, risk < 30, pop 1-59, no proof needed)
    owes nothing on those rows - the decider approves them without the user. Any failure to build or judge the rows =
    not exempt (they keep owing: fail closed)."""
    try:
        from credit_review import uvn_status            # lazy: uvn_status imports this module
        rows = uvn_status.uvn_requests([int(uid)], query, ("user_verification_needed",)).get(int(uid), [])
        # each row's _no_ask is uvn_status.ask_class(raw row), which is approval_path_admits for 'approval_path'
        return bool(rows) and all(r.get("_no_ask") == "approval_path" for r in rows)
    except Exception:  # noqa: BLE001 - an unjudgeable row is never an exemption
        return False


def owes_proof(uid: int, query: Query, notes: list[str] | None = None) -> list[str]:
    """Why this user still owes proof (empty = owes nothing): U (any user_verification_needed row), H2 (an unverified
    row whose IDP review_* rule fired), H1 (an account hold), or an open ask (an ask went out and a request is still
    pending). The steward's CLASS_SQL (captain 12:55Z), read at send."""
    out: list[str] = []
    rows = query("SELECT status, CAST(regexp_like(coalesce(json_format(CAST(verificationdata AS json)), ''), "
                 f"'{REVIEW_FIRED}') AS varchar) FROM postgresql_core.public.credit_requests "
                 f"WHERE userid = {int(uid)} AND deletedat IS NULL AND status IN ('user_verification_needed', 'unverified')")
    pending = False
    for row in rows:
        if len(row) != 2:
            raise Unknown("unexpected replica row shape")
        pending = True
        if row[0] == "user_verification_needed":
            out.append("owes:uvn")
        elif row[1] == "true":
            out.append("owes:review_hold")
    if account_hold_facts(uid):
        out.append("owes:account_hold")
    try:
        asked = _ro(LEDGER).execute(
            f"SELECT 1 FROM verify_messages WHERE account_id=? AND status IN ('sent','attempted') "
            f"AND campaign IN ({','.join('?' * len(ASKS))}) LIMIT 1", (str(uid), *ASKS)).fetchone()
    except sqlite3.Error as exc:
        raise Unknown(f"verify ledger unreadable: {exc}") from exc
    if asked and pending:
        out.append("owes:open_ask")
    out += dv_unverifiable(uid, query)
    out += proof_required_owed(uid, query)
    # r5 / p1 (b): only the UVN reason can be lifted, and only with no open ask and no document on file
    if out == ["owes:uvn"] * len(out) and out and not store_facts(uid)["docs"] and approval_path_exempt(uid, query):
        out = []
        if notes is not None:
            notes.append("owes_nothing:approval_path")
    return sorted(set(out))


def proof_required_owed(uid: int, query: Query) -> list[str]:
    """v1 STOP-CLASS (10-31 03:12Z, captain hard limit): an open unverified/processing row whose validator verdict says
    proof is required (verificationData.proof_required = true) OWES proof - whatever core's status says - unless core has
    set a review-stage mark on it (metadata.reviewStage); and a row with a fresh DSP capture pending
    (metadata.freshDspCapture) is not settled either. Either way the owes-nothing lines (/k, nothing-needed bodies)
    never go: the user gets the ask class. One count row; any other shape fails closed."""
    rows = query("SELECT CAST(count_if(CAST(json_extract(verificationdata, '$.proof_required') AS boolean) "
                 "AND json_extract(metadata, '$.reviewStage') IS NULL) AS varchar), "
                 "CAST(count_if(json_extract(metadata, '$.freshDspCapture') IS NOT NULL) AS varchar) "
                 "FROM postgresql_core.public.credit_requests /* proof_required_owed */ "
                 f"WHERE userid = {int(uid)} AND deletedat IS NULL AND status IN ('unverified', 'processing')")
    if len(rows) != 1 or len(rows[0]) != 2 or not all(str(x).isdigit() for x in rows[0]):
        raise Unknown("unexpected replica row shape (proof_required)")
    out = []
    if int(rows[0][0]):
        out.append("owes:proof_required")
    if int(rows[0][1]):
        out.append("owes:fresh_capture_pending")
    return out


def dv_unverifiable(uid: int, query: Query) -> list[str]:
    """l1 [key=nm-batch2-unverifiable] / r5: a user whose filing doc-verify READ and found it does not verify the credit
    (latest outcome per request 'unverifiable' or 'not_document*') still owes a better document - by verdict, whatever
    core's status says - so the owes-nothing lines (/k, nothing-needed bodies) never go to them. A missing store = no
    reads yet; an unreadable one fails closed."""
    if not os.path.exists(DV_STORE):
        return []
    try:
        latest: dict[str, str] = {}
        for rid, outcome in _ro(DV_STORE).execute(
                "SELECT lower(request_id), coalesce(outcome, '') FROM dv_outcomes WHERE user_id = ? ORDER BY at, id", (int(uid),)):
            latest[str(rid)] = str(outcome)
    except sqlite3.Error as exc:
        raise Unknown(f"doc-verify store unreadable: {exc}") from exc
    bad = sorted(r for r, o in latest.items() if re.fullmatch(r"[a-z0-9-]{1,64}", r)
                 and (o == "unverifiable" or o.startswith("not_document")))
    if not bad:
        return []
    rows = query("SELECT lower(CAST(id AS varchar)) FROM postgresql_core.public.credit_requests "
                 f"WHERE userid = {int(uid)} AND deletedat IS NULL "
                 "AND status IN ('user_verification_needed', 'unverified', 'processing') "
                 "AND lower(CAST(id AS varchar)) IN (" + ",".join(f"'{r}'" for r in bad) + ")")
    if any(len(r) != 1 for r in rows):
        raise Unknown("unexpected replica row shape")
    return ["owes:dv_unverifiable"] if rows else []


REPLY_DUE_AFTER_S = 24 * 3600
# Fable [key=reply-due-classes] (r5 249, p1 250): the coded answer classes; comm_state picks EXACTLY one per answer
REPLY_DUE_CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review", "reply-ref")
REPLY_REF = "reply-ref"   # [key=product-dispute-refs]: r5's approved reply set - only where the picker hands the part off
STATUS_PART_DAYS = 30                           # a customer part older than this is never auto-answered (handoff)
# b1 / QA #1517 (19:05Z, 6th veto round): the classifier is an ALLOWLIST, not a synonym chase. A part is a STATUS
# question only when it asks one of these explicit status questions (where is / any update / status of / has it been
# approved ...) AND hits no veto below; everything else - a bare title, a reply to our note, 'thanks', a how-to - is
# handed to a person. A wrong 'status' is a canned line to a real question; a wrong handoff costs a human minute.
_SUBJ = r"(my|the|our|this|that|these) (credit |song |track )?(requests?|credits?|claims?|documents?|proof|merge|tracks?|songs?)"
STATUS_QUESTION_RE = re.compile(
    r"\b(any (update|news|progress)|an update|updates? on (my|the|it)|status (of|on)|what'?s the status|"
    r"where (is|are) (it|they|" + _SUBJ + r")|(heard|hear) back|still waiting|been waiting|"
    r"still (nothing|no news|pending|under review|in review)|nothing yet|"
    # interrogative: has it been approved / is my request approved yet / will my credit be verified
    r"(is|are|was|were|has|have|will|did) (it|they|" + _SUBJ + r")( still| now| already| yet)?( been| be| get| got)? "
    r"(approved|verified|accepted|checked|reviewed|added|confirmed|pending|done)|"
    # declarative, with a named subject (never a bare 'it'): my request is approved / my credit has been checked
    + _SUBJ + r" (is|are|has been|have been|was|were|gets?|got)( still| now| already)? "
    r"(approved|verified|accepted|checked|reviewed|added|confirmed|pending|under review|in review))\b", re.I)
# QA #1517 (22:0xZ): a status question must NAME what it is about - the credit / request / claim / merge / track (or a
# linked title, checked in trigger_class). "Any update on my concert tickets?" in a credit thread is a person's job.
STATUS_REF_RE = re.compile(r"\b(credits?|requests?|claims?|merge[sd]?|tracks?|songs?|verif\w*|approv\w*|profile)\b", re.I)
# a how-to / change request is a person's job, whatever status words it carries ("Can I edit my credit request?",
# "How do I upload my document?")
HOWTO_RE = re.compile(
    r"\b(how (do|can|should|would|could) (i|we)|how to|(can|could|may) (i|we)|is it possible|is there a way|"
    r"edit\w*|modif\w*|chang\w*|correct\w*|fix\w*|updat(e|ing) (my|the) (credit|request|profile|role|name|details))\b", re.I)
# QA #1517 / b1 270: a timing question ('when will', 'how long') is NEVER a status cue by itself (regex proximity let
# "When will my Dolby Atmos credit feature be supported?" through), and any product cue in the part vetoes it outright:
# the part goes to the handoff list for a human (handoff:product).
# r5 (QA #1517): a billing word vetoes the status class too. The SAME pattern and name as #1418's R9 billing veto
# (TOPIC_BILLING_RE): one source once both land (the second to merge keeps one definition).
TOPIC_BILLING_RE = re.compile(r"\b(refund\w*|charge[sd]?|chargeback|invoice\w*|billing|billed|payment\w*|subscription\w*|paypal|card)\b")
# QA #1517: an ACTION request (cancel / delete / withdraw / refund ...) is never answered with a canned status line,
# however it names the request - it goes to a person (handoff)
ACTION_RE = re.compile(
    r"\b(cancel\w*|delete\w*|remove\w*|withdraw\w*|take (it|them|this) (down|off)|unsubscrib\w*|refund\w*|"
    r"close my account|stop (emailing|messaging|contacting)|don'?t (want|need) (it|this|the credit)|change (the|my) role|"
    r"wrong (role|credit|person|account)|not (me|mine)|"
    # b1 (QA #1517): a correction to what they SENT ("I uploaded the wrong document; can you replace it?") is an action
    r"wrong|replac\w*|instead|mistake\w*|resend\w*|re-?upload\w*|swap\w*)\b", re.I)
PRODUCT_RE = re.compile(
    r"\b(support(s|ed|ing)?|feature|features|dolby|atmos|spatial|immersive|integrat\w*|roadmap|plans? to|"
    r"add(ing)? (a |an |the )?(new )?(field|option|role|category|feature)|available in|availability|pricing|price|"
    r"subscription|upgrade|premium|bug|crash\w*|error|log ?in|password|api|app store|android|ios|iphone)\b", re.I)
# R9: the SAME pattern as the gate's thread_on_topic (intercom-verify-request.sh). Bare 'verification' / 'under review'
# are not enough: 'Your payment is under review' and 'Account verification for billing' are billing threads (QA #1509).
# QA #1418 (b1 16:00Z): 'claim' / 'proof of' count only in a credit context, and a bare 'credit(s)' never counts in a
# billing thread ("Refund claim for a credit card charge"). QA #1418 07:06Z: 'merge' counts only beside a profile /
# account / page / duplicate ("Please merge my invoices" is billing), and a billing word vetoes the whole thread, strong
# terms included. The gate's thread_on_topic carries the same three patterns and the same rule (test-pinned).
TOPIC_STRONG_RE = re.compile(r"\b(song|track) ?credits?\b|\bcredit (request|verification|review|claim)s?\b|split ?sheets?|\bmerg(e|es|ed|ing)( (my|the|these|those|our|two|both|duplicate|muso|artist))* (profiles?|accounts?|pages?|duplicates?)\b|\b(profiles?|accounts?|pages?) (merged|merging|merge)\b|\bduplicate (profiles?|accounts?|artist pages?)\b|\b(profile|artist|page) claims?\b|\bclaim(s|ed|ing)? (my |the |this |a |an |our )?(muso )?(profile|artist|page)s?\b|\bproof of (my |the |our |this )?(credits?|role|work|contribution|authorship|ownership)\b")
TOPIC_WEAK_RE = re.compile(r"\bcredits?\b")
TOPIC_BILLING_RE = re.compile(r"\b(refund\w*|charge[sd]?|chargeback|invoice\w*|billing|billed|payment\w*|subscription\w*|paypal|card)\b")


def ticket_type_name(conv: dict[str, Any]) -> str:
    """The thread's ticket type name, whatever shape Intercom gives it: an object with a name, a bare string, or
    nothing (a string ticket_type crashed R9 with AttributeError -> COMM STATE CHECK FAILED, unledgered; h2 10-30)."""
    t = conv.get("ticket")
    tt = t.get("ticket_type") if isinstance(t, dict) else None
    if isinstance(tt, dict):
        return str(tt.get("name") or "")
    return tt if isinstance(tt, str) else ""


def on_topic(conv: dict[str, Any]) -> bool:
    """R9 (thread kind): the thread is about credits / claims / merges - ticket type, title, subject, opening message
    or one of its last 3 human parts ('credit card' / 'credit note' are billing words)."""
    src = conv.get("source") or {}
    parts = [p for p in ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
             if (p.get("author") or {}).get("type") in ("user", "lead", "contact", "admin")
             and (p.get("part_type") or "comment") != "note" and (p.get("body") or "")]
    text = " \n ".join(str(x) for x in [ticket_type_name(conv),
                                         conv.get("title") or "", src.get("subject") or "", src.get("body") or ""]
                        + [p["body"] for p in parts[-3:]])
    t = re.sub(r"credit[ -]?cards?|credit notes?|store credit", " ", text.lower())
    # QA #1418 (07:06Z): a billing word vetoes the whole thread, strong terms included ("Please merge my invoices")
    return bool(not TOPIC_BILLING_RE.search(t) and (TOPIC_STRONG_RE.search(t) or TOPIC_WEAK_RE.search(t)))


# QA #1594 (b1 521): the CLOSED shape of an /o "I already emailed it" reply - the whole message must match; one extra
# clause (a question, a negation, a new request) falls out of it and the reply stays due (an answer is owed).
_SAID_EMAILED_RE = re.compile(
    r"(?:(?:yes|yep|yeah|ok|okay|done|hi|hello|hey)[\s,.!]*)*"
    r"(?:i|we)?\s*(?:have|'ve|ve)?\s*(?:already|just)?\s*(?:sent|emailed|e-mailed|mailed|forwarded)"
    r"(?:\s+(?:it|them|this|that|everything|the\s+(?:document|documents|docs|file|files|proof|pdf|screenshot|screenshots"
    r"|split\s+sheet|contract|invoice|email)))?"
    r"(?:\s+(?:over|across))?(?:\s+to\s+(?:you|you\s+guys|support|muso|muso\s+support|support@muso\.ai))?"
    r"(?:\s+(?:already|earlier|today|yesterday|this\s+morning|last\s+week|a\s+while\s+ago|before))?"
    r"[\s,.!]*(?:(?:thanks|thank\s+you|thx|cheers|regards)[\s,.!]*)?",
    re.I)


def said_emailed(custs: list[dict[str, Any]]) -> bool:
    """The customer's reply after our /o ask says the document was already sent: there is affirmative TEXT, and EVERY
    text part is the closed affirmative shape (whole message; it has no room for a question or a negation). An attachment
    never makes it said_emailed on its own (r5 + p1 10-31 23:3xZ): an attachment with a question, or with no text, stays
    reply_due - the attachment is read as a filing on its own path."""
    texts = [re.sub(r"<[^>]+>", " ", html.unescape(p.get("body") or "")).strip() for p in custs]
    if not any(texts):
        return False
    return all(_SAID_EMAILED_RE.fullmatch(t) for t in texts if t)   # the closed shape admits no "?" and no negation


def _is_o_thread(source_id: str) -> bool:
    """The conversation was started by our /o ask: its source id is the message id ledgered for a sent uvn-status note
    carrying the /o approval suffix. Unreadable ledger = Unknown (fail closed)."""
    if not source_id.isdigit() or not os.path.exists(LEDGER):
        return False
    try:
        return _ro(LEDGER).execute("SELECT 1 FROM verify_messages WHERE message_id=? AND status='sent' "
                                   "AND approval_ref LIKE '%gmail-fallback fable-copy-1030-r5/o%' LIMIT 1",
                                   (source_id,)).fetchone() is not None
    except sqlite3.Error as exc:
        raise Unknown(f"ledger unreadable: {exc}") from exc


def reply_due(conversation: str, contact_id: str, part_id: str, ic: Intercom, now: float | None = None) -> list[str]:
    """Fable [key=reply-due] (l1 219, p1 200): the user wrote to us in a credit/claim/merge thread and nobody answered
    for > 24 h. Empty list = due (the gate may send EXACTLY ONE in-thread answer despite the 7-day cooldowns);
    otherwise the reasons it is not. Fail closed on anything unreadable."""
    if not (conversation.isdigit() and part_id.isdigit() and contact_id):
        return ["reply_due:bad_input"]
    now = now or time.time()
    conv = ic("GET", f"/conversations/{conversation}?display_as=plaintext", None)
    if str(conv.get("id") or "") != conversation:
        raise Unknown("conversation unreadable")
    why: list[str] = []
    if [str(x.get("id")) for x in (conv.get("contacts") or {}).get("contacts") or []] != [contact_id]:
        why.append("reply_due:not_this_users_thread")
    if not on_topic(conv):
        why.append("reply_due:R9_thread_not_about_credits")
    if str(conv.get("state") or "").lower() != "open":
        why.append("reply_due:thread_not_open")               # p1 246 + QA #1517: ONLY an explicitly open thread
    parts = [conv.get("source") or {}] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
    idx = next((i for i, p in enumerate(parts) if str(p.get("id") or "") == part_id), None)
    if idx is None:
        return why + ["reply_due:part_not_in_thread"]
    trig = parts[idx]
    if (trig.get("author") or {}).get("type") not in ("user", "lead", "contact"):
        why.append("reply_due:not_a_customer_part")
    if any((p.get("author") or {}).get("type") in SUPPORT_AUTHORS and (p.get("part_type") or "comment") != "note"
           and ((p.get("body") or "").strip() or p.get("attachments")) for p in parts[idx + 1:]):
        why.append("reply_due:already_answered")
    # the 24 h run from the customer's LATEST message (QA #1509): part A 30 h ago + part B 1 h ago is not due yet
    custs = [p for p in parts[idx:] if (p.get("author") or {}).get("type") in ("user", "lead", "contact")]
    if _is_o_thread(str((conv.get("source") or {}).get("id") or "")) and said_emailed(custs):
        # [key=gmail-o-forward] (r5; QA #1594): in the thread our /o ask started, ONLY an affirmative "I sent/emailed/
        # forwarded it" (or an attachment) is the coded outcome said_emailed - the match waits on the Gmail read
        # (waiting_on third_party:gmail). A question, a "haven't", "how do I send it" or anything else stays reply_due.
        why.append("reply_due:gmail_o_reply (said_emailed; waiting_on third_party:gmail)")
    if max(((p.get("created_at") or now) for p in custs), default=now) > now - REPLY_DUE_AFTER_S:
        why.append("reply_due:not_24h_yet")
    return why


# Fable [key=lamberto-reply-due] (r5 co-sign 235): the thread facts a reply_due answer depends on.
GATE_BOT_ADMINS = frozenset({"5763097"})       # Caroline = the gate's own admin (also the ops-bot reassign target); not humans
NOTHING_NEEDED_RE = re.compile(r"nothing is needed from you right now", re.I)   # the approved status-note line
NOTHING_NEEDED_CAMPAIGNS = ("status-team-review", "credit-hold-status", "claim-proof-pending")
HUMAN_ACTIVE_S = 48 * 3600                     # a named human who wrote in the thread within 48 h keeps it
HANDOFF_EVERY_S = 7 * 86400                    # one reassignment per thread per 7 days


def reply_due_thread(conversation: str, ic: Intercom, now: float | None = None, part: str = "") -> dict[str, Any]:
    """prior_note: our earlier 'Nothing is needed from you right now' line in THIS conversation (read from the thread -
    a comment by a gate admin id - or a ledgered note of a nothing-needed campaign into it; the ledger alone is not
    enough while the #1510 backfill is pending), as {part, campaign, at}. assignee: a named HUMAN admin assigned to the
    thread, as {id, last_part_at, action}: 'skip' while that human has their OWN part (comment or note) within 48 h or the
    thread was already handed over in the last 7 days, else 'reassign'. Tag / assignment events are not the human
    writing (r5 g). Unreadable = Unknown (fail closed)."""
    now = now or time.time()
    conv = ic("GET", f"/conversations/{conversation}?display_as=plaintext", None)
    if str(conv.get("id") or "") != conversation:
        raise Unknown("conversation unreadable")
    src = dict(conv.get("source") or {})
    src.setdefault("created_at", conv.get("created_at"))
    parts = [src] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
    out: dict[str, Any] = {"prior_note": None, "assignee": None}
    # QA #1517: Intercom returns at most 500 parts; with a truncated history an earlier nothing-needed line may be out
    # of view, so the prior note is UNKNOWN - fail closed (the locked correction is never bypassed)
    cp = conv.get("conversation_parts") or {}
    total = int(cp.get("total_count") or 0)
    if total > len(cp.get("conversation_parts") or []) or len(cp.get("conversation_parts") or []) >= 500:
        raise Unknown("conversation history is truncated (> 500 parts); the earlier notes cannot all be read")
    ours = [p for p in parts if (p.get("author") or {}).get("type") in ("admin", "bot")
            and str((p.get("author") or {}).get("id") or "") in GATE_BOT_ADMINS
            and (p.get("part_type") or "comment") != "note" and NOTHING_NEEDED_RE.search(p.get("body") or "")]
    ledgered: dict[str, str] = {}
    try:
        if os.path.exists(LEDGER):
            for mid, camp in _ro(LEDGER).execute(
                    "SELECT coalesce(message_id, ''), campaign FROM verify_messages WHERE conversation_id=? AND status='sent' "
                    f"AND campaign IN ({','.join('?' * len(NOTHING_NEEDED_CAMPAIGNS))})",
                    (conversation, *NOTHING_NEEDED_CAMPAIGNS)):
                ledgered[str(mid)] = camp
    except sqlite3.Error as exc:
        raise Unknown(f"ledger unreadable: {exc}") from exc
    if ours:
        last = max(ours, key=lambda p: p.get("created_at") or 0)
        out["prior_note"] = {"part": str(last.get("id") or ""), "at": int(last.get("created_at") or 0),
                             "campaign": ledgered.get(str(last.get("id") or ""), "unledgered (#1510 backfill class)")}
    # a ledger row alone is not evidence (QA #1517): the note must be IN this thread; the ledger only labels its campaign
    aid = str(conv.get("admin_assignee_id") or "")
    if aid not in ("", "0", "None") and aid not in GATE_BOT_ADMINS:
        out["assignee"] = assignee_state(conversation, aid, parts, ic, now, part=part)
    return out


def assignee_state(conversation: str, aid: str, parts: list[dict[str, Any]], ic: Intercom, now: float,
                   part: str = "") -> dict[str, Any]:
    """Fable 238/240 + r5: a thread assigned to a HUMAN (any admin outside GATE_BOT_ADMINS). action =
    'skip'      the human has an OWN part (comment or note) within 48 h, or replied after our handoff note (any human
                comment after it counts; we do not second-guess their wording), or we already reassigned it in 7 d;
    'handoff'   no handoff note yet: the gate writes one (tag credit-answer-ready + internal note with the exact answer);
    'wait'      the handoff note is under 48 h old (measured from the note's created_at);
    'reassign+answer'  the note is >= 48 h old and no human replied: reassign to the gate admin (+ note), then answer."""
    def human(p: dict[str, Any]) -> bool:
        a = p.get("author") or {}
        return a.get("type") == "admin" and str(a.get("id") or "") not in GATE_BOT_ADMINS
    own = [int(p.get("created_at") or 0) for p in parts if human(p) and str((p.get("author") or {}).get("id") or "") == aid
           and (p.get("part_type") or "comment") in ("comment", "note") and ((p.get("body") or "").strip() or p.get("attachments"))]
    last_own = max(own, default=0)
    try:
        db = _ro(LEDGER) if os.path.exists(LEDGER) else None
        # QA #1517: only a handoff to the CURRENT assignee counts (A handed, thread moved to B: B gets their own note),
        # and only the handoff of THIS customer part (part A handed 50 h ago never stands in for a new part B)
        ho = db.execute("SELECT message_id, created_at FROM verify_messages WHERE campaign='handoff' AND status='handoff' "
                        "AND conversation_id=? AND approval_ref LIKE ? ORDER BY id DESC LIMIT 1",
                        (conversation, f"handoff from:{aid} to:{aid} reply_due:{part} %")).fetchone() if db and part else None
        since7 = datetime.fromtimestamp(now - HANDOFF_EVERY_S, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        moved = bool(db and db.execute("SELECT 1 FROM verify_messages WHERE campaign='reassign' AND status='reassign' "
                                       "AND conversation_id=? AND created_at >= ? LIMIT 1", (conversation, since7)).fetchone())
    except sqlite3.Error as exc:
        raise Unknown(f"ledger unreadable: {exc}") from exc
    st: dict[str, Any] = {"id": aid, "name": "", "last_part_at": last_own, "handoff_part": "", "handoff_at": 0,
                          "human_replied_after": False}
    try:
        st["name"] = str((ic("GET", f"/admins/{aid}", None) or {}).get("name") or "")[:80]   # display only
    except Exception:  # noqa: BLE001 - the name is a report column, never a decision
        pass
    if ho:
        st["handoff_part"] = str(ho[0] or "")
        st["handoff_at"] = int(datetime.fromisoformat(str(ho[1]).replace("Z", "+00:00")).timestamp())
        st["human_replied_after"] = any(human(p) and (p.get("part_type") or "comment") == "comment"
                                        and (p.get("created_at") or 0) > st["handoff_at"]
                                        and ((p.get("body") or "").strip() or p.get("attachments")) for p in parts)
    if moved or st["human_replied_after"] or last_own >= now - HUMAN_ACTIVE_S:
        st["action"] = "skip"
    elif not ho:
        st["action"] = "handoff"
    elif st["handoff_at"] > now - HUMAN_ACTIVE_S:
        st["action"] = "wait"
    else:
        st["action"] = "reassign+answer"
    return st


def filed_requests(uid: int, keys: list[str] | tuple[str, ...], conversation: str, query: Query) -> list[str]:
    """b1 270: the FILED-REQUEST evidence a status answer needs - the named requests that exist for this user, are
    still open on the replica (not approved / rejected / deleted), and are linked to THIS conversation: one of our
    sent notes in it named the request (ledger), or a filing in it was taken against the request (proof_intake)."""
    want = sorted({str(k).lower() for k in keys if re.fullmatch(r"[a-z0-9-]{1,64}", str(k).lower())})   # no quotes: SQL-safe
    if not want or not str(conversation).isdigit():
        return []
    lst = ",".join(f"'{k}'" for k in want)
    rows = query("SELECT lower(CAST(id AS varchar)) FROM postgresql_core.public.credit_requests "
                 f"WHERE userid = {int(uid)} AND deletedat IS NULL AND status NOT IN ('approved', 'rejected') "
                 f"AND lower(CAST(id AS varchar)) IN ({lst})")
    open_ids = {str(r[0]).lower() for r in rows if r}
    linked: set[str] = set()
    try:
        for (rj,) in _ro(LEDGER).execute("SELECT request_ids_json FROM verify_messages WHERE conversation_id=? "
                                         "AND status='sent'", (str(conversation),)):
            try:
                linked |= {str(x).lower() for x in json.loads(rj or "[]")}
            except ValueError:
                continue
    except sqlite3.Error as exc:
        raise Unknown(f"ledger unreadable: {exc}") from exc
    try:
        db = _ro(PROOF_STORE)
        cols = {r[1] for r in db.execute("PRAGMA table_info(proof_intake)")}
        if "candidate_request_ids_json" in cols:
            for (cj,) in db.execute("SELECT coalesce(candidate_request_ids_json, '[]') FROM proof_intake "
                                    "WHERE user_id=? AND conversation_id=?", (int(uid), str(conversation))):
                try:
                    linked |= {str(x).lower() for x in json.loads(cj or "[]")}
                except ValueError:
                    continue
    except sqlite3.Error as exc:
        raise Unknown(f"proof_intake unreadable: {exc}") from exc
    return sorted(open_ids & linked)


def status_trigger(uid: int, keys: list[str] | tuple[str, ...], conversation: str, part_id: str, query: Query,
                   ic: Intercom, conv: dict[str, Any] | None = None) -> dict[str, Any]:
    """The ONE classification both the dry run and the send use (QA #1517): the part, the user's open titles and the
    filed-request evidence for this thread."""
    if conv is None:
        conv = ic("GET", f"/conversations/{conversation}?display_as=plaintext", None)
    filed = filed_requests(uid, keys, conversation, query)
    # b1 (QA 11:36): a title counts only for a request LINKED to this conversation - naming the track of another open
    # request (filed in another thread) is not a status part about THIS thread's request
    linked = open_titles(uid, query, only=filed)
    # QA #1517: a part that names ANOTHER open request (one not linked to this thread) is about that request - never a
    # canned answer for this thread's request
    others = [t for t in open_titles(uid, query) if t not in set(linked)]
    return trigger_class(conv, part_id, titles=linked, filed=filed, other_titles=others)


def trigger_class(conv: dict[str, Any], part_id: str, titles: list[str] | tuple[str, ...] = (),
                  now: float | None = None, filed: list[str] | tuple[str, ...] = (),
                  other_titles: list[str] | tuple[str, ...] = ()) -> dict[str, Any]:
    """[key=reply-due-classes] (b): is the customer's part a STATUS question about their own request/claim/merge?
    status = the customer's latest part, under STATUS_PART_DAYS old, no veto (billing / action / product / how-to,
    another open request named), a request linked to this thread, AND an allowlisted status question
    (STATUS_QUESTION_RE; b1 19:05Z). Everything else is non_status -> the handoff list for a person, never a coded
    line. `titles` stays for the report only. -> {class, why, part_age_d}."""
    now = now or time.time()
    src = dict(conv.get("source") or {})
    src.setdefault("created_at", conv.get("created_at"))
    src.setdefault("id", "")
    parts = [src] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
    idx = next((i for i, p in enumerate(parts) if str(p.get("id") or "") == str(part_id)), None)
    if idx is None:
        return {"class": "non_status", "why": "part not in thread", "part_age_d": None}
    p = parts[idx]
    # QA #1517: only the customer's LATEST part is answered - a later part (a product question after a status one)
    # is what they are waiting on
    if any((q.get("author") or {}).get("type") in ("user", "lead", "contact") and q.get("part_type") != "note"
           and ((q.get("body") or "").strip() or q.get("attachments")) for q in parts[idx + 1:]):
        return {"class": "non_status", "why": "not the customer's latest part", "part_age_d": None}
    age = round((now - float(p.get("created_at") or 0)) / 86400, 1) if p.get("created_at") else None
    if age is None or age > STATUS_PART_DAYS:
        return {"class": "non_status", "why": f"stale part (> {STATUS_PART_DAYS} d, or undated)", "part_age_d": age}
    body = re.sub(r"\s+", " ", str(p.get("body") or "")).lower()
    # b1 270: a product cue anywhere in the part vetoes a coded answer; no filed request in this thread = no status
    bm = TOPIC_BILLING_RE.search(body)
    if bm:
        return {"class": "non_status", "why": f"billing cue '{bm.group(0)}' (handoff)", "part_age_d": age}
    am = ACTION_RE.search(body)
    if am:
        return {"class": "non_status", "why": f"action request '{am.group(0)}' (handoff)", "part_age_d": age}
    pm = PRODUCT_RE.search(body)
    if pm:
        return {"class": "non_status", "why": f"product cue '{pm.group(0)}'", "part_age_d": age}
    hm = HOWTO_RE.search(body)
    if hm:
        return {"class": "non_status", "why": f"how-to / change request '{hm.group(0)}' (handoff)", "part_age_d": age}
    if not filed:
        return {"class": "non_status", "why": "no open request of theirs is linked to this thread", "part_age_d": age}
    for t in other_titles:
        tt = re.sub(r"\s+", " ", str(t or "")).strip().lower()
        if (len(tt.split()) >= 2 or len(tt) >= 6) and re.search(r"(?<!\w)" + re.escape(tt) + r"(?!\w)", body):
            return {"class": "non_status", "why": f"names another open request '{t}' (not linked to this thread)",
                    "part_age_d": age}
    # QA #1517 (01:30Z): the status phrase and what it names must be in the SAME sentence - "Any update on my concert
    # tickets? I also have a credit request." asks about tickets, not the credit (handoff)
    def names_it(sentence: str) -> bool:
        if STATUS_REF_RE.search(sentence):
            return True
        return any((tt := re.sub(r"\s+", " ", str(t or "")).strip().lower()) and (len(tt.split()) >= 2 or len(tt) >= 6)
                   and re.search(r"(?<!\w)" + re.escape(tt) + r"(?!\w)", sentence) for t in titles)
    sentences = [x for x in re.split(r"(?<=[.!?])\s+|\n+", body) if x.strip()]
    m = None
    for sent in sentences:
        sm = STATUS_QUESTION_RE.search(sent)
        if sm and names_it(sent):
            return {"class": "status", "why": f"status question '{sm.group(0)}'", "part_age_d": age}
        m = m or sm
    if m:
        return {"class": "non_status", "why": f"status words '{m.group(0)}' without naming the credit in that sentence (handoff)",
                "part_age_d": age}
    return {"class": "non_status", "why": "not an allowlisted status question (handoff)", "part_age_d": age}


def open_titles(uid: int, query: Query, only: list[str] | tuple[str, ...] | None = None) -> list[str]:
    """The track titles on this user's open (pending) credit requests - a part naming one is about their own request.
    `only`: just these request ids (the requests linked to the thread); an empty list = no titles."""
    if only is not None:
        ids = sorted({str(k).lower() for k in only if re.fullmatch(r"[a-z0-9-]{1,64}", str(k).lower())})
        if not ids:
            return []
        scope = " AND lower(CAST(id AS varchar)) IN (" + ",".join(f"'{k}'" for k in ids) + ")"
    else:
        scope = ""
    rows = query("SELECT coalesce(spotifytracktitle, '') FROM postgresql_core.public.credit_requests "
                 f"WHERE userid = {int(uid)} AND deletedat IS NULL AND status IN ('user_verification_needed', 'unverified')"
                 + scope)
    return sorted({str(r[0]).strip() for r in rows if r and str(r[0]).strip()})


def answer_class(st: dict[str, Any], core: dict[str, Any], docs: list[str], owes: list[str]) -> tuple[str, str]:
    """[key=reply-due-classes] (a): the ONE coded answer, in p1's order -> (campaign, why); campaign '' = no coded
    answer (the handoff list). decision told > per-need ask (L11c: chosen by its own builder, never here) > uvn-status
    ask if NO document > status-doc-received if a document is on file, undecided, and NO receipt was ever sent (r5 A:
    never a second receipt) > status-team-review (a receipted document, or no document and no owed proof). The
    'nothing is needed' family never goes to an owes-proof user."""
    if core["told"] or st["told_notes"] or core["decided"]:
        return "", "decided_or_told (the decision line is not a reply_due class yet)"
    if not docs:
        # QA #1517: only a user who OWES proof is asked for it; no document and nothing owed (under review) -> status
        return ("uvn-status", "no document on file, proof owed") if owes else \
            ("status-team-review", "no document on file and no proof owed")
    if not st["acked"]:
        return "status-doc-received", "a document on file, undecided, never receipted"
    if owes:
        return "", "owes proof after a receipt (" + ",".join(owes[:3]) + "): no 'nothing is needed' line"
    return "status-team-review", "the document was already receipted"


def check(campaign: str, copy: str, uid: int, keys: list[str], contact_id: str, *, conversation: str = "",
          doc_sha: str = "", doc_at: str = "", need_code: str = "", filing_conversation: str = "",
          doc_map: dict[str, str] | None = None, doc_intakes: dict[str, str] | None = None,
          query: Query = trino, ic: Intercom = intercom,
          fraud: Callable[[int, Query], list[str]] | None = None, reply_due_part: str = "",
          nothing_needed_body: bool = False, correction: bool = False) -> dict[str, Any]:
    # QA #1517 (critical): a reply_due answer ALWAYS takes the full path below (trigger, class, thread, assignee); the
    # 'nothing is needed' fast path is for unsolicited notes only. answer_class keeps that family from owes-proof users.
    if nothing_else(campaign, copy) and not reply_due_part:
        notes: list[str] = []
        why = owes_proof(uid, query, notes)
        return {"hold": bool(why), "state": "owes_proof" if why else "owes_nothing", "reasons": why or notes}
    if nothing_needed_body:
        # p1 / r5 (rule gap, 10-30 18:4xZ): the gate found a "nothing (else) is needed" line in the RENDERED body of a
        # campaign outside the family above - the owes-nothing rule (captain 12:55Z) applies by body, not by name:
        # every other check runs AND a user who owes proof is held
        res = check(campaign, copy, uid, keys, contact_id, conversation=conversation, query=query, ic=ic, fraud=fraud,
                    reply_due_part=reply_due_part)
        owe = owes_proof(uid, query)
        return {**res, "hold": bool(res["hold"] or owe), "reasons": list(res["reasons"]) + [f"nothing_needed_body:{w}" for w in owe]}
    core = core_facts(uid, keys, query)
    st = store_facts(uid, keys, core["created"])
    need = None
    if campaign in WAIT_LINES:
        ic_found = intercom_facts(contact_id, max(st["last_ask"], core["last_ask"]), ic, core["created"])
        # (documents_on_file() is the same pair of reads, for the render-time caller)
    elif campaign == NEED_ASK:
        if not need_code:
            raise Unknown("proof-need-ask needs the need code the message is about")
        need = need_facts(uid, keys, doc_sha, doc_at, need_code, doc_map, doc_intakes)
        # the filing event itself is the document's own part at its arrival second; ANY customer part after that second
        # (a correction or another file 1 s later) holds the ask (QA #1418: no slack window)
        since = datetime.fromisoformat(_ts(doc_at)).replace(tzinfo=timezone.utc).timestamp()
        # the filing-part evidence comes from the FILING conversation even when the note goes by email (R9 / a closed
        # thread): r5 / QA #1418 - otherwise the document's own part reads as newer and the email path never sends
        fc = filing_conversation or conversation
        ic_found = intercom_facts(contact_id, _ts(datetime.fromtimestamp(since, timezone.utc).isoformat()), ic,
                                  attach_since=since, filing=(fc, since) if fc.isdigit() else None,
                                  text_after_ask=True)
    else:
        ic_found = []
    last_part: dict[str, Any] = {}
    thread = thread_facts(conversation, ic, extra=last_part)
    fr = (fraud or fraud_facts)(uid, query)
    if campaign in ASKS or campaign in VOLUME_PASS_CAMPAIGNS:
        # [key=r8-hold-due]: a volume-only hold holds approvals and keeps the 'nothing is needed' family off - never the
        # ask that resolves it; a hard hold (or an unknown kind) still holds the ask
        fr = [f for f in fr if f != HOLD_VOLUME]
    docs_all = st["docs"] + ic_found
    # QA #1660 b: `proof-on-file` (the render read) and this return are ONE fact - see documents_on_file(). They are the
    # same function because they disagreed once: the render read counted only our stores while this counted the
    # customer's Intercom attachments too, so every recipient whose only evidence arrived in Intercom refused the send
    # with a 'could not read' reason. Intercom-only evidence counts (it is a document they sent us) and is reported by
    # name so a human can see nothing is filed in intake yet.
    proof_on_file = bool(docs_all)
    proof_note = (["intercom_only_proof"] if campaign == MERGE_CLAIM_FIRST and ic_found and not st["docs"] else [])
    state, why = decide(campaign, copy, st, core, ic_found, thread, fr, need, last_part.get("last_part"))
    if reply_due_part:
        # [key=reply-due]: answering a user who wrote to us is not an unsolicited note - the 7-day cooldowns do not
        # apply to EXACTLY this one answer; every other rule (decided/told, documents, fraud, thread, identity) does
        due = (["reply_due:campaign_not_allowed"] if campaign not in REPLY_DUE_CAMPAIGNS
               else reply_due(conversation, contact_id, reply_due_part, ic))
        why = [w for w in why if not w.startswith("messaged_7d")] if not due else why + due
        if not due:
            # (b) only a STATUS part is auto-answered; (a) the campaign must be the ONE class comm_state picks
            tc = status_trigger(uid, keys, conversation, reply_due_part, query, ic)
            docs = st["docs"] + intercom_facts(contact_id, max(st["last_ask"], core["last_ask"]), ic, core["created"])
            klass, kwhy = answer_class(st, core, docs, owes_proof(uid, query))
            # the class decides the answer, so the per-campaign document holds of the asked campaign do not apply
            why = [w for w in why if not w.startswith(("proof_on_file", "already_acknowledged"))]
            if campaign == REPLY_REF:
                # an approved ref answers ONLY a part the picker hands off - a status part gets its coded class instead
                if tc["class"] == "status":
                    why.append(f"reply_due:coded_class_applies:{klass or 'none'}")
                # QA #1601: a handoff is only the customer's LATEST, FRESH part - a superseded, stale, undated or
                # missing part is never answered by a ref (the same holds the coded classes keep)
                tw = str(tc.get("why") or "")
                if tw.startswith(("not the customer's latest part", "stale part", "part not in thread")):
                    why.append("reply_ref:part_not_answerable: " + tw)
                why += reply_ref_facts(copy, uid, keys, query)
            elif tc["class"] != "status":
                why.append("reply_due:non_status_part (handoff:product): " + tc["why"])
            elif not klass:
                why.append("reply_due:no_coded_class: " + kwhy)
            elif klass != campaign:
                why.append(f"reply_due:class_is:{klass}")
            facts = reply_due_thread(conversation, ic, part=reply_due_part)
            facts.update({"trigger_class": tc, "answer_class": {"campaign": klass, "why": kwhy}})
            a = facts["assignee"]
            if a and a["action"] == "skip":
                why.append(f"reply_due:human_assignee:{a['id']}")           # listed for that human, never posted
            return {"hold": bool(why), "state": state, "reasons": why, "reply_due": facts,
                    "proof_on_file": proof_on_file, "proof_note": proof_note}
    if correction and campaign == "uvn-status":
        # [key=k-proof-required] /c2: this ask corrects OUR recent status line about the same requests - our own 7-day
        # cooldown (that line) does not defer the correction; every other rule still holds
        why = [w for w in why if not w.startswith("messaged_7d")]
    return {"hold": bool(why), "state": state, "reasons": why, "proof_on_file": proof_on_file,
            "proof_note": proof_note}


def reply_ref_facts(copy: str, uid: int, keys: list[str], query: Query) -> list[str]:
    """r5's send-time facts for the approved reply set, read live (unreadable = Unknown, fail closed): /q only when the
    user has NO open credit request; /y only when the named request is DECIDED (approved / rejected)."""
    if copy == "refq":
        n = query(f"SELECT count(*) FROM postgresql_core.public.credit_requests WHERE userid = {int(uid)} "
                  "AND deletedat IS NULL AND status NOT IN ('approved', 'rejected')")
        if not n or int(n[0][0]) != 0:
            return ["reply_ref:q_open_request_exists"]
    if copy == "refy":
        rid = (keys or [""])[0].lower()
        if not re.fullmatch(r"[0-9a-f-]{36}", rid):
            return ["reply_ref:y_needs_the_request_id"]
        st = query(f"SELECT status FROM postgresql_core.public.credit_requests WHERE lower(CAST(id AS varchar)) = '{rid}' "
                   f"AND userid = {int(uid)} AND deletedat IS NULL")
        if not st or str(st[0][0]) not in ("approved", "rejected"):
            return ["reply_ref:y_request_not_decided"]
    return []


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="send-time communication state (read-only)")
    sub = ap.add_subparsers(dest="op", required=True)
    pf = sub.add_parser("proof-on-file",
                        help="the documents-on-file fact alone - the SAME fact check() decides on (our stores + the "
                             "files the customer sent us in Intercom; QA #1660 b), so the two reads cannot disagree: the "
                             "merge-claim-first render fact - exit 2 when it cannot be read")
    pf.add_argument("--user-id", required=True)
    pf.add_argument("--request-ids", default="")
    pf.add_argument("--contact-id", default="",
                    help="the customer's Intercom contact; default: the contact our newest ledger note went to "
                         "(empty = unknown = unreadable, exit 2)")
    c = sub.add_parser("check")
    c.add_argument("--campaign", required=True)
    c.add_argument("--copy", default="")
    c.add_argument("--user-id", required=True)
    c.add_argument("--request-ids", default="")
    c.add_argument("--contact-id", default="")
    c.add_argument("--conversation", default="", help="the conversation the note would go into (R1: the filing one)")
    c.add_argument("--reply-due", default="", help="[key=reply-due]: the customer part this note answers")
    c.add_argument("--correction", action="store_true",
                   help="uvn-status /c2: this ask corrects our earlier status line (our 7-day cooldown does not apply)")
    c.add_argument("--nothing-needed-body", action="store_true",
                   help="the rendered note says nothing (else) is needed: hold anyone who still owes proof")
    c.add_argument("--doc-sha", default="", help="proof-need-ask: the checked document's sha256")
    c.add_argument("--doc-at", default="", help="proof-need-ask: when that document arrived (ISO UTC)")
    c.add_argument("--need", default="", help="proof-need-ask: the need code the message is about")
    c.add_argument("--filing-conversation", default="", help="proof-need-ask: the document's filing conversation "
                   "(its own part is not news), even when the note goes by email")
    c.add_argument("--doc-map", default="", help="proof-need-ask: request=sha,... each request's own document")
    c.add_argument("--doc-intakes", default="", help="proof-need-ask: sha=intake_id,... the intake each document was read from")
    a = ap.parse_args(argv)
    if a.op == "proof-on-file":
        if not str(a.user_id).isdigit():
            print(json.dumps({"proof_on_file": None, "reasons": ["no Muso user id"]}))
            return 2
        keys = [k for k in a.request_ids.split(",") if k]
        try:
            core = core_facts(int(a.user_id), keys, trino)
            st = store_facts(int(a.user_id), keys, core["created"])
            # the render happens BEFORE the shell resolves the recipient, so the contact comes from our own ledger
            # (the contact our newest note went to = the one the send-time check reads)
            contact = a.contact_id or st.get("last_contact") or ""
            docs = documents_on_file(int(a.user_id), core, st, contact, intercom) if contact else list(st["docs"])
        except Unknown as exc:
            print(json.dumps({"proof_on_file": None, "reasons": [f"unknown: {exc}"]}))
            return 2
        # A customer whose Intercom contact we do not know (no note of ours names one) is read from the record alone:
        # the fact is then the record, the copy renders without the acknowledgement (it asserts nothing), and the gate's
        # state check - which runs after the recipient is resolved and CAN read Intercom - may see more. The shell
        # refuses only when the body would ASSERT a fact the state check does not confirm, so this direction is safe and
        # is named here rather than swallowed (QA #1660 b).
        print(json.dumps({"proof_on_file": bool(docs), "docs": sorted(set(docs)),
                          "record_only": bool(st["docs"]), "intercom_only": bool(docs) and not st["docs"],
                          "contact_unknown": not contact}))
        return 0
    if not str(a.user_id).isdigit():
        print(json.dumps({"hold": None, "reasons": ["no Muso user id"]}))
        return 2
    try:
        res = check(a.campaign, a.copy, int(a.user_id), [k for k in a.request_ids.split(",") if k], a.contact_id,
                    conversation=a.conversation, reply_due_part=a.reply_due, doc_sha=a.doc_sha, doc_at=a.doc_at,
                    need_code=a.need, filing_conversation=a.filing_conversation,
                    doc_map=dict(x.split("=", 1) for x in a.doc_map.split(",") if "=" in x),
                    doc_intakes=dict(x.split("=", 1) for x in a.doc_intakes.split(",") if "=" in x),
                    nothing_needed_body=a.nothing_needed_body, correction=a.correction)
    except Unknown as exc:
        print(json.dumps({"hold": None, "reasons": [f"unknown: {exc}"]}))
        return 2
    print(json.dumps(res))
    return 3 if res["hold"] else 0


if __name__ == "__main__":
    sys.exit(_main())
