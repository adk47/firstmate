#!/usr/bin/env bats
# Tests for scripts/lib/codex-quota.sh — the measured-quota helpers that
# replace the "freshest snapshot = current account" inference which caused
# the 2026-08-05/06 incident (see the file header for the full story). Every
# function here is PURE (reads stdin/files, echoes data, never calls
# codex/openclaw/ssh), so this suite sources the lib directly and stubs
# nothing on PATH — there is nothing live to accidentally call. All state
# paths are pinned into a mktemp sandbox regardless, to match this repo's
# hermetic-bats convention (scripts/tests/codex-usage.bats).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/codex-quota.sh"
FIXTURE="$HYDRA_REPO/scripts/tests/fixtures/codex-app-server-ratelimits.jsonl"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  DIR="$TEST_TMPDIR/measure"; export DIR
  LEDGER="$TEST_TMPDIR/ledger.tsv"; export LEDGER
  mkdir -p "$DIR"
  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# ── cq_parse_ratelimits ────────────────────────────────────────

@test "cq_parse_ratelimits: real fixture parses into the 10-field row" {
  run cq_parse_ratelimits probe-live 1786020154 < "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | awk -F'\t' '{print NF}')" -eq 10 ]
  [ "$(printf '%s' "$output" | cut -f1)"  = "1786020154" ]   # measured_at = passed-in now
  [ "$(printf '%s' "$output" | cut -f3)"  = "10080" ]        # w1_min
  [ "$(printf '%s' "$output" | cut -f4)"  = "100" ]          # w1_pct
  [ "$(printf '%s' "$output" | cut -f5)"  = "1786160294" ]   # w1_reset
  [ "$(printf '%s' "$output" | cut -f9)"  = "probe-live" ]   # source
  [ "$(printf '%s' "$output" | cut -f10)" = "pro" ]          # plan
}

@test "cq_parse_ratelimits: windows are read BY windowDurationMins, not position (weekly-as-primary shape)" {
  # Observed live 7.x shape (2026-07-21, again 2026-08-06): the weekly window
  # can arrive as 'secondary' with 'primary' null. The set is not stable — a
  # positional reader would mislabel this.
  local variant="$TEST_TMPDIR/variant.jsonl"
  cat > "$variant" <<'JSON'
{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1786160294},"planType":"pro","rateLimitReachedType":null}}}
JSON
  run cq_parse_ratelimits probe-live 1786020154 < "$variant"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f3)" = "-" ]      # w1 (primary) absent
  [ "$(printf '%s' "$output" | cut -f6)" = "10080" ]  # w2 (secondary) carries the weekly window
  [ "$(printf '%s' "$output" | cut -f7)" = "42" ]
}

@test "cq_parse_ratelimits: ignores rateLimitsByLimitId sub-limits (codex_bengalfox trap)" {
  # The real fixture's codex_bengalfox sub-limit sits at 0% while the account
  # is fully spent (100%). Averaging/mining across it would report a capped
  # account as healthy.
  run cq_parse_ratelimits probe-live 1786020154 < "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f4)" = "100" ]
}

@test "cq_parse_ratelimits: empty stdin -> no output, exit 0" {
  run cq_parse_ratelimits probe-live 1786020154 < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cq_parse_ratelimits: valid JSON with no matching result -> no output, exit 0" {
  printf '{}\n' > "$TEST_TMPDIR/no-result.json"
  run cq_parse_ratelimits probe-live 1786020154 < "$TEST_TMPDIR/no-result.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Found while writing this suite and FIXED in the source: `jq -rs` exits 5 on
# non-JSON stdin and `2>/dev/null` swallows only its stderr, not its status, so
# this used to propagate rc 5 against the function's own documented contract.
# That matters because codex-account-rotate.sh runs under `set -e` — a garbled
# probe response would have aborted a rotation instead of degrading to the
# honest `unknown` that every caller is built to handle. Malformed input must
# be indistinguishable from absent input.
@test "cq_parse_ratelimits: malformed (non-JSON) stdin -> no output, exit 0 (contract holds)" {
  echo 'not json at all' > "$TEST_TMPDIR/garbage.txt"
  run cq_parse_ratelimits probe-live 1786020154 < "$TEST_TMPDIR/garbage.txt"
  [ -z "$output" ]
  [ "$status" -eq 0 ]
}

@test "cq_parse_ratelimits: garbage parses to the SAME unknown state as absent input" {
  # The property that actually protects callers: whatever the probe coughs up,
  # a caller cannot end up treating it as a healthy account.
  echo 'not json at all' > "$TEST_TMPDIR/garbage.txt"
  run cq_parse_ratelimits probe-live 1786020154 < "$TEST_TMPDIR/garbage.txt"
  [ "$status" -eq 0 ]
  run cq_row_state "$output" 95 60 1786020154
  [ "$output" = "unknown" ]
}

# ── THE AUG-6 REGRESSION ANCHOR ─────────────────────────────────
# This is the most important test in the suite. This exact row (13 days
# stale, reset already in the past) is what the old caller in codex-usage.sh
# read as "not capped" == "healthy", rotating the entire fleet onto an
# already-exhausted account (see the file header incident writeup). If this
# test ever passes with state=healthy, the regression is back.

@test "AUG-6 REGRESSION ANCHOR: a 13-day-stale row with a lapsed reset is unknown, NEVER healthy" {
  local row now
  row=$'1784903410\t-\t10080\t95.0\t1785258161\t-\t-\t-\tarchive\tpro'
  now=1786020154
  run cq_row_state "$row" 95 60 "$now"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  [ "$output" != "healthy" ]
}

# ── cq_row_state tri-state matrix ───────────────────────────────

@test "cq_row_state: fresh + high pct -> capped" {
  local now=1786020154
  local row; row=$(printf '%s\t-\t10080\t99\t%s\t-\t-\t-\tprobe-live\tpro' "$now" "$(( now + 100000 ))")
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "capped" ]
}

@test "cq_row_state: fresh + low pct -> healthy" {
  local now=1786020154
  local row; row=$(printf '%s\t-\t10080\t4\t%s\t-\t-\t-\tprobe-live\tpro' "$now" "$(( now + 100000 ))")
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "healthy" ]
}

@test "cq_row_state: fresh but reached_type set -> capped even under the pct floor" {
  local now=1786020154
  local row; row=$(printf '%s\trate_limit_reached\t10080\t10\t%s\t-\t-\t-\tprobe-live\tpro' "$now" "$(( now + 100000 ))")
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "capped" ]
}

@test "cq_row_state: stale measured_at -> unknown" {
  local now=1786020154
  local row; row=$(printf '%s\t-\t10080\t10\t%s\t-\t-\t-\tprobe-live\tpro' "$(( now - 7200 ))" "$(( now + 100000 ))")
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "unknown" ]
}

# Clock-rollback guard: a measurement dated in the FUTURE satisfies the
# freshness comparison trivially (now - ts goes negative), so without an
# explicit check a stale 0%-used row would read `healthy` forever after a
# rollback — and _check_usage_cap would veto rotation during a real cap,
# calling it somebody else's auth.order noise.
@test "cq_parse_ratelimits: a window missing usedPercent is '-', not a synthetic 0" {
  # `// 0` on a partial window (resetsAt present, usedPercent null) manufactured
  # a fresh 0%-used row that cq_row_state read as `healthy`, letting
  # _check_usage_cap dismiss a real cap signature as auth.order noise.
  local partial="$TEST_TMPDIR/partial.jsonl"
  cat > "$partial" <<'JSON'
{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"windowDurationMins":10080,"resetsAt":1786160294},"secondary":null,"planType":"pro","rateLimitReachedType":null}}}
JSON
  run cq_parse_ratelimits probe-live 1786020154 < "$partial"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f4)" = "-" ]
  run cq_row_state "$output" 95 60 1786020154
  [ "$output" = "unknown" ]
  [ "$output" != "healthy" ]
}

@test "cq_parse_ratelimits: a genuine 0% is still 0, not '-'" {
  # The absent-marker change must not swallow a real zero — jq's // fires on
  # null/false only, and 0 is truthy.
  local zero="$TEST_TMPDIR/zero.jsonl"
  cat > "$zero" <<'JSON'
{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1786160294},"secondary":null,"planType":"pro","rateLimitReachedType":null}}}
JSON
  run cq_parse_ratelimits probe-live 1786020154 < "$zero"
  [ "$(printf '%s' "$output" | cut -f4)" = "0" ]
  run cq_row_state "$output" 95 60 1786020154
  [ "$output" = "healthy" ]
}

@test "cq_row_state: a FUTURE-dated measurement is unknown, never healthy" {
  local now=1786020154
  local future=$(( now + 7200 ))
  local row
  row="$(printf '%s\t-\t10080\t10\t%s\t-\t-\t-\tprobe-live\tpro' "$future" "$(( now + 90000 ))")"
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "unknown" ]
  [ "$output" != "healthy" ]
}

@test "cq_row_state: benign NTP slew inside the tolerance still reads healthy" {
  # The guard must not flip a normal reading to unknown over a second or two of
  # clock jitter between the writer and the reader.
  local now=1786020154
  local row
  row="$(printf '%s\t-\t10080\t10\t%s\t-\t-\t-\tprobe-live\tpro' "$(( now + 5 ))" "$(( now + 90000 ))")"
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "healthy" ]
}

@test "cq_row_state: empty row -> unknown" {
  run cq_row_state "" 95 60 1786020154
  [ "$output" = "unknown" ]
}

@test "cq_row_state: malformed measured_at -> unknown" {
  local now=1786020154
  local row; row=$(printf 'notanumber\t-\t10080\t10\t%s\t-\t-\t-\tprobe-live\tpro' "$(( now + 100000 ))")
  run cq_row_state "$row" 95 60 "$now"
  [ "$output" = "unknown" ]
}

# ── cq_row_load ──────────────────────────────────────────────────

@test "cq_row_load: returns the max across live windows" {
  local now=1786020154
  local row; row=$(printf '%s\t-\t300\t10\t%s\t10080\t42\t%s\tprobe-live\tpro' \
    "$now" "$(( now + 100 ))" "$(( now + 200000 ))")
  run cq_row_load "$row" "$now"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "cq_row_load: ignores a window whose reset has lapsed" {
  local now=1786020154
  local row; row=$(printf '%s\t-\t300\t99\t%s\t10080\t5\t%s\tprobe-live\tpro' \
    "$now" "$(( now - 100 ))" "$(( now + 200000 ))")
  run cq_row_load "$row" "$now"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "cq_row_load: rc 1 when no window is live" {
  local now=1786020154
  local row; row=$(printf '%s\t-\t300\t99\t%s\t10080\t5\t%s\tprobe-live\tpro' \
    "$now" "$(( now - 100 ))" "$(( now - 200 ))")
  run cq_row_load "$row" "$now"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── measurement store (cq_measure_write / read) ──────────────────

@test "cq_measure_write / cq_measure_read: round-trip and the file is mode 600" {
  cq_measure_write "$DIR" "openai-codex:aaron@muso.ai" $'123\t-\t10080\t10\t456\t-\t-\t-\tprobe-live\tpro'
  run cq_measure_read "$DIR" "openai-codex:aaron@muso.ai"
  [ "$status" -eq 0 ]
  [ "$output" = $'123\t-\t10080\t10\t456\t-\t-\t-\tprobe-live\tpro' ]
  local path; path="$(cq_measure_path "$DIR" "openai-codex:aaron@muso.ai")"
  local mode
  # GNU stat FIRST, BSD as the fallback — never the other way round. `stat -f`
  # is a valid GNU flag meaning "filesystem status", so on Linux the BSD-first
  # form prints a block-device report instead of a mode and the `||` fallback
  # appends to it, yielding garbage. macOS has no `-c`, so it errors cleanly and
  # falls through. Same idiom as codex-account-rotate.bats:141.
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
  [ "$mode" = "600" ]
}

@test "cq_measure_read: rc 1 when absent" {
  run cq_measure_read "$DIR" "openai-codex:nobody@x.com"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── active-account ledger ────────────────────────────────────────

@test "cq_ledger_account_at: correct account across a rotation boundary" {
  cq_ledger_append "$LEDGER" "openai-codex:aaron@muso.ai" "boot" 1000
  cq_ledger_append "$LEDGER" "openai-codex:me.com" "rotate" 2000
  run cq_ledger_account_at "$LEDGER" 1500
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:aaron@muso.ai" ]
  run cq_ledger_account_at "$LEDGER" 2500
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:me.com" ]
}

@test "cq_ledger_account_at: rc 1 before the first entry" {
  cq_ledger_append "$LEDGER" "openai-codex:aaron@muso.ai" "boot" 1000
  run cq_ledger_account_at "$LEDGER" 500
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "cq_ledger_account_at: skips malformed lines" {
  {
    printf 'not-a-timestamp\tsomekey\tbadrow\n'
    printf '1000\t\tempty-key-row\n'
    printf '2000\topenai-codex:me.com\trotate\n'
  } > "$LEDGER"
  run cq_ledger_account_at "$LEDGER" 5000
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:me.com" ]
}

@test "cq_ledger_account_at: picks the LAST entry at or before the timestamp" {
  cq_ledger_append "$LEDGER" "openai-codex:a@x.com" "r1" 1000
  cq_ledger_append "$LEDGER" "openai-codex:b@x.com" "r2" 1000
  run cq_ledger_account_at "$LEDGER" 1000
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:b@x.com" ]
}

@test "cq_ledger_count_since: counts entries at/after an epoch" {
  cq_ledger_append "$LEDGER" "a" "r" 1000
  cq_ledger_append "$LEDGER" "b" "r" 2000
  cq_ledger_append "$LEDGER" "c" "r" 3000
  run cq_ledger_count_since "$LEDGER" 2000
  [ "$output" = "2" ]
}

@test "cq_ledger_count_since: filters by reason substring when given" {
  cq_ledger_append "$LEDGER" "a" "cap-rotate" 1000
  cq_ledger_append "$LEDGER" "b" "manual" 2000
  cq_ledger_append "$LEDGER" "c" "cap-rotate" 3000
  run cq_ledger_count_since "$LEDGER" 0 "cap-rotate"
  [ "$output" = "2" ]
}

# ── evidence formatter enforcement ────────────────────────────────
# The mechanical form of "never assert a fact the system did not measure":
# every line containing a percent sign must also carry "measured", and the
# unknown case must carry no percent sign at all.

@test "cq_format_evidence: healthy/capped/unknown lines obey the % <-> measured rule" {
  local now=1786020154
  local healthy capped
  healthy="$(printf '%s\t-\t10080\t10\t%s\t-\t-\t-\tprobe-live\tpro' "$now" "$(( now + 100000 ))")"
  capped="$(printf '%s\t-\t10080\t99\t%s\t-\t-\t-\tprobe-live\tpro' "$now" "$(( now + 100000 ))")"

  run cq_format_evidence "acct-healthy" "$healthy" "$now"
  [ "$status" -eq 0 ]
  case "$output" in *%*) [[ "$output" == *"measured"* ]] ;; *) false ;; esac

  run cq_format_evidence "acct-capped" "$capped" "$now"
  [ "$status" -eq 0 ]
  case "$output" in *%*) [[ "$output" == *"measured"* ]] ;; *) false ;; esac

  run cq_format_evidence "acct-unknown" "" "$now"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNKNOWN"* ]]
  case "$output" in *%*) false ;; esac
}
