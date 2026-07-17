#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-health.sh — sourceable helpers for detecting Codex
# (OpenAI agentRuntime) health problems on the EDGE gateway.
#
# Sourced by scripts/openclaw-watchdog.sh; unit-tested by
# scripts/tests/codex-health.bats. The log-scanning functions read
# journal text on STDIN and echo an integer, so they are testable
# with heredoc fixtures and never call journalctl/ssh themselves —
# the same pure-function pattern as scripts/lib/drift-check.sh.
#
# Why these specific signatures (verified live on hydra, openclaw
# 2026.5.27, against the 14-day edge journal during the #356 window):
# a Codex OAuth failure does NOT surface as `reason=auth` in the
# `[model-fallback/decision]` line — that field was only ever
# unknown / timeout / rate_limit on edge. It surfaces as the literal
# OAuth error string, and for the vision/image tool as the
# image/pdf "All image models failed" summary. So keying an alert on
# `reason=auth` would never fire here; we key on the substrings that
# actually appear.
# ──────────────────────────────────────────────────────────────

# codex_count_auth_invalidated — count Codex-OAuth-dead lines on stdin.
# Signature: "authentication token has been invalidated" (openclaw emits
# this from both the text turn and the image/pdf tool when the
# openai-codex credential is stale/rotated-away). Fired 35x / 14 days
# during the edge #356 window. After the auth symlink + restart this
# should read 0; any nonzero means edge's Codex token went stale and
# Caroline has silently degraded to the sonnet text fallback.
codex_count_auth_invalidated() {
  grep -c -i -e "authentication token has been invalidated" || true
}

# codex_count_refresh_reused — count Codex-OAuth REFRESH-RACE lines on stdin.
# This is a DIFFERENT failure signature from codex_count_auth_invalidated above
# and it is the one that went undetected for 3.5h on 2026-06-08: two gateway
# processes (main + edge) sharing the one canonical codex token both hit the
# 5-min pre-expiry refresh window at once, both POSTed a refresh, one rotated the
# single-use token and the loser got an HTTP 401 it surfaces as:
#   "OpenAI Codex token refresh failed (401): ... code=refresh_token_reused"
# and the model-fallback layer then logs `reason=auth_permanent` while it drops
# the whole codex fleet to openrouter/openai/gpt-5.4-mini. NONE of those strings
# matches codex_count_auth_invalidated (which keys on the May-29 "token has been
# invalidated" wording), so the old watchdog stayed silent. We key on the literal
# substrings that actually appear for THIS class. Any nonzero count = a codex
# refresh race / permanent-auth fallback is in progress on the scanned journal.
# The durable PREVENTION is scripts/lib/ensure-codex-refresh-lock-shared.sh
# (converge the two processes' refresh-lock dirs); this detector is the alarm.
codex_count_refresh_reused() {
  grep -c -i -E \
    -e "refresh_token_reused" \
    -e "OpenAI Codex token refresh failed" \
    -e "reason=auth_permanent" \
    -e "token refresh failed.*\(?401\)?" || true
}

# codex_count_apikey_route — count Codex #90925 api-key-route 401s on stdin.
# @openclaw/codex@2026.6.x ("OpenAI route unification") routes openai/gpt-5.5 to
# the OpenAI Responses API-KEY endpoint (api.openai.com/v1/responses) instead of
# the Codex app-server OAuth route. hydra is OAuth-only (placeholder OPENAI_API_KEY)
# so it 401s `invalid_api_key` / "Incorrect API key provided: sk-..." and the whole
# fleet falls back to openrouter/openai/gpt-5.4-mini (incident 2026-06-19, after a
# manual `plugins install @openclaw/codex@2026.6.1 --force` floated codex off the
# 2026.5.27 pin). NONE of the other codex detectors match this string. Remediate by
# re-pinning codex (ensure-codex-version-pinned.sh) + restart; the SUCCESSFUL
# gpt-5.4-mini fallback line carries neither string, so the alert clears once codex
# is back on the OAuth route.
#
# Count ONLY genuine route-failure records — a `[model-fallback/decision]` or a
# `FailoverError` line carrying the api-key 401 — and NOT:
#   - raw `[openai-transport]` 401 probes (background compaction can probe the
#     Responses endpoint with the placeholder key; alone that is not a fleet
#     degradation and never reaches a fallback decision), or
#   - agent/chat text repeating "invalid_api_key" while discussing an incident
#     (`[agent:...]`, channel=webchat/slack).
# Do NOT additionally filter a real route-failure record on summarization/compaction
# wording: when #90925 is live, openclaw circuit-breaks gpt-5.5 for normal turns
# (they route straight to mini as reason=unknown, no api-key string) and the ONLY
# records that keep re-hitting gpt-5.5 auth are the periodic background
# summarization calls — so their `detail=Summarization failed: 401 ...` line IS the
# live signal, not noise. Excluding it made the fail-CLOSED write-gate go fail-OPEN
# on the 2026-07-06 outage (whole fleet on mini, gate reported healthy). A reason=auth
# api-key 401 means codex auth is broken regardless of which call triggered it; count
# it. Any nonzero count = the #90925 mis-route is live.
#
# Identify a genuine route-failure record POSITIVELY by its leading openclaw tag: the
# `[^\[]*` forbids any earlier bracketed tag, so agent/chat transcript lines (which
# lead with `[agent:...]`) and quoted text are excluded STRUCTURALLY, and both branches
# are anchored the same way. Do NOT substring-exclude `channel=`/`[agent` from the whole
# line: a real `[model-fallback/decision] reason=auth` record can legitimately carry its
# originating channel, and dropping it on that basis would be a SECOND fail-OPEN of the
# same class as the summarization one. NOTE the api-key 401 is logged FLAT (the message
# is inlined on the transport / decision / FailoverError line), not as a multi-line JSON
# body like refresh_reused — if that ever changes, mirror codex_count_refresh_reused's
# independent-substring matching so a split body still counts.
codex_count_apikey_route() {
  awk '
    function is_apikey(line) {
      return line ~ /invalid_api_key/ || line ~ /incorrect api key provided/
    }
    function is_route_failure_record(line) {
      return line ~ /node\[[0-9]+\]:[^\[]*\[model-fallback\/decision\]/ \
        || line ~ /node\[[0-9]+\]:[^\[]*failovererror/
    }
    {
      line = tolower($0)
      if (is_apikey(line) && is_route_failure_record(line)) {
        count++
      }
    }
    END {
      print count + 0
    }
  ' || true
}

# codex_apikey_route_verdict — classify a nonzero api-key-route 401 count by the
# ACTUAL codex pin state, so the alert stops blaming EVERY such 401 on a version
# float. Args: <apikey_count> <pin_check_exit>, where pin_check_exit is the exit
# code of `ensure-codex-version-pinned.sh --check` (0 clean / 1 drift / 2 read-err).
# Echoes one of:
#   none         — no 401s, nothing to alert
#   float        — 401s AND the pin drifted: the genuine #90925 6.x mis-route;
#                  re-pin + restart is the correct fix.
#   compaction   — 401s but the pin is CLEAN: NOT a float. This is the embedded
#                  compaction/summarization path, which resolves a separate
#                  summarizer target that bypasses the codex OAuth runtime and drops
#                  openai/gpt-5.5 to the raw api-key transport → placeholder key →
#                  401 → self-recovers to openrouter/openai/gpt-5.4-mini. A re-pin
#                  is a NO-OP here; it self-heals and needs no action. Do NOT set
#                  agents.defaults.compaction.model — openclaw ignores that override
#                  on Codex-backed agents (emits an "override ignored" warning) and
#                  the fallback already lands on the exact model. (Root-caused
#                  2026-07-06: a stuck QA lane retried cli_budget [compaction-diag]
#                  compaction ~24x, all api-key 401s, pin clean, paged as a float.)
#   unverifiable — 401s but the pin check itself errored (exit 2): can't tell float
#                  from compaction; alert and ask for a manual pin check.
# Pure function (no journalctl/ssh), same testable pattern as the counters above.
codex_apikey_route_verdict() {
  local count="${1:-0}" pin_exit="${2:-2}"
  [ "$count" -gt 0 ] 2>/dev/null || { echo none; return; }
  case "$pin_exit" in
    1) echo float ;;
    0) echo compaction ;;
    *) echo unverifiable ;;
  esac
}

# codex_pin_check_exit — exit code of ensure-codex-version-pinned.sh --check
#   0 = clean (codex on the canonical pin), 1 = drift, 2 = unverifiable (read error
#   or the pin script is missing/not executable). Isolated behind one resolver so the
#   watchdog and the write-gate share it and bats can stub the pin verdict via
#   CODEX_PIN_CHECK_BIN without a real openclaw on PATH. Reads only; no mutation.
codex_pin_check_exit() {
  local bin="${CODEX_PIN_CHECK_BIN:-$(dirname "${BASH_SOURCE[0]}")/ensure-codex-version-pinned.sh}"
  [ -x "$bin" ] || return 2
  "$bin" --check >/dev/null 2>&1
}

# codex_count_token_expired — count Codex OAuth access-token-LAPSED 401s on stdin.
# Signature: "authentication token is expired" (the chatgpt.com/backend-api/codex
# OAuth route, NOT the api-key route above). This is the ordinary token lapse that
# TRIGGERED the 2026-06-19 outage and went unalerted ~9h because no detector keyed
# on it. DISTINCT from codex_count_auth_invalidated ("has been invalidated"): keyed
# on "is expired" ONLY so it never double-counts the shared "Please try signing in
# again" tail. Remediate with device-code re-auth (the TOKEN, not the plugin, is
# stale). Any nonzero count = codex's OAuth access token expired and refresh isn't
# renewing it.
codex_count_token_expired() {
  grep -c -i -e "authentication token is expired" || true
}

# codex_count_vision_failures — count exhausted-vision lines on stdin.
# Signature: "All image models failed" (the image tool AND the pdf tool
# share this prefix). Caroline's image tool is agents.defaults.imageModel
# = codex/gpt-5.6-sol → openrouter gemini-3.5-flash → haiku-4.5, so this line
# only fires when ALL of codex AND both OpenRouter fallbacks failed — a
# real, customer-visible vision outage, not a transient codex-auth blip
# (a codex-only failure degrades to gemini and does NOT log this). NOTE:
# deliberately does NOT match the per-candidate "Model does not support
# images" line, which is benign noise emitted while iterating fallbacks.
codex_count_vision_failures() {
  grep -c -i -e "All image models failed" || true
}

# codex_count_websearch_reconnect — count web_search MANAGED-PROVIDER
# reconnect-break lines on stdin. Signature: `[tools] web_search failed:
# Reconnecting` and `provider reconnection failed`. DISTINCT from every
# other counter above: those key on the codex AUTH runtime (OAuth/api-key);
# this one is the codex-backed managed `web_search` TOOL going unreachable,
# which fires when `tools.web.search.provider` is set to a managed provider
# (e.g. "codex") that the managed worker can't authenticate against on hydra.
# Root cause: PR #695 set `tools.web.search.provider:"codex"` on main, which
# on openclaw 7.1 is mutually exclusive with native codex search (setting a
# provider DISABLES native) — the managed worker then can't authenticate and
# every web_search call spins `Reconnecting... N/5` before failing. This was
# SILENT for ~15min post-deploy because only internal agents (scout) call
# web_search and nothing probed it after the restart; reverted in #701, and
# #701 also added a CI config gate (validate-config-matrix check 7) to block
# the provider+native combination from ever landing again. This counter is
# the RUNTIME safety net for the case a bad config still slips through: any
# nonzero count means web_search is broken fleet-wide for whichever profile
# has `tools.web.search.enabled` (main today). Page-only, no auto-heal — the
# fix is a config revert (or "unset provider"), not something a script
# should apply unattended.
codex_count_websearch_reconnect() {
  # BOTH signatures are anchored to the web_search TOOL: the gateway tool-error
  # line (`[tools] web_search failed: Reconnecting`) and the same break narrated
  # as a provider-reconnection failure — matched as `web_search.*provider
  # reconnection failed` so it catches both the gateway form (`[tools] web_search
  # failed: provider reconnection failed`) and the agent form (`web_search
  # provider reconnection failed`). The watchdog feeds the ENTIRE main journal
  # into this counter, so the second pattern MUST require web_search context — a
  # bare "provider reconnection failed" would also match unrelated
  # managed-provider/tool reconnects and false-page as "web_search BROKEN",
  # sending operators toward the wrong fix.
  grep -c -i -e "\[tools\] web_search failed: Reconnecting" -e "web_search.*provider reconnection failed" || true
}

# codex_edge_auth_symlink_status <auth-profiles-path>
# Filesystem health of edge/support's codex auth store. Echoes exactly
# one of: ok | not-symlink | dangling | missing
#   missing      — neither a file nor a symlink at the path
#   not-symlink  — a regular file (a deploy/rsync clobbered the symlink,
#                  or it was never provisioned by ensure-edge-codex-auth.sh)
#   dangling     — a symlink whose target no longer exists
#   ok           — a symlink whose target exists
# This checks STRUCTURE only — that edge's store is a live symlink to main's
# canonical codex token (the durability invariant a deploy/rsync can silently
# break, re-introducing #356). It deliberately does NOT inspect token
# `expires`: the codex access token is short-lived (~9h) and refresh-on-use.
# Verified live 2026-06-08 — the canonical auth-profiles.json had just rewritten
# itself (mtime 08:43:29Z, auth-state usageStats.lastUsed 08:43:28Z) to an
# `expires` only ~9h out, with 0 "authentication token has been invalidated"
# lines on edge. So `expires` is ALWAYS far inside any multi-hour window and
# carries no human-re-auth signal; the former 24h "stale" sub-check fired on
# essentially every cycle — a false alarm that re-auth would NOT have silenced
# (a fresh token is also <24h out). A genuinely dead/rotated-away token surfaces
# in the journal and is caught by codex_count_auth_invalidated above.
# Reads through the symlink, so it is portable across macOS (bats host) and
# Linux (node-8) without `readlink -f`.
codex_edge_auth_symlink_status() {
  local path="$1"
  if [ -L "$path" ]; then
    if [ ! -e "$path" ]; then echo dangling; return; fi
    echo ok; return
  fi
  if [ -e "$path" ]; then echo not-symlink; return; fi
  echo missing
}

# codex_health_gate [gateway_unit] [window_min]
# Live model-health verdict shared by write-gating wrappers (scripts/muso-stripe-write.sh
# and skills-all/muso-ops-admin/scripts/muso-admin-api.sh). It is the one place that
# decides "is codex healthy enough to let a consequential WRITE proceed", so the rule
# lives once and both call sites stay identical.
#
# Return contract:
#   0 — healthy   (journal readable, no refresh-race / auth-invalidated lines)
#   1 — DEGRADED  (>=1 codex-down signature in the window)
#   2 — UNVERIFIABLE (journal could not be read) — callers MUST fail closed
# On non-zero it prints a single-line human reason to stderr; the caller prepends its
# own "REFUSED (<context>)" framing and the defer-to-a-human instruction. An empty-but-
# readable window is healthy-quiet (return 0).
#
# WHY a verdict here and not just inline in each wrapper: the agent cannot perceive its
# own fallback (the `Model Fallback:` banner is delivery-only, never in the prompt — see
# memory reference_agent_cannot_see_own_fallback_state), so the only honest signal is a
# tool RESULT the agent can read. Keying that on one shared probe means a wrapper can
# never drift to a weaker check than the money path uses.
#
# `journalctl` is invoked by name (not an absolute path) so tests can stub it on PATH —
# see the fake_journalctl helper in scripts/tests/*.bats. Reads only; no mutation.
codex_health_gate() {
  local unit="${1:-openclaw-gateway-main}" window="${2:-5}"
  local journal
  if ! journal="$(journalctl -u "$unit" --since "${window} min ago" --no-pager 2>/dev/null)"; then
    echo "cannot read journald for ${unit} — codex model health unverifiable" >&2
    return 2
  fi
  local reused invalidated apikey expired
  reused="$(printf '%s\n' "$journal" | codex_count_refresh_reused)"
  invalidated="$(printf '%s\n' "$journal" | codex_count_auth_invalidated)"
  apikey="$(printf '%s\n' "$journal" | codex_count_apikey_route)"
  expired="$(printf '%s\n' "$journal" | codex_count_token_expired)"

  # The api-key-route 401 is the ONE degradation signature that is ambiguous: a real
  # #90925 float (codex off-pin) mis-routes EVERY gpt-5.5 turn to the api-key endpoint
  # and truly degrades the fleet, but the SAME `invalid_api_key` signature also appears
  # when only the embedded compaction summarizer bypasses the OAuth route while codex
  # stays healthy for real turns (pin CLEAN — root-caused 2026-07-06: a stuck QA lane
  # retried cli_budget compaction ~24x, all api-key 401s, fleet otherwise serving on
  # OAuth). Refusing consequential WRITES on that benign case is a false-positive
  # fail-CLOSED. So gate the api-key contribution on the ACTUAL pin: float or
  # unverifiable → degraded (fail closed on a write gate); compaction (pin clean) → the
  # fleet is healthy for the write, do not count it. The OTHER three signatures are
  # genuine OAuth-route failures that DO break real turns, so they degrade unconditionally.
  local apikey_degraded=0 apikey_verdict=clean
  if [ "${apikey:-0}" -gt 0 ]; then
    local pin_exit=0
    codex_pin_check_exit || pin_exit=$?
    apikey_verdict="$(codex_apikey_route_verdict "$apikey" "$pin_exit")"
    [ "$apikey_verdict" = "compaction" ] || apikey_degraded=1
  fi

  if [ "${reused:-0}" -gt 0 ] || [ "${invalidated:-0}" -gt 0 ] \
     || [ "$apikey_degraded" -gt 0 ] || [ "${expired:-0}" -gt 0 ]; then
    echo "codex is DEGRADED in the last ${window}min (refresh-race/auth_permanent=${reused}, auth-invalidated=${invalidated}, apikey-route#90925=${apikey}/${apikey_verdict}, token-expired=${expired})" >&2
    return 1
  fi
  if [ "${apikey:-0}" -gt 0 ]; then
    # Healthy-but-noteworthy: api-key 401s present yet pin clean → benign compaction
    # path, write allowed. Surface it (stderr) so the allow is not silent.
    echo "codex api-key 401s in the last ${window}min are compaction-only (pin clean) — write allowed; not a fleet degradation" >&2
  fi
  return 0
}
