#!/usr/bin/env bash
# gateway-settle.sh — settle gate for smoke-test.sh's LLM probes (Step 7).
# Sourced (not executed) so bats can unit-test it with stubbed
# systemctl / journalctl / ps / curl / sleep.
#
# WHY (MUS-28729, 4 Nov 2026): every gateway start is followed 65-100 s later by
# a 292-680 s main-thread freeze ("host timing gap detected"). The mesh and
# web_search probes ran inside or just after that freeze, so the deny-free
# reference probe came back `inconclusive`, websearch_scoped_verdict (correctly)
# failed closed, and Deploy HYDRA rolled back — twice, 4 extra gateway restarts.
# A bare "/health answers" check passes BEFORE the freeze starts, so it cannot be
# the gate: we wait for the unit's current MainPID to have logged its freeze
# (or to be old enough that it will not freeze any more), then for consecutive
# fast health reads.
#
# The gate NEVER fails or skips a deploy: on timeout it warns and the probes
# still judge. It adds no retries to the probes themselves.
#
# Env (all optional):
#   SMOKE_SETTLE_MIN_UPTIME_S  900   MainPID uptime that counts as settled without a gap line
#   SMOKE_SETTLE_FAST_READS    3     consecutive fast /health reads required
#   SMOKE_SETTLE_BUDGET_S      1200  overall budget; elapsed = time slept between polls
#   SMOKE_SETTLE_INTERVAL_S    10    poll interval (>= 1)
# Each must be a whole number (FAST_READS and INTERVAL >= 1); anything else falls back to the default.

# _settle_num <value> <default> <min> -> prints value when it is an integer >= min,
# else the default. A bad override (0 interval, "abc", "1.5", negative) must never
# stall the loop: interval 0 would keep `elapsed` at 0 and the budget unreachable.
_settle_num() {
  if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge "$3" ]]; then echo "$1"; else echo "$2"; fi
}

# _settle_pid <unit> -> prints the unit's current MainPID ("" when unreadable).
_settle_pid() {
  local pid
  pid="$(systemctl show --property=MainPID --value "$1" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid"
  return 0
}

# _settle_arm_a <pid> -> prints "gap" | "uptime" and returns 0 when arm (a)
# holds for that process; returns 1 otherwise (including when it cannot be read).
_settle_arm_a() {
  local pid="$1" up start min n
  min="$(_settle_num "${SMOKE_SETTLE_MIN_UPTIME_S:-}" 900 0)"
  [[ -n "$pid" ]] || return 1
  up="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  [[ "$up" =~ ^[0-9]+$ ]] || return 1
  start=$(( $(date +%s) - up ))
  n="$(journalctl "_PID=$pid" --since "@$start" --no-pager 2>/dev/null | grep -c 'host timing gap detected' || true)"
  if [[ "${n:-0}" -gt 0 ]]; then echo gap; return 0; fi
  if [[ "$up" -ge "$min" ]]; then echo uptime; return 0; fi
  return 1
}

# _settle_fast_read <port> -> 0 when /health answers 200 in < 2 s.
_settle_fast_read() {
  local out code t
  out="$(curl -sS -m 3 -o /dev/null -w '%{http_code} %{time_total}' "http://127.0.0.1:$1/health" 2>/dev/null || true)"
  code="${out%% *}"; t="${out#* }"
  [[ "$code" == "200" ]] && awk -v t="$t" 'BEGIN { exit !(t + 0 < 2) }'
}

# wait_gateway_settled <profile> <port>
# Always returns 0. Needs log()/warn_check() from the caller (smoke-test.sh).
wait_gateway_settled() {
  local profile="$1" port="$2" unit="openclaw-gateway-$1.service"
  local need budget interval minup elapsed=0 fast=0 arm="" a pid="" cur
  need="$(_settle_num "${SMOKE_SETTLE_FAST_READS:-}" 3 1)"
  budget="$(_settle_num "${SMOKE_SETTLE_BUDGET_S:-}" 1200 0)"
  interval="$(_settle_num "${SMOKE_SETTLE_INTERVAL_S:-}" 10 1)"
  minup="$(_settle_num "${SMOKE_SETTLE_MIN_UPTIME_S:-}" 900 0)"

  while :; do
    # A restart mid-gate gives a fresh process with its own post-start freeze
    # ahead: the arm and the fast-read count belong to one PID only.
    cur="$(_settle_pid "$unit")"
    if [[ "$cur" != "$pid" ]]; then pid="$cur"; arm=""; fast=0; fi
    if [[ -z "$arm" ]]; then
      if a="$(_settle_arm_a "$pid")"; then arm="$a"; fi
    fi
    if [[ -n "$arm" ]]; then
      if _settle_fast_read "$port"; then fast=$((fast + 1)); else fast=0; fi
      # restart during the read: that read does not count for the new process
      cur="$(_settle_pid "$unit")"
      if [[ "$cur" != "$pid" ]]; then pid="$cur"; arm=""; fast=0; fi
      if [[ "$fast" -ge "$need" ]]; then
        log "  $profile: gateway settled after ${elapsed}s (arm a: $arm; $need consecutive fast /health reads)"
        return 0
      fi
    fi
    if [[ "$elapsed" -ge "$budget" ]]; then
      if [[ -z "$arm" ]]; then
        warn_check "$profile: gateway did not settle within ${budget}s (condition a: no post-start timing-gap line yet and uptime < ${minup}s) — probing anyway"
      else
        warn_check "$profile: gateway did not settle within ${budget}s (condition b: ${fast}/${need} consecutive fast /health reads, arm a: $arm) — probing anyway"
      fi
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}
