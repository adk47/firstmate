# Stage B on node-8: the sender's dry run over the 41-user list. It asks core's route with apply=false for every
# user `plan` did not hold, writes `dry` rows to the ledger, and sends nothing.
cd /tmp/precedent-untold-tell-r1 || exit 9
nohup bash -c '
date -u +%FT%TZ
rm -f dry41.json
timeout 1500 python3 /opt/hydra/scripts/credit-decision-told.py dry --list list41.json --list-sha "$(cat list41.json.sha)" --limit 41 --out dry41.json > dry41.out 2> dry41.err
echo "dry rc=$?"; date -u +%FT%TZ; echo STAGE_B_DONE
' > b.log 2>&1 &
echo started
