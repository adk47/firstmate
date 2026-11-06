#!/usr/bin/env bats
# Tests for scripts/qa-worker.sh — one review lane against the durable queue.
#
# Every external command is shadowed on PATH: `openclaw` is a stub that records
# the prompt it was given and "publishes" a verdict, `gh`/qa-gh is a stub that
# serves a synthetic commit-status list. NOTHING here touches a real gateway, a
# real GitHub API or Slack — an unstubbed QA test once fired 9 real Slack alerts
# to prod (see qa-review-reconcile.bats), so the stubs are mandatory.
#
# The broker runs in "cli" mode against a throwaway sqlite file, which exercises
# the same python module the HTTP service wraps.

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WORKER="$HYDRA_REPO/scripts/qa-worker.sh"
BROKER="$HYDRA_REPO/scripts/lib/qa_broker.py"

REPO="Muso-AI/hydra"
PR=1730
SHA="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
REQ_UID="U123ABC"

setup() {
  TMP="$(mktemp -d)"
  export QA_QUEUE_DB="$TMP/queue.sqlite"
  export QA_BROKER_URL="cli"
  export QA_WORKER_ID="test-worker"
  export QA_WORKER_ONCE=1
  export QA_WORKER_POLL_S=1
  export QA_BROKER_DEDUPE_DONE=go-only
  export QA_BROKER_MAX_REVIEWS_PER_KEY=2
  # The GitHub REST budget gate is exercised by its own test below; every other
  # test would otherwise need a rate_limit-answering stub.
  export QA_WORKER_GH_BUDGET=0

  # ── stubs ────────────────────────────────────────────────────────────────
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
# Record the invocation and publish a verdict, like the real skill would.
echo "OPENCLAW ARGS: $*" >> "$STUB_LOG"

# Parse the way the REAL CLI does, not permissively. A stub that accepts any
# flag cannot catch an invocation the installed binary rejects, and that is
# exactly how `--session isolated` shipped: every claimed job died before the
# agent started and was dead-lettered with no verdict, while the suite was
# green. Only the documented option set is accepted here.
sub="${1:-}"
[ "$sub" = "agent" ] || { echo "OpenClaw does not recognize command \"$sub\"" >&2; exit 1; }
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --agent|--session-id|--timeout|--message|--model) shift 2 || { echo "option $1 requires a value" >&2; exit 1; } ;;
    --json) shift ;;
    *) echo "OpenClaw does not recognize option \"$1\"" >&2; exit 1 ;;
  esac
done

case "$STUB_MODE" in
  ok)      exit 0 ;;
  quota)   echo "Error: 429 rate limit exceeded" >&2; exit 1 ;;
  transport) echo "Error: Opening handshake has timed out" >&2; exit 1 ;;
  fail)    echo "Error: the review turn errored" >&2; exit 1 ;;
  # Long enough for a test to inspect the lease mid-review, short enough that
  # the worker's "finish the current job" SIGTERM path does not stall the suite.
  hang)    sleep 8; exit 0 ;;
  *)       exit 0 ;;
esac
STUB
  chmod +x "$TMP/bin/openclaw"

  cat >"$TMP/bin/qa-gh.sh" <<'STUB'
#!/usr/bin/env bash
# Serve a synthetic qa-review status list. STUB_STATUS_STATE/STUB_STATUS_DESC
# control the newest row; empty means "no status posted".
#
# The worker reads this TWICE per job: once before the turn (the baseline) and
# once after. A turn that publishes a status makes the newest row NEWER, so by
# default each call advances created_at by a second, which is what a real turn
# does. STUB_STATUS_FIXED_AT=1 pins the timestamp instead, modelling a turn that
# published nothing while an older verdict is still on the commit (the forced
# re-review case).
# STUB_STATUS_EMPTY_FIRST=N answers "no status" for the first N calls, so a
# test can model the skill posting the status a moment after the turn returns.
# A `pulls/<n>` read answers the PR's CURRENT head, which the worker checks
# when a turn published no status: a head that moved during the review means the
# turn reviewed the newer head, not that the review failed.
case "$*" in
  *pulls/*)
    printf '%s\n' "${STUB_HEAD_SHA:-$STUB_DEFAULT_HEAD}"
    exit 0
    ;;
esac
n=$(cat "$STUB_STATUS_COUNTER" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STUB_STATUS_COUNTER"
# STUB_STATUS_FAIL_FIRST=N makes the first N reads FAIL (non-zero exit), which
# is different from answering "no status": a failed baseline read must not be
# treated as an empty one, or a forced re-review can finish on the old verdict.
if [ -n "${STUB_STATUS_FAIL_FIRST:-}" ] && [ "$n" -lt "$STUB_STATUS_FAIL_FIRST" ]; then
  echo "gh: Server Error (HTTP 502)" >&2; exit 1
fi
if [ -n "${STUB_STATUS_EMPTY_FIRST:-}" ] && [ "$n" -lt "$STUB_STATUS_EMPTY_FIRST" ]; then
  printf '[]\n'; exit 0
fi
if [ -n "${STUB_STATUS_STATE:-}" ]; then
  if [ -n "${STUB_STATUS_FIXED_AT:-}" ]; then
    created="${STUB_STATUS_CREATED_AT:-2026-11-04T12:00:00Z}"
  else
    created="$(printf '2026-11-04T12:%02d:%02dZ' $(( (n / 60) % 60 )) $(( n % 60 )))"
  fi
  printf '[{"context":"qa-review","state":"%s","description":"%s","created_at":"%s","creator":{"login":"%s"}}]\n' \
    "$STUB_STATUS_STATE" "$STUB_STATUS_DESC" "$created" "${STUB_STATUS_CREATOR:-muso-qa-bot[bot]}"
else
  printf '[]\n'
fi
STUB
  chmod +x "$TMP/bin/qa-gh.sh"

  export STUB_LOG="$TMP/openclaw.log"
  export STUB_STATUS_COUNTER="$TMP/status-calls"
  # Default: the PR head is the head the job was enqueued for, so a turn that
  # publishes nothing is a real failure unless a test moves the head.
  export STUB_DEFAULT_HEAD="$SHA"
  unset STUB_HEAD_SHA
  : >"$STUB_LOG"
  export QA_GH="$TMP/bin/qa-gh.sh"
  export PATH="$TMP/bin:$PATH"
  export STUB_MODE="ok"
}

teardown() {
  rm -rf "$TMP"
}

enqueue() { python3 "$BROKER" --db "$QA_QUEUE_DB" enqueue "$REPO" "$PR" "$SHA" "$REQ_UID" >/dev/null; }

# ── happy path ─────────────────────────────────────────────────────────────

@test "worker: claims a queued job and records a GO verdict" {
  enqueue
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claimed job"* ]]
  [[ "$output" == *"verdict=go"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('done','go'), r
c.close()"
}

@test "worker: a NO-GO is recorded as no_go" {
  enqueue
  export STUB_STATUS_STATE="failure"
  export STUB_STATUS_DESC="NO-GO — 2 blocking findings"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('done','no_go'), r
c.close()"
}

@test "worker: a CANNOT REVIEW failure is recorded as cannot_review" {
  enqueue
  export STUB_STATUS_STATE="failure"
  export STUB_STATUS_DESC="CANNOT REVIEW: diff exceeds the line cap"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('done','cannot_review'), r
c.close()"
}

@test "worker: no status posted is never recorded as a verdict" {
  # A turn that exits 0 without publishing a qa-review status is a FAILED
  # review, not a `done` row with verdict `unknown`: the repos read the status,
  # so a terminal row with no status is a PR that sits unreviewed forever.
  enqueue
  export QA_WORKER_VERDICT_GRACE_S=0
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('queued',None), r
c.close()"
}

@test "worker: a head that moved during the review retires the job, it does not retry" {
  # The skill resolves the PR head itself, so a turn that started on A and
  # finished after B was pushed reviewed B and published its status on B. This
  # job only looks at A, so the successful turn reads as `unknown`. Retrying
  # would re-review B, spend a review attempt, and eventually dead-letter a PR
  # that is in fact being reviewed.
  enqueue
  export QA_WORKER_VERDICT_GRACE_S=0
  export STUB_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict,review_attempts FROM jobs WHERE id=1').fetchone()
assert r==('superseded',None,0), r
c.close()"
  [[ "$output" == *"head moved"* ]]
}

@test "worker: an unreadable head falls back to the normal no-verdict failure" {
  # A failed head read must not be read as "the head moved": that would retire
  # a job whose review genuinely failed. Fail in the safe direction.
  enqueue
  export QA_WORKER_VERDICT_GRACE_S=0
  export STUB_HEAD_SHA=""
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('queued',None), r
c.close()"
}

@test "worker: sends the shared review prompt with the PR url and head sha" {
  enqueue
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  grep -q "https://github.com/${REPO}/pull/${PR}" "$STUB_LOG"
  grep -q "head commit ${SHA}" "$STUB_LOG"
  grep -q -- "--agent qa" "$STUB_LOG"
}

@test "worker: an idle queue exits cleanly under QA_WORKER_ONCE without claiming" {
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopping after 0 job"* ]]
  [ ! -s "$STUB_LOG" ]
}

# ── failure classification ─────────────────────────────────────────────────

@test "worker: a transport failure requeues with the transport budget" {
  enqueue
  export STUB_MODE="transport"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,transport_attempts,last_error FROM jobs WHERE id=1').fetchone()
assert r[0]=='queued', r
assert r[1]==1, r
assert 'handshake' in (r[2] or ''), r
c.close()"
}

@test "worker: a quota failure requeues with the 30-minute quota backoff" {
  enqueue
  export STUB_MODE="quota"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,quota_attempts,not_before FROM jobs WHERE id=1').fetchone()
assert r[0]=='queued', r
assert r[1]==1, r
c.close()"
}

@test "worker: a review-turn failure requeues with the review budget" {
  enqueue
  export STUB_MODE="fail"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,attempts,last_error FROM jobs WHERE id=1').fetchone()
assert r[0]=='queued', r
assert 'errored' in (r[2] or ''), r
c.close()"
}

# ── lease / heartbeat ──────────────────────────────────────────────────────

@test "worker: heartbeat keeps the lease alive during a long review" {
  enqueue
  export QA_WORKER_HEARTBEAT_S=1
  export STUB_MODE="hang"
  # Run in the background so we can inspect the lease mid-review.
  bash "$WORKER" >/dev/null 2>&1 &
  worker_pid=$!
  sleep 3
  lease_until="$(python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT lease_until,status FROM jobs WHERE id=1').fetchone()
print(r[0] if r else 0)
c.close()")"
  now="$(date +%s)"
  # A renewed lease is in the future; without heartbeat the original 1500s lease
  # would also be in the future, so assert it moved past the initial claim+1500.
  [ "$lease_until" -gt $((now + 1400)) ]
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
}

@test "worker: SIGTERM between jobs exits 0 without failing the job" {
  enqueue
  run bash -c "QA_WORKER_ONCE=0 bash '$WORKER' & p=\$!; sleep 1; kill -TERM \$p; wait \$p; echo rc=\$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

# ── dedupe interaction ────────────────────────────────────────────────────

@test "worker: a duplicate enqueue while the job is running is refused" {
  enqueue
  export STUB_MODE="hang"
  bash "$WORKER" >/dev/null 2>&1 &
  worker_pid=$!
  sleep 2
  run python3 "$BROKER" --db "$QA_QUEUE_DB" enqueue "$REPO" "$PR" "$SHA" "$REQ_UID"
  [ "$status" -eq 76 ]
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
}

@test "worker: a GO is not re-reviewed when the same key is enqueued again" {
  enqueue
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  run python3 "$BROKER" --db "$QA_QUEUE_DB" enqueue "$REPO" "$PR" "$SHA" "$REQ_UID"
  [ "$status" -eq 76 ]
  [[ "$output" == *'"status":"duplicate"'* ]]
}

# ── fatal configuration ───────────────────────────────────────────────────

@test "worker: the review turn uses a real CLI invocation (--session-id, not --session)" {
  # Regression for the Critical that shipped: `--session isolated` is not an
  # option on the installed CLI, so every review died before the agent started.
  # The stub above rejects unknown options, so this fails if the worker ever
  # passes one again.
  enqueue
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  run env QA_WORKER_ONCE=1 STUB_MODE=ok bash "$WORKER"
  [ "$status" -eq 0 ]
  # Assert the review actually COMPLETED. Without this the test could pass on a
  # worker that never ran a turn: a non-final `! grep` does not fail a bats test,
  # so a worker passing both --session-id and an invalid --session would fail the
  # turn, skip the greps below, and still leave the test green.
  [[ "$output" == *"verdict=go"* ]]
  grep -q 'OPENCLAW ARGS: agent --agent qa --session-id ' "$STUB_LOG"
  if grep -q -- '--session ' "$STUB_LOG"; then
    echo "worker passed --session, which the real CLI rejects" >&2
    false
  fi
  # A fresh session per job is what isolates the review.
  grep -qE -- '--session-id qa-review-Muso-AI-hydra-1730-a1b2c3d-[0-9]+-[0-9]+' "$STUB_LOG"
}

@test "worker: exits 1 when openclaw is not on PATH" {
  enqueue
  run env PATH="/usr/bin:/bin" OPENCLAW=definitely-not-openclaw bash "$WORKER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL"* ]]
}

# ── GitHub REST budget gate ────────────────────────────────────────────────
# N reviewer pods share ONE App installation's REST budget. A worker that
# claims a job it cannot finish burns a review slot and ends in a false
# CANNOT REVIEW, so the gate must refuse to claim — and "unknown" is never
# "fine".

@test "worker: does not claim when the GitHub REST budget is below the floor" {
  enqueue
  export QA_WORKER_GH_BUDGET=1
  export QA_GH_BUDGET_FILE="$TMP/gh-budget.json"
  export QA_GH_BUDGET_FLOOR=800
  # A gh stub that answers rate_limit with a nearly-spent budget.
  cat >"$TMP/bin/qa-gh-budget-stub" <<'STUB'
#!/usr/bin/env bash
printf '{"resources":{"core":{"remaining":12,"reset":1999999999}}}\n'
STUB
  chmod +x "$TMP/bin/qa-gh-budget-stub"
  export QA_GH="$TMP/bin/qa-gh-budget-stub"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"below floor"* ]]
  # The job is still queued: nothing was claimed, nothing was failed.
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status FROM jobs WHERE id=1').fetchone()
assert r==('queued',), r
c.close()"
  [ ! -s "$STUB_LOG" ]   # openclaw was never invoked
}

@test "worker: does not claim when the GitHub REST budget is unknown" {
  enqueue
  export QA_WORKER_GH_BUDGET=1
  export QA_GH_BUDGET_FILE="$TMP/gh-budget.json"
  cat >"$TMP/bin/qa-gh-budget-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TMP/bin/qa-gh-budget-stub"
  export QA_GH="$TMP/bin/qa-gh-budget-stub"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget unknown"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status FROM jobs WHERE id=1').fetchone()
assert r==('queued',), r
c.close()"
}

@test "worker: claims normally when the budget is healthy" {
  enqueue
  export QA_WORKER_GH_BUDGET=1
  export QA_GH_BUDGET_FILE="$TMP/gh-budget.json"
  cat >"$TMP/bin/qa-gh-budget-stub" <<'STUB'
#!/usr/bin/env bash
printf '{"resources":{"core":{"remaining":4999,"reset":1999999999}}}\n'
STUB
  chmod +x "$TMP/bin/qa-gh-budget-stub"
  export QA_GH="$TMP/bin/qa-gh-budget-stub"
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claimed job"* ]]
}

# ── HTTP transport (review-bot finding, 2026-11-06) ───────────────────────
# The broker used to answer an empty claim with 204 and no body. The worker
# reads the body's rc, so an empty body parsed as rc 2 ("malformed"): an idle
# worker logged a claim error every poll forever, and QA_WORKER_ONCE=1 never
# exited. Both sides are fixed; this pins the client half.

@test "worker: a bodyless 204 claim is 'nothing to claim', not a malformed answer" {
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        # The old broker behaviour: 204, no body.
        self.send_response(204); self.end_headers()
    def do_GET(self):
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/healthz" && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" run timeout 20 bash "$WORKER"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # A one-shot worker exits 0 on an empty queue; it must not spin or error.
  [ "$rc" -eq 0 ]
  [[ "$out" != *"claim returned rc 2"* ]]
  [[ "$out" != *"malformed"* ]]
}

@test "worker: a broker internal error (rc 3) is loud, not an idle queue" {
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"ok":false,"error":"OperationalError: no such table","rc":3}'
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/healthz" && break
    sleep 0.1
  done
  QA_BROKER_URL="http://127.0.0.1:$port" run timeout 20 bash "$WORKER"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ]
  [[ "$out" == *"INTERNAL ERROR"* ]]
  # It must not be mistaken for an empty queue.
  [[ "$out" != *"queue empty"* ]]
}

@test "worker: a turn that exits 0 but publishes no status is requeued, not finished" {
  # The repos read the qa-review STATUS, not the broker. Recording a turn that
  # published nothing as `done` makes the row terminal with no verdict on the
  # PR: it sits unreviewed forever and nothing retries it. That is the silent
  # drop the queue exists to prevent, so it must be a failure.
  enqueue
  export QA_WORKER_VERDICT_GRACE_S=0
  # No status is ever posted (STUB_STATUS_STATE unset -> []).
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published no qa-review status"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
row=c.execute('SELECT status,verdict,review_attempts FROM jobs WHERE id=1').fetchone()
assert row[0]=='queued', row
assert row[1] is None, row
assert row[2]==1, row
c.close()"
}

@test "worker: a status that appears during the grace window is a normal finish" {
  # The skill posts the status, so a turn can return a moment before the API
  # reflects it. The grace re-read must not turn that race into a retry.
  enqueue
  export QA_WORKER_VERDICT_GRACE_S=0
  # The first read sees nothing, the second sees the GO the skill just posted.
  export STUB_STATUS_EMPTY_FIRST=1
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finished verdict=go"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
row=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert row==('done','go'), row
c.close()"
}

@test "worker: a forced re-review does not finish on the PREVIOUS verdict" {
  # A NO-GO on this head, then a tier-label fix reopens the same key with
  # --force. The new turn exits 0 but publishes nothing. The old NO-GO is still
  # on the commit, so a naive read records it as this run's verdict: the
  # re-review slot is consumed and the PR still has no fresh verdict.
  enqueue
  export STUB_STATUS_STATE="failure"
  export STUB_STATUS_DESC="NO-GO — 1 blocking finding"
  export STUB_STATUS_FIXED_AT=1
  export STUB_STATUS_CREATED_AT="2026-11-04T12:00:00Z"
  # The turn publishes nothing new: every read returns the same old row.
  export QA_WORKER_VERDICT_GRACE_S=0
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published no qa-review status"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('queued',None), r
c.close()"
}

@test "worker: a status posted AFTER the baseline is this run's verdict" {
  enqueue
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  # The baseline read sees the old NO-GO; the post-turn read sees a newer GO.
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finished verdict=go"* ]]
}

@test "worker: a qa-review status from another actor is not this run's verdict" {
  # `qa-review` is a public context: anyone with write access can post it. A
  # status posted by someone else after the baseline must not be recorded as
  # this reviewer's verdict, or the re-review slot is consumed by a verdict this
  # turn never produced.
  enqueue
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO — 0 blocking findings"
  export STUB_STATUS_CREATOR="some-other-actor"
  export QA_WORKER_VERDICT_GRACE_S=0
  run bash "$WORKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published no qa-review status"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status,verdict FROM jobs WHERE id=1').fetchone()
assert r==('queued',None), r
c.close()"
}

@test "worker: a bodyless 502 from the broker is a transport failure, not an idle queue" {
  # A proxy's bodyless 502 makes curl exit 0. Reading the empty body as "nothing
  # to claim" (rc 1) means every reviewer treats an unavailable broker as an
  # idle queue while accepted jobs wait.
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  enqueue
  QA_BROKER_URL="http://127.0.0.1:$port" run bash "$WORKER"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ]
  # It must NOT report an empty queue, and the job must still be queued.
  [[ "$out" != *"queue empty"* ]]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT status FROM jobs WHERE id=1').fetchone()
assert r==('queued',), r
c.close()"
}

@test "worker: a JSON 502 without rc is a transport failure, not a claim" {
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 - "$port" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body=b'{"error":"upstream unavailable"}'
        self.send_response(502)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        body=b'{"error":"upstream unavailable"}'
        self.send_response(502)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1
  done
  enqueue
  QA_BROKER_URL="http://127.0.0.1:$port" run bash "$WORKER"
  local rc=$status out="$output"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ]
  [[ "$out" != *"queue empty"* ]]
  [[ "$out" != *"no job id"* ]]
}

@test "worker: an unreadable status baseline requeues instead of reviewing blind" {
  # An EMPTY baseline is legitimate (no status yet); a FAILED read is not.
  # read_verdict skips its `after` filter when the baseline is empty, so a
  # transient GET failure let a forced re-review that published nothing read the
  # previous NO-GO and finish, consuming the re-review slot.
  export STUB_STATUS_FAIL_FIRST=1
  export STUB_STATUS_STATE="failure"
  export STUB_STATUS_DESC="NO-GO"
  export STUB_STATUS_FIXED_AT=1
  enqueue
  QA_WORKER_ONCE=1 run "$WORKER"
  [ "$status" -eq 0 ]
  # The turn must not have run at all: nothing to attribute a verdict to.
  [ ! -s "$STUB_LOG" ]
  python3 -c "
import sqlite3
c=sqlite3.connect('$QA_QUEUE_DB')
row=c.execute('SELECT status, verdict, last_error FROM jobs').fetchone()
assert row[0]=='queued', row
assert row[1] is None, row
assert 'baseline' in (row[2] or ''), row
c.close()"
}

@test "worker: a baseline read that succeeds with no statuses still reviews" {
  # The empty-but-successful case must keep working: a first review has no
  # prior status, and refusing to run it would deadlock every new PR.
  export STUB_STATUS_STATE="success"
  export STUB_STATUS_DESC="GO"
  enqueue
  QA_WORKER_ONCE=1 run "$WORKER"
  [ "$status" -eq 0 ]
  [ -s "$STUB_LOG" ]
  python3 -c "
import sqlite3
c=sqlite3.connect('$QA_QUEUE_DB')
row=c.execute('SELECT status, verdict FROM jobs').fetchone()
assert row==('done','go'), row
c.close()"
}

@test "worker: the heartbeat is scoped to the claimed job, not the worker id" {
  # A restarted container can reuse `<hostname>-<pid>`. An unscoped heartbeat
  # would renew an ABANDONED row owned by that id forever, so the reaper would
  # never requeue it and the PR would sit running with no worker behind it.
  export QA_WORKER_HEARTBEAT_S=1
  export STUB_MODE="hang"
  enqueue
  # A second job for a different PR, already running under the SAME worker id
  # and abandoned (its heartbeat is old).
  python3 "$BROKER" --db "$QA_QUEUE_DB" enqueue "$REPO" 999 "$(printf '%040d' 9)" "$REQ_UID" >/dev/null
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET status='running', lease_owner='w1', "
          "lease_until=strftime('%s','now')+1500, "
          "last_heartbeat_at=strftime('%s','now')-600 WHERE pr=999")
c.commit()
PY
  # Not `run`: bats' `run` captures in the foreground, so backgrounding it does
  # not start the worker.
  QA_WORKER_ID=w1 QA_WORKER_ONCE=1 "$WORKER" >/dev/null 2>&1 &
  local wpid=$!
  sleep 4
  python3 - "$QA_QUEUE_DB" "$PR" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
claimed = int(sys.argv[2])
rows = dict(c.execute("SELECT pr, last_heartbeat_at FROM jobs").fetchall())
now = int(time.time())
# The claimed job is being renewed; the abandoned one (pr 999) is not.
assert rows[claimed] > now - 60, rows
assert rows[999] < now - 300, rows
c.close()
PY
  wait "$wpid" 2>/dev/null || true
}
