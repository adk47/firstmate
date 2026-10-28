#!/usr/bin/env bats
# Guards for the qa-review-gateway pod profile and entrypoint (node8-to-pods T9).
#   pods/qa-review-gateway/openclaw-qa.json — the `qa`-only gateway profile
#   pods/qa-review-gateway/entrypoint.sh    — what each pod runs
# The security posture asked for by security-arch-fable-s1 (2026-10-28 06:21Z) is
# asserted here, each with a mutation proving the assertion is load-bearing:
# no reused / literal gateway token, Control UI off, no chat-completions surface,
# exec not `full`, no channels, no agent-to-agent, the minimum plugin set.
# The profile lives OUTSIDE the repo root on purpose: check-gateway-profile-parity.sh
# treats every root openclaw-*.json as a node-8 profile that deploy.sh must start.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PROFILE="$HYDRA_REPO/pods/qa-review-gateway/openclaw-qa.json"
ENTRY="$HYDRA_REPO/pods/qa-review-gateway/entrypoint.sh"
MAIN="$HYDRA_REPO/openclaw-main.json"

# assert_profile <file>: every posture rule; prints the first violation.
assert_profile() {
  local f="$1" v
  v="$(jq -r '
    [ (if (.gateway.auth.token? // null) != null then "gateway.auth.token is set (the token must come from OPENCLAW_GATEWAY_TOKEN)" else empty end),
      (if .gateway.auth.mode != "token" then "gateway.auth.mode is not token" else empty end),
      (if (.gateway.auth.password? // null) != null then "gateway.auth.password is set" else empty end),
      (if .gateway.controlUi.enabled != false then "controlUi is not disabled" else empty end),
      (if (.gateway.http.endpoints.chatCompletions.enabled // false) != false then "chatCompletions endpoint enabled" else empty end),
      (if (.gateway.tailscale.mode // "off") != "off" then "tailscale on" else empty end),
      (if has("channels") then "channels configured" else empty end),
      (if has("bindings") then "bindings configured" else empty end),
      (if (.tools.exec.mode // "full") == "full" then "tools.exec.mode is full (or unset = full)" else empty end),
      (if (.tools.exec.security // "") == "full" then "tools.exec.security is full" else empty end),
      (if (.tools.agentToAgent.enabled // false) != false then "agentToAgent enabled" else empty end),
      (if ([.agents.list[]?.id] != ["qa"]) then "agents.list is not exactly [qa]" else empty end),
      (if ((.plugins.allow // []) - ["codex","openrouter"]) != [] then "plugins.allow beyond codex+openrouter: \((.plugins.allow // []) - ["codex","openrouter"])" else empty end),
      (if (.secrets.providers["hydra-env"].allowlist // []) != ["MUSO_SLACK_BOT_TOKEN_QA"] then "hydra-env allowlist is not exactly the QA bot token" else empty end),
      (if ([.tools.deny[]?] | index("group:sessions")) == null then "tools.deny lacks group:sessions" else empty end),
      (if ([.tools.deny[]?] | index("group:automation")) == null then "tools.deny lacks group:automation (cron/gateway tools)" else empty end),
      (if ([.tools.deny[]?] | index("group:ui")) == null then "tools.deny lacks group:ui (browser/canvas)" else empty end),
      (if ([.tools.deny[]?] | index("group:messaging")) == null then "tools.deny lacks group:messaging" else empty end)
    ] | first // "OK"' "$f")"
  echo "$v"
  [ "$v" = "OK" ]
}

mutate() {  # mutate <jq-filter> → path of a mutated copy (asserting it differs)
  local out="$BATS_TEST_TMPDIR/m.json"
  jq "$1" "$PROFILE" > "$out"
  ! cmp -s "$PROFILE" "$out" || { echo "mutation '$1' changed nothing"; return 1; }
  echo "$out"
}

@test "profile: valid JSON and the posture holds" {
  jq -e . "$PROFILE" >/dev/null
  run assert_profile "$PROFILE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "profile: carries no secret literal at all (no token-shaped value anywhere)" {
  run jq -r '.. | strings | select(test("^[0-9a-f]{40,}$") or test("^(sk-|xox[bpa]-|ghp_|github_pat_)"))' "$PROFILE"
  [ -z "$output" ]
  # and never Caroline's gateway token
  lit="$(jq -r '.gateway.auth.token // empty' "$MAIN")"
  [ -n "$lit" ]
  ! grep -qF "$lit" "$PROFILE"
}

@test "profile mutations: each posture rule goes red" {
  for m in \
    '.gateway.auth.token = "x"' \
    '.gateway.controlUi.enabled = true' \
    'del(.gateway.controlUi)' \
    '.gateway.http.endpoints.chatCompletions.enabled = true' \
    '.channels = {"slack": {}}' \
    '.tools.exec.mode = "full"' \
    'del(.tools.exec.mode)' \
    '.tools.exec.security = "full"' \
    '.tools.agentToAgent.enabled = true' \
    '.agents.list += [{"id":"operations"}]' \
    '.plugins.allow += ["slack"]' \
    '.secrets.providers["hydra-env"].allowlist += ["MUSO_SLACK_BOT_TOKEN_OPERATIONS"]' \
    '.tools.deny -= ["group:sessions"]' \
    '.tools.deny -= ["group:automation"]'; do
    f="$(mutate "$m")"
    if assert_profile "$f" >/dev/null; then echo "mutation stayed green: $m"; return 1; fi
  done
}

@test "profile: the qa agent and model routing match Caroline's main profile (no silent drift)" {
  [ "$(jq -cS '.agents.list[] | select(.id=="qa")' "$MAIN")" = "$(jq -cS '.agents.list[0]' "$PROFILE")" ]
  [ "$(jq -cS '.models' "$MAIN")" = "$(jq -cS '.models' "$PROFILE")" ]
  [ "$(jq -cS '.auth.order' "$MAIN")" = "$(jq -cS '.auth.order' "$PROFILE")" ]
  [ "$(jq -cS '.agents.defaults.model' "$MAIN")" = "$(jq -cS '.agents.defaults.model' "$PROFILE")" ]
}

@test "profile: is NOT at the repo root (node-8 deploy enumerates root openclaw-*.json)" {
  [ ! -e "$HYDRA_REPO/openclaw-qa.json" ]
}

# 2026-10-28: hydra deploy 40722546980 failed because the profile sat at
# k8s/prod/qa-review-gateway/openclaw-qa.json. deploy.sh runs `kubectl apply -f k8s/prod/<dir>/`
# on every directory there, and kubectl reads every .yaml/.yml/.json inside it.
k8s_prod_non_manifests() {  # <root>: print each .yaml/.yml/.json under k8s/prod/*/ lacking apiVersion+kind
  python3 - "$1" <<'PY'
import glob, json, sys, yaml
root = sys.argv[1]
for f in sorted(glob.glob(f"{root}/k8s/prod/*/*")):
    if not f.endswith((".yaml", ".yml", ".json")):
        continue
    try:
        docs = [json.load(open(f))] if f.endswith(".json") else [d for d in yaml.safe_load_all(open(f)) if d is not None]
    except Exception as e:
        print(f"{f}: unparseable ({e})"); continue
    if not docs:
        print(f"{f}: no document"); continue
    for d in docs:
        if not (isinstance(d, dict) and d.get("apiVersion") and d.get("kind")):
            print(f"{f}: not a Kubernetes object (apiVersion/kind not set)"); break
PY
}

@test "deploy safety: every .yaml/.yml/.json under k8s/prod/*/ is a Kubernetes object (deploy.sh kubectl-applies the whole dir)" {
  run k8s_prod_non_manifests "$HYDRA_REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; return 1; }
  # the gateway profile and its entrypoint live outside the applied tree
  [ ! -e "$HYDRA_REPO/k8s/prod/qa-review-gateway" ]
}

@test "deploy safety mutation: a profile json put back under k8s/prod/<dir>/ is caught" {
  mkdir -p "$BATS_TEST_TMPDIR/r/k8s/prod/qa-review-gateway"
  cp "$PROFILE" "$BATS_TEST_TMPDIR/r/k8s/prod/qa-review-gateway/"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}\n' > "$BATS_TEST_TMPDIR/r/k8s/prod/qa-review-gateway/ok.yaml"
  run k8s_prod_non_manifests "$BATS_TEST_TMPDIR/r"
  [[ "$output" == *"qa-review-gateway/openclaw-qa.json: not a Kubernetes object"* ]]
  [[ "$output" != *"ok.yaml"* ]]
}

# ── entrypoint ──────────────────────────────────────────────────────────────
entry_env() {
  STUB="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB" "$BATS_TEST_TMPDIR/hydra/scripts" "$BATS_TEST_TMPDIR/hydra/pods/qa-review-gateway"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  cat > "$STUB/openclaw" <<'S'
#!/bin/bash
echo "openclaw $*" >> "$CALLS"
[ "$1 $2" = "config validate" ] && [ -n "${STUB_VALIDATE_FAIL:-}" ] && exit 1
exit 0
S
  cat > "$BATS_TEST_TMPDIR/hydra/scripts/codex-auth-secret.sh" <<'S'
#!/bin/bash
echo "codex-auth-secret $* state=$OPENCLAW_STATE_DIR" >> "$CALLS"
exit "${STUB_IMPORT_RC:-0}"
S
  chmod +x "$STUB/openclaw" "$BATS_TEST_TMPDIR/hydra/scripts/codex-auth-secret.sh"
  cp "$PROFILE" "$BATS_TEST_TMPDIR/hydra/pods/qa-review-gateway/"
  cp "$MAIN" "$BATS_TEST_TMPDIR/hydra/openclaw-main.json"
  echo '{}' > "$BATS_TEST_TMPDIR/auth.json"
  export PATH="$STUB:$PATH" HYDRA_ROOT="$BATS_TEST_TMPDIR/hydra" QA_CODEX_AUTH_FILE="$BATS_TEST_TMPDIR/auth.json"
  export OPENCLAW_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPENCLAW_GATEWAY_TOKEN="qa-gw-$(printf 'a%.0s' {1..40})"
}

@test "entrypoint: validate -> doctor --non-interactive -> import -> exec gateway, in that order" {
  entry_env
  run bash "$ENTRY"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cut -d' ' -f1-3 "$CALLS" | tr '\n' '|')" = "openclaw config validate|openclaw doctor --non-interactive|codex-auth-secret import --in|openclaw gateway --port|" ]
  ! grep -qE -- '--fix|--repair' "$CALLS"
  [ -f "$OPENCLAW_STATE_DIR/openclaw.json" ]
}

@test "entrypoint: refuses Caroline's literal token, a short token, and no token -- before any openclaw call" {
  entry_env
  OPENCLAW_GATEWAY_TOKEN="$(jq -r .gateway.auth.token "$MAIN")" run bash "$ENTRY"
  [ "$status" -ne 0 ]; [[ "$output" == *"openclaw-main.json"* ]]
  OPENCLAW_GATEWAY_TOKEN="short" run bash "$ENTRY"
  [ "$status" -ne 0 ]
  OPENCLAW_GATEWAY_TOKEN="" run bash "$ENTRY"
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "entrypoint: a refused codex import or a bad profile never starts the gateway" {
  entry_env
  STUB_IMPORT_RC=1 run bash "$ENTRY"
  [ "$status" -ne 0 ]
  ! grep -q 'openclaw gateway' "$CALLS"
  : > "$CALLS"
  STUB_VALIDATE_FAIL=1 run bash "$ENTRY"
  [ "$status" -ne 0 ]
  ! grep -q 'openclaw gateway' "$CALLS"
  rm "$QA_CODEX_AUTH_FILE"; : > "$CALLS"
  run bash "$ENTRY"
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}
