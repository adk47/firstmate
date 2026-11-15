"""Read-only: rows on file per doc-verify run id, for the runs since SINCE.

Run on node-8 as `ssh root@<node-8> 'nice -n 10 python3 - <SINCE>' < per_run.py`.
Opens both sqlite files with mode=ro. SELECT only. Prints JSON: no person, request or
document id, only run ids, counts and times.

Every query is bounded on the integer primary key, because neither table has an index
on run_id: the low id is found by bisection on `at`, which rises with `id`.
"""
import json
import sqlite3
import sys
import time

STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
GATEWAY = "/root/.openclaw-main/state/openclaw.sqlite"
JOB = "ba2972be-31ed-59a0-b0cc-b950bec9cf81"
SINCE = sys.argv[1] if len(sys.argv) > 1 else "2026-11-14T17:45:00Z"

t0 = time.time()
db = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True, timeout=30)


def low_id(table: str) -> tuple[int, int]:
    hi = db.execute(f"SELECT MAX(id) FROM {table}").fetchone()[0] or 0
    lo, top = 0, hi
    while lo < top:                                   # first id whose `at` >= SINCE
        mid = (lo + top) // 2
        row = db.execute(f"SELECT id, at FROM {table} WHERE id >= ? ORDER BY id LIMIT 1", (mid,)).fetchone()
        if row is None or row[1] >= SINCE:
            top = mid
        else:
            lo = row[0] + 1
    return lo, hi


s_lo, s_hi = low_id("dv_steps")
o_lo, o_hi = low_id("dv_outcomes")
runs: dict[str, dict] = {}
for run_id, n, docs, gate, hold, errs, first, last in db.execute(
        "SELECT run_id, COUNT(*), COUNT(DISTINCT proof_id), SUM(step='gate'), SUM(step='account_hold'), "
        "SUM(status='error'), MIN(at), MAX(at) FROM dv_steps WHERE id >= ? GROUP BY run_id", (s_lo,)):
    runs[run_id] = {"steps": n, "documents_with_a_step": docs, "gate_steps": gate or 0,
                    "account_hold_steps": hold or 0, "error_steps": errs or 0, "first": first, "last": last,
                    "outcomes": 0, "outcome_words": {}}
for run_id, word, n in db.execute(
        "SELECT run_id, outcome, COUNT(*) FROM dv_outcomes WHERE id >= ? GROUP BY run_id, outcome", (o_lo,)):
    r = runs.setdefault(run_id, {"steps": 0, "documents_with_a_step": 0, "gate_steps": 0, "account_hold_steps": 0,
                                 "error_steps": 0, "first": None, "last": None, "outcomes": 0, "outcome_words": {}})
    r["outcomes"] += n
    r["outcome_words"][word] = n
# a run id older than SINCE whose rows straddle the bound would be cut: name them
straddle = [r[0] for r in db.execute("SELECT DISTINCT run_id FROM dv_steps WHERE id >= ? AND id < ?",
                                     (max(0, s_lo - 2000), s_lo))]
plan = [r[3] for r in db.execute("EXPLAIN QUERY PLAN SELECT COUNT(*) FROM dv_steps WHERE run_id = ?", ("x",))]
plan += [r[3] for r in db.execute("EXPLAIN QUERY PLAN SELECT COUNT(*) FROM dv_outcomes WHERE run_id = ?", ("x",))]

gw = sqlite3.connect(f"file:{GATEWAY}?mode=ro", uri=True, timeout=30)
since_ms = int(time.mktime(time.strptime(SINCE, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone) * 1000
ticks = [{"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(a / 1000)),
          "finished": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(b / 1000)) if b else None,
          "status": s, "error_text": (e or "")[:200]}
         for a, b, s, e in gw.execute("SELECT started_at_ms, finished_at_ms, status, error_text FROM cron_run_receipts "
                                      "WHERE job_id = ? AND started_at_ms >= ? ORDER BY started_at_ms",
                                      (JOB, since_ms))]
print(json.dumps({"measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "since": SINCE,
                  "dv_steps": {"low_id": s_lo, "max_id": s_hi}, "dv_outcomes": {"low_id": o_lo, "max_id": o_hi},
                  "runs": runs, "run_ids_straddling_the_bound": straddle, "run_id_query_plan": plan,
                  "ticks": ticks, "seconds": round(time.time() - t0, 2)}, indent=1, sort_keys=True))
