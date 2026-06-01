#!/usr/bin/env bats
# Tests for scripts/codex-usage-report.sh + scripts/lib/codex-usage.sh — the
# twice-daily Codex OAuth usage report (hydra#382). The cron agent runs the
# report script and relays its stdout to a Slack DM; this suite proves the
# script reads the real {profiles:{...}} object shape correctly (the original
# bug iterated the root object and died on the `version` number), surfaces 5h +
# weekly usage from a rollout `rate_limits` snapshot, degrades honestly when no
# fresh snapshot exists, and never prints access/refresh tokens.
#
# Everything runs against a mktemp sandbox pointed at by CODEX_USAGE_ROOT, so it
# NEVER touches real node-8 auth/rollout files. openclaw + ssh are PATH-shadowed
# with refusing stubs so an accidental live call fails loud
# (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-usage-report.sh"
LIB="$HYDRA_REPO/scripts/lib/codex-usage.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  ROOT="$TEST_TMPDIR/root"; export ROOT

  # Refuse any accidental live call.
  mkdir -p "$TEST_TMPDIR/bin"
  local c
  for c in openclaw ssh; do
    cat > "$TEST_TMPDIR/bin/$c" <<STUB
#!/bin/bash
echo "test stub: $c call refused (\$*)" >&2
exit 99
STUB
    chmod +x "$TEST_TMPDIR/bin/$c"
  done
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  CANON="$ROOT/.openclaw-main/agents/main/agent"; export CANON
  OPS_SESS="$ROOT/.openclaw-main/agents/operations/agent/codex-home/sessions/2026/06/01"
  export OPS_SESS
  mkdir -p "$CANON" "$OPS_SESS"

  # Two codex accounts (aaron active) + a non-codex profile to prove the
  # startswith filter. Tokens are dummy strings to prove redaction by omission.
  cat > "$CANON/auth-profiles.json" <<'JSON'
{"version":1,"profiles":{
  "openai-codex:aaron@muso.ai":{"provider":"openai-codex","type":"oauth","email":"aaron@muso.ai","chatgptPlanType":"pro","expires":1780940020504,"accountId":"acc-a","access":"SECRET_ACCESS_A","refresh":"SECRET_REFRESH_A"},
  "openai-codex:aaronkaufman@me.com":{"provider":"openai-codex","type":"oauth","email":"aaronkaufman@me.com","chatgptPlanType":"pro","expires":1780940062168,"accountId":"acc-b","access":"SECRET_ACCESS_B","refresh":"SECRET_REFRESH_B"},
  "anthropic:default":{"provider":"anthropic","type":"oauth"}
}}
JSON
  printf '%s' '{"version":1,"lastGood":{"openai-codex":"openai-codex:aaron@muso.ai"},"usageStats":{}}' \
    > "$CANON/auth-state.json"

  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# epoch_to_iso <epoch_s> — portable across GNU (date -d) and BSD/macOS (date -r).
epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.031Z 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.031Z
}

# write_rollout <file> <age_seconds> <pct5h> <pctWeek>
# Write a rollout whose rate_limits snapshot is <age_seconds> in the past.
write_rollout() {
  local file="$1" age="$2" p5="$3" pw="$4" now ts iso r5 rw
  now="$(date +%s)"; ts="$(( now - age ))"
  iso="$(epoch_to_iso "$ts")"
  r5="$(( now + 7200 ))"; rw="$(( now + 500000 ))"
  cat > "$file" <<JSON
{"type":"session_meta","timestamp":"$iso","payload":{"id":"x","model_provider":"openai"}}
{"type":"event_msg","ts":"$iso","rate_limits":{"limit_id":"codex","primary":{"used_percent":$p5,"window_minutes":300,"resets_at":$r5},"secondary":{"used_percent":$pw,"window_minutes":10080,"resets_at":$rw},"plan_type":"pro"}}
JSON
}

run_report() { run env CODEX_USAGE_ROOT="$ROOT" "$SCRIPT" "$@"; }

# ── integration: report script ────────────────────────────────

@test "happy path: active shows 5h+weekly numbers, standby shows no-snapshot, non-codex filtered, no tables" {
  write_rollout "$OPS_SESS/rollout-2026-06-01T09-00-00-abc.jsonl" 3600 0 12.5
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'aaron@muso.ai* — active'
  echo "$output" | grep -q '5h window: 0% used'
  echo "$output" | grep -q 'weekly: 12.5% used'
  echo "$output" | grep -qF 'aaronkaufman@me.com* — idle standby'
  echo "$output" | grep -q 'no fresh quota snapshot'
  # only the two codex accounts appear; the anthropic profile does not
  ! echo "$output" | grep -qi 'anthropic'
  # mrkdwn, not a markdown table
  ! echo "$output" | grep -q '|'
}

@test "no rollout snapshots: active degrades to 'snapshot unavailable', standby still shown, exit 0" {
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'aaron@muso.ai* — active'
  echo "$output" | grep -q 'fresh quota snapshot unavailable'
  echo "$output" | grep -qF 'aaronkaufman@me.com* — idle standby'
}

@test "stale snapshot (older than FRESHNESS_HOURS): active degrades to 'snapshot unavailable'" {
  # 10h old vs default 6h freshness window.
  write_rollout "$OPS_SESS/rollout-stale.jsonl" "$(( 10 * 3600 ))" 5 5
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'aaron@muso.ai* — active'
  echo "$output" | grep -q 'fresh quota snapshot unavailable'
}

@test "missing auth files: emits a note and exits 0 (no crash)" {
  rm -f "$CANON/auth-profiles.json" "$CANON/auth-state.json"
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'no codex accounts found'
}

@test "malformed auth-profiles.json does not crash, exits 0" {
  printf '%s' '{ this is not valid json ' > "$CANON/auth-profiles.json"
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'no codex accounts found'
}

@test "redaction: access/refresh tokens never appear in text or json output" {
  write_rollout "$OPS_SESS/rollout-a.jsonl" 3600 0 1
  run_report
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'SECRET_ACCESS'
  ! echo "$output" | grep -q 'SECRET_REFRESH'
  run_report --json
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'SECRET_ACCESS'
  ! echo "$output" | grep -q 'SECRET_REFRESH'
}

@test "--json: well-formed, active_account correct, both accounts present with right roles" {
  write_rollout "$OPS_SESS/rollout-a.jsonl" 3600 0 12.5
  run_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tz == "America/Chicago"' >/dev/null
  echo "$output" | jq -e '.active_account == "openai-codex:aaron@muso.ai"' >/dev/null
  echo "$output" | jq -e '.accounts | length == 2' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaron@muso.ai") | .role=="active" and .freshness=="fresh" and .used_percent_weekly==12.5' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .role=="standby" and .used_percent_5h==null' >/dev/null
}

@test "unknown argument exits 2" {
  run_report --bogus
  [ "$status" -eq 2 ]
}

@test "freshest snapshot wins across multiple rollouts" {
  # An older snapshot (5h ago, 99%) and a newer one (1h ago, 3%): the newer's
  # numbers must be the ones reported for the active account.
  write_rollout "$OPS_SESS/rollout-old.jsonl" "$(( 5 * 3600 ))" 99 99
  write_rollout "$OPS_SESS/rollout-new.jsonl" 3600 3 7
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '5h window: 3% used'
  echo "$output" | grep -q 'weekly: 7% used'
  ! echo "$output" | grep -q '99% used'
}

# ── unit: pure helpers ────────────────────────────────────────

@test "regression (#382): cu_list_accounts reads the object shape, returns 2 codex rows, filters non-codex" {
  run cu_list_accounts "$CANON/auth-profiles.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'openai-codex:')" -eq 2 ]
  echo "$output" | grep -q 'aaron@muso.ai'
  echo "$output" | grep -q 'aaronkaufman@me.com'
  ! echo "$output" | grep -qi 'anthropic'
}

@test "unit: cu_active_account returns lastGood codex profile id" {
  run cu_active_account "$CANON/auth-state.json"
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:aaron@muso.ai" ]
}

@test "unit: cu_is_fresh classifies fresh / stale / none" {
  local now; now="$(date +%s)"
  run cu_is_fresh "$(( now - 3600 ))" 6;    [ "$output" = "fresh" ]
  run cu_is_fresh "$(( now - 10*3600 ))" 6; [ "$output" = "stale" ]
  run cu_is_fresh 0 6;                       [ "$output" = "none" ]
  run cu_is_fresh "x" 6;                     [ "$output" = "none" ]
}

@test "unit: cu_human_resets_in formats days/hours/minutes, 'now', and unknown" {
  local now=1000000
  run cu_human_resets_in "$(( now + 2*86400 + 3*3600 ))" "$now"; [ "$output" = "in 2d 3h" ]
  run cu_human_resets_in "$(( now + 4*3600 + 12*60 ))" "$now";   [ "$output" = "in 4h 12m" ]
  run cu_human_resets_in "$(( now + 9*60 ))" "$now";             [ "$output" = "in 9m" ]
  run cu_human_resets_in "$(( now - 100 ))" "$now";              [ "$output" = "now" ]
  run cu_human_resets_in "garbage" "$now";                       [ "$output" = "at an unknown time" ]
}

@test "unit: cu_fmt_pct keeps integers integer and fractions to one decimal" {
  run cu_fmt_pct 0.0;  [ "$output" = "0" ]
  run cu_fmt_pct 1.0;  [ "$output" = "1" ]
  run cu_fmt_pct 12.5; [ "$output" = "12.5" ]
  run cu_fmt_pct "";   [ "$output" = "0" ]
}

@test "unit: cu_latest_rate_limits returns the max-ts row as TSV" {
  write_rollout "$OPS_SESS/r1.jsonl" "$(( 4 * 3600 ))" 50 50
  write_rollout "$OPS_SESS/r2.jsonl" 600 2 9
  run cu_latest_rate_limits "$OPS_SESS/r1.jsonl" "$OPS_SESS/r2.jsonl"
  [ "$status" -eq 0 ]
  # column 2 = pct5h of the newer (600s old) snapshot
  [ "$(printf '%s' "$output" | cut -f2)" = "2" ]
  [ "$(printf '%s' "$output" | cut -f4)" = "9" ]
}
