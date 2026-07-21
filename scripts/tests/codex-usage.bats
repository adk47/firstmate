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

  # Hermeticity: the report now prefers the rotate actuator's active-account
  # state file over lastGood; pin it at an absent path so a real
  # /var/lib/hydra/codex-active-account on the CI host can't leak in. Same for
  # the per-account snapshot archive dir.
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/absent-active-account"
  export CODEX_USAGE_ARCHIVE_DIR="$TEST_TMPDIR/archive"
  export CODEX_ROTATE_STAMP="$TEST_TMPDIR/absent-rotate-stamp"

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

@test "active-account state file overrides stale lastGood (2026-07-21 mislabel fix)" {
  # After an account rotation, auth-state.json's lastGood still names the OLD
  # account (the 7.x runtime no longer maintains it) — the freshest quota
  # snapshot was being attributed to the wrong subscription. The rotate
  # actuator's state file is authoritative when present and valid.
  echo "openai-codex:aaronkaufman@me.com" > "$TEST_TMPDIR/active-account"
  run env CODEX_USAGE_ROOT="$ROOT" CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account" "$SCRIPT" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.active_account == "openai-codex:aaronkaufman@me.com"' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .role=="active"' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaron@muso.ai") | .role=="standby"' >/dev/null
}

@test "state file naming an unknown profile → falls back to lastGood" {
  echo "openai-codex:ghost@nowhere.com" > "$TEST_TMPDIR/active-account"
  run env CODEX_USAGE_ROOT="$ROOT" CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account" "$SCRIPT" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.active_account == "openai-codex:aaron@muso.ai"' >/dev/null
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

@test "unit: cu_latest_rate_limits returns the max-ts row as window-keyed TSV" {
  write_rollout "$OPS_SESS/r1.jsonl" "$(( 4 * 3600 ))" 50 50
  write_rollout "$OPS_SESS/r2.jsonl" 600 2 9
  run cu_latest_rate_limits "$OPS_SESS/r1.jsonl" "$OPS_SESS/r2.jsonl"
  [ "$status" -eq 0 ]
  # row: ts, reached, w1_min, w1_pct, w1_reset, w2_min, w2_pct, w2_reset —
  # the newer (600s old) snapshot wins.
  [ "$(printf '%s' "$output" | cut -f2)" = "-" ]     # no rate_limit_reached_type
  [ "$(printf '%s' "$output" | cut -f3)" = "300" ]   # 5h window keyed by minutes
  [ "$(printf '%s' "$output" | cut -f4)" = "2" ]
  [ "$(printf '%s' "$output" | cut -f6)" = "10080" ] # weekly keyed by minutes
  [ "$(printf '%s' "$output" | cut -f7)" = "9" ]
}

@test "window-keyed regression (2026-07-21): primary=weekly + secondary null renders 'weekly', never '5h window'" {
  # The live 7.x shape observed during the cap incident: primary IS the weekly
  # window (window_minutes 10080) and secondary is null. The old positional
  # parse labeled this '5h window: 98%'.
  local now iso r
  now="$(date +%s)"; iso="$(epoch_to_iso "$(( now - 600 ))")"; r="$(( now + 200000 ))"
  cat > "$OPS_SESS/rollout-r-weekly.jsonl" <<JSON
{"type":"event_msg","ts":"$iso","rate_limits":{"limit_id":"codex","primary":{"used_percent":98.0,"window_minutes":10080,"resets_at":$r},"secondary":null,"plan_type":"pro","rate_limit_reached_type":null}}
JSON
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'weekly: 98% used'
  ! echo "$output" | grep -q '5h window'
}

@test "rate_limit_reached_type in the snapshot is surfaced in the text report" {
  local now iso r
  now="$(date +%s)"; iso="$(epoch_to_iso "$(( now - 600 ))")"; r="$(( now + 200000 ))"
  cat > "$OPS_SESS/rollout-r-capped.jsonl" <<JSON
{"type":"event_msg","ts":"$iso","rate_limits":{"limit_id":"codex","primary":{"used_percent":100,"window_minutes":10080,"resets_at":$r},"secondary":null,"rate_limit_reached_type":"secondary_window"}}
JSON
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'rate limit reached (secondary_window)'
}

@test "standby with an ARCHIVED snapshot shows last-known quota instead of 'no fresh'" {
  local now r; now="$(date +%s)"; r="$(( now + 90000 ))"
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\t-\t10080\t97\t%s\t-\t-\t-\n' "$(( now - 7200 ))" "$r" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_aaronkaufman_me.com.snapshot.tsv"
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'last known (2h ago):'
  echo "$output" | grep -q 'weekly: 97% used'
  run_report --json
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .freshness=="archived" and .used_percent_weekly==97' >/dev/null
}

@test "rotation-boundary: a snapshot predating the last rotation is NOT attributed to the new active account" {
  # QA finding (#719, round 4): right after a rotation the freshest rollout
  # entry can predate the switch — it belongs to the OUTGOING account. Showing
  # it under the new active account would display the old capped quota twice
  # (as 'active' and in the outgoing archive).
  write_rollout "$OPS_SESS/rollout-pre-switch.jsonl" 3600 0 98   # 1h old
  echo "openai-codex:aaronkaufman@me.com" > "$TEST_TMPDIR/active-account"
  date +%s > "$TEST_TMPDIR/rotate-stamp"                          # rotated NOW
  run env CODEX_USAGE_ROOT="$ROOT" \
      CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account" \
      CODEX_ROTATE_STAMP="$TEST_TMPDIR/rotate-stamp" "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'aaronkaufman@me.com* — active'
  echo "$output" | grep -q 'fresh quota snapshot unavailable'
  ! echo "$output" | grep -q '98% used'
}

@test "rotation-boundary: a snapshot NEWER than the rotation is attributed normally" {
  write_rollout "$OPS_SESS/rollout-post-switch.jsonl" 600 1 42    # 10min old
  echo "openai-codex:aaronkaufman@me.com" > "$TEST_TMPDIR/active-account"
  printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$TEST_TMPDIR/rotate-stamp"  # rotated 1h ago
  run env CODEX_USAGE_ROOT="$ROOT" \
      CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account" \
      CODEX_ROTATE_STAMP="$TEST_TMPDIR/rotate-stamp" "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'weekly: 42% used'
}

@test "unit: cu_window_label maps known and unknown windows" {
  run cu_window_label 300;   [ "$output" = "5h window" ]
  run cu_window_label 10080; [ "$output" = "weekly" ]
  run cu_window_label 720;   [ "$output" = "12h" ]
  run cu_window_label 2880;  [ "$output" = "2d" ]
  run cu_window_label "-";   [ "$output" = "window" ]
}

@test "unit: cu_row_capped_until finds the blocking window's reset" {
  local now; now="$(date +%s)"
  local future=$(( now + 90000 )) past=$(( now - 100 ))
  # weekly at 98% resetting in the future → blocked until that reset
  run cu_row_capped_until "$(printf '1\t-\t10080\t98\t%s\t-\t-\t-' "$future")" 95 "$now"
  [ "$status" -eq 0 ]; [ "$output" = "$future" ]
  # same but the reset already passed → not blocked
  run -1 cu_row_capped_until "$(printf '1\t-\t10080\t98\t%s\t-\t-\t-' "$past")" 95 "$now"
  # below threshold → not blocked
  run -1 cu_row_capped_until "$(printf '1\t-\t10080\t50\t%s\t-\t-\t-' "$future")" 95 "$now"
}
