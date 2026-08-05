#!/usr/bin/env bats
# Tests for the skill hot-patch announce/acknowledge pair used by
# deploy.sh Step 4a. PATH-shadows ssh and slack-notify so these
# tests never touch real node-8 or fire real Slack (see
# memory/feedback_bats_must_stub_openclaw.md and the 2026-05-06
# PR #245 incident).
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
ANNOUNCE_SRC="$REPO_ROOT/scripts/lib/announce-skill-hot-patch.sh"
ACK_LIB="$REPO_ROOT/scripts/lib/acknowledge-hot-patch-drift.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Fake server filesystem rooted at $TEST_TMPDIR/server. The ack
  # filter uses $DEPLOY_PATH as the prefix when resolving each
  # drifted file's absolute server path; pointing it here means
  # HYDRA_LOCAL=true can stat real local files without ssh.
  export DEPLOY_PATH="$TEST_TMPDIR/server"
  mkdir -p "$DEPLOY_PATH/skills-all/foo"
  mkdir -p "$DEPLOY_PATH/skills-all/bar"

  export HYDRA_HOTPATCH_LOG="$TEST_TMPDIR/hot-patches.log"
  export HYDRA_HOTPATCH_ALLOWED_PREFIX="$DEPLOY_PATH/skills-all/"

  # PATH-shadow ssh so any accidental ssh call in HYDRA_LOCAL=false
  # paths fails loudly rather than reaching prod node-8. We don't
  # use HYDRA_LOCAL=false in these tests, but the guard is cheap.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Source the ack lib in a controlled scope, defining its required
# globals so the function under test has everything it needs without
# pulling in all of deploy.sh.
load_ack_lib() {
  HYDRA_LOCAL=true
  NODE8_USER=root
  NODE8_IP=127.0.0.1
  SSH_KEY=/dev/null
  SSH_OPTS_STR=""
  LOG_CALLS_FILE="$TEST_TMPDIR/log.calls"
  : > "$LOG_CALLS_FILE"
  log() { printf '%s\n' "$*" >> "$LOG_CALLS_FILE"; }
  # shellcheck disable=SC1090
  source "$ACK_LIB"
}

# Stage a file at $DEPLOY_PATH/<rel> with the given content. Returns
# the file's sha256 on stdout for the caller to use in announce.
stage_server_file() {
  local rel="$1" content="$2"
  printf '%s' "$content" > "$DEPLOY_PATH/$rel"
  sha256sum "$DEPLOY_PATH/$rel" | awk '{print $1}'
}

# Append a synthetic announce log line. Takes (epoch, writer, sha, abs_path).
# Canonicalises the path the same way the real announce script does so the
# ack filter's lookup (which canonicalises its own resolved abs) finds it.
append_announce() {
  local epoch="$1" writer="$2" sha="$3" abs_raw="$4"
  local abs iso
  abs=$(realpath "$abs_raw" 2>/dev/null || echo "$abs_raw")
  iso=$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || python3 -c "import time; print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime($epoch)))")
  printf '%s %s %s pid=12345 ppid=1 sha256=%s %s\n' \
    "$epoch" "$iso" "$writer" "$sha" "$abs" >> "$HYDRA_HOTPATCH_LOG"
}

# Build a synthetic rsync itemize line for a given relative path.
drift_line_for() {
  printf '>fcsT...... %s' "$1"
}

# ─── Ack filter behaviour ──────────────────────────────────────────

@test "no announce log → drift passes through unchanged" {
  load_ack_lib
  stage_server_file skills-all/foo/SKILL.md "preview bytes" >/dev/null
  drift=$(drift_line_for skills-all/foo/SKILL.md)

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ "$output" = "$drift" ]
  ! grep -q 'drift acknowledged' "$LOG_CALLS_FILE"
}

@test "fresh sha-matched announce → drift dropped, ack logged" {
  load_ack_lib
  sha=$(stage_server_file skills-all/foo/SKILL.md "preview bytes")
  now=$(date -u +%s)
  append_announce "$now" "nick" "$sha" "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  drift=$(drift_line_for skills-all/foo/SKILL.md)

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'drift acknowledged: skills-all/foo/SKILL.md' "$LOG_CALLS_FILE"
  grep -q 'by nick' "$LOG_CALLS_FILE"
}

@test "sha-mismatched announce → drift kept, no ack" {
  load_ack_lib
  stage_server_file skills-all/foo/SKILL.md "preview bytes" >/dev/null
  now=$(date -u +%s)
  # Announce the WRONG hash for this path.
  append_announce "$now" "nick" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  drift=$(drift_line_for skills-all/foo/SKILL.md)

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ "$output" = "$drift" ]
  ! grep -q 'drift acknowledged' "$LOG_CALLS_FILE"
}

@test "stale (>ack_window) announce → drift kept, no ack" {
  load_ack_lib
  export HYDRA_HOTPATCH_ACK_WINDOW=3600
  sha=$(stage_server_file skills-all/foo/SKILL.md "preview bytes")
  stale=$(( $(date -u +%s) - 7200 ))   # 2h ago, double the window
  append_announce "$stale" "nick" "$sha" "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  drift=$(drift_line_for skills-all/foo/SKILL.md)

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ "$output" = "$drift" ]
  ! grep -q 'drift acknowledged' "$LOG_CALLS_FILE"
}

@test "announce for unrelated path → drift kept, no ack" {
  load_ack_lib
  sha_foo=$(stage_server_file skills-all/foo/SKILL.md "preview bytes")
  stage_server_file skills-all/bar/SKILL.md "other content" >/dev/null
  now=$(date -u +%s)
  # Announce points at bar/, but drift is for foo/.
  append_announce "$now" "nick" "$sha_foo" "$DEPLOY_PATH/skills-all/bar/SKILL.md"
  drift=$(drift_line_for skills-all/foo/SKILL.md)

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ "$output" = "$drift" ]
  ! grep -q 'drift acknowledged' "$LOG_CALLS_FILE"
}

@test "prefix-collision path → drift kept (awk field-equality, not substring)" {
  load_ack_lib
  # Stage two files where one path is a substring of the other.
  mkdir -p "$DEPLOY_PATH/skills-all/gog" "$DEPLOY_PATH/skills-all/gogcli"
  sha_gog=$(stage_server_file skills-all/gog/SKILL.md "gog content")
  stage_server_file skills-all/gogcli/SKILL.md "different content" >/dev/null
  now=$(date -u +%s)
  # Announce points at gog/SKILL.md, drift is for gogcli/SKILL.md.
  append_announce "$now" "nick" "$sha_gog" "$DEPLOY_PATH/skills-all/gog/SKILL.md"
  drift=$(drift_line_for skills-all/gogcli/SKILL.md)

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ "$output" = "$drift" ]
  ! grep -q 'drift acknowledged' "$LOG_CALLS_FILE"
}

@test "multiple drift lines, partial ack → only acked one dropped" {
  load_ack_lib
  sha_foo=$(stage_server_file skills-all/foo/SKILL.md "preview foo")
  stage_server_file skills-all/bar/SKILL.md "preview bar" >/dev/null
  now=$(date -u +%s)
  append_announce "$now" "nick" "$sha_foo" "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  drift=$(printf '%s\n%s' \
    "$(drift_line_for skills-all/foo/SKILL.md)" \
    "$(drift_line_for skills-all/bar/SKILL.md)")

  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'skills-all/foo/SKILL.md'; then echo "the acked foo entry still appears in the remaining-drift output" >&2; false; fi
  echo "$output" | grep -q 'skills-all/bar/SKILL.md'
  grep -q 'drift acknowledged: skills-all/foo/SKILL.md' "$LOG_CALLS_FILE"
}

# ─── announce-skill-hot-patch.sh behaviour ─────────────────────────

@test "announce writes a well-formed log line" {
  stage_server_file skills-all/foo/SKILL.md "new content" >/dev/null
  sha=$(sha256sum "$DEPLOY_PATH/skills-all/foo/SKILL.md" | awk '{print $1}')

  run env HYDRA_HOTPATCH_LOG="$HYDRA_HOTPATCH_LOG" \
    HYDRA_HOTPATCH_ALLOWED_PREFIX="$HYDRA_HOTPATCH_ALLOWED_PREFIX" \
    ANNOUNCE_SHA="$sha" \
    "$ANNOUNCE_SRC" nick "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  [ "$status" -eq 0 ]

  line=$(tail -1 "$HYDRA_HOTPATCH_LOG")
  # Canonical form survives macOS /tmp → /private/tmp via realpath
  # in the announce script.
  canonical=$(realpath "$DEPLOY_PATH/skills-all/foo/SKILL.md")
  echo "$line" | grep -qE "^[0-9]+ [0-9T:Z-]+ nick pid=[0-9]+ ppid=[0-9?]+ sha256=$sha $(printf '%s' "$canonical" | sed 's:[][\\.*^$/]:\\&:g')$"
}

@test "announce rejects sha that is not 64 lowercase hex" {
  stage_server_file skills-all/foo/SKILL.md "x" >/dev/null
  run env HYDRA_HOTPATCH_LOG="$HYDRA_HOTPATCH_LOG" \
    HYDRA_HOTPATCH_ALLOWED_PREFIX="$HYDRA_HOTPATCH_ALLOWED_PREFIX" \
    ANNOUNCE_SHA="notasha" \
    "$ANNOUNCE_SRC" nick "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '64 lowercase hex'
  [ ! -s "$HYDRA_HOTPATCH_LOG" ]
}

@test "announce rejects writer with whitespace (positional parser guard)" {
  stage_server_file skills-all/foo/SKILL.md "x" >/dev/null
  sha=$(sha256sum "$DEPLOY_PATH/skills-all/foo/SKILL.md" | awk '{print $1}')
  run env HYDRA_HOTPATCH_LOG="$HYDRA_HOTPATCH_LOG" \
    HYDRA_HOTPATCH_ALLOWED_PREFIX="$HYDRA_HOTPATCH_ALLOWED_PREFIX" \
    ANNOUNCE_SHA="$sha" \
    "$ANNOUNCE_SRC" "aaron preview" "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'writer name must not contain whitespace'
  [ ! -s "$HYDRA_HOTPATCH_LOG" ]
}

@test "announce rejects target path with whitespace (positional parser guard)" {
  # Stage under the allowed prefix so the path-allowlist check passes
  # and the whitespace check is the gate that fires.
  mkdir -p "$DEPLOY_PATH/skills-all/foo bar"
  printf 'x' > "$DEPLOY_PATH/skills-all/foo bar/SKILL.md"
  sha=$(sha256sum "$DEPLOY_PATH/skills-all/foo bar/SKILL.md" | awk '{print $1}')
  run env HYDRA_HOTPATCH_LOG="$HYDRA_HOTPATCH_LOG" \
    HYDRA_HOTPATCH_ALLOWED_PREFIX="$HYDRA_HOTPATCH_ALLOWED_PREFIX" \
    ANNOUNCE_SHA="$sha" \
    "$ANNOUNCE_SRC" nick "$DEPLOY_PATH/skills-all/foo bar/SKILL.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'target path must not contain whitespace'
  [ ! -s "$HYDRA_HOTPATCH_LOG" ]
}

@test "announce rejects path outside allowed prefix" {
  mkdir -p "$TEST_TMPDIR/outside"
  printf 'x' > "$TEST_TMPDIR/outside/SKILL.md"
  sha=$(sha256sum "$TEST_TMPDIR/outside/SKILL.md" | awk '{print $1}')
  run env HYDRA_HOTPATCH_LOG="$HYDRA_HOTPATCH_LOG" \
    HYDRA_HOTPATCH_ALLOWED_PREFIX="$HYDRA_HOTPATCH_ALLOWED_PREFIX" \
    ANNOUNCE_SHA="$sha" \
    "$ANNOUNCE_SRC" nick "$TEST_TMPDIR/outside/SKILL.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'must be under'
  [ ! -s "$HYDRA_HOTPATCH_LOG" ]
}

@test "announce + ack end-to-end: real announce makes deploy filter accept" {
  load_ack_lib
  sha=$(stage_server_file skills-all/foo/SKILL.md "preview")
  run env HYDRA_HOTPATCH_LOG="$HYDRA_HOTPATCH_LOG" \
    HYDRA_HOTPATCH_ALLOWED_PREFIX="$HYDRA_HOTPATCH_ALLOWED_PREFIX" \
    ANNOUNCE_SHA="$sha" \
    "$ANNOUNCE_SRC" aaron "$DEPLOY_PATH/skills-all/foo/SKILL.md"
  [ "$status" -eq 0 ]

  drift=$(drift_line_for skills-all/foo/SKILL.md)
  run acknowledge_announced_hotpatches "$drift"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'drift acknowledged: skills-all/foo/SKILL.md' "$LOG_CALLS_FILE"
  grep -q 'by aaron' "$LOG_CALLS_FILE"
}
