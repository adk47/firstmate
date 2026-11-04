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

# ── wiring: smoke-test.sh must call the gate before each profile's first LLM probe ──
# A refactor that drops or reorders these calls leaves the lib tests green while the
# 4 Nov rollback loop returns, so pin the call sites in smoke-test.sh itself.

line_of() { grep -n -m1 -F -- "$1" "$BATS_TEST_DIRNAME/../smoke-test.sh" | cut -d: -f1; }

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

@test "wiring: check_web_search fail) arm uses websearch_scoped_fail_message, not the old text" {
  grep -q 'fail_check "\$label: \$(websearch_scoped_fail_message ' "$BATS_TEST_DIRNAME/../smoke-test.sh"
  ! grep -q 'NO tool policy explains it' "$BATS_TEST_DIRNAME/../smoke-test.sh"
}
