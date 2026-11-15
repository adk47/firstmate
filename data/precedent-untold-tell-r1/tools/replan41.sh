# Read-only: plan the 41 with this branch's decision_told.py (the delivery key), against a COPY of the ledger's
# decision_told table. Nothing is written to the live ledger, no route is called, nothing is sent.
# stdin prefix (written by the caller) places the branch's decision_told.py and credit-decision-told.py in $W/new.
set -u
W=/tmp/precedent-untold-tell-r1
date -u +%FT%TZ
while [ "$(systemctl is-active credit-notify-tick.service)" = activating ] || [ "$(systemctl is-active credit-notify-tick.service)" = active ]; do sleep 15; done
echo "tick idle at $(date -u +%FT%TZ)"
mkdir -p $W/new/credit_review
for f in /opt/hydra/scripts/credit_review/*.py; do b=$(basename $f); [ "$b" = decision_told.py ] || ln -sf "$f" "$W/new/credit_review/$b"; done
sha256sum $W/new/credit_review/decision_told.py $W/new/credit-decision-told.py /opt/hydra/scripts/credit_review/decision_told.py
sha256sum $W/list41.json
cd $W/new && timeout 900 python3 - <<'P'
import importlib.util, json, sqlite3, sys, io, contextlib
sys.path.insert(0, ".")
LIVE = "/var/lib/hydra/credit-review/ledger.sqlite3"
copy = "/tmp/precedent-untold-tell-r1/decision_told_copy.sqlite3"
import os
if os.path.exists(copy): os.remove(copy)
c = sqlite3.connect(copy)
c.execute("ATTACH DATABASE 'file:%s?mode=ro' AS live" % LIVE) if False else None
src = sqlite3.connect("file:%s?mode=ro" % LIVE, uri=True, timeout=30)
ddl = src.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='decision_told'").fetchone()[0]
c.execute(ddl)
rows = src.execute("SELECT * FROM decision_told").fetchall()
c.executemany("INSERT INTO decision_told VALUES (%s)" % ",".join("?" * len(rows[0])), rows)
c.commit(); c.close()
print("copied decision_told rows:", len(rows), "max id:", max(r[0] for r in rows))
spec = importlib.util.spec_from_file_location("cdt", "credit-decision-told.py")
cdt = importlib.util.module_from_spec(spec); spec.loader.exec_module(cdt)
import hashlib
sha = hashlib.sha256(open("/tmp/precedent-untold-tell-r1/list41.json", "rb").read()).hexdigest()[:12]
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = cdt.main(["plan", "--list", "/tmp/precedent-untold-tell-r1/list41.json", "--list-sha", sha, "--limit", "41"],
                  ledger=copy, verify_ledger=LIVE)
out = json.loads(buf.getvalue())
print("rc", rc, "users", out.get("users"), "eligible", out.get("eligible"), "held", out.get("held"), "refused", out.get("refused"))
from credit_review import decision_told as dt
db = sqlite3.connect(copy)
tried, told = dt.attempts(db), dt.told(db)
for key in ("plans", "ready", "users_plan", "eligible_users"):
    if isinstance(out.get(key), list):
        print("list key:", key, len(out[key]))
print("keys:", sorted(out))
ids = [int(u["user_id"]) for u in json.load(open("/tmp/precedent-untold-tell-r1/list41.json"))["users"]]
for u in sorted(ids):
    t = tried.get(u, {})
    print(u, "last_attempt", max(t.values()) if t else "-", "attempted_groups", len(t), "sent_groups", len(told.get(u, ())))
json.dump(out, open("/tmp/precedent-untold-tell-r1/replan41.json", "w"))
P
echo "rc=$?"
python3 - <<'P'
import json
o = json.load(open("/tmp/precedent-untold-tell-r1/replan41.json"))
def strip(x):
    if isinstance(x, dict):
        return {k: (len(v) if k == "subject_ids" else strip(v)) for k, v in x.items()}
    if isinstance(x, list):
        return [strip(i) for i in x]
    return x
print("REPLAN_JSON " + json.dumps(strip(o)))
P
date -u +%FT%TZ
