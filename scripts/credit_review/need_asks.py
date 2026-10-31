#!/usr/bin/env python3
"""L11c per-need asks: the audience and the sender path (proof-loop captain card L11c; p1 rulings 096/098,
captain-1028-213x (c)). Every send goes through intercom-verify-request.sh --campaign proof-need-ask, which owns the
copy, the lock (PROOF_NEED_ASK_COPY_APPROVED), the go-live guards and the send-time comm_state read; this module
only decides WHO is listed and WHICH document each ask names.

  build: one row per (user, request) whose LATEST doc-verify outcome is `unverifiable` with a sendable need code,
         for a request still pending on the replica, joined to the proof_intake row of that document (its arrival
         time, kind and filing conversation). Sendable codes (p1 ruling 098):
           readable_document, counterparty_signed_or_registered.
         Out of the audience: distributor_dashboard_with_code (no challenge-code issuer until b1's F9 lands) and
         issuer_email_from_official_domain (verify@ is off; the gate would hold it anyway). Counted, not listed.
  send:  one ask per user per run (the oldest document first), paid first, --max-users bounded, dry-run by default;
         a real run halts before any gate call while the gate's lock is 0.

CLI:  need_asks.py build --out FILE
      need_asks.py send --list FILE --segment paid|free [--mode dry-run|apply] [--max-users N] [--preview DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import comm_state, receipts, uvn_status, verify_notify  # noqa: E402

CAMPAIGN = "proof-need-ask"
LOCK = "PROOF_NEED_ASK_COPY_APPROVED"
SENDABLE = ("readable_document", "counterparty_signed_or_registered")
NOT_YET = {"distributor_dashboard_with_code": "no_code_issuer", "issuer_email_from_official_domain": "verify_at_off"}
DV_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"
PAYING = "/var/lib/credit-trust/paying-users.json"
PENDING = ("user_verification_needed", "unverified")


class NeedError(RuntimeError):
    pass



MAX_DOC_GROUP = 20      # QA #1418: the most documents one per-need ask may name (the gate's MAX_DOC_GROUP)

def doc_kind(mime: str) -> str:
    m = (mime or "").lower()
    return "image" if m.startswith("image/") else "PDF" if m == "application/pdf" else "document"


def latest_outcomes(dv_store: str) -> dict[tuple[int, str, str], tuple[str, str, str]]:
    """{(user, request, document): (outcome, need, proof_id)} from each (request, DOCUMENT)'s LATEST doc-verify row.
    QA #1418: keyed per document - a later verified read of document B never hides document A's open need."""
    try:
        db = sqlite3.connect(f"file:{dv_store}?mode=ro", uri=True)
        cols = {r[1] for r in db.execute("PRAGMA table_info(dv_outcomes)")}
        # QA #1418 round 7: pair the read with the intake it READ (dv_outcomes.intake_id, written by the doc-verify
        # runner), never with a later re-upload of the same file
        iid = "coalesce(intake_id, '')" if "intake_id" in cols else "''"
        rows = db.execute(f"SELECT user_id, lower(request_id), outcome, coalesce(need, ''), proof_id, at, id, {iid} "
                          "FROM dv_outcomes WHERE user_id IS NOT NULL ORDER BY at, id").fetchall()
    except sqlite3.Error as exc:
        raise NeedError(f"doc-verify store unreadable: {exc}") from exc
    out: dict[tuple[int, str, str], tuple[str, str, str]] = {}
    for uid, rid, outcome, need, proof_id, _at, _id, intake_id in rows:
        out[(int(uid), rid, str(proof_id))] = (outcome, need, intake_id or proof_id)
    return out


NEED_ORDER = ("counterparty_signed_or_registered", "readable_document")   # Fable [key=l11c-plural] (d): counterparty first


def tray_outcomes(tray_path: str) -> tuple[dict[tuple[int, str, str], tuple[str, str, str]],
                                          dict[tuple[int, str, str], str], set[int], int]:
    """b1's L11c tray (doc-verify-build-b1 trays/l11c-asks-*.json; Fable [key=l11c-plural]: the source of truth):
    rows[need][paid|free] = [{request_id, user_id, outcome, proof, intake_id}]. Returns the outcomes in
    latest_outcomes' shape (keyed by intake id, not sha), the intake id per (user, request), the paid users, and how
    many listed requests are carried pre-T0 rows (pre_t0_carried: askable, p1 160 / b1 161; reported, not filtered)."""
    try:
        with open(tray_path, encoding="utf-8") as fh:
            doc = json.load(fh)
        rows = doc["rows"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise NeedError(f"tray unreadable: {exc}") from exc
    out: dict[tuple[int, str, str], tuple[str, str, str]] = {}
    intake: dict[tuple[int, str, str], str] = {}
    paid: set[int] = set()
    carried: set[tuple[int, str]] = set()
    for need, segs in rows.items():
        for seg, items in (segs or {}).items():
            for r in items or []:
                # carried pre-T0 rows ARE dv-3 rows and askable (p1 160, b1 161 - b1's earlier hold withdrawn); counted only
                if r.get("pre_t0_carried") is True:
                    carried.add((int(r["user_id"]), str(r["request_id"]).lower()))
                uid, rid, iid = int(r["user_id"]), str(r["request_id"]).lower(), str(r.get("intake_id") or "")
                out[(uid, rid, iid)] = (str(r.get("outcome") or ""), need, iid)     # per DOCUMENT (QA #1418)
                intake[(uid, rid, iid)] = iid
                if seg == "paid":
                    paid.add(uid)
    return out, intake, paid, len(carried)


def build(*, dv_store: str = DV_STORE, proof_store: str = PROOF_STORE, paying_path: str = PAYING,
          query: uvn_status.Query | None = None, now: datetime | None = None, tray: str | None = None) -> dict[str, Any]:
    counts: Counter[str] = Counter()
    tray_paid: set[int] | None = None
    if tray:
        outcomes, _ids, tray_paid, n_carried = tray_outcomes(tray)
        counts["listed_pre_t0_carried"] = n_carried
    else:
        outcomes = latest_outcomes(dv_store)
    try:
        pdb = sqlite3.connect(f"file:{proof_store}?mode=ro", uri=True)
        intake: dict[tuple[int, str], tuple[str, str, str, str, str, str]] = {}
        arrivals: dict[int, list[str]] = {}         # every intake arrival per user (comm_state's newer-intake rule)
        for u, sha, rec, mime, conv, iid, mb in pdb.execute(
                "SELECT user_id, file_sha256, received_at, mime, conversation_id, intake_id, coalesce(matched_by, '') "
                "FROM proof_intake"):
            v = (rec, mime or "", str(conv or ""), sha, str(mb), str(iid or ""))
            # by sha: the EARLIEST arrival of that file (the one that was read); a later same-file intake is then
            # 'anything newer' at send (comm_state) and holds the ask - QA #1418 round 7
            if (int(u), sha) not in intake or rec < intake[(int(u), sha)][0]:
                intake[(int(u), sha)] = v
            intake[(int(u), str(iid))] = v          # the tray and dv_outcomes.intake_id name the document by intake id
            arrivals.setdefault(int(u), []).append([rec, str(iid or "")])     # (time, intake): QA #1513
        with open(paying_path, encoding="utf-8") as fh:
            paying = {int(x) for x in (json.load(fh).get("ids") or [])}
    except (sqlite3.Error, OSError, ValueError) as exc:
        raise NeedError(f"input unreadable: {exc}") from exc
    cands: dict[int, list[dict[str, Any]]] = {}
    for (uid, rid, _doc), (outcome, need, sha) in outcomes.items():
        if outcome != "unverifiable" or not need:
            continue
        if need in NOT_YET:
            counts[f"skip_{NOT_YET[need]}"] += 1
            continue
        if need not in SENDABLE:
            counts["skip_unknown_need"] += 1
            continue
        doc = intake.get((uid, sha))
        if not doc:
            counts["skip_no_intake_row"] += 1
            continue
        # an email-filed document (support@: no Intercom conversation) gets the ask by Intercom email to the account's
        # Intercom user (proof-loop-lead-fable-p1 152); the gate takes "email" for the per-need ask only
        conv = doc[2] if doc[2].isdigit() else "email"
        if conv == "email":
            # l1 [key=l11c-email-filed]: only when the filing was matched to the account by a strong identity (the
            # sender IS the account: professional id / authenticated email / session); anything else -> tray
            if doc[4] not in receipts.STRONG_MATCH:
                counts["skip_email_filed_weak_identity"] += 1
                continue
            counts["email_filed_rows"] += 1
        cands.setdefault(uid, []).append({"request_id": rid, "need": need, "doc_sha": doc[3], "doc_received_at": doc[0],
                                          "doc_kind": doc_kind(doc[1]), "filing_conversation": conv, "matched_by": doc[4],
                                          "intake_id": doc[5]})
    pend = uvn_status.uvn_requests(sorted(cands), query or uvn_status.trino, PENDING) if cands else {}
    users: list[dict[str, Any]] = []
    for uid, rows in cands.items():
        live = {r["request_id"].lower() for r in pend.get(uid, []) if not r["_incomplete"]}
        rows = sorted((r for r in rows if r["request_id"] in live), key=lambda r: r["doc_received_at"])
        if not rows:
            counts["skip_not_pending"] += 1
            continue
        is_paid = uid in (tray_paid if tray_paid is not None else paying)
        users.append({"user_id": str(uid), "paid": is_paid, "asks": rows, "arrivals": sorted(arrivals.get(uid, []))})
        counts[f"list_{'paid' if is_paid else 'free'}"] += 1
        counts["list_requests"] += len(rows)
    users.sort(key=lambda u: (not u["paid"], u["asks"][0]["doc_received_at"]))
    return {"generated_at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"),
            "users": users, "counts": dict(counts)}


def core_proof_requested(rids: list[str], query: uvn_status.Query) -> set[str]:
    """The requests core itself sent its generic proof request on (metadata.proofRequest). p1 178: that is NOT an
    earlier L11c ask (L11c is the specific follow-up after we read their reply); it is recorded on the ledger row as
    ask_class=core_proof_request for the audit. The 7-day gate (core_notice) still applies."""
    ids = sorted({r.lower() for r in rids if re.fullmatch(r"[0-9a-fA-F-]{36}", r)})
    out: set[str] = set()
    for i in range(0, len(ids), 200):
        chunk = ",".join(f"'{r}'" for r in ids[i:i + 200])
        for row in query("SELECT lower(CAST(id AS varchar)), CAST(json_extract(metadata, '$.proofRequest') IS NOT NULL AS varchar) "
                         f"FROM postgresql_core.public.credit_requests WHERE lower(CAST(id AS varchar)) IN ({chunk}) "
                         "AND /* core_proof_request */ 1 = 1"):
            if len(row) >= 2 and str(row[1]).lower() == "true":
                out.add(str(row[0]).lower())
    return out


def payloads(users: list[dict[str, Any]], query: uvn_status.Query, asked: set[str] | None = None,
             held_out: list[str] | None = None) -> list[dict[str, Any]]:
    """ONE gate payload per user (Fable [key=l11c-plural]): the first need group, counterparty first, that still has
    pending requests nobody asked about. The unit is (user, DOCUMENT) (p1 156): the message is about the documents of
    that need sent on the NEWEST day in one filing thread (named by kind + date in the copy, Fable 166) and names
    EVERY pending, not-yet-asked request of THOSE documents (re-read against the replica now). Other documents and the other need wait: the gate's 7-day rule defers
    them to a later run."""
    asked = {a.lower() for a in (asked or set())}
    held: list[str] = held_out if held_out is not None else []
    uids = [int(u["user_id"]) for u in users]
    accts = uvn_status.accounts_of(uids, query)
    pend = uvn_status.uvn_requests(uids, query, PENDING)
    out = []
    for u in users:
        uid = int(u["user_id"])
        acct = accts.get(uid)
        if not acct or not acct.get("email"):
            continue
        rows = {r["request_id"].lower(): r for r in pend.get(uid, []) if not r["_incomplete"]}
        for need in NEED_ORDER:
            cand = [a for a in u["asks"] if a["need"] == need and a["request_id"].lower() in rows
                    and a["request_id"].lower() not in asked]
            if not cand:
                continue
            newest = max(cand, key=lambda a: (a["doc_received_at"], a["doc_sha"]))
            # Fable 166: the documents of this need sent on the NEWEST day, in the same filing thread ("the documents
            # you sent on {date}" when several); older documents wait for a later run. A request with several such
            # documents is named once, on its newest one (that is its doc_map entry).
            # QA #1418: EVERY document of that day + thread is part of this ask (doc_count / doc_shas / doc_intakes) -
            # two same-day documents for one request are both named by the count and both covered by the
            # once-per-request lock; only the displayed request (credits / doc_map) is deduplicated
            docs, group, seen = [], [], set()
            for a in sorted(cand, key=lambda a: (a["doc_received_at"], a["doc_sha"]), reverse=True):
                if a["doc_received_at"][:10] != newest["doc_received_at"][:10] \
                        or a["filing_conversation"] != newest["filing_conversation"]:
                    continue
                docs.append(a)
                rid = a["request_id"].lower()
                if rid not in seen:
                    seen.add(rid)
                    group.append(a)
            # QA #1418 (03:1xZ): judged AFTER the group is built, on the GROUP's intakes only - exactly the set the send
            # names. A same-second document in ANOTHER conversation is then newer here too (builder == send).
            # QA #1418: the SAME rule the send applies (comm_state.newer_intake): a need whose newest document is older
            # than any intake of this user would be held at send - skip it here, so the batch reaches the need that
            # CAN go (never a held ask retried every run). Rows built before 'arrivals' existed are not filtered.
            if comm_state.newer_intake(newest["doc_received_at"], u.get("arrivals") or [],
                                       {str(a.get("intake_id") or "") for a in docs if a.get("intake_id")}):
                held.append(f"user {uid}: {need} (an intake newer than its newest document)")
                continue
            group.reverse()
            n_docs = len({a["doc_sha"] for a in docs})
            if n_docs > MAX_DOC_GROUP:
                # QA #1418 (08:36Z): the gate refuses a group larger than it checks; list it here, never a batch slot
                held.append(f"user {uid}: {need} ({n_docs} documents in one group > {MAX_DOC_GROUP}: for a person)")
                continue
            credits = [{k: v for k, v in rows[a["request_id"].lower()].items() if not k.startswith("_")} for a in group]
            core_asked = core_proof_requested([c["request_id"] for c in credits], query)
            for c in credits:
                c["ask_class"] = "core_proof_request" if c["request_id"].lower() in core_asked else "asked"
            out.append({"user": {"email": acct["email"], "id": str(uid), "professional_id": acct["professional_id"],
                                 "auth_id": acct["auth_id"], "first_name": acct.get("first_name", ""),
                                 "filing_conversation": newest["filing_conversation"]},
                        "credits": credits,
                        "need": {"code": need, "doc_sha": newest["doc_sha"], "doc_received_at": newest["doc_received_at"],
                                 "doc_kind": newest["doc_kind"], "doc_count": n_docs,
                                 "doc_shas": sorted({a["doc_sha"] for a in docs}),
                                 "doc_map": {a["request_id"]: a["doc_sha"] for a in group},
                                 # QA #1418: the INTAKE each named document was read from (the gate checks that row)
                                 "doc_intakes": {a["doc_sha"]: a.get("intake_id", "") for a in docs if a.get("intake_id")}}})
            break
    return out


def send(*, list_path: str, segment: str, mode: str = "dry-run", max_users: int = 25, preview_dir: str | None = None,
         query: uvn_status.Query | None = None, wrapper: str = verify_notify.WRAPPER,
         runner: verify_notify.Runner = verify_notify._run, ledger_path: str | None = None) -> verify_notify.Report:
    report = verify_notify.Report()
    if mode == "apply" and not uvn_status.campaign_lock_open(wrapper, LOCK):
        report.halted = f"{CAMPAIGN} is send-locked in the gate ({LOCK}=0); nothing sent (dry-run renders it)"
        return report
    with open(list_path, encoding="utf-8") as fh:
        users = [u for u in json.load(fh)["users"] if u["paid"] == (segment == "paid")]
    try:
        from credit_review import verify_ledger  # noqa: PLC0415
        db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
        keys = sorted({a["request_id"] for u in users for a in u["asks"]})
        asked = set(verify_ledger.blocked_ids(db, keys, CAMPAIGN)) if keys else set()
    except Exception as exc:  # noqa: BLE001 - an unreadable ledger sends nothing
        report.halted = f"the verify ledger is unreadable ({exc}); nothing sent"[:300]
        return report
    # the bound applies AFTER the ledger (QA #1418): a user whose every ask is already handled never takes a batch
    # slot, so repeated bounded runs keep reaching new users instead of re-selecting the first max_users forever
    users = [u for u in users if any(a["request_id"] not in asked for a in u["asks"])]
    # ... and AFTER the live re-read too (QA #1418): payloads() drops users whose requests resolved or who have no
    # deliverable account; only then is the batch bounded, so a stale first page never consumes every slot
    held: list[str] = []
    live = payloads(users, query or uvn_status.trino, asked, held)
    report.held_newer = held        # needs the send would hold (comm_state.newer_intake): listed, never retried
    report.not_found = len(users) - len(live)
    ps = live[:max_users]
    report.candidates = len(ps)
    verify_notify.send_all(ps, report, mode=mode, wrapper=wrapper, runner=runner, extra=["--campaign", CAMPAIGN],
                           pace_seconds=1.0, preview_dir=preview_dir)
    return report


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="op", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", required=True)
    b.add_argument("--tray", default=None, help="b1's L11c tray JSON (the source of truth, Fable [key=l11c-plural])")
    s = sub.add_parser("send")
    s.add_argument("--list", required=True)
    s.add_argument("--segment", choices=("paid", "free"), required=True)
    s.add_argument("--mode", choices=("dry-run", "apply"), default="dry-run")
    s.add_argument("--max-users", type=int, default=25)
    s.add_argument("--preview", default=None)
    a = ap.parse_args(argv)
    try:
        if a.op == "build":
            res = build(tray=a.tray)
            fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(res, fh, indent=1)
            print(json.dumps({"generated_at": res["generated_at"], "counts": res["counts"]}))
            return 0
        if a.preview:
            Path(a.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
        rep = send(list_path=a.list, segment=a.segment, mode=a.mode, max_users=a.max_users, preview_dir=a.preview)
    except NeedError as exc:
        print(f"NEED ASKS: nothing listed or sent: {exc}")
        return 2
    print(json.dumps({"halted": rep.halted, "candidates": rep.candidates, "not_found": rep.not_found,
                      "validated": rep.validated, "sent": rep.sent_notes, "deferred": rep.deferred_users,
                      "refused": rep.refused_users, "failed": rep.failed_users, "refusals": rep.refusals[:10],
                      "held_newer_intake": len(getattr(rep, "held_newer", [])),
                      "held_newer_examples": getattr(rep, "held_newer", [])[:10],
                      "failures": rep.failures[:10]}))
    return 1 if rep.halted or rep.failed_users else 0


if __name__ == "__main__":
    sys.exit(_main())
