#!/usr/bin/env bash
# tests/fm-chair-runway.test.sh - behavior tests for bin/fm-chair-runway.sh.
#
# Every source is driven through the script's documented seams, so no test
# reaches a live pool and the OR rule is pinned directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chair-runway-tests)
SCRIPT="$ROOT/bin/fm-chair-runway.sh"

PROBE="$TMP_ROOT/probe.sh"
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
# <url> <model> <timeout> -> prints an HTTP-ish code
printf '%s\n' "${FM_TEST_PROBE_CODE:-200}"
SH
chmod +x "$PROBE"

HEALTH="$TMP_ROOT/health.json"
ACCOUNTS="$TMP_ROOT/accounts.json"
GROK="$TMP_ROOT/grok.json"

write_health() {  # <routable> <configured>
  printf '{"pool":{"routable":%s,"configured":%s}}\n' "$1" "$2" > "$HEALTH"
}

write_accounts() {  # <requiresReauth-count>
  local n=$1 i out='['
  for ((i = 0; i < n; i++)); do
    [ "$i" -gt 0 ] && out+=','
    out+="{\"name\":\"acct$i\",\"requiresReauth\":true,\"tokenStatus\":\"expired\"}"
  done
  out+=']'
  printf '%s\n' "$out" > "$ACCOUNTS"
}

write_grok() {  # <percent>
  cat > "$GROK" <<EOF
{"providers":[{"provider":"grok","quotaSemantics":{"effectiveAvailability":[{"scope":"all_products","effectivePercentRemaining":$1}]}}]}
EOF
}

run_runway() {
  FM_CHAIR_PROBE_CMD="$PROBE" \
  FM_CHAIR_CCFLARE_FIXTURE=1 \
  FM_CHAIR_CCFLARE_HEALTH_JSON="$HEALTH" \
  FM_CHAIR_CCFLARE_ACCOUNTS_JSON="$ACCOUNTS" \
  FM_CHAIR_GROK_JSON="$GROK" \
  bash "$SCRIPT" "$@"
}

base_fixtures() {
  write_health 0 11
  write_accounts 0
  write_grok 50
}

# --- OR rule ----------------------------------------------------------------

base_fixtures
write_health 0 11
write_accounts 11
write_grok 50
out=$(FM_TEST_PROBE_CODE=200 run_runway)
assert_contains "$out" "fable=green" "8317 green alone makes Fable green"
assert_contains "$out" "pool8317=green" "8317 probe 200 is green"
assert_contains "$out" "ccflare=red" "0 routable ccflare is red"
assert_contains "$out" "needs_reauth=11" "ccflare reauth count reported"
assert_contains "$out" "names=acct0,acct1" "ccflare reauth names reported"
pass "8317 green + ccflare red -> fable green"

write_health 3 11
write_accounts 0
write_grok 50
out=$(FM_TEST_PROBE_CODE=401 run_runway)
assert_contains "$out" "pool8317=red" "probe 401 is red"
assert_contains "$out" "ccflare=green" "routable>0 ccflare is green"
assert_contains "$out" "fable=green" "ccflare green alone makes Fable green"
pass "8317 red + ccflare green -> fable green"

write_health 0 11
write_accounts 11
write_grok 50
out=$(FM_TEST_PROBE_CODE=401 run_runway)
assert_contains "$out" "fable=red" "both red -> fable red"
assert_contains "$out" "reason=no_fable_source" "both red names the reason"
pass "8317 red + ccflare red -> fable red"

out=$(FM_TEST_PROBE_CODE=000 run_runway)
assert_contains "$out" "pool8317=unknown" "probe no-response is unknown"
assert_contains "$out" "fable=unknown" "one unknown and one red -> fable unknown"
pass "unknown is never rendered as green or red"

out=$(FM_TEST_PROBE_CODE=503 run_runway)
assert_contains "$out" "pool8317=unknown" "probe 5xx is unknown"
pass "probe 5xx is unknown"

# --- grok floor -------------------------------------------------------------

write_health 3 11
write_accounts 0
write_grok 11
out=$(FM_TEST_PROBE_CODE=200 run_runway)
assert_contains "$out" "grok=green" "grok above floor is green"
assert_contains "$out" "grok_pct=11" "grok percent reported"

write_grok 9
out=$(FM_TEST_PROBE_CODE=200 run_runway)
assert_contains "$out" "grok=red" "grok below floor is red"
pass "grok floor applies at 10 percent"

printf 'fm-chair-runway tests passed\n'