#!/usr/bin/env bats
# Tests for scripts/lib/ensure-secret-perms.sh — the boot-path/ watchdog healer
# that keeps openclaw's file-based secret stores owner-only (0600) so the
# gateway's FAIL-CLOSED secret loader can read them. Closes the 2026-06-15
# fleet-wide outage where /opt/hydra/secrets/llm-provider-keys.json drifted to
# 0644 and crash-looped both gateways.
#
# All cases run against a throwaway HYDRA_SECRETS_DIR — never the real
# /opt/hydra/secrets. No network, no systemctl, no openclaw.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/ensure-secret-perms.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export HYDRA_SECRETS_DIR="$TEST_TMPDIR/secrets"
  mkdir -p "$HYDRA_SECRETS_DIR"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# ── ensure (default) mode ─────────────────────────────────────────────────────

@test "ensure: a world-readable 0644 secret is tightened to 0600 (the incident)" {
  printf '{"OPENROUTER_API_KEY":"x"}' > "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  chmod 644 "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  run "$LIB"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$HYDRA_SECRETS_DIR/llm-provider-keys.json")" = "600" ]
  [[ "$output" == *"tightened llm-provider-keys.json 644 -> 600"* ]]
}

@test "ensure: a group-readable 0640 secret is tightened to 0600" {
  printf 'x' > "$HYDRA_SECRETS_DIR/google-sa-hydra.json"
  chmod 640 "$HYDRA_SECRETS_DIR/google-sa-hydra.json"
  run "$LIB"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$HYDRA_SECRETS_DIR/google-sa-hydra.json")" = "600" ]
}

@test "ensure: an already-0600 secret is left untouched and is silent about it" {
  printf 'x' > "$HYDRA_SECRETS_DIR/vault-init.json"
  chmod 600 "$HYDRA_SECRETS_DIR/vault-init.json"
  run "$LIB"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$HYDRA_SECRETS_DIR/vault-init.json")" = "600" ]
  [[ "$output" != *"tightened"* ]]
}

@test "ensure: non-.json files (e.g. .gitkeep) are NOT touched" {
  printf '' > "$HYDRA_SECRETS_DIR/.gitkeep"
  chmod 644 "$HYDRA_SECRETS_DIR/.gitkeep"
  run "$LIB"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$HYDRA_SECRETS_DIR/.gitkeep")" = "644" ]   # untouched
}

@test "ensure: a chmod-000 secret is NOT treated as too-open (0 group/other bits)" {
  printf 'x' > "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  chmod 000 "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  run "$LIB" --check
  [ "$status" -eq 0 ]                 # 000 is owner-only-ish: NOT a "too open" violation
  run "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" != *"tightened"* ]]    # ensure mode leaves it alone
}

@test "ensure: absent secrets dir is a no-op success (never blocks gateway start)" {
  rm -rf "$HYDRA_SECRETS_DIR"
  run "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"absent"* ]]
}

@test "ensure: tightens multiple too-open secrets in one pass" {
  for n in a b c; do printf 'x' > "$HYDRA_SECRETS_DIR/$n.json"; chmod 644 "$HYDRA_SECRETS_DIR/$n.json"; done
  run "$LIB"
  [ "$status" -eq 0 ]
  for n in a b c; do [ "$(mode_of "$HYDRA_SECRETS_DIR/$n.json")" = "600" ]; done
  [[ "$output" == *"tightened 3 too-open secret file(s)"* ]]
}

# ── --check (read-only detector) mode ─────────────────────────────────────────

@test "--check: clean when every secret is 0600 → exit 0, leaves perms unchanged" {
  printf 'x' > "$HYDRA_SECRETS_DIR/llm-provider-keys.json"; chmod 600 "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  run "$LIB" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean: every secret file"* ]]
}

@test "--check: a too-open secret → exit 1 and names the offender, WITHOUT fixing it" {
  printf 'x' > "$HYDRA_SECRETS_DIR/llm-provider-keys.json"; chmod 644 "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  run "$LIB" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"too-open secret file(s)"* ]]
  [[ "$output" == *"llm-provider-keys.json (644)"* ]]
  # --check is read-only: it must NOT have repaired the file.
  [ "$(mode_of "$HYDRA_SECRETS_DIR/llm-provider-keys.json")" = "644" ]
}

@test "--check: absent secrets dir → exit 0 (nothing too-open to report)" {
  rm -rf "$HYDRA_SECRETS_DIR"
  run "$LIB" --check
  [ "$status" -eq 0 ]
}
