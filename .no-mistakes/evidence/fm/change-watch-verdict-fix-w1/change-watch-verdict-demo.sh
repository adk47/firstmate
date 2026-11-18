#!/usr/bin/env bash
# End-to-end CLI demo of the change-watch verdict fix, using the same seams the
# behavior tests use (FM_CW_FORGE_DIR, FM_CW_CLUSTER_DIR, stubbed arm/send).
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7Q98G82GJCAYEZR0V0GVV3C
CW="$ROOT/bin/fm-change-watch.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-cw-evidence.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'
MANIFEST='k8s/prod/core-services/deployments.yaml'
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
run_cw() {
  local home=$1 now=$2; shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR="$home/cluster" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true \
    "$CW" "$@"
}
seed_pr() {
  local home=$1 manifest=$2 body=$3; shift 3
  : > "$home/forge/files.txt"
  local f; for f in "$@"; do printf '%s\n' "$f" >> "$home/forge/files.txt"; done
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeefcafe > "$home/forge/head-ref"
  mkdir -p "$home/forge/content/$(dirname "$manifest")"
  cp "$body" "$home/forge/content/$manifest"
}
seed_diff() {
  local home=$1 path=$2 line; shift 2
  { printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$path" "$path" "$path" "$path"
    for line in "$@"; do printf '@@ -%s,1 +%s,1 @@\n-          value: old\n+          value: new\n' "$line" "$line"; done
  } > "$home/forge/diff.txt"
}
seed_series() {
  local home=$1 metric=$2 target=$3 window=$4; shift 4
  : > "$home/cluster/$metric.$target.$window"
  local line; for line in "$@"; do printf '%s\n' "$line" >> "$home/cluster/$metric.$target.$window"; done
}

H=$(new_world demo)
seed_pr "$H" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$H" "$MANIFEST" 26
seed_series "$H" restarts muso-prod_feed-service baseline 2
seed_series "$H" restarts muso-prod_feed-service sample 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2

echo '$ fm-change-watch.sh register demo https://github.com/Muso-AI/H-DevOps/pull/3317'
run_cw "$H" 1790000000 register demo "$PR_URL"

# The motivating failure: at +15m the rollout has not landed, so the read scores nothing.
echo
echo '$ # rollout still landing at +15m: the sample reads nothing'
rm -f "$H/cluster/restarts.muso-prod_feed-service.sample"
run_cw "$H" 1790000900 sample demo-3317 900 >/dev/null
echo "  recorded: $(run_cw "$H" 1790000900 verdict demo-3317)"

# The rollout lands; the later readings measure the release.
seed_series "$H" restarts muso-prod_feed-service sample 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
echo
echo '$ # rollout landed: +1h and +6h readings measure the release'
run_cw "$H" 1790044000 drive demo-3317 >/dev/null
echo "  verdict: $(run_cw "$H" 1790044000 verdict demo-3317)"
echo "  durable row: $(cat "$H/state/change-watch/rows/demo-3317.json")"
echo
echo '$ fm-change-watch.sh gate demo --terminal-gap   # teardown gate'
run_cw "$H" 1790044000 gate demo --terminal-gap && echo "  gate: accepted (teardown is no longer refused)"

# Now the repair path: a row written by the old, stricter rule.
echo
echo '$ # simulate a row the old rule latched to unmeasurable despite later readings'
sed -i 's/"terminal_state": "proven"/"terminal_state": "unmeasurable-with-reason"/; s/"reason": "the +6h reading/"reason": "nothing measured at +15m; the +6h reading/' \
  "$H/state/change-watch/rows/demo-3317.json"
printf 'unmeasurable-with-reason: nothing measured at +15m\n' > "$H/state/change-watch/demo-3317/verdict"
echo "  verdict: $(run_cw "$H" 1790050000 verdict demo-3317)"
echo
echo '$ fm-change-watch.sh rederive            # dry run'
run_cw "$H" 1790050000 rederive
echo
echo '$ fm-change-watch.sh rederive --apply'
run_cw "$H" 1790050000 rederive --apply
echo
echo "  verdict after repair: $(run_cw "$H" 1790050000 verdict demo-3317)"
echo "  durable row after repair: $(cat "$H/state/change-watch/rows/demo-3317.json")"
echo
echo '$ fm-change-watch.sh rederive --apply    # idempotent second run'
run_cw "$H" 1790050000 rederive --apply
