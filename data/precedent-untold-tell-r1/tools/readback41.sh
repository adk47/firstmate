date -u +%FT%TZ
python3 - <<'P'
import sqlite3, json
ids=[6678,17097,19104,19327,26504,27448,27927,32439,50621,53479,56521,61588,63778,68272,72407,75714,77481,96293,99416,109550,109681,119526,153177,155423,230556,233234,243908,252460,255205,270441,279975,288257,291623,304550,305363,319572,325208,336111,347304,368676,368924]
told12=[22104,29419,70317,78042,84189,91567,96558,100814,102783,119162,212494,275342]
db=sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro",uri=True,timeout=30)
def q(sql,a): return db.execute(sql%",".join("?"*len(a)),a).fetchall()
print("ids41", len(ids))
print("41 rows_by_mode_outcome(rows,users)", q("select mode,outcome,count(*),count(distinct user_id) from decision_told where user_id in (%s) group by 1,2 order by 1,2",ids))
print("41 sent_apply_users", q("select count(distinct user_id) from decision_told where mode='apply' and outcome='sent' and user_id in (%s)",ids))
print("41 max_apply_at", q("select max(at) from decision_told where mode='apply' and user_id in (%s)",ids))
print("41 rows since 2026-11-14T20:50Z", q("select id,run_id,at,user_id,mode,outcome,substr(report_json,1,160) from decision_told where at>='2026-11-14T20:50:00Z' and user_id in (%s) order by id",ids))
print("12 told: rows since 2026-11-14T20:37Z", q("select count(*) from decision_told where at>='2026-11-14T20:37:00Z' and user_id in (%s)",told12))
print("my run", db.execute("select mode,outcome,count(*) from decision_told where run_id='decision-told-dry-62fcd9c893' group by 1,2").fetchall())
print("fleet apply", db.execute("select outcome,count(distinct user_id) from decision_told where mode='apply' group by 1").fetchall())
P
cat /var/lib/hydra/credit-review/notify-tick-status.txt
cat /var/lib/hydra/credit-review/notify-tick/last-run.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({k:d[k] for k in ("carried","sent","untold","stopped","sender_failures")}))'
stat -c '%y' /var/lib/hydra/credit-review/notify-tick/last-run.json
