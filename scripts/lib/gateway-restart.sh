#!/usr/bin/env bash
# gateway-restart.sh — drain-aware gateway restart (replaces bare `systemctl
# restart` on the deploy + codex-token-refresh paths).
#
# Why: `systemctl restart openclaw-gateway-*` sends SIGTERM — a hard kill that
# discards in-flight LLM turns and their not-yet-delivered replies (Caroline
# mid-answer to a customer, agents mid-task). With up to ~9 deploys/day, that
# was a real customer-facing cost. OpenClaw 2026.6.1 natively supports
# `openclaw gateway restart --safe`: the gateway drains active work (embedded
# runs, pending reply deliveries, queued turns, background execs) and then
# self-restarts via SIGUSR1 → exit(0) → systemd `Restart=always` brings it back
# with a NEW MainPID (that unit setting exists for exactly this, PR #169).
# Live-probed on node-8 2026-07-13: the CLI returns immediately (~3s) with
# `{"ok":true,"result":"deferred"|"scheduled",...}` and a preflight blocker
# list; the restart lands once work drains. NOTE: despite what the upstream
# docs suggest about `gateway.reload.deferralTimeoutMs` (default 5 min)
# forcing the restart on expiry, a busy main gateway was observed draining
# for ~12 min with NO forced restart — the request simply persists until the
# work actually drains. So GATEWAY_DRAIN_DEADLINE_SECS below is the REAL
# forcing mechanism: it bounds our client-side await, after which the caller
# falls back to a hard `systemctl restart` (today's behavior). 390s default
# ≈ the documented 300s deferral + RestartSec=10 + margin; on a gateway with
# long-running cron work (QA autoreviews) expect the fallback to fire.
#
# Fail-open by design: ANY safe-path failure (CLI error, RPC unreachable,
# deadline expiry, unit in failed state) falls back to the old hard
# `systemctl restart` — a deploy must always converge; the drain is an
# optimization, never a gate. Callers that can page (deploy.sh) should notify
# on fallback so a permanently-broken safe path can't degrade silently.
#
# Stale-code window (accepted): rsync lands new files BEFORE the restart, so
# the old process may run against new files on disk for up to the drain window
# (~5 min vs seconds today). Same hazard in kind as today, longer in degree —
# strictly better than killing the customer's turn.
#
# Env seams (read at CALL time so tests/callers can tune):
#   OPENCLAW_BIN / SYSTEMCTL_BIN / JOURNALCTL_BIN
#                                         binaries (default openclaw/systemctl/journalctl)
#   GATEWAY_EXEC_FN                       name of a function taking ONE shell
#                                         command string; deploy.sh passes
#                                         run_on_node8 so every probe honors
#                                         $HYDRA_LOCAL (ssh mode included).
#                                         Default: local bash -c.
#   HYDRA_HARD_RESTART=1                  escape hatch: skip the drain entirely
#   GATEWAY_DRAIN_DEADLINE_SECS (390)     await budget for the safe restart
#   GATEWAY_DRAIN_POLL_SECS (5)           await poll interval
#   GATEWAY_SAFE_REQUEST_TIMEOUT_SECS (30) timeout on the CLI request itself
#   GATEWAY_HARD_POLL_TRIES (15) / GATEWAY_HARD_POLL_SECS (2)
#                                         post-hard-restart is-active poll
#   GATEWAY_FALLBACK_NOTIFY_FN            optional: name of a function taking
#                                         one message string, invoked whenever
#                                         drain_restart_gateway falls back to
#                                         a hard restart (NOT on the explicit
#                                         HYDRA_HARD_RESTART hatch). Callers
#                                         that can page should set it so a
#                                         broken safe path is never silent.
#
# Pure functions only — no side effects at source time (edge-restart-gate.sh
# doctrine). Sourced by scripts/deploy.sh and scripts/codex-token-refresh.sh;
# tested by scripts/tests/gateway-restart.bats.

_gr_log() { echo "[gateway-restart] $*"; }

# Best-effort fallback pager — no-op unless the caller wired
# GATEWAY_FALLBACK_NOTIFY_FN (never lets a notify failure break the restart).
_gr_notify() {
  [ -n "${GATEWAY_FALLBACK_NOTIFY_FN:-}" ] || return 0
  "$GATEWAY_FALLBACK_NOTIFY_FN" "$1" || true
}

_gateway_exec_local() { bash -c "$1"; }

_gr_exec() { "${GATEWAY_EXEC_FN:-_gateway_exec_local}" "$1"; }

# gateway_main_pid <service> — echo the unit's MainPID ("0" when not running).
gateway_main_pid() {
  _gr_exec "${SYSTEMCTL_BIN:-systemctl} show -p MainPID --value $1"
}

# gateway_nrestarts <service> — echo systemd's own NRestarts counter (the
# number of times Restart=always has brought this unit back up since it was
# last reset). Empty on a read failure — callers must not treat empty as 0.
gateway_nrestarts() {
  _gr_exec "${SYSTEMCTL_BIN:-systemctl} show -p NRestarts --value $1"
}

# gateway_nrestarts_retry <service> — like gateway_nrestarts, but retries up
# to GATEWAY_NRESTARTS_RETRY_TRIES times (default 3, GATEWAY_NRESTARTS_RETRY_INTERVAL_SECS
# apart, default 1s) before giving up. A single transient `systemctl
# show`/SSH hiccup RIGHT AFTER a restart must not make the caller treat this
# as "no restart happened" (2026-09-23 QA finding on #1010: the caller used
# to fold a failed read into the same empty string as "this deploy never
# restarted the unit", which made check_gateway_not_crashlooping a silent
# no-op on exactly the class of transient failure this gate exists to survive
# — a crash loop right after a flaky read went unreported). Echoes the
# number on success; rc 1 (nothing echoed) only after every attempt failed —
# see gateway_crash_looping_state_only for what a caller should do then.
# _gr_posint <value> <default> <knob-name>: echo <value> if it is a positive
# integer, else echo <default> and WARN naming the knob. Every refusal-gate
# loop in this file that is driven by an env knob goes through this (QA on
# #1010, twice): `seq 1 0`, a negative or a non-number runs ZERO iterations on
# GNU, and a zero-iteration loop in a gate falls through to its "all clear"
# return. An invalid override falls back to the default instead of failing
# every deploy on a typo -- the property that matters is that the check runs.
# (macOS `seq 1 0` counts DOWN and prints "1 0", so the 0 case only
# reproduces on Linux, which is where deploys run.)
_gr_posint() {
  case "$1" in
    ''|*[!0-9]*|0) _gr_log "WARN: invalid $3='$1', using $2" >&2; printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
# _gr_nonneg <value> <default> <knob-name>: same, for an interval that may be 0.
_gr_nonneg() {
  case "$1" in
    ''|*[!0-9]*) _gr_log "WARN: invalid $3='$1', using $2" >&2; printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

gateway_nrestarts_retry() {
  local service="$1" tries interval i val
  tries="$(_gr_posint "${GATEWAY_NRESTARTS_RETRY_TRIES:-3}" 3 GATEWAY_NRESTARTS_RETRY_TRIES)"
  interval="$(_gr_nonneg "${GATEWAY_NRESTARTS_RETRY_INTERVAL_SECS:-1}" 1 GATEWAY_NRESTARTS_RETRY_INTERVAL_SECS)"
  for i in $(seq 1 "$tries"); do
    val="$(gateway_nrestarts "$service")" || val=""
    case "$val" in
      ''|*[!0-9]*) : ;;  # unreadable or non-numeric -> retry
      *) printf '%s\n' "$val"; return 0 ;;
    esac
    [ "$i" -lt "$tries" ] && sleep "$interval"
  done
  return 1
}

# gateway_crash_looping <service> <baseline_nrestarts> — rc 0 when the unit
# has restarted MORE times than baseline (captured by the caller immediately
# AFTER the restart it just performed on this unit finishes — see the "why
# AFTER, not before" note below — so a pre-existing nonzero counter never
# trips this, only restarts that happened SINCE), or is currently stuck
# `failed` / repeatedly seen `activating (auto-restart)`. rc 1 otherwise,
# including on an unreadable NRestarts (fails OPEN on the counter — the state
# checks below still catch a stuck unit; see the lib header's fail-open
# rationale).
#
# Why the baseline must be captured AFTER, not before: live-measured on
# node-8 (systemd 255) — an explicit `systemctl restart` on a unit RESETS its
# NRestarts to 0, while an ongoing `Restart=always` crash loop (no explicit
# restart in between) increments it every cycle (observed 0 -> 4 in 5s). A
# baseline read BEFORE our restart is worthless against a unit that was
# ALREADY crash-looping when the deploy restarted it (exactly the 2026-09-22
# incident: edge was already crash-looping when Step 6 restarted it; the
# restart zeroed the counter; 30s later current was ~1-2, so old-baseline
# `current > old_baseline` read false and the gate never fired). Reading the
# baseline right after our own restart sidesteps needing to know which kind
# of restart fired: a hard `systemctl restart` reads back 0 and a safe
# (SIGUSR1) restart reads back baseline_before+1 — both are still just "the
# unit's restart count as of the moment THIS deploy finished touching it",
# and any further increment past that point is a NEW crash this deploy must
# not paper over.
#
# The safe path (drain-restart via SIGUSR1 -> exit(0) -> systemd
# Restart=always) was checked against this file's own header (why: it is
# documented as reusing Restart=always to bring the unit back, the exact same
# trigger this function's own crash-loop measurement showed increments
# NRestarts) rather than assumed — so its post-restart NRestarts is baseline+1,
# not baseline+0, but capturing AFTER still produces the correct baseline
# either way because it never needs to know which of the two happened.
#
# The state-based fallback (is-failed / SubState) is SAMPLED across a short
# window rather than read once: between two crash cycles a unit reads
# ActiveState=active/SubState=running for the brief moment it's actually up
# (measured directly: a crash-looping unit was caught mid-window reading
# `running`), so a single snapshot is close to a coin flip on whether it
# lands during that window or during `auto-restart`/`failed`. Sampling
# GATEWAY_CRASHLOOP_STATE_SAMPLES times (default 3) GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS
# apart (default 1s) only runs when the NRestarts check was inconclusive (a
# hard restart having just zeroed the counter, no new crash counted yet), so
# it costs a few bounded seconds on exactly the case that needs it, never on
# every deploy step.
#
# This is deliberately blind to a merely SLOW bind: a process that is ACTIVE
# and simply hasn't finished loading its agents yet has an unchanged
# NRestarts and an ActiveState of "active" for the entire sampling window, so
# it never matches either branch here. That includes a FROZEN main (hydra
# #984): the frozen process is the same PID systemd already counted as
# started, it never restarts and never fails during the freeze, so this
# function cannot misread a freeze as a crash loop — a genuine crash loop is
# visible only through NRestarts having moved past its post-restart baseline
# or the unit repeatedly showing a restart/failed state, neither of which a
# freeze produces.
gateway_crash_looping() {
  local service="$1" baseline="$2" current
  current="$(gateway_nrestarts "$service")" || current=""
  case "$baseline" in ''|*[!0-9]*) baseline=0 ;; esac
  case "$current" in
    ''|*[!0-9]*) : ;;  # unreadable -> fall through to the state-only checks
    *) [ "$current" -gt "$baseline" ] && return 0 ;;
  esac
  gateway_crash_looping_state_only "$service"
}

# gateway_crash_looping_state_only <service> — the is-failed / auto-restart
# half of gateway_crash_looping, usable on its own when there is NO numeric
# baseline at all (every gateway_nrestarts_retry attempt after a performed
# restart still failed — see that function's header). Sampled the same way
# (GATEWAY_CRASHLOOP_STATE_SAMPLES times, GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS
# apart) and for the same reason: a single snapshot can land on the brief
# "running" gap between two crashes.
#
# Deliberately does NOT substitute a raw "read NRestarts once more right now,
# fail if > 0" heuristic when the baseline is unreadable: that number is NOT
# evidence of a crash on the SAFE (SIGUSR1) restart path, whose own
# legitimate self-restart increments NRestarts by exactly 1 through the same
# Restart=always mechanism a crash uses (see gateway_crash_looping's own
# header for the live measurement) — a bare `current > 0` would false-fail
# every healthy safe-restart deploy that happened to hit a flaky baseline
# read, which is worse than the silent-no-op bug this function exists to
# close. systemd's own is-failed/SubState are the only signals that stay
# meaningful with zero baseline, so those are all this checks.
gateway_crash_looping_state_only() {
  local service="$1" tries interval i sub
  tries="${GATEWAY_CRASHLOOP_STATE_SAMPLES:-3}"
  interval="${GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS:-1}"
  # Validated through the shared helper above (see _gr_posint).
  tries="$(_gr_posint "$tries" 3 GATEWAY_CRASHLOOP_STATE_SAMPLES)"
  interval="$(_gr_nonneg "$interval" 1 GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS)"
  for i in $(seq 1 "$tries"); do
    if _gr_exec "${SYSTEMCTL_BIN:-systemctl} is-failed --quiet $service" 2>/dev/null; then
      return 0
    fi
    sub="$(_gr_exec "${SYSTEMCTL_BIN:-systemctl} show -p SubState --value $service" 2>/dev/null)" || sub=""
    [ "$sub" = "auto-restart" ] && return 0
    [ "$i" -lt "$tries" ] && sleep "$interval"
  done
  return 1
}

# gateway_journal_tail <service> [lines] — bounded recent journal for a
# failure message. Best-effort: echoes whatever journalctl returns (empty on
# any failure), never dies — a broken/absent journalctl must not take down
# the fail() path that wants to quote it.
gateway_journal_tail() {
  local service="$1" lines="${2:-40}"
  _gr_exec "${JOURNALCTL_BIN:-journalctl} -u $service -n $lines --no-pager" 2>/dev/null || true
}

# request_safe_restart <service> <profile>
# rc 0 = request in flight (poll decides), 1 = request failed (fall back now),
# rc 2 = HYDRA_HARD_RESTART set (caller goes straight to hard restart).
# rc 124 from `timeout` maps to 0: a blocking CLI killed client-side almost
# certainly delivered the RPC — killing the client cannot un-schedule a
# gateway-side drain, so let the poll be the source of truth.
request_safe_restart() {
  local service="$1" profile="$2" rc=0
  [ "${HYDRA_HARD_RESTART:-0}" = "1" ] && return 2
  _gr_exec "timeout --kill-after=5 ${GATEWAY_SAFE_REQUEST_TIMEOUT_SECS:-30} ${OPENCLAW_BIN:-openclaw} --profile $profile gateway restart --safe --json" || rc=$?
  case "$rc" in
    0|124) return 0 ;;
    *)     _gr_log "safe-restart request for $service failed (rc=$rc)"; return 1 ;;
  esac
}

# await_gateway_restart <service> <old_pid>
# rc 0 once the unit is active with a NEW nonzero MainPID (the gateway
# self-restarted); rc 1 on deadline expiry or if the unit lands in `failed`
# (StartLimitBurst trip — reset-failed so the caller's fallback can start it).
# Tolerates the RestartSec=10 `activating` gap between exit(0) and the new PID.
await_gateway_restart() {
  local service="$1" old_pid="$2" deadline="${GATEWAY_DRAIN_DEADLINE_SECS:-390}" poll="${GATEWAY_DRAIN_POLL_SECS:-5}"
  local elapsed=0 pid
  # Fail CLOSED without a verified pre-request PID: with old_pid empty (e.g. a
  # transient ssh/systemctl failure at capture time), any nonzero PID would
  # look "new" and the still-running OLD gateway would be reported as a
  # successful restart — the caller would then skip the hard fallback and
  # proceed against stale code.
  if [ -z "$old_pid" ] || [ "$old_pid" = "0" ]; then
    _gr_log "WARN: no verified pre-request MainPID for $service — cannot detect a self-restart; failing closed"
    return 1
  fi
  while [ "$elapsed" -lt "$deadline" ]; do
    sleep "$poll"; elapsed=$((elapsed + poll))
    if _gr_exec "${SYSTEMCTL_BIN:-systemctl} is-failed --quiet $service" 2>/dev/null; then
      _gr_log "$service entered failed state during drain (start-limit?) — reset-failed"
      _gr_exec "${SYSTEMCTL_BIN:-systemctl} reset-failed $service" || true
      return 1
    fi
    if _gr_exec "${SYSTEMCTL_BIN:-systemctl} is-active --quiet $service" 2>/dev/null; then
      pid="$(gateway_main_pid "$service")" || pid=""
      if [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "$old_pid" ]; then
        _gr_log "$service restarted after drain (pid $old_pid -> $pid, ${elapsed}s)"
        return 0
      fi
    fi
  done
  _gr_log "WARN: $service did not restart within ${deadline}s drain budget"
  return 1
}

# hard_restart_gateway <service> — today's behavior: `systemctl restart` +
# bounded is-active poll. rc 0 on active, 1 otherwise.
hard_restart_gateway() {
  local service="$1" tries="${GATEWAY_HARD_POLL_TRIES:-15}" poll="${GATEWAY_HARD_POLL_SECS:-2}" i
  _gr_exec "${SYSTEMCTL_BIN:-systemctl} restart $service" || return 1
  for i in $(seq 1 "$tries"); do
    sleep "$poll"
    if _gr_exec "${SYSTEMCTL_BIN:-systemctl} is-active --quiet $service" 2>/dev/null; then
      _gr_log "$service restarted (hard, ${i}x${poll}s)"
      return 0
    fi
  done
  _gr_log "WARN: $service not active after hard restart (${tries}x${poll}s)"
  return 1
}

# drain_restart_gateway <service> <profile> — serial convenience wrapper:
# safe request → await → fall back to hard restart on any failure.
# rc 0 = gateway restarted (either path), nonzero = even the hard path failed.
drain_restart_gateway() {
  local service="$1" profile="$2" old_pid req_rc=0
  old_pid="$(gateway_main_pid "$service")" || old_pid=""
  if [ -z "$old_pid" ] || [ "$old_pid" = "0" ]; then
    # No verified baseline PID → a drain result would be unverifiable (see
    # await_gateway_restart). Skip the pointless request; go straight hard.
    _gr_log "WARN: could not capture MainPID for $service — skipping drain, hard restart"
    _gr_notify ":warning: drain-aware restart: could not capture a pre-request MainPID for $service — hard restart without drain (in-flight turns may be cut)."
    hard_restart_gateway "$service"
    return $?
  fi
  request_safe_restart "$service" "$profile" || req_rc=$?
  case "$req_rc" in
    2) _gr_log "HYDRA_HARD_RESTART=1 — skipping drain for $service" ;;
    1) _gr_log "WARN: falling back to hard restart for $service (safe request failed)"
       _gr_notify ":warning: drain-aware restart: safe-restart request FAILED for $service — hard restart fallback (in-flight turns may be cut). If this repeats, the drain path is broken (scripts/lib/gateway-restart.sh)." ;;
    0) if await_gateway_restart "$service" "$old_pid"; then return 0; fi
       _gr_log "WARN: falling back to hard restart for $service (drain did not complete)"
       _gr_notify ":warning: drain-aware restart: active work didn't drain within ${GATEWAY_DRAIN_DEADLINE_SECS:-390}s for $service — hard restart fallback (in-flight turns may be cut)." ;;
  esac
  hard_restart_gateway "$service"
}
