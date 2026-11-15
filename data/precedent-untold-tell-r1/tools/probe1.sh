set -u
L=/var/lib/hydra/credit-review/ledger.sqlite3
ls -la /var/lib/hydra/credit-review/ | head -30
echo "--- kill files"; ls -la /etc/hydra/*.disabled 2>&1 | head -40
echo "--- tables"
python3 - <<'P'
import sqlite3
db=sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro",uri=True,timeout=30)
print(sorted(r[0] for r in db.execute("select name from sqlite_master where type='table'")))
print(db.execute("select sql from sqlite_master where name='decision_told'").fetchone()[0])
print("decision_told by mode/outcome:", db.execute("select mode,outcome,count(*),count(distinct user_id) from decision_told group by 1,2").fetchall())
print("last rows:", db.execute("select id,run_id,at,user_id,mode,outcome from decision_told order by id desc limit 5").fetchall())
print("apply attempts today:", db.execute("select count(distinct user_id) from decision_told where mode='apply' and outcome='attempt' and substr(at,1,10)=strftime('%Y-%m-%d','now')").fetchone())
P
echo "--- tick status"; cat /var/lib/hydra/credit-review/notify-tick-status.txt 2>&1; ls -la /var/lib/hydra/credit-review/notify-tick/ 2>&1 | tail -8
echo "--- timer"; systemctl list-timers --all 2>/dev/null | grep -i 'notify\|decision' ; systemctl is-active credit-notify-tick.timer; systemctl is-enabled credit-notify-tick.timer
echo "--- deployed sha"; cat /opt/hydra/.deployed-sha 2>&1; echo; sha256sum /opt/hydra/scripts/credit-notify-tick.py /opt/hydra/scripts/credit-decision-told.py /opt/hydra/scripts/credit_review/decision_told.py /opt/hydra/scripts/credit_review/notify_chunks.py /opt/hydra/scripts/credit_review/notify_tick.py /root/mklist2.js 2>&1
