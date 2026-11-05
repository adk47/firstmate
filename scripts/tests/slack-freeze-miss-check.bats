#!/usr/bin/env bats
# Tests for scripts/slack-freeze-miss-check.sh (MUS-29976): after a gateway
# "host timing gap" (process frozen), list Slack @mentions the bot never logged
# as `[slack] Inbound app_mention`, and flag them. Flag only, never replay.
#
# journalctl, curl, logger and muso are PATH/env-stubbed: no Slack call, no real
# journal line, no real #clio_devops post. curl's argv is recorded so the token
# can be asserted absent from it; its stdin (`--config -`) is recorded separately.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/slack-freeze-miss-check.sh"
TOKEN="xoxb-TESTTOKEN-DO-NOT-LEAK"
BODY="SECRET-MESSAGE-BODY-9f3"

_now() { if command -v gdate >/dev/null 2>&1; then gdate "$@"; else date "$@"; fi; }

setup() {
  T="$(mktemp -d)"; export T
  # _resolve_token prefers an inherited MUSO_SLACK_BOT_TOKEN_* over the env file: never let a live one in.
  local v; for v in $(compgen -e | grep '^MUSO_SLACK_BOT_TOKEN_'); do unset "$v"; done
  mkdir -p "$T/bin" "$T/state" "$T/fx"
  export SFMC_STATE_DIR="$T/state"
  export SFMC_UNITS="openclaw-gateway-main"
  export SFMC_CONFIG_MAIN="$T/openclaw.json"
  export MUSO_SLACK_ENV_FILE="$T/muso-slack.env"
  export SLACK_NOTIFY_LIVE_ENV_FILE="$T/never-live.env"
  export MUSO_BIN="$T/bin/muso"
  export CURL_ARGV="$T/curl-argv" CURL_STDIN="$T/curl-stdin" MUSO_CALLS="$T/muso-calls" LOGGER_CALLS="$T/logger-calls"
  : > "$CURL_ARGV"; : > "$CURL_STDIN"; : > "$MUSO_CALLS"; : > "$LOGGER_CALLS"
  printf 'MUSO_SLACK_BOT_TOKEN_SCOUT=%s\nMUSO_SLACK_BOT_TOKEN_DEVOPS=devops-tok\n' "$TOKEN" > "$MUSO_SLACK_ENV_FILE"
  cat > "$SFMC_CONFIG_MAIN" <<'J'
{"channels":{"slack":{"accounts":{"scout":{"botToken":{"source":"env","provider":"hydra-env","id":"MUSO_SLACK_BOT_TOKEN_SCOUT"}},
 "unbound":{"botToken":{"source":"env","provider":"hydra-env","id":"MUSO_SLACK_BOT_TOKEN_NOPE"}}}}},
 "bindings":[{"agentId":"scout","match":{"channel":"slack","accountId":"scout"}}]}
J
  # thaw = 10 min ago, frozen 5 min; mention landed mid-freeze
  THAW=$(( $(_now +%s) - 600 ))
  export THAW MENTION_TS="$(( THAW - 120 )).365029"
  _stubs
  _journal_gap
  _slack_fixtures mention
}

teardown() { rm -rf "$T"; }

_stubs() {
  cat > "$T/bin/journalctl" <<'S'
#!/bin/bash
# --since "@<epoch>" => the inbound-line query; anything else => the gap query.
# fx/inbound_rc / fx/gaps_rc: exit non-zero with output on stderr (a real journalctl failure).
case "$*" in
  *--until*) [ -e "$T/fx/inbound_rc" ] && { echo "journalctl: boom" >&2; exit "$(cat "$T/fx/inbound_rc")"; }
             cat "$T/fx/inbound" 2>/dev/null ;;
  *) [ -e "$T/fx/gaps_rc" ] && { echo "journalctl: boom" >&2; exit "$(cat "$T/fx/gaps_rc")"; }
     cat "$T/fx/gaps" 2>/dev/null ;;
esac
S
  cat > "$T/bin/logger" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$LOGGER_CALLS"
S
  cat > "$T/bin/muso" <<'S'
#!/bin/bash
printf 'CALL %s\n' "$*" >> "$MUSO_CALLS"
prev=""; for a in "$@"; do [ "$prev" = "--text" ] && printf '%s' "$a" > "$T/last-alert"; prev="$a"; done
[ -e "$T/fx/muso_fail" ] && exit 1
exit 0
S
  cat > "$T/bin/curl" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
url=""; for a in "$@"; do case "$a" in https://*|http://*) url="$a";; esac; done
m="${url##*/}"
# A paged call (cursor=<c>) reads fx/<method>.<c>; the first page reads fx/<method>.
for a in "$@"; do case "$a" in cursor=?*) m="$m.${a#cursor=}";; esac; done
if [ -e "$T/fx/ratelimit" ]; then printf '{"ok":false,"error":"ratelimited"}\n429'; exit 0; fi
if [ -r "$T/fx/$m" ]; then cat "$T/fx/$m"; else printf '{"ok":false,"error":"no_fixture_%s"}' "$m"; fi
printf '\n200'
S
  chmod +x "$T"/bin/*
  export PATH="$T/bin:$PATH"
}

_iso() { _now -u -d "@$1" +%Y-%m-%dT%H:%M:%S+00:00; }

_journal_gap() {
  printf '%s host node[1]: [health] host timing gap detected: process was frozen ~300000ms; restarting channels when idle and refreshing health\n' \
    "$(_iso "$THAW")" > "$T/fx/gaps"
  : > "$T/fx/inbound"
}

_slack_fixtures() {
  echo '{"ok":true,"user_id":"UBOT1"}' > "$T/fx/auth.test"
  echo '{"ok":true,"channels":[{"id":"C0ARS7XMY93"}],"response_metadata":{"next_cursor":""}}' > "$T/fx/users.conversations"
  echo '{"ok":true,"permalink":"https://muso.slack.com/archives/C0ARS7XMY93/p1"}' > "$T/fx/chat.getPermalink"
  if [ "${1:-}" = mention ]; then
    printf '{"ok":true,"messages":[{"ts":"%s","user":"U02S7C96CGN","text":"hey <@UBOT1> %s"},{"ts":"%s.000100","user":"U02S7C96CGN","text":"no mention here"}]}' \
      "$MENTION_TS" "$BODY" "$((THAW - 100))" > "$T/fx/conversations.history"
  else
    echo '{"ok":true,"messages":[]}' > "$T/fx/conversations.history"
  fi
}

_slack_fixtures_empty_history() { echo '{"ok":true,"messages":[]}' > "$T/fx/conversations.history"; }

# _inbound_line [epoch]: journal time of the Inbound line; default = 1s after the fixture mention.
_inbound_line() {
  printf '%s host node[1]: [slack] Inbound app_mention slack:T1:channel:C0ARS7XMY93:user:U02S7C96CGN -> bot:UBOT1 (group, 20 chars)\n' \
    "$(_iso "${1:-$((THAW - 119))}")" >> "$T/fx/inbound"
}

@test "script exists and is executable (red on base)" {
  [ -x "$SCRIPT" ]
}

@test "(a) gap + mention with no Inbound line -> one miss line + one alert, no message text" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^slack-freeze-miss: possibly missed inbound')" -eq 1 ]
  printf '%s\n' "$output" | grep -q "unit=openclaw-gateway-main account=scout channel=C0ARS7XMY93 ts=$MENTION_TS"
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
  grep -q 'https://muso.slack.com/archives/C0ARS7XMY93/p1' "$T/last-alert"
  if grep -rq "$BODY" "$T/last-alert" "$LOGGER_CALLS"; then false; fi
  [[ "$output$stderr" != *"$BODY"* ]]
  [ "$(wc -l < "$LOGGER_CALLS")" -eq 1 ]
}

@test "(b) matching Inbound line -> no miss, no alert" {
  _inbound_line
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"possibly missed"* ]]
  [ ! -s "$MUSO_CALLS" ]
}

@test "(c) no gap -> zero Slack calls" {
  : > "$T/fx/gaps"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
  [ ! -s "$MUSO_CALLS" ]
}

@test "(d) same gap on a second run -> no second alert" {
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  : > "$CURL_ARGV"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
  [ ! -s "$CURL_ARGV" ]
}

@test "(e) 429 -> exit 0 and the gap is NOT marked done (next run retries)" {
  touch "$T/fx/ratelimit"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$MUSO_CALLS" ]
  [ -z "$(ls "$T/state" | grep '^done-')" ]
  rm "$T/fx/ratelimit"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
  [ -n "$(ls "$T/state" | grep '^done-')" ]
}

@test "(f) token never appears in curl argv; it is passed on stdin" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$CURL_ARGV" ]
  if grep -q "$TOKEN" "$CURL_ARGV"; then false; fi
  grep -q "$TOKEN" "$CURL_STDIN"
  [[ "$output" != *"$TOKEN"* ]]
}

@test "unsafe state dir (symlink) -> no Slack calls, exit 1 (detector is off: loud)" {
  rm -rf "$T/state"; mkdir "$T/real"; ln -s "$T/real" "$T/state"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$CURL_ARGV" ]
}

@test "SFMC_ALERT=0 logs the miss but posts nothing" {
  SFMC_ALERT=0 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"possibly missed inbound"* ]]
  [ ! -s "$MUSO_CALLS" ]
}

@test "mention of a different bot id is not a miss" {
  printf '{"ok":true,"messages":[{"ts":"%s","user":"U02S7C96CGN","text":"hey <@UOTHER>"}]}' "$MENTION_TS" > "$T/fx/conversations.history"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"possibly missed"* ]]
}

@test "two mentions, one Inbound line -> exactly one miss" {
  printf '{"ok":true,"messages":[{"ts":"%s.1","user":"U02S7C96CGN","text":"<@UBOT1>"},{"ts":"%s.2","user":"U02S7C96CGN","text":"<@UBOT1>"}]}' \
    "$((THAW - 120))" "$((THAW - 110))" > "$T/fx/conversations.history"
  _inbound_line
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^slack-freeze-miss: possibly missed')" -eq 1 ]
}

@test "lost mention + later delivered mention from the same sender: the LOST one is reported" {
  printf '{"ok":true,"messages":[{"ts":"%s.1","user":"U02S7C96CGN","text":"<@UBOT1>"},{"ts":"%s.2","user":"U02S7C96CGN","text":"<@UBOT1>"}]}' \
    "$((THAW - 10))" "$((THAW + 30))" > "$T/fx/conversations.history"
  _inbound_line "$((THAW + 31))"   # only the later one was ever logged; both within 60s of that line
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^slack-freeze-miss: possibly missed')" -eq 1 ]
  [[ "$output" == *"ts=$((THAW - 10)).1"* ]]
  if printf '%s' "$output" | grep -q "ts=$((THAW + 30)).2"; then false; fi
}

@test "an inherited live MUSO_SLACK_BOT_TOKEN_SCOUT never reaches curl (setup clears it)" {
  [ -z "${MUSO_SLACK_BOT_TOKEN_SCOUT:-}" ]
}

@test "unchecked account (auth fails) is reported, never silent" {
  echo '{"ok":false,"error":"invalid_auth"}' > "$T/fx/auth.test"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check failed"*"account=scout"*"invalid_auth"* ]]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
}

@test "call cap is deterministic: gap is alerted as 'could not check' and marked done in ONE run" {
  echo '{"ok":true,"channels":[{"id":"C1"},{"id":"C2"},{"id":"C3"}],"response_metadata":{"next_cursor":""}}' > "$T/fx/users.conversations"
  _slack_fixtures_empty_history
  SFMC_MAX_CALLS=3 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
  grep -q 'could not check: scout:C2 scout:C3' "$T/last-alert"
  [ -n "$(ls "$T/state" | grep '^done-')" ]
}

@test "call cap is per gap: an exhausted first gap does not blank the second" {
  echo '{"ok":true,"channels":[{"id":"C1"},{"id":"C2"},{"id":"C3"}],"response_metadata":{"next_cursor":""}}' > "$T/fx/users.conversations"
  printf '%s host node[1]: [health] host timing gap detected: process was frozen ~300000ms; x\n' \
    "$(_iso "$((THAW - 1000))")" > "$T/fx/gaps.tmp"
  cat "$T/fx/gaps" >> "$T/fx/gaps.tmp"; mv "$T/fx/gaps.tmp" "$T/fx/gaps"
  SFMC_MAX_CALLS=3 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^slack-freeze-miss: possibly missed')" -eq 2 ]
  [ "$(ls "$T/state" | grep -c '^done-')" -eq 2 ]
}

@test "conversations.history is paged: a lost mention on page 2 is reported and the gap marked done" {
  echo '{"ok":true,"messages":[{"ts":"1.1","user":"U1","text":"nothing"}],"has_more":true,"response_metadata":{"next_cursor":"CUR2"}}' > "$T/fx/conversations.history"
  printf '{"ok":true,"messages":[{"ts":"%s","user":"U02S7C96CGN","text":"hey <@UBOT1> %s"}],"has_more":false}' \
    "$MENTION_TS" "$BODY" > "$T/fx/conversations.history.CUR2"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"possibly missed inbound unit=openclaw-gateway-main account=scout channel=C0ARS7XMY93 ts=$MENTION_TS"* ]]
  [[ "$output" != *"has_more"* ]]
  grep -q 'cursor=CUR2' "$CURL_ARGV"
  [ -n "$(ls "$T/state" | grep '^done-')" ]
}

# ── round 4 (CTO ruling MUS-30199): expiry of un-done gaps, journalctl rc checks ──

# _regap <age_s>: one gap whose thaw is <age_s> seconds ago; fixtures follow it.
_regap() {
  THAW=$(( $(_now +%s) - $1 )); export THAW MENTION_TS="$(( THAW - 120 )).365029"
  _journal_gap; _slack_fixtures mention
}
_done_count() { ls "$T/state" | grep -c '^done-' || true; }

@test "(r4-a) 429 on a young gap (thaw=now-600): no done marker, no alert, exit 0" {
  touch "$T/fx/ratelimit"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$MUSO_CALLS" ]
  [ "$(_done_count)" -eq 0 ]
  [[ "$output" != *"gap expired"* ]]
}

@test "(r4-b) 429 on a gap about to leave the lookback (thaw=now-1740): one 'Could not check' alert, marked done, expired line" {
  _regap 1740
  touch "$T/fx/ratelimit"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"slack-freeze-miss: gap expired unchecked unit=openclaw-gateway-main thaw=$THAW reason=ratelimited"* ]]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
  grep -q 'Could not check Slack mentions for openclaw-gateway-main' "$T/last-alert"
  grep -q '(ratelimited)' "$T/last-alert"
  [ "$(_done_count)" -eq 1 ]
  grep -q 'gap expired unchecked' "$LOGGER_CALLS"
  grep -q -- '-p user.err' "$LOGGER_CALLS"
}

@test "(r4-c) two gaps in the margin, 429 on the first: BOTH expire and are marked done (no break on 429)" {
  _regap 1740
  printf '%s host node[1]: [health] host timing gap detected: process was frozen ~300000ms; x\n' \
    "$(_iso "$((THAW + 100))")" >> "$T/fx/gaps"
  touch "$T/fx/ratelimit"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'gap expired unchecked')" -eq 2 ]
  [ "$(_done_count)" -eq 2 ]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 2 ]
  # the second gap made no Slack API call: only the first one's auth.test hit curl
  [ "$(wc -l < "$CURL_ARGV")" -eq 1 ]
}

@test "(r4-d1) undeliverable alert on a gap in the margin: expired alert_undelivered, marked done, MISSES listed" {
  _regap 1740
  touch "$T/fx/muso_fail"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=alert_undelivered"* ]]
  [ "$(_done_count)" -eq 1 ]
  grep -q "scout C0ARS7XMY93 $MENTION_TS" "$T/last-alert"
}

@test "(r4-d2) undeliverable alert on a young gap: NOT done, no expiry" {
  touch "$T/fx/muso_fail"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gap expired"* ]]
  [ "$(_done_count)" -eq 0 ]
}

@test "(r4-e) outer journalctl fails: exit 1, 'journal read failed' line, no done marker, no Slack call" {
  echo 1 > "$T/fx/gaps_rc"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-freeze-miss: journal read failed unit=openclaw-gateway-main rc=1"* ]]
  [ "$(_done_count)" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
  [ ! -s "$MUSO_CALLS" ]
  grep -q -- '-p user.err' "$LOGGER_CALLS"
  [[ "$output$stderr" != *"boom"* ]]
}

@test "(r4-f) inner (window) journalctl fails while history holds 2 mentions: no 'possibly missed', no done marker, exit 1" {
  printf '{"ok":true,"messages":[{"ts":"%s.1","user":"U02S7C96CGN","text":"<@UBOT1>"},{"ts":"%s.2","user":"U02S7C96CGN","text":"<@UBOT1>"}]}' \
    "$((THAW - 120))" "$((THAW - 110))" > "$T/fx/conversations.history"
  echo 1 > "$T/fx/inbound_rc"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" != *"possibly missed"* ]]
  [ ! -s "$MUSO_CALLS" ]
  [ "$(_done_count)" -eq 0 ]
}

@test "(r4-f2) inner journal read keeps failing until the gap is in the margin: expired journal_read_failed, marked done" {
  _regap 1740
  echo 1 > "$T/fx/inbound_rc"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"reason=journal_read_failed"* ]]
  [ "$(_done_count)" -eq 1 ]
}

@test "(r4-g) empty journal (exit 0, no lines): exit 0, no Slack call" {
  : > "$T/fx/gaps"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
  [ ! -s "$MUSO_CALLS" ]
}

@test "SFMC_LOOKBACK_S / SFMC_EXPIRY_MARGIN_S: non-digit values fall back to the defaults" {
  _regap 1740
  touch "$T/fx/ratelimit"
  SFMC_LOOKBACK_S="30min" SFMC_EXPIRY_MARGIN_S="x" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gap expired unchecked"* ]]
}

# Round 5 (MUS-30256): every error path is loud: stdout line + user.err + RC=1; per-gap failures go via _leave_undone.
@test "(r5-a) missing config, young gap: exit 1, 'config unreadable', no done marker, zero Slack calls" {
  rm -f "$SFMC_CONFIG_MAIN"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-freeze-miss: config unreadable unit=openclaw-gateway-main"* ]]
  grep -q -- '-p user.err' "$LOGGER_CALLS"
  [ "$(_done_count)" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
}

@test "(r5-b) missing config, gap in the margin: expired reason=config_unreadable, marked done, one 'Could not check' post" {
  _regap 1740
  rm -f "$SFMC_CONFIG_MAIN"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gap expired unchecked unit=openclaw-gateway-main thaw=$THAW reason=config_unreadable"* ]]
  [ "$(_done_count)" -eq 1 ]
  [ "$(grep -c "^CALL" "$MUSO_CALLS")" -eq 1 ]
  grep -q 'Could not check Slack mentions' "$T/last-alert"
}

@test "(r5-c) malformed JSON config: exit 1, config_invalid, no done marker" {
  echo '{not json' > "$SFMC_CONFIG_MAIN"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config invalid unit=openclaw-gateway-main"* ]]
  [ "$(_done_count)" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
}

@test "(r5-d) valid JSON with zero slack bindings: exit 1, config_invalid, no done marker" {
  echo '{"channels":{"slack":{"accounts":{}}},"bindings":[]}' > "$SFMC_CONFIG_MAIN"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config invalid unit=openclaw-gateway-main"* ]]
  [ "$(_done_count)" -eq 0 ]
}

@test "(r5-e) gap line whose time does not parse: exit 1, 'gap timestamp unparseable'" {
  printf '2026-13-05T10:00:00+00:00 host node[1]: [health] host timing gap detected: process was frozen ~300000ms; x\n' > "$T/fx/gaps"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gap timestamp unparseable unit=openclaw-gateway-main iso=2026-13-05T10:00:00+00:00"* ]]
  grep -q -- '-p user.err' "$LOGGER_CALLS"
}

@test "(r5-f) unknown unit in SFMC_UNITS: exit 1, 'unknown unit'" {
  SFMC_UNITS="openclaw-gateway-weird" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown unit openclaw-gateway-weird"* ]]
  grep -q -- '-p user.err' "$LOGGER_CALLS"
}
