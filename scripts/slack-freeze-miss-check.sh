#!/bin/bash
# ──────────────────────────────────────────────────────────────
# slack-freeze-miss-check — flag Slack @mentions lost while a gateway was frozen
# (MUS-29976, under MUS-28729).
#
# Runs every 5 min via /etc/cron.d/slack-freeze-miss-check ON NODE-8
# (scripts/install-aux-units.sh). When a gateway logs
#   [health] host timing gap detected: process was frozen ~<N>ms
# the Slack socket was dead for N ms and its retries are long exhausted, so a
# mention sent in that window never becomes `[slack] Inbound app_mention` and is
# never redelivered (5 Nov: C0ARS7XMY93 ts 1793880787.365029, lost silently).
#
# This script DETECTS AND FLAGS. It never replays: replaying into the agent risks a
# double answer or acting on a stale ask, so a human or the asker re-sends.
#
# Per gap (window = [thaw - N - 60s, thaw + 120s]), per Slack account bound to an
# agent in that unit's openclaw.json: auth.test -> bot user id; users.conversations
# -> the bot's channels; conversations.history over the window; keep messages
# containing <@BOTID>. A mention is "seen" when the journal carries an Inbound
# line for the same channel + sender + bot whose JOURNAL time is within
# [ts-2s, ts+60s] of the message ts (the Inbound line carries no message ts, so the
# journal time is the key). Each Inbound line is consumed by at most one mention,
# oldest mention first, so a lost mention is never paired with a later delivered one.
#
# Out of scope: thread replies (conversations.replies) and DMs. Only channel
# top-level messages are checked.
#
# Output: per miss one stdout line (cron log) + one journal line, and ONE alert per
# gap to #clio_devops listing every miss with its chat.getPermalink link. Message
# text is never read into a log or alert. A gap whose accounts could not be checked
# (non-429 API error) is still alerted, as "unchecked".
#
# Tokens: each account's botToken is a SecretRef {source:env,id:MUSO_SLACK_BOT_TOKEN_<BOT>}
# (or a literal, edge). The env id is resolved from MUSO_SLACK_ENV_FILE, the same file
# scripts/lib/slack-notify.sh reads. The token goes to curl on STDIN (`--config -`),
# never argv, and is never printed.
#
# Dedup: a gap is marked done (done-<unit>-<thawepoch>) when its check finished. Four paths
# leave a gap un-done for the next run: a 429, an undeliverable alert, a failed journal read,
# an unreadable/invalid unit config (reason=config_unreadable|config_invalid).
# Each is retried until the gap is within SFMC_EXPIRY_MARGIN_S of leaving the SFMC_LOOKBACK_S
# window; then it EXPIRES: one `gap expired unchecked ... reason=` line (stdout + user.err) and one
# best-effort "Could not check ..." post, and the gap is marked done WHATEVER the post returns
# (the user.err journal line is the durable record). A 429 never stops the loop: later gaps skip
# the API but still expire. The call cap is deterministic (a retry would stop at the same call),
# so a gap that hits it is alerted as "could not check: ..." and marked done at once.
# A journalctl failure (rc != 0) is never read as "no entries": outer read -> `journal read
# failed` line + exit 1; window read -> the gap is un-done (never a mass "lost" alert).
# Every error path is loud: one stdout line + one `logger -p user.err` line + exit 1. That covers an
# unsafe state dir or failed mktemp (detector OFF), a bad config, an unparseable gap time, an unknown
# unit, and a failed journal read. Not errors: flock -n busy (another run is checking), a gap that is
# already done or younger than thaw+120s. _check_gap runs under `||` (errexit suspended), so every
# failure inside it is checked explicitly.
# SFMC_MAX_CALLS bounds the Slack calls of ONE gap (CALLS resets per gap), not of one run.
# State dir is root-owned 0700, same gate as HEAP_STATE_DIR in openclaw-watchdog.sh
# (never /tmp).
#
# Env: SFMC_STATE_DIR SFMC_UNITS SFMC_CONFIG_MAIN SFMC_CONFIG_EDGE SFMC_LOOKBACK_S (1800)
#      SFMC_EXPIRY_MARGIN_S (900) SFMC_MAX_CALLS SFMC_ALERT (0 = log only) SFMC_API MUSO_SLACK_ENV_FILE
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SFMC_STATE_DIR="${SFMC_STATE_DIR:-/var/lib/hydra-watchdog/slack-freeze-miss}"
SFMC_UNITS="${SFMC_UNITS:-openclaw-gateway-main openclaw-gateway-edge}"
SFMC_CONFIG_MAIN="${SFMC_CONFIG_MAIN:-/root/.openclaw-main/openclaw.json}"
SFMC_CONFIG_EDGE="${SFMC_CONFIG_EDGE:-/root/.openclaw-edge/openclaw.json}"
SFMC_LOOKBACK_S="${SFMC_LOOKBACK_S:-1800}"
SFMC_EXPIRY_MARGIN_S="${SFMC_EXPIRY_MARGIN_S:-900}"
SFMC_MAX_CALLS="${SFMC_MAX_CALLS:-300}"
SFMC_ALERT="${SFMC_ALERT:-1}"
SFMC_API="${SFMC_API:-https://slack.com/api}"
: "${MUSO_SLACK_ENV_FILE:=/etc/openclaw/main.env}"
case "$SFMC_MAX_CALLS" in ''|*[!0-9]*) SFMC_MAX_CALLS=300 ;; esac
case "$SFMC_LOOKBACK_S" in ''|*[!0-9]*) SFMC_LOOKBACK_S=1800 ;; esac
case "$SFMC_EXPIRY_MARGIN_S" in ''|*[!0-9]*) SFMC_EXPIRY_MARGIN_S=900 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
[ "$SFMC_ALERT" = 0 ] || source "$SCRIPT_DIR/lib/slack-notify.sh"

log() { printf '[slack-freeze-miss-check %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
# _fail <msg>: an error path is loud: one stdout line + one user.err journal line (caller sets RC=1 or exits 1).
_fail() {
  local line="slack-freeze-miss: $*"
  printf '%s\n' "$line"; logger -t slack-freeze-miss -p user.err -- "$line" 2>/dev/null || true
}
_date() { if command -v gdate >/dev/null 2>&1; then gdate "$@"; else date "$@"; fi; }

_state_ok() {
  mkdir -p "$SFMC_STATE_DIR" 2>/dev/null || true
  [ ! -L "$SFMC_STATE_DIR" ] && [ -d "$SFMC_STATE_DIR" ] && [ -O "$SFMC_STATE_DIR" ] \
    && chmod 700 "$SFMC_STATE_DIR" 2>/dev/null
}
_state_ok || { _fail "state dir $SFMC_STATE_DIR unsafe (symlink/not ours): detector is OFF"; exit 1; }
command -v flock >/dev/null 2>&1 && { exec 9>"$SFMC_STATE_DIR/.lock"; flock -n 9 || exit 0; }
WORK="$(mktemp -d "$SFMC_STATE_DIR/work.XXXXXX")" || { _fail "mktemp in $SFMC_STATE_DIR failed: detector is OFF"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

CALLS=0
DEFER=0   # 1 => 429: leave the gap un-done, retry next run
LAST_ERR=""
# _api <method> [k=v ...] -> body in $RESP (a global: DEFER/LAST_ERR must survive, so never call
# it inside $( )). rc 0 ok:true; 1 API error or call cap (LAST_ERR set); 2 defer (429).
_api() {
  local method="$1"; shift
  local -a args=(); local kv resp code body
  RESP=""
  CALLS=$((CALLS + 1))
  if [ "$CALLS" -gt "$SFMC_MAX_CALLS" ]; then LAST_ERR="call_cap"; return 1; fi
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  # Token on stdin as a curl config line: not in argv (ps), not in the environment of curl.
  resp="$(printf 'header = "Authorization: Bearer %s"\n' "$TOK" \
    | curl -sS --max-time 20 --config - --get -w '\n%{http_code}' "${args[@]}" "$SFMC_API/$method" 2>/dev/null)" \
    || { LAST_ERR="curl_failed"; return 1; }
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [ "$code" = 429 ]; then DEFER=1; LAST_ERR="ratelimited"; log "429 from $method — will retry next run"; return 2; fi
  if ! printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    LAST_ERR="$(printf '%s' "$body" | jq -r '.error // "bad_response"' 2>/dev/null || echo bad_response)"
    [ "$LAST_ERR" = ratelimited ] && { DEFER=1; return 2; }
    return 1
  fi
  RESP="$body"
}

# _resolve_token <config> <account> -> token on stdout (empty if unresolvable)
_resolve_token() {
  local ref id line val
  ref="$(jq -c --arg a "$2" '.channels.slack.accounts[$a].botToken // empty' "$1" 2>/dev/null)" || return 0
  case "$ref" in
    \"*) printf '%s' "$ref" | jq -r . ;;   # literal token in the config
    \{*)
      id="$(printf '%s' "$ref" | jq -r 'select(.source=="env") | .id // empty')"
      [[ "$id" =~ ^MUSO_SLACK_BOT_TOKEN_[A-Z0-9_]+$ ]] || return 0   # never read arbitrary vars
      [ -n "${!id:-}" ] && { printf '%s' "${!id}"; return 0; }
      [ -r "$MUSO_SLACK_ENV_FILE" ] || return 0
      line="$(grep -m1 "^${id}=" "$MUSO_SLACK_ENV_FILE" 2>/dev/null)" || return 0
      val="${line#*=}"; val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
      printf '%s' "$val" ;;
  esac
}

# _check_gap <unit> <config> <thaw_epoch> <frozen_ms>
# Sets MISSES (lines "account channel ts permalink") and UNCHECKED (account names).
_check_gap() {
  local unit="$1" cfg="$2" thaw="$3" ms="$4" ws we acct bot cursor resp ch hist k
  ws=$(( thaw - ms / 1000 - 60 )); we=$(( thaw + 120 ))
  MISSES=(); UNCHECKED=()
  # Inbound lines in the window: have["channel sender bot"]="epoch epoch ..." (journal time).
  declare -A have=()
  local iso ie inb="$WORK/inbound.$unit"
  # A failed read must not look like "no Inbound lines" (every mention would be reported lost).
  journalctl -u "$unit" --since "@$ws" --until "@$we" --no-pager -o short-iso >"$inb" 2>"$WORK/jerr.inbound" || return 3
  while read -r iso ch k; do
    [ -n "$ch" ] || continue
    ie="$(_date -u -d "$iso" +%s 2>/dev/null)" || continue
    have["$ch $k"]+=" $ie"
  done < <(sed -n 's/^\([^ ]*\) .*\[slack\] Inbound app_mention slack:[^:]*:channel:\([A-Z0-9]*\):user:\([A-Z0-9]*\) -> bot:\([A-Z0-9]*\).*/\1 \2 \3 \4/p' "$inb")
  for acct in $ACCTS; do
    TOK="$(_resolve_token "$cfg" "$acct")"
    if [ -z "$TOK" ]; then log "check failed account=$acct unit=$unit error=no_token"; UNCHECKED+=("$acct"); continue; fi
    bot=""
    _api auth.test && bot="$(printf '%s' "$RESP" | jq -r '.user_id // empty')"
    [ "$DEFER" = 1 ] && return 2
    if [ -z "$bot" ]; then log "check failed account=$acct unit=$unit error=${LAST_ERR:-auth.test}"; UNCHECKED+=("$acct"); continue; fi
    local chans=() failed=0
    cursor=""
    while :; do
      _api users.conversations types=public_channel,private_channel exclude_archived=true limit=200 ${cursor:+cursor=$cursor} || { failed=1; break; }
      while read -r k; do [ -n "$k" ] && chans+=("$k"); done < <(printf '%s' "$RESP" | jq -r '.channels[]?.id')
      cursor="$(printf '%s' "$RESP" | jq -r '.response_metadata.next_cursor // empty')"
      [ -n "$cursor" ] || break
    done
    [ "$DEFER" = 1 ] && return 2
    if [ "$failed" = 1 ]; then log "check failed account=$acct unit=$unit error=${LAST_ERR}"; UNCHECKED+=("$acct"); continue; fi
    for ch in "${chans[@]}"; do
      # Page on next_cursor; the pages are merged before the mention filter. A failed page
      # (API error or the call cap) marks the channel unchecked.
      hist='{"messages":[]}'; cursor=""; failed=0
      while :; do
        _api conversations.history channel="$ch" oldest="$ws" latest="$we" inclusive=true limit=200 ${cursor:+cursor=$cursor} || { failed=1; break; }
        hist="$(printf '%s\n%s' "$hist" "$RESP" | jq -s '{messages: (map(.messages[]?))}')"
        cursor="$(printf '%s' "$RESP" | jq -r '.response_metadata.next_cursor // empty')"
        [ -n "$cursor" ] || break
      done
      [ "$DEFER" = 1 ] && return 2
      if [ "$failed" = 1 ]; then
        log "check failed account=$acct unit=$unit channel=$ch error=${LAST_ERR}"; UNCHECKED+=("$acct:$ch"); continue
      fi
      # Each Inbound line (journal-time order) claims the NEAREST PRECEDING unclaimed mention of the
      # same sender within [e-60, e+2]; what stays unclaimed is lost. Nearest-preceding means a lost
      # mention is never paired with the Inbound line of a later delivered one, however close they are.
      local -a mts=() msd=() used=()
      while IFS=$'\t' read -r ts sender; do
        [ -n "$ts" ] && { mts+=("$ts"); msd+=("$sender"); used+=(0); }
      done < <(printf '%s' "$hist" | jq -r --arg b "$bot" \
        '[.messages[]? | select(.user != $b and ((.text // "") | contains("<@" + $b + ">")))] | sort_by(.ts) | .[] | [.ts, .user] | @tsv')
      local i best e mi
      local -A seen=()
      for i in "${!mts[@]}"; do
        k="$ch ${msd[$i]} $bot"; [ -n "${seen[$k]:-}" ] && continue; seen[$k]=1
        for e in $(printf '%s' "${have[$k]:-}" | tr ' ' '\n' | sort -n); do
          best=-1
          for j in "${!mts[@]}"; do
            [ "${used[$j]}" = 0 ] && [ "$ch ${msd[$j]} $bot" = "$k" ] || continue
            mi="${mts[$j]%%.*}"
            [ "$mi" -ge $(( e - 60 )) ] && [ "$mi" -le $(( e + 2 )) ] && best="$j"
          done
          [ "$best" -ge 0 ] && used[best]=1
        done
      done
      for i in "${!mts[@]}"; do
        [ "${used[$i]}" = 0 ] && MISSES+=("$acct $ch ${mts[$i]}")
      done
    done
  done
  return 0
}

_post_text() {   # <text> -> post to the alert channel (SFMC_ALERT=0: nothing)
  local payload="$WORK/payload.json"
  [ "$SFMC_ALERT" = 0 ] && return 0
  jq -nc --arg ch "${SLACK_CHANNEL:-C0ADV2W76G4}" --arg t "$1" '{channel:$ch, text:$t}' > "$payload"
  _slack_post_payload "$payload"
}

_mark_done() { local t; t="$(mktemp "$SFMC_STATE_DIR/done.XXXXXX")" && mv -f "$t" "$1"; }

# _leave_undone <unit> <thaw> <reason> <donekey>: the gap was not checked. Retry next run, unless it is
# about to leave the lookback window: then say so once (journal user.err + best-effort post), mark done.
_leave_undone() {
  local unit="$1" thaw="$2" reason="$3" key="$4" line text m
  if [ $(( $(_date -u +%s) - thaw )) -lt $(( SFMC_LOOKBACK_S - SFMC_EXPIRY_MARGIN_S )) ]; then
    log "gap unit=$unit thaw=$thaw un-done ($reason) — will retry next run"; return 0
  fi
  line="slack-freeze-miss: gap expired unchecked unit=$unit thaw=$thaw reason=$reason"
  printf '%s\n' "$line"
  logger -t slack-freeze-miss -p user.err -- "$line" 2>/dev/null || true
  text="Could not check Slack mentions for $unit around $(_date -u -d "@$thaw" +%H:%M:%SZ) ($reason). Anything sent to the bot in the minutes before that may need to be re-sent."
  if [ "$reason" = alert_undelivered ] && [ "${#MISSES[@]}" -gt 0 ]; then
    for m in "${MISSES[@]}"; do text+=$'\n'"• $m"; done
  fi
  _post_text "$text" || log "expiry notice for unit=$unit thaw=$thaw not delivered (marked done anyway)"
  _mark_done "$key"
}

_alert_gap() {   # <unit> <thaw>
  local unit="$1" thaw="$2" lines="" m a c t link
  for m in "${MISSES[@]}"; do
    read -r a c t <<<"$m"
    link=""; TOK="$(_resolve_token "$CFG" "$a")"
    _api chat.getPermalink channel="$c" message_ts="$t" && link="$(printf '%s' "$RESP" | jq -r '.permalink // empty')"
    [ "$DEFER" = 1 ] && return 2
    lines+="• account=$a channel=$c ts=$t ${link}"$'\n'
  done
  [ "${#UNCHECKED[@]}" -gt 0 ] && lines+="• could not check: ${UNCHECKED[*]}"$'\n'
  _post_text "Slack mentions possibly lost while $unit was frozen (thaw $(_date -u -d "@$thaw" +%H:%M:%SZ)). The bot never logged these as inbound; ask the sender to re-send:"$'\n'"$lines"
}

RC=0
RATELIMITED=0   # 1 => a 429 this run: later gaps skip the API but still run the expiry rule
for UNIT in $SFMC_UNITS; do
  case "$UNIT" in
    *main) CFG="$SFMC_CONFIG_MAIN" ;;
    *edge) CFG="$SFMC_CONFIG_EDGE" ;;
    *) _fail "unknown unit $UNIT (no config mapping)"; RC=1; continue ;;
  esac
  # A bad config never skips the unit: it is reported once, and every gap goes through _leave_undone
  # (retry, then expire loudly) with reason=$CFG_ERR. A config with zero slack-bound accounts has no
  # legitimate state on main/edge (a unit without Slack is removed from SFMC_UNITS).
  CFG_ERR=""; ACCTS=""
  if [ ! -r "$CFG" ]; then CFG_ERR=config_unreadable
  elif ! ACCTS="$(jq -r '[.bindings[]? | select(.match.channel=="slack") | .match.accountId] | unique[]' "$CFG" 2>/dev/null)" \
    || [ -z "$ACCTS" ]; then CFG_ERR=config_invalid
  fi
  [ -z "$CFG_ERR" ] || { _fail "config ${CFG_ERR#config_} unit=$UNIT path=$CFG"; RC=1; }
  GAPS="$WORK/gaps.$UNIT"; jrc=0
  journalctl -u "$UNIT" --since "@$(( $(_date -u +%s) - SFMC_LOOKBACK_S ))" --no-pager -o short-iso >"$GAPS" 2>"$WORK/jerr.$UNIT" || jrc=$?
  if [ "$jrc" -ne 0 ]; then
    _fail "journal read failed unit=$UNIT rc=$jrc"
    RC=1; continue
  fi
  while read -r iso ms; do
    [ -n "$iso" ] || continue
    thaw="$(_date -u -d "$iso" +%s 2>/dev/null)" || { _fail "gap timestamp unparseable unit=$UNIT iso=$iso"; RC=1; continue; }
    key="$SFMC_STATE_DIR/done-$UNIT-$thaw"
    [ -e "$key" ] && continue
    # Wait for the thaw+120s part of the window to exist in the journal.
    [ "$(_date -u +%s)" -ge $(( thaw + 120 )) ] || continue
    DEFER=0; TOK=""; CALLS=0; MISSES=(); UNCHECKED=(); reason=""; crc=0
    if [ -n "$CFG_ERR" ]; then
      reason=$CFG_ERR
    elif [ "$RATELIMITED" = 1 ]; then
      reason=ratelimited
    else
      _check_gap "$UNIT" "$CFG" "$thaw" "$ms" || crc=$?
      if [ "$DEFER" = 1 ]; then RATELIMITED=1; reason=ratelimited
      elif [ "$crc" = 3 ]; then
        reason=journal_read_failed; RC=1
        _fail "journal read failed unit=$UNIT thaw=$thaw (window read)"
      fi
    fi
    if [ -n "$reason" ]; then _leave_undone "$UNIT" "$thaw" "$reason" "$key"; continue; fi
    if [ "${#MISSES[@]}" -gt 0 ] || [ "${#UNCHECKED[@]}" -gt 0 ]; then
      for m in "${MISSES[@]}"; do
        read -r a c t <<<"$m"
        line="slack-freeze-miss: possibly missed inbound unit=$UNIT account=$a channel=$c ts=$t"
        printf '%s\n' "$line"
        logger -t slack-freeze-miss -p user.warning -- "$line" 2>/dev/null || true
      done
      if ! _alert_gap "$UNIT" "$thaw"; then
        if [ "$DEFER" = 1 ]; then RATELIMITED=1; reason=ratelimited; else reason=alert_undelivered; fi
        _leave_undone "$UNIT" "$thaw" "$reason" "$key"; continue
      fi
    fi
    _mark_done "$key"
  done < <(sed -n 's/^\([0-9T:+-]*\) .*host timing gap detected: process was frozen ~\([0-9]*\)ms.*/\1 \2/p' "$GAPS")
done
exit "$RC"
