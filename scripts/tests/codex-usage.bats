#!/usr/bin/env bats
# Tests for scripts/codex-usage-report.sh + scripts/lib/codex-usage.sh — the
# twice-daily Codex OAuth usage report (hydra#382). The cron agent runs the
# report script and relays its stdout to a Slack DM; this suite proves the
# script reads the real {profiles:{...}} object shape correctly (the original
# bug iterated the root object and died on the `version` number), degrades
# honestly when no fresh measurement exists, and never prints access/refresh
# tokens.
#
# 2026-08-06 rewrite: the TEXT report no longer renders per-window bullets
# from a fleet-wide rollout snapshot attributed to "whichever account is
# active" — rollouts carry no account identity on openclaw 7.x, so that
# heuristic put one subscription's numbers under every account and reported
# two untouched Pro subscriptions as 95-97% spent when a direct probe measured
# 100% / 4% / 0%. The text path now renders ONE evidence line per account from
# that account's OWN `.measure.tsv` file via cq_format_evidence() in
# scripts/lib/codex-quota.sh — see that file's header for the row format and
# the full incident writeup. emit_json (the `--json` path) was NOT touched by
# this rewrite and still reads the older `.snapshot.tsv` archive.
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

# measure <email> <pct> <reset_off> [age] [src] — write a one-row
# .measure.tsv for <email> (mirrors the identically-named helper in
# scripts/tests/codex-account-rotate.bats; kept in sync by hand since the two
# suites don't share a fixture library). The row's ONLY window is the weekly
# one (10080) — codex-quota-refresh.sh's real rows can carry a second window,
# but cq_format_evidence only ever surfaces the max live window, so one is
# enough to drive every text-report assertion in this file.
measure() {
  local email="$1" pct="$2" reset_off="$3" age="${4:-0}" src="${5:-probe-live}"
  local now; now=$(date +%s)
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\t-\t10080\t%s\t%s\t-\t-\t-\t%s\tpro\n' \
    "$(( now - age ))" "$pct" "$(( now + reset_off ))" "$src" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_${email/@/_}.measure.tsv"
}

run_report() { run env CODEX_USAGE_ROOT="$ROOT" "$SCRIPT" "$@"; }

# ── integration: report script ────────────────────────────────

@test "happy path: active shows its own measured %, standby shows quota UNKNOWN, non-codex filtered, no tables" {
  # 2d 3h 30m, deliberately NOT the 2d 3h boundary: cq_human_in truncates, so
  # an exact-boundary offset renders "2d 3h" only until wall-clock drifts a
  # second past it between writing the fixture and rendering the report —
  # observed flaking 1-in-3 locally. The half-hour margin absorbs that.
  measure "aaron@muso.ai" 42 185400 300
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '*aaron@muso.ai* — active'
  echo "$output" | grep -q 'aaron@muso.ai — 42% used (measured 5m ago, probe-live)'
  echo "$output" | grep -q 'resets in 2d 3h'
  echo "$output" | grep -qF '*aaronkaufman@me.com* — idle standby'
  echo "$output" | grep -q 'aaronkaufman@me.com — quota UNKNOWN (no measurement on record)'
  # only the two codex accounts appear; the anthropic profile does not
  if echo "$output" | grep -qi 'anthropic'; then echo "the anthropic profile leaked into codex-usage output" >&2; false; fi
  # mrkdwn, not a markdown table
  ! echo "$output" | grep -q '|'
}

@test "no measurements on record: both accounts degrade to 'quota UNKNOWN', exit 0" {
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '*aaron@muso.ai* — active'
  echo "$output" | grep -q 'aaron@muso.ai — quota UNKNOWN (no measurement on record)'
  echo "$output" | grep -qF '*aaronkaufman@me.com* — idle standby'
  echo "$output" | grep -q 'aaronkaufman@me.com — quota UNKNOWN (no measurement on record)'
}

@test "stale measurement (older than CQ_MEASURE_MAX_AGE_MIN): active degrades to 'quota UNKNOWN', percentage never appears" {
  # codex-quota.sh's default CQ_MEASURE_MAX_AGE_MIN is 60 minutes; 4000s (~67m)
  # is stale under that default without depending on it being sourced here.
  measure "aaron@muso.ai" 5 3600 4000
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '*aaron@muso.ai* — active'
  echo "$output" | grep -q 'aaron@muso.ai — quota UNKNOWN'
  ! echo "$output" | grep -q '5% used'
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
  if echo "$output" | grep -q 'SECRET_ACCESS'; then echo "the raw access token leaked into text output" >&2; false; fi
  if echo "$output" | grep -q 'SECRET_REFRESH'; then echo "the raw refresh token leaked into text output" >&2; false; fi
  run_report --json
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'SECRET_ACCESS'; then echo "the raw access token leaked into json output" >&2; false; fi
  ! echo "$output" | grep -q 'SECRET_REFRESH'
}

@test "--json: well-formed, active_account correct, reads the SAME measurements as the text report" {
  # --json and the text report must render from one source. While emit_json
  # still read the old .snapshot.tsv archive and emit_text read .measure.tsv,
  # the two could report different numbers for the same account — the exact
  # class of divergence the 2026-08-06 rewrite exists to remove.
  measure "aaron@muso.ai" 12.5 90000
  run_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tz == "America/Chicago"' >/dev/null
  echo "$output" | jq -e '.active_account == "openai-codex:aaron@muso.ai"' >/dev/null
  echo "$output" | jq -e '.accounts | length == 2' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaron@muso.ai") | .role=="active" and .freshness=="healthy" and .used_percent_weekly==12.5' >/dev/null
  # An unmeasured account is "unknown" — never a number, and never silently
  # absent, because an omitted account reads as "not a problem".
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .role=="standby" and .freshness=="unknown" and .used_percent_weekly==null' >/dev/null
}

@test "--json: a partial second window must not erase a valid first one" {
  # cq_parse_ratelimits emits "-" for a missing usedPercent. `--argjson p -` is
  # a jq parse error, and the `|| out="[]"` fallback then discarded windows
  # already accumulated — so one incomplete window nulled the whole --json
  # report, including used_percent_weekly for a window that parsed fine.
  local now; now=$(date +%s)
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\t-\t10080\t42\t%s\t300\t-\t%s\tprobe-live\tpro\n' \
    "$now" "$(( now + 185400 ))" "$(( now + 3600 ))" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_aaron_muso.ai.measure.tsv"
  run_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.accounts[] | select(.email=="aaron@muso.ai") | .used_percent_weekly==42' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaron@muso.ai") | (.windows|length)==1' >/dev/null
}

@test "--json and text agree on every account (single source of truth)" {
  measure "aaron@muso.ai"        100 90000
  measure "aaronkaufman@me.com"    0 90000
  run_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.accounts[] | select(.email=="aaron@muso.ai") | .used_percent_weekly==100 and .freshness=="capped"' >/dev/null
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .used_percent_weekly==0 and .freshness=="healthy"' >/dev/null
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'aaron@muso.ai — 100% used'
  echo "$output" | grep -q 'aaronkaufman@me.com — 0% used'
}

@test "unknown argument exits 2" {
  run_report --bogus
  [ "$status" -eq 2 ]
}

@test "per-account independence: three accounts each render their own measurement, none bleeds into another (2026-08-06 anchor)" {
  # REPLACES "freshest snapshot wins across multiple rollouts", which policed
  # the retired rollout-attribution heuristic (rollouts carry no account
  # identity, so the freshest one used to be attributed to whichever account
  # was nominally active). The property that matters now is independence:
  # each account's number comes ONLY from its own measurement file. This is
  # the regression anchor for the 2026-08-06 incident, which reported
  # aaron@muso.ai/gmail/me.com at 95%/97%/95% (all really aaron@muso.ai's
  # borrowed number) when a direct probe measured 100%/4%/0%.
  cat > "$CANON/auth-profiles.json" <<'JSON'
{"version":1,"profiles":{
  "openai-codex:aaron@muso.ai":{"provider":"openai-codex","type":"oauth","email":"aaron@muso.ai","chatgptPlanType":"pro"},
  "openai-codex:aarondkaufman@gmail.com":{"provider":"openai-codex","type":"oauth","email":"aarondkaufman@gmail.com","chatgptPlanType":"pro"},
  "openai-codex:aaronkaufman@me.com":{"provider":"openai-codex","type":"oauth","email":"aaronkaufman@me.com","chatgptPlanType":"pro"}
}}
JSON
  measure "aaron@muso.ai" 100 90000 300
  measure "aarondkaufman@gmail.com" 4 90000 300
  measure "aaronkaufman@me.com" 0 90000 300
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'aaron@muso.ai — 100% used'
  echo "$output" | grep -q 'aarondkaufman@gmail.com — 4% used'
  echo "$output" | grep -q 'aaronkaufman@me.com — 0% used'
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

@test "window-keyed regression (2026-07-21): a measurement whose ONLY window is weekly (10080) still renders" {
  # OpenAI has moved the weekly window between primary/secondary before
  # (observed 2026-07-21 and again 2026-08-06) — the measurement row format
  # is window-keyed (w1_min/w1_pct/w1_reset), not positional, so a row
  # carrying only the weekly window (no 5h window at all) must still render
  # cleanly rather than mislabeling or dropping it.
  measure "aaron@muso.ai" 98 200000 600
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'aaron@muso.ai — 98% used'
}

@test "rate_limit_reached_type in the measurement is surfaced as CAPPED in the text report" {
  local now; now="$(date +%s)"
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\tsecondary_window\t10080\t40\t%s\t-\t-\t-\tprobe-live\tpro\n' \
    "$(( now - 300 ))" "$(( now + 200000 ))" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_aaron_muso.ai.measure.tsv"
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'aaron@muso.ai — 40% used'
  echo "$output" | grep -q 'CAPPED'
}

@test "a STANDBY renders its own measured quota, in both text and json" {
  # The 2026-08-06 failure was specifically that standby accounts had no real
  # numbers — they were inferred from whichever rollout was freshest fleet-wide.
  # A standby must now carry its own measurement, with its own age, in both
  # renderers.
  measure "aaronkaufman@me.com" 97 90000 1800
  run_report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'aaronkaufman@me.com — 97% used (measured 30m ago,'
  run_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .freshness=="capped" and .used_percent_weekly==97' >/dev/null
  # A stale .snapshot.tsv from the RETIRED inference layer must not resurrect
  # itself into either renderer.
  local now; now="$(date +%s)"
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\t-\t10080\t3\t%s\t-\t-\t-\n' "$(( now - 7200 ))" "$(( now + 90000 ))" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_aaronkaufman_me.com.snapshot.tsv"
  run_report --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.accounts[] | select(.email=="aaronkaufman@me.com") | .used_percent_weekly==97' >/dev/null
}

# The two "rotation-boundary" tests below used to police the retired
# rollout-attribution heuristic (a rotation-stamp epoch gated whether a
# fleet-wide rollout snapshot could be attributed to the newly-active
# account). The text report no longer attributes anything by timestamp —
# every account reads its own `.measure.tsv` — so that boundary concept is
# gone from this path. Replaced with the two properties that now matter:
# a stale reading degrades to UNKNOWN on its own account's age (no rotation
# stamp involved), and staleness stays account-scoped rather than leaking
# into a sibling account's line.

@test "a stale measurement for the ACTIVE account renders UNKNOWN, not an old percentage" {
  # 4000s (~67m) is stale under codex-quota.sh's default 60m
  # CQ_MEASURE_MAX_AGE_MIN without depending on it being sourced here.
  echo "openai-codex:aaronkaufman@me.com" > "$TEST_TMPDIR/active-account"
  measure "aaronkaufman@me.com" 98 3600 4000
  run env CODEX_USAGE_ROOT="$ROOT" \
      CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account" "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '*aaronkaufman@me.com* — active'
  echo "$output" | grep -q 'aaronkaufman@me.com — quota UNKNOWN'
  ! echo "$output" | grep -q '98% used'
}

@test "one account's stale measurement never leaks into a sibling account's line" {
  echo "openai-codex:aaronkaufman@me.com" > "$TEST_TMPDIR/active-account"
  measure "aaron@muso.ai" 98 3600 4000          # stale
  measure "aaronkaufman@me.com" 42 600 300      # fresh
  run env CODEX_USAGE_ROOT="$ROOT" \
      CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/active-account" "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'aaronkaufman@me.com — 42% used'
  echo "$output" | grep -q 'aaron@muso.ai — quota UNKNOWN'
  ! echo "$output" | grep -q '98% used'
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
