#!/usr/bin/env bats
# Tests for scripts/lib/ensure-codex-refresh-lock-shared.sh — the cross-process
# Codex refresh-lock convergence that makes openclaw's O_EXCL refresh lock
# exclude ACROSS the main+edge gateway processes (closes the 2026-06-08
# refresh_token_reused race).
#
# Everything runs in a sandbox via CODEX_LOCK_ROOT/CANON_LOCK_DIR/ACTIVE_LOCK_DIRS
# so the suite never touches live node-8 lock dirs. PATH-shadows ssh so an
# accidental remote call fails loudly (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/ensure-codex-refresh-lock-shared.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH

  # Sandbox layout mirrors node-8: <root>/.openclaw-{main,edge}/locks/oauth-refresh
  export CODEX_LOCK_ROOT="$TEST_TMPDIR/root"
  export CANON_LOCK_DIR="$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh"
  export ACTIVE_LOCK_DIRS="$CODEX_LOCK_ROOT/.openclaw-edge/locks/oauth-refresh"
  mkdir -p "$CANON_LOCK_DIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# physical (symlink-resolved) path of a dir
_real() { (cd "$1" 2>/dev/null && pwd -P) || printf ''; }

# ── ensure mode ───────────────────────────────────────────────

@test "ensure: an existing REAL active dir becomes a symlink to canonical (the rm-then-link bug)" {
  mkdir -p "$ACTIVE_LOCK_DIRS"               # the live node-8 state: a real dir
  [ ! -L "$ACTIVE_LOCK_DIRS" ]               # precondition: real dir, not a link

  run bash "$LIB"
  [ "$status" -eq 0 ]

  [ -L "$ACTIVE_LOCK_DIRS" ]                  # now a symlink…
  [ "$(_real "$ACTIVE_LOCK_DIRS")" = "$(_real "$CANON_LOCK_DIR")" ]  # …to canonical
  # NOT the naive-ln bug where a link is created INSIDE the dir:
  [ ! -e "$ACTIVE_LOCK_DIRS/oauth-refresh" ]
}

@test "ensure: in-flight *.lock files are migrated into canonical before relinking" {
  mkdir -p "$ACTIVE_LOCK_DIRS"
  echo held > "$ACTIVE_LOCK_DIRS/sha256-deadbeef.lock"

  run bash "$LIB"
  [ "$status" -eq 0 ]

  [ -L "$ACTIVE_LOCK_DIRS" ]
  [ -f "$CANON_LOCK_DIR/sha256-deadbeef.lock" ]
  [ "$(cat "$CANON_LOCK_DIR/sha256-deadbeef.lock")" = "held" ]
}

@test "ensure: idempotent — a correct symlink is left untouched, exit 0" {
  run bash "$LIB"; [ "$status" -eq 0 ]
  local first; first="$(readlink "$ACTIVE_LOCK_DIRS")"
  run bash "$LIB"; [ "$status" -eq 0 ]
  [ -L "$ACTIVE_LOCK_DIRS" ]
  [ "$(readlink "$ACTIVE_LOCK_DIRS")" = "$first" ]
}

@test "ensure: replaces a WRONG-target symlink with one pointing at canonical" {
  local wrong="$TEST_TMPDIR/somewhere-else"; mkdir -p "$wrong"
  mkdir -p "$(dirname "$ACTIVE_LOCK_DIRS")"
  ln -sfn "$wrong" "$ACTIVE_LOCK_DIRS"

  run bash "$LIB"
  [ "$status" -eq 0 ]
  [ "$(_real "$ACTIVE_LOCK_DIRS")" = "$(_real "$CANON_LOCK_DIR")" ]
}

@test "ensure: seeds canonical if missing and still converges" {
  rm -rf "$CANON_LOCK_DIR"
  mkdir -p "$ACTIVE_LOCK_DIRS"
  run bash "$LIB"
  [ "$status" -eq 0 ]
  [ -d "$CANON_LOCK_DIR" ]
  [ -L "$ACTIVE_LOCK_DIRS" ]
  [ "$(_real "$ACTIVE_LOCK_DIRS")" = "$(_real "$CANON_LOCK_DIR")" ]
}

# ── --check mode ──────────────────────────────────────────────

@test "--check: exit 0 when every active dir is a symlink to canonical" {
  bash "$LIB"                  # converge first
  run bash "$LIB" --check
  [ "$status" -eq 0 ]
}

@test "--check: exit 1 and names the offender when an active dir is a plain dir" {
  mkdir -p "$ACTIVE_LOCK_DIRS"   # plain dir = not converged
  run bash "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$ACTIVE_LOCK_DIRS"* ]]
}

@test "--check: exit 1 when an active dir is a symlink to the WRONG place" {
  local wrong="$TEST_TMPDIR/elsewhere"; mkdir -p "$wrong"
  mkdir -p "$(dirname "$ACTIVE_LOCK_DIRS")"
  ln -sfn "$wrong" "$ACTIVE_LOCK_DIRS"
  run bash "$LIB" --check
  [ "$status" -eq 1 ]
}

@test "--check: exit 1 when an active dir is missing entirely" {
  # parent exists, the oauth-refresh dir does not → not converged
  mkdir -p "$(dirname "$ACTIVE_LOCK_DIRS")"
  run bash "$LIB" --check
  [ "$status" -eq 1 ]
}

# ── multi-profile (future third codex gateway) ────────────────

@test "ensure+check: converges multiple active dirs" {
  local edge2="$CODEX_LOCK_ROOT/.openclaw-edge2/locks/oauth-refresh"
  export ACTIVE_LOCK_DIRS="$ACTIVE_LOCK_DIRS $edge2"
  mkdir -p "$ACTIVE_LOCK_DIRS" "$edge2"

  run bash "$LIB"; [ "$status" -eq 0 ]
  run bash "$LIB" --check; [ "$status" -eq 0 ]
}
