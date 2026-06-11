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

# Shared fixtures for the structured-digest pipeline suites
# (validate-digest / redact-json / render-digest / build-blocks /
# post-digest / publish-digest). Contacts: A appears in convs 1+4, so a
# theme citing {1,4} recomputes to ONE unique customer; {1,2} to two;
# {1,2,3} to three. Conv ...099 exists ONLY in audit.jsonl (escalated).
setup_digest_fixtures() {
  cat > "$WORKDIR/conversations.jsonl" <<'EOF'
{"id":"215474000000001","contact_id":"contact-A","customer_email":"a@x.com"}
{"id":"215474000000002","contact_id":"contact-B","customer_email":"b@x.com"}
{"id":"215474000000003","contact_id":"contact-C","customer_email":null}
{"id":"215474000000004","contact_id":"contact-A","customer_email":"a@x.com"}
{"id":"215474000000005","contact_id":null,"customer_email":"d@x.com"}
EOF

  cat > "$WORKDIR/audit.jsonl" <<'EOF'
{"kind":"reasoning_leak","action":"escalated","conv":"215474000000099","reason":"tone","markers":["looking-at-history"],"sample":""}
EOF

  cat > "$WORKDIR/digest-daily.json" <<'EOF'
{
  "kind": "daily", "date": "2026-06-11", "window_hours": 30, "conv_count": 23,
  "severity": {"p0": 0, "p1": 0, "p2": 1},
  "scores": {"voice": 5, "tools": "skipped", "sentiment": 4},
  "guard": {"caught_stripped": 0, "caught_escalated": 0, "missed_shipped": 0, "source": "journalctl", "shapes": [], "items": []},
  "findings": [
    {"dimension": "sentiment", "severity": "P2", "text": "1 frustrated \"are you actually checking?\"", "conversation_ids": ["215474000000002"]},
    {"dimension": "good_catch", "severity": "info", "text": "clean refund-gate run", "conversation_ids": ["215474000000003"]}
  ],
  "themes": [
    {"category": "issue", "label": "Spotify sync stuck", "summary": "Releases not appearing after delivery.", "conversation_ids": ["215474000000001", "215474000000002"], "unique_customers": 2}
  ],
  "kb_gap_candidates": [],
  "degraded": []
}
EOF

  cat > "$WORKDIR/digest-weekly.json" <<'EOF'
{
  "kind": "weekly", "date": "2026-06-08", "window_hours": 168, "conv_count": 140,
  "severity": {"p0": 0, "p1": 1, "p2": 3},
  "scores": {"voice": 4, "tools": "skipped", "sentiment": 3},
  "guard": {"caught_stripped": 2, "caught_escalated": 1, "missed_shipped": 0, "source": "journalctl", "shapes": ["looking-at-history"],
    "items": [{"type": "unanswered_escalation", "conversation_id": "215474000000099", "note": "reason tone"}]},
  "findings": [
    {"dimension": "voice", "severity": "P2", "text": "1 blacklist \"Great question\"", "conversation_ids": ["215474000000005"]}
  ],
  "themes": [
    {"category": "feature_request", "label": "CSV export of credits", "summary": "Asked for a bulk export.", "conversation_ids": ["215474000000002", "215474000000003"], "unique_customers": 2}
  ],
  "kb_gap_candidates": [
    {"category": "question", "label": "How royalties accrue", "summary": "Same accrual question.", "conversation_ids": ["215474000000001", "215474000000002", "215474000000003"], "unique_customers": 3, "proposed_kb_note": "Royalties accrue when..."}
  ],
  "degraded": []
}
EOF
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
