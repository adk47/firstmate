#!/usr/bin/env bash
# Evidence transcript for the change-watch verdict fix.
# Runs the real bin/fm-change-watch.sh against stub kubectl/forge seams and
# prints the operator-visible output of each ruled-on case.
set -u
REPO=${REPO:-/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7SX9WRYKDNMZGA4F9VC6WW5}
CW="$REPO/bin/fm-change-watch.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cw-evidence.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FAIL=0

new_world() {
  local home="$TMP/$1"
  mkdir -p "$home/state" "$home/forge/content" "$home/cluster" "$home/bin" "$home/config" "$home/sentry"
  cat > "$home/arm.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_ARM_LOG"
STUB
  cat > "$home/send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SEND_LOG"
STUB
  chmod +x "$home/arm.sh" "$home/send.sh"
  cat > "$home/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
  *" --raw=/version "*) printf '{"gitVersion":"v1.31.0"}\n' ;;
  *" get deploy -A "*) [ -z "${FM_CW_SHIM_WORKLOADS:-}" ] || cat "$FM_CW_SHIM_WORKLOADS" ;;
  *" get pods "*)
    app=$(printf '%s' "$*" | sed -n 's/.*app=\([^ ]*\).*/\1/p')
    printf '{"items":[{"metadata":{"name":"%s-1","labels":{"pod-template-hash":"h1"}},"spec":{"containers":[{"name":"c","image":"%s","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":{}}]}}]}\n' \
      "$app" "${FM_CW_SHIM_IMAGE:-}"
    ;;
  *" top pods "*) printf '%s-1   c   100m   128Mi\n' "$(printf '%s' "$*" | sed -n 's/.*app=\([^ ]*\).*/\1/p')" ;;
  *" logs "*) : ;;
  *" set env "*) printf 'ENV=production\n' ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$home/bin/kubectl"
  printf '%s\n' "$home"
}

seed_app_pr() {
  printf 'src/server.ts\nsrc/routes/feed.ts\n' > "$1/forge/files.txt"
  printf '%s\n' 1790000000 > "$1/forge/merge-epoch"
  printf '%s\n' deadbeef > "$1/forge/head-ref"
  : > "$1/forge/diff.txt"
}

run_cw() {
  local home=$1 now=$2 image=$3
  shift 3
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR='' \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true \
    PATH="$home/bin:$PATH" FM_CW_SHIM_WORKLOADS="$home/workloads" \
    FM_CW_SHIM_IMAGE="$image" FM_CW_CONFIG_DIR="$home/config" \
    FM_CW_SENTRY_DIR="$home/sentry" \
    "$CW" "$@"
}

hdr() { printf '\n### %s\n' "$*"; }
check() { if "$@"; then printf 'PASS: %s\n' "$CHECK"; else printf 'FAIL: %s\n' "$CHECK"; FAIL=1; fi; }

PR='https://github.com/Muso-AI/core-backend/pull/4242'
SCHED=$'900\t1790000900\n3600\t1790003600\n21600\t1790021600'

# --- 1. a later reading rescues an earlier one that only awaited the deploy ---
hdr "1. +15m awaited the deploy; the +6h reading measured the landed release"
H1=$(new_world rescue)
seed_app_pr "$H1"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$H1/workloads"
printf '[]\n' > "$H1/sentry/issues-core-backend.json"
run_cw "$H1" 1790000000 'localhost:30500/muso/core-backend:old-1' register rescue "$PR" >/dev/null
printf '%s\n' "$SCHED" > "$H1/state/change-watch/rescue-4242/schedule"
run_cw "$H1" 1790000900 'localhost:30500/muso/core-backend:old-1' sample rescue-4242 900 >/dev/null
printf '%s\n' '-- +15m sample line (col7 scored, col8 awaiting):'
awk -F'\t' '$2==900' "$H1/state/change-watch/rescue-4242/samples.log"
run_cw "$H1" 1790021600 'localhost:30500/muso/core-backend:new-2' drive rescue-4242 >/dev/null
printf 'verdict: %s\n' "$(run_cw "$H1" 1790021600 'localhost:30500/muso/core-backend:new-2' verdict rescue-4242)"
printf '%s\n' '-- durable row readings:'
sed -n 's/.*"readings": \({[^}]*}\).*/readings: \1/p' "$H1/state/change-watch/rows/rescue-4242.json"
CHECK='the watch ended clean and its row is proven despite the awaiting first reading'
check grep -q '"terminal_state": "proven"' "$H1/state/change-watch/rows/rescue-4242.json"

# --- 2. an all-awaiting window is not a measurement ---------------------------
hdr "2. every reading waited on a rollout that never landed"
H2=$(new_world awaiting)
seed_app_pr "$H2"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$H2/workloads"
printf '[]\n' > "$H2/sentry/issues-core-backend.json"
run_cw "$H2" 1790000000 'localhost:30500/muso/core-backend:old-1' register await "$PR" >/dev/null
printf '%s\n' "$SCHED" > "$H2/state/change-watch/await-4242/schedule"
run_cw "$H2" 1790021600 'localhost:30500/muso/core-backend:old-1' drive await-4242 >/dev/null
printf 'verdict: %s\n' "$(run_cw "$H2" 1790021600 'localhost:30500/muso/core-backend:old-1' verdict await-4242)"
printf 'row terminal_state: %s\n' "$(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$H2/state/change-watch/rows/await-4242.json")"
CHECK='an all-awaiting watch is unmeasurable and its verdict names the +6h awaiting rollout'
check grep -q 'the +6h reading awaited a rollout' "$H2/state/change-watch/await-4242/verdict"

# --- 3. rederive repairs a stale proven row from its own readings ------------
hdr "3. rederive repairs a pre-fix row the old rule called proven"
sed -i 's/"terminal_state": "unmeasurable-with-reason"/"terminal_state": "proven"/' \
  "$H2/state/change-watch/rows/await-4242.json"
printf 'clean\n' > "$H2/state/change-watch/await-4242/verdict"
printf 'before: row=%s verdict=%s\n' \
  "$(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$H2/state/change-watch/rows/await-4242.json")" \
  "$(cat "$H2/state/change-watch/await-4242/verdict")"
run_cw "$H2" 1790030000 'localhost:30500/muso/core-backend:old-1' rederive --apply
printf 'after: row=%s\n' "$(sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$H2/state/change-watch/rows/await-4242.json")"
printf 'verdict: %s\n' "$(run_cw "$H2" 1790030000 'localhost:30500/muso/core-backend:old-1' verdict await-4242)"
CHECK='the rederive stamps the row unmeasurable and rewrites the clean verdict to name the case'
check grep -q '^unmeasurable-with-reason: the +6h reading awaited a rollout' "$H2/state/change-watch/await-4242/verdict"

# --- 4. a derived regression fails the gate, never a stale pass --------------
hdr "4. a row-less watch whose readings recorded a regression"
H3=$(new_world derived)
seed_app_pr "$H3"
printf 'muso-prod\tcore-backend-api\t6\tlocalhost:30500/muso/core-backend:old-1\n' > "$H3/workloads"
printf '[]\n' > "$H3/sentry/issues-core-backend.json"
run_cw "$H3" 1790000000 'localhost:30500/muso/core-backend:old-1' register dw "$PR" >/dev/null
rm -f "$H3/state/change-watch/rows/dw-4242.json"
printf '1790000900\t900\trestarts@muso-prod/core-backend-api\t5\t1\t1\t1\t0\n' \
  > "$H3/state/change-watch/dw-4242/samples.log"
printf 'completed unmeasured\n' > "$H3/state/change-watch/dw-4242/verdict"
set +e
out=$(run_cw "$H3" 1790044000 'localhost:30500/muso/core-backend:old-1' gate dw --terminal-gap 2>&1); rc=$?
set -e
printf 'teardown gate exit=%s: %s\n' "$rc" "$out"
CHECK='the derived regression fails teardown and names the readings'
check test "$rc" -ne 0
set +e
run_cw "$H3" 1790044000 'localhost:30500/muso/core-backend:old-1' gate dw >/dev/null 2>&1; rc2=$?
set -e
printf 'done-claim gate exit=%s\n' "$rc2"
CHECK='the derived regression also fails the done-claim gate'
check test "$rc2" -ne 0
run_cw "$H3" 1790044000 'localhost:30500/muso/core-backend:old-1' followup dw-4242 'repo#43' >/dev/null
set +e
run_cw "$H3" 1790044000 'localhost:30500/muso/core-backend:old-1' gate dw --terminal-gap >/dev/null; rc3=$?
set -e
printf 'teardown gate after followup: exit=%s\n' "$rc3"
CHECK='teardown passes once the follow-up work item is recorded'
check test "$rc3" -eq 0

printf '\nRESULT: %s\n' "$([ "$FAIL" -eq 0 ] && echo all-cases-pass || echo failures-present)"
exit "$FAIL"
