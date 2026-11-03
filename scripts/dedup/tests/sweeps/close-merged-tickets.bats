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
  # env(1) parses its OPTIONS before the assignments, so "-u NAME" must come FIRST: after an assignment,
  # "-u" is taken as the command to run and the step dies 127 (bats fails that as an unasserted non-zero run).
  run env -u MUSOAI_INTERCOM_TOKEN CLICKUP_API_KEY=fake bash "$SWEEP" --dry-run
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
  if echo "$output" | grep -q "PAGINATION_CAP"; then echo "unexpected match: PAGINATION_CAP" >&2; return 1; fi
  # It pulled the one tagged ticket and matched it to the executed merge.
  echo "$output" | grep -q "pulled 1 open profile-merge tickets"
  echo "$output" | grep -q "1 tickets match an executed merge"

  rm -rf "$STUBDIR"
}

# 2026-10-26 (profile-merge-ops-m1): "executed" means a VERIFIED row in core's merge
# ledger, never an action_log POST (which includes merges core refused 409/400), and a
# ticket naming its duplicates closes only when each one was merged away.
@test "merges come from verified profile_merges rows, and named duplicates must all be merged" {
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/muso" <<'MUSOEOF'
#!/usr/bin/env bash
cat > "$SQL_LOG"
printf '%s\n' '{"merge_into":"11111111-1111-4111-8111-111111111111","profiles_ids":"[\"22222222-2222-4222-8222-222222222222\"]","at":"2026-10-26 21:50:43.582000 UTC"}'
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
if printf '%s' "$url" | grep -q 'page=0'; then
  cat > "$out" <<'JSON'
{"tasks":[
 {"id":"DONE","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"x@example.com\", \"details\": {\"duplicate_profile_urls\": [\"https://muso.ai/profile/22222222-2222-4222-8222-222222222222\"]}} ---END-ACTION-REQUEST---"},
 {"id":"STILL","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"y@example.com\", \"details\": {\"duplicate_profile_urls\": [\"https://muso.ai/profile/33333333-3333-4333-8333-333333333333\"]}} ---END-ACTION-REQUEST---"},
 {"id":"HALFREAD","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"h@example.com\", \"details\": {\"duplicate_profile_urls\": [\"https://muso.ai/profile/22222222-2222-4222-8222-222222222222\", \"https://muso.ai/artist/rich-j-kidd\"]}} ---END-ACTION-REQUEST---"},
 {"id":"NONEREAD","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"n@example.com\", \"details\": {\"duplicate_profile_urls\": [\"Rich J Kidd (the other one)\"]}} ---END-ACTION-REQUEST---"},
 {"id":"UNREADKEEP","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"k@example.com\", \"details\": {\"main_profile_url\": \"https://muso.ai/artist/kept-profile\", \"duplicate_profile_urls\": [\"https://muso.ai/profile/22222222-2222-4222-8222-222222222222\"]}} ---END-ACTION-REQUEST---"},
 {"id":"CONFLICTKEEP","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"c@example.com\", \"details\": {\"main_profile_url\": \"https://muso.ai/profile/11111111-1111-4111-8111-111111111111\", \"survivor_profile_id\": \"55555555-5555-4555-8555-555555555555\", \"duplicate_profile_urls\": [\"https://muso.ai/profile/22222222-2222-4222-8222-222222222222\"]}} ---END-ACTION-REQUEST---"},
 {"id":"OTHERKEEP","url":"u","status":{"status":"to do"},"description":"---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"11111111-1111-4111-8111-111111111111\", \"customer_email\": \"z@example.com\", \"details\": {\"main_profile_url\": \"https://muso.ai/profile/44444444-4444-4444-8444-444444444444\", \"duplicate_profile_urls\": [\"https://muso.ai/profile/22222222-2222-4222-8222-222222222222\"]}} ---END-ACTION-REQUEST---"}
]}
JSON
else
  printf '%s' '{"tasks":[]}' > "$out"
fi
printf '200'
CURLEOF
  chmod +x "$STUBDIR/curl"

  run env PATH="$STUBDIR:$PATH" CLICKUP_API_KEY=fake SQL_LOG="$STUBDIR/sql.log" \
      bash "$SWEEP" --dry-run --skip-customer-reply-check --days 90

  [ "$status" -eq 0 ]
  grep -q "postgresql_core.public.profile_merges" "$STUBDIR/sql.log"
  grep -q "status = 'verified'" "$STUBDIR/sql.log"
  if grep -q "action_log" "$STUBDIR/sql.log"; then echo "unexpected match: action_log" >&2; return 1; fi
  echo "$output" | grep -q "1 tickets match an executed merge"
  echo "$output" | grep -q '"task_id":"DONE"'
  if echo "$output" | grep -q '"task_id":"STILL"'; then echo "unexpected match: task_id:STILL" >&2; return 1; fi
  # The duplicate went into 1111, not into the 4444 this ticket asked to keep.
  if echo "$output" | grep -q '"task_id":"OTHERKEEP"'; then echo "unexpected match: task_id:OTHERKEEP" >&2; return 1; fi
  # QA #1375 @cbe5240e: a named duplicate with no readable profile id keeps the ticket
  # open, both next to a merged one (no partial close) and alone (no fallback to the
  # customer_profile_id rule, which this ticket's survivor 1111 would satisfy).
  if echo "$output" | grep -q '"task_id":"HALFREAD"'; then echo "unexpected match: task_id:HALFREAD" >&2; return 1; fi
  if echo "$output" | grep -q '"task_id":"NONEREAD"'; then echo "unexpected match: task_id:NONEREAD" >&2; return 1; fi
  echo "$output" | grep -q "2 name a duplicate with no readable profile id (left open)"
  # Fable #1375 @c838cbbb: an explicit keep with no readable id, or explicit keeps naming
  # different profiles, holds the ticket open; never the customer_profile_id fallback
  # (both tickets' duplicate 2222 was verified into the customer profile 1111).
  if echo "$output" | grep -q '"task_id":"UNREADKEEP"'; then echo "unexpected match: task_id:UNREADKEEP" >&2; return 1; fi
  if echo "$output" | grep -q '"task_id":"CONFLICTKEEP"'; then echo "unexpected match: task_id:CONFLICTKEEP" >&2; return 1; fi
  echo "$output" | grep -q "2 name a keep profile that is unreadable or conflicting (left open)"
  rm -rf "$STUBDIR"
}

# Merge keep conflicts: while EITHER ticket of a pair (create_ticket tags both
# merge-keep-conflict + merge-keep-conflict-with:<other>) still carries
# merge-keep-conflict, neither ticket is matched or closed; once the tag is gone
# on both, they are worked again.
@test "a merge-keep-conflict pair is held until the tag is gone on both" {
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/muso" <<'MUSOEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"merge_into":"P-SURVIVOR","profiles_ids":"[\"P-LOSER\"]","at":"2026-06-01 00:00:00"}
JSON
MUSOEOF
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
if printf '%s' "$url" | grep -q 'page=0'; then
  jq -n --argjson a "$TAGS1" --argjson b "$TAGS2" '{tasks: [
    {id: "task1", url: "u1", status: {status: "to do"}, tags: ($a | map({name: .})),
     description: "---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P-LOSER\", \"customer_email\": \"x@example.com\"} ---END-ACTION-REQUEST---"},
    {id: "task2", url: "u2", status: {status: "to do"}, tags: ($b | map({name: .})),
     description: "---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P-SURVIVOR\", \"customer_email\": \"x@example.com\"} ---END-ACTION-REQUEST---"}]}' > "$out"
else
  printf '%s' '{"tasks":[]}' > "$out"
fi
printf '200'
CURLEOF
  chmod +x "$STUBDIR/muso" "$STUBDIR/curl"

  run env PATH="$STUBDIR:$PATH" CLICKUP_API_KEY=fake \
      TAGS1='["merge-keep-conflict-with:task2"]' TAGS2='["Merge-Keep-Conflict","merge-keep-conflict-with:task1"]' \
      bash "$SWEEP" --dry-run --skip-customer-reply-check --days 90
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2 held by a merge keep conflict"
  echo "$output" | grep -q "0 tickets match an executed merge"

  run env PATH="$STUBDIR:$PATH" CLICKUP_API_KEY=fake \
      TAGS1='["merge-keep-conflict-with:task2"]' TAGS2='["merge-keep-conflict-with:task1"]' \
      bash "$SWEEP" --dry-run --skip-customer-reply-check --days 90
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0 held by a merge keep conflict"
  echo "$output" | grep -q "2 tickets match an executed merge"

  rm -rf "$STUBDIR"
}

# A ticket tagged merge-intake-stale (create_ticket could not write a follow-up's
# merge targets into its description) is held on its own, like merge-keep-conflict.
@test "a merge-intake-stale ticket is held; its untagged neighbour is still worked" {
  STUBDIR="$(mktemp -d)"
  cat > "$STUBDIR/muso" <<'MUSOEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"merge_into":"P-SURVIVOR","profiles_ids":"[\"P-LOSER\"]","at":"2026-06-01 00:00:00"}
JSON
MUSOEOF
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
if printf '%s' "$url" | grep -q 'page=0'; then
  jq -n '{tasks: [
    {id: "task1", url: "u1", status: {status: "to do"}, tags: [{name: "merge-intake-stale"}],
     description: "---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P-LOSER\", \"customer_email\": \"x@example.com\"} ---END-ACTION-REQUEST---"},
    {id: "task2", url: "u2", status: {status: "to do"}, tags: [],
     description: "---ACTION-REQUEST--- {\"action_type\": \"profile-merge\", \"customer_profile_id\": \"P-SURVIVOR\", \"customer_email\": \"y@example.com\"} ---END-ACTION-REQUEST---"}]}' > "$out"
else
  printf '%s' '{"tasks":[]}' > "$out"
fi
printf '200'
CURLEOF
  chmod +x "$STUBDIR/muso" "$STUBDIR/curl"

  run env PATH="$STUBDIR:$PATH" CLICKUP_API_KEY=fake \
      bash "$SWEEP" --dry-run --skip-customer-reply-check --days 90
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 held by a merge keep conflict"
  echo "$output" | grep -q "1 tickets match an executed merge"

  rm -rf "$STUBDIR"
}
