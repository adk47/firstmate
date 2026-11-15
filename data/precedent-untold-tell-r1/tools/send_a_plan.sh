# Stage A on node-8: build the class list with the tick's own builder, narrow it to the 41 ids, and ask the
# sender's `plan` what it would do. `plan` calls no route and sends nothing.
set -u
W=/tmp/precedent-untold-tell-r1; mkdir -p "$W"; cd "$W" || exit 9
IDS="6678 17097 19104 19327 26504 27448 27927 32439 50621 53479 56521 61588 63778 68272 72407 75714 77481 96293 99416 109550 109681 119526 153177 155423 230556 233234 243908 252460 255205 270441 279975 288257 291623 304550 305363 319572 325208 336111 347304 368676 368924"
nohup bash -c '
date -u +%FT%TZ
IDS="'"$IDS"'" python3 - <<P
import importlib.util, json, os, sys
sys.path.insert(0, "/opt/hydra/scripts")
spec = importlib.util.spec_from_file_location("tick", "/opt/hydra/scripts/credit-notify-tick.py")
tick = importlib.util.module_from_spec(spec); spec.loader.exec_module(tick)
from credit_review import decision_told as dt
doc = tick.build_list()
if doc is None: sys.exit("class list could not be built")
want = [int(x) for x in os.environ["IDS"].split()]
by = {int(u["user_id"]): u for u in doc["users"]}
print("class users", len(doc["users"]), "wanted", len(want), "missing from class", [u for u in want if u not in by])
header = {k: v for k, v in doc.items() if k != "users"}
def write(name, ids):
    users = [by[u] for u in ids if u in by]
    raw = json.dumps({**header, "users": users}).encode()
    open(name, "wb").write(raw)
    print(name, "users", len(users), "requests", sum(len(u["facts"]) for u in users), "sha", dt.file_sha(raw))
    open(name + ".sha", "w").write(dt.file_sha(raw))
write("list41.json", want)
write("list2.json", [99416, 288257])
P
echo "build rc=$?"; date -u +%FT%TZ
for n in list41 list2; do
  [ -s $n.json ] || continue
  timeout 1500 python3 /opt/hydra/scripts/credit-decision-told.py plan --list $n.json --list-sha "$(cat $n.json.sha)" --limit 41 > plan-$n.out 2> plan-$n.err
  echo "plan $n rc=$?"; date -u +%FT%TZ
done
echo STAGE_A_DONE
' > a.log 2>&1 &
echo started
