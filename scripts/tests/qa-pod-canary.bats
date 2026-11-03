#!/usr/bin/env bats
# Tests for scripts/lib/qa-pod-canary.sh and its call site in
# .github/workflows/external-pr-review.yml (node8-to-pods T9 canary).
# gh and kubectl are PATH stubs, and the dispatcher is a stub that records the
# env it was called with. No test can reach GitHub, the cluster or a gateway.
# The workflow cases EXECUTE the shipped `run:` block extracted from the YAML.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/qa-pod-canary.sh"
WF="$HYDRA_REPO/.github/workflows/external-pr-review.yml"
TOKEN="tok-$(printf 'q%.0s' {1..44})"

setup() {
  T="$(mktemp -d)"; export T
  mkdir -p "$T/bin" "$T/runner"
  export RUNNER_TEMP="$T/runner"
  export STUB_LABELS='["other"]' STUB_IP="10.43.13.138" STUB_TOKEN_B64
  STUB_TOKEN_B64="$(printf '%s' "$TOKEN" | base64 | tr -d '\n')"
  cat > "$T/bin/gh" <<'S'
#!/bin/bash
echo "gh $*" >> "$T/gh.log"
case "$*" in
  *"/labels"*) [ -n "${STUB_LABELS_FAIL:-}" ] && exit 1; printf '%s' "$STUB_LABELS" | jq -r '.[]' ;;
  *"/pulls/"*) echo "${STUB_AUTHOR:-nsollazzo}" ;;
  *) exit 0 ;;
esac
S
  cat > "$T/bin/kubectl" <<'S'
#!/bin/bash
echo "kubectl $*" >> "$T/kubectl.log"
case "$*" in
  *"get svc qa-review-gateway"*) [ -n "${STUB_SVC_FAIL:-}" ] && exit 1; printf '%s' "$STUB_IP" ;;
  *"get secret qa-review-gateway-token"*) [ -n "${STUB_SECRET_FAIL:-}" ] && exit 1; printf '%s' "$STUB_TOKEN_B64" ;;
  *) exit 1 ;;
esac
S
  chmod +x "$T/bin/gh" "$T/bin/kubectl"
  export PATH="$T/bin:$PATH"
}
teardown() { rm -rf "$T"; }

route() {  # route in a subshell; print the env the caller would see
  bash -c 'source "$1"; qa_pod_canary_route Muso-AI/H-DevOps 42; rc=$?
    echo "rc=$rc url=${OPENCLAW_GATEWAY_URL:-} qurl=${QA_REVIEW_GATEWAY_URL:-} file=${OPENCLAW_GATEWAY_TOKEN_FILE:-}"
    [ -n "${OPENCLAW_GATEWAY_TOKEN_FILE:-}" ] && { echo "content=$(cat "$OPENCLAW_GATEWAY_TOKEN_FILE")"; stat -c "mode=%a" "$OPENCLAW_GATEWAY_TOKEN_FILE" 2>/dev/null || stat -f "mode=%Lp" "$OPENCLAW_GATEWAY_TOKEN_FILE"; }
    exit 0' _ "$LIB"
}

@test "unlabelled PR: no env change, no kubectl call (node-8 path byte-identical)" {
  run route
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 url= qurl= file="* ]]
  [ ! -e "$T/kubectl.log" ]
}

@test "labelled PR: URL = ws://<ClusterIP>:18789, token in a 0600 file, never on stdout/stderr" {
  export STUB_LABELS='["tier:1","qa-pod-canary"]'
  run route
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 url=ws://10.43.13.138:18789 qurl=ws://10.43.13.138:18789 file=$T/runner/qa-gw-token."* ]]
  [[ "$output" == *"content=$TOKEN"* ]]
  [[ "$output" == *"mode=600"* ]]
  # only the `content=` line (the test's own read-back) may carry the token
  [ "$(grep -c "$TOKEN" <<< "$output")" -eq 1 ]
  ! grep -q "$TOKEN" "$T/kubectl.log"
}

@test "label match is exact: qa-pod-canary-x and QA-POD-CANARY do not route" {
  export STUB_LABELS='["qa-pod-canary-x","QA-POD-CANARY","xqa-pod-canary"]'
  run route
  [[ "$output" == *"rc=0 url= "* ]]
}

@test "labelled but the Service has no ClusterIP: rc 1, nothing exported (no silent node-8 fallback)" {
  export STUB_LABELS='["qa-pod-canary"]' STUB_SVC_FAIL=1
  run route
  [[ "$output" == *"rc=1 url= qurl= file="* ]]
  export STUB_SVC_FAIL="" STUB_IP="None"
  run route
  [[ "$output" == *"rc=1 url= "* ]]
}

@test "labelled but the token Secret is unreadable: rc 1, no token file left behind" {
  export STUB_LABELS='["qa-pod-canary"]' STUB_SECRET_FAIL=1
  run route
  [[ "$output" == *"rc=1 url= qurl= file="* ]]
  [ -z "$(ls -A "$T/runner")" ]
}

@test "labels unreadable: local path, rc 0, and it says so" {
  export STUB_LABELS_FAIL=1
  run route
  [[ "$output" == *"rc=0 url= "* ]]
  [[ "$output" == *"could not read labels"* ]]
}

@test "cleanup removes the token file" {
  export STUB_LABELS='["qa-pod-canary"]'
  run bash -c 'source "$1"; qa_pod_canary_route Muso-AI/H-DevOps 42; f="$OPENCLAW_GATEWAY_TOKEN_FILE"; [ -s "$f" ] || exit 3; qa_pod_canary_cleanup; [ ! -e "$f" ]' _ "$LIB"
  [ "$status" -eq 0 ]
}

# ── the SHIPPED workflow step, executed ─────────────────────────────────────
extract_step() {
  python3 - "$WF" > "$T/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for j in d["jobs"].values():
    for s in j.get("steps", []):
        if s.get("name", "").startswith("Validate payload, map author, and dispatch"):
            print(s["run"]); sys.exit(0)
sys.exit("step not found")
PY
  # a sandbox repo: the real libs this step sources, a recording dispatcher stub
  mkdir -p "$T/repo/scripts/lib"
  cp "$HYDRA_REPO/scripts/lib/qa-pod-canary.sh" "$T/repo/scripts/lib/"
  printf '#!/bin/bash\nexit 0\n' > "$T/repo/scripts/lib/qa-external-repo-allowlist.sh"
  printf '#!/bin/bash\necho U0AL36NADEY\n' > "$T/repo/scripts/lib/qa-author-slack-uid.sh"
  cat > "$T/repo/scripts/qa-dispatch-pr-review.sh" <<'S'
#!/bin/bash
printf 'dispatch %s url=%s tokfile=%s\n' "$*" "${OPENCLAW_GATEWAY_URL:-}" "${OPENCLAW_GATEWAY_TOKEN_FILE:-}" >> "$T/dispatch.log"
[ -n "${OPENCLAW_GATEWAY_TOKEN_FILE:-}" ] && cp "$OPENCLAW_GATEWAY_TOKEN_FILE" "$T/seen-token"
exit 0
S
}
run_step() {
  (cd "$T/repo" && REPO=Muso-AI/H-DevOps PR=42 HEAD_SHA=0f175183abf AUTHOR=nsollazzo BASE=main IS_DRAFT=false QA_ACK_PAT=x \
     bash -e "$T/step.sh")
}

@test "workflow step, unlabelled: dispatches with NO gateway env (unchanged path)" {
  extract_step
  run run_step
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^dispatch 42 0f175183abf Muso-AI/H-DevOps U0AL36NADEY url= tokfile=$' "$T/dispatch.log"
}

@test "workflow step, labelled: the dispatcher sees the pod URL + token file; the file is gone after the step" {
  extract_step
  export STUB_LABELS='["qa-pod-canary"]'
  run run_step
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^dispatch 42 0f175183abf Muso-AI/H-DevOps U0AL36NADEY url=ws://10.43.13.138:18789 tokfile=' "$T/dispatch.log"
  [ "$(cat "$T/seen-token")" = "$TOKEN" ]
  [ -z "$(ls -A "$T/runner")" ]           # EXIT trap removed the token file
  [[ "$output" != *"$TOKEN"* ]]
}

@test "workflow step, labelled but unresolvable: step FAILS and does not dispatch" {
  extract_step
  export STUB_LABELS='["qa-pod-canary"]' STUB_SECRET_FAIL=1
  run run_step
  [ "$status" -ne 0 ]
  [ ! -e "$T/dispatch.log" ]
  [[ "$output" == *"qa-pod-canary but the pod gateway could not be resolved"* ]]
}

@test "workflow mutation: dropping the canary call means a labelled PR dispatches locally (the call is load-bearing)" {
  extract_step
  python3 - "$T/step.sh" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
a = 'if ! GH_TOKEN="${QA_ACK_PAT:-${GH_TOKEN:-}}" qa_pod_canary_route "$REPO" "$PR"; then'
assert a in s, "mutation did not apply"
open(p, "w").write(s.replace(a, 'if false; then'))
PY
  export STUB_LABELS='["qa-pod-canary"]'
  run run_step
  [ "$status" -eq 0 ]
  grep -q 'url= tokfile=$' "$T/dispatch.log"
}
