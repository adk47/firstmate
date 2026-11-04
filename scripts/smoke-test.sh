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

# page_websearch_unavailable <label> <detail> — the PAGE half of the
# page-and-warn ruling (2026-11-04): a provider-unavailable web_search result
# must be visible to a human, not just a WARN line in a deploy log nobody
# reads. Best-effort by design: a Slack outage must never turn a WARN into a
# deploy failure, and this must never be the reason a deploy blocks.
page_websearch_unavailable() {
  local label="$1" detail="$2"
  local lib="$_SMOKE_DIR/lib/slack-notify.sh"
  [ -r "$lib" ] || return 0
  # shellcheck source=lib/slack-notify.sh
  ( . "$lib" >/dev/null 2>&1 || exit 0
    slack_notify "web_search provider UNAVAILABLE (${label}): ${detail}. No candidate was registered, so no request was made — this is provider-side, not a payload or policy fault. The deploy proceeded; the check stays visible until the provider is back." >/dev/null 2>&1 || true
  ) || true
  return 0
}

# websearch_probe_attempt + its helpers (real-call evidence via the scout
# rollout, not model text) are pure/injectable and live in a separate lib so
# bats can unit-test them without a live gateway — see check_web_search
# below and scripts/lib/websearch-probe.sh for the full rationale.
_SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/websearch-probe.sh
source "$_SMOKE_DIR/lib/websearch-probe.sh"
# credit_gate_probe — same split rationale; asserts the deployed credit
# reject/approve gates still refuse (issue #754).
# shellcheck source=lib/credit-gate-probe.sh
source "$_SMOKE_DIR/lib/credit-gate-probe.sh"
# mesh_probe_* — same split rationale; classifies the Clio -> CTO round-trip
# without trusting loose keywords in the reply (see lib/mesh-probe.sh).
# cron_store_* — the canonical durable-cron accounting, shared with deploy.sh's
# Step 6b convergence heal so the two can never disagree (see lib/cron-store.sh).
# shellcheck source=lib/cron-store.sh
source "$_SMOKE_DIR/lib/cron-store.sh"
# wait_gateway_settled — hold the LLM probes until the post-start freeze is over
# (MUS-28729; see lib/gateway-settle.sh).
# shellcheck source=lib/gateway-settle.sh
source "$_SMOKE_DIR/lib/gateway-settle.sh"
# shellcheck source=lib/mesh-probe.sh
source "$_SMOKE_DIR/lib/mesh-probe.sh"
# slack_probe_* — gate that every Slack account in openclaw-main.json came
# up with a RESOLVED botToken SecretRef (lib/slack-probe.sh has the rationale).
# shellcheck source=lib/slack-probe.sh
source "$_SMOKE_DIR/lib/slack-probe.sh"
# restart_recovery_* — same split rationale; tells a main-session restart
# recovery REPLAY (every direct turn on `agent:<id>:main` is rejected with
# "changed while starting work" until the replay's journal terminal line) apart
# from a genuinely broken agent (see lib/restart-recovery.sh).
# shellcheck source=lib/restart-recovery.sh
source "$_SMOKE_DIR/lib/restart-recovery.sh"

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

# recovery_gate <profile> <session-keys-csv> <label> — run before any
# direct-turn probe of a main session; list EVERY session the probe touches
# (the mesh probe nests a sessions_send into agent:cto:main, so a replay on
# the downstream key rejects it just the same). After a FORCED restart (drain skipped) the gateway
# replays each interrupted `agent:<id>:main` under main-session restart
# recovery, and for the whole replay every direct turn on that key is rejected
# at claim time with `Session "<key>" changed while starting work. Retry.`
# (2026-09-11: agent:clio:main replayed for 16.5 min; the smoke test logged it
# as "did not return PONG", which reads like a broken agent). Waits up to
# SMOKE_RECOVERY_WAIT_SECS for the journal's terminal line, then:
#   0 → clear, probe.   1 → still replaying: an explicit WARN naming the cause,
#   caller SKIPS the probe.   2 → journal unreadable: log it and probe anyway —
#   the probe itself still fails loud, so the original behaviour is the safe
#   fallback here, not a silent skip.
SMOKE_RECOVERY_WAIT_SECS="${SMOKE_RECOVERY_WAIT_SECS:-120}"
# A key that already exhausted its wait is skipped on sight — clio is gated
# twice (mesh probe, then its ping), and paying the budget twice buys nothing.
declare -A _RECOVERY_PENDING=()
recovery_gate() {
  local profile="$1" keys="$2" label="$3" rc=0 key
  local -a key_list=()
  IFS=, read -r -a key_list <<< "$keys"
  for key in "${key_list[@]}"; do
    if [[ -n "$key" && -n "${_RECOVERY_PENDING[$key]:-}" ]]; then
      warn_check "$label: '$key' still under restart recovery (already waited ${SMOKE_RECOVERY_WAIT_SECS}s above) — LLM probe SKIPPED."
      return 1
    fi
  done
  restart_recovery_wait "$profile" "$keys" "$SMOKE_RECOVERY_WAIT_SECS" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      key="$RESTART_RECOVERY_PENDING_KEY"
      _RECOVERY_PENDING[$key]=1
      warn_check "$label: '$key' is still under main-session restart recovery after ${SMOKE_RECOVERY_WAIT_SECS}s — LLM probe SKIPPED. Expected after a forced restart, not an agent fault: direct turns return 'changed while starting work' until the journal logs 'restart recovery terminal: session=$key'. Re-probe by hand once it does (docs/lessons/deploy-ci-pr.md)."
      return 1 ;;
    3)
      warn_check "$label: SMOKE_RECOVERY_WAIT_SECS='$SMOKE_RECOVERY_WAIT_SECS' is not a non-negative integer — restart-recovery gate for '$keys' SKIPPED, probing without it"
      return 0 ;;
    *)
      log "  $label: could not read the gateway journal to check restart recovery for '$keys' (rc=$rc); probing anyway"
      return 0 ;;
  esac
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
  local start elapsed response rc verdict
  recovery_gate "$profile" "agent:${agent_id}:main" "$label" || return 0
  start=$(date +%s)
  # `if VAR=$(...)` keeps BOTH the exit status and the captured output (same
  # shape as the mesh probe below). The old `|| response="TIMEOUT"` replaced
  # the output on ANY non-zero exit — and `openclaw agent` exits 1 on a
  # restart-recovery claim rejection, so the exact error was gone before
  # anything could classify it (QA round 2 on PR #934).
  if response=$(timeout 60 openclaw --profile "$profile" agent --agent "$agent_id" -m "respond with the exact word PONG and nothing else" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  verdict="$(restart_recovery_ping_verdict "$rc" "$response")"
  case "$verdict" in
    pass)
      pass_check "$label: agent '$agent_id' responded PONG in ${elapsed}s" ;;
    recovery)
      # The gate read clear but the turn still hit the recovery claim: a
      # replay (re)started between the read and the turn. Name it — this is
      # not a 60s timeout and not a broken agent.
      warn_check "$label: agent '$agent_id' rejected the turn with the restart-recovery claim error (a main-session replay is in progress; see recovery_gate). Response head: $(echo "$response" | head -c 200)" ;;
    timeout)
      warn_check "$label: agent '$agent_id' did not return PONG within 60s (elapsed=${elapsed}s, rc=124). Response head: $(echo "$response" | head -c 200)" ;;
    *)
      warn_check "$label: agent '$agent_id' did not return PONG (elapsed=${elapsed}s, rc=$rc). Response head: $(echo "$response" | head -c 200)" ;;
  esac
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
# the one authoritative signal is a search event in the probed agent's
# codex-home rollout — legacy `web_search_end`, or the codex >= 0.151.0
# `item_completed` Extension `web.search` item — counted by JSON shape). Both
# are fixed in the lib: the break regex is checked against the captured
# response text regardless of exit code, and a PASS requires the agent's
# rollout to have gained a search event during the attempt (positive rollout
# evidence outranks the text — the hosted search backend can echo the break
# string over real results; the probe also runs in a fresh session so the
# agent's `main` history cannot feed that echo).
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
  # SMOKE_OPENCLAW_CFG_DIR is a TEST SEAM (scripts/tests/smoke-test.bats): the dispatcher branch below is the thing
  # qa-review 2026-11-04 found untested, and it cannot be reached without a config that says search is enabled.
  enabled=$(python3 - "$profile" "${SMOKE_OPENCLAW_CFG_DIR:-/opt/hydra}" <<'PYEOF' 2>/dev/null || echo "false"
import json, sys
profile, cfgdir = sys.argv[1], sys.argv[2]
with open(f'{cfgdir}/openclaw-{profile}.json') as f:
    c = json.load(f)
print('true' if c.get('tools', {}).get('web', {}).get('search', {}).get('enabled') is True else 'false')
PYEOF
  )
  if [[ "$enabled" != "true" ]]; then
    pass_check "$label: web_search not enabled for this profile — skipping probe"
    return
  fi

  local prompt="Use web_search to find the official homepage URL of MusicBrainz. You MUST call the web_search tool. Reply with exactly: SEARCH_STATUS: <ok|error and the error text>"

  # DUAL PROBE (item i, 2026-09-11). The GLOBAL availability verdict comes from a
  # DENY-FREE reference agent and stays a hard FAIL. scout is still probed, but a
  # scout-ONLY failure degrades to WARN naming the policy that caused it.
  #
  # WHY: this check hardcoded `--agent scout`, and scout carries a `tools.deny`
  # that on openclaw >= 2026.8 marks its codex harness restricted and disables
  # its native tool surface INCLUDING web search (validate-config-matrix.sh
  # check #8 is the authority for that rule). On 2026-09-11 that made Step 7
  # hard-fail on a PER-AGENT policy while `qa` (deny-free) had a confirmed
  # web_search_end at 14:44Z, after the cutover — blocking every deploy, and with
  # it the token-refresh timer, on a restriction that was not a global outage.
  #
  # The rollout-event standard is UNCHANGED for both agents: a pass still
  # requires a real web_search_end. Reply text is never evidence.
  local reference restriction ref_verdict ref_detail scout_verdict scout_detail result attempt
  reference="$(websearch_reference_agent "$profile")"

  if [[ -z "$reference" ]]; then
    # FAIL CLOSED. With no unrestricted agent there is no reference, so a scout
    # failure cannot be attributed to a policy and keeps its original hard-fail
    # semantics rather than being downgraded on an assumption.
    log "  $label: no deny-free reference agent — scout-only probe (fail-closed)"
    for attempt in 1 2; do
      result="$(websearch_probe_attempt "$profile" "$prompt" scout)"
      scout_verdict="$(echo "$result" | sed -n 's/^VERDICT=//p')"
      scout_detail="$(echo "$result" | sed -n 's/^DETAIL=//p')"
      case "$scout_verdict" in
        fail) fail_check "$label: web_search BROKEN (${scout_detail}) — and no deny-free agent exists to prove otherwise"; return ;;
        # qa-review 2026-11-04 (finding 1): this arm used to WARN, so a config regression that REMOVED the deny-free
        # reference was missed whenever scout happened to report provider-unavailable. With no reference there is
        # nothing to attribute the provider condition to, and the missing reference is itself the regression: fail
        # closed, exactly like `fail`. (The reference-present arm below still WARNs - there the reference is the
        # evidence that the provider condition is not global.)
        unavailable) fail_check "$label: web_search provider UNAVAILABLE (${scout_detail}) — and NO deny-free reference agent exists, so this cannot be attributed to a provider-side condition: the missing reference is itself a config regression. Fail closed."; return ;;
        pass) pass_check "$label: web_search ok (${scout_detail})"; return ;;
      esac
    done
    warn_check "$label: web_search probe inconclusive (${scout_detail}) — not treating as a break"
    return
  fi

  for attempt in 1 2; do
    result="$(websearch_probe_attempt "$profile" "$prompt" "$reference")"
    ref_verdict="$(echo "$result" | sed -n 's/^VERDICT=//p')"
    ref_detail="$(echo "$result" | sed -n 's/^DETAIL=//p')"
    [[ "$ref_verdict" != "inconclusive" ]] && break
    [[ "$attempt" -eq 1 ]] && log "  $label: reference probe (${reference}) inconclusive, retrying once..."
  done

  if [[ "$ref_verdict" == "fail" ]]; then
    fail_check "$label: web_search BROKEN GLOBALLY (${ref_detail}) — confirmed on deny-free agent '${reference}', so this is not a per-agent policy restriction"
    return
  fi

  # PROVIDER-UNAVAILABLE on the deny-free reference: page and proceed. The
  # runtime throws "disabled or no provider is available" from
  # resolveWebSearchCandidates() when the candidate list is EMPTY, i.e. before
  # any request — so there is no 429/timeout/entitlement rejection to read and
  # nothing about this deploy's payload is implicated. Rolling back cannot fix
  # a provider that was never registered, and on 2026-11-04 it blocked the
  # Gmail readers fix behind a vendor-side capability. A POLICY refusal is
  # still `fail` above and still blocks.
  if [[ "$ref_verdict" == "unavailable" ]]; then
    warn_check "$label: web_search provider UNAVAILABLE (${ref_detail}) — confirmed on deny-free agent '${reference}'; no candidate registered, so no request was made. Not a payload or policy fault; deploy proceeds and this is paged."
    page_websearch_unavailable "$label" "$ref_detail"
    return
  fi

  result="$(websearch_probe_attempt "$profile" "$prompt" scout)"
  scout_verdict="$(echo "$result" | sed -n 's/^VERDICT=//p')"
  scout_detail="$(echo "$result" | sed -n 's/^DETAIL=//p')"
  restriction="$(websearch_agent_restriction "$profile" scout)"

  case "$(websearch_scoped_verdict "$ref_verdict" "$scout_verdict" "$restriction")" in
    fail)
      fail_check "$label: $(websearch_scoped_fail_message "$scout_detail" "$restriction" "$reference" "$ref_verdict" "$ref_detail")"
      ;;
    warn)
      if [[ "$scout_verdict" == "unavailable" ]]; then
        # b1's NO-GO on #1745: `unavailable` is provider-side (the candidate list was EMPTY, so no request was made).
        # The message must not claim more than was measured: with ref=pass we know search works globally; with
        # ref=inconclusive we do NOT, and saying "the deny-free agent proved search works" there would be asserting a
        # fact the probe never established. Both are WARN + page; only the wording differs.
        if [[ "$ref_verdict" == "pass" ]]; then
          warn_check "$label: web_search provider UNAVAILABLE for scout (${scout_detail}) — deny-free agent '${reference}' proved search works, so this is not a global outage. Deploy proceeds; page sent."
        else
          warn_check "$label: web_search provider UNAVAILABLE for scout (${scout_detail}) — the reference probe was '${ref_verdict}', so global search is NOT proven; the provider list was empty, so no request was made and this is not a payload, policy or config fault. Deploy proceeds; page sent."
        fi
        page_websearch_unavailable "$label" "$scout_detail"
      else
        warn_check "$label: web_search is RESTRICTED for agent 'scout' by ${restriction} — deny-free agent '${reference}' searches fine, so this is a per-agent policy, not an outage. Deploy proceeds with the restriction visible. See validate-config-matrix.sh check #8."
      fi
      ;;
    pass)
      pass_check "$label: web_search ok (${ref_detail}, via deny-free agent '${reference}')"
      ;;
    *)
      warn_check "$label: web_search probe inconclusive (ref='${ref_detail}', scout='${scout_detail}') — not treating as a break"
      ;;
  esac
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
  # tool, CTO thinks, Clio synthesizes the reply). Measured 2026-08-04 on
  # node-8: 36s for a successful round-trip, so 60s is the right ceiling.
  #
  # Bounded retry (up to 3 attempts, same idiom as check_web_search's
  # attempt loop above) to cut false warn_check noise from LLM latency —
  # any single attempt the classifier calls `pass` is a pass; only if all
  # 3 attempts fail to confirm do we degrade to a warn.
  #
  # PASS CRITERION (2026-08-04, QA finding on PR #791): a dedicated token from
  # mesh_probe_verdict, NOT the old `grep -qi 'cto\|responded\|pong\|
  # acknowledged'`. That keyword set matched the failure sentence "I couldn't
  # reach CTO" on an rc=0 turn, so the probe could report PASS exactly when
  # cross-agent messaging was broken. Harmless only while the probe could never
  # reach rc=0 at all (see INVOCATION below) — repairing the call is what made
  # the weak pattern load-bearing. See scripts/lib/mesh-probe.sh for the
  # classifier, its three-state contract, and an honest note on what the token
  # does and does not prove.
  #
  # INVOCATION (2026-08-04): must be `agent --agent <id> -m <text>`, the same
  # form ping_agent() uses. There is NO `openclaw agent send` subcommand —
  # `agent send clio "..."` parses as three stray positionals and exits 1 in
  # ~0s with "Too many arguments for this command." That typo shipped in
  # 42f0adb3 (2026-04-06) and this probe never passed once in the ~4 months
  # since: 8/8 of the most recent deploys logged the warn, 0 logged a pass.
  #
  # It hid that long because the old `|| MESH_RESPONSE="TIMEOUT"` clobbered
  # the captured stderr on ANY non-zero exit, so a usage error rendered
  # identically to a real timeout. That cost two wrong diagnoses: issue #91
  # (opened 2026-04-12 blaming post-deploy agent warm-up, closed 2026-05-28
  # as "one-off, no recurrence" — it was recurring every single deploy), and
  # the timeout/retry mitigations above, which treated latency that was never
  # the problem. So: keep the rc, and report what actually happened. rc 124 is
  # timeout's own signal for "deadline hit"; anything else non-zero is the
  # command itself failing and must surface its stderr verbatim.
  log "  Testing cross-agent mesh behaviorally (Clio -> CTO via LLM)..."
  # The probe is a direct turn on agent:clio:main that nests a sessions_send
  # into agent:cto:main; a restart-recovery replay on EITHER key rejects it
  # (all 3 attempts failed in ~1s each at 14:44:22-24Z on 2026-09-11 while
  # clio's key was held). Gate both keys like ping_agent.
  wait_gateway_settled main 18789
  MESH_GATED=0
  recovery_gate main agent:clio:main,agent:cto:main "Main" || MESH_GATED=1
  for attempt in 1 2 3; do
    if [[ "$MESH_GATED" -eq 1 ]]; then break; fi
    # `if VAR=$(...)` (not `VAR=$(...); rc=$?`) because this script runs under
    # `set -e` — a bare failing assignment would abort the whole smoke test.
    # Same shape as _websearch_probe_attempt in scripts/lib/websearch-probe.sh.
    if MESH_RESPONSE=$(timeout 60 openclaw --profile main agent --agent clio -m "$(mesh_probe_prompt)" 2>&1); then
      MESH_RC=0
    else
      MESH_RC=$?
    fi
    MESH_VERDICT="$(mesh_probe_verdict "$MESH_RC" "$MESH_RESPONSE")"
    if [[ "$MESH_VERDICT" == "pass" ]]; then
      pass_check "Main: Cross-agent mesh behavioral test passed (Clio -> CTO round-trip)"
      break
    fi
    MESH_DETAIL="$(mesh_probe_detail "$MESH_RC" "$MESH_VERDICT" "$MESH_RESPONSE")"
    if [[ "$attempt" -lt 3 ]]; then
      log "  Main: Cross-agent mesh behavioral test inconclusive on attempt $attempt ($MESH_DETAIL), retrying..."
    else
      warn_check "Main: Cross-agent mesh behavioral test did not confirm after 3 attempts — $MESH_DETAIL"
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

  # Slack SecretRef gate — a botToken ref that fails to resolve leaves the
  # account with botTokenSource != "config" and the bot silently dark. A parseable
  # bad answer is a HARD fail (rollback). A gateway that gives no parseable answer
  # after the retry budget proves nothing either way, so it only warns that
  # resolution was NOT verified (20 Oct deploy was rolled back on that). Account
  # list is read from the deployed config, not hard-coded.
  slack_probe_gate /opt/hydra/openclaw-main.json

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
  # to enabled-only. A PAGINATED response (hasMore) is UNKNOWN and fails loud:
  # `.total` is the all-rows count including the ephemerals this check excludes,
  # and openclaw 2026.7.1 exposes no paging flag, so the unseen rows cannot be
  # fetched. Do not "fall back" to it — that is the bug, not the mitigation.
  if [ ! -f /opt/hydra/cron-jobs.json ]; then
    fail_check "Main: /opt/hydra/cron-jobs.json missing — repo file did not deploy"
  else
    # The repo must hold DURABLE jobs only. The gateway-side count below excludes
    # ephemeral one-shots (deleteAfterRun:true + schedule.kind "at"), and such a job
    # deletes itself after its run, so committing one makes this check fail on every
    # deploy: hydra#1411 committed the Prodigi export one-shot, it ran and self-deleted
    # at 2026-10-28T00:02Z, and deploy 40609006536 rolled back on "repo has 51,
    # gateway loaded 50". A one-shot stays on the gateway (exempt from the store-only
    # guard) and never enters cron-jobs.json; if one was committed, remove it after
    # its run. scripts/tests/cron-payload-contract.bats enforces this in CI.
    EXPECTED_CRONS=$(jq '.jobs | length' /opt/hydra/cron-jobs.json 2>/dev/null || echo "?")
    # 2>/dev/null (NOT 2>&1): same reason as check_channel_health above —
    # openclaw 2026.4.27 emits `Config warnings:\n- plugins.entries.*` on
    # stderr at every CLI invocation, which corrupted the jq parse here
    # and produced "FAIL: cron count check failed (expected=14 loaded=?)"
    # in PR #228's 2026-04-30 09:11 UTC deploy run. The intercom manifest
    # is missing channelConfigs metadata (separate tech debt to fix at
    # the plugin source), but the smoke test should not block deploys
    # on stderr-only warnings.
    # Read through lib/cron-store.sh's retried gateway read (the same helper
    # deploy.sh Step 6b uses), never a bare single-shot CLI call: run
    # 35116340141 (2026-09-16 15:44Z) rolled a healthy deploy back on ONE empty
    # read taken ~2 min after the restart. The helper retries a refused
    # connection AND an rc-0 empty read, and reports WHY on stderr, which is
    # kept for the failure message instead of being discarded. rc 2 =
    # paginated: the durable count cannot be derived from a truncated page, so
    # it is UNKNOWN and gets its own message rather than a parse failure.
    CRON_LIST_ERR="$(mktemp)"
    CRON_COUNT_RC=0
    LOADED_CRONS=$(cron_store_gateway_durable_count main 2>"$CRON_LIST_ERR") || CRON_COUNT_RC=$?
    (( CRON_COUNT_RC == 0 )) || LOADED_CRONS="?"
    if (( CRON_COUNT_RC == 2 )); then
      fail_check "Main: cron list came back PAGINATED (hasMore=true) — the durable cron count is unobtainable, so the store is unverifiable."
    elif (( CRON_COUNT_RC != 0 )); then
      fail_check "Main: cron store read failed within ${CRON_STORE_READ_DEADLINE_SECS}s (attempt timeout ${CRON_STORE_READ_ATTEMPT_TIMEOUT_SECS}s): $(tr '\n' ' ' < "$CRON_LIST_ERR" | sed 's/  */ /g')"
    elif [[ "$EXPECTED_CRONS" == "?" ]]; then
      fail_check "Main: cron count check failed (expected=? loaded=$LOADED_CRONS) — could not parse /opt/hydra/cron-jobs.json"
    elif [[ "$LOADED_CRONS" == "$EXPECTED_CRONS" ]]; then
      pass_check "Main: cron scheduler loaded $LOADED_CRONS jobs (matches repo)"
    else
      fail_check "Main: cron count mismatch — repo has $EXPECTED_CRONS, gateway loaded $LOADED_CRONS (was the cron file written to the wrong path?)"
    fi
    rm -f "$CRON_LIST_ERR"
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
  wait_gateway_settled edge 18810
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
# Credit-request safety gates, as DEPLOYED (issue #754)
# -------------------------------------------------------------------
# CI's bats suites pin these gates in the REPO; nothing until now checked that
# they landed INTACT ON THIS BOX. An rsync exclude/keepglob drift, a hot-patch
# overwrite, or a partial sync can leave node-8 running a gate that no longer
# enforces while every CI check and the deploy itself stay green. Both gates
# have already shipped a fail-open bug of this class (#740 reject, #750 approve).
#
# Deliberately warn-only for now: this check sits in a path where a false
# positive would hard-fail the deploy fleet-wide and trip the rollback step.
# Promote to fail_check once it has run clean across a few deploys (#754).
log "Checking credit-request safety gates (as deployed)..."
for _gate_script in \
  /opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh \
  /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh
do
  _gate_label="$(basename "$(dirname "$(dirname "$_gate_script")")")"
  case "$_gate_script" in
    */workspaces/*) _gate_label="workspace/$_gate_label" ;;
    *)              _gate_label="skills-all/$_gate_label" ;;
  esac
  if [[ ! -f "$_gate_script" ]]; then
    warn_check "Credit gates: $_gate_label — script not found at $_gate_script"
    continue
  fi
  # credit_gate_probe runs the assertions in an isolated child process, so the
  # API script's `set -euo pipefail` and globals cannot leak in here.
  if _gate_out="$(credit_gate_probe "$_gate_script" 2>&1)"; then
    pass_check "Credit gates: $_gate_label enforcing (reject + approve, incl. JSON-escape/newline evasions)"
  else
    warn_check "Credit gates: $_gate_label NOT fully enforcing — $(echo "$_gate_out" | grep -E '^(BAD|INVALID):' | tr '\n' ';')"
  fi
done
unset _gate_script _gate_label _gate_out

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
