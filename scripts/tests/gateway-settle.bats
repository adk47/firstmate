#!/usr/bin/env bats
# Tests for scripts/lib/gateway-settle.sh (MUS-28729). systemctl, ps, journalctl,
# curl and sleep are PATH stubs; no live gateway is touched.
#   (i)   fast /health from t=0 but no timing-gap line and uptime < min -> NOT settled
#         until the gap line appears
#   (ii)  gap line present, reads 000,000,200,200,200 -> settles after the 3rd fast read
#   (iii) budget exhausted -> warn line, return 0
#   (iv)  uptime >= min with no gap line -> settles on fast reads

setup() {
  T="$(mktemp -d)"; mkdir -p "$T/bin"; export T
  LIB="$BATS_TEST_DIRNAME/../lib/gateway-settle.sh"
  cat > "$T/bin/systemctl" <<'S'
#!/bin/sh
cat "$T/pid" 2>/dev/null || echo 4242
S
  cat > "$T/bin/ps" <<'S'
#!/bin/sh
echo "${STUB_UPTIME:-100}"
S
  cat > "$T/bin/sleep" <<'S'
#!/bin/sh
# STUB_RESTART_AT_SLEEP=n: the gateway restarts (new MainPID) during sleep n
n=$(cat "$T/sn" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$T/sn"
if [ -n "${STUB_RESTART_AT_SLEEP:-}" ] && [ "$n" -eq "$STUB_RESTART_AT_SLEEP" ]; then echo 5555 > "$T/pid"; fi
exit 0
S
  # journalctl: prints the gap line from call number $STUB_GAP_AT onward (0 = never)
  cat > "$T/bin/journalctl" <<'S'
#!/bin/sh
n=$(cat "$T/jn" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$T/jn"
# STUB_GAP_PID: only that PID ever logged the gap line
if [ -n "${STUB_GAP_PID:-}" ] && [ "$1" != "_PID=$STUB_GAP_PID" ]; then exit 0; fi
if [ "${STUB_GAP_AT:-0}" -gt 0 ] && [ "$n" -ge "$STUB_GAP_AT" ]; then
  echo "[health] host timing gap detected: process was frozen ~300000ms"
fi
exit 0
S
  # curl: next line of $T/reads ("000 0.0" / "200 0.4"); last line repeats
  cat > "$T/bin/curl" <<'S'
#!/bin/sh
n=$(cat "$T/cn" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$T/cn"
l=$(sed -n "${n}p" "$T/reads"); [ -n "$l" ] || l=$(tail -n 1 "$T/reads")
# STUB_RESTART_AT_CURL=n: the gateway restarts (new MainPID) during read n
if [ -n "${STUB_RESTART_AT_CURL:-}" ] && [ "$n" -eq "$STUB_RESTART_AT_CURL" ]; then echo 5555 > "$T/pid"; fi
printf '%s' "$l"
S
  chmod +x "$T"/bin/*
  export PATH="$T/bin:$PATH"
  log() { echo "LOG $*"; }
  warn_check() { echo "WARN $*"; }
  # shellcheck disable=SC1090
  source "$LIB"
}
teardown() { rm -rf "$T"; }

@test "(i) fast health but no gap line and short uptime: not settled until the gap line appears" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=4 STUB_UPTIME=100
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"gateway settled"*"arm a: gap"* ]]
  # journalctl was polled 4 times: three misses (no curl allowed yet), then the gap
  [ "$(cat "$T/jn")" -eq 4 ]
  [ "$(cat "$T/cn")" -eq 3 ]
}

@test "(i) fast health alone never settles while the gap line never appears" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=0 STUB_UPTIME=100 SMOKE_SETTLE_BUDGET_S=50
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN main: gateway did not settle within 50s (condition a"* ]]
  [ ! -e "$T/cn" ]
}

@test "(ii) gap present; 000,000,200,200,200 settles after the third fast read" {
  printf '000 0.0\n000 0.0\n200 0.3\n200 0.3\n200 0.3\n' > "$T/reads"
  export STUB_GAP_AT=1 STUB_UPTIME=100
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"gateway settled after 40s"* ]]
  [ "$(cat "$T/cn")" -eq 5 ]
}

@test "(ii) a slow or failed read resets the consecutive count" {
  printf '200 0.3\n200 0.3\n200 2.5\n200 0.3\n200 0.3\n200 0.3\n' > "$T/reads"
  export STUB_GAP_AT=1
  run wait_gateway_settled main 18789
  [[ "$output" == *"gateway settled after 50s"* ]]
  [ "$(cat "$T/cn")" -eq 6 ]
}

@test "(iii) budget runs out: warn line, return 0" {
  echo "000 0.0" > "$T/reads"
  export STUB_GAP_AT=1 SMOKE_SETTLE_BUDGET_S=30
  run wait_gateway_settled edge 18810
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN edge: gateway did not settle within 30s (condition b: 0/3"* ]]
  [[ "$output" == *"probing anyway"* ]]
}

@test "(iv) uptime >= min with no gap line settles on fast reads" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=0 STUB_UPTIME=1000
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"arm a: uptime"* ]]
}

@test "unreadable MainPID is not settled (budget warn, never a failure)" {
  printf '#!/bin/sh\necho 0\n' > "$T/bin/systemctl"
  echo "200 0.2" > "$T/reads"
  export SMOKE_SETTLE_BUDGET_S=20
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN main: gateway did not settle"* ]]
}

@test "a restart between reads resets the arm and the fast count (new PID has no gap yet)" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=1 STUB_GAP_PID=4242 STUB_RESTART_AT_CURL=2 SMOKE_SETTLE_BUDGET_S=50
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" != *"gateway settled"* ]]
  [[ "$output" == *"WARN main: gateway did not settle within 50s (condition a"* ]]
}

@test "a restart between reads: the new PID settles only after its own gap line" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=1 STUB_RESTART_AT_CURL=2
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"gateway settled"*"arm a: gap"* ]]
  # 2 reads on the old PID (the 2nd discarded), then 3 fresh ones on the new PID
  [ "$(cat "$T/cn")" -eq 5 ]
}

@test "a restart during the FINAL fast read does not settle (pins the post-read PID reset)" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=1 STUB_GAP_PID=4242 STUB_RESTART_AT_CURL=3 SMOKE_SETTLE_BUDGET_S=50
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" != *"gateway settled"* ]]
  [[ "$output" == *"WARN main: gateway did not settle within 50s (condition a"* ]]
  # reads 1-3 on the old PID; the new PID never logs a gap, so no read follows
  [ "$(cat "$T/cn")" -eq 3 ]
}

@test "a restart during sleep: no read is counted on the new PID before its own gap line (pins the top-of-loop PID reset)" {
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=1 STUB_GAP_PID=4242 STUB_RESTART_AT_SLEEP=1 SMOKE_SETTLE_BUDGET_S=50
  run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" != *"gateway settled"* ]]
  [[ "$output" == *"WARN main: gateway did not settle within 50s (condition a"* ]]
  # one read on the old PID, then none: the new PID has no arm
  [ "$(cat "$T/cn")" -eq 1 ]
}

# ── wiring: smoke-test.sh must call the gate before each profile's first LLM probe ──
# A refactor that drops or reorders these calls leaves the lib tests green while the
# 4 Nov rollback loop returns, so pin the call sites in smoke-test.sh itself.

line_of() { grep -n -m1 -F -- "$1" "$BATS_TEST_DIRNAME/../smoke-test.sh" | cut -d: -f1; }

# Bot NO-GO 5 Nov (hydra#1746 @090dd6bcf): SMOKE_SETTLE_INTERVAL_S=0 made `elapsed` never
# advance, so the budget was never reached and the deploy smoke hung. A runaway loop is
# cut off by the sleep stub (500 sleeps) so a regression fails instead of hanging bats.
_runaway_guard() {
  cat > "$T/bin/sleep" <<'S'
#!/bin/sh
n=$(cat "$T/sn" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$T/sn"
if [ "$n" -gt 500 ]; then echo RUNAWAY >&2; kill -TERM "$PPID"; fi
exit 0
S
  chmod +x "$T/bin/sleep"
}

@test "a non-positive or non-numeric poll interval falls back to 10s and the budget still ends the gate" {
  _runaway_guard
  echo "200 0.2" > "$T/reads"
  export STUB_GAP_AT=0 STUB_UPTIME=100 SMOKE_SETTLE_BUDGET_S=50
  local bad
  for bad in 0 -5 abc "" 1.5; do
    rm -f "$T/sn"
    SMOKE_SETTLE_INTERVAL_S="$bad" run wait_gateway_settled main 18789
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN main: gateway did not settle within 50s"* ]]
    [ "$(cat "$T/sn")" -eq 5 ]   # 50s budget / 10s default interval
  done
}

@test "non-numeric budget, fast-read count or min uptime fall back to their defaults" {
  _runaway_guard
  printf '200 0.3\n' > "$T/reads"
  export STUB_GAP_AT=1 STUB_UPTIME=100
  SMOKE_SETTLE_FAST_READS=abc SMOKE_SETTLE_BUDGET_S=zzz SMOKE_SETTLE_MIN_UPTIME_S=x run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"gateway settled after 20s"*"3 consecutive fast"* ]]
}

@test "non-numeric min uptime falls back to 900 and does not settle early on uptime alone (pins the min= fallback)" {
  _runaway_guard
  printf '200 0.3\n' > "$T/reads"   # health is fast from t=0: only arm (a) can hold the gate
  export STUB_GAP_AT=0 STUB_UPTIME=100 SMOKE_SETTLE_BUDGET_S=50
  SMOKE_SETTLE_MIN_UPTIME_S=x run wait_gateway_settled main 18789
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not settle within 50s"* ]]
}

@test "wiring: smoke-test.sh settles main before the mesh gate and check_web_search main" {
  local g m w
  g="$(line_of 'wait_gateway_settled main 18789')"
  m="$(line_of 'recovery_gate main agent:clio:main')"
  w="$(line_of 'check_web_search main "Main"')"
  [ -n "$g" ] && [ -n "$m" ] && [ -n "$w" ]
  [ "$g" -lt "$m" ]
  [ "$g" -lt "$w" ]
}

@test "wiring: smoke-test.sh settles edge before ping_agent edge" {
  local g p
  g="$(line_of 'wait_gateway_settled edge 18810')"
  p="$(line_of 'ping_agent edge support')"
  [ -n "$g" ] && [ -n "$p" ]
  [ "$g" -lt "$p" ]
}
