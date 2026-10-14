#!/bin/bash
# ──────────────────────────────────────────────────────────────
# OpenClaw Gateway Watchdog
#
# Runs every 2 minutes via cron ON NODE-8 (local to the gateway).
# Checks journalctl for successful agent runs and validates each
# gateway profile's config. Restarts openclaw-gateway if there
# are agent runs but zero successes (and it's not just upstream
# rate limiting), and posts to #clio_devops via the devops bot
# token on any anomaly.
#
# Cadence dropped from 10 min → 2 min after the 2026-05-05
# main-gateway crash-loop outage: the worst-case detection lag
# was the dominant component of the ~30 min ops-silent window.
# Validating 3 profiles + counting journal hits is ~100ms total.
#
# Install on node-8: managed by scripts/install-aux-units.sh
# (writes /etc/cron.d/openclaw-watchdog idempotently). Manual
# crontab installs are no longer the source of truth.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[openclaw-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
OPENCLAW_CONFIG="/root/.openclaw-main/openclaw.json"
CHECK_WINDOW_MIN=15
# Cooldown stamp dir. Overridable so the bats suite (which CI runs ON the live
# node-8 host) writes throwaway stamps instead of clobbering the production
# watchdog's real /tmp cooldown clocks.
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/tmp}"
# The RESTART cooldown stamp (shared by the STUCK and heap-trough restarts) is
# written as root, so it lives in a root-owned 0700 dir, NOT the /tmp default
# above: a predictable path under world-writable /tmp lets any local user
# pre-create it as a symlink and make root truncate an arbitrary file. Same
# class and same gate as DR_STATE_DIR/_dr_state_ok. One definition, both
# writers follow it. Never falls back to /tmp.
HEAP_STATE_DIR="${HEAP_STATE_DIR:-/var/lib/hydra-watchdog}"
_heap_state_ok() {
  mkdir -p "$HEAP_STATE_DIR" 2>/dev/null || true
  [ ! -L "$HEAP_STATE_DIR" ] && [ -d "$HEAP_STATE_DIR" ] && [ -O "$HEAP_STATE_DIR" ] \
    && chmod 700 "$HEAP_STATE_DIR" 2>/dev/null
}
COOLDOWN_FILE="$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
# Safe stamp: gate the dir, write a mktemp file inside it, then rename over the
# target (rename replaces a planted symlink instead of following it). An unsafe
# dir skips the stamp and logs it; callers never lose the restart for it.
_stamp_cooldown() {
  local t
  _heap_state_ok || { log "cooldown dir $HEAP_STATE_DIR unsafe (symlink/not ours) — NOT stamping cooldown"; return 0; }
  t=$(mktemp "$HEAP_STATE_DIR/cooldown.XXXXXX" 2>/dev/null) || { log "cooldown mktemp failed — NOT stamping cooldown"; return 0; }
  date +%s > "$t" && mv -f "$t" "$COOLDOWN_FILE" || rm -f "$t"
}
COOLDOWN_MIN=30  # Don't restart more than once per 30 min
GATEWAY_SERVICE="openclaw-gateway-main"  # PR 43: multi-gateway split

# MUS-1009 A2 / MUS-1588: proactive drain-restart on the 60-min heap TROUGH
# (see the block near the crash-loop check below for the full rationale).
# Env-overridable so the bats suite runs with no live gateway.
HEAP_TROUGH_RESTART_BYTES="${HEAP_TROUGH_RESTART_BYTES:-4294967296}"  # 4.0 GiB (50% of the 8192 MiB cap)
HEAP_TROUGH_WINDOW_MIN="${HEAP_TROUGH_WINDOW_MIN:-60}"
HEAP_TROUGH_MIN_SAMPLES="${HEAP_TROUGH_MIN_SAMPLES:-6}"
HEAP_TROUGH_MAX_GAP_MIN="${HEAP_TROUGH_MAX_GAP_MIN:-10}"  # largest hole tolerated in the window
# A non-numeric override must not silently disable the fail-closed sample
# floor: `[ N -lt "$HEAP_TROUGH_MIN_SAMPLES" ]` returns exit 2 (not 1) on a
# bad value, and an `if` condition is exempt from `set -e`, so the check would
# fall through the `elif`/`else` as though the floor had been cleared instead
# of aborting or erroring. Same digits-only guard idiom as _sane_epoch below.
#
# Digits-only is NOT sufficient on its own (GitHub Muso QA Bot, hydra#1046):
# bash's `[ -lt ]` represents both operands as (at most) a signed 64-bit
# integer, so an all-digit value past ~19 digits — e.g.
# HEAP_TROUGH_RESTART_BYTES=999999999999999999999999 — still passes the
# `case` guard below but makes `[` itself exit 2 ("integer expected") at the
# comparison. Same consequence as the non-numeric case: the `if`/`elif` does
# not trap it under `set -e`, so execution falls through to the NEXT branch —
# which for the leading sample-count check can still reach RESTART with far
# fewer than HEAP_TROUGH_MIN_SAMPLES real samples, and for the trough-vs-
# threshold `elif` is the RESTART branch outright. Bound the LENGTH (15
# digits — ~910 TiB, far past any real byte count or sample count, and
# comfortably inside bash's 19-digit signed-integer range with margin) in
# addition to digits-only, on BOTH knobs: fixing only the one named in a
# given finding leaves its sibling fail-open in the same way.
case "$HEAP_TROUGH_MIN_SAMPLES" in ''|*[!0-9]*) HEAP_TROUGH_MIN_SAMPLES=6 ;; esac
[ "${#HEAP_TROUGH_MIN_SAMPLES}" -le 15 ] || HEAP_TROUGH_MIN_SAMPLES=6
# The same mechanism applies here, in the worse direction: a non-numeric or
# overlong threshold makes the trough comparison itself error out and fall
# through to the RESTART branch — a config typo drain-restarts a perfectly
# healthy gateway every cooldown window, exit 0, with the log/Slack asserting
# a threshold crossing that never happened (MUS-1667 review finding 1; the
# length half is hydra#1046's bot finding).
case "$HEAP_TROUGH_RESTART_BYTES" in ''|*[!0-9]*) HEAP_TROUGH_RESTART_BYTES=4294967296 ;; esac
[ "${#HEAP_TROUGH_RESTART_BYTES}" -le 15 ] || HEAP_TROUGH_RESTART_BYTES=4294967296
# Same hazard for the other two numeric knobs consumed by shell/awk arithmetic.
case "$HEAP_TROUGH_MAX_GAP_MIN" in ''|*[!0-9]*) HEAP_TROUGH_MAX_GAP_MIN=10 ;; esac
[ "${#HEAP_TROUGH_MAX_GAP_MIN}" -le 6 ] || HEAP_TROUGH_MAX_GAP_MIN=10
case "$HEAP_TROUGH_WINDOW_MIN" in ''|*[!0-9]*) HEAP_TROUGH_WINDOW_MIN=60 ;; esac
[ "${#HEAP_TROUGH_WINDOW_MIN}" -le 6 ] || HEAP_TROUGH_WINDOW_MIN=60

# MUS-1298: a 100% failure ratio over 1 sample is not a signal. The 29 Sep
# 15:18 incident restarted the whole fleet off ONE failed run (a
# skill-workshop-review context-window overflow — an application error a
# restart cannot fix). STUCK now requires both a bad ratio (SUCCESS_COUNT -eq
# 0) AND a real sample (MSG_COUNT >= MIN_RUNS_FOR_STUCK).
MIN_RUNS_FOR_STUCK="${MIN_RUNS_FOR_STUCK:-3}"
# Liveness probe target for the STUCK gate below. Overridable so the bats
# suite can stub `curl` without needing a live gateway on node-8.
GATEWAY_LIVENESS_PROBE_URL="${GATEWAY_LIVENESS_PROBE_URL:-http://127.0.0.1:18789/}"

# Source the shared Slack helper. Both this watchdog and the new
# openclaw-pre-start-heal.sh need to post to the same #clio_devops
# channel via the gated muso CLI (devops bot, token pulled from
# MUSO_SLACK_ENV_FILE by the lib).
# Locating sibling lib via this script's own directory rather than
# a hard /opt/hydra path keeps the script working when invoked from
# a worktree (laptop test) or a deploy mirror.
_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

# drain_restart_gateway (MUS-1009 A2): the heap-trough trigger below must
# restart through the same drain-aware path as deploy.sh/codex-token-refresh.sh
# rather than a bare `systemctl restart` — a proactive restart ahead of an OOM
# still has in-flight turns worth draining.
# shellcheck source=lib/gateway-restart.sh
source "$_WATCHDOG_DIR/lib/gateway-restart.sh"
# Every OTHER drain_restart_gateway caller (codex-token-refresh.sh,
# codex-canonical-refresh.sh, codex-edge-mirror.sh, codex-reauth.sh,
# codex-account-rotate.sh) wires this per the lib's own caller contract
# (lib/gateway-restart.sh: "Callers that can page ... should notify on
# fallback so a permanently-broken safe path can't degrade silently").
# Without it, a broken safe-restart path degrades to a hard SIGTERM kill —
# cutting exactly the in-flight turns the drain exists to protect — while
# drain_restart_gateway still returns 0 and this trigger takes its SUCCESS
# branch, paging #clio_devops that the drain worked (MUS-1667 review
# finding 2). declare -F guards a sandbox that sources this lib standalone
# without slack-notify.sh, though this script always sources both.
_heap_trough_fallback_notify() { declare -F slack_notify >/dev/null && slack_notify "[heap-trough] $1" || true; }
export GATEWAY_FALLBACK_NOTIFY_FN="${GATEWAY_FALLBACK_NOTIFY_FN:-_heap_trough_fallback_notify}"

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh).
# The gateways are stopped ON PURPOSE for a window; without this the 2-min
# watchdog restarts them mid-archive (it corrupted the 2026-07 7.1 state archive)
# and pages a fleet that is down by design. Fail-safe: an absent/expired/malformed
# flag reads as "not in maintenance", so normal protection is the default and a
# forgotten window self-clears on TTL. See lib/maintenance-flag.sh.
# shellcheck source=lib/maintenance-flag.sh
source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

# Expected systemd log line that indicates a (re)start.
# systemd logs PAST TENSE ("Started ..."), NOT "Starting ...".
# If you change this regex, the inline self-test below fails loudly.
# Fixture captured from journalctl on node-8, 2026-04-07 (incident
# day: an 80-min crash loop went undetected because the previous
# version of this regex was 'Starting openclaw-gateway' which never
# matched anything systemd actually emits).
readonly RESTART_LOG_REGEX='Started openclaw-gateway-main\.service'
readonly RESTART_LOG_FIXTURE='Apr 07 20:51:14 ovh-node-8 systemd[1]: Started openclaw-gateway-main.service - OpenClaw Gateway HYDRA (main profile).'

log() { echo "$LOGPREFIX $1"; }

# MUS-1298 round 2 (QA NO-GO on hydra#1030): validate MIN_RUNS_FOR_STUCK before
# it reaches the numeric comparisons at the STUCK gate below. A malformed
# override (e.g. "three") makes `[ "$MSG_COUNT" -ge "$MIN_RUNS_FOR_STUCK" ]`
# emit "integer expression expected" and evaluate false — the STUCK block is
# silently skipped, so a dead gateway with 3+ failed runs is neither probed
# nor restarted. A non-positive override (e.g. "0", "-1") doesn't error, but
# neuters the sample-size floor and resurrects the exact single-run-restart
# bug this card fixed. A guard that can't parse its own threshold must still
# guard: reject anything that isn't a positive integer and fall back to 3
# loudly instead of skipping or weakening the check.
# MUS-1298 round 3 (GitHub QA bot NO-GO on hydra#1030 @ 1eccff79): bound the
# WIDTH too, not just the sign. An unbounded `[0-9]*` still accepts an
# all-digit value wide enough to exceed bash's 64-bit integer range (e.g. a
# 31-digit string), which hits the exact same "integer expression expected"
# failure mode as the non-numeric case. Cap at 1-999 (3 digits) — far above
# any threshold this watchdog would ever need, and small enough to never
# overflow a shell arithmetic comparison.
if ! [[ "$MIN_RUNS_FOR_STUCK" =~ ^[1-9][0-9]{0,2}$ ]]; then
  log "MIN_RUNS_FOR_STUCK='$MIN_RUNS_FOR_STUCK' is not a positive integer — falling back to 3"
  MIN_RUNS_FOR_STUCK=3
fi

# slack_notify is provided by lib/slack-notify.sh sourced above.
# It silently no-ops if the devops bot token can't be read (e.g., the
# main-profile config is itself broken — the exact case the new
# pre-start-heal flow handles).

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (cost: ~1ms).
# Guards against the bug class that silently broke this watchdog
# for months: a regex that never matched real systemd output.
# Three independent tripwires together:
#   1. fixture grep (catches regex drift vs real systemd format)
#   2. function-defined check (catches the slack_notify ordering bug)
#   3. variable-set check (catches GATEWAY_SERVICE wipeouts)
# ──────────────────────────────────────────────────────────────
_watchdog_self_test() {
  local failed=0

  # Assert 1: the restart regex matches the known-good systemd fixture.
  if ! echo "$RESTART_LOG_FIXTURE" | grep -qE "$RESTART_LOG_REGEX"; then
    echo "$LOGPREFIX SELF-TEST FAIL: RESTART_LOG_REGEX does not match RESTART_LOG_FIXTURE" >&2
    echo "  regex:   $RESTART_LOG_REGEX" >&2
    echo "  fixture: $RESTART_LOG_FIXTURE" >&2
    failed=1
  fi

  # Assert 2: slack_notify is defined before any caller references it.
  if ! declare -F slack_notify >/dev/null; then
    echo "$LOGPREFIX SELF-TEST FAIL: slack_notify function not defined" >&2
    failed=1
  fi

  # Assert 3: GATEWAY_SERVICE is a non-empty identifier.
  if [[ -z "${GATEWAY_SERVICE:-}" ]]; then
    echo "$LOGPREFIX SELF-TEST FAIL: GATEWAY_SERVICE is empty" >&2
    failed=1
  fi

  return $failed
}

# --self-test mode: explicit invocation by smoke-test.sh and humans
# verifying a fix. Exits 0 on pass, 1 on fail. No side effects.
if [[ "${1:-}" == "--self-test" ]]; then
  if _watchdog_self_test; then
    echo "$LOGPREFIX SELF-TEST PASS"
    exit 0
  else
    exit 1
  fi
fi

# Serialize ticks (bot Important on hydra#1046). The cron fires every 2 min with
# no other lock, but a heap-trough drain can run ~390s, so ticks overlap: two
# ticks that both read "no cooldown" each fire their own drain_restart_gateway
# (then competing hard SIGTERMs after the deadline), and the heap-sample file
# append/trim races the same way. A non-blocking flock makes the whole tick the
# critical section; the loser logs and exits 0. If the lock can't be opened or
# flock is absent we proceed unserialized (the old behaviour) and say so, rather
# than silently disabling the watchdog. fd 9 is closed for the DR healer child.
WATCHDOG_LOCK_FILE="${WATCHDOG_LOCK_FILE:-/run/lock/openclaw-watchdog.lock}"
if command -v flock >/dev/null 2>&1 && { exec 9>"$WATCHDOG_LOCK_FILE"; } 2>/dev/null; then
  flock -n 9 || { log "previous tick still running - skip"; exit 0; }
else
  log "watchdog lock $WATCHDOG_LOCK_FILE unavailable - running unserialized"
fi

# Implicit self-test on every cron run. If this fails in production,
# abort BEFORE we can silently misbehave — loud failure beats quiet
# safety-net rot. Best-effort Slack alert (slack_notify is defined
# above this point).
if ! _watchdog_self_test; then
  echo "$LOGPREFIX ABORTING: self-test failed — watchdog is misconfigured." >&2
  slack_notify ":rotating_light: *Watchdog self-test FAILED* on node-8 — watchdog aborted. Fix openclaw-watchdog.sh regex/function order." || true
  exit 1
fi

# ── DR layer-2 escalation (AI healer) ─────────────────────────────────────
# When a CRITICAL codex signature persists across DR_STRIKE_THRESHOLD
# consecutive ticks (~6 min at the 2-min cadence — the ExecStartPre healers
# and the auto-restart below have had their chance), hand off to
# dr-ai-healer.sh: the "AI-decides, code-executes" escalator (direct
# OpenRouter call — the one model path that works while the gateway/codex
# stack is down). Definitive code-heal failures (restart FAILED, crash loop)
# escalate immediately. The healer carries its own single-flight lock,
# cooldown, session budget and kill switch, so firing it here is cheap and
# idempotent; it runs in the background so a slow AI round can never stall
# the 2-min watchdog tick. DR_HEALER is overridable so the bats suite points
# it at a recorder stub instead of the real escalator.
DR_HEALER="${DR_HEALER:-$_WATCHDOG_DIR/dr-ai-healer.sh}"
DR_STRIKE_THRESHOLD="${DR_STRIKE_THRESHOLD:-3}"
# DR strike/log writes live in a dedicated root-owned 0700 dir, NOT the
# world-writable /tmp default of WATCHDOG_STATE_DIR: the watchdog runs as
# root and these paths are predictable, so under /tmp any local user could
# pre-create them as symlinks and make root truncate an arbitrary file.
# Fail closed: if the dir is a symlink or not ours, skip DR writes entirely.
DR_STATE_DIR="${DR_STATE_DIR:-/var/lib/hydra-dr}"
_dr_state_ok() {
  mkdir -p "$DR_STATE_DIR" 2>/dev/null || true
  [ ! -L "$DR_STATE_DIR" ] && [ -d "$DR_STATE_DIR" ] && [ -O "$DR_STATE_DIR" ] \
    && chmod 700 "$DR_STATE_DIR" 2>/dev/null
}
_dr_escalate() {
  [ -x "$DR_HEALER" ] || return 0
  _dr_state_ok || { log "DR state dir $DR_STATE_DIR unsafe (symlink/not ours) — NOT escalating"; return 0; }
  log "DR ESCALATION: signature '$1' — invoking dr-ai-healer.sh (background)"
  nohup "$DR_HEALER" --trigger "$1" >> "$DR_STATE_DIR/dr-ai-healer.log" 2>&1 9>&- &
}
_dr_strike() {
  _dr_state_ok || { log "DR state dir $DR_STATE_DIR unsafe (symlink/not ours) — NOT tracking strikes"; return 0; }
  local f="$DR_STATE_DIR/dr-strikes-$1" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  case "$n" in *[!0-9]*|"") n=0 ;; esac
  n=$((n + 1))
  if [ "$n" -ge "$DR_STRIKE_THRESHOLD" ]; then
    rm -f "$f"   # reset so a still-broken state re-strikes from zero (healer cooldown paces re-fires)
    _dr_escalate "$1"
  else
    echo "$n" > "$f"
  fi
}
_dr_clear() { [ -L "$DR_STATE_DIR" ] || rm -f "$DR_STATE_DIR/dr-strikes-$1"; }
# _dr_track <sig> <count>: strike while the detector fires, clear on a clean tick.
_dr_track() { if [ "${2:-0}" -gt 0 ]; then _dr_strike "$1"; else _dr_clear "$1"; fi; }

# Schema validity check (all profiles). Today's outage (2026-05-05) was a
# crash-loop on main caused by an out-of-band write that added schema-
# invalid keys (`subagents`, `agents.llm.idleTimeoutSeconds`, etc.). The
# crash-loop detector below catches restarts but only after journal entries
# accumulate; a fresh schema-invalid config that takes the gateway down
# during a quiet hour produces no agent activity → idle path → silent rot.
# Validate every cron tick instead. The crash-loop alert below has no
# cooldown either, so we match that pattern: alert every 10 min while
# broken (operator can ack/silence in Slack).
# Record each profile's verdict so the gateway-liveness check below can reuse it
# instead of re-running `openclaw config validate` (the heaviest per-tick call —
# see the cadence note above) a second time for a down profile.
declare -A GATEWAY_CONFIG_VALID=()
for profile in main edge; do
  PROFILE_VALID=$(openclaw --profile "$profile" config validate 2>&1 || true)
  if echo "$PROFILE_VALID" | grep -q "Config valid"; then
    GATEWAY_CONFIG_VALID[$profile]=1
  else
    GATEWAY_CONFIG_VALID[$profile]=0
    log "INVALID CONFIG on profile=${profile}: ${PROFILE_VALID}"
    slack_notify ":rotating_light: *${profile} profile config INVALID* on node-8 — gateway will not start (or will crash-loop). Run \`openclaw --profile ${profile} config validate\` and fix.\n\`\`\`${PROFILE_VALID}\`\`\`"
  fi
done

# ── Secret-file permission guard (proactive — prevents the 2026-06-15 outage) ─
# openclaw's secret loader is FAIL-CLOSED: a file-based secret provider whose
# file is group/other-accessible is rejected at (re)start/reload ("permissions
# are too open") and the gateway refuses to start. On 2026-06-15 a perm drift to
# 0644 on /opt/hydra/secrets/llm-provider-keys.json sat latent while the gateway
# ran, then a routine deploy's config reload re-validated it and crash-looped
# BOTH gateways into `failed` for ~10 min. The validate loop above does NOT
# catch this (the config schema was valid; only the secret file's perms were
# wrong). Detect drift every tick and re-tighten it BEFORE a reload trips it.
# pre-start-heal applies the same fix on (re)start; this closes the
# perms-drift-while-running gap. ensure-secret-perms.sh honors HYDRA_SECRETS_DIR.
if [ -x "$_WATCHDOG_DIR/lib/ensure-secret-perms.sh" ]; then
  if ! SECRET_PERM_OUT=$("$_WATCHDOG_DIR/lib/ensure-secret-perms.sh" --check 2>&1); then
    log "SECRET PERMS TOO OPEN: ${SECRET_PERM_OUT}"
    "$_WATCHDOG_DIR/lib/ensure-secret-perms.sh" >/dev/null 2>&1 || true  # re-tighten now
    slack_notify ":lock: *Secret file perms drifted* on node-8 — a file-based secret store was group/other-readable, which crash-loops the gateway on the next config reload (the 2026-06-15 fleet outage). The watchdog re-tightened it to 0600. Investigate what relaxed it:\n\`\`\`${SECRET_PERM_OUT}\`\`\`"
  fi
fi

# ── Sentry MCP registration drift (runtime-only state, no other alarm) ───────
# .mcp.servers carries an auth token so it is registered at RUNTIME, never
# committed -- which means nothing in git can restore it and no CI check can
# notice it is gone. On 2026-08-26 a failed deploy ATTEMPT fired rollback.sh,
# which restored the profile configs with a plain `cp` and destroyed the Sentry
# registration 17 hours after it was made. The deploy reported success (only
# attempt 2 passed, and `gh run list` shows just the latest attempt), the
# gateway was healthy, every existing guard read clean, and the loss was found
# days later by an unrelated dry-run failing. That silence is the bug this
# block closes.
#
# pre-start-heal re-converges it on every (re)start; this catches drift while
# the gateway keeps running, and PAGES rather than healing silently -- if
# something is removing it repeatedly we need to know, not to paper over it.
# Exit 1 = drifted (repairable), 2 = cannot tell. Both are worth saying out
# loud; only 1 is worth auto-healing.
if [ ! -x "$_WATCHDOG_DIR/lib/ensure-sentry-mcp.sh" ]; then
  # FAIL-OPEN GUARD, CLOSED. A bare `if [ -x ... ]` means that deleting the
  # healer (partial deploy, stray cleanup, lost exec bit) silently disables this
  # alarm FOREVER -- and the missing registration it exists to catch then
  # persists with no heal and no page. An absent enforcement mechanism is itself
  # the alarm condition, not a reason to stay quiet.
  log "SENTRY MCP HEALER MISSING: $_WATCHDOG_DIR/lib/ensure-sentry-mcp.sh is absent or not executable"
  slack_notify_critical ":satellite: *Sentry MCP healer is MISSING* on node-8 (\`lib/ensure-sentry-mcp.sh\` absent or not executable) — the drift check and auto-heal are DISABLED, so a lost registration would go unnoticed indefinitely. Expected from a deploy of \`scripts/lib/\`; check the last deploy."
elif [ -x "$_WATCHDOG_DIR/lib/ensure-sentry-mcp.sh" ]; then
  SENTRY_MCP_OUT=$("$_WATCHDOG_DIR/lib/ensure-sentry-mcp.sh" --check 2>&1) || SENTRY_MCP_RC=$?
  case "${SENTRY_MCP_RC:-0}" in
    0) ;;
    1) log "SENTRY MCP DRIFT: ${SENTRY_MCP_OUT}"
       if "$_WATCHDOG_DIR/lib/ensure-sentry-mcp.sh" >/dev/null 2>&1; then
         slack_notify ":satellite: *Sentry MCP registration had vanished* from \`/root/.openclaw-main/openclaw.json\` and the watchdog re-registered it from \`/opt/hydra/secrets/sentry.env\`. It is runtime-only state (the entry carries a token), so nothing in git would have restored it. Find out what removed it — \`/var/log/openclaw-legitimate-writes.log\` names every writer."
       else
         slack_notify_critical ":satellite: *Sentry MCP registration is GONE and could not be restored* — \`cto\`/\`qa\` have no Sentry tools. Usually \`/opt/hydra/secrets/sentry.env\` is missing (root, 0600, \`SENTRY_API_TOKEN=...\`). See RUNBOOK §Sentry issue triage.\n\`\`\`${SENTRY_MCP_OUT}\`\`\`"
       fi ;;
    3) # exit 3 = the sentry MCP is DISABLED by the healer's ESM_ENABLED
       # constant but is still registered in the live config. Healing here
       # REMOVES the server; it does not restore it. Kept as its own branch
       # because the rc=1 copy below says "re-registered", which would be the
       # exact opposite of what just happened (QA #929 v3 finding 1).
       log "SENTRY MCP DISABLED-BUT-PRESENT: ${SENTRY_MCP_OUT}"
       if "$_WATCHDOG_DIR/lib/ensure-sentry-mcp.sh" >/dev/null 2>&1; then
         slack_notify ":satellite: *Sentry MCP was still registered while disabled* — the watchdog REMOVED it from \`/root/.openclaw-main/openclaw.json\`. The server is off by design (PR #929: removing the \`sentry__*\` denies restored native web search, and disabling the registration keeps the write surface unchanged until Aaron rules on fleet-wide \`sentry__update_issue\` access). \`cto\`/\`qa\` have no Sentry tools and that is expected. If you INTENDED to re-enable it, flip \`ESM_ENABLED\` in \`scripts/lib/ensure-sentry-mcp.sh\` in a PR — a live re-registration will just be removed again on the next tick."
       else
         slack_notify_critical ":satellite: *Sentry MCP is disabled but could NOT be removed* from \`/root/.openclaw-main/openclaw.json\` — the write surface is wider than intended until this is fixed.\n\`\`\`${SENTRY_MCP_OUT}\`\`\`"
       fi ;;
    *) # exit 2 = cannot tell (unreadable/invalid config, no secrets file). This
       # used to only log, which meant Sentry could be unavailable INDEFINITELY
       # with nothing paging -- the exact silent-failure shape this block exists
       # to close. "We could not check" is a third state, not a quiet pass.
       log "SENTRY MCP UNVERIFIABLE (exit ${SENTRY_MCP_RC}): ${SENTRY_MCP_OUT}"
       slack_notify_critical ":satellite: *Sentry MCP state UNVERIFIABLE* on node-8 (exit ${SENTRY_MCP_RC}) — the healer could not tell whether the registration is present, so \`cto\`/\`qa\` may have no Sentry tools and nothing will notice. Usually an unreadable/invalid \`/root/.openclaw-main/openclaw.json\` or a missing \`/opt/hydra/secrets/sentry.env\`.\n\`\`\`${SENTRY_MCP_OUT}\`\`\`" ;;
  esac
  unset SENTRY_MCP_RC
fi

# ── Gateway liveness (BOTH profiles) — checked BEFORE the activity logic ──────
# A FAILED/inactive gateway emits ZERO agent runs, which the "No agent activity
# — system idle, no action needed" branch further down silently swallows (it
# exits 0). That is exactly the 2026-06-15 outage: both main+edge sat systemd
# `failed` (fail-closed on a too-open secret file) for ~10 min while this
# watchdog logged "system idle, no action needed" every tick and never paged.
# The old edge-only liveness block lived AFTER that early exit, so when main had
# no activity it never ran either — a double blind spot. Liveness is orthogonal
# to agent activity, so check it FIRST, independently, for BOTH profiles.
# Config-invalid is already alarmed by the validate loop above and a restart
# won't fix it, so here we only auto-recover the valid-config-but-dead-process
# case: reset-failed (clears a tripped StartLimitBurst — else `restart` no-ops
# with "Start request repeated too quickly") then restart, whose ExecStartPre
# (pre-start-heal) re-tightens secret perms + codex auth before it comes back.
check_gateway_liveness() {
  local profile="$1" svc="$2" config_valid="$3" status now
  # is-active prints the state AND exits non-zero for every state but `active`,
  # so fall back only on EMPTY output — `|| echo` would append "unknown" to a
  # real state and no case arm below would ever match. `|| true` keeps the
  # non-zero exit from tripping `set -e`.
  status=$(systemctl is-active "$svc" 2>/dev/null || true)
  [ -n "$status" ] || status="unknown"
  case "$status" in
    active) return 0 ;;
    activating|reloading|deactivating)
      log "GATEWAY ${svc} transient state=${status} — skipping liveness action this tick"
      return 0 ;;
  esac

  log "GATEWAY DOWN: ${svc} status=${status}"
  # config_valid is the verdict the validate loop above already computed (1/0) —
  # reuse it rather than re-running the heavy `openclaw config validate`.
  if [ "$config_valid" != "1" ]; then
    log "  ${svc}: config INVALID — not restarting (the validate loop already alarms this)"
    return 0
  fi

  log "  ${svc}: config valid — reset-failed + restart"
  systemctl reset-failed "$svc" 2>/dev/null || true
  systemctl restart "$svc" || true
  # Poll the start. These units are Type=simple, so `is-active` reports "active"
  # the instant ExecStart forks — even for a process that crashes a second or two
  # later (then enters the RestartSec backoff, reported as "activating"). So a
  # single "active" read is NOT proof of recovery: require TWO consecutive
  # "active" samples (~2s apart) so a brief pre-crash window can't be mistaken
  # for durable recovery. Break early on "failed" (a definitive stop).
  now="unknown"; prev=""
  for _ in 1 2 3 4 5 6; do
    sleep 2
    now=$(systemctl is-active "$svc" 2>/dev/null || true)
    [ -n "$now" ] || now="unknown"
    [ "$now" = "failed" ] && break
    [ "$now" = "active" ] && [ "$prev" = "active" ] && break
    prev="$now"
  done
  if [ "$now" = "active" ] && [ "$prev" = "active" ]; then
    log "  ${svc}: recovered (status now active)"
    slack_notify ":white_check_mark: *${profile} gateway* was \`${status}\` on node-8 — watchdog ran \`reset-failed\` + restart and it is back online. ExecStartPre self-healed (secret perms / codex auth). Investigate the original cause: \`journalctl -u ${svc} -n 80 --no-pager\`."
  else
    log "  ${svc}: restart FAILED — status now ${now}"
    slack_notify_critical ":rotating_light: *${profile} gateway DOWN* on node-8 (\`${status}\` → restart → \`${now}\`). Config validates clean, so this is NOT a schema problem (suspect secrets / auth / runtime). Watchdog auto-restart FAILED — manual: \`ssh node-8; systemctl reset-failed ${svc}; systemctl restart ${svc}; journalctl -u ${svc} -n 120 --no-pager\`."
    # Code-level healing definitively failed (ExecStartPre ran, restart didn't
    # stick) → escalate to the AI healer immediately, no strike accumulation.
    _dr_escalate "gateway_restart_failed_${profile}"
  fi
  return 0
}

check_gateway_liveness main "$GATEWAY_SERVICE" "${GATEWAY_CONFIG_VALID[main]:-0}"
check_gateway_liveness edge openclaw-gateway-edge "${GATEWAY_CONFIG_VALID[edge]:-0}"

# Edge Codex (Caroline) silent-degradation watch. Runs on EVERY tick,
# independent of the success/idle/restart logic below (Caroline can be busy
# and failing while main is idle). Caroline = the support agent on edge,
# primary openai/gpt-5.6-sol via the Codex agentRuntime, with an
# openrouter gpt-5.6-luna → haiku text fallback AND an
# agents.defaults.imageModel vision pin. Those fallbacks mean a Codex auth
# failure does NOT take her down — she SILENTLY degrades (text -> openrouter
# luna, the sol quality lost) and, on vision exhaustion, loses image
# understanding. None of that surfaces in the
# config-validate counters above. Codex auth on edge does NOT log
# reason=auth; it logs the literal OAuth string and the image/pdf
# "All image models failed" summary — see scripts/lib/codex-health.sh.
# shellcheck source=lib/codex-health.sh
source "$_WATCHDOG_DIR/lib/codex-health.sh"
# shellcheck source=lib/version-compare.sh
source "$_WATCHDOG_DIR/lib/version-compare.sh"

# Overridable so the bats suite can point at a throwaway fixture instead of
# reading the live edge agent's auth store on the node-8 CI host.
EDGE_AUTH_PROFILES="${WATCHDOG_EDGE_AUTH_PROFILES:-/root/.openclaw-edge/agents/support/agent/auth-profiles.json}"
# Same seam for the 2.0-era surfaces the edge auth tripwire reads instead.
EDGE_MIRROR_CHECK="${WATCHDOG_EDGE_MIRROR_CHECK:-$_WATCHDOG_DIR/lib/codex-edge-mirror.sh}"
EDGE_MIRROR_TIMER="${WATCHDOG_EDGE_MIRROR_TIMER:-codex-edge-mirror.timer}"
CODEX_COOLDOWN_MIN=60  # token rotation is ~10-day; hourly re-alert is plenty

# _codex_cooldown_ok <stampfile> <minutes> — true if last alert older than N min.
# _sane_epoch <raw> <now> — echo a stamp that is SAFE for `$(( ))` epoch
# arithmetic, else 0. "Digits only" is not enough; three digit-only strings are
# still unsafe, and each breaks a cooldown differently:
#   - `08` — digits, but INVALID OCTAL. Bash reads a leading zero as base-8, so
#     `$(( ))` errors exactly like `1abc` does.
#   - `9999999999` — a valid FUTURE epoch. The age goes negative, which reads as
#     "just alerted/restarted" and suppresses for centuries.
#   - >10 digits — beyond any plausible epoch, and wide enough to overflow.
# `10#` forces base-10 so a leading zero is data, not a base marker. Anything not
# provably safe becomes 0 = "no recent alert/restart", i.e. fail toward acting.
_sane_epoch() {
  local raw="$1" now="$2" v
  case "$raw" in (''|*[!0-9]*) printf '0'; return ;; esac
  [ "${#raw}" -le 10 ] || { printf '0'; return; }
  v=$(( 10#$raw ))
  [ "$v" -le "$now" ] || { printf '0'; return; }   # future stamp → treat as none
  printf '%s' "$v"
}

_codex_cooldown_ok() {
  local f="$1" mins="$2" last now
  [ -f "$f" ] || return 0
  last=$(cat "$f" 2>/dev/null || echo 0)
  now=$(date +%s)
  # Normalise before the arithmetic. This function is called inside an `if`
  # condition, so a bad stamp does NOT abort the script — the failing `$(( ))`
  # aborts the compound command, neither branch runs, and the alert is silently
  # skipped while the tick sails on. A corrupt byte must never mute codex.
  last=$(_sane_epoch "$last" "$now")
  [ "$(( (now - last) / 60 ))" -ge "$mins" ]
}

# ── /dev/null char-device guard (MUS-6775) ──────────────────────────────────
# On 2026-10-09 /dev/null became a regular root-owned file (a `rm -rf /dev/null`
# over SSH); non-root `> /dev/null` then failed and PR Validation went red for
# hours as unrelated bats failures. PAGES ONLY: recreating a device node is a
# node-8 write that needs Nick (MUS-6760), and the file's content is the only
# record of what wrote to it. DEVNULL_PATH is a test seam.
DEVNULL_PATH="${DEVNULL_PATH:-/dev/null}"
# The cooldown stamp is written as root, so it lives in the root-owned 0700
# HEAP_STATE_DIR (same gate and mktemp+mv pattern as _stamp_cooldown), never under
# the world-writable /tmp default of WATCHDOG_STATE_DIR.
DEVNULL_STAMP="$HEAP_STATE_DIR/openclaw-watchdog-devnull-cooldown"
# An unsafe state dir (symlink/not ours) has no trustworthy stamp: never read one
# through it, or a planted recent stamp mutes the page. Page every tick instead.
if ! [ -c "$DEVNULL_PATH" ] && { ! _heap_state_ok || _codex_cooldown_ok "$DEVNULL_STAMP" "$CODEX_COOLDOWN_MIN"; }; then
  DEVNULL_LS=$(ls -ld "$DEVNULL_PATH" 2>&1 || true)
  log "DEVNULL NOT A CHAR DEVICE: ${DEVNULL_LS}"
  slack_notify_critical ":rotating_light: *node-8 ${DEVNULL_PATH} is not a char device* — every non-root \`> /dev/null\` fails and CI shows unrelated bats failures. The watchdog does NOT repair it (the file content is evidence). Restore is MUS-6760 and needs Nick.\n\`\`\`${DEVNULL_LS}\`\`\`"
  if _heap_state_ok && DEVNULL_TMP=$(mktemp "$HEAP_STATE_DIR/devnull.XXXXXX" 2>/dev/null); then
    date +%s > "$DEVNULL_TMP" && mv -f "$DEVNULL_TMP" "$DEVNULL_STAMP" || rm -f "$DEVNULL_TMP"
  else
    log "devnull cooldown dir $HEAP_STATE_DIR unsafe (symlink/not ours) — NOT stamping cooldown"
  fi
fi

# MUS-1298: gate the STUCK restart on a real liveness probe. 3 attempts, 10s
# apart. Any HTTP response (1xx-5xx) means the gateway is answering — the run
# failures are application-level and a restart won't fix them. Restart only
# when all 3 probes come back dead.
#
# Never write `$(curl … || echo 000)` — on a timeout curl already prints 000
# to stdout AND exits non-zero, so the `||` fallback appends a second one:
# `000000` passes a `!= 000` test and a dead gateway reads as healthy forever
# (muso-gateway-health §6). `|| true` here only neutralises curl's own exit
# status (required under `set -e`, else a refused/timed-out connection kills
# the whole watchdog tick instead of just failing this probe) — it prints
# nothing, so curl's own "000" write-out is never duplicated.
_gateway_probe_alive() {
  local attempt code
  for attempt in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$GATEWAY_LIVENESS_PROBE_URL" || true)
    code=${code:-000}
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 10
  done
  return 1
}

EDGE_LOGS=$(journalctl -u openclaw-gateway-edge --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)
# DR strikes need FRESH failures, not the 15-min alert window: a single
# historical error line rides that window for ~7 ticks and would 3-strike a
# fleet that already recovered. Strike counts come from a short window
# (default 3 min > the 2-min cadence, so an ONGOING failure is seen every
# tick while a one-off ages out after at most 2 ticks — below the threshold).
DR_STRIKE_WINDOW_MIN="${DR_STRIKE_WINDOW_MIN:-3}"
EDGE_LOGS_FRESH=$(journalctl -u openclaw-gateway-edge --since "${DR_STRIKE_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)
MAIN_LOGS_FRESH=$(journalctl -u openclaw-gateway-main --since "${DR_STRIKE_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)
CODEX_AUTHFAIL=$(printf '%s\n' "$EDGE_LOGS" | codex_count_auth_invalidated)
CODEX_VISIONFAIL=$(printf '%s\n' "$EDGE_LOGS" | codex_count_vision_failures)
# Strike on BOTH gateways' fresh logs: the 15-min ALERT above is edge-scoped
# (the #356 Caroline shape), but a persistent invalidated-auth failure on
# main alone must still reach layer 2 — like every other codex detector.
_dr_track codex_auth_invalidated "$(printf '%s\n%s\n' "$MAIN_LOGS_FRESH" "$EDGE_LOGS_FRESH" | codex_count_auth_invalidated)"

if [ "${CODEX_AUTHFAIL:-0}" -gt 0 ] && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-auth-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "EDGE CODEX AUTH DEAD: ${CODEX_AUTHFAIL} 'token invalidated' lines in last ${CHECK_WINDOW_MIN}min"
  slack_notify ":rotating_light: *Edge Codex auth FAILING* (Caroline/support) — ${CODEX_AUTHFAIL}x 'authentication token has been invalidated' in last ${CHECK_WINDOW_MIN}min. She has silently degraded to the openrouter gpt-5.6-luna text fallback (replies still work; gpt-5.6-sol quality lost) — this is the #356 shape. The edge auth symlink self-heals on \`systemctl restart openclaw-gateway-edge\` (ExecStartPre re-points it at a fresh main codex token via ensure-codex-auth). If it keeps firing after a restart, the main codex token is itself stale → re-auth codex on main."
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-auth-cooldown"
fi

if [ "${CODEX_VISIONFAIL:-0}" -gt 0 ] && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-vision-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "EDGE VISION DOWN: ${CODEX_VISIONFAIL} 'All image models failed' lines in last ${CHECK_WINDOW_MIN}min"
  slack_notify ":rotating_light: *Edge vision DOWN* (Caroline/support) — ${CODEX_VISIONFAIL}x 'All image models failed' in last ${CHECK_WINDOW_MIN}min. Customers sending screenshots/PDFs get no image understanding. imageModel is codex/gpt-5.6-sol → openrouter gemini → haiku, so this means codex AND both OpenRouter fallbacks failed — check OPENROUTER_API_KEY, codex auth, and \`openclaw --profile edge config validate\`."
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-vision-cooldown"
fi

# Edge auth-store integrity tripwire. The STORE's shape changed at openclaw
# 2026.8, so the tripwire has to change with it — there is no version-agnostic
# assertion here, because the healthy state on one side is the alarm state on
# the other.
#
#   < 2026.8  edge auth durability rests on auth-profiles.json being a SYMLINK
#             to main's canonical codex token. A deploy clobbering it (regular
#             file), a dangling link, or a missing store all silently
#             re-introduce #356 — alert before it bites.
#   >= 2026.8 there is no symlink and no per-agent JSON at all: each profile
#             reads its own `authProfiles.store` cell in
#             <stateDir>/state/openclaw.sqlite, and edge's is populated by
#             codex-edge-mirror.sh (ExecStartPre + a daily timer). The 7.1 probe
#             reads `missing` here BY DESIGN, and its remedy — restart edge to
#             re-run ensure-codex-auth — does nothing on 2.0. Left ungated it
#             paged hourly, for a healthy fleet, with an un-actionable fix. So
#             on 2.0 assert the surfaces that actually carry edge's credential:
#             the mirror's own read-only --check, and the timer that keeps it
#             converged.
#
# (We do NOT alert on token expiry in either era: the codex access token is
# ~9h-lived + refresh-on-use, so its `expires` carries no human-re-auth signal —
# a real auth death is caught by the `authentication token has been invalidated`
# tripwire above. See codex-health.sh.)
#
# An unreadable/unparseable runtime version is its OWN alert, never a skip: a
# tripwire that stays silent because it could not tell which era it is in is
# indistinguishable from a healthy one, and this guard exists precisely because
# the wrong-era check reported the wrong thing for six days.
_edge_auth_runtime_ver="$(openclaw_runtime_version)"
CODEX_EDGE_AUTH_STATUS=""
CODEX_EDGE_AUTH_DETAIL=""
if [ -z "$_edge_auth_runtime_ver" ]; then
  CODEX_EDGE_AUTH_STATUS="unevaluated"
  CODEX_EDGE_AUTH_DETAIL="\`openclaw --version\` is missing or not version-shaped, so the era of edge's auth store cannot be determined. Neither the 7.1 symlink probe nor the 2.0 cell probe can be trusted until that is resolved — run \`openclaw --version\` on node-8."
elif version_at_least "2026.8" "$_edge_auth_runtime_ver"; then
  # 2.0 era: the cell + the mirror timer are the real invariants.
  _mirror_rc=0
  "$EDGE_MIRROR_CHECK" --check >/dev/null 2>&1 || _mirror_rc=$?
  _mirror_timer="$(systemctl is-enabled "$EDGE_MIRROR_TIMER" 2>/dev/null || echo unknown)"
  if [ "$_mirror_rc" -eq 1 ]; then
    CODEX_EDGE_AUTH_STATUS="cell-drift"
    CODEX_EDGE_AUTH_DETAIL="\`codex-edge-mirror.sh --check\` reports DRIFT on edge's \`authProfiles.store\` cell (missing row/profile, stale access or expires, accountId ≠ token claim, refresh slot not the sentinel, or a leaked refresh token). Caroline falls back to paid OpenRouter with \`Explicit auth order for openai has no usable profiles\` while this is true. Run that command on node-8 for the per-profile reason, then \`codex-edge-mirror.sh --dry-run\` before converging."
  elif [ "$_mirror_rc" -ne 0 ]; then
    CODEX_EDGE_AUTH_STATUS="unevaluated"
    CODEX_EDGE_AUTH_DETAIL="\`codex-edge-mirror.sh --check\` could not evaluate edge's auth cell (exit ${_mirror_rc}: runtime unknown, store/table missing, or node absent). Edge's credential state is UNKNOWN, not healthy."
  elif [ "$_mirror_timer" != "enabled" ]; then
    CODEX_EDGE_AUTH_STATUS="mirror-timer-${_mirror_timer}"
    CODEX_EDGE_AUTH_DETAIL="edge's auth cell is clean right now, but \`${EDGE_MIRROR_TIMER}\` is \`${_mirror_timer}\` (expected \`enabled\`). Main's access token rotates, so without the daily mirror edge's copy goes stale on its own — this is the outage that has not happened yet. \`systemctl enable --now ${EDGE_MIRROR_TIMER}\`."
  fi
else
  # 7.1 era: the symlink fabric is the real invariant.
  _symlink_status=$(codex_edge_auth_symlink_status "$EDGE_AUTH_PROFILES")
  if [ "$_symlink_status" != "ok" ]; then
    CODEX_EDGE_AUTH_STATUS="symlink-${_symlink_status}"
    CODEX_EDGE_AUTH_DETAIL="symlink status \`${_symlink_status}\` (expected \`ok\`). not-symlink=a deploy clobbered it; dangling=main source moved; missing=never provisioned. \`systemctl restart openclaw-gateway-edge\` re-runs ensure-codex-auth (ExecStartPre) to re-point it at main's canonical codex token."
  fi
fi

if [ -n "$CODEX_EDGE_AUTH_STATUS" ] && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-symlink-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "EDGE CODEX AUTH STORE status=${CODEX_EDGE_AUTH_STATUS} runtime=${_edge_auth_runtime_ver:-unknown}"
  slack_notify ":warning: *Edge Codex auth store* (Caroline/support) status: \`${CODEX_EDGE_AUTH_STATUS}\` on runtime \`${_edge_auth_runtime_ver:-unknown}\`. ${CODEX_EDGE_AUTH_DETAIL}"
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-symlink-cooldown"
fi

# ── Cross-process Codex refresh-race watch (main + edge) ──────────────────────
# 2026-06-08 outage: main AND edge both refresh the ONE shared codex token, but
# openclaw's refresh lock is per-state-dir, so the two processes raced at the
# 5-min pre-expiry margin → one rotated the single-use token, the loser POSTed
# the spent one → `refresh_token_reused` → the WHOLE codex fleet fell back to
# openrouter/openai/gpt-5.4-mini for 3.5h with NO alert (the auth tripwire above
# keys on a different string AND reads only the edge journal; today's 401s were
# on main, and a codex→openrouter fallback completes isError=false so the generic
# counters below never trip). Scan BOTH gateway journals for the refresh-race
# signature, and verify the lock-dir convergence that PREVENTS it is still live.
MAIN_CODEX_LOGS=$(journalctl -u openclaw-gateway-main --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)
CODEX_REFRESH_RACE=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_refresh_reused)
MAIN_CODEX_LOGS_FRESH="$MAIN_LOGS_FRESH"
# Escalating the race still helps: the healer re-checks lock convergence and
# otherwise pages no_action (a spent single-use token is unhealable by design).
_dr_track codex_refresh_race "$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS_FRESH" "$EDGE_LOGS_FRESH" | codex_count_refresh_reused)"

if [ "${CODEX_REFRESH_RACE:-0}" -gt 0 ] && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-refresh-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "CODEX REFRESH RACE: ${CODEX_REFRESH_RACE} refresh_token_reused lines (main+edge) in last ${CHECK_WINDOW_MIN}min"
  slack_notify_critical ":rotating_light: *Codex refresh-token race* — ${CODEX_REFRESH_RACE}x \`refresh_token_reused\` across main+edge in last ${CHECK_WINDOW_MIN}min. The ENTIRE codex fleet (gpt-5.6) has degraded to \`openrouter/openai/gpt-5.6-luna\`. The single-use refresh token is spent → this needs *interactive re-auth*: run \`/opt/hydra/scripts/lib/codex-reauth.sh\` on node-8 (device-code login + merge + sync + restart; it prints a URL and a code for Aaron). Prevention is the lock-dir convergence (ensure-codex-refresh-lock-shared.sh) — see the tripwire below.\n_NOTE: \`openclaw models auth login --provider openai-codex --device-code\` does NOT work here — the \`openai\` plugin that owns that flow is disabled and off \`plugins.allow\`._"
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-refresh-cooldown"
fi

# ── Codex SESSION REVOCATION watch (2026-07-27 outage) ────────────────────────
# OpenAI ended the OAuth session server-side (sign-in elsewhere / password change
# / admin action). The access token is structurally valid and unexpired, and the
# refresh chain is dead too, so codex-oauth-refresh.sh answers
# `refresh_token_invalidated`. ALL THREE ensure-* guards read CLEAN throughout —
# nothing is structurally wrong, the credential is simply revoked upstream. That
# is why this needs its own detector: no convergence check can ever see it.
# Ordered BEFORE the generic auth_permanent catch-all so the specific, actionable
# page wins. On 2026-07-27 this class was misreported as a refresh-token race and
# cost ~1h chasing lock convergence that was, and stayed, converged.
CODEX_SESSION_INVALID=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_session_invalidated)
_dr_track codex_session_invalidated "$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS_FRESH" "$EDGE_LOGS_FRESH" | codex_count_session_invalidated)"

if [ "${CODEX_SESSION_INVALID:-0}" -gt 0 ] && [ "${CODEX_REFRESH_RACE:-0}" -eq 0 ] \
   && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-session-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "CODEX SESSION REVOKED: ${CODEX_SESSION_INVALID} session-invalidated lines (main+edge) in last ${CHECK_WINDOW_MIN}min"
  slack_notify_critical ":rotating_light: *Codex session revoked upstream* — ${CODEX_SESSION_INVALID}x \`token_invalidated\`/\"access token could not be refreshed\" across main+edge in last ${CHECK_WINDOW_MIN}min, with ZERO \`refresh_token_reused\`. OpenAI ended the OAuth session for the active account, so the refresh chain is dead too — the fleet is on \`openrouter/openai/gpt-5.6-luna\`.\n*This is NOT the refresh race and NOT a token lapse* — the ensure-* guards will all read CLEAN; do not go chasing them. Recovery needs a real browser login: run \`/opt/hydra/scripts/lib/codex-reauth.sh\` on node-8, which prints a device URL + code for Aaron, then merges, syncs and restarts.\nIf another account still has quota, \`/opt/hydra/scripts/lib/codex-account-rotate.sh --auto\` may restore service immediately without waiting for a human."
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-session-cooldown"
fi

# ── Codex AUTH-PROFILE MIGRATION REQUIRED watch (openclaw >= 2026.8) ──────────
# On 2.0 the runtime expects credentials in the shared authProfiles.store row
# (config_machine_state / per-agent auth_profile_store), not the legacy
# per-agent JSON files this fleet ran on 7.x. A host that upgraded without
# first converging onto that shape refuses to serve codex and says so with the
# literal `AUTH_PROFILE_MIGRATION_REQUIRED` code, or "requires legacy
# credential migration". Structurally this is its own class — the credential
# is well-formed, just in the wrong shape for the runtime reading it — so it
# gets its own detector rather than folding into the session-revocation or
# catch-all paths. Ordered before the generic auth_permanent catch-all so the
# specific, actionable page wins. See scripts/lib/codex-auth-invariants.sh,
# the read-only checker for the 2.0 shape this signature means is missing.
CODEX_AUTH_MIGRATION_REQUIRED=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_auth_profile_migration_required)
_dr_track codex_auth_migration_required "$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS_FRESH" "$EDGE_LOGS_FRESH" | codex_count_auth_profile_migration_required)"

if [ "${CODEX_AUTH_MIGRATION_REQUIRED:-0}" -gt 0 ] \
   && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-migration-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "CODEX AUTH PROFILE MIGRATION REQUIRED: ${CODEX_AUTH_MIGRATION_REQUIRED} migration-required lines (main+edge) in last ${CHECK_WINDOW_MIN}min"
  slack_notify_critical ":rotating_light: *Codex auth profile migration required* — ${CODEX_AUTH_MIGRATION_REQUIRED}x \`AUTH_PROFILE_MIGRATION_REQUIRED\`/\"requires legacy credential migration\" across main+edge in last ${CHECK_WINDOW_MIN}min. The runtime is >= 2026.8 and expects the shared \`authProfiles.store\` row (config_machine_state), but a host has not converged onto that shape — the credential is well-formed, just in the wrong place.\n*This is NOT a refresh race, session revocation, or token lapse* — run \`scripts/lib/codex-auth-invariants.sh --check\` on node-8 to see exactly which invariant is violated (non-\`openai:*\` keys, un-archived legacy files, per-agent fan-out, missing/short store row) before touching anything."
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-migration-cooldown"
fi

# Convergence tripwire: if the two processes' refresh-lock dirs are no longer ONE
# shared physical dir, the race can recur on the next (~daily) refresh — alert
# BEFORE it bites. --check is read-only: exit 1 = not converged (CONV_OUT names
# the offenders). Guarded under `if !` so set -e never fires on the exit 1.
if [ -x "$_WATCHDOG_DIR/lib/ensure-codex-refresh-lock-shared.sh" ]; then
  if ! CONV_OUT=$("$_WATCHDOG_DIR/lib/ensure-codex-refresh-lock-shared.sh" --check 2>&1) \
     && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-lockconv-cooldown" "$CODEX_COOLDOWN_MIN"; then
    log "CODEX REFRESH-LOCK NOT CONVERGED: ${CONV_OUT}"
    slack_notify ":warning: *Codex refresh-lock convergence broke* on node-8 — the main & edge gateways' \`locks/oauth-refresh/\` are no longer one shared dir, so a concurrent codex refresh can race again (the 2026-06-08 \`refresh_token_reused\` outage). \`systemctl restart openclaw-gateway-edge\` re-runs the ExecStartPre healer to reconverge, or run \`scripts/lib/ensure-codex-refresh-lock-shared.sh\` on node-8.\n\`\`\`${CONV_OUT}\`\`\`"
    date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-lockconv-cooldown"
  fi
fi

# ── Codex plugin VERSION drift + #90925 api-key-route / OAuth-lapse watch ──────
# 2026-06-19 outage: a manual `plugins install @openclaw/codex@2026.6.1 --force`
# floated codex off the 2026.5.27 pin and reintroduced #90925 — gpt-5.5 mis-routes
# to the OpenAI api-key endpoint → `invalid_api_key` → the WHOLE fleet (main AND
# edge) ran on openrouter/gpt-5.4-mini for ~9h with ZERO alerts (the auth/refresh
# detectors key on different strings AND the auth tripwire reads edge only). Scan
# BOTH journals for the api-key-route signature and the OAuth token-lapse that
# originally triggered it, and verify codex is still on the pin. See
# scripts/lib/codex-version.sh + scripts/lib/ensure-codex-version-pinned.sh.
CODEX_APIKEY_ROUTE=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_apikey_route)
CODEX_TOKEN_EXPIRED=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_token_expired)
_dr_track codex_token_expired "$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS_FRESH" "$EDGE_LOGS_FRESH" | codex_count_token_expired)"

# Resolve the ACTUAL pin state ONCE (read-only; 0 clean / 1 drift / 2 read-err) and
# reuse it for BOTH the api-key-route verdict below and the pin-drift tripwire further
# down — an api-key 401 is only a "floated off pin" if the pin genuinely drifted. The
# `if !`/`|| PIN_CHECK_EXIT=$?` capture keeps set -e from firing on the nonzero exits.
PIN_CHECK_OUT=""
PIN_CHECK_EXIT=0
if [ -x "$_WATCHDOG_DIR/lib/ensure-codex-version-pinned.sh" ]; then
  PIN_CHECK_OUT=$("$_WATCHDOG_DIR/lib/ensure-codex-version-pinned.sh" --check 2>&1) || PIN_CHECK_EXIT=$?
else
  PIN_CHECK_EXIT=2  # can't verify the pin → treat api-key 401s as unverifiable
fi

# api-key-route 401s: page ONLY for the verdicts that need a human (float, unverifiable).
# The `compaction` verdict is a benign, self-recovering, no-action condition (the embedded
# summarizer bypassing the OAuth route while codex is healthy for real turns) — it must
# NOT page DevOps, and must NOT consume the shared api-key cooldown (else a benign
# compaction blip would mask a genuine float for the whole cooldown window). So the
# cooldown check + stamp live INSIDE the paging arms, not around the whole block.
if [ "${CODEX_APIKEY_ROUTE:-0}" -gt 0 ]; then
  CODEX_APIKEY_VERDICT=$(codex_apikey_route_verdict "$CODEX_APIKEY_ROUTE" "$PIN_CHECK_EXIT")
  _APIKEY_COOLDOWN="$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-apikey-cooldown"
  case "$CODEX_APIKEY_VERDICT" in
    compaction)
      # Log-only (forensics in the watchdog log); never pages, never touches the cooldown.
      log "CODEX API-KEY 401 WITH PIN INTACT: ${CODEX_APIKEY_ROUTE} invalid_api_key/Incorrect-API-key lines (main+edge) in last ${CHECK_WINDOW_MIN}min; codex ON pin — benign compaction path (trigger=cli_budget), self-recovers, NO page"
      _dr_clear codex_apikey_float
      ;;
    float)
      # Strike only on a GENUINE float with FRESH 401s (benign compaction must
      # never burn the AI healer's budget, and a historical 401 riding the
      # 15-min window must not re-strike after recovery); cooldown below gates
      # only the page.
      _dr_track codex_apikey_float "$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS_FRESH" "$EDGE_LOGS_FRESH" | codex_count_apikey_route)"
      if _codex_cooldown_ok "$_APIKEY_COOLDOWN" "$CODEX_COOLDOWN_MIN"; then
        log "CODEX #90925 API-KEY ROUTE: ${CODEX_APIKEY_ROUTE} invalid_api_key/Incorrect-API-key lines (main+edge) in last ${CHECK_WINDOW_MIN}min; pin DRIFTED"
        slack_notify ":rotating_light: *Codex floated off pin → #90925 api-key route* — ${CODEX_APIKEY_ROUTE}x \`invalid_api_key\`/\`Incorrect API key\` across main+edge in last ${CHECK_WINDOW_MIN}min AND codex is off the canonical pin (scripts/lib/codex-version.sh). An off-pin codex can route the fleet primary to the OpenAI api-key endpoint instead of the Codex OAuth route (the 6.x #90925 shape), so the WHOLE fleet is on \`openrouter/openai/gpt-5.6-luna\`. Fix: re-pin codex + restart — \`scripts/lib/ensure-codex-version-pinned.sh\` on node-8 (re-pins to the canonical version), then \`systemctl restart openclaw-gateway-main openclaw-gateway-edge\`. A plain restart also self-heals (ExecStartPre re-pins)."
        date +%s > "$_APIKEY_COOLDOWN"
      fi
      ;;
    unverifiable)
      if _codex_cooldown_ok "$_APIKEY_COOLDOWN" "$CODEX_COOLDOWN_MIN"; then
        log "CODEX API-KEY 401, PIN UNVERIFIABLE: ${CODEX_APIKEY_ROUTE} lines (main+edge) in last ${CHECK_WINDOW_MIN}min; --check exit ${PIN_CHECK_EXIT}"
        slack_notify ":warning: *Codex api-key 401s, pin state UNVERIFIABLE* — ${CODEX_APIKEY_ROUTE}x \`invalid_api_key\`/\`Incorrect API key\` across main+edge in last ${CHECK_WINDOW_MIN}min, but \`ensure-codex-version-pinned.sh --check\` could not read the pin (exit ${PIN_CHECK_EXIT}). Check the pin manually on node-8 before assuming a float.\n\`\`\`${PIN_CHECK_OUT}\`\`\`"
        date +%s > "$_APIKEY_COOLDOWN"
      fi
      ;;
  esac
else
  _dr_clear codex_apikey_float
fi

if [ "${CODEX_TOKEN_EXPIRED:-0}" -gt 0 ] && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-expired-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "CODEX OAUTH TOKEN EXPIRED: ${CODEX_TOKEN_EXPIRED} 'token is expired' lines (main+edge) in last ${CHECK_WINDOW_MIN}min"
  slack_notify_critical ":rotating_light: *Codex OAuth token expired* — ${CODEX_TOKEN_EXPIRED}x \`authentication token is expired\` across main+edge in last ${CHECK_WINDOW_MIN}min. The codex access token lapsed and refresh isn't renewing it → fleet on \`openrouter/openai/gpt-5.6-luna\`. FIRST try the browser-free path: \`/opt/hydra/scripts/lib/codex-oauth-refresh.sh\` then \`systemctl restart openclaw-gateway-main openclaw-gateway-edge\`. Only if that reports \`invalid_grant\`/\`refresh_token_invalidated\` (chain dead) run \`/opt/hydra/scripts/lib/codex-reauth.sh\` for a device-code login.\n_NOTE: \`openclaw models auth login --provider openai-codex --device-code\` does NOT work here — the \`openai\` plugin that owns that flow is disabled and off \`plugins.allow\`._"
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-expired-cooldown"
fi

# ── Codex auth-dead CATCH-ALL ─────────────────────────────────────────────────
# `reason=auth_permanent` with NONE of the specific classes matched. It says only
# "openclaw gave up on the codex credential", never why. Deliberately vague
# rather than confidently wrong: an unclassified page that says "triage this"
# beats a precise-sounding one pointing at the wrong subsystem, which is exactly
# what cost an hour on 2026-07-27. Placed here, after every specific detector has
# been computed, so those variables are genuinely set and not `:-0` defaults.
CODEX_AUTH_PERMANENT=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_auth_permanent)

if [ "${CODEX_AUTH_PERMANENT:-0}" -gt 0 ] && [ "${CODEX_REFRESH_RACE:-0}" -eq 0 ] \
   && [ "${CODEX_SESSION_INVALID:-0}" -eq 0 ] && [ "${CODEX_APIKEY_ROUTE:-0}" -eq 0 ] \
   && [ "${CODEX_TOKEN_EXPIRED:-0}" -eq 0 ] && [ "${CODEX_AUTH_MIGRATION_REQUIRED:-0}" -eq 0 ] \
   && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-authperm-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "CODEX AUTH DEAD (UNCLASSIFIED): ${CODEX_AUTH_PERMANENT} auth_permanent lines (main+edge) in last ${CHECK_WINDOW_MIN}min"
  slack_notify_critical ":rotating_light: *Codex auth failing — cause UNCLASSIFIED* — ${CODEX_AUTH_PERMANENT}x \`reason=auth_permanent\` across main+edge in last ${CHECK_WINDOW_MIN}min, but NONE of the known signatures (refresh race, session revoked, api-key route, token expired) matched. The fleet is on the openrouter fallback.\nTriage on node-8: \`ensure-codex-auth.sh --check\`, \`ensure-codex-version-pinned.sh --check\`, \`ensure-codex-refresh-lock-shared.sh --check\`, then read the live journal for the actual error string. If this fires repeatedly the signature is NEW — add a detector to \`scripts/lib/codex-health.sh\` so the next occurrence pages precisely."
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-authperm-cooldown"
fi

# ── Codex LIVENESS: is the fleet actually running on codex? ───────────────────
# Every detector above asks "is a known failure string present?". This asks the
# question that actually matters to the business: are turns being SERVED by
# codex, or by the paid openrouter rung? On 2026-07-27 all three ensure-* guards
# read CLEAN for the whole ~2h outage — nothing was structurally wrong, the
# credential was simply revoked upstream — so only this question would have said
# "no" throughout. It is signature-independent: it catches a NEW failure class
# nobody has written a detector for yet, which is the whole point.
#
# Requires TWO CONSECUTIVE unhealthy ticks before paging. A single tick is noisy:
# one transient auth blip during a session takeover or compaction can serve one
# turn on the fallback and self-recover (observed 17:28 on 2026-07-27). Two ticks
# means it is not recovering on its own.
CODEX_OPENROUTER_SERVING=$(printf '%s\n%s\n' "$MAIN_CODEX_LOGS" "$EDGE_LOGS" | codex_count_openrouter_serving)
_CODEX_LIVENESS_STREAK_FILE="$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-streak"
_CODEX_LIVENESS_LAST_FILE="$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-lastline"
_CODEX_LIVENESS_STREAK=$(cat "$_CODEX_LIVENESS_STREAK_FILE" 2>/dev/null || echo 0)
case "$_CODEX_LIVENESS_STREAK" in ''|*[!0-9]*) _CODEX_LIVENESS_STREAK=0 ;; esac

# The streak must count DISTINCT degradation events, not re-observations of one.
# This watchdog fires every 2min but reads a 15min journal window, so a single
# fallback line is visible for ~7 consecutive ticks — a naive per-tick increment
# would reach the 2-tick threshold ~4min after ONE transient blip, which is
# exactly the noise the threshold exists to suppress (a real one was observed
# 17:28 on 2026-07-27, self-recovered). So fingerprint the NEWEST matching line
# and only advance the streak when it actually changes; an unchanged fingerprint
# means we are still looking at the same event through an overlapping window.
# Fingerprint PER GATEWAY, not over the concatenation. The two journals are
# joined as "all main lines, then all edge lines", so a single `tail -n1` over
# the pair always returns edge's last match whenever edge has ANY — a stale edge
# event would then pin the fingerprint and silently hold the streak while main
# kept degrading. A per-unit tuple changes whenever EITHER gateway sees something
# new, which is the property the debounce actually needs.
_codex_liveness_fp() {
  printf '%s\n' "$1" | grep -E "decision=candidate_succeeded.*candidate=openrouter/" \
    | tail -n1 | cksum 2>/dev/null || true
}
_CODEX_LIVENESS_NEWEST="main:$(_codex_liveness_fp "$MAIN_CODEX_LOGS")|edge:$(_codex_liveness_fp "$EDGE_LOGS")"
_CODEX_LIVENESS_PREV=$(cat "$_CODEX_LIVENESS_LAST_FILE" 2>/dev/null || true)

if [ "${CODEX_OPENROUTER_SERVING:-0}" -gt 0 ]; then
  if [ "$_CODEX_LIVENESS_NEWEST" = "$_CODEX_LIVENESS_PREV" ]; then
    log "CODEX LIVENESS: still the SAME newest fallback line as last tick (overlapping ${CHECK_WINDOW_MIN}min window) — streak held at ${_CODEX_LIVENESS_STREAK}"
  else
    _CODEX_LIVENESS_STREAK=$((_CODEX_LIVENESS_STREAK + 1))
    echo "$_CODEX_LIVENESS_STREAK" > "$_CODEX_LIVENESS_STREAK_FILE"
  fi
  printf '%s' "$_CODEX_LIVENESS_NEWEST" > "$_CODEX_LIVENESS_LAST_FILE"
  log "CODEX LIVENESS: ${CODEX_OPENROUTER_SERVING} turn(s) served by openrouter in last ${CHECK_WINDOW_MIN}min (consecutive tick ${_CODEX_LIVENESS_STREAK})"
  if [ "$_CODEX_LIVENESS_STREAK" -ge 2 ] \
     && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-cooldown" "$CODEX_COOLDOWN_MIN"; then
    slack_notify_critical ":rotating_light: *Codex NOT serving — fleet on the paid openrouter rung* — ${CODEX_OPENROUTER_SERVING}x turns served by \`openrouter/*\` in the last ${CHECK_WINDOW_MIN}min, for ${_CODEX_LIVENESS_STREAK} consecutive checks. Agents are degraded AND this is costing per-token money.\nThis check is signature-independent, so the cause may be a class with no detector yet. Triage in order: (1) usage cap — \`/opt/hydra/scripts/lib/codex-usage.sh\` / rotate with \`codex-account-rotate.sh --auto\`; (2) session revoked — \`codex-reauth.sh\`; (3) token lapse — \`codex-oauth-refresh.sh\`; (4) the three \`ensure-*\` guards. If ALL read clean and none apply, the signature is new — capture the journal error string and add a detector to \`scripts/lib/codex-health.sh\`."
    date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-cooldown"
  fi
else
  [ "$_CODEX_LIVENESS_STREAK" -gt 0 ] && log "CODEX LIVENESS: recovered — codex is serving again (streak reset from ${_CODEX_LIVENESS_STREAK})"
  rm -f "$_CODEX_LIVENESS_STREAK_FILE" "$_CODEX_LIVENESS_LAST_FILE"
fi

# ── web_search managed-provider reconnect watch (main) ─────────────────────
# 2026-07 incident: PR #695 set `tools.web.search.provider:"codex"` on main,
# which on openclaw 7.1 disables NATIVE codex search (the two are mutually
# exclusive) — the managed worker then couldn't authenticate and every
# web_search call spun `Reconnecting... N/5` before failing. This was SILENT
# for ~15min because only internal agents (scout) call web_search and nothing
# probed it post-restart. #701 reverted the config and added a CI config gate
# (validate-config-matrix check 7) to block provider+native from landing
# again; this is the RUNTIME safety net for a bad config that still slips
# through. Main-only scan (MAIN_CODEX_LOGS is main's 15-min window, defined
# above) — web_search is not enabled on edge today. Page-only; the fix is a
# config change (revert/unset provider), never something to auto-heal.
CODEX_WEBSEARCH_RECONNECT=$(printf '%s\n' "$MAIN_CODEX_LOGS" | codex_count_websearch_reconnect)
if [ "${CODEX_WEBSEARCH_RECONNECT:-0}" -gt 0 ] && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-websearch-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "MAIN WEB_SEARCH BROKEN: ${CODEX_WEBSEARCH_RECONNECT} 'Reconnecting'/'provider reconnection failed' lines in last ${CHECK_WINDOW_MIN}min"
  slack_notify ":rotating_light: *web_search BROKEN on main* — ${CODEX_WEBSEARCH_RECONNECT}x \`Reconnecting\`/\`provider reconnection failed\` in last ${CHECK_WINDOW_MIN}min. Managed-provider misconfig or codex hosted-search auth failure (cf. #695/#701) — check \`tools.web.search\` in openclaw-main.json (provider + native are mutually exclusive on 7.1) and revert/unset \`tools.web.search.provider\` if set, then restart openclaw-gateway-main."
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-websearch-cooldown"
fi

# Pin-drift tripwire: page if codex != the deploy pin even without a 401 yet (a
# fresh float, or an ExecStartPre re-pin that failed). Reuses the single --check run
# above (PIN_CHECK_EXIT: 1 = drift, PIN_CHECK_OUT names the offenders).
if [ "$PIN_CHECK_EXIT" -eq 1 ] \
   && _codex_cooldown_ok "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-pin-cooldown" "$CODEX_COOLDOWN_MIN"; then
  log "CODEX VERSION DRIFT: ${PIN_CHECK_OUT}"
  slack_notify ":warning: *Codex version drifted off the pin* on node-8 — codex is not at the canonical pinned build (codex@2026.6.x reintroduces the #90925 api-key-route outage). \`systemctl restart\` the affected gateway to self-heal (ExecStartPre re-pins), or run \`scripts/lib/ensure-codex-version-pinned.sh\` on node-8.\n\`\`\`${PIN_CHECK_OUT}\`\`\`"
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-pin-cooldown"
fi

# Crash loop detection: if systemd has restarted the gateway more than
# 10 times in the last 10 minutes, something is wrong with the config.
# Don't add more restarts — alert and stop.
RESTART_COUNT=$(journalctl -u "$GATEWAY_SERVICE" --since "10 min ago" --no-pager 2>/dev/null \
  | grep -cE "$RESTART_LOG_REGEX" || true)
if [ "${RESTART_COUNT:-0}" -gt 10 ]; then
  log "CRASH LOOP DETECTED: ${RESTART_COUNT} restarts in 10 min — NOT restarting. Check openclaw.json for invalid config."
  slack_notify_critical ":rotating_light: *CRASH LOOP DETECTED* — Gateway restarted ${RESTART_COUNT} times in 10 min. Likely invalid config. NOT restarting. Run \`openclaw doctor --fix\` on node-8."
  # Definitive code-heal failure → immediate AI-healer escalation (its own
  # cooldown/budget prevent a storm while the loop persists).
  _dr_escalate crash_loop
  exit 0
fi

# ── Heap TROUGH proactive drain-restart (MUS-1009 A2 / MUS-1588) ─────────────
# 6 main-gateway heap-limit crashes in 8 days. Live heap is a sawtooth (one
# process went 5.66 -> 3.96 -> 3.08 -> 5.85 -> 4.23 GiB inside 40 minutes), so
# neither a single sample nor the latest reading is a usable trigger — a
# `heap >= 6.0` test would have drain-restarted the fleet 1-4x/hour. The
# MINIMUM of heapUsedBytes over a trailing HEAP_TROUGH_WINDOW_MIN (default 60)
# is the only monotonic signal: on the incident night it read 0.46 GiB at
# 05:00 UTC, 4.03 at 17:00 and 5.86 at 18:00, with the OOM at 18:59:17 — the
# trough alone tracked the climb toward the 8192 MiB cap.
#
# Source: the gateway's UNCONDITIONAL `diagnostic.memory.sample` stream
# (heapUsedBytes every 30s, read via `openclaw gateway stability`). NOT the
# journal's `[diagnostics/memory] memory pressure:` lines: those are emitted
# only while the process is above an adaptive pressure threshold and are
# rate-limited per key, so a window of them holds only the HIGH samples — a GC
# dip below the threshold leaves no line and the "trough" reads falsely high
# (QA bot, hydra#1046). Parse heapUsedBytes (exact integer), never heap=.
#
# A read that returns nothing, or fewer than HEAP_TROUGH_MIN_SAMPLES
# samples, must NEVER default to firing — same fail-safe posture as the
# maintenance-flag check at the top of this script. This is an ADDITIONAL
# restart reason, not a bypass: the maintenance flag and the crash-loop block
# above already would have exited before this point if either applied, and
# this trigger shares the STUCK path's cooldown stamp below — one restart
# reason firing must suppress the other for COOLDOWN_MIN, since both restart
# the same unit.
#
# MUST be scoped to the CURRENTLY RUNNING process: samples persisted for a
# process a crash already killed must never be read as the new one's trough.
# Live-measured on node-8 (2026-09-30 18:59:53 UTC restart, the MUS-1009
# incident restart itself): the dying process's final hour was all above the
# threshold, and a read spanning the restart would drain-restart a 60-second-
# old gateway — restarting the very recovery pass this trigger exists to
# protect (the ~10min post-restart freeze noted in scripts/install-aux-units.sh).
# The sample file is therefore keyed to the unit's InvocationID (a fresh UUID
# systemd assigns on every (re)start); a different ID discards the file, so a
# restart is a hard boundary. An unreadable ID fails closed.
#
# The ring buffer behind the RPC only retains ~10 minutes (measured: 19-21
# samples at 30s cadence), so the 60-minute window is ACCUMULATED here, one
# tick at a time, in HEAP_TROUGH_SAMPLES_FILE ("# <InvocationID>" header, then
# "<ts_ms> <heapUsedBytes>" rows). That accumulation is only a trough if there
# are no holes in it — a missed tick, an unreachable RPC or a watchdog that was
# only just deployed all leave a stretch where a dip could have gone unseen.
# So coverage is part of the gate: no gap larger than HEAP_TROUGH_MAX_GAP_MIN
# anywhere from the window start to now, otherwise NO RESTART.
#
# The sample file lives in its OWN root-owned 0700 dir, NOT under the
# /tmp-default WATCHDOG_STATE_DIR: this runs as root and the path is
# predictable, so any local user could pre-create it (or its temp file) as a
# symlink and make root truncate an arbitrary file. Same class and same gate
# as DR_STATE_DIR/_dr_state_ok above; an unsafe dir skips the trigger (NO
# RESTART) and never falls back to /tmp.
HEAP_TROUGH_SAMPLES_FILE="$HEAP_STATE_DIR/openclaw-watchdog-heap-samples"
HEAP_TROUGH_INVOCATION_ID=$(systemctl show -p InvocationID --value "$GATEWAY_SERVICE" 2>/dev/null || true)
HEAP_TROUGH_STATS=""
HEAP_TROUGH_STATE_UNSAFE=0
if [ -n "$HEAP_TROUGH_INVOCATION_ID" ] && ! _heap_state_ok; then
  HEAP_TROUGH_STATE_UNSAFE=1
  log "HEAP TROUGH: heap state dir $HEAP_STATE_DIR unsafe (symlink/not ours) — skipping this tick, NOT restarting"
elif [ -n "$HEAP_TROUGH_INVOCATION_ID" ]; then
  HT_NOW_MS=$(( $(date +%s) * 1000 ))
  if [ "$(head -n 1 "$HEAP_TROUGH_SAMPLES_FILE" 2>/dev/null || true)" != "# $HEAP_TROUGH_INVOCATION_ID" ]; then
    printf '# %s\n' "$HEAP_TROUGH_INVOCATION_ID" > "$HEAP_TROUGH_SAMPLES_FILE"
  fi
  # `last` comes only from rows inside [window start, now]: a future-dated row
  # (gateway clock skew, host clock stepped back) must never become `last`, or
  # every later sample fails ts>last and the window silently stops filling.
  HT_START_MS=$(( HT_NOW_MS - HEAP_TROUGH_WINDOW_MIN * 60000 ))
  HT_LAST_MS=$(awk -v s="$HT_START_MS" -v n="$HT_NOW_MS" 'NR>1 && $1 ~ /^[0-9]+$/ && $1>=s && $1<=n {l=$1} END{print l+0}' "$HEAP_TROUGH_SAMPLES_FILE")
  # Append samples newer than what is stored. Parse stops at "summary": that
  # block repeats heapUsedBytes under `latest`, which is not a window sample.
  # Rows with a non-numeric or >15-digit value are dropped here, so nothing
  # overlong ever reaches a shell `[ -lt ]` (exit 2 inside an `elif` falls
  # through to the restart branch). `|| true`: an unreachable RPC is a gap,
  # which the coverage gate below turns into NO RESTART.
  openclaw --profile main gateway stability --type diagnostic.memory.sample \
    --limit 200 --timeout 10000 --json 2>/dev/null \
    | awk '/"summary"/{exit} /"ts":/{t=$2; gsub(/[^0-9]/,"",t)} /"heapUsedBytes":/{h=$2; gsub(/[^0-9]/,"",h); if(t!="" && h!="" && length(h)<=15 && length(t)<=15){print t, h}; t=""}' \
    | awk -v last="$HT_LAST_MS" '$1>last' >> "$HEAP_TROUGH_SAMPLES_FILE" || true
  # Trim to the window [start, now] (both ends), then: min, count,
  # covered(0/1), largest gap (min). The temp file is mktemp'd inside the safe
  # dir so its name is not predictable either. The stats pass re-applies the
  # same bounds, so a failed trim cannot let an out-of-window row count.
  HT_TMP=$(mktemp "$HEAP_STATE_DIR/heap-samples.XXXXXX" 2>/dev/null) || HT_TMP=""
  if [ -n "$HT_TMP" ]; then
    { printf '# %s\n' "$HEAP_TROUGH_INVOCATION_ID"
      awk -v s="$HT_START_MS" -v n="$HT_NOW_MS" 'NR>1 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && length($2)<=15 && $1>=s && $1<=n' "$HEAP_TROUGH_SAMPLES_FILE"; } > "$HT_TMP" \
      && mv "$HT_TMP" "$HEAP_TROUGH_SAMPLES_FILE" || rm -f "$HT_TMP"
  fi
  HEAP_TROUGH_STATS=$(awk -v s="$HT_START_MS" -v n="$HT_NOW_MS" -v g="$HEAP_TROUGH_MAX_GAP_MIN" '
    NR==1{prev=s; next}
    !($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1>=s && $1<=n) { next }
    { if (c==0 || $2<min) min=$2; c++; if ($1-prev>maxgap) maxgap=$1-prev; prev=$1 }
    END{ if (n-prev>maxgap) maxgap=n-prev
         print (c>0?min:0), c+0, (c>0 && maxgap<=g*60000 ? 1 : 0), int(maxgap/60000) }' "$HEAP_TROUGH_SAMPLES_FILE" || true)
else
  # Can't verify which process is even running -> can't verify the trough is
  # about that process. Same fail-safe posture as zero samples.
  log "HEAP TROUGH: could not read ${GATEWAY_SERVICE}'s InvocationID — skipping this tick, NOT restarting"
fi
HEAP_TROUGH_MIN_BYTES=$(printf '%s' "$HEAP_TROUGH_STATS" | cut -d' ' -f1)
HEAP_TROUGH_SAMPLE_COUNT=$(printf '%s' "$HEAP_TROUGH_STATS" | cut -d' ' -f2)
HEAP_TROUGH_COVERED=$(printf '%s' "$HEAP_TROUGH_STATS" | cut -d' ' -f3)
HEAP_TROUGH_MAX_GAP_SEEN=$(printf '%s' "$HEAP_TROUGH_STATS" | cut -d' ' -f4)

if [ -z "$HEAP_TROUGH_INVOCATION_ID" ] || [ "$HEAP_TROUGH_STATE_UNSAFE" -eq 1 ]; then
  :
elif [ "${HEAP_TROUGH_SAMPLE_COUNT:-0}" -lt "$HEAP_TROUGH_MIN_SAMPLES" ]; then
  log "HEAP TROUGH: ${HEAP_TROUGH_SAMPLE_COUNT:-0} heapUsedBytes sample(s) in last ${HEAP_TROUGH_WINDOW_MIN}min (< ${HEAP_TROUGH_MIN_SAMPLES} required) — not evaluating, NOT restarting"
elif [ "${HEAP_TROUGH_COVERED:-0}" != "1" ]; then
  log "HEAP TROUGH: ${HEAP_TROUGH_SAMPLE_COUNT} samples do not cover the last ${HEAP_TROUGH_WINDOW_MIN}min (largest gap ${HEAP_TROUGH_MAX_GAP_SEEN:-?}min > ${HEAP_TROUGH_MAX_GAP_MIN}min allowed) — a dip could be hidden, NOT restarting"
elif [ "$HEAP_TROUGH_MIN_BYTES" -lt "$HEAP_TROUGH_RESTART_BYTES" ]; then
  log "HEAP TROUGH: min heapUsedBytes=${HEAP_TROUGH_MIN_BYTES} over ${HEAP_TROUGH_SAMPLE_COUNT} samples in last ${HEAP_TROUGH_WINDOW_MIN}min (< ${HEAP_TROUGH_RESTART_BYTES} threshold) — healthy, no action"
else
  log "HEAP TROUGH: min heapUsedBytes=${HEAP_TROUGH_MIN_BYTES} over ${HEAP_TROUGH_SAMPLE_COUNT} samples in last ${HEAP_TROUGH_WINDOW_MIN}min >= ${HEAP_TROUGH_RESTART_BYTES} threshold"

  HEAP_TROUGH_COOLDOWN_OK=1
  if [ -f "$COOLDOWN_FILE" ]; then
    HT_LAST_RESTART=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    HT_NOW=$(date +%s)
    # Same corrupt/future-stamp hardening as the STUCK cooldown below.
    HT_LAST_RESTART=$(_sane_epoch "$HT_LAST_RESTART" "$HT_NOW")
    HT_ELAPSED=$(( (HT_NOW - HT_LAST_RESTART) / 60 ))
    if [ "$HT_ELAPSED" -lt "$COOLDOWN_MIN" ]; then
      log "HEAP TROUGH: SKIP restart — last restart ${HT_ELAPSED}min ago (cooldown: ${COOLDOWN_MIN}min)"
      HEAP_TROUGH_COOLDOWN_OK=0
    fi
  fi

  if [ "$HEAP_TROUGH_COOLDOWN_OK" -eq 1 ]; then
    log "HEAP TROUGH: drain-restarting ${GATEWAY_SERVICE} before V8 aborts"
    # Stamp the cooldown BEFORE the (up to GATEWAY_DRAIN_DEADLINE_SECS, default
    # 390s) drain call, not after. The watchdog cron fires every 2min with no
    # flock, so a stamp written only on return leaves every overlapping tick
    # during the drain free to read "no cooldown" and fire its OWN
    # drain_restart_gateway — each one racing its own 390s await and, on
    # timeout, its own hard `systemctl restart` SIGTERM, exactly the in-flight
    # turns the drain path exists to protect. The STUCK path below can safely
    # stamp AFTER because its bare `systemctl restart` returns in seconds, not
    # minutes — that precedent does not transfer to this multi-minute call.
    _stamp_cooldown
    if drain_restart_gateway "$GATEWAY_SERVICE" main; then
      log "HEAP TROUGH: drain-restarted ${GATEWAY_SERVICE} proactively (MUS-1009 A2)"
      slack_notify ":recycle: *main gateway heap trough* — min heapUsedBytes=${HEAP_TROUGH_MIN_BYTES} over ${HEAP_TROUGH_SAMPLE_COUNT} samples in the last ${HEAP_TROUGH_WINDOW_MIN}min stayed at/above the ${HEAP_TROUGH_RESTART_BYTES}-byte trough threshold — drain-restarted ${GATEWAY_SERVICE} proactively (MUS-1009 A2) before it hit the 8192 MiB cap."
    else
      log "HEAP TROUGH: drain-restart of ${GATEWAY_SERVICE} FAILED (safe path and hard fallback both failed)"
      slack_notify_critical ":rotating_light: *main gateway heap trough restart FAILED* — min heapUsedBytes=${HEAP_TROUGH_MIN_BYTES} over ${HEAP_TROUGH_SAMPLE_COUNT} samples crossed the ${HEAP_TROUGH_RESTART_BYTES}-byte threshold and BOTH the drain-restart and its hard-restart fallback failed. Manual: \`ssh node-8; systemctl reset-failed ${GATEWAY_SERVICE}; systemctl restart ${GATEWAY_SERVICE}\`."
      _dr_escalate heap_trough_restart_failed
    fi
  fi
fi

# Grab recent logs once
RECENT_LOGS=$(journalctl -u "$GATEWAY_SERVICE" --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null || true)

# Count successful agent runs in the last CHECK_WINDOW_MIN minutes
SUCCESS_COUNT=$(echo "$RECENT_LOGS" | grep -c 'run agent end.*isError=false' 2>/dev/null || true)
SUCCESS_COUNT=${SUCCESS_COUNT:-0}

# Count errors in the same window
ERROR_COUNT=$(echo "$RECENT_LOGS" | grep -c 'isError=true' 2>/dev/null || true)
ERROR_COUNT=${ERROR_COUNT:-0}

# Count messages received (agents were invoked)
MSG_COUNT=$(echo "$RECENT_LOGS" | grep -c 'run agent' 2>/dev/null || true)
MSG_COUNT=${MSG_COUNT:-0}

log "Check: ${SUCCESS_COUNT} successes, ${ERROR_COUNT} errors, ${MSG_COUNT} agent runs in last ${CHECK_WINDOW_MIN}min"

# If there are no agent runs at all, system might just be idle — don't restart
if [ "$MSG_COUNT" -eq 0 ]; then
  log "No agent activity — system idle, no action needed"
  exit 0
fi

# Check if errors are all upstream overloads (Anthropic 529 / OpenRouter 429) — if so,
# don't restart, it won't help.
OVERLOAD_COUNT=$(echo "$RECENT_LOGS" | grep -c 'overloaded_error\|Overloaded\|429.*overloaded\|rate limit reached' 2>/dev/null || true)
OVERLOAD_COUNT=${OVERLOAD_COUNT:-0}

if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$MSG_COUNT" -gt 0 ] && [ "$OVERLOAD_COUNT" -ge "$ERROR_COUNT" ] && [ "$ERROR_COUNT" -gt 0 ]; then
  log "API OVERLOADED: ${OVERLOAD_COUNT} upstream overload errors — NOT restarting (won't help)."
  exit 0
fi

# Sample-size guard: a 100% failure ratio over fewer than MIN_RUNS_FOR_STUCK
# runs is not a signal (the 29 Sep 15:18 incident restarted the whole fleet
# off ONE failed run). Keep SUCCESS_COUNT -eq 0 as the ratio term and
# MIN_RUNS_FOR_STUCK as the sample-size term — both are needed.
if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$MSG_COUNT" -gt 0 ] && [ "$MSG_COUNT" -lt "$MIN_RUNS_FOR_STUCK" ]; then
  log "INSUFFICIENT SAMPLE: ${MSG_COUNT} runs (< ${MIN_RUNS_FOR_STUCK}), 0 successes — not restarting"
  exit 0
fi

# If there are agent runs but zero successes AND it's not just API overload, the system is stuck
if [ "$SUCCESS_COUNT" -eq 0 ] && [ "$MSG_COUNT" -ge "$MIN_RUNS_FOR_STUCK" ]; then
  log "STUCK: ${MSG_COUNT} agent runs but 0 successes — checking cooldown"

  # Cooldown check — don't restart too frequently
  if [ -f "$COOLDOWN_FILE" ]; then
    LAST_RESTART=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    # Unlike _codex_cooldown_ok this is a plain assignment, so a bad stamp is
    # FATAL: the `$(( ))` fails, ELAPSED is never set, and `set -u` (line 21)
    # kills the tick on the next read — the watchdog stops watching everything
    # else from one corrupt byte. A future stamp is worse than fatal: it reads
    # as a restart that already happened and suppresses recovery indefinitely.
    LAST_RESTART=$(_sane_epoch "$LAST_RESTART" "$NOW")
    ELAPSED=$(( (NOW - LAST_RESTART) / 60 ))
    if [ "$ELAPSED" -lt "$COOLDOWN_MIN" ]; then
      log "SKIP: Last restart was ${ELAPSED}min ago (cooldown: ${COOLDOWN_MIN}min)"
      exit 0
    fi
  fi

  # Liveness gate: a real 100%-failure sample can still be application-level
  # (e.g. every run hitting the same context-window overflow) rather than a
  # frozen gateway. If the gateway answers at all, restarting won't help.
  if _gateway_probe_alive; then
    log "NOT STUCK: gateway answering on :18789 — ${MSG_COUNT} failed runs are application-level"
    exit 0
  fi

  # Capture the error pattern for the notification
  LAST_ERROR=$(journalctl -u "$GATEWAY_SERVICE" --since "${CHECK_WINDOW_MIN} min ago" --no-pager 2>/dev/null \
    | grep 'isError=true' | tail -1 | sed 's/.*error=/error=/' | head -c 200 || echo "unknown")

  # --- Proactive outage notice: post to ALL channels with recent activity ---
  log "Posting outage notice to active channels..."
  python3 /opt/hydra/scripts/outage-notify.py "$LAST_ERROR" 2>/dev/null || true

  log "Restarting openclaw-gateway..."
  systemctl restart "$GATEWAY_SERVICE"

  # Record restart time
  _stamp_cooldown

  # Wait for startup
  sleep 5

  # Verify it came back
  STATUS=$(systemctl is-active "$GATEWAY_SERVICE" 2>/dev/null || echo "unknown")

  if [ "$STATUS" = "active" ]; then
    log "Restart successful — gateway is active"

    # Wait for agents to fully initialize (Slack sockets connect)
    sleep 10

    # Scan for unanswered messages and build impact report
    AFFECTED=$(python3 /opt/hydra/scripts/scan-unanswered.py 2>/dev/null || echo "")

    NOTIFY_MSG=":warning: *OpenClaw Watchdog* — Auto-restarted gateway. ${MSG_COUNT} agent runs with 0 successes in last ${CHECK_WINDOW_MIN}min.\nLast error: \`${LAST_ERROR}\`\nStatus: back online :white_check_mark:"
    if [ -n "$AFFECTED" ]; then
      NOTIFY_MSG="${NOTIFY_MSG}\n\n:busts_in_silhouette: *Unanswered messages during outage:*\n${AFFECTED}"
    fi
    slack_notify "$NOTIFY_MSG"

    # Re-trigger unanswered requests so agents actually respond to them
    log "Re-triggering unanswered requests..."
    python3 /opt/hydra/scripts/retrigger-unanswered.py "$LAST_ERROR" 2>/dev/null || true
  else
    log "CRITICAL: Restart failed — gateway status: ${STATUS}"
    slack_notify_critical ":rotating_light: *OpenClaw Watchdog* — CRITICAL: Auto-restart FAILED. Gateway status: ${STATUS}. Manual intervention required."
    _dr_escalate gateway_restart_failed_activity
  fi
else
  log "Healthy: ${SUCCESS_COUNT}/${MSG_COUNT} agent runs succeeded"
fi

# --- Per-agent timeout detection ---
# Check if any agent has high timeout rate (agents acking but not responding)
TIMEOUT_COUNT=$(echo "$RECENT_LOGS" | grep -c 'reason=timeout' 2>/dev/null || true)
TIMEOUT_COUNT=${TIMEOUT_COUNT:-0}
if [ "$TIMEOUT_COUNT" -gt 5 ]; then
  log "HIGH TIMEOUT RATE: ${TIMEOUT_COUNT} timeouts in last ${CHECK_WINDOW_MIN}min"
  # Identify which agents are timing out
  TIMEOUT_AGENTS=$(echo "$RECENT_LOGS" | grep 'reason=timeout' | grep -oP 'provider=\S+' | sort | uniq -c | sort -rn | head -3)
  slack_notify ":warning: *Agent Timeout Alert* — ${TIMEOUT_COUNT} timeouts in last ${CHECK_WINDOW_MIN}min. Agents may be acking but not responding.\n${TIMEOUT_AGENTS}"
fi

# --- Unanswered message scan + auto-retrigger ---
UNANSWERED=$(python3 /opt/hydra/scripts/scan-unanswered.py 2>/dev/null || echo "")
UNANSWERED_COUNT=$(echo "$UNANSWERED" | grep -c '•' 2>/dev/null || true)
UNANSWERED_COUNT=${UNANSWERED_COUNT:-0}
if [ "$UNANSWERED_COUNT" -gt 0 ]; then
  log "UNANSWERED: ${UNANSWERED_COUNT} messages waiting for agent response"
  slack_notify ":warning: *${UNANSWERED_COUNT} unanswered @mentions detected*\n${UNANSWERED}"

  # Auto-retrigger unanswered messages via chat completions API
  GW_TOKEN=$(python3 -c "import json; print(json.load(open('${OPENCLAW_CONFIG}')).get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null || true)
  if [ -n "$GW_TOKEN" ]; then
    log "Retriggering ${UNANSWERED_COUNT} unanswered requests..."
    python3 /opt/hydra/scripts/retrigger-unanswered.py "auto-heal" 2>/dev/null || true
  fi
fi

# Edge gateway liveness is now handled by check_gateway_liveness() near the top
# of this script (before the activity-based early-exit), alongside main. The old
# edge-only block lived here, AFTER the "system idle" exit, so it never ran when
# main had no activity — the double blind spot behind the 2026-06-15 outage.
