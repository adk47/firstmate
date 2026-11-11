#!/usr/bin/env bash
# Behavior tests for the launch-brief argv contract in bin/fm-spawn.sh.
#
# Linux caps a single argv element at MAX_ARG_STRLEN (131072 bytes). The launch
# line used to substitute the WHOLE brief into one argv element, so any brief
# above the cap could not start at all: the pane died with
# "-bash: /usr/bin/env: Argument list too long" and the lane read as dead rather
# than as an oversized brief. These tests pin both sides of the fix: an
# oversized brief launches through a constant-size path pointer, and a small
# brief launches exactly as before.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-argv)
ARG_LIMIT=131072

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# Grow a brief past the argv cap with legitimate archive content, never a
# placeholder: the launcher must cope with a large brief, not be told to avoid one.
grow_brief() {
  local brief=$1 bytes=$2
  {
    printf '\n## Lane history\n'
    awk -v n="$bytes" 'BEGIN { for (i = 0; i < n; i += 64) printf "%s\n", "archived lane history line 0123456789 abcdefghijklmnopqrstuvwxyz" }'
  } >> "$brief"
}

run_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

launch_line() {  # <launch-log>
  grep -F 'encode launch-brief' "$1" | tail -n 1
}

test_oversized_brief_launches_through_the_path_pointer() {
  local rec id out status launch brief_bytes launch_bytes
  id='brief-argv-oversized-z1'
  rec=$(make_spawn_case brief-argv-oversized pi "$id")
  read_case_record "$rec"
  grow_brief "$HOME_DIR/data/$id/brief.md" 400000
  brief_bytes=$(wc -c < "$HOME_DIR/data/$id/brief.md")
  [ "$brief_bytes" -gt "$ARG_LIMIT" ] || fail "test setup did not build an oversized brief ($brief_bytes bytes)"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an oversized brief must still launch through the path pointer"$'\n'"$out"

  launch=$(launch_line "$LAUNCH_LOG")
  [ -n "$launch" ] || fail "oversized spawn sent no launch line"
  launch_bytes=$(printf '%s' "$launch" | wc -c)
  [ "$launch_bytes" -lt "$ARG_LIMIT" ] \
    || fail "launch line is $launch_bytes bytes, at or above the $ARG_LIMIT-byte argv cap"
  assert_contains "$launch" "Read the brief at $HOME_DIR/data/$id/launch-brief.md and follow it exactly." \
    "launch line did not carry the constant-size brief pointer"
  assert_not_contains "$launch" "archived lane history line" \
    "launch line still embedded the brief's content"
  pass "a $brief_bytes-byte brief launches through a $launch_bytes-byte path pointer"
}

test_small_brief_launch_is_unchanged() {
  local rec id out status launch
  id='brief-argv-small-z1'
  rec=$(make_spawn_case brief-argv-small pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a small brief must launch exactly as before"$'\n'"$out"

  launch=$(launch_line "$LAUNCH_LOG")
  # The control pins the whole launch shape, not just a substring: the pointer
  # form must be the ONLY change, so a small brief keeps the same command.
  assert_contains "$launch" "\"\$(printf %s 'Read the brief at $HOME_DIR/data/$id/launch-brief.md and follow it exactly.' | '$ROOT/bin/fm-operational-input.sh' encode launch-brief)\"" \
    "small-brief launch did not use the canonical pointer launch argument"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" \
    "small-brief launch lost its Pi turn-end extension"
  assert_not_contains "$launch" "archived lane history line" \
    "small-brief launch embedded brief content"
  pass "a small brief launches with the same command shape as before"
}

test_oversized_inline_body_fails_loudly_before_launch() {
  local rec id out status launch brief_bytes
  id='brief-argv-inline-over-z1'
  rec=$(make_spawn_case brief-argv-inline-over pi "$id")
  read_case_record "$rec"
  grow_brief "$HOME_DIR/data/$id/brief.md" 400000
  brief_bytes=$(wc -c < "$HOME_DIR/data/$id/brief.md")

  out=$(FM_SPAWN_BRIEF_INLINE_HARNESSES=pi FM_SPAWN_BRIEF_INLINE_MAX=200000 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "an inline body above the argv cap must fail the spawn, not launch it"
  assert_contains "$out" "this brief is too large to pass as an argument" \
    "the refusal did not name the oversized-brief cause"
  assert_contains "$out" "$HOME_DIR/data/$id/launch-brief.md" \
    "the refusal did not name the brief path"
  assert_contains "$out" "$ARG_LIMIT" \
    "the refusal did not name the argv limit"
  launch=$(launch_line "$LAUNCH_LOG")
  [ -z "$launch" ] || fail "the spawn sent a launch line despite refusing the oversized brief"
  pass "an oversized inline body refuses the spawn with a named error and no launch ($brief_bytes-byte brief)"
}

test_inline_harness_caps_the_body_and_names_the_truncation() {
  local rec id out status launch body body_bytes
  id='brief-argv-inline-cap-z1'
  rec=$(make_spawn_case brief-argv-inline-cap pi "$id")
  read_case_record "$rec"
  grow_brief "$HOME_DIR/data/$id/brief.md" 400000

  out=$(FM_SPAWN_BRIEF_INLINE_HARNESSES=pi \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a capped inline body must still launch"$'\n'"$out"

  body="$HOME_DIR/state/$id.brief-arg"
  [ -f "$body" ] || fail "the inline harness launch left no capped body at $body"
  body_bytes=$(wc -c < "$body")
  [ "$body_bytes" -lt "$ARG_LIMIT" ] || fail "capped inline body is $body_bytes bytes, above the argv cap"
  head -n 1 "$body" | grep -Fq "Read the brief at $HOME_DIR/data/$id/launch-brief.md and follow it exactly." \
    || fail "the capped inline body does not start with the brief path pointer"
  assert_grep "only its first 65536 bytes are inline" "$body" \
    "the capped inline body did not name its truncation"
  launch=$(launch_line "$LAUNCH_LOG")
  assert_contains "$launch" "< '$body'" \
    "the inline harness launch did not read its capped body from disk"
  pass "an inline harness caps the body at 65536 bytes, names the truncation, and launches"
}

test_oversized_brief_launches_through_the_path_pointer
test_small_brief_launch_is_unchanged
test_oversized_inline_body_fails_loudly_before_launch
test_inline_harness_caps_the_body_and_names_the_truncation
