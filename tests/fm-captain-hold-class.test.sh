#!/usr/bin/env bash
# Decision class on fm-captain-hold.sh hold.
# A missing class stays on the captain's board.
# Only an explicit --class fable leaves it, and the kill-switch file puts it back.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-class)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

show_task() {  # <home> <id>
  tasks_in "$1" show "$2"
}

class_hits() {  # <text> <needle>
  printf '%s' "$1" | grep -o -F -- "$2" | wc -l | tr -d ' '
}

home=$(make_home class-main)

run_captain "$home" hold d1-omit --title "Omitted class" --reason "pick a default" --repo sample \
  >/dev/null || fail "omitted class hold failed"
show=$(show_task "$home" d1-omit)
assert_contains "$show" 'Decision class: b' "omitted class did not record b"
assert_not_contains "$show" 'Decision class: fable' "omitted class recorded fable"
pass "omitted --class records Decision class: b"

run_captain "$home" hold d1-fable --title "Fable class" --reason "fable rules this" --repo sample \
  --class fable >/dev/null || fail "fable class hold failed"
show=$(show_task "$home" d1-fable)
assert_contains "$show" 'Decision class: fable' "explicit fable did not record fable"
assert_not_contains "$show" 'Decision class: b' "explicit fable also recorded b"
pass "--class fable records Decision class: fable"

run_captain "$home" hold d1-b --title "Class b" --reason "captain owns this" --repo sample \
  --class b >/dev/null || fail "class b hold failed"
show=$(show_task "$home" d1-b)
assert_contains "$show" 'Decision class: b' "explicit b did not record b"
pass "--class b records Decision class: b"

rc=0
run_captain "$home" hold d1-nope --title "Bad class" --reason "should not land" --repo sample \
  --class nope >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "invalid class"
if show_task "$home" d1-nope >/dev/null 2>&1; then
  fail "invalid class created a task"
fi
pass "invalid --class exits 2 and writes no task"

run_captain "$home" hold d1-re --title "Rehold" --reason "first ruling" --repo sample \
  --class fable >/dev/null || fail "seed fable hold failed"
run_captain "$home" hold d1-re --reason "back on the board" >/dev/null \
  || fail "re-hold without class failed"
show=$(show_task "$home" d1-re)
[ "$(class_hits "$show" 'Decision class:')" = 1 ] || fail "re-hold left more than one class line: $show"
assert_contains "$show" 'Decision class: b' "re-hold without class did not return to b"
assert_not_contains "$show" 'Decision class: fable' "re-hold without class kept fable"
pass "re-hold with no flag records Decision class: b"

run_captain "$home" hold d1-stay --title "Stay fable" --reason "still hers" --repo sample \
  --class fable >/dev/null || fail "stay seed failed"
run_captain "$home" hold d1-stay --reason "still hers" --class fable >/dev/null \
  || fail "fable re-hold failed"
show=$(show_task "$home" d1-stay)
[ "$(class_hits "$show" 'Decision class:')" = 1 ] || fail "fable re-hold duplicated the class line: $show"
assert_contains "$show" 'Decision class: fable' "fable re-hold dropped fable"
pass "re-hold with --class fable stays fable"

parent=$(make_home class-parent)
mate="$TMP_ROOT/class-mate-home"
mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
printf 'class-mate\n' > "$mate/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
  > "$mate/.fm-secondmate-parent"
cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
fakebin=$(fm_fakebin "$mate")
fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
channel="$parent/state/class-mate.status"

run_captain "$mate" hold d1-class --title "Parent ping" --reason "needs him" --repo sample \
  >/dev/null || fail "default mate hold failed"
assert_grep 'needs-decision [key=captain-hold-d1-class-1]: captain hold d1-class: needs him' \
  "$channel" "a default hold did not reach the parent channel"
run_captain "$mate" hold d1-class --reason "fable has it" --class fable >/dev/null \
  || fail "fable re-hold on the mate failed"
[ "$(grep -c '^needs-decision' "$channel")" = 1 ] \
  || fail "fable re-hold published another needs-decision: $(cat "$channel")"
show=$(show_task "$mate" d1-class)
assert_contains "$show" 'Decision class: fable' "mate fable re-hold did not record fable"
pass "default hold pings the parent and --class fable does not ping again"

: > "$home/config/decisions-to-aaron"
run_captain "$home" hold d1-kill --title "Kill switch" --reason "file is present" --repo sample \
  --class fable >/dev/null || fail "kill-switch hold failed"
show=$(show_task "$home" d1-kill)
assert_contains "$show" 'Decision class: b' "kill switch did not force class b"
assert_not_contains "$show" 'Decision class: fable' "kill switch still recorded fable"
pass "config/decisions-to-aaron forces Decision class: b"

printf 'pass 8 fail 0\n'
