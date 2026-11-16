#!/usr/bin/env python3
"""Split the 'proof on file: human review' holds by whether the document on file is a record type.

Read-only. Run on node-8 without leaving a file there:
    ssh root@<node-8> 'cd /opt/hydra/scripts && nice -n 10 python3 - --rows' \
        < data/docverify-bar-on-supportable-subset-r1/tools/split.py > OUT.json

The population is fixed before anything is read: every request whose LATEST credit-review ledger row
(highest id, any mode) carries the decider's `proof on file: human review` sentence (`decide.py`
`DOC_ON_FILE_HOLD`). The document is the one doc-verify read for that request under its current
version; when doc-verify holds no row for the request itself, the hold is the user's (proof on file is
per user), so the user's own documents are the ones read.

Each request lands in exactly one lane, first match wins (`route`):
  no_document_read   doc-verify has read no document of this request or user: there is no document type
                     to split on, so no ask
  account_hold       a document of the account is forged / on hold: nobody is asked, ever
  record_type        a document is of record by the gate's own test (gate.py `not_a_document_of_record`:
                     extraction doc_type in gate.RECORD_DOC_TYPES, or kind in gate.RECORD_H3_KINDS): it
                     waits on the reader's bar
  not_record_ask     no document is a record type: one ask, the need the gate itself recorded on the
                     row, in the approved words of proof_reviewer.ASK_LINES (no new copy). A row where
                     every read was `unknown` recorded no need, so it gets the gate's own
                     readable_document ask: a clearer copy is what settles a document we could not read.

The record kinds and the ask words are IMPORTED from the deployed tree, never restated here. Writes
nothing. Per-request rows (customer ids) go to stdout only with --rows; never commit them.
"""
from __future__ import annotations

import collections
import json
import sqlite3
import sys

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
DOC_VERIFY = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
VERSION = "dv-4"
HOLD = "proof on file: human review"

NO_DOC, HOLD_LANE, RECORD, ASK = (
    "no_document_read", "account_hold", "record_type", "not_record_ask")
LANES = (NO_DOC, HOLD_LANE, RECORD, ASK)
# Tie-break between needs recorded equally often on one request: the document that settles a credit by
# itself first (a document of record), then the F9 dashboard, then the issuer line, then a readable copy.
NEED_ORDER = ("counterparty_signed_or_registered", "distributor_dashboard_with_code",
              "issuer_email_from_official_domain", "readable_document")


def is_record(doc: dict, record_kinds, record_doc_types) -> bool:
    """The gate's own record test (gate.py, the `not_a_document_of_record` blocker), minus F9: an F9
    dashboard is evidence, not a document of record."""
    return doc.get("doc_type") in record_doc_types or doc.get("kind") in record_kinds


def route(docs: list[dict], record_kinds, record_doc_types, ask_lines, account_need, default_need) -> dict:
    """One request's lane. `docs`: one dict per doc-verify outcome row the request rests on, with
    `kind` (the kind doc-verify recorded on its `text` step; the gate uses `h3.kind or` it), `doc_type`
    (the extraction's), `outcome`, `need` and `account_hold`."""
    if not docs:
        return {"lane": NO_DOC}
    if any(d.get("account_hold") or d.get("outcome") == "forged" or d.get("need") == account_need
           for d in docs):
        return {"lane": HOLD_LANE}
    kinds = sorted({d.get("kind") or "unknown" for d in docs})
    if any(is_record(d, record_kinds, record_doc_types) for d in docs):
        return {"lane": RECORD, "kinds": kinds}
    needs = collections.Counter(d["need"] for d in docs if d.get("need") in ask_lines)
    if not needs:
        return {"lane": ASK, "kinds": kinds, "need": default_need, "ask": ask_lines[default_need]}
    top = max(needs.values())
    need = next(n for n in NEED_ORDER if needs.get(n) == top)
    return {"lane": ASK, "kinds": kinds, "need": need, "ask": ask_lines[need]}


def main(argv: list[str]) -> None:
    sys.path.insert(0, ".")
    from credit_verify.docverify import gate          # noqa: E402  (the deployed tree: cwd /opt/hydra/scripts)
    from credit_review import proof_reviewer           # noqa: E402

    led = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True, timeout=120)
    pop = led.execute(
        "SELECT d.request_id, d.user_id, d.paid_priority, d.decided_at FROM decisions d"
        " JOIN (SELECT request_id, max(id) mid FROM decisions GROUP BY request_id) m ON m.mid = d.id"
        " WHERE substr(d.reason, 1, ?) = ?", (len(HOLD), HOLD)).fetchall()
    ledger_last = led.execute("SELECT max(decided_at) FROM decisions").fetchone()[0]
    led.close()

    dv = sqlite3.connect(f"file:{DOC_VERIFY}?mode=ro", uri=True, timeout=120)
    kind: dict[str, str] = {}
    doc_type: dict[str, str] = {}
    for pid, step, dj in dv.execute("SELECT proof_id, step, detail_json FROM dv_steps"
                                    " WHERE step IN ('text', 'extract') AND request_id = '' ORDER BY id"):
        try:
            d = json.loads(dj or "{}")
        except ValueError:
            d = {}
        if step == "text":
            kind[pid] = d.get("kind") or "unknown"
        else:
            doc_type[pid] = d.get("doc_type") or "none"
    by_req: dict[str, list] = collections.defaultdict(list)
    by_user: dict[str, list] = collections.defaultdict(list)
    for pid, rid, uid, outcome, need, hold in dv.execute(
            "SELECT o.proof_id, o.request_id, o.user_id, o.outcome, o.need, o.account_hold FROM dv_outcomes o"
            " JOIN (SELECT max(id) mid FROM dv_outcomes WHERE version = ? GROUP BY proof_id, request_id, role) l"
            " ON l.mid = o.id", (VERSION,)):
        d = {"proof_id": pid, "kind": kind.get(pid, "unknown"), "doc_type": doc_type.get(pid, "none"),
             "outcome": outcome, "need": need,
             "account_hold": bool(hold)}
        by_req[rid].append(d)
        by_user[str(uid)].append(d)
    dv.close()

    lanes = {ln: {"requests": 0, "users": set(), "paid_requests": 0, "paid_users": set()} for ln in LANES}
    scope = collections.Counter()
    needs = collections.defaultdict(lambda: {"requests": 0, "users": set()})
    kinds_by_lane = collections.defaultdict(collections.Counter)
    types_by_lane = collections.defaultdict(dict)   # lane -> proof_id -> extraction doc_type
    record_by = collections.Counter()
    users_lanes = collections.defaultdict(set)
    rows = []
    for rid, uid, paid, decided_at in pop:
        docs = by_req.get(rid)
        sc = "request" if docs else ("user" if by_user.get(str(uid)) else "none")
        docs = docs or by_user.get(str(uid)) or []
        r = route(docs, gate.RECORD_H3_KINDS, gate.RECORD_DOC_TYPES, proof_reviewer.ASK_LINES,
                  gate.NEED_ACCOUNT, gate.NEED_READABLE)
        if docs:
            kind_only = any(d["kind"] in gate.RECORD_H3_KINDS for d in docs)
            type_only = any(d["doc_type"] in gate.RECORD_DOC_TYPES for d in docs)
            record_by[(kind_only, type_only)] += 1
        for d in docs:
            types_by_lane[r["lane"]][d["proof_id"]] = d["doc_type"]
        ln = r["lane"]
        scope[sc] += 1
        lanes[ln]["requests"] += 1
        lanes[ln]["users"].add(uid)
        users_lanes[uid].add(ln)
        if paid:
            lanes[ln]["paid_requests"] += 1
            lanes[ln]["paid_users"].add(uid)
        for k in r.get("kinds", []):
            kinds_by_lane[ln][k] += 1
        if ln == ASK:
            needs[r["need"]]["requests"] += 1
            needs[r["need"]]["users"].add(uid)
        if "--rows" in argv:
            rows.append({"request_id": rid, "user_id": uid, "paid": bool(paid), "decided_at": decided_at,
                         "doc_scope": sc, "documents": len({d["proof_id"] for d in docs}), **r})
    out = {
        "ledger_last_row": ledger_last, "version": VERSION, "record_kinds": list(gate.RECORD_H3_KINDS),
        "record_doc_types": list(gate.RECORD_DOC_TYPES),
        "population": {"requests": len(pop), "users": len({p[1] for p in pop}),
                       "paid_requests": sum(1 for p in pop if p[2]),
                       "paid_users": len({p[1] for p in pop if p[2]})},
        "document_scope": dict(scope),
        "lanes": {ln: {"requests": v["requests"], "users": len(v["users"]), "paid_requests": v["paid_requests"],
                       "paid_users": len(v["paid_users"])} for ln, v in lanes.items()},
        "users_in_more_than_one_lane": sum(1 for s in users_lanes.values() if len(s) > 1),
        "asks": {n: {"requests": v["requests"], "users": len(v["users"]), "words": proof_reviewer.ASK_LINES[n]}
                 for n, v in sorted(needs.items())},
        "requests_per_kind_by_lane": {ln: dict(c.most_common()) for ln, c in kinds_by_lane.items()},
        "documents_per_doc_type_by_lane": {ln: dict(collections.Counter(m.values()).most_common())
                                           for ln, m in types_by_lane.items()},
        "requests_record_by_kind_vs_doc_type": {f"kind={k} doc_type={t}": n for (k, t), n in sorted(record_by.items())},
    }
    if rows:
        out["rows"] = rows
    json.dump(out, sys.stdout, indent=1, sort_keys=False, default=str)
    print()


if __name__ == "__main__":
    main(sys.argv[1:])
