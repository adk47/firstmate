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
    admin = [p for p in parts if (p.get("author") or {}).get("type") in ("admin", "bot", "team")
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
    elif campaign == RECEIPT and copy in ("docrecvr", "docrecvq", "docrecv"):
        if decided or told:
            why.append("decided_or_told:" + ",".join((decided + told)[:5]))
        why += [t for t in thread if t in ("R6_stale_thread", "R7_thread_resolved")]
    return state, why


def owes_proof(uid: int, query: Query) -> list[str]:
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
    return sorted(set(out))


def check(campaign: str, copy: str, uid: int, keys: list[str], contact_id: str, *, conversation: str = "",
          query: Query = trino, ic: Intercom = intercom, fraud: Callable[[int, Query], list[str]] | None = None
          ) -> dict[str, Any]:
    if nothing_else(campaign, copy):
        why = owes_proof(uid, query)
        return {"hold": bool(why), "state": "owes_proof" if why else "owes_nothing", "reasons": why}
    core = core_facts(uid, keys, query)
    st = store_facts(uid, keys, core["created"])
    ic_found = (intercom_facts(contact_id, max(st["last_ask"], core["last_ask"]), ic, core["created"])
                if campaign in WAIT_LINES else [])
    thread = thread_facts(conversation, ic)
    fr = (fraud or fraud_facts)(uid, query)
    state, why = decide(campaign, copy, st, core, ic_found, thread, fr)
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
    a = ap.parse_args(argv)
    if not str(a.user_id).isdigit():
        print(json.dumps({"hold": None, "reasons": ["no Muso user id"]}))
        return 2
    try:
        res = check(a.campaign, a.copy, int(a.user_id), [k for k in a.request_ids.split(",") if k], a.contact_id,
                    conversation=a.conversation)
    except Unknown as exc:
        print(json.dumps({"hold": None, "reasons": [f"unknown: {exc}"]}))
        return 2
    print(json.dumps(res))
    return 3 if res["hold"] else 0


if __name__ == "__main__":
    sys.exit(_main())
