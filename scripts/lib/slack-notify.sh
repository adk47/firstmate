#!/bin/bash
# ──────────────────────────────────────────────────────────────
# slack-notify.sh — sourced helper for posting Slack messages
# from hydra ops scripts via the gated muso CLI (devops bot).
#
# Usage:
#   source /opt/hydra/scripts/lib/slack-notify.sh
#   slack_notify "your message here"
#
# Env knobs:
#   SLACK_CHANNEL            # Slack channel ID to post into.
#                            # Defaults to C0ADV2W76G4 (#clio_devops).
#   MUSO_BIN                 # muso binary (default: muso) — tests stub this.
#   MUSO_SLACK_ENV_FILE      # env file holding MUSO_SLACK_BOT_TOKEN_<BOT>
#                            # vars (default: /etc/openclaw/main.env). Ops
#                            # scripts run under units that do NOT load
#                            # main.env, so the lib pulls the slack vars in
#                            # itself when they're absent.
#   SLACK_NOTIFY_REQUESTER   # audit attribution for the gated send
#                            # (default: <calling script>@hydra-ops).
#
# Sends go through `muso slack send` (issue #5 PR1): per-bot tokens from the
# environment, Slack's HTTP-200 ok:false trap decoded by the CLI (exit 0 is
# confirmed delivery), every send audited with requester attribution.
#
# Why a sourced lib instead of a separate executable: callers want
# slack_notify to be silent on transient failures (Slack is the alert
# channel — failing to alert about an alert shouldn't itself fail the
# script that's already mid-recovery). Sourcing keeps `|| true`
# semantics the same as the previous inline copy in openclaw-watchdog.sh.
# ──────────────────────────────────────────────────────────────

: "${SLACK_CHANNEL:=C0ADV2W76G4}"
# Which muso slack bot sends. devops is the historical default; callers whose
# target channel only has another bot as a member (e.g. #cs_priority → the
# operations bot) export SLACK_NOTIFY_BOT before sourcing.
: "${SLACK_NOTIFY_BOT:=devops}"
: "${MUSO_BIN:=muso}"
: "${MUSO_SLACK_ENV_FILE:=/etc/openclaw/main.env}"

# The cron.d watchdogs and root crontab run with cron's default PATH
# (/usr/bin:/bin), which excludes /usr/local/bin where deploy.sh installs
# muso — resolve the absolute path so cron-driven alerts don't 127.
if [ "$MUSO_BIN" = "muso" ] && ! command -v muso >/dev/null 2>&1 && [ -x /usr/local/bin/muso ]; then
  MUSO_BIN=/usr/local/bin/muso
fi

# Test fence (hydra#1195: an unfenced bats run posted 68 real messages). Both are
# no-ops outside bats (BATS_TEST_FILENAME unset).
# Belt 1: under bats slack_load_env never reads the live /etc/openclaw/main.env; a
# test that points MUSO_SLACK_ENV_FILE at its own fixture still works.
# Belt 2: under bats the installed muso is never exec'd, even with a token already
# exported. The live env path and the installed-muso list are variables only so a
# test can point them at fixtures.
: "${SLACK_NOTIFY_LIVE_ENV_FILE:=/etc/openclaw/main.env}"
: "${SLACK_NOTIFY_INSTALLED_MUSO:=/usr/local/bin/muso /usr/bin/muso}"
_slack_refuse_installed_muso() {
  [ -n "${BATS_TEST_FILENAME:-}" ] || return 1
  local resolved p
  resolved="$(command -v -- "$MUSO_BIN" 2>/dev/null)" || return 1
  for p in $SLACK_NOTIFY_INSTALLED_MUSO; do
    if [ "$resolved" = "$p" ]; then
      echo "slack-notify: refusing to exec installed $p under bats" >&2
      return 0
    fi
  done
  return 1
}

# slack_load_env [BOT]: make sure the muso slack token vars are exported and
# the token for BOT (default devops) is present. The watchdog/cron units load
# shared.env+edge.env, not main.env where the MUSO_SLACK_* vars live — so pull
# in exactly those lines (nothing else) when they're missing. Best-effort:
# pre-start-heal in particular may run when config files are broken; a missing
# env file just means we can't notify, never that we fail the caller.
slack_load_env() {
  local bot_var
  bot_var="MUSO_SLACK_BOT_TOKEN_$(printf '%s' "${1:-devops}" | tr '[:lower:]' '[:upper:]')"
  if [ -z "${!bot_var:-}" ] && [ -r "$MUSO_SLACK_ENV_FILE" ] \
    && ! { [ -n "${BATS_TEST_FILENAME:-}" ] && [ "$MUSO_SLACK_ENV_FILE" = "$SLACK_NOTIFY_LIVE_ENV_FILE" ]; }; then
    # MUSO_STATE_DIR rides along so muso's fail-closed audit log lands in
    # the shared /var/log/muso-ops trail (RUNBOOK) even under units/crons
    # that carry neither main.env nor HOME.
    eval "$(grep -E '^MUSO_(SLACK_[A-Z_]+|STATE_DIR)=' "$MUSO_SLACK_ENV_FILE" | sed 's/^/export /')" 2>/dev/null || true
  fi
  [ -n "${!bot_var:-}" ]
}

_slack_requester() {
  printf '%s' "${SLACK_NOTIFY_REQUESTER:-$(basename "${0:-hydra-ops}")@hydra-ops}"
}

# Real Slack user IDs for CRITICAL pages. A literal "@name" in a bot message
# renders as plain text and pings NOBODY — only <@UID> mentions ping. These are
# the single code-side source (the same IDs live in prose in
# skills-all/muso-devops-alert-triage/SKILL.md).
SLACK_UID_NICK="U0AL36NADEY"
SLACK_UID_AARON="U7RP6HKUZ"

# slack_notify_critical <msg>: slack_notify with both on-call owners actually
# pinged. Same best-effort contract as slack_notify (never fails the caller).
slack_notify_critical() {
  slack_notify "<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> $1"
}

slack_notify() {
  local msg="$1"
  # Callers historically embedded the 2-char sequence \n and relied on the
  # JSON body decode to render newlines; muso's --text marshals it literally,
  # so translate here to keep the old contract.
  msg="${msg//\\n/$'\n'}"
  _slack_refuse_installed_muso && return 0
  slack_load_env "$SLACK_NOTIFY_BOT" || return 0
  "$MUSO_BIN" slack send --bot "$SLACK_NOTIFY_BOT" \
    --channel "$SLACK_CHANNEL" --text "$msg" \
    --requester "$(_slack_requester)" >/dev/null 2>&1 || true
}

# slack_notify_critical_status <msg>: the same critical page as slack_notify_critical, but RETURNING the real
# delivery status (0 only when Slack confirmed the post). For callers that dedupe on a watermark: a caller that
# advances its watermark after a silent failure has lost that page forever, so best-effort is the wrong contract there.
# Every other caller keeps slack_notify_critical's never-fail semantics.
slack_notify_critical_status() {
  local msg="$1" dir file rc=0
  msg="${msg//\\n/$'\n'}"
  _slack_refuse_installed_muso && return 1
  slack_load_env "$SLACK_NOTIFY_BOT" || return 1
  [ -n "${SLACK_CHANNEL:-}" ] || return 1
  # mktemp-ok: every path here removes the dir before returning; an EXIT trap would outlive the function.
  dir="$(mktemp -d "${SCRATCH_DIR:-${TMPDIR:-/var/tmp}}/slack-notify.XXXXXX" 2>/dev/null)" || return 1
  file="$dir/payload.json"
  if ! jq -nc --arg ch "$SLACK_CHANNEL" \
       --arg t "<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> $msg" '{channel:$ch, text:$t}' > "$file" 2>/dev/null; then
    rm -rf "$dir"; return 1
  fi
  _slack_post_payload "$file" || rc=1
  rm -rf "$dir"
  return "$rc"
}

# _slack_post_payload <path-to-json>  (internal)
# Posts the chat.postMessage-shaped payload at <path> ({channel, text, blocks,
# thread_ts} — same shape callers always built) via `muso slack send` and
# RETURNS the real delivery status: 0 only when Slack confirmed the post.
# The CLI decodes Slack's HTTP-200 {"ok":false} trap itself (invalid_auth,
# not_in_channel, missing scope... all exit non-zero), so muso's exit code IS
# the delivery status — no response parsing needed here anymore.
_slack_post_payload() {
  local payload_file="$1"
  [ -r "$payload_file" ] || return 1
  _slack_refuse_installed_muso && return 1
  slack_load_env "$SLACK_NOTIFY_BOT" || return 1

  local channel text thread_ts
  channel=$(jq -r '.channel // empty' "$payload_file" 2>/dev/null) || return 1
  # No silent default: the old verbatim-POST path let Slack reject a
  # channel-less payload, so the status-aware callers never advanced their
  # dedupe state on a malformed payload. Keep that contract.
  [ -n "$channel" ] || return 1
  text=$(jq -r '.text // empty' "$payload_file" 2>/dev/null)
  thread_ts=$(jq -r '.thread_ts // empty' "$payload_file" 2>/dev/null)

  local args=(slack send --bot "$SLACK_NOTIFY_BOT" --channel "$channel"
    --requester "$(_slack_requester)")
  [ -n "$text" ] && args+=(--text "$text")
  [ -n "$thread_ts" ] && args+=(--thread-ts "$thread_ts")
  # release.sh (and any payload that sets unfurl_links:false) relied on the
  # old verbatim POST honoring it — map onto the CLI's --no-unfurl.
  if jq -e '.unfurl_links == false or .unfurl_media == false' "$payload_file" >/dev/null 2>&1; then
    args+=(--no-unfurl)
  fi

  local blocks_file=""
  if jq -e '.blocks | type == "array" and length > 0' "$payload_file" >/dev/null 2>&1; then
    blocks_file=$(mktemp) || return 1
    jq '.blocks' "$payload_file" > "$blocks_file" 2>/dev/null || { rm -f "$blocks_file"; return 1; }
    args+=(--blocks-file "$blocks_file")
  fi

  local status=0
  "$MUSO_BIN" "${args[@]}" >/dev/null 2>&1 || status=$?
  [ -n "$blocks_file" ] && rm -f "$blocks_file"
  return "$status"
}

# slack_notify_payload_file <path-to-json>
# Posts the payload at <path> ({channel, text, blocks, thread_ts}). Use this
# for Block Kit messages: build the JSON in Python (apostrophes in commit
# subjects will break naive bash heredocs — see the 2026-05-07
# api-evidence.sh apostrophe-in-heredoc burn).
#
# Best-effort: never fails the caller (preserves the historical contract that
# failing to post an alert shouldn't abort a script that's already mid-recovery).
slack_notify_payload_file() {
  _slack_post_payload "$1" || true
  return 0
}

# slack_notify_payload_file_status <path-to-json>
# Same post, but RETURNS delivery status (0 only on a confirmed post). Use when
# the caller must NOT advance dedupe / idempotency state for an alert that was
# never actually delivered (e.g. a watchdog that would otherwise mark an
# incident "already paged" and never retry it).
slack_notify_payload_file_status() {
  _slack_post_payload "$1"
}

# slack_notify_payload_file_ts <path-to-json>
# Like slack_notify_payload_file_status (0 only on a confirmed post) but ALSO
# echoes the delivered message ts on stdout (empty on failure) so the caller can
# thread a later reply onto it. Plain-text only (channel + text [+ thread_ts]
# [+ no-unfurl]); NO Block Kit -- keep this narrow so it stays additive and does
# not disturb _slack_post_payload, which release.sh depends on. Mirrors the
# ts-capture idiom in clickup-sla-digest.sh (muso slack send --json | jq .ts).
slack_notify_payload_file_ts() {
  local payload_file="$1"
  [ -r "$payload_file" ] || return 1
  _slack_refuse_installed_muso && return 1
  slack_load_env "$SLACK_NOTIFY_BOT" || return 1

  local channel text thread_ts
  channel=$(jq -r '.channel // empty' "$payload_file" 2>/dev/null) || return 1
  [ -n "$channel" ] || return 1
  text=$(jq -r '.text // empty' "$payload_file" 2>/dev/null)
  thread_ts=$(jq -r '.thread_ts // empty' "$payload_file" 2>/dev/null)

  local args=(slack send --bot "$SLACK_NOTIFY_BOT" --channel "$channel"
    --requester "$(_slack_requester)" --json)
  [ -n "$text" ] && args+=(--text "$text")
  [ -n "$thread_ts" ] && args+=(--thread-ts "$thread_ts")
  if jq -e '.unfurl_links == false or .unfurl_media == false' "$payload_file" >/dev/null 2>&1; then
    args+=(--no-unfurl)
  fi

  # Capture stdout (only stderr -> /dev/null) so the {channel, ts} JSON is
  # parseable. muso exit code IS the delivery status (it decodes Slack's
  # HTTP-200 {ok:false} trap), so only emit a ts on a confirmed post.
  local resp status=0
  resp="$("$MUSO_BIN" "${args[@]}" 2>/dev/null)" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s' "$resp" | jq -r '.ts // empty' 2>/dev/null || true
  fi
  return "$status"
}
