#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# A relaunch on backend=orca rebinds only a terminal Orca's own inventory no
# longer lists: a listed terminal, an unreadable inventory, or a recorded Orca
# worktree that no longer resolves to the task's worktree all refuse before any
# terminal is created, and a proven-gone terminal is replaced by exactly one
# fresh terminal in the recorded worktree, which the task record rebinds to.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    state=ready
    [ -f "$DIR/orca-runtime-starting" ] && state=starting
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"%s"}}}\n' "$state"
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    handle=term-1
    [ -f "$DIR/orca-create-handle" ] && handle=$(cat "$DIR/orca-create-handle")
    printf 'create %s\n' "$*" >> "$DIR/orca-calls"
    printf '{"ok":true,"result":{"terminal":{"handle":"%s"}}}\n' "$handle"
    exit 0
    ;;
  "terminal list")
    printf 'list\n' >> "$DIR/orca-calls"
    [ -f "$DIR/orca-list-fails" ] && exit 1
    listed=$(cat "$DIR/orca-listed" 2>/dev/null)
    count=$(printf '%s' "$listed" | grep -o '"handle"' | wc -l | tr -d ' ')
    truncated=false
    [ -f "$DIR/orca-list-truncated" ] && truncated=true
    printf '{"ok":true,"result":{"terminals":[%s],"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"totalCount":%s,"truncated":%s}}\n' "$listed" "$count" "$truncated"
    exit 0
    ;;
  "worktree show")
    printf '{"ok":true,"result":{"worktree":{"path":"%s"}}}\n' "$(cat "$DIR/orca-worktree-path")"
    exit 0
    ;;
  "terminal close")
    printf 'close %s\n' "$*" >> "$DIR/orca-calls"
    printf '{"ok":true}\n'
    exit 0
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

# make_orca_relaunch_case <name> <id>: a recorded Orca task whose terminal
# term-old the fake inventory controls. Prints the case dir.
make_orca_relaunch_case() {
  local name=$1 id=$2 case_dir home proj wt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch against a recorded Orca task.

## Firstmate spec
Confirm the relaunch only replaces a terminal Orca no longer lists.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=scout"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-old"
  } > "$home/state/$id.meta"
  printf '%s\n' "$wt" > "$case_dir/orca-worktree-path"
  printf 'term-new\n' > "$case_dir/orca-create-handle"
  printf '%s\n' "$case_dir"
}

run_orca_relaunch() {  # <case-dir> <id>
  local case_dir=$1 id=$2 fb home
  home="$case_dir/home"
  fb=$(make_orca_fakebin "$case_dir")
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1
}

test_orca_relaunch_refuses_a_terminal_orca_still_lists() {
  local id=orca-relaunch-a2 case_dir out status
  case_dir=$(make_orca_relaunch_case listed "$id")
  printf '{"handle":"term-other"},{"handle":"term-old"}' > "$case_dir/orca-listed"
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  expect_code 1 "$status" "a relaunch must refuse while Orca still lists the terminal"$'\n'"$out"
  assert_contains "$out" "still exists" "the refusal should say the terminal still exists"
  assert_not_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create" "no terminal may be created while the old one is listed"
  [ "$(grep '^terminal=' "$case_dir/home/state/$id.meta" | cut -d= -f2-)" = term-old ] \
    || fail "a refused relaunch must leave the recorded terminal unchanged"
  pass "orca relaunch refuses while Orca still lists the recorded terminal"
}

test_orca_relaunch_refuses_when_the_inventory_cannot_be_read() {
  local id=orca-relaunch-a3 case_dir out status
  case_dir=$(make_orca_relaunch_case listfail "$id")
  : > "$case_dir/orca-list-fails"
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  expect_code 1 "$status" "an unreadable Orca inventory must refuse"$'\n'"$out"
  assert_contains "$out" "could not read Orca's terminal inventory" "the refusal should name the unreadable inventory"
  assert_not_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create" "an unreadable inventory must never be read as absence"
  pass "orca relaunch never reads an unreadable terminal inventory as a gone terminal"
}

test_orca_relaunch_refuses_before_the_runtime_is_ready() {
  local id=orca-relaunch-a6 case_dir out status
  case_dir=$(make_orca_relaunch_case starting "$id")
  : > "$case_dir/orca-listed"
  : > "$case_dir/orca-runtime-starting"
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  expect_code 1 "$status" "a relaunch must refuse while the Orca runtime is not ready"$'\n'"$out"
  assert_contains "$out" "could not read Orca's terminal inventory" "the refusal should name the unreadable inventory"
  assert_not_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create" "an inventory from a runtime that is not ready must never be read as absence"
  pass "orca relaunch never reads an empty inventory from a runtime that is not ready as a gone terminal"
}

test_orca_relaunch_refuses_a_truncated_inventory() {
  local id=orca-relaunch-a7 case_dir out status
  case_dir=$(make_orca_relaunch_case truncated "$id")
  printf '{"handle":"term-other"}' > "$case_dir/orca-listed"
  : > "$case_dir/orca-list-truncated"
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  expect_code 1 "$status" "a truncated Orca inventory must refuse"$'\n'"$out"
  assert_contains "$out" "could not read Orca's terminal inventory" "the refusal should name the unreadable inventory"
  assert_not_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create" "a truncated inventory must never be read as absence"
  pass "orca relaunch never reads a truncated terminal inventory as a gone terminal"
}

test_orca_relaunch_closes_its_fresh_terminal_when_it_refuses_after_creating_it() {
  local id=orca-relaunch-a8 case_dir out status plain
  case_dir=$(make_orca_relaunch_case abort "$id")
  : > "$case_dir/orca-listed"
  plain="$case_dir/plain-dir"
  mkdir -p "$plain"
  sed -i.bak "s|^worktree=.*|worktree=$plain|" "$case_dir/home/state/$id.meta"
  printf '%s\n' "$plain" > "$case_dir/orca-worktree-path"
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  expect_code 1 "$status" "a relaunch into a non-isolated worktree must refuse"$'\n'"$out"
  assert_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create " "the refusal under test must come after the fresh terminal is created"$'\n'"$out"
  assert_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "close terminal close --terminal term-new" "a refused relaunch must close the terminal it created"$'\n'"$out"
  [ "$(grep '^terminal=' "$case_dir/home/state/$id.meta" | tail -1 | cut -d= -f2-)" = term-old ] \
    || fail "a refused relaunch must leave the recorded terminal unchanged"
  pass "orca relaunch closes the fresh terminal it created when it refuses before rebinding the record"
}

test_orca_relaunch_refuses_a_worktree_that_resolves_elsewhere() {
  local id=orca-relaunch-a4 case_dir out status
  case_dir=$(make_orca_relaunch_case moved "$id")
  : > "$case_dir/orca-listed"
  mkdir -p "$case_dir/elsewhere"
  printf '%s\n' "$case_dir/elsewhere" > "$case_dir/orca-worktree-path"
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  expect_code 1 "$status" "a recorded Orca worktree that resolves elsewhere must refuse"$'\n'"$out"
  assert_contains "$out" "not task $id's recorded worktree" "the refusal should name the worktree mismatch"
  assert_not_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create" "no terminal may be created in another worktree"
  pass "orca relaunch refuses when the recorded Orca worktree no longer resolves to the task's worktree"
}

test_orca_relaunch_rebinds_a_gone_terminal_in_the_recorded_worktree() {
  local id=orca-relaunch-a5 case_dir out status wt
  case_dir=$(make_orca_relaunch_case gone "$id")
  : > "$case_dir/orca-listed"
  wt=$(grep '^worktree=' "$case_dir/home/state/$id.meta" | cut -d= -f2-)
  out=$(run_orca_relaunch "$case_dir" "$id"); status=$?
  assert_contains "$(cat "$case_dir/orca-calls" 2>/dev/null)" "create terminal create --worktree id:wt-1::$wt" \
    "the fresh terminal must be created in the recorded Orca worktree"$'\n'"$out"
  [ "$(grep -c '^create ' "$case_dir/orca-calls")" = 1 ] || fail "exactly one terminal must be created"$'\n'"$out"
  expect_code 0 "$status" "a relaunch of a terminal Orca no longer lists should succeed"$'\n'"$out"
  [ "$(grep '^terminal=' "$case_dir/home/state/$id.meta" | tail -1 | cut -d= -f2-)" = term-new ] \
    || fail "the record must rebind to the fresh terminal"$'\n'"$(cat "$case_dir/home/state/$id.meta")"
  [ "$(grep '^orca_worktree_id=' "$case_dir/home/state/$id.meta" | tail -1 | cut -d= -f2-)" = "wt-1::$wt" ] \
    || fail "the record must keep its Orca worktree id"
  [ "$(grep '^worktree=' "$case_dir/home/state/$id.meta" | tail -1 | cut -d= -f2-)" = "$wt" ] \
    || fail "the record must keep its worktree"
  pass "orca relaunch replaces a terminal Orca no longer lists with one fresh terminal in the recorded worktree"
}

test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_refuses_a_terminal_orca_still_lists
test_orca_relaunch_refuses_when_the_inventory_cannot_be_read
test_orca_relaunch_refuses_before_the_runtime_is_ready
test_orca_relaunch_refuses_a_truncated_inventory
test_orca_relaunch_closes_its_fresh_terminal_when_it_refuses_after_creating_it
test_orca_relaunch_refuses_a_worktree_that_resolves_elsewhere
test_orca_relaunch_rebinds_a_gone_terminal_in_the_recorded_worktree

echo "# all fm-spawn-orca-worktree tests passed"
