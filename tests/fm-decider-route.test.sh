#!/usr/bin/env bash
# tests/fm-decider-route.test.sh - the Decider seat's routing contract.
#
# bob-architecture.md section 2 item 6 / section 8 row 5: a worker's open
# needs-decision key that matches one of the captain's standing orders is
# delivered to the persistent Decider seat instead of waiting for the
# supervisor's turn, and only class (a) - money, a legal signature, the
# captain's own logins or clicks, anything irreversible - stays with the captain.
# These cases pin, over the real executables and a stubbed tmux:
#   1. The classifier's two directions: every standing order is recognized, and
#      money, legal, credential, and irreversible decisions are class (a) even
#      when their note also reads like a standing order.
#   2. A sweep routes exactly the standing-order decisions, once per decision,
#      and never wakes firstmate for the successes.
#   3. The routing ledger records the episode, so a second sweep asks nothing
#      again and a key that closes and reopens gets a fresh ruling clock.
#   4. `answer` closes the decision through fm-send --resolve-key and records the
#      ruling; the same command refuses a class (a) decision outright.
#   5. A seat that cannot be reached leaves the decision unasked so the next
#      sweep retries, rather than losing the decision silently.
#   6. A decision that outlives the ruling window surfaces once, with the wake
#      line naming it, and never again for that episode.
#   7. With no seat configured nothing is routed; an armed check with no seat is
#      reported as the routing outage it is.
#   8. arm writes and binds the check shim, and disarm retires it while keeping
#      the routing ledger the measurement reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-decider-route.sh"

TMP_ROOT=$(fm_test_tmproot fm-decider-route)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: fm-send reaches a clean verdict for the inbox plane, so a routed
# decision is one durable record plus a doorbell line. FM_FAKE_TMUX_FAIL=1 makes
# the composer unwritable, which is how a test simulates an unreachable seat.
write_tmux_stub() {  # <fakebin>
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"; fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

setup_home() {  # <name> -> echoes the case dir holding home/ and fakebin/
  local name=$1 dir fb
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config"
  fb=$(fm_fakebin "$dir")
  write_tmux_stub "$fb"
  fm_fake_exit0 "$fb" sleep
  printf 'decider\n' > "$dir/home/config/decider-task"
  fm_write_meta "$dir/home/state/decider.meta" \
    "window=sess:fm-decider" "kind=ship" "harness=claude"
  fm_write_meta "$dir/home/state/t1.meta" \
    "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf '%s' "$dir"
}

# Run a firstmate command against one case home. The home is deliberately not a
# git checkout, so the worktree-tangle guard stays silent.
run_route() {  # <dir> [env...] -- <args...>
  local dir=$1
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" \
    FM_HOME="$dir/home" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SEND_SETTLE=0 \
    FM_SEND_LOG="$dir/send.log" \
    ${envs[@]+"${envs[@]}"} \
    "$ROUTE" "$@"
}

classify() {  # <key> <note>
  bash -c '. "$1"; shift; fm_decider_classify "$1" "$2"' _ \
    "$ROOT/bin/fm-decider-lib.sh" "$1" "$2"
}

inbox_count() {  # <dir>
  local dir=$1
  set -- "$dir"/home/state/decider.inbox/*.msg
  [ -e "$1" ] || { printf '0'; return 0; }
  printf '%s' "$#"
}

# --- 1. the classifier ------------------------------------------------------

test_classifier_standing_orders() {
  local key note want got
  while IFS='|' read -r key note want; do
    [ -n "$key" ] || continue
    got=$(classify "$key" "$note")
    [ "$got" = "$want" ] || fail "classify '$key' / '$note' => '$got', wanted '$want'"
  done <<'CASES'
ddl-nullable|add a nullable column to the events table|additive-ddl
ddl-index|create a concurrent index on projects id|additive-ddl
copy-email|sentry email wording needs the fable approved line|copy-fable-delegated
hide-flag|hide the new panel behind a feature flag|reversible-hide
v4-decide|flip user-safe v4 on for everyone|user-safe-v4-flip
pr-merge|merge the approved PR on a green go|merge-on-go
refund-no-figure|issue a refund for the duplicate charge without naming an amount|captain
refund-small-money|issue a $40 refund for the duplicate charge|refund-under-150
CASES
  pass "decider route: every standing-order class is recognized"
}

test_classifier_class_a() {
  local key note want got
  while IFS='|' read -r key note want; do
    [ -n "$key" ] || continue
    got=$(classify "$key" "$note")
    [ "$got" = "$want" ] || fail "classify '$key' / '$note' => '$got', wanted '$want'"
  done <<'CASES'
refund-none|issue a refund for the duplicate charge|captain
refund-big|refund the customer $400|captain
price-change|raise the enterprise tier price by five percent|captain
ddl-price|add a nullable column and pay the vendor|captain
sign-dpa|sign the DPA with the new vendor|captain
rotate-key|rotate the production API key|captain
console-click|sign in to the vendor console and click approve|captain
drop-prod|delete the production table after the migration|captain
merge-contract|merge the enterprise contract while legal signature is pending|captain
pending-reply-abc|pending-reply-missed:abc summary|captain
CASES
  pass "decider route: money, legal, credentials, and irreversible work stay with the captain"
}

test_classifier_unclassified_stays_with_captain() {
  local got
  got=$(classify js-runtime 'which of the two api shapes should the client use')
  [ "$got" = unclassified ] || fail "an unmatched decision must stay unclassified, got '$got'"
  got=$(classify refund-shape 'refund the internal ledger concept in the docs')
  case "$got" in
    captain|unclassified) ;;
    *) fail "a refund-shaped note with no stated amount must not be routed, got '$got'" ;;
  esac
  pass "decider route: an unplaceable decision is never handed to a worker"
}

test_refund_cap_boundary() {
  local got
  # shellcheck disable=SC2016 # A literal amount is the point.
  got=$(FM_DECIDER_REFUND_CAP=100 classify refund-mid 'refund $120')
  [ "$got" = captain ] || fail "a refund of 120 with a 100 cap must be the captain's, got '$got'"
  # shellcheck disable=SC2016 # A literal amount is the point.
  got=$(FM_DECIDER_REFUND_CAP=100 classify refund-under 'refund $20')
  [ "$got" = refund-under-150 ] || fail "a refund of 20 with a 100 cap should route, got '$got'"
  pass "decider route: the bounded money carve-out reads the configured cap"
}

# --- 2. sweep ---------------------------------------------------------------

write_status() {  # <dir> <line...>
  local dir=$1
  shift
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$dir/home/state/t1.status"
  done
}

test_sweep_routes_only_standing_orders() {
  local dir out rc
  dir=$(setup_home routes)
  write_status "$dir" \
    'working: start' \
    'needs-decision [key=ddl-nullable]: add a nullable column to events - additive, reversible' \
    'needs-decision [key=pay-vendor]: should we pay the vendor for the extra seats' \
    'needs-decision [key=shape]: which of the two api shapes should the client use' \
    'blocked [key=waiting]: waiting on the external service'
  out=$(run_route "$dir" -- sweep); rc=$?
  expect_code 0 "$rc" "a sweep should succeed"
  [ -z "$out" ] || fail "a sweep that routes cleanly must not wake firstmate, got: $out"
  [ "$(inbox_count "$dir")" = 1 ] || fail "exactly one ruling request was expected, got $(inbox_count "$dir")"
  assert_contains "$(cat "$dir"/home/state/decider.inbox/001.msg)" 'key: ddl-nullable' \
    "the ruling request should name the decision key"
  assert_contains "$(cat "$dir"/home/state/decider.inbox/001.msg)" 'class: additive-ddl' \
    "the ruling request should name the standing order"
  assert_contains "$(cat "$dir"/home/state/decider.inbox/001.msg)" "bin/fm-decider-route.sh answer t1 ddl-nullable" \
    "the ruling request should state the exact answer command"
  pass "decider route: a sweep routes the standing order and leaves class (a) alone"
}

test_sweep_is_idempotent() {
  local dir before
  dir=$(setup_home idempotent)
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  run_route "$dir" -- sweep >/dev/null 2>&1
  before=$(inbox_count "$dir")
  run_route "$dir" -- sweep >/dev/null 2>&1
  [ "$(inbox_count "$dir")" = "$before" ] \
    || fail "a second sweep must not re-ask an already-routed decision ($before then $(inbox_count "$dir"))"
  [ "$(grep -c '^A' "$dir/home/state/decider-ledger.tsv")" = 1 ] \
    || fail "the ledger should record exactly one ask"
  pass "decider route: one ruling request per decision episode"
}

test_sweep_reopens_a_closed_episode() {
  local dir
  dir=$(setup_home reopen)
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  run_route "$dir" -- sweep >/dev/null 2>&1
  printf 'resolved [key=ddl-nullable]: shipped\n' >> "$dir/home/state/t1.status"
  run_route "$dir" -- sweep >/dev/null 2>&1
  [ "$(grep -c "^C	" "$dir/home/state/decider-ledger.tsv")" = 1 ] \
    || fail "the close should be recorded once"
  assert_grep "$(printf '\tt1\tddl-nullable\t')" "$dir/home/state/decider-ledger.tsv" \
    "the close should name the decision"
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add another nullable column'
  run_route "$dir" -- sweep >/dev/null 2>&1
  [ "$(inbox_count "$dir")" = 2 ] || fail "a reopened key is a new episode and should be asked again"
  [ "$(grep -c '^O' "$dir/home/state/decider-ledger.tsv")" = 2 ] \
    || fail "a reopened key should open a second episode in the ledger"
  pass "decider route: a key that closes and reopens gets its own episode and clock"
}

test_unreachable_seat_keeps_the_decision_open() {
  local dir out
  dir=$(setup_home unreachable)
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  # A regular file where the inbox directory belongs makes the durable record
  # impossible, which is the only send failure that can lose a decision.
  printf 'not a directory\n' > "$dir/home/state/decider.inbox"
  out=$(run_route "$dir" -- sweep 2>&1)
  assert_contains "$out" 'could not deliver a ruling request' \
    "an undeliverable request must surface instead of vanishing"
  ! grep -q '^A	' "$dir/home/state/decider-ledger.tsv" \
    || fail "an undelivered request must not be recorded as asked"
  rm -f "$dir/home/state/decider.inbox"
  run_route "$dir" -- sweep >/dev/null 2>&1
  [ "$(inbox_count "$dir")" = 1 ] || fail "the next sweep should retry the delivery"
  pass "decider route: a failed delivery leaves the decision to be retried, never lost"
}

test_ruling_window_surfaces_once() {
  local dir now out out2
  dir=$(setup_home window)
  now=1700000000
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  run_route "$dir" FM_DECIDER_NOW="$now" -- sweep >/dev/null 2>&1
  out=$(run_route "$dir" FM_DECIDER_NOW=$((now + 3600)) -- sweep)
  [ -z "$out" ] || fail "a decision inside its ruling window must stay quiet, got: $out"
  out=$(run_route "$dir" FM_DECIDER_NOW=$((now + 8000)) -- sweep)
  assert_contains "$out" 'has waited for a ruling from the Decider seat past the window' \
    "an unruled decision past the window must surface"
  out2=$(run_route "$dir" FM_DECIDER_NOW=$((now + 9000)) -- sweep)
  [ -z "$out2" ] || fail "the window must be reported once per episode, got: $out2"
  pass "decider route: one wake when a routed decision outlives the ruling window"
}

test_no_seat_configured_is_inert() {
  local dir out rc
  dir=$(setup_home no-seat)
  rm -f "$dir/home/config/decider-task"
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  out=$(run_route "$dir" -- sweep); rc=$?
  expect_code 0 "$rc" "an unconfigured home is not an error"
  [ -z "$out" ] || fail "an unconfigured home must stay silent, got: $out"
  [ "$(inbox_count "$dir")" = 0 ] || fail "nothing may be routed with no seat configured"
  pass "decider route: no configured seat routes nothing and stays quiet"
}

test_armed_without_seat_is_reported() {
  local dir out
  dir=$(setup_home armed-no-seat)
  rm -f "$dir/home/config/decider-task"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/home/state/decider-route.check.sh"
  chmod 0700 "$dir/home/state/decider-route.check.sh"
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  out=$(run_route "$dir" -- sweep)
  assert_contains "$out" 'the check is armed but no Decider seat is configured' \
    "an armed check with no seat is a routing outage and must say so"
  pass "decider route: an armed check with no seat reports the outage"
}

# --- 3. answer --------------------------------------------------------------

test_answer_closes_the_key() {
  local dir out status
  dir=$(setup_home answers)
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  run_route "$dir" -- sweep >/dev/null 2>&1
  out=$(run_route "$dir" -- answer t1 ddl-nullable 'Add it nullable with a default.' 2>&1)
  assert_contains "$out" 'ruled: t1 [key=ddl-nullable] closed' "answer should report the ruling"
  status=$(run_route "$dir" -- status)
  assert_not_contains "$status" 'key=ddl-nullable' "the answered key must leave the open set"
  grep -qE '^R[[:space:]]+[0-9]+[[:space:]]+t1[[:space:]]+ddl-nullable[[:space:]]+additive-ddl' \
    "$dir/home/state/decider-ledger.tsv" \
    || fail "the ruling must be recorded in the ledger as an R record naming the episode"
  pass "decider route: answer closes the decision through --resolve-key and records the ruling"
}

test_answer_refuses_class_a() {
  local dir out rc
  dir=$(setup_home refuses)
  write_status "$dir" 'needs-decision [key=pay-vendor]: should we pay the vendor for extra seats'
  run_route "$dir" -- sweep >/dev/null 2>&1
  set +e
  out=$(run_route "$dir" -- answer t1 pay-vendor 'Yes, pay it.' 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "the seat must be refused a class (a) decision"
  assert_contains "$out" "the captain's to answer" "the refusal should say whose decision it is"
  ! grep -q '^R	' "$dir/home/state/decider-ledger.tsv" \
    || fail "a refused ruling must never be recorded as a ruling"
  assert_contains "$(run_route "$dir" -- status)" 'key=pay-vendor' \
    "the refused decision must still be open"
  pass "decider route: the seat cannot record a ruling on a class (a) decision"
}

test_answer_refuses_an_unrouted_key() {
  local dir out rc
  dir=$(setup_home unrouted)
  set +e
  out=$(run_route "$dir" -- answer t9 ghost-key 'nope' 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "an unrouted key must be refused"
  assert_contains "$out" 'not an episode this home routed' "the refusal should explain the miss"
  pass "decider route: answer only records episodes this home actually routed"
}

# --- 4. arming --------------------------------------------------------------

test_arm_and_disarm() {
  local dir shim trust
  dir=$(setup_home arming)
  shim="$dir/home/state/decider-route.check.sh"
  trust="$dir/home/state/decider-route.check-trust"
  write_status "$dir" 'needs-decision [key=ddl-nullable]: add a nullable column'
  run_route "$dir" -- sweep >/dev/null 2>&1
  run_route "$dir" -- arm >/dev/null 2>&1 || fail "arm should succeed with a seated decider"
  assert_present "$shim" "arm should write the check shim"
  assert_present "$trust" "arm should bind the shim's bytes"
  assert_contains "$(cat "$shim")" "exec $ROUTE sweep" "the shim should dispatch the sweep"
  run_route "$dir" -- disarm >/dev/null 2>&1 || fail "disarm should succeed"
  assert_absent "$shim" "disarm should remove the shim"
  assert_absent "$trust" "disarm should remove the trust binding"
  assert_present "$dir/home/state/decider-ledger.tsv" \
    "disarm must keep the routing ledger the measurement reads"
  pass "decider route: arm binds the sweep and disarm retires it while keeping the ledger"
}

test_arm_requires_a_seated_decider() {
  local dir out rc
  dir=$(setup_home unseated)
  rm -f "$dir/home/state/decider.meta"
  set +e
  out=$(run_route "$dir" -- arm 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arm must refuse a decider seat with no task record"
  assert_contains "$out" 'no task record for the Decider seat' "the refusal should name the cause"
  assert_absent "$dir/home/state/decider-route.check.sh" "a refused arm writes no shim"
  pass "decider route: arming refuses a seat that is not actually seated"
}

test_classifier_standing_orders
test_classifier_class_a
test_classifier_unclassified_stays_with_captain
test_refund_cap_boundary
test_sweep_routes_only_standing_orders
test_sweep_is_idempotent
test_sweep_reopens_a_closed_episode
test_unreachable_seat_keeps_the_decision_open
test_ruling_window_surfaces_once
test_no_seat_configured_is_inert
test_armed_without_seat_is_reported
test_answer_closes_the_key
test_answer_refuses_class_a
test_answer_refuses_an_unrouted_key
test_arm_and_disarm
test_arm_requires_a_seated_decider
