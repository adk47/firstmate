#!/usr/bin/env bats
# Tests for scripts/weekly-cleanup.sh — the weekly node-8 junk sweeper
# (stale /tmp entries by MTIME, hot-patch *.bak*/*.orig, apt autoremove).
#
# PATH-shadows muso + ssh + apt-get so a real Slack send / remote call /
# package mutation during a test fails loudly instead of touching the
# production box (this suite runs on node-8's self-hosted CI runner).
# Every filesystem path the script touches is overridden into a mktemp
# sandbox — the suite must never point at the real /tmp or /opt/hydra.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WC="$HYDRA_REPO/scripts/weekly-cleanup.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/tmproot" \
    "$TEST_TMPDIR/bakroot-a" "$TEST_TMPDIR/bakroot-b"

  # Refuse real network / package ops: stub ssh, muso, apt-get; never read
  # the real main.env.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  # muso stub: record argv, capture --text / --blocks-file for inspection.
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--blocks-file" ] && cp "$a" "$TEST_TMPDIR/last-blocks" 2>/dev/null
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  prev="$a"
done
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  # apt-get stub: record the invocation, mutate nothing.
  cat > "$TEST_TMPDIR/bin/apt-get" <<'STUB'
#!/bin/bash
echo "$*" >> "$TEST_TMPDIR/apt-calls.log"
exit 0
STUB
  # flock shim: macOS has no flock(1); use the real one when present (Linux CI).
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/muso" \
    "$TEST_TMPDIR/bin/apt-get" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  export WEEKLY_CLEANUP_TMP_ROOT="$TEST_TMPDIR/tmproot"
  export WEEKLY_CLEANUP_TMP_AGE_DAYS=14
  export WEEKLY_CLEANUP_BAK_ROOTS="$TEST_TMPDIR/bakroot-a $TEST_TMPDIR/bakroot-b"
  export WEEKLY_CLEANUP_BAK_AGE_DAYS=30
  export WEEKLY_CLEANUP_LOCKFILE="$TEST_TMPDIR/wc.lock"
  export WEEKLY_CLEANUP_SKIP_HOST_GUARD=1
  # CRITICAL: the CI runner IS node-8 — without this, a test run would
  # invoke the clone sweeper against the real workspace roots.
  export WEEKLY_CLEANUP_SKIP_SWEEP=1
  # MUSO_SLACK_ENV_FILE is absent by default → no token → slack-notify
  # silently skips the send (no muso call).
}

# /bin/rm + hash -r: the rm-failure test installs an rm stub in PATH; once
# the sandbox is deleted bash's hashed lookup would point at the dead stub.
teardown() { /bin/rm -rf "$TEST_TMPDIR"; hash -r; }

# Helper: set mtime N days into the past (-h: follow nothing, works on links).
old() { touch -h -d "$1 days ago" -- "$2"; }

# Helper: give slack-notify a token so it calls the (stubbed) muso.
slack_fixture() {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
}

# ──────────────────────────────────────────────────────────────
# /tmp category: age predicate, excludes, rails
# ──────────────────────────────────────────────────────────────

@test "old depth-1 file → deleted, counted, bytes freed > 0" {
  head -c 5000 /dev/zero > "$WEEKLY_CLEANUP_TMP_ROOT/stale.json"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/stale.json"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ ! -e "$WEEKLY_CLEANUP_TMP_ROOT/stale.json" ]
  [[ "$output" == *"tmp: deleted=1"* ]]
  [[ "$output" =~ TOTAL\ freed_kb=([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" -gt 0 ]
}

@test "fresh depth-1 file → kept" {
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/recent.json"
  old 3 "$WEEKLY_CLEANUP_TMP_ROOT/recent.json"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/recent.json" ]
  [[ "$output" == *"tmp: deleted=0"* ]]
}

@test "old depth-1 directory → deleted recursively" {
  mkdir -p "$WEEKLY_CLEANUP_TMP_ROOT/dead-clone/nested"
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/dead-clone/nested/f"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/dead-clone/nested/f"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/dead-clone/nested"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/dead-clone"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ ! -e "$WEEKLY_CLEANUP_TMP_ROOT/dead-clone" ]
  [[ "$output" == *"tmp: deleted=1"* ]]
}

@test "default excludes survive despite age (systemd-private/openclaw/lock.d)" {
  mkdir "$WEEKLY_CLEANUP_TMP_ROOT/systemd-private-zz"
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/openclaw-foo"
  mkdir "$WEEKLY_CLEANUP_TMP_ROOT/hydra-deploy.lock.d"
  old 40 "$WEEKLY_CLEANUP_TMP_ROOT/systemd-private-zz"
  old 40 "$WEEKLY_CLEANUP_TMP_ROOT/openclaw-foo"
  old 40 "$WEEKLY_CLEANUP_TMP_ROOT/hydra-deploy.lock.d"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/systemd-private-zz" ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/openclaw-foo" ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/hydra-deploy.lock.d" ]
  [[ "$output" == *"excluded=3"* ]]
  [[ "$output" == *"tmp: deleted=0"* ]]
}

@test "WEEKLY_CLEANUP_TMP_EXCLUDES override REPLACES the default list" {
  export WEEKLY_CLEANUP_TMP_EXCLUDES='keepme-*'
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/keepme-x"
  mkdir "$WEEKLY_CLEANUP_TMP_ROOT/systemd-private-zz"
  old 40 "$WEEKLY_CLEANUP_TMP_ROOT/keepme-x"
  old 40 "$WEEKLY_CLEANUP_TMP_ROOT/systemd-private-zz"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/keepme-x" ]
  [ ! -e "$WEEKLY_CLEANUP_TMP_ROOT/systemd-private-zz" ]
}

@test "active-content rail: old dir with one fresh nested file → kept" {
  mkdir -p "$WEEKLY_CLEANUP_TMP_ROOT/live-clone/sub"
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/live-clone/sub/fresh"
  old 1 "$WEEKLY_CLEANUP_TMP_ROOT/live-clone/sub/fresh"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/live-clone/sub"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/live-clone"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/live-clone/sub/fresh" ]
  [[ "$output" == *"active_skipped=1"* ]]
  [[ "$output" == *"tmp: deleted=0"* ]]
}

@test "old depth-1 symlink: link removed, target untouched" {
  echo precious > "$TEST_TMPDIR/target-file"
  ln -s "$TEST_TMPDIR/target-file" "$WEEKLY_CLEANUP_TMP_ROOT/stale-link"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/stale-link"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ ! -e "$WEEKLY_CLEANUP_TMP_ROOT/stale-link" ]
  [ -e "$TEST_TMPDIR/target-file" ]
  [[ "$output" == *"tmp: deleted=1"* ]]
}

# ──────────────────────────────────────────────────────────────
# Structural guards (fail-closed)
# ──────────────────────────────────────────────────────────────

@test "tmp root missing → exit 1, nothing else deleted" {
  export WEEKLY_CLEANUP_TMP_ROOT="$TEST_TMPDIR/nonexistent"
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"
  old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC"
  [ "$status" -eq 1 ]
  [ -e "$TEST_TMPDIR/bakroot-a/dead.bak" ]
}

@test "tmp root is a symlink → exit 1 (refuses)" {
  mkdir "$TEST_TMPDIR/real-tmp"
  ln -s "$TEST_TMPDIR/real-tmp" "$TEST_TMPDIR/tmp-link"
  export WEEKLY_CLEANUP_TMP_ROOT="$TEST_TMPDIR/tmp-link"
  run bash "$WC"
  [ "$status" -eq 1 ]
}

@test "tmp root '/' → exit 1 (refuses)" {
  export WEEKLY_CLEANUP_TMP_ROOT="/"
  run bash "$WC"
  [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────
# .bak / .orig category
# ──────────────────────────────────────────────────────────────

@test "all four bak patterns >30d deleted in BOTH roots; 5-day-old kept" {
  for r in "$TEST_TMPDIR/bakroot-a" "$TEST_TMPDIR/bakroot-b"; do
    mkdir -p "$r/deep/nest"
    for f in "$r/a.bak" "$r/deep/b.bak.20260101T000000Z" "$r/deep/nest/c.bak-123" "$r/d.orig"; do
      echo x > "$f"; old 40 "$f"
    done
    echo x > "$r/recent.bak"; old 5 "$r/recent.bak"
  done
  run bash "$WC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bak: deleted=8"* ]]
  [ ! -e "$TEST_TMPDIR/bakroot-a/a.bak" ]
  [ ! -e "$TEST_TMPDIR/bakroot-b/deep/nest/c.bak-123" ]
  [ -e "$TEST_TMPDIR/bakroot-a/recent.bak" ]
  [ -e "$TEST_TMPDIR/bakroot-b/recent.bak" ]
}

@test "pattern tightness: foo.bakery and foo.original survive at any age" {
  echo x > "$TEST_TMPDIR/bakroot-a/foo.bakery"
  echo x > "$TEST_TMPDIR/bakroot-a/foo.original"
  old 100 "$TEST_TMPDIR/bakroot-a/foo.bakery"
  old 100 "$TEST_TMPDIR/bakroot-a/foo.original"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/bakroot-a/foo.bakery" ]
  [ -e "$TEST_TMPDIR/bakroot-a/foo.original" ]
  [[ "$output" == *"bak: deleted=0"* ]]
}

@test "missing bak root → skipped with note, exit 0, other root still cleaned" {
  export WEEKLY_CLEANUP_BAK_ROOTS="$TEST_TMPDIR/nonexistent-root $TEST_TMPDIR/bakroot-a"
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"
  old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/bakroot-a/dead.bak" ]
  [[ "$output" == *"bak root missing, skipped"* ]]
}

@test "repo invariant: no *.bak* / *.orig file is tracked in git" {
  # The cleanup deletes these patterns on the server without consulting git
  # (/opt/hydra has no .git). Safe only while the repo never tracks one —
  # this test turns that assumption into a CI gate.
  run -0 bash -c 'cd "$1" && git ls-files' _ "$HYDRA_REPO"
  [ -n "$output" ]   # guard against a vacuous pass outside a git checkout
  run bash -c 'cd "$1" && git ls-files | grep -E "\.bak(\.|-|$)|\.orig$"' _ "$HYDRA_REPO"
  [ "$status" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────
# --dry-run
# ──────────────────────────────────────────────────────────────

@test "--dry-run: deletes nothing, prints would-delete lines, no muso, no apt" {
  slack_fixture
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/stale"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/stale"
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"
  old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC" --dry-run
  [ "$status" -eq 0 ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/stale" ]
  [ -e "$TEST_TMPDIR/bakroot-a/dead.bak" ]
  [[ "$output" == *"DRY-RUN: would delete"* ]]
  [ ! -s "$STUB_CALLS" ]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
}

# ──────────────────────────────────────────────────────────────
# Slack summary
# ──────────────────────────────────────────────────────────────

@test "real run posts Block Kit blocks + counts to #clio_devops as devops bot" {
  slack_fixture
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/stale"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/stale"
  run bash "$WC"
  [ "$status" -eq 0 ]
  grep -q -- '--bot devops' "$STUB_CALLS"
  grep -q -- '--channel C0ADV2W76G4' "$STUB_CALLS"
  grep -q -- '--requester' "$STUB_CALLS"
  # Block Kit blocks were sent and are valid JSON (python-built payload).
  [ -f "$TEST_TMPDIR/last-blocks" ]
  run python3 -m json.tool "$TEST_TMPDIR/last-blocks"
  [ "$status" -eq 0 ]
  grep -q 'deleted=1' "$TEST_TMPDIR/last-text"
}

@test "zero-work run still posts a summary (silence means broken)" {
  slack_fixture
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'deleted=0' "$TEST_TMPDIR/last-text"
}

@test "Slack delivery is best-effort: muso failure → still exit 0" {
  slack_fixture
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/bin/bash
exit 7
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  run bash "$WC"
  [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# apt step
# ──────────────────────────────────────────────────────────────

@test "real run invokes apt-get autoremove + autoclean (stubbed)" {
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/apt-calls.log" ]
  run cat "$TEST_TMPDIR/apt-calls.log"
  [[ "$output" == *"autoremove"* ]]
  [[ "$output" == *"autoclean"* ]]
}

@test "WEEKLY_CLEANUP_SKIP_APT=1 → apt never invoked" {
  export WEEKLY_CLEANUP_SKIP_APT=1
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
  [[ "$output" == *"apt: skipped"* ]]
}

# ──────────────────────────────────────────────────────────────
# Error handling + idempotence
# ──────────────────────────────────────────────────────────────

@test "per-file rm failure → counted as error, exit 0, error in payload" {
  slack_fixture
  cat > "$TEST_TMPDIR/bin/rm" <<'STUB'
#!/bin/bash
for a in "$@"; do
  if [ -n "${WEEKLY_CLEANUP_TEST_RM_FAIL:-}" ] && [ "$a" = "$WEEKLY_CLEANUP_TEST_RM_FAIL" ]; then
    echo "rm: stub: cannot remove '$a'" >&2
    exit 1
  fi
done
exec /bin/rm "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/rm"
  export WEEKLY_CLEANUP_TEST_RM_FAIL="$WEEKLY_CLEANUP_TMP_ROOT/stuck"
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/stuck"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/stuck"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$WEEKLY_CLEANUP_TMP_ROOT/stuck" ]
  [[ "$output" == *"errors=1"* ]]
  [[ "$output" == *"tmp: deleted=0"* ]]
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'errors=1' "$TEST_TMPDIR/last-text"
}

@test "idempotent: immediate second run deletes 0" {
  echo x > "$WEEKLY_CLEANUP_TMP_ROOT/stale"
  old 20 "$WEEKLY_CLEANUP_TMP_ROOT/stale"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmp: deleted=1"* ]]
  run bash "$WC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmp: deleted=0"* ]]
}

@test "unknown flag → exit 2" {
  run bash "$WC" --bogus
  [ "$status" -eq 2 ]
}

@test "clone sweeper is wired in and dry-run propagates (hermetic roots)" {
  # Point the sweeper at sandbox roots so enabling it is safe, then verify
  # the weekly wrapper invokes it and forwards --dry-run.
  mkdir -p "$TEST_TMPDIR/sweeproot/repos" "$TEST_TMPDIR/sweeproot/ws"
  export WEEKLY_CLEANUP_SKIP_SWEEP=0
  export SWEEP_REPOS_ROOT="$TEST_TMPDIR/sweeproot/repos"
  export SWEEP_WS_ROOT="$TEST_TMPDIR/sweeproot/ws"
  export SWEEP_SKIP_HOST_GUARD=1
  export SWEEP_LOCKFILE="$TEST_TMPDIR/sweep.lock"
  run bash "$WC" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"clone-sweep: ok"* ]]
  [[ "$output" == *"[sweep-clones"* ]]
}

@test "a failing clone sweeper fails the weekly cleanup (structural breakage is not masked)" {
  # The sweeper's exit 1/2 mean the category never ran. Masking that would
  # leave systemd reporting a healthy weekly cleanup — exactly what this
  # script's exit contract forbids.
  mkdir -p "$TEST_TMPDIR/sweeproot/ws"
  export WEEKLY_CLEANUP_SKIP_SWEEP=0
  # Missing repos root => the sweeper's structural refusal, exit 1.
  export SWEEP_REPOS_ROOT="$TEST_TMPDIR/sweeproot/does-not-exist"
  export SWEEP_WS_ROOT="$TEST_TMPDIR/sweeproot/ws"
  export SWEEP_SKIP_HOST_GUARD=1
  export SWEEP_LOCKFILE="$TEST_TMPDIR/sweep.lock"
  run bash "$WC" --dry-run
  [ "$status" -eq 1 ]
  # The summary still had to be emitted before the failure surfaced.
  [[ "$output" == *"clone-sweep: failed"* ]]
  [[ "$output" == *"TOTAL freed_kb="* ]]
}

@test "clone sweeper skip knob is honored" {
  run bash "$WC" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"clone-sweep: skipped"* ]]
}
