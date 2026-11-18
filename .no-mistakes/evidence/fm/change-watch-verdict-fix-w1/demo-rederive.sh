#!/usr/bin/env bash
# End-to-end operator demo for the change-watch verdict fix.
# Drives the real bin/fm-change-watch.sh CLI through: a +15m read that measured
# nothing, later readings that measured the release, a legacy pre-fix row that
# teardown refuses, and the rederive one-shot that repairs it.
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7RA5RF9CGQ0Z7QGTZTPK4BD
CW="$ROOT/bin/fm-change-watch.sh"
TMP=$(mktemp -d /tmp/fm-cw-demo.XXXXXX)
HOME_D=$TMP/home
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'
MANIFEST='k8s/prod/core-services/deployments.yaml'

mkdir -p "$HOME_D/state" "$HOME_D/forge/content" "$HOME_D/cluster"
cat > "$HOME_D/arm.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_ARM_LOG"
STUB
cat > "$HOME_D/send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SEND_LOG"
STUB
chmod +x "$HOME_D/arm.sh" "$HOME_D/send.sh"

cat > "$TMP/multi.yaml" <<'YAML'
apiVersion: apps/v1
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
YAML
FEED_LINE=26

run_cw() {
  local now=$1; shift
  env FM_HOME="$HOME_D" FM_STATE_OVERRIDE="$HOME_D/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$HOME_D/forge" FM_CW_CLUSTER_DIR="$HOME_D/cluster" \
    FM_CW_ARM_CMD="$HOME_D/arm.sh" FM_CW_ARM_LOG="$HOME_D/arm.log" \
    FM_CW_SEND_CMD="$HOME_D/send.sh" FM_CW_SEND_LOG="$HOME_D/send.log" \
    FM_CW_TRACE="$HOME_D/trace" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true \
    "$CW" "$@"
}
step() { printf '\n=== %s ===\n' "$*"; }

# --- forge fixture: the merged PR and its diff -------------------------------
printf '%s\n' "$MANIFEST" README.md > "$HOME_D/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_D/forge/merge-epoch"
printf '%s\n' deadbeefcafe > "$HOME_D/forge/head-ref"
mkdir -p "$HOME_D/forge/content/$(dirname "$MANIFEST")"
cp "$TMP/multi.yaml" "$HOME_D/forge/content/$MANIFEST"
{
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$MANIFEST" "$MANIFEST" "$MANIFEST" "$MANIFEST"
  printf '@@ -%s,1 +%s,1 @@\n-          value: old\n+          value: new\n' "$FEED_LINE" "$FEED_LINE"
} > "$HOME_D/forge/diff.txt"

# --- cluster fixture: a stable restarts series -------------------------------
printf '2\n' > "$HOME_D/cluster/restarts.muso-prod_feed-service.baseline"
seed_sample() { printf '2\n%.0s' $(seq 1 15) > "$HOME_D/cluster/restarts.muso-prod_feed-service.sample"; }
seed_sample

step "register the merged PR"
run_cw 1790000000 register d1 "$PR_URL"

step "the +15m reading fails outright (no usable series at the rollout)"
rm -f "$HOME_D/cluster/restarts.muso-prod_feed-service.sample"
run_cw 1790000900 sample d1-3317 900; printf 'sample exit=%s (a failed read, not a verdict)\n' "$?"
seed_sample

step "the +1h/+6h drive reads the release that has now rolled out"
run_cw 1790044000 drive d1-3317
printf 'verdict: %s\n' "$(run_cw 1790044000 verdict d1-3317)"
printf 'row: %s\n' "$(cat "$HOME_D/state/change-watch/rows/d1-3317.json")"

step "gate for the done claim on the proven watch"
run_cw 1790044000 gate d1 >/dev/null; printf 'gate exit=%s\n' "$?"
run_cw 1790044000 gate d1 --terminal-gap >/dev/null; printf 'teardown gate (--terminal-gap) exit=%s\n' "$?"

# --- the state the pre-fix code left behind ---------------------------------
step "rewrite the row/verdict into the shape the pre-fix code wrote (stale unmeasurable)"
ROW="$HOME_D/state/change-watch/rows/d1-3317.json"
sed -i 's/"terminal_state": "proven"/"terminal_state": "unmeasurable-with-reason"/; s/"reason": "the +6h reading/"reason": "nothing measured at +15m; the +6h reading/' "$ROW"
printf 'unmeasurable-with-reason: nothing measured at +15m\n' > "$HOME_D/state/change-watch/d1-3317/verdict"
printf 'verdict: %s\n' "$(run_cw 1790050000 verdict d1-3317)"
printf 'row: %s\n' "$(cat "$ROW")"
run_cw 1790050000 gate d1 --terminal-gap >/dev/null; printf 'teardown gate (--terminal-gap) exit=%s (refused, task stuck)\n' "$?"

step "rederive dry run: what would change, and why"
run_cw 1790050000 rederive

step "rederive --apply: repair the row from its own readings"
run_cw 1790050000 rederive --apply
printf 'row after apply: %s\n' "$(cat "$ROW")"
printf 'verdict: %s\n' "$(run_cw 1790050000 verdict d1-3317)"

step "teardown gate after repair"
run_cw 1790050000 gate d1 --terminal-gap >/dev/null; printf 'teardown gate (--terminal-gap) exit=%s\n' "$?"

step "rederive is idempotent"
run_cw 1790059000 rederive

write_evidence_note() { :; }
rm -rf "$TMP"
