#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Caroline RAG index watchdog (self-heal + alert)
#
# openclaw PAUSES the memory_search (RAG) vector index on every
# runtime version bump (reference: memory-index-pause-after-upgrade).
# A paused index returns NOTHING from retrieval, so the mandatory
# pre-retrieval RAG hook (plugins/intercom) answers ungrounded and the
# customer-facing failure is silent. The deploy-time forced reindex in
# deploy.sh covers the DEPLOY path; this watchdog is the safety net for
# the BETWEEN-deploy events that also pause the index (an out-of-band
# openclaw auto-update, a manual gateway restart).
#
# On each tick it reads `openclaw --profile edge memory status --agent
# support --deep` and classifies the index. If it is paused / its index
# metadata is missing / the vector store is not ready / it reports
# issues, the watchdog SELF-HEALS by running
# `openclaw --profile edge memory index --force --agent support`
# (the exact fix applied by hand this session), re-checks, and ALERTS
# #clio_devops with what it found and whether the rebuild restored it.
# This mirrors the codex-auth self-heal-and-alert pattern (the ensure-*
# scripts heal, a watchdog alerts) -- prose alone is not enforcement.
#
# Runs every ~10 min via /etc/cron.d/caroline-rag-index-watchdog ON
# NODE-8 (installed idempotently by scripts/install-aux-units.sh). Must
# run as root -- invokes openclaw against /root/.openclaw-edge and reads
# the devops bot token.
#
# Flags:
#   --dry-run   classify + print what WOULD happen (detect / would-heal /
#               would-post). Mutates NOTHING: no reindex, no Slack post,
#               no cooldown-state write.
#   --check     classify + print only; exit 1 if unhealthy, 0 if healthy.
#               No reindex, no post, no state. A manual / scriptable probe.
#
# Env knobs (defaults target the live edge gateway; mainly for tests):
#   CAROLINE_RAG_PROFILE        openclaw profile (default edge)
#   CAROLINE_RAG_AGENT          agent (default support)
#   CAROLINE_RAG_STATUS_FILE    pre-captured `memory status --deep` text
#                               (tests); default = live openclaw call
#   CAROLINE_RAG_NO_HEAL        1 = alert-only, never reindex (kill-switch)
#   CAROLINE_RAG_COOLDOWN_SECS  re-page suppression window (default 21600 = 6h)
#   CAROLINE_RAG_STATE_FILE     cooldown watermark (default
#                               /var/lib/caroline-rag-index-watchdog/last-alert)
#   CAROLINE_RAG_LOCKFILE       single-run lock
#   CAROLINE_RAG_SLACK_CHANNEL  target channel (default #clio_devops)
#   CAROLINE_RAG_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
#   OPENCLAW_BIN                openclaw binary (resolved to an absolute
#                               path for cron's minimal PATH; tests stub it)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[caroline-rag-index-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
PROFILE="${CAROLINE_RAG_PROFILE:-edge}"
AGENT="${CAROLINE_RAG_AGENT:-support}"
STATUS_FILE="${CAROLINE_RAG_STATUS_FILE:-}"
NO_HEAL="${CAROLINE_RAG_NO_HEAL:-0}"
COOLDOWN_SECS="${CAROLINE_RAG_COOLDOWN_SECS:-21600}"
STATE_FILE="${CAROLINE_RAG_STATE_FILE:-/var/lib/caroline-rag-index-watchdog/last-alert}"
LOCKFILE="${CAROLINE_RAG_LOCKFILE:-/var/run/caroline-rag-index-watchdog.lock}"
SKIP_HOST_GUARD="${CAROLINE_RAG_SKIP_HOST_GUARD:-0}"
DRY_RUN=0
CHECK_ONLY=0

# slack-notify.sh reads this (target channel).
export SLACK_CHANNEL="${CAROLINE_RAG_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --check)   CHECK_ONLY=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

# Resolve openclaw for cron's minimal PATH (/usr/bin:/bin). provision-peer-labels.sh
# documents /usr/bin/openclaw as the node-8 install location; fall back to
# /usr/local/bin too. Tests override OPENCLAW_BIN to a stub.
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
if [ "$OPENCLAW_BIN" = "openclaw" ] && ! command -v openclaw >/dev/null 2>&1; then
  for _cand in /usr/bin/openclaw /usr/local/bin/openclaw; do
    if [ -x "$_cand" ]; then OPENCLAW_BIN="$_cand"; break; fi
  done
fi

# ──────────────────────────────────────────────────────────────
# classify_memory_status -- pure detection core.
# Reads `memory status --deep` text on STDIN; echoes "ok" when the index
# is healthy, otherwise a "; "-joined list of the problems found. Keyed
# on the exact labels this session's live probe + validate-caroline-rag.sh
# use: a paused vector search, a missing index identity, a vector store
# that is not "ready", or a non-empty Issues: block. Pure (no openclaw /
# no I/O) so it is unit-testable with heredoc fixtures.
# ──────────────────────────────────────────────────────────────
classify_memory_status() {
  local status reasons=()
  status="$(cat)"

  if printf '%s\n' "$status" | grep -qiE "paused until memory is rebuilt|Vector search:[[:space:]]*paused"; then
    reasons+=("vector search paused")
  fi
  if printf '%s\n' "$status" | grep -qiE "index metadata is missing"; then
    reasons+=("index identity missing")
  fi
  if ! printf '%s\n' "$status" | grep -qiE "Vector store:[[:space:]]*ready"; then
    reasons+=("vector store not ready")
  fi
  # Non-empty Issues: block (same shape validate-caroline-rag.sh asserts):
  # awk exits 1 on the first non-empty line after `Issues:`.
  if ! printf '%s\n' "$status" | awk '/^Issues:/{flag=1; next} flag && NF{exit 1}'; then
    reasons+=("memory status reports issues")
  fi

  if [ "${#reasons[@]}" -eq 0 ]; then
    echo "ok"
    return 0
  fi
  local joined
  joined=$(printf '%s; ' "${reasons[@]}")
  echo "${joined%; }"
}

capture_status() {
  if [ -n "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    "$OPENCLAW_BIN" --profile "$PROFILE" memory status --agent "$AGENT" --deep 2>&1 || true
  fi
}

# ──────────────────────────────────────────────────────────────
# Inline self-test -- runs on EVERY invocation (~5ms). Guards the
# failure that would let THIS watchdog rot silently: a detector that no
# longer detects. A healthy fixture must classify "ok"; a paused fixture
# must NOT.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local healthy paused
  healthy="$(printf '%s\n' \
    "Embeddings: ready" "Vector store: ready" "Dreaming: off" "Issues:" \
    | classify_memory_status)"
  if [ "$healthy" != "ok" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: healthy status did not classify ok (got: $healthy)" >&2
    return 1
  fi
  paused="$(printf '%s\n' \
    "Vector search: paused until memory is rebuilt" \
    "Index identity: index metadata is missing" \
    | classify_memory_status)"
  if ! printf '%s' "$paused" | grep -q "paused"; then
    echo "$LOGPREFIX SELF-TEST FAIL: paused status did not flag a pause (got: $paused)" >&2
    return 1
  fi
  return 0
}

if ! _self_test; then
  log "ABORT: self-test failed -- refusing to run with a broken detector"
  exit 3
fi

# ──────────────────────────────────────────────────────────────
# Host guard: wrong node -> no-op. Skippable for tests. Skipped when a
# STATUS_FILE fixture is supplied (tests run off-host).
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && [ -z "$STATUS_FILE" ] \
   && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) -- script is node-8-specific"
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# --check: classify + report, mutate nothing, exit code = verdict.
# ──────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" -eq 1 ]; then
  verdict="$(capture_status | classify_memory_status)"
  if [ "$verdict" = "ok" ]; then
    log "OK: Caroline RAG index healthy (profile=$PROFILE agent=$AGENT)."
    exit 0
  fi
  log "UNHEALTHY: $verdict"
  exit 1
fi

# Single-run lock so overlapping ticks never double-reindex / double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another caroline-rag-index-watchdog run holds $LOCKFILE"; exit 0; }
fi

pre_verdict="$(capture_status | classify_memory_status)"

if [ "$pre_verdict" = "ok" ]; then
  log "OK: Caroline RAG index healthy (profile=$PROFILE agent=$AGENT)."
  # Healthy again -> clear the cooldown watermark so the NEXT incident
  # pages immediately rather than being suppressed by a stale window.
  [ "$DRY_RUN" -eq 0 ] && rm -f "$STATE_FILE"
  exit 0
fi

log "UNHEALTHY: $pre_verdict"

# ── Dry-run: report intent, mutate nothing ─────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$NO_HEAL" = "1" ]; then
    log "DRY-RUN: would alert ${SLACK_CHANNEL} (auto-heal disabled; would NOT reindex)."
  else
    log "DRY-RUN: would run 'openclaw --profile $PROFILE memory index --force --agent $AGENT', re-check, then alert ${SLACK_CHANNEL}."
  fi
  exit 0
fi

# ── Cooldown gate (BEFORE the heal): attempt a heal + page at most once per
# COOLDOWN_SECS for an ONGOING condition. This bounds the alert noise AND the
# expensive full re-embed -- otherwise a PERSISTENT failure (reindex returns 0
# but classify stays unhealthy) would re-embed the whole KB every tick. A
# transient pause heals on the first tick and the next healthy tick clears the
# watermark (above), so a re-break after a successful heal still heals promptly.
now="$(date +%s)"
last=0
if [ -f "$STATE_FILE" ]; then
  last="$(tr -dc '0-9' < "$STATE_FILE" 2>/dev/null || echo 0)"
  [ -n "$last" ] || last=0
fi
if [ "$((now - last))" -lt "$COOLDOWN_SECS" ]; then
  log "within cooldown (${COOLDOWN_SECS}s since last alert) -- skipping heal + alert this tick."
  exit 0
fi

# ── Self-heal: force a rebuild, then re-classify ───────────────
heal_line=""
post_verdict="$pre_verdict"
if [ "$NO_HEAL" = "1" ]; then
  heal_line="Auto-heal is disabled (CAROLINE_RAG_NO_HEAL=1); index NOT rebuilt."
  log "auto-heal disabled -- not reindexing."
else
  log "self-heal: forcing 'memory index --force' (profile=$PROFILE agent=$AGENT)..."
  reindex_rc=0
  # Time-box the re-embed: this process holds the flock fd, so a hung reindex
  # would wedge every future tick (flock -n skip) until killed. rc=124 on timeout.
  reindex_out="$(timeout 300 "$OPENCLAW_BIN" --profile "$PROFILE" memory index --force --agent "$AGENT" 2>&1)" || reindex_rc=$?
  if [ "$reindex_rc" -ne 0 ]; then
    log "self-heal: reindex command FAILED (rc=$reindex_rc): ${reindex_out:0:200}"
    heal_line="Forced reindex command FAILED (rc=$reindex_rc)."
  else
    log "self-heal: reindex command completed; re-checking status."
    heal_line="Forced reindex ran."
  fi
  post_verdict="$(capture_status | classify_memory_status)"
fi

# ── Build the alert ────────────────────────────────────────────
if [ "$post_verdict" = "ok" ]; then
  emoji=":white_check_mark:"
  headline="Caroline RAG index self-healed"
  body="Was: ${pre_verdict}. ${heal_line} Vector store is now ready; retrieval is grounded again."
else
  emoji=":rotating_light:"
  headline="Caroline RAG index STILL unhealthy after self-heal"
  body="Detected: ${post_verdict}. ${heal_line} Retrieval is returning nothing, so the pre-retrieval RAG hook will answer ungrounded. Run: ssh hydra openclaw --profile ${PROFILE} memory index --force --agent ${AGENT} ; then openclaw --profile ${PROFILE} memory status --agent ${AGENT} --deep"
fi
alert_text="${emoji} *${headline}* (${PROFILE}/${AGENT})
${body}"

log "$headline -- pre=[$pre_verdict] post=[$post_verdict]"

# Cooldown was already enforced before the heal; advance the watermark only on
# a CONFIRMED Slack delivery (below) so a failed post retries on the next tick.
payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT
jq -n --arg channel "$SLACK_CHANNEL" --arg text "$alert_text" \
  '{channel: $channel, text: $text}' > "$payload_file"

if slack_notify_payload_file_status "$payload_file"; then
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$now" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  log "posted alert to ${SLACK_CHANNEL}."
else
  log "WARN: Slack post failed -- leaving cooldown watermark unset so the next tick retries."
fi
