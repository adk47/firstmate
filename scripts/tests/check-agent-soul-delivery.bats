#!/usr/bin/env bats
# Tests for scripts/check-agent-soul-delivery.sh — the MUS-6635 recurrence guard
# for MUS-6600 (gpt-6 agents running with no AGENT_SOUL / <available_skills> /
# cron-mode text in the developer message the MODEL actually saw).
#
# Fixtures are synthetic codex rollouts built by mk_session() in the live node-8
# shape (agents/<id>/agent/codex-home/sessions/Y/M/D/rollout-*.jsonl). The
# "stripped" fixture is the live MUS-6600 shape: SOUL present in
# turn_context.collaboration_mode.settings.developer_instructions (the client
# record) but ABSENT from the model-visible first developer response_item.
# Slack is PATH-stubbed and MUSO_SLACK_ENV_FILE points at nothing, so the suite
# can never page #clio_devops.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-agent-soul-delivery.sh"

CRON_MARKER='This is an OpenClaw cron automation turn. Apply these instructions only to this scheduled job.'
DREAM_SENTINEL='__openclaw_memory_core_short_term_promotion_dream__'

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-fake-fixture' > "$MUSO_SLACK_ENV_FILE"  # reaches the PATH-stubbed muso only
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"; : > "$STUB_CALLS"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  MAIN="$TEST_TMPDIR/openclaw-main"; EDGE="$TEST_TMPDIR/openclaw-edge"
  mkdir -p "$MAIN/agents" "$EDGE/agents"
  export AGENT_SOUL_PROFILE_DIRS="$MAIN"   # tests that need edge add it
  export AGENT_SOUL_STATE_FILE="$TEST_TMPDIR/state"
  export AGENT_SOUL_LOCKFILE="$TEST_TMPDIR/lock"
  export AGENT_SOUL_SKIP_HOST_GUARD=1
  export AGENT_SOUL_MAX_AGE_HOURS=48
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# config <profile-dir> <agent-id>...   → openclaw.json with agents.list + defaults
config() {
  local dir="$1"; shift
  printf '%s\n' "$@" | jq -R '{id: .}' | jq -s '{agents: {defaults: {workspace: "/w"}, list: .}}' > "$dir/openclaw.json"
}

# mk_session <profile-dir> <agent> <name> <kind>
# kinds: compliant | stripped | stripped-no-ctx | lightweight-cron | dreaming-nomarker | cron-lostsoul |
#        cron-lostsoul-multiagent | cron-ok | cron-nomarker
# lightweight-cron is the LIVE MUS-8377 shape (13 Oct): the plugin-managed Memory Dreaming job
# (lightContext:true) -> sentinel in the [cron:] user turn, model-visible cron marker, no SOUL/skills,
# and NO "Lightweight bootstrap context" in session_meta.base_instructions (0 of 400 live rollouts
# carry it there; the string only lives in the cron tool's description under dynamic_tools).
mk_session() {
  local dir="$1" agent="$2" name="$3" kind="$4"
  local d="$dir/agents/$agent/agent/codex-home/sessions/2026/10/12"
  mkdir -p "$d"
  local f="$d/rollout-$name.jsonl"
  local soul="# AGENT_SOUL
You are $agent." skills="<available_skills>
<skill>x</skill>
</available_skills>"
  local base="You are a personal agent running inside OpenClaw."
  local perms="<permissions instructions>sandbox</permissions instructions>"
  local codex_tpl="<collaboration_mode># Collaboration Mode: Default</collaboration_mode>"
  local user_msg='hello' ctx_di="$soul $skills"
  local item0 items meta_bi="You are a personal agent."
  case "$kind" in
    compliant)        item0="$base $soul $skills" ;;
    stripped)         item0="$base"; items="$perms $codex_tpl" ;;
    cron-ok)          item0="$base $soul $skills $CRON_MARKER"; user_msg='[cron:1111 nightly] run it' ;;
    cron-nomarker)    item0="$base $soul $skills"; user_msg='[cron:1111 nightly] run it' ;;
    lightweight-cron) item0="$base"; items="$perms <collaboration_mode>$CRON_MARKER</collaboration_mode>"
                      user_msg="[cron:2222 Memory Dreaming Promotion] $DREAM_SENTINEL"; ctx_di="$CRON_MARKER" ;;
    dreaming-nomarker) item0="$base"; items="$perms $codex_tpl"
                      user_msg="[cron:2222 Memory Dreaming Promotion] $DREAM_SENTINEL"; ctx_di="$CRON_MARKER" ;;
    cron-lostsoul-multiagent) item0="$base"
                      items="$perms <multi_agent_role>You are \`/root\`, the primary agent</multi_agent_role> <collaboration_mode>$CRON_MARKER</collaboration_mode>"
                      user_msg='[cron:3333 nightly] go'; ctx_di="$CRON_MARKER" ;;
    cron-lostsoul)    item0="$base"; items="$perms <collaboration_mode>$CRON_MARKER</collaboration_mode>"
                      user_msg='[cron:3333 nightly] go'; ctx_di="$CRON_MARKER" ;;
    *) echo "bad kind $kind" >&2; return 1 ;;
  esac
  {
    jq -nc --arg bi "$meta_bi" '{type:"session_meta",payload:{id:"s",base_instructions:{text:$bi},dynamic_tools:[{name:"cron",description:"lightContext: Lightweight bootstrap context (skip full workspace context)"}]}}'
    jq -nc --arg di "$ctx_di" '{type:"turn_context",payload:{collaboration_mode:{settings:{developer_instructions:$di}}}}'
    jq -nc --arg a "$item0" --arg b "${items:-}" \
      '{type:"response_item",payload:{role:"developer",content:([{type:"input_text",text:$a}] + (if $b == "" then [] else [{type:"input_text",text:$b}] end))}}'
    jq -nc --arg u "$user_msg" '{type:"response_item",payload:{role:"user",content:[{type:"input_text",text:$u}]}}'
  } > "$f"
  echo "$f"
}

@test "compliant interactive session -> PASS, exit 0" {
  export AGENT_SOUL_PROFILE_DIRS="$MAIN $EDGE"
  config "$MAIN" cto; config "$EDGE" support
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa compliant
  mk_session "$EDGE" support 2026-10-12T10-00-00-bbb compliant
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS cto"* ]]
  [[ "$output" == *"PASS support"* ]]
}

@test "stripped session (SOUL only in turn_context, live MUS-6600 shape) -> FAIL, exit 1" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa stripped
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL cto"* ]]
  [[ "$output" == *"AGENT_SOUL"* ]]
  [[ "$output" == *"<available_skills>"* ]]
}

@test "the client-side turn_context SOUL must not satisfy the check" {
  config "$MAIN" cto
  f="$(mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa stripped)"
  # prove the fixture really carries SOUL in turn_context (otherwise vacuous)
  jq -e 'select(.type=="turn_context")|.payload.collaboration_mode.settings.developer_instructions|contains("AGENT_SOUL")' "$f" >/dev/null
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "mutation: stripping AGENT_SOUL from a compliant fixture turns the check red" {
  config "$MAIN" cto
  f="$(mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa compliant)"
  run "$SCRIPT"; [ "$status" -eq 0 ]
  tmp="$f.tmp"
  jq -c 'if .type=="response_item" and .payload.role=="developer" then (.payload.content[0].text |= gsub("AGENT_SOUL";"REDACTED")) else . end' "$f" > "$tmp" && mv "$tmp" "$f"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL cto"* ]]
}

@test "mutation: stripping <available_skills> alone turns the check red" {
  config "$MAIN" cto
  f="$(mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa compliant)"
  tmp="$f.tmp"
  jq -c 'if .type=="response_item" and .payload.role=="developer" then (.payload.content[0].text |= gsub("<available_skills>";"")) else . end' "$f" > "$tmp" && mv "$tmp" "$f"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL cto"* ]]
  [[ "$output" != *"AGENT_SOUL"* ]]
}

@test "lightweight-cron session (by-design exemption) is not a defect: older compliant session decides" {
  config "$MAIN" clio
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa lightweight-cron
  mk_session "$MAIN" clio 2026-10-12T01-00-00-bbb compliant
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS clio"* ]]
}

@test "lightweight-cron does not mask a stripped interactive session behind it" {
  config "$MAIN" clio
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa lightweight-cron
  mk_session "$MAIN" clio 2026-10-12T01-00-00-bbb stripped
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"* ]]
}

@test "agent whose only session is lightweight-cron is SKIPped, other agents still asserted" {
  config "$MAIN" clio cto
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa lightweight-cron
  mk_session "$MAIN" cto 2026-10-12T10-00-00-bbb compliant
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP clio"* ]]
  [[ "$output" == *"PASS cto"* ]]
}

@test "a non-lightweight cron lacking SOUL is NOT exempt (the 74 gpt-6 cron turns)" {
  config "$MAIN" cto
  f="$(mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa stripped)"
  # make it a cron turn WITHOUT the cron marker anywhere model-visible
  tmp="$f.tmp"
  jq -c 'if .type=="response_item" and .payload.role=="user" then (.payload.content[0].text="[cron:1111 nightly] run it") else . end' "$f" > "$tmp" && mv "$tmp" "$f"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL cto"* ]]
}

@test "cron session with SOUL+skills but no cron-mode marker -> FAIL naming the marker" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa cron-nomarker
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL cto"* ]]
  [[ "$output" == *"OpenClaw cron automation turn"* ]]
}

@test "compliant cron session with the marker -> PASS" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa cron-ok
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS cto"* ]]
}

@test "stale agent directory not in openclaw.json is ignored even with a stripped session" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa compliant
  mk_session "$MAIN" design 2026-10-12T10-00-00-zzz stripped
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"design"* ]]
}

@test "configured agent with a session older than the threshold is SKIPped, not asserted" {
  config "$MAIN" cto qa
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa compliant
  old="$(mk_session "$MAIN" qa 2026-10-01T10-00-00-bbb stripped)"
  touch -t 202610010000 "$old"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP qa"* ]]
  [[ "$output" == *"PASS cto"* ]]
}

@test "vacuity guard: zero agents asserted -> exit 1, never a silent pass" {
  config "$MAIN" cto
  old="$(mk_session "$MAIN" cto 2026-10-01T10-00-00-aaa compliant)"
  touch -t 202610010000 "$old"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"asserted 0"* ]]
}

@test "unreadable openclaw.json fails loud" {
  export AGENT_SOUL_PROFILE_DIRS="$MAIN $EDGE"
  echo '{not json' > "$MAIN/openclaw.json"; config "$EDGE" support
  mk_session "$EDGE" support 2026-10-12T10-00-00-aaa compliant
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"openclaw.json"* ]]
}

@test "--alert posts once on a defect and dedupes the identical repeat" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa stripped
  run "$SCRIPT" --alert
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$STUB_CALLS")" -ge 1 ]
  n1="$(wc -l < "$STUB_CALLS")"
  run "$SCRIPT" --alert
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$STUB_CALLS")" -eq "$n1" ]
}

@test "--alert: a page that was never delivered leaves no dedupe state and is retried next tick" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa stripped
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
exit 1
STUB
  run "$SCRIPT" --alert
  [ "$status" -eq 1 ]
  [ "$(grep -c '^slack send' "$STUB_CALLS")" -eq 1 ]
  [ ! -e "$AGENT_SOUL_STATE_FILE" ]
  run "$SCRIPT" --alert
  [ "$status" -eq 1 ]
  [ "$(grep -c '^slack send' "$STUB_CALLS")" -eq 2 ]
}

@test "--alert posts nothing when every agent is compliant" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa compliant
  run "$SCRIPT" --alert
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "--alert stands down inside a maintenance window" {
  config "$MAIN" cto
  mk_session "$MAIN" cto 2026-10-12T10-00-00-aaa stripped
  printf '{"reason":"deploy","expires_epoch":32503680000}\n' > "$HYDRA_MAINTENANCE_FLAG"
  run "$SCRIPT" --alert
  [ ! -s "$STUB_CALLS" ]
}

@test "unknown flag exits 2" {
  run "$SCRIPT" --nope
  [ "$status" -eq 2 ]
}

@test "full cron that kept the marker but lost SOUL+skills (no lightweight evidence) is NOT exempt -> FAIL" {
  config "$MAIN" clio
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa compliant
  mk_session "$MAIN" clio 2026-10-12T09-00-00-bbb cron-lostsoul
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"* ]]
}

@test "more than 15 lightweight crons newer than a stripped interactive session do not hide it -> FAIL" {
  config "$MAIN" clio cto
  mk_session "$MAIN" clio 2026-10-12T01-00-00-stripped stripped
  for i in $(seq -w 1 20); do
    mk_session "$MAIN" clio "2026-10-12T02-${i}-00-lw$i" lightweight-cron
  done
  mk_session "$MAIN" cto 2026-10-12T10-00-00-ok compliant
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"* ]]
}

@test "malformed newest rollout fails closed; an older compliant session must not turn it into a PASS" {
  config "$MAIN" clio cto
  mk_session "$MAIN" clio 2026-10-12T01-00-00-ok compliant
  f="$(mk_session "$MAIN" clio 2026-10-12T09-00-00-bad compliant)"
  sed -i.bak '2s/.*/{"type":"turn_context", BROKEN/' "$f"; rm -f "$f.bak"
  mk_session "$MAIN" cto 2026-10-12T10-00-00-ok compliant
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"*"unparsable"* ]]
  [[ "$output" != *"PASS clio"* ]]
}

@test "MUS-8377: a stripped INTERACTIVE session after a dreaming cron still FAILs (exemption never widens to interactive)" {
  config "$MAIN" clio
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa lightweight-cron
  mk_session "$MAIN" clio 2026-10-12T01-00-00-bbb stripped
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"*"AGENT_SOUL"* ]]
}

@test "MUS-8377: a stripped non-dreaming cron in the multi-agent shape is NOT exempt (multi_agent_role alone exempts nothing)" {
  config "$MAIN" clio
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa cron-lostsoul-multiagent
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"* ]]
}

@test "MUS-8377: a dreaming cron that also lost the cron-mode marker (MUS-6600 signature) -> FAIL naming the marker" {
  config "$MAIN" clio
  mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa dreaming-nomarker
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL clio"*"OpenClaw cron automation turn"* ]]
}

@test "MUS-8377: dreaming cron with SOUL+skills present is a normal PASS, not an exemption" {
  config "$MAIN" clio
  f="$(mk_session "$MAIN" clio 2026-10-12T03-00-00-aaa cron-ok)"
  tmp="$f.tmp"
  jq -c 'if .type=="response_item" and .payload.role=="user" then (.payload.content[0].text="[cron:2222 Memory Dreaming Promotion] '"$DREAM_SENTINEL"'") else . end' "$f" > "$tmp" && mv "$tmp" "$f"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS clio"* ]]
}
