#!/usr/bin/env bash
set -euo pipefail

# HYDRA Smoke Test
# ================
# Post-deploy validation for multi-gateway setup.

NAMESPACE="${NAMESPACE:-hydra}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
FAILURES=0
WARNINGS=0
TARGET="${1:-all}"

# Validate target (supports comma-separated: main,edge)
IFS=',' read -ra TARGET_PARTS <<< "$TARGET"
for t in "${TARGET_PARTS[@]}"; do
  case "$t" in
    main|edge|all) ;;
    *) echo "Error: invalid target '$t'. Must be main|edge|all"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail_check() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass_check() { log "PASS: $*"; }
warn_check() { log "WARN: $*"; WARNINGS=$((WARNINGS + 1)); }

# websearch_probe_attempt + its helpers (real-call evidence via the scout
# rollout, not model text) are pure/injectable and live in a separate lib so
# bats can unit-test them without a live gateway — see check_web_search
# below and scripts/lib/websearch-probe.sh for the full rationale.
_SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/websearch-probe.sh
source "$_SMOKE_DIR/lib/websearch-probe.sh"

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
  # 2>/dev/null (NOT 2>&1): same reason as check_channel_health and the
  # cron count check — openclaw 2026.4.27 emits `Config warnings:\n
  # - plugins.entries.<plugin>: ...` on stderr and `2>&1` would let those
  # warning bullets match `^- ` and inflate the agent count by 4
  # (manifested as "FAIL: Main: Expected 10 agents, got 14" / "FAIL:
  # Edge: Expected 1 agents, got 3" in PR #227's 2026-04-30 10:19 UTC
  # post-merge deploy).
  agent_output=$(openclaw --profile "$profile" agents list --bindings 2>/dev/null) || true
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
  # 2>/dev/null (NOT 2>&1): openclaw 2026.4.27 prints
  # `Config warnings:\n- plugins.entries.<plugin>: ...` to stderr at every
  # CLI invocation. Mixing those into stdout via 2>&1 falsely counted each
  # warning bullet as an unhealthy channel (manifested as
  # "FAIL: Main: 4/20 unhealthy channels" in PR #228's 2026-04-30 09:11
  # UTC deploy run even though all channels were fine). The same warnings
  # also render to stdout as a `@clack/prompts`-style box, but those lines
  # carry a `│  -` prefix (not column-0 `- `) so the existing `^- ` regex
  # correctly skips them.
  channel_output=$(openclaw --profile "$profile" channels status --probe 2>/dev/null) || true
  total=$(echo "$channel_output" | grep -c '^- ' || true)
  healthy=$(echo "$channel_output" | grep -c '^- .*enabled.*configured' || true)
  unhealthy=$((total - healthy))
  # Detect the openclaw 2026.4.27 CLI quirk where `channels status --probe`
  # falls back to "config-only" mode when its hardcoded probe target port
  # (e.g. 127.0.0.1:19001 for dev) doesn't match the gateway's actual
  # listen port from the profile config (dev currently listens on 18830).
  # The gateway IS up and serving real traffic — the CLI just can't reach
  # itself for the probe. Treat this as a warn, not a hard fail; otherwise
  # every deploy stays red on a pre-existing CLI/config mismatch unrelated
  # to whether the deploy succeeded. PR #227 / 2026-04-30 10:19 UTC.
  if echo "$channel_output" | grep -q "Gateway not reachable\|showing config-only status"; then
    warn_check "$label: channels probe couldn't reach gateway (CLI port mismatch in 4.27); gateway is_active was already verified upstream"
    return
  fi
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

# check_web_search <profile> <label> — post-restart probe that a REAL
# web_search tool call round-trips, added after the #695/#701 incident: PR
# #695 set tools.web.search.provider:"codex" on main, which on openclaw 7.1
# is mutually exclusive with native codex search (setting a provider
# DISABLES native) — the managed codex worker then couldn't authenticate and
# every web_search call spun `Reconnecting... N/5` before failing. This broke
# web_search FLEET-WIDE and was SILENT for ~15min because only internal
# agents use it and nothing probed it after the restart. #701 reverted the
# config and added a CI config gate (validate-config-matrix check 7) to
# reject the provider+native combination pre-merge; this check is the
# RUNTIME safety net for a bad config that still slips through, or a
# provider-side outage CI can't see.
#
# Guard: only runs for a profile with .tools.web.search.enabled == true in
# /opt/hydra/openclaw-<profile>.json (main today; edge does not have
# web_search enabled and is skipped cleanly — pass/skip, not fail, same
# idiom as expected_agent_count's python/jq probe above).
#
# The actual probe + verdict logic (websearch_probe_attempt) lives in
# scripts/lib/websearch-probe.sh — PR #704 QA review found two bugs in an
# earlier version of this check that lived inline here: (1) a naive
# `response=$(...) || response="TIMEOUT"` clobbered the real output on ANY
# nonzero exit, so a Reconnecting break that also made the agent process
# exit non-zero never matched the break regex and wrongly degraded to a
# warn; (2) a PASS was granted on model text alone ("SEARCH_STATUS: ok"),
# which the model can produce from training data without ever calling
# web_search (verified live: `openclaw agent --json` carries no tool-call
# transcript, and the gateway journal logs failures only, never successes —
# the one authoritative signal is a `web_search_end` event in the scout
# agent's codex-home rollout). Both are fixed in the lib: the break regex is
# checked against the captured response text regardless of exit code, and a
# PASS requires the scout rollout to have gained a web_search_end event
# during the attempt.
#
# Verdict is deliberately asymmetric: fail loud on a REAL break, but never
# flake the deploy on ordinary LLM non-determinism (the agent choosing not
# to call the tool, or a slow round-trip). A BROKEN signature in the
# transcript is unambiguous and always a hard fail; confirmed rollout
# evidence is a pass; anything else (timeout, tool not invoked, no rollout
# evidence, garbled output) gets ONE retry and only then degrades to a
# warn — never a fail — because an inconclusive probe is not evidence
# web_search is actually down.
check_web_search() {
  local profile="$1" label="$2"
  local enabled
  enabled=$(python3 - "$profile" <<'PYEOF' 2>/dev/null || echo "false"
import json, sys
profile = sys.argv[1]
with open(f'/opt/hydra/openclaw-{profile}.json') as f:
    c = json.load(f)
print('true' if c.get('tools', {}).get('web', {}).get('search', {}).get('enabled') is True else 'false')
PYEOF
  )
  if [[ "$enabled" != "true" ]]; then
    pass_check "$label: web_search not enabled for this profile — skipping probe"
    return
  fi

  local prompt="Use web_search to find the official homepage URL of MusicBrainz. You MUST call the web_search tool. Reply with exactly: SEARCH_STATUS: <ok|error and the error text>"
  local attempt result verdict detail
  for attempt in 1 2; do
    result="$(websearch_probe_attempt "$profile" "$prompt")"
    verdict="$(echo "$result" | sed -n 's/^VERDICT=//p')"
    detail="$(echo "$result" | sed -n 's/^DETAIL=//p')"
    case "$verdict" in
      fail)
        fail_check "$label: web_search BROKEN (${detail}) — managed-provider misconfig or codex hosted-search failure (cf. #695/#701)"
        return
        ;;
      pass)
        pass_check "$label: web_search ok (${detail})"
        return
        ;;
    esac
    if [[ "$attempt" -eq 1 ]]; then
      log "  $label: web_search probe inconclusive on attempt 1 (${detail}), retrying once..."
    fi
  done
  warn_check "$label: web_search probe inconclusive (${detail}) — not treating as a break"
}

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
        fail_check "Legacy openclaw-gateway.service is masked but $LEGACY_STATE (MainPID=$LEGACY_PID, ExecStart=$LEGACY_EXEC) — run: systemctl stop openclaw-gateway.service; then investigate how a masked unit got started (see docs/runbooks/RUNBOOK.md#legacy-openclaw-gateway-zombie)"
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
      fail_check "Legacy openclaw-gateway.service is enabled=$LEGACY_ENABLED active=$LEGACY_STATE — must be masked. Run: systemctl stop openclaw-gateway.service && systemctl mask openclaw-gateway.service (see docs/runbooks/RUNBOOK.md#legacy-openclaw-gateway-zombie for full remediation)"
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
  #
  # Bounded retry (up to 3 attempts, same idiom as check_web_search's
  # attempt loop above) to cut false warn_check noise from LLM latency —
  # any single attempt matching the grep pattern is a pass; only if all
  # 3 attempts fail to match do we degrade to a warn.
  log "  Testing cross-agent mesh behaviorally (Clio -> CTO via LLM)..."
  for attempt in 1 2 3; do
    MESH_RESPONSE=$(timeout 60 openclaw --profile main agent send clio "ping cto via sessions_send and report back" 2>&1) || MESH_RESPONSE="TIMEOUT"
    if echo "$MESH_RESPONSE" | grep -qi 'cto\|responded\|pong\|acknowledged'; then
      pass_check "Main: Cross-agent mesh behavioral test passed (Clio -> CTO round-trip)"
      break
    fi
    if [[ "$attempt" -lt 3 ]]; then
      log "  Main: Cross-agent mesh behavioral test inconclusive on attempt $attempt, retrying..."
    else
      warn_check "Main: Cross-agent mesh behavioral test did not confirm within 60s after 3 attempts. Response was: $(echo "$MESH_RESPONSE" | head -c 200)"
    fi
  done

  # Targeted pings for critical main-profile agents (user-specified).
  # Soft gate: these exercise a real LLM round-trip per agent and will
  # warn on flake rather than block the deploy. Each adds 5-60s to the
  # smoke test depending on LLM latency.
  ping_agent main clio       "Main"
  ping_agent main cmo        "Main"
  ping_agent main operations "Main"

  check_channel_health main "Main"

  # web_search post-restart probe — see check_web_search's comment above
  # for the #695/#701 incident this guards against.
  check_web_search main "Main"

  # Cron loading gate — guards against the silent path-drift outage class
  # that took down all the cron jobs for 19 hours on 2026-04-07. The
  # repo file at /opt/hydra/cron-jobs.json is the source of truth; the
  # gateway must report the same job count via `cron status --json`. If
  # the deploy script ever writes to a path the gateway doesn't read
  # again, this check fails the deploy instead of silently shipping
  # zero crons.
  #
  # LOADED uses `cron list --all --json` (per-job detail, `--all` INCLUDES
  # disabled) and counts only PERSISTENT crons — it EXCLUDES ephemeral
  # one-shot jobs (schedule.kind=="at" && deleteAfterRun). Agent-dispatched
  # reviews (e.g. qa-autoreview-pr-*) create those; they linger DISABLED in
  # the in-memory store after running (deleteAfterRun GC is lazy) and are NOT
  # part of the repo definition, so counting them false-failed EVERY deploy
  # that overlapped a recent dispatch (2026-06-30: repo=26 vs loaded=28 from
  # two stale qa-autoreview one-shots — this whole check's reason for being).
  # We still count disabled PERSISTENT crons (via --all), matching the full
  # repo set (enabled + disabled) that deploy.sh imports — do NOT narrow this
  # to enabled-only. `.total` is the scalar all-rows count (== the previous
  # `cron status --json .jobs`); if the store ever paginates (hasMore) we fall
  # back to it so we never UNDER-count and mask a genuinely-missing repo cron.
  if [ ! -f /opt/hydra/cron-jobs.json ]; then
    fail_check "Main: /opt/hydra/cron-jobs.json missing — repo file did not deploy"
  else
    EXPECTED_CRONS=$(jq '.jobs | length' /opt/hydra/cron-jobs.json 2>/dev/null || echo "?")
    # 2>/dev/null (NOT 2>&1): same reason as check_channel_health above —
    # openclaw 2026.4.27 emits `Config warnings:\n- plugins.entries.*` on
    # stderr at every CLI invocation, which corrupted the jq parse here
    # and produced "FAIL: cron count check failed (expected=14 loaded=?)"
    # in PR #228's 2026-04-30 09:11 UTC deploy run. The intercom manifest
    # is missing channelConfigs metadata (separate tech debt to fix at
    # the plugin source), but the smoke test should not block deploys
    # on stderr-only warnings.
    LOADED_RAW=$(openclaw --profile main cron list --all --json 2>/dev/null) || LOADED_RAW=""
    if [ -z "$LOADED_RAW" ]; then
      fail_check "Main: openclaw cron list --all --json returned nothing (gateway not running?)"
    else
      LOADED_CRONS=$(echo "$LOADED_RAW" | jq '
        if (.hasMore == true) then .total
        else [ .jobs[] | select(((.schedule.kind == "at") and (.deleteAfterRun == true)) | not) ] | length
        end' 2>/dev/null || echo "?")
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
# OpenRouter reachability (sole inference path for all profiles)
# -------------------------------------------------------------------
log "Checking OpenRouter reachability..."
OR_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://openrouter.ai/api/v1/models 2>/dev/null || echo "000")
if [[ "$OR_HTTP" == "200" ]]; then
  pass_check "OpenRouter /api/v1/models returned 200"
else
  fail_check "OpenRouter /api/v1/models returned ${OR_HTTP} — every agent will fail until this clears"
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
