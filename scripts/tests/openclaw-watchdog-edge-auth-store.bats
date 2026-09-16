#!/usr/bin/env bats
# Behavioral tests for the EDGE AUTH-STORE tripwire in scripts/openclaw-watchdog.sh.
#
# This guard exists because the check it replaced was correct for 7.1 and WRONG
# for 2.0, and nothing in the code said which era it was written for. On
# openclaw <= 2026.7 edge's codex credential lived in
# `agents/support/agent/auth-profiles.json` as a SYMLINK to main's canonical
# token, so `missing` meant "never provisioned" — a real alarm. On 2026.8 that
# file does not exist at all: each profile reads its own `authProfiles.store`
# cell in `<stateDir>/state/openclaw.sqlite`, populated by codex-edge-mirror.sh.
# So after the 2026-09-10 cutover the ungated probe read `missing` BY DESIGN and
# paged #clio_devops every hour, for a provably healthy edge, with a remedy
# (restart edge to re-run ensure-codex-auth) that does nothing on 2.0.
#
# The fix is NOT "delete the check" — edge's credential still needs a tripwire,
# it just needs the 2.0 one. So these cases pin both eras AND the refusal to
# guess between them:
#   1. 7.1 + broken symlink        → pages (the original alarm still works)
#   2. 7.1 + ok symlink            → silent
#   3. 2.0 + clean cell + timer    → silent (the false positive is GONE)
#   4. 2.0 + cell drift            → pages (the real 2.0 alarm)
#   5. 2.0 + clean cell, timer off → pages (the outage that hasn't happened yet)
#   6. unparseable runtime version → pages UNEVALUATED, never silence
#
# Case 6 is the one that makes this honest. A tripwire that goes quiet because it
# could not tell which era it is in looks exactly like a healthy one, and that
# ambiguity is the whole reason this guard was wrong for six days.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/openclaw-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/sysctl" "$TEST_TMPDIR/oc" "$TEST_TMPDIR/secrets"

  # A real maintenance window would disarm the whole watchdog (CI runs on the
  # live node-8 host, which has one during deploys). Pin it absent.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"

  export STUB_SYSCTL_DIR="$TEST_TMPDIR/sysctl"
  export STUB_OPENCLAW_DIR="$TEST_TMPDIR/oc"
  export WATCHDOG_STATE_DIR="$TEST_TMPDIR/state"; mkdir -p "$WATCHDOG_STATE_DIR"

  # Pages are captured, never delivered. A FAKE token is required, not optional:
  # `slack_notify` does `slack_load_env || return 0`, so with no token it returns
  # silently and every page assertion below would pass vacuously against a guard
  # that never fired. The real token is unset first (CI runs on a credentialed
  # host and slack_load_env honours an already-exported var), and delivery is
  # stubbed at MUSO_BIN, so nothing can reach Slack.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"
  printf 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test-not-a-real-token\n' > "$MUSO_SLACK_ENV_FILE"

  printf 'x' > "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  chmod 600 "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  export HYDRA_SECRETS_DIR="$TEST_TMPDIR/secrets"

  # Refresh-lock convergence reads clean (edge dir is a symlink to main's), so
  # its own tripwire cannot add a page and confuse the assertions below.
  export CODEX_LOCK_ROOT="$TEST_TMPDIR/lockroot"
  mkdir -p "$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh" "$CODEX_LOCK_ROOT/.openclaw-edge/locks"
  ln -s "$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh" "$CODEX_LOCK_ROOT/.openclaw-edge/locks/oauth-refresh"

  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  is-active)
    f="$STUB_SYSCTL_DIR/$2.status"
    [ -f "$f" ] && cat "$f" || echo active ;;
  is-enabled) echo "${STUB_UNIT_ENABLED:-enabled}" ;;
  *) : ;;
esac
exit 0
STUB

  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  # STUB_OPENCLAW_VERSION="" models an openclaw that is absent or answers
  # something non-version-shaped — openclaw_runtime_version() returns empty for
  # both, which is the case-6 input.
  if [ -n "${STUB_OPENCLAW_VERSION+x}" ] && [ -z "$STUB_OPENCLAW_VERSION" ]; then
    echo "OpenClaw (unknown build)"
  else
    echo "openclaw ${STUB_OPENCLAW_VERSION:-2026.8.2}"
  fi
  exit 0
fi
prof=""
while [ $# -gt 0 ]; do
  case "$1" in --profile) prof="$2"; shift 2 ;; *) shift ;; esac
done
f="$STUB_OPENCLAW_DIR/$prof.validate"
[ -f "$f" ] && cat "$f" || echo "Config valid: /root/.openclaw-$prof/openclaw.json"
exit 0
STUB

  # journalctl silent: no codex signature lines, so the only page this suite can
  # produce is the one under test.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/journalctl"

  # The muso CLI is the page sink. Record the Slack text instead of sending it.
  export PAGE_LOG="$TEST_TMPDIR/pages.log"
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"slack send"* ]]; then printf '%s\n' "\$*" >> "$PAGE_LOG"; fi
exit 0
STUB
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"

  # The mirror's read-only --check, stubbed: 0 clean / 1 drift / 2 unevaluatable,
  # which is its real documented contract. The live script would read the edge
  # SQLite cell on node-8.
  cat > "$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh" <<'MSTUB'
#!/usr/bin/env bash
exit "${STUB_MIRROR_CHECK_RC:-0}"
MSTUB
  export WATCHDOG_EDGE_MIRROR_CHECK="$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh"
  export WATCHDOG_EDGE_MIRROR_TIMER="codex-edge-mirror.timer"

  # DR escalation must never spawn the real healer (it makes a live OpenRouter
  # call and can restart gateways).
  export DR_CALLS="$TEST_TMPDIR/dr-calls"; : > "$DR_CALLS"
  export DR_STATE_DIR="$TEST_TMPDIR/dr-state"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$DR_CALLS"\nexit 0\n' > "$TEST_TMPDIR/bin/dr-ai-healer.sh"
  export DR_AI_HEALER_BIN="$TEST_TMPDIR/bin/dr-ai-healer.sh"

  chmod +x "$TEST_TMPDIR/bin/"*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# A symlink fixture whose target exists → codex_edge_auth_symlink_status "ok".
_link_ok() {
  printf '{}' > "$TEST_TMPDIR/canon-auth.json"
  ln -sf "$TEST_TMPDIR/canon-auth.json" "$TEST_TMPDIR/edge-auth.json"
  export WATCHDOG_EDGE_AUTH_PROFILES="$TEST_TMPDIR/edge-auth.json"
}

# No file at all → status "missing". This is the exact on-disk shape of a live
# 2.0 host, which is why case 3 matters.
_link_missing() {
  export WATCHDOG_EDGE_AUTH_PROFILES="$TEST_TMPDIR/does-not-exist.json"
}

_edge_auth_page() { grep -h "Edge Codex auth store" "$PAGE_LOG" 2>/dev/null || true; }

# ── 7.1 era: the original alarm must still work ──────────────────────────────

@test "7.1 + missing symlink: still pages, and names the symlink status" {
  export STUB_OPENCLAW_VERSION="2026.7.1"
  _link_missing

  run "$WD"

  [ "$status" -eq 0 ]
  [[ "$(_edge_auth_page)" == *"symlink-missing"* ]]
  [[ "$(_edge_auth_page)" == *"2026.7.1"* ]]
  # The 7.1 remedy is the one that actually works on 7.1.
  [[ "$(_edge_auth_page)" == *"ensure-codex-auth"* ]]
}

@test "7.1 + a clobbered symlink (regular file) pages not-symlink" {
  export STUB_OPENCLAW_VERSION="2026.7.1"
  printf '{}' > "$TEST_TMPDIR/edge-auth.json"     # regular file, not a link
  export WATCHDOG_EDGE_AUTH_PROFILES="$TEST_TMPDIR/edge-auth.json"

  run "$WD"

  [ "$status" -eq 0 ]
  [[ "$(_edge_auth_page)" == *"symlink-not-symlink"* ]]
}

@test "7.1 + healthy symlink: silent" {
  export STUB_OPENCLAW_VERSION="2026.7.1"
  _link_ok

  run "$WD"

  [ "$status" -eq 0 ]
  [ -z "$(_edge_auth_page)" ]
}

# ── 2.0 era: the false positive is gone, the real alarms are not ─────────────

@test "2.0 + absent symlink + clean cell + enabled timer: SILENT (the hourly false positive)" {
  export STUB_OPENCLAW_VERSION="2026.8.2"
  _link_missing                      # exactly what node-8 looks like today
  export STUB_MIRROR_CHECK_RC=0
  export STUB_UNIT_ENABLED=enabled

  run "$WD"

  [ "$status" -eq 0 ]
  [ -z "$(_edge_auth_page)" ]
}

@test "2.0 + cell drift: pages, and points at the mirror check rather than a restart" {
  export STUB_OPENCLAW_VERSION="2026.8.2"
  _link_missing
  export STUB_MIRROR_CHECK_RC=1      # documented: 1 = drift
  export STUB_UNIT_ENABLED=enabled

  run "$WD"

  [ "$status" -eq 0 ]
  [[ "$(_edge_auth_page)" == *"cell-drift"* ]]
  [[ "$(_edge_auth_page)" == *"codex-edge-mirror.sh --check"* ]]
  # The 7.1 remedy must NOT be offered on 2.0 — it is the un-actionable advice
  # that made the old page worthless.
  [[ "$(_edge_auth_page)" != *"ensure-codex-auth"* ]]
}

@test "2.0 + mirror check cannot evaluate: pages UNEVALUATED, never 'healthy'" {
  export STUB_OPENCLAW_VERSION="2026.8.2"
  _link_missing
  export STUB_MIRROR_CHECK_RC=2      # documented: 2 = could not evaluate
  export STUB_UNIT_ENABLED=enabled

  run "$WD"

  [ "$status" -eq 0 ]
  [[ "$(_edge_auth_page)" == *"unevaluated"* ]]
  [[ "$(_edge_auth_page)" == *"UNKNOWN, not healthy"* ]]
}

@test "2.0 + clean cell but the mirror timer is disabled: pages (stale-by-rotation)" {
  export STUB_OPENCLAW_VERSION="2026.8.2"
  _link_missing
  export STUB_MIRROR_CHECK_RC=0
  export STUB_UNIT_ENABLED=disabled

  run "$WD"

  [ "$status" -eq 0 ]
  [[ "$(_edge_auth_page)" == *"mirror-timer-disabled"* ]]
  [[ "$(_edge_auth_page)" == *"codex-edge-mirror.timer"* ]]
}

# ── the refusal to guess ─────────────────────────────────────────────────────

@test "unparseable runtime version: pages UNEVALUATED instead of silently skipping" {
  export STUB_OPENCLAW_VERSION=""    # openclaw answers "OpenClaw (unknown build)"
  _link_ok                           # a healthy 7.1 fixture must NOT buy silence

  run "$WD"

  [ "$status" -eq 0 ]
  [[ "$(_edge_auth_page)" == *"unevaluated"* ]]
  [[ "$(_edge_auth_page)" == *"cannot be determined"* ]]
}

# ── the cooldown still applies, so a standing condition pages hourly not 2-minutely ──

@test "a fresh cooldown stamp suppresses a repeat page for the same condition" {
  export STUB_OPENCLAW_VERSION="2026.8.2"
  _link_missing
  export STUB_MIRROR_CHECK_RC=1
  date -u +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-symlink-cooldown"

  run "$WD"

  [ "$status" -eq 0 ]
  [ -z "$(_edge_auth_page)" ]
}
