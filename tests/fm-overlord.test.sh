#!/usr/bin/env bash
# tests/fm-overlord.test.sh - the overseer must print one line per domain naming
# each number, its source, and its age; interject once when a named threshold is
# crossed (a status line, a page, a steer carrying the correction); stay silent
# on an unchanged number; and read an absent or disagreeing source as
# unmeasured. The incident this pins: on 2026-11-11 a send count of 0 held for a
# day and green pull requests sat unmerged, and no check raised either.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERLORD="$ROOT/bin/fm-overlord.sh"
TMP_ROOT=$(fm_test_tmproot fm-overlord)

# 2026-11-11T12:00:00Z
T0=1794398400

stamp() {  # <epoch> -> ISO seconds
  python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/remote"
  # The forge client answers with <home>/gh.json; absent, it fails.
  cat > "$home/fakebin/fake-gh" <<SH
#!/usr/bin/env bash
case "\$*" in *organization*) exit 1 ;; esac
[ -f "$home/gh.json" ] || exit 1
cat "$home/gh.json"
SH
  # The steer command records its arguments; <home>/send.fail makes it refuse.
  cat > "$home/fakebin/fake-send" <<SH
#!/usr/bin/env bash
if [ -f "$home/send.fail" ]; then echo 'fm-send: no such task' >&2; exit 1; fi
printf '%s\n' "\$*" >> "$home/sent"
SH
  chmod +x "$home/fakebin/fake-gh" "$home/fakebin/fake-send"
  printf '%s\n' "$home"
}

# run <home> <now> <action> [extra env...]
run() {
  local home=$1 now=$2 action=$3
  shift 3
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_OVERLORD_NOW="$now" FM_OVERLORD_PROBE_SECS=0 FM_OVERLORD_GH_BIN="$home/fakebin/fake-gh" \
    FM_OVERLORD_SEND_BIN="$home/fakebin/fake-send" "$@" "$OVERLORD" "$action" 2>&1
}

# tick <home> <start-epoch> <would_send>: append one completed 10-minute tick.
tick() {
  {
    printf '%s tick start: live=1 paid_live=1 cap=250 out=/x deployed=abc\n' "$(stamp "$2")"
    printf '%s ask-free check (rc=0): {"candidates": 5, "would_send": %s, "sent": %s}\n' "$(stamp $(($2 + 300)))" "$3" "$3"
    printf '%s tick done; exit 0\n' "$(stamp $(($2 + 600)))"
  } >> "$1/remote/tick.log"
}

# pass_line <home> <n> <end-epoch> <users-told> <unmeasured>
pass_line() {
  printf 'working: [key=sentinel-%s] sentinel: pass %s %s->%s on abc123: open-uvn=10 users-told=%s risk0=0 unmeasured=%s artifact=/x | note\n' \
    "$2" "$2" "$(stamp $(($3 - 600)))" "$(stamp "$3")" "$4" "$5" >> "$1/state/watch-lane.status"
}

# green_prs <home> <count> <head-age-secs> <now>: a forge answer with <count>
# green, mergeable pull requests whose head is <head-age-secs> old.
green_prs() {
  python3 - "$1/gh.json" "$2" "$3" "$4" <<'PY'
import datetime, json, sys
path, count, head_age, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
pushed = datetime.datetime.fromtimestamp(now - head_age, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
nodes = [{"number": i, "url": "https://example.test/o/r/pull/%d" % i, "mergeable": "MERGEABLE", "headRefOid": "h%d" % i,
          "repository": {"nameWithOwner": "o/r"},
          "commits": {"nodes": [{"commit": {"oid": "h%d" % i, "committedDate": pushed, "statusCheckRollup": {"state": "SUCCESS"}}}]}}
         for i in range(1, count + 1)]
json.dump({"data": {"total": {"issueCount": 40},
                    "green": {"issueCount": count, "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}},
          open(path, "w"))
PY
}

configure() {  # <home> [extra lines...]
  local home=$1
  shift
  {
    printf 'FM_OVERLORD_SENTINEL_LANE=watch-lane\n'
    printf 'FM_OVERLORD_TICK_LOG=%s/remote/tick.log\n' "$home"
    printf 'FM_OVERLORD_CLAIMS_JSON=%s/remote/claims.json\n' "$home"
    printf 'FM_OVERLORD_SUPPORT_JSON=%s/remote/support.json\n' "$home"
    printf 'FM_OVERLORD_PR_SCOPE=org:o\n'
    printf 'FM_OVERLORD_OWNER_CREDIT=credit-lane\n'
    printf 'FM_OVERLORD_OWNER_MERGES=merge-lane\n'
    printf 'FM_OVERLORD_OWNER_SUPPORT=support-lane\n'
    printf 'FM_OVERLORD_FABLE_LANE=fable-lane\n'
    printf 'FM_OVERLORD_PAGE_CMD=cat >> "%s/paged"\n' "$home"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$home/config/overlord.env"
}

backlog() {  # <path> <written-epoch> <json-fields>
  printf '{"written_at": "%s", %s}\n' "$(stamp "$2")" "$3" > "$1"
}

fresh_backlogs() {  # <home> <now>: both backlog files just written, all zero
  backlog "$1/remote/claims.json" $(($2 - 60)) '"stuck_over_7d_no_step": 0, "reason_loss": 0'
  backlog "$1/remote/support.json" $(($2 - 60)) \
    '"waiting_on_us": 0, "promised_a_person_24h": 7, "promises_broken_24h": 0, "commitments_overdue": 0'
}

healthy() {  # <home> <now>: every source present and inside its threshold
  local home=$1 now=$2
  : > "$home/remote/tick.log"
  tick "$home" $((now - 9000)) 4
  tick "$home" $((now - 1800)) 3
  : > "$home/state/watch-lane.status"
  pass_line "$home" 1 $((now - 15000)) 100 0
  pass_line "$home" 2 $((now - 600)) 140 0
  fresh_backlogs "$home" "$now"
  green_prs "$home" 0 0 "$now"
}

test_an_unreadable_source_holds_an_open_crossing_instead_of_resolving_it() {
  local home
  home=$(make_home hold)
  configure "$home"
  healthy "$home" "$T0"
  : > "$home/remote/tick.log"
  tick "$home" $((T0 - 9000)) 0
  tick "$home" $((T0 - 1800)) 0
  run "$home" "$T0" check >/dev/null
  assert_contains "$(cat "$home/state/overlord.status")" "blocked [key=overlord-credit-would-send]" "the zero would_send did not interject"

  # The tick log becomes unreadable: the crossing is merely unmeasured, not cleared.
  healthy "$home" $((T0 + 600))
  rm -f "$home/remote/tick.log"
  run "$home" $((T0 + 600)) check >/dev/null
  assert_not_contains "$(cat "$home/state/overlord.status")" "resolved [key=overlord-credit-would-send]" \
    "an unreadable source resolved the crossing"

  # Readable again and clear: it resolves.
  : > "$home/remote/tick.log"
  tick "$home" $((T0 + 1200)) 6
  tick "$home" $((T0 + 1800)) 6
  fresh_backlogs "$home" $((T0 + 2400))
  run "$home" $((T0 + 2400)) check >/dev/null
  assert_contains "$(tail -1 "$home/state/overlord.status")" "resolved [key=overlord-credit-would-send]" \
    "a readable clear source did not resolve the crossing"
  pass "an unreadable source holds an open crossing, and a readable clear one resolves it"
}

test_a_worsening_level_threshold_interjects_again_after_the_reminder_window() {
  local home
  home=$(make_home level)
  configure "$home"
  healthy "$home" "$T0"
  run "$home" "$T0" check >/dev/null
  backlog "$home/remote/support.json" $((T0 + 540)) \
    '"waiting_on_us": 0, "promised_a_person_24h": 7, "promises_broken_24h": 0, "commitments_overdue": 2'
  run "$home" $((T0 + 600)) check >/dev/null
  assert_contains "$(cat "$home/state/overlord.status")" "commitments_overdue=2" "the overdue commitment did not interject"

  backlog "$home/remote/support.json" $((T0 + 1140)) \
    '"waiting_on_us": 0, "promised_a_person_24h": 7, "promises_broken_24h": 0, "commitments_overdue": 2'
  run "$home" $((T0 + 1200)) check >/dev/null
  [ "$(wc -l < "$home/state/overlord.status" | tr -d ' ')" = 1 ] || fail "an unchanged overdue count interjected again"

  backlog "$home/remote/support.json" $((T0 + 15000)) \
    '"waiting_on_us": 0, "promised_a_person_24h": 7, "promises_broken_24h": 0, "commitments_overdue": 10'
  run "$home" $((T0 + 15000)) check >/dev/null
  assert_contains "$(tail -1 "$home/state/overlord.status")" "commitments_overdue=10" \
    "a worsening overdue count did not interject again"
  pass "a worsening level threshold interjects again after the reminder window"
}

test_a_cut_short_remote_read_is_unmeasured_not_a_false_tick() {
  local home out
  home=$(make_home truncated)
  configure "$home"
  healthy "$home" "$T0"
  cat > "$home/fakebin/fake-remote" <<SH
#!/usr/bin/env bash
cat "$home/partial-stream"
SH
  chmod +x "$home/fakebin/fake-remote"
  {
    printf '@@now %s\n' "$T0"
    printf '@@file ticklog present %s\n' "$T0"
    printf '%s tick start: live=1 paid_live=1 cap=250 out=/x deployed=abc\n' "$(stamp $((T0 - 20000)))"
    printf '%s ask-free check (rc=0): {"candidates": 5, "would_send": 0, "sent": 0}\n' "$(stamp $((T0 - 19900)))"
    printf '@@file claims present %s\n' "$T0"
    printf '{"written_at": "%s", "stuck_over_7d_no_step": 0, "reason_loss": 0}\n' "$(stamp $((T0 - 60)))"
  } > "$home/partial-stream"
  out=$(run "$home" "$T0" digest FM_OVERLORD_REMOTE="$home/fakebin/fake-remote")
  assert_contains "$out" "would_send=unmeasured (remote:$home/remote/tick.log was cut short before the read finished)" \
    "a cut-short tick log was read as a tick"
  assert_contains "$out" "tick=unmeasured (remote:$home/remote/tick.log was cut short before the read finished)" \
    "a cut-short tick log produced a tick reading"
  pass "a cut-short remote read is unmeasured, not a false tick"
}

test_a_hanging_remote_read_is_bounded_and_reads_unmeasured() {
  local home out start elapsed
  home=$(make_home hang)
  configure "$home"
  healthy "$home" "$T0"
  cat > "$home/fakebin/fake-remote" <<'SH'
#!/usr/bin/env bash
exec sleep 30
SH
  chmod +x "$home/fakebin/fake-remote"
  start=$(date +%s)
  out=$(run "$home" "$T0" digest FM_CHECK_TIMEOUT=4 FM_OVERLORD_PR_SCOPE= FM_OVERLORD_REMOTE="$home/fakebin/fake-remote")
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 10 ] || fail "a hanging remote read blocked for ${elapsed}s"
  assert_contains "$out" "would_send=unmeasured" "a hanging remote read did not read unmeasured"
  pass "a hanging remote read is bounded and reads unmeasured"
}

test_an_unconfigured_home_is_not_reported_as_inside_thresholds() {
  local home out
  home=$(make_home unconfigured)
  out=$(run "$home" "$T0" digest)
  assert_not_contains "$out" "inside thresholds" "an unconfigured home read as inside thresholds"
  assert_contains "$out" "| unmeasured (not configured): users_told_today, would_send" \
    "the credit line did not report its unconfigured readings"
  pass "an unconfigured home is not reported as inside thresholds"
}

test_a_malformed_pr_scope_reads_unmeasured_instead_of_crashing() {
  local home out
  home=$(make_home scope)
  configure "$home" 'FM_OVERLORD_PR_SCOPE=org:'
  healthy "$home" "$T0"
  out=$(run "$home" "$T0" digest)
  assert_contains "$out" "merges | open,green_unmerged_2h=unmeasured (FM_OVERLORD_PR_SCOPE names an org with no login)" \
    "a malformed scope did not read unmeasured"
  assert_contains "$out" "| unmeasured: open, green_unmerged_2h" "a malformed scope was reported as inside thresholds"
  pass "a malformed PR scope reads unmeasured instead of crashing the check"
}

test_digest_prints_one_line_per_domain_with_number_source_and_age() {
  local home out
  home=$(make_home digest)
  configure "$home"
  healthy "$home" "$T0"
  out=$(run "$home" "$T0" digest)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] || fail "the digest is not one line per domain: $out"
  assert_contains "$out" "credit | users_told_today=140 [pass 2 window" "the credit line does not name the pass and its window"
  assert_contains "$out" "source state/watch-lane.status; age 10m" "the credit line does not name its source and age"
  assert_contains "$out" "would_send=4,3 [last two completed ticks" "the credit line does not carry the last two ticks"
  assert_contains "$out" "support | waiting_on_us=0 [source $home/remote/support.json; age 1m]" "the support line lacks source and age"
  assert_contains "$out" "merges | open=40" "the merges line lacks the open count"
  assert_contains "$out" "claims | stuck_over_7d_no_step=0" "the claims line lacks its number"
  assert_contains "$out" "meter | tick=started 30m ago" "the meter line lacks the tick"
  assert_not_contains "$out" "WRONG" "a healthy home read as wrong"
  assert_absent "$home/state/.overlord.json" "the digest wrote a record"
  assert_absent "$home/state/overlord.status" "the digest wrote a status line"
  pass "the digest prints one line per domain with number, source, and age, and changes nothing"
}

test_zero_would_send_on_two_ticks_interjects_once_then_resolves() {
  local home out status
  home=$(make_home would-send)
  configure "$home"
  healthy "$home" "$T0"
  out=$(run "$home" "$T0" check)
  [ -z "$out" ] || fail "a healthy check printed: $out"
  assert_absent "$home/state/overlord.status" "a healthy check wrote a status line"
  assert_absent "$home/sent" "a healthy check steered a lane"

  # One zero tick is not two.
  tick "$home" $((T0 + 5400)) 0
  pass_line "$home" 6 $((T0 + 6600)) 145 0
  fresh_backlogs "$home" $((T0 + 7200))
  run "$home" $((T0 + 7200)) check >/dev/null
  assert_absent "$home/state/overlord.status" "one zero tick already interjected"

  tick "$home" $((T0 + 12600)) 0
  pass_line "$home" 3 $((T0 + 13800)) 150 0
  fresh_backlogs "$home" $((T0 + 14400))
  run "$home" $((T0 + 14400)) check >/dev/null
  status=$(cat "$home/state/overlord.status")
  assert_contains "$status" "blocked [key=overlord-credit-would-send]: OVERLORD credit: would_send=0 on two consecutive ticks; would_send=0,0" \
    "the status line does not name the domain, threshold, and number"
  assert_contains "$status" "source $home/remote/tick.log; age 20m" "the status line does not name the source and age"
  assert_contains "$(cat "$home/paged")" "would_send=0 on two consecutive ticks" "the page does not carry the crossed threshold"
  assert_contains "$(cat "$home/sent")" "credit-lane --fire-and-forget" "the owning lane was not steered"
  assert_contains "$(cat "$home/sent")" "Find what removed every candidate" "the steer carries the observation, not the correction"

  # The same crossing on a later poll: no second line, page, or steer.
  pass_line "$home" 4 $((T0 + 14900)) 160 0
  fresh_backlogs "$home" $((T0 + 15000))
  run "$home" $((T0 + 15000)) check >/dev/null
  [ "$(wc -l < "$home/state/overlord.status" | tr -d ' ')" = 1 ] || fail "an unchanged crossing wrote again: $(cat "$home/state/overlord.status")"
  [ "$(wc -l < "$home/paged" | tr -d ' ')" = 1 ] || fail "an unchanged crossing paged again"
  [ "$(wc -l < "$home/sent" | tr -d ' ')" = 1 ] || fail "an unchanged crossing steered again"

  tick "$home" $((T0 + 16200)) 6
  pass_line "$home" 5 $((T0 + 17400)) 170 0
  fresh_backlogs "$home" $((T0 + 18000))
  run "$home" $((T0 + 18000)) check >/dev/null
  assert_contains "$(cat "$home/state/overlord.status")" "resolved [key=overlord-credit-would-send]" "the cleared crossing was not closed"
  pass "would_send=0 on two ticks interjects once (status line, page, steer) and closes when it clears"
}

test_users_told_flat_for_four_hours_is_wrong_but_a_shorter_flat_is_not() {
  local home out
  home=$(make_home flat)
  configure "$home"
  healthy "$home" "$T0"
  : > "$home/state/watch-lane.status"
  pass_line "$home" 1 $((T0 - 7200)) 500 0
  pass_line "$home" 2 $((T0 - 600)) 500 0
  out=$(run "$home" "$T0" digest)
  assert_not_contains "$out" "has not risen" "two hours flat read as a four-hour crossing"
  : > "$home/state/watch-lane.status"
  pass_line "$home" 1 $((T0 - 15000)) 500 0
  pass_line "$home" 2 $((T0 - 600)) 500 0
  out=$(run "$home" "$T0" digest)
  assert_contains "$out" "WRONG: users_told_today has not risen in 4h00m" "four hours flat did not cross"
  pass "users_told_today flat across four hours is wrong, and a shorter flat stretch is not"
}

test_green_unmerged_rises_goes_to_fable_and_an_unchanged_count_is_silent() {
  local home status
  home=$(make_home merges)
  configure "$home"
  healthy "$home" "$T0"
  green_prs "$home" 3 10800 "$T0"
  run "$home" "$T0" check >/dev/null
  status=$(cat "$home/state/overlord.status")
  assert_contains "$status" "blocked [key=overlord-merges-green-unmerged]: OVERLORD merges: green_unmerged_2h rises; green_unmerged_2h=3" \
    "a standing green backlog was not interjected"
  assert_contains "$(cat "$home/sent")" "fable-lane --fire-and-forget" "an irreversible correction did not go to the Fable lane"
  assert_not_contains "$(cat "$home/sent")" "merge-lane --fire-and-forget" "the owning lane was told to merge without a review"
  assert_contains "$(cat "$home/sent")" "https://example.test/o/r/pull/1" "the review request does not name the pull requests"

  # Unchanged is not wrong: nothing new is said, and the rise stays open.
  healthy "$home" $((T0 + 600))
  green_prs "$home" 3 10800 $((T0 + 600))
  run "$home" $((T0 + 600)) check >/dev/null
  [ "$(wc -l < "$home/state/overlord.status" | tr -d ' ')" = 1 ] || fail "an unchanged count wrote again: $(cat "$home/state/overlord.status")"
  [ "$(wc -l < "$home/sent" | tr -d ' ')" = 1 ] || fail "an unchanged count steered again"

  # A further rise does not interject on the next poll, only once the reminder window has passed.
  healthy "$home" $((T0 + 1200))
  green_prs "$home" 5 10800 $((T0 + 1200))
  run "$home" $((T0 + 1200)) check >/dev/null
  [ "$(wc -l < "$home/sent" | tr -d ' ')" = 1 ] || fail "a further rise interjected on the very next poll"
  healthy "$home" $((T0 + 16000))
  green_prs "$home" 5 10800 $((T0 + 16000))
  run "$home" $((T0 + 16000)) check >/dev/null
  assert_contains "$(tail -1 "$home/state/overlord.status")" "green_unmerged_2h=5" "a rise that held past the reminder window was not interjected again"

  # Back to where it rose from closes it.
  healthy "$home" $((T0 + 16600))
  run "$home" $((T0 + 16600)) check >/dev/null
  assert_contains "$(tail -1 "$home/state/overlord.status")" "resolved [key=overlord-merges-green-unmerged]" "a cleared backlog was not closed"

  # A head pushed inside the window is not counted, and neither is a result on another commit.
  green_prs "$home" 2 600 $((T0 + 17000))
  assert_contains "$(run "$home" $((T0 + 17000)) digest)" "green_unmerged_2h=0" "a fresh head counted as waiting two hours"
  green_prs "$home" 2 10800 $((T0 + 17000))
  sed -i.bak 's/"oid": "h1"/"oid": "stale"/' "$home/gh.json"
  assert_contains "$(run "$home" $((T0 + 17000)) digest)" "green_unmerged_2h=1 " "a result on another commit was counted as the current head"
  pass "a rising green-unmerged count goes to Fable for review, and an unchanged count is silent"
}

test_absent_and_stale_sources_are_unmeasured_and_two_ticks_interject() {
  local home out
  home=$(make_home unmeasured)
  configure "$home"
  healthy "$home" "$T0"
  rm -f "$home/remote/support.json"
  backlog "$home/remote/claims.json" $((T0 - 20000)) '"stuck_over_7d_no_step": 9, "reason_loss": 9'
  out=$(run "$home" "$T0" digest)
  assert_contains "$out" "support | waiting_on_us,promised_a_person_24h,promises_broken_24h,commitments_overdue=unmeasured ($home/remote/support.json does not exist" \
    "an absent source did not read unmeasured"
  assert_contains "$out" "is stale: written 5h33m ago" "a stale source was read as current"
  assert_not_contains "$out" "stuck_over_7d_no_step=9" "a stale number was reported"
  run "$home" "$T0" check >/dev/null
  assert_absent "$home/state/overlord.status" "one unmeasured tick already interjected"
  healthy "$home" $((T0 + 600))
  rm -f "$home/remote/support.json" "$home/remote/claims.json"
  run "$home" $((T0 + 600)) check >/dev/null
  assert_contains "$(cat "$home/state/overlord.status")" "blocked [key=overlord-meter-unmeasured-support]: OVERLORD meter: support unmeasured on two consecutive ticks" \
    "two unmeasured ticks did not interject"
  assert_contains "$(cat "$home/sent")" "support-lane --fire-and-forget" "the unmeasured numbers were not steered to the lane that owns them"
  pass "absent and stale sources read unmeasured, and two unmeasured ticks interject to the owning lane"
}

test_support_thresholds_and_a_late_tick() {
  local home status
  home=$(make_home support)
  configure "$home"
  healthy "$home" "$T0"
  run "$home" "$T0" check >/dev/null
  healthy "$home" $((T0 + 600))
  backlog "$home/remote/support.json" $((T0 + 540)) \
    '"waiting_on_us": 4, "promised_a_person_24h": 7, "promises_broken_24h": 1, "commitments_overdue": 2'
  # The last tick started 3h ago against a 2h cadence.
  : > "$home/remote/tick.log"
  tick "$home" $((T0 - 20000)) 2
  tick "$home" $((T0 - 10200)) 2
  run "$home" $((T0 + 600)) check >/dev/null
  status=$(cat "$home/state/overlord.status")
  assert_contains "$status" "[key=overlord-support-waiting]: OVERLORD support: waiting_on_us rises; waiting_on_us=4" "a rising wait did not interject"
  assert_contains "$status" "[key=overlord-support-overdue]: OVERLORD support: a commitment passed its due time with no sent message; commitments_overdue=2" \
    "an overdue commitment did not interject"
  assert_contains "$status" "[key=overlord-meter-tick]: OVERLORD meter: the tick exceeds its cadence; tick=started 3h00m ago" "a late tick did not interject"
  assert_contains "$status" "the correction was not delivered to a lane: no lane configured. Route it by hand." \
    "a crossing with no owning lane did not say the correction went nowhere"
  pass "a rising wait, an overdue commitment, and a late tick each interject, and an unowned correction says so"
}

test_a_refused_steer_is_recorded_on_the_same_key() {
  local home status
  home=$(make_home refused)
  configure "$home"
  healthy "$home" "$T0"
  : > "$home/remote/tick.log"
  tick "$home" $((T0 - 9000)) 0
  tick "$home" $((T0 - 1800)) 0
  : > "$home/send.fail"
  run "$home" "$T0" check >/dev/null
  status=$(cat "$home/state/overlord.status")
  assert_contains "$status" "blocked [key=overlord-credit-would-send]: the correction was not delivered to a lane: the steer was refused (fm-send: no such task)" \
    "a refused steer was not recorded"
  pass "a steer that could not be delivered is recorded on the crossing's own key"
}

test_adjudicate_names_windows_and_never_averages() {
  local out rc
  out=$("$OVERLORD" adjudicate risk0 6 '2026-11-11T22:00:00Z->2026-11-11T22:10:00Z' sentinel-a \
    0 '2026-11-11T23:00:00Z->2026-11-11T23:10:00Z' sentinel-b)
  assert_contains "$out" "risk0=0:" "the later window was not authoritative"
  assert_contains "$out" "6 [window 2026-11-11T22:00:00Z->2026-11-11T22:10:00Z, source sentinel-a]" "a reading was not named with its window and source"
  assert_contains "$out" "because its window ends latest" "the verdict does not say why"
  out=$("$OVERLORD" adjudicate risk0 6 '2026-11-11T23:00:00Z->2026-11-11T23:10:00Z' sentinel-a \
    0 '2026-11-11T23:00:00Z->2026-11-11T23:10:00Z' sentinel-b)
  rc=$?
  expect_code 1 "$rc" "same-window disagreement"
  assert_contains "$out" "risk0=unmeasured" "a same-window disagreement was not unmeasured"
  out=$("$OVERLORD" adjudicate risk0 6 - sentinel-a 0 '2026-11-11T23:00:00Z->2026-11-11T23:10:00Z' sentinel-b)
  assert_contains "$out" "risk0=unmeasured" "an unknown window was adjudicated"
  assert_not_contains "$out" "risk0=3" "the readings were averaged"
  out=$("$OVERLORD" adjudicate risk0 4 - a 4 - b)
  assert_contains "$out" "risk0=4 (the readings agree)" "agreeing readings were not accepted"
  pass "adjudicate names each window and source, prefers the latest window, and answers unmeasured rather than an average"
}

test_a_pass_recorded_twice_with_different_counts_is_unmeasured_and_goes_to_fable() {
  local home out
  home=$(make_home disagree)
  configure "$home"
  healthy "$home" "$T0"
  pass_line "$home" 2 $((T0 - 600)) 155 0
  out=$(run "$home" "$T0" digest)
  assert_contains "$out" "users_told_today=unmeasured (users_told_today disagrees over one window: 140 [window" "a doubled pass was read as one number"
  run "$home" "$T0" check >/dev/null
  assert_contains "$(cat "$home/state/overlord.status")" "blocked [key=overlord-disagree-users-told]" "the disagreement was not interjected"
  assert_contains "$(cat "$home/sent")" "fable-lane --fire-and-forget" "the disagreement did not go to the Fable lane"
  assert_contains "$(cat "$home/sent")" "This needs an adjudication" "the Fable lane was not asked to adjudicate"
  pass "one pass recorded twice with different counts is unmeasured and goes to Fable to adjudicate"
}

test_the_check_reads_its_sources_at_most_once_per_probe_window() {
  local home
  home=$(make_home probe)
  configure "$home"
  healthy "$home" "$T0"
  run "$home" "$T0" check FM_OVERLORD_PROBE_SECS=600 >/dev/null
  : > "$home/remote/tick.log"
  tick "$home" $((T0 - 9000)) 0
  tick "$home" $((T0 - 1800)) 0
  run "$home" $((T0 + 300)) check FM_OVERLORD_PROBE_SECS=600 >/dev/null
  assert_absent "$home/state/overlord.status" "the check read its sources again inside the probe window"
  run "$home" $((T0 + 600)) check FM_OVERLORD_PROBE_SECS=600 >/dev/null
  assert_present "$home/state/overlord.status" "the check did not read once the probe window passed"
  pass "the check reads its sources at most once per probe window"
}

test_status_arm_and_disarm() {
  local home out
  home=$(make_home arm)
  configure "$home"
  healthy "$home" "$T0"
  out=$(run "$home" "$T0" status)
  assert_contains "$out" "no check has recorded a reading yet" "status invented a reading"
  run "$home" "$T0" check >/dev/null
  out=$(run "$home" $((T0 + 120)) status)
  assert_contains "$out" "recorded 2026-11-11T12:00Z (2m ago)" "status does not say when the reading was taken"
  assert_contains "$out" "merges | open=40" "status does not replay the recorded lines"
  run "$home" "$T0" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/overlord.check.sh" "arm did not write the shim"
  assert_present "$home/state/overlord.check-trust" "arm did not bind the shim"
  assert_contains "$(cat "$home/state/overlord.check.sh")" "fm-overlord.sh check" "the shim does not run the check"
  run "$home" "$T0" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/overlord.check.sh" "disarm left the shim"
  assert_absent "$home/state/.overlord.json" "disarm left the record"
  pass "status replays the last reading, and arm and disarm manage the registered shim"
}

test_digest_prints_one_line_per_domain_with_number_source_and_age
test_zero_would_send_on_two_ticks_interjects_once_then_resolves
test_an_unreadable_source_holds_an_open_crossing_instead_of_resolving_it
test_a_worsening_level_threshold_interjects_again_after_the_reminder_window
test_a_cut_short_remote_read_is_unmeasured_not_a_false_tick
test_a_hanging_remote_read_is_bounded_and_reads_unmeasured
test_an_unconfigured_home_is_not_reported_as_inside_thresholds
test_a_malformed_pr_scope_reads_unmeasured_instead_of_crashing
test_users_told_flat_for_four_hours_is_wrong_but_a_shorter_flat_is_not
test_green_unmerged_rises_goes_to_fable_and_an_unchanged_count_is_silent
test_absent_and_stale_sources_are_unmeasured_and_two_ticks_interject
test_support_thresholds_and_a_late_tick
test_a_refused_steer_is_recorded_on_the_same_key
test_adjudicate_names_windows_and_never_averages
test_a_pass_recorded_twice_with_different_counts_is_unmeasured_and_goes_to_fable
test_the_check_reads_its_sources_at_most_once_per_probe_window
test_status_arm_and_disarm
