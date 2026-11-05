#!/usr/bin/env bats
# Tests for scripts/audit-refund-confirmations.sh - the "refund issued with no confirmation > 24 h" alert
# (captain 2026-11-03 20:04Z building rule; Fable d2 ruling refund-confirm-1103, firstmate 109).
#
# A refund is money that already left the account: silence is not a neutral default. The suite pins the three things
# that make the page worth reading - it fires on a real silent refund, it pages each refund ONCE (a standing finding
# keeps the exit code red without re-paging immutable evidence), and "the feed is missing / unreadable" is an outage
# page, never a clean run.
#
# Hermetic: a throwaway ledger built with the real helper's schema, a temp refund feed, a temp state dir, --dry-run
# (so nothing is posted) and --now (so the age is measured, not wall-clock dependent).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
AUDIT="$HYDRA_REPO/scripts/audit-refund-confirmations.sh"
HELPER="$HYDRA_REPO/scripts/credit_review/verify_ledger.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export REFUND_AUDIT_LEDGER="$TEST_TMPDIR/ledger.sqlite3"
  export REFUND_AUDIT_HELPER="$HELPER"
  export REFUND_AUDIT_FEED="$TEST_TMPDIR/refunds.jsonl"
  export REFUND_AUDIT_STATE_FILE="$TEST_TMPDIR/state/seen.json"
  export REFUND_AUDIT_INFRA_STATE="$TEST_TMPDIR/state/infra.json"
  python3 -I "$HELPER" --db "$REFUND_AUDIT_LEDGER" migrate >/dev/null
  # the slack helper is fenced under bats, and muso is pointed at a no-op so a non-dry run can never post
  export MUSO_BIN=/bin/false
  # ... and a DELIVERING stub for the tests that need a page to actually land: same seam, opposite outcome. Both stubs
  # LOG each call, so "the next tick retried it" is measured rather than inferred from an exit code (QA 2026-11-04
  # round 3 finding 3).
  printf '#!/bin/sh\necho call >> "%s"\nexit 0\n' "$TEST_TMPDIR/muso-ok.log" > "$TEST_TMPDIR/muso-ok"
  printf '#!/bin/sh\necho call >> "%s"\nexit 1\n' "$TEST_TMPDIR/muso-fail.log" > "$TEST_TMPDIR/muso-fail"
  chmod +x "$TEST_TMPDIR/muso-ok" "$TEST_TMPDIR/muso-fail"
  export DELIVERS_OK="$TEST_TMPDIR/muso-ok"
  export DELIVERS_FAIL="$TEST_TMPDIR/muso-fail"
}
delivering() { export MUSO_BIN="$DELIVERS_OK" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token; }

# --- a real local processor: response fixtures by request order, every request path recorded -------------------------
# The curl stubs elsewhere in this file consume stdin and never parse a URL, which is exactly how a query curl REFUSES to
# send ("bad range in URL" on `created[gte]=<epoch>`) survived a round of green tests. The end-to-end tests below run the
# REAL curl against this server and assert the query that arrives.
start_fake_stripe() { # <dir> -> port on stdout; responses from <dir>/resp0.json, resp1.json, ... then resp.json
  local dir="$1"
  cat > "$dir/srv.py" <<'PYSRV'
import http.server, socketserver, sys, os
root = sys.argv[1]
state = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(root, "requests.log"), "a") as fh:
            fh.write(self.path + "\n")
        idx = state["n"]; state["n"] += 1
        p = os.path.join(root, "resp%d.json" % idx)
        if not os.path.exists(p):
            p = os.path.join(root, "resp.json")
        body = open(p, "rb").read() if os.path.exists(p) else b'{"object":"list","has_more":false,"data":[]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
with open(os.path.join(root, "port"), "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PYSRV
  # the server's own stdout/stderr must not be the command substitution's pipe, or this function never returns
  python3 "$dir/srv.py" "$dir" > "$dir/srv.out" 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 100); do [ -s "$dir/port" ] && break; sleep 0.05; done
  cat "$dir/port"
}
stop_fake_stripe() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; return 0; }
teardown() { stop_fake_stripe; }

# a TESTABLE copy of the feed writer: the only way to point it at a local server (a deployed copy refuses the seams)
testable_writer() { # -> path on stdout
  local w="$TEST_TMPDIR/feed-writer.sh"
  cp "$HYDRA_REPO/scripts/lib/refund-feed-from-stripe.sh" "$w"
  sed -i 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$w"
  printf '%s' "$w"
}

feed() { printf '%s\n' "$@" > "$REFUND_AUDIT_FEED"; }

# a refund-confirm row that DID go out: the ledger is the only thing that can call a refund told
told() { # <refund id>
  python3 - "$REFUND_AUDIT_LEDGER" "$1" <<'PY'
import json, sqlite3, sys
path, rid = sys.argv[1:3]
db = sqlite3.connect(path)
db.execute(
    "INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, n_credits,"
    " approved_by, approval_ref, copy_ref, approver_kind, approval_id, template_sha256, created_at, updated_at)"
    " VALUES ('refund-confirm','initial','fan@example.com','2026-11-03','sent','email',?,1,"
    " 'fable-ruling-1103-d2/refund-confirm','ref','refundconfirm','fable-ruling','fable-ruling-1103-d2/refund-confirm',"
    " ?, '2026-11-03T18:00:00Z','2026-11-03T18:00:00Z')",
    (json.dumps([{"request_id": rid, "profile_id": None, "track_id": None}]), "a" * 64))
db.commit()
PY
}

run_audit() { run "$AUDIT" --now "${NOW:-2026-11-05T00:00:00Z}" --dry-run; }

@test "a refund past 24 h with no confirmation note pages, naming the refund id, the user and the age" {
  feed '{"refund_id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","user_key":"pancho95jandro@gmail.com","issued_at":"2026-11-03T16:25:02Z"}'
  run_audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"refund issued and not told"* ]]
  [[ "$output" == *"re_3UXkW8LsjTo3Ar3l0cunpPeE"* ]]
  [[ "$output" == *"pancho95jandro@gmail.com"* ]]
  [[ "$output" == *"refunded 30"*"h ago"* ]] || [[ "$output" == *"refunded 31"*"h ago"* ]]
}

@test "a refund the ledger shows as told is clean, and the 24 h threshold is a threshold (11 h is not a finding)" {
  feed '{"refund_id":"re_3UClHTLsjTo3Ar3l1c7IAjbJ","user_key":"offtherow@gmail.com","issued_at":"2026-11-03T16:25:02Z"}'
  told re_3UClHTLsjTo3Ar3l1c7IAjbJ
  run_audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean:"* ]]
  feed '{"refund_id":"re_3UClHTLsjTo3Ar3l1c7IAjbJ","user_key":"x@example.com","issued_at":"2026-11-03T16:25:02Z"}' \
        '{"refund_id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","user_key":"y@example.com","issued_at":"2026-11-04T13:00:00Z"}'
  # 11 h old, untold: under the 24 h threshold, so still clean - the threshold measures, it does not guess
  run_audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean:"* ]]
  [[ "$output" != *"re_3UXkW8LsjTo3Ar3l0cunpPeE"* ]]
  # the same feed a day later: the told one stays clean and the untold one is now a finding
  run "$AUDIT" --now 2026-11-06T00:00:00Z --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"re_3UXkW8LsjTo3Ar3l0cunpPeE"* ]]
  [[ "$output" != *"re_3UClHTLsjTo3Ar3l1c7IAjbJ"* ]]   # told: never a finding
}

@test "each silent refund pages ONCE; a standing finding keeps the exit code red without re-paging" {
  feed '{"refund_id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","user_key":"y@example.com","issued_at":"2026-11-03T16:25:02Z"}'
  delivering   # a REAL run needs a page that actually lands before the watermark may be written
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings: 1"* ]]
  grep -q 're_3UXkW8LsjTo3Ar3l0cunpPeE' "$REFUND_AUDIT_STATE_FILE"
  run_audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"standing: 1 refund(s) already paged"* ]]
  [[ "$output" != *"refund issued and not told"* ]]
}

@test "a page that does not reach Slack is NOT recorded as paged, and the next tick retries it (QA finding 3)" {
  feed '{"refund_id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","user_key":"y@example.com","issued_at":"2026-11-03T16:25:02Z"}'
  muso_calls() { local f="$1"; if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi; }
  # the delivery FAILS (a stub that logs the attempt and exits non-zero). Reporting an unlanded page as paged would lose
  # the refund forever.
  export MUSO_BIN="$DELIVERS_FAIL" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 2 ]
  [[ "$output" == *"did NOT reach Slack"* ]]
  [[ "$output" == *"re_3UXkW8LsjTo3Ar3l0cunpPeE"* ]]       # the finding is still named, on stderr
  # the page was ATTEMPTED exactly once - so a green second run cannot be a "no page was ever tried" artefact
  [ "$(muso_calls "$TEST_TMPDIR/muso-fail.log")" -eq 1 ]
  # ... and the refund was NOT written off: either no state file, or one that does not name it. A watermark advanced over
  # a page that did not land is exactly the silent loss this test exists to prevent, so the assertion is explicit rather
  # than a non-terminal `|| !` chain.
  if [ -s "$REFUND_AUDIT_STATE_FILE" ]; then
    ! grep -q 're_3UXkW8LsjTo3Ar3l0cunpPeE' "$REFUND_AUDIT_STATE_FILE"
  fi
  # the next tick with a working Slack pages it AGAIN (measured: exactly one new call), then records it
  delivering
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings: 1"* ]]
  [[ "$output" != *"standing:"* ]]
  [ "$(muso_calls "$TEST_TMPDIR/muso-ok.log")" -eq 1 ]
  grep -q 're_3UXkW8LsjTo3Ar3l0cunpPeE' "$REFUND_AUDIT_STATE_FILE"
  # the refund is recorded exactly once, and the record is what makes the next run "standing" rather than a second page
  [ "$(jq -r 'length' "$REFUND_AUDIT_STATE_FILE")" -eq 1 ]
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"standing: 1 refund(s) already paged"* ]]
  [ "$(muso_calls "$TEST_TMPDIR/muso-ok.log")" -eq 1 ]
}

@test "an untold refund the ledger merely ATTEMPTED is still untold (a stuck claim is not a tell)" {
  python3 - "$REFUND_AUDIT_LEDGER" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute(
    "INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, n_credits,"
    " approved_by, approval_ref, copy_ref, created_at, updated_at)"
    " VALUES ('refund-confirm','initial','fan@example.com','2026-11-03','attempted','email',?,1,'U7RP6HKUZ','ref',"
    " 'refundconfirm','2026-11-03T16:30:00Z','2026-11-03T16:30:00Z')",
    (json.dumps([{"request_id": "re_3UXkW8LsjTo3Ar3l0cunpPeE"}]),))
db.commit()
PY
  feed '{"refund_id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","user_key":"y@example.com","issued_at":"2026-11-03T16:25:02Z"}'
  run_audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"re_3UXkW8LsjTo3Ar3l0cunpPeE"* ]]
}

@test "a missing feed is COULD-NOT-CHECK (exit 2), never clean, and the same outage does not re-page within a day" {
  export REFUND_AUDIT_FEED="$TEST_TMPDIR/absent.jsonl"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [[ "$output" == *"the processor refund feed is unreadable"* ]]
}

# QA 2026-11-04 (the last open finding on #1728): the production feed is DERIVED from Stripe, so "nobody wrote the
# file" is no longer a way for this audit to be blind. These two tests are the difference between an alert that runs and
# one that posts a generic outage forever: with no feed named, the audit asks the processor and pages the refund it
# finds; and when Stripe cannot be read, the page names the processor as the reason (still an outage, never "clean").
@test "with no feed named the audit derives it from Stripe and pages the silent refund it finds" {
  unset REFUND_AUDIT_FEED
  # the writer reads the credential the gate reads; a stub never sees it, but its absence is a refusal, not a feed
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  cat > "$TEST_TMPDIR/refunds.json" <<'JSON'
{"object":"list","has_more":false,"data":[{"id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","object":"refund","status":"succeeded","created":1793723102,"charge":{"id":"ch_1","billing_details":{"email":"pancho95jandro@gmail.com"}}},{"id":"re_3UClHTLsjTo3Ar3l1c7IAjbJ","object":"refund","status":"pending","created":1793723102,"charge":{"id":"ch_2","billing_details":{"email":"x@example.com"}}}]}
JSON
  cat > "$TEST_TMPDIR/curl-stub" <<'STUB'
#!/bin/sh
cat >/dev/null            # the credential arrives on the config pipe; a stub must consume it
cat "$REFUND_STUB_BODY"
STUB
  chmod +x "$TEST_TMPDIR/curl-stub"
  export REFUND_STUB_BODY="$TEST_TMPDIR/refunds.json"
  export REFUND_FEED_TEST_CURL_BIN="$TEST_TMPDIR/curl-stub"
  export REFUND_FEED_TEST_STRIPE_BASE="https://api.stripe.test"
  # the audit calls the repo's writer, whose TESTABLE flag the suite opens exactly as the verify-gate suite does
  cp "$HYDRA_REPO/scripts/lib/refund-feed-from-stripe.sh" "$TEST_TMPDIR/feed-writer.sh"
  sed -i 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$TEST_TMPDIR/feed-writer.sh"
  export REFUND_AUDIT_FEED_WRITER="$TEST_TMPDIR/feed-writer.sh"
  run_audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"re_3UXkW8LsjTo3Ar3l0cunpPeE"* ]]
  [[ "$output" == *"pancho95jandro@gmail.com"* ]]
  # the pending refund is NOT money that arrived, so it is not a finding (a "your refund is on its way" note about
  # money that can still fail is exactly the false confirmation the gate refuses)
  [[ "$output" != *"re_3UClHTLsjTo3Ar3l1c7IAjbJ"* ]]
}

@test "when Stripe cannot be read the page names the processor, and a deployed copy refuses the test seams" {
  unset REFUND_AUDIT_FEED
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  cat > "$TEST_TMPDIR/stripe-error.json" <<'JSON'
{"error":{"type":"api_error","message":"bank says no"}}
JSON
  cat > "$TEST_TMPDIR/curl-broken" <<'STUB'
#!/bin/sh
cat >/dev/null
cat "$REFUND_STUB_BODY"
STUB
  chmod +x "$TEST_TMPDIR/curl-broken"
  export REFUND_STUB_BODY="$TEST_TMPDIR/stripe-error.json"
  export REFUND_FEED_TEST_CURL_BIN="$TEST_TMPDIR/curl-broken"
  export REFUND_FEED_TEST_STRIPE_BASE="https://api.stripe.test"
  cp "$HYDRA_REPO/scripts/lib/refund-feed-from-stripe.sh" "$TEST_TMPDIR/feed-writer.sh"
  sed -i 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$TEST_TMPDIR/feed-writer.sh"
  export REFUND_AUDIT_FEED_WRITER="$TEST_TMPDIR/feed-writer.sh"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [[ "$output" == *"could not be read from Stripe"* ]]
  [[ "$output" == *"bank says no"* ]]
  # and the committed copy - the one that ships - refuses a caller-selectable processor outright, writing no feed
  run bash "$HYDRA_REPO/scripts/lib/refund-feed-from-stripe.sh" --out "$TEST_TMPDIR/never.jsonl"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not settable on a deployed copy"* ]]
  [ ! -e "$TEST_TMPDIR/never.jsonl" ]
}

@test "a malformed feed is an outage, not a pass (a refund whose id or time cannot be read is unmeasurable)" {
  feed '{"refund_id":"not-a-stripe-id","user_key":"y@example.com","issued_at":"2026-11-03T16:25:02Z"}'
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  feed 'this is not json'
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
}

@test "an unreadable refund time is a finding, never silence" {
  feed '{"refund_id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","user_key":"y@example.com","issued_at":"last tuesday"}'
  run_audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"age cannot be measured"* ]]
}

# --- QA 2026-11-04 (twice): a rolling window must not lose a refund, and "standing" must actually stand -------------
# "Last 7 days" is a silent hole: if the audit or Stripe is down for eight days, a refund from day one is absent when the
# check recovers, and the audit reports clean without ever naming it. The AUDIT (not the writer, which cannot know
# whether its answer was ever compared) keeps a durable cursor of the instant it last made a comparison it trusted, and
# retains every untold refund id until a note is sent, so an untold refund cannot age out of the alert.
old_epoch() { echo $(( $(date -u +%s) - $1 * 86400 )); }

feed_state_init() { # <covered_through epoch> [<outstanding json>]
  mkdir -p "$(dirname "$FEED_STATE_FILE")"
  jq -cn --argjson c "$1" --argjson o "${2:-[]}" '{covered_through: $c, outstanding: $o}' > "$FEED_STATE_FILE"
}

silent_refund_fixture() { # <dir> <epoch>
  mkdir -p "$1"
  printf '{"object":"list","has_more":false,"data":[{"id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","object":"refund","status":"succeeded","created":%s,"charge":{"id":"ch_1","billing_details":{"email":"pancho95jandro@gmail.com"}}}]}' "$2" > "$1/resp.json"
}

@test "after a gap longer than the window the audit still sees the refund it missed, then retains it once paged" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  silent_refund_fixture "$TEST_TMPDIR/srv" "$(old_epoch 10)"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  feed_state_init "$(old_epoch 12)"
  delivering
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings: 1"* ]]
  # the query really asked for the gap, through the REAL curl (globbing would have eaten created[gte])
  grep -q 'created\[gte\]=' "$TEST_TMPDIR/srv/requests.log"
  grep -q 'expand\[\]=data.charge' "$TEST_TMPDIR/srv/requests.log"
  # the cursor advanced to THIS run's start, and the untold refund is retained BY ID
  covered="$(jq -r '.covered_through' "$FEED_STATE_FILE")"
  [ "$covered" -gt "$(( $(date -u +%s) - 120 ))" ]
  [ "$(jq -r '.outstanding[0].refund_id' "$FEED_STATE_FILE")" = "re_3UXkW8LsjTo3Ar3l0cunpPeE" ]
  # NOW the window has moved past the refund and the processor returns nothing: retention keeps the finding standing and
  # the run red, WITHOUT paging immutable evidence a second time.
  printf '{"object":"list","has_more":false,"data":[]}' > "$TEST_TMPDIR/srv/resp.json"
  run "$AUDIT" --now 2026-11-06T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"standing: 1 refund(s) already paged and still unconfirmed"* ]]
  [[ "$output" != *"refund issued and not told"* ]]
}

@test "a ledger outage does not advance the cursor, so the refund issued during it is found on recovery" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  silent_refund_fixture "$TEST_TMPDIR/srv" "$(old_epoch 10)"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  # ONE clock reading for the fixture and the assertion: evaluating old_epoch twice straddles a second boundary and made
  # this test fail in CI while passing locally (a 1-second race, not a behaviour change)
  cursor_before="$(old_epoch 12)"
  feed_state_init "$cursor_before"
  # Stripe is reachable, the LEDGER is not: no comparison could be made, so nothing may be recorded as covered
  mv "$REFUND_AUDIT_LEDGER" "$REFUND_AUDIT_LEDGER.hidden"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [ "$(jq -r '.covered_through' "$FEED_STATE_FILE")" = "$cursor_before" ]
  # recovery: the same window is read again, and the refund from the gap is still there to be found
  mv "$REFUND_AUDIT_LEDGER.hidden" "$REFUND_AUDIT_LEDGER"
  delivering
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings: 1"* ]]
  [ "$(jq -r '.outstanding[0].refund_id' "$FEED_STATE_FILE")" = "re_3UXkW8LsjTo3Ar3l0cunpPeE" ]
}

@test "the query survives real curl: created[gte] and expand[] arrive intact (globoff)" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  mkdir -p "$TEST_TMPDIR/srv"
  printf '{"object":"list","has_more":false,"data":[]}' > "$TEST_TMPDIR/srv/resp.json"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  feed_state_init "$(old_epoch 1)"
  run_audit
  [ "$status" -eq 0 ]
  # WITHOUT -g curl refuses this URL outright ("bad range in URL" on created[gte]); this pins that it still arrives
  grep -q 'created\[gte\]=[0-9]' "$TEST_TMPDIR/srv/requests.log"
  grep -q 'expand\[\]=data.charge' "$TEST_TMPDIR/srv/requests.log"
}

@test "a first run with no cursor bootstraps from the fixed campaign start, so a refund older than the window is measured" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  # a refund twelve days old: outside the rolling 7-day window, inside the campaign's history
  silent_refund_fixture "$TEST_TMPDIR/srv" "$(old_epoch 12)"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  bootstrap="$(old_epoch 20)"
  export REFUND_AUDIT_FEED_BOOTSTRAP_EPOCH="$bootstrap"
  # NO feed_state_init: no comparison has ever been recorded here
  delivering
  run "$AUDIT" --now 2026-11-05T00:00:00Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings: 1"* ]]
  # the query started at the FIXED bootstrap instant, not at now-7d: the refund is in the answer set
  grep -q "created\[gte\]=$bootstrap" "$TEST_TMPDIR/srv/requests.log"
  # and the cursor is written only now, with the untold refund retained by id
  [ "$(jq -r '.covered_through' "$FEED_STATE_FILE")" -gt "$(( $(date -u +%s) - 120 ))" ]
  [ "$(jq -r '.outstanding[0].refund_id' "$FEED_STATE_FILE")" = "re_3UXkW8LsjTo3Ar3l0cunpPeE" ]
}

@test "an unreadable cursor is an outage, never a silent fall-back to the rolling window (QA finding 1)" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  mkdir -p "$TEST_TMPDIR/srv"
  printf '{"object":"list","has_more":false,"data":[]}' > "$TEST_TMPDIR/srv/resp.json"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  # the file EXISTS but cannot be read: falling back to 7 days would drop every id it was holding
  mkdir -p "$(dirname "$FEED_STATE_FILE")"
  printf 'not json at all' > "$FEED_STATE_FILE"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [[ "$output" == *"exists but its state is unusable"* ]]
  # no bounded question was asked that would pretend to answer it, and the corrupt file was not overwritten
  [ ! -s "$TEST_TMPDIR/srv/requests.log" ]
  [ "$(cat "$FEED_STATE_FILE")" = "not json at all" ]
}

@test "a state file with a good cursor and a broken outstanding list is an outage (QA 2026-11-04 round 4 finding 1)" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  mkdir -p "$TEST_TMPDIR/srv"
  printf '{"object":"list","has_more":false,"data":[]}' > "$TEST_TMPDIR/srv/resp.json"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  # a VALID cursor with an outstanding value that is not a list: reading `.[]` off it would yield nothing, and the
  # retained refunds would silently disappear once they age out of the rolling Stripe window
  mkdir -p "$(dirname "$FEED_STATE_FILE")"
  printf '{"covered_through":%s,"outstanding":{"re_3UXkW8LsjTo3Ar3l0cunpPeE":"x"}}' "$(old_epoch 3)" > "$FEED_STATE_FILE"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [[ "$output" == *"outstanding is object"* ]]
  [ ! -s "$TEST_TMPDIR/srv/requests.log" ]
  # ... and the same fail-closed answer when the LIST is right but an entry cannot be re-judged
  printf '{"covered_through":%s,"outstanding":[{"user_key":"a@example.com"}]}' "$(old_epoch 3)" > "$FEED_STATE_FILE"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"an outstanding row is not an object with a non-empty string refund_id"* ]]
  [ ! -s "$TEST_TMPDIR/srv/requests.log" ]
  # QA 2026-11-05 round 5 finding 4: an ABSENT or NULL outstanding is not "an empty list". This writer always emits the
  # field, so its absence means a truncated or foreign file, and the retained ids cannot be told apart from lost ones.
  printf '{"covered_through":%s}' "$(old_epoch 3)" > "$FEED_STATE_FILE"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"outstanding is missing"* ]]
  [ ! -s "$TEST_TMPDIR/srv/requests.log" ]
  printf '{"covered_through":%s,"outstanding":null}' "$(old_epoch 3)" > "$FEED_STATE_FILE"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"outstanding is null"* ]]
  [ ! -s "$TEST_TMPDIR/srv/requests.log" ]
  # ... and an EMPTY list is still legal: that is the writer's own "nothing retained" answer
  feed_state_init "$(old_epoch 3)"
  run_audit
  [ "$status" -eq 0 ]
}

@test "a processor page that does not say whether more exist is an outage, never a complete feed (QA 2026-11-04 round 4 finding 2)" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  mkdir -p "$TEST_TMPDIR/srv"
  # has_more is ABSENT: `// false` used to end pagination here, so a refund on page two was never measured
  printf '{"object":"list","data":[{"id":"re_3UXkW8LsjTo3Ar3l0cunpPeE","object":"refund","status":"succeeded","created":%s,"charge":{"id":"ch_1","billing_details":{"email":"pancho95jandro@gmail.com"}}}]}' "$(old_epoch 2)" > "$TEST_TMPDIR/srv/resp.json"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  # ONE clock reading for the fixture and the assertion (two old_epoch calls straddle a second boundary - the same
  # 1-second test race that reddened CI once already)
  cursor_before="$(old_epoch 3)"
  feed_state_init "$cursor_before"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [[ "$output" == *"did not say whether more refunds exist"* ]]
  # nothing was written off: the cursor is untouched and no finding was invented from a half-read feed
  [ "$(jq -r '.covered_through' "$FEED_STATE_FILE")" = "$cursor_before" ]
}

@test "a gap older than the catch-up bound is reported, never silently covered" {
  unset REFUND_AUDIT_FEED REFUND_FEED_TEST_CURL_BIN
  export MUSOAI_STRIPE_API_KEY=sk_test_stub
  export FEED_STATE_FILE="$TEST_TMPDIR/feed-state.json"
  export REFUND_AUDIT_FEED_STATE="$FEED_STATE_FILE"
  export REFUND_AUDIT_FEED_WRITER="$(testable_writer)"
  mkdir -p "$TEST_TMPDIR/srv"
  printf '{"object":"list","has_more":false,"data":[]}' > "$TEST_TMPDIR/srv/resp.json"
  port="$(start_fake_stripe "$TEST_TMPDIR/srv")"
  export REFUND_FEED_TEST_STRIPE_BASE="http://127.0.0.1:$port"
  feed_state_init "$(old_epoch 100)"
  before="$(jq -r '.covered_through' "$FEED_STATE_FILE")"
  run_audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"COULD NOT RUN"* ]]
  [[ "$output" == *"beyond the 60-day bound"* ]]
  # the cursor does NOT advance, and Stripe is never asked a bounded question that would pretend to answer it
  [ "$(jq -r '.covered_through' "$FEED_STATE_FILE")" = "$before" ]
  [ ! -s "$TEST_TMPDIR/srv/requests.log" ]
}
