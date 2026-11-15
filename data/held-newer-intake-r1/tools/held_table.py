#!/usr/bin/env python3
"""Read-only: which paid users does the builder's newer-intake hold drop, and what are the two dates it compares.

Run on node-8:  python3 held_table.py /root/h2-runs/sched/<tick>/need-asks-all.json [check.out]

Reads the builder's own list (need_asks.py build --out) and the deployed predicate (comm_state.newer_intake). It
opens no store and writes nothing. The grouping is the one in need_asks.payloads(): per need, the newest document,
then the documents of that day in the same filing thread. What it does NOT repeat is payloads()'s live re-read of
which requests are still pending and not yet asked, so it lists every need group on the list, not only the ones the
run reached.
"""
import json
import statistics
import subprocess
import sys
from datetime import datetime

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import comm_state  # noqa: E402  (the deployed predicate, never a copy)

NEED_ORDER = ("counterparty_signed_or_registered", "readable_document", "distributor_dashboard_with_code")
TRINO = "/opt/hydra/scripts/trino-query.sh"


def ts(s):
    return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")


def gap_text(sec):
    if sec < 120:
        return f"{int(sec)} s"
    if sec < 2 * 3600:
        return f"{sec / 60:.0f} min"
    if sec < 2 * 86400:
        return f"{sec / 3600:.1f} h"
    return f"{sec / 86400:.1f} d"


def main():
    listed = json.load(open(sys.argv[1]))
    paid = [u for u in listed["users"] if u.get("paid")]
    rows, pairs, every_need = {}, [], 0
    for u in paid:
        uid, arrivals = str(u["user_id"]), u.get("arrivals") or []
        needs = {a["need"] for a in u["asks"]} & set(NEED_ORDER)
        n_before = len(pairs)
        ask_by_intake = {str(a.get("intake_id") or ""): a["need"] for a in u["asks"] if a.get("intake_id")}
        for need in NEED_ORDER:
            cand = [a for a in u["asks"] if a["need"] == need]
            if not cand:
                continue
            newest = max(cand, key=lambda a: (a["doc_received_at"], a["doc_sha"]))
            docs = [a for a in cand if a["doc_received_at"][:10] == newest["doc_received_at"][:10]
                    and a["filing_conversation"] == newest["filing_conversation"]]
            named = {str(a.get("intake_id") or "") for a in docs if a.get("intake_id")}
            if not comm_state.newer_intake(newest["doc_received_at"], arrivals, named):
                continue
            pairs.append(f"user {uid}: {need}")
            if uid in rows:
                continue
            doc_at = newest["doc_received_at"]
            later = [(a[0], str(a[1] or "")) for a in arrivals
                     if ts(a[0]) > ts(doc_at) or (ts(a[0]) == ts(doc_at) and a[1] and str(a[1]) not in named)]
            last_at, last_id = max(later)
            rows[uid] = {"uid": uid, "need": need, "doc_at": doc_at, "intake_at": last_at, "later": len(later),
                         "gap": (ts(last_at) - ts(doc_at)).total_seconds(),
                         "later_on_list": ask_by_intake.get(last_id, "")}
        if needs and len(pairs) - n_before == len(needs):
            every_need += 1
            rows[uid]["every_need"] = True
    held = sorted(rows.values(), key=lambda r: int(r["uid"]))
    gaps = [r["gap"] for r in held]
    print(f"list generated_at={listed.get('generated_at')} paid_users={len(paid)} "
          f"held_users={len(held)} held_pairs={len(pairs)}")
    print("gap between the named document and the user's newest intake, all held users: "
          f"median {gap_text(statistics.median(gaps))}; "
          f"same second {sum(g == 0 for g in gaps)}, under 10 min {sum(0 < g < 600 for g in gaps)}, "
          f"10 min to 24 h {sum(600 <= g < 86400 for g in gaps)}, 1 to 30 d {sum(86400 <= g < 30 * 86400 for g in gaps)}, "
          f"over 30 d {sum(g >= 30 * 86400 for g in gaps)}")
    print(f"newest intake is itself an askable document on this list: {sum(bool(r['later_on_list']) for r in held)} "
          f"of {len(held)}")
    print(f"held on EVERY need they have on the list (no payload possible): {every_need} of {len(held)}")
    if len(sys.argv) > 2:
        t = open(sys.argv[2]).read()
        ex = json.loads(t[t.find("{"):]).get("held_newer_examples") or []
        miss = [e.split(" (")[0] for e in ex if e.split(" (")[0] not in pairs]
        print(f"cross-check: {len(ex) - len(miss)} of {len(ex)} held_newer_examples of that run are in this "
              f"recomputation; missing: {miss}")
    step = max(1, len(held) // 10)
    pick = held[::step][:10]                      # every step-th held user by user id: no hand picking
    ids = ",".join(str(int(r["uid"])) for r in pick)
    sql = ("SELECT userid, CAST(max(createdat) AS varchar) FROM postgresql_core.public.credit_requests "
           f"WHERE userid IN ({ids}) AND deletedat IS NULL GROUP BY userid")
    out = subprocess.run([TRINO, sql], capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        print(f"core read failed rc={out.returncode}: {out.stderr.strip()[-300:]}")
    created = {}
    for line in out.stdout.splitlines():
        p = [x.strip().strip('"') for x in line.split(",", 1)]
        if len(p) == 2 and p[0].isdigit():
            created[p[0]] = p[1][:19].replace(" ", "T") + "Z"
    print()
    print("| user | need the ask would name | named document arrived | newest intake arrived | gap | later intakes "
          "| newest intake askable on this list | held on every need | newest credit_requests.createdat |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in sorted(pick, key=lambda r: -r["gap"]):
        print(f"| {r['uid']} | {r['need']} | {r['doc_at']} | {r['intake_at']} | {gap_text(r['gap'])} | {r['later']} "
              f"| {r['later_on_list'] or 'no'} | {'yes' if r.get('every_need') else 'no'} "
              f"| {created.get(r['uid'], 'not read')} |")


if __name__ == "__main__":
    main()
