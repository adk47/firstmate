"""C5 coded rule `no_proof_after_ask` (Fable [key=paid-to-zero], captain 2026-10-30 13:2xZ): the policy close of a
credit request whose user was ASKED for proof, got the day-7 reminder, and filed NOTHING by ask + 14 days.

Deterministic, no model. It writes decider rows into the credit-review ledger's append-only `decisions` table in the
agreed coded-close shape (data/doc-verify-build-b1/coded-close-row-shape.md, Fable [key=coded-close-store]):
decision='close' (or 'hold' with the reason it may not close), reason_code / evidence_kind 'no_proof_after_ask',
rule_version, expected_status, gate_state, popularity, v9_anchor, evidence_json, mode shadow|apply. The L12 executor
consumes ONLY apply rows (its `coded_outcome = decisions:<id>` check) and re-checks every rail at write time.

A request may close only when ALL hold (any unreadable input = hold, never close):
  - its LATEST credit ask (verify_messages, status sent, kind initial) named it, and that ask is >= 14 days old;
  - a reminder went to the user after that ask (REQUIRE_REMINDER; the plan's day-7 reminder comes first);
  - it is still open (unverified | user_verification_needed) and not deleted, same user;
  - no document since the ask: our stores (proof intake, doc-verify outcomes, proof-on-file, a tagged reply), and
    Intercom (an attachment or a shared-document link from the user on/after the ask);
  - the user did not reply after the ask (a text reply goes to a human / reply-due, never to a close);
  - V9 shows no DSP anchor, and V9 has READ it (unread = hold; Fable may relax this by rule PR);
  - popularity 1..59 from the server, no client-sourced metadata, the user holds no claim on the profile,
    the account gate allows and the account is not watchlisted (the executor's own close rails, read the same way).
Apply mode additionally needs policies/credit-no-proof-close.json apply_enabled=true with an approved closing line
(nothing is closed without telling the user), no kill file, and at most DAILY_CAP apply closes per UTC day.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

RULE_NAME = "no_proof_after_ask"
RULE_ID = "C5:no_proof_after_ask/v1"
REASON_CODE = RULE_NAME
DEADLINE_DAYS = 14
DAILY_CAP = 100
REQUIRE_REMINDER = True
#: credit asks only (claim-proof-ask is about a claim, not a credit request)
CREDIT_ASKS = ("uvn-status", "verify-live", "retro-past", "gap-ask", "proof-need-ask")
CLOSABLE_FROM = ("unverified", "user_verification_needed")
BIG_POPULARITY = 60
LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
POLICY = os.environ.get("NO_PROOF_CLOSE_POLICY",
                        str(Path(__file__).resolve().parents[2] / "policies" / "credit-no-proof-close.json"))
KILL_FILES = ("/etc/hydra/no-proof-close.disabled", "/etc/hydra/fable-decider.disabled")



def rule_version() -> str:
    """The rule id + the sha of this file: a later rule change never silently re-opens a decided row."""
    return RULE_ID + "+" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]


def ensure_columns(db: sqlite3.Connection) -> None:
    """The shared coded-decision columns (credit_review/coded_close.py)."""
    from credit_review import coded_close
    coded_close.ensure_columns(db)


def _ts(v: Any) -> str:
    s = str(v or "").strip().replace(" UTC", "").replace(" ", "T").rstrip("Z")
    return s[:19] if len(s) >= 19 else ""


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s[:19]).replace(tzinfo=timezone.utc)


@dataclass
class Ask:
    ask_id: int
    user_id: int
    campaign: str
    sent_at: str                      # ISO UTC, seconds
    request_ids: list[str]
    contact_id: str = ""
    conversation_id: str = ""
    last_reply_at: str = ""


def latest_asks(db: sqlite3.Connection) -> dict[str, Ask]:
    """{request id: the LATEST sent credit ask naming it} (a newer ask restarts the clock)."""
    q = ("SELECT id, account_id, campaign, coalesce(sent_at, created_at), coalesce(request_ids_json, '[]'), "
         "coalesce(contact_id, ''), coalesce(conversation_id, ''), coalesce(last_reply_at, '') FROM verify_messages "
         "WHERE status = 'sent' AND kind = 'initial' AND campaign IN (%s) ORDER BY id" % ",".join("?" * len(CREDIT_ASKS)))
    out: dict[str, Ask] = {}
    for aid, acct, camp, at, ids_json, contact, conv, reply in db.execute(q, CREDIT_ASKS):
        if not str(acct or "").isdigit() or not _ts(at):
            continue
        try:
            ids = [str(x).lower() for x in json.loads(ids_json or "[]")]
        except ValueError:
            continue
        ask = Ask(int(aid), int(acct), camp, _ts(at), ids, str(contact), str(conv), _ts(reply))
        for rid in ids:
            if rid not in out or ask.sent_at >= out[rid].sent_at:
                out[rid] = ask
    return out


@dataclass(frozen=True)
class Reminder:
    sent_at: str
    parent_row: int | None
    request_ids: frozenset[str]


def latest_ask_id(db: sqlite3.Connection, rid: str) -> int | None:
    """The id of the LATEST sent credit ask naming this request, read now (None = none). A newer ask than the one a
    close was decided on restarts the clock, so the close no longer stands (QA #1536)."""
    rid = rid.lower()
    best: tuple[str, int] | None = None
    q = ("SELECT id, coalesce(sent_at, created_at), coalesce(request_ids_json, '[]') FROM verify_messages "
         "WHERE status = 'sent' AND kind = 'initial' AND campaign IN (%s) AND lower(request_ids_json) LIKE ?"
         % ",".join("?" * len(CREDIT_ASKS)))
    for aid, at, ids_json in db.execute(q, (*CREDIT_ASKS, f"%{rid}%")):
        try:
            if rid not in {str(x).lower() for x in json.loads(ids_json or "[]")}:
                continue
        except ValueError:
            continue
        key = (_ts(at), int(aid))
        if best is None or key >= best:
            best = key
    return best[1] if best else None


def reminders(db: sqlite3.Connection) -> dict[int, list[Reminder]]:
    """{user id: every sent reminder, with what it reminded about} (QA #1536: a reminder counts only for its own ask
    or the requests it names, never for another request of the same user)."""
    out: dict[int, list[Reminder]] = {}
    for acct, at, parent, ids_json in db.execute(
            "SELECT account_id, coalesce(sent_at, created_at), parent_row, coalesce(request_ids_json, '[]') "
            "FROM verify_messages WHERE status = 'sent' AND kind LIKE 'reminder%'"):
        if not (str(acct or "").isdigit() and _ts(at)):
            continue
        try:
            ids = frozenset(str(x).lower() for x in json.loads(ids_json or "[]"))
        except ValueError:
            ids = frozenset()
        out.setdefault(int(acct), []).append(
            Reminder(_ts(at), int(parent) if str(parent or "").isdigit() else None, ids))
    return out


def reminded_for(rid: str, ask: "Ask", user_reminders: list[Reminder]) -> list[str]:
    """sent_at of the reminders after this ask that are about THIS ask (parent_row) or name THIS request."""
    return sorted(r.sent_at for r in user_reminders
                  if r.sent_at > ask.sent_at and (r.parent_row == ask.ask_id or rid in r.request_ids))


@dataclass
class Row:
    request_id: str
    user_id: int
    decision: str                     # close | hold
    reason: str
    expected_status: str | None
    popularity: int | None
    paid: bool | None
    gate_state: str
    v9_anchor: str
    deadline: str
    evidence: dict[str, Any] = field(default_factory=dict)


Docs = Callable[[int, list[str], str], list[str]]          # (user, request ids, since) -> documents found
#: (contact id, since) -> {"docs": [...], "replies": [...]}: documents AND any user message (text included) on/after
#: `since` in ANY of the contact's conversations (QA #1536: the ledger's last_reply_at is not kept for plain asks)
Intercom = Callable[[str, str], dict[str, list[str]]]


def evaluate(now: datetime, asks: dict[str, Ask], reminded: dict[int, list[Reminder]], facts: dict[str, Any],
             docs_fn: Docs, intercom_fn: Intercom, anchors: dict[str, str], gate_fn: Callable[[int], Any],
             paid_ids: frozenset[int] | None) -> tuple[list[Row], dict[str, int]]:
    """The decision for every request whose deadline has passed. Requests not yet due, or no longer open, get no row
    (counted only). Never raises on one user's unreadable input: that user's rows hold."""
    rows: list[Row] = []
    skipped: dict[str, int] = {}
    by_user: dict[tuple[int, int], list[str]] = {}
    for rid, ask in asks.items():
        by_user.setdefault((ask.user_id, ask.ask_id), []).append(rid)
    for (uid, _aid), rids in sorted(by_user.items()):
        ask = asks[rids[0]]
        deadline = _dt(ask.sent_at) + timedelta(days=DEADLINE_DAYS)
        if now < deadline:
            skipped["not_due"] = skipped.get("not_due", 0) + len(rids)
            continue
        open_rids = []
        for rid in rids:
            f = facts.get(rid)
            if f is not None and not f.deleted and f.status in CLOSABLE_FROM:
                open_rids.append(rid)
            else:
                k = "not_open:" + ("missing" if f is None else "deleted" if f.deleted else str(f.status))
                skipped[k] = skipped.get(k, 0) + 1
        if not open_rids:
            continue
        # user-level reads, once per (user, ask); any failure holds every open request of the ask
        user_why: str | None = None
        found: list[str] = []
        replies: list[str] = []
        try:
            found += docs_fn(uid, open_rids, ask.sent_at)
        except Exception as exc:  # noqa: BLE001
            user_why = f"unknown:stores:{str(exc)[:80]}"
        if user_why is None:
            try:
                ic = intercom_fn(ask.contact_id, ask.sent_at)
                found += list(ic.get("docs") or [])
                replies = list(ic.get("replies") or [])
            except Exception as exc:  # noqa: BLE001
                user_why = f"unknown:intercom:{str(exc)[:80]}"
        gate = None
        if user_why is None:
            try:
                gate = gate_fn(uid)
            except Exception as exc:  # noqa: BLE001
                user_why = f"unknown:account_gate:{str(exc)[:80]}"
        gate_state = "unknown" if gate is None else ("allow" if gate.allowed else str(gate.decision))
        watch = bool(gate is not None and ((isinstance(gate.payload, dict) and gate.payload.get("watch")) or any(
            "watchlist" in r.lower() or "deny" in r.lower() for r in gate.reasons)))
        for rid in open_rids:
            f = facts[rid]
            v9 = anchors.get(rid, "unknown")
            pop = f.popularity
            why = user_why
            if why is None and f.user_id != uid:
                why = "user_mismatch"
            if why is None and found:
                why = "proof_on_file:" + ",".join(sorted(set(found)))[:200]
            reminder_at = reminded_for(rid, ask, reminded.get(uid, []))
            if why is None and (replies or (ask.last_reply_at and ask.last_reply_at > ask.sent_at)):
                why = "replied_after_ask:" + ",".join(sorted(set(replies)))[:120]
            if why is None and REQUIRE_REMINDER and not reminder_at:
                why = "no_reminder_yet"
            if why is None and v9 == "anchor":
                why = "dsp_anchor"
            if why is None and v9 != "no_anchor":
                why = "v9_unread"
            if why is None and (f.metadata_source == "client" or pop is None or not 1 <= pop < BIG_POPULARITY):
                why = f"big_or_unknown_popularity:{pop}"
            if why is None and f.owns_profile is not False:
                why = "submitter_has_claim_on_profile" if f.owns_profile else "profile_claim_unknown"
            if why is None and gate_state != "allow":
                why = f"account_gate_{gate_state}"
            if why is None and watch:
                why = "watchlisted_account"
            evidence = {"ask_id": ask.ask_id, "ask_campaign": ask.campaign, "ask_sent_at": ask.sent_at + "Z",
                        "deadline": deadline.strftime("%Y-%m-%dT%H:%M:%SZ"), "reminders_after_ask": reminder_at[:3],
                        "documents_found": sorted(set(found))[:10], "replies_found": sorted(set(replies))[:10],
                        "last_reply_at": ask.last_reply_at or None, "contact_id": ask.contact_id or None,
                        "conversation_id": ask.conversation_id or None}
            rows.append(Row(rid, uid, "hold" if why else "close",
                            why or (f"asked {ask.sent_at[:10]} ({ask.campaign}), reminded {reminder_at[0][:10]}, no "
                                    f"document or reply by the {DEADLINE_DAYS}-day deadline"),
                            f.status, pop, None if paid_ids is None else uid in paid_ids, gate_state, v9,
                            deadline.strftime("%Y-%m-%dT%H:%M:%SZ"), evidence))
    rows.sort(key=lambda r: (r.decision != "close", r.paid is not True, r.deadline, r.user_id, r.request_id))
    return rows, skipped


def intercom_read(contact_id: str, since: str, ic: Callable[[str, str, dict | None], dict],
                  conv_cap: int = 60) -> dict[str, list[str]]:
    """Documents and replies from this contact on/after `since` (ISO UTC) in ANY of their conversations. A part
    authored by the user/lead/contact with a readable time >= since is a reply; with an attachment or a shared-document
    link it is also a document. A part with no readable time counts (fail closed). More conversations than we read =
    treated as replied. Raises when Intercom cannot be read."""
    from credit_review.comm_state import has_doc_link
    if not contact_id:
        raise RuntimeError("no Intercom contact to read")
    since_epoch = datetime.fromisoformat(since[:19]).replace(tzinfo=timezone.utc).timestamp()
    res = ic("POST", "/conversations/search", {"query": {"field": "contact_ids", "operator": "=", "value": contact_id},
                                              "pagination": {"per_page": conv_cap}})
    convs = res.get("conversations")
    if not isinstance(convs, list):
        raise RuntimeError("conversation search unreadable")
    if (res.get("total_count") or len(convs)) > conv_cap:
        return {"docs": [], "replies": ["intercom:more_conversations_than_checked"]}
    docs: list[str] = []
    replies: list[str] = []
    for c in convs:
        cid = str(c.get("id") or "")
        if not cid.isdigit():
            raise RuntimeError("conversation id unreadable")
        conv = ic("GET", f"/conversations/{cid}?display_as=plaintext", None)
        src = dict(conv.get("source") or {})
        if not src.get("created_at"):
            src["created_at"] = conv.get("created_at") or c.get("created_at")
        for p in [src] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or []):
            if (p.get("author") or {}).get("type") not in ("user", "lead", "contact"):
                continue
            at = p.get("created_at")
            if at and at < since_epoch:
                continue
            replies.append(f"intercom_reply:{cid}")
            if p.get("attachments") or has_doc_link(p.get("body") or ""):
                docs.append(f"intercom_document:{cid}")
    return {"docs": sorted(set(docs)), "replies": sorted(set(replies))}


def policy(path: str | None = None) -> dict[str, Any]:
    try:
        return json.loads(Path(path or POLICY).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def apply_refusal(pol: dict[str, Any], kill_files: Iterable[str] = KILL_FILES) -> str | None:
    """Why apply mode may not run, or None. Fail closed."""
    for k in kill_files:
        if os.path.exists(k):
            return f"kill file {k}"
    if pol.get("apply_enabled") is not True:
        return "policy apply_enabled is not true (shadow first; the flip is a reviewed PR)"
    if not pol.get("approved_by") or not pol.get("approval_ref"):
        return "policy has no approved_by / approval_ref"
    if not isinstance(pol.get("closing_line_campaign"), str) or not pol["closing_line_campaign"]:
        return "no approved closing line (closing_line_campaign): nothing is closed without telling the user"
    return None


def applied_today(db: sqlite3.Connection, now: datetime) -> int:
    day = now.strftime("%Y-%m-%d")
    return db.execute("SELECT count(*) FROM decisions WHERE mode = 'apply' AND decision = 'close' AND reason_code = ? "
                      "AND decided_at >= ?", (REASON_CODE, day)).fetchone()[0]


TRAY_TTL = timedelta(hours=1)        # a published tray expires: the executor refuses it after this (QA #1536)


def _tray_marks(db: sqlite3.Connection) -> dict[int, tuple[str, str]]:
    """{decision id: (kind, tray expires_at)} from the decision_outcomes 'tray' lines; kind published | expired.
    Line shapes: 'published:decisions:<id>:<tray name>@<expires_at>' and 'expired:decisions:<id>:<why>'."""
    out: dict[int, tuple[str, str]] = {}
    for (o,) in db.execute("SELECT outcome FROM decision_outcomes WHERE action = 'tray' ORDER BY id"):
        kind, _, rest = str(o).partition(":decisions:")
        did, _, tail = rest.partition(":")
        if did.isdigit() and kind in ("published", "expired"):
            out[int(did)] = (kind, tail.rpartition("@")[2] if kind == "published" else "")
    return out


def already_decided(db: sqlite3.Connection, mode: str, now: datetime | None = None) -> set[str]:
    """Requests with a LIVE close row of this rule in this mode (a re-run never duplicates one). Live = shadow, or an
    apply close not yet published, or published in a tray that has not expired. A close that expired at publication
    (proof / reply arrived since) or whose tray expired unexecuted is not live: the request is decided again (an
    executed close left the request rejected, so the next decision skips it as not open)."""
    if mode != "apply":
        return {str(r).lower() for (r,) in db.execute(
            "SELECT request_id FROM decisions WHERE decision = 'close' AND reason_code = ? AND mode = ?",
            (REASON_CODE, mode))}
    marks = _tray_marks(db)
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    live = set()
    for did, rid in db.execute("SELECT id, request_id FROM decisions WHERE decision = 'close' AND reason_code = ? "
                               "AND mode = 'apply'", (REASON_CODE,)):
        kind, exp = marks.get(did, ("", ""))
        if not kind or (kind == "published" and exp and exp > stamp):
            live.add(str(rid).lower())
    return live


def record(db: sqlite3.Connection, run_id: str, mode: str, rows: list[Row], now: datetime,
           daily_cap: int = DAILY_CAP) -> dict[str, Any]:
    """Append the rows (close + hold) and, per close in shadow, a decision_outcomes 'shadow' line. In apply mode at
    most `daily_cap` closes per UTC day; the rest are written as holds 'daily_cap'. Returns counts + close row ids.
    The cap / duplicate reads and every insert run in ONE `BEGIN IMMEDIATE` transaction (QA #1536): a concurrent run
    waits for the write lock and then re-reads, so two runs can never both spend the same cap or close one request
    twice."""
    ver = rule_version()
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    out: dict[str, Any] = {"close": 0, "hold": {}, "close_ids": [], "duplicate": 0, "rule_version": ver}
    db.commit()
    db.execute("BEGIN IMMEDIATE")
    try:
        done = already_decided(db, mode, now)
        room = daily_cap - applied_today(db, now) if mode == "apply" else None
        for r in rows:
            if r.decision == "close" and r.request_id in done:
                out["duplicate"] += 1
                continue
            decision, reason = r.decision, r.reason
            if decision == "close" and room is not None and room <= 0:
                decision, reason = "hold", "daily_cap"
            cur = db.execute(
                "INSERT INTO decisions (run_id, decided_at, request_id, user_id, popularity, big_track, decision, "
                "reason, evidence_kind, paid_priority, mode, reason_code, rule_version, expected_status, gate_state, "
                "v9_anchor, intake_ids, evidence_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (run_id, at, r.request_id, r.user_id, r.popularity,
                 1 if (r.popularity or 0) >= BIG_POPULARITY else 0, decision, reason[:600], REASON_CODE,
                 None if r.paid is None else int(r.paid), mode, REASON_CODE, ver, r.expected_status, r.gate_state,
                 r.v9_anchor, "[]", json.dumps(r.evidence, ensure_ascii=False)))
            if decision == "close":
                out["close"] += 1
                out["close_ids"].append((cur.lastrowid, r))
                done.add(r.request_id)
                if room is not None:
                    room -= 1
                if mode == "shadow":
                    db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
                               "VALUES (?,?,?,?,?)", (run_id, at, r.request_id, "close", "shadow"))
            else:
                k = reason.split(":")[0]
                out["hold"][k] = out["hold"].get(k, 0) + 1
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return out


def unpublished(db: sqlite3.Connection) -> list[tuple[int, Row, dict[str, Any]]]:
    """Committed APPLY close rows of this rule with no tray mark yet (neither published nor expired)."""
    marks = _tray_marks(db)
    out = []
    for did, rid, uid, status, paid, reason, ev in db.execute(
            "SELECT id, request_id, user_id, expected_status, paid_priority, reason, coalesce(evidence_json, '{}') "
            "FROM decisions WHERE mode = 'apply' AND decision = 'close' AND reason_code = ? ORDER BY id",
            (REASON_CODE,)):
        if did not in marks:
            try:
                evidence = json.loads(ev)
            except ValueError:
                evidence = {}
            out.append((did, Row(rid, uid, "close", reason, status, None, bool(paid), "", "", ""), evidence))
    return out


#: (user id, request ids, the ask's sent_at, contact id) -> why the close no longer stands ('' = it stands)
Recheck = Callable[[int, list[str], str, str], str]


def tray_name(status: str, ids: list[int]) -> str:
    """A STABLE publication identity: the same rows always make the same file name."""
    return f"no-proof-{status}-" + hashlib.sha256(",".join(map(str, sorted(ids))).encode()).hexdigest()[:16] + ".json"


def publish(db: sqlite3.Connection, run_id: str, tray_dir: str, now: datetime, recheck: Recheck) -> dict[str, Any]:
    """Publish executor trays for the unpublished apply close rows, exactly once (QA #1536):
      1. reconcile: a tray recorded as published whose file is missing is rebuilt under its SAME name;
      2. re-check proof AND reply for every unpublished row right now; a row whose evidence changed is marked
         'expired' (never published; the request may be decided again);
      3. write each new tray to <name>.tmp, commit its 'published' marks in one transaction, THEN rename. A crash
         before the commit leaves only a .tmp (never executed, superseded next run); after it, step 1 recovers.
    Every tray carries expires_at = now + TRAY_TTL; the executor refuses an expired tray."""
    outdir = Path(tray_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    res: dict[str, Any] = {"trays": [], "expired": {}, "reconciled": []}
    # 1. reconcile: a tray recorded published whose rename never happened is renamed under its SAME name while it is
    #    still valid; an expired leftover is removed (its rows are re-decided, see already_decided)
    stamp = at
    for (o,) in db.execute("SELECT DISTINCT outcome FROM decision_outcomes WHERE action = 'tray' "
                           "AND outcome LIKE 'published:%'"):
        name, _s, exp = str(o).partition(":decisions:")[2].partition(":")[2].rpartition("@")
        if not name or (outdir / name).exists():
            continue
        tmp = outdir / (name + ".tmp")
        if tmp.exists():
            if exp and exp > stamp:
                os.replace(tmp, outdir / name)
                res["reconciled"].append(name)
            else:
                tmp.unlink()
    # 2. re-check, 3. publish
    fresh: list[tuple[int, Row]] = []
    expired: list[tuple[int, Row, str]] = []
    for did, r, ev in unpublished(db):
        try:
            newer = latest_ask_id(db, r.request_id)
            if newer != ev.get("ask_id"):
                expired.append((did, r, f"newer_ask:{newer}"))
                continue
            why = recheck(r.user_id, [r.request_id], str(ev.get("ask_sent_at") or "").rstrip("Z"),
                          str(ev.get("contact_id") or ""))
        except Exception as exc:  # noqa: BLE001 - unreadable = it no longer stands
            why = f"unknown:{str(exc)[:80]}"
        (expired.append((did, r, why)) if why else fresh.append((did, r)))
    staged = []
    # The slow re-checks ran outside the lock; the CLAIM is atomic (QA #1559): under one write lock, keep only rows
    # still unmarked (a concurrent publisher may have taken some), stage, mark, commit - then rename.
    db.commit()
    db.execute("BEGIN IMMEDIATE")
    try:
        still = {did for did, _r, _ev in unpublished(db)}
        fresh = [(did, r) for did, r in fresh if did in still]
        expired = [(did, r, why) for did, r, why in expired if did in still]
        for status, doc in tray_docs(fresh).items():
            ids = [int(x["coded_outcome"].split(":")[1]) for x in doc["rows"]]
            name = tray_name(status, ids)
            doc["expires_at"] = (now + TRAY_TTL).strftime("%Y-%m-%dT%H:%M:%SZ")
            tmp = outdir / (name + ".tmp")
            tmp.write_text(json.dumps(doc, indent=1), encoding="utf-8")
            staged.append((name, tmp, doc))
        for did, r, why in expired:
            db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES (?,?,?,?,?)",
                       (run_id, at, r.request_id, "tray", f"expired:decisions:{did}:{why}"[:300]))
            k = why.split(":")[0]
            res["expired"][k] = res["expired"].get(k, 0) + 1
        for name, _tmp, doc in staged:
            for x in doc["rows"]:
                db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES "
                           "(?,?,?,?,?)", (run_id, at, x["request_id"], "tray",
                                           f"published:{x['coded_outcome']}:{name}@{doc['expires_at']}"))
        db.commit()
    except BaseException:
        db.rollback()
        raise
    for name, tmp, _doc in staged:
        os.replace(tmp, outdir / name)
        res["trays"].append(str(outdir / name))
    return res


def live_recheck(uid: int, rids: list[str], since: str, contact: str) -> str:
    """Proof AND reply re-read, now: '' = the close still stands, else why not. Raises when unreadable."""
    from credit_review import comm_state
    docs = comm_state.store_facts(uid, rids, since=since)["docs"]
    if docs:
        return "proof_on_file:" + ",".join(sorted(set(docs)))[:120]
    ic = intercom_read(contact, since, comm_state.intercom)
    if ic["docs"]:
        return "proof_on_file:" + ",".join(ic["docs"])[:120]
    if ic["replies"]:
        return "replied_after_ask:" + ",".join(ic["replies"])[:120]
    return ""


def recheck_decisions(ids: dict[str, int], recheck: Recheck | None = None,
                      ledger: str | None = None) -> dict[str, str]:
    """{request id: '' | why} for the decider rows {request id: decision id}, re-read at EXECUTION time by the L12
    executor (tray flag recheck_evidence, QA #1536): the ask + contact come from the row's own evidence_json; a row
    that is missing, not an apply close of this rule, or unreadable is refused."""
    recheck = recheck or live_recheck
    out: dict[str, str] = {}
    if not ids:
        return out
    con = sqlite3.connect(f"file:{ledger or LEDGER}?mode=ro", uri=True, timeout=10)
    try:
        rows = {did: (str(rid).lower(), uid, dec, mode, code, ev) for did, rid, uid, dec, mode, code, ev in con.execute(
            "SELECT id, request_id, user_id, decision, mode, reason_code, coalesce(evidence_json, '{}') FROM decisions "
            "WHERE id IN (%s)" % ",".join("?" * len(ids)), list(ids.values()))}
        latest = {rid: latest_ask_id(con, rid) for rid in ids}
    finally:
        con.close()
    for rid, did in ids.items():
        row = rows.get(did)
        if row is None or row[0] != rid or row[2] != "close" or row[3] != "apply" or row[4] != REASON_CODE:
            out[rid] = "unknown:not an apply no_proof_after_ask close for this request"
            continue
        try:
            ev = json.loads(row[5])
            if latest.get(rid) != ev.get("ask_id"):
                out[rid] = f"newer_ask:{latest.get(rid)}"
                continue
            out[rid] = recheck(int(row[1]), [rid], str(ev.get("ask_sent_at") or "").rstrip("Z"),
                               str(ev.get("contact_id") or ""))
        except Exception as exc:  # noqa: BLE001
            out[rid] = f"unknown:{str(exc)[:80]}"
    return out


def tray_docs(close_ids: list[tuple[int, Row]]) -> dict[str, dict[str, Any]]:
    """One executor reject tray per expected status, from APPLY close rows only (each row cites decisions:<id>)."""
    trays: dict[str, dict[str, Any]] = {}
    for did, r in close_ids:
        t = trays.setdefault(r.expected_status or "", {
            "action": "reject", "expected_status": r.expected_status, "order": "as_listed",
            # the executor re-reads, per batch at write time: V9 (a new DSP anchor refuses the close) and the
            # proof / reply evidence (a user who answered since is never closed) - QA #1536
            "refuse_if_dsp_anchor": True, "recheck_evidence": "no_proof_after_ask",
            "note": f"coded rule {RULE_ID}; rows from the decider ledger, never a hand list", "rows": []})
        t["rows"].append({"request_id": r.request_id, "user_id": r.user_id, "ruling_id": f"decisions-{did}",
                          "rule": RULE_ID, "paid": bool(r.paid), "coded_outcome": f"decisions:{did}",
                          "evidence": r.reason})
    return trays
