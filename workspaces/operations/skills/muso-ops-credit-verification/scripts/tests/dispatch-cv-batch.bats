#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Covers dispatch-cv-batch.sh's repeat-dispatch guard (2026-07-22 incident:
# the agent mis-routed a UVN review onto the batch pipeline and dispatched
# it once per profile — ~30 invocations in ~2 minutes, each a guaranteed
# "Sampled: 0" no-op posting a full Slack block). The pipeline is
# one-dispatch-per-request by contract; the guard makes a loop impossible
# instead of merely documented (prose is not enforcement).
#
# Guard contract:
#   - state file: CV_DISPATCH_HISTORY_FILE (default /var/lib/hydra/cv-dispatch-history)
#   - window:     CV_DISPATCH_GUARD_WINDOW_SECS (default 600)
#   - allowed:    CV_DISPATCH_GUARD_MAX (default 2) dispatches per window;
#                 the next one exits 2 WITHOUT invoking the pipeline
#   - corrupt/unreadable state → warn + reset + proceed (anti-spam guard,
#     not a money gate; blocking the 4-hourly cron on state rot is worse)
#   - CV_DISPATCH_GUARD_DISABLE=1 → skip entirely (tests / manual recovery)

DISPATCH="$SCRIPTS_DIR/lobster-mvp/dispatch-cv-batch.sh"

setup() {
  setup_tmp_env

  # Fake gateway config with a token so the script gets past auth checks.
  export OPENCLAW_CONFIG_PATH="$TEST_TMPDIR/openclaw.json"
  printf '{"gateway":{"auth":{"token":"test-token"}}}\n' > "$OPENCLAW_CONFIG_PATH"

  # The script hard-fails if the deployed pipeline file is missing; point it
  # at a stand-in via the tmpdir-shadowed HOME-independent path is not
  # possible (path is a constant), so stub `curl` AND pre-create the check
  # target only when it doesn't exist on this host. On dev boxes the /opt
  # path is absent → tests that expect a SUCCESSFUL dispatch must skip.
  # The guard, however, fires BEFORE the pipeline-file check, so refusal
  # tests run everywhere.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'CURL %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/curl.calls"
printf '{"ok":true,"result":{"details":{"output":["stub summary"]}}}\n'
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  export CV_DISPATCH_HISTORY_FILE="$TEST_TMPDIR/cv-dispatch-history"
  export CV_DISPATCH_GUARD_WINDOW_SECS=600
  export CV_DISPATCH_GUARD_MAX=2
  unset CV_DISPATCH_GUARD_DISABLE
}
teardown() { teardown_tmp_env; }

pipeline_deployed() { [[ -r /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/pipelines/verify-credit-batch-mvp.lobster ]]; }

curl_calls() { grep -c '^CURL ' "$TEST_TMPDIR/curl.calls" 2>/dev/null || echo 0; }

@test "third dispatch inside the window is refused with exit 2 and no pipeline invoke" {
  now=$(date +%s)
  printf '%s\n%s\n' "$((now - 30))" "$((now - 10))" > "$CV_DISPATCH_HISTORY_FILE"
  run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"repeat-dispatch guard"* ]]
  [[ "$stderr" == *"Do NOT retry"* ]]
  # Routing hint: the loop's root cause was a UVN ask mis-routed here.
  [[ "$stderr" == *"UVN"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "stale (outside-window) entries are pruned and do not trip the guard" {
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  now=$(date +%s)
  printf '%s\n%s\n%s\n' "$((now - 4000))" "$((now - 3000))" "$((now - 2000))" > "$CV_DISPATCH_HISTORY_FILE"
  run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  # File rewritten: stale entries gone, exactly the new stamp remains.
  [ "$(wc -l < "$CV_DISPATCH_HISTORY_FILE")" -eq 1 ]
}

@test "corrupt state file warns, resets, and proceeds" {
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  printf 'not-a-number\ngarbage 123\n' > "$CV_DISPATCH_HISTORY_FILE"
  run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"guard state"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "CV_DISPATCH_GUARD_DISABLE=1 skips the guard even over threshold" {
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  now=$(date +%s)
  printf '%s\n%s\n%s\n%s\n' "$((now-40))" "$((now-30))" "$((now-20))" "$((now-10))" > "$CV_DISPATCH_HISTORY_FILE"
  CV_DISPATCH_GUARD_DISABLE=1 run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "unwritable history dir warns and proceeds (fail-open, guard-only)" {
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  export CV_DISPATCH_HISTORY_FILE="$TEST_TMPDIR/no-perms/cv-dispatch-history"
  mkdir -p "$TEST_TMPDIR/no-perms"
  chmod 555 "$TEST_TMPDIR/no-perms"
  run --separate-stderr "$DISPATCH" 5 "" dry
  chmod 755 "$TEST_TMPDIR/no-perms"
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "guard refusal happens even before arg-dependent gateway checks (no config needed)" {
  # Refusal path must not require a readable config/pipeline — the guard
  # sits before those checks, so a looping agent is stopped on ANY host.
  export OPENCLAW_CONFIG_PATH="$TEST_TMPDIR/nonexistent.json"
  now=$(date +%s)
  printf '%s\n%s\n' "$((now - 30))" "$((now - 10))" > "$CV_DISPATCH_HISTORY_FILE"
  run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"repeat-dispatch guard"* ]]
}

@test "invalid args still fail loud BEFORE the guard records anything" {
  run --separate-stderr "$DISPATCH" --help
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"batch_size must be a non-negative integer"* ]]
  [ ! -s "$CV_DISPATCH_HISTORY_FILE" ]
}

@test "non-numeric guard env overrides warn and fall back to defaults (no abort, no spurious trip)" {
  # Bash (( )) evaluates variable contents: `abc` would abort under set -u.
  # (Empty values never reach the arithmetic — the ${VAR:-default} expansion
  # already substitutes on empty, so only non-empty garbage needs the guard.)
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  CV_DISPATCH_GUARD_WINDOW_SECS="600s" CV_DISPATCH_GUARD_MAX="abc" \
    run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"bad CV_DISPATCH_GUARD_WINDOW_SECS"* ]]
  [[ "$stderr" == *"bad CV_DISPATCH_GUARD_MAX"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "leading-zero (octal-shaped) history entry routes to corrupt-reset, not an arithmetic error" {
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  printf '08\n09\n' > "$CV_DISPATCH_HISTORY_FILE"
  run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"guard state"* ]]
  [[ "$stderr" != *"value too great for base"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "parallel dispatch storm: no more than GUARD_MAX invocations reach the pipeline" {
  # QA #725: the read/check/write must be atomic across processes — without
  # the flock, N concurrent racers all read the same prior state and all
  # pass. With it, the guard sections serialize: exactly GUARD_MAX (2)
  # reach curl, the rest refuse with exit 2.
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  local pids=() fails=0
  for i in 1 2 3 4 5 6; do
    "$DISPATCH" 5 "" dry >/dev/null 2>>"$TEST_TMPDIR/storm.stderr" &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do
    if ! wait "$p"; then fails=$((fails + 1)); fi
  done
  [ "$(curl_calls)" -eq 2 ]
  [ "$fails" -eq 4 ]
  grep -q "repeat-dispatch guard tripped" "$TEST_TMPDIR/storm.stderr"
}

@test "future-dated history entries reset as corrupt instead of tripping the guard forever" {
  # QA #725 round 2: NOW - future is negative, i.e. always < window — two
  # future stamps would refuse every dispatch until that future date. They
  # must route to the corrupt-reset path (warn + proceed).
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  now=$(date +%s)
  printf '%s\n%s\n' "$((now + 86400))" "$((now + 172800))" > "$CV_DISPATCH_HISTORY_FILE"
  run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"guard state"* ]]
  [ "$(curl_calls)" -eq 1 ]
}
