# Read-only read-back after the re-plan under the delivery key. Removes this task's ledger copy from /tmp.
date -u +%FT%TZ
rm -f /tmp/precedent-untold-tell-r1/decision_told_copy.sqlite3 /tmp/precedent-untold-tell-r1/replan41.json
ls /tmp/precedent-untold-tell-r1/
python3 - <<'P'
import json, sqlite3
ids = [int(u["user_id"]) for u in json.load(open("/tmp/precedent-untold-tell-r1/list41.json"))["users"]]
told12 = [22104, 29419, 70317, 78042, 84189, 91567, 96558, 100814, 102783, 119162, 212494, 275342]
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True, timeout=30)
q = ",".join(map(str, ids))
print("ids", len(ids))
print("apply rows for the 41 by outcome (rows, users):", db.execute(
    f"SELECT outcome, count(*), count(DISTINCT user_id) FROM decision_told WHERE mode='apply' AND user_id IN ({q}) GROUP BY 1").fetchall())
print("users of the 41 with a sent apply row:", db.execute(
    f"SELECT count(DISTINCT user_id) FROM decision_told WHERE mode='apply' AND outcome='sent' AND user_id IN ({q})").fetchone()[0])
print("newest apply row for the 41:", db.execute(f"SELECT max(at) FROM decision_told WHERE mode='apply' AND user_id IN ({q})").fetchone()[0])
print("rows of any mode for the 41 since 2026-11-14T21:10Z:")
for r in db.execute(f"SELECT id, at, user_id, mode, outcome, substr(report_json, 1, 150) FROM decision_told WHERE user_id IN ({q}) AND at > '2026-11-14T21:10:00Z' ORDER BY id"):
    print(" ", r)
print("rows for the 12 since 2026-11-14T20:37Z:", db.execute(
    "SELECT count(*) FROM decision_told WHERE user_id IN (%s) AND at > '2026-11-14T20:37:00Z'" % ",".join(map(str, told12))).fetchone()[0])
print("our 3 dry rows:", db.execute("SELECT id, at, user_id, mode, outcome, run_id FROM decision_told WHERE id BETWEEN 4428 AND 4430").fetchall())
print("fleet apply:", db.execute("SELECT outcome, count(DISTINCT user_id) FROM decision_told WHERE mode='apply' GROUP BY 1").fetchall())
print("triggers:", [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='decision_told'")])
P
cat /var/lib/hydra/credit-review/notify-tick-status.txt
python3 -c "
import json; o=json.load(open('/var/lib/hydra/credit-review/notify-tick/last-run.json')); print('carried', o['carried'], 'sent', len(o['sent']), 'untold', o['untold'], 'stopped', repr(o['stopped']))"
stat -c '%y' /var/lib/hydra/credit-review/notify-tick/last-run.json
