#!/usr/bin/env bash
# Tests for bin/fm-fable-runway.sh (the read-only Fable-runway monitor) and
# bin/fm-fable-runway-check.sh (the registered slow-poll check).
#
# The monitor's verdict is the whole point of the script, so every threshold is
# pinned from a fixture: GREEN, YELLOW and RED on both the remaining-percent and
# the projected-exhaustion axes, the pool's routable counts, the pool's own
# per-account exhaustion projection, and the unmeasurable case that must be RED
# with a reason rather than GREEN. Fixtures are files, so no case reads quota-axi
# or reaches a live better-ccflare gateway.
#
# The pool's two ways of reading a verdict wrong are pinned too: a pool with no
# Fable-scoped window anywhere must still be judged by its routable count rather
# than falling through to UNKNOWN, and one nearly spent account among healthy
# ones must not red-line the pool. So is the per-call clamp that keeps a hung
# quota-axi from running the whole check past the watcher's own bound.
#
# The check cases pin the wake contract: one line on a state change, silence on
# an unchanged poll and on pool membership churn alone, a throttled RED repeat,
# and the fail-back line that names the account which regained Fable capacity -
# only for an account that really came back, never for one merely added, and not
# lost to a silent poll, an unreadable pool, or a record from another schema.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR="$ROOT/bin/fm-fable-runway.sh"
CHECK="$ROOT/bin/fm-fable-runway-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-fable-runway)

# A fixed clock so every projection in a fixture is deterministic.
NOW=1790000000

iso_in_hours() {
  jq -rn --argjson now "$NOW" --argjson h "$1" '($now + ($h * 3600)) | todateiso8601'
}

# make_quota <file> <remaining> <burn> <exhaustion-hours|none> <runway-status>
make_quota() {
  local file=$1 remaining=$2 burn=$3 hours=$4 status=$5 exhaustion='null'
  if [ "$hours" != none ]; then
    exhaustion="\"$(iso_in_hours "$hours")\""
  fi
  cat > "$file" <<JSON
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [
        {
          "id": "model:fable",
          "label": "Fable week",
          "kind": "model",
          "percentRemaining": $remaining,
          "pace": {"status": "ahead", "burnMultiple": $burn}
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "model:fable",
            "status": "known",
            "effectivePercentRemaining": $remaining,
            "runway": {"status": "$status", "projectedExhaustedAt": $exhaustion}
          }
        ]
      }
    }
  ]
}
JSON
}

# make_pool <health-file> <accounts-file> <routable> <configured> <exhausted>
# Resets the accounts file to an empty pool array.
make_pool() {
  local health=$1 accounts=$2 routable=$3 configured=$4 exhausted=$5
  cat > "$health" <<JSON
{"status":"ok","pool":{"configured":$configured,"paused":0,"rate_limited":0,"routable":$routable,"usage_exhausted":$exhausted,"next_available_at":null}}
JSON
  printf '[]\n' > "$accounts"
}

# add_account <accounts-file> <name> <session-pct> <weekly-all-pct> <fable-pct> <resets-in-hours>
add_account() {
  local file=$1 name=$2 session=$3 weekly=$4 pct=$5 hours=$6 resets tmp="$1.tmp"
  resets=$(iso_in_hours "$hours")
  jq -c --arg name "$name" --argjson session "$session" --argjson weekly "$weekly" \
    --argjson pct "$pct" --arg resets "$resets" '
    . + [{
      name: $name,
      tokenStatus: "valid",
      paused: false,
      usageData: {limits: [
        {kind: "session", percent: $session},
        {kind: "weekly_all", percent: $weekly},
        {kind: "weekly_scoped", percent: $pct,
         resets_at: $resets,
         scope: {model: {display_name: "Fable"}}}
      ]}
    }]' "$file" > "$tmp" && mv "$tmp" "$file"
}

# add_account_with_wall <accounts-file> <name> <session-pct> <weekly-all-pct>
#   <fable-pct> <resets-in-hours>
# Both weekly windows carry a resets_at, so the all-models wall is projectable
# the same way the Fable-scoped one is.
add_account_with_wall() {
  local file=$1 name=$2 session=$3 weekly=$4 pct=$5 hours=$6 resets tmp="$1.tmp"
  resets=$(iso_in_hours "$hours")
  jq -c --arg name "$name" --argjson session "$session" --argjson weekly "$weekly" \
    --argjson pct "$pct" --arg resets "$resets" '
    . + [{
      name: $name,
      tokenStatus: "valid",
      paused: false,
      usageData: {limits: [
        {kind: "session", percent: $session},
        {kind: "weekly_all", percent: $weekly, resets_at: $resets},
        {kind: "weekly_scoped", percent: $pct,
         resets_at: $resets,
         scope: {model: {display_name: "Fable"}}}
      ]}
    }]' "$file" > "$tmp" && mv "$tmp" "$file"
}

# add_account_resetting_at <accounts-file> <name> <fable-pct> <resets-at>
# The resets_at is written verbatim, so a fixture can carry a timestamp the
# monitor cannot place in a seven-day week.
add_account_resetting_at() {
  local file=$1 name=$2 pct=$3 resets=$4 tmp="$1.tmp"
  jq -c --arg name "$name" --argjson pct "$pct" --arg resets "$resets" '
    . + [{
      name: $name,
      tokenStatus: "valid",
      paused: false,
      usageData: {limits: [
        {kind: "session", percent: 5},
        {kind: "weekly_all", percent: $pct},
        {kind: "weekly_scoped", percent: $pct,
         resets_at: $resets,
         scope: {model: {display_name: "Fable"}}}
      ]}
    }]' "$file" > "$tmp" && mv "$tmp" "$file"
}

# add_account_needing_auth <accounts-file> <name> <fable-pct> <resets-in-hours>
#   <auth-field> <auth-value>
# An otherwise healthy account carrying one of the gateway's login-required
# signals, so the same fixture covers requiresReauth, tokenStatus and pauseReason.
add_account_needing_auth() {
  local file=$1 name=$2 pct=$3 hours=$4 key=$5 value=$6 resets tmp="$1.tmp"
  resets=$(iso_in_hours "$hours")
  jq -c --arg name "$name" --argjson pct "$pct" --arg resets "$resets" \
    --arg key "$key" --argjson value "$value" '
    . + [({
      name: $name,
      tokenStatus: "valid",
      paused: false,
      usageData: {limits: [
        {kind: "session", percent: 5},
        {kind: "weekly_all", percent: $pct},
        {kind: "weekly_scoped", percent: $pct,
         resets_at: $resets,
         scope: {model: {display_name: "Fable"}}}
      ]}
    } | .[$key] = $value)]' "$file" > "$tmp" && mv "$tmp" "$file"
}

# add_plain_account <accounts-file> <name> <session-pct> <weekly-all-pct>
# An account whose windows carry no Fable-scoped limit at all, which is what a
# gateway build that does not break its weekly window out per model reports.
add_plain_account() {
  local file=$1 name=$2 session=$3 weekly=$4 tmp="$1.tmp"
  jq -c --arg name "$name" --argjson session "$session" --argjson weekly "$weekly" '
    . + [{
      name: $name,
      tokenStatus: "valid",
      paused: false,
      usageData: {limits: [
        {kind: "session", percent: $session},
        {kind: "weekly_all", percent: $weekly}
      ]}
    }]' "$file" > "$tmp" && mv "$tmp" "$file"
}

# make_auth_account <auth-dir> <label> <expires-in-hours> <disabled>
# One CLIProxyAPI auth file. The secret-bearing fields are written too, so a
# case can assert that none of them ever reaches the monitor's line.
make_auth_account() {
  local dir=$1 label=$2 hours=$3 disabled=$4
  mkdir -p "$dir"
  jq -n --arg e "$(iso_in_hours "$hours")" --argjson d "$disabled" '{
    type: "claude",
    email: "do-not-print@example.invalid",
    access_token: "sk-do-not-print-access",
    refresh_token: "sk-do-not-print-refresh",
    expired: $e,
    disabled: $d
  }' > "$dir/claude-$label.json"
}

# A path that does not exist, so a case that says nothing about CLIProxyAPI is
# judged by better-ccflare alone and never reads this machine's real inventory.
NO_AUTH="$TMP_ROOT/no-auth-dir"

# run_monitor <quota> <health> <accounts> [auth-dir]: line followed by rc=<n>
run_monitor() {
  local quota=$1 health=$2 accounts=$3 out rc
  out=$(FM_FABLE_RUNWAY_NOW="$NOW" \
    FM_FABLE_RUNWAY_AUTH_DIR="${4:-$NO_AUTH}" \
    FM_FABLE_RUNWAY_QUOTA_JSON="$quota" \
    FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$health" \
    FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$accounts" \
    "$MONITOR" 2>/dev/null)
  rc=$?
  printf '%s\n' "$out"
  printf 'rc=%s\n' "$rc"
}

field() { printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p" | head -n 1; }

expect_field() {
  local line=$1 key=$2 want=$3 label=$4 got
  got=$(field "$line" "$key")
  [ "$got" = "$want" ] || fail "$label: $key was '$got', wanted '$want' (line: $line)"
}

expect_rc() {
  local out=$1 want=$2 label=$3 got
  got=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -n 1)
  [ "$got" = "$want" ] || fail "$label: exit was '$got', wanted '$want' (out: $out)"
}

# --- monitor: supervisor runway thresholds ----------------------------------

lab="$TMP_ROOT/monitor"
mkdir -p "$lab"
quota="$lab/quota.json"
health="$lab/health.json"
accounts="$lab/accounts.json"

# Green: plenty of runway on both axes, healthy pool depth.
make_quota "$quota" 50 0.5 none through_reset
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" acct-a 5 40 20 100
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" overall GREEN "green overall"
expect_field "$out" fable_state GREEN "green fable"
expect_field "$out" pool_state GREEN "green pool"
expect_field "$out" fable_remaining 50% "green remaining"
expect_rc "$out" 0 "green exit"
pass "green fixture reports GREEN and exits 0"

# Yellow on remaining percent (24 is under 25 but not under 10).
make_quota "$quota" 24 0.5 none through_reset
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state YELLOW "yellow remaining fable"
expect_field "$out" fable_reason remaining_under_25_percent "yellow remaining reason"
expect_field "$out" overall YELLOW "yellow remaining overall"
expect_rc "$out" 0 "yellow remaining exit"
pass "remaining under 25 percent is YELLOW and exits 0"

# Yellow on projected exhaustion (5h is under 6h but not under 2h).
make_quota "$quota" 80 1.0 5 projected_exhaustion
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state YELLOW "yellow time fable"
expect_field "$out" fable_reason exhaustion_under_6h "yellow time reason"
expect_rc "$out" 0 "yellow time exit"
pass "projected exhaustion under 6h is YELLOW"

# Red on remaining percent.
make_quota "$quota" 9 1.0 none through_reset
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state RED "red remaining fable"
expect_field "$out" fable_reason remaining_under_10_percent "red remaining reason"
expect_field "$out" overall RED "red remaining overall"
expect_rc "$out" 2 "red remaining exit"
pass "remaining under 10 percent is RED and exits non-zero"

# Red on projected exhaustion.
make_quota "$quota" 80 2.0 1 projected_exhaustion
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state RED "red time fable"
expect_field "$out" fable_reason exhaustion_under_2h "red time reason"
expect_rc "$out" 2 "red time exit"
pass "projected exhaustion under 2h is RED and exits non-zero"

# exhausted_now is RED even without a projected timestamp.
make_quota "$quota" 3 3.0 none exhausted_now
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state RED "exhausted-now fable"
expect_field "$out" fable_reason exhausted_now "exhausted-now reason"
expect_rc "$out" 2 "exhausted-now exit"
pass "exhausted_now is RED"

# Threshold boundaries: exactly 10 percent and exactly 2h are not RED.
make_quota "$quota" 10 1.0 none through_reset
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state YELLOW "boundary 10 percent fable"
make_quota "$quota" 80 1.0 2 projected_exhaustion
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state YELLOW "boundary 2h fable"
pass "the RED boundaries are exclusive (10 percent and 2h are YELLOW)"

# Unmeasurable: an unrecognized quota document is RED with a reason, never GREEN.
printf '{"schemaVersion": 5, "providers": "nope"}\n' > "$quota"
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state RED "unmeasurable fable"
expect_field "$out" fable_reason quota_axi_json_not_recognized "unmeasurable reason"
expect_rc "$out" 2 "unmeasurable exit"
pass "an unmeasurable runway is RED with a reason"

# An empty provider list is also unmeasurable, and named separately.
printf '{"schemaVersion": 5, "providers": []}\n' > "$quota"
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" fable_state RED "no-provider fable"
expect_field "$out" fable_reason no_claude_provider "no-provider reason"
pass "a missing claude provider is RED with a reason"

# --- monitor: pool thresholds ------------------------------------------------

make_quota "$quota" 60 0.5 none through_reset

# Pool YELLOW at 3 routable accounts.
make_pool "$health" "$accounts" 3 11 6
add_account "$accounts" acct-a 5 40 10 200
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state YELLOW "pool yellow routable"
expect_field "$out" pool_reason routable_at_or_below_3 "pool yellow reason"
expect_field "$out" overall YELLOW "pool yellow overall"
expect_rc "$out" 0 "pool yellow exit"
pass "3 routable accounts is a YELLOW pool"

# Pool RED at 1 routable account.
make_pool "$health" "$accounts" 1 11 8
add_account "$accounts" acct-a 5 40 10 200
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "pool red routable"
expect_field "$out" pool_reason routable_at_or_below_1 "pool red reason"
expect_rc "$out" 2 "pool red exit"
pass "1 routable account is a RED pool"

# Pool RED when no account is Fable-capable, even with routable accounts.
make_pool "$health" "$accounts" 5 11 6
add_account "$accounts" spent 5 100 100 200
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "pool no-capable"
expect_field "$out" pool_reason no_fable_capable_account "pool no-capable reason"
expect_rc "$out" 2 "pool no-capable exit"
pass "a pool with no Fable-capable account is RED"

# Pool exhaustion projection: 90 percent used with six hours of a seven-day
# window elapsed projects exhaustion in well under two hours.
make_pool "$health" "$accounts" 5 11 1
add_account "$accounts" burny 5 40 90 162
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "pool projected red"
expect_field "$out" pool_reason exhaustion_under_2h "pool projected reason"
expect_rc "$out" 2 "pool projected exit"
pass "a fast-burning pool account projects a RED pool"

# The routable count decides on its own, so an empty pool is RED rather than
# falling through to UNKNOWN when no account exposes a Fable-scoped window.
make_pool "$health" "$accounts" 0 11 11
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "empty pool state"
expect_field "$out" pool_reason routable_at_or_below_1 "empty pool reason"
expect_field "$out" overall RED "empty pool overall"
expect_rc "$out" 2 "empty pool exit"
pass "a pool with zero routable accounts is RED, not UNKNOWN"

# Accounts with no Fable-scoped window suppress the projection, not the verdict.
make_pool "$health" "$accounts" 6 11 0
add_plain_account "$accounts" plain-a 5 40
add_plain_account "$accounts" plain-b 5 40
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "no-window pool state"
expect_field "$out" pool_reason routable_only_without_fable_window "no-window pool reason"
expect_field "$out" pool_tracked none "no-window pool tracked"
expect_field "$out" pool_capable none "no-window pool capable"
expect_field "$out" pool_exhaustion unknown "no-window pool projection"
expect_rc "$out" 0 "no-window pool exit"
make_pool "$health" "$accounts" 2 11 9
add_plain_account "$accounts" plain-a 5 40
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state YELLOW "no-window thin pool state"
expect_field "$out" pool_reason routable_at_or_below_3 "no-window thin pool reason"
pass "a pool with no Fable-scoped window is still judged by its routable count"

# A pool can mix both account shapes, and a window-less account is not Fable
# capacity: it must neither be named as capable nor make the pool look healthy
# while the only readable Fable window is burning down.
make_pool "$health" "$accounts" 11 11 0
add_account "$accounts" scoped-hot 5 99 99 24
add_plain_account "$accounts" plain-1 2 2
add_plain_account "$accounts" plain-2 3 3
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_capable scoped-hot "mixed-shape pool capable"
expect_field "$out" pool_tracked scoped-hot "mixed-shape pool tracked"
expect_field "$out" pool_state RED "mixed-shape pool state"
expect_field "$out" pool_reason exhaustion_under_2h "mixed-shape pool reason"
expect_rc "$out" 2 "mixed-shape pool exit"

# The mirror case: the only Fable window in the pool is spent, so the pool has
# no Fable capacity however routable its window-less accounts are.
make_pool "$health" "$accounts" 11 11 1
add_account "$accounts" scoped-spent 5 100 100 100
add_plain_account "$accounts" plain-1 2 2
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "spent-window pool state"
expect_field "$out" pool_reason no_fable_capable_account "spent-window pool reason"
expect_field "$out" pool_capable none "spent-window pool capable"
expect_rc "$out" 2 "spent-window pool exit"
pass "an account with no Fable window is routable but never Fable-capable"

# The pool verdict is not the worst account: one nearly spent account among
# healthy ones leaves the pool GREEN, and the projection reported is the best
# remaining account's runway.
make_pool "$health" "$accounts" 6 11 0
for acct_name in one two three four five; do
  add_account "$accounts" "acct-$acct_name" 5 40 20 100
done
add_account "$accounts" acct-hot 5 99 99 24
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "mixed pool state"
expect_field "$out" pool_reason has_fable_capacity "mixed pool reason"
expect_field "$out" pool_exhaustion 100.0h "mixed pool projection"
expect_rc "$out" 0 "mixed pool exit"
pass "one nearly spent account does not red-line a pool of healthy ones"

# A pool where every capable account is inside two hours is RED.
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" burny-a 5 90 90 162
add_account "$accounts" burny-b 5 92 92 162
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "all-hot pool state"
expect_field "$out" pool_reason exhaustion_under_2h "all-hot pool reason"
expect_rc "$out" 2 "all-hot pool exit"
pass "a pool whose every capable account is inside two hours is RED"

# A capable account whose week cannot be placed may have any amount of runway
# left, so it must not let the one account that happens to be projectable decide
# RED on its own. A clock a minute ahead, or a gateway that does not cut the week
# at exactly seven days, puts resets_at past now+168h on a freshly reset account.
make_pool "$health" "$accounts" 8 11 0
add_account "$accounts" fresh-skewed 5 2 2 169
add_account "$accounts" hot 5 99 99 24
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_unprojected fresh-skewed "skewed-week unprojected"
expect_field "$out" pool_capable fresh-skewed,hot "skewed-week capable"
expect_field "$out" pool_reason exhaustion_unprojectable "skewed-week reason"
expect_field "$out" pool_state GREEN "skewed-week pool state"
expect_rc "$out" 0 "skewed-week exit"

# A resets_at carrying a non-UTC offset cannot be placed either, and that must
# cost the account its projection rather than the whole pool verdict.
make_pool "$health" "$accounts" 8 11 0
add_account_resetting_at "$accounts" offset-account 2 "2026-10-01T12:00:00+01:00"
add_account "$accounts" hot 5 99 99 24
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_unprojected offset-account "offset unprojected"
expect_field "$out" pool_reason exhaustion_unprojectable "offset reason"
expect_field "$out" pool_state GREEN "offset pool state"
expect_rc "$out" 0 "offset exit"

# With every capable account unprojectable there is no projection at all, and
# the pool is still judged by its routable count rather than by a guess.
make_pool "$health" "$accounts" 8 11 0
add_account "$accounts" skewed-one 5 2 2 169
add_account "$accounts" skewed-two 5 40 40 200
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_unprojected skewed-one,skewed-two "all-unprojectable unprojected"
expect_field "$out" pool_exhaustion unknown "all-unprojectable projection"
expect_field "$out" pool_reason exhaustion_unprojectable "all-unprojectable reason"
expect_field "$out" pool_state GREEN "all-unprojectable pool state"
expect_rc "$out" 0 "all-unprojectable exit"

# The suppression is of the time rule only: the routable thresholds still apply.
make_pool "$health" "$accounts" 3 11 6
add_account "$accounts" skewed-one 5 2 2 169
add_account "$accounts" hot 5 99 99 24
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state YELLOW "unprojectable thin pool state"
expect_field "$out" pool_reason routable_at_or_below_3 "unprojectable thin pool reason"
pass "an unprojectable capable account suppresses the time rule, not the verdict"

# The all-models weekly wall binds before the Fable-scoped one here: every
# account has burned 99 percent of weekly_all with its Fable week barely
# touched. Reading the Fable window alone would report a full week of runway
# right up to the moment the pool walls.
make_pool "$health" "$accounts" 8 8 0
for acct_name in 0 1 2 3 4; do
  add_account_with_wall "$accounts" "acct-$acct_name" 5 99 5 100
done
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "weekly-all wall pool state"
expect_field "$out" pool_reason exhaustion_under_2h "weekly-all wall pool reason"
expect_rc "$out" 2 "weekly-all wall exit"

# The sooner wall wins in the other direction too: a spent Fable week is not
# rescued by an untouched all-models week.
make_pool "$health" "$accounts" 8 8 0
add_account_with_wall "$accounts" fable-bound 5 5 99 24
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "fable wall pool state"
expect_field "$out" pool_reason exhaustion_under_2h "fable wall pool reason"

# One placeable weekly window is enough: an account is unprojectable only when
# neither week can be placed.
make_pool "$health" "$accounts" 8 8 0
jq -c --arg r "$(iso_in_hours 100)" '[{
  name: "half-placeable", tokenStatus: "valid", paused: false,
  usageData: {limits: [
    {kind: "session", percent: 5},
    {kind: "weekly_all", percent: 50, resets_at: "2026-10-01T12:00:00+01:00"},
    {kind: "weekly_scoped", percent: 50, resets_at: $r,
     scope: {model: {display_name: "Fable"}}}
  ]}
}]' <<<'null' > "$accounts"
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_unprojected none "half-placeable unprojected"
expect_field "$out" pool_state GREEN "half-placeable pool state"
expect_field "$out" pool_reason has_fable_capacity "half-placeable pool reason"
pass "an account's runway is the sooner of its two weekly walls"

# A week that refills before its burn can spend it never walls. Eight capable
# accounts each sitting at 99 percent on both weekly windows, every one of them
# resetting in an hour, is a pool with eight fresh weeks about to start - not a
# pool two hours from having nothing to serve. Aligned weeks are the normal
# shape of a pool provisioned in one sitting, so the last hours before a shared
# reset must not be a RED that wakes the supervisor for a Grok handoff.
make_pool "$health" "$accounts" 8 8 0
for acct_name in a b c d e f g h; do
  add_account_with_wall "$accounts" "acct-$acct_name" 5 99 99 1
done
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "reset-ceiling pool state"
expect_field "$out" pool_reason has_fable_capacity "reset-ceiling pool reason"
expect_field "$out" pool_exhaustion 1.0h "reset-ceiling pool projection"
expect_field "$out" overall GREEN "reset-ceiling overall"
expect_rc "$out" 0 "reset-ceiling exit"

# The ceiling is on the projection, not on the verdict: the same 99 percent with
# a week still to run really is about to wall, and stays RED.
make_pool "$health" "$accounts" 8 8 0
for acct_name in a b c d e f g h; do
  add_account_with_wall "$accounts" "acct-$acct_name" 5 99 99 100
done
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "unreached-ceiling pool state"
expect_field "$out" pool_reason exhaustion_under_2h "unreached-ceiling pool reason"
expect_rc "$out" 2 "unreached-ceiling exit"
pass "a weekly window that resets before it can be spent does not red-line the pool"

# An account the gateway says has to log in again is its own signal: named on
# the line, excluded from capacity, and never part of the projection. All three
# spellings of it the gateway can use land in the same place.
for auth_case in 'requiresReauth true' 'tokenStatus "expired"' 'pauseReason "reauth_required"'; do
  auth_key=${auth_case%% *}
  auth_val=${auth_case#* }
  make_pool "$health" "$accounts" 6 11 0
  add_account "$accounts" healthy 5 40 20 100
  add_account_needing_auth "$accounts" locked-out 20 100 "$auth_key" "$auth_val"
  out=$(run_monitor "$quota" "$health" "$accounts")
  expect_field "$out" pool_needs_auth locked-out "$auth_key needs-auth names"
  expect_field "$out" pool_capable healthy "$auth_key needs-auth capable"
  expect_field "$out" pool_tracked healthy,locked-out "$auth_key needs-auth tracked"
  expect_field "$out" pool_exhaustion 100.0h "$auth_key needs-auth projection"
  expect_field "$out" pool_state GREEN "$auth_key needs-auth pool state"
done

# A healthy pool names no account there, and a pool that cannot be read names
# none either rather than inventing one.
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" healthy 5 40 20 100
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_needs_auth none "healthy pool needs-auth"
out=$(FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_AUTH_DIR="$NO_AUTH" \
  FM_FABLE_RUNWAY_QUOTA_JSON="$quota" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$lab/absent-health.json" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$lab/absent-accounts.json" \
  "$MONITOR" 2>/dev/null)
expect_field "$out" pool_needs_auth none "unreadable pool needs-auth"
expect_field "$out" pool_state UNKNOWN "unreadable pool state with needs-auth column"

# Every account locked out is no Fable capacity at all, whatever the gateway
# still counts as routable.
make_pool "$health" "$accounts" 6 11 0
add_account_needing_auth "$accounts" locked-a 20 100 requiresReauth true
add_account_needing_auth "$accounts" locked-b 20 100 requiresReauth true
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_needs_auth locked-a,locked-b "all-locked needs-auth names"
expect_field "$out" pool_state RED "all-locked pool state"
expect_field "$out" pool_reason no_fable_capable_account "all-locked pool reason"
expect_rc "$out" 2 "all-locked exit"
pass "an account that needs a login is named, excluded from capacity, and not projected"

# The two proxies share the same logins, so whichever refreshed a token last
# leaves the other holding a dead one. This is the shape that produced: every
# better-ccflare account reads tokenStatus=expired and routable=0 while
# CLIProxyAPI holds a live grant for all of them and the fleet is served
# normally. The auth inventory is the authority, so this pool is healthy.
authdir="$lab/inventory"
rm -rf "$authdir"
make_pool "$health" "$accounts" 0 5 0
for acct_name in one two three four five; do
  add_account_needing_auth "$accounts" "acct-$acct_name" 20 100 tokenStatus '"expired"'
  make_auth_account "$authdir" "acct-$acct_name" 8 false
done
out=$(run_monitor "$quota" "$health" "$accounts" "$authdir")
expect_field "$out" pool_routable 5/5 "cross-proxy routable"
expect_field "$out" pool_needs_auth none "cross-proxy needs-auth"
expect_field "$out" pool_capable acct-one,acct-two,acct-three,acct-four,acct-five \
  "cross-proxy capable"
expect_field "$out" pool_state GREEN "cross-proxy pool state"
expect_field "$out" pool_reason has_fable_capacity "cross-proxy pool reason"
expect_rc "$out" 0 "cross-proxy exit"

# The inventory holds only two fields of each file, and the account is labelled
# from the file name, so nothing secret in that file can reach the line.
case "$out" in
  *do-not-print*) fail "the monitor must never print an auth file's secrets: $out" ;;
esac
pass "a live CLIProxyAPI grant outranks a stale better-ccflare token status"

# An expired or disabled grant is not capacity. With the other proxy also
# refusing the account, no proxy holds a live grant and the account is named.
rm -rf "$authdir"
make_pool "$health" "$accounts" 0 3 0
add_account_needing_auth "$accounts" live-one 20 100 tokenStatus '"expired"'
add_account_needing_auth "$accounts" gone-expired 20 100 tokenStatus '"expired"'
add_account_needing_auth "$accounts" gone-disabled 20 100 tokenStatus '"expired"'
make_auth_account "$authdir" live-one 8 false
make_auth_account "$authdir" gone-expired -1 false
make_auth_account "$authdir" gone-disabled 8 true
out=$(run_monitor "$quota" "$health" "$accounts" "$authdir")
expect_field "$out" pool_routable 1/3 "expired-grant routable"
expect_field "$out" pool_needs_auth gone-disabled,gone-expired "expired-grant needs-auth"
expect_field "$out" pool_capable live-one "expired-grant capable"
expect_field "$out" pool_state RED "expired-grant pool state"
expect_field "$out" pool_reason routable_at_or_below_1 "expired-grant pool reason"
expect_rc "$out" 2 "expired-grant exit"

# The rule is cross-proxy in both directions: an account the inventory has
# nothing live for is still not a login to perform while better-ccflare holds a
# working one. It is not routable capacity, because the fleet's base URL points
# at the other proxy, but it is not the captain's problem either.
rm -rf "$authdir"
make_pool "$health" "$accounts" 4 4 0
add_account "$accounts" cc-only 5 40 20 100
add_account_needing_auth "$accounts" both-dead 20 100 tokenStatus '"expired"'
make_auth_account "$authdir" both-dead -1 false
out=$(run_monitor "$quota" "$health" "$accounts" "$authdir")
expect_field "$out" pool_needs_auth both-dead "cross-proxy live-elsewhere needs-auth"
expect_field "$out" pool_routable 0/1 "cross-proxy live-elsewhere routable"
pass "needs-auth means no proxy holds a live grant, in either direction"

# An unreadable better-ccflare costs the projection, not the verdict, while the
# inventory still answers. That is the whole point of it being supplementary.
rm -rf "$authdir"
for acct_name in 1 2 3 4 5; do
  make_auth_account "$authdir" "inv-$acct_name" 8 false
done
out=$(run_monitor "$quota" "$lab/absent-health.json" "$lab/absent-accounts.json" "$authdir")
expect_field "$out" pool_state GREEN "inventory-only pool state"
expect_field "$out" pool_routable 5/5 "inventory-only routable"
expect_field "$out" pool_reason routable_only_without_fable_window "inventory-only reason"
expect_field "$out" pool_exhaustion unknown "inventory-only projection"
expect_rc "$out" 0 "inventory-only exit"

# With neither source readable the pool is UNKNOWN, exactly as before.
out=$(run_monitor "$quota" "$lab/absent-health.json" "$lab/absent-accounts.json" "$NO_AUTH")
expect_field "$out" pool_state UNKNOWN "no-source pool state"
expect_field "$out" pool_reason pool_unavailable "no-source pool reason"
pass "an unreadable better-ccflare is not an unreadable pool while the inventory answers"

# A resets_at the clock has already passed is a window whose reset is due, not
# one with negative runway left.
make_pool "$health" "$accounts" 8 8 0
add_account_with_wall "$accounts" stale 5 99 99 -1
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_exhaustion 0.0h "stale-reset projection"
expect_field "$out" pool_state GREEN "stale-reset pool state"
pass "a window whose reset is already due reports no negative runway"

# An account whose name is an empty string is still a named member of the pool,
# so the fail-back label stays available to it.
make_pool "$health" "$accounts" 8 8 0
add_account "$accounts" "" 5 40 20 100
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_capable unnamed "empty-name pool capable"
expect_field "$out" pool_tracked unnamed "empty-name pool tracked"
expect_field "$out" pool_state GREEN "empty-name pool state"
pass "an account with an empty name is reported as unnamed, not as no account"

# An empty pool URL is not a way to switch the pool read off; it takes the
# default, and only an unreadable pool yields UNKNOWN.
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" acct-a 5 40 20 100
out=$(FM_FABLE_RUNWAY_POOL_URL='' FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_AUTH_DIR="$NO_AUTH" \
  FM_FABLE_RUNWAY_QUOTA_JSON="$quota" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$health" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$accounts" \
  "$MONITOR" 2>/dev/null)
expect_field "$out" pool_state GREEN "empty pool url state"
expect_field "$out" pool_reason has_fable_capacity "empty pool url reason"
pass "an empty pool URL falls back to the default rather than disabling the read"

# The pool's ordered routing steady state: one account burns out its week while
# the rest sit untouched at zero. A zero-burn window is readable and maximally
# healthy, so it must keep the pool out of RED. An untouched account's window is
# also the one whose resets_at sits a full week out or further, which is exactly
# where the seven-day back-extrapolation cannot place it - that must not cost it
# its place in the counts.
make_pool "$health" "$accounts" 11 11 0
for acct_name in 1 2 3 4 5; do
  add_account "$accounts" "idle-$acct_name" 0 0 0 100
done
add_account "$accounts" untouched-at-reset 0 0 0 168
add_account "$accounts" untouched-fresh-week 0 0 0 200
add_account "$accounts" active 5 99 99 1
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "ordered-routing pool state"
expect_field "$out" pool_reason has_fable_capacity "ordered-routing pool reason"
expect_field "$out" pool_exhaustion 200.0h "ordered-routing pool projection"
expect_rc "$out" 0 "ordered-routing pool exit"

# The same pool with only the untouched-window accounts, so nothing else can
# carry the counts past the thresholds.
make_pool "$health" "$accounts" 11 11 0
add_account "$accounts" untouched-at-reset 0 0 0 168
add_account "$accounts" active 5 99 99 1
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "week-out untouched pool state"
expect_field "$out" pool_reason has_fable_capacity "week-out untouched pool reason"
expect_field "$out" pool_exhaustion 168.0h "week-out untouched pool projection"
expect_rc "$out" 0 "week-out untouched pool exit"
pass "untouched zero-burn accounts keep a burning pool out of RED"

# One malformed account record costs one name, never the whole pool verdict: a
# pool with no routable account stays RED rather than aborting into UNKNOWN.
make_pool "$health" "$accounts" 0 2 2
add_account "$accounts" acct-a 5 40 20 100
jq -c '.[1] = (.[0] | del(.name))' "$accounts" > "$accounts.tmp" && mv "$accounts.tmp" "$accounts"
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state RED "nameless account pool state"
expect_field "$out" pool_reason routable_at_or_below_1 "nameless account pool reason"
expect_field "$out" overall RED "nameless account overall"
expect_rc "$out" 2 "nameless account exit"
printf '%s\n' "$out" | grep -q 'pool_capable=acct-a,unnamed' \
  || fail "a nameless account must cost one name, not the verdict (got: $out)"
pass "an account record with no readable name does not abort the pool verdict"

# A burst one hour into a freshly opened week is not imminent exhaustion: the
# elapsed portion of the window is floored at six hours before extrapolating.
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" fresh-week 5 40 40 167
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "fresh window state"
expect_field "$out" pool_exhaustion 9.0h "fresh window projection"
expect_rc "$out" 0 "fresh window exit"

# A window whose resets_at says it has not opened yet stays unprojectable.
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" not-started 5 40 40 200
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "unstarted window state"
expect_field "$out" pool_exhaustion unknown "unstarted window projection"
pass "a freshly opened week is floored, and one that has not opened is unprojectable"

# An unreachable pool is UNKNOWN, and the supervisor's own runway still decides.
make_quota "$quota" 60 0.5 none through_reset
out=$(FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_AUTH_DIR="$NO_AUTH" \
  FM_FABLE_RUNWAY_QUOTA_JSON="$quota" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$lab/absent-health.json" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$lab/absent-accounts.json" \
  "$MONITOR" 2>/dev/null)
expect_field "$out" pool_state UNKNOWN "pool unavailable"
expect_field "$out" overall GREEN "overall with unavailable pool"
pass "an unreachable optional pool is UNKNOWN, not RED"

# --- monitor: the per-call clamp --------------------------------------------

# A check the watcher kills prints nothing and records nothing, so it would go
# silently dark and repeat that silence every poll. A hung quota-axi therefore
# has to be cut to the per-call cap even when the operator raised the timeout
# well past the watcher's own bound.
clamplab="$TMP_ROOT/clamp"
mkdir -p "$clamplab/bin"
cat > "$clamplab/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
chmod 0755 "$clamplab/bin/quota-axi"
make_pool "$health" "$accounts" 6 11 0
add_account "$accounts" acct-a 5 40 20 100
clamp_started=$(date +%s)
clamped=$(PATH="$clamplab/bin:$PATH" \
  FM_CHECK_TIMEOUT=30 \
  FM_FABLE_RUNWAY_AUTH_DIR="$NO_AUTH" \
  FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$health" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$accounts" \
  "$MONITOR" 2>/dev/null)
clamp_elapsed=$(( $(date +%s) - clamp_started ))
[ "$clamp_elapsed" -lt 20 ] \
  || fail "a hung quota-axi must be cut to the per-call cap (took ${clamp_elapsed}s)"
expect_field "$clamped" fable_state RED "clamped fable state"
expect_field "$clamped" fable_reason quota_axi_version_unreadable_or_below_floor "clamped fable reason"
pass "a hung quota-axi is cut to the per-call cap, well inside FM_CHECK_TIMEOUT"

# --- check: wake contract ----------------------------------------------------

checklab="$TMP_ROOT/check"
mkdir -p "$checklab/state"
cquota="$checklab/quota.json"
chealth="$checklab/health.json"
caccounts="$checklab/accounts.json"

# The check's helper is the one part of this that leaves the process, so every
# poll below runs with orca and osascript shadowed on PATH. No case can ring a
# real terminal or post a real desktop banner, and the fakes double as the
# record of what the helper actually issued.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
for fake in orca osascript; do
  cat > "$FAKEBIN/$fake" <<SH
#!/usr/bin/env bash
[ -n "\${FM_FABLE_FAKE_LOG:-}" ] || exit 0
printf '%s\\n' "\$*" >> "\$FM_FABLE_FAKE_LOG/$fake.log"
SH
  chmod 0755 "$FAKEBIN/$fake"
done

# run_check_in <lab-dir> <now>: a poll against that lab's own state and fixtures.
run_check_in() {
  PATH="$FAKEBIN:$PATH" \
    FM_FABLE_RUNWAY_AUTH_DIR="${3:-$NO_AUTH}" \
    FM_HOME="$1" \
    FM_FABLE_FAKE_LOG="$1" \
    FM_STATE_OVERRIDE="$1/state" \
    FM_FABLE_RUNWAY_NOW="$2" \
    FM_FABLE_RUNWAY_QUOTA_JSON="$1/quota.json" \
    FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$1/health.json" \
    FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$1/accounts.json" \
    "$CHECK" check 2>/dev/null
}

# notes_in <lab-dir>: how many durable handoff notes that lab's state holds.
notes_in() {
  set -- "$1"/state/fable-runway-handoff-*.md
  [ -e "$1" ] && printf '%s\n' "$#" || printf '0\n'
}

run_check() { run_check_in "$checklab" "$1"; }

make_pool "$chealth" "$caccounts" 6 11 0
add_account "$caccounts" acct-a 5 40 20 100
make_quota "$cquota" 60 0.5 none through_reset
first=$(run_check "$NOW")
[ -n "$first" ] || fail "check first poll must print the observed state"
expect_field "$first" overall GREEN "check first poll overall"
case "$first" in
  *'capacity back'*) fail "a first poll must not claim a recovery: $first" ;;
esac

second=$(run_check "$((NOW + 300))")
[ -z "$second" ] || fail "check must stay silent on an unchanged poll (got: $second)"
pass "the check prints once and then stays silent while the state is unchanged"

# A yellow transition wakes; the next unchanged poll is silent again.
make_quota "$cquota" 20 0.5 none through_reset
yellow=$(run_check "$((NOW + 600))")
expect_field "$yellow" overall YELLOW "check yellow transition"
silent=$(run_check "$((NOW + 900))")
[ -z "$silent" ] || fail "check must stay silent on an unchanged yellow poll (got: $silent)"
pass "a state change wakes and an unchanged yellow poll stays silent"

# The RED repeat is throttled, then re-fires an hour on. The clock moves, not a
# knob: there is no way to ask for a sustained RED to stay quiet.
make_quota "$cquota" 5 0.5 none through_reset
red=$(run_check "$((NOW + 1200))")
expect_field "$red" overall RED "check red transition"
quiet=$(run_check "$((NOW + 1500))")
[ -z "$quiet" ] || fail "a persistent RED must not repeat within the throttle (got: $quiet)"
still_quiet=$(run_check "$((NOW + 4700))")
[ -z "$still_quiet" ] \
  || fail "a persistent RED must not repeat a second short of the hour (got: $still_quiet)"
repeat=$(run_check "$((NOW + 4800))")
expect_field "$repeat" overall RED "check red repeat"
pass "a persistent RED repeats only once the fixed re-alert hour has passed"

# Fail-back: an account the pool tracked but could not use is usable again, and
# the check names it.
make_quota "$cquota" 60 0.5 none through_reset
make_pool "$chealth" "$caccounts" 1 11 9
add_account "$caccounts" revived-account 5 100 100 200
run_check "$((NOW + 3000))" >/dev/null
make_pool "$chealth" "$caccounts" 6 11 0
add_account "$caccounts" revived-account 5 40 10 200
recovery=$(run_check "$((NOW + 3300))")
printf '%s\n' "$recovery" | grep -q 'capacity back account=revived-account' \
  || fail "fail-back must name the recovered account (got: $recovery)"
expect_field "$recovery" pool_state GREEN "fail-back pool state"
pass "the fail-back line names the account that regained Fable capacity"

# A regain that leaves the pool thin carries the same label; `pool_state=` on
# the same line is what says how far the pool recovered.
backlab="$TMP_ROOT/back"
mkdir -p "$backlab/state"
make_quota "$backlab/quota.json" 60 0.5 none through_reset
make_pool "$backlab/health.json" "$backlab/accounts.json" 1 11 9
add_account "$backlab/accounts.json" thin-account 5 100 100 200
run_check_in "$backlab" "$NOW" >/dev/null
make_pool "$backlab/health.json" "$backlab/accounts.json" 3 11 7
add_account "$backlab/accounts.json" thin-account 5 40 10 200
back=$(run_check_in "$backlab" "$((NOW + 300))")
expect_field "$back" pool_state YELLOW "capacity-back pool state"
printf '%s\n' "$back" | grep -q 'capacity back account=thin-account' \
  || fail "a regain that leaves the pool thin must name the account (got: $back)"
pass "a regain on a still-thin pool carries the same label and a YELLOW pool_state"

# A gateway restart between polls makes the pool unreadable, and an unreadable
# pool observed no membership at all. The window that resets during the outage
# must still be named by the wake that follows it.
gaplab="$TMP_ROOT/gap"
mkdir -p "$gaplab/state"
make_quota "$gaplab/quota.json" 60 0.5 none through_reset
make_pool "$gaplab/health.json" "$gaplab/accounts.json" 6 11 5
add_account "$gaplab/accounts.json" outage-account 5 100 100 100
gap_first=$(run_check_in "$gaplab" "$NOW")
expect_field "$gap_first" pool_state RED "outage first poll state"
expect_field "$gap_first" pool_reason no_fable_capable_account "outage first poll reason"
expect_field "$gap_first" pool_tracked outage-account "outage first poll tracked"
# The gateway restarts, so both fetches fail and the pool reads UNKNOWN.
rm -f "$gaplab/health.json" "$gaplab/accounts.json"
gap_outage=$(run_check_in "$gaplab" "$((NOW + 300))")
expect_field "$gap_outage" pool_state UNKNOWN "outage poll state"
expect_field "$gap_outage" pool_reason pool_unavailable "outage poll reason"
# The gateway is back and the account's window reset during the restart.
make_pool "$gaplab/health.json" "$gaplab/accounts.json" 6 11 0
add_account "$gaplab/accounts.json" outage-account 5 0 0 100
gap_wake=$(run_check_in "$gaplab" "$((NOW + 600))")
expect_field "$gap_wake" pool_state GREEN "outage recovery pool state"
printf '%s\n' "$gap_wake" | grep -q 'capacity back account=outage-account' \
  || fail "a regain across an unreadable pool must still be named (got: $gap_wake)"
pass "an unreadable pool does not consume a pending regain"

# A record stamped with another schema is no record at all, so the next poll is
# a first poll: it prints, and it claims no recovery it cannot have observed.
schemalab="$TMP_ROOT/schema"
mkdir -p "$schemalab/state"
make_quota "$schemalab/quota.json" 60 0.5 none through_reset
make_pool "$schemalab/health.json" "$schemalab/accounts.json" 6 11 0
add_account "$schemalab/accounts.json" schema-account 5 40 20 100
run_check_in "$schemalab" "$NOW" >/dev/null
silent_repeat=$(run_check_in "$schemalab" "$((NOW + 300))")
[ -z "$silent_repeat" ] \
  || fail "the unchanged poll before the schema swap must be silent (got: $silent_repeat)"
# The foreign record claims exactly the states this poll observes, so reading it
# would silence the poll; ignoring it makes the poll a first poll, which prints.
printf 'schema=fm-fable-runway-check-v0\noverall=GREEN\nfable_state=GREEN\npool_state=GREEN\ncapable=schema-account\nred_at=0\n' \
  > "$schemalab/state/.fable-runway"
foreign=$(run_check_in "$schemalab" "$((NOW + 600))")
[ -n "$foreign" ] || fail "a record from another schema must be ignored, so the poll prints"
expect_field "$foreign" pool_state GREEN "foreign-schema poll state"
case "$foreign" in
  *'capacity back'*) fail "a poll with no usable record must not claim a recovery: $foreign" ;;
esac
pass "a record stamped with another schema is treated as no record at all"

# The gateway's routable count lags a per-account window reset by a poll, so the
# regain itself lands on a silent poll. The next wake that prints must still
# name the account, because that name is what the runbook's fail-back step
# confirms.
lagslab="$TMP_ROOT/lag"
mkdir -p "$lagslab/state"
make_quota "$lagslab/quota.json" 60 0.5 none through_reset
make_pool "$lagslab/health.json" "$lagslab/accounts.json" 1 11 9
add_account "$lagslab/accounts.json" lagging-account 5 100 100 100
lag_first=$(run_check_in "$lagslab" "$NOW")
expect_field "$lag_first" pool_state RED "lagged regain first poll"
# The window resets while the gateway still reports one routable account.
make_pool "$lagslab/health.json" "$lagslab/accounts.json" 1 11 9
add_account "$lagslab/accounts.json" lagging-account 5 0 0 100
lag_silent=$(run_check_in "$lagslab" "$((NOW + 300))")
[ -z "$lag_silent" ] \
  || fail "a regain with the pool still RED for the same reason must stay silent (got: $lag_silent)"
# The routable count catches up and the pool goes GREEN.
make_pool "$lagslab/health.json" "$lagslab/accounts.json" 6 11 0
add_account "$lagslab/accounts.json" lagging-account 5 0 0 100
lag_wake=$(run_check_in "$lagslab" "$((NOW + 600))")
expect_field "$lag_wake" pool_state GREEN "lagged regain wake pool state"
printf '%s\n' "$lag_wake" | grep -q 'capacity back account=lagging-account' \
  || fail "a regain consumed by a silent poll must still be named (got: $lag_wake)"
pass "a regain that lands on a silent poll is named by the next wake that prints"

# An account the captain adds is new, not recovered, even when its arrival is
# what lifts the pool out of YELLOW.
addlab="$TMP_ROOT/added"
mkdir -p "$addlab/state"
make_quota "$addlab/quota.json" 60 0.5 none through_reset
make_pool "$addlab/health.json" "$addlab/accounts.json" 3 11 0
add_account "$addlab/accounts.json" incumbent 5 40 20 100
run_check_in "$addlab" "$NOW" >/dev/null
make_pool "$addlab/health.json" "$addlab/accounts.json" 6 11 0
add_account "$addlab/accounts.json" incumbent 5 40 20 100
add_account "$addlab/accounts.json" newcomer 5 40 20 100
added=$(run_check_in "$addlab" "$((NOW + 300))")
expect_field "$added" pool_state GREEN "added account pool state"
case "$added" in
  *'capacity back'*) fail "a newly added account is not a recovery: $added" ;;
esac
pass "an account added to the pool is never labelled a recovery"

# Pool membership churns on its own, and none of it is news while both runway
# states hold: an account leaving the capable set on a GREEN pool stays silent.
churnlab="$TMP_ROOT/churn"
mkdir -p "$churnlab/state"
make_quota "$churnlab/quota.json" 60 0.5 none through_reset
make_pool "$churnlab/health.json" "$churnlab/accounts.json" 6 11 0
add_account "$churnlab/accounts.json" keeps 5 40 20 100
add_account "$churnlab/accounts.json" leaves 5 40 20 100
churn_first=$(run_check_in "$churnlab" "$NOW")
expect_field "$churn_first" pool_state GREEN "churn first poll"
make_pool "$churnlab/health.json" "$churnlab/accounts.json" 6 11 1
add_account "$churnlab/accounts.json" keeps 5 40 20 100
add_account "$churnlab/accounts.json" leaves 5 100 100 100
churn_quiet=$(run_check_in "$churnlab" "$((NOW + 300))")
[ -z "$churn_quiet" ] \
  || fail "losing a capable account on a GREEN pool must not wake (got: $churn_quiet)"
pass "pool membership churn with both runway states unchanged stays silent"

# An account that starts wanting a login again wakes firstmate on its own, even
# though neither runway state moved: the pool keeps a capable member, so without
# that rule this is indistinguishable from ordinary membership churn. The same
# transition is notified to the captain, because re-authenticating is the one
# remedy a model turn cannot perform.
authlab="$TMP_ROOT/auth"
mkdir -p "$authlab/state"
make_quota "$authlab/quota.json" 60 0.5 none through_reset
make_pool "$authlab/health.json" "$authlab/accounts.json" 6 11 0
add_account "$authlab/accounts.json" steady 5 40 20 100
add_account "$authlab/accounts.json" wobbler 5 40 20 100
auth_first=$(run_check_in "$authlab" "$NOW")
expect_field "$auth_first" pool_needs_auth none "needs-auth first poll"
[ ! -s "$authlab/osascript.log" ] \
  || fail "a healthy first poll must not notify ($(cat "$authlab/osascript.log"))"
make_pool "$authlab/health.json" "$authlab/accounts.json" 6 11 0
add_account "$authlab/accounts.json" steady 5 40 20 100
add_account_needing_auth "$authlab/accounts.json" wobbler 20 100 requiresReauth true
auth_wake=$(run_check_in "$authlab" "$((NOW + 300))")
[ -n "$auth_wake" ] || fail "an account entering needs-auth must wake firstmate"
expect_field "$auth_wake" pool_needs_auth wobbler "needs-auth wake names"
expect_field "$auth_wake" pool_state GREEN "needs-auth wake pool state"
grep -q 'wobbler' "$authlab/osascript.log" 2>/dev/null \
  || fail "the needs-auth transition must notify, naming the account"
auth_quiet=$(run_check_in "$authlab" "$((NOW + 600))")
[ -z "$auth_quiet" ] \
  || fail "an account that already needs a login must not wake again (got: $auth_quiet)"
[ "$(wc -l < "$authlab/osascript.log")" -eq 1 ] \
  || fail "the notification must not repeat every poll"
pass "an account newly needing a login wakes once and notifies the captain"

# The zero-token failover action: overall RED with nothing left to serve Fable
# from has to move the seat without waiting for a model turn, so the check hands
# the episode to its plain-bash helper.
hlab="$TMP_ROOT/handoff"
mkdir -p "$hlab/state" "$hlab/config"
printf 'FM_FABLE_RUNWAY_GROK_TERMINAL=grok-seat\n' > "$hlab/config/fable-runway.env"
make_quota "$hlab/quota.json" 60 0.5 none through_reset
make_pool "$hlab/health.json" "$hlab/accounts.json" 5 11 6
add_account "$hlab/accounts.json" spent 5 100 100 200
hand=$(run_check_in "$hlab" "$NOW")
expect_field "$hand" overall RED "handoff poll overall"
expect_field "$hand" pool_capable none "handoff poll capable"
[ "$(notes_in "$hlab")" = 1 ] || fail "a RED episode must write one durable handoff note"
note=$(printf '%s\n' "$hlab"/state/fable-runway-handoff-*.md)
grep -q 'docs/runbooks/supervisor-failover-grok.md' "$note" \
  || fail "the handoff note must point at the runbook"
grep -q 'no_fable_capable_account' "$note" \
  || fail "the handoff note must carry the reason token"
grep -q 'fable-runway: overall=RED' "$note" \
  || fail "the handoff note must carry the monitor line"
grep -q 'terminal send --terminal grok-seat' "$hlab/orca.log" 2>/dev/null \
  || fail "the doorbell must go to the configured terminal ($(cat "$hlab/orca.log" 2>/dev/null))"
grep -q -- "--enter" "$hlab/orca.log" || fail "the doorbell must be submitted"
grep -qF "$note" "$hlab/orca.log" || fail "the doorbell must carry the note path"
grep -qF "$note" "$hlab/osascript.log" 2>/dev/null \
  || fail "the notification must name the note path"

# The same RED an hour on re-alerts, and the episode still fires only once.
run_check_in "$hlab" "$((NOW + 4800))" >/dev/null
[ "$(notes_in "$hlab")" = 1 ] || fail "a sustained RED episode must not write a second note"
[ "$(wc -l < "$hlab/orca.log")" -eq 1 ] || fail "the doorbell must ring once per episode"

# Capacity comes back, so the episode closes; the next RED is a new one.
make_pool "$hlab/health.json" "$hlab/accounts.json" 6 11 0
add_account "$hlab/accounts.json" spent 5 40 20 200
run_check_in "$hlab" "$((NOW + 5100))" >/dev/null
[ ! -e "$hlab/state/.fable-runway-handoff" ] \
  || fail "recovering must close the failover episode"
make_pool "$hlab/health.json" "$hlab/accounts.json" 5 11 6
add_account "$hlab/accounts.json" spent 5 100 100 200
run_check_in "$hlab" "$((NOW + 5400))" >/dev/null
[ "$(notes_in "$hlab")" = 2 ] || fail "a RED after a recovery must open a new episode"
pass "a RED with no Fable capacity left notes, rings and notifies once per episode"

# A home with no terminal handle configured skips only the doorbell: the note
# and the notification are what the captain reads, and neither may depend on
# orca being installed or configured.
nolab="$TMP_ROOT/nohandle"
mkdir -p "$nolab/state"
make_quota "$nolab/quota.json" 60 0.5 none through_reset
make_pool "$nolab/health.json" "$nolab/accounts.json" 5 11 6
add_account "$nolab/accounts.json" spent 5 100 100 200
nohandle=$(run_check_in "$nolab" "$NOW")
expect_field "$nohandle" overall RED "unconfigured handle overall"
[ "$(notes_in "$nolab")" = 1 ] || fail "an unconfigured handle must not cost the note"
[ ! -e "$nolab/orca.log" ] || fail "an unconfigured handle must not ring anything"
[ -s "$nolab/osascript.log" ] || fail "an unconfigured handle must not cost the notification"
pass "an unconfigured Grok terminal skips the doorbell and nothing else"

# A gateway blip is not an empty pool. `pool_capable=none` is what an unread
# pool prints too, so a check that cannot tell them apart rings the Grok seat
# every time the gateway restarts - on a home whose pool was healthy throughout.
bliplab="$TMP_ROOT/blip"
mkdir -p "$bliplab/state" "$bliplab/config"
printf 'FM_FABLE_RUNWAY_GROK_TERMINAL=grok-seat\n' > "$bliplab/config/fable-runway.env"
printf 'not a quota document\n' > "$bliplab/quota.json"
make_pool "$bliplab/health.json" "$bliplab/accounts.json" 6 11 0
add_account "$bliplab/accounts.json" healthy 5 40 20 100
blip_first=$(run_check_in "$bliplab" "$NOW")
expect_field "$blip_first" overall RED "blip first poll overall"
expect_field "$blip_first" fable_state RED "blip first poll fable"
expect_field "$blip_first" pool_state GREEN "blip first poll pool"
[ "$(notes_in "$bliplab")" = 0 ] \
  || fail "a RED supervisor runway on a healthy pool must not open an episode"
mv "$bliplab/health.json" "$bliplab/health.away"
run_check_in "$bliplab" "$((NOW + 300))" >/dev/null
mv "$bliplab/health.away" "$bliplab/health.json"
run_check_in "$bliplab" "$((NOW + 600))" >/dev/null
[ "$(notes_in "$bliplab")" = 0 ] \
  || fail "a single unreadable poll must not open a handoff episode"
[ ! -e "$bliplab/orca.log" ] || fail "a gateway blip must not ring the Grok seat"
pass "one unreadable pool poll is could-not-determine, not an empty pool"

# A pool that stays unreachable while the supervisor's own runway is RED leaves
# no way to switch at all, so it does open an episode - saying that, and never
# that the pool is empty.
mv "$bliplab/health.json" "$bliplab/health.away"
run_check_in "$bliplab" "$((NOW + 900))" >/dev/null
[ "$(notes_in "$bliplab")" = 0 ] \
  || fail "the first poll of an outage must not open an episode on its own"
run_check_in "$bliplab" "$((NOW + 1500))" >/dev/null
[ "$(notes_in "$bliplab")" = 1 ] \
  || fail "a sustained unreadable pool with a RED runway must open one episode"
outage_note=$(printf '%s\n' "$bliplab"/state/fable-runway-handoff-*.md)
grep -q 'Pool unreachable for 10 minutes' "$outage_note" \
  || fail "the outage note must say how long the pool has been unreachable ($(cat "$outage_note"))"
grep -q 'supervisor runway unmeasurable' "$outage_note" \
  || fail "the outage note must say the runway is unmeasurable"
grep -q 'No Fable-capable account left' "$outage_note" \
  && fail "an unreadable pool must never be reported as an empty pool"
grep -q 'Pool unreachable for 10 minutes' "$bliplab/orca.log" \
  || fail "the outage doorbell must carry the unreachable wording"
grep -q 'Pool unreachable' "$bliplab/osascript.log" \
  || fail "the outage banner must carry the unreachable wording"
run_check_in "$bliplab" "$((NOW + 1800))" >/dev/null
[ "$(notes_in "$bliplab")" = 1 ] || fail "a continuing outage must not re-open the episode"
pass "a sustained unreachable pool opens one episode that never claims the pool is empty"

# The check always runs its sibling monitor: the watcher validates the shim's
# bytes before dispatch, so no environment variable may redirect it elsewhere.
seamlab="$TMP_ROOT/seam"
mkdir -p "$seamlab/state"
cat > "$seamlab/impostor.sh" <<'SH'
#!/usr/bin/env bash
printf 'fable-runway: overall=RED fable_state=RED pool_state=RED fable_remaining=0%% fable_burn=9x fable_exhaustion=unknown(unknown) pool_routable=0/0 pool_exhausted=0 pool_capable=none pool_tracked=none pool_exhaustion=unknown fable_reason=impostor pool_reason=impostor\n'
SH
chmod 0755 "$seamlab/impostor.sh"
seam=$(PATH="$FAKEBIN:$PATH" \
  FM_FABLE_RUNWAY_AUTH_DIR="$NO_AUTH" \
  FM_HOME="$seamlab" \
  FM_FABLE_FAKE_LOG="$seamlab" \
  FM_STATE_OVERRIDE="$seamlab/state" \
  FM_FABLE_RUNWAY_MONITOR="$seamlab/impostor.sh" \
  FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_QUOTA_JSON="$cquota" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$chealth" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$caccounts" \
  "$CHECK" check 2>/dev/null)
[ -n "$seam" ] || fail "the check's first poll must print the monitor's line"
case "$seam" in
  *impostor*) fail "the check must not take its monitor from the environment: $seam" ;;
esac
pass "the check runs its sibling monitor, not one named by the environment"

# --- check: arm and disarm ---------------------------------------------------

armlab="$TMP_ROOT/arm"
mkdir -p "$armlab/state" "$armlab/home/state"
arm_out=$(FM_HOME="$armlab/home" FM_STATE_OVERRIDE="$armlab/state" "$CHECK" arm 2>&1)
[ -f "$armlab/state/fable-runway.check.sh" ] || fail "arm must write the check shim ($arm_out)"
[ -f "$armlab/state/fable-runway.check-trust" ] || fail "arm must bind the shim ($arm_out)"
bash -n "$armlab/state/fable-runway.check.sh" || fail "the shim must be valid bash"
disarm_out=$(FM_HOME="$armlab/home" FM_STATE_OVERRIDE="$armlab/state" "$CHECK" disarm 2>&1)
[ ! -e "$armlab/state/fable-runway.check.sh" ] || fail "disarm must remove the shim ($disarm_out)"
[ ! -e "$armlab/state/fable-runway.check-trust" ] || fail "disarm must remove the trust binding"
: > "$armlab/state/.fable-runway-handoff"
FM_HOME="$armlab/home" FM_STATE_OVERRIDE="$armlab/state" "$CHECK" disarm >/dev/null 2>&1
[ ! -e "$armlab/state/.fable-runway-handoff" ] \
  || fail "disarm must also retire the failover episode marker"
pass "arm writes and binds the shim; disarm removes it"

printf 'fm-fable-runway tests passed\n'
