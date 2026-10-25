#!/usr/bin/env bats
# Tests for scripts/clean-my-linux.sh: the node-8 disk cleaner's orchestrator
# (rule order, df early-stop, per-run caps, apply gate, one Slack report).
#
# The /tmp, clone and codex rules are DELEGATES (tmp-reaper.sh,
# sweep-workspace-clones.sh, codex-home-prune.sh): each keeps its own policy
# and its own suite, and every one is stubbed here. The /tmp pattern tests of
# the predecessor weekly-cleanup.bats (age TTLs, excludes, the old
# "active-content rail") exercised logic that no longer lives in this script;
# the reaper's open-handle guard (tmp-reaper.bats) is its replacement.
#
# PATH-shadows muso + ssh + apt-get + df so a real Slack send / remote call /
# package mutation during a test fails loudly instead of touching the
# production box (this suite runs on node-8's self-hosted CI runner).
# Every filesystem path the script touches is overridden into a mktemp
# sandbox, and the suite must never point at the real /tmp or /opt/hydra.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WC="$HYDRA_REPO/scripts/clean-my-linux.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/tmproot" "$TEST_TMPDIR/delegates" \
    "$TEST_TMPDIR/bakroot-a" "$TEST_TMPDIR/bakroot-b"

  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
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
  cat > "$TEST_TMPDIR/bin/apt-get" <<'STUB'
#!/bin/bash
echo "$*" >> "$TEST_TMPDIR/apt-calls.log"
exit 0
STUB
  # df stub: used% comes from $TEST_TMPDIR/df-pct (default 99 = every rule runs).
  cat > "$TEST_TMPDIR/bin/df" <<'STUB'
#!/bin/bash
pct="$(cat "$TEST_TMPDIR/df-pct" 2>/dev/null || echo 99)"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/test 1000 $pct $((100 - pct)) ${pct}% /"
STUB
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/"*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  echo 99 > "$TEST_TMPDIR/df-pct"

  # Delegate stubs: log "<name> <argv>", print $STUB_<NAME>_OUT, exit $STUB_<NAME>_RC.
  export DELEG_LOG="$TEST_TMPDIR/delegate-calls.log"; : > "$DELEG_LOG"
  local n
  for n in REAPER SWEEP CODEX; do
    cat > "$TEST_TMPDIR/delegates/$n" <<STUB
#!/bin/bash
echo "$n \$*" >> "\$DELEG_LOG"
[ -n "\${STUB_${n}_OUT:-}" ] && echo "\$STUB_${n}_OUT"
[ -n "\${STUB_${n}_HOOK:-}" ] && eval "\$STUB_${n}_HOOK"
exit "\${STUB_${n}_RC:-0}"
STUB
    chmod +x "$TEST_TMPDIR/delegates/$n"
  done
  export CLEAN_MY_LINUX_TMP_REAPER="$TEST_TMPDIR/delegates/REAPER"
  export CLEAN_MY_LINUX_SWEEP_SCRIPT="$TEST_TMPDIR/delegates/SWEEP"
  export CLEAN_MY_LINUX_CODEX_PRUNE="$TEST_TMPDIR/delegates/CODEX"

  export CLEAN_MY_LINUX_TMP_ROOT="$TEST_TMPDIR/tmproot"
  export CLEAN_MY_LINUX_BAK_ROOTS="$TEST_TMPDIR/bakroot-a $TEST_TMPDIR/bakroot-b"
  export CLEAN_MY_LINUX_BAK_AGE_DAYS=30
  export CLEAN_MY_LINUX_LOCKFILE="$TEST_TMPDIR/wc.lock"
  export CLEAN_MY_LINUX_STATE_DIR="$TEST_TMPDIR/state"
  export CLEAN_MY_LINUX_SKIP_HOST_GUARD=1
  # CRITICAL: the CI runner IS node-8. Delegates are stubbed above; this also
  # opts out of R2 by default so an unstubbed run can never sweep real roots.
  export CLEAN_MY_LINUX_SKIP_SWEEP=1
}

# /bin/rm + hash -r: the rm-failure test installs an rm stub in PATH.
teardown() { /bin/rm -rf "$TEST_TMPDIR"; hash -r; }

old() { touch -h -d "$1 days ago" -- "$2"; }

slack_fixture() {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
}

# ──────────────────────────────────────────────────────────────
# Apply gate (default dry-run) + mode propagation
# ──────────────────────────────────────────────────────────────

@test "default (no flags) deletes NOTHING and runs every delegate in --dry-run" {
  export CLEAN_MY_LINUX_SKIP_SWEEP=0
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"; old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/bakroot-a/dead.bak" ]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
  [[ "$output" == *"mode=dry-run"* ]]
  grep -qx 'REAPER --dry-run' "$DELEG_LOG"
  grep -qx 'SWEEP --dry-run' "$DELEG_LOG"
  grep -qx 'CODEX --dry-run' "$DELEG_LOG"
  ! grep -q -- '--apply' "$DELEG_LOG"
}

@test "--apply propagates --apply to every delegate and really deletes" {
  export CLEAN_MY_LINUX_SKIP_SWEEP=0
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"; old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/bakroot-a/dead.bak" ]
  grep -qx 'REAPER --apply' "$DELEG_LOG"
  grep -qx 'SWEEP --apply' "$DELEG_LOG"
  grep -qx 'CODEX --apply' "$DELEG_LOG"
  ! grep -q -- '--dry-run' "$DELEG_LOG"
  [ -f "$TEST_TMPDIR/apt-calls.log" ]
}

@test "rules run in the documented order" {
  export CLEAN_MY_LINUX_SKIP_SWEEP=0
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 "$DELEG_LOG" | paste -sd, -)" = "REAPER,SWEEP,CODEX" ]
}

@test "dry-run still posts its Slack report (that is how the first prod run is read)" {
  slack_fixture
  run bash "$WC"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'DRY-RUN' "$TEST_TMPDIR/last-text"
}

@test "unknown flag → exit 2" {
  run bash "$WC" --bogus
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────────────────────
# df early-stop
# ──────────────────────────────────────────────────────────────

@test "already at/below target: no rule runs, target-reached-after=none" {
  echo 60 > "$TEST_TMPDIR/df-pct"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ ! -s "$DELEG_LOG" ]
  [[ "$output" == *"target-reached-after=none"* ]]
}

@test "target reached mid-table: later rules are skipped, named in the report" {
  export STUB_REAPER_HOOK='echo 60 > "$TEST_TMPDIR/df-pct"'
  export CLEAN_MY_LINUX_SKIP_SWEEP=0
  slack_fixture
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 "$DELEG_LOG")" = "REAPER" ]
  [[ "$output" == *"target-reached-after=tmp-reaper"* ]]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
  grep -q 'target-reached-after=tmp-reaper' "$TEST_TMPDIR/last-text"
}

@test "TARGET_USED_PCT is honored (66% runs at default 65, stops at 70)" {
  echo 66 > "$TEST_TMPDIR/df-pct"
  run bash "$WC" --apply
  [ -s "$DELEG_LOG" ]
  : > "$DELEG_LOG"
  CLEAN_MY_LINUX_TARGET_USED_PCT=70 run bash "$WC" --apply
  [ ! -s "$DELEG_LOG" ]
}

@test "unreadable df fails closed (keeps cleaning) and the warning is visible" {
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/df"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ -s "$DELEG_LOG" ]
  # The warning must reach the report and must not poison $(used_pct): on
  # stdout it becomes a two-line non-number and `[ -le ]` errors out.
  grep -q "cannot read df" <<<"$output"
  if grep -q "integer expression" <<<"$output"; then false; fi
}

@test "a zero cap deletes nothing: MAX_ENTRIES=0 and MAX_BYTES=0 never enter a rule" {
  CLEAN_MY_LINUX_MAX_ENTRIES=0 run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ ! -s "$DELEG_LOG" ]
  [[ "$output" == *"cap-hit=entries"* ]]
  CLEAN_MY_LINUX_MAX_BYTES=0 run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ ! -s "$DELEG_LOG" ]
  [[ "$output" == *"cap-hit=bytes"* ]]
}

# ──────────────────────────────────────────────────────────────
# Per-run caps
# ──────────────────────────────────────────────────────────────

@test "MAX_ENTRIES stops the run mid-table, exits 0, reports cap-hit=entries" {
  export STUB_REAPER_OUT="tmp-reaper: done reaped=5 skipped_busy=0 reclaimed_kib=10 failures=0"
  export CLEAN_MY_LINUX_MAX_ENTRIES=5 CLEAN_MY_LINUX_SKIP_SWEEP=0
  slack_fixture
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 "$DELEG_LOG")" = "REAPER" ]
  [[ "$output" == *"cap-hit=entries"* ]]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
  grep -q 'cap-hit=entries' "$TEST_TMPDIR/last-text"
}

@test "a delegate may overshoot MAX_ENTRIES: the overshoot is reported, not clamped, and no later rule runs" {
  export STUB_REAPER_OUT="tmp-reaper: done reaped=5000 skipped_busy=0 reclaimed_kib=10 failures=0"
  export CLEAN_MY_LINUX_MAX_ENTRIES=5 CLEAN_MY_LINUX_SKIP_SWEEP=0
  slack_fixture
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 "$DELEG_LOG")" = "REAPER" ]
  [ "$(wc -l < "$DELEG_LOG")" -eq 1 ]
  [[ "$output" == *"cap-hit=entries"* ]]
  [[ "$output" == *"entries=5000"* ]]
  grep -q 'cap-hit=entries' "$TEST_TMPDIR/last-text"
}

@test "MAX_BYTES stops the run mid-table, exits 0, reports cap-hit=bytes" {
  export STUB_REAPER_OUT="tmp-reaper: done reaped=1 skipped_busy=0 reclaimed_kib=2048 failures=0"
  export CLEAN_MY_LINUX_MAX_BYTES=2097152 CLEAN_MY_LINUX_SKIP_SWEEP=0
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 "$DELEG_LOG")" = "REAPER" ]
  [[ "$output" == *"cap-hit=bytes"* ]]
}

@test "below both caps nothing trips" {
  export STUB_REAPER_OUT="tmp-reaper: done reaped=4 skipped_busy=0 reclaimed_kib=2047 failures=0"
  export CLEAN_MY_LINUX_MAX_ENTRIES=5 CLEAN_MY_LINUX_MAX_BYTES=2097152
  run bash "$WC" --apply
  [[ "$output" != *"cap-hit"* ]]
  grep -q CODEX "$DELEG_LOG"
}

@test "R4 is capped per entry: MAX_ENTRIES=2 deletes exactly 2 of 3 old .bak files" {
  local f
  for f in a b c; do echo x > "$TEST_TMPDIR/bakroot-a/$f.bak"; old 40 "$TEST_TMPDIR/bakroot-a/$f.bak"; done
  export CLEAN_MY_LINUX_MAX_ENTRIES=2
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(find "$TEST_TMPDIR/bakroot-a" -name '*.bak' | wc -l)" -eq 1 ]
  [[ "$output" == *"cap-hit=entries"* ]]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
}

@test "R4 never overshoots MAX_BYTES: an entry that would cross the budget is kept" {
  local f
  for f in a b; do head -c 8192 /dev/zero > "$TEST_TMPDIR/bakroot-a/$f.bak"; old 40 "$TEST_TMPDIR/bakroot-a/$f.bak"; done
  export CLEAN_MY_LINUX_MAX_BYTES=12288
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ "$(find "$TEST_TMPDIR/bakroot-a" -name '*.bak' | wc -l)" -eq 1 ]
  [[ "$output" == *"cap-hit=bytes"* ]]
}

@test "R4 keeps a first backup that is larger than the whole byte budget" {
  head -c 16384 /dev/zero > "$TEST_TMPDIR/bakroot-a/big.bak"; old 40 "$TEST_TMPDIR/bakroot-a/big.bak"
  export CLEAN_MY_LINUX_MAX_BYTES=8192
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/bakroot-a/big.bak" ]
  [[ "$output" == *"cap-hit=bytes"* ]]
}

@test "non-numeric cap fails loud with exit 2, deletes nothing" {
  CLEAN_MY_LINUX_MAX_ENTRIES=lots run bash "$WC" --apply
  [ "$status" -eq 2 ]
  [ ! -s "$DELEG_LOG" ]
}

# ──────────────────────────────────────────────────────────────
# Delegates: missing / failing
# ──────────────────────────────────────────────────────────────

@test "a MISSING codex-home-prune.sh is skipped, run still exits 0" {
  export CLEAN_MY_LINUX_CODEX_PRUNE="$TEST_TMPDIR/delegates/does-not-exist"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"rule codex-prune: skipped (script missing)"* ]]
  [ -f "$TEST_TMPDIR/apt-calls.log" ]
}

@test "delegate exit 1 propagates, after the summary, Slack post and later rules" {
  export STUB_REAPER_RC=1
  slack_fixture
  run bash "$WC" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"rule tmp-reaper: failed (exit 1)"* ]]
  grep -q CODEX "$DELEG_LOG"
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'errors=1' "$TEST_TMPDIR/last-text"
}

@test "delegate exit 2 propagates" {
  export STUB_CODEX_RC=2
  run bash "$WC" --apply
  [ "$status" -eq 2 ]
}

@test "the FIRST failing delegate's rc wins" {
  export STUB_REAPER_RC=1 STUB_CODEX_RC=2
  run bash "$WC" --apply
  [ "$status" -eq 1 ]
}

@test "real clone sweeper is wired in and dry-run propagates (hermetic roots)" {
  mkdir -p "$TEST_TMPDIR/sweeproot/repos" "$TEST_TMPDIR/sweeproot/ws"
  export CLEAN_MY_LINUX_SKIP_SWEEP=0
  export CLEAN_MY_LINUX_SWEEP_SCRIPT="$HYDRA_REPO/scripts/sweep-workspace-clones.sh"
  export SWEEP_REPOS_ROOT="$TEST_TMPDIR/sweeproot/repos"
  export SWEEP_WS_ROOT="$TEST_TMPDIR/sweeproot/ws"
  export SWEEP_SKIP_HOST_GUARD=1
  export SWEEP_LOCKFILE="$TEST_TMPDIR/sweep.lock"
  run bash "$WC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rule clone-sweep: ok"* ]]
  [[ "$output" == *"[sweep-clones"* ]]
}

@test "a failing real clone sweeper fails the run (structural breakage is not masked)" {
  mkdir -p "$TEST_TMPDIR/sweeproot/ws"
  export CLEAN_MY_LINUX_SKIP_SWEEP=0
  export CLEAN_MY_LINUX_SWEEP_SCRIPT="$HYDRA_REPO/scripts/sweep-workspace-clones.sh"
  export SWEEP_REPOS_ROOT="$TEST_TMPDIR/sweeproot/does-not-exist"
  export SWEEP_WS_ROOT="$TEST_TMPDIR/sweeproot/ws"
  export SWEEP_SKIP_HOST_GUARD=1
  export SWEEP_LOCKFILE="$TEST_TMPDIR/sweep.lock"
  run bash "$WC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rule clone-sweep: failed"* ]]
  [[ "$output" == *"TOTAL entries="* ]]
}

@test "clone sweeper skip knob is honored" {
  run bash "$WC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rule clone-sweep: skipped"* ]]
  ! grep -q SWEEP "$DELEG_LOG"
}

# ──────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────
# Structural guards (fail-closed)
# ──────────────────────────────────────────────────────────────

@test "tmp root missing → exit 1, nothing else deleted" {
  export CLEAN_MY_LINUX_TMP_ROOT="$TEST_TMPDIR/nonexistent"
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"
  old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC"
  [ "$status" -eq 1 ]
  [ -e "$TEST_TMPDIR/bakroot-a/dead.bak" ]
}

@test "tmp root is a symlink → exit 1 (refuses)" {
  mkdir "$TEST_TMPDIR/real-tmp"
  ln -s "$TEST_TMPDIR/real-tmp" "$TEST_TMPDIR/tmp-link"
  export CLEAN_MY_LINUX_TMP_ROOT="$TEST_TMPDIR/tmp-link"
  run bash "$WC"
  [ "$status" -eq 1 ]
}

@test "tmp root '/' → exit 1 (refuses)" {
  export CLEAN_MY_LINUX_TMP_ROOT="/"
  run bash "$WC"
  [ "$status" -eq 1 ]
}

@test "tmp root spelled as root ('//', '///', '/.') → exit 1; a legit trailing slash still runs" {
  local spelling
  for spelling in "//" "///" "/."; do
    : > "$DELEG_LOG"
    CLEAN_MY_LINUX_TMP_ROOT="$spelling" run bash "$WC" --apply
    [ "$status" -eq 1 ] || { echo "spelling '$spelling' got status $status: $output"; return 1; }
    [ ! -s "$DELEG_LOG" ]
  done
  mkdir -p "$TEST_TMPDIR/tmproot-slash"
  : > "$DELEG_LOG"
  CLEAN_MY_LINUX_TMP_ROOT="$TEST_TMPDIR/tmproot-slash/" run bash "$WC" --apply
  [ "$status" -eq 0 ]
  grep -q REAPER "$DELEG_LOG"
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
  run bash "$WC" --apply
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
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/bakroot-a/foo.bakery" ]
  [ -e "$TEST_TMPDIR/bakroot-a/foo.original" ]
  [[ "$output" == *"bak: deleted=0"* ]]
}

@test "missing bak root → skipped with note, exit 0, other root still cleaned" {
  export CLEAN_MY_LINUX_BAK_ROOTS="$TEST_TMPDIR/nonexistent-root $TEST_TMPDIR/bakroot-a"
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"
  old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC" --apply
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
# Slack summary
# ──────────────────────────────────────────────────────────────

@test "real run posts Block Kit blocks + counts to #clio_devops as devops bot" {
  slack_fixture
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"; old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  grep -q -- '--bot devops' "$STUB_CALLS"
  grep -q -- '--channel C0ADV2W76G4' "$STUB_CALLS"
  grep -q -- '--requester' "$STUB_CALLS"
  [ -f "$TEST_TMPDIR/last-blocks" ]
  run python3 -m json.tool "$TEST_TMPDIR/last-blocks"
  [ "$status" -eq 0 ]
  grep -q 'entries=1' "$TEST_TMPDIR/last-text"
}

@test "zero-work run still posts a summary (silence means broken)" {
  slack_fixture
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'entries=0' "$TEST_TMPDIR/last-text"
}

@test "Slack delivery is best-effort: muso failure → still exit 0" {
  slack_fixture
  printf '#!/bin/bash\nexit 7\n' > "$TEST_TMPDIR/bin/muso"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# apt step: once per 24h
# ──────────────────────────────────────────────────────────────

@test "--apply invokes apt-get autoremove + autoclean (stubbed)" {
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  run cat "$TEST_TMPDIR/apt-calls.log"
  [[ "$output" == *"autoremove"* ]]
  [[ "$output" == *"autoclean"* ]]
}

@test "apt watermark suppresses a second apt inside 24h, allows it after" {
  run bash "$WC" --apply
  [ "$(grep -c autoremove "$TEST_TMPDIR/apt-calls.log")" -eq 1 ]
  [ -e "$TEST_TMPDIR/state/apt.last" ]
  run bash "$WC" --apply
  [ "$(grep -c autoremove "$TEST_TMPDIR/apt-calls.log")" -eq 1 ]
  [[ "$output" == *"rule apt: skipped (ran <24h ago)"* ]]
  touch -d '25 hours ago' "$TEST_TMPDIR/state/apt.last"
  run bash "$WC" --apply
  [ "$(grep -c autoremove "$TEST_TMPDIR/apt-calls.log")" -eq 2 ]
}

@test "dry-run never writes the apt watermark nor runs apt" {
  run bash "$WC"
  [ ! -e "$TEST_TMPDIR/state/apt.last" ]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
}

@test "CLEAN_MY_LINUX_SKIP_APT=1 → apt never invoked" {
  export CLEAN_MY_LINUX_SKIP_APT=1
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/apt-calls.log" ]
  [[ "$output" == *"rule apt: skipped"* ]]
}

# ──────────────────────────────────────────────────────────────
# Error handling + idempotence
# ──────────────────────────────────────────────────────────────

@test "per-file rm failure → counted as error, exit 0, error in payload" {
  slack_fixture
  cat > "$TEST_TMPDIR/bin/rm" <<'STUB'
#!/bin/bash
for a in "$@"; do
  if [ -n "${CLEAN_MY_LINUX_TEST_RM_FAIL:-}" ] && [ "$a" = "$CLEAN_MY_LINUX_TEST_RM_FAIL" ]; then
    echo "rm: stub: cannot remove '$a'" >&2
    exit 1
  fi
done
exec /bin/rm "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/rm"
  export CLEAN_MY_LINUX_TEST_RM_FAIL="$TEST_TMPDIR/bakroot-a/stuck.bak"
  echo x > "$TEST_TMPDIR/bakroot-a/stuck.bak"; old 40 "$TEST_TMPDIR/bakroot-a/stuck.bak"
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [ -e "$TEST_TMPDIR/bakroot-a/stuck.bak" ]
  [[ "$output" == *"bak: deleted=0 errors=1"* ]]
  grep -q 'errors=1' "$TEST_TMPDIR/last-text"
}

@test "idempotent: immediate second run deletes 0" {
  echo x > "$TEST_TMPDIR/bakroot-a/dead.bak"; old 40 "$TEST_TMPDIR/bakroot-a/dead.bak"
  run bash "$WC" --apply
  [[ "$output" == *"bak: deleted=1"* ]]
  run bash "$WC" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"bak: deleted=0"* ]]
}

@test "weekly unit ExecStart requests --apply (the dry-run default would reclaim nothing)" {
  line="$(sed -n '/^cat > \/etc\/systemd\/system\/hydra-weekly-cleanup.service/,/^CLEANUPSVC$/p' \
    "$HYDRA_REPO/scripts/install-aux-units.sh" | grep '^ExecStart=')"
  [[ "$line" == *"/scripts/clean-my-linux.sh --apply" ]]
}

@test "retired weekly-cleanup.sh is rsync-excluded so the Step 4a pre-flight does not halt on its deletion" {
  [ ! -e "$HYDRA_REPO/scripts/weekly-cleanup.sh" ]
  sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$HYDRA_REPO/scripts/deploy.sh" \
    | grep -qFx -- "  --exclude='scripts/weekly-cleanup.sh'"
}
