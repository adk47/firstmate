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
# On each tick it reads `openclaw --profile $PROFILE memory status --agent
# $AGENT --deep` and classifies the index. If it is paused / its index
# metadata is missing / the vector store is not ready / it reports
# issues, the watchdog SELF-HEALS by running `openclaw --profile $PROFILE
# memory $HEAL_CMD --agent <each of $HEAL_AGENTS>` and re-checks the canary.
# The heal command is per-profile: edge uses `index --force`; main uses
# `status --index` (which clears main's identity-metadata pause -- `index
# --force` does not). Two cron instances run: edge/support and main/cmo
# (main heals its whole reference-bearing set; see install-aux-units.sh).
#
# A restart-caused pause self-heals within a few minutes, so a red page is
# SUPPRESSED for CAROLINE_RAG_GRACE_SECS after the gateway (re)started
# (the fresh index is still settling). When a paged index later recovers,
# the next healthy tick posts a threaded ":white_check_mark: resolved"
# reply on the original alert.
#
# Alerting is PROBLEM-ONLY -- it NEVER posts an "all good" / "self-healed"
# ping (those flooded #clio_devops ~8x/day; the green was the symptom, not
# news). It posts to #clio_devops in exactly two cases:
#   - HEAL FAILED: the rebuild did NOT restore the index (red page).
#   - FLAPPING: the index self-heals >= CAROLINE_RAG_FLAP_THRESHOLD times
#     within CAROLINE_RAG_FLAP_WINDOW_SECS. A one-off post-bump pause that
#     heals is expected and stays silent; a RECURRING pause means retrieval
#     is ungrounded between heals and the root cause is unaddressed -- that
#     pages ONCE per CAROLINE_RAG_FLAP_COOLDOWN_SECS (red).
# This mirrors the codex-auth self-heal-and-alert pattern (the ensure-*
# scripts heal, a watchdog alerts) -- prose alone is not enforcement.
#
# Runs every ~10 min via /etc/cron.d/caroline-rag-index-watchdog ON
# NODE-8 (installed idempotently by scripts/install-aux-units.sh) -- one
# instance per profile (edge/support and main/cmo). Must run as root --
# invokes openclaw against /root/.openclaw-$PROFILE and reads the devops
# bot token.
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
#   CAROLINE_RAG_AGENT          canary agent detection reads (default support)
#   CAROLINE_RAG_HEAL_CMD       heal subcommand (default: 'status --index' when
#                               PROFILE=main -- resets the identity-metadata
#                               pause -- else 'index --force')
#   CAROLINE_RAG_HEAL_AGENTS    space-separated agents to heal once the canary
#                               is paused (default = CAROLINE_RAG_AGENT; the main
#                               cron passes its whole reference-bearing set)
#   CAROLINE_RAG_GRACE_SECS     post-restart grace: skip the red page if the
#                               gateway (re)started < this many secs ago
#                               (default 300; <=0 disables)
#   CAROLINE_RAG_RESTART_EPOCH  test seam: override the gateway restart epoch
#                               (empty => systemctl ActiveEnterTimestamp)
#   CAROLINE_RAG_ALERT_TS_FILE  persisted Slack ts of the last red page, used to
#                               resolve it in-thread on the next healthy tick
#                               (default /var/lib/.../last-alert-ts)
#   CAROLINE_RAG_STATUS_FILE    pre-captured `memory status --deep` text
#                               (tests); default = live openclaw call
#   CAROLINE_RAG_NO_HEAL        1 = alert-only, never reindex (kill-switch)
#   CAROLINE_RAG_COOLDOWN_SECS  re-page suppression window (default 21600 = 6h)
#   CAROLINE_RAG_STATE_FILE     cooldown watermark (default
#                               /var/lib/caroline-rag-index-watchdog/last-alert)
#   CAROLINE_RAG_FLAP_THRESHOLD     successful heals within the window that
#                                   count as flapping (default 3)
#   CAROLINE_RAG_FLAP_WINDOW_SECS   flapping look-back window (default 86400 = 24h)
#   CAROLINE_RAG_FLAP_COOLDOWN_SECS re-page suppression for the flapping alert
#                                   (default 86400 = 24h -> at most one/day)
#   CAROLINE_RAG_HEAL_LOG           successful-heal timestamp log (default
#                                   /var/lib/caroline-rag-index-watchdog/heal-history)
#   CAROLINE_RAG_FLAP_STATE         flapping-alert watermark (default
#                                   /var/lib/caroline-rag-index-watchdog/last-flap-alert)
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
FLAP_THRESHOLD="${CAROLINE_RAG_FLAP_THRESHOLD:-3}"
FLAP_WINDOW_SECS="${CAROLINE_RAG_FLAP_WINDOW_SECS:-86400}"
FLAP_COOLDOWN_SECS="${CAROLINE_RAG_FLAP_COOLDOWN_SECS:-86400}"
HEAL_LOG="${CAROLINE_RAG_HEAL_LOG:-/var/lib/caroline-rag-index-watchdog/heal-history}"
FLAP_STATE="${CAROLINE_RAG_FLAP_STATE:-/var/lib/caroline-rag-index-watchdog/last-flap-alert}"
LOCKFILE="${CAROLINE_RAG_LOCKFILE:-/var/run/caroline-rag-index-watchdog.lock}"
SKIP_HOST_GUARD="${CAROLINE_RAG_SKIP_HOST_GUARD:-0}"

# Per-profile heal command. main's pause is an IDENTITY-METADATA pause that
# `index --force` "completes" but does NOT clear; `memory status --index` resets
# the metadata and actually clears it (operator-confirmed 2026-07-01). edge's
# pause is a different cause and heals with `index --force`.
if [ -n "${CAROLINE_RAG_HEAL_CMD:-}" ]; then
  HEAL_CMD="$CAROLINE_RAG_HEAL_CMD"
elif [ "$PROFILE" = "main" ]; then
  HEAL_CMD="status --index"
else
  HEAL_CMD="index --force"
fi
# Agents to heal once the canary ($AGENT) is detected paused. A gateway restart
# pauses ALL of a profile's agents' indexes at once, so detection stays cheap on
# the single canary while main heals its whole reference-bearing set. edge stays
# single-agent (default = the canary itself).
HEAL_AGENTS="${CAROLINE_RAG_HEAL_AGENTS:-$AGENT}"
# Post-restart grace: suppress the red page when the gateway (re)started < GRACE
# ago -- the pause is restart-expected and the fresh index is still settling.
GRACE_SECS="${CAROLINE_RAG_GRACE_SECS:-300}"
RESTART_EPOCH_OVERRIDE="${CAROLINE_RAG_RESTART_EPOCH:-}"   # test seam; empty => systemctl
# Slack ts of the last red page, persisted so the next healthy tick can resolve
# the alert with a threaded "recovered" reply, then clear it.
ALERT_TS_FILE="${CAROLINE_RAG_ALERT_TS_FILE:-/var/lib/caroline-rag-index-watchdog/last-alert-ts}"
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

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh):
# a window restarts the edge gateway (pausing the index) on purpose, so this
# self-heal/page would fight the operator. Fail-safe: an absent/expired/malformed
# flag reads as "not in maintenance".
# shellcheck source=lib/maintenance-flag.sh
source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

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

# post_alert TEXT -> 0 ONLY on a CONFIRMED Slack delivery, non-zero otherwise.
# Self-contained (its own temp payload + cleanup) so the two call sites
# (failed-heal page, flapping page) never clash on a shared EXIT trap.
post_alert() {
  local text="$1" pf rc=0
  pf="$(mktemp)"
  jq -n --arg channel "$SLACK_CHANNEL" --arg text "$text" \
    '{channel: $channel, text: $text}' > "$pf"
  slack_notify_payload_file_status "$pf" || rc=$?
  rm -f "$pf"
  return "$rc"
}

# post_alert_capture_ts TEXT -> post a red page and echo the delivered Slack ts
# on stdout; returns 0 ONLY on a CONFIRMED delivery. Lets the caller persist the
# ts so the next healthy tick can resolve the alert in-thread.
post_alert_capture_ts() {
  local text="$1" pf ts rc=0
  pf="$(mktemp)"
  jq -n --arg channel "$SLACK_CHANNEL" --arg text "$text" \
    '{channel: $channel, text: $text}' > "$pf"
  ts="$(slack_notify_payload_file_ts "$pf")" || rc=$?
  rm -f "$pf"
  printf '%s' "$ts"
  return "$rc"
}

# post_reply_in_thread TEXT THREAD_TS -> post TEXT as a threaded reply under
# THREAD_TS; returns 0 ONLY on a CONFIRMED delivery. _slack_post_payload already
# forwards .thread_ts, so this reuses the status-returning payload path.
post_reply_in_thread() {
  local text="$1" thread_ts="$2" pf rc=0
  pf="$(mktemp)"
  jq -n --arg channel "$SLACK_CHANNEL" --arg text "$text" --arg ts "$thread_ts" \
    '{channel: $channel, text: $text, thread_ts: $ts}' > "$pf"
  slack_notify_payload_file_status "$pf" || rc=$?
  rm -f "$pf"
  return "$rc"
}

# gateway_restart_epoch -> wall-clock epoch of the gateway unit's last
# ActiveEnter, or "" if unknown. Uses the ISO ActiveEnterTimestamp + `date -d`
# (matches openclaw-config-write-audit.sh:129 -- the *Monotonic variant is
# CLOCK_MONOTONIC and is NOT comparable to `date +%s`). Test seam:
# CAROLINE_RAG_RESTART_EPOCH short-circuits systemctl for hermetic bats.
gateway_restart_epoch() {
  if [ -n "$RESTART_EPOCH_OVERRIDE" ]; then
    printf '%s' "$RESTART_EPOCH_OVERRIDE"
    return 0
  fi
  local iso
  iso="$(systemctl show -p ActiveEnterTimestamp --value "openclaw-gateway-${PROFILE}.service" 2>/dev/null || true)"
  [ -n "$iso" ] || return 0
  date -d "$iso" +%s 2>/dev/null || true
}

# within_restart_grace -> 0 (true) ONLY when we KNOW the gateway restarted
# < GRACE_SECS ago (using the global $now). Unknown / unparseable timestamp =>
# false, i.e. we DO page (fail toward alerting, matching
# openclaw-config-write-audit's "empty timestamp -> still alert").
within_restart_grace() {
  [ "$GRACE_SECS" -gt 0 ] || return 1
  local re
  re="$(gateway_restart_epoch)"
  [ -n "$re" ] || return 1
  [ "$((now - re))" -lt "$GRACE_SECS" ]
}

# record_heal_and_count NOW -> append NOW to the heal log, prune entries older
# than FLAP_WINDOW_SECS, and echo how many heals remain in the window. This is
# the flapping signal: a healthy index never calls this; a flapping one bumps
# the count on every silent heal. Kept separate from the 6h cooldown watermark
# (which a healthy tick clears) so flapping survives the recover-then-rebreak
# cycle that the green spam came from.
record_heal_and_count() {
  local now="$1" cutoff
  cutoff=$(( now - FLAP_WINDOW_SECS ))
  mkdir -p "$(dirname "$HEAL_LOG")"
  touch "$HEAL_LOG"
  printf '%s\n' "$now" >> "$HEAL_LOG"
  awk -v c="$cutoff" '$1+0 >= c' "$HEAL_LOG" > "$HEAL_LOG.tmp" && mv "$HEAL_LOG.tmp" "$HEAL_LOG"
  awk 'END{print NR+0}' "$HEAL_LOG"
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
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -f "$STATE_FILE"
    # Resolve any OUTSTANDING red page in-thread, then clear its ts. Delete the
    # ts file ONLY on a confirmed reply so a failed post retries on a later
    # healthy tick. Only red pages write ALERT_TS_FILE, so flapping alerts never
    # get a resolve reply. (Top-level code -> no `local`.)
    if [ -s "$ALERT_TS_FILE" ]; then
      _resolve_ts="$(tr -dc '0-9.' < "$ALERT_TS_FILE" 2>/dev/null || true)"
      if [ -n "$_resolve_ts" ] && post_reply_in_thread ":white_check_mark: Caroline RAG index recovered (${PROFILE}/${AGENT}) -- resolved." "$_resolve_ts"; then
        rm -f "$ALERT_TS_FILE"
        log "resolved outstanding red alert in-thread (ts=$_resolve_ts)."
      else
        log "resolve-in-thread reply not delivered -- keeping ts file for a later healthy tick."
      fi
    fi
  fi
  exit 0
fi

log "UNHEALTHY: $pre_verdict"

# ── Dry-run: report intent, mutate nothing ─────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$NO_HEAL" = "1" ]; then
    log "DRY-RUN: would alert ${SLACK_CHANNEL} (auto-heal disabled; would NOT reindex)."
  else
    log "DRY-RUN: would run 'openclaw --profile $PROFILE memory $HEAL_CMD --agent <$HEAL_AGENTS>' and re-check the canary. Alerts ${SLACK_CHANNEL} ONLY if the heal fails or the index is flapping; a successful heal is silent."
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

# ── Self-heal: rebuild the index(es), then re-classify ─────────
heal_line=""
post_verdict="$pre_verdict"
if [ "$NO_HEAL" = "1" ]; then
  heal_line="Auto-heal is disabled (CAROLINE_RAG_NO_HEAL=1); index NOT rebuilt."
  log "auto-heal disabled -- not reindexing."
else
  log "self-heal: running 'memory $HEAL_CMD' for agents [$HEAL_AGENTS] (profile=$PROFILE)..."
  reindex_rc=0
  reindex_failed=""
  # shellcheck disable=SC2086  # HEAL_AGENTS is a script-controlled space-separated agent list
  for _ha in $HEAL_AGENTS; do
    _rc=0
    # Time-box each re-embed: this process holds the flock fd, so a hung heal
    # would wedge every future tick (flock -n skip) until killed. rc=124 on timeout.
    # shellcheck disable=SC2086  # HEAL_CMD is a script-controlled two-word subcommand
    reindex_out="$(timeout 300 "$OPENCLAW_BIN" --profile "$PROFILE" memory $HEAL_CMD --agent "$_ha" 2>&1)" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
      reindex_rc=$_rc
      reindex_failed="$reindex_failed $_ha"
      log "self-heal: heal FAILED for $_ha (rc=$_rc): ${reindex_out:0:160}"
    fi
  done
  if [ "$reindex_rc" -ne 0 ]; then
    heal_line="Heal ('memory $HEAL_CMD') FAILED for:${reindex_failed} (rc=$reindex_rc)."
  else
    log "self-heal: heal completed for [$HEAL_AGENTS]; re-checking status."
    heal_line="Heal ran ('memory $HEAL_CMD' for [$HEAL_AGENTS])."
  fi
  # Re-check the CANARY. A gateway restart pauses all a profile's agents
  # uniformly, so the canary is a faithful proxy for a restart-wide pause.
  post_verdict="$(capture_status | classify_memory_status)"
  # ...but the canary re-check CANNOT see a non-canary agent whose heal failed
  # independently (e.g. a per-agent re-embed error while cmo heals fine). Without
  # this, that failure would take the silent-success path below and the agent
  # could stay paused until the next deploy. Any heal failure counts as unhealthy
  # so the red page fires and names the failed agents. (QA #620.)
  if [ "$reindex_rc" -ne 0 ] && [ "$post_verdict" = "ok" ]; then
    post_verdict="canary healthy but heal FAILED for:${reindex_failed}"
  fi
fi

# ── Outcome ────────────────────────────────────────────────────
# A SUCCESSFUL self-heal is SILENT (no "all good" ping). It only pages when the
# index is FLAPPING -- healing repeatedly means retrieval is ungrounded between
# heals and a full re-embed runs every time, i.e. the root cause is unaddressed.
if [ "$post_verdict" = "ok" ]; then
  flap_count="$(record_heal_and_count "$now")"
  log "heal succeeded; staying silent (problem-only alerting). ${flap_count} heal(s) in the last $((FLAP_WINDOW_SECS/3600))h. ${heal_line}"

  last_flap=0
  if [ -f "$FLAP_STATE" ]; then
    last_flap="$(tr -dc '0-9' < "$FLAP_STATE" 2>/dev/null || echo 0)"
    [ -n "$last_flap" ] || last_flap=0
  fi
  if [ "$flap_count" -ge "$FLAP_THRESHOLD" ] && [ "$((now - last_flap))" -ge "$FLAP_COOLDOWN_SECS" ]; then
    flap_text=":rotating_light: *Caroline RAG index is flapping* (${PROFILE}/${AGENT})
The vector index has paused and been force-rebuilt ${flap_count} times in the last $((FLAP_WINDOW_SECS/3600))h (latest: ${pre_verdict}). It self-heals each time, but retrieval is ungrounded between each pause and the next ~10-min heal, and a full re-embed runs every time -- the root cause is unaddressed. Find what keeps pausing the index (out-of-band openclaw auto-update / ${PROFILE} restart churn): ssh hydra journalctl -u openclaw-gateway-${PROFILE}.service --since '24 hours ago' | grep -iE 'restart|upgrad|version|pause|index'"
    if post_alert "$flap_text"; then
      mkdir -p "$(dirname "$FLAP_STATE")"
      printf '%s\n' "$now" > "$FLAP_STATE.tmp" && mv "$FLAP_STATE.tmp" "$FLAP_STATE"
      log "posted FLAPPING alert to ${SLACK_CHANNEL} (count=${flap_count})."
    else
      log "WARN: flapping-alert Slack post failed -- leaving flap watermark unset so the next tick retries."
    fi
  fi
  exit 0
fi

# ── FAILURE: the heal did NOT restore the index -> page (red). ──
# Name the agent(s) to remediate: the ones whose heal FAILED (a non-canary agent
# the re-check can't see), else the canary that classify still reports unhealthy.
affected_agents="${reindex_failed:-}"; affected_agents="${affected_agents# }"
[ -n "$affected_agents" ] || affected_agents="$AGENT"
alert_text=":rotating_light: *Caroline RAG index STILL unhealthy after self-heal* (${PROFILE}/${AGENT})
Detected: ${post_verdict}. ${heal_line} The pre-retrieval RAG hook answers ungrounded for affected agent(s): ${affected_agents}. Run: ssh hydra 'for a in ${affected_agents}; do openclaw --profile ${PROFILE} memory ${HEAL_CMD} --agent \$a; done' ; then openclaw --profile ${PROFILE} memory status --agent ${AGENT} --deep"

log "STILL unhealthy after self-heal -- pre=[$pre_verdict] post=[$post_verdict]"

# Post-restart grace: if the gateway (re)started < GRACE_SECS ago, this pause is
# restart-expected and the fresh index is still settling -- defer the page one
# tick WITHOUT advancing the cooldown watermark (so the next tick, grace expired,
# pages if still broken). The heal already ran above, so repair is NOT skipped --
# only the noisy mid-restart page. Grace never gates the FLAPPING alert (that
# signal is about restart churn itself).
if within_restart_grace; then
  log "within post-restart grace (< ${GRACE_SECS}s since openclaw-gateway-${PROFILE} restart) -- deferring red page; NOT advancing watermark."
  exit 0
fi

# Cooldown was already enforced before the heal; advance the watermark only on
# a CONFIRMED Slack delivery so a failed post retries on the next tick. Capture
# the message ts so the next healthy tick can resolve the alert in-thread.
if red_ts="$(post_alert_capture_ts "$alert_text")"; then
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$now" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  if [ -n "$red_ts" ]; then
    mkdir -p "$(dirname "$ALERT_TS_FILE")"
    printf '%s\n' "$red_ts" > "$ALERT_TS_FILE.tmp" && mv "$ALERT_TS_FILE.tmp" "$ALERT_TS_FILE"
  fi
  log "posted alert to ${SLACK_CHANNEL}${red_ts:+ (ts=$red_ts)}."
else
  log "WARN: Slack post failed -- leaving cooldown watermark unset so the next tick retries."
fi
