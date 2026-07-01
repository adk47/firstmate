#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Caroline RAG index — heal-on-boot (edge/support)
#
# openclaw 2026.6.1 PAUSES the memory_search vector index on every edge
# gateway restart ("index metadata is missing" / "vector search paused") and
# does NOT auto-rebuild it (reference: memory-index-pause-after-upgrade;
# docs/lessons/openclaw-and-codex.md:174-181). Root-caused 2026-07-01: edge
# restarts ~once per deploy, so on busy merge days the index paused ~10x/day
# and stayed ungrounded until the every-10-min caroline-rag-index-watchdog.sh
# healed it. That ~10-min window (once per restart) was the "flapping".
#
# This closes the gap by rebuilding the index IMMEDIATELY after every edge
# start. It is fired NON-BLOCKING from the gateway unit's ExecStartPost (via
# openclaw-edge-reindex.service, installed by install-aux-units.sh), so it runs
# on deploy restarts, failed-deploy rollback restarts, manual restarts, AND
# Restart=always crash/OOM auto-restarts. (An ExecStartPost fires on every
# start including internal auto-restarts; a Wants= companion would be skipped on
# the auto-restart path — hence ExecStartPost, not Wants=.)
#
# Alerting: NONE. This healer is SILENT — it only logs (to the journal via
# systemd). Paging stays owned by caroline-rag-index-watchdog.sh (the every-
# 10-min safety net), so heal-on-boot can never become a new #clio_devops noise
# source. If the rebuild fails, the next watchdog tick pages.
#
# Runs as root on node-8 only. Shares the watchdog's flock so an on-start heal
# and a coincident cron tick can never both force a reindex.
#
# Env knobs (defaults target the live edge gateway; mainly for tests):
#   CAROLINE_RAG_PROFILE          openclaw profile (default edge)
#   CAROLINE_RAG_AGENT            agent (default support)
#   CAROLINE_RAG_STATUS_FILE      pre-captured `memory status --deep` (tests)
#   CAROLINE_RAG_LOCKFILE         shared single-run lock (default = the
#                                 watchdog's, so they mutually exclude)
#   CAROLINE_RAG_SKIP_HOST_GUARD  1 = skip the ovh-node-8 guard (tests)
#   REINDEX_READY_TIMEOUT_SECS    agents-bound readiness deadline (default 60)
#   REINDEX_SKIP_READY            1 = skip the readiness poll (tests)
#   OPENCLAW_BIN                  openclaw binary (resolved to an absolute path
#                                 for systemd's minimal PATH; tests stub it)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[openclaw-edge-reindex-on-start $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
PROFILE="${CAROLINE_RAG_PROFILE:-edge}"
AGENT="${CAROLINE_RAG_AGENT:-support}"
STATUS_FILE="${CAROLINE_RAG_STATUS_FILE:-}"
LOCKFILE="${CAROLINE_RAG_LOCKFILE:-/var/run/caroline-rag-index-watchdog.lock}"
SKIP_HOST_GUARD="${CAROLINE_RAG_SKIP_HOST_GUARD:-0}"
READY_TIMEOUT="${REINDEX_READY_TIMEOUT_SECS:-60}"
SKIP_READY="${REINDEX_SKIP_READY:-0}"

log() { echo "$LOGPREFIX $1"; }

# Resolve openclaw for systemd's minimal PATH (same block the watchdog uses for
# cron's PATH). Tests override OPENCLAW_BIN to a stub.
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
if [ "$OPENCLAW_BIN" = "openclaw" ] && ! command -v openclaw >/dev/null 2>&1; then
  for _cand in /usr/bin/openclaw /usr/local/bin/openclaw; do
    if [ -x "$_cand" ]; then OPENCLAW_BIN="$_cand"; break; fi
  done
fi

# Host guard: wrong node -> no-op. Skipped for tests / when a fixture is given.
if [ "$SKIP_HOST_GUARD" != "1" ] && [ -z "$STATUS_FILE" ] \
   && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) -- edge-only healer"
  exit 0
fi

capture_status() {
  if [ -n "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    # Time-boxed: a slow/hung `memory status` must not blow the unit's
    # TimeoutStartSec budget nor hold the shared lock indefinitely.
    timeout 60 "$OPENCLAW_BIN" --profile "$PROFILE" memory status --agent "$AGENT" --deep 2>&1 || true
  fi
}

# is_paused STATUS -> 0 if the index shows the restart-pause signature. Keyed on
# the exact labels caroline-rag-index-watchdog.sh's classify_memory_status uses.
is_paused() {
  printf '%s\n' "$1" \
    | grep -qiE "paused until memory is rebuilt|Vector search:[[:space:]]*paused|index metadata is missing"
}

# reindex -> force a full rebuild, time-boxed exactly like the watchdog / deploy
# post-flight. Echoes nothing; returns the command's rc (124 on timeout).
reindex() {
  local rc=0 out
  out="$(timeout 300 "$OPENCLAW_BIN" --profile "$PROFILE" memory index --force --agent "$AGENT" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || log "reindex rc=$rc: ${out:0:200}"
  return "$rc"
}

# Readiness gate: the daemon must finish binding agents before we reindex. A
# reindex issued mid-boot can be clobbered when the daemon re-writes/re-pauses
# index identity during its own startup, re-opening the gap. Poll the same
# agents-bound signal deploy.sh's wait_for_agents_bound uses. Best-effort: on
# timeout, log and continue (the CLI may still work; the 10-min watchdog is the
# ultimate net).
wait_ready() {
  [ "$SKIP_READY" = "1" ] && return 0
  # Real WALL-CLOCK deadline (bash $SECONDS), not a sleep-accumulator: a slow
  # `agents list` on a wedged gateway would otherwise let the loop run far past
  # READY_TIMEOUT. Each poll is also `timeout`-bounded so a single hung call
  # can't stall the deadline check. Keeps wait_ready ~READY_TIMEOUT even on a
  # sick gateway (best-effort: on timeout we log and reindex anyway).
  local deadline=$((SECONDS + READY_TIMEOUT)) bound=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    bound=$(timeout 15 "$OPENCLAW_BIN" --profile "$PROFILE" agents list --bindings 2>/dev/null | grep -c '^- ' || true)
    if [ "$bound" -ge 1 ]; then
      log "gateway ready ($bound agent(s) bound)."
      return 0
    fi
    sleep 3
  done
  log "WARN: gateway not ready after ${READY_TIMEOUT}s (no agents bound) -- attempting reindex anyway."
  return 0
}

# Wait for readiness BEFORE taking the lock, so the (up to READY_TIMEOUT)
# poll never holds the shared lock and blocks a watchdog tick.
wait_ready

# Single-run lock, shared with the watchdog. flock -n: whichever holds it heals;
# the other skips (the index still gets healed by the winner).
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "SKIP: caroline-rag-index lock held (a watchdog tick or another on-start heal is running)."
  exit 0
fi

pre="$(capture_status)"
if ! is_paused "$pre"; then
  log "OK: index not paused after start (profile=$PROFILE agent=$AGENT) -- nothing to heal."
  exit 0
fi

log "index paused after start -- forcing rebuild (profile=$PROFILE agent=$AGENT)..."
if ! reindex; then
  log "WARN: reindex FAILED -- leaving it for the 10-min watchdog to page."
  exit 0
fi

# Verify + retry once: a --force can lose the race with a busy gateway on a
# small index and re-pause (docs/lessons/openclaw-and-codex.md:180-181).
post="$(capture_status)"
if is_paused "$post"; then
  log "still paused after rebuild -- retrying reindex once (documented busy-gateway race)."
  reindex || true
  post="$(capture_status)"
fi

if is_paused "$post"; then
  log "WARN: index STILL paused after rebuild+retry -- leaving it for the 10-min watchdog to page."
else
  log "OK: index rebuilt and grounded (profile=$PROFILE agent=$AGENT)."
fi
exit 0
