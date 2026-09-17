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
# The check cases pin the wake contract: one line on a state change, silence on
# an unchanged poll, a throttled RED repeat, and the fail-back line that names
# the account which regained Fable capacity.
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

# run_monitor <quota> <health> <accounts>: print the line followed by rc=<n>
run_monitor() {
  local quota=$1 health=$2 accounts=$3 out rc
  out=$(FM_FABLE_RUNWAY_NOW="$NOW" \
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

# An unreachable pool is UNKNOWN, and the supervisor's own runway still decides.
make_quota "$quota" 60 0.5 none through_reset
out=$(FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_QUOTA_JSON="$quota" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$lab/absent-health.json" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$lab/absent-accounts.json" \
  "$MONITOR" 2>/dev/null)
expect_field "$out" pool_state UNKNOWN "pool unavailable"
expect_field "$out" overall GREEN "overall with unavailable pool"
pass "an unreachable optional pool is UNKNOWN, not RED"

# --- check: wake contract ----------------------------------------------------

checklab="$TMP_ROOT/check"
mkdir -p "$checklab/state"
cquota="$checklab/quota.json"
chealth="$checklab/health.json"
caccounts="$checklab/accounts.json"

run_check() {
  FM_STATE_OVERRIDE="$checklab/state" \
    FM_FABLE_RUNWAY_NOW="$1" \
    FM_FABLE_RUNWAY_QUOTA_JSON="$cquota" \
    FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$chealth" \
    FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$caccounts" \
    "$CHECK" check 2>/dev/null
}

make_pool "$chealth" "$caccounts" 6 11 0
add_account "$caccounts" acct-a 5 40 20 100
make_quota "$cquota" 60 0.5 none through_reset
first=$(run_check "$NOW")
[ -n "$first" ] || fail "check first poll must print the observed state"
expect_field "$first" overall GREEN "check first poll overall"
case "$first" in
  *'GREEN again'*|*'capacity back'*) fail "a first poll must not claim a recovery: $first" ;;
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

# The RED repeat is throttled, then re-fires after the realert window.
make_quota "$cquota" 5 0.5 none through_reset
red=$(run_check "$((NOW + 1200))")
expect_field "$red" overall RED "check red transition"
quiet=$(run_check "$((NOW + 1500))")
[ -z "$quiet" ] || fail "a persistent RED must not repeat within the throttle (got: $quiet)"
FM_FABLE_RUNWAY_REALERT_SECS=60
export FM_FABLE_RUNWAY_REALERT_SECS
repeat=$(run_check "$((NOW + 2000))")
unset FM_FABLE_RUNWAY_REALERT_SECS
expect_field "$repeat" overall RED "check red repeat"
pass "a persistent RED repeats only after the realert window"

# Fail-back: the pool regains a Fable-capable account and the check names it.
make_quota "$cquota" 60 0.5 none through_reset
make_pool "$chealth" "$caccounts" 1 11 9
add_account "$caccounts" spent 5 100 100 200
run_check "$((NOW + 3000))" >/dev/null
make_pool "$chealth" "$caccounts" 6 11 0
add_account "$caccounts" revived-account 5 40 10 200
recovery=$(run_check "$((NOW + 3300))")
printf '%s\n' "$recovery" | grep -q 'GREEN again account=revived-account' \
  || fail "fail-back must name the recovered account (got: $recovery)"
expect_field "$recovery" pool_state GREEN "fail-back pool state"
pass "the fail-back line names the account that regained Fable capacity"

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
pass "arm writes and binds the shim; disarm removes it"

printf 'fm-fable-runway tests passed\n'
