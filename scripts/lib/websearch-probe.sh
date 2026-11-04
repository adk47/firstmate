#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# websearch-probe.sh — pure/injectable helpers for scripts/smoke-test.sh's
# post-restart web_search probe (see #695/#701 incident: PR #695 set
# tools.web.search.provider:"codex" on main, which on openclaw 7.1 disables
# NATIVE codex search and left the managed worker unable to authenticate —
# web_search failed fleet-wide for ~15min, silently, because nothing probed
# it post-restart).
#
# Sourced by smoke-test.sh; unit-tested by scripts/tests/websearch-probe.bats.
# Split out of smoke-test.sh itself (which runs unconditional host-wide
# checks — pgrep, systemctl, curl — the instant it's invoked, so it can't be
# sourced by bats without a live gateway) so these functions can be tested
# in isolation, same pattern as scripts/lib/codex-health.sh being a
# sourceable library for scripts/openclaw-watchdog.sh.
#
# Why NOT trust `openclaw agent --json` output or the gateway journal as
# PASS evidence (verified live on node-8, 2026-07-16 — QA finding on PR
# #704, node-8 signal facts folded in here):
#   - `--json` carries NO tool-call transcript at all: the only
#     "web_search" token anywhere in a 30KB response is the skill/prompt
#     listing. A model reply of "SEARCH_STATUS: ok" is NOT proof a tool call
#     happened — the model can answer from training data (MusicBrainz is a
#     very well-known site) without ever invoking web_search.
#   - the gateway journal logs web_search FAILURES only
#     (`[tools] web_search failed: Reconnecting`) — it never logs successes,
#     so "nothing broken in the journal" is not proof something ran either.
# The one authoritative signal that a REAL web_search call executed is a
# search event in the probed agent's codex-home session rollout, counted by
# JSON STRUCTURE (never substring — the review bot's rollouts quote PR
# prose containing the literal event name). The persisted shape depends on
# the vendored codex binary (both verified live on node-8):
#   - codex <= 0.144.3: `{"type":"event_msg","payload":{"type":"web_search_end",...}}`
#   - codex >= 0.151.0 (@openclaw/codex 2026.8.2): the legacy event is gone;
#     a native search is `{"type":"event_msg","payload":{"type":"item_completed",
#     "item":{"type":"Extension","kind":"web.search","results":[...]}}}`.
#     A substring grep for `web_search_end` read 0 for 28h (2026-09-10 12:47
#     -> 2026-09-11) while 17 real searches ran, so this probe could never
#     PASS and every "0 events since the cutover" reading was a false
#     negative.
# Verified live 2026-07-16: a successful probe produced 12 web_search_end /
# 0 Reconnecting; the broken (managed-provider misconfigured) state produced
# Reconnecting / 0 web_search_end.
#
# Two more live facts (2026-09-11) shape the verdict and the invocation:
#   - The hosted search backend summarises its results with the RECENT
#     CONVERSATION as input. In scout's persistent `main` session that
#     history carried a real prior outage, and the backend returned
#     "SEARCH_STATUS: error: web_search is disabled or no provider is
#     available." as the search OUTPUT over 29 real results (rollout
#     Extension item, musicbrainz.org first). So the probe runs in a FRESH
#     `--session-id` per attempt, and positive rollout evidence outranks a
#     break signature in the model text: the text can be an echo, the
#     structural event cannot.
#   - A prompt that says "call the web_search tool" steers the model to
#     openclaw's own `web_search` dynamic tool whenever that is exposed —
#     which only happens on the managed plan (restricted native surface, cf.
#     the 2026-09-10 sentry__* deny incident), where it fails with "disabled
#     or no provider". That IS a real break and the text signature still
#     catches it — a native-plan thread never exposes that tool.
# ──────────────────────────────────────────────────────────────

# _websearch_rollout_glob <profile> — glob for the scout agent's codex-home
# session rollout files. Env-overridable (WEBSEARCH_PROBE_ROLLOUT_GLOB) so
# bats can point this at a throwaway fixture dir instead of the real
# /root/.openclaw-<profile> store on node-8.
_websearch_rollout_glob() {
  local profile="$1" agent="${2:-scout}"
  echo "${WEBSEARCH_PROBE_ROLLOUT_GLOB:-/root/.openclaw-${profile}/agents/${agent}/agent/codex-home/sessions/*/*/*/rollout-*.jsonl}"
}

# _websearch_newest_rollout <glob> — path of the most-recently-modified file
# matching glob, or empty if none match. `ls -t` (not GNU-only `find
# -newer`) so this stays portable across the bats host (macOS) and node-8.
_websearch_newest_rollout() {
  local glob="$1"
  # No-match MUST return success with empty output: `ls -t` on an unmatched
  # glob exits non-zero, and under the caller's `set -euo pipefail` a non-zero
  # command substitution (baseline_path=$(...)) would abort the whole smoke
  # test before the probe reaches its retry-then-warn path. The trailing
  # `|| true` (with `2>/dev/null` swallowing the ls error) makes the empty
  # case a clean, empty success — no prior rollout is a valid state (fresh
  # host, or a scout that has never searched).
  # shellcheck disable=SC2086  # intentional glob expansion, not quoting
  ls -t $glob 2>/dev/null | head -n1 || true
}

# _websearch_rollout_hits <path> — count of persisted search events in the
# given rollout file, in EITHER shape (legacy `web_search_end` event, or the
# codex >= 0.151.0 `item_completed` Extension `web.search` item), matched by
# JSON structure. Malformed lines are skipped (`fromjson?`). Echoes 0 (not an
# error) for an empty/missing path — a profile with no rollout history yet
# has made "0 real calls so far". A missing jq fails LOUD (nonzero + stderr)
# BEFORE the empty-path shortcut, so a host that cannot count is detected on
# the baseline read even when no rollout exists yet: reading 0 would silently
# turn every probe into "inconclusive". Callers MUST capture this status
# (`if ! n="$(_websearch_rollout_hits ...)"`) — a bare command substitution
# discards it (QA #937).
_websearch_rollout_hits() {
  local path="$1" n
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: websearch-probe: jq is required to count rollout search events by JSON shape" >&2
    return 2
  fi
  [ -n "$path" ] && [ -r "$path" ] || { echo 0; return; }
  # jq's own status is propagated past `wc`/`tr` via PIPESTATUS: a jq crash
  # must surface as an error, never be read as "0 real calls" (jq-fail-open
  # class). Malformed lines are already tolerated by `fromjson?`.
  if ! n=$(jq -R -r 'fromjson? | select(.type == "event_msg")
        | select((.payload.type == "web_search_end")
              or (.payload.type == "item_completed"
                  and .payload.item.type == "Extension"
                  and .payload.item.kind == "web.search"))
        | 1' "$path" | wc -l | tr -d ' '; exit "${PIPESTATUS[0]}"); then
    echo "ERROR: websearch-probe: jq failed while counting search events in ${path}" >&2
    return 3
  fi
  echo "${n:-0}"
}

# _websearch_real_call_ran <profile> <baseline_path> <baseline_hits> —
# echoes 1 iff the newest rollout of that agent gained a search event since
# the pre-probe baseline (a brand-new rollout file counts as "gained" if it
# carries >=1 hit); echoes 0 otherwise, including "nothing changed" — the
# "model replied without actually calling the tool" case FINDING 2 (PR #704
# QA review) exists to catch. Returns NONZERO (echoing nothing) when the
# counter itself failed — the caller must not read that as "0 real calls".
_websearch_real_call_ran() {
  local profile="$1" agent="$2" baseline_path="$3" baseline_hits="$4"
  local glob after_path after_hits
  glob="$(_websearch_rollout_glob "$profile" "$agent")"
  after_path="$(_websearch_newest_rollout "$glob")"
  if ! after_hits="$(_websearch_rollout_hits "$after_path")"; then
    return 2
  fi
  if [ "$after_path" != "$baseline_path" ]; then
    if [ "${after_hits:-0}" -gt 0 ]; then
      echo 1
    else
      echo 0
    fi
    return
  fi
  if [ "${after_hits:-0}" -gt "${baseline_hits:-0}" ]; then
    echo 1
  else
    echo 0
  fi
}

# _websearch_probe_verdict <response_text> <real_call_ran:0|1> — pure
# classification, no I/O.
#
# FINDING 1 fix (PR #704 QA): a BROKEN signature in the response text is
# matched REGARDLESS of the agent process's exit code — this function is
# handed the captured text directly, so a break can
# never be lost to a `response=$(...) || response="TIMEOUT"` clobber
# upstream (the original bug: a Reconnecting failure that also made the
# agent process exit non-zero discarded the real output before it could be
# matched against the break regex).
# FINDING 2 fix (PR #704 QA): PASS requires real_call_ran=1 (positive
# rollout evidence of an actual tool call); model text alone (e.g. a
# hallucinated "SEARCH_STATUS: ok") is never sufficient on its own.
# 2026-09-11: positive rollout evidence OUTRANKS a break signature in the
# text. The hosted search backend echoed "web_search is disabled or no
# provider is available" as the search output of a real 29-result search
# (see header) — a structural event proves the call ran, the text proves
# nothing either way. A break signature only fails the probe when NO search
# event was persisted during the attempt (that is exactly the managed-plan
# outage: the openclaw `web_search` tool errors and native never fires).
# Anything else is "inconclusive" — callers retry once, then warn; this
# function never returns fail on an inconclusive read.
#
# 2026-11-04: PROVIDER-UNAVAILABLE is its own verdict, not `fail`.
#
# WHY: on 2026-11-04 every hydra deploy rolled back on this check while the
# fault was entirely on the provider side. The installed runtime throws
# `web_search is disabled or no provider is available.` from
# `resolveWebSearchCandidates()` when the candidate list is EMPTY — i.e. no
# request is ever made, so there is no 429, no timeout and no entitlement
# rejection to read. On this box the cause was the codex harness host
# capability going inactive (`[agent/embedded] agent cleanup failed: …
# step=codex-trajectory-flush error=agent harness host capability is no
# longer active`), which unregisters the native search tool. Nothing about
# the deploy payload, the tool policy or the config caused it, and a rollback
# cannot fix it — it only blocks the payload that IS ready (the Gmail readers
# fix) behind a vendor-side capability.
#
# So the three provider signatures now return `unavailable`, which the scoped
# verdict downgrades to WARN + page. A POLICY signature (a tool refused by
# policy) still returns `fail` and still blocks: that is a config regression
# we can fix, and the ruling keeps hard-fail for exactly that case.
_websearch_probe_verdict() {
  local response="$1" real_call_ran="$2"
  if [ "${real_call_ran:-0}" -eq 1 ]; then
    echo pass
    return
  fi
  # A policy refusal is a config regression: hard fail, never softened.
  if echo "$response" | grep -qiE 'not allowed by (tool )?policy|denied by (tool )?policy|blocked by (tool )?policy|tool .{0,40}is not permitted'; then
    echo fail
    return
  fi
  # Provider-side: no candidate registered, or the provider is reconnecting.
  if echo "$response" | grep -qiE 'Reconnecting|disabled or no provider is available|provider reconnection failed'; then
    echo unavailable
    return
  fi
  echo inconclusive
}

# websearch_probe_attempt <profile> <prompt> — runs ONE real probe attempt
# and echoes exactly two lines: `VERDICT=<fail|unavailable|pass|inconclusive>` and
# `DETAIL=<diagnostic text>` (the matched break signature on fail, a short
# rollout-evidence note on pass, or the raw exit code + reason on
# inconclusive). Snapshots the agent's newest rollout + its search-event
# count BEFORE invoking openclaw (the baseline), invokes the agent turn in a
# FRESH session (so the agent's persistent `main` history cannot poison the
# hosted search summariser — see header) WITHOUT clobbering the captured
# output on a nonzero exit (FINDING 1), then classifies via
# _websearch_probe_verdict.
websearch_probe_attempt() {
  local profile="$1" prompt="$2" agent="${3:-scout}"
  local glob baseline_path baseline_hits response rc real_ran verdict detail session_id
  glob="$(_websearch_rollout_glob "$profile" "$agent")"
  baseline_path="$(_websearch_newest_rollout "$glob")"
  # A counter that cannot run (no jq) is a BLOCKING verdict at this boundary,
  # not an inconclusive one: the dispatcher reads only the VERDICT line, and a
  # bare `x="$(...)"` would discard the helper's nonzero status and let Step 7
  # retry, warn and deploy with nothing measured (QA #937). Fail closed here,
  # before spending an agent turn.
  if ! baseline_hits="$(_websearch_rollout_hits "$baseline_path" 2>&1)"; then
    echo "VERDICT=fail"
    echo "DETAIL=probe cannot measure rollout evidence, failing closed: ${baseline_hits}"
    return 0
  fi
  session_id="websearch-probe-$(date +%s)-$$"

  # 2026-11-04: the turn timeout must be enforced BY THE GATEWAY, not by
  # killing the client. `timeout 150 openclaw agent …` kills the CLI process
  # while the RUN keeps going server-side, and an abandoned run is permanent
  # "active work": the gateway then loops
  #   [admission] closed: suspend phase
  #   [health] host thaw channel restart deferred: gateway still has active work
  # every 30 s and stops serving ANY agent turn (`Opening handshake has timed
  # out` for every agent on the profile) until it is restarted. Two or three
  # abandoned probes are enough. That is how this check took the fleet's agent
  # control plane down on 2026-11-04 and made the post-rollback smoke fail
  # identically — the alarm cost the thing it measures.
  #
  # `--timeout` is the gateway-side bound (openclaw agent --help: "Override
  # agent command timeout (seconds)"), so the run is cancelled properly. The
  # outer `timeout` is a belt-and-braces bound on the CLI itself and is set
  # ABOVE the gateway bound so it never wins the race.
  if response=$(timeout 200 openclaw --profile "$profile" agent --agent "$agent" --session-id "$session_id" --timeout 150 --json --message "$prompt" 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if ! real_ran="$(_websearch_real_call_ran "$profile" "$agent" "$baseline_path" "$baseline_hits" 2>&1)"; then
    echo "VERDICT=fail"
    echo "DETAIL=probe cannot measure rollout evidence, failing closed: ${real_ran}"
    return 0
  fi
  verdict="$(_websearch_probe_verdict "$response" "$real_ran")"

  case "$verdict" in
    fail)
      detail="$(echo "$response" | grep -ioE 'not allowed by (tool )?policy[^"]*|denied by (tool )?policy[^"]*|blocked by (tool )?policy[^"]*|tool [^"]{0,40}is not permitted' | head -1)"
      ;;
    unavailable)
      detail="$(echo "$response" | grep -ioE 'Reconnecting[^"]*|disabled or no provider is available|provider reconnection failed' | head -1)"
      ;;
    pass)
      detail="confirmed via ${agent} rollout search event (web_search_end or item_completed/Extension web.search)"
      ;;
    *)
      detail="rc=${rc}, no confirmed tool call (agent may not have searched, or timed out)"
      ;;
  esac

  echo "VERDICT=${verdict}"
  echo "DETAIL=${detail}"
}

# ──────────────────────────────────────────────────────────────
# Deny-aware scoping (item i, 2026-09-11)
#
# WHY: the Step-7 probe hardcoded `--agent scout`, and scout carries
# `tools.deny: ["sentry__*"]`. On openclaw >= 2026.8 ANY deny outside the
# closed CODEX_TOOL_POLICY_SAFE_DENY_NAMES list (or a narrowing `allow`)
# marks that agent's codex harness restricted, which disables its native
# tool surface INCLUDING web search — see validate-config-matrix.sh check
# #8, which is the authority for that rule, and
# docs/lessons/openclaw-and-codex.md. So a scout-only failure proves the
# AGENT is restricted, not that web_search is down fleet-wide. On
# 2026-09-11 that distinction blocked every deploy: Step 7 hard-failed on a
# per-agent policy while `qa` (deny-free) still had a confirmed
# web_search_end at 14:44Z, after the cutover.
#
# So: the GLOBAL availability verdict comes from a DENY-FREE reference
# agent and stays a hard FAIL. The scout probe is kept, but a scout-only
# failure degrades to WARN that names the agent and the exact policy path.
#
# The rollout-event standard is UNCHANGED: a pass still requires a real
# search event in the rollout (`web_search_end`, or the codex >= 0.151.0
# `item_completed` Extension `web.search` item). Reply text is never
# evidence, for either agent.
# ──────────────────────────────────────────────────────────────

# Mirrors CODEX_TOOL_POLICY_SAFE_DENY_NAMES from @openclaw/codex. Denying one
# of these does NOT restrict the harness. validate-config-matrix.sh check #8
# is the authority; re-verify both on every openclaw/codex bump.
WEBSEARCH_SAFE_DENY_NAMES="web_fetch x_search memory_search memory_get dashboard canvas show_widget message heartbeat_respond automations gateway skill_workshop image_generate music_generate video_generate tts"

# _websearch_config_path <profile> — the profile config to read policies from.
# Env-overridable so bats can point at a fixture.
_websearch_config_path() {
  echo "${WEBSEARCH_PROBE_CONFIG:-/opt/hydra/openclaw-$1.json}"
}

# websearch_agent_restriction <profile> <agent> — echoes a human-readable
# "<policy path> = <json>" when that agent's tool policy restricts the codex
# harness, or empty when it does not. Reads the same policy holders check #8
# does: the agent's own tools, agents.defaults, global, and any byProvider
# sub-policy of those. Empty output means "not restricted (or unreadable)" —
# callers must treat unreadable as non-attributing, never as proof.
websearch_agent_restriction() {
  local profile="$1" agent="$2" cfg
  cfg="$(_websearch_config_path "$profile")"
  [ -r "$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # Same GENERIC WALK as validate-config-matrix.sh check #8 (PR #929): find every
  # object carrying a deny/allow array whose JSON path contains a `tools`
  # segment, rather than enumerating known keys. Enumerating is what let
  # `byProvider`, then `toolsBySender`, then channel-group `tools` each slip
  # through check #8 in turn; a detector that knows fewer holders than the gate
  # would report "no policy explains it" for a real restriction and turn an
  # attributable WARN back into a false hard FAIL — the exact failure this whole
  # change exists to remove.
  #
  # ATTRIBUTION BOUNDARY, deliberately narrower than the gate: only policies that
  # provably apply to THIS agent — global `tools`, `agents.defaults.tools`, and
  # the agent's own subtree. Channel-group policies are session-scoped (they
  # depend on which group the turn arrives in) and cannot be pinned to an agent
  # statically, so they are NOT claimed here. A restriction we cannot attribute
  # stays unattributed, and the caller fails closed on it.
  jq -r --arg a "$agent" --arg safe "$WEBSEARCH_SAFE_DENY_NAMES" '
    ($safe | split(" ")) as $safe
    | . as $root
    # The tools value the agent itself carries, read exactly as openclaw reads
    # it before falling back to defaults. null/absent => defaults apply.
    | ( if ($root.agents.entries | type) == "object"
        then ($root.agents.entries[$a].tools // null)
        else ([ ($root.agents.list // [])[] | select(.id == $a) | .tools ] | first // null) end
      ) as $agentOwnTools
    | [ paths(type == "object" and ((.deny | type) == "array" or (.allow | type) == "array")) ]
    | map(select(any(.[]; . == "tools")))
    | map(select(
        (.[0] == "tools")
        # agents.defaults.tools applies ONLY when the agent has no tools of its
        # own. openclaw resolves it with NULLISH coalescing:
        #   resolveAgentConfig(cfg, agentId)?.tools ?? cfg.agents.defaults.tools
        # so an agent-level tools:{} (deny-free but PRESENT) shadows a
        # restrictive default entirely. Treating defaults as unconditional would
        # reject a deny-free agent as the reference and turn a per-agent
        # restriction into a hard deploy block (QA #933 round 3).
        or ((.[0] == "agents" and .[1] == "defaults") and ($agentOwnTools == null))
        or (.[0] == "agents" and .[1] == "list"
            and (($root.agents.list[.[2]].id // "") == $a))
        or (.[0] == "agents" and .[1] == "entries" and .[2] == $a)))
    | map({ p: (. as $pp
                | if ($pp[0] == "agents" and $pp[1] == "list")
                  then "agents.list[id=" + $a + "]." + ($pp[3:] | join("."))
                  else ($pp | join(".")) end),
            t: (. as $pp | $root | getpath($pp)) })
    | .[]
    | .p as $p | .t as $t
    | ( ( ($t.deny // []) | map(select(. as $d | ($safe | index($d)) == null))
          | select(length > 0) | ($p + ".deny = " + tostring) ),
        ( ($t.allow // []) | select(length > 0 and (index("*") == null))
          | ($p + ".allow = " + tostring) ) )
  ' "$cfg" 2>/dev/null | head -1
}

# websearch_reference_agent <profile> [preferred...] — echoes the first
# DENY-FREE agent to use for the global availability verdict. Prefers the
# names passed (default: qa then cto), then any other deny-free agent, so the
# probe keeps working if the roster changes. Echoes empty when EVERY agent is
# restricted — callers must fail closed there, because with no unrestricted
# reference a failure cannot be attributed to a policy.
websearch_reference_agent() {
  local profile="$1"; shift
  local preferred=("$@") cfg candidates=() a
  [ ${#preferred[@]} -eq 0 ] && preferred=(qa cto)
  cfg="$(_websearch_config_path "$profile")"
  [ -r "$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2207
  candidates=($(jq -r '
    if (.agents.entries | type) == "object" then (.agents.entries | keys[])
    else ((.agents.list // [])[] | .id) end' "$cfg" 2>/dev/null))
  for a in "${preferred[@]}"; do
    for c in "${candidates[@]}"; do
      if [ "$a" = "$c" ] && [ -z "$(websearch_agent_restriction "$profile" "$a")" ]; then
        echo "$a"; return 0
      fi
    done
  done
  for c in "${candidates[@]}"; do
    if [ -z "$(websearch_agent_restriction "$profile" "$c")" ]; then
      echo "$c"; return 0
    fi
  done
  return 0
}

# websearch_scoped_verdict <reference_verdict> <scout_verdict> <restriction>
# — combines the two probe verdicts into the Step-7 outcome. Echoes one of:
#   fail  — global break (the reference agent, which is deny-free, is broken),
#           or scout is broken with NO usable reference (fail closed: we
#           cannot attribute it, so we must not downgrade it)
#   warn  — scout broken but the deny-free reference works => per-agent
#           restriction, named, deploy proceeds with it visible; OR the
#           provider is UNAVAILABLE (no candidate registered / reconnecting)
#           on the deny-free reference => provider-side, page and proceed
#   pass  — reference confirmed a real search event in its rollout
#   inconclusive — nothing proven either way; caller retries then warns
websearch_scoped_verdict() {
  local ref="$1" scout="$2" restriction="$3"

  # A deny-free reference that FAILED is a real global outage. Hard fail first,
  # before anything else can soften it.
  if [ "$ref" = "fail" ]; then echo fail; return; fi

  # PROVIDER-UNAVAILABLE on the deny-free reference: the provider list is empty
  # or the provider is reconnecting. No request was made, so nothing about the
  # payload, the policy or the config is implicated, and a rollback cannot fix
  # it. WARN + page (the caller pages); the deploy proceeds. A policy refusal
  # never reaches here — it is `fail` above.
  if [ "$ref" = "unavailable" ]; then echo warn; return; fi

  # PROVIDER-UNAVAILABLE on SCOUT, with a reference that is not itself broken: the provider list was empty (or the
  # provider is reconnecting), so NO REQUEST WAS MADE. That is the same provider-side condition as the arm above, and
  # it is not attributable to the payload, the policy or the config - a rollback cannot fix it. b1's NO-GO on #1745
  # (2026-11-04) is exactly this cell: the two rounds that failed today's deploy were reference INCONCLUSIVE + scout
  # provider-unavailable, and mapping that to FAIL rolled back a deploy for a condition the deploy did not cause.
  # A reference that is ABSENT is NOT this case - that is a config regression (no deny-free agent exists) and stays
  # fail-closed below, as does a scout that genuinely FAILED with no positive reference evidence.
  if [ "$scout" = "unavailable" ] && { [ "$ref" = "pass" ] || [ "$ref" = "inconclusive" ]; }; then
    echo warn; return
  fi

  if [ "$scout" = "fail" ] || [ "$scout" = "unavailable" ]; then
    # WARN requires ref == "pass" — POSITIVE evidence, not merely "not failed".
    # The contract is "a deny-free agent searches fine, so this is a per-agent
    # policy"; only a pass carries that, because a pass is the one verdict backed
    # by a real web_search_end event in the reference agent's rollout.
    #
    # QA #933: an earlier version accepted any non-fail ref here, so
    # (inconclusive, fail, restriction) returned WARN — Step 7 would let a deploy
    # proceed with NO deny-free agent having produced search evidence at all.
    # That is the same fail-closed rule this function already applies to a missing
    # reference and to an unattributed scout failure, just one combination further
    # out, and it was the one cell not covered.
    if [ "$ref" = "pass" ] && [ -n "$restriction" ]; then echo warn; return; fi
    # Everything else with a broken scout fails closed: no reference at all, a
    # reference that never proved itself, or a failure no policy explains.
    echo fail; return
  fi

  if [ "$ref" = "pass" ]; then echo pass; return; fi
  echo inconclusive
}

# websearch_scoped_fail_message <scout_detail> <restriction> <reference> <ref_verdict> <ref_detail>
# Text for the `fail` arm of websearch_scoped_verdict (smoke-test.sh prefixes the
# label). The verdict is unchanged; only the blame is. With a restriction present
# and a reference that did not pass, the old "NO tool policy explains it" was
# false — scout's tools.deny exists, it just cannot be confirmed as the cause
# because the deny-free reference never produced search evidence (MUS-28729).
websearch_scoped_fail_message() {
  local scout_detail="$1" restriction="$2" reference="$3" ref_verdict="$4" ref_detail="$5"
  if [ -n "$restriction" ] && [ "$ref_verdict" != "pass" ]; then
    echo "web_search BROKEN for scout (${scout_detail}) and deny-free reference '${reference}' was ${ref_verdict} (${ref_detail}) — scout's ${restriction} cannot be confirmed as the cause"
  else
    echo "web_search BROKEN for scout (${scout_detail}) and NO tool policy explains it — not attributable to a restriction"
  fi
}
