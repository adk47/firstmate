#!/usr/bin/env bash
# tests/fm-test-reap.test.sh - a behavior test must never leave a server
# running after it ends. The incident this pins: the remote secondmate e2e and
# trace-context tests started the remote job worker (its own process group,
# under a restart supervisor), stopped only the recorded serving pid, and were
# then ended by the per-script time bound; four workers kept serving from the
# left-over fixture for 32 hours at ~45% CPU. bin/fm-test-reap-lib.sh owns the
# reaping; tests/lib.sh runs it from every registered fixture's cleanup, and
# bin/fm-test-run.sh runs it over each concurrent script's private TMPDIR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-reap)

# A stand-in for the remote job worker: a supervisor script that lives under
# the fixture, runs in its own process group, and restarts its serving child
# whenever that child dies, exactly the shape a pid-only stop cannot end.
write_fake_supervisor() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fake-worker.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --serve ]; then
  printf '%s\n' "$$" > "$(dirname "$0")/../worker.pid"
  while :; do sleep 1; done
fi
trap '' HUP
while :; do
  "$0" --serve &
  wait "$!"
  sleep 0.1
done
SH
  chmod +x "$dir/bin/fake-worker.sh"
}

start_detached_supervisor() {  # <dir>
  local dir=$1 i=0
  rm -f "$dir/worker.pid"
  (
    set -m
    nohup "$dir/bin/fake-worker.sh" >/dev/null 2>&1 < /dev/null &
  )
  while [ ! -s "$dir/worker.pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/worker.pid" ] || fail "the fake worker never started"
}

test_reap_stops_a_restarting_worker_tree() {
  local dir pid i=0
  dir="$TMP_ROOT/tree"
  write_fake_supervisor "$dir"
  start_detached_supervisor "$dir"
  pid=$(cat "$dir/worker.pid")
  # The old cleanup: stop the recorded serving pid only. The supervisor
  # restarts it, which is how the leaked workers multiplied.
  rm -f "$dir/worker.pid"
  kill "$pid" 2>/dev/null || true
  while [ ! -s "$dir/worker.pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/worker.pid" ] || fail "the fake supervisor did not restart its child (the fixture is wrong)"
  [ -n "$(fm_test_processes_under "$dir")" ] || fail "no fixture process was found before reaping"
  FM_TEST_REAP_WAIT_SECS=3 fm_test_reap_processes_under "$dir" 2>/dev/null \
    || fail "the reaper reported processes still running under the fixture"
  [ -z "$(fm_test_processes_under "$dir")" ] || fail "a fixture process survived the reaper"
  pass "the reaper stops a restarting worker tree in its own process group, not only the recorded pid"
}

test_reap_refuses_a_path_that_could_match_everything() {
  fm_test_processes_under / >/dev/null 2>&1 && fail "the reaper accepted / as a fixture directory"
  fm_test_processes_under relative/path >/dev/null 2>&1 && fail "the reaper accepted a relative path"
  pass "the reaper refuses a short or relative directory"
}

# A test ended by TERM to its process group (an interrupt, or a runner's bound)
# runs tests/lib.sh's cleanup, which reaps the worker it started in a group of
# its own before removing the fixture. Under the per-script bound that cleanup
# has only the second before KILL follows, so the runner sweep below is the
# guarantee and this is the first line.
test_a_terminated_test_reaps_its_fixture_worker() {
  local child out fixture pgid i=0
  child="$TMP_ROOT/child.test.sh"
  out="$TMP_ROOT/child.out"
  write_fake_supervisor "$TMP_ROOT/tree-src"
  cat > "$child" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"
CHILD_ROOT=\$(fm_test_tmproot fm-test-reap-child)
printf '%s\n' "\$CHILD_ROOT" > "$TMP_ROOT/child.root"
mkdir -p "\$CHILD_ROOT/bin"
cp "$TMP_ROOT/tree-src/bin/fake-worker.sh" "\$CHILD_ROOT/bin/fake-worker.sh"
( set -m; nohup "\$CHILD_ROOT/bin/fake-worker.sh" >/dev/null 2>&1 < /dev/null & )
i=0
while [ ! -s "\$CHILD_ROOT/worker.pid" ] && [ "\$i" -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done
printf 'ready\n' > "$TMP_ROOT/child.ready"
sleep 600
SH
  set -m
  FM_TEST_REAP_WAIT_SECS=3 bash "$child" > "$out" 2>&1 &
  pgid=$!
  set +m
  while [ ! -s "$TMP_ROOT/child.ready" ] && [ "$i" -lt 400 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$TMP_ROOT/child.ready" ] || { kill -KILL -- "-$pgid" 2>/dev/null; fail "the child test never started its worker: $(cat "$out")"; }
  kill -TERM -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
  fixture=$(cat "$TMP_ROOT/child.root")
  [ -z "$(fm_test_processes_under "$fixture")" ] \
    || fail "a test ended by TERM left its worker running under $fixture"
  [ ! -e "$fixture" ] || fail "a test ended by TERM left its fixture behind: $fixture"
  pass "a test ended by TERM reaps the worker it started in its own process group and removes the fixture"
}

# The runner backstop: a concurrent script that leaks a detached process into
# its private TMPDIR, with no cleanup of its own at all, is reaped as soon as
# it returns.
test_runner_reaps_what_a_concurrent_script_leaked() {
  local repo out script marker hang leak
  repo="$TMP_ROOT/runner-repo"
  marker="$TMP_ROOT/leak.dir"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-test-reap-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
  # The runner sources the git isolation helper around every suite it runs.
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  # Both names are individually proven isolated, so the runner schedules them
  # concurrently, each with its own TMPDIR.
  for script in fm-cd-pretool-check.test.sh fm-pr-merge.test.sh; do
    hang=
    # The second one hangs past the per-script bound, the incident's shape.
    [ "$script" = fm-pr-merge.test.sh ] && hang='sleep 600'
    cat > "$repo/tests/$script" <<SH
#!/usr/bin/env bash
trap - EXIT INT TERM
leak="\$TMPDIR/leak-$script"
mkdir -p "\$leak"
printf '%s\n' "\$leak" >> "$marker"
cp "$TMP_ROOT/tree-src/bin/fake-worker.sh" "\$leak/fake-worker.sh"
( set -m; nohup "\$leak/fake-worker.sh" >/dev/null 2>&1 < /dev/null & )
i=0
while [ ! -s "\$leak/../worker.pid" ] && [ "\$i" -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done
echo "ok - leaking fixture"
$hang
SH
    chmod +x "$repo/tests/$script"
  done
  out="$TMP_ROOT/runner.out"
  (cd "$repo" && FM_TEST_REAP_WAIT_SECS=3 bin/fm-test-run.sh --per-script-timeout-secs 10 \
      tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh) > "$out" 2>&1
  grep -q 'fm-pr-merge.test.sh exceeded the per-script bound' "$out" \
    || fail "the hanging fixture was not ended by the per-script bound: $(cat "$out")"
  grep -E '^FM_TEST_BEGIN' "$out" | head -n 2 | awk '{print $1}' | paste -sd, - | grep -qx 'FM_TEST_BEGIN,FM_TEST_BEGIN' \
    || fail "the fixtures did not run concurrently, so the private-TMPDIR sweep was not exercised: $(cat "$out")"
  [ "$(grep -c . "$marker")" -eq 2 ] || fail "both leaking fixtures did not run: $(cat "$out")"
  while IFS= read -r leak; do
    [ -z "$(fm_test_processes_under "${leak%/*}")" ] \
      || fail "the runner left a leaked process running under ${leak%/*}"
  done < "$marker"
  grep -q '^reaped ' "$out" || fail "the runner did not report what it reaped: $(cat "$out")"
  pass "the runner reaps what a concurrent script leaked under its private TMPDIR, after a pass or the time bound, and reports it"
}

# Every test that starts the remote job worker reaps its whole fixture tree in
# its own cleanup, not just the recorded serving pid.
test_every_remote_worker_test_reaps_its_fixture() {
  local f missing=''
  for f in "$ROOT"/tests/*.test.sh; do
    grep -q 'remote-jobs/worker.pid' "$f" || continue
    grep -q 'fm_test_reap_fixture_processes' "$f" || missing="$missing ${f##*/}"
  done
  [ -z "$missing" ] || fail "tests that start the remote job worker without reaping their fixture:$missing"
  pass "every test that starts the remote job worker reaps its fixture tree on cleanup"
}

test_reap_stops_a_restarting_worker_tree
test_reap_refuses_a_path_that_could_match_everything
test_a_terminated_test_reaps_its_fixture_worker
test_runner_reaps_what_a_concurrent_script_leaked
test_every_remote_worker_test_reaps_its_fixture
