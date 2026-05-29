#!/usr/bin/env bats
# Tests for scripts/qa-pr-approve.sh — the gated "approve-only" wrapper QA uses
# after a GO-verdict PR review. Every test PATH-shadows `gh` with a stub so the
# suite NEVER touches real GitHub (memory: bats must stub openclaw/gh — Clio's
# PR #245 fired 9 real Slack alerts from an unstubbed test).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-pr-approve.sh"

NICK="U0AL36NADEY"   # allowlisted requester

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export QA_PR_APPROVE_LOG_DIR="$TEST_TMPDIR/api-logs/github"
  export STUB_CALLS="$TEST_TMPDIR/gh-calls"
  : > "$STUB_CALLS"

  # Stub `gh`. Configurable via STUB_ME / STUB_AUTHOR / STUB_APPROVE_RC.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
sub="$1"; shift || true
case "$sub" in
  api)   echo "${STUB_ME:-adk47}" ;;                 # gh api user --jq .login
  pr)
    action="$1"; shift || true
    case "$action" in
      view)
        if printf '%s ' "$@" | grep -q 'author'; then
          echo "${STUB_AUTHOR:-nsollazzo}"           # PR author login
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
