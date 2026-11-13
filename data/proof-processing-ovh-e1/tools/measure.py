#!/usr/bin/env python3
"""Read-only counts for the proof path on node-8. Prints one JSON object; counts only, never an id or an email.

    python3 measure.py [--day 2026-11-13]

Stores are opened read-only. Core is read through scripts/trino-query.sh (the read replica). A read that fails is
reported as "unread", never as zero.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import sqlite3
import subprocess
import time
from collections import Counter

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
PROOF = "/var/lib/hydra-credit-verify/proof.sqlite"
DOCVERIFY = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
TRINO = "/opt/hydra/scripts/trino-query.sh"
TRAY = "/var/lib/hydra-credit-verify/intake-unresolved.jsonl"
STATE = "/var/lib/hydra-credit-verify/proof-file-state.json"
PENDING = ("user_verification_needed", "unverified")


def ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)


def trino(sql: str) -> list[list[str]] | None:
    try:
        p = subprocess.run([TRINO, sql], capture_output=True, text=True, timeout=180, cwd="/opt/hydra")
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return [r for r in csv.reader(io.StringIO(p.stdout)) if r]


def ids(raw: str | None) -> list[str]:
    try:
        got = json.loads(raw or "[]")
    except ValueError:
        return []
    return [str(x).lower() for x in got] if isinstance(got, list) else []


def statuses(request_ids: set[str]) -> dict[str, int] | str:
    """{status: n} in core for these request ids."""
    out: Counter = Counter()
    todo = sorted(i for i in request_ids if len(i) == 36 and all(c in "0123456789abcdef-" for c in i))
    for k in range(0, len(todo), 1500):
        part = ", ".join(f"UUID '{i}'" for i in todo[k:k + 1500])
        rows = trino("SELECT status, count(*) FROM postgresql_core.public.credit_requests "
                     f"WHERE deletedat IS NULL AND id IN ({part}) GROUP BY status")
        if rows is None:
            return "unread"
        for st, n in rows:
            out[st] += int(n)
    out["not_in_core_or_deleted"] = len(todo) - sum(out.values())
    return dict(sorted(out.items()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--day", default=time.strftime("%Y-%m-%d", time.gmtime()))
    a = ap.parse_args()
    day = a.day
    out: dict = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "day": day}

    with ro(PROOF) as db:
        out["documents_on_file"], out["accounts_with_documents"], out["newest_document"] = db.execute(
            "SELECT count(*), count(DISTINCT user_id), max(received_at) FROM proof_intake").fetchone()
        out["documents_received_today"] = db.execute(
            "SELECT count(*) FROM proof_intake WHERE received_at >= ?", (day,)).fetchone()[0]
        out["documents_by_source"] = dict(db.execute("SELECT source, count(*) FROM proof_intake GROUP BY 1"))
        doc_users = [str(u) for (u,) in db.execute("SELECT DISTINCT user_id FROM proof_intake")]
        named = set()
        for (raw,) in db.execute("SELECT candidate_request_ids_json FROM proof_intake"):
            named.update(ids(raw))
        out["requests_named_by_a_document"] = len(named)
        intake_ids = {str(i) for (i,) in db.execute("SELECT intake_id FROM proof_intake")}
        out["documents_with_no_local_bytes"] = db.execute(
            "SELECT count(*) FROM proof_intake WHERE file_path IS NULL").fetchone()[0]
        out["documents_filed_by"] = dict(db.execute("SELECT filed_by, count(*) FROM proof_intake GROUP BY 1"))
        out["stage2_rows_today"], out["stage2_requests_today"] = db.execute(
            "SELECT count(*), count(DISTINCT request_id) FROM stage2_shadow WHERE judged_at >= ?", (day,)).fetchone()

    with ro(DOCVERIFY) as db:
        out["doc_verify_today"] = dict(db.execute(
            "SELECT outcome, count(DISTINCT request_id) FROM dv_outcomes WHERE at >= ? GROUP BY 1", (day,)))
        keyed = {str(i) for (i,) in db.execute("SELECT intake_id FROM dv_intake_keys")}
        judged = {str(i) for (i,) in db.execute("SELECT DISTINCT intake_id FROM dv_outcomes WHERE intake_id IS NOT NULL")}
        out["documents_doc_verify_has_keyed"] = len(intake_ids & keyed)
        out["documents_with_a_doc_verify_outcome"] = len(intake_ids & judged)
        out["documents_doc_verify_has_not_keyed"] = len(intake_ids - keyed)
        out["doc_verify_documents_read_ever"] = db.execute("SELECT count(DISTINCT proof_id) FROM dv_outcomes").fetchone()[0]
        # the newest doc-verify outcome per (request, role): what the reader says about each claim today
        out["doc_verify_latest_per_claim"] = {o: {"claims": int(n), "requests": int(r)} for o, n, r in db.execute(
            "SELECT outcome, count(*), count(DISTINCT request_id) FROM dv_outcomes WHERE id IN "
            "(SELECT max(id) FROM dv_outcomes GROUP BY request_id, role) GROUP BY 1")}
        verified = {str(r).lower() for (r,) in db.execute(
            "SELECT DISTINCT request_id FROM dv_outcomes WHERE id IN "
            "(SELECT max(id) FROM dv_outcomes GROUP BY request_id, role) AND outcome='verified'")}
        out["doc_verify_verified_requests"] = len(verified)

    with ro(LEDGER) as db:
        out["notes_sent"] = db.execute("SELECT count(*) FROM verify_messages WHERE status='sent'").fetchone()[0]
        out["notes_answered"] = db.execute(
            "SELECT count(*) FROM verify_messages WHERE status='sent' AND proof_tagged_at IS NOT NULL").fetchone()[0]
        out["accounts_answered"] = db.execute(
            "SELECT count(DISTINCT account_id) FROM verify_messages WHERE status='sent' AND proof_tagged_at IS NOT NULL "
            "AND account_id IS NOT NULL").fetchone()[0]
        out["notes_answered_by_campaign"] = dict(db.execute(
            "SELECT campaign, count(*) FROM verify_messages WHERE status='sent' AND proof_tagged_at IS NOT NULL GROUP BY 1"))
        out["notes_unmeasured_no_account"] = db.execute(
            "SELECT count(*) FROM verify_messages WHERE status='sent' AND coalesce(account_id,'')=''").fetchone()[0]
        has = db.execute("SELECT 1 FROM sqlite_master WHERE name='proof_marks'").fetchone()
        out["marker_runs"] = dict(db.execute(
            "SELECT run_id, count(*) FROM proof_marks WHERE reverted_at IS NULL GROUP BY 1")) if has else {}
        marked = {int(r) for (r,) in db.execute(
            "SELECT message_row FROM proof_marks WHERE reverted_at IS NULL")} if has else set()
        answered, answered_before = set(), set()
        for rid, raw in db.execute("SELECT id, request_ids_json FROM verify_messages WHERE status='sent' "
                                   "AND proof_tagged_at IS NOT NULL AND campaign NOT IN "
                                   "('claim-proof-ask','claim-status','claim-proof-pending')"):
            answered.update(ids(raw))
            if int(rid) not in marked:
                answered_before.update(ids(raw))
        out["credit_requests_on_answered_notes"] = len(answered)
        out["credit_requests_on_notes_answered_before_the_marker"] = len(answered_before)
        out["proof_checked_at_rows"] = db.execute(
            "SELECT count(*) FROM verify_messages WHERE proof_checked_at IS NOT NULL").fetchone()[0]
        out["doc_approvals"] = db.execute("SELECT count(*) FROM doc_approvals").fetchone()[0]
        out["decider_rows_today"] = {f"{m}:{d}": n for m, d, n in db.execute(
            "SELECT mode, decision, count(DISTINCT request_id) FROM decisions WHERE decided_at >= ? GROUP BY 1, 2", (day,))}

    out["core_status_of_requests_on_answered_notes"] = statuses(answered)
    out["core_status_of_requests_on_notes_answered_before_the_marker"] = statuses(answered_before)
    out["core_status_of_requests_named_by_a_document"] = statuses(named)
    out["core_status_of_doc_verify_verified_requests"] = statuses(verified)
    rows = trino("SELECT count(*) FROM postgresql_core.public.credit_document_verdicts")
    out["core_credit_document_verdicts_rows"] = "unread" if rows is None else int(rows[0][0])

    t0 = f"TIMESTAMP '{day} 00:00:00 UTC'"
    rows = trino("SELECT status, count(*), count_if(updatedat >= " + t0 + " AND createdat < " + t0 + "), "
                 "count_if(createdat >= " + t0 + ") FROM postgresql_core.public.credit_requests "
                 "WHERE deletedat IS NULL GROUP BY status")
    if rows is None:
        out["core"] = "unread"
    else:
        out["core"] = {st: {"total": int(n), "older_request_written_today": int(t), "created_today": int(c)}
                       for st, n, t, c in rows}
        out["core_pending_total"] = sum(v["total"] for k, v in out["core"].items() if k in PENDING)
        out["core_decided_today_older_requests"] = sum(
            v["older_request_written_today"] for k, v in out["core"].items() if k in ("approved", "rejected"))
    part = ", ".join(u for u in doc_users if u.isdigit())
    rows = trino("SELECT status, count(*), count(DISTINCT userid) FROM postgresql_core.public.credit_requests "
                 f"WHERE deletedat IS NULL AND userid IN ({part}) GROUP BY status") if part else []
    out["core_requests_of_accounts_with_documents"] = "unread" if rows is None else {
        st: {"requests": int(n), "accounts": int(u)} for st, n, u in rows}
    try:
        tray = [json.loads(x) for x in open(TRAY, encoding="utf-8") if x.strip()]
        out["unresolved_tray"] = {"rows": len(tray), "rows_today": sum(1 for t in tray if str(t.get("at", "")) >= day),
                                  "conversations": len({t.get("conversation_id") for t in tray}),
                                  "why_today": dict(Counter(str(t.get("why"))[:60] for t in tray
                                                            if str(t.get("at", "")) >= day))}
    except (OSError, ValueError):
        out["unresolved_tray"] = "unread"
    try:
        st = json.load(open(STATE, encoding="utf-8"))
        out["feeder"] = {"cursor": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(st.get("since") or 0))),
                         "conversations_carried": len(st.get("carry") or []),
                         "messages_carried": len(st.get("carry_messages") or [])}
    except (OSError, ValueError):
        out["feeder"] = "unread"
    print(json.dumps(out, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
