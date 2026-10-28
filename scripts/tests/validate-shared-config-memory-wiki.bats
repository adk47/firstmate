#!/usr/bin/env bats
# Rejection-path coverage for the memory-wiki vault-scope gate in
# scripts/validate-shared-config.sh.
#
# WHY THIS EXISTS (QA finding, PR #956): the gate is a fail-closed isolation
# check, but CI only ever ran it against the compliant checked-in config, so
# every refusal branch was unproven. The concrete regression it guards: a later
# refactor treats an ABSENT scope as "disabled", CI stays green, a config edit
# then drops `vault.scope`, and OpenClaw falls back to
# DEFAULT_WIKI_VAULT_SCOPE="global" — one shared vault at <stateDir>/wiki/main
# across every agent on the profile, so `wiki_apply` by finance is returned to
# qa by `wiki_search`. Manual mutation testing proved the behaviour once; this
# file is what keeps it proven.
#
# The validator derives HYDRA_ROOT from its OWN directory and offers no env
# override — deliberately, since an override on a security gate could be set in
# CI and point it at the wrong files. So each case builds a throwaway tree that
# mimics the repo layout, drops in a COPY of the real script, and supplies
# fixture configs derived from the real ones. Every other check in the
# validator therefore sees genuine data and passes, and only the memory-wiki
# gate varies.
bats_require_minimum_version 1.5.0

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/scripts" "$TEST_TMPDIR/shared-reference/reference"
  cp "$REPO/scripts/validate-shared-config.sh" "$TEST_TMPDIR/scripts/"
  # The Caroline support-deny check (captain 2026-10-28) calls this lib relative to the script.
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  cp "$REPO/scripts/lib/assert-support-deny.sh" "$TEST_TMPDIR/scripts/lib/"
  # The roster check reads a real file relative to the script; give it the real one.
  cp "$REPO/shared-reference/reference/slack-people.json" \
     "$TEST_TMPDIR/shared-reference/reference/slack-people.json"
  cp "$REPO/openclaw-main.json" "$TEST_TMPDIR/openclaw-main.json"
  cp "$REPO/openclaw-edge.json" "$TEST_TMPDIR/openclaw-edge.json"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# _wiki <profile> <mode>
#   agent      -> enabled with vault.scope="agent"      (the safe shape)
#   global     -> enabled with vault.scope="global"      (the unsafe shape)
#   noscope    -> enabled with NO config block           (defaults to global)
#   emptyvault -> enabled with config.vault but no scope (defaults to global)
#   disabled   -> enabled:false                          (safe; gate must skip)
#   absent     -> no memory-wiki entry at all            (safe; gate must skip)
_wiki() {
  python3 - "$TEST_TMPDIR/openclaw-$1.json" "$2" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    c = json.load(f)
entries = c.setdefault("plugins", {}).setdefault("entries", {})
allow = c.setdefault("plugins", {}).setdefault("allow", [])
if mode == "absent":
    entries.pop("memory-wiki", None)
else:
    if "memory-wiki" not in allow:
        allow.append("memory-wiki")
    e = {"enabled": mode != "disabled"}
    if mode == "agent":
        e["config"] = {"vault": {"scope": "agent"}}
    elif mode == "global":
        e["config"] = {"vault": {"scope": "global"}}
    elif mode == "emptyvault":
        e["config"] = {"vault": {}}
    elif mode == "disabled":
        e["config"] = {"vault": {"scope": "agent"}}
    entries["memory-wiki"] = e
with open(path, "w") as f:
    json.dump(c, f, indent=2)
PY
}

run_validator() { run "$TEST_TMPDIR/scripts/validate-shared-config.sh"; }

# _gate_line <profile> — the gate's own output line, or empty if it did not run.
_gate_line() { printf '%s\n' "$output" | grep -E "$1\.memory-wiki\.vault\.scope" || true; }

# ── the compliant shape ─────────────────────────────────────────────────────

@test "main with vault.scope=agent passes the gate and the validator succeeds" {
  _wiki main agent
  run_validator
  [ "$status" -eq 0 ]
  [[ "$(_gate_line main)" == *'OK: main.memory-wiki.vault.scope = "agent"'* ]]
  [[ "$output" == *"All shared settings match"* ]]
}

# ── the refusal branches: this is what the finding asked for ────────────────

@test "main with memory-wiki enabled but NO config block is REFUSED, naming the global default" {
  _wiki main noscope
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line main)" == *"DRIFT"* ]]
  # The message must name the actual hazard, not just report a mismatch: an
  # absent key is not a typo, it silently selects the shared vault.
  [[ "$(_gate_line main)" == *"MISSING-defaults-to-global"* ]]
}

@test "main with vault.scope=global is REFUSED" {
  _wiki main global
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line main)" == *"DRIFT"* ]]
  [[ "$(_gate_line main)" == *'got "global"'* ]]
}

@test "a config.vault block that omits scope is REFUSED too (the half-configured shape)" {
  # The adjacent case to 'no config block': someone adds vault.path or
  # vault.renderMode and never sets scope. Reads exactly as unsafe.
  _wiki main emptyvault
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line main)" == *"MISSING-defaults-to-global"* ]]
}

@test "EDGE with memory-wiki enabled but no scope is REFUSED (the gate covers both profiles)" {
  # Edge ships memory-wiki disabled today. The gate must still bind there, so
  # enabling Caroline's wiki later cannot land globally-scoped by accident.
  _wiki edge noscope
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line edge)" == *"DRIFT"* ]]
  [[ "$(_gate_line edge)" == *"MISSING-defaults-to-global"* ]]
}

@test "EDGE with vault.scope=agent passes" {
  _wiki edge agent
  run_validator
  [ "$status" -eq 0 ]
  [[ "$(_gate_line edge)" == *'OK: edge.memory-wiki.vault.scope = "agent"'* ]]
}

# ── disabled stays safe, and must NOT be asserted ──────────────────────────

@test "enabled:false is safe — the gate does not run and does not fail" {
  # The exact regression the finding described in reverse: a refactor must not
  # start treating a disabled entry as a violation, nor an absent scope as
  # disabled. A disabled plugin registers no tools, so there is nothing to pin.
  _wiki main disabled
  run_validator
  [ "$status" -eq 0 ]
  [ -z "$(_gate_line main)" ]
}

@test "no memory-wiki entry at all is safe — the gate does not run" {
  _wiki main absent
  _wiki edge absent
  run_validator
  [ "$status" -eq 0 ]
  [ -z "$(_gate_line main)" ]
  [ -z "$(_gate_line edge)" ]
}

# ── the gate does not fire on unrelated drift ──────────────────────────────

@test "a globally-scoped wiki on ONE profile does not implicate the other" {
  _wiki main global
  _wiki edge agent
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line main)" == *"DRIFT"* ]]
  [[ "$(_gate_line edge)" == *"OK"* ]]
}

# ── the allowlist half (QA finding, PR #956 round 2) ───────────────────────
# The gate read only `enabled` and `vault.scope` and never checked the allowlist
# that actually permits the plugin to load. Concrete failure: a later edit drops
# `memory-wiki` from `plugins.allow` but leaves the enabled entry and
# scope=agent. `validate-shared-config.sh` exits 0, `openclaw config validate`
# also exits 0 with only a warning ("plugin disabled (not in allowlist) but
# config is present"), OpenClaw loads nothing, and CI stays green while the
# feature silently stops registering its tools.

# _drop_from_allow <profile> — remove memory-wiki from plugins.allow only.
_drop_from_allow() {
  python3 - "$TEST_TMPDIR/openclaw-$1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    c = json.load(f)
allow = c.get("plugins", {}).get("allow", [])
c["plugins"]["allow"] = [x for x in allow if x != "memory-wiki"]
with open(path, "w") as f:
    json.dump(c, f, indent=2)
PY
}

@test "enabled with a correct scope but MISSING from plugins.allow is REFUSED" {
  _wiki main agent
  _drop_from_allow main
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line main)" == *"DRIFT"* ]]
  [[ "$(_gate_line main)" == *"ENABLED-BUT-NOT-IN-plugins.allow"* ]]
}

@test "the allowlist check binds on EDGE too" {
  _wiki edge agent
  _drop_from_allow edge
  run_validator
  [ "$status" -ne 0 ]
  [[ "$(_gate_line edge)" == *"ENABLED-BUT-NOT-IN-plugins.allow"* ]]
}

@test "a DISABLED entry missing from plugins.allow is still safe" {
  # Disabled loads nothing either way, so an absent allowlist entry is not drift.
  _wiki main disabled
  _drop_from_allow main
  run_validator
  [ "$status" -eq 0 ]
  [ -z "$(_gate_line main)" ]
}
