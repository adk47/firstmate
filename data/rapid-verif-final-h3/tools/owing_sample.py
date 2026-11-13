#!/usr/bin/env python3
"""Read-only sample of the uvn-status owing list against primary facts (rapid-verif-final-h3, task 1).

Run on node-8 with the deployed tree on the path:

    PYTHONPATH=/opt/hydra/scripts python3 owing_sample.py --owing /root/h2-runs/sched/<tick>/owing-uvn.json

It writes NOTHING on the host except the --out files the caller names. Every read is one of:
  - the verify ledger, opened `mode=ro`;
  - the core replica through the deployed `verify_notify.trino` (the tick's own reader);
  - the tick's own artefacts under --sched-root (check / apply outcome JSON);
  - the proof-on-file list and the fraud lens's account holds, through the deployed readers.

It asks two questions the tick's counters cannot answer by themselves:

  1. LISTED: of N random users on the owing list, who has (a) a request that is still open on the replica and
     (b) a sent row in the ledger, and what - if anything - stands between them and an ask.
  2. SKIPPED: `skip_already_told_uvn` counts a user as told when the ledger has a sent uvn-status row for the
     account OR core's `metadata.proofRequest` exists on any open request. This splits the whole skipped
     population by WHICH of the two it rests on, and whether the marker carries a `noticeSentAt` at all.

No email address, name or message body is read into the output: users are named by core user id only.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import random
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any

OPEN = ("unverified", "processing", "user_verification_needed")
# campaigns whose message asks the user for proof (a status line or a receipt is not an ask)
ASK_CAMPAIGNS = ("uvn-status", "first-ask-1", "reminder-1", "proof-need-ask", "gap-ask", "verify-live")
STATUS_LINE_CAMPAIGNS = ("status-team-review", "status-doc-received")


def _ids(raw: str | None) -> set[str]:
    try:
        return {str(x).strip().lower() for x in json.loads(raw or "[]")}
    except ValueError:
        return set()


def ledger_rows(path: str) -> dict[str, list[dict[str, Any]]]:
    """Every verify_messages row by account id. A row with no account id (reminders, loop closes) takes its
    parent's account id, so a reminder of an ask is seen as contact with the asked account."""
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    rows = db.execute("SELECT id, campaign, kind, status, parent_row, account_id, request_ids_json, message_id, "
                      "conversation_id, coalesce(sent_at, created_at) AS at, proof_tagged_at, last_reply_at, "
                      "proof_checked_at FROM verify_messages ORDER BY id").fetchall()
    acct = {r["id"]: str(r["account_id"] or "") for r in rows}
    out: dict[str, list[dict[str, Any]]] = defaultdict(list)
    unresolved = 0
    for r in rows:
        a = acct[r["id"]] or acct.get(r["parent_row"] or -1, "")
        if not a:
            unresolved += 1
            continue
        out[a].append({"id": r["id"], "campaign": r["campaign"], "kind": r["kind"], "status": r["status"],
                       "ids": _ids(r["request_ids_json"]), "at": str(r["at"] or "").replace(" ", "T")[:19],
                       "delivered": bool(r["message_id"]), "tagged": bool(r["proof_tagged_at"]),
                       "replied": bool(r["last_reply_at"]), "checked": bool(r["proof_checked_at"])})
    out["__unresolved__"] = [{"n": unresolved}]
    return out


def tick_outcomes(root: str, days: tuple[str, ...]) -> dict[str, dict[str, str]]:
    """The newest uvn-status outcome the tick itself recorded per user (check and apply), with the tick stamp."""
    seen: dict[str, dict[str, str]] = {}
    for day in days:
        for f in sorted(glob.glob(os.path.join(root, f"{day}T*", "uvn-status-*-*.json"))):
            stamp = f.split(os.sep)[-2]
            try:
                doc = json.load(open(f, encoding="utf-8"))
            except (OSError, ValueError):
                continue
            for o in doc.get("outcomes") or []:
                seen[str(o.get("user"))] = {"tick": stamp, "result": str(o.get("result")),
                                            "reason": str(o.get("reason") or "")[:60]}
    return seen


def reason_code(reason: str) -> str:
    for code in ("c2_signed_only", "messaged_7d", "core_notice_within_7d", "no_channel", "comm_state", "run_size",
                 "asked_90d", "G5", "G2"):
        if code in reason:
            return code
    return (reason.split(" ")[0] or "other")[:30]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--owing", required=True)
    ap.add_argument("--ledger", default="/var/lib/hydra/credit-review/ledger.sqlite3")
    ap.add_argument("--sched-root", default="/root/h2-runs/sched")
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261113)
    ap.add_argument("--out", required=True, help="per-user JSONL (core user ids and reason codes only)")
    ap.add_argument("--skip-population", action="store_true",
                    help="also split the whole skip_already_told population (one whole-table replica read)")
    a = ap.parse_args()

    from credit_review import (core_notice, owing_proof, uvn_status, verify_ledger,  # the DEPLOYED readers
                               verify_notify)

    now = datetime.now(timezone.utc)
    doc = json.load(open(a.owing, encoding="utf-8"))
    listed = sorted(doc["users"], key=lambda u: int(u["user_id"]))
    rng = random.Random(a.seed)
    sample_ids = {u["user_id"] for u in rng.sample(listed, min(a.n, len(listed)))}
    all_ids = [int(u["user_id"]) for u in listed]
    sids = sorted(int(u) for u in sample_ids)
    led = ledger_rows(a.ledger)
    unresolved = led.pop("__unresolved__")[0]["n"]
    db = verify_ledger.connect_ro(a.ledger, must_exist=True)
    days = tuple(sorted({now.strftime("%Y%m%d"), (now - timedelta(days=1)).strftime("%Y%m%d")}))
    outcomes = tick_outcomes(a.sched_root, days)
    held = owing_proof.held_accounts(owing_proof.ACCOUNT_HOLDS, a.ledger)
    try:
        documented = verify_notify.load_proof_on_file(now=now)
        pof_state = "read"
    except verify_notify.ProofFileError as exc:
        # reported, and the list is then read whatever its age: a stale list is said, never read as "nobody filed"
        documented = verify_notify.load_proof_on_file(max_age_h=24 * 365, now=now)
        pof_state = f"stale_or_partial ({str(exc)[:80]})"
    released = uvn_status.stage2_released(uvn_status.CAMPAIGN)
    # emails are held in memory for the ledger's same-user rule only; they never reach the output
    accounts = uvn_status.accounts_of(all_ids, verify_notify.trino)
    # the runner's own read of what can be asked about: UVN rows, unverified / processing rows core marked
    # proof_required, and the decider's per-role splits (pending_rows, as uvn_status.run calls it)
    partial = frozenset(uvn_status.partial_pending_roles(a.ledger))
    runner_rows = uvn_status.pending_rows(all_ids, uvn_status.CAMPAIGN, released, verify_notify.trino,
                                          partial_ids=partial)

    # (a) the replica NOW: every request of every listed user, any status, deleted or not
    live: dict[str, dict[str, list[str]]] = defaultdict(dict)
    for i in range(0, len(all_ids), 500):
        idl = ",".join(str(x) for x in all_ids[i:i + 500])
        for uid, rid, st, deleted, notice in verify_notify.trino(
                "SELECT CAST(userid AS varchar), lower(CAST(id AS varchar)), status, "
                "CAST(CASE WHEN deletedat IS NOT NULL THEN 1 ELSE 0 END AS varchar), "
                "coalesce(json_extract_scalar(metadata, '$.proofRequest.noticeSentAt'), '') "
                f"FROM postgresql_core.public.credit_requests WHERE userid IN ({idl})"):
            live[uid][rid] = [st, deleted, notice]
    notices = core_notice.reasons_by_user(sids, query=verify_notify.trino, now=now)

    def facts(u: dict[str, Any]) -> dict[str, Any]:
        """One listed user against the runner's own rules, in the runner's own order (uvn_status.run), then the
        gate's /c2 rule. `first_blocker` is the first rule that stops the ask; '' when none of the coded rules do."""
        uid = u["user_id"]
        want = [r.lower() for r in u["request_ids"]]
        acct = accounts.get(int(uid), {})
        email = acct.get("email", "")
        cond, params = verify_ledger._same_user(db, email, uid)
        mine = db.execute(f"SELECT m.campaign, m.kind, m.status, coalesce(m.sent_at, m.created_at) AS at, "
                          f"m.request_ids_json FROM verify_messages m WHERE {cond}", params).fetchall()
        sent = [r for r in mine if r["status"] == "sent"]
        asks = sorted({r["campaign"] for r in sent if r["campaign"] in ASK_CAMPAIGNS})
        rr = {str(r["request_id"]).lower(): r for r in runner_rows.get(int(uid), [])}
        open_uvn = [r for r in want if r in rr]
        askable = [r for r in open_uvn if not rr[r]["_no_ask"] and not rr[r]["_incomplete"]]
        no_ask = Counter(rr[r]["_no_ask"] for r in open_uvn if rr[r]["_no_ask"])
        overlap = verify_ledger.nothing_needed_overlap(db, uid, want)["overlap"]
        why = verify_ledger.uvn_user_done(db, email, now=now, campaign=uvn_status.CAMPAIGN, user_id=uid,
                                          request_ids=want) if email else "no_account_row"
        if uvn_status.documents_block(documented, uid, want, released, u.get("oldest") or None):
            first = "documents_on_file"
        elif want and verify_ledger.blocked_ids(db, want, uvn_status.CAMPAIGN) >= set(want):
            first = "already_handled:rows_noted_or_asked"
        elif int(uid) in held:
            first = "fraud_lens_hold"
        elif not acct.get("professional_id"):
            first = "no_professional_id"
        elif why:
            first = why if why in verify_ledger.DEFER_REASONS else f"already_handled:{why}"
        elif not open_uvn:
            first = "no_askable_row_now"
        elif not askable:
            first = ("no_ask:" + no_ask.most_common(1)[0][0]) if no_ask else "rows_unshowable"
        elif overlap:
            first = "c2_signed_only"
        else:
            first = ""
        oc = outcomes.get(uid, {})
        return {"user_id": uid, "paid": bool(u["paid"]), "first_blocker": first, "listed_requests": len(want),
                "askable_status_now": len(open_uvn), "askable_now": len(askable), "sent_rows": len(sent),
                "sent_campaigns": sorted({r["campaign"] for r in sent}), "sent_asks": asks,
                "last_sent_at": max((str(r["at"] or "").replace(" ", "T")[:19] for r in sent), default=""),
                "status_line_names_listed_rows": bool(overlap), "document_on_file": bool(documented.get(uid)),
                "emailed_support_90d": uid in documented.support_contacts,
                "tick": oc.get("tick", ""), "tick_result": oc.get("result", ""),
                "tick_reason": reason_code(oc.get("reason", "")) if oc else ""}

    def bucket(f: dict[str, Any], lv: dict[str, list[str]], core: "list[str] | None" = None) -> str:
        """The brief's four-way split. `lv` = the listed requests on the replica now; `core` (sample only) = core's
        own notices inside 7 days, which the gate holds on."""
        if not any(v[0] in OPEN and v[1] == "0" for v in lv.values()):
            return "no_open_credit_request"
        if f["sent_asks"] or any(v[2] and v[0] in OPEN and v[1] == "0" for v in lv.values()):
            return "already_asked"
        if f["first_blocker"] or core:
            return "held_by_rule"
        if f["tick_result"] and f["tick_reason"] not in ("run_size", "", "c2_signed_only") \
                and f["tick_result"] not in ("sent", "accepted"):
            return "held_by_rule"
        return "owed_never_asked_nothing_in_the_way"

    pop_first: dict[str, Counter] = {"paid": Counter(), "free": Counter()}
    pop_bucket: dict[str, Counter] = {"paid": Counter(), "free": Counter()}
    pop_flags: dict[str, Counter] = {"paid": Counter(), "free": Counter()}
    samp_bucket: dict[str, Counter] = {"paid": Counter(), "free": Counter()}
    samp_sub: Counter = Counter()
    samp_tick: Counter = Counter()
    per_user = []
    for u in listed:
        f = facts(u)
        k = "paid" if f["paid"] else "free"
        pop_first[k][f["first_blocker"] or "(none)"] += 1
        lv = live.get(u["user_id"], {})
        lvl = {r: v for r, v in lv.items() if r in {x.lower() for x in u["request_ids"]}}
        b = bucket(f, lvl)
        pop_bucket[k][b] += 1
        pop_flags[k]["listed_rows_status:" + "+".join(sorted({v[0] if v[1] == "0" else "deleted"
                                                              for v in lvl.values()}) or ["none"])] += 1
        for flag in ("status_line_names_listed_rows", "document_on_file", "emailed_support_90d"):
            pop_flags[k][flag] += bool(f[flag])
        pop_flags[k]["no_sent_row_ever"] += not f["sent_rows"]
        pop_flags[k]["sent_ask_any_campaign"] += bool(f["sent_asks"])
        for c in f["sent_campaigns"]:
            pop_flags[k]["sent:" + c] += 1
        pop_flags[k]["tick_outcome:" + (f["tick_reason"] or "none_recorded")] += 1
        if not f["first_blocker"] or f["first_blocker"] == "c2_signed_only":
            pop_flags[k][f"{f['first_blocker'] or 'clear'}->tick:{f['tick_reason'] or 'none_recorded'}"] += 1
        if u["user_id"] in sample_ids:
            core = notices.get(int(u["user_id"]), [])
            sb = bucket(f, lvl, core)
            sub = (f["first_blocker"] or ("core_notice:" + core[0][:28] if core else
                                          ("gate:" + f["tick_reason"]) if sb == "held_by_rule" else
                                          "tick:" + (f["tick_reason"] or "not_reached")))
            if sb == "already_asked":
                sub = "+".join(f["sent_asks"]) or "core_proofRequest_notice"
            samp_bucket[k][sb] += 1
            samp_sub[f"{sb}/{sub}"] += 1
            samp_tick[f"{sb} | tick={f['tick_result'] or 'not_reached'}:{f['tick_reason'] or '-'}"] += 1
            per_user.append({**f, "bucket": sb, "sub": sub, "open_now_any_status": sum(
                1 for v in lvl.values() if v[0] in OPEN and v[1] == "0"), "core_notice_7d": core})
    with open(a.out, "w", encoding="utf-8") as fh:
        for row in sorted(per_user, key=lambda r: int(r["user_id"])):
            fh.write(json.dumps(row, sort_keys=True) + "\n")

    def tot(d: dict[str, Counter]) -> dict[str, Any]:
        both = d["paid"] + d["free"]
        return {"all": dict(sorted(both.items(), key=lambda kv: -kv[1])),
                "paid": dict(sorted(d["paid"].items(), key=lambda kv: -kv[1])),
                "free": dict(sorted(d["free"].items(), key=lambda kv: -kv[1]))}

    res: dict[str, Any] = {
        "measured_at": now.isoformat(timespec="seconds"), "owing_list": a.owing,
        "owing_generated_at": doc.get("generated_at"), "listed": len(listed), "sample": len(per_user), "seed": a.seed,
        "ledger_rows_without_account": unresolved, "proof_on_file": pof_state, "stage2_released_rows": len(released),
        "sample_buckets": tot(samp_bucket), "sample_sub": dict(sorted(samp_sub.items(), key=lambda kv: -kv[1])),
        "sample_bucket_x_tick": dict(sorted(samp_tick.items(), key=lambda kv: -kv[1])),
        "population_buckets": tot(pop_bucket), "population_first_blocker": tot(pop_first),
        "population_flags": {k: dict(sorted(v.items())) for k, v in pop_flags.items()},
    }

    if a.skip_population:
        rows = owing_proof.replica_rows(verify_notify.trino)
        told = owing_proof.told_users(a.ledger)
        by_user: dict[int, list[list[str]]] = defaultdict(list)
        for r in rows:
            by_user[int(r[0])].append(r)
        skipped: dict[int, dict[str, Any]] = {}
        for uid, rs in by_user.items():
            owe, cls = owing_proof.owed(rs, uid in held)
            if not owe or cls != "uvn":
                continue
            marker = any(r[6] == "1" for r in rs)
            if uid in told or marker:
                skipped[uid] = {"ledger": uid in told, "marker": marker, "owed": len(owe),
                                "owed_with_marker": sum(1 for r in owe.values() if r[6] == "1"),
                                "paid": any(r[4] == "1" for r in rs)}
        split: Counter = Counter()
        for s in skipped.values():
            split["ledger_and_marker" if s["ledger"] and s["marker"] else
                  "ledger_only" if s["ledger"] else "marker_only"] += 1
        # marker-only users: does the marker carry a notice timestamp at all, and how old is it
        mo = sorted(u for u, s in skipped.items() if not s["ledger"])
        notice: Counter = Counter()
        newest: dict[int, str] = {}
        has_marker_rows: Counter = Counter()
        for i in range(0, len(mo), 500):
            chunk = ",".join(str(x) for x in mo[i:i + 500])
            for uid, n_marker, n_notice, last_notice, n_resp in verify_notify.trino(
                    "SELECT CAST(userid AS varchar), CAST(count(*) AS varchar), "
                    "CAST(count(json_extract_scalar(metadata, '$.proofRequest.noticeSentAt')) AS varchar), "
                    "coalesce(max(json_extract_scalar(metadata, '$.proofRequest.noticeSentAt')), ''), "
                    "CAST(count(json_extract_scalar(metadata, '$.proofRequest.responseAt')) AS varchar) "
                    "FROM postgresql_core.public.credit_requests WHERE deletedat IS NULL "
                    "AND status IN ('unverified', 'processing', 'user_verification_needed') "
                    "AND json_extract(metadata, '$.proofRequest') IS NOT NULL "
                    f"AND userid IN ({chunk}) GROUP BY 1"):
                newest[int(uid)] = last_notice
                has_marker_rows["users"] += 1
                notice["marker_has_noticeSentAt" if int(n_notice) else "marker_without_noticeSentAt"] += 1
                if int(n_resp):
                    notice["user_responded(responseAt)"] += 1
                if last_notice:
                    notice["notice_year_month:" + last_notice[:7]] += 1
        srng = random.Random(a.seed)
        ssample = srng.sample(sorted(skipped), min(a.n, len(skipped)))
        sb: Counter = Counter()
        for uid in ssample:
            s = skipped[uid]
            sent = [r for r in led.get(str(uid), []) if r["status"] == "sent" and r["campaign"] == "uvn-status"]
            if sent:
                k = "ledger_sent_uvn_ask"
                k += ":delivered_id" if all(r["delivered"] for r in sent) else ":no_message_id"
                if any(r["tagged"] or r["replied"] for r in sent):
                    k += ":reply_or_proof_stamped"
            elif newest.get(uid):
                k = "core_marker_only:notice_" + newest[uid][:7]
            else:
                k = "core_marker_only:no_noticeSentAt"
            sb[k] += 1
        res["skipped"] = {
            "population": len(skipped), "paid": sum(1 for s in skipped.values() if s["paid"]),
            "rests_on": dict(split), "marker_only_users": len(mo), "marker_only_replica_users": has_marker_rows["users"],
            "marker_only_notice": dict(sorted(notice.items())), "sample": len(ssample), "sample_split": dict(sb),
            "owed_rows_total": sum(s["owed"] for s in skipped.values()),
            "owed_rows_carrying_marker": sum(s["owed_with_marker"] for s in skipped.values()),
        }
    json.dump(res, sys.stdout, indent=1, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
