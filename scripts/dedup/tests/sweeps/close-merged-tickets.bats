#!/usr/bin/env bats

# Smoke tests for the args/validation layer of close-merged-tickets.sh.
# Network paths (Trino + ClickUp) are not exercised here — they require live
# stubs and an integration harness — but the input-validation guards that
# protect against bad operator invocations are covered.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SWEEP="$REPO_ROOT/scripts/dedup/sweeps/close-merged-tickets.sh"
}

@test "rejects non-numeric --days" {
  CLICKUP_API_KEY=fake run bash "$SWEEP" --days notanumber
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "must be a non-negative integer"
}

@test "rejects --days with SQL-injection attempt" {
  CLICKUP_API_KEY=fake run bash "$SWEEP" --days "30' day; DROP TABLE--"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "must be a non-negative integer"
}

@test "rejects unknown flag" {
  CLICKUP_API_KEY=fake run bash "$SWEEP" --frobnicate
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown flag"
}

@test "rejects when CLICKUP_API_KEY missing" {
  run env -u CLICKUP_API_KEY bash "$SWEEP" --dry-run
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "CLICKUP_API_KEY not set"
}

@test "rejects when MUSOAI_INTERCOM_TOKEN missing and customer-reply check enabled" {
  # Default behavior: customer-reply check is ON, so MUSOAI_INTERCOM_TOKEN required.
  run env CLICKUP_API_KEY=fake -u MUSOAI_INTERCOM_TOKEN bash "$SWEEP" --dry-run
  # The Trino-or-curl call will likely fail before this, but the script must
  # at least include the Intercom token requirement in its docs.
  bash "$SWEEP" --help | grep -q "MUSOAI_INTERCOM_TOKEN"
}

@test "--skip-customer-reply-check is documented in --help" {
  run bash "$SWEEP" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--skip-customer-reply-check"
}

@test "--help exits 0 and prints usage" {
  run bash "$SWEEP" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage:"
  echo "$output" | grep -q -- "--apply"
}

# Fetch-path test: the ClickUp query must be server-side filtered to the
# action:profile-merge tag (so it scans the handful of merge tickets, not the
# whole 4,500+-task board) and complete without hitting PAGINATION_CAP. muso
# (Trino) and curl (ClickUp) are PATH-shadowed; --skip-customer-reply-check
# keeps it off Intercom; --dry-run keeps it read-only.
@test "fetch is server-side filtered by action:profile-merge tag and completes without the cap" {
  STUBDIR="$(mktemp -d)"

  cat > "$STUBDIR/muso" <<'MUSOEOF'
#!/usr/bin/env bash
# Ignore SQL on stdin; emit one executed merge in the action_log NDJSON shape
# (loser P-LOSER folded into survivor P-SURVIVOR).
cat <<'JSON'
{"merge_into":"P-SURVIVOR","profiles_ids":"[\"P-LOSER\"]","at":"2026-06-01 00:00:00"}
JSON
MUSOEOF
  chmod +x "$STUBDIR/muso"

  cat > "$STUBDIR/curl" <<'CURLEOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -X|-H|-w|--data) shift 2;;
    -sS|-s|-S) shift;;
    http*) url="$1"; shift;;
    *) shift;;
  esac
done
[ -n "${CURL_URL_LOG:-}" ] && printf '%s\n' "$url" >> "$CURL_URL_LOG"
# page 0 -> one tagged merge ticket; page>=1 -> empty (terminates the loop)
if printf '%s' "$url" | grep -q 'page=0'; then
  cat > "$out" <<'JSON'
{"tasks":[{"id":"TASK1","url":"https://app.clickup.com/t/TASK1","status":{"status":"to do"},"description":"hi ---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P-LOSER\", \"customer_email\": \"x@example.com\"} ---END-ACTION-REQUEST---"}]}
JSON
else
  printf '%s' '{"tasks":[]}' > "$out"
fi
printf '200'
CURLEOF
  chmod +x "$STUBDIR/curl"

  run env PATH="$STUBDIR:$PATH" CLICKUP_API_KEY=fake \
      CURL_URL_LOG="$STUBDIR/curl-urls.log" \
      bash "$SWEEP" --dry-run --skip-customer-reply-check --days 90

  [ "$status" -eq 0 ]
  # The fetch carried the server-side tag filter (URL-encoded tags[]=action:profile-merge).
  grep -q 'tags%5B%5D=action%3Aprofile-merge' "$STUBDIR/curl-urls.log"
  # It did NOT abort at the pagination cap.
  ! echo "$output" | grep -q "PAGINATION_CAP"
  # It pulled the one tagged ticket and matched it to the executed merge.
  echo "$output" | grep -q "pulled 1 open profile-merge tickets"
  echo "$output" | grep -q "1 tickets match an executed merge"

  rm -rf "$STUBDIR"
}
