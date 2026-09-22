#!/usr/bin/env bash
# tests/fm-roster.test.sh - behavior tests for bin/fm-roster.sh.
#
# The contract under test is the captain-facing roster: one row per supervised
# task with a plain-words "doing now", the model string, the real context
# figure from the pane footer, and an estimate whose basis is stated; then the
# unsupervised surfaces with the same doing-now / model / estimate columns;
# then a totals line. The other half is the bounded read: a 5 MB status log
# must not slow the report or hide its newest line. Every host-facing source
# (pane reads, process scan, Orca terminal list) is answered by a fixture stub
# here, so the suite is deterministic and never touches the live host.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROSTER="$ROOT/bin/fm-roster.sh"
TMP_ROOT=$(fm_test_tmproot fm-roster)
NOW=1790033000
UUID_WORKER=11111111-1111-4111-8111-111111111111
UUID_STRAY=22222222-2222-4222-8222-222222222222
UUID_GROK=33333333-3333-4333-8333-333333333333

# Three live processes stand in for resumed cmux-app sessions: one working in
# a supervised task's recorded worktree (its own relaunched worker), one stray
# Claude session, and one stray grok session.
SLEEPERS=()
cleanup_sleepers() { kill "${SLEEPERS[@]}" 2>/dev/null; fm_test_cleanup; }
trap cleanup_sleepers EXIT
start_sleeper() {  # <cwd>; appends the pid to SLEEPERS
  (cd "$1" && exec sleep 300) >/dev/null 2>&1 &
  SLEEPERS+=("$!")
}

build_home() {
  local home="$TMP_ROOT/home"
  mkdir -p "$home/state" "$home/data/cmux-takeover/status" \
    "$home/projects/alpha" "$home/projects/beta" "$home/claude-projects/proj" \
    "$home/grok-sessions/ws/$UUID_GROK" "$home/data/scout" \
    "$home/wt/alpha-worker" "$home/wt/stray-claude" "$home/wt/stray-grok"

  fm_write_meta "$home/state/ship-working.meta" \
    "project=$home/projects/alpha" "worktree=$home/wt/alpha-worker" \
    "harness=pi" "terminal=term_live" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca" "spawn_gen=s$((NOW - 3600)).1.1"
  fm_write_meta "$home/state/ship-done-pr.meta" \
    "project=$home/projects/alpha" "harness=claude" "model=opus[1m]" \
    "effort=high" "kind=ship" "backend=orca"
  fm_write_meta "$home/state/ship-done-merged.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=fireworks-us/accounts/fireworks/models/deepseek-v4p1-flash" \
    "effort=default" "kind=ship" "backend=orca"
  fm_write_meta "$home/state/ship-blocked.meta" \
    "project=$home/projects/beta" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca"
  fm_write_meta "$home/state/lane.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca"
  fm_write_meta "$home/state/scout.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=scout" "backend=orca"
  fm_write_meta "$home/state/scout-noreport.meta" \
    "project=$home/projects/alpha" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=scout" "backend=orca"
  fm_write_meta "$home/state/ship-nostatus.meta" \
    "harness=pi" "model=openrouter-named/deepseek/deepseek-v4.1-flash" \
    "effort=high" "kind=ship" "backend=orca"
  fm_write_meta "$home/state/big.meta" \
    "project=$home/projects/beta" "harness=pi" \
    "model=openrouter-named/deepseek/deepseek-v4.1-flash" "effort=high" \
    "kind=ship" "backend=orca" "spawn_gen=s$((NOW - 3600)).2.2"

  printf 'working: implementing the parser\n' > "$home/state/ship-working.status"
  printf 'done: PR https://example.invalid/alpha/pull/1 checks green\n' \
    > "$home/state/ship-done-pr.status"
  printf 'done: PR https://example.invalid/alpha/pull/2 checks green\n' \
    > "$home/state/ship-done-merged.status"
  printf 'blocked: waiting on the captain to supply the API credential\n' \
    > "$home/state/ship-blocked.status"
  printf 'paused [key=await-tick]: idle until next tick at 07:15Z - nothing in flight\n' \
    > "$home/state/lane.status"
  printf 'working: triaging the crash cluster\n' > "$home/state/scout.status"
  printf 'working: triaging the second cluster\n' > "$home/state/scout-noreport.status"

  printf '# scout report\n' > "$home/data/scout/report.md"

  # The Orca stub answers the pane read for term_live with a Pi footer whose
  # cache-hit token (CH99.9%) precedes the real context token (58.7%/1.0M),
  # and the terminal list with that bound terminal plus one stray pane.
  cat > "$home/fake-orca" <<'ORCA'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal read")
    printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term_live","tail":["----","~/wt/alpha-worker (fm/parser)","up5.4M dn371k R124M CH99.9% $2.290 58.7%/1.0M   (fireworks-us) deepseek-v4p1-flash - high"]}}}'
    ;;
  "terminal list")
    printf '%s\n' '{"ok":true,"result":{"terminals":[{"handle":"term_live","title":"pi - parser","agentIdentity":"pi","preview":"Working","worktreePath":"/x/alpha-worker","lastOutputAt":1790032940000},{"handle":"term_00000000-0000-4000-8000-000000000002","title":"term_00000000-0000-4000-8000-000000000002","agentIdentity":"pi","preview":"vault deletions: 26\nTook 420.7s\n── ⠙ Working ────","worktreePath":"/x/stray-pane","lastOutputAt":1790032400000}]}}'
    ;;
  *) exit 1 ;;
esac
ORCA
  chmod +x "$home/fake-orca"

  # Resumed cmux-app sessions: a Claude log opens with the harness caveat and a
  # slash-command block before the captain's request; a grok log opens with the
  # <user_info> preamble and synthetic reminders before the first <user_query>.
  cat > "$home/claude-projects/proj/$UUID_STRAY.jsonl" <<'JSONL'
{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"}}
{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nThe user opened the file.\n</system-reminder>fix the flaky deploy"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}
JSONL
  cat > "$home/grok-sessions/ws/$UUID_GROK/chat_history.jsonl" <<'JSONL'
{"type": "user", "content": "<user_info>\nOS Version: macos\nShell: /bin/zsh\n</user_info>"}
{"type": "user", "content": "<system-reminder>\nThe following skills are available.\n</system-reminder>", "synthetic_reason": "system_reminder"}
{"type": "user", "content": "<user_query>\ncheck the vault seal\n</user_query>"}
{"type": "assistant", "content": "checking"}
JSONL

  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] ship-working - alpha: implement the parser (repo: alpha) (kind: ship) (since 2026-09-21)
- [ ] lane - alpha lane takeover: keep the lane alive (repo: alpha) (kind: ship) (since 2026-09-01)
- [ ] scout - mobile crash triage (repo: alpha) (kind: scout) (since 2026-09-21)

MD

  # Done ship tasks: duration is the dispatch brief mtime to the newest other
  # entry in data/<id>/. A directory holding only briefs has no duration, and
  # the Done section is newest-first, so the sample window is the first 20
  # measurable entries in file order: twenty at 4h, then twelve stale 100h
  # entries that must not enter the median.
  python3 - "$home" "$NOW" <<'PY'
import os
import sys

home, now = sys.argv[1], float(sys.argv[2])


def done_dir(task_id, hours, artifact=True):
    path = os.path.join(home, "data", task_id)
    os.makedirs(path, exist_ok=True)
    brief = os.path.join(path, "launch-brief.md")
    with open(brief, "w") as handle:
        handle.write("brief\n")
    start = now - hours * 3600 - 10
    os.utime(brief, (start, start))
    if artifact:
        report = os.path.join(path, "pr.md")
        with open(report, "w") as handle:
            handle.write("pr\n")
        os.utime(report, (now - 10, now - 10))
    os.utime(path, (now, now))


done_dir("done-briefonly", 0, artifact=False)
for index in range(20):
    done_dir("done-recent-%02d" % index, 4)
for index in range(12):
    done_dir("done-old-%02d" % index, 100)

lines = ["## Done"]
lines.append("- [x] done-briefonly - alpha brief only (repo: alpha) (kind: ship) (merged 2026-09-21)")
lines.append("- [x] ship-done-merged - alpha shipped (repo: alpha) (kind: ship) (merged 2026-09-21)")
for index in range(20):
    lines.append("- [x] done-recent-%02d - alpha work (repo: alpha) (kind: ship) (merged 2026-09-20)" % index)
for index in range(12):
    lines.append("- [x] done-old-%02d - alpha old work (repo: alpha) (kind: ship) (merged 2026-08-01)" % index)
with open(os.path.join(home, "data", "backlog.md"), "a") as handle:
    handle.write("\n".join(lines) + "\n")

# The 5 MB synthetic status log: its newest line must be found and the report
# must stay fast, which only holds if the reader takes a tail, not the file.
path = os.path.join(home, "state", "big.status")
line = b"working: filler line that must never be the newest\n"
target = 5 * 1024 * 1024
with open(path, "wb") as handle:
    written = 0
    while written < target - len(line):
        handle.write(line)
        written += len(line)
    handle.write(b"working: the big-log newest line\n")

heartbeat = os.path.join(home, "data", "cmux-takeover", "status", "v3-ak.json")
with open(heartbeat, "w") as handle:
    handle.write("{}\n")
os.utime(heartbeat, (now - 7200, now - 7200))
PY

  # Migrated surfaces: "big" is a whole task-id token of the live task "big";
  # "work" is only a substring of "ship-working" and so has no live task.
  cat > "$home/data/cmux-takeover/expected-loops.json" <<'JSON'
{
  "schema": "fixture",
  "surfaces": {
    "aaaa": {"surface": "zzz-supervised-by-task", "term": "term_live", "slug": "live-surface", "firstmate_task": "ship-working"},
    "bbbb": {"surface": "zzz-supervised-by-token", "term": "term_none", "slug": "big", "firstmate_task": null},
    "cccc": {"surface": "V3 AK", "term": "term_dead", "slug": "v3-ak", "firstmate_task": null,
             "expected": [{"kind": "cron", "sched": "41 * * * *", "what": "Run-20 drive heartbeat"}, {"kind": "cron", "sched": "23 * * * *", "what": "Run-20 resume drive"}]},
    "dddd": {"surface": "Orphan surface", "term": "term_orphan", "slug": "orphan", "firstmate_task": null},
    "eeee": {"surface": "zzz-substring-only", "term": "term_sub", "slug": "work", "firstmate_task": null}
  }
}
JSON

  printf '%s\n' "$home"
}

HOME_DIR=$(build_home)

start_sleeper "$HOME_DIR/wt/alpha-worker"
start_sleeper "$HOME_DIR/wt/stray-claude"
start_sleeper "$HOME_DIR/wt/stray-grok"
PID_WORKER=${SLEEPERS[0]} PID_STRAY=${SLEEPERS[1]} PID_GROK=${SLEEPERS[2]}
cat > "$HOME_DIR/fake-ps" <<PS
#!/usr/bin/env bash
printf '%s\n' \\
  '$PID_WORKER /usr/local/bin/claude --dangerously-skip-permissions --resume $UUID_WORKER' \\
  '$PID_STRAY claude --resume $UUID_STRAY' \\
  '$PID_GROK grok -r $UUID_GROK' \\
  '1 /sbin/launchd'
PS
chmod +x "$HOME_DIR/fake-ps"

run_roster() {  # <home>
  local home=$1
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_ROSTER_PEEK_CMD="" \
    FM_ROSTER_ORCA_CMD="$home/fake-orca" \
    FM_ROSTER_PS_CMD="$home/fake-ps" \
    FM_ROSTER_NOW_EPOCH="$NOW" \
    FM_ROSTER_CLAUDE_PROJECTS="$home/claude-projects" \
    FM_ROSTER_GROK_SESSIONS="$home/grok-sessions" \
    "$ROSTER"
}

# A read-only report must not create, remove, or rewrite anything under the home.
before=$(find "$HOME_DIR" -type f | sort)
start=$(date +%s)
out=$(run_roster "$HOME_DIR") || fail "fm-roster.sh exited non-zero"
elapsed=$(( $(date +%s) - start ))
after=$(find "$HOME_DIR" -type f | sort)

[ "$before" = "$after" ] || fail "fm-roster.sh changed files under the home"

assert_contains "$out" "UNDER FIRSTMATE SUPERVISION" "the supervised table is missing"
assert_contains "$out" "NOT UNDER SUPERVISION" "the unsupervised table is missing"
assert_contains "$out" "Totals:" "the totals line is missing"

# Supervised rows.
assert_contains "$out" "working: implementing the parser" "the working task's doing-now line is missing"
assert_contains "$out" "pi / deepseek-v4.1-flash / high" "the model column is not harness/model/effort"
assert_contains "$out" "implementing (~3h" "the working ship estimate is missing"
assert_contains "$out" "median 4h of 20 done" "the estimate basis is not the first 20 measurable Done ships"
assert_contains "$out" "claude / opus[1m] / high" "the Claude model string is wrong"
assert_contains "$out" "idle until 07:15Z" "the standing lane's doing-now line is wrong"
assert_contains "$out" "standing - no end; next tick 07:15Z" "the standing lane has no estimate"
assert_contains "$out" "waiting on firstmate: waiting on the captain to supply the API credential" \
  "the blocked task is not mapped to waiting on firstmate"
assert_contains "$out" "blocked on firstmate" "the blocked task's estimate is missing"
assert_contains "$out" "PR open, awaiting merge" "the open PR is not reported as awaiting merge"
assert_contains "$out" "awaiting cleanup" "the merged task is not reported as awaiting cleanup"
assert_contains "$out" "report written" "the scout with a report is not marked written"
assert_contains "$out" "report due" "the scout without a report is not marked due"
assert_contains "$out" "setting up" "the no-status task is not reported as setting up"
assert_contains "$out" "(no status yet)" "the no-status task has no doing-now placeholder"
assert_contains "$out" "the big-log newest line" "the 5 MB status log's newest line was not read"

# CTX% is the Pi footer's context token, never its cache-hit token.
assert_contains "$out" "58.7%" "the context column does not show the pane's context figure"
assert_not_contains "$out" "99.9%" "the context column shows the cache-hit figure"

# The bounded read is the point of the 5 MB fixture.
[ "$elapsed" -le 20 ] || fail "the report took ${elapsed}s on a 5 MB status log"

# Unsupervised rows carry doing-now / model / estimate like supervised rows.
assert_contains "$out" "DOING NOW" "the unsupervised table lacks a doing-now column"
assert_contains "$out" "migrated" "the migrated surface source is missing"
assert_contains "$out" "V3 AK" "the migrated surface with no task is missing"
assert_contains "$out" "Run-20 drive heartbeat; Run-20 resume drive" "the migrated surface does not show its expected loop"
assert_contains "$out" "unsupervised - no estimate; relaunch item queued" "the migrated surface estimate is missing"
assert_contains "$out" "Orphan surface" "the unmatched expected-loop entry is missing"
assert_contains "$out" "zzz-substring-only" "a surface whose slug is only a substring of a task id was hidden"
assert_contains "$out" "2.0h" "the migrated surface heartbeat age is missing"
assert_not_contains "$out" "zzz-supervised-by-task" "a surface linked to a live task was listed as unsupervised"
assert_not_contains "$out" "zzz-supervised-by-token" "a surface matched by task-id token was listed as unsupervised"
assert_not_contains "$out" "cmux-surfaces-rehome" "an internal backlog id leaked into the roster"

# Resumed cmux-app sessions: the supervised task's own worker is skipped, and
# the strays show the captain's request rather than harness scaffolding.
assert_not_contains "$out" "alpha-worker" "a supervised task's relaunched worker was listed as unsupervised"
assert_contains "$out" "stray-claude" "the stray Claude session is missing"
assert_contains "$out" "fix the flaky deploy" "the stray Claude session does not show its opening request"
assert_contains "$out" "claude via pool" "the stray Claude session has no model cell"
assert_contains "$out" "stray-grok" "the stray grok session is missing"
assert_contains "$out" "check the vault seal" "the stray grok session does not show its opening request"
assert_not_contains "$out" "<local-command-caveat>" "the Claude caveat block leaked into the roster"
assert_not_contains "$out" "<command-name>" "the slash-command block leaked into the roster"
assert_not_contains "$out" "<system-reminder>" "a system-reminder block leaked into the roster"
assert_not_contains "$out" "<user_info>" "the grok user_info preamble leaked into the roster"

# Orca terminals bound to no task show their agent and last screen line.
assert_contains "$out" "stray-pane" "the unbound Orca terminal is missing"
assert_contains "$out" "pi: Working" "the unbound Orca terminal does not show its agent and last line"
assert_not_contains "$out" "pi - parser" "the terminal bound to a supervised task was listed as unbound"

# Without FM_HOME, a run from a linked task worktree reports the primary
# checkout that holds state/*.meta, not the worktree's own empty root.
fm_git_worktree "$TMP_ROOT/primary" "$TMP_ROOT/linked" fm/roster-test
mkdir -p "$TMP_ROOT/primary/state" "$TMP_ROOT/primary/data" "$TMP_ROOT/linked/bin"
fm_write_meta "$TMP_ROOT/primary/state/primary-task.meta" \
  "harness=pi" "model=openrouter-named/deepseek/deepseek-v4.1-flash" \
  "effort=high" "kind=ship" "backend=orca"
printf 'working: the primary home task\n' > "$TMP_ROOT/primary/state/primary-task.status"
ln -s "$ROSTER" "$TMP_ROOT/linked/bin/fm-roster.sh"
linked_out=$(env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_ROSTER_PEEK_CMD="" FM_ROSTER_ORCA_CMD="" FM_ROSTER_PS_CMD="" FM_ROSTER_NOW_EPOCH="$NOW" \
  "$TMP_ROOT/linked/bin/fm-roster.sh") \
  || fail "fm-roster.sh failed from a linked worktree without FM_HOME"
assert_contains "$linked_out" "primary-task" "the linked-worktree run did not report the primary home's task"
assert_contains "$linked_out" "the primary home task" "the linked-worktree run did not read the primary home's status"

# A clean Home with nothing running still renders both empty tables and exits 0.
empty_home="$TMP_ROOT/empty"
mkdir -p "$empty_home/state" "$empty_home/data"
empty_out=$(FM_HOME="$empty_home" FM_STATE_OVERRIDE="$empty_home/state" \
  FM_DATA_OVERRIDE="$empty_home/data" FM_ROSTER_PEEK_CMD="" FM_ROSTER_ORCA_CMD="" \
  FM_ROSTER_PS_CMD="" FM_ROSTER_NOW_EPOCH="$NOW" "$ROSTER") \
  || fail "fm-roster.sh failed on an empty home"
assert_contains "$empty_out" "(no supervised tasks in this home)" "the empty supervised table has no placeholder"
assert_contains "$empty_out" "(nothing outside firstmate's supervision is running)" \
  "the empty unsupervised table has no placeholder"

"$ROSTER" --help >/dev/null 2>&1 || fail "fm-roster.sh --help exited non-zero"
pass "the fleet roster reports supervised and unsupervised work with doing/model/estimate, reads the real context figure, defaults to the primary home, bounds its reads, and stays read-only"
