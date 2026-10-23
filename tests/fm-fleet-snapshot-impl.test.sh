#!/usr/bin/env bash
# tests/fm-fleet-snapshot-impl.test.sh - the Python per-task pass
# (bin/fm-fleet-snapshot.py) against the original bash pass
# (FM_SNAPSHOT_IMPL=bash) of bin/fm-fleet-snapshot.sh.
#
# Pins, through the real executable over one fixture home:
#   1. Parity: both passes print byte-identical normalized JSON in --json and
#      --secondmate-home-summary modes over a fixture that exercises every
#      native classification path (busy, idle, malformed, gen-mismatch, and
#      untrusted busy records; status-log fallbacks with keys, timestamps,
#      correlation tokens, and pauses; a ship worktree at detached HEAD; a
#      gone worktree; a missing target; an Orca terminal absent from the
#      inventory; PR and report hints; open decisions) and every delegated one
#      (a ship branch with a run, including one older than the owner's bounded
#      listing, a ship branch with no run, a Grok rendered-tail harness, a
#      local secondmate, a remote secondmate).
#   2. The runs ledger is read once per repository and reused inside
#      FM_SNAPSHOT_RUNS_CACHE_SECS, and refreshed when the window is 0, while
#      every ship branch still gets its own fresh `axi status` read.
#   3. A reused open-decision fold stays identical to the bash pass's fresh
#      fold, and an appended decision invalidates it.
#   4. An unknown FM_SNAPSHOT_IMPL is refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAP="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-impl)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
FAKE="$TMP_ROOT/fake"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$DATA" "$FAKE" "$FAKEBIN" "$HOME_DIR/config" "$HOME_DIR/projects"
: > "$FAKE/calls"

cat > "$FAKEBIN/orca" <<'SH'
#!/usr/bin/env bash
set -u
F=${FM_FAKE:?}
printf 'orca %s\n' "$*" >> "$F/calls"
case "${1:-} ${2:-}" in
  "terminal list")
    printf '{"ok":true,"result":{"terminals":['
    sep=
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      printf '%s{"handle":"%s"}' "$sep" "$h"; sep=,
    done < "$F/orca-live"
    printf '],"truncated":false}}\n'
    ;;
  "terminal read")
    term=
    while [ $# -gt 0 ]; do [ "$1" = --terminal ] && term=$2; shift; done
    if grep -Fxq "$term" "$F/orca-live"; then
      printf '{"ok":true,"result":{"terminal":{"tail":["working on it","esc to interrupt"]}}}\n'
    else
      printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}\n'
      exit 1
    fi
    ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
F=${FM_FAKE:?}
printf 'no-mistakes %s\n' "$*" >> "$F/calls"
case "${1:-} ${2:-}" in
  "runs --limit")
    total=$(grep -c . "$F/runs")
    if [ "$3" -lt "$total" ]; then
      head -n "$3" "$F/runs"
      printf '\n  (%s more runs, use --limit to see more)\n' "$((total - $3))"
    else
      cat "$F/runs"
    fi
    ;;
  "axi ")
    # The bare identity overview fm-crew-state.sh selects a branch's run from,
    # built from the same ledger the plain listing serves.
    total=$(grep -c . "$F/runs")
    printf 'count: %s of %s total\nruns[%s]{id,branch,status,head,pr}:\n' "$total" "$total" "$total"
    i=0
    while read -r st br sha _ _ pr; do
      [ -n "$st" ] || continue
      i=$((i + 1))
      case "$br" in fm/run-branch) id=r1 ;; fm/old-run) id=r0 ;; *) id=r-$i ;; esac
      printf '  "%s",%s,%s,%s,"%s"\n' "$id" "$br" "$st" "$sha" "${pr:-}"
    done < "$F/runs"
    ;;
  "axi status")
    head=$(git rev-parse HEAD 2>/dev/null)
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
    if [ "$branch" = fm/run-branch ]; then
      printf 'run:\n  id: r1\n  branch: %s\n  head: %s\n  status: completed\n  outcome: checks-passed\n' "$branch" "$head"
    elif [ "$branch" = fm/old-run ]; then
      printf 'run:\n  id: r0\n  branch: %s\n  head: %s\n  status: completed\n  outcome: failed\n' "$branch" "$head"
    else
      printf 'run:\n  id: r9\n  branch: fm/other\n  head: 0000000\n  status: running\n'
    fi
    ;;
esac
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    case "$*" in
      *-a*) printf 'fmses:fm-mate\n' ;;
      *) printf 'fm-mate\n' ;;
    esac
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'zsh\n' ;;
      *pane_pid*) printf '1\n' ;;
      *) printf 'fakepane\n' ;;
    esac
    ;;
  capture-pane) printf 'idle\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/orca" "$FAKEBIN/no-mistakes" "$FAKEBIN/tmux"

# --- fixture home -------------------------------------------------------------

REPO="$TMP_ROOT/repo"
fm_git_init_commit "$REPO" >/dev/null 2>&1
# A remote-tracking ref holds the shared base, so a ship's done claim passes the
# named-head reachability gate (bin/fm-dod-lib.sh) on both passes.
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse HEAD)"
add_worktree() {  # <name> <branch> -> echoes path
  local wt="$TMP_ROOT/wt-$1"
  git -C "$REPO" worktree add --quiet -b "$2" "$wt" >/dev/null 2>&1
  printf '%s\n' "$wt"
}

orca_task() {  # <id> <harness> <kind> <worktree> [extra meta...]
  local id=$1 harness=$2 kind=$3 wt=$4
  shift 4
  fm_write_meta "$STATE/$id.meta" "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$REPO" "harness=$harness" "kind=$kind" "mode=no-mistakes" "yolo=off" \
    "spawn_gen=s-$id" "backend=orca" "orca_worktree_id=wt-$id" "terminal=term-$id" "$@"
  printf 'term-%s\n' "$id" >> "$FAKE/orca-live"
}

busy_record() {  # <id> <state> <source> [gen-in-record]
  printf 'g-%s\n' "$1" > "$STATE/$1.busy-gen"
  printf 'v1 gen=%s seq=3 state=%s source=%s event=x ts=1700000000\n' "${4:-g-$1}" "$2" "$3" \
    > "$STATE/$1.busy-state"
}

: > "$FAKE/orca-live"
WT_SCOUT=$(add_worktree scout fm/scout)
WT_SHIP=$(add_worktree ship fm/ship-native)
WT_RUN=$(add_worktree run fm/run-branch)
WT_OLD=$(add_worktree old fm/old-run)
WT_DETACHED=$(add_worktree detached fm/detached)
git -C "$WT_SCOUT" checkout -q --detach
git -C "$WT_DETACHED" checkout -q --detach

orca_task busy pi scout "$WT_SCOUT"
busy_record busy busy pi-ext
orca_task idle pi ship "$WT_SHIP" "pr=https://github.com/example/repo/pull/7"
busy_record idle idle pi-ext
printf 'working: first\n2026-10-16T01:02Z done: PR https://github.com/example/repo/pull/9 checks green\n\n' \
  > "$STATE/idle.status"
orca_task keyed claude scout "$WT_SCOUT"
busy_record keyed idle claude-hook
printf '%s\n' 'needs-decision [key=api-shape]: pick a shape' \
  'blocked: [key=creds] need a token' 'resolved [key=creds]: token issued' \
  'needs-decision corr=0123456789abcdef [key=texte]: wording?' \
  'paused [key=wait]: waiting on the vendor' > "$STATE/keyed.status"
orca_task malformed pi scout "$WT_SCOUT"
printf 'g-malformed\n' > "$STATE/malformed.busy-gen"
printf 'v1 gen=g-malformed state=busy\n' > "$STATE/malformed.busy-state"
orca_task stalegen pi scout "$WT_SCOUT"
busy_record stalegen busy pi-ext g-old
orca_task untrusted pi scout "$WT_SCOUT"
busy_record untrusted busy claude-hook
orca_task norecord claude scout "$WT_SCOUT"
printf 'done: finished\n' > "$STATE/norecord.status"
orca_task resolvedonly pi scout "$WT_SCOUT"
busy_record resolvedonly idle pi-ext
printf 'resolved: answered\n' > "$STATE/resolvedonly.status"
orca_task gone pi scout "$WT_SCOUT"
orca_task shipgone pi ship "$WT_SHIP"
sed -i.bak -e '/^term-gone$/d' -e '/^term-shipgone$/d' "$FAKE/orca-live" && rm -f "$FAKE/orca-live.bak"
orca_task detached pi ship "$WT_DETACHED"
busy_record detached idle pi-ext
printf 'done: detached ship finished\n' > "$STATE/detached.status"
orca_task wtgone pi ship "$TMP_ROOT/never-created"
fm_write_meta "$STATE/notarget.meta" "endpoint_task_id=notarget" "worktree=$WT_SCOUT" \
  "harness=pi" "kind=scout" "backend=orca"
orca_task report pi scout "$WT_SCOUT"
busy_record report idle pi-ext
mkdir -p "$DATA/report"
printf '# findings\n' > "$DATA/report/report.md"
printf 'done: report written\n' > "$STATE/report.status"
orca_task run pi ship "$WT_RUN"
printf 'working: validating\n' > "$STATE/run.status"
orca_task oldrun pi ship "$WT_OLD"
busy_record oldrun idle pi-ext
orca_task grok grok scout "$WT_SCOUT"
fm_write_secondmate_meta "$STATE/mate.meta" "$HOME_DIR" "fmses:fm-mate" "alpha, beta,,gamma" pi
printf 'working: routing\n' > "$STATE/mate.status"
fm_write_meta "$STATE/far.meta" "window=fm-far" "endpoint_task_id=far" "worktree=/remote/far" \
  "harness=pi" "kind=secondmate" "remote_host=far.example" "remote_root=/srv/fm" \
  "remote_backend=tmux" "remote_target=fmses:fm-far" "home=/srv/fm/far"
printf 'done: remote mate idle\n' > "$STATE/far.status"

RUN_SHA=$(git -C "$WT_RUN" rev-parse --short HEAD)
printf 'completed fm/run-branch %s 2026-10-15 10:00 https://github.com/example/repo/pull/3\n' "$RUN_SHA" \
  > "$FAKE/runs"
printf 'failed fm/elsewhere %s 2026-10-14 09:00\n' "$RUN_SHA" >> "$FAKE/runs"
# Older than the owner's bounded listing (FM_CREW_STATE_RUNS_LIMIT=2 below), so
# only the delegated owner's fresh no-mistakes reads find this branch's failed run.
printf 'failed fm/old-run %s 2026-09-01 08:00\n' "$(git -C "$WT_OLD" rev-parse --short HEAD)" >> "$FAKE/runs"

# Generous read bounds: a parity reference that times out on a loaded host
# would compare a bound, not a classification.
snapshot() {  # <impl> <mode> [env...]
  local impl=$1 mode=$2
  shift 2
  env PATH="$FAKEBIN:$PATH" FM_FAKE="$FAKE" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SNAPSHOT_NOW=2026-10-16T05:00:00Z FM_SNAPSHOT_NOW_EPOCH=1792126800 \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=60 FM_SNAPSHOT_PREFETCH_TIMEOUT=900 \
    FM_SNAPSHOT_IMPL="$impl" FM_SNAPSHOT_SECONDMATES=0 FM_CREW_STATE_RUNS_LIMIT=2 "$@" "$SNAP" "$mode"
}

test_parity_json_and_home_summary() {
  local mode b p
  for mode in --json --secondmate-home-summary; do
    b="$TMP_ROOT/bash$mode.json"
    p="$TMP_ROOT/python$mode.json"
    snapshot bash "$mode" > "$b.raw" 2>"$b.err" || fail "bash pass failed in $mode: $(cat "$b.err")"
    snapshot python "$mode" > "$p.raw" 2>"$p.err" || fail "python pass failed in $mode: $(cat "$p.err")"
    jq -S . "$b.raw" > "$b" || fail "bash $mode output is not JSON"
    jq -S . "$p.raw" > "$p" || fail "python $mode output is not JSON"
    if ! cmp -s "$b" "$p"; then
      fail "the two passes diverge in $mode:"$'\n'"$(diff "$b" "$p" | head -60)"
    fi
  done
  # The fixture must really exercise the paths it claims, or parity is vacuous.
  local states
  states=$(jq -r '.tasks[] | "\(.id)=\(.current_state.state)/\(.current_state.source)"' "$TMP_ROOT/python--json.json")
  for want in busy=working/pane idle=done/status-log keyed=parked/status-log \
    malformed=unknown/pane stalegen=unknown/pane untrusted=unknown/pane norecord=unknown/pane \
    resolvedonly=unknown/none gone=unknown/none shipgone=unknown/none detached=done/status-log \
    wtgone=unknown/none notarget=unknown/none \
    report=done/status-log run=done/run-step oldrun=failed/run-step mate=working/status-log far=unknown/none; do
    case $'\n'"$states"$'\n' in
      *$'\n'"$want"$'\n'*) ;;
      *) fail "fixture path not exercised: expected $want in"$'\n'"$states" ;;
    esac
  done
  [ "$(jq '[.tasks[] | select(.id=="keyed") | .hints.open_decisions[]] | length' "$TMP_ROOT/python--json.json")" -ge 1 ] \
    || fail "the keyed fixture should carry open decisions"
  pass "fleet snapshot: the python and bash per-task passes print identical JSON in both modes"
}

test_runs_ledger_cached_per_repo() {
  local n a
  rm -rf "$STATE/snapshot-cache"
  : > "$FAKE/calls"
  snapshot python --json >/dev/null 2>&1 || fail "first cached snapshot failed"
  snapshot python --json >/dev/null 2>&1 || fail "second cached snapshot failed"
  n=$(grep -c '^no-mistakes runs' "$FAKE/calls")
  [ "$n" = 1 ] || fail "the runs listing should be read once per repo inside the cache window, read $n times"
  # run, oldrun, idle, and shipgone sit on branches; each snapshot reads each
  # fresh. A selected run's follow-up `axi status --run <id>` read is not counted.
  a=$(grep -cx 'no-mistakes axi status' "$FAKE/calls")
  [ "$a" = 8 ] || fail "every ship branch needs its own fresh axi status read per snapshot, saw $a"
  : > "$FAKE/calls"
  snapshot python --json FM_SNAPSHOT_RUNS_CACHE_SECS=0 >/dev/null 2>&1 || fail "uncached snapshot failed"
  n=$(grep -c '^no-mistakes runs' "$FAKE/calls")
  [ "$n" = 1 ] || fail "a zero cache window should refresh the listing, read $n times"
  pass "fleet snapshot: one runs-ledger read per repo is reused inside FM_SNAPSHOT_RUNS_CACHE_SECS"
}

keyed_decisions() {  # <impl>
  snapshot "$1" --json 2>/dev/null \
    | jq -S '[.tasks[] | select(.id=="keyed") | .hints.open_decisions[]]'
}

test_fold_reuse_matches_and_invalidates() {
  local warm cached fresh
  rm -rf "$STATE/snapshot-cache"
  warm=$(keyed_decisions python)
  cached=$(keyed_decisions python)
  fresh=$(keyed_decisions bash)
  [ -n "$fresh" ] && [ "$fresh" != "[]" ] || fail "the keyed fixture should fold open decisions"
  [ -f "$STATE/snapshot-cache/fold/keyed" ] || fail "a finished fold should be kept for reuse"
  [ "$warm" = "$fresh" ] && [ "$cached" = "$fresh" ] \
    || fail "a reused fold diverged from the bash pass:"$'\n'"cached=$cached"$'\n'"bash=$fresh"
  printf 'needs-decision [key=late-call]: appended after the cached fold\n' >> "$STATE/keyed.status"
  cached=$(keyed_decisions python)
  fresh=$(keyed_decisions bash)
  assert_contains "$cached" "late-call" "an appended decision must invalidate the cached fold"
  [ "$cached" = "$fresh" ] || fail "the refolded result diverged from the bash pass"
  pass "fleet snapshot: a reused open-decision fold matches a fresh one and an appended decision invalidates it"
}

test_unknown_impl_refused() {
  local rc
  snapshot nope --json >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown FM_SNAPSHOT_IMPL should be refused"
  pass "fleet snapshot: an unknown FM_SNAPSHOT_IMPL is refused"
}

test_parity_json_and_home_summary
test_runs_ledger_cached_per_repo
test_fold_reuse_matches_and_invalidates
test_unknown_impl_refused
