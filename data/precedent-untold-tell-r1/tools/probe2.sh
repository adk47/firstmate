python3 - <<'P'
import sqlite3, json, collections
ids=[6678,17097,19104,19327,22104,26504,27448,27927,29419,32439,50621,53479,56521,61588,63778,68272,70317,72407,75714,77481,78042,84189,91567,96293,96558,99416,100814,102783,109550,109681,119162,119526,153177,155423,212494,230556,233234,243908,252460,255205,270441,275342,279975,288257,291623,304550,305363,319572,325208,336111,347304,368676,368924]
db=sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro",uri=True,timeout=30)
q="select id,run_id,at,user_id,group_key,copy_ref,subject_ids_json,mode,outcome,report_json from decision_told where user_id in (%s) order by user_id,id" % ",".join("?"*len(ids))
rows=db.execute(q,ids).fetchall()
by=collections.defaultdict(list)
for r in rows: by[r[3]].append(r)
out=[]
for u in ids:
    rs=by.get(u,[])
    live=[r for r in rs if r[7]=='apply']
    dry=[r for r in rs if r[7]=='dry']
    rec={"user_id":u,"live_outcomes":sorted({r[8] for r in live}),"live_rows":[(r[0],r[1],r[2],r[8]) for r in live],
         "live_groups":sorted({r[4] for r in live}),"copy_refs":sorted({r[5] for r in rs}),
         "n_subjects_live":[len(json.loads(r[6])) for r in live if r[8]=='attempt'],
         "dry_counts":dict(collections.Counter(r[8] for r in dry)),"last_dry":(dry[-1][2],dry[-1][8]) if dry else None}
    errs=[r for r in live if r[8]=='error']
    if errs:
        try: rec["error"]=json.loads(errs[-1][9]).get("error")
        except Exception as e: rec["error"]="unreadable:"+str(e)
    if dry and dry[-1][8]=='dry_refused':
        try: rec["last_dry_error"]=json.loads(dry[-1][9]).get("error")
        except Exception as e: rec["last_dry_error"]="unreadable"
    out.append(rec)
print(json.dumps(out))
P
echo "=====LASTRUN"; cat /var/lib/hydra/credit-review/notify-tick/last-run.json
