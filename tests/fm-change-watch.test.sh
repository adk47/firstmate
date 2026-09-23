#!/usr/bin/env bash
# Tests for bin/fm-change-watch.sh, the post-merge change watch.
#
# The watch exists to catch a merge that is bad BY EFFECT rather than by
# content, so the cases here pin exactly that: a merged PR whose hunk lands in
# one Deployment of a multi-Deployment manifest registers that one target under
# the manifest's own namespace; a 5xx series that crosses its bar at +15m
# reports the first regression as a wake and a steer; an OOMKilled event reports
# on the sample that sees it; a clean series runs the whole 12h schedule and
# records the clean note; a schedule that never read a target completes
# unmeasured instead of clean; an interrupted drive is never clean and can be
# re-armed; the pool metric is scoped to the Deployment's own pool; and a
# docs-only PR registers nothing at all.
#
# Every cluster and forge read is stubbed through the script's own seams
# (FM_CW_FORGE_DIR, FM_CW_CLUSTER_DIR, FM_CW_ARM_CMD, FM_CW_SEND_CMD) or a
# kubectl PATH shim, so no case reaches a cluster, the network, or the wiki.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CW="$ROOT/bin/fm-change-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-change-watch)
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'
MANIFEST='k8s/prod/core-services/deployments.yaml'

# --- helpers -----------------------------------------------------------------

# new_world <name> prints a fresh isolated home.
new_world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/forge/content" "$home/cluster"
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
# CW_SLEEP overrides the drive's sleep command; CW_CLUSTER_DIR the series dir.
run_cw() {
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR="${CW_CLUSTER_DIR-$home/cluster}" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD="${CW_SLEEP:-true}" \
    "$CW" "$@"
}

# seed_pr <home> <manifest-path> <manifest-body-file> <files...> seeds the merged
# PR's file list, merge epoch, head ref, and the manifest content at that ref.
seed_pr() {
  local home=$1 manifest=$2 body=$3
  shift 3
  : > "$home/forge/files.txt"
  local f
  for f in "$@"; do printf '%s\n' "$f" >> "$home/forge/files.txt"; done
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeefcafe > "$home/forge/head-ref"
  mkdir -p "$home/forge/content/$(dirname "$manifest")"
  cp "$body" "$home/forge/content/$manifest"
}

# seed_diff <home> <path> <new-line...> writes one-line changes, one hunk each.
seed_diff() {
  local home=$1 path=$2 line
  shift 2
  {
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$path" "$path" "$path" "$path"
    for line in "$@"; do
      printf '@@ -%s,1 +%s,1 @@\n-          value: old\n+          value: new\n' "$line" "$line"
    done
  } > "$home/forge/diff.txt"
}

# seed_series <home> <metric> <target> <window> <lines...>
seed_series() {
  local home=$1 metric=$2 target=$3 window=$4
  shift 4
  : > "$home/cluster/$metric.$target.$window"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/cluster/$metric.$target.$window"; done
}

# The real tree's shape: one manifest per component declaring several
# Deployments, each under its own metadata.namespace, plus a Service.
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
FEED_LINE=26     # inside the feed-service Deployment document
API_LINE=13      # inside the core-backend-api Deployment document
SERVICE_LINE=36  # inside the Service document

# --- (a) a hunk in one Deployment registers exactly that target -----------------

HOME_A=$(new_world a)
seed_pr "$HOME_A" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST" README.md
seed_diff "$HOME_A" "$MANIFEST" "$FEED_LINE"

out=$(run_cw "$HOME_A" 1790000000 register w1 "$PR_URL") || fail "register failed"
case "$out" in
  *"registered w1-3317"*"(1 target(s))"*) pass "register reports one derived target" ;;
  *) fail "unexpected register output: $out" ;;
esac

WATCH_A="$HOME_A/state/change-watch/w1-3317"
[ -f "$WATCH_A/targets" ] || fail "register did not write targets"
[ "$(cat "$WATCH_A/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "derived target is wrong: $(cat "$WATCH_A/targets")"
pass "the target is the Deployment the hunk landed in, under the manifest's namespace"

[ "$(grep -c '' "$WATCH_A/schedule")" -eq 15 ] || fail "schedule is not the bounded 15-sample set"
[ "$(head -1 "$WATCH_A/schedule" | cut -f1)" -eq 300 ] || fail "first sample is not +5m"
[ "$(tail -1 "$WATCH_A/schedule" | cut -f1)" -eq 43200 ] || fail "last sample is not +12h"
grep -q "^http_5xx_per_min@muso-prod/feed-service" "$WATCH_A/baseline" \
  || fail "baseline is missing the 5xx metric"
grep -q "^pgbouncer_cl_waiting@muso-prod/feed-service" "$WATCH_A/baseline" \
  || fail "baseline is missing the per-target pool metric"

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

# A hunk in the other Deployment picks that one; a hunk only in the Service picks nothing.
HOME_A2=$(new_world a2)
seed_pr "$HOME_A2" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A2" "$MANIFEST" "$API_LINE"
run_cw "$HOME_A2" 1790000000 register w2 "$PR_URL" >/dev/null || fail "register failed"
[ "$(cat "$HOME_A2/state/change-watch/w2-3317/targets")" = "$(printf 'muso-prod\tcore-backend-api')" ] \
  || fail "a hunk in core-backend-api did not target it alone"
HOME_A3=$(new_world a3)
seed_pr "$HOME_A3" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A3" "$MANIFEST" "$SERVICE_LINE"
out=$(run_cw "$HOME_A3" 1790000000 register w3 "$PR_URL") || fail "register failed"
case "$out" in
  *"no deployable service touched"*) pass "a hunk only in a Service document targets no Deployment" ;;
  *) fail "a Service-only hunk registered a watch: $out" ;;
esac

# Without a diff the whole manifest is watched and the registration says so.
HOME_A4=$(new_world a4)
seed_pr "$HOME_A4" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
out=$(run_cw "$HOME_A4" 1790000000 register w4 "$PR_URL") || fail "register failed"
case "$out" in
  *"(2 target(s); whole manifest: $MANIFEST)"*) pass "an unplaceable hunk falls back to the whole manifest and says so" ;;
  *) fail "whole-manifest fallback is not reported: $out" ;;
esac
[ "$(cat "$HOME_A4/state/change-watch/w4-3317/targets")" = "$(printf 'muso-prod\tcore-backend-api\nmuso-prod\tfeed-service')" ] \
  || fail "whole-manifest fallback targets are wrong"

# A PR changing several lines of one Deployment (the motivating merge's shape)
# still targets exactly that Deployment.
HOME_A5=$(new_world a5)
seed_pr "$HOME_A5" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A5" "$MANIFEST" $((FEED_LINE - 2)) "$FEED_LINE"
out=$(run_cw "$HOME_A5" 1790000000 register w5 "$PR_URL") || fail "register failed"
case "$out" in
  *"registered w5-3317"*"(1 target(s))"*) ;;
  *) fail "a two-hunk diff did not register one target: $out" ;;
esac
[ "$(cat "$HOME_A5/state/change-watch/w5-3317/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "two hunks in feed-service did not target it alone"
pass "several hunks in one Deployment target that Deployment once"

# A Deployment that declares no namespace is skipped with its reason, never guessed.
HOME_A6=$(new_world a6)
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: argocd-server\nspec: {}\n' > "$TMP_ROOT/nons.yaml"
seed_pr "$HOME_A6" k8s/prod/argocd/install.yaml "$TMP_ROOT/nons.yaml" k8s/prod/argocd/install.yaml
seed_diff "$HOME_A6" k8s/prod/argocd/install.yaml 4
out=$(run_cw "$HOME_A6" 1790000000 register w6 "$PR_URL") || fail "register failed"
case "$out" in
  *"no deployable service touched"*"(no namespace: argocd-server in k8s/prod/argocd/install.yaml)"*) ;;
  *) fail "a Deployment without metadata.namespace was not skipped with its reason: $out" ;;
esac
[ -e "$HOME_A6/state/change-watch/w6-3317" ] && fail "a Deployment without a namespace was watched under a guess"
pass "a Deployment without metadata.namespace is skipped, never guessed"

# A manifest that cannot be read is reported as unread, not as no service.
HOME_A7=$(new_world a7)
seed_pr "$HOME_A7" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_A7" "$MANIFEST" "$FEED_LINE"
rm -f "$HOME_A7/forge/head-ref"
out=$(run_cw "$HOME_A7" 1790000000 register w7 "$PR_URL") || fail "register failed"
case "$out" in
  *"could not read 1 manifest(s) for $PR_URL; nothing registered"*) ;;
  *) fail "an unreadable manifest was not reported as unread: $out" ;;
esac
[ -e "$HOME_A7/state/change-watch/w7-3317" ] && fail "an unreadable manifest created a watch record"
pass "an unreadable manifest is a stated measurement gap, not a PR without a service"

# --- (b) a regressing 5xx series fires at +15m --------------------------------

HOME_B=$(new_world b)
seed_pr "$HOME_B" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_B" "$MANIFEST" "$FEED_LINE"
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

# A relative bar with no baseline reading is recorded but never scored.
HOME_M=$(new_world m)
seed_pr "$HOME_M" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_M" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_M" restarts muso-prod_feed-service baseline ''
seed_series "$HOME_M" restarts muso-prod_feed-service sample 2
run_cw "$HOME_M" 1790000000 register m1 "$PR_URL" >/dev/null || fail "register failed"
run_cw "$HOME_M" 1790000300 sample m1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_M" 1790000300 verdict m1-3317 | grep -q "clean so far" \
  || fail "a restarts reading with no baseline was scored against zero"
awk -F'\t' '$3 == "restarts@muso-prod/feed-service" && $4 == "2" && $7 == "0" { ok = 1 } END { exit(ok ? 0 : 1) }' \
  "$HOME_M/state/change-watch/m1-3317/samples.log" \
  || fail "the unscored reading was not recorded with scored=0"
pass "a metric with a relative bar and no baseline is recorded but not scored"

# --- (c) an OOMKilled event regresses ------------------------------------------

HOME_C=$(new_world c)
seed_pr "$HOME_C" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_C" "$MANIFEST" "$FEED_LINE"
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
seed_pr "$HOME_D" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_D" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_D" http_5xx_per_min muso-prod_feed-service baseline 0
seed_series "$HOME_D" http_5xx_per_min muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
seed_series "$HOME_D" restarts muso-prod_feed-service baseline 2
seed_series "$HOME_D" restarts muso-prod_feed-service sample \
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

# A schedule in which the target was never read completes unmeasured, not clean.
HOME_U=$(new_world u)
seed_pr "$HOME_U" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_U" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_U" 1790000000 register u1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_U/state/u1.meta"
run_cw "$HOME_U" 1790044000 drive u1-3317 >/dev/null || fail "unmeasured drive failed"
[ "$(run_cw "$HOME_U" 1790044000 verdict u1-3317)" = "change-watch completed unmeasured" ] \
  || fail "an entirely unmeasured watch read as: $(run_cw "$HOME_U" 1790044000 verdict u1-3317)"
grep -qF "note: change-watch completed unmeasured for $PR_URL (never measured: muso-prod/feed-service)" \
  "$HOME_U/state/u1.status" || fail "the unmeasured completion note was not appended"
grep -q "change-watch clean" "$HOME_U/state/u1.status" && fail "an unmeasured watch recorded a clean note"
[ -e "$HOME_U/state/.wake-queue" ] && [ -s "$HOME_U/state/.wake-queue" ] \
  && fail "an unmeasured completion must not queue a wake"
pass "a never-measured target completes unmeasured with its own note and no clean claim"

# --- the pool metric is the Deployment's own pool -------------------------------

HOME_P=$(new_world p)
seed_pr "$HOME_P" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_P" "$MANIFEST" "$FEED_LINE"
printf '10.0.0.17\t6432\tfeed\n' > "$HOME_P/cluster/pool.muso-prod_feed-service"
seed_series "$HOME_P" pgbouncer_cl_waiting muso-prod_feed-service baseline 0
seed_series "$HOME_P" pgbouncer_cl_waiting muso-prod_feed-service sample 3 3
run_cw "$HOME_P" 1790000000 register p1 "$PR_URL" >/dev/null || fail "register failed"
[ "$(cat "$HOME_P/state/change-watch/p1-3317/pools")" = "$(printf 'muso-prod/feed-service\t10.0.0.17\t6432\tfeed')" ] \
  || fail "the resolved pool was not recorded"
run_cw "$HOME_P" 1790000300 sample p1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_P" 1790000900 sample p1-3317 >/dev/null || fail "sample failed"
[ "$(run_cw "$HOME_P" 1790000900 verdict p1-3317)" = "change-watch regressed at +15m on pgbouncer_cl_waiting (3 vs baseline 0)" ] \
  || fail "two consecutive pool waits did not regress"
pass "the pool metric reads the Deployment's resolved pool"

HOME_Q=$(new_world q)
seed_pr "$HOME_Q" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_Q" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_Q" pgbouncer_cl_waiting muso-prod_feed-service baseline 0
seed_series "$HOME_Q" pgbouncer_cl_waiting muso-prod_feed-service sample 3 3
run_cw "$HOME_Q" 1790000000 register q1 "$PR_URL" >/dev/null || fail "register failed"
[ "$(awk -F'\t' '$1 == "pgbouncer_cl_waiting@muso-prod/feed-service" { print $2 }' "$HOME_Q/state/change-watch/q1-3317/baseline")" = "" ] \
  || fail "an unresolvable pool produced a baseline reading"
run_cw "$HOME_Q" 1790000300 sample q1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_Q" 1790000900 sample q1-3317 >/dev/null || fail "sample failed"
run_cw "$HOME_Q" 1790000900 verdict q1-3317 | grep -q "clean so far" \
  || fail "an unresolvable pool was scored from a series it does not own"
pass "an unresolvable pool leaves the pool metric unmeasured"

# --- an interrupted drive is never clean and can be re-armed ------------------

HOME_I=$(new_world i)
seed_pr "$HOME_I" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_I" "$MANIFEST" "$FEED_LINE"
seed_series "$HOME_I" restarts muso-prod_feed-service baseline 0
seed_series "$HOME_I" restarts muso-prod_feed-service sample \
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
run_cw "$HOME_I" 1790000000 register i1 "$PR_URL" >/dev/null || fail "register failed"
printf 'kind=crewmate\n' > "$HOME_I/state/i1.meta"
cat > "$HOME_I/kill-sleep.sh" <<'STUB'
#!/usr/bin/env bash
kill -TERM "$PPID"
sleep 5
STUB
chmod +x "$HOME_I/kill-sleep.sh"

CW_SLEEP="$HOME_I/kill-sleep.sh" run_cw "$HOME_I" 1790000900 drive i1-3317 >/dev/null 2>&1 \
  && fail "a drive stopped mid-schedule exited as if it completed"
[ "$(run_cw "$HOME_I" 1790000900 verdict i1-3317)" = "change-watch interrupted at +15m" ] \
  || fail "interrupted verdict is wrong: $(run_cw "$HOME_I" 1790000900 verdict i1-3317)"
[ "$(grep -c '' "$HOME_I/state/change-watch/i1-3317/sampled")" -eq 2 ] \
  || fail "the drive did not take the two due samples before the stop"
grep -qF "check: change-watch i1 $PR_URL interrupted at +15m" "$HOME_I/state/.wake-queue" \
  || fail "the interruption did not queue one check wake"
[ ! -e "$HOME_I/state/change-watch/i1-3317/drive.pid" ] || fail "the stopped drive left its pid record"
pass "a drive stopped mid-schedule records interrupted and queues one wake"

before=$(grep -c '' "$HOME_I/arm.log")
out=$(run_cw "$HOME_I" 1790001000 register i1 "$PR_URL") || fail "re-register failed"
case "$out" in
  *"re-armed i1-3317"*"(13 sample(s) remaining)"*) pass "re-registering an interrupted watch re-arms the remaining samples" ;;
  *) fail "re-register did not re-arm: $out" ;;
esac
[ "$(grep -c '' "$HOME_I/arm.log")" -eq $((before + 2)) ] \
  || fail "re-arm did not retire the old source and arm a new one: $(cat "$HOME_I/arm.log")"
grep -q "^retire cw-" "$HOME_I/arm.log" || fail "re-arm did not retire the stopped source"
run_cw "$HOME_I" 1790001000 verdict i1-3317 | grep -q "clean so far" \
  || fail "re-arm did not clear the interrupted verdict"

run_cw "$HOME_I" 1790044000 drive i1-3317 >/dev/null || fail "resumed drive failed"
[ "$(run_cw "$HOME_I" 1790044000 verdict i1-3317)" = "change-watch clean" ] \
  || fail "resumed drive did not end clean: $(run_cw "$HOME_I" 1790044000 verdict i1-3317)"
[ "$(grep -c '' "$HOME_I/state/change-watch/i1-3317/sampled")" -eq 15 ] \
  || fail "the resumed drive did not take exactly the remaining samples"
pass "a re-armed watch finishes its remaining schedule"

# A drive killed outright is found by its dead pid at the next read.
HOME_K=$(new_world k)
seed_pr "$HOME_K" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_K" "$MANIFEST" "$FEED_LINE"
run_cw "$HOME_K" 1790000000 register k1 "$PR_URL" >/dev/null || fail "register failed"
printf '%s\n' 999999 > "$HOME_K/state/change-watch/k1-3317/drive.pid"
printf '%s\n' 1790001800 > "$HOME_K/state/change-watch/k1-3317/drive.alive"
[ "$(run_cw "$HOME_K" 1790040000 verdict k1-3317)" = "change-watch interrupted at +30m" ] \
  || fail "a dead drive was not reported at its last heartbeat: $(run_cw "$HOME_K" 1790040000 verdict k1-3317)"
grep -qF "check: change-watch k1 $PR_URL interrupted at +30m" "$HOME_K/state/.wake-queue" \
  || fail "a dead drive did not queue the interruption wake"
pass "a drive killed outright is recorded as interrupted at its last heartbeat"

# --- (e) a docs-only PR registers nothing --------------------------------------

HOME_E=$(new_world e)
printf 'README.md\ndocs/notes.md\n' > "$HOME_E/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_E/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_E/forge/head-ref"
out=$(run_cw "$HOME_E" 1790000000 register e1 "$PR_URL") || fail "docs-only register failed"
case "$out" in
  *"no deployable service touched"*"nothing registered"*) pass "docs-only PR registers nothing" ;;
  *) fail "docs-only register did not report nothing: $out" ;;
esac
[ -e "$HOME_E/state/change-watch/e1-3317" ] && fail "docs-only PR created a watch record"
[ "$(grep -c '' "$HOME_E/arm.log" 2>/dev/null || echo 0)" -eq 0 ] \
  || fail "docs-only PR armed a watch"
pass "docs-only PR leaves no watch behind"

# --- an application repo resolves through its name -----------------------------

HOME_F=$(new_world f)
mkdir -p "$HOME_F/projects/H-DevOps/k8s/prod/core-services"
cp "$TMP_ROOT/multi.yaml" "$HOME_F/projects/H-DevOps/k8s/prod/core-services/deployments.yaml"
printf 'src/main.py\n' > "$HOME_F/forge/files.txt"
printf '%s\n' 1790000000 > "$HOME_F/forge/merge-epoch"
printf '%s\n' deadbeef > "$HOME_F/forge/head-ref"
out=$(env FM_HOME="$HOME_F" FM_STATE_OVERRIDE="$HOME_F/state" FM_CW_NOW=1790000000 \
  FM_CW_FORGE_DIR="$HOME_F/forge" FM_CW_CLUSTER_DIR="$HOME_F/cluster" \
  FM_CW_HDEVOPS_K8S_DIR="$HOME_F/projects/H-DevOps/k8s/prod" \
  FM_CW_ARM_CMD="$HOME_F/arm.sh" FM_CW_ARM_LOG="$HOME_F/arm.log" \
  FM_CW_SEND_CMD="$HOME_F/send.sh" FM_CW_SEND_LOG="$HOME_F/send.log" \
  FM_CW_NO_WIKI=1 "$CW" register f1 'https://github.com/Muso-AI/feed-service/pull/42') \
  || fail "application-repo register failed"
case "$out" in
  *"registered f1-42"*) pass "an application repo resolves to its service Deployment" ;;
  *) fail "application-repo register did not resolve a target: $out" ;;
esac
[ "$(cat "$HOME_F/state/change-watch/f1-42/targets")" = "$(printf 'muso-prod\tfeed-service')" ] \
  || fail "application-repo target is wrong (namespace must come from the manifest)"

# --- live reads through a kubectl shim -----------------------------------------
# The shim answers the exact kubectl calls a sample makes: two replicas with a
# 512Mi limit, metrics-server rows with a CPU column before the memory column,
# and a capped access log whose lines span two minutes.

HOME_L=$(new_world l)
mkdir -p "$HOME_L/bin"
cat > "$HOME_L/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
  *" get pods "*)
    cat <<'JSON'
{"items":[{"metadata":{"name":"feed-service-abc"},
  "spec":{"containers":[{"name":"feed-service","resources":{"limits":{"memory":"512Mi"}}}]},
  "status":{"containerStatuses":[{"name":"feed-service","restartCount":0,"lastState":{}}]}},
 {"metadata":{"name":"feed-service-def"},
  "spec":{"containers":[{"name":"feed-service","resources":{"limits":{"memory":"512Mi"}}}]},
  "status":{"containerStatuses":[{"name":"feed-service","restartCount":0,"lastState":{}}]}}]}
JSON
    ;;
  *" top pods "*)
    printf 'feed-service-abc   feed-service   500m   300Mi\nfeed-service-def   feed-service   250m   400Mi\n'
    ;;
  *" logs "*)
    awk 'BEGIN {
      for (i = 0; i < 2000; i++) {
        s = int(i * 120 / 1999)
        printf "[pod/feed-service-abc/feed-service] 2026-09-22T06:%02d:%02d.000000000Z 10.0.0.1 - \"GET /home HTTP/1.1\" %d 12\n", int(s / 60), s % 60, (i % 167 == 0 ? 502 : 200)
      }
    }'
    ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$HOME_L/bin/kubectl"
seed_pr "$HOME_L" "$MANIFEST" "$TMP_ROOT/multi.yaml" "$MANIFEST"
seed_diff "$HOME_L" "$MANIFEST" "$FEED_LINE"
CW_CLUSTER_DIR='' PATH="$HOME_L/bin:$PATH" run_cw "$HOME_L" 1790000000 register l1 "$PR_URL" >/dev/null \
  || fail "live register failed"
CW_CLUSTER_DIR='' PATH="$HOME_L/bin:$PATH" run_cw "$HOME_L" 1790000300 sample l1-3317 >/dev/null \
  || fail "live sample failed"
SAMPLES_L="$HOME_L/state/change-watch/l1-3317/samples.log"
[ "$(awk -F'\t' '$3 == "rss_ratio@muso-prod/feed-service" { print $4 }' "$SAMPLES_L")" = "0.7812" ] \
  || fail "rss_ratio did not take the worst replica's 400Mi of 512Mi from the memory column: $(cat "$SAMPLES_L")"
[ "$(awk -F'\t' '$3 == "http_5xx_per_min@muso-prod/feed-service" { print $4 "/" $5 }' "$SAMPLES_L")" = "6.0000/6.0000" ] \
  || fail "a capped log was not rated over the span it covers in both windows: $(cat "$SAMPLES_L")"
CW_CLUSTER_DIR='' PATH="$HOME_L/bin:$PATH" run_cw "$HOME_L" 1790000300 verdict l1-3317 | grep -q "clean so far" \
  || fail "an unchanged service regressed on live reads"
pass "live reads take the worst replica's memory column and rate a capped log over its span"
