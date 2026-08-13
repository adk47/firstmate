#!/usr/bin/env bats
# Tests for scripts/lib/codex-quota-probe.sh — the live-measurement probe that
# replaces standby-quota inference (see codex-quota.sh's incident writeup).
# This is the one surface in the codex-quota layer that is NOT pure: it spawns
# a real `codex app-server` process against a throwaway CODEX_HOME. Every test
# here runs against a FAKE `codex` binary stub on PATH and a scratch auth
# store built with dummy, syntactically-plausible-but-fake credentials — never
# real tokens, never the live canonical store (see memory/feedback about bats
# suites that must stub codex/openclaw/ssh).
#
# The suite exercises the script's five safety layers directly (see the file
# header): sentinel-only scratch credentials, the pre-expiry skip margin, the
# absolute/basename/symlink scratch-path guard, tmpfs-optional scratch
# cleanup on every exit path (including timeout), and the post-run rewrite
# detector.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-quota-probe.sh"
SYNC_SCRIPT="$HYDRA_REPO/scripts/lib/codex-auth-sync.sh"

# A syntactically plausible but fake access token (NOT a real JWT — nothing
# here ever decodes it, cq_parse_ratelimits only cares about app-server's
# stdout).
DUMMY_ACCESS="access-tok-9f8e7d6c5b4a-DUMMY-NOT-REAL"
DUMMY_ACCOUNT_ID="acc-dummy-0000-1111"
# A real-looking dummy refresh token, distinctive enough to grep for.
DUMMY_REFRESH="rt-REAL-LOOKING-DUMMY-REFRESH-abcdef0123456789"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/scratch-root"

  export CODEX_AUTH_STORE="$TEST_TMPDIR/auth-profiles.json"
  export CODEX_PLUGIN_ROOT="$TEST_TMPDIR/plugin-root"
  export CODEX_PROBE_SCRATCH_ROOT="$TEST_TMPDIR/scratch-root"
  export CODEX_PROBE_MIN_TOKEN_MIN=60
  export CODEX_PROBE_TIMEOUT=30
  export CODEX_PROBE_DISABLED_FLAG="$TEST_TMPDIR/absent-disabled-flag"

  # expires far in the future, epoch MILLISECONDS (the script's unit — note
  # this is easy to get wrong: `expires` is ms, `date +%s` is seconds).
  local far_future_ms=$(( ($(date +%s) + 100000000) * 1000 ))
  cat > "$CODEX_AUTH_STORE" <<JSON
{"profiles":{
  "openai-codex:test@x.com":{"provider":"openai-codex","type":"oauth","email":"test@x.com","chatgptPlanType":"pro","expires":$far_future_ms,"accountId":"$DUMMY_ACCOUNT_ID","access":"$DUMMY_ACCESS","refresh":"$DUMMY_REFRESH"}
}}
JSON

  mkdir -p "$CODEX_PLUGIN_ROOT/@openclaw/codex/vendor"
  _write_stub_codex
  cp "$TEST_TMPDIR/bin/codex" "$CODEX_PLUGIN_ROOT/@openclaw/codex/vendor/codex"
  chmod +x "$CODEX_PLUGIN_ROOT/@openclaw/codex/vendor/codex"
  BIN="$CODEX_PLUGIN_ROOT/@openclaw/codex/vendor/codex"; export BIN

  # No `find` shim here on purpose. cqp_resolve_binary used to depend on
  # `find -printf` (a GNU extension BSD/macOS find lacks), and a shim made this
  # suite pass while the real function silently returned nothing on macOS — a
  # test that proves the shim works, not the code. The function now sorts with
  # POSIX `ls -t`, so this suite exercises it directly on both platforms.
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # shellcheck disable=SC1090
  source "$SCRIPT"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# STUB_MODE: ok (default) | fail | hang | rewrite
# STUB_HELP_FAILS=1: `app-server --help` fails (preflight failure case)
# STUB_MARKER: touched whenever `app-server` (not --help) actually runs
# STUB_COPY_DIR: if set, the stub copies its $CODEX_HOME aside before exiting
_write_stub_codex() {
  cat > "$TEST_TMPDIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "app-server" ] && [ "${2:-}" = "--help" ]; then
  [ "${STUB_HELP_FAILS:-0}" = "1" ] && exit 1
  exit 0
fi
if [ "$1" = "app-server" ]; then
  [ -n "${STUB_MARKER:-}" ] && : > "$STUB_MARKER"
  if [ -n "${STUB_COPY_DIR:-}" ]; then
    mkdir -p "$STUB_COPY_DIR"
    cp -a "$CODEX_HOME/." "$STUB_COPY_DIR/" 2>/dev/null || true
  fi
  case "${STUB_MODE:-ok}" in
    fail) exit 1 ;;
    hang) sleep 100 ;;
    rewrite)
      tmp="$CODEX_HOME/auth.json.tmp"
      jq '.tokens.refresh_token = "HACKED-ROTATED-TOKEN"' "$CODEX_HOME/auth.json" > "$tmp" \
        && mv "$tmp" "$CODEX_HOME/auth.json"
      exit 0
      ;;
    *)
      cat <<'JSONOUT'
{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":9999999999},"secondary":null,"planType":"pro","rateLimitReachedType":null}}}
JSONOUT
      exit 0
      ;;
  esac
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/codex"
}

_scratch_root_empty() {
  [ -z "$(ls -A "$CODEX_PROBE_SCRATCH_ROOT" 2>/dev/null)" ]
}

# ── 1. sentinel scratch credential + no real-refresh leak ────────────────

@test "probe builds scratch auth.json with the sentinel refresh slot and never leaks the real refresh token" {
  local copy="$TEST_TMPDIR/copy-aside"
  STUB_COPY_DIR="$copy" run cqp_main --account test@x.com
  [ "$status" -eq 0 ]
  [ -d "$copy" ]
  run jq -r '.tokens.refresh_token' "$copy/auth.json"
  [ "$output" = "SYNC-MANAGED-NO-REFRESH-TOKEN" ]
  run grep -raqF -- "$DUMMY_REFRESH" "$copy"
  [ "$status" -ne 0 ]
}

# ── 2. scratch dir absence on every exit path ─────────────────────────────

@test "scratch dir is absent after a normal exit" {
  cqp_main --account test@x.com >/dev/null
  _scratch_root_empty
}

@test "scratch dir is absent after the stub exits non-zero" {
  STUB_MODE=fail run cqp_main --account test@x.com
  [ "$status" -ne 0 ]
  _scratch_root_empty
}

# The timeout test above does NOT exercise the signal path — `timeout` kills the
# app-server child while the probe keeps running normally. This one sends TERM
# to the PROBE ITSELF, which is what systemd/cron do on a deploy or shutdown.
#
# Bash resumes execution after an INT/TERM handler that merely returns, so a
# cleanup-only trap deleted auth.json and then fell into the post-probe
# verification, which saw the missing credential, concluded it had been
# rewritten, and returned rc 9 — making codex-quota-refresh.sh write the
# persistent kill switch and page a credential-rewrite alarm. A routine stop
# would have disabled every later quota refresh until a human cleared it.
#
# The kill happens inside a FOREGROUND wrapper script, never from the test body:
# signalling a job that bats owns takes bats' own process tree down with it
# (observed: "Executed 14 instead of expected 15 tests").
@test "a TERM to the probe cleans up and exits 143 — never a false rc 9" {
  cat > "$TEST_TMPDIR/termrun.sh" <<WRAP
#!/usr/bin/env bash
source "$SCRIPT"
cqp_probe_account "openai-codex:test@x.com" "$BIN" > "$TEST_TMPDIR/term.out" 2>&1 &
p=\$!
sleep 2
kill -TERM "\$p" 2>/dev/null
wait "\$p" 2>/dev/null
echo "probe_rc=\$?"
WRAP
  chmod +x "$TEST_TMPDIR/termrun.sh"

  STUB_MODE=hang CODEX_PROBE_TIMEOUT=30 run "$TEST_TMPDIR/termrun.sh"

  # 143 = 128 + SIGTERM, i.e. the handler terminated rather than falling through.
  [[ "$output" == *"probe_rc=143"* ]]

  # No scratch may survive the signal.
  run bash -c 'ls -d "$1"/codex-quota-probe.* 2>/dev/null | wc -l | tr -d " "' _ "$CODEX_PROBE_SCRATCH_ROOT"
  [ "$output" = "0" ]

  # And it must NOT have reported a safety violation.
  run grep -q "SAFETY VIOLATION" "$TEST_TMPDIR/term.out"
  [ "$status" -ne 0 ]
}

@test "scratch dir is absent after the stub hangs and hits the timeout" {
  CODEX_PROBE_TIMEOUT=2 STUB_MODE=hang run cqp_main --account test@x.com
  [ "$status" -ne 0 ]
  _scratch_root_empty
}

# ── 3. _cqp_assert_safe_scratch ───────────────────────────────────────────

@test "_cqp_assert_safe_scratch: refuses a relative path" {
  run _cqp_assert_safe_scratch "codex-quota-probe-relative"
  [ "$status" -eq 2 ]
}

@test "_cqp_assert_safe_scratch: refuses a basename that does not start with codex-quota-probe" {
  run _cqp_assert_safe_scratch "$TEST_TMPDIR/not-ours"
  [ "$status" -eq 2 ]
}

@test "_cqp_assert_safe_scratch: refuses a one-segment top-level path" {
  run _cqp_assert_safe_scratch "/codex-quota-probe-topmost"
  [ "$status" -eq 2 ]
}

@test "_cqp_assert_safe_scratch: refuses a symlink" {
  mkdir -p "$TEST_TMPDIR/real-target"
  ln -s "$TEST_TMPDIR/real-target" "$TEST_TMPDIR/codex-quota-probe-link"
  run _cqp_assert_safe_scratch "$TEST_TMPDIR/codex-quota-probe-link"
  [ "$status" -eq 2 ]
}

@test "_cqp_assert_safe_scratch: accepts a valid absolute, correctly-named, non-symlink path" {
  mkdir -p "$TEST_TMPDIR/codex-quota-probe-valid"
  run _cqp_assert_safe_scratch "$TEST_TMPDIR/codex-quota-probe-valid"
  [ "$status" -eq 0 ]
}

# ── 4. Layer 2 — pre-expiry skip margin ───────────────────────────────────

@test "an account whose token expires within CODEX_PROBE_MIN_TOKEN_MIN is skipped, never invoked" {
  local marker="$TEST_TMPDIR/stub-invoked-marker"
  local near_ms=$(( ($(date +%s) + 30 * 60) * 1000 ))  # expires in 30min < 60min floor
  cat > "$CODEX_AUTH_STORE" <<JSON
{"profiles":{
  "openai-codex:test@x.com":{"provider":"openai-codex","type":"oauth","email":"test@x.com","chatgptPlanType":"pro","expires":$near_ms,"accountId":"$DUMMY_ACCOUNT_ID","access":"$DUMMY_ACCESS","refresh":"$DUMMY_REFRESH"}
}}
JSON
  STUB_MARKER="$marker" run cqp_probe_account "openai-codex:test@x.com" "$BIN"
  [ "$status" -ne 0 ]
  [ ! -e "$marker" ]
}

# ── 5. rewrite detector (SAFETY VIOLATION) ────────────────────────────────

@test "a stub that rewrites CODEX_HOME/auth.json's refresh slot triggers a SAFETY VIOLATION (status 9)" {
  STUB_MODE=rewrite run cqp_probe_account "openai-codex:test@x.com" "$BIN"
  [ "$status" -eq 9 ]
  [[ "$output" == *"SAFETY VIOLATION"* ]]
}

# ── 6. preflight failure ──────────────────────────────────────────────────

@test "cqp_preflight returns 2 when 'app-server --help' fails" {
  STUB_HELP_FAILS=1 run cqp_preflight "$BIN"
  [ "$status" -eq 2 ]
}

# ── 7. kill switch ─────────────────────────────────────────────────────────

@test "kill switch: an existing CODEX_PROBE_DISABLED_FLAG file makes cqp_main return 1 without invoking the stub" {
  local marker="$TEST_TMPDIR/stub-invoked-marker"
  : > "$CODEX_PROBE_DISABLED_FLAG"
  STUB_MARKER="$marker" run cqp_main --account test@x.com
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

# ── 8. drift sentinel ──────────────────────────────────────────────────────

@test "DRIFT SENTINEL: the literal sentinel string is present in BOTH codex-auth-sync.sh and codex-quota-probe.sh" {
  # If one file's sentinel changes without the other, the probe's safety
  # layer 1 (scratch credential is byte-shaped like a real per-agent store)
  # silently breaks: the scratch auth.json would carry a value app-server
  # could plausibly try to use, or codex-auth-sync.sh's drift check
  # (codex-quota-probe.sh:71-72) would no longer be true. Keep both edits
  # atomic.
  run grep -qF "SYNC-MANAGED-NO-REFRESH-TOKEN" "$SYNC_SCRIPT"
  [ "$status" -eq 0 ]
  run grep -qF "SYNC-MANAGED-NO-REFRESH-TOKEN" "$SCRIPT"
  [ "$status" -eq 0 ]
}
