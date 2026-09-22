#!/usr/bin/env bash
# Tests for bin/fm-change-watch.sh, the post-merge change watch.
#
# The watch exists to catch a merge that is bad BY EFFECT rather than by
# content, so the cases here pin exactly that: a merged PR that touches one
# Deployment registers a bounded schedule and a baseline; a 5xx series that
# crosses its bar at +15m reports the first regression as a wake and a steer; an
# OOMKilled event reports on the sample that sees it; a clean series runs the
# whole 12h schedule and records the clean note; and a docs-only PR registers
# nothing at all.
#
# Every cluster and forge read is stubbed through the script's own seams
# (FM_CW_FORGE_DIR, FM_CW_CLUSTER_DIR, FM_CW_ARM_CMD, FM_CW_SEND_CMD), so no
# case reaches a cluster, the network, or the wiki.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CW="$ROOT/bin/fm-change-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-change-watch)
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'

# --- helpers -----------------------------------------------------------------

# new_world <name> prints a fresh isolated home.
new_world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/forge/content/k8s/prod/muso-prod" "$home/cluster"
  cat > "$home/arm.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_ARM_LOG"
STUB
  cat > "$home/send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SEND_LOG"
STUB
  chmod +x "$home/arm.sh" "$home/send.sh"
  printf '%s\n' "$home"
}

# run_cw <home> <now> <args...> runs the watch with every seam pointed at <home>.
run_cw() {
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR="$home/cluster" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD=true \
    "$CW" "$@"
}

# seed_pr <home> <manifest-path> <manifest-body-file> <files...>
seed_pr() {
  local home=$1 manifest=$2 body=$3
  shift 3
  : > "$home/forge/files.txt"
  local f
  for f in "$@"; do printf '%s\n' "$f" >> "$home/forge/files.txt"; done
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeefcafe > "$home/forge/merge-ref"
  mkdir -p "$home/forge/content/$(dirname "$manifest")"
  cp "$body" "$home/forge/content/$manifest"
}

# seed_series <home> <metric> <target> <window> <lines...>
seed_series() {
  local home=$1 metric=$2 target=$3 window=$4
  shift 4
  : > "$home/cluster/$metric.$target.$window"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/cluster/$metric.$target.$window"; done
}

DEPLOY_MANIFEST='apiVersion: apps/v1
kind: Deployment
metadata:
  name: feed-service
  namespace: muso-prod
spec:
  template: {}
---
apiVersion: v1
kind: Service
metadata:
  name: feed
'

# --- (a) a merged PR touching one Deployment registers a watch -----------------

HOME_A=$(new_world a)
printf '%s' "$DEPLOY_MANIFEST" > "$TMP_ROOT/feed.yaml"
seed_pr "$HOME_A" k8s/prod/muso-prod/feed.yaml "$TMP_ROOT/feed.yaml" \
  k8s/prod/muso-prod/feed.yaml README.md

out=$(run_cw "$HOME_A" 1790000000 register w1 "$PR_URL") || fail "register failed"
case "$out" in
  *"registered w1-3317"*"(1 target(s))"*) pass "register reports one derived target" ;;
  *) fail "unexpected register output: $out" ;;
esac

WATCH_A="$HOME_A/state/change-watch/w1-3317"
[ -f "$WATCH_A/targets" ] || fail "register did not write targets"
[ "$(cat "$WATCH_A/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "derived target is wrong: $(cat "$WATCH_A/targets")"

[ "$(grep -c '' "$WATCH_A/schedule")" -eq 15 ] || fail "schedule is not the bounded 15-sample set"
[ "$(head -1 "$WATCH_A/schedule" | cut -f1)" -eq 300 ] || fail "first sample is not +5m"
[ "$(tail -1 "$WATCH_A/schedule" | cut -f1)" -eq 43200 ] || fail "last sample is not +12h"
grep -q "^http_5xx_per_min@muso-prod/feed-service" "$WATCH_A/baseline" \
  || fail "baseline is missing the 5xx metric"
grep -q "^pgbouncer_cl_waiting@watch" "$WATCH_A/baseline" \
  || fail "baseline is missing the watch-level pool metric"

grep -q -- "--condition $CW due w1-3317" "$HOME_A/arm.log" \
  || fail "arming did not bind the due condition"
grep -q -- "--action $CW drive w1-3317" "$HOME_A/arm.log" \
  || fail "arming did not bind the drive action"

# Registering the same merge twice is idempotent and re-arms nothing.
before=$(grep -c '' "$HOME_A/arm.log")
out=$(run_cw "$HOME_A" 1790000060 register w1 "$PR_URL") || fail "repeat register failed"
case "$out" in
  *"already registered"*) pass "repeat register is idempotent" ;;
  *) fail "repeat register did not report idempotence: $out" ;;
esac
[ "$(grep -c '' "$HOME_A/arm.log")" -eq "$before" ] || fail "repeat register armed a second watch"

# The condition is false before the first sample and true at it.
run_cw "$HOME_A" 1790000000 due w1-3317 && fail "due fired before the first sample"
run_cw "$HOME_A" 1790000300 due w1-3317 || fail "due did not fire at +5m"
pass "due gates the first sample"

# --- (b) a regressing 5xx series fires at +15m --------------------------------

HOME_B=$(new_world b)
seed_pr "$HOME_B" k8s/prod/muso-prod/feed.yaml "$TMP_ROOT/feed.yaml" k8s/prod/muso-prod/feed.yaml
seed_series "$HOME_B" http_5xx_per_min muso-prod_feed-service baseline 0
seed_series "$HOME_B" http_5xx_per_min muso-prod_feed-service sample 0.2 5
run_cw "$HOME_B" 1790000000 register b1 "$PR_URL" >/dev/null || fail "register failed"

run_cw "$HOME_B" 1790000300 sample b1-3317 >/dev/null || fail "sample at +5m failed"
run_cw "$HOME_B" 1790000300 verdict b1-3317 | grep -q "clean so far" \
  || fail "+5m sample should be clean"
run_cw "$HOME_B" 1790000900 sample b1-3317 >/dev/null || fail "sample at +15m failed"
line=$(run_cw "$HOME_B" 1790000900 verdict b1-3317)
[ "$line" = "change-watch regressed at +15m on http_5xx_per_min (5 vs baseline 0)" ] \
  || fail "verdict line is wrong: $line"
pass "5xx series reports the first regression at +15m"

grep -qF "check: change-watch b1 $PR_URL http_5xx_per_min regressed" "$HOME_B/state/.wake-queue" \
  || fail "the regression did not queue the check wake"
grep -q "regressed at +15m on http_5xx_per_min" "$HOME_B/send.log" \
  || fail "the regression did not steer the owning lane"
grep -q "measured 5" "$HOME_B/send.log" || fail "the steer does not carry the numbers"
pass "regression queues one wake and steers the lane with the numbers"

# A further sample must not re-report.
run_cw "$HOME_B" 1790001800 sample b1-3317 >/dev/null || true
[ "$(grep -cF "check: change-watch b1 $PR_URL" "$HOME_B/state/.wake-queue")" -eq 1 ] \
  || fail "the regression was reported more than once"
pass "the regression is reported exactly once"

# --- (c) an OOMKilled event regresses ------------------------------------------

HOME_C=$(new_world c)
seed_pr "$HOME_C" k8s/prod/muso-prod/feed.yaml "$TMP_ROOT/feed.yaml" k8s/prod/muso-prod/feed.yaml
seed_series "$HOME_C" oomkilled muso-prod_feed-service baseline 0
seed_series "$HOME_C" oomkilled muso-prod_feed-service sample 0 1
run_cw "$HOME_C" 1790000000 register c1 "$PR_URL" >/dev/null || fail "register failed"

run_cw "$HOME_C" 1790000900 drive c1-3317 >/dev/null || fail "drive failed"
line=$(run_cw "$HOME_C" 1790000900 verdict c1-3317)
[ "$line" = "change-watch regressed at +15m on oomkilled (1 vs baseline 0)" ] \
  || fail "OOMKilled verdict is wrong: $line"
grep -qF "check: change-watch c1 $PR_URL oomkilled regressed" "$HOME_C/state/.wake-queue" \
  || fail "OOMKilled did not queue the check wake"
pass "an OOMKilled event regresses the watch"

# --- (d) a clean 12h series records the clean note -----------------------------

HOME_D=$(new_world d)
seed_pr "$HOME_D" k8s/prod/muso-prod/feed.yaml "$TMP_ROOT/feed.yaml" k8s/prod/muso-prod/feed.yaml
seed_series "$HOME_D" http_5xx_per_min muso-prod_feed-service baseline 0 \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
seed_series "$HOME_D" restarts muso-prod_feed-service baseline 2 \
  2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
run_cw "$HOME_D" 1790000000 register d1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_D/state/d1.meta"

run_cw "$HOME_D" 1790044000 drive d1-3317 >/dev/null || fail "clean drive failed"
[ "$(run_cw "$HOME_D" 1790044000 verdict d1-3317)" = "change-watch clean" ] \
  || fail "clean drive did not end clean"
grep -qF "note: change-watch clean for $PR_URL" "$HOME_D/state/d1.status" \
  || fail "the clean note was not appended to the task status log"
[ -e "$HOME_D/state/.wake-queue" ] && [ -s "$HOME_D/state/.wake-queue" ] \
  && fail "a clean watch must not queue a wake"
pass "a clean 12h series records the clean note and queues nothing"

# Every metric unmeasured is clean, never a failure.
HOME_U=$(new_world u)
seed_pr "$HOME_U" k8s/prod/muso-prod/feed.yaml "$TMP_ROOT/feed.yaml" k8s/prod/muso-prod/feed.yaml
run_cw "$HOME_U" 1790000000 register u1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_U/state/u1.meta"
run_cw "$HOME_U" 1790044000 drive u1-3317 >/dev/null || fail "unmeasured drive failed"
[ "$(run_cw "$HOME_U" 1790044000 verdict u1-3317)" = "change-watch clean" ] \
  || fail "an entirely unmeasured watch must still be clean"
pass "unmeasured metrics degrade per metric and never fail the watch"

# --- (e) a docs-only PR registers nothing --------------------------------------

HOME_E=$(new_world e)
printf 'README.md\ndocs/notes.md\n' > "$HOME_E/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_E/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_E/forge/merge-ref"
out=$(run_cw "$HOME_E" 1790000000 register e1 "$PR_URL") || fail "docs-only register failed"
case "$out" in
  *"no deployable service touched"*"nothing registered"*) pass "docs-only PR registers nothing" ;;
  *) fail "docs-only register did not report nothing: $out" ;;
esac
[ -e "$HOME_E/state/change-watch/e1-3317" ] && fail "docs-only PR created a watch record"
[ "$(grep -c '' "$HOME_E/arm.log" 2>/dev/null || echo 0)" -eq 0 ] \
  || fail "docs-only PR armed a watch"
pass "docs-only PR leaves no watch behind"

# --- an application repo resolves through its service name ---------------------

HOME_F=$(new_world f)
mkdir -p "$HOME_F/projects/H-DevOps/k8s/prod/muso-prod"
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: core-backend\n  namespace: muso-prod\n' \
  > "$HOME_F/projects/H-DevOps/k8s/prod/muso-prod/deployments.yaml"
printf 'src/main.py\n' > "$HOME_F/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_F/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_F/forge/merge-ref"
out=$(env FM_HOME="$HOME_F" FM_STATE_OVERRIDE="$HOME_F/state" FM_CW_NOW=1790000000 \
  FM_CW_FORGE_DIR="$HOME_F/forge" FM_CW_CLUSTER_DIR="$HOME_F/cluster" \
  FM_CW_HDEVOPS_K8S_DIR="$HOME_F/projects/H-DevOps/k8s/prod" \
  FM_CW_ARM_CMD="$HOME_F/arm.sh" FM_CW_ARM_LOG="$HOME_F/arm.log" \
  FM_CW_SEND_CMD="$HOME_F/send.sh" FM_CW_SEND_LOG="$HOME_F/send.log" \
  FM_CW_NO_WIKI=1 "$CW" register f1 'https://github.com/Muso-AI/core-backend/pull/42') \
  || fail "application-repo register failed"
case "$out" in
  *"registered f1-42"*) pass "an application repo resolves to its service Deployment" ;;
  *) fail "application-repo register did not resolve a target: $out" ;;
esac
[ "$(cat "$HOME_F/state/change-watch/f1-42/targets")" = "$(printf 'muso-prod\tcore-backend')" ] \
  || fail "application-repo target is wrong"
