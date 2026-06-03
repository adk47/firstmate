#!/usr/bin/env bash
# Shared helpers for muso-caroline-weekly-review bats tests.
# CRITICAL: PATH-stub external tools so tests never touch prod
# (see feedback_bats_must_stub_openclaw.md).

setup_skill_tmp() {
  export TEST_TMPDIR="$(mktemp -d)"
  export WORKDIR="$TEST_TMPDIR/workdir"
  mkdir -p "$WORKDIR"

  mkdir -p "$TEST_TMPDIR/bin"

  # openclaw stub — records calls, never delivers
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf 'openclaw %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/openclaw.calls"
exit 0
STUB

  # gh stub — records calls, simulates success
  cat > "$TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/gh.calls"
case "$1" in
  pr)
    [[ "$2" == "create" ]] && echo "https://github.com/Muso-AI/hydra/pull/9999"
    ;;
  auth)
    [[ "$2" == "status" ]] && exit 0
    ;;
esac
exit 0
STUB

  # curl stub — reads $TEST_TMPDIR/curl-fixture.json if present, else 200 empty.
  # Honors -D <file> (writes headers), -o <file> (writes body), and
  # -w "%{http_code}" (appends code to stdout) so scripts that use any of
  # these flags work correctly in tests.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/curl.calls"
# Parse -D and -o flags
HEADERS_FILE=""
BODY_FILE=""
HTTP_CODE_FORMAT=""
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    -D) HEADERS_FILE="${args[$((i+1))]}" ;;
    -o) BODY_FILE="${args[$((i+1))]}" ;;
    -w) HTTP_CODE_FORMAT="${args[$((i+1))]}" ;;
    *%{http_code}*) HTTP_CODE_FORMAT="${args[$i]}" ;;
  esac
done
CONTENT=$([ -f "${TEST_TMPDIR:-/tmp}/curl-fixture.json" ] && cat "${TEST_TMPDIR:-/tmp}/curl-fixture.json" || echo '{}')
if [ -n "$BODY_FILE" ]; then
  echo "$CONTENT" > "$BODY_FILE"
else
  echo "$CONTENT"
fi
if [ -n "$HEADERS_FILE" ]; then
  printf "HTTP/1.1 200 OK\r\n" > "$HEADERS_FILE"
fi
# If caller used -w "%{http_code}" (or similar), append the simulated code
# on its own line so the script can parse it via tail -n1.
if [ -n "$HTTP_CODE_FORMAT" ] && [[ "$HTTP_CODE_FORMAT" == *%{http_code}* ]]; then
  if [ -f "${TEST_TMPDIR:-/tmp}/curl-http-code" ]; then
    echo
    cat "${TEST_TMPDIR:-/tmp}/curl-http-code"
  else
    echo
    echo 200
  fi
fi
exit 0
STUB

  # journalctl stub — reads $TEST_TMPDIR/journal-fixture.txt if present
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf 'journalctl %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/journalctl.calls"
if [ -f "${TEST_TMPDIR:-/tmp}/journal-fixture.txt" ]; then
  cat "${TEST_TMPDIR:-/tmp}/journal-fixture.txt"
fi
exit 0
STUB

  chmod +x "$TEST_TMPDIR/bin/"*
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Common env used by scripts under test
  export MUSOAI_INTERCOM_TOKEN="test-token"
  export CAROLINE_BOT_ADMIN_ID="caroline-admin-123"
}

teardown_skill_tmp() {
  rm -rf "$TEST_TMPDIR"
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
