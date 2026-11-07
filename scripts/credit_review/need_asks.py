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
import dataclasses
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import comm_state, receipts, uvn_status, verify_notify  # noqa: E402

CAMPAIGN = "proof-need-ask"
LOCK = "PROOF_NEED_ASK_COPY_APPROVED"
DISTRIBUTOR = "distributor_dashboard_with_code"
# distributor: captain-approved 2026-10-29 19:0xZ (p1 208); F9 challenge codes issued at send (credit-doc-verify.py)
SENDABLE = ("readable_document", "counterparty_signed_or_registered", DISTRIBUTOR)
NOT_YET = {"issuer_email_from_official_domain": "verify_at_off"}
DOC_VERIFY_CLI = os.environ.get("NEED_ASKS_DOC_VERIFY_CLI", "/opt/hydra/scripts/credit-doc-verify.py")
CODE_PLACEHOLDER = "MUSO-XXXX"          # dry-run previews: the code is masked, nothing is issued
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


NEED_ORDER = ("counterparty_signed_or_registered", "readable_document", DISTRIBUTOR)   # Fable [key=l11c-plural] (d): counterparty first


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


STALE_FILING_DAYS = 180


def stale_filing(received: Any, now: datetime) -> bool:
    """The document was sent more than STALE_FILING_DAYS before `now` (the gate's e_stale_filing, same day-granular rule).
    An unreadable date is not stale here (the gate's need-shape check refuses it)."""
    try:
        d = datetime.strptime(str(received or "")[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return False
    today = now.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    return (today - d).days > STALE_FILING_DAYS


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
    waits: list[dict[str, Any]] = []
    t_now = now or datetime.now(timezone.utc)
    for uid, rows in cands.items():
        live = {r["request_id"].lower() for r in pend.get(uid, []) if not r["_incomplete"]}
        rows = sorted((r for r in rows if r["request_id"] in live), key=lambda r: r["doc_received_at"])
        is_paid = uid in (tray_paid if tray_paid is not None else paying)
        # fable-copy-1030-r5/l2 (1) / p1 552: a document older than STALE_FILING_DAYS is NOT asked about by the automated
        # line - the row WAITS for a human (wait:stale_filing, due_at = a day out), listed, never silently dropped
        fresh = []
        for r in rows:
            if stale_filing(r.get("doc_received_at"), t_now):
                waits.append({"user_id": str(uid), "paid": is_paid, "request_id": r["request_id"], "reason": "wait:stale_filing",
                              "doc_received_at": r.get("doc_received_at"),
                              "due_at": (t_now + timedelta(days=1)).isoformat(timespec="seconds")})
                counts["wait_stale_filing"] += 1
            else:
                fresh.append(r)
        rows = fresh
        if not rows:
            counts["skip_not_pending"] += 1
            continue
        users.append({"user_id": str(uid), "paid": is_paid, "asks": rows, "arrivals": sorted(arrivals.get(uid, []))})
        counts[f"list_{'paid' if is_paid else 'free'}"] += 1
        counts["list_requests"] += len(rows)
    users.sort(key=lambda u: (not u["paid"], u["asks"][0]["doc_received_at"]))
    facts = replica_facts(query or uvn_status.trino) if users else {}
    for u in users:
        u["facts"] = facts_of(u, facts)
    return {"generated_at": (now or datetime.now(timezone.utc)).isoformat(timespec="seconds"),
            "replica_facts": facts_header(users), "users": users, "counts": dict(counts), "waits": waits,
            "signed_on": verify_notify.deployed_head()}


# r5 #1582 (c): an E list carries the SAME signing header as owing_proof's - the exact runnable SQL, its sha256, and a
# sha256 over every listed user's per-request facts (request id, core status, proof_required) as read at build time;
# `verify-facts` re-runs THIS string at signing and names every user whose facts changed (they are out of the batch)
FACTS_SQL = ("SELECT CAST(cr.userid AS varchar), lower(CAST(cr.id AS varchar)), cr.status, "
             "CAST(coalesce(CAST(json_extract(cr.verificationdata, '$.proof_required') AS boolean), false) AS varchar) "
             "FROM postgresql_core.public.credit_requests cr WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL "
             "AND cr.status NOT IN ('approved', 'rejected')")


def replica_facts(query: uvn_status.Query) -> dict[str, list[str]]:
    rows = query(FACTS_SQL)
    if any(len(r) != 4 or not str(r[0]).isdigit() for r in rows):
        raise NeedError("unexpected replica facts row shape")
    # QA #1582: the OWNER is part of the fact - a request that moved to another user is a change
    return {str(r[1]).lower(): [str(r[1]).lower(), str(r[2]), str(r[3]).lower(), str(r[0])] for r in rows}


def facts_of(u: dict[str, Any], facts: dict[str, list[str]]) -> list[list[str]]:
    rids = sorted({str(a["request_id"]).lower() for a in u["asks"]})
    return [facts.get(r, [r, "gone", "", ""]) for r in rids]


def facts_header(users: list[dict[str, Any]]) -> dict[str, str]:
    blob = json.dumps(sorted([u["user_id"], u.get("facts")] for u in users), separators=(",", ":"))
    return {"query": FACTS_SQL, "query_sha256": hashlib.sha256(FACTS_SQL.encode()).hexdigest(),
            "sha256": hashlib.sha256(blob.encode()).hexdigest()}


def verify_facts(lst: dict[str, Any], query: uvn_status.Query) -> list[str]:
    """Re-read the replica for a built E list (the signing rule): a header that no longer matches the listed facts (the
    list was edited) and every user whose facts changed since the build. Empty = signable as built."""
    diffs = []
    users = lst.get("users") or []
    head = lst.get("replica_facts") or {}
    if head.get("query") != FACTS_SQL or head.get("sha256") != facts_header(users)["sha256"]:
        diffs.append("header: replica_facts does not match the listed facts or the query (the list changed after its build)")
    now = replica_facts(query)
    for u in users:
        cur = facts_of(u, now)
        if cur != u.get("facts"):
            diffs.append(f"{u['user_id']}: listed {u.get('facts')} -> now {cur}")
    return diffs


# throughput (firstmate 651, measured on node-8 01:0xZ 11-02): `lower(CAST(id AS varchar)) IN (...)` cannot be pushed down
# to Postgres, so every call was a ~14 s full scan of credit_requests (once PER USER in payloads(): ~14 s/user). A typed
# `id IN (UUID '...')` predicate is pushed down: ~2 s for up to 200 ids, same rows. Above ~256 values Trino compacts the
# domain and the pushdown is lost (400 ids measured 14 s), so chunks stay at 200. Only canonical 8-4-4-4-12 hex ids are
# ever quoted (a UUID literal that does not parse would fail the whole query).
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
UUID_CHUNK = 200


def core_proof_requested(rids: list[str], query: uvn_status.Query) -> set[str]:
    """The requests core itself sent its generic proof request on (metadata.proofRequest). p1 178: that is NOT an
    earlier L11c ask (L11c is the specific follow-up after we read their reply); it is recorded on the ledger row as
    ask_class=core_proof_request for the audit. The 7-day gate (core_notice) still applies."""
    ids = sorted({r.lower() for r in rids if UUID_RE.fullmatch(r)})
    out: set[str] = set()
    for i in range(0, len(ids), UUID_CHUNK):
        chunk = ",".join(f"UUID '{r}'" for r in ids[i:i + UUID_CHUNK])
        for row in query("SELECT lower(CAST(id AS varchar)), CAST(json_extract(metadata, '$.proofRequest') IS NOT NULL AS varchar) "
                         f"FROM postgresql_core.public.credit_requests WHERE id IN ({chunk}) "
                         "AND /* core_proof_request */ 1 = 1"):
            if len(row) >= 2 and str(row[1]).lower() == "true":
                out.add(str(row[0]).lower())
    return out


def payloads(users: list[dict[str, Any]], query: uvn_status.Query, asked: set[str] | None = None,
             held_out: list[str] | None = None, filtered_out: list[dict[str, str]] | None = None) -> list[dict[str, Any]]:
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
            _filtered(filtered_out, uid, "no_deliverable_account")
            continue
        rows = {r["request_id"].lower(): r for r in pend.get(uid, []) if not r["_incomplete"]}
        n_out, n_held = len(out), len(held)
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
            group.reverse()
            if need == DISTRIBUTOR:
                group = group[-1:]          # one F9 code verifies ONE request: one credit per distributor ask
                docs = [a for a in docs if a["request_id"].lower() == group[0]["request_id"].lower()]
            # QA #1418 (03:1xZ) / QA #1513: judged AFTER the group is built (and, for a distributor ask, narrowed to its one
            # request), with the SAME rule the send applies (comm_state.newer_intake over the intakes the MESSAGE
            # NAMES, i.e. exactly need.doc_intakes below): a need whose newest document is older than any intake of this
            # user, or shares its second with an intake the message does not name (another thread's same-second
            # document), would be held at send - skip it here, so the batch reaches the need that CAN go and a held
            # user never takes a --max-users slot run after run. Rows built before 'arrivals' existed are not filtered.
            if comm_state.newer_intake(newest["doc_received_at"], u.get("arrivals") or [],
                                       {str(a.get("intake_id") or "") for a in docs if a.get("intake_id")}):
                held.append(f"user {uid}: {need} (an intake newer than its newest document)")
                continue
            n_docs = len({a["doc_sha"] for a in docs})
            if n_docs > MAX_DOC_GROUP:
                # QA #1418 (08:36Z): the gate refuses a group larger than it checks; list it here, never a batch slot
                held.append(f"user {uid}: {need} ({n_docs} documents in one group > {MAX_DOC_GROUP}: for a person)")
                continue
            credits = [{k: v for k, v in rows[a["request_id"].lower()].items() if not k.startswith("_")} for a in group]
            for c in credits:
                c["ask_class"] = "asked"        # set below from ONE batched core_proof_requested read for all payloads
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
        if len(out) == n_out:            # QA / r5 #1582: no payload for this user - say why (per user, never a count)
            why = held[-1].split(": ", 1)[1] if len(held) > n_held else "no pending, not-yet-asked request (re-read now)"
            _filtered(filtered_out, uid, why)
    core_asked = core_proof_requested([c["request_id"] for p in out for c in p["credits"]], query)
    for p in out:
        for c in p["credits"]:
            c["ask_class"] = "core_proof_request" if c["request_id"].lower() in core_asked else "asked"
    return out


def _filtered(sink: list[dict[str, str]] | None, uid: Any, reason: str) -> None:
    if sink is not None:
        sink.append({"user": str(uid), "result": "filtered", "reason": reason[:200]})


def issue_code(request_id: str, user_id: str) -> dict[str, str]:
    """F9 (#1476): the request's 7-day challenge code (an active one is returned again) as {code, expires_at}; {} when
    it cannot be issued."""
    try:
        p = subprocess.run([sys.executable, DOC_VERIFY_CLI, "challenge", "issue", "--request", request_id, "--user", str(user_id)],
                           capture_output=True, text=True, timeout=120, check=False)
        got = json.loads(p.stdout or "{}") if p.returncode == 0 else {}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    code = str(got.get("code") or "")
    return ({"code": code, "expires_at": str(got.get("expires_at") or ""), "new": got.get("new") is True}
            if re.fullmatch(r"[A-Z0-9][A-Z0-9-]{3,31}", code) else {})


# the gate's answers that are CONFIRMED pre-POST (verify_notify outcome results): only these void a minted code
PRE_POST_RESULTS = ("deferred", "skipped", "refused", "refused_unledgered")


def void_code(request_id: str, code: str) -> bool:
    """b1 #1527: retire a minted code whose send did not go (a held send after the preflight). True = voided."""
    try:
        p = subprocess.run([sys.executable, DOC_VERIFY_CLI, "challenge", "void", "--request", request_id, "--code", code,
                            "--reason", "held_send"], capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return p.returncode == 0


CODE_WINDOW_MIN = timedelta(days=7) - timedelta(minutes=5)    # a FRESH code: issued seconds before its send (QA #1513)


def with_codes(ps: list[dict[str, Any]], mode: str, report: verify_notify.Report,
               issuer: Any = issue_code, now: datetime | None = None) -> list[dict[str, Any]]:
    """Distributor asks get their F9 code: issued at send (apply), masked placeholder in a dry run (nothing issued).
    A code that cannot be issued drops that ask (nothing sent; noted)."""
    out = []
    for p in ps:
        if p["need"]["code"] != DISTRIBUTOR:
            out.append(p)
            continue
        rid = p["credits"][0]["request_id"]
        got = CODE_PLACEHOLDER if mode != "apply" else issuer(rid, p["user"]["id"])
        code = got.get("code", "") if isinstance(got, dict) else str(got or "")
        if not code:
            report.refusals.append(f"distributor_code_not_issued:{rid}")
            continue
        # QA #1513: an ACTIVE code is returned again; one issued for an earlier attempt that the gate then held may have
        # less than the promised 7 days left - never send it (it expires, then the next run draws a fresh one)
        # QA #1513: the copy promises 7 days, so only a code issued NOW for this send goes; an earlier attempt's still-
        # active code (returned again by 'challenge issue') is never re-sent - it lapses, then the next run gets a fresh one
        if isinstance(got, dict) and got.get("new") is False:
            # counted as a deferral, never a silent drop (QA #1513): the run's report shows it
            report.deferred_users += 1
            report.refusals.append(f"distributor_code_not_fresh:{rid}")
            continue
        if isinstance(got, dict) and got.get("expires_at"):
            try:
                left = datetime.fromisoformat(got["expires_at"].replace("Z", "+00:00")) - (now or datetime.now(timezone.utc))
            except ValueError:
                left = timedelta(0)
            if left < CODE_WINDOW_MIN:
                report.refusals.append(f"distributor_code_window_short:{rid}")
                continue
        out.append({**p, "need": {**p["need"], "verify_code": code}})
    return out


_GROUP_LOCKED: dict[str, bool] = {}


def send(*, mode: str = "dry-run", ledger_path: str | None = None, **kw: Any) -> verify_notify.Report:
    """QA #1617: an apply holds the credit-group run lock (ONE shared budget with every credit campaign, uvn_status's
    runs included) from before the budget read to after the last send; a dry run takes no lock."""
    if mode != "apply" or not uvn_status.campaign_lock_open(kw.get("wrapper", verify_notify.WRAPPER), LOCK):
        return _send(mode=mode, ledger_path=ledger_path, **kw)      # (a send-locked apply halts there, no lock taken)
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
        _GROUP_LOCKED[lpath] = True
        try:
            return _send(mode=mode, ledger_path=ledger_path, **kw)
        finally:
            _GROUP_LOCKED.pop(lpath, None)
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def _page_ends_at_budget_stop(report: verify_notify.Report, page_users: list[str]) -> None:
    """[key=note-step-budget] (QA #1756 Important): the tick's share can end INSIDE the batch - the send loop refuses to
    START a user whose worst case would not fit and records them `deferred / apply_budget`. Those users are already in
    `taken` above (page.end was computed from the batch), so without this clamp the cursor would step PAST them and they
    would wait a whole rotation of the list instead of the next tick. The page ends at the FIRST user the loop deferred,
    which is exactly what the cap stop and `--max-users` already do for the users they never reached."""
    if not getattr(report, "budget_deferred_users", 0):
        return
    deferred = {str(o.get("user")) for o in report.outcomes
                if o.get("result") == "deferred" and str(o.get("reason", "")).startswith("apply_budget")}
    first = next((j for j, uid in enumerate(page_users) if uid in deferred), None)
    if first is not None and report.page["start"] + first < report.page["end"]:
        report.page["end"] = report.page["start"] + first


def _send(*, list_path: str, segment: str, mode: str = "dry-run", max_users: int = 25, preview_dir: str | None = None,
          max_entries: int | None = None, start_entry: int = 0,
         query: uvn_status.Query | None = None, wrapper: str = verify_notify.WRAPPER,
         runner: verify_notify.Runner = verify_notify._run, ledger_path: str | None = None,
         issuer: Any = issue_code, voider: Any = void_code, check_recipients: bool = False) -> verify_notify.Report:
    """r5 RULE (10-31 14:2xZ, after the 14:00Z E batch sent 0/22): a batch is signable ONLY on the live gates' answer -
    check_recipients (dry run) asks the gate's --check-recipient for every user (core notice, comm_state, G1-G5;
    read-only), so the would-send set is known before anyone signs. A plain dry run only renders."""
    report = verify_notify.Report()
    if mode == "apply" and not uvn_status.campaign_lock_open(wrapper, LOCK):
        report.halted = f"{CAMPAIGN} is send-locked in the gate ({LOCK}=0); nothing sent (dry-run renders it)"
        return report
    with open(list_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    verify_notify.bind_list(doc)           # [key=signed-on-sha]: the per-user sha rail reads this header
    users = [u for u in doc["users"] if u["paid"] == (segment == "paid")]
    # r5 639 / p1 638 (the proof-need-ask check ran unpaged for 85+ min): like uvn-status (#1612), a run walks ONE page
    # of this segment's LIST ENTRIES - [start_entry, start_entry + max_entries) - chosen before any ledger or replica
    # read; report.page {start, end, listed} lets the caller (the tick's cursor) start the next run where this one stopped
    n_listed = len(users)
    start = max(0, min(int(start_entry or 0), n_listed)) if n_listed else 0
    stop = n_listed if max_entries is None else min(n_listed, start + max(0, int(max_entries)))
    users = users[start:stop]
    page_users = [str(u["user_id"]) for u in users]
    report.page = {"start": start, "end": stop, "listed": n_listed}
    report.listed_users = [str(u["user_id"]) for u in users]   # QA / r5 #1582: every one is accounted for below
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
    for u in users:
        if not any(a["request_id"] not in asked for a in u["asks"]):
            _filtered(report.filtered, u["user_id"], "already_asked (every ask of this user is in the ledger)")
    users = [u for u in users if any(a["request_id"] not in asked for a in u["asks"])]
    # ... and AFTER the live re-read too (QA #1418): payloads() drops users whose requests resolved or who have no
    # deliverable account; only then is the batch bounded, so a stale first page never consumes every slot
    held: list[str] = []
    live = payloads(users, query or uvn_status.trino, asked, held, report.filtered)
    report.held_newer = held        # needs the send would hold (comm_state.newer_intake): listed, never retried
    report.not_found = len(users) - len(live)
    # QA #1611: a signed apply keeps only the signed accepted users BEFORE the run-size slice, the distributor
    # preflight and the F9 code issuance - an unsigned user takes no slot, no gate call and no code
    for p in [p for p in live if verify_notify.not_signed(mode, p["user"]["id"])]:
        _filtered(report.filtered, p["user"]["id"], "not_in_signed_accepted (not in the signed check's accepted set)")
    live = [p for p in live if not verify_notify.not_signed(mode, p["user"]["id"])]
    ps = live[:max_users]
    for p in live[max_users:]:
        _filtered(report.filtered, p["user"]["id"], f"over --max-users {max_users} (a later batch)")
    # QA #1617 (Critical): proof-need-ask is in the policy's credit group - an apply spends the SAME shared daily budget
    # as every credit campaign, under the same group run lock. A signed, unpaged apply goes whole or not at all (exit 3);
    # otherwise the users past today's room are cap-stopped with a daily_cap outcome each. Unreadable policy = refusal.
    if mode == "apply":
        if not uvn_status.POLICY_OK:
            report.halted = f"cap_policy_unreadable: {uvn_status.POLICY_PATH} is missing or malformed; nothing sent"
            report.policy_error = True
            return report
        lpath = ledger_path or verify_ledger.DEFAULT_PATH
        if not _GROUP_LOCKED.get(lpath):    # send() takes the group lock for the whole apply (below)
            report.halted = "the credit-group run lock is not held; nothing sent"
            return report
        left = max(uvn_status.credit_group_left(lpath, datetime.now(timezone.utc).strftime("%Y-%m-%d")), 0)
        if verify_notify.APPLY_ONLY is not None and not verify_notify.APPLY_PAGE and left < len(ps):
            report.cap_short = True
            report.halted = (f"daily_cap_short: {left} left of today's shared credit cap, {len(ps)} signed users in this "
                             "list - a signed list goes whole or not at all; nothing sent")
            for p in ps:
                verify_notify._outcome(report, p, "deferred", "daily_cap_short")
            return report
        for p in ps[left:]:
            verify_notify._outcome(report, p, "deferred", "daily_cap: today's shared credit cap is spent; a later run")
        ps = ps[:left]
    report.candidates = len(ps)
    # page.end = the first page entry this run will NOT examine (past --max-users, or past today's room), so the next
    # run starts exactly there (never past entries a capped run never reached); page_end = where the page itself ends
    taken = {str(p["user"]["id"]) for p in ps}
    unexamined = {str(p["user"]["id"]) for p in live} - taken
    report.page["page_end"] = report.page["end"]
    first_open = next((j for j, uid in enumerate(page_users) if uid in unexamined), None)
    if first_open is not None:
        report.page["end"] = report.page["start"] + first_open
    # QA #1513: a distributor ask's F9 code is issued for THAT payload immediately before its own gate call (never a
    # whole batch of codes up front), and a reused active code must still have the promised 7 days (with_codes)
    plain = [p for p in ps if p["need"]["code"] != DISTRIBUTOR]
    verify_notify.send_all(plain, report, mode=mode, wrapper=wrapper, runner=runner, extra=["--campaign", CAMPAIGN],
                           pace_seconds=1.0, preview_dir=preview_dir,
                           check_recipients=check_recipients and mode != "apply")
    for j, p in enumerate(ps):
        if p["need"]["code"] != DISTRIBUTOR:
            continue
        # QA #1756 Important: the budget guard must run BEFORE the code is minted, not only inside the send loop.
        # with_codes() issues the F9 code for this payload, so a distributor user reaching here after the shared share
        # was spent got a code minted for a note that was then deferred - a code issued for nothing. Ask the send
        # loop's own predicate first, and defer this user and every distributor behind them exactly as the loop does.
        if mode == "apply" and verify_notify.budget_exhausted():
            _defer_distributors_from(ps, j, report)
            break
        if mode == "apply" and not preflight_ok(p, report, wrapper, runner):
            continue                         # QA #1513: the gate would not send it now -> no code is minted
        # QA #1756 Important 2 (r12): the guard above runs BEFORE the preflight, and the preflight is a real gate call
        # (up to ~20s). With 200-219s left the guard passed, the preflight ate the margin, and with_codes() minted an
        # F9 code for a note the send loop then deferred - a code issued for nothing, and if retiring it failed the
        # next tick saw a non-fresh active code and held the user until it expired. Re-ask the loop's own predicate
        # IMMEDIATELY before minting: the preflight is the only work between the two reads.
        if mode == "apply" and verify_notify.budget_exhausted():
            _defer_distributors_from(ps, j, report)
            break
        coded = with_codes([p], mode, report, issuer)
        before, n_out = report.sent_notes, len(report.outcomes)
        verify_notify.send_all(coded, report, mode=mode, wrapper=wrapper, runner=runner,
                               extra=["--campaign", CAMPAIGN], pace_seconds=1.0, preview_dir=preview_dir,
                           check_recipients=check_recipients and mode != "apply")
        if mode == "apply" and coded and report.sent_notes == before:
            rid, code = coded[0]["credits"][0]["request_id"], coded[0]["need"]["verify_code"]
            new = report.outcomes[n_out:]
            result = new[-1]["result"] if len(new) == 1 else ""
            if result in PRE_POST_RESULTS:
                # the gate held or refused it BEFORE any POST, after the code was minted (a change since the
                # preflight): retire the code so the next run issues a fresh one (b1 #1527); a failed void is reported
                report.refusals.append(f"distributor_code_{'voided' if voider(rid, code) else 'void_failed'}:{rid}")
            else:
                # r5 (QA #1513): a failure / ambiguous result may have reached the POST - the code is NEVER voided on it
                # (the user may hold it); it lapses on its own and is reported
                report.refusals.append(f"distributor_code_kept_ambiguous:{rid}")
    # QA #1756 Important: the clamp runs AFTER the distributor phase, not between the two phases. A distributor user
    # deferred on the budget is in `taken` (page.end was computed from the whole batch), so clamping only after the
    # plain batch let the cursor step PAST them and they waited a whole rotation instead of the next tick.
    _page_ends_at_budget_stop(report, page_users)
    return report


def _defer_distributors_from(ps: list[dict[str, Any]], j: int, report: verify_notify.Report) -> None:
    """Defer this distributor and every distributor behind them on the spent apply budget, exactly as the send loop
    would (QA #1756): the loop's own predicate is the authority, and a user it would not start must not have a code
    minted for them either."""
    for rest in ps[j:]:
        if rest["need"]["code"] != DISTRIBUTOR:
            continue
        report.deferred_users += 1
        report.budget_deferred_users += 1
        verify_notify._outcome(report, rest, "deferred",
                               "apply_budget: the run's share is spent and one note can cost up to "
                               f"{verify_notify.WORST_USER_S:.0f}s; not started, stays owed for the next tick")


def preflight_ok(p: dict[str, Any], report: verify_notify.Report, wrapper: str, runner: verify_notify.Runner) -> bool:
    """QA #1513: BEFORE an F9 code is minted, the gate runs every send-time check read-only on the masked payload
    (--check-recipient, C11: the same deferral / hold / refusal as the send). Only 'RECIPIENT OK' mints; any other
    answer is recorded in the run's report exactly as the send would have recorded it, and no code exists to strand.
    The send itself re-checks everything (a change between the two reads holds, never sends)."""
    pre = verify_notify.Report()
    masked = {**p, "need": {**p["need"], "verify_code": CODE_PLACEHOLDER}}
    verify_notify.send_all([masked], pre, mode="dry-run", wrapper=wrapper, runner=runner, extra=["--campaign", CAMPAIGN],
                           check_recipients=True)
    if pre.recipient_ok == 1 and not pre.halted:
        return False if pre.failed_users else True
    for f in dataclasses.fields(pre):
        if f.name in ("recipient_ok", "validated", "candidates"):
            continue
        a, b = getattr(report, f.name), getattr(pre, f.name)
        if isinstance(b, bool) or b in (None, "", [], {}, 0):
            continue
        if isinstance(b, int):
            setattr(report, f.name, a + b)
        elif isinstance(b, list):
            a.extend(b)
        elif isinstance(b, str) and not a:
            setattr(report, f.name, b)
    report.refusals.append(f"distributor_preflight_not_ok:{p['credits'][0]['request_id']}")
    return False


def accounting(rep: verify_notify.Report) -> dict[str, Any]:
    """QA / r5 #1582: accepted + every gate non-send + filtered-before-gate == listed, per user (a check run). `balanced`
    False = a user the run cannot account for: the list is NOT signable."""
    listed = list(getattr(rep, "listed_users", []))
    acc = [a["user"] for a in rep.accepted]
    gate = [str(o.get("user")) for o in rep.outcomes]
    filt = [f["user"] for f in rep.filtered]
    return {"listed": len(listed), "would_send_users": acc,
            "counts": {"accepted": len(acc), "gate_non_send": len(gate), "filtered": len(filt)},
            "balanced": sorted(acc + gate + filt) == sorted(listed)}


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="op", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", required=True)
    b.add_argument("--tray", default=None, help="b1's L11c tray JSON (the source of truth, Fable [key=l11c-plural])")
    v = sub.add_parser("verify-facts")
    v.add_argument("--list", required=True)
    s = sub.add_parser("send")
    s.add_argument("--list", required=True)
    s.add_argument("--segment", choices=("paid", "free"), required=True)
    s.add_argument("--mode", choices=("dry-run", "apply"), default="dry-run")
    s.add_argument("--max-users", type=int, default=None, help="users this run (default 25); with --signed-accepted: "
                   "the signed check's attempt cap")
    s.add_argument("--signed-accepted", default="", metavar="CHECK_JSON",
                   help="apply: send exactly the users this signed --check-recipients outcomes file accepted; the sent "
                        "set must equal it or the run exits 3 ([key=apply-sized-to-list])")
    s.add_argument("--page", action="store_true", help="with --signed-accepted: a subset may be sent (the outbound tick)")
    s.add_argument("--start-entry", type=int, default=0, metavar="K",
                   help="r5 639: walk this segment's list from entry K (the tick's cursor; default 0)")
    s.add_argument("--max-entries", type=int, default=None, metavar="N",
                   help="r5 639: walk at most N list entries this run (default: all); the outcomes record the page")
    s.add_argument("--preview", default=None)
    s.add_argument("--preview-accepted", default="", metavar="CHECK_JSON",
                   help="with --preview: render exactly the users this --check-recipients outcomes file accepted")
    s.add_argument("--check-recipients", action="store_true",
                   help="dry run: the gate's live --check-recipient for every user (the signable would-send set)")
    s.add_argument("--outcomes-json", default=None, help="write every non-send gate answer {user, result, reason} (0600)")
    # [key=note-step-budget] (QA #1756 Critical): the outbound tick hands every family the seconds it has left before
    # TICK_HARD_S (family(), credit-verify-outbound.sh). proof-need-ask runs THIS parser, so without the flag an armed
    # need-ask apply exited 2 at argparse before writing a single thing - and the tick reads a missing outcomes file as
    # UNMEASURED and kills itself, with nothing refused and nothing sent. Declared here; the send loop reads it through
    # verify_notify.APPLY_BUDGET_S, exactly as the other families' CLIs do.
    s.add_argument("--apply-budget-s", type=float, default=None, metavar="SECONDS",
                   help="the tick's remaining share; the send loop never STARTS a user whose worst case would not fit")
    a = ap.parse_args(argv)
    # [key=note-step-budget] --apply-budget-s is declared on the SEND subparser only, but this line runs for every
    # subcommand. The outbound tick runs `need_asks.py build`, whose namespace has no such attribute, so reading it
    # unconditionally raised AttributeError on every tick's proof-need-ask build: the tick aborted before the apply
    # step and never wrote its outcome file. Same shape as credit-review.py's own read of the flag.
    verify_notify.set_apply_budget(getattr(a, "apply_budget_s", None))
    if a.op == "send" and a.preview_accepted:
        # t01b 584: the preview renders exactly the check's accepted set, walking the whole list
        if not a.preview or a.mode != "dry-run" or a.check_recipients:
            print("NEED ASKS: --preview-accepted goes with --preview on a plain --mode dry-run; nothing rendered")
            return 2
        try:
            verify_notify.PREVIEW_ONLY = verify_notify.load_preview_accepted(a.preview_accepted)
            with open(a.list, encoding="utf-8") as fh:
                a.max_users = max(a.max_users or 0, len(json.load(fh).get("users") or []), 1)
        except (OSError, ValueError, TypeError, AttributeError) as exc:
            print(f"NEED ASKS: --preview-accepted: {exc}; nothing rendered")
            return 2
    signed = None
    if a.op == "send" and a.signed_accepted:
        # Fable [key=apply-sized-to-list] (amended 586): sized from the signed check's attempt cap; sends only its set
        if a.mode != "apply":
            print("NEED ASKS: --signed-accepted is for --mode apply; nothing sent")
            return 2
        try:
            signed = verify_notify.load_preview_accepted(a.signed_accepted)
            with open(a.signed_accepted, encoding="utf-8") as fh:
                cap = json.load(fh).get("max_users")
        except (OSError, ValueError, TypeError) as exc:
            print(f"NEED ASKS: --signed-accepted: {exc}; nothing sent")
            return 2
        if not isinstance(cap, int) or cap < 1:
            print(f"NEED ASKS: --signed-accepted: {a.signed_accepted} records no attempt cap (max_users); nothing sent")
            return 2
        if a.max_users is not None and a.max_users < cap and not a.page:
            print(f"NEED ASKS: apply-sized-to-list: the signed check ran at --max-users {cap}; --max-users {a.max_users} "
                  f"would cut the signed set - apply it whole (omit --max-users); nothing sent")
            return 2
        if not a.page:
            # Fable rule (r5, E page 2): a signed subset is applied from a NEW list of exactly the signed rows
            try:
                with open(a.list, encoding="utf-8") as fh:
                    ids = {str(u.get("user_id")) for u in json.load(fh).get("users") or []
                           if bool(u.get("paid")) is (a.segment == "paid")}
            except (OSError, ValueError, AttributeError) as exc:
                print(f"NEED ASKS: --signed-accepted: the list is unreadable ({exc}); nothing sent")
                return 2
            extra = sorted(ids - signed)
            if extra:
                print(f"NEED ASKS: signed-subset-list: the list holds {len(extra)} user(s) outside the signed accepted set "
                      f"({', '.join(extra[:10])}); apply a signed subset from a NEW list of exactly the signed rows; "
                      "nothing sent")
                return 2
        if a.max_users is None or not a.page:
            a.max_users = cap
        verify_notify.APPLY_ONLY = signed
        verify_notify.APPLY_PAGE = bool(a.page)   # QA #1617: the tick's paged apply sends what fits; a hand apply is whole
    if a.op == "send" and a.max_users is None:
        a.max_users = 25
    try:
        if a.op == "verify-facts":
            with open(a.list, encoding="utf-8") as fh:
                diffs = verify_facts(json.load(fh), uvn_status.trino)
            print(json.dumps({"changed": diffs}))
            return 1 if diffs else 0
        if a.op == "build":
            res = build(tray=a.tray)
            fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(res, fh, indent=1)
            print(json.dumps({"generated_at": res["generated_at"], "counts": res["counts"]}))
            return 0
        if a.preview:
            Path(a.preview).mkdir(mode=0o700, parents=True, exist_ok=True)
        if a.check_recipients and a.mode == "apply":
            print("NEED ASKS: --check-recipients is a dry-run check; nothing sent")
            return 2
        tmp = ""
        if a.outcomes_json:
            # QA #1582: preflight BEFORE any send - a fresh 0600 temp file beside the target (never an existing file's
            # mode); an unwritable location stops the run with nothing sent
            try:
                fd, tmp = tempfile.mkstemp(prefix=".outcomes-", dir=os.path.dirname(os.path.abspath(a.outcomes_json)))
                os.close(fd)
            except OSError as exc:
                print(f"NEED ASKS: --outcomes-json {a.outcomes_json} is not writable ({exc}); nothing sent")
                return 2
        if a.mode == "apply":
            # QA #1604: ONE apply lock for the whole run - preflight, code issuance and every send
            try:
                with verify_notify.apply_session():
                    rep = send(list_path=a.list, segment=a.segment, mode=a.mode, max_users=a.max_users,
                               preview_dir=a.preview, check_recipients=a.check_recipients,
                               max_entries=a.max_entries, start_entry=a.start_entry)
            except verify_notify.ApplyLockError as exc:
                print(f"NEED ASKS: {exc}")
                return 3
        else:
            rep = send(list_path=a.list, segment=a.segment, mode=a.mode, max_users=a.max_users, preview_dir=a.preview,
                       check_recipients=a.check_recipients, max_entries=a.max_entries, start_entry=a.start_entry)
        if tmp:
            try:
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump({"mode": a.mode, "segment": a.segment, "check_recipients": a.check_recipients,
                               **accounting(rep),
                               "accepted": list(rep.accepted), "sent": list(getattr(rep, "sent", [])),
                               "outcomes": list(rep.outcomes),
                               "filtered": list(rep.filtered),
                               # p1 579: the deploy head this ran on, and the head its list was signed on
                               "deployed": verify_notify.deployed_head() or None,
                               "signed_on": verify_notify.LIST_SIGNED_ON or None,
                               "max_users": a.max_users,               # this run's attempt cap
                               "page": getattr(rep, "page", None) or None}, fh)   # r5 639: the entries walked
                os.replace(tmp, a.outcomes_json)          # atomic, and the fresh file's 0600 mode goes with it
            except OSError as exc:
                rep.failures.append(f"outcomes file not written: {exc}"[:200])
                rep.failed_users += 1                     # surfaced: the run exits 1
                Path(tmp).unlink(missing_ok=True)
    except NeedError as exc:
        print(f"NEED ASKS: nothing listed or sent: {exc}")
        return 2
    print(json.dumps({"halted": rep.halted, "candidates": rep.candidates, "not_found": rep.not_found,
                      "validated": rep.validated, "would_send": getattr(rep, "recipient_ok", 0),
                      **accounting(rep),
                      "sent": rep.sent_notes, "deferred": rep.deferred_users,
                      "refused": rep.refused_users, "failed": rep.failed_users, "refusals": rep.refusals[:10],
                      "held_newer_intake": len(getattr(rep, "held_newer", [])),
                      "held_newer_examples": getattr(rep, "held_newer", [])[:10],
                      "failures": rep.failures[:10]}))
    # QA #1582: a recipient check that cannot account for every listed user (e.g. the gate answered VALID instead of
    # RECIPIENT OK - wrapper drift) is NOT a signable set: fail closed on the exit status, not only in the JSON
    if a.check_recipients and not accounting(rep)["balanced"]:
        return 3
    if getattr(rep, "policy_error", False):
        return 2                                      # QA #1617: an unreadable cap policy is an operational failure
    if getattr(rep, "cap_short", False):
        return 3                                      # [key=uvn-daily-cap-400]: refused whole before the first send
    if rep.halted or rep.failed_users:
        return 1
    if signed is not None:
        bad = verify_notify.signed_set_mismatch(verify_notify.APPLY_REPORTS or [rep], signed, page=a.page)
        if bad:
            print(f"NEED ASKS: {bad}")
            return 3
    return 3 if verify_notify.HEAD_REFUSED else 0     # [key=signed-on-sha]: users deferred on the sha rail -> exit 3


if __name__ == "__main__":
    sys.exit(_main())
