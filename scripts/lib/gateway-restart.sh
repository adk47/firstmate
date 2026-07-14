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
#   OPENCLAW_BIN / SYSTEMCTL_BIN          binaries (default openclaw/systemctl)
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
