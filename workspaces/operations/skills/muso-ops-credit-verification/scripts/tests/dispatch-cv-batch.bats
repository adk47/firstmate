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
  # at the REPO's copy so every dispatch test actually runs instead of
  # skipping on a host without /opt/hydra. The regression this suite now
  # carries ("the batch must name its agent owner") is worthless if it can
  # only run on node-8.
  export CV_PIPELINE_PATH="$SCRIPTS_DIR/../pipelines/verify-credit-batch-mvp.lobster"

  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'CURL %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/curl.calls"
# Record the POST body verbatim so a test can assert on WHAT was sent, not
# just that something was. `%q` above escapes the JSON, so this is the only
# faithful copy.
if [[ -n "${TEST_TMPDIR:-}" ]]; then
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "-d" ]]; then printf '%s\n' "$arg" >> "$TEST_TMPDIR/curl.body"; fi
    prev="$arg"
  done
fi
if [[ -n "${CV_TEST_RESPONSE_FILE:-}" && -r "${CV_TEST_RESPONSE_FILE:-}" ]]; then
  cat "$CV_TEST_RESPONSE_FILE"
else
  printf '{"ok":true,"result":{"details":{"output":["stub summary"]}}}\n'
fi
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  export CV_DISPATCH_HISTORY_FILE="$TEST_TMPDIR/cv-dispatch-history"
  export CV_DISPATCH_GUARD_WINDOW_SECS=600
  export CV_DISPATCH_GUARD_MAX=2
  unset CV_DISPATCH_GUARD_DISABLE

  # Real apply is gated on the TRACKED policies/credit-approval-automation.json,
  # resolved next to the script with no env override (2026-10-11). The
  # accounting/lock tests below exercise a REAL run, so they run a copy of the
  # scripts whose sibling registry approves it. The gate's own tests use the
  # repo copy (approved=false) or an unapproved/broken tree.
  APPROVED_SCRIPTS="$(make_approval_tree true)"
  DISPATCH="$APPROVED_SCRIPTS/lobster-mvp/dispatch-cv-batch.sh"
  CRON_ENTRY="$APPROVED_SCRIPTS/credit-verification-batch-cron.sh"
}
teardown() { teardown_tmp_env; }

pipeline_deployed() { [[ -r "${CV_PIPELINE_PATH:-/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/pipelines/verify-credit-batch-mvp.lobster}" ]]; }

CRON_ENTRY="$SCRIPTS_DIR/credit-verification-batch-cron.sh"

curl_calls() { grep -c '^CURL ' "$TEST_TMPDIR/curl.calls" 2>/dev/null || echo 0; }

# --- helpers for the invoke-contract + zero-work regression tests -----------

# Build a /tools/invoke response whose last step stdout is the pipeline's
# own summary text plus its machine contract line, the way
# render-dry-run-summary.sh emits both to ONE stdout.
# --rawfile, not --arg: --arg would need a real newline inside a bash
# double-quoted string, and a literal \n there stays backslash-n, putting the
# contract line mid-line where the parser cannot see it.
make_response() { # <file> <queue_depth> <sampled> <attempted> <landed>
  local file="$1" qd="$2" smp="$3" att="$4" lnd="$5"
  printf 'Queue depth (live): %s | Sampled: %s of 500\nCV_BATCH_SUMMARY queue_depth=%s fetch_size=500 sampled=%s would_approve=%s would_uvn=0 attempted=%s landed=%s refused=0 transport_failed=0 dry_run=false run_id=lobster-test-1\n' \
    "$qd" "$smp" "$qd" "$smp" "$lnd" "$att" "$lnd" > "$TEST_TMPDIR/summary.txt"
  jq -nc --rawfile s "$TEST_TMPDIR/summary.txt" \
    '{ok:true, result:{details:{output:[$s]}}}' > "$file"
}

# `real` mode needs the shared credit-write lock; keep it in the tmpdir so a
# test never waits on (or is influenced by) the prod lock.
real_dispatch() { # <args...>
  CV_DISPATCH_GUARD_DISABLE=1 \
  CV_CREDIT_WRITE_LOCK_PATH="$TEST_TMPDIR/credit-status-writes.lock" \
  CV_CREDIT_WRITE_LOCK_WAIT_SECS=1 \
    run --separate-stderr "$DISPATCH" "$@"
}

last_body() { tail -1 "$TEST_TMPDIR/curl.body" 2>/dev/null; }

# Encode an arbitrary summary text as the response's last step stdout. Hand-
# written JSON with an embedded newline is invalid JSON and the dispatcher
# would fail at the invoke (exit 5) instead of at the guard — use --rawfile.
make_raw_response() { # <response-file> <summary-text-file>
  jq -nc --rawfile s "$2" '{ok:true, result:{details:{output:[$s]}}}' > "$1"
}

@test "the cron ENTRYPOINT runs the dispatcher in real+queue mode with no thread ts" {
  # This is what cron-jobs.json executes (the runtime rejects empty argv
  # elements, so the cron cannot pass "" for the dispatcher's thread_ts
  # positional — see credit-verification-batch-cron.sh). The entrypoint must
  # therefore land on the real-apply / queue-selector defaults, and the
  # zero-work guard must still be reachable through it.
  [ -f "$CRON_ENTRY" ]
  [ -x "$CRON_ENTRY" ]
  bash -n "$CRON_ENTRY"
  make_response "$TEST_TMPDIR/resp.json" 2700 500 500 480
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  CV_DISPATCH_GUARD_DISABLE=1 \
  CV_CREDIT_WRITE_LOCK_PATH="$TEST_TMPDIR/credit-status-writes.lock" \
  CV_CREDIT_WRITE_LOCK_WAIT_SECS=1 \
    run --separate-stderr "$CRON_ENTRY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=ok"* ]]
  run jq -e '.args.argsJson | fromjson
             | .batch_size == 500 and .dry_run == "false"
               and .selector_kind == "queue" and .thread_ts == ""' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "the cron ENTRYPOINT still fails the run when the queue has work and nothing was sampled" {
  make_response "$TEST_TMPDIR/resp.json" 2700 0 0 0
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  CV_DISPATCH_GUARD_DISABLE=1 \
  CV_CREDIT_WRITE_LOCK_PATH="$TEST_TMPDIR/credit-status-writes.lock" \
  CV_CREDIT_WRITE_LOCK_WAIT_SECS=1 \
    run --separate-stderr "$CRON_ENTRY"
  [ "$status" -eq 6 ]
  [[ "$output" == *"outcome=silent_noop"* ]]
}

@test "real apply is forced DRY when the registry does not approve it (the repo default)" {
  # 2026-10-11 containment: the approve rule was inverted, so a real run must be
  # impossible until the captain approves the fixed pipeline in a reviewed PR.
  # The REPO's registry says approved=false, so a real request becomes dry.
  run jq -e '.automations["credit-verification-batch"].approved == false' "$SCRIPTS_DIR/../../../../../policies/credit-approval-automation.json"
  [ "$status" -eq 0 ]
  DISPATCH="$SCRIPTS_DIR/lobster-mvp/dispatch-cv-batch.sh"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"CV_REAL_APPLY_BLOCKED"* ]]
  [[ "$output" == *"outcome=dry_run_real_apply_not_approved"* ]]
  [[ "$stderr" == *"real apply is NOT approved"* ]]
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "a caller cannot re-arm real apply by pointing an env var at its own registry" {
  # QA finding on hydra#1138: CV_APPROVAL_REGISTRY used to be a caller-controlled
  # override. It must now be ignored.
  printf '{"automations":{"credit-verification-batch":{"approved":true,"approved_by":"me","approval_ref":"me"}}}\n' > "$TEST_TMPDIR/forged.json"
  DISPATCH="$SCRIPTS_DIR/lobster-mvp/dispatch-cv-batch.sh"
  CV_APPROVAL_REGISTRY="$TEST_TMPDIR/forged.json" real_dispatch 500 "" real queue ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"CV_REAL_APPLY_BLOCKED"* ]]
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "real apply is forced DRY when the registry is unapproved, malformed, or approved without who/where" {
  local unapproved
  unapproved="$(make_approval_tree false)"
  DISPATCH="$unapproved/lobster-mvp/dispatch-cv-batch.sh"
  real_dispatch 5 "" real profile 8b3859c5-7930-4a48-8078-7262b2bb8dc6
  [ "$status" -eq 0 ]
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
  local reg="$unapproved/../../../../../policies/credit-approval-automation.json"
  printf 'not json' > "$reg"
  : > "$TEST_TMPDIR/curl.body"
  real_dispatch 1 "" real credit b490eaad-7575-4ff9-9f08-804e37ce51e3
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
  printf '{"automations":{"credit-verification-batch":{"approved":true,"approved_by":null,"approval_ref":"x"}}}\n' > "$reg"
  : > "$TEST_TMPDIR/curl.body"
  real_dispatch 1 "" real credit b490eaad-7575-4ff9-9f08-804e37ce51e3
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
  rm -f "$reg"
  : > "$TEST_TMPDIR/curl.body"
  real_dispatch 1 "" real credit b490eaad-7575-4ff9-9f08-804e37ce51e3
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "the cron entrypoint (no args) is also forced DRY without approval" {
  CV_DISPATCH_GUARD_DISABLE=1 run --separate-stderr "$SCRIPTS_DIR/credit-verification-batch-cron.sh"
  [ "$status" -eq 0 ]
  run jq -e '.args.argsJson | fromjson | .dry_run == "true"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "real apply proceeds only when the registry approves it" {
  make_response "$TEST_TMPDIR/resp.json" 10 10 10 10
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"CV_REAL_APPLY_BLOCKED"* ]]
  run jq -e '.args.argsJson | fromjson | .dry_run == "false"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "every dispatch names an explicit agent owner in the invoke body" {
  # 2026-09-11 outage: openclaw 2026.8.x refuses an unowned session key once
  # multiple agents are configured (AGENT_SELECTION_REQUIRED: 'Multiple
  # agents are configured, but session key "main" has no explicit owner').
  # The body must therefore carry agentId (and an agent-prefixed sessionKey),
  # or the 4-hourly batch dies before the pipeline runs. This is the test that
  # fails against the pre-fix script.
  CV_DISPATCH_GUARD_DISABLE=1 run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [ -s "$TEST_TMPDIR/curl.body" ]
  run jq -e '.agentId == "operations"' <<< "$(last_body)"
  [ "$status" -eq 0 ]
  run jq -e '.sessionKey | startswith("agent:operations:")' <<< "$(last_body)"
  [ "$status" -eq 0 ]
  # The tool call itself must survive the change untouched.
  run jq -e '.tool == "lobster" and .action == "run" and (.args.pipeline | length > 0)' <<< "$(last_body)"
  [ "$status" -eq 0 ]
}

@test "a real run that sampled 0 while the queue has work FAILS (exit 6)" {
  # The silent half of the 2026-09-11 outage: the pipeline runs, samples
  # nothing from a 2.7k-deep queue, posts a 'no-op' summary, and the
  # scheduler sees success. Zero processed with work available is a failure.
  make_response "$TEST_TMPDIR/resp.json" 2700 0 0 0
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"processed 0 credits while the unverified queue holds 2700"* ]]
  [[ "$output" == *"outcome=silent_noop"* ]]
}

@test "a real run against an EMPTY queue is a success (exit 0, outcome=no_work)" {
  make_response "$TEST_TMPDIR/resp.json" 0 0 0 0
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=no_work"* ]]
}

@test "a real run whose attempts all failed is an error (exit 6, outcome=all_failed)" {
  make_response "$TEST_TMPDIR/resp.json" 900 500 500 0
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"attempted 500 credit write(s) and landed 0"* ]]
  [[ "$output" == *"outcome=all_failed"* ]]
}

@test "a real run with no readable accounting fails closed (exit 6)" {
  # A 200 whose output shape we cannot read must never be credited with work.
  printf 'summary with no machine line\n' > "$TEST_TMPDIR/summary.txt"
  make_raw_response "$TEST_TMPDIR/resp.json" "$TEST_TMPDIR/summary.txt"
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"no usable CV_BATCH_SUMMARY accounting"* ]]
  [[ "$output" == *"outcome=unaccounted"* ]]
}

@test "a present-but-MALFORMED contract line fails closed (exit 6)" {
  # QA on PR #961: `sampled=null` is what the renderer prints when
  # .counts.total disappears after an upstream schema change. With
  # attempted=0 it used to fall through the numeric tests to no_eligible and
  # exit 0 — the silent success this guard exists to prevent.
  printf 'Queue depth (live): 2700 | Sampled: null of 500\nCV_BATCH_SUMMARY queue_depth=2700 fetch_size=500 sampled=null would_approve=0 would_uvn=0 attempted=0 landed=0 refused=0 transport_failed=0 dry_run=false run_id=x\n' > "$TEST_TMPDIR/summary.txt"
  make_raw_response "$TEST_TMPDIR/resp.json" "$TEST_TMPDIR/summary.txt"
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"invalid fields: sampled=null"* ]]
  [[ "$output" == *"outcome=unaccounted"* ]]
}

@test "a contract line MISSING required keys fails closed (exit 6)" {
  # Same class, one step further: a truncated contract line (schema change that
  # drops attempted/landed) must not read as "nothing decidable".
  printf 'CV_BATCH_SUMMARY queue_depth=2700 fetch_size=500 sampled=0\n' > "$TEST_TMPDIR/summary.txt"
  make_raw_response "$TEST_TMPDIR/resp.json" "$TEST_TMPDIR/summary.txt"
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 6 ]
  [[ "$stderr" == *"attempted=<absent>"* ]]
  [[ "$output" == *"outcome=unaccounted"* ]]
}

@test "a real run that lands writes is a success (exit 0, outcome=ok)" {
  make_response "$TEST_TMPDIR/resp.json" 2700 500 500 480
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  real_dispatch 500 "" real queue ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=ok"* ]]
  [[ "$output" == *"landed=480"* ]]
}

@test "a DRY run is never failed by the zero-work guard" {
  # A dry run cannot write, so 0 processed is not a fault — and the guard
  # must not turn a deliberate sample into a scheduler error.
  make_response "$TEST_TMPDIR/resp.json" 2700 0 0 0
  export CV_TEST_RESPONSE_FILE="$TEST_TMPDIR/resp.json"
  CV_DISPATCH_GUARD_DISABLE=1 run --separate-stderr "$DISPATCH" 5 "" dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=dry_run"* ]]
}

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
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available (macOS) — the guard lock is a Linux feature"; fi
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

@test "real dispatch fails closed when the shared credit-write lock is held" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available (macOS)"; fi
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  local lock_path="$TEST_TMPDIR/credit-status-writes.lock"
  local ready_path="$TEST_TMPDIR/credit-status-writes.ready"
  (
    exec 7>"$lock_path"
    flock 7
    touch "$ready_path"
    sleep 3
  ) &
  local holder_pid=$!
  for _ in {1..100}; do
    [[ -e "$ready_path" ]] && break
    sleep 0.01
  done
  [[ -e "$ready_path" ]]

  CV_DISPATCH_GUARD_DISABLE=1 \
    CV_CREDIT_WRITE_LOCK_PATH="$lock_path" \
    CV_CREDIT_WRITE_LOCK_WAIT_SECS=1 \
    run --separate-stderr "$DISPATCH" 5 "" real
  wait "$holder_pid"

  [ "$status" -eq 5 ]
  [[ "$stderr" == *"timed out waiting for shared credit-write lock"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "dry dispatch does not wait for the shared credit-write lock" {
  if ! command -v flock >/dev/null 2>&1; then skip "flock not available (macOS)"; fi
  if ! pipeline_deployed; then skip "pipeline file not deployed on this host"; fi
  local lock_path="$TEST_TMPDIR/credit-status-writes.lock"
  (
    exec 7>"$lock_path"
    flock 7
    sleep 2
  ) &
  local holder_pid=$!

  CV_DISPATCH_GUARD_DISABLE=1 \
    CV_CREDIT_WRITE_LOCK_PATH="$lock_path" \
    CV_CREDIT_WRITE_LOCK_WAIT_SECS=1 \
    run --separate-stderr "$DISPATCH" 5 "" dry
  wait "$holder_pid"

  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
}
