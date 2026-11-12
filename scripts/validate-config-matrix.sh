#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# validate-config-matrix.sh
#
# Pin the workload-driven model + thinking matrix invariants
# established in PR #220 so they cannot silently regress.
#
# Each check encodes a rule that, if broken, has historically
# caused a production incident:
#
#   - Agent missing thinkingDefault, or thinkingDefault == "off":
#     2026-04-28 ops batch ran a bash for-loop with thinkingLevel
#     "off" → BORDERLINE-flag for every credit ID, zero browser
#     calls.
#
#   - Claude 4.x model declared reasoning:false in the project
#     registry while upstream pi-ai catalog says reasoning:true:
#     resolveThinkingDefaultForModel returns "off" for any agent
#     without an explicit thinkingDefault → re-creates the 04-28
#     incident shape.
#
#   - agents.defaults.thinkingDefault unset on a profile:
#     a future agent added without per-agent thinkingDefault
#     inherits runtime "off" → same as above.
#
# Usage:  validate-config-matrix.sh [config.json ...]
#         (no args → checks openclaw-main.json, openclaw-edge.json,
#          cron-jobs.json from CWD)
# Exit:   0 clean, 1 invariant violated, 2 arg/dependency error
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "validate-config-matrix: jq is required but not on PATH" >&2
  exit 2
fi

PROFILES=()
CRON=""
if (( $# == 0 )); then
  PROFILES=(openclaw-main.json openclaw-edge.json)
  CRON="cron-jobs.json"
else
  for f in "$@"; do
    case "$f" in
      *cron-jobs.json) CRON="$f" ;;
      *openclaw-*.json) PROFILES+=("$f") ;;
      *)
        echo "validate-config-matrix: unrecognised file (expected openclaw-*.json or cron-jobs.json): $f" >&2
        exit 2 ;;
    esac
  done
fi

# Allowed thinking enum (must match openclaw schema's ThinkLevel).
ALLOWED_LEVELS='["off","minimal","low","medium","high","xhigh","adaptive"]'
# Stricter set for thinkingDefault on agents — never silently "off".
AGENT_THINKING_LEVELS='["minimal","low","medium","high","xhigh","adaptive"]'

fail=0
# ${PROFILES[@]+...} guard: PROFILES may be empty (e.g. cron-jobs.json passed
# alone) and bash 3.2 errors on "${empty[@]}" under `set -u`.
# The one metered fallback every surface uses (see checks 5 and 6b).
REQUIRED_AGENT_FALLBACK="${REQUIRED_AGENT_FALLBACK:-openrouter/deepseek/deepseek-v4.1-flash-1017}"

for cfg in ${PROFILES[@]+"${PROFILES[@]}"}; do
  if [[ ! -f "$cfg" ]]; then
    echo "validate-config-matrix: skip (not found): $cfg" >&2
    continue
  fi
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    echo "ERROR: $cfg is not valid JSON" >&2
    fail=1
    continue
  fi

  # 0b. gateway.auth.mode must be set and not "none". The gateways listen on
  #     0.0.0.0 (bind:"lan") BY DESIGN: the in-cluster Intercom -> Caroline path
  #     reaches them on 10.0.0.8, so loopback is not an option. That makes token
  #     auth the only thing between the pod network and the Control UI's RPC
  #     layer -- an auth.mode of "none" (or an absent key) would be an
  #     unauthenticated admin API reachable from every pod in the cluster. This
  #     deliberately does NOT gate `bind`: "lan" is the required value.
  authv=$(jq -r '.gateway.auth.mode // "MISSING"' "$cfg")
  if [[ "$authv" == "none" || "$authv" == "MISSING" ]]; then
    echo "ERROR: $cfg gateway.auth.mode must not be none/absent (was: $authv)" >&2
    fail=1
  fi

  # 1. Every agent in agents.list[] has thinkingDefault, none "off".
  bad=$(jq -r --argjson allowed "$AGENT_THINKING_LEVELS" '
    .agents.list // []
    | .[]
    | (.thinkingDefault // "MISSING") as $t
    | select(($allowed | index($t)) == null)
    | .id + " (thinkingDefault=" + ($t | tostring) + ")"
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    while IFS= read -r line; do
      echo "ERROR: $cfg agent missing/invalid thinkingDefault: $line" >&2
    done <<< "$bad"
    fail=1
  fi

  # 2. agents.defaults.thinkingDefault must be set (not "off").
  defv=$(jq -r '.agents.defaults.thinkingDefault // "MISSING"' "$cfg")
  if [[ "$defv" == "MISSING" || "$defv" == "off" ]]; then
    echo "ERROR: $cfg agents.defaults.thinkingDefault must be set (was: $defv) — prevents silent runtime fallback to off for any future agent without an explicit thinkingDefault" >&2
    fail=1
  fi
  if ! jq -en --argjson allowed "$ALLOWED_LEVELS" --arg v "$defv" \
       '$allowed | index($v) != null' >/dev/null 2>&1; then
    echo "ERROR: $cfg agents.defaults.thinkingDefault not in allowed set: $defv" >&2
    fail=1
  fi

  # 3. Claude 4.x models with reasoning declared must have reasoning=true.
  #    (Upstream pi-ai catalog declares true; project must agree to keep
  #    resolveThinkingDefaultForModel from returning "off".)
  #    Models live under the openrouter provider as anthropic/claude-* now.
  bad=$(jq -r '
    .models.providers.openrouter.models // []
    | .[]
    | select(
        ((.id // "") | test("^anthropic/claude-(opus|sonnet|haiku|4\\.[567])"))
        and (.reasoning != true)
      )
    | "  - " + (.id // "<no-id>") + " (reasoning=" + ((.reasoning // "missing") | tostring) + ")"
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    echo "ERROR: $cfg has Claude 4.x models with reasoning != true (must match upstream pi-ai catalog):" >&2
    echo "$bad" >&2
    fail=1
  fi

  # 6. Empty-completion fallback safety: in every agent model.fallbacks chain,
  #    every entry EXCEPT the last must be a GPT-5-family model. openclaw only
  #    treats an empty/0-token completion as a failure-that-cascades for GPT-5
  #    models (isGpt5ModelId gate in result-fallback-classifier); a non-GPT-5
  #    model in a non-final position that returns an empty completion is scored
  #    candidate_succeeded and silently STOPS the chain instead of advancing to
  #    the stronger model behind it (2026-06-08 @CMO incident, PR #450).
  #    GPT id pattern: (^|[/:])gpt-[56]([.-]|$), so openrouter/openai/gpt-5.4-mini,
  #    openai/gpt-5.5 and openrouter/openai/gpt-6-luna qualify; gemini / haiku
  #    / sonnet / opus do not. openclaw's own isGpt5ModelId is /gpt-5/ only, but
  #    on the pinned @openclaw/codex 2026.8.35 the fallback classifier
  #    (result-fallback-classifier) no longer consults it — any empty result
  #    cascades (MUS-5128) — so gpt-6 is safe here; this gate stays as a belt.
  #    Scope: agent text `model` chains only — NOT
  #    imageModel (separate path; gpt-5.4-mini is not an image model). A non-GPT-5
  #    *primary* (e.g. cmo on opus-4.7 by choice) keeps an unavoidable
  #    empty-swallow residual that the cron-health watchdog covers; this gate
  #    enforces only the fallback positions.
  bad=$(jq -r '
    ( [ {id: "agents.defaults", fb: (.agents.defaults.model.fallbacks // [])} ]
      + [ (.agents.list // [])[] | {id: .id, fb: (.model.fallbacks // [])} ] )
    | .[]
    | .id as $id | .fb as $fb | ($fb | length) as $n
    | select($n > 1)
    | range(0; $n - 1) as $i
    | $fb[$i] as $m
    | select(($m | test("(^|[/:])gpt-[56]([.-]|$)"; "i")) | not)
    | $id + " fallback[" + ($i | tostring) + "]=" + $m
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    while IFS= read -r line; do
      echo "ERROR: $cfg non-GPT-5 model in a non-final fallback position (empty completions will NOT cascade — openclaw isGpt5ModelId gate): $line" >&2
    done <<< "$bad"
    fail=1
  fi

  # 6b. ONE model chain, fleet-wide (captain 2026-11-03): every agent turn —
  #     agents.defaults and every agents.list[] override — gets the subscription
  #     first and EXACTLY ONE metered fallback, the same shared DeepSeek tier
  #     scripts/lib/model_chain.py uses. Anything else re-opens the pre-2026-11
  #     behaviour where a subscription outage silently upgraded agent turns onto
  #     paid OpenRouter frontier models (gpt-6-luna, then claude-haiku).
  #     Enforced as an exact match on purpose: a "better" fallback added here is a
  #     spend decision, not a config tweak, so it must fail CI and be argued for.
  #     The PRIMARY is left free (ceo/cmo/scout run luna by choice); only the
  #     fallback list is pinned. model-chain-watchdog pages when the fleet
  #     actually rides this tier, so a uniform config never means silent unbounded
  #     spend.
  bad=$(jq -r --arg fb "$REQUIRED_AGENT_FALLBACK" '
    ( [ {id: "agents.defaults", fb: (.agents.defaults.model.fallbacks // [])} ]
      + [ (if (.agents.entries | type) == "object"
           then (.agents.entries | to_entries[] | {id: .key, fb: (.value.model.fallbacks // [])})
           else ((.agents.list // [])[] | {id: (.id // "<no-id>"), fb: (.model.fallbacks // [])}) end) ] )
    | .[]
    | select((.fb | length) != 1 or .fb[0] != $fb)
    | .id + " fallbacks=" + (.fb | tojson)
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    while IFS= read -r line; do
      echo "ERROR: $cfg agent model chain is not the one uniform chain (primary = the subscription, fallbacks = [\"$REQUIRED_AGENT_FALLBACK\"] only): $line" >&2
    done <<< "$bad"
    fail=1
  fi

  # 7. web_search must have a well-formed backend that does not self-disable. On
  #    openclaw 7.1, native codex search (tools.web.search.openaiCodex.enabled — the
  #    codex model calling OpenAI's own search in-thread, key-free via the ChatGPT
  #    OAuth the fleet already runs) and a MANAGED provider (tools.web.search.provider)
  #    are MUTUALLY EXCLUSIVE: setting a provider flips every codex thread OFF native
  #    onto a bounded managed worker. In hydra that worker has no auth (empty
  #    CODEX_HOME, placeholder OPENAI_API_KEY) so it fails "Reconnecting..." — setting
  #    provider:"codex" on this native-search fleet DISABLED web_search fleet-wide
  #    (incident 2026-07-17, PR #695). So the invariants are:
  #      - reject BOTH openaiCodex.enabled and provider set at once (self-disabling);
  #      - reject enabled-with-no-backend (neither native nor a provider);
  #      - native-only (openaiCodex.enabled, NO provider) is the SUPPORTED shape → ok;
  #      - a managed provider (native off) must be a recognized id ($KNOWN, since a
  #        static check can't read the live plugin registry — catches typos like
  #        "codxe" that resolve zero candidates), allowlisted, not entry-disabled,
  #        and — unless it is the key-free "codex" — carry a plugins.entries block +
  #        apiKey.
  #    Extend $KNOWN when adopting a new provider. NOTE: this deliberately leaves the
  #    #607 gap open — a non-codex fallback turn has no search — which is the accepted
  #    status quo until upstream fixes the managed bounded-turn auth path.
  ws_err=$(jq -r '
    if (.tools.web.search.enabled // false) != true then empty
    else
      (.tools.web.search.provider // "") as $p
      | ((.tools.web.search.openaiCodex.enabled // false) == true) as $native
      | (.plugins.allow // []) as $allow
      | (.plugins.entries // {}) as $entries
      | (["codex","perplexity"]) as $known
      | if   $native and $p != ""         then "tools.web.search sets BOTH openaiCodex.enabled and provider:\"" + $p + "\" — mutually exclusive on openclaw 7.1: a managed provider DISABLES native in-thread codex search (incident 2026-07-17, #695). Use native (drop provider) OR managed (drop openaiCodex.enabled), not both."
        elif (($native | not) and $p == "") then "tools.web.search.enabled but has no backend — set openaiCodex.enabled:true (native, key-free codex OAuth) or a managed provider"
        elif $p == ""                     then empty
        elif ($known | index($p)) == null then "provider \"" + $p + "\" is not a recognized web-search provider id (known: " + ($known | join(", ")) + ") — a typo or invented id resolves zero candidates at runtime"
        elif ($allow | index($p)) == null then "provider \"" + $p + "\" is not in plugins.allow (closed allowlist)"
        elif $entries[$p].enabled == false then "provider \"" + $p + "\" entry is disabled (plugins.entries[\"" + $p + "\"].enabled=false — the plugin will not register)"
        elif $p == "codex"                then empty
        elif $entries[$p] == null         then "provider \"" + $p + "\" has no plugins.entries[\"" + $p + "\"] block"
        elif ($entries[$p].config.webSearch.apiKey // $entries[$p].config.apiKey // .tools.web.search.apiKey // null) == null then "provider \"" + $p + "\" has no apiKey credential (config.webSearch.apiKey / config.apiKey / tools.web.search.apiKey all absent)"
        else empty end
    end
  ' "$cfg")
  if [[ -n "$ws_err" ]]; then
    echo "ERROR: $cfg web_search misconfigured: $ws_err" >&2
    fail=1
  fi
  # 8. No tool policy may restrict the codex harness's NATIVE tool surface.
  #    On openclaw >= 2026.8 the codex harness declares
  #    conversationToolPolicySupport:"exact", and openclaw then classifies an
  #    agent's policy via toolPolicyRestrictsHarnessNativeTools()
  #    (dist/selection-Bge6N4vD.js): the policy is RESTRICTED if any deny entry
  #    is `!isKnownCoreToolId(name) || !safeDenyToolNames.has(name)`, or if
  #    `allow` is a non-empty list without "*" (toolPolicyRestrictsTools, in
  #    dist/tool-policy-Dh52Cnoz.js). A restricted policy sets
  #    pluginHarnessToolPolicyRestricted, and the FIRST line of
  #    shouldEnableCodexAppServerNativeToolSurface()
  #    (@openclaw/codex dist/dynamic-tools-*.js) returns false on it. That drops
  #    the whole CODEX_RING_ZERO feature set for the agent -- shell_tool,
  #    unified_exec, standalone_web_search, web_search_request, multi_agent,
  #    skill_search, memories, image_generation, browser_use, code_mode,
  #    view_image -- and pushes resolveCodexWebSearchPlan() off "native-hosted"
  #    onto "managed". With no managed provider configured (the SUPPORTED shape,
  #    enforced by check #7 above) runWebSearch() then throws
  #    "web_search is disabled or no provider is available."
  #
  #    Incident 2026-09-10: the 2026.8.2 cutover turned the long-standing
  #    `tools.deny: ["sentry__*"]` (registered globally, denied to every agent
  #    but cto/qa) into exactly this kill switch. Scout lost web search mid-task
  #    and told a user its "web research provider is disabled/unavailable"; five
  #    other agents were silently downgraded with nothing in the journal naming
  #    the cause. UPGRADE-2026.8.1.md Gate N looked straight at this interaction
  #    and closed it on "the refusal disappears" -- true, and the wrong
  #    assertion: declaring "exact" replaces a LOUD refusal with a SILENT
  #    capability downgrade.
  #
  #    The safe set is a CLOSED list in the codex plugin
  #    (CODEX_TOOL_POLICY_SAFE_DENY_NAMES). MCP tool ids and globs can never
  #    appear in it, so an MCP tool cannot be denied per-agent without paying
  #    the whole native surface -- and MCP servers are global in 2026.8.2
  #    (canonicalizeConfiguredMcpServer accepts no agent-scoping key), so there
  #    is no config-level way to hide one from a subset of agents. Re-verify
  #    this list on every openclaw/codex bump.
  SAFE_DENY='["web_fetch","x_search","memory_search","memory_get","dashboard","canvas","show_widget","message","heartbeat_respond","automations","gateway","skill_workshop","image_generate","music_generate","video_generate","tts"]'
  #    Deliberate exceptions, "<config-basename>:<agentId>:<tool>". Each one
  #    ACCEPTS a restricted codex harness for that agent because the deny buys
  #    something worth more than the native surface. Kept inline rather than in
  #    a side file.
  #      - openclaw-edge.json:support:exec -- Caroline must not have a shell
  #        (#408). Losing codex-native shell_tool/unified_exec with it is defense
  #        in depth. Be honest about the rest of the bill though: she ALSO loses
  #        skill_search, memories and native web search, and that part is pure
  #        cost. It is accepted only because openclaw offers no per-agent knob
  #        for the native surface -- an upstream gap that, unlike every other
  #        workaround in this repo, has no issue number to cite yet. File one and
  #        reference it here so this has an expiry condition.
  #      - openclaw-main.json:operations:web_search -- credit-verification must
  #        not free-text search. Note this deny is doing MORE than the
  #        muso-credit-verification-enforcer plugin's redirect-web-search hook:
  #        that hook is a `before_tool_call`, so it can only intercept the
  #        openclaw tool path, while codex-native standalone_web_search runs
  #        inside the codex app-server. The deny closes the native path too --
  #        precisely BECAUSE it restricts the harness. So if `web_search` ever
  #        joins the safe list, do NOT delete this exception as redundant: that
  #        would silently reopen free-text search for the agent that must not
  #        have it. The cost is real and unpriced elsewhere: operations is a
  #        codex agent and stays permanently restricted, losing skill_search,
  #        memories, image_generation and browser_use too.
  #      - openclaw-edge.json:support:<the 12 verification/merge tools> -- captain 2026-10-28 12:1xZ /
  #        12:3xZ: Caroline holds no verification or merge capability. Two reads left this list on
  #        2026-11-12 (ai-support-quality-v1): credit_verification_check and profile_claim_status fail
  #        closed on the signed-in contact and return that customer's own rows only, and they are the
  #        only writer of the open_request fact the output guard needs. A stale row for either fails
  #        this check, so re-denying them means restoring their rows here too. These are plugin
  #        tools (support-tools), not codex-native ones, and `support` already runs the restricted
  #        harness because of `exec` above, so they add no further native-surface cost. They are listed
  #        here so a deploy keeps the live deny list (scripts/lib/assert-support-deny.sh).
  #      - openclaw-main.json:scout:{exec,process,lobster,nodes,computer,terminal} -- security-arch-fable-s1
  #        [key=exec-lever] 2026-11-01: an agent that READS untrusted text never holds a shell; scout reads the open
  #        web, so it goes first. The bill is the same as Caroline's and it is LARGE for scout: the restricted
  #        harness turns native web_search / web_run OFF (@openclaw/codex resolveCodexWebSearchPlan: restricted ->
  #        kind=managed; hydra configures no managed provider, check #7), plus skill_search/memories/MCP. Scout keeps
  #        web_fetch, company_finder_* and the support-tools lookups. lobster is denied because its `exec --shell`
  #        steps spawn with no tool-policy check. The registry + rules live in policies/agent-exec-policy.json and
  #        scripts/check-agent-exec-policy.py; revert = drop these six rows and scout's deny together.
  #      - openclaw-main.json:finance:{exec,process,lobster,nodes,computer,terminal} -- firstmate ruling
  #        [key=exec-posture-lapsed] 2026-11-09: both dated exec exceptions expired on 2026-11-08 and the fail-safe's
  #        first duty is to resolve an expired posture to DENIED. finance was left denied deliberately and is
  #        unaffected by the renewal below. State the bill plainly, because it is the whole point of the ruling:
  #        finance has no Stripe reporting; and because `exec` is outside the safe-deny set, it ALSO loses
  #        codex-native web_search / skill_search / memories / MCP. The row exists so a deploy keeps the deny; the
  #        route back is a captain-decided change to check-agent-exec-policy.py's rules (a RE-GRANT to a non-ops
  #        agent is rejected there by design, so it can never be flipped back by editing data).
  #      - openclaw-main.json:qa:{process,lobster,nodes,computer,terminal} -- firstmate ruling
  #        [key=exec-posture-renew-qa] 2026-11-09: qa was re-granted `exec` for 31 days through the reviewed
  #        allowlist in check-agent-exec-policy.py (REGRANT_ALLOWLIST), so `qa:exec` is NO LONGER an exception and
  #        its row here is gone -- a stale row would fail this check rather than linger. The five remaining denies
  #        are the deliberate narrowing: qa may run the qa-*.sh wrappers and ordinary shell, but holds no
  #        process-spawn, lobster, nodes, computer or terminal surface. Because they are outside the safe-deny set
  #        qa still runs the restricted harness, so it still has no native web_search / skill_search / memories /
  #        MCP; the PR body enumerates what replaces each of those. Revert = restore `exec` to qa's deny list and
  #        delete the REGRANT_ALLOWLIST claim.
  HARNESS_DENY_EXCEPTIONS='["openclaw-main.json:scout:exec","openclaw-main.json:qa:process","openclaw-main.json:qa:lobster","openclaw-main.json:qa:nodes","openclaw-main.json:qa:computer","openclaw-main.json:qa:terminal","openclaw-main.json:finance:exec","openclaw-main.json:finance:process","openclaw-main.json:finance:lobster","openclaw-main.json:finance:nodes","openclaw-main.json:finance:computer","openclaw-main.json:finance:terminal","openclaw-main.json:scout:process","openclaw-main.json:scout:lobster","openclaw-main.json:scout:nodes","openclaw-main.json:scout:computer","openclaw-main.json:scout:terminal","openclaw-edge.json:support:exec","openclaw-main.json:operations:web_search","openclaw-edge.json:support:credits_verify","openclaw-edge.json:support:profiles_claim_self","openclaw-edge.json:support:profiles_consolidate","openclaw-edge.json:support:profile_credits_status","openclaw-edge.json:support:dedupe_check","openclaw-edge.json:support:remove_credits","openclaw-edge.json:support:credit_status_lookup","openclaw-edge.json:support:document_intake","openclaw-edge.json:support:merge_request_intake","openclaw-edge.json:support:credit_trust_handoff","openclaw-edge.json:support:merge_intake","openclaw-edge.json:support:proof_on_file"]'

  #    REACH OF THIS GATE, stated honestly: openclaw classifies over
  #    explicitPolicies = [globalPolicy, globalProviderPolicy, agentPolicy,
  #    agentProviderPolicy, groupPolicy, senderPolicy, sandboxPolicy,
  #    subagentPolicy, inheritedToolPolicy, runtimeToolPolicyForInheritance,
  #    requestedToolPolicy]. Only the first and third are expressible in a repo
  #    config, and those are what this check reads; the rest are runtime-derived
  #    and invisible to a static gate. Note `tools.alsoAllow` is deliberately NOT
  #    checked -- it is absent from explicitPolicies (it only reaches
  #    runtimePolicies via mergeAlsoAllowPolicy), so hydra's global
  #    alsoAllow:["lobster"] does not restrict anything. Verified in
  #    dist/selection-Bge6N4vD.js on 2026.8.2; re-check on bump.
  #
  #    Agent shape: the repo configs use `.agents.list[]`. On >=2026.8 the doctor
  #    ALSO understands a keyed `.agents.entries{}` form and logs "Moved
  #    agents.list to keyed agents.entries" at load -- but that normalization is
  #    IN MEMORY: verified 2026-09-10 on 2026.8.2 that both live on-disk configs
  #    (/root/.openclaw-{main,edge}/openclaw.json) are still `list`. So the
  #    entries branch below is FORWARD-DEFENSIVE, not evidence that anything is
  #    currently mis-reading its config -- checks #1/#2/#6 and
  #    scripts/lib/ensure-sentry-mcp.sh all still read `.agents.list` and are all
  #    still correct today. Read both anyway: if the shape ever does land on
  #    disk, a gate that reads the wrong one finds zero agents and passes
  #    silently, which is the exact failure this check exists to prevent. If
  #    NEITHER shape is present, fail loud rather than "pass" -- an unparseable
  #    config is a finding, not a clean bill of health. An EMPTY shape
  #    (`entries: {}` / `list: []`) is the same finding wearing a parseable hat:
  #    zero agents is zero evidence, so it fails too rather than reporting clean.
  shape=$(jq -r '
    if (.agents.entries | type) == "object" then (if (.agents.entries | length) > 0 then "entries" else "EMPTY" end)
    elif (.agents.list | type) == "array" then (if (.agents.list | length) > 0 then "list" else "EMPTY" end)
    else "NONE" end
  ' "$cfg")
  if [[ "$shape" == "NONE" || "$shape" == "EMPTY" ]]; then
    if [[ "$shape" == "NONE" ]]; then
      echo "ERROR: $cfg has neither .agents.list[] nor .agents.entries{} — cannot evaluate tool policies (refusing to report a config it cannot parse as clean)" >&2
    else
      echo "ERROR: $cfg declares an agents shape with ZERO agents — nothing was evaluated, so this is a finding, not a clean bill of health" >&2
    fi
    fail=1
  else
    bad=$(jq -r --argjson safe "$SAFE_DENY" --argjson exc "$HARNESS_DENY_EXCEPTIONS" \
                 --arg base "$(basename "$cfg")" --arg shape "$shape" '
      # Global tools.* counts too: it merges into the same explicitPolicies set
      # openclaw classifies, so a global deny restricts EVERY agent at once.
      # agents.defaults.tools is the SAME hazard by a quieter route: openclaw
      # resolves every agent key as
      # `resolveAgentConfig(cfg, agentId)?.<key> ?? cfg.agents.defaults.<key>`
      # (the resolution this repo already relies on in
      # scripts/check-soul-bootstrap-size.sh and scripts/memory-health-check.sh),
      # so a deny parked there applies to every agent that has no `tools` of its
      # own -- invisible to a gate that reads only `.tools` and `.agents.*.tools`.
      # WHY THIS IS A GENERIC WALK AND NOT A LIST OF KNOWN KEYS.
      # openclaw classifies over `explicitPolicies`
      # (dist/selection-Bge6N4vD.js:746-758): globalPolicy, globalProviderPolicy,
      # agentPolicy, agentProviderPolicy, groupPolicy, senderPolicy,
      # sandboxPolicy, subagentPolicy, inheritedToolPolicy,
      # runtimeToolPolicyForInheritance, requestedToolPolicy. ANY of them
      # containing a non-core-safe deny (or a narrowing allow) restricts the
      # codex harness and kills its native tool surface.
      #
      # Enumerating the config keys behind those holders one at a time is how
      # this check got caught twice: round 1 read only `.tools.deny`, round 2
      # added `byProvider` (globalProviderPolicy/agentProviderPolicy), and review
      # immediately found `toolsBySender` (senderPolicy) next, with
      # channel group `tools` (groupPolicy) behind it. Each fix closed one
      # holder and left the next one open.
      #
      # So this no longer enumerates. It walks the WHOLE config for any object
      # carrying a `deny` or `allow` array whose JSON path contains a `tools`
      # segment, and evaluates every one. That covers all four
      # currently-reachable holders, the channel-group and sender routes, and
      # any FUTURE key openclaw adds under a tools subtree, without another
      # round trip. The `tools`-segment condition is what keeps `plugins.allow`
      # (a plugin allowlist, not a tool policy) out of scope — verified: a naive
      # "any object with deny/allow" walk flags it.
      #
      # SCOPE, stated honestly: config-expressible holders only.
      # inheritedToolPolicy, runtimeToolPolicyForInheritance and
      # requestedToolPolicy are runtime-derived and cannot appear in a repo
      # config, so a static gate cannot see them; sandboxPolicy and
      # subagentPolicy are likewise resolved outside these files today. If any
      # of those ever gains a config surface it will land under a `tools` path
      # and this walk picks it up automatically.
      #
      # $shape is passed in rather than re-tested here so the shape decision has
      # exactly ONE authority (the probe above) and the two cannot drift.
      . as $root
      | [ paths(type == "object" and ((.deny | type) == "array" or (.allow | type) == "array")) ]
      | map(select(any(.[]; . == "tools")))
      | map({ path: ., policy: (. as $pp | $root | getpath($pp)) })
      | map(. + { id:
          ( .path as $pp
            | if ($pp[0] == "agents") and ($pp[1] == "list")
              then ($root.agents.list[$pp[2]].id // ("agents.list[" + ($pp[2] | tostring) + "]"))
              elif ($pp[0] == "agents") and ($pp[1] == "entries") then $pp[2]
              elif ($pp[0] == "agents") and ($pp[1] == "defaults") then "<agents.defaults>"
              elif ($pp[0] == "tools") then "<global>"
              else "<" + ($pp[0] | tostring) + ">" end ) })
      | map({ key: (.id + " @ " + (.path | join("."))), value: .policy, id: .id }) as $policies
      | ( $policies[]
          | .key as $label | .id as $id | .value as $p
          | ( ($p.deny // [])[] as $d
              | select(($safe | index($d)) == null
                       and ($exc | index($base + ":" + $id + ":" + $d)) == null)
              | "  - " + $label + ": deny \"" + $d + "\" is not in CODEX_TOOL_POLICY_SAFE_DENY_NAMES" ),
            ( ($p.allow // []) | select(length > 0 and (index("*") == null))
              | "  - " + $label + ": allow " + tostring + " is a narrowing allow-list (no \"*\")" ) ),
        # Staleness, borrowed from the .skill-workspace-divergence.txt precedent:
        # that file fails CI when an entry no longer diverges, so a reconciled
        # exception cannot linger. Without the same rule here, deleting a deny
        # would leave its exception behind as a standing pre-authorisation for a
        # re-add that nobody reviews. Only exceptions naming THIS config are
        # judged -- the others are simply not applicable to this file.
        ( $exc[]
          | select(startswith($base + ":"))
          | . as $e
          | ($e | split(":")) as $parts
          | if ($parts | length) != 3
            then "  - MALFORMED EXCEPTION \"" + $e + "\": expected <config>:<agent>:<tool>"
            else $parts[1] as $xid | $parts[2] as $xtool
              | select([ $policies[] | select(.id == $xid) | (.value.deny // []) | index($xtool) ]
                       | map(select(. != null)) | length == 0)
              | "  - STALE EXCEPTION \"" + $e + "\": " + $xid + " no longer denies \""
                + $xtool + "\" — drop it from HARNESS_DENY_EXCEPTIONS"
            end )
    ' "$cfg")
    if [[ -n "$bad" ]]; then
      echo "ERROR: $cfg has tool policies that RESTRICT the codex harness and silently disable its native tool surface (web_search, shell_tool, image_generation, browser_use, skill_search, memories, ...) — incident 2026-09-10:" >&2
      echo "$bad" >&2
      echo "  Fix: drop the entry, or add \"<config>:<agent>:<tool>\" to HARNESS_DENY_EXCEPTIONS with a comment saying why losing the native surface is acceptable for that agent." >&2
      fail=1
    fi
  fi

  # 9. Every agent model ref must be declared in THIS file's own catalog
  #    (models.providers.<provider>.models[].id). An undeclared ref does not
  #    refuse at runtime: openclaw synthesizes a model with default metadata
  #    (text-only, 200k context), so an image sent to a fallback is silently
  #    mis-handled (MUS-8506 Row D; QA's mutation on hydra#1176 set an
  #    undeclared openai/gpt-7-sol and every gate exited 0).
  #    Ref form is <provider>/<id>; split on the FIRST slash only, because
  #    openrouter ids are themselves namespaced (openrouter/google/gemini-3.5-flash).
  #    The prefix resolves to a models.providers key, else to the single
  #    provider whose agentRuntime.id equals it. The runtime hop is deliberate:
  #    imageModel MUST use the codex/ prefix (openai/<id> as an imageModel hits
  #    the HTTP media-understanding route and TypeErrors,
  #    docs/lessons/openclaw-and-codex.md:617), and the codex -> openai mapping
  #    lives in the config (models.providers.openai.agentRuntime.id), so do not
  #    collapse it into a hardcoded codex->openai literal. Zero or several
  #    matching providers FAIL loud rather than pick one.
  #    Invariant: gate the LITERAL imageModel prefix (before resolution), because
  #    codex/ and openai/ resolve to the same provider; a declared openai/<id>
  #    imageModel must still FAIL, expected prefix = that provider's agentRuntime.id.
  #    A provider-key imageModel prefix is accepted only for an HTTP provider (baseUrl)
  #    with NO agentRuntime.id; the runtime arm is checked first, so a provider with
  #    both still refuses. No agentRuntime.id and no baseUrl refuses too (never fail open).
  #    Scope: agents.defaults + per-agent model/imageModel, primary and
  #    fallbacks, walking the same shape check 8 picks (keyed agents.entries{}
  #    when present, else agents.list[]). Reads only .models.providers.
  bad=$(jq -r '
    def refs($root; $m):
      if ($m | type) == "object" then
        ( if ($m.primary | type) == "string"
          then [{path: ($root + ".primary"), ref: $m.primary}] else [] end )
        + [ ($m.fallbacks // []) | to_entries[] | select(.value | type == "string")
            | {path: ($root + ".fallbacks[" + (.key | tostring) + "]"), ref: .value} ]
      elif ($m | type) == "string" then [{path: $root, ref: $m}]
      else [] end;
    (.models.providers // {}) as $p
    | ( refs("agents.defaults.model"; .agents.defaults.model)
        + refs("agents.defaults.imageModel"; .agents.defaults.imageModel)
        + [ (if (.agents.entries | type) == "object"
             then (.agents.entries | to_entries[] | {shape: "entries", id: .key, a: .value})
             else ((.agents.list // [])[] | {shape: "list", id: (.id // "<no-id>"), a: .}) end)
            | ("agents." + .shape + "[" + .id + "]") as $root
            | refs($root + ".model"; .a.model),
              refs($root + ".imageModel"; .a.imageModel) ]
          | flatten )
    | .[]
    | .path as $path | .ref as $ref
    | ($ref | index("/")) as $s
    | if $s == null or $s == 0 then
        "  - " + $path + " = " + $ref + ": malformed model ref (expected <provider>/<id>)"
      else
        $ref[:$s] as $pre | $ref[$s + 1:] as $id
        | ( if ($p | has($pre)) then {prov: $pre}
            else ( [ $p | to_entries[] | select(.value.agentRuntime.id == $pre) | .key ] ) as $m
              | if ($m | length) == 0
                then {err: ("unknown model-ref prefix \"" + $pre + "\" (not a models.providers key and not any provider'\''s agentRuntime.id)")}
                elif ($m | length) > 1
                then {err: ("ambiguous runtime prefix \"" + $pre + "\" matches " + ($m | length | tostring) + " providers")}
                else {prov: $m[0]} end
            end ) as $r
        | ( if ($path | test("\\.imageModel(\\.|$)")) and ($p | has($pre)) and (($p[$pre].agentRuntime.id | type) == "string")
            then "  - " + $path + " = " + $ref + ": imageModel must use the runtime prefix \"" + $p[$pre].agentRuntime.id + "/\", not the provider key \"" + $pre + "/\" (image input takes the HTTP media-understanding route and TypeErrors)"
            elif ($path | test("\\.imageModel(\\.|$)")) and ($p | has($pre)) and (($p[$pre].baseUrl | type) != "string")
            then "  - " + $path + " = " + $ref + ": models.providers." + $pre + " declares neither agentRuntime.id nor baseUrl, so an image cannot be routed (image input would take the HTTP media-understanding route and TypeError); declare baseUrl, or use the runtime prefix"
            else empty end ),
          ( if $r.err then "  - " + $path + " = " + $ref + ": " + $r.err
            elif any($p[$r.prov].models[]?; .id == $id) then empty
            else "  - " + $path + " = " + $ref + ": \"" + $id + "\" is not declared in models.providers." + $r.prov + ".models[].id (openclaw would synthesize text-only / 200k default metadata)"
            end )
      end
  ' "$cfg")
  if [[ -n "$bad" ]]; then
    echo "ERROR: $cfg has agent model refs not declared in its own models.providers catalog:" >&2
    echo "$bad" >&2
    fail=1
  fi
done

# 4. Cron payload thinking values must be in the allowed enum.
if [[ -n "$CRON" && -f "$CRON" ]]; then
  if ! jq empty "$CRON" >/dev/null 2>&1; then
    echo "ERROR: $CRON is not valid JSON" >&2
    fail=1
  else
    bad=$(jq -r --argjson allowed "$ALLOWED_LEVELS" '
      .jobs // []
      | .[]
      | .payload.thinking as $t
      | select($t != null and ($allowed | index($t)) == null)
      | .name + " (thinking=" + ($t | tostring) + ")"
    ' "$CRON")
    if [[ -n "$bad" ]]; then
      while IFS= read -r line; do
        echo "ERROR: $CRON cron job has invalid thinking value: $line" >&2
      done <<< "$bad"
      fail=1
    fi

    # 5. Every cron payload must run on codex (openai/gpt-6-sol) with EXACTLY ONE
    #    fallback: the metered DeepSeek tier. This pins the captain's 2026-11-03
    #    model-chain ruling on the scheduled surface as well, and it supersedes
    #    the pre-2026-11 chain (gpt-6-luna hop, then claude-haiku backstop):
    #
    #      primary   openai/gpt-6-sol        the ChatGPT/Codex subscription, $0
    #      fallback  openrouter/deepseek/deepseek-v4.1-flash-1017
    #
    #    Why the old two-hop chain had to go: gpt-6-luna and claude-haiku are
    #    OpenRouter FRONTIER models, so a subscription outage silently upgraded
    #    every cron (and every agent turn) onto paid frontier inference — the
    #    exact spend the ruling exists to stop. DeepSeek 1017 is ~100x cheaper and
    #    is the tier the scripted user paths already use
    #    (scripts/lib/model_chain.py), so one order now holds fleet-wide.
    #
    #    Why a single non-GPT-5 fallback is safe HERE: check 6's GPT-5-family rule
    #    exists because openclaw scores a non-GPT-5 model's empty completion as
    #    candidate_succeeded, which stops the chain BEFORE a stronger model behind
    #    it. That failure mode needs a model BEHIND the non-GPT one. DeepSeek is
    #    the final entry, so nothing is lost: an empty completion from it is a
    #    dead end either way, and model-chain-watchdog pages on next=none.
    #    (On @openclaw/codex 2026.8.35 every empty result cascades regardless —
    #    MUS-5128 — so the family gate is a belt, not the mechanism.)
    #
    #    A cron on any other model, or with a longer/other chain, has silently
    #    re-opened paid frontier spend: fail loud instead.
    REQUIRED_CRON_MODEL="openai/gpt-6-sol"
    REQUIRED_CRON_FALLBACK1="openrouter/deepseek/deepseek-v4.1-flash-1017"
    #    Applies ONLY to agentTurn crons (the ones that invoke a model). A
    #    deterministic `command`/`script` cron runs an argv with no model call
    #    (payload.model is absent by design), so the fallback-chain rule is N/A;
    #    exempt anything whose payload.kind is not agentTurn. Missing kind is
    #    treated as agentTurn so a real model cron that forgets its model is
    #    still caught.
    bad=$(jq -r --arg m "$REQUIRED_CRON_MODEL" --arg fb1 "$REQUIRED_CRON_FALLBACK1" '
      .jobs // []
      | .[]
      | select((.payload.kind // "agentTurn") == "agentTurn")
      | (.payload.model // "MISSING") as $model
      | (.payload.fallbacks // []) as $fbs
      | select($model != $m or $fbs != [$fb1])
      | .name + " (model=" + ($model | tostring) + ", fallbacks=" + ($fbs | tojson) + ")"
    ' "$CRON")
    if [[ -n "$bad" ]]; then
      while IFS= read -r line; do
        echo "ERROR: $CRON cron job must be on $REQUIRED_CRON_MODEL with fallbacks=[\"$REQUIRED_CRON_FALLBACK1\"] and nothing else (one uniform model chain; see check 5's comment): $line" >&2
      done <<< "$bad"
      fail=1
    fi
  fi
fi

# 10. ZDR + precision floor on every production DeepSeek/GLM route (captain
#     2026-11-04: "we need [ZDR] ... only use the fastest cheapest ZDR deepseek
#     models ... protect our code"). Every openrouter deepseek/z-ai ref must
#     resolve to a catalog entry whose compat.openRouterRouting is the one ZDR
#     block (zdr true, data_collection deny, price sort, fp8/bf16/fp16 only,
#     max_price capped), no fireworks/ ref may survive, and every Python caller
#     that builds an OpenRouter body must send ZDR_ROUTING. The runtime half of
#     this rule is model_chain.validate_routing; this is the config half, because
#     the gateways' routing lives in JSON and a dropped `zdr` flag would
#     otherwise be invisible until a customer's document hit a lossy host.
#     Resolved from THIS script's directory, not CWD: the guard must run even
#     when the matrix is invoked from elsewhere with explicit config paths.
ZDR_GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-zdr-routing.py"
if [[ -f "$ZDR_GUARD" ]]; then
  if ! python3 "$ZDR_GUARD" ${PROFILES[@]+${PROFILES[@]}} ${CRON:+"$CRON"}; then
    echo "ERROR: ZDR routing guard failed (see scripts/check-zdr-routing.py)" >&2
    fail=1
  fi
else
  echo "ERROR: scripts/check-zdr-routing.py is missing — the ZDR guard cannot run" >&2
  fail=1
fi

if (( fail == 0 )); then
  echo "validate-config-matrix: all checks passed"
fi
exit $fail
