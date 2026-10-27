#!/usr/bin/env python3
"""intercom-backlog tail lists (WS2 e4, Fable plan [key=ws2-plan-1027]): turn the > 30 d
customer-last tail into input lists for the EXISTING approved campaign senders, using the
classes cs-systemic-c3 defined for the live set (data/cs-systemic-c3/inbound-plan-1027.md §2/§4).

This file SENDS NOTHING and WRITES NO STATUS OR LEDGER ROW. It only writes JSON lists. The sends
happen later through the campaign drivers (credit-review.py uvn-status --campaign ...), which
re-check everything at send time: the 7-day core-marker gate, the shared one-message-per-user-
per-day ledger, documents in Intercom, the fraud lens and the caps. Under the captain's freeze
[key=sender-map-1027] nobody runs those sends until the lift.

Class per conversation (one per user; first match wins):
  A  status-doc-received   pending unverified/processing rows with a document on file
                            (proof-on-file entry for the request, or a whole-user entry)
  B  status-team-review    pending unverified/processing rows, no document on file
  D  claim-status          a pending profile claim -> handoff ids for claim-lane-resume-c2
                            (its sender owns the claim list: profile name and url are its facts)
  C  uvn-status            only user_verification_needed rows. Written with skip set: Fable R4
                            says the only approved wording for a UVN row is an ASK, and nothing goes
                            to them before lift L11, so the driver (it offers only skip == null)
                            can never send these until a later list clears the skip
  M  merge                 no approved wording: held
  X  no-account            the Intercom external_id maps to no account: the reconcile lane (x2)
  -  none                  nothing pending to state: held (the hold list)
Scope: credit / claim / merge topics only (c3's classes); other topics are "out-of-scope" (held).
Captain overrides apply first (overrides.py): captain-* and hold-read rows are never classed.
Proof-on-file is the strict shared rule (verify_notify.load_proof_on_file); when it cannot be
read, A and B are NOT written at all (A vs B cannot be told apart, so no note).

List order is oldest first; the drivers take paid first through --segment.

Usage (node-8): python3 tail_lists.py <triage.jsonl> --out DIR [--tag tail-2026-10] [--proof-on-file P]
"""
import argparse
import collections
import csv
import datetime as dt
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import overrides  # noqa: E402
from credit_review import verify_notify  # noqa: E402

TAIL_TAG = "tail-2026-10"
PENDING_TEAM = ("unverified", "processing")
UVN = "user_verification_needed"
R4_SKIP = "held: Fable R4, UVN rows get the ask only after lift L11"
# c3's scope for these classes: credit / claim / merge conversations. Other topics (removal
# disputes, account, stats, other) have no approved line and stay on the hold list.
CREDIT_TOPICS = ("credit", "claim", "merge")


def classify(rows, pending, claims, documented, *, tag=TAIL_TAG, now=None):
    """Pure. rows = triage rows (overrides already applied); pending = {user_id: [(request_id,
    status)]}; claims = {user_id: [claim_id]}; documented = verify_notify.ProofOnFile or None
    (None = unreadable: no A/B). Returns {class: [entry]} with entries oldest first."""
    out = collections.defaultdict(list)
    seen_users = set()
    for r in sorted(rows, key=lambda r: r["waiting_since"]):
        if r.get("band") != "gt30d" or (tag and tag not in (r.get("tags") or [])):
            continue
        act = r.get("action", "")
        if act.startswith("captain-") or act == overrides.HOLD_READ:
            continue
        if r.get("topic") not in CREDIT_TOPICS:
            out["out-of-scope"].append({"conversation_id": r["id"], "paid": bool(r.get("paid")),
                                        "waiting_since": r["waiting_since"], "reason": r.get("topic")})
            continue
        base = {"conversation_id": r["id"], "paid": bool(r.get("paid")), "waiting_since": r["waiting_since"]}
        uid = r.get("user_id")
        if not uid:
            out["X"].append(dict(base, reason=act))
            continue
        if uid in seen_users:  # one note per user: the oldest conversation carries it
            out["dup"].append(dict(base, user_id=uid))
            continue
        seen_users.add(uid)
        rows_u = pending.get(uid, [])
        team = [rid for rid, st in rows_u if st in PENDING_TEAM]
        uvn = [rid for rid, st in rows_u if st == UVN]
        entry = dict(base, user_id=int(uid), skip=None)
        if team:
            if documented is None:
                out["AB-unreadable"].append(dict(entry, request_ids=team))
                continue
            docs = documented.get(str(uid), [])
            whole = any(rid is None for rid, _ in docs)
            doc_ids = {rid for rid, _ in docs if rid}
            with_doc = [rid for rid in team if whole or rid in doc_ids]
            if with_doc:
                out["A"].append(dict(entry, request_ids=with_doc))
            else:
                out["B"].append(dict(entry, request_ids=team))
        elif claims.get(uid):
            out["D"].append(dict(entry, claim_ids=sorted(claims[uid])))
        elif uvn:
            out["C"].append(dict(entry, request_ids=uvn, skip=R4_SKIP))
        elif r.get("topic") == "merge" or act == "draft-merge":
            out["M"].append(dict(entry))
        else:
            out["none"].append(dict(entry, reason=act))
    return out


def driver_list(entries, campaign, now=None):
    """The uvn_status.load_list shape: {generated_at, users[]} (+ provenance)."""
    now = now or dt.datetime.now(dt.timezone.utc)
    return {"generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "campaign": campaign,
            "source": "intercom-backlog-i1 tail_lists.py (WS2 e4)",
            "users": [{"user_id": e["user_id"], "paid": e["paid"], "skip": e["skip"],
                       "request_ids": [str(x) for x in e["request_ids"]],
                       "conversation_id": e["conversation_id"]} for e in entries]}


def trino(sql):
    p = subprocess.run(["/opt/hydra/scripts/trino-query.sh"], input=sql, capture_output=True, text=True, timeout=900)
    if p.returncode:
        raise RuntimeError(p.stderr.strip()[:300])
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


def read_core(uids):
    pending, claims = collections.defaultdict(list), collections.defaultdict(list)
    uids = sorted({str(u) for u in uids if u})
    for i in range(0, len(uids), 150):
        ids = ",".join(uids[i:i + 150])
        for uid, rid, st in trino(
                "select cast(userid as varchar), cast(id as varchar), status from postgresql_core.public.credit_requests "
                f"where deletedat is null and status in ('unverified','processing','user_verification_needed') "
                f"and userid in ({ids})"):
            pending[uid].append((rid, st))
        for uid, cid in trino(
                "select cast(userid as varchar), cast(id as varchar) from postgresql_core.public.claiming "
                f"where deletedat is null and status = 'pending' and userid in ({ids})"):
            claims[uid].append(cid)
    return pending, claims


def write_json(path, doc):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("triage")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", default=TAIL_TAG, help="'' = every > 30 d row")
    ap.add_argument("--proof-on-file", default=None)
    ap.add_argument("--overrides", default=overrides.DEFAULT_PATH)
    a = ap.parse_args()
    try:
        ov = overrides.load(a.overrides)
    except overrides.OverridesError as e:
        sys.exit(f"REFUSED: {e}")
    rows = overrides.apply([json.loads(l) for l in open(a.triage)], ov)
    try:
        documented = verify_notify.load_proof_on_file(a.proof_on_file)
        proof_note = "read"
    except verify_notify.ProofFileError as e:
        documented, proof_note = None, f"UNREADABLE ({e}): no A/B list written"
    pending, claims = read_core(r.get("user_id") for r in rows)
    out = classify(rows, pending, claims, documented, tag=a.tag)
    os.makedirs(a.out, mode=0o700, exist_ok=True)
    files = {}
    for cls, camp in (("A", "status-doc-received"), ("B", "status-team-review"), ("C", "uvn-status")):
        if out.get(cls):
            p = os.path.join(a.out, f"tail-{camp}.json")
            write_json(p, driver_list(out[cls], camp))
            files[cls] = p
    if out.get("D"):
        p = os.path.join(a.out, "tail-claim-status-handoff.json")
        write_json(p, {"for": "claim-lane-resume-c2", "claims": out["D"]})
        files["D"] = p
    counts = {k: {"total": len(v), "paid": sum(1 for e in v if e["paid"])} for k, v in sorted(out.items())}
    support = sum(1 for k in ("A", "B") for e in out.get(k, [])
                  if documented is not None and verify_notify.is_support_contact(documented, str(e["user_id"])))
    print(json.dumps({"proof_on_file": proof_note, "counts": counts, "files": files,
                      "support_at_contacts_in_AB (driver holds them)": support}, indent=1))


if __name__ == "__main__":
    main()
