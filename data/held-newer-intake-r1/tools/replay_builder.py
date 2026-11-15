"""Builder replay: who gets a proof-need-ask payload under the deployed rule and under this branch's rule.

Read-only. Runs on node-8 from stdin (nothing is written there): run_replay.sh prepends `SRC`, the base64 source of
this branch's comm_state.py and need_asks.py, and every other module is the deployed one under /opt/hydra/scripts.
Both rules are run over the SAME list file, the SAME ledger read and the SAME replica answers (each distinct statement
is asked once and replayed), so the two columns differ only by the rule.

What it does NOT measure: the gate. No gate call is made. `need_facts` below is this branch's own send-time check,
called directly; on node-8 the gate reads the deployed comm_state.py until a deploy.

usage (through run_replay.sh):  python3 -I - <need-asks-all.json> [page_start page_len max_users]
"""
import base64
import copy
import json
import sys
import time
import types
from collections import Counter

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import comm_state as cs_old  # noqa: E402
from credit_review import need_asks as na_old  # noqa: E402
from credit_review import uvn_status, verify_ledger  # noqa: E402


def load(name):
    mod = types.ModuleType(f"credit_review._hni_{name}")
    mod.__file__ = f"/opt/hydra/scripts/credit_review/{name}.py"
    mod.__package__ = "credit_review"
    sys.modules[mod.__name__] = mod
    exec(compile(base64.b64decode(SRC[name]).decode(), f"<branch {name}.py>", "exec"), mod.__dict__)  # noqa: F821
    return mod


cs_new = load("comm_state")
na_new = load("need_asks")
na_new.comm_state = cs_new

CACHE = {}
LIVE = {"n": 0, "s": 0.0}


def q(sql):
    if sql not in CACHE:
        t = time.time()
        CACHE[sql] = uvn_status.trino(sql)
        LIVE["n"] += 1
        LIVE["s"] += time.time() - t
    return copy.deepcopy(CACHE[sql])


DB = verify_ledger.connect_ro(verify_ledger.DEFAULT_PATH, must_exist=True)


def run(na, users, max_users=None):
    """The steps need_asks._send takes before any gate call, with a read-only ledger."""
    users = copy.deepcopy(users)
    keys = sorted({a["request_id"] for u in users for a in u["asks"]})
    asked = set(verify_ledger.blocked_ids(DB, keys, na.CAMPAIGN)) if keys else set()
    told = verify_ledger.sent_request_ids(DB, na.ELSEWHERE_CAMPAIGN)
    asked |= {k for k in keys if str(k).lower() in told}
    live_users = [u for u in users if any(a["request_id"] not in asked for a in u["asks"])]
    held, filtered = [], []
    t = time.time()
    ps = na.payloads(live_users, q, asked, held, filtered)
    took = time.time() - t
    cut = ps if max_users is None else ps[:max_users]
    return {"listed": len(users), "already_asked": len(users) - len(live_users), "payloads": ps, "batch": cut,
            "held": held, "filtered": filtered, "seconds": took}


def uid_of(p):
    return str(p["user"]["id"])


def show(tag, r):
    held_users = {h.split(":")[0] for h in r["held"] if "an intake newer" in h}
    got = {uid_of(p) for p in r["payloads"]}
    print(f"  {tag}: listed {r['listed']}, every ask already in the ledger {r['already_asked']}, "
          f"users with a payload {len(got)}, held user-need pairs {sum('an intake newer' in h for h in r['held'])}, "
          f"users held on a need {len(held_users)}, users with no payload and a hold "
          f"{len({h for h in held_users if h.split()[-1] not in got})}, payloads() {r['seconds']:.1f}s")
    print(f"     payloads by need: {dict(Counter(p['need']['code'] for p in r['payloads']))}")
    print(f"     batch of {len(r['batch'])} by need: {dict(Counter(p['need']['code'] for p in r['batch']))}")
    print(f"     filtered reasons: {dict(Counter(f['reason'].split(' (')[0][:60] for f in r['filtered']).most_common(8))}")


def compare(users, max_users=None):
    by_uid = {str(u["user_id"]): u for u in users}
    old, new = run(na_old, users, max_users), run(na_new, users, max_users)
    show("deployed rule", old)
    show("this branch  ", new)
    po, pn = {uid_of(p): p for p in old["payloads"]}, {uid_of(p): p for p in new["payloads"]}
    gained, lost = sorted(set(pn) - set(po), key=int), sorted(set(po) - set(pn), key=int)
    changed = sorted((u for u in set(po) & set(pn)
                      if (po[u]["need"]["code"], po[u]["need"]["doc_sha"]) != (pn[u]["need"]["code"], pn[u]["need"]["doc_sha"])),
                     key=int)
    print(f"  users who gain a payload: {len(gained)}; lose one: {len(lost)}; keep one about a different document: {len(changed)}")

    def newest(uid, p):
        last = max((str(a[0])[:19] for a in by_uid[uid].get("arrivals") or []), default="")
        return p["need"]["doc_received_at"][:19] >= last

    for label, ids in (("gain", gained), ("different document", changed)):
        if not ids:
            continue
        n_new = sum(newest(u, pn[u]) for u in ids)
        twin = Counter()
        for u in ids:
            p = pn[u]["need"]
            try:
                f = cs_new.need_facts(int(u), [c["request_id"] for c in pn[u]["credits"]], p["doc_sha"],
                                      p["doc_received_at"], p["code"], doc_map=p.get("doc_map"),
                                      doc_intakes=p.get("doc_intakes"))
                twin["send-time check would hold (newer)" if f["newer"] else
                     "send-time check: not checked" if f["unchecked"] else "send-time check passes"] += 1
            except Exception as exc:  # noqa: BLE001 - reported, never guessed
                twin[f"send-time check raised {type(exc).__name__}"] += 1
        print(f"  {label} ({len(ids)}): ask names the user's newest intake {n_new}, an older document {len(ids) - n_new}; "
              f"by need {dict(Counter(pn[u]['need']['code'] for u in ids))}; {dict(twin)}")
        print(f"     first ids: {ids[:10]}")
    if lost:
        print(f"  lost ids: {lost[:10]}")
    if max_users is not None:
        bo, bn = [uid_of(p) for p in old["batch"]], [uid_of(p) for p in new["batch"]]
        print(f"  batch of {max_users}: {len(set(bo) & set(bn))} users in both, {len(set(bn) - set(bo))} new to it")


doc = json.load(open(sys.argv[1], encoding="utf-8"))
paid = [u for u in doc["users"] if u["paid"]]
print(f"list generated_at {doc.get('generated_at')}, users {len(doc['users'])}, paid {len(paid)}; "
      f"run at {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
print("whole paid segment:")
compare(paid)
if len(sys.argv) >= 5:
    start, length, cap = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    print(f"the tick's page [{start}, {start + length}) with --max-users {cap}:")
    compare(paid[start:start + length], cap)
print(f"replica statements asked once each: {LIVE['n']} in {LIVE['s']:.1f}s")
