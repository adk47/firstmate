#!/usr/bin/env bats
# Tests for scripts/lib/cto-push-audit-guard.sh — the git pre-push hook that
# refuses a CTO push lacking a recent audit row for the target repo. This is the
# mechanical backstop behind the prose guard that keeps the standalone ship-kit
# `fix`/`ship` skills from bypassing cto-codex-coding's audit rail (PR #582).
#
# Hermetic: no network, no openclaw, no real audit dir — every case points
# CTO_AUDIT_DIR at a temp dir and pins "now" via CTO_PUSH_GUARD_NOW.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HOOK="$HYDRA_REPO/scripts/lib/cto-push-audit-guard.sh"

# Fixed "now": 2026-06-25T12:00:00Z (midday, so today/yesterday are unambiguous).
NOW=1782648000
REPO="Muso-AI/core-backend"
URL="https://github.com/Muso-AI/core-backend.git"

# Portable epoch -> UTC date / ISO8601 (GNU date first, then BSD/macOS).
_date() { date -u -d "@$1" "+$2" 2>/dev/null || date -u -r "$1" "+$2" 2>/dev/null; }
iso()   { _date "$1" "%Y-%m-%dT%H:%M:%SZ"; }
ymd()   { _date "$1" "%Y-%m-%d"; }

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export CTO_AUDIT_DIR="$TEST_TMPDIR/audit"
  export CTO_PUSH_GUARD_NOW="$NOW"
  mkdir -p "$CTO_AUDIT_DIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Append an audit row {ts, target} to the log file for the given epoch's date.
add_row() { # <epoch> <target>
  local epoch="$1" target="$2" f
  f="$CTO_AUDIT_DIR/$(ymd "$epoch").jsonl"
  printf '{"ts":"%s","agent":"cto","action":"code-change","target":"%s","requester":"U0AL36NADEY","authorization":"god-mode"}\n' \
    "$(iso "$epoch")" "$target" >> "$f"
}

run_hook() { run bash "$HOOK" origin "$URL" </dev/null; }

# Run the hook with a pushed-ref line on stdin (as git feeds a pre-push hook):
# "<local-ref> <local-oid> <remote-ref> <remote-oid>".
run_hook_ref() { # <remote-ref>
  run bash "$HOOK" origin "$URL" <<<"refs/heads/local 0 $1 0"
}
Z="0000000000000000000000000000000000000000"

@test "passes with a fresh audit row for the repo" {
  add_row "$(( NOW - 1800 ))" "$REPO"   # 30 min ago
  run_hook
  [ "$status" -eq 0 ]
}

@test "blocks when no audit row exists at all" {
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"no CTO audit row"* ]]
}

@test "blocks when the only audit row is older than the window" {
  add_row "$(( NOW - 8 * 3600 ))" "$REPO"   # 8h ago, default window is 6h
  run_hook
  [ "$status" -eq 1 ]
}

@test "blocks when the recent audit row is for a different repo" {
  add_row "$(( NOW - 600 ))" "Muso-AI/web-credits"
  run_hook
  [ "$status" -eq 1 ]
}

@test "passes for an SSH-form remote URL" {
  add_row "$(( NOW - 600 ))" "$REPO"
  run bash "$HOOK" origin "git@github.com:Muso-AI/core-backend.git" </dev/null
  [ "$status" -eq 0 ]
}

@test "passes when the row crossed UTC midnight into yesterday's file (within window)" {
  # 2h before midday-now still falls on 'today'; force a row landing in
  # yesterday's file by pinning now to just after midnight.
  export CTO_PUSH_GUARD_NOW="$(( NOW - 12*3600 + 1800 ))"   # 00:30Z
  add_row "$(( NOW - 12*3600 - 1800 ))" "$REPO"             # 23:30Z previous day
  run bash "$HOOK" origin "$URL" </dev/null
  [ "$status" -eq 0 ]
}

@test "respects a widened window via CTO_PUSH_GUARD_WINDOW_HOURS" {
  add_row "$(( NOW - 8 * 3600 ))" "$REPO"   # 8h ago
  CTO_PUSH_GUARD_WINDOW_HOURS=12 run bash "$HOOK" origin "$URL" </dev/null
  [ "$status" -eq 0 ]
}

@test "blocks (fail-closed) when the remote URL can't be resolved to a repo" {
  add_row "$(( NOW - 600 ))" "$REPO"
  run bash "$HOOK" origin "not-a-url" </dev/null
  [ "$status" -eq 1 ]
}

# --- Branch-shape rail (refs on stdin) ---

@test "passes a cto/ branch push with a fresh audit row" {
  add_row "$(( NOW - 600 ))" "$REPO"
  run_hook_ref "refs/heads/cto/fix-login-20260625-101500"
  [ "$status" -eq 0 ]
}

@test "blocks a non-cto/ branch (fix/...) even with a fresh audit row" {
  add_row "$(( NOW - 600 ))" "$REPO"
  run_hook_ref "refs/heads/fix/login"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cto/<slug>"* ]]
}

@test "blocks a push to a default branch (main)" {
  add_row "$(( NOW - 600 ))" "$REPO"
  run_hook_ref "refs/heads/main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"default branch"* ]]
}

@test "ignores non-branch refs (tags) for the branch rail" {
  add_row "$(( NOW - 600 ))" "$REPO"
  run_hook_ref "refs/tags/v1"
  [ "$status" -eq 0 ]
}
