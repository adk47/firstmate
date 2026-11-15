date -u +%FT%TZ
sha256sum /tmp/prec_untold_users.txt
python3 - <<'P'
import sqlite3, re, collections
ids=sorted({int(x) for x in re.findall(r"\d+", open("/tmp/prec_untold_users.txt").read())})
print("ids", len(ids))
db=sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro",uri=True,timeout=30)
ph=",".join("?"*len(ids))
print("rows_by_mode_outcome", db.execute("select mode,outcome,count(*),count(distinct user_id) from decision_told where user_id in (%s) group by 1,2 order by 1,2"%ph,ids).fetchall())
print("sent_apply_users", db.execute("select count(distinct user_id) from decision_told where mode='apply' and outcome='sent' and user_id in (%s)"%ph,ids).fetchone())
print("max_apply_at_for_53", db.execute("select max(at) from decision_told where mode='apply' and user_id in (%s)"%ph,ids).fetchone())
print("apply_rows_since_2037Z_for_53", db.execute("select count(*) from decision_told where mode='apply' and at>='2026-11-14T20:37:00Z' and user_id in (%s)"%ph,ids).fetchone())
print("fleet", db.execute("select mode,outcome,count(distinct user_id) from decision_told where mode='apply' group by 1,2").fetchall())
print("fleet_max_at", db.execute("select max(at) from decision_told").fetchone())
P
cat /var/lib/hydra/credit-review/notify-tick-status.txt
