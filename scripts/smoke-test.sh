#!/usr/bin/env bash
set -euo pipefail

# HYDRA Smoke Test
# ================
# Post-deploy validation for multi-gateway setup.

NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
CLIPROXYAPI_PORT=8317
FAILURES=0
WARNINGS=0
TARGET="${1:-all}"

# Validate target (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|dev|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|dev|all"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail_check() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass_check() { log "PASS: $*"; }
warn_check() { log "WARN: $*"; WARNINGS=$((WARNINGS + 1)); }

# expected_agent_count <profile> — print the count of enabled agents
# in /opt/hydra/openclaw-<profile>.json. Returns "?" on any failure
# (file missing, JSON parse error, etc) — the caller is expected to
# treat "?" as a hard fail rather than coerce to 0, which would
# mask "gateway down + config gone" as a false 0/0 pass.
expected_agent_count() {
  local profile="$1"
  python3 - "$profile" <<'PYEOF' 2>/dev/null || echo "?"
import json, sys
profile = sys.argv[1]
with open(f'/opt/hydra/openclaw-{profile}.json') as f:
    c = json.load(f)
agents = c.get('agents', {}).get('list', [])
print(len([a for a in agents if a.get('enabled', True)]))
PYEOF
}

# check_agent_count <profile> <label> — fetch BOUND count via openclaw
# CLI, compare to expected_agent_count. Hard fail on mismatch OR on
# inability to determine the expected count (a "?" response).
check_agent_count() {
  local profile="$1" label="$2"
  local expected agent_output agent_count
  expected=$(expected_agent_count "$profile")
  agent_output=$(openclaw --profile "$profile" agents list --bindings 2>&1) || true
  agent_count=$(echo "$agent_output" | grep -c '^- ' || true)
  if [[ "$expected" == "?" ]]; then
    fail_check "$label: could not read /opt/hydra/openclaw-${profile}.json — refusing to compare counts (would mask gateway-down as 0/0 pass)"
    return
  fi
  if [[ "$agent_count" -eq "$expected" ]]; then
    pass_check "$label: $agent_count/$expected agents bound"
  else
    fail_check "$label: Expected $expected agents, got $agent_count"
    echo "$agent_output"
  fi
}

# check_channel_health <profile> <label> — extracted from the three
# verbatim copies that previously lived in the main/edge/dev blocks.
check_channel_health() {
  local profile="$1" label="$2"
  local channel_output total healthy unhealthy
  channel_output=$(openclaw --profile "$profile" channels status --probe 2>&1) || true
  total=$(echo "$channel_output" | grep -c '^- ' || true)
  healthy=$(echo "$channel_output" | grep -c '^- .*enabled.*configured' || true)
  unhealthy=$((total - healthy))
  if (( total == 0 )); then
    fail_check "$label: channels status returned no channels — gateway may be down"
  elif (( unhealthy == 0 )); then
    pass_check "$label: All $total channels healthy (enabled + configured)"
  else
    fail_check "$label: $unhealthy/$total unhealthy channels"
    echo "$channel_output" | grep '^- ' | grep -v 'enabled.*configured' | head -5 | sed 's/^/    /'
  fi
}

ping_agent() {
  # ping_agent <profile> <agent_id> <label>
  # Runs a real LLM round-trip via openclaw agent --agent X -m "...".
  # SOFT gate: warns on failure, does not block the deploy. LLM
  # round-trips are flaky (Anthropic overload, warm-up timing) so a
  # hard gate would cause false-positive deploy blocks.
  local profile="$1"
  local agent_id="$2"
  local label="$3"
  local start elapsed response
  start=$(date +%s)
  response=$(timeout 60 openclaw --profile "$profile" agent --agent "$agent_id" -m "respond with the exact word PONG and nothing else" 2>&1) || response="TIMEOUT"
  elapsed=$(( $(date +%s) - start ))
  if echo "$response" | grep -qi 'pong'; then
    pass_check "$label: agent '$agent_id' responded PONG in ${elapsed}s"
  else
    warn_check "$label: agent '$agent_id' did not return PONG within 60s (elapsed=${elapsed}s). Response head: $(echo "$response" | head -c 200)"
  fi
}
needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }

# -------------------------------------------------------------------
# Host-wide checks (not per-profile)
# -------------------------------------------------------------------

# mcp-remote leak guard: On 2026-04-24, orphaned `npm exec mcp-remote`
# subprocesses under the gateway pgid caused a reaper to kill the
# whole gateway. The fix was to switch remote MCP servers to native
# transport: "streamable-http" — which spawns zero subprocesses.
# This check fails the smoke test if ANY mcp-remote process is ever
# found running. A transient mcp-remote during legitimate SSE/stdio
# fallback is not expected; if one appears, a regression has snuck
# in via `openclaw mcp set` or a bundle-mcp behavior change.
log "Checking mcp-remote leak guard (host-wide)..."
MCP_REMOTE_PROCS=$(pgrep -af 'mcp-remote' 2>/dev/null | grep -v 'pgrep\|smoke-test' || true)
if [ -z "$MCP_REMOTE_PROCS" ]; then
  pass_check "no mcp-remote processes running (streamable-http transport holding)"
else
  MCP_REMOTE_COUNT=$(echo "$MCP_REMOTE_PROCS" | wc -l | tr -d ' ')
  fail_check "$MCP_REMOTE_COUNT mcp-remote process(es) running — streamable-http migration regressed. Sample: $(echo "$MCP_REMOTE_PROCS" | head -1 | head -c 200). Run scripts/lint-openclaw-config.sh /root/.openclaw-*/openclaw.json to find the offending entry."
fi

# Retired-unit guard: hydra-mcp-reap.{timer,service} were removed in
# PR #172 because they killed the gateway's own pgid (see above).
# install-aux-units.sh cleans them up on every deploy. If they
# reappear, either install-aux-units.sh regressed or something
# outside the deploy re-installed the units — either way, loud fail.
RESURRECTED_UNITS=$(systemctl list-unit-files 'hydra-mcp-reap.*' --no-pager 2>/dev/null | grep -E '^hydra-mcp-reap\.' || true)
if [ -z "$RESURRECTED_UNITS" ]; then
  pass_check "hydra-mcp-reap units retired (no reanimation)"
else
  fail_check "hydra-mcp-reap unit files present — they were retired in PR #172. Run install-aux-units.sh to clean up, or investigate what re-installed them: $RESURRECTED_UNITS"
fi

# -------------------------------------------------------------------
# Main gateway checks
# -------------------------------------------------------------------
if needs_target "main"; then
  log "Checking main gateway (port 18789)..."

  # Zombie guard: the pre-multi-profile legacy unit
  # /etc/systemd/system/openclaw-gateway.service (no '-main' suffix) binds
  # port 18789 and runs openclaw *without* --profile. On 2026-04-21 it was
  # found to have been `disabled` but still `active` — its openclaw process
  # used service-mode pid-clearing to SIGTERM openclaw-gateway-main.service
  # every ~20s, preventing main from staying up for more than one cycle.
  # It also answered CLI queries with the pre-migration cron storePath,
  # creating a 2-week silent drift between deploys and what the gateway read.
  # The legacy unit file was renamed to *.legacy-disabled-<timestamp> and
  # the service is now masked (→ /dev/null). This gate refuses to ever let
  # it reanimate.
  # is-enabled returns non-zero on absent units (→ stdout "not-found") AND
  # on systemctl failures (→ empty output). We keep the `|| true` so `set -e`
  # callers don't abort, but separate the two outcomes below: absent unit
  # passes, empty output fails (cannot verify).
  LEGACY_STATE=$(systemctl is-active openclaw-gateway.service 2>/dev/null || true)
  LEGACY_ENABLED=$(systemctl is-enabled openclaw-gateway.service 2>/dev/null || true)
  case "$LEGACY_ENABLED" in
    masked|masked-runtime)
      if [ "$LEGACY_STATE" = "active" ] || [ "$LEGACY_STATE" = "activating" ] || [ "$LEGACY_STATE" = "reloading" ]; then
        LEGACY_PID=$(systemctl show --property=MainPID --value openclaw-gateway.service 2>/dev/null || echo "?")
        LEGACY_EXEC=$(systemctl show --property=ExecStart --value openclaw-gateway.service 2>/dev/null | head -c 200 || echo "?")
        fail_check "Legacy openclaw-gateway.service is masked but $LEGACY_STATE (MainPID=$LEGACY_PID, ExecStart=$LEGACY_EXEC) — run: systemctl stop openclaw-gateway.service; then investigate how a masked unit got started (see docs/RUNBOOK.md#legacy-openclaw-gateway-zombie)"
      else
        pass_check "Legacy openclaw-gateway.service is masked (zombie stays dead)"
      fi
      ;;
    not-found)
      pass_check "Legacy openclaw-gateway.service not present (no zombie possible)"
      ;;
    "")
      fail_check "systemctl returned empty output for openclaw-gateway.service is-enabled — cannot verify zombie is masked (dbus down? non-systemd host? permissions?)"
      ;;
    *)
      fail_check "Legacy openclaw-gateway.service is enabled=$LEGACY_ENABLED active=$LEGACY_STATE — must be masked. Run: systemctl stop openclaw-gateway.service && systemctl mask openclaw-gateway.service (see docs/RUNBOOK.md#legacy-openclaw-gateway-zombie for full remediation)"
      ;;
  esac

  # Verify dual-write convergence: deploy.sh mirrors cron-jobs.json to
  # both the profile path (authoritative storePath) and the legacy path
  # (defense-in-depth vs zombie). We compare only the static job
  # definitions — the gateway writes runtime state (lastRunAtMs,
  # nextRunAtMs, consecutiveErrors) back to the profile path
  # continuously, so a byte-level diff would fire on every cron tick.
  # The invariant that matters: job id/name/schedule/prompt/delivery
  # must match, so if the mirror step silently broke, a future zombie
  # reanimation would read a stale job list.
  if [ -f /root/.openclaw-main/cron/jobs.json ] && [ -f /root/.openclaw/cron/jobs.json ]; then
    if diff <(jq -S '.jobs | map(del(.state, .updatedAtMs)) | sort_by(.id)' /root/.openclaw-main/cron/jobs.json 2>/dev/null) \
            <(jq -S '.jobs | map(del(.state, .updatedAtMs)) | sort_by(.id)' /root/.openclaw/cron/jobs.json 2>/dev/null) \
            >/dev/null 2>&1; then
      pass_check "cron-jobs.json job definitions in sync across profile and legacy paths (dual-write converged)"
    else
      fail_check "cron-jobs.json job definitions diverged between /root/.openclaw-main/cron/jobs.json and /root/.openclaw/cron/jobs.json — deploy's dual-write step likely broke"
    fi
  fi

  # Expected count is derived from openclaw-main.json by check_agent_count.
  # The helper hard-fails on inability to read the config (rather than
  # coercing to 0) so a deploy that wipes the config can never produce
  # a green 0/0 false-pass paired with a downed gateway.
  check_agent_count main "Main"

  # Structural check: verify sessions tool is enabled with full visibility.
  # sessions_send is a METHOD of the global .tools.sessions tool, not a
  # named tool. If .tools.sessions.visibility is not "all", cross-agent
  # messaging is structurally broken — regardless of whether any
  # individual LLM call succeeds. This is the hard gate.
  #
  # Validated during spec review 2026-04-08:
  #   jq -e '.tools.sessions.visibility == "all"' openclaw-main.json
  # returns true for the repo and live server configs, and correctly
  # returns false when .tools.sessions is removed or visibility changed.
  if jq -e '.tools.sessions.visibility == "all"' /opt/hydra/openclaw-main.json >/dev/null 2>&1; then
    pass_check "Main: sessions tool enabled with full visibility (cross-agent messaging wired correctly)"
  else
    fail_check "Main: .tools.sessions.visibility is not 'all' in openclaw-main.json — cross-agent messaging structurally broken"
  fi

  # Behavioral mesh test — SOFT gate. A real LLM round-trip through
  # Clio's tool-use loop, which is inherently flaky (Anthropic overload,
  # LLM non-determinism in response wording, warm-up timing). The hard
  # gate on .tools.sessions.visibility above catches the "wiring broken"
  # case; this check just tries to confirm it actually works end-to-end.
  #
  # Timeout bumped from 30s to 60s because a Clio→CTO LLM round-trip
  # via sessions_send can genuinely take 30-50s (Clio thinks, picks the
  # tool, CTO thinks, Clio synthesizes the reply).
  log "  Testing cross-agent mesh behaviorally (Clio -> CTO via LLM)..."
  MESH_RESPONSE=$(timeout 60 openclaw --profile main agent send clio "ping cto via sessions_send and report back" 2>&1) || MESH_RESPONSE="TIMEOUT"
  if echo "$MESH_RESPONSE" | grep -qi 'cto\|responded\|pong\|acknowledged'; then
    pass_check "Main: Cross-agent mesh behavioral test passed (Clio -> CTO round-trip)"
  else
    warn_check "Main: Cross-agent mesh behavioral test did not confirm within 60s. Response was: $(echo "$MESH_RESPONSE" | head -c 200)"
  fi

  # Targeted pings for critical main-profile agents (user-specified).
  # Soft gate: these exercise a real LLM round-trip per agent and will
  # warn on flake rather than block the deploy. Each adds 5-60s to the
  # smoke test depending on LLM latency.
  ping_agent main clio       "Main"
  ping_agent main cmo        "Main"
  ping_agent main operations "Main"

  check_channel_health main "Main"

  # Cron loading gate — guards against the silent path-drift outage class
  # that took down all the cron jobs for 19 hours on 2026-04-07. The
  # repo file at /opt/hydra/cron-jobs.json is the source of truth; the
  # gateway must report the same job count via `cron status --json`. If
  # the deploy script ever writes to a path the gateway doesn't read
  # again, this check fails the deploy instead of silently shipping
  # zero crons.
  #
  # Both sides explicitly resolved to a SCALAR COUNT to avoid the
  # "compare integer to JSON array" footgun. The repo file's `.jobs`
  # is an array (so we use `.jobs | length`). The CLI's `.jobs` happens
  # to be a number today (verified live: openclaw cron status --json
  # returns {"jobs": 12, ...}), but to be future-proof against the CLI
  # ever switching shape, we handle both with `if type == array then
  # length else . end`.
  if [ ! -f /opt/hydra/cron-jobs.json ]; then
    fail_check "Main: /opt/hydra/cron-jobs.json missing — repo file did not deploy"
  else
    EXPECTED_CRONS=$(jq '.jobs | length' /opt/hydra/cron-jobs.json 2>/dev/null || echo "?")
    LOADED_RAW=$(openclaw --profile main cron status --json 2>&1) || LOADED_RAW=""
    if [ -z "$LOADED_RAW" ]; then
      fail_check "Main: openclaw cron status --json returned nothing (gateway not running?)"
    else
      LOADED_CRONS=$(echo "$LOADED_RAW" | jq 'if (.jobs | type) == "array" then (.jobs | length) else .jobs end' 2>/dev/null || echo "?")
      if [[ "$EXPECTED_CRONS" == "?" || "$LOADED_CRONS" == "?" ]]; then
        fail_check "Main: cron count check failed (expected=$EXPECTED_CRONS loaded=$LOADED_CRONS) — could not parse JSON. Raw output: $LOADED_RAW"
      elif [[ "$LOADED_CRONS" == "$EXPECTED_CRONS" ]]; then
        pass_check "Main: cron scheduler loaded $LOADED_CRONS jobs (matches repo)"
      else
        fail_check "Main: cron count mismatch — repo has $EXPECTED_CRONS, gateway loaded $LOADED_CRONS (was the cron file written to the wrong path?)"
      fi
    fi
  fi

  # -------------------------------------------------------------------
  # Watchdog self-test — verifies the crash-loop detector regex still
  # matches real systemd output and the alert path is wired correctly.
  # Closes the loop on the 2026-04-07 incident: a typo in the watchdog
  # regex went undetected for months because nothing exercised it. This
  # gate fires the typo at deploy time so it cannot rot silently again.
  # -------------------------------------------------------------------
  if [ -x /opt/hydra/scripts/openclaw-watchdog.sh ]; then
    if /opt/hydra/scripts/openclaw-watchdog.sh --self-test >/dev/null 2>&1; then
      pass_check "Main: watchdog self-test passed"
    else
      /opt/hydra/scripts/openclaw-watchdog.sh --self-test 2>&1 | sed 's/^/    /'
      fail_check "Main: watchdog self-test FAILED — crash-loop detection is broken"
    fi
  else
    fail_check "Main: /opt/hydra/scripts/openclaw-watchdog.sh missing or not executable"
  fi

  # Config-mirror staleness check — /opt/hydra/config/ is a dead
  # shadow mirror that was removed on 2026-04-08 during the CD
  # consolidation. If it still exists on the server, someone forgot
  # the manual `rm -rf /opt/hydra/config/` cleanup step after this
  # PR merged. Fire a warning on every deploy until the cleanup is
  # done. Soft-fail — doesn't block.
  if [[ -d /opt/hydra/config ]]; then
    config_size=$(du -sh /opt/hydra/config 2>/dev/null | cut -f1 || echo "?")
    warn_check "Main: /opt/hydra/config/ still exists ($config_size) — dead CD shadow mirror from pre-2026-04-08 architecture. Please run: rm -rf /opt/hydra/config/"
  else
    pass_check "Main: /opt/hydra/config/ cleanup complete (dead shadow mirror removed)"
  fi
fi

# -------------------------------------------------------------------
# Edge gateway checks
# -------------------------------------------------------------------
if needs_target "edge"; then
  log "Checking edge gateway (port 18810)..."
  check_agent_count edge "Edge"
  check_channel_health edge "Edge"
  # Targeted ping for the customer-facing support agent.
  ping_agent edge support "Edge"
fi

# -------------------------------------------------------------------
# Dev gateway checks
# -------------------------------------------------------------------
if needs_target "dev"; then
  log "Checking dev gateway (port 18830)..."
  check_agent_count dev "Dev"
  check_channel_health dev "Dev"
fi

# -------------------------------------------------------------------
# CLIProxyAPI health check (optional — only if Anthropic fallback is active)
# -------------------------------------------------------------------
log "Checking CLIProxyAPI /health..."
HEALTH_RESPONSE=$(curl -sf "http://127.0.0.1:${CLIPROXYAPI_PORT:-8317}/health" 2>&1) || HEALTH_RESPONSE="UNREACHABLE"
if echo "$HEALTH_RESPONSE" | grep -qi 'ok\|healthy'; then
  pass_check "CLIProxyAPI /health returned OK"
else
  # Non-fatal: CLIProxyAPI is only needed for the Anthropic fallback path.
  # Use warn_check (not bare log) so this fires the WARNINGS counter
  # and shows up in the summary line. Otherwise the summary lies
  # ("0 warnings") whenever CLIProxyAPI is unreachable.
  warn_check "CLIProxyAPI not reachable (non-fatal — primaries are gpt-5.5 / opus-4-7, not Anthropic-direct)"
fi

# -------------------------------------------------------------------
# Results
# -------------------------------------------------------------------
echo ""
log "========================================="
if [[ "$FAILURES" -eq 0 ]]; then
  if (( WARNINGS > 0 )); then
    log "SMOKE TEST PASSED (target: $TARGET, 0 failed, $WARNINGS warning(s))"
  else
    log "SMOKE TEST PASSED (target: $TARGET, all checks green)"
  fi
  exit 0
else
  log "SMOKE TEST FAILED (target: $TARGET, $FAILURES check(s) failed, $WARNINGS warning(s))"
  exit 1
fi
