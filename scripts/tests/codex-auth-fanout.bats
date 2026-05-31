#!/usr/bin/env bats
# Tests for scripts/lib/ensure-codex-auth.sh — the fleet-wide central-store
# guard for codex (ChatGPT OAuth) auth. Canonical store is the `main` profile's
# primary agent; every other agent must SYMLINK to it (a single-use refresh
# token cannot survive being copied into per-agent stores — see the script
# header and the fan-out incident that motivated PR #376).
#
# These tests build a throwaway fake-fleet under a mktemp -d sandbox and point
# the script at it via CODEX_AUTH_ROOT, so they NEVER read or write real node-8
# auth files (/root/.openclaw-*/agents/*/agent/...). Modeled on
# scripts/tests/pr-skill-drift-gate.bats (setup/teardown + `run env ... "$SCRIPT"`).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/ensure-codex-auth.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  ROOT="$TEST_TMPDIR/root"; export ROOT

  # Fake fleet: main profile owns canonical (main/) plus a second agent (clio/);
  # edge profile carries support/. Mirrors the real
  # /root/.openclaw-<profile>/agents/<agent>/agent/ layout.
  CANON_DIR="$ROOT/.openclaw-main/agents/main/agent"; export CANON_DIR
  CLIO_DIR="$ROOT/.openclaw-main/agents/clio/agent"
  SUPPORT_DIR="$ROOT/.openclaw-edge/agents/support/agent"
  mkdir -p "$CANON_DIR" "$CLIO_DIR" "$SUPPORT_DIR"

  # Canonical store holds the one legitimate codex profile.
  cat > "$CANON_DIR/auth-profiles.json" <<'JSON'
{"profiles":{"openai-codex:default":{"type":"oauth","refresh_token":"rt-canonical"}}}
JSON
  printf '%s' '{"active":"openai-codex:default"}' > "$CANON_DIR/auth-state.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# All cases drive the script with CODEX_AUTH_ROOT pointing at the sandbox, which
# defaults CANON_DIR and AGENTS_GLOB underneath it.
ensure() { run env CODEX_AUTH_ROOT="$ROOT" "$SCRIPT"; }
check()  { run env CODEX_AUTH_ROOT="$ROOT" "$SCRIPT" --check; }

# Write a codex-bearing regular file (the fan-out shape) at $1.
plant_codex_regular_file() {
  cat > "$1" <<'JSON'
{"profiles":{"openai-codex:default":{"type":"oauth","refresh_token":"rt-fanned-out"}}}
JSON
}

# Make $1 a symlink to the canonical auth-profiles.json (the desired clean shape).
link_to_canonical_profiles() {
  ln -sfn "$CANON_DIR/auth-profiles.json" "$1"
}

@test "clean fleet (symlinks + codex-less regular files) → --check exits 0" {
  # support/ is already correctly symlinked to canonical.
  link_to_canonical_profiles "$SUPPORT_DIR/auth-profiles.json"
  ln -sfn "$CANON_DIR/auth-state.json" "$SUPPORT_DIR/auth-state.json"
  # clio/ has a regular file but with NO codex profile → not a fan-out.
  printf '%s' '{"profiles":{"anthropic:default":{}}}' > "$CLIO_DIR/auth-profiles.json"

  check
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'clean'
}

@test "NEGATIVE: regular-file codex store in a non-canonical agent → --check exits 1 and names it" {
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"

  check
  [ "$status" -eq 1 ]
  # The offending path is printed as "  - <path>".
  echo "$output" | grep -qF -- "  - $SUPPORT_DIR/auth-profiles.json"
}

@test "ensure converts a regular-file codex store into a symlink and leaves a .bak" {
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"

  ensure
  [ "$status" -eq 0 ]
  # Now a symlink pointing at canonical.
  [ -L "$SUPPORT_DIR/auth-profiles.json" ]
  [ "$(readlink "$SUPPORT_DIR/auth-profiles.json")" = "$CANON_DIR/auth-profiles.json" ]
  # The original regular file was backed up exactly once.
  shopt -s nullglob
  baks=("$SUPPORT_DIR"/auth-profiles.json.bak-*)
  shopt -u nullglob
  [ "${#baks[@]}" -eq 1 ]
  # Backup preserved the fanned-out bytes.
  grep -q 'rt-fanned-out' "${baks[0]}"
  # Reading through the symlink yields the canonical bytes (token now shared).
  grep -q 'rt-canonical' "$SUPPORT_DIR/auth-profiles.json"
}

@test "ensure is idempotent: re-run makes no new backup and --check stays 0" {
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"

  ensure
  [ "$status" -eq 0 ]
  shopt -s nullglob
  first=("$SUPPORT_DIR"/auth-profiles.json.bak-*)
  shopt -u nullglob
  [ "${#first[@]}" -eq 1 ]

  # Second ensure: link already correct → no work, no additional .bak.
  ensure
  [ "$status" -eq 0 ]
  shopt -s nullglob
  second=("$SUPPORT_DIR"/auth-profiles.json.bak-*)
  shopt -u nullglob
  [ "${#second[@]}" -eq 1 ]

  check
  [ "$status" -eq 0 ]
}

@test "ensure never backs up an existing symlink (no churn)" {
  # support/ already a (wrong-ish but symlink) link → must not be backed up.
  ln -sfn /nonexistent/old-target "$SUPPORT_DIR/auth-profiles.json"

  ensure
  [ "$status" -eq 0 ]
  # Relinked to canonical, but NO backup created for the prior symlink.
  [ "$(readlink "$SUPPORT_DIR/auth-profiles.json")" = "$CANON_DIR/auth-profiles.json" ]
  shopt -s nullglob
  baks=("$SUPPORT_DIR"/auth-profiles.json.bak-*)
  shopt -u nullglob
  [ "${#baks[@]}" -eq 0 ]
}

@test "ensure links even when canonical is missing (dangling link acceptable) and warns" {
  rm -f "$CANON_DIR/auth-profiles.json" "$CANON_DIR/auth-state.json"
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"

  ensure
  [ "$status" -eq 0 ]
  [ -L "$SUPPORT_DIR/auth-profiles.json" ]
  [ "$(readlink "$SUPPORT_DIR/auth-profiles.json")" = "$CANON_DIR/auth-profiles.json" ]
  echo "$output" | grep -qi 'canonical store missing'
}

@test "malformed JSON in a non-canonical store does not crash --check (treated as no codex)" {
  printf '%s' '{ this is not valid json ' > "$SUPPORT_DIR/auth-profiles.json"

  check
  # Not a fan-out (jq can't read an openai-codex key out of garbage) → clean.
  [ "$status" -eq 0 ]
}

@test "--check exits 2 when jq is unavailable" {
  # Build a PATH that has the coreutils the script needs (date, etc.) but
  # deliberately OMITS jq, so `command -v jq` fails and the error exit fires.
  # We can't just empty PATH — the script wouldn't even reach its jq check.
  mkdir -p "$TEST_TMPDIR/nojqbin"
  local b p
  for b in bash env date ln cp readlink basename dirname sed cat grep awk; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$TEST_TMPDIR/nojqbin/$b"
  done
  # Sanity: jq must NOT be resolvable through this PATH.
  ! PATH="$TEST_TMPDIR/nojqbin" command -v jq >/dev/null 2>&1

  run env -i PATH="$TEST_TMPDIR/nojqbin" CODEX_AUTH_ROOT="$ROOT" \
    "$TEST_TMPDIR/nojqbin/bash" "$SCRIPT" --check
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi 'jq required'
}

@test "--check exits 2 when the glob root is unreadable" {
  run env CODEX_AUTH_ROOT="$TEST_TMPDIR/does-not-exist" "$SCRIPT" --check
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi 'glob root unreadable'
}

@test "canonical store is never relinked or backed up by ensure" {
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"

  ensure
  [ "$status" -eq 0 ]
  # Canonical stays a regular file with its original bytes; no .bak beside it.
  [ -f "$CANON_DIR/auth-profiles.json" ]
  [ ! -L "$CANON_DIR/auth-profiles.json" ]
  grep -q 'rt-canonical' "$CANON_DIR/auth-profiles.json"
  shopt -s nullglob
  canon_baks=("$CANON_DIR"/auth-profiles.json.bak-*)
  shopt -u nullglob
  [ "${#canon_baks[@]}" -eq 0 ]
}
