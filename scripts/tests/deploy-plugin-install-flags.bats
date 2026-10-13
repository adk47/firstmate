#!/usr/bin/env bats
# scripts/deploy.sh plugin_install_version_flags(): --accept-capabilities is a
# 2026.8+ CLI option. Passing it unconditionally broke the supported
# OPENCLAW_VERSION=2026.7.1 override (a rollback deploy): the 7.1 CLI rejects
# the unknown option, so every external-plugin install failed after the 7.1
# runtime was already installed (QA finding, PR #899). The function is
# extracted from deploy.sh the same way deploy-agents-bound-probe.bats does.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  awk '/^plugin_install_version_flags\(\) \{$/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/fn.sh"
  [ -s "$TEST_TMPDIR/fn.sh" ] || { echo "extraction produced nothing — did the function move?" >&2; return 1; }
  grep -q '^}$' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the closing brace" >&2; return 1; }
  # shellcheck source=../lib/version-compare.sh
  source "$HYDRA_REPO/scripts/lib/version-compare.sh"
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/fn.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "2026.8.2 (the window target) gets --accept-capabilities" {
  [ "$(plugin_install_version_flags 2026.8.2)" = "--accept-capabilities" ]
}
@test "2026.8.1 gets --accept-capabilities (first 2.0 release)" {
  [ "$(plugin_install_version_flags 2026.8.1)" = "--accept-capabilities" ]
}
@test "2026.7.1 (the rollback override) gets NO flag — the 7.x CLI rejects it" {
  [ -z "$(plugin_install_version_flags 2026.7.1)" ]
}
@test "2026.5.27 (the pre-7.x codex pin) gets NO flag" {
  [ -z "$(plugin_install_version_flags 2026.5.27)" ]
}
@test "a later minor (2026.9.2) still gets the flag" {
  [ "$(plugin_install_version_flags 2026.9.2)" = "--accept-capabilities" ]
}
@test "empty or garbage versions print nothing (the install then fails on the CLI's own error, not on a guessed flag)" {
  [ -z "$(plugin_install_version_flags "")" ]
  [ -z "$(plugin_install_version_flags banana)" ]
}
@test "deploy.sh never passes --accept-capabilities unconditionally (only via the gated function)" {
  # the literal flag must appear in deploy.sh only inside plugin_install_version_flags() and comments
  n=$(grep -nE 'accept-capabilities' "$DEPLOY_SH" | grep -vE '^[0-9]+:\s*#' | grep -vE "printf .*--accept-capabilities" | wc -l | tr -d ' ')
  [ "$n" -eq 0 ]
}

# ── the REAL install path (QA round 7): execute install_external_plugin() against
# a stubbed `openclaw` and assert the argv it builds, so deleting the call or the
# array expansion cannot stay green. Functions are extracted verbatim from
# deploy.sh; deploy.sh's surrounding globals are supplied here.

setup_install_path() {
  for fn in plugin_runtime_version plugin_install_version_flags stop_gateway_for_plugin_pin install_external_plugin; do
    awk "/^${fn}\\(\\) \\{/,/^\\}\$/" "$DEPLOY_SH" >> "$TEST_TMPDIR/install.sh"
    grep -q "^${fn}() {" "$TEST_TMPDIR/install.sh" || { echo "extraction missing $fn" >&2; return 1; }
  done
  mkdir -p "$TEST_TMPDIR/bin"; CALLS="$TEST_TMPDIR/calls"; export CALLS
  # openclaw stub: records every argv; `plugins list --json` reports the version
  # of the LAST recorded install for that package (so the post-install pin check
  # sees what the install "did"), or nothing before any install.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "openclaw $*" >> "$CALLS"
case " $* " in
  *" plugins list "*)
    # per-PROFILE ledger: the version of the last install recorded for THIS profile
    prof=$2
    v=$(grep -E "^openclaw --profile $prof plugins install @openclaw/[a-z]+@[0-9.]+" "$CALLS" | tail -1 | grep -oE "@[0-9.]+" | tr -d @)
    [ -n "$v" ] && echo "{\"plugins\":[{\"id\":\"slack\",\"version\":\"$v\"},{\"id\":\"codex\",\"version\":\"$v\"}]}" || echo '{"plugins":[]}'
    ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  TARGET=all; needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }
  log() { printf '%s\n' "$*"; }
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/install.sh"
}

@test "REAL install path, 2026.8.2: argv is 'plugins install <pkg>@2026.8.2 --force --pin --accept-capabilities' on both profiles" {
  setup_install_path
  run install_external_plugin @openclaw/slack 2026.8.2
  [ "$status" -eq 0 ]
  for p in main edge; do
    grep -qxF "openclaw --profile $p plugins install @openclaw/slack@2026.8.2 --force --pin --accept-capabilities" "$CALLS"
  done
}

@test "REAL install path, 2026.7.1 (rollback override): argv is '--force --pin' with NO --accept-capabilities" {
  setup_install_path
  run install_external_plugin @openclaw/codex 2026.7.1
  [ "$status" -eq 0 ]
  for p in main edge; do
    grep -qxF "openclaw --profile $p plugins install @openclaw/codex@2026.7.1 --force --pin" "$CALLS"
  done
  if grep -q "accept-capabilities" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q 'accept-capabilities' '$CALLS'" >&2; false; fi
}

@test "REAL install path: an install whose pin misses (ledger still old) fails loud, not silently green" {
  setup_install_path
  # make `plugins list` ignore installs entirely: the ledger never changes
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "openclaw $*" >> "$CALLS"
case " $* " in *" plugins list "*) echo '{"plugins":[{"id":"slack","version":"2026.7.1"}]}';; esac
exit 0
STUB
  run install_external_plugin @openclaw/slack 2026.8.2
  [ "$status" -ne 0 ]
  [[ "$output" == *"after install, expected '2026.8.2'"* ]]
}

@test "MUTATION: dropping the gated flag expansion from the real install call turns the 8.2 argv test RED" {
  setup_install_path
  sed -i.bak 's/--force --pin "\${extra_flags\[@\]}"/--force --pin/' "$TEST_TMPDIR/install.sh"
  grep -q -- '--force --pin 2>&1' "$TEST_TMPDIR/install.sh"   # the mutation applied
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/install.sh"
  run install_external_plugin @openclaw/slack 2026.8.2
  if grep -q "accept-capabilities" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q 'accept-capabilities' '$CALLS'" >&2; false; fi   # the mutant omits the flag => the 8.2 assertion above would fail
}
