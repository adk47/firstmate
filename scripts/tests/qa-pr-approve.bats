#!/usr/bin/env bats
# Tests for scripts/qa-pr-approve.sh — the gated "approve-only" wrapper QA uses
# after a GO-verdict review. Every test PATH-shadows `gh` with a stub so the
# suite NEVER touches real GitHub (memory: bats must stub openclaw/gh — Clio's
# PR #245 fired 9 real Slack alerts from an unstubbed test).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-pr-approve.sh"

NICK="U0AL36NADEY"   # allowlisted requester

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export QA_PR_APPROVE_LOG_DIR="$TEST_TMPDIR/api-logs/github"
  # Guard 8 state dir: left nonexistent by default = "no rebase-integrity
  # report" (external repo / pre-feature head), which must keep passing — every
  # pre-Guard-8 test in this file exercises exactly that path.
  export QA_REBASE_STATE_DIR="$TEST_TMPDIR/ri"
  export STUB_CALLS="$TEST_TMPDIR/gh-calls"
  : > "$STUB_CALLS"

  # Stub `gh`. Configurable via STUB_ME / STUB_AUTHOR / STUB_APPROVE_RC /
  # STUB_BAD_CHECKS / STUB_OPEN_BLOCKERS.
  #
  # Fixture-based jq coverage (Guard 6 / Guard 7):
  #   STUB_ROLLUP_JSON — if set, the stub extracts the script's actual --jq
  #     filter from its own args and runs it against this JSON via local jq,
  #     so the real filter string is exercised with no duplication/drift.
  #   STUB_THREADS_JSON — same idea for the graphql / Guard-7 path.
  # Fallback (STUB_ROLLUP_JSON/STUB_THREADS_JSON unset): echo the canned count,
  # keeping all existing canned-count tests unaffected.
  #
  # NOTE: production `gh` uses gojq; this stub runs local jq. The node-8 live
  # smoke covers the gojq path. Both should behave identically for the filters
  # used here (no gojq-specific extensions).
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
# emit the argument that follows --jq in "$@"
_jqflt() { local p=""; for a in "$@"; do [ "$p" = "--jq" ] && { printf '%s' "$a"; return; }; p="$a"; done; }

sub="$1"; shift || true
case "$sub" in
  api)
    if [ "${1:-}" = "graphql" ]; then
      if [ -n "${STUB_THREADS_JSON:-}" ]; then
        _flt="$(_jqflt "$@")"
        if [ -n "$_flt" ]; then
          printf '%s' "$STUB_THREADS_JSON" | jq -r "$_flt"
        else
          # No --jq: emit the raw payload, exactly as real gh does. Guard 8 pipes
          # gh into a separate jq so it can pass the bot-login set via --argjson
          # (gh's own --jq takes no arguments).
          printf '%s' "$STUB_THREADS_JSON"
        fi
      else
        echo "${STUB_OPEN_BLOCKERS:-0}"                 # count of unresolved Critical/Important threads
      fi
    elif printf '%s\n' "$@" | grep -qE '^repos/[^/]+/[^/]+/pulls/[0-9]+/files\?per_page=100$'; then
      _args="$*"
      if printf '%s' "$_args" | grep -q -- '--paginate' \
        && printf '%s' "$_args" | grep -q -- '--slurp'; then
        echo "files-api-paginated-slurped" >> "$STUB_CALLS"
      fi
      _page1="${STUB_FILES_PAGE_1:-${STUB_FILES:-src/app.ts}}"
      _page2="${STUB_FILES_PAGE_2:-}"
      if [ -n "${STUB_FILES_JSON:-}" ]; then
        printf '%s' "$STUB_FILES_JSON"
      else
        jq -nc --arg p1 "$_page1" --arg p2 "$_page2" '
          ($p1 | split(" ") | map(select(length > 0) | {filename: ., status: "modified"})) as $a
          | ($p2 | split(" ") | map(select(length > 0) | {filename: ., status: "modified"})) as $b
          | if ($b | length) > 0 then [$a, $b] else [$a] end'
      fi
    else
      # No colon: an explicitly EMPTY STUB_ME must stay empty, so tests can model
      # `gh api user` 403ing under a GitHub App installation token. With `:-` an
      # empty value would silently fall back and the regression would go untested.
      echo "${STUB_ME-adk47}"                         # gh api user --jq .login
    fi ;;
  pr)
    action="$1"; shift || true
    case "$action" in
      view)
        if printf '%s ' "$@" | grep -q 'statusCheckRollup'; then
          if [ -n "${STUB_ROLLUP_JSON:-}" ]; then
            printf '%s' "$STUB_ROLLUP_JSON" | jq -r "$(_jqflt "$@")"
          else
            echo "${STUB_BAD_CHECKS:-0}"               # count of non-passing checks
          fi
        elif printf '%s ' "$@" | grep -q 'headRefOid'; then
          echo "${STUB_HEAD_OID:-0123456789abcdef0123456789abcdef01234567}"  # Guard 8 report key
        elif printf '%s ' "$@" | grep -q -- 'changedFiles'; then
          _page1="${STUB_FILES_PAGE_1:-${STUB_FILES:-src/app.ts}}"
          _all="$_page1 ${STUB_FILES_PAGE_2:-}"
          set -- $_all
          echo "${STUB_CHANGED_COUNT:-$#}"
        elif printf '%s ' "$@" | grep -q 'author'; then
          echo "${STUB_AUTHOR:-nsollazzo}"            # PR author login
        else
          echo "  reviewDecision=APPROVED  mergeStateStatus=CLEAN  state=OPEN"
        fi ;;
      review)
        echo "approve" >> "$STUB_CALLS"
        # prove the audit log already exists at approve time (log-before-write)
        [ -f "${QA_PR_APPROVE_LOG_DIR}/$(date -u +%F).jsonl" ] && echo "log-present-at-approve" >> "$STUB_CALLS"
        exit "${STUB_APPROVE_RC:-0}" ;;
    esac ;;
esac
STUB
  chmod +x "$STUBBIN/gh"
  export PATH="$STUBBIN:$PATH"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

logfile() { echo "$QA_PR_APPROVE_LOG_DIR/$(date -u +%F).jsonl"; }

# ---------------------------------------------------------------------------
# Existing canned-count tests (unchanged — stub fallback path)
# ---------------------------------------------------------------------------

@test "happy path: allowlisted requester, non-self author → approves once, logs first" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  # approved exactly once, never merged
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
  # audit log written, with the expected shape
  grep -q '"action":"github_pr_approve"' "$(logfile)"
  grep -q '"target":"Muso-AI/core-backend#123"' "$(logfile)"
  # log existed BEFORE the approve call
  grep -q '^log-present-at-approve$' "$STUB_CALLS"
}

@test "self-approval blocked: author == gateway account → exit 4, never approves" {
  STUB_ME="adk47" STUB_AUTHOR="adk47" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
  [ ! -s "$STUB_CALLS" ] || ! grep -q '^approve$' "$STUB_CALLS"
}

@test "non-Muso-AI repo → exit 3, no approval, no log" {
  run "$SCRIPT" SomeOrg/secret 123 "$NICK"
  [ "$status" -eq 3 ]
  ! grep -q '^approve$' "$STUB_CALLS"
  [ ! -f "$(logfile)" ]
}

@test "requester not in allowlist → exit 5, no approval" {
  run "$SCRIPT" core-backend 123 "U999NOTALLOWED"
  [ "$status" -eq 5 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "owner/repo form with Muso-AI owner is accepted" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" run "$SCRIPT" Muso-AI/web-credits 7 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '"target":"Muso-AI/web-credits#7"' "$(logfile)"
}

@test "missing args → usage exit 2" {
  run "$SCRIPT" core-backend 123
  [ "$status" -eq 2 ]
}

@test "non-numeric PR number → usage exit 2" {
  run "$SCRIPT" core-backend not-a-number "$NICK"
  [ "$status" -eq 2 ]
}

@test "gh approve failure surfaces as exit 7" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_APPROVE_RC=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 7 ]
}

@test "CI not green → exit 8, never approves, never logs the approval" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=2 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "unresolved Critical/Important thread → exit 9, never approves" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "#287 replay: CI green but a blocking thread open → exit 9, no approval" {
  # The exact shape that mis-approved #287: green CI, an unresolved 🔴/🟡 thread.
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=4 \
    run "$SCRIPT" hydra 287 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 6 fixture-based tests — real jq filter exercised against JSON shapes
# ---------------------------------------------------------------------------

@test "guard6/fixture: all green (CheckRun SUCCESS + StatusContext SUCCESS) → exit 0, approve recorded" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"StatusContext","context":"deploy/preview","state":"SUCCESS"}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: pending CheckRun (IN_PROGRESS, conclusion null) → exit 8, no approve" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: non-qa-review FAILURE → exit 8, no approve" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"unit-tests","status":"COMPLETED","conclusion":"FAILURE"}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: qa-review FAILURE excluded, all others green → exit 0 (circular-dep exclusion), approve recorded" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"StatusContext","context":"qa-review","state":"FAILURE"},
    {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: empty rollup → exit 8 (fail-closed: empty rollup is not proof CI ran) [QA #398]" {
  ROLLUP='{"statusCheckRollup":[]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: rollup with ONLY an excluded qa-review check → exit 8 (no real checks present) [QA #398]" {
  ROLLUP='{"statusCheckRollup":[{"__typename":"StatusContext","context":"qa-review","state":"SUCCESS"}]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 7 fixture-based tests — real jq filter exercised against JSON shapes
# ---------------------------------------------------------------------------

# Helper: wrap nodes array in the full graphql response envelope Guard 7 expects
# Usage: STUB_THREADS_JSON="$(threads_json '[{...},{...}]')"
# (defined as a plain variable prefix in each test for portability)

@test "guard7/fixture: unresolved Critical (🔴) thread → exit 9, no approve" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🔴 Critical: fix the null check"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: unresolved Important (🟡) thread → exit 9, no approve" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🟡 Important: consider edge case"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: isResolved:true on 🔴 thread → exit 0 (resolved clears the block), approve recorded" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🔴 Critical: fix the null check"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: 🟢 nice-to-have unresolved thread → exit 0 (only 🔴/🟡 block), approve recorded" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🟢 Nice: consider extracting this helper"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: unresolved thread with empty comments.nodes → exit 0 (no crash; safe // \"\")" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: hasNextPage:true (>100 threads) → exit 9 (fail-closed; a blocker could be on page 2) [QA #398]" {
  # Even with zero blockers visible on page 1, a second page means we cannot be sure.
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"all clear"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 8 — rebase-integrity report (scripts/check-rebase-integrity.sh hand-off)
# ---------------------------------------------------------------------------

HEAD_OID="0123456789abcdef0123456789abcdef01234567"   # stub default; sha7 = 0123456
MARKER="REBASE WARNING [0123456]"

ri_report() {  # <status> — write a well-formed per-head report Guard 8 keys on
  mkdir -p "$QA_REBASE_STATE_DIR"
  printf '{"repo":"Muso-AI/core-backend","pr":123,"head_sha":"%s","status":"%s"}' \
    "$HEAD_OID" "$1" > "$QA_REBASE_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
}

ri_report_raw() {  # <content> — write raw bytes (malformed-JSON cases)
  mkdir -p "$QA_REBASE_STATE_DIR"
  printf '%s' "$1" > "$QA_REBASE_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
}

NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'

@test "guard8: WARN report but no REBASE WARNING thread filed → exit 10, no approve" {
  ri_report WARN
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$NO_THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  echo "$output" | grep -q 'REBASE WARNING'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: WARN + QA-filed marker thread RESOLVED by a human → approves (resolution is the ack)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** PR deletes recent main work","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: marker thread filed by someone OTHER than the gateway account → exit 10 (forged ack)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** looks fine to me","author":{"login":"nsollazzo"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8/guard7 division of labor: WARN + marker thread UNRESOLVED → exit 9 (Guard 7 blocks first)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** PR deletes recent main work","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: marker for a DIFFERENT head sha does not satisfy the WARN gate → exit 10" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — REBASE WARNING [fffffff]** stale finding from an older push","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: report status ERROR → exit 10 (rebase state unverified, fail closed)" {
  ri_report ERROR
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: malformed report JSON → exit 10 (fail closed)" {
  ri_report_raw 'this is not json'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: report interior fields mismatching the filename key → exit 10 (fail closed)" {
  ri_report_raw '{"repo":"Muso-AI/core-backend","pr":999,"head_sha":"0000000000000000000000000000000000000000","status":"CLEAN"}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: CLEAN report → approves" {
  ri_report CLEAN
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: missing report file for an EXTERNAL repo (no analyzer in its CI) → approves" {
  # QA_REBASE_STATE_DIR exists but holds no report for this head
  mkdir -p "$QA_REBASE_STATE_DIR"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: missing report file for a REQUIRED repo (hydra) → exit 10 (failed hand-off is not clean)" {
  mkdir -p "$QA_REBASE_STATE_DIR"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" hydra 625 "$NICK"
  [ "$status" -eq 10 ]
  echo "$output" | grep -q 'no rebase-integrity report'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: QA_REBASE_REQUIRED_REPOS is tunable — hydra not listed → missing report approves" {
  mkdir -p "$QA_REBASE_STATE_DIR"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_REBASE_REQUIRED_REPOS="other-repo" \
    run "$SCRIPT" hydra 625 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Bot identity — the App-token migration
# ---------------------------------------------------------------------------
# `gh api user` returns 403 "Resource not accessible by integration" under a
# GitHub App installation token: there is no user behind an App token. The stub
# models that as empty output (STUB_ME="").

test_policy() {  # <json> — point the script at a throwaway policy
  printf '%s' "$1" > "$TEST_TMPDIR/policy.json"
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/policy.json"
}

DEFAULT_POLICY='{"identity":{"bot_logins":["muso-qa-bot","muso-qa-bot[bot]","adk47"],"app_repos":[]},
  "author_deny":[],"require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'

@test "identity: gh api user 403s (App token) → falls back to a policy bot login, still approves" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
  grep -q '"identity":"muso-qa-bot"' "$(logfile)"
}

@test "identity: Guard 3 fires on the app/<slug> author form gh actually returns" {
  # `gh pr view --json author` is GraphQL and returns "app/<slug>" — NOT the REST
  # "<slug>[bot]" form. Verified against Muso-AI/auth's dependabot PR 2026-07-27:
  # REST said "dependabot[bot]", gh pr view said "app/dependabot". Comparing raw
  # strings matches nothing, so norm_login() must collapse both.
  test_policy "$DEFAULT_POLICY"
  STUB_ME="" STUB_AUTHOR="app/muso-qa-bot" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: Guard 3 also fires on the REST <slug>[bot] form" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="muso-qa-bot" STUB_AUTHOR="muso-qa-bot[bot]" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
}

@test "guard3c: author_deny matches across app/ and [bot] forms too" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":["adk47"],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="app/adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
}

@test "guard3c: malformed author_deny → exit 12 (fail closed), not a silent pass" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":"adk47",
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: changed-file count mismatch with paginated REST list → exit 11 (fail closed)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="a.ts b.ts" STUB_CHANGED_COUNT=130 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'reports 130 changed files'
  echo "$output" | grep -q 'returned 2'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: >100 ordinary files from paginated REST → approves" {
  page1=""
  for i in $(seq 1 100); do page1="${page1}src/page-1-file-${i}.ts "; done
  page2=""
  for i in $(seq 1 35); do page2="${page2}src/page-2-file-${i}.ts "; done
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_PAGE_1="$page1" STUB_FILES_PAGE_2="$page2" STUB_CHANGED_COUNT=135 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^files-api-paginated-slurped$' "$STUB_CALLS"
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: sensitive file on REST page 2 → exit 11 with the path" {
  page1=""
  for i in $(seq 1 100); do page1="${page1}src/page-1-file-${i}.ts "; done
  page2=""
  for i in $(seq 1 34); do page2="${page2}src/page-2-file-${i}.ts "; done
  page2="${page2}policies/qa-approval-policy.json"
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_PAGE_1="$page1" STUB_FILES_PAGE_2="$page2" STUB_CHANGED_COUNT=135 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'policies/qa-approval-policy.json'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: rename out of a sensitive path checks previous_filename → exit 11" {
  files='[[{"filename":"src/app.ts","status":"modified"}],
    [{"filename":"archive/old-policy.json","previous_filename":"policies/qa-approval-policy.json","status":"renamed"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=2 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'policies/qa-approval-policy.json'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: duplicate filename across REST pages → exit 11 (fail closed)" {
  files="$(jq -nc '
    ([range(1; 101) | {filename: ("src/file-" + tostring + ".ts"), status: "modified"}]) as $page1
    | [$page1, [{filename: "src/file-1.ts", status: "modified"}]]')"
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=101 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'duplicate'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: empty filename in REST row → exit 11 (fail closed)" {
  files='[[{"filename":"","status":"modified"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'parse'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: empty previous_filename on renamed REST row → exit 11 (fail closed)" {
  files='[[{"filename":"archive/policy.json","previous_filename":"","status":"renamed"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'parse'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: unknown REST file status → exit 11 (fail closed)" {
  files='[[{"filename":"src/app.ts","status":"mystery"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'parse'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: empty sensitive_paths → exit 11 (a dropped key must not disable the guard)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: gh api user 403s AND Guard 8 WARN → marker thread still resolves (the \$me-empty bug)" {
  # Regression guard. Before the fix, an empty \$me made Guard 8 compare
  # .author.login against "", match nothing, and refuse EVERY WARN head.
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** rebase dropped work","author":{"login":"muso-qa-bot"}}]}}
  ]}}}}}'
  STUB_ME="" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: a legacy marker thread filed by the OLD host account still counts (cutover/rollback)" {
  # PRs open across the cutover carry adk47-filed REBASE WARNING threads. If the
  # login test were a single value rather than the bot_logins set, those PRs
  # would strand at exit 10 the moment the App took over.
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** filed pre-cutover","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="muso-qa-bot[bot]" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: GraphQL Bot.login form (no [bot] suffix) matches the REST-form identity" {
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** x","author":{"login":"muso-qa-bot"}}]}}
  ]}}}}}'
  STUB_ME="muso-qa-bot[bot]" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
}

@test "self-approval still blocks when the acting identity authored the PR" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="muso-qa-bot[bot]" STUB_AUTHOR="muso-qa-bot[bot]" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 3b — sensitive paths (exit 11)
# ---------------------------------------------------------------------------

@test "guard3b: PR touching policies/ → exit 11, never approves, never logs" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["policies/","secrets/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="README.md policies/qa-approval-policy.json" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 700 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'sensitive path'
  ! grep -q '^approve$' "$STUB_CALLS"
  [ ! -f "$(logfile)" ]
}

@test "guard3b: the bot cannot approve a change to its own approval script" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["scripts/qa-pr-approve.sh"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="scripts/qa-pr-approve.sh" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 701 "$NICK"
  [ "$status" -eq 11 ]
}

@test "guard3b: sensitive paths apply regardless of author (stronger than the old self-approve block)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES=".github/workflows/deploy.yml" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
}

@test "guard3b: ordinary source paths are unaffected → approves" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"],"Muso-AI/hydra":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="src/app.ts docs/README.md" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "unreadable policy → refuses (fail closed) at the first guard that reads it, never approves" {
  # Guard 3c reads the policy before 3b does, and is itself fail-closed, so an
  # unreadable policy dies 12 rather than reaching 3b's exit 11. Either way the
  # invariant that matters holds: no approval without a readable policy.
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/does-not-exist.json"
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'fail closed'
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 3c — author_deny (exit 12)
# ---------------------------------------------------------------------------

@test "guard3c: author in author_deny → exit 12, never approves" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":["adk47"],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'author_deny'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3c: author_deny is case-insensitive (GitHub logins are)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":["adk47"],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="ADK47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
}

@test "guard3c: flipping author_deny to [] lets the same PR through (the deliberate policy flip)" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Code-owner honesty
# ---------------------------------------------------------------------------

@test "codeowner repos: approval succeeds but says it does NOT unblock the merge" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":["Muso-AI/hydra"],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 702 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
  echo "$output" | grep -q 'still needs a human code owner'
}

@test "guard3b: the bot cannot approve a PR that edits the reviewer SKILL itself" {
  # The skill is as load-bearing as the wrapper: a PR that edits it to skip the
  # 7-lens workflow, or to post qa-review=success directly, weakens the gate just
  # as effectively as editing qa-pr-approve.sh. Without this the bot could
  # approve the change that removes its own review authority.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["skills-all/muso-github-code-review/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="skills-all/muso-github-code-review/SKILL.md" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 900 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'sensitive path'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: the SHIPPED policy actually covers the reviewer skill and the QA scripts" {
  # Guards the policy DATA, not just the code path — the entries above are the
  # whole protection, and a dropped line is silent.
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  for p in "skills-all/muso-github-code-review/" "scripts/qa-pr-approve.sh" \
           "scripts/qa-gh.sh" "scripts/qa-review-status.sh" "policies/" "secrets/" "CODEOWNERS"; do
    run jq -e --arg p "$p" '(.sensitive_paths["Muso-AI/hydra"] // []) + (.sensitive_paths["*"] // []) | index($p)' "$pol"
    [ "$status" -eq 0 ]
  done
}

@test "guard3b: .github/CODEOWNERS is covered (GitHub honours it at HIGHER precedence than root)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["CODEOWNERS",".github/CODEOWNERS","docs/CODEOWNERS"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES=".github/CODEOWNERS" QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 901 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: docs/CODEOWNERS is covered too" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["CODEOWNERS",".github/CODEOWNERS","docs/CODEOWNERS"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="docs/CODEOWNERS" QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 902 "$NICK"
  [ "$status" -eq 11 ]
}

@test "guard3b: the SHIPPED policy covers all three GitHub CODEOWNERS locations" {
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  for p in "CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS"; do
    run jq -e --arg p "$p" '(.sensitive_paths["Muso-AI/hydra"] // []) | index($p)' "$pol"
    [ "$status" -eq 0 ]
  done
}

@test "guard3c: a MISSING author_deny key → exit 12 (absent must not read as empty allow-list)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'missing or null'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3c: a NULL author_deny → exit 12" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":null,
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
}

@test "guard3c: an EXPLICIT [] is still honoured as the deliberate policy flip" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}
