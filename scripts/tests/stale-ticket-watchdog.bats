#!/usr/bin/env bats
# Tests for scripts/stale-ticket-watchdog.sh — the overdue
# hydra-action-request sweep added after the 2026-05 Sandy Vee incident
# (profile-claim tickets sat unworked for weeks while Caroline kept
# re-promising "2 business days").
#
# PATH-shadows curl + muso so no test ever hits ClickUp or Slack for real
# (see memory/feedback_bats_must_stub_openclaw.md). Behavioural assertions
# use --dry-run; the post-path test runs against a stubbed muso that
# captures argv + text.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/stale-ticket-watchdog.sh"

# Fixed "now": 2026-06-12T00:00:00Z
NOW=1781222400
DAY=86400

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  export STALE_TICKET_NOW="$NOW"
  export STALE_TICKET_SKIP_HOST_GUARD=1
  export STALE_TICKET_LOCKFILE="$TEST_TMPDIR/lock"
  export CLICKUP_API_KEY="pk_test_dummy"
  # Never fall back to the real gateway env on node-8.
  export CLICKUP_ENV_FILE="$TEST_TMPDIR/clickup.env"  # absent
  export CLICKUP_FIXTURE="$TEST_TMPDIR/tasks.json"

  # Refuse real Slack: no token unless a test opts in via the muso stub.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent by default
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"

  # curl stub: serves $CLICKUP_FIXTURE for page 0, empty page after — and
  # records the URL so we can assert the list/filters requested.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${@: -1}"
echo "$url" >> "$TEST_TMPDIR/curl-urls"
case "$url" in
  *page=0*) cat "$CLICKUP_FIXTURE" ;;
  *)        echo '{"tasks":[],"last_page":true}' ;;
esac
STUB
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  [ "$prev" = "--channel" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-channel"
  prev="$a"
done
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl" "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# task <id> <name> <due_epoch|null> <created_epoch> <tags-csv>
task_json() {
  local id="$1" name="$2" due="$3" created="$4" tags="$5"
  local due_ms="null"
  [ "$due" != "null" ] && due_ms="\"$((due * 1000))\""
  local tag_objs
  tag_objs=$(printf '%s' "$tags" | awk -F, '{for(i=1;i<=NF;i++){printf "%s{\"name\":\"%s\"}", (i>1?",":""), $i}}')
  printf '{"id":"%s","name":"%s","due_date":%s,"date_created":"%s","url":"https://app.clickup.com/t/%s","status":{"status":"open"},"tags":[%s]}' \
    "$id" "$name" "$due_ms" "$((created * 1000))" "$id" "$tag_objs"
}

fixture() {  # joins task JSONs into a list response
  local joined; joined=$(IFS=,; printf '%s' "$*")
  printf '{"tasks":[%s],"last_page":true}' "$joined" > "$CLICKUP_FIXTURE"
}

@test "fails loud when CLICKUP_API_KEY is missing" {
  unset CLICKUP_API_KEY
  run -2 "$WD" --dry-run
  [[ "$output" == *"CLICKUP_API_KEY"* ]]
}

@test "overdue action-request ticket is reported in dry-run" {
  fixture "$(task_json abc1 'Action Request: profile-claim' $((NOW - 5*DAY)) $((NOW - 20*DAY)) 'hydra-action-request,tier-1')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"abc1"* ]]
  [[ "$output" == *"profile-claim"* ]]
  [[ "$output" == *"1 overdue"* ]]
  # dry-run must not post
  [ ! -s "$STUB_CALLS" ]
}

@test "ticket due in the future is not reported" {
  fixture "$(task_json fut1 'Action Request: refund' $((NOW + 2*DAY)) $((NOW - DAY)) 'hydra-action-request,tier-2')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 overdue"* ]]
}

@test "ticket without the hydra-action-request tag is ignored" {
  fixture "$(task_json oth1 'Unrelated task' $((NOW - 5*DAY)) $((NOW - 20*DAY)) 'misc')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"0 overdue"* ]]
}

@test "no due date counts as overdue only after the grace window" {
  fixture \
    "$(task_json old1 'Action Request: profile-claim' null $((NOW - 10*DAY)) 'hydra-action-request,tier-1')" \
    "$(task_json new1 'Action Request: profile-claim' null $((NOW - 2*DAY)) 'hydra-action-request,tier-1')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"old1"* ]]
  [[ "$output" != *"new1"* ]]
  [[ "$output" == *"1 overdue"* ]]
}

@test "escalation-tagged tickets are listed first" {
  fixture \
    "$(task_json pla1 'Action Request: refund' $((NOW - 3*DAY)) $((NOW - 9*DAY)) 'hydra-action-request,tier-2')" \
    "$(task_json esc1 'Action Request: profile-claim' $((NOW - 2*DAY)) $((NOW - 8*DAY)) 'hydra-action-request,tier-1,escalation:sla-breach-customer-followup')"
  run -0 "$WD" --dry-run
  esc_line=$(printf '%s\n' "$output" | grep -n 'esc1' | cut -d: -f1)
  pla_line=$(printf '%s\n' "$output" | grep -n 'pla1' | cut -d: -f1)
  [ "$esc_line" -lt "$pla_line" ]
  [[ "$output" == *"customer follow-up past SLA"* ]]
}

@test "zero overdue means no Slack post even on the real path" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  fixture "$(task_json fut1 'Action Request: refund' $((NOW + 2*DAY)) $((NOW - DAY)) 'hydra-action-request,tier-2')"
  run -0 "$WD"
  [ ! -s "$STUB_CALLS" ]
}

@test "real path posts digest to #cs_chats via muso slack send" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  fixture "$(task_json abc1 'Action Request: profile-claim' $((NOW - 21*DAY)) $((NOW - 30*DAY)) 'hydra-action-request,tier-1')"
  run -0 "$WD"
  grep -q 'slack send' "$STUB_CALLS"
  [ "$(cat "$TEST_TMPDIR/last-channel")" = "C0ANM0PN9L5" ]
  text=$(cat "$TEST_TMPDIR/last-text")
  [[ "$text" == *"abc1"* ]]
  [[ "$text" == *"21d overdue"* ]]
  [[ "$text" == *"https://app.clickup.com/t/abc1"* ]]
}

@test "failed Slack post exits non-zero" {
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  fixture "$(task_json abc1 'Action Request: profile-claim' $((NOW - 5*DAY)) $((NOW - 9*DAY)) 'hydra-action-request,tier-1')"
  run -1 "$WD"
}

@test "escalated tickets trigger the Nick + Jan mention line" {
  fixture \
    "$(task_json esc1 'Action Request: profile-claim' $((NOW - 2*DAY)) $((NOW - 8*DAY)) 'hydra-action-request,tier-1,escalation:sla-breach-customer-followup')"
  run -0 "$WD" --dry-run
  [[ "$output" == *"<@U0AL36NADEY> <@U038BM16T7W>"* ]]
  [[ "$output" == *"1 ticket(s) have a customer follow-up past the promised SLA"* ]]
}

@test "no mention line when no overdue ticket is escalation-tagged" {
  fixture "$(task_json pla1 'Action Request: refund' $((NOW - 3*DAY)) $((NOW - 9*DAY)) 'hydra-action-request,tier-2')"
  run -0 "$WD" --dry-run
  [[ "$output" != *"<@U0AL36NADEY>"* ]]
}

@test "STALE_TICKET_MENTIONS= disables the ping" {
  export STALE_TICKET_MENTIONS=""
  fixture "$(task_json esc1 'Action Request: profile-claim' $((NOW - 2*DAY)) $((NOW - 8*DAY)) 'hydra-action-request,tier-1,escalation:sla-breach-customer-followup')"
  run -0 "$WD" --dry-run
  [[ "$output" != *"<@U0AL36NADEY>"* ]]
}

@test "a page far beyond ARG_MAX is handled (descriptions never ride argv)" {
  # One overdue task plus ~4MB of bulky tasks — regression for the
  # `jq: Argument list too long` hit on the real queue.
  {
    printf '{"tasks":[%s' "$(task_json abc1 'Action Request: profile-claim' $((NOW - 5*DAY)) $((NOW - 20*DAY)) 'hydra-action-request,tier-1')"
    blob=$(head -c 40000 /dev/zero | tr '\0' 'x')
    for i in $(seq 1 100); do
      printf ',{"id":"bulk%s","name":"bulk","description":"%s","due_date":null,"date_created":"%s","url":"u","status":{"status":"open"},"tags":[]}' "$i" "$blob" "$((NOW * 1000))"
    done
    printf '],"last_page":true}'
  } > "$CLICKUP_FIXTURE"
  run -0 "$WD" --dry-run
  [[ "$output" == *"abc1"* ]]
  [[ "$output" == *"1 overdue"* ]]
}

@test "ClickUp API error fails loud" {
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo '{"err":"Team not authorized","ECODE":"OAUTH_027"}'
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  run -1 "$WD" --dry-run
  [[ "$output" == *"ClickUp"* ]]
}

@test "Slack control chars in a ticket name are escaped in the digest" {
  # Ticket names are built from customer/request text (buildTicketTitle → gist),
  # so a crafted title must not broadcast-ping or inject links into #cs_chats
  # via the daily digest. Escape & < > at the Slack boundary; keep our own link.
  fixture "$(task_json inj1 'Action Request: <!channel> ping <@U0AL36NADEY> & <https://evil|x>' $((NOW - 5*DAY)) $((NOW - 20*DAY)) 'hydra-action-request,tier-1')"
  run -0 "$WD" --dry-run
  # raw control sequences must NOT survive
  [[ "$output" != *"<!channel>"* ]]
  [[ "$output" != *"<@U0AL36NADEY>"* ]]
  # escaped forms appear instead
  [[ "$output" == *"&lt;!channel&gt;"* ]]
  [[ "$output" == *"&lt;@U0AL36NADEY&gt;"* ]]
  [[ "$output" == *"&amp;"* ]]
  # the trusted ClickUp link is still intact (real mrkdwn)
  [[ "$output" == *"<https://app.clickup.com/t/inj1|inj1>"* ]]
}

@test "a task with null date_created is skipped, not crashed (fail-soft)" {
  # ClickUp always sets date_created, but a malformed/legacy record with a
  # null timestamp must not abort the whole digest: `null | tonumber` errors
  # and, under set -e, would lose the entire run. The anomalous task is
  # dropped; the rest of the queue still reports.
  {
    printf '{"tasks":['
    printf '%s,' "$(task_json ok1 'Action Request: profile-claim' $((NOW - 5*DAY)) $((NOW - 20*DAY)) 'hydra-action-request,tier-1')"
    printf '{"id":"bad1","name":"Action Request: broken","due_date":null,"date_created":null,"url":"https://app.clickup.com/t/bad1","status":{"status":"open"},"tags":[{"name":"hydra-action-request"}]}'
    printf '],"last_page":true}'
  } > "$CLICKUP_FIXTURE"
  run -0 "$WD" --dry-run
  [[ "$output" == *"ok1"* ]]
  [[ "$output" == *"1 overdue"* ]]
  [[ "$output" != *"bad1"* ]]
}
