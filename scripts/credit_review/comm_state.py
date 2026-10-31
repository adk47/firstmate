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
Unreadable store, replica or Intercom read = UNKNOWN (exit 2): the gate sends nothing.

CLI:  comm_state.py check --campaign C --user-id N --request-ids a,b [--contact-id X]
      -> {"hold": bool, "state": "...", "reasons": [...]}   exit 0 send / 3 hold / 2 unknown
"""
from __future__ import annotations

import argparse
import csv
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
WAIT_LINES = ("credit-hold-status", "claim-proof-pending", "uvn-status", "claim-proof-ask")
RECEIPT = "status-doc-received"
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
    out: dict[str, Any] = {"docs": [], "acked": "", "notes_7d": [], "told_notes": [], "last_ask": ""}
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
                          "coalesce(request_ids_json, '[]') "
                          "FROM verify_messages WHERE account_id=?", (str(uid),)).fetchall()
    except sqlite3.Error as exc:
        raise Unknown(f"verify ledger unreadable: {exc}") from exc
    week = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d")
    want = {str(k).lower() for k in keys}
    for camp, kind, status, at, _reply, tagged, day, ids_json in rows:
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


def intercom_facts(contact_id: str, last_ask: str, ic: Intercom, since: str = "") -> list[str]:
    """An attachment the user sent us in Intercom on/after `since` (the oldest named request's creation; empty =
    any time). Fable 199: a text message is never 'replied' - a text question is an ask trigger, so `last_ask` no
    longer turns a text reply into a hold (kept in the signature for the callers)."""
    since_epoch = datetime.fromisoformat(since).replace(tzinfo=timezone.utc).timestamp() if since else None
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
        for p in parts:
            if (p.get("author") or {}).get("type") not in ("user", "lead", "contact"):
                continue
            fresh = since_epoch is None or not p.get("created_at") or p["created_at"] >= since_epoch
            # an attachment with no readable time counts (fail closed; b1 C3)
            if p.get("attachments") and fresh:
                found.append(f"intercom_attachment:{cid}")
            # a text reply is not 'replied' - but a LINK to a shared document is a document (b1 on #1508)
            elif fresh and has_doc_link(p.get("body") or ""):
                found.append(f"intercom_document_link:{cid}")
    return sorted(set(found))


def thread_facts(conversation: str, ic: Intercom, now: float | None = None) -> list[str]:
    """R5 / R6 / R7 on the conversation the note would go into (R6/R7 apply to R1 only; see decide)."""
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
        out.append("R7_thread_resolved")          # r5: a closed conversation is not a delivery target
    if admin:
        last = max(admin, key=lambda p: p.get("created_at") or 0)
        if RESOLVED.search(last.get("body") or "") and (last.get("created_at") or 0) >= max(cust or [0]):
            out.append("R7_thread_resolved")
    cparts = [p for p in parts if (p.get("author") or {}).get("type") in ("user", "lead", "contact")]
    if cparts and RESOLVED.search(max(cparts, key=lambda p: p.get("created_at") or 0).get("body") or ""):
        out.append("R7_thread_resolved")          # the customer's own last word: it is sorted
    return sorted(set(out))


def account_hold_facts(uid: int, now: float | None = None) -> list[str]:
    """R8 (r5): the fraud-lens account-hold set, read at send time; older than 72 h or unreadable = UNKNOWN."""
    now = now or time.time()
    try:
        age = now - os.path.getmtime(ACCOUNT_HOLDS)
        held = set()
        with open(ACCOUNT_HOLDS, encoding="utf-8") as fh:
            for ln in fh:
                if ln.strip():
                    held.add(str(json.loads(ln).get("user_id")))
    except (OSError, ValueError, AttributeError) as exc:
        raise Unknown(f"account holds unreadable: {exc}") from exc
    if age > ACCOUNT_HOLDS_MAX_AGE:
        raise Unknown(f"account holds are {int(age // 3600)}h old (> 72h)")
    if age < -300:      # a future mtime (> 5 min ahead): its age is unknowable (QA #1456 on G8)
        raise Unknown("account holds mtime is in the future; age unknown")
    return ["R8_account_hold"] if str(uid) in held else []


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


def decide(campaign: str, copy: str, st: dict[str, Any], core: dict[str, Any], ic_found: list[str],
           thread: list[str] | None = None, fraud: list[str] | None = None) -> tuple[str, list[str]]:
    """(state, hold reasons) - empty reasons = send."""
    docs = st["docs"] + ic_found
    decided = sorted(set(core["decided"]))
    told = sorted(set(core["told"])) + st["told_notes"]
    state = ("told" if told else "decided" if decided else "acknowledged" if st["acked"] else
             "replied" if docs else "asked" if (st["last_ask"] or core["last_ask"]) else "none")
    why: list[str] = list(fraud or [])
    thread = thread or []
    if st["notes_7d"]:
        why.append("messaged_7d:" + "+".join(sorted(set(st["notes_7d"]))))
    if "R5_admin_comment_7d" in thread:
        why.append("messaged_7d:R5_admin_comment_in_thread")
    if campaign in WAIT_LINES:
        if docs:
            why.append("proof_on_file:" + ",".join(sorted(set(docs)))[:300])
        if st["acked"]:
            why.append("already_acknowledged")
        if decided or told:
            why.append("decided_or_told")
    elif campaign == RECEIPT and copy in ("docrecvr", "docrecvn", "docrecvq", "docrecv"):
        if decided or told:
            why.append("decided_or_told:" + ",".join((decided + told)[:5]))
        why += [t for t in thread if t in ("R6_stale_thread", "R7_thread_resolved")]
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
REPLY_DUE_CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review")
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
TOPIC_RE = re.compile(r"\bcredits?\b|\bclaim(s|ed|ing)?\b|\bmerg(e|es|ed|ing)\b|split ?sheets?|\bproof of\b|"
                      r"\b(song|track) ?credits?\b")


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
    return bool(TOPIC_RE.search(re.sub(r"credit[ -]?cards?|credit notes?|store credit", " ", text.lower())))


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
          query: Query = trino, ic: Intercom = intercom, fraud: Callable[[int, Query], list[str]] | None = None,
          reply_due_part: str = "", nothing_needed_body: bool = False) -> dict[str, Any]:
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
    ic_found = (intercom_facts(contact_id, max(st["last_ask"], core["last_ask"]), ic, core["created"])
                if campaign in WAIT_LINES else [])
    thread = thread_facts(conversation, ic)
    fr = (fraud or fraud_facts)(uid, query)
    state, why = decide(campaign, copy, st, core, ic_found, thread, fr)
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
            if tc["class"] != "status":
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
            return {"hold": bool(why), "state": state, "reasons": why, "reply_due": facts}
    return {"hold": bool(why), "state": state, "reasons": why}


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="send-time communication state (read-only)")
    sub = ap.add_subparsers(dest="op", required=True)
    c = sub.add_parser("check")
    c.add_argument("--campaign", required=True)
    c.add_argument("--copy", default="")
    c.add_argument("--user-id", required=True)
    c.add_argument("--request-ids", default="")
    c.add_argument("--contact-id", default="")
    c.add_argument("--conversation", default="", help="the conversation the note would go into (R1: the filing one)")
    c.add_argument("--reply-due", default="", help="[key=reply-due]: the customer part this note answers")
    c.add_argument("--nothing-needed-body", action="store_true",
                   help="the rendered note says nothing (else) is needed: hold anyone who still owes proof")
    a = ap.parse_args(argv)
    if not str(a.user_id).isdigit():
        print(json.dumps({"hold": None, "reasons": ["no Muso user id"]}))
        return 2
    try:
        res = check(a.campaign, a.copy, int(a.user_id), [k for k in a.request_ids.split(",") if k], a.contact_id,
                    conversation=a.conversation, reply_due_part=a.reply_due, nothing_needed_body=a.nothing_needed_body)
    except Unknown as exc:
        print(json.dumps({"hold": None, "reasons": [f"unknown: {exc}"]}))
        return 2
    print(json.dumps(res))
    return 3 if res["hold"] else 0


if __name__ == "__main__":
    sys.exit(_main())
