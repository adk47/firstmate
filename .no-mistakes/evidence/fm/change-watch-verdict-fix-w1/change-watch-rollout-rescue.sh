#!/usr/bin/env bash
# End-to-end reproduction of the reported failure and its fix, run against the
# real bin/fm-change-watch.sh from this worktree (new) and from the base commit
# (old), with every cluster/forge read stubbed through the script's own seams.
#
# Scenario: a merge whose rollout is still landing at +15m (so that reading
# scores nothing), and whose +1h and +6h readings then measure the release.
#   old code -> unmeasurable-with-reason, teardown REFUSES the task forever
#   new code -> proven/clean, teardown gate passes
#   new rederive --apply -> repairs the row the old code left behind
set -u
REPO=$1
BASE=$2
NEW_CW=$REPO/bin/fm-change-watch.sh
# The old script resolves its sibling libs from its own directory, so it is
# staged in its own bin/ with the repo's libs beside it.
OLD_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-cw-old.XXXXXX")
OLD_CW="$OLD_BIN/fm-change-watch.sh"
git -C "$REPO" show "$BASE:bin/fm-change-watch.sh" > "$OLD_CW"
chmod +x "$OLD_CW"
for f in "$REPO"/bin/*; do
  [ "$(basename "$f")" = fm-change-watch.sh ] && continue
  ln -s "$f" "$OLD_BIN/$(basename "$f")"
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-cw-evidence.XXXXXX")
MANIFEST='k8s/prod/core-services/deployments.yaml'
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'
MULTI_MANIFEST='apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-backend-api
  namespace: muso-prod
spec:
  template:
    spec:
      containers:
        - name: core-backend-api
          env:
            - name: ENV
              value: production
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: feed-service
  namespace: muso-prod
spec:
  template:
    spec:
      containers:
        - name: feed-service
          env:
            - name: DB_HOST
              value: db-pool
---
apiVersion: v1
kind: Service
metadata:
  name: feed
  namespace: muso-prod
spec:
  selector:
    app: feed-service
'
printf '%s' "$MULTI_MANIFEST" > "$TMP_ROOT/multi.yaml"

new_world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/forge/content" "$home/cluster"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FM_CW_ARM_LOG"\n' > "$home/arm.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FM_CW_SEND_LOG"\n' > "$home/send.sh"
  chmod +x "$home/arm.sh" "$home/send.sh"
  printf '%s\n' "$home"
}
seed_pr() {
  local home=$1 manifest=$2 body=$3
  printf '%s\n' "$manifest" > "$home/forge/files.txt"
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeefcafe > "$home/forge/head-ref"
  mkdir -p "$home/forge/content/$(dirname "$manifest")"
  cp "$body" "$home/forge/content/$manifest"
}
seed_diff() {
  local home=$1 path=$2 line=$3
  { printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$path" "$path" "$path" "$path"
    printf '@@ -%s,1 +%s,1 @@\n-          value: old\n+          value: new\n' "$line" "$line"
  } > "$home/forge/diff.txt"
}
seed_series() {
  local home=$1 metric=$2 target=$3 window=$4
  shift 4
  : > "$home/cluster/$metric.$target.$window"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/cluster/$metric.$target.$window"; done
}
run_cw() {  # <cw-script> <home> <now> <args...>
  local cw=$1 home=$2 now=$3
  shift 3
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR="$home/cluster" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true \
    "$cw" "$@"
}

# --- the scenario, exercised on both scripts ---------------------------------
scenario() {  # <home>
  local home=$1
  seed_pr "$home" "$MANIFEST" "$TMP_ROOT/multi.yaml"
  seed_diff "$home" "$MANIFEST" 26
  seed_series "$home" restarts muso-prod_feed-service baseline 2
  seed_series "$home" restarts muso-prod_feed-service sample 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
}

ROW=/dev/null
OLD_HOME=$(new_world old)
scenario "$OLD_HOME"
run_cw "$OLD_CW" "$OLD_HOME" 1790000000 register o1 "$PR_URL" >/dev/null
# +15m: the rollout is still landing, so the read scores nothing.
rm -f "$OLD_HOME/cluster/restarts.muso-prod_feed-service.sample"
run_cw "$OLD_CW" "$OLD_HOME" 1790000900 sample o1-3317 900 >/dev/null
# The rollout lands; +1h and +6h measure the release.
seed_series "$OLD_HOME" restarts muso-prod_feed-service sample 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$OLD_CW" "$OLD_HOME" 1790044000 drive o1-3317 >/dev/null
echo '=== BEFORE THE FIX (base commit script) ==='
echo "verdict: $(run_cw "$OLD_CW" "$OLD_HOME" 1790044000 verdict o1-3317)"
echo "durable row terminal_state: $(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$OLD_HOME/state/change-watch/rows/o1-3317.json")"
if run_cw "$OLD_CW" "$OLD_HOME" 1790044000 gate o1 --terminal-gap; then
  echo 'teardown gate: PASS'
else
  echo 'teardown gate: REFUSED (the task can never be cleaned up)'
fi

NEW_HOME=$(new_world new)
scenario "$NEW_HOME"
run_cw "$NEW_CW" "$NEW_HOME" 1790000000 register n1 "$PR_URL" >/dev/null
rm -f "$NEW_HOME/cluster/restarts.muso-prod_feed-service.sample"
run_cw "$NEW_CW" "$NEW_HOME" 1790000900 sample n1-3317 900 >/dev/null
seed_series "$NEW_HOME" restarts muso-prod_feed-service sample 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$NEW_CW" "$NEW_HOME" 1790044000 drive n1-3317 >/dev/null
echo
echo '=== AFTER THE FIX (this branch) ==='
echo "verdict: $(run_cw "$NEW_CW" "$NEW_HOME" 1790044000 verdict n1-3317)"
echo "durable row terminal_state: $(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$NEW_HOME/state/change-watch/rows/n1-3317.json")"
echo "durable row reason: $(sed -n 's/.*"reason": "\(.*\)".*/\1/p' "$NEW_HOME/state/change-watch/rows/n1-3317.json")"
if run_cw "$NEW_CW" "$NEW_HOME" 1790044000 gate n1 --terminal-gap; then
  echo 'teardown gate: PASS (the task can be cleaned up)'
else
  echo 'teardown gate: REFUSED'
fi

# --- repairing the rows the old code already wrote ---------------------------
echo
echo '=== REDERIVE: repairing the stale row the old code left behind ==='
# Make the old home's row look exactly like the 80 production rows the fix was
# written for: proven readings, but an unmeasurable-with-reason terminal state.
python3 - "$OLD_HOME/state/change-watch/rows/o1-3317.json" <<'PY'
import json, sys
p = sys.argv[1]
row = json.load(open(p))
row["terminal_state"] = "unmeasurable-with-reason"
row["reason"] = "nothing measured at +15m"
json.dump(row, open(p, "w"), indent=2, sort_keys=True)
PY
printf 'unmeasurable-with-reason: nothing measured at +15m\n' \
  > "$OLD_HOME/state/change-watch/o1-3317/verdict"
echo "stale row before rederive: $(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$OLD_HOME/state/change-watch/rows/o1-3317.json")"
echo '--- rederive (dry run) ---'
run_cw "$NEW_CW" "$OLD_HOME" 1790050000 rederive
echo '--- rederive --apply ---'
run_cw "$NEW_CW" "$OLD_HOME" 1790050000 rederive --apply
echo "row after rederive: $(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$OLD_HOME/state/change-watch/rows/o1-3317.json")"
echo "verdict after rederive: $(run_cw "$NEW_CW" "$OLD_HOME" 1790050000 verdict o1-3317)"
if run_cw "$NEW_CW" "$OLD_HOME" 1790050000 gate o1 --terminal-gap; then
  echo 'teardown gate after rederive: PASS'
else
  echo 'teardown gate after rederive: REFUSED'
fi
echo
echo "temp fixtures: $TMP_ROOT"
