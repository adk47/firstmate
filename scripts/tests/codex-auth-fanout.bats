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
  # Hermeticity: codex-auth-sync now resolves its primary from the account-
  # rotation state file (/var/lib/hydra/codex-active-account); pin it at an
  # absent sandbox path so live state on the node-8 CI runner can't leak in.
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/absent-active-account"
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

  # PATH-shadow openclaw (per memory/feedback_bats_must_stub_openclaw.md):
  # the script version-gates its 7.x delegation to codex-auth-sync.sh via
  # `openclaw --version`. Default the stub to a 6.x runtime so these legacy
  # symlink-fabric tests keep exercising the legacy path even on a host whose
  # real openclaw is >= 2026.7.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "OpenClaw ${FAKE_OPENCLAW_VERSION:-2026.6.1} (test)"; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
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
  # The runtime-version gate in main() runs before the jq check, so openclaw
  # must resolve here too — otherwise this exercises the "unparseable
  # runtime" gate (covered separately) instead of isolating "no jq".
  cp "$TEST_TMPDIR/bin/openclaw" "$TEST_TMPDIR/nojqbin/openclaw"
  # Sanity: jq must NOT be resolvable through this PATH.
  if PATH="$TEST_TMPDIR/nojqbin" command -v jq >/dev/null 2>&1; then echo "the constructed nojqbin PATH still resolves jq, invalidating the fixture" >&2; false; fi

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

@test "runtime >= 2026.7 delegates ensure mode to codex-auth-sync.sh" {
  # On 7.x the JSON symlink fabric is inert; the script must hand off to the
  # sqlite/codex-home successor instead of relinking JSON. The sandbox
  # canonical lacks `access` fields, so the sync script exits 2 — proving the
  # handoff happened (legacy ensure mode would exit 0).
  export FAKE_OPENCLAW_VERSION=2026.7.1
  ensure
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'delegating to codex-auth-sync.sh'
}

@test "runtime >= 2026.7 delegates --check mode to codex-auth-sync.sh" {
  export FAKE_OPENCLAW_VERSION=2026.7.1
  check
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'delegating to codex-auth-sync.sh'
}

@test "runtime >= 2026.8 delegates ensure mode to codex-auth-invariants.sh, always exit 0" {
  # On 2.0 the runtime serves every agent from the shared authProfiles.store
  # row directly; there is nothing left here to symlink or fan out, so
  # "ensure" is a pure report and must never block start (ExecStartPre).
  # The sandbox has no 2.0 state at all, so the invariants checker itself
  # would exit 2 (UNEVALUATED) — proving delegation happened is that the
  # wrapper still forces exit 0 around that.
  export FAKE_OPENCLAW_VERSION=2026.8.1
  ensure
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'delegating to codex-auth-invariants.sh'
}

@test "runtime >= 2026.8 delegates --check mode to codex-auth-invariants.sh and propagates its exit code" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  check
  # This sandbox's fixture is 7.x-shaped (un-archived auth-profiles.json /
  # auth-state.json regular files under the canonical agent dir, no 2.0
  # sqlite state at all) — codex-auth-invariants.sh correctly reads that as a
  # CRITICAL violation (exit 1), not a false-clean 0. Proving the wrapper's
  # exit code IS that propagated value (not its own legacy 0/1/2) is the
  # point of this test.
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'delegating to codex-auth-invariants.sh'
}

# ── unparseable/unknown runtime must never guess ─────────────────────────────
# QA bot finding (PR #897, 2026-08-31): an unparseable `openclaw --version`
# must not silently fall through to the legacy 7.1 symlink-fabric checks —
# those files are INERT on >= 2026.7/2026.8, so guessing "pre-2026.7" there
# would run_check a fan-out signal that cannot exist anymore (false clean) or
# run_ensure symlinks nobody reads. Both modes must refuse to guess.

@test "unparseable runtime version: --check fails loud (exit 2), never runs the legacy fan-out check" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "garbage"; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  # Plant a fan-out shape that the legacy check WOULD flag (exit 1) if it ran
  # — proving the script instead exits 2 (UNEVALUATED-style) BEFORE reaching
  # it, rather than guessing pre-2026.7 and running it anyway.
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"

  check
  [ "$status" -eq 2 ]
  echo "$output" | grep -qi 'could not determine openclaw runtime version'
}

@test "unparseable runtime version: ensure mode exits 0 (never blocks start) but writes nothing" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo ""; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  # support/ has no auth files yet — if legacy ensure mode ran (guessing
  # pre-2026.7), it would symlink them into existence.
  ensure
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'could not determine openclaw runtime version'
  [ ! -e "$SUPPORT_DIR/auth-profiles.json" ]
  [ ! -e "$SUPPORT_DIR/auth-state.json" ]
}

# ── QA bot round 3 (CRITICAL, fresh): a missing/unexecutable invariants
# checker on >= 2026.8 must never fall through to the legacy pre-2026.7
# symlink-fabric / codex-auth-sync.sh checks — those cannot evaluate a 2.0
# store at all. Builds a sandboxed copy of scripts/lib/ so
# codex-auth-invariants.sh can be made absent/unexecutable without touching
# the real repo file every other test in this suite relies on.
_sandbox_lib_without_invariants() {
  local mode="$1" sandbox_lib="$TEST_TMPDIR/lib-no-invariants"
  mkdir -p "$sandbox_lib"
  cp "$HYDRA_REPO/scripts/lib/ensure-codex-auth.sh" "$sandbox_lib/"
  cp "$HYDRA_REPO/scripts/lib/version-compare.sh" "$sandbox_lib/"
  cp "$HYDRA_REPO/scripts/lib/codex-auth-sync.sh" "$sandbox_lib/"
  if [ "$mode" = "unexecutable" ]; then
    cp "$HYDRA_REPO/scripts/lib/codex-auth-invariants.sh" "$sandbox_lib/"
    chmod -x "$sandbox_lib/codex-auth-invariants.sh"
  fi
  # else "absent": codex-auth-invariants.sh is not copied at all.
  chmod +x "$sandbox_lib/ensure-codex-auth.sh" "$sandbox_lib/codex-auth-sync.sh"
  printf '%s' "$sandbox_lib/ensure-codex-auth.sh"
}

@test "runtime >= 2026.8, invariants checker ABSENT: --check refuses (exit 2), never runs legacy checks" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  local sandboxed_script
  sandboxed_script="$(_sandbox_lib_without_invariants absent)"
  # Plant a fan-out shape the legacy check WOULD flag (exit 1) if it ran.
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"
  run env CODEX_AUTH_ROOT="$ROOT" "$sandboxed_script" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"codex-auth-invariants.sh is missing or not executable"* ]]
  [[ "$output" != *"delegating to codex-auth-sync.sh"* ]]
}

@test "runtime >= 2026.8, invariants checker UNEXECUTABLE: --check refuses (exit 2), never runs legacy checks" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  local sandboxed_script
  sandboxed_script="$(_sandbox_lib_without_invariants unexecutable)"
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"
  run env CODEX_AUTH_ROOT="$ROOT" "$sandboxed_script" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"codex-auth-invariants.sh is missing or not executable"* ]]
  [[ "$output" != *"delegating to codex-auth-sync.sh"* ]]
}

@test "runtime >= 2026.8, invariants checker ABSENT: ensure mode warns + skips, never blocks start, never runs legacy" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  local sandboxed_script
  sandboxed_script="$(_sandbox_lib_without_invariants absent)"
  # support/ has no auth files yet — if legacy ensure mode ran, it would
  # symlink them into existence.
  run env CODEX_AUTH_ROOT="$ROOT" "$sandboxed_script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex-auth-invariants.sh is missing or not executable"* ]]
  [[ "$output" != *"delegating to codex-auth-sync.sh"* ]]
  [ ! -e "$SUPPORT_DIR/auth-profiles.json" ]
  [ ! -e "$SUPPORT_DIR/auth-state.json" ]
}

# ── runtime_ver must be probed exactly once ───────────────────────────────
# QA bot finding (PR #897 round 4): main() resolves the runtime version once,
# but maybe_delegate_to_invariants and maybe_delegate_to_sync each used to
# RE-CALL openclaw_runtime_version — a stub that answers 2026.8.1 on the
# first `openclaw --version` call and fails on every call after reproduces
# main()'s single resolved value silently disagreeing with a helper's own
# re-probe: main() sees 2026.8.1 and clears the "unparseable" gate, but the
# re-probing helper gets nothing and falls through toward the legacy
# pre-2026.7 checks. This uses the same invariants-checker-ABSENT sandbox as
# the tests above (rather than letting the real 2026.8 path run) so the
# assertion is scoped to ensure-codex-auth.sh's OWN `--version` calls —
# codex-auth-invariants.sh is a separate process that legitimately probes
# again on its own once delegated to, which is not what this finding is
# about. With the fix, main() probes once and passes runtime_ver into both
# helpers as an argument, so exactly ONE call happens even though two
# helpers run.
@test "openclaw --version succeeds once then fails: --check still takes the 2026.8 path via a single probe" {
  local count_file="$TEST_TMPDIR/version-call-count"
  rm -f "$count_file"
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/bin/bash
if [ "\$1" = "--version" ]; then
  n=0
  [ -f "$count_file" ] && n="\$(cat "$count_file")"
  n=\$((n + 1))
  printf '%s' "\$n" > "$count_file"
  if [ "\$n" -eq 1 ]; then
    echo "OpenClaw 2026.8.1 (test)"
    exit 0
  fi
  exit 1
fi
echo "test stub: unexpected openclaw call (\$*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  local sandboxed_script
  sandboxed_script="$(_sandbox_lib_without_invariants absent)"
  plant_codex_regular_file "$SUPPORT_DIR/auth-profiles.json"
  run env CODEX_AUTH_ROOT="$ROOT" "$sandboxed_script" --check
  # Same shape as "runtime >= 2026.8, invariants checker ABSENT: --check
  # refuses" above: main() resolved 2026.8.1 on its single probe, so the
  # missing-checker path fires (exit 2), never the legacy fan-out check
  # (which WOULD see the planted regular file and exit 1). A re-probing
  # helper getting a failed second call would instead see an empty
  # runtime_ver and fall through toward the legacy pre-2026.7 checks.
  [ "$status" -eq 2 ]
  [[ "$output" == *"codex-auth-invariants.sh is missing or not executable"* ]]
  [[ "$output" != *"could not determine openclaw runtime version"* ]]
  [[ "$output" != *"delegating to codex-auth-sync.sh"* ]]
  [ -f "$count_file" ]
  [ "$(cat "$count_file")" = "1" ]
}
