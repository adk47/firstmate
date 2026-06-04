#!/usr/bin/env bats
# Tests for scripts/qa-dispatch-pr-review.sh — the fire-and-forget dispatcher
# that registers a one-shot openclaw cron job to auto-review a hydra PR.
# Every test PATH-shadows `openclaw` with a stub so the suite NEVER touches the
# live gateway (memory: bats must stub openclaw/gh — an unstubbed test once
# fired 9 real Slack alerts to prod). Arg-validation tests must reject BEFORE
# any openclaw call, so a bad invocation can never dispatch a real review.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-dispatch-pr-review.sh"

GOOD_SHA="0f175183abf"   # 11 hex chars — valid

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export STUB_CALLS="$TEST_TMPDIR/calls"          # one token per subcommand
  export STUB_ARGV="$TEST_TMPDIR/argv"            # every arg, one per line
  : > "$STUB_CALLS"
  : > "$STUB_ARGV"

  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/openclaw" <<'STUB'
#!/usr/bin/env bash
# Record every arg for assertions.
printf '%s\n' "$@" >> "$STUB_ARGV"
# Find the cron subcommand (the word after "cron").
sub=""
prev=""
for a in "$@"; do
  if [ "$prev" = "cron" ]; then sub="$a"; break; fi
  prev="$a"
done
case "$sub" in
  # `cron list` returns STUB_LIST_JSON if a test set one, else no jobs.
  list) if [ -f "${STUB_LIST_JSON:-}" ]; then cat "${STUB_LIST_JSON}"; else echo '{"jobs":[]}'; fi ;;
  add)  echo "cron-add" >> "$STUB_CALLS"; echo '{"ok":true}' ;;
  rm)   echo "cron-rm"  >> "$STUB_CALLS" ;;
esac
STUB
  chmod +x "$STUBBIN/openclaw"
  export PATH="$STUBBIN:$PATH"
  export OPENCLAW="openclaw"   # resolve via the stubbed PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "happy path: dispatches one cron add for the qa agent on main" {
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cron-add$' "$STUB_CALLS")" -eq 1 ]
  # targets the qa agent, the main profile, and the per-PR job name
  grep -qx 'qa' "$STUB_ARGV"
  grep -qx 'main' "$STUB_ARGV"
  grep -qx 'qa-autoreview-pr-123' "$STUB_ARGV"
  grep -qx 'isolated' "$STUB_ARGV"
  grep -qx -- '--delete-after-run' "$STUB_ARGV"
}

@test "happy path: message carries the PR URL + AUTO-REVIEW + Nick's requester UID" {
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  grep -q 'AUTO-REVIEW' "$STUB_ARGV"
  grep -q 'github.com/Muso-AI/hydra/pull/123' "$STUB_ARGV"
  grep -q 'U0AL36NADEY' "$STUB_ARGV"
}

@test "happy path: opening DM routed through the per-PR thread helper" {
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # The opening note goes through qa-pr-thread-dm.sh (threads re-reviews), not a
  # bare qa-slack-dm.sh call with an inline "reviewing PR" string.
  grep -q 'qa-pr-thread-dm.sh Muso-AI/hydra 123 U0AL36NADEY' "$STUB_ARGV"
}

@test "missing args -> usage exit 2, no dispatch" {
  run "$SCRIPT" 123
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "too many args -> usage exit 2, no dispatch" {
  run "$SCRIPT" 123 "$GOOD_SHA" extra
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "non-numeric PR -> exit 2 BEFORE any openclaw call" {
  run "$SCRIPT" not-a-number "$GOOD_SHA"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "bad SHA (non-hex) -> exit 2 BEFORE any openclaw call" {
  run "$SCRIPT" 123 "zzz-not-hex"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "bad SHA (too short) -> exit 2" {
  run "$SCRIPT" 123 "abc"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "fallback delivery disabled via --no-deliver (skill owns Slack delivery)" {
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  # --no-deliver is the actual off-switch for the runner's fallback delivery. Without
  # it the isolated cron's final text delivery fails with "Delivering to Slack requires
  # target ..." (omitting --announce alone does NOT disable the fallback).
  grep -qx -- '--no-deliver' "$STUB_ARGV"
  ! grep -qx -- '--announce'  "$STUB_ARGV"
}

@test "sweeps stale qa-autoreview-pr-* one-shots, leaves fresh + non-qa jobs alone" {
  now_ms=$(( $(date -u +%s) * 1000 ))
  stale_ms=$(( now_ms - 7200000 ))   # 2h ago — a done/failed run
  fresh_ms=$(( now_ms - 60000 ))     # 1m ago — possibly in-flight
  export STUB_LIST_JSON="$TEST_TMPDIR/list.json"
  cat > "$STUB_LIST_JSON" <<JSON
{"jobs":[
  {"id":"STALEQA","name":"qa-autoreview-pr-999","createdAtMs":$stale_ms},
  {"id":"FRESHQA","name":"qa-autoreview-pr-998","createdAtMs":$fresh_ms},
  {"id":"OTHERCRON","name":"some-other-cron","createdAtMs":$stale_ms}
]}
JSON
  run "$SCRIPT" 123 "$GOOD_SHA"
  [ "$status" -eq 0 ]
  grep -qx 'STALEQA' "$STUB_ARGV"      # stale qa-autoreview job removed
  ! grep -qx 'FRESHQA' "$STUB_ARGV"    # fresh (in-flight) qa-autoreview job left alone
  ! grep -qx 'OTHERCRON' "$STUB_ARGV"  # non-qa job never touched, even when stale
}
