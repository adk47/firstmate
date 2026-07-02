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
        printf '%s' "$STUB_THREADS_JSON" | jq -r "$(_jqflt "$@")"
      else
        echo "${STUB_OPEN_BLOCKERS:-0}"                 # count of unresolved Critical/Important threads
      fi
    else
      echo "${STUB_ME:-adk47}"                        # gh api user --jq .login
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
