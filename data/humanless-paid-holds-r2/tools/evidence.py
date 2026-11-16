import sqlite3, json, collections, time
def ro(p): return sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30)
L = ro("/var/lib/hydra/credit-review/ledger.sqlite3")
P = ro("/var/lib/hydra-credit-verify/proof.sqlite")
D = ro("/var/lib/hydra-credit-verify/doc-verify.sqlite")
t=time.time()
for db,name in ((P,"proof"),(D,"docverify")):
    for n,s in db.execute("select name, sql from sqlite_master where type='index'"):
        if any(k in (s or n) for k in ("stage2_shadow","dv_outcomes","verdicts")): print(name, "IDX", n, s)
print(P.execute("select sql from sqlite_master where name='verdicts'").fetchone()[0])
def grp(r):
    if r.startswith("score approval not now"): return "score"
    if r.startswith("proof on file: stage 2 judged"): return "stage2"
    if "human review" in r: return "human"
rows = L.execute("select request_id,user_id,claimed_roles,reason,popularity,big_track,mode,decided_at from decisions where id in (select max(id) from decisions group by request_id) and paid_priority=1").fetchall()
held = {r[0].lower(): (grp(r[3]),)+r[1:] for r in rows if grp(r[3])}
print("held", len(held), collections.Counter(v[0] for v in held.values()), round(time.time()-t,1))
ids = list(held)
def batched(db, sql):
    out=[]
    for i in range(0,len(ids),400):
        b=ids[i:i+400]
        out += db.execute(sql % ",".join("?"*len(b)), b).fetchall()
    return out
s2 = batched(P, "select lower(request_id),role,outcome,judged_at,id,analyzer_version from stage2_shadow where lower(request_id) in (%s)")
print("stage2 rows", len(s2), round(time.time()-t,1))
latest={}
for rid,role,o,at,i,v in s2:
    k=(rid,role)
    if k not in latest or i>latest[k][0]: latest[k]=(i,o,at,v)
c=collections.Counter(); 
for (rid,role),(i,o,at,v) in latest.items(): c[(held[rid][0],o)]+=1
print("stage2 latest per (req,role) by group/outcome:"); [print("  ",k,n) for k,n in sorted(c.items())]
print("stage2 versions", collections.Counter(v[3] for v in latest.values()), "judged_at range", min(v[2] for v in latest.values()), max(v[2] for v in latest.values()))
print("requests with any stage2 row by group", collections.Counter(held[r][0] for r in {k[0] for k in latest}))
dv = batched(D, "select lower(request_id),role,outcome,need,at,id,version,h3_verdict,account_hold from dv_outcomes where lower(request_id) in (%s)")
print("dv rows", len(dv), round(time.time()-t,1))
dl={}
for rid,role,o,need,at,i,v,h3,ah in dv:
    k=(rid,role)
    if k not in dl or i>dl[k][0]: dl[k]=(i,o,need,at,v,h3,ah)
c=collections.Counter()
for (rid,role),x in dl.items(): c[(held[rid][0],x[1],x[2],x[4])]+=1
print("dv latest per (req,role) by group/outcome/need/version:"); [print("  ",k,n) for k,n in sorted(c.items(), key=lambda kv:(kv[0][0],-kv[1]))]
print("requests with any dv row by group", collections.Counter(held[r][0] for r in {k[0] for k in dl}))
print("dv at range", min(x[3] for x in dl.values()), max(x[3] for x in dl.values()), "account_hold", collections.Counter(x[6] for x in dl.values()))
# role-shape check
ex=[(rid, held[rid][2], sorted(r for (q,r) in latest if q==rid)[:6], sorted(r for (q,r) in dl if q==rid)[:6]) for rid in ids[:4000:800]]
for e in ex: print("ROLES", e[1], "| s2:", e[2], "| dv:", e[3])
