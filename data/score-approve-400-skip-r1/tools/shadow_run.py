"""Read-only shadow run of THIS BRANCH's score_approve.py + admin.py on node-8, against production data.

It writes nothing on the host. The two modules are loaded from memory over the deployed tree, the ledger
is an in-memory database seeded from the real one (opened mode=ro, last 7 days of decisions and outcomes,
so rotation, cooldown and caps match production), and the mode is "shadow" (no PUT, no audit file). The
admin wrapper's own per-call bookkeeping runs as it does for any read.

The skip table starts empty in the in-memory ledger, so this measures one run: it does not exercise the
24 h announce rule across runs.

Run from the repository root (the two assignments are prepended, the result is one line on stdout):

    { echo "ADMIN_B64 = '$(base64 -w0 scripts/credit_review/admin.py)'"
      echo "SA_B64 = '$(base64 -w0 scripts/credit_review/score_approve.py)'"
      cat data/score-approve-400-skip-r1/tools/shadow_run.py
    } | ssh root@<node-8> 'cd /opt/hydra && PYTHONDONTWRITEBYTECODE=1 timeout 960 python3 -B -'

It reads core through the admin API at the job's own pace (150 profile reads, about 6 minutes), on the
rate limit the job and the decider share, so run it between score-approve fires.
"""
ADMIN_B64, SA_B64 = globals()["ADMIN_B64"], globals()["SA_B64"]  # prepended by the command above

import os as _os
for _f in ("/etc/openclaw/shared.env", "/etc/openclaw/main.env"):  # the gateway's (so the cron's) environment
    try:
        for _l in open(_f, encoding="utf-8"):
            _l = _l.strip()
            if _l and not _l.startswith("#") and "=" in _l:
                _k, _v = _l.split("=", 1)
                _os.environ.setdefault(_k.strip(), _v.strip().strip('"').strip("'"))
    except OSError:
        pass

import base64, json, os, sqlite3, sys, time, types
from datetime import datetime, timedelta, timezone
sys.dont_write_bytecode = True
sys.path.insert(0, "/opt/hydra/scripts")
import credit_review
def load(name, b64):
    fname = f"/opt/hydra/scripts/credit_review/{name}.py"
    m = types.ModuleType(f"credit_review.{name}")
    m.__package__, m.__file__ = "credit_review", fname
    sys.modules[m.__name__] = m
    setattr(credit_review, name, m)
    exec(compile(base64.b64decode(b64).decode(), fname, "exec"), m.__dict__)
    return m
admin_api = load("admin", ADMIN_B64)
sa = load("score_approve", SA_B64)
from credit_review import decide
assert decide.admin_api is admin_api if hasattr(decide, "admin_api") else True
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
now = datetime.now(timezone.utc)
db = sqlite3.connect("file::memory:", uri=True)
decide.ensure_schema(db)
db.execute(f"ATTACH DATABASE 'file:{LEDGER}?mode=ro' AS src")
since = (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
seeded = {}
for table, col in (("decisions", "decided_at"), ("decision_outcomes", "at")):
    mine = [r[1] for r in db.execute(f"PRAGMA main.table_info({table})")]
    theirs = {r[1] for r in db.execute(f"PRAGMA src.table_info({table})")}
    cols = ", ".join(c for c in mine if c in theirs and c != "id")
    seeded[table] = db.execute(f"INSERT INTO main.{table} ({cols}) SELECT {cols} FROM src.{table} WHERE {col} >= ? ORDER BY id",
                               (since,)).rowcount
db.commit()
db.execute("DETACH DATABASE src")
os.environ["MUSO_ADMIN_IDENTITY"] = decide.ADMIN_IDENTITY
policy, sp = decide.Policy.load(), sa.ScorePolicy.load()
calls = {"n": 0, "400": 0}
class Counting(admin_api.AdminClient):
    def get(self, path, params=None):
        calls["n"] += 1
        try:
            return super().get(path, params)
        except admin_api.BadRequest:
            calls["400"] += 1
            raise
t0 = time.monotonic()
out = {"started": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "deployed_sha": open("/opt/hydra/.deployed-sha").read().strip(),
       "seeded_rows_7d": seeded, "max_per_run": sp.max_per_run, "max_profiles_per_run": sp.max_profiles_per_run}
try:
    res = sa.run(Counting(), db, mode="shadow", policy=policy, sp=sp)
    out.update(ok=True, run_id=res.run_id, mode=res.mode, candidates=res.candidates, reread=res.reread,
               would_approve=res.would_approve, approved=res.approved, capped=res.capped, held=res.held,
               read_exhausted=res.read_exhausted, account_held=res.account_held, watch_held=res.watch_held,
               unreadable_profiles=[{"profile_id": s["profile_id"], "status": s["status"], "requests": len(s["request_ids"]),
                                     "reason": s["reason"]} for s in res.unreadable_profiles],
               unreadable_new=res.unreadable_new, note=res.note, line=res.line(),
               decisions_this_run=dict(db.execute("SELECT decision, COUNT(*) FROM decisions WHERE run_id = ? GROUP BY 1",
                                                  (res.run_id,)).fetchall()),
               profiles_decided=db.execute("SELECT COUNT(DISTINCT profile_id) FROM decisions WHERE run_id = ?",
                                           (res.run_id,)).fetchone()[0],
               users_would_approve=db.execute("SELECT COUNT(DISTINCT user_id) FROM decisions WHERE run_id = ? AND decision = 'approve'",
                                              (res.run_id,)).fetchone()[0],
               skip_rows=db.execute(f"SELECT COUNT(*) FROM {sa.UNREADABLE_TABLE}").fetchone()[0])
except Exception as exc:  # the figure is 'did not run', never a zero
    out.update(ok=False, error=f"{type(exc).__name__}: {str(exc)[:400]}")
out.update(seconds=round(time.monotonic() - t0, 1), admin_gets=calls["n"], admin_http_400=calls["400"])
print("SHADOW_RESULT " + json.dumps(out, sort_keys=True))
