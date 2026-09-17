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
# only for an account that really came back, never for one merely added.
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
add_account "$accounts" scoped-hot 5 99 99 1
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
expect_field "$out" pool_exhaustion 272.0h "mixed pool projection"
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

# The pool's ordered routing steady state: one account burns out its week while
# the rest sit untouched at zero. A zero-burn window is readable and maximally
# healthy, so it must keep the pool out of RED.
make_pool "$health" "$accounts" 11 11 0
for acct_name in 1 2 3 4 5 6 7 8 9 10; do
  add_account "$accounts" "idle-$acct_name" 0 0 0 100
done
add_account "$accounts" active 5 99 99 1
out=$(run_monitor "$quota" "$health" "$accounts")
expect_field "$out" pool_state GREEN "ordered-routing pool state"
expect_field "$out" pool_reason has_fable_capacity "ordered-routing pool reason"
expect_field "$out" pool_exhaustion 168.0h "ordered-routing pool projection"
expect_rc "$out" 0 "ordered-routing pool exit"
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
  FM_FABLE_RUNWAY_QUOTA_TIMEOUT=60 \
  FM_FABLE_RUNWAY_NOW="$NOW" \
  FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$health" \
  FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$accounts" \
  "$MONITOR" 2>/dev/null)
clamp_elapsed=$(( $(date +%s) - clamp_started ))
[ "$clamp_elapsed" -lt 20 ] \
  || fail "a hung quota-axi must be cut to the per-call cap (took ${clamp_elapsed}s)"
expect_field "$clamped" fable_state RED "clamped fable state"
expect_field "$clamped" fable_reason quota_axi_below_compatibility_floor "clamped fable reason"
pass "a hung quota-axi is cut to the per-call cap, well inside FM_CHECK_TIMEOUT"

# --- check: wake contract ----------------------------------------------------

checklab="$TMP_ROOT/check"
mkdir -p "$checklab/state"
cquota="$checklab/quota.json"
chealth="$checklab/health.json"
caccounts="$checklab/accounts.json"

# run_check_in <lab-dir> <now>: a poll against that lab's own state and fixtures.
run_check_in() {
  FM_STATE_OVERRIDE="$1/state" \
    FM_FABLE_RUNWAY_NOW="$2" \
    FM_FABLE_RUNWAY_QUOTA_JSON="$1/quota.json" \
    FM_FABLE_RUNWAY_POOL_HEALTH_JSON="$1/health.json" \
    FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON="$1/accounts.json" \
    "$CHECK" check 2>/dev/null
}

run_check() { run_check_in "$checklab" "$1"; }

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

# Fail-back: an account the pool tracked but could not use is usable again, and
# the check names it.
make_quota "$cquota" 60 0.5 none through_reset
make_pool "$chealth" "$caccounts" 1 11 9
add_account "$caccounts" revived-account 5 100 100 200
run_check "$((NOW + 3000))" >/dev/null
make_pool "$chealth" "$caccounts" 6 11 0
add_account "$caccounts" revived-account 5 40 10 200
recovery=$(run_check "$((NOW + 3300))")
printf '%s\n' "$recovery" | grep -q 'GREEN again account=revived-account' \
  || fail "fail-back must name the recovered account (got: $recovery)"
expect_field "$recovery" pool_state GREEN "fail-back pool state"
pass "the fail-back line names the account that regained Fable capacity"

# The same regain on a pool that is still thin reads `capacity back`.
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
  || fail "a regain that leaves the pool thin must read 'capacity back' (got: $back)"
pass "a regain on a still-thin pool is labelled 'capacity back'"

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
printf '%s\n' "$lag_wake" | grep -q 'GREEN again account=lagging-account' \
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
  *'GREEN again'*|*'capacity back'*) fail "a newly added account is not a recovery: $added" ;;
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

# The check always runs its sibling monitor: the watcher validates the shim's
# bytes before dispatch, so no environment variable may redirect it elsewhere.
seamlab="$TMP_ROOT/seam"
mkdir -p "$seamlab/state"
cat > "$seamlab/impostor.sh" <<'SH'
#!/usr/bin/env bash
printf 'fable-runway: overall=RED fable_state=RED pool_state=RED fable_remaining=0%% fable_burn=9x fable_exhaustion=unknown(unknown) pool_routable=0/0 pool_exhausted=0 pool_capable=none pool_tracked=none pool_exhaustion=unknown fable_reason=impostor pool_reason=impostor\n'
SH
chmod 0755 "$seamlab/impostor.sh"
seam=$(FM_STATE_OVERRIDE="$seamlab/state" \
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
pass "arm writes and binds the shim; disarm removes it"

printf 'fm-fable-runway tests passed\n'
