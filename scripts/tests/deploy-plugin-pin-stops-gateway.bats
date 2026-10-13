#!/usr/bin/env bats
# deploy.sh install_external_plugin(): when install_openclaw swapped the runtime in
# this deploy (record file present), a plugin install must run with the target
# profile's gateway STOPPED. The trigger is the swap, not the version: the fence
# exists in 2026.8.2 too and only stays quiet while the DB's stamped app_version
# equals the running binary's (CTO ruling, MUS-5079).
#
# REGRESSION (Deploy HYDRA run 37791745129, 8 Oct): Step 4d.5 ran
# `openclaw plugins install @openclaw/slack@2026.8.35` against a live 2026.8.2
# gateway and 8.35 refused it: "OpenClaw refused shared state schema mutation ...
# because another Gateway owns that state directory" (dist/state-database-
# coordinator withStateSchemaFence: the first 8.35 contact with an 8.2-schema
# state DB must migrate it, and migration is fenced against a live gateway).
# Binary and DB stamps agreed on every earlier deploy, so it never fired. The deploy auto-rolled back.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  # shellcheck source=../lib/version-compare.sh
  source "$HYDRA_REPO/scripts/lib/version-compare.sh"
  for fn in plugin_runtime_version plugin_install_version_flags stop_gateway_for_plugin_pin install_external_plugin; do
    awk "/^${fn}\\(\\) \\{/,/^\\}\$/" "$DEPLOY_SH" >> "$TEST_TMPDIR/install.sh"
    grep -q "^${fn}() {" "$TEST_TMPDIR/install.sh" || { echo "extraction missing $fn" >&2; return 1; }
  done
  DEPLOY_PATH="$TEST_TMPDIR/deploy"; export DEPLOY_PATH; mkdir -p "$DEPLOY_PATH"
  mkdir -p "$TEST_TMPDIR/bin"; CALLS="$TEST_TMPDIR/calls"; export CALLS
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "openclaw $*" >> "$CALLS"
case " $* " in
  *" plugins list "*)
    prof=$2
    v=$(grep -E "^openclaw --profile $prof plugins install @openclaw/[a-z]+@[0-9.]+" "$CALLS" | tail -1 | grep -oE "@[0-9.]+" | tr -d @)
    [ -n "$v" ] && echo "{\"plugins\":[{\"id\":\"slack\",\"version\":\"$v\"},{\"id\":\"codex\",\"version\":\"$v\"}]}" || echo "{\"plugins\":[{\"id\":\"slack\",\"version\":\"${LEDGER_VERSION:-}\"}]}"
    ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  TARGET=all; needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }
  log() { printf '%s\n' "$*"; }
  printf '#!/bin/bash\necho "systemctl $*" >> "$CALLS"\nexit "${SYSTEMCTL_RC:-0}"\n' > "$TEST_TMPDIR/bin/systemctl"; chmod +x "$TEST_TMPDIR/bin/systemctl"
  unset HYDRA_FORCE_RESTART
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/install.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

swapped() { printf '2026.8.2\nmain=15 edge=15\n' > "$DEPLOY_PATH/.pre-deploy-openclaw-version"; }

line_of() { grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1; }

@test "2026.8.35: each profile's gateway is stopped BEFORE its plugin install" {
  swapped
  install_external_plugin @openclaw/slack 2026.8.35
  for p in main edge; do
    stop=$(line_of "systemctl stop openclaw-gateway-$p")
    inst=$(line_of "openclaw --profile $p plugins install @openclaw/slack@2026.8.35")
    [ -n "$stop" ] && [ -n "$inst" ]
    [ "$stop" -lt "$inst" ]
  done
}

@test "2026.8.35: the stop forces the Step 6 restart, so a stopped gateway is never left down" {
  swapped
  # shellcheck disable=SC2034
  install_external_plugin @openclaw/slack 2026.8.35
  [ "${HYDRA_FORCE_RESTART:-}" = "1" ]
}

@test "no runtime swap this deploy (binary already at target): no stop and no forced restart, whatever the plugin version" {
  install_external_plugin @openclaw/slack 2026.8.35
  if grep -q "systemctl stop" "$CALLS"; then echo "NEGATED ASSERTION FAILED: gateway stopped without a runtime swap" >&2; false; fi
  [ -z "${HYDRA_FORCE_RESTART:-}" ]
}

@test "runtime swapped, plugin target OLDER than 8.35 (a 2026.7.1 rollback deploy): the gateway is still stopped" {
  swapped
  install_external_plugin @openclaw/slack 2026.7.1
  grep -qF "systemctl stop openclaw-gateway-main" "$CALLS"
  [ "${HYDRA_FORCE_RESTART:-}" = "1" ]
}

@test "a plugin already at the target is skipped WITHOUT stopping the gateway" {
  swapped
  LEDGER_VERSION=2026.8.35 install_external_plugin @openclaw/slack 2026.8.35
  if grep -q "systemctl stop" "$CALLS"; then echo "NEGATED ASSERTION FAILED: stopped for a no-op pin" >&2; false; fi
  [ -z "${HYDRA_FORCE_RESTART:-}" ]
}

@test "edge-only target stops only the edge gateway" {
  swapped
  TARGET=edge
  install_external_plugin @openclaw/codex 2026.8.35
  grep -qF "systemctl stop openclaw-gateway-edge" "$CALLS"
  if grep -q "openclaw-gateway-main" "$CALLS"; then echo "NEGATED ASSERTION FAILED: main stopped" >&2; false; fi
}

@test "a failed stop aborts the pin (no install against a live gateway)" {
  swapped
  export SYSTEMCTL_RC=1
  run install_external_plugin @openclaw/slack 2026.8.35
  [ "$status" -ne 0 ]
  if grep -q "plugins install" "$CALLS"; then echo "NEGATED ASSERTION FAILED: installed after failed stop" >&2; false; fi
}

# --- Step 6 must tell "we stopped it on purpose" from "we could not read its PID".
# finish_gateway_restart case 3 pages Slack "could not capture a pre-request
# MainPID" (the drain path is broken). Firing it by design on every version-bump
# deploy would train us to ignore it.

step6_setup() {
  for fn in gateway_stopped_by_deploy missing_pid_restart_req finish_gateway_restart; do
    awk "/^${fn}\\(\\) \\{/,/^\\}\$/" "$DEPLOY_SH" >> "$TEST_TMPDIR/step6.sh"
    grep -q "^${fn}() {" "$TEST_TMPDIR/step6.sh" || { echo "extraction missing $fn" >&2; return 1; }
  done
  : > "$TEST_TMPDIR/slack"; : > "$TEST_TMPDIR/restarts"
  notify_slack() { echo "$1" >> "$TEST_TMPDIR/slack"; }
  hard_restart_gateway() { echo "$1" >> "$TEST_TMPDIR/restarts"; }
  verify_gateway_env_pin() { :; }
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/step6.sh"
}

@test "Step 6: a gateway the deploy stopped on purpose restarts WITHOUT the no-PID page" {
  swapped
  step6_setup
  install_external_plugin @openclaw/slack 2026.8.35
  req=0; missing_pid_restart_req main || req=$?
  finish_gateway_restart openclaw-gateway-main "" "$req"
  grep -qx openclaw-gateway-main "$TEST_TMPDIR/restarts"
  if grep -q "MainPID" "$TEST_TMPDIR/slack"; then echo "NEGATED ASSERTION FAILED: paged for a deliberate stop" >&2; false; fi
}

@test "Step 6: a genuinely unreadable PID (nothing stopped by the deploy) still pages" {
  step6_setup
  req=0; missing_pid_restart_req main || req=$?
  finish_gateway_restart openclaw-gateway-main "" "$req"
  grep -qx openclaw-gateway-main "$TEST_TMPDIR/restarts"
  grep -q "could not capture a pre-request MainPID" "$TEST_TMPDIR/slack"
}

@test "Step 6: the exemption is per profile (edge stopped, main PID unreadable -> main still pages)" {
  swapped
  step6_setup
  TARGET=edge install_external_plugin @openclaw/codex 2026.8.35
  req=0; missing_pid_restart_req main || req=$?
  finish_gateway_restart openclaw-gateway-main "" "$req"
  grep -q "could not capture a pre-request MainPID" "$TEST_TMPDIR/slack"
}

# The record must SURVIVE a failure inside Step 6: rollback.sh Step 1c restores the
# binary only under the user_version guard, and a record cleared early would leave
# a failed Step 6 with the new runtime under old plugins. It is removed only once
# Step 6 has finished, i.e. after the edge gateway's restart handling.
@test "Step 6: the pre-deploy runtime record is cleared AFTER the gateway restarts, not before" {
  rm_line=$(grep -n '^rm -f "\$DEPLOY_PATH/.pre-deploy-openclaw-version"' "$DEPLOY_SH" | head -1 | cut -d: -f1)
  req_line=$(grep -n 'request_safe_restart "openclaw-gateway-main" "main"' "$DEPLOY_SH" | head -1 | cut -d: -f1)
  edge_line=$(grep -n 'finish_gateway_restart "openclaw-gateway-edge"' "$DEPLOY_SH" | head -1 | cut -d: -f1)
  [ -n "$rm_line" ] && [ -n "$req_line" ] && [ -n "$edge_line" ]
  [ "$rm_line" -gt "$req_line" ]
  [ "$rm_line" -gt "$edge_line" ]
}

@test "install_openclaw records the state DB user_version on line 2 of the record" {
  grep -q 'state_user_versions "' "$DEPLOY_SH"
  mkdir -p "$TEST_TMPDIR/oc/.openclaw-main/state"
  sqlite3 "$TEST_TMPDIR/oc/.openclaw-main/state/openclaw.sqlite" "pragma user_version=15;"
  awk '/^state_user_versions\(\) \{/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/suv.sh"
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/suv.sh"
  [ "$(state_user_versions "$TEST_TMPDIR/oc")" = "main=15 edge=absent" ]
}
