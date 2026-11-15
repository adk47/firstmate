#!/usr/bin/env python3
"""proof-refusal: who is told why the document they sent did not verify a credit, and the send through the gate.

The proof reviewer (proof_reviewer.py) rejects a document and records, per request, the reason and the need code
naming what would satisfy the request (proof_review_decisions.ask_need). This module turns those rows into ONE
note per person through `intercom-verify-request.sh --campaign proof-refusal`, which owns the copy, the lint, the
outbound copy gate, the ledger claim and the 7-day rule. It writes no copy and approves nothing.

A row is listed only where an approved body says exactly what the reader recorded (PAIRS). Every other rejected
row is HELD and counted by class in the list's `held`, never sent a body that names a different need:

  build     read the ledger (read-only) and write the list: one entry per person, paid first.
  send      the tick's family step (the CLI of need_asks.py `send`): dry-run check, bodies, apply.
  readback  read back every note this campaign has sent: sent = claimed, 0 hard bounces, 0 spam complaints.
            Exit 0 = all three hold (or nothing was sent yet), 3 = one does not, 2 = could not be measured.
            The tick asks it before every run and runs no batch on anything but 0.

At the send every listed request is read again from core: a request that is no longer pending, one held for a
cause no document clears (policy.never_ask), one another ask class holds, one a proof-need-ask already named and
one this campaign already wrote about are dropped, each with its reason in the outcomes file.

The reviewer's decision is read again too (`moved`), because the list is as old as the tick's build and the
reviewer runs beside it: once for the page (every mode; a moved row is dropped), and on an apply once more per
person immediately before that person's own gate call (any moved row holds the whole person, nothing claimed).
A row stands only while its review row and its newest unreverted decision still say what the list said.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import need_asks, proof_reviewer, uvn_status, verify_notify  # noqa: E402

CAMPAIGN = "proof-refusal"
LOCK = "PROOF_REFUSAL_COPY_APPROVED"
NEED_ASK_CAMPAIGN = need_asks.CAMPAIGN
LEDGER = proof_reviewer.LEDGER
PAYING = need_asks.PAYING
PENDING = need_asks.PENDING
LABEL = "PROOF REFUSAL"

# (the reviewer's reason, the reader's recorded need) -> an approved body exists. The gate holds the same table
# (refusal_note in intercom-verify-request.sh) and refuses a whole note that carries any other pair; the test
# pins the two equal, and the evidence words equal to proof_reviewer.ASK_LINES.
PAIRS = frozenset({
    ("doesnt_name_you", proof_reviewer.NEED_COUNTERPARTY),
    ("other_track", proof_reviewer.NEED_COUNTERPARTY),
    ("unreadable", proof_reviewer.NEED_READABLE),
})
EVIDENCE = {need: proof_reviewer.ASK_LINES[need] for _, need in PAIRS}


class RefusalError(RuntimeError):
    """The list cannot be built or read; nothing is listed or sent."""


def held_class(reason: str, need: str, route: str, account: str, agrees: bool) -> str:
    """'' = listed; otherwise why this rejected row is held (one class per row, the first that applies)."""
    if not agrees:
        return "no_matching_decision"          # the review row has no unreverted decision that says the same
    if not account:
        return "no_account"
    if (reason, need) in PAIRS:
        return ""
    if reason not in {r for r, _ in PAIRS}:
        return "no_body_for_reason"            # not_a_document, other_role: no approved body
    if not need:
        return "reader_named_no_need"          # blocked routes: the reader recorded nothing that would change it
    return f"reader_need:{need}"               # e.g. the distributor dashboard: the ask path's, never this note's


def _paying(path: str) -> frozenset[int]:
    try:
        with open(path, encoding="utf-8") as fh:
            ids = json.load(fh)["ids"]
        return frozenset(int(i) for i in ids)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise RefusalError(f"the paying-users file {path} is unreadable ({exc}); paid-first cannot be ordered") from exc


def build(*, ledger: str = LEDGER, paying_path: str = PAYING) -> dict[str, Any]:
    """The list: one entry per person with every listed row, paid first, and every held row counted by class."""
    paying = _paying(paying_path)
    try:
        db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        reviews = db.execute("SELECT family, request_id, reason, reviewed_at FROM verify_proof_reviews "
                             "WHERE outcome='rejected'").fetchall()
        decisions: dict[tuple[int, str], sqlite3.Row] = {}
        for d in db.execute("SELECT id, run_id, family, request_id, account_id, outcome, reason, ask_need, ask_route "
                            "FROM proof_review_decisions WHERE reverted_at IS NULL ORDER BY id"):
            decisions[(d["family"], d["request_id"])] = d          # the newest unreverted decision wins
        accounts = {r["id"]: r["account_id"] for r in db.execute("SELECT id, account_id FROM verify_messages")}
        db.close()
    except sqlite3.Error as exc:
        raise RefusalError(f"the ledger {ledger} is unreadable ({exc})") from exc
    users: dict[str, dict[str, Any]] = {}
    held: dict[str, dict[str, Any]] = {}
    runs: set[str] = set()
    for r in reviews:
        d = decisions.get((r["family"], r["request_id"]))
        agrees = d is not None and d["outcome"] == "rejected" and d["reason"] == r["reason"]
        account = str((d["account_id"] if d is not None else None) or accounts.get(r["family"]) or "").strip()
        if not account.isdigit():
            account = ""
        need = str((d["ask_need"] if d is not None else "") or "")
        route = str((d["ask_route"] if d is not None else "") or "")
        if d is not None and d["run_id"]:
            runs.add(str(d["run_id"]))
        cls = held_class(r["reason"], need, route, account, agrees)
        if cls:
            h = held.setdefault(cls, {"rows": 0, "users": set()})
            h["rows"] += 1
            if account:
                h["users"].add(account)
            continue
        u = users.setdefault(account, {"user_id": int(account), "paid": int(account) in paying, "rows": []})
        u["rows"].append({"request_id": str(r["request_id"]).lower(), "reason": r["reason"], "need": need,
                          "family": int(r["family"]), "reviewed_at": r["reviewed_at"]})
    listed = sorted(users.values(), key=lambda u: (not u["paid"], u["user_id"]))
    for u in listed:
        u["rows"].sort(key=lambda x: (x["reviewed_at"] or "", x["request_id"]))
    held_out = {k: {"rows": v["rows"], "users": len(v["users"]),
                    "users_also_listed": len(v["users"] & set(users)),
                    "user_ids": sorted(v["users"], key=int)} for k, v in sorted(held.items())}
    return {"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "campaign": CAMPAIGN, "signed_on": verify_notify.deployed_head(),
            "source": {"ledger": ledger, "reviewer_runs": sorted(runs), "rejected_rows": len(reviews)},
            "counts": {"rejected_rows": len(reviews), "listed_rows": sum(len(u["rows"]) for u in listed),
                       "listed_users": len(listed), "listed_paid": sum(1 for u in listed if u["paid"]),
                       "held_rows": sum(v["rows"] for v in held_out.values())},
            "held": held_out, "users": listed}


def _contact(cid: str) -> dict[str, Any] | None:
    """One Intercom contact, read-only; None = could not be read (never read as "no bounce")."""
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if not token:
        return None
    for attempt in range(4):
        req = urllib.request.Request(f"https://api.intercom.io/contacts/{cid}", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/json", "Intercom-Version": "2.11"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 - a fixed https host
                return json.loads(r.read())
        except urllib.error.HTTPError as exc:
            if exc.code == 429 or exc.code >= 500:
                time.sleep(5 * (attempt + 1))
                continue
            return None
        except (OSError, ValueError):
            time.sleep(5)
    return None


def readback(*, ledger: str = LEDGER, fetch: Any = _contact) -> dict[str, Any]:
    """Every note this campaign claimed, read back: `claimed` is the rows the gate wrote before a POST (attempted or
    sent), `sent` the rows a POST confirmed, and each sent contact is read for a hard bounce and a spam complaint.
    `ok` only when claimed == sent and both counts are 0; a row or a contact that cannot be read is `unmeasured`,
    never a pass. Per UTC day too, so each run's counts can be posted."""
    try:
        db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
        rows = db.execute("SELECT id, status, contact_id, day FROM verify_messages WHERE campaign=? "
                          "AND status IN ('attempted','sent') ORDER BY id", (CAMPAIGN,)).fetchall()
        db.close()
    except sqlite3.Error as exc:
        return {"campaign": CAMPAIGN, "verdict": "unmeasured", "why": f"the ledger is unreadable ({exc})"[:200]}
    out: dict[str, Any] = {"campaign": CAMPAIGN, "claimed": len(rows),
                           "sent": sum(1 for r in rows if r[1] == "sent"), "hard_bounced": 0, "spam_complaints": 0,
                           "contacts_read": 0, "by_day": {}}
    for _id, status, _cid, day in rows:
        d = out["by_day"].setdefault(day, {"claimed": 0, "sent": 0})
        d["claimed"] += 1
        d["sent"] += status == "sent"
    unconfirmed = [r[0] for r in rows if r[1] != "sent"]
    if unconfirmed:
        out["unconfirmed_rows"] = unconfirmed[:50]
    no_contact = [r[0] for r in rows if r[1] == "sent" and not r[2]]
    unread: list[str] = []
    bounced: list[str] = []
    spam: list[str] = []
    for cid in sorted({str(r[2]) for r in rows if r[1] == "sent" and r[2]}):
        c = fetch(cid)
        if not isinstance(c, dict):
            unread.append(cid)
            continue
        out["contacts_read"] += 1
        if c.get("has_hard_bounced"):
            bounced.append(cid)
        if c.get("marked_email_as_spam"):
            spam.append(cid)
    out["hard_bounced"], out["spam_complaints"] = len(bounced), len(spam)
    stops = []
    if out["sent"] != out["claimed"]:
        stops.append(f"sent {out['sent']} != claimed {out['claimed']}")
    if bounced:
        stops.append(f"{len(bounced)} hard bounce(s)")
        out["bounced_contacts"] = bounced[:50]
    if spam:
        stops.append(f"{len(spam)} spam complaint(s)")
        out["spam_contacts"] = spam[:50]
    if stops:                                   # a measured failure is named even when another part went unread
        out["verdict"], out["why"] = "stop", "; ".join(stops)
    elif unread or no_contact:
        out["verdict"] = "unmeasured"
        out["why"] = (f"{len(unread)} contact(s) could not be read and {len(no_contact)} sent row(s) name no contact; "
                      "a bounce or a complaint there would not be seen")
    else:
        out["verdict"] = "ok"
    return out


MOVED = "decision_changed"


def moved(ledger: str, rows: list[tuple[int, int, str, str, str]]) -> dict[tuple[int, str], str]:
    """{(family, request_id): why} for every row the ledger no longer says what the list said about it.

    `rows` is (user_id, family, request_id, reason, need) as listed. A row stands only while its review row is
    still `rejected` for that reason AND its newest unreverted decision is still `rejected`, for that reason, with
    that need, on that account - the same reading `build` made. The list is built once per tick and the reviewer
    runs beside it: a rejection it reverses, or a need it re-reads, after the build must not reach a customer as
    the old reason, because the one-message-per-request rule would then keep the right one from ever being sent.
    An unreadable ledger raises: a decision that cannot be re-read is never assumed to stand."""
    out: dict[tuple[int, str], str] = {}
    if not rows:
        return out
    try:
        db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        try:
            for uid, family, rid, reason, need in rows:
                key = (int(family), str(rid).lower())
                rev = db.execute("SELECT outcome, reason FROM verify_proof_reviews WHERE family=? AND "
                                 "lower(request_id)=?", key).fetchone()
                d = db.execute("SELECT account_id, outcome, reason, ask_need FROM proof_review_decisions WHERE "
                               "family=? AND lower(request_id)=? AND reverted_at IS NULL ORDER BY id DESC LIMIT 1",
                               key).fetchone()
                note = db.execute("SELECT account_id FROM verify_messages WHERE id=?", (key[0],)).fetchone()
                account = str((d["account_id"] if d is not None else None)
                              or (note["account_id"] if note is not None else None) or "").strip()
                if rev is None or rev["outcome"] != "rejected":
                    out[key] = "the review row is no longer a rejection"
                elif rev["reason"] != reason:
                    out[key] = "the review row names another reason"
                elif d is None or d["outcome"] != "rejected":
                    out[key] = "no unreverted rejection decision stands"
                elif d["reason"] != reason:
                    out[key] = "the decision names another reason"
                elif str(d["ask_need"] or "") != need:
                    out[key] = "the decision names another need"
                elif account != str(uid):
                    out[key] = "the decision is on another account"
        finally:
            db.close()
    except sqlite3.Error as exc:
        raise RefusalError(f"the ledger {ledger} is unreadable ({exc}); the decisions could not be re-read") from exc
    return out


def _listed_rows(users: list[dict[str, Any]]) -> list[tuple[int, int, str, str, str]]:
    return [(int(u["user_id"]), int(r["family"]), str(r["request_id"]), str(r["reason"]), str(r["need"]))
            for u in users for r in u["rows"]]


def _payload_rows(p: dict[str, Any]) -> list[tuple[int, int, str, str, str]]:
    return [(int(p["user"]["id"]), int(c["review_family"]), str(c["request_id"]), str(c["reason"]), str(c["need"]))
            for c in p["credits"]]


def payloads(users: list[dict[str, Any]], query: uvn_status.Query, done: set[str], asked: set[str],
             filtered_out: list[dict[str, str]] | None = None,
             stale: dict[tuple[int, str], str] | None = None) -> list[dict[str, Any]]:
    """One gate payload per user from a live re-read of every listed request. A row is dropped, with its reason,
    when the reviewer's decision moved after the list was built (`stale`, from `moved`), it is already written
    about, already named by a proof-need-ask, no longer pending, held for a cause no document clears, or held by
    another ask class; a user with no row left is filtered with the reason most of their rows carry."""
    stale = stale or {}
    uids = [int(u["user_id"]) for u in users]
    if not uids:
        return []
    accounts = uvn_status.accounts_of(uids, query)
    live = uvn_status.uvn_requests(uids, query, PENDING)
    out: list[dict[str, Any]] = []
    for u in users:
        uid = int(u["user_id"])
        acct = accounts.get(uid) or {}
        if not acct.get("email"):
            need_asks._filtered(filtered_out, uid, "no_deliverable_account")
            continue
        now = {str(r["request_id"]).lower(): r for r in live.get(uid) or []}
        credits: list[dict[str, Any]] = []
        why: dict[str, int] = {}
        for row in u["rows"]:
            rid = str(row["request_id"]).lower()
            r = now.get(rid)
            if (int(row["family"]), rid) in stale:
                reason = f"{MOVED} ({stale[(int(row['family']), rid)]}; re-read now)"
            elif rid in done:
                reason = "already_told (this campaign already wrote about the request)"
            elif rid in asked:
                reason = "told_by_need_ask (a proof-need-ask already named the request)"
            elif r is None:
                reason = "not_pending_now (re-read now)"
            elif r.get("_never_ask") or r.get("_no_ask") == uvn_status.NEVER_ASKED:
                reason = "never_ask (held for a cause no document clears)"
            elif r.get("_no_ask"):
                reason = f"no_ask:{r['_no_ask']} (another class holds the request)"
            elif r.get("_incomplete"):
                reason = "request_incomplete (re-read now)"
            elif (row["reason"], row["need"]) not in PAIRS:
                reason = "no_approved_body"
            else:
                credits.append({"request_id": rid, "profile_id": r.get("profile_id"), "track_id": r.get("track_id"),
                                "track_title": r.get("track_title"), "artist_name": r.get("artist_name"),
                                "role": r.get("role"), "reason": row["reason"], "need": row["need"],
                                "review_family": int(row["family"])})
                continue
            why[reason] = why.get(reason, 0) + 1
        if not credits:
            top = max(why.items(), key=lambda kv: kv[1])[0] if why else "no_rows"
            need_asks._filtered(filtered_out, uid, f"{top}; {sum(why.values())} row(s) dropped, none left")
            continue
        out.append({"user": {"email": acct["email"], "id": str(uid), "professional_id": acct.get("professional_id"),
                             "auth_id": acct.get("auth_id"), "first_name": acct.get("first_name")},
                    "credits": credits, "dropped": why})
    return out


def send(*, mode: str = "dry-run", ledger_path: str | None = None, **kw: Any) -> verify_notify.Report:
    """An apply holds the credit-group run lock (one shared budget with every credit campaign) from before the
    budget read to after the last send; a dry run takes no lock. need_asks.send's shape, this campaign's lock."""
    if mode != "apply" or not uvn_status.campaign_lock_open(kw.get("wrapper", verify_notify.WRAPPER), LOCK):
        return _send(mode=mode, ledger_path=ledger_path, **kw)
    import fcntl  # noqa: PLC0415
    from credit_review import verify_ledger  # noqa: PLC0415
    lpath = ledger_path or verify_ledger.DEFAULT_PATH
    with open(uvn_status.group_lock_path(lpath, CAMPAIGN), "a+") as fh:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            report = verify_notify.Report()
            report.halted = "another credit-group apply run is in progress (one shared budget); nothing sent by this one"
            return report
        try:
            return _send(mode=mode, ledger_path=ledger_path, group_locked=True, **kw)
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def _send(*, list_path: str, segment: str, mode: str = "dry-run", max_users: int = 25,
          preview_dir: str | None = None, max_entries: int | None = None, start_entry: int = 0,
          query: uvn_status.Query | None = None, wrapper: str = verify_notify.WRAPPER,
          runner: verify_notify.Runner = verify_notify._run, ledger_path: str | None = None,
          check_recipients: bool = False, group_locked: bool = False) -> verify_notify.Report:
    report = verify_notify.Report()
    if mode == "apply" and not uvn_status.campaign_lock_open(wrapper, LOCK):
        report.halted = f"{CAMPAIGN} is send-locked in the gate ({LOCK}=0); nothing sent (dry-run renders it)"
        return report
    try:
        with open(list_path, encoding="utf-8") as fh:
            doc = json.load(fh)
        if doc.get("campaign") != CAMPAIGN:
            raise ValueError(f"not a {CAMPAIGN} list")
        users = [u for u in doc["users"] if bool(u["paid"]) is (segment == "paid")]
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        raise RefusalError(f"the list {list_path} is unreadable ({exc})") from exc
    verify_notify.bind_list(doc)           # [key=signed-on-sha]: the per-user sha rail reads this header
    n_listed = len(users)
    start = max(0, min(int(start_entry or 0), n_listed)) if n_listed else 0
    stop = n_listed if max_entries is None else min(n_listed, start + max(0, int(max_entries)))
    users = users[start:stop]
    page_users = [str(u["user_id"]) for u in users]
    report.page = {"start": start, "end": stop, "listed": n_listed}
    report.listed_users = list(page_users)
    try:
        from credit_review import verify_ledger  # noqa: PLC0415
        db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
        keys = sorted({r["request_id"] for u in users for r in u["rows"]})
        done = {str(k).lower() for k in verify_ledger.blocked_ids(db, keys, CAMPAIGN)} if keys else set()
        # a request a proof-need-ask already named has been told what would change it, in that ask's own words;
        # this note never lands on top of it
        asked = verify_ledger.sent_request_ids(db, NEED_ASK_CAMPAIGN) if keys else set()
        # the reviewer's decision, re-read now for the whole page: the list is as old as the tick's build
        lpath = ledger_path or verify_ledger.DEFAULT_PATH
        stale = moved(lpath, _listed_rows(users))
    except Exception as exc:  # noqa: BLE001 - an unreadable ledger sends nothing
        report.halted = f"the verify ledger is unreadable ({exc}); nothing sent"[:300]
        return report
    live = payloads(users, query or uvn_status.trino, done, asked, report.filtered, stale)
    report.not_found = len(users) - len(live)
    for p in [p for p in live if verify_notify.not_signed(mode, p["user"]["id"])]:
        need_asks._filtered(report.filtered, p["user"]["id"],
                            "not_in_signed_accepted (not in the signed check's accepted set)")
    live = [p for p in live if not verify_notify.not_signed(mode, p["user"]["id"])]
    ps = live[:max_users]
    for p in live[max_users:]:
        need_asks._filtered(report.filtered, p["user"]["id"], f"over --max-users {max_users} (a later batch)")
    if mode == "apply":
        if not uvn_status.POLICY_OK:
            report.halted = f"cap_policy_unreadable: {uvn_status.POLICY_PATH} is missing or malformed; nothing sent"
            report.policy_error = True
            return report
        if CAMPAIGN not in uvn_status.CREDIT_GROUP:
            report.halted = (f"{CAMPAIGN} has no place in the policy's credit group ({uvn_status.POLICY_PATH}); a "
                             "campaign outside the shared daily budget never applies; nothing sent")
            report.policy_error = True
            return report
        if not group_locked:
            report.halted = "the credit-group run lock is not held; nothing sent"
            return report
        left = max(uvn_status.credit_group_left(lpath, datetime.now(timezone.utc).strftime("%Y-%m-%d")), 0)
        if verify_notify.APPLY_ONLY is not None and not verify_notify.APPLY_PAGE and left < len(ps):
            report.cap_short = True
            report.halted = (f"daily_cap_short: {left} left of today's shared credit cap, {len(ps)} signed users in "
                             "this list - a signed list goes whole or not at all; nothing sent")
            for p in ps:
                verify_notify._outcome(report, p, "deferred", "daily_cap_short")
            return report
        for p in ps[left:]:
            verify_notify._outcome(report, p, "deferred", "daily_cap: today's shared credit cap is spent; a later run")
        ps = ps[:left]
    report.candidates = len(ps)
    taken = {str(p["user"]["id"]) for p in ps}
    unexamined = {str(p["user"]["id"]) for p in live} - taken
    report.page["page_end"] = report.page["end"]
    first_open = next((j for j, uid in enumerate(page_users) if uid in unexamined), None)
    if first_open is not None:
        report.page["end"] = report.page["start"] + first_open
    for p in ps:
        p.pop("dropped", None)             # the gate's file carries the user and the credits, nothing else
    def prepare(p: dict[str, Any]) -> Any:
        # WORKER thread, immediately before this person's own gate call: an apply of 100 notes runs for minutes,
        # and the page's re-read above is as old as its first note. Any row that moved holds the WHOLE person -
        # the body the check rendered and the reviewer signed named every row, and the next tick's build lists
        # them again from what the ledger says then. Nothing is claimed, so nothing has to be given back.
        try:
            gone = moved(lpath, _payload_rows(p))
        except RefusalError as exc:
            return verify_notify.Held(halt=f"{exc}; nobody further started")

        def hold() -> None:
            report.deferred_users += 1
            verify_notify._outcome(report, p, "deferred", f"{MOVED}: {len(gone)} of {len(p['credits'])} row(s) "
                                   f"({sorted(set(gone.values()))[0]}); not sent, listed again by the next build")
        return verify_notify.Held(apply=hold) if gone else p

    walk = verify_notify.ApplyPipeline(admit=lambda _p, _n: "go", prepare=prepare, settle=lambda _p, **_k: None,
                                       workers=verify_notify.APPLY_WORKERS)
    verify_notify.send_all(ps, report, mode=mode, wrapper=wrapper, runner=runner, extra=["--campaign", CAMPAIGN],
                           pace_seconds=1.0, preview_dir=preview_dir,
                           check_recipients=check_recipients and mode != "apply", pipeline=walk)
    need_asks._page_ends_at_budget_stop(report, page_users)
    return report


def _main(argv: list[str] | None = None) -> int:   # noqa: C901, PLR0911, PLR0912 - need_asks._main's send rails
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="op", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", required=True)
    b.add_argument("--ledger", default=LEDGER)
    b.add_argument("--paying", default=PAYING)
    s = sub.add_parser("send")
    s.add_argument("--list", required=True)
    s.add_argument("--segment", choices=("paid", "free"), required=True)
    s.add_argument("--mode", choices=("dry-run", "apply"), default="dry-run")
    s.add_argument("--max-users", type=int, default=None)
    s.add_argument("--signed-accepted", default="", metavar="CHECK_JSON")
    s.add_argument("--page", action="store_true")
    s.add_argument("--start-entry", type=int, default=0, metavar="K")
    s.add_argument("--max-entries", type=int, default=None, metavar="N")
    s.add_argument("--preview", default=None)
    s.add_argument("--preview-accepted", default="", metavar="CHECK_JSON")
    s.add_argument("--check-recipients", action="store_true")
    s.add_argument("--outcomes-json", default=None)
    s.add_argument("--apply-budget-s", type=float, default=None, metavar="SECONDS")
    rb = sub.add_parser("readback")
    rb.add_argument("--ledger", default=LEDGER)
    rb.add_argument("--out", default=None)
    a = ap.parse_args(argv)
    if a.op == "readback":
        res = readback(ledger=a.ledger)
        line = json.dumps(res)
        if a.out:
            try:
                fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(line + "\n")
            except OSError as exc:
                print(json.dumps({**res, "verdict": "unmeasured", "why": f"--out is not writable ({exc})"[:200]}))
                return 2
        print(line)
        return {"ok": 0, "stop": 3}.get(res["verdict"], 2)
    verify_notify.set_apply_budget(getattr(a, "apply_budget_s", None))
    if a.op == "build":
        try:
            res = build(ledger=a.ledger, paying_path=a.paying)
        except RefusalError as exc:
            print(f"{LABEL}: nothing listed: {exc}")
            return 2
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=1)
        print(json.dumps({"generated_at": res["generated_at"], "source": res["source"], "counts": res["counts"],
                          "held": {k: {"rows": v["rows"], "users": v["users"]} for k, v in res["held"].items()}}))
        return 0
    if a.preview_accepted:
        if not a.preview or a.mode != "dry-run" or a.check_recipients:
            print(f"{LABEL}: --preview-accepted goes with --preview on a plain --mode dry-run; nothing rendered")
            return 2
        try:
            verify_notify.PREVIEW_ONLY = verify_notify.load_preview_accepted(a.preview_accepted)
            with open(a.list, encoding="utf-8") as fh:
                a.max_users = max(a.max_users or 0, len(json.load(fh).get("users") or []), 1)
        except (OSError, ValueError, TypeError, AttributeError) as exc:
            print(f"{LABEL}: --preview-accepted: {exc}; nothing rendered")
            return 2
    signed = None
    if a.signed_accepted:
        if a.mode != "apply":
            print(f"{LABEL}: --signed-accepted is for --mode apply; nothing sent")
            return 2
        try:
            signed = verify_notify.load_preview_accepted(a.signed_accepted)
            with open(a.signed_accepted, encoding="utf-8") as fh:
                cap = json.load(fh).get("max_users")
        except (OSError, ValueError, TypeError) as exc:
            print(f"{LABEL}: --signed-accepted: {exc}; nothing sent")
            return 2
        if not isinstance(cap, int) or cap < 1:
            print(f"{LABEL}: --signed-accepted: {a.signed_accepted} records no attempt cap (max_users); nothing sent")
            return 2
        if not a.page:
            print(f"{LABEL}: --signed-accepted goes with --page here (the tick's paged apply); nothing sent")
            return 2
        if a.max_users is None:
            a.max_users = cap
        verify_notify.APPLY_ONLY = signed
        verify_notify.APPLY_PAGE = True
    if a.max_users is None:
        a.max_users = 25
    if a.check_recipients and a.mode == "apply":
        print(f"{LABEL}: --check-recipients is a dry-run check; nothing sent")
        return 2
    if a.mode == "apply" and signed is None:
        # the same rail the tick walks: nobody is sent a note the read-only check did not accept first
        print(f"{LABEL}: an apply needs --signed-accepted (this run's own --check-recipients outcomes); nothing sent")
        return 2
    if a.preview:
        Path(a.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = ""
    if a.outcomes_json:
        try:
            fd, tmp = tempfile.mkstemp(prefix=".outcomes-", dir=os.path.dirname(os.path.abspath(a.outcomes_json)))
            os.close(fd)
        except OSError as exc:
            print(f"{LABEL}: --outcomes-json {a.outcomes_json} is not writable ({exc}); nothing sent")
            return 2
    kw = dict(list_path=a.list, segment=a.segment, mode=a.mode, max_users=a.max_users, preview_dir=a.preview,
              check_recipients=a.check_recipients, max_entries=a.max_entries, start_entry=a.start_entry)
    try:
        if a.mode == "apply":
            try:
                with verify_notify.apply_session():
                    rep = send(**kw)
            except verify_notify.ApplyLockError as exc:
                print(f"{LABEL}: {exc}")
                return 3
        else:
            rep = send(**kw)
    except RefusalError as exc:
        if tmp:
            Path(tmp).unlink(missing_ok=True)
        print(f"{LABEL}: nothing listed or sent: {exc}")
        return 2
    acc = need_asks.accounting(rep)
    if tmp:
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"mode": a.mode, "segment": a.segment, "check_recipients": a.check_recipients, **acc,
                           "accepted": list(rep.accepted), "sent": list(getattr(rep, "sent", [])),
                           "outcomes": list(rep.outcomes), "filtered": list(rep.filtered),
                           "deployed": verify_notify.deployed_head() or None,
                           "signed_on": verify_notify.LIST_SIGNED_ON or None,
                           "max_users": a.max_users, "page": getattr(rep, "page", None) or None}, fh)
            os.replace(tmp, a.outcomes_json)
        except OSError as exc:
            rep.failures.append(f"outcomes file not written: {exc}"[:200])
            rep.failed_users += 1
            Path(tmp).unlink(missing_ok=True)
    print(json.dumps({"campaign": CAMPAIGN, "halted": rep.halted, "candidates": rep.candidates,
                      "not_found": rep.not_found, "validated": rep.validated,
                      "would_send": getattr(rep, "recipient_ok", 0), **acc, "sent": rep.sent_notes,
                      "deferred": rep.deferred_users, "refused": rep.refused_users, "failed": rep.failed_users,
                      "refusals": rep.refusals[:10], "failures": rep.failures[:10]}))
    if a.check_recipients and not acc["balanced"]:
        return 3
    if getattr(rep, "policy_error", False):
        return 2
    if getattr(rep, "cap_short", False):
        return 3
    if rep.halted or rep.failed_users:
        return 1
    if signed is not None:
        bad = verify_notify.signed_set_mismatch(verify_notify.APPLY_REPORTS or [rep], signed, page=a.page)
        if bad:
            print(f"{LABEL}: {bad}")
            return 3
    return 3 if verify_notify.HEAD_REFUSED else 0


if __name__ == "__main__":
    sys.exit(_main())
