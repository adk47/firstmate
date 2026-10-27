#!/usr/bin/env bats
# Tests for scripts/ghl-api-watchdog.sh — the daily GHL canary around
# scripts/ghl.sh (whose own behaviour is covered by ghl-client.bats).
#
# ghl.sh is STUBBED (GHL_CLIENT) and so is Slack (MUSO_BIN), so no test touches
# the live GHL API or a real key. The stub records which key each probe received.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/ghl-api-watchdog.sh"
B2B_KEY="b2bkey-SENTINEL-1111"
WB_KEY="wbkey-SENTINEL-2222"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/state"
  export GHL_STATE_DIR="$TEST_TMPDIR/state"
  export GHL_ENV_FILE="$TEST_TMPDIR/main.env"
  export GHL_CLIENT="$TEST_TMPDIR/bin/ghl"
  export GHL_SKIP_HOST_GUARD=1
  printf 'OTHER_SECRET=do-not-leak\nGHL_API_KEY=%s\nGHL_WINBACK_API_KEY=%s\n' "$B2B_KEY" "$WB_KEY" > "$GHL_ENV_FILE"
  unset GHL_API_KEY GHL_WINBACK_API_KEY
  stub_ghl 0 0 ""
  stub_muso 0
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# stub_ghl <b2b rc> <winback rc> <stderr line for a failing probe>
# Logs "<account> <key it received> <argv>" per call to $TEST_TMPDIR/ghl-calls.
stub_ghl() {
  cat > "$GHL_CLIENT" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--account" ] && [ "\$2" = "winback" ]; then acct=winback; key="\$GHL_WINBACK_API_KEY"; rc=$2
else acct=b2b; key="\$GHL_API_KEY"; rc=$1; fi
echo "\$acct \$key \$*" >> "$TEST_TMPDIR/ghl-calls"
[ "\$rc" -ne 0 ] && echo "$3" >&2
exit \$rc
STUB
  chmod +x "$GHL_CLIENT"
}

# stub_muso <exit_code> — one log line per send (newlines collapsed).
stub_muso() {
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/usr/bin/env bash
all="\$*"
printf '%s\n' "\${all//\$'\n'/ }" >> "$TEST_TMPDIR/slack-sends"
exit $1
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test"
  export MUSO_SLACK_ENV_FILE="/dev/null"
}

sends() { if [ -f "$TEST_TMPDIR/slack-sends" ]; then wc -l < "$TEST_TMPDIR/slack-sends" | tr -d ' '; else echo 0; fi; }

@test "both clean: no post, exit 0, the log line says clean" {
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean: b2b ok, winback ok"* ]]
  [ "$(sends)" -eq 0 ]
  [ "$(wc -l < "$TEST_TMPDIR/ghl-calls" | tr -d ' ')" -eq 2 ]
  grep -qF 'location_id=S5w31kRRgsBjjiVATWlP pipeline_id=GeSt85TueSvJ0SNFZXfQ limit=1' "$TEST_TMPDIR/ghl-calls"
  grep -qF -e '--account winback GET /opportunities/search location_id=fmK5Vl9sJv49WTYA0QyP limit=1' "$TEST_TMPDIR/ghl-calls"
}

@test "each probe gets its own account's key" {
  run "$WD"
  grep -qE "^b2b $B2B_KEY " "$TEST_TMPDIR/ghl-calls"
  grep -qE "^winback $WB_KEY " "$TEST_TMPDIR/ghl-calls"
}

@test "b2b exit 11: exactly one post, naming 1010, never the key" {
  stub_ghl 11 0 "ghl: HTTP 403 Cloudflare client-signature block: page DevOps with this line: error code: 1010"
  run "$WD"
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 1 ]
  grep -qF '1010' "$TEST_TMPDIR/slack-sends"
  grep -qF 'GHL canary: b2b (GHL_API_KEY)' "$TEST_TMPDIR/slack-sends"
  ! grep -qF "$B2B_KEY" "$TEST_TMPDIR/slack-sends"
  ! grep -qF "$WB_KEY" "$TEST_TMPDIR/slack-sends"
  [[ "$output" != *"$B2B_KEY"* ]]
  [[ "$output" == *"degraded: b2b exit 11, winback ok"* ]]
}

@test "a second run inside the cooldown posts nothing" {
  stub_ghl 11 0 "ghl: HTTP 403 Cloudflare client-signature block: error code: 1010"
  run "$WD"; [ "$(sends)" -eq 1 ]
  run "$WD"
  [ "$(sends)" -eq 1 ]
  [[ "$output" == *"page suppressed for b2b"* ]]
}

@test "a future-dated stamp (clock stepped back) does not mute the page" {
  stub_ghl 11 0 "ghl: HTTP 403 Cloudflare client-signature block: error code: 1010"
  mkdir -p "$TEST_TMPDIR/state"
  echo $(( $(date -u +%s) + 5 * 86400 )) > "$TEST_TMPDIR/state/ghl-api-b2b-last-alert"
  run "$WD"
  [ "$(sends)" -eq 1 ]
}

@test "cooldown is per account: winback still pages after b2b did" {
  stub_ghl 11 0 "ghl: HTTP 403 Cloudflare client-signature block: error code: 1010"
  run "$WD"; [ "$(sends)" -eq 1 ]
  stub_ghl 11 10 "ghl: HTTP 401 key rejected"
  run "$WD"
  [ "$(sends)" -eq 2 ]
  grep -qF 'GHL canary: winback (GHL_WINBACK_API_KEY)' "$TEST_TMPDIR/slack-sends"
}

@test "a recovery clears the stamp so the next failure pages at once" {
  stub_ghl 11 0 "ghl: HTTP 403 ... 1010"
  run "$WD"; [ "$(sends)" -eq 1 ]
  stub_ghl 0 0 ""
  run "$WD"; [[ "$output" == *"clean: b2b ok, winback ok"* ]]
  stub_ghl 11 0 "ghl: HTTP 403 ... 1010"
  run "$WD"
  [ "$(sends)" -eq 2 ]
}

@test "a failed Slack post does not advance the cooldown" {
  stub_ghl 11 0 "ghl: HTTP 403 ... 1010"
  stub_muso 1
  run "$WD"
  [[ "$output" == *"cooldown NOT advanced"* ]]
  stub_muso 0
  run "$WD"
  [ "$(sends)" -eq 2 ]
}

@test "env file with two GHL_API_KEY lines: the last wins (and the file is not sourced)" {
  printf 'GHL_API_KEY=stale-first\nexport GHL_API_KEY="%s" # rotated\nGHL_WINBACK_API_KEY=%s\nBOOM=$(touch %s/sourced)\n' \
    "$B2B_KEY" "$WB_KEY" "$TEST_TMPDIR" > "$GHL_ENV_FILE"
  run "$WD"
  [ "$status" -eq 0 ]
  grep -qE "^b2b $B2B_KEY " "$TEST_TMPDIR/ghl-calls"
  [ ! -e "$TEST_TMPDIR/sourced" ]
}

@test "var missing from the env file: the page names the var, no probe runs for it" {
  printf 'GHL_API_KEY=%s\n' "$B2B_KEY" > "$GHL_ENV_FILE"
  run "$WD"
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 1 ]
  grep -qF 'GHL canary: winback (GHL_WINBACK_API_KEY)' "$TEST_TMPDIR/slack-sends"
  grep -qF 'GHL_WINBACK_API_KEY is missing or empty' "$TEST_TMPDIR/slack-sends"
  ! grep -q '^winback' "$TEST_TMPDIR/ghl-calls"
}

@test "unreadable env file pages both accounts by var name" {
  rm -f "$GHL_ENV_FILE"
  run "$WD"
  [ "$(sends)" -eq 2 ]
  grep -qF 'GHL_API_KEY is missing or empty' "$TEST_TMPDIR/slack-sends"
}

@test "--dry-run: no post and no cooldown stamp, even on a failure" {
  stub_ghl 11 10 "ghl: HTTP 403 ... 1010"
  run "$WD" --dry-run
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 0 ]
  [[ "$output" == *"DRY-RUN: would page"* ]]
  [ -z "$(ls -A "$TEST_TMPDIR/state")" ]
}

@test "--dry-run leaves an existing stamp alone on a clean run" {
  echo 123 > "$TEST_TMPDIR/state/ghl-api-b2b-last-alert"
  run "$WD" --dry-run
  [ -e "$TEST_TMPDIR/state/ghl-api-b2b-last-alert" ]
}

@test "host guard: off node-8 it refuses and runs no probe" {
  printf '#!/usr/bin/env bash\necho some-laptop\n' > "$TEST_TMPDIR/bin/hostname"
  chmod +x "$TEST_TMPDIR/bin/hostname"
  PATH="$TEST_TMPDIR/bin:$PATH" GHL_SKIP_HOST_GUARD=0 run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing to run"* ]]
  [ ! -f "$TEST_TMPDIR/ghl-calls" ]
}

@test "unknown arg exits 2" {
  run "$WD" --nope
  [ "$status" -eq 2 ]
}
