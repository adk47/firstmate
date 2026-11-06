#!/usr/bin/env bats
# Tests for scripts/lib/qa_broker.py — the durable QA review queue.
#
# The broker's whole value is four invariants, so this file tests them as
# invariants rather than as incidental behaviour:
#   1. a key (repo#pr@head_sha) is never reviewed twice
#   2. a newer head supersedes a queued older one
#   3. one PR has at most one active review (a database constraint)
#   4. a crashed reviewer's lease expires and its job re-queues
# Plus the retry/dead-letter contract and the dedupe metrics the captain asked
# to see. Every test runs against a throwaway sqlite file in BATS_TMPDIR; the
# suite never touches the live queue at /var/lib/hydra-qa/queue.sqlite.

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
BROKER="$HYDRA_REPO/scripts/lib/qa_broker.py"

REPO="Muso-AI/hydra"
REQ_UID="U123ABC"

setup() {
  TMPDB="$(mktemp -d)"
  export QA_QUEUE_DB="$TMPDB/queue.sqlite"
  # Deterministic dedupe posture for the suite; individual tests override.
  export QA_BROKER_DEDUPE_DONE="go-only"
  export QA_BROKER_MAX_REVIEWS_PER_KEY=2
  export QA_BROKER_PER_REPO_INFLIGHT_CAP=0
  # The HTTP layer refuses mutations without a token unless this is set. The
  # suite exercises the queue, not the auth gate; the gate has its own tests
  # below, which unset this and set QA_BROKER_TOKEN instead.
  export QA_BROKER_ALLOW_UNAUTHENTICATED=1
  unset QA_BROKER_TOKEN
}

teardown() {
  rm -rf "$TMPDB"
}

# Run the broker and split stdout from rc without tripping `set -e`.
broker() {
  run python3 "$BROKER" "$@"
}

sha() { printf '%040d' "$1"; }

# Read one field out of the last `run` output (the broker prints JSON).
json_get() {
  printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$2"
}

# ── 1. dedupe: the same key is never reviewed twice ───────────────────────

@test "dedupe: a second enqueue of the same key is refused while queued" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"queued"'* ]]

  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 76 ]
  [[ "$output" == *'"status":"duplicate"'* ]]
  [[ "$output" == *'"existing_status":"queued"'* ]]
}

@test "dedupe: a second enqueue is refused while the review is running" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  [ "$status" -eq 0 ]

  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 76 ]
  [[ "$output" == *'"existing_status":"running"'* ]]
}

@test "dedupe: a GO verdict is terminal — the same key is refused when done" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 go

  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 76 ]
  [[ "$output" == *'"existing_status":"done"'* ]]
  [[ "$output" == *'"verdict":"go"'* ]]
}

@test "dedupe: a failed verdict may be re-reviewed only with --force" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 no_go

  # without --force: refused as a duplicate (NOT "superseded" — that word is
  # reserved for a queued row a newer head replaced, so the supersede metric
  # cannot be inflated by ordinary re-enqueues).
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 76 ]
  [[ "$output" == *'"status":"duplicate"'* ]]
  [[ "$output" == *'"existing_status":"done"'* ]]

  # with --force: re-opened, still ONE row for the key (never two)
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"queued"'* ]]
  [[ "$output" == *'"reopened":true'* ]]
}

@test "dedupe: --force cannot exceed QA_BROKER_MAX_REVIEWS_PER_KEY" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 no_go          # attempts=1
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --force   # attempts reset to 0
  broker claim w2
  broker finish 2 w2 no_go          # attempts=1 again
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --force   # allowed, attempts=2
  broker claim w3
  broker finish 3 w3 no_go          # attempts=2 == cap
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 76 ]
}

@test "dedupe: QA_BROKER_DEDUPE_DONE=off lets a GO be re-reviewed" {
  export QA_BROKER_DEDUPE_DONE=off
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 go
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 0 ]
}

# ── 2. supersede: a newer head cancels the queued older one ───────────────

@test "supersede: a newer head supersedes the older QUEUED head" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:00:00Z
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z
  [ "$status" -eq 0 ]
  [[ "$output" == *'"superseded":1'* ]]

  broker dump
  [[ "$output" == *'"status":"superseded"'* ]]
  [[ "$output" == *'"status":"queued"'* ]]
}

@test "supersede: a newer head does NOT kill a RUNNING review" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  [ "$status" -eq 0 ]

  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"queued"'* ]]

  # the running review is still running, and its verdict still lands
  broker dump
  [[ "$output" == *'"status":"running"'* ]]
  broker finish 1 w1 go
  [ "$status" -eq 0 ]
}

@test "supersede: only the newest of several queued heads survives" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:00:00Z
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z
  broker enqueue "$REPO" 1730 "$(sha 3)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:10:00Z
  broker dump
  # exactly one queued row for the PR
  queued=$(python3 -c "
import json,sys
rows=json.load(sys.stdin)
print(sum(1 for r in rows if r['status']=='queued'))" <<<"$output")
  [ "$queued" -eq 1 ]
}

@test "supersede: a delayed OLDER head does not cancel the current head's review" {
  # Arrival order is not commit order. A dispatch for head B lands, then a
  # delayed dispatch for the OLDER head A arrives. Without the producer's
  # current-head assertion, A would supersede B and the PR's actual head would
  # get no review at all while the stale head became the only claimable job.
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"queued"'* ]]
  # Nothing was superseded: both rows are queued, and the current head is
  # still there to be reviewed.
  broker dump
  [[ "$output" != *'"status":"superseded"'* ]]
  python3 -c "
import json,sys
rows=json.load(sys.stdin)
q=[r for r in rows if r['status']=='queued']
assert len(q)==2, q
assert any(r['head_sha']=='$(sha 2)' for r in q), q
" <<<"$output"
}

@test "supersede: without --current-head nothing is superseded (fail safe)" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID"
  [ "$status" -eq 0 ]
  [[ "$output" != *'superseded=1'* ]]
  broker dump
  [[ "$output" != *'"status":"superseded"'* ]]
}

# ── 3. one active review per PR (a database constraint) ───────────────────

@test "one-active: a second claim for the same PR finds nothing" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  [ "$status" -eq 0 ]
  broker claim w2
  [ "$status" -eq 1 ]
}

@test "one-active: the unique index blocks a second running row at the DB level" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  # Bypass the API and try to insert a competing running row for the same PR.
  run python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
try:
    conn.execute(
        "INSERT INTO jobs(repo,pr,head_sha,requester_uid,enqueued_at,status)"
        " VALUES ('Muso-AI/hydra',1730,'ffffffffffffffffffffffffffffffffffffffff','U1',0,'running')"
    )
    conn.commit()
    print("INSERTED")
except sqlite3.IntegrityError as e:
    print("BLOCKED")
conn.close()
PY
  [[ "$output" == *"BLOCKED"* ]]
}

@test "one-active: active_reviews_per_pr_max metric stays at 1" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker enqueue "$REPO" 1731 "$(sha 2)" "$REQ_UID"
  broker claim w1
  broker claim w2
  broker stats
  python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['dedupe']['active_reviews_per_pr_max']==1, d
" <<<"$output"
}

# ── 4. lease: a crashed reviewer's job re-queues ─────────────────────────

@test "lease: an expired lease returns the job to the queue" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1 --lease 1
  [ "$status" -eq 0 ]
  sleep 2
  broker reap --grace 0
  [ "$status" -eq 0 ]
  [[ "$output" == *'"requeued"'* ]]

  broker dump
  [[ "$output" == *'"status":"queued"'* ]]
}

@test "lease: reap preserves the attempt count (a crash is an attempt)" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1 --lease 1
  sleep 2
  broker reap --grace 0
  broker dump
  python3 -c "
import json,sys
rows=json.load(sys.stdin)
row=[r for r in rows if r['status']=='queued'][0]
assert row['attempts']==1, row
assert row['last_error']=='lease expired', row
" <<<"$output"
}

@test "lease: heartbeat extends the lease so reap leaves the job alone" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1 --lease 2
  broker heartbeat w1 --lease 300
  [ "$status" -eq 0 ]
  broker reap --grace 0
  broker dump
  [[ "$output" == *'"status":"running"'* ]]
}

@test "lease: a crash loop dead-letters instead of spinning" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  # claim+expire three times: MAX_REVIEW_ATTEMPTS is 3
  for _ in 1 2 3; do
    broker claim w1 --lease 1 || true
    sleep 2
    broker reap --grace 0 >/dev/null || true
    # clear the not_before backoff so the next claim is immediate
    python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET not_before=0 WHERE status='queued'\")
c.commit(); c.close()"
  done
  broker dump
  [[ "$output" == *'"status":"dead"'* ]]
}

# ── retry classes ─────────────────────────────────────────────────────────

@test "abandon: a job whose head moved is retired as superseded, not failed" {
  # The skill resolves the PR head itself, so a turn that started on A and
  # finished after B was pushed reviewed B and published on B. This job only
  # looks at A, so the successful turn reads as `unknown`. Retrying would
  # re-review B and eventually dead-letter a PR that is being reviewed.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  run python3 "$BROKER" abandon 1 w1 "head moved to bbbbbbb during the review"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"superseded"'* ]]
  broker dump
  [[ "$output" == *'"status":"superseded"'* ]]
  # Not a failure: no review attempt is charged, so a head move can never
  # dead-letter a PR.
  [[ "$output" == *'"review_attempts":0'* ]]
  [[ "$output" == *'"transport_attempts":0'* ]]
  # And it is not counted as dead or lost.
  broker stats
  python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['dead']==0, d
assert d['lost_window']==0, d
assert d['running']==0, d
assert d['depth']==0, d
" <<<"$output"
}

@test "abandon: a worker that does not hold the lease cannot retire the job" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  run python3 "$BROKER" abandon 1 w2 "not mine"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"not_owner"'* ]]
  broker dump
  [[ "$output" == *'"status":"running"'* ]]
}

@test "abandon: a superseded job is not claimable again" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  python3 "$BROKER" abandon 1 w1 "head moved" >/dev/null
  run python3 "$BROKER" claim w2
  # An empty claim is rc 1 with no body on the CLI path.
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "ownership: a worker that does not hold the lease cannot fail the job" {
  # After a stale-heartbeat reap and a reclaim, the ORIGINAL worker is still
  # running its review. If it could call fail(), it would requeue the NEW
  # owner's running review: duplicate work, and a dead-letter charged to the
  # wrong attempt.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim worker-A
  [ "$status" -eq 0 ]
  broker fail 1 worker-B 1 review "stale worker"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"not_owner"'* ]]
  # The row is untouched: still running, still owned by A.
  broker dump
  [[ "$output" == *'"status":"running"'* ]]
  [[ "$output" == *'"lease_owner":"worker-A"'* ]]
  # And A can still finish it.
  broker finish 1 worker-A go
  [ "$status" -eq 0 ]
}

@test "ownership: a reaped job cannot be failed by the worker that lost it" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim worker-A
  # The reaper takes it back (A's heartbeat went stale).
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET last_heartbeat_at=0, lease_until=0 WHERE id=1\")
c.commit(); c.close()"
  broker reap >/dev/null
  broker fail 1 worker-A 1 review "late failure"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"not_owner"'* ]]
  # The reaper's requeue stands; A's late failure did not consume an attempt.
  broker dump
  [[ "$output" == *'"status":"queued"'* ]]
  [[ "$output" == *'"attempts":1'* ]]
}

@test "retry: a transport failure requeues with the transport budget" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker fail 1 w1 75 transport "Opening handshake has timed out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"queued"'* ]]
  [[ "$output" == *'"retry_in":120'* ]]
}

@test "retry: a quota failure waits 30 minutes flat" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker fail 1 w1 429 quota "usage cap exceeded"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retry_in":1800'* ]]
}

@test "retry: a review-turn failure backoff starts at 60s" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker fail 1 w1 1 review "turn errored"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retry_in":60'* ]]
}

@test "dead-letter: 12 transport failures mark the job dead and keep it" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  for _ in $(seq 1 12); do
    # Clear the backoff BEFORE claiming: a claim of a row whose not_before is
    # still in the future returns empty, and fail() now (correctly) refuses a
    # row this worker does not hold, so the old order silently stopped after
    # the first attempt.
    python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET not_before=0 WHERE status='queued'\")
c.commit(); c.close()"
    broker claim w1 >/dev/null 2>&1 || true
    run python3 "$BROKER" fail 1 w1 75 transport "gateway unreachable"
    [[ "$output" == *'"status":"dead"'* ]] && break
  done
  broker dump
  [[ "$output" == *'"status":"dead"'* ]]
  [[ "$output" == *'"transport_attempts":12'* ]]
}

@test "dead-letter: a forced enqueue retries a dead job on the same head" {
  # The retry budget is spent on an OUTAGE (a dead gateway, a spent quota). Once
  # that is fixed the PR still has no verdict, and the design promises dead +
  # force as the operator-retry path. Without it the only ways out were a new
  # commit or hand-editing the database.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET status='dead', last_error='gateway unreachable', transport_attempts=12 WHERE id=1\")
c.commit(); c.close()"
  # Without force it is still a duplicate: an automatic reconciler retry must
  # not resurrect a job that already exhausted its budget.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 76 ]
  [[ "$output" == *'"status":"duplicate"'* ]]
  [[ "$output" == *'"existing_status":"dead"'* ]]
  # With force it reopens, and the budgets are reset so the retry can run.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"queued"'* ]]
  [[ "$output" == *'"reopened":true'* ]]
  broker dump
  [[ "$output" == *'"status":"queued"'* ]]
  [[ "$output" == *'"transport_attempts":0'* ]]
  [[ "$output" == *'"last_error":null'* ]]
  # And it is claimable again.
  broker claim w1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"running"'* ]]
  # One row per key, never a second.
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
assert c.execute('SELECT COUNT(*) FROM jobs').fetchone()[0]==1
c.close()"
}

@test "dead-letter: a dead row is never deleted and is counted in stats" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET status='dead', last_error='test' WHERE id=1\")
c.commit(); c.close()"
  broker stats
  python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['dead']==1, d
" <<<"$output"
}

# ── metrics ───────────────────────────────────────────────────────────────

@test "metrics: duplicates and supersedes are counted in stats" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:00:00Z >/dev/null
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" >/dev/null || true   # duplicate
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z >/dev/null  # supersedes sha1
  broker stats
  python3 -c "
import json,sys
d=json.load(sys.stdin)['dedupe']
assert d['duplicates_dropped']>=1, d
assert d['superseded']>=1, d
" <<<"$output"
}

@test "metrics: wait p50/p95 are reported after a claim" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker stats
  python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'wait_p50_s' in d and 'wait_p95_s' in d, d
assert d['done_window']==0, d
" <<<"$output"
}

# ── persistence: a restart loses nothing ─────────────────────────────────

@test "persistence: a fresh process sees the queued rows" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 1731 "$(sha 2)" "$REQ_UID" >/dev/null
  # Every invocation is already a separate process; this asserts the rows are
  # on disk rather than in memory.
  broker stats
  python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['depth']==2, d
" <<<"$output"
}

@test "persistence: a claim survives a process restart" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker dump
  python3 -c "
import json,sys
rows=json.load(sys.stdin)
assert rows[0]['status']=='running', rows
assert rows[0]['lease_owner']=='w1', rows
" <<<"$output"
}

# ── validation ────────────────────────────────────────────────────────────

@test "validation: a non-Muso-AI repo is refused" {
  broker enqueue "evil/repo" 1 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 2 ]
}

@test "validation: a non-numeric PR is refused" {
  broker enqueue "$REPO" "abc" "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 2 ]
}

@test "validation: a malformed sha is refused" {
  broker enqueue "$REPO" 1 "nothex" "$REQ_UID"
  [ "$status" -eq 2 ]
}

@test "validation: a non-Slack requester uid is refused" {
  broker enqueue "$REPO" 1 "$(sha 1)" "aaron"
  [ "$status" -eq 2 ]
}

@test "validation: an unknown verdict is refused" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker finish 1 w1 "maybe"
  [ "$status" -eq 2 ]
}

@test "ownership: a worker cannot finish another worker's job" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker finish 1 w2 go
  [ "$status" -eq 2 ]
}

# ── lost jobs: the invariant that nothing disappears ──────────────────────
# Every enqueued job is either open (queued/running) or terminal
# (done/dead/superseded). If those do not add up, a row went missing. This is
# the metric the captain asked for, so it is tested as an invariant.

@test "lost: a healthy queue reports zero lost jobs" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker finish 1 w1 go >/dev/null
  broker stats >/dev/null
  [ "$(json_get "$output" lost_window)" -eq 0 ]
  [ "$(json_get "$output" lost_total)" -eq 0 ]
}

@test "lost: a row deleted behind the broker's back is counted as lost" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  # Simulate the failure the metric exists to catch: a row vanishes.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  broker stats >/dev/null
  [ "$(json_get "$output" lost_window)" -eq 1 ]
  [ "$(json_get "$output" lost_total)" -eq 1 ]
}

@test "lost: enqueued_window counts arrivals in the window" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  broker stats >/dev/null
  [ "$(json_get "$output" enqueued_window)" -eq 2 ]
}

# ── fleet-wide in-flight cap ──────────────────────────────────────────────
# Scaling to N pods must not mean N simultaneous reviews against one shared
# model route and one shared GitHub budget.

@test "cap: QA_BROKER_MAX_RUNNING stops claims once the fleet is saturated" {
  export QA_BROKER_MAX_RUNNING=2
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 3 "$(sha 3)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker claim w2 >/dev/null
  broker claim w3
  [ "$status" -eq 1 ]          # empty claim, not an error
  [ -z "$output" ]
  broker stats >/dev/null
  [ "$(json_get "$output" running)" -eq 2 ]
  [ "$(json_get "$output" depth)" -eq 1 ]
}

@test "cap: a finished review frees a slot for the next claim" {
  export QA_BROKER_MAX_RUNNING=1
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker claim w2
  [ "$status" -eq 1 ]
  broker finish 1 w1 go >/dev/null
  broker claim w2 >/dev/null
  [ "$(json_get "$output" pr)" -eq 2 ]
}

@test "cap: 0 (the default) means unlimited" {
  export QA_BROKER_MAX_RUNNING=0
  for i in 1 2 3 4 5; do
    broker enqueue "$REPO" "$i" "$(sha "$i")" "$REQ_UID" >/dev/null
  done
  for i in 1 2 3 4 5; do
    broker claim "w$i" >/dev/null
  done
  broker stats >/dev/null
  [ "$(json_get "$output" running)" -eq 5 ]
}

# ── stale heartbeat: a SIGKILLed worker must not hold a PR for the lease ──
# A pod eviction or node drain never releases the lease, so waiting for
# lease_until would hold that PR for the whole lease (25 min) — most of the
# wait budget the queue exists to protect.

@test "reap: a stale heartbeat requeues before the lease expires" {
  export QA_BROKER_HEARTBEAT_STALE_S=360
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  # The worker is gone: its heartbeat is 10 minutes old, but the lease still
  # has ~20 minutes to run.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
now = int(time.time())
c.execute("UPDATE jobs SET last_heartbeat_at=?, lease_until=?", (now - 600, now + 1200))
c.commit()
PY
  broker reap >/dev/null
  [ "$(json_get "$output" count)" -eq 1 ]
  broker stats >/dev/null
  [ "$(json_get "$output" depth)" -eq 1 ]
  [ "$(json_get "$output" running)" -eq 0 ]
}

@test "reap: a fresh heartbeat is left alone even if the lease is long" {
  export QA_BROKER_HEARTBEAT_STALE_S=360
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker heartbeat w1 >/dev/null
  broker reap >/dev/null
  [ "$(json_get "$output" count)" -eq 0 ]
  broker stats >/dev/null
  [ "$(json_get "$output" running)" -eq 1 ]
}

@test "reap: the requeue reason distinguishes stale heartbeat from expired lease" {
  export QA_BROKER_HEARTBEAT_STALE_S=360
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
now = int(time.time())
c.execute("UPDATE jobs SET last_heartbeat_at=?, lease_until=?", (now - 600, now + 1200))
c.commit()
PY
  broker reap >/dev/null
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
r=c.execute('SELECT last_error FROM jobs WHERE id=1').fetchone()
assert r[0]=='heartbeat stale', r
c.close()"
}

@test "migration: an old database without last_heartbeat_at is upgraded in place" {
  # CREATE TABLE IF NOT EXISTS is a no-op on an existing file, so a new column
  # would silently never appear on a live queue.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL, requester_uid TEXT NOT NULL, enqueued_at INTEGER NOT NULL,
  not_before INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0, transport_attempts INTEGER NOT NULL DEFAULT 0,
  quota_attempts INTEGER NOT NULL DEFAULT 0, lease_owner TEXT, lease_until INTEGER,
  started_at INTEGER, finished_at INTEGER, verdict TEXT, last_error TEXT,
  superseded_by INTEGER, UNIQUE(repo, pr, head_sha));
""")
c.commit()
PY
  broker stats >/dev/null
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
cols={r[1] for r in c.execute('PRAGMA table_info(jobs)')}
assert 'last_heartbeat_at' in cols, cols
c.close()"
}

# ── review-bot findings (2026-11-06) ───────────────────────────────────────
# Each of these pins a bug the automated reviewer found in the first cut. They
# are regression tests, not new behaviour.

@test "force cap: the re-review budget is cumulative, not reset by each reopen" {
  # A failed review leaves attempts=1; --force passes the <2 check and the
  # reopen used to reset attempts to 0, so every --force looked like the first
  # one and the documented cap never fired.
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 no_go
  # First forced re-review is allowed (reviews=1 < 2).
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reopened":true'* ]]
  broker claim w2
  broker finish 1 w2 no_go
  # Second forced re-review is refused: reviews=2 is the cap.
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 76 ]
  [[ "$output" == *'"status":"duplicate"'* ]]
}

@test "force cap: reviews counts completions, so a retried run does not consume it" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker fail 1 w1 1 review "turn errored"
  # The retry is scheduled with a backoff; clear it so the test does not sleep.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET not_before=0")
c.commit()
PY
  # A retry is not a completed review: the cap must still allow two re-reviews.
  broker claim w2
  broker finish 1 w2 no_go
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 0 ]
}

@test "lost: the windowed count compares like-for-like populations" {
  # Ten old healthy rows plus one newly lost row used to yield 1 - 10 = -9,
  # which masked the loss and silenced the digest's page.
  for i in $(seq 1 10); do
    broker enqueue "$REPO" "$i" "$(sha "$i")" "$REQ_UID"
  done
  for i in $(seq 1 10); do
    broker claim "w$i"
    broker finish "$i" "w$i" go
  done
  # Age them out of the window.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 100000")
c.execute("UPDATE events SET at = at - 100000")
c.commit()
PY
  broker enqueue "$REPO" 99 "$(sha 99)" "$REQ_UID"
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM jobs WHERE pr=99")
c.commit()
PY
  broker stats --window 3600
  [ "$status" -eq 0 ]
  [[ "$output" == *'"lost_window":1'* ]]
  [[ "$output" == *'"lost_total":1'* ]]
}

@test "http: an empty claim answers 200 with rc 1, never a bodyless 204" {
  # A 204 cannot carry the body the worker reads, and an empty body parses as
  # rc 2 ("malformed"), which an idle worker logs as an error forever and which
  # never lets a one-shot worker exit.
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  run curl -sS -o /tmp/claim-body.$$ -w '%{http_code}' -X POST \
    "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' -d '{"worker":"w1"}'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$output" = "200" ]
  run cat /tmp/claim-body.$$
  rm -f /tmp/claim-body.$$
  [[ "$output" == *'"rc":1'* ]]
}

@test "http: enqueue then claim then finish round-trips over the wire" {
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  run curl -sS -X POST "http://127.0.0.1:$port/enqueue" -H 'Content-Type: application/json' \
    -d "{\"repo\":\"$REPO\",\"pr\":7,\"head_sha\":\"$(sha 7)\",\"requester_uid\":\"$REQ_UID\"}"
  [[ "$output" == *'"status":"queued"'* ]]
  run curl -sS -X POST "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' -d '{"worker":"w1"}'
  [[ "$output" == *'"pr":7'* ]]
  run curl -sS -X POST "http://127.0.0.1:$port/finish" -H 'Content-Type: application/json' \
    -d '{"id":1,"worker":"w1","verdict":"go"}'
  [[ "$output" == *'"verdict":"go"'* ]]
  # A duplicate enqueue is a 409 carrying rc 76, not a 200.
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/enqueue" \
    -H 'Content-Type: application/json' \
    -d "{\"repo\":\"$REPO\",\"pr\":7,\"head_sha\":\"$(sha 7)\",\"requester_uid\":\"$REQ_UID\"}"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$output" = "409" ]
}

# ── second review round (2026-11-06) ──────────────────────────────────────

@test "claim: a queued newer head does not block an unrelated PR" {
  # With head A running and head B queued for the same PR, the old SELECT chose
  # B and the partial unique index rejected the UPDATE with IntegrityError,
  # which the HTTP layer reported as an empty claim — so one PR's queued head
  # could starve every other PR.
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker enqueue "$REPO" 1 "$(sha 2)" "$REQ_UID"   # newer head, same PR
  broker enqueue "$REPO" 2 "$(sha 3)" "$REQ_UID"   # unrelated PR
  broker claim w2
  [ "$status" -eq 0 ]
  [[ "$output" == *'"pr":2'* ]]
  # And the same PR's newer head is still claimable once A finishes.
  broker finish 1 w1 go
  broker claim w3
  [ "$status" -eq 0 ]
  [[ "$output" == *'"pr":1'* ]]
  [[ "$output" == *"$(sha 2)"* ]]
}

@test "claim: a PR with a running review is never selected twice" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker enqueue "$REPO" 1 "$(sha 2)" "$REQ_UID"
  broker claim w2
  # Nothing else is queued, so the second claim is empty rather than an error.
  [ "$status" -eq 1 ]
}

@test "lost: a forced re-review does not cancel the loss alarm" {
  # Reopening used to move enqueued_at into the current window without adding
  # an enqueue event, so one reopened old row plus one newly deleted job read
  # lost_window=0 while lost_total=1 and the digest never paged.
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 no_go
  # Age the row and its events out of the window.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 100000")
c.execute("UPDATE events SET at = at - 100000")
c.commit()
PY
  # Force a re-review: the row re-enters the queue but is NOT a new arrival.
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 0 ]
  # Now lose a different, freshly enqueued job.
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID"
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  broker stats --window 3600
  [ "$status" -eq 0 ]
  [[ "$output" == *'"lost_window":1'* ]]
  [[ "$output" == *'"lost_total":1'* ]]
}

@test "lost: a reopen keeps the original arrival time" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  broker claim w1
  broker finish 1 w1 no_go
  local before
  before="$(python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
print(c.execute('SELECT enqueued_at FROM jobs WHERE id=1').fetchone()[0])")"
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" --force
  [ "$status" -eq 0 ]
  local after
  after="$(python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
print(c.execute('SELECT enqueued_at FROM jobs WHERE id=1').fetchone()[0])")"
  [ "$before" = "$after" ]
}

@test "http: an internal error answers rc 3, never rc 1 (an idle queue)" {
  # A broker that cannot read its store must not look like an empty queue, or
  # accepted PRs wait with no worker error anywhere.
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  # Break the store out from under the running service.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DROP TABLE jobs")
c.commit()
PY
  run curl -sS -X POST "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' -d '{"worker":"w1"}'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [[ "$output" == *'"rc":3'* ]]
  [[ "$output" != *'"rc":1'* ]]
}

@test "auth: a mutation without the token is refused, and nothing is claimed" {
  # An unauthenticated /claim + /finish lets any pod that can reach the service
  # record a `go` for a PR nobody reviewed and consume the job, so the real
  # review never runs. The queue is the only thing between a PR and a verdict.
  local port=$(( 20000 + RANDOM % 20000 ))
  unset QA_BROKER_ALLOW_UNAUTHENTICATED
  export QA_BROKER_TOKEN="s3cret-token"
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  # Enqueue WITH the token so there is a job to steal.
  curl -sS -X POST "http://127.0.0.1:$port/enqueue" -H 'Content-Type: application/json' \
    -H 'X-QA-Broker-Token: s3cret-token' \
    -d "{\"repo\":\"$REPO\",\"pr\":1,\"head_sha\":\"$(sha 1)\",\"requester_uid\":\"$REQ_UID\"}" >/dev/null
  # No token: refused.
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/claim" \
    -H 'Content-Type: application/json' -d '{"worker":"attacker"}'
  [ "$output" = "401" ]
  # Wrong token: refused.
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/claim" \
    -H 'Content-Type: application/json' -H 'X-QA-Broker-Token: wrong' -d '{"worker":"attacker"}'
  [ "$output" = "401" ]
  # The job is still queued and unclaimed.
  run curl -sS "http://127.0.0.1:$port/stats"
  [[ "$output" == *'"depth":1'* ]]
  [[ "$output" == *'"running":0'* ]]
  # The right token works.
  run curl -sS -X POST "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' \
    -H 'X-QA-Broker-Token: s3cret-token' -d '{"worker":"w1"}'
  [[ "$output" == *'"rc":0'* ]]
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "auth: with no token configured the broker refuses mutations rather than serving them openly" {
  local port=$(( 20000 + RANDOM % 20000 ))
  unset QA_BROKER_ALLOW_UNAUTHENTICATED
  unset QA_BROKER_TOKEN
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/claim" \
    -H 'Content-Type: application/json' -d '{"worker":"w1"}'
  [ "$output" = "503" ]
  # Reads stay open: the digest and health checks must not need the secret.
  run curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/stats"
  [ "$output" = "200" ]
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "caps: a malformed cap is refused, never treated as unlimited" {
  # _env_int returns the default on a bad value and every cap defaults to 0 =
  # unlimited, so QA_BROKER_MAX_RUNNING=bad silently removed the ceiling.
  export QA_BROKER_MAX_RUNNING="not-a-number"
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  [ "$status" -eq 0 ]
  run python3 "$BROKER" --db "$QA_QUEUE_DB" claim w1
  [ "$status" -ne 0 ]
  [[ "$output" == *"QA_BROKER_MAX_RUNNING"* ]]
  [[ "$output" == *"unlimited"* ]]
  # Nothing was claimed.
  unset QA_BROKER_MAX_RUNNING
  broker stats
  [[ "$output" == *'"running":0'* ]]
  [[ "$output" == *'"depth":1'* ]]
}

@test "caps: a negative cap is refused" {
  export QA_BROKER_PER_REPO_INFLIGHT_CAP="-1"
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID"
  run python3 "$BROKER" --db "$QA_QUEUE_DB" claim w1
  [ "$status" -ne 0 ]
  [[ "$output" == *"negative"* ]]
}

@test "http: a successful finish and fail carry rc 0, so the worker does not log a false refusal" {
  local port=$(( 20000 + RANDOM % 20000 ))
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -sS -X POST "http://127.0.0.1:$port/enqueue" -H 'Content-Type: application/json' \
    -d "{\"repo\":\"$REPO\",\"pr\":1,\"head_sha\":\"$(sha 1)\",\"requester_uid\":\"$REQ_UID\"}" >/dev/null
  curl -sS -X POST "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' -d '{"worker":"w1"}' >/dev/null
  run curl -sS -X POST "http://127.0.0.1:$port/finish" -H 'Content-Type: application/json' \
    -d '{"id":1,"worker":"w1","verdict":"go"}'
  [[ "$output" == *'"rc":0'* ]]
  # And /fail on a second job.
  curl -sS -X POST "http://127.0.0.1:$port/enqueue" -H 'Content-Type: application/json' \
    -d "{\"repo\":\"$REPO\",\"pr\":2,\"head_sha\":\"$(sha 2)\",\"requester_uid\":\"$REQ_UID\"}" >/dev/null
  curl -sS -X POST "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' -d '{"worker":"w1"}' >/dev/null
  run curl -sS -X POST "http://127.0.0.1:$port/fail" -H 'Content-Type: application/json' \
    -d '{"id":2,"worker":"w1","rc":1,"class":"review","message":"x"}'
  [[ "$output" == *'"rc":0'* ]]
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "serve: the broker reaps a dead worker's job without an external caller" {
  # serve_forever() used to never call reap(), so a killed worker's row stayed
  # running forever: depth read zero and no replacement could claim it.
  local port=$(( 20000 + RANDOM % 20000 ))
  export QA_BROKER_REAP_INTERVAL_S=1
  export QA_BROKER_HEARTBEAT_STALE_S=1
  python3 "$BROKER" --db "$QA_QUEUE_DB" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -sS -X POST "http://127.0.0.1:$port/enqueue" -H 'Content-Type: application/json' \
    -d "{\"repo\":\"$REPO\",\"pr\":5,\"head_sha\":\"$(sha 5)\",\"requester_uid\":\"$REQ_UID\"}" >/dev/null
  curl -sS -X POST "http://127.0.0.1:$port/claim" -H 'Content-Type: application/json' \
    -d '{"worker":"dead-worker"}' >/dev/null
  # The worker is now "killed": it never heartbeats again.
  sleep 4
  run curl -sS "http://127.0.0.1:$port/stats"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # The reaper returned it to the queue on its own.
  [[ "$output" == *'"depth":1'* ]]
  [[ "$output" == *'"running":0'* ]]
}

@test "supersede: a delayed POST that verified an OLDER head cannot cancel a newer one" {
  # The check-then-act race the review bot reproduced: dispatch A verifies head
  # A is current, head B is pushed, dispatch B verifies and enqueues B, and only
  # THEN does A's delayed POST arrive still claiming current_head. Arrival order
  # says A is newest; the verification token says otherwise.
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z
  [ "$status" -eq 0 ]
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:00:00Z
  [ "$status" -eq 0 ]
  [[ "$output" != *'superseded=1'* ]]
  broker dump
  # B is still queued and still claimable: the current head keeps its review.
  [[ "$output" != *'"status":"superseded"'* ]]
  python3 -c "
import json,sys
rows=json.load(sys.stdin)
q=[r for r in rows if r['status']=='queued']
assert len(q)==2, q
assert any(r['head_sha']=='$(sha 2)' for r in q), q
" <<<"$output"
}

@test "supersede: a strictly newer verification token does supersede" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:00:00Z
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z
  [ "$status" -eq 0 ]
  [[ "$output" == *'"superseded":1'* ]]
}

@test "supersede: an unverified row (no token) is never superseded" {
  # Fail safe: an unknown order could be the newer head, so it is left alone.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker enqueue "$REPO" 1730 "$(sha 2)" "$REQ_UID" --current-head \
    --head-order 2026-11-06T00:05:00Z
  [ "$status" -eq 0 ]
  [[ "$output" != *'superseded=1'* ]]
  broker dump
  [[ "$output" != *'"status":"superseded"'* ]]
}

@test "budgets: transport retries do not spend the review budget" {
  # The three budgets are independent. `attempts` counts every claim, so using
  # it as the review budget meant 3 transport failures left a job ONE review
  # failure from dead-letter (MAX_REVIEW_ATTEMPTS=3), and 12 transport failures
  # would have dead-lettered it on the review budget instead of the transport
  # one.
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  for _ in 1 2 3; do
    python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET not_before=0 WHERE status='queued'\"); c.commit(); c.close()"
    broker claim w1 >/dev/null
    broker fail 1 w1 75 transport "gateway unreachable" >/dev/null
  done
  broker dump
  # Three transport attempts spent, zero review attempts.
  [[ "$output" == *'"transport_attempts":3'* ]]
  [[ "$output" == *'"review_attempts":0'* ]]
  [[ "$output" == *'"status":"queued"'* ]]
  # Now the review budget is still whole: two review failures must NOT kill it.
  for _ in 1 2; do
    python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET not_before=0 WHERE status='queued'\"); c.commit(); c.close()"
    broker claim w1 >/dev/null
    broker fail 1 w1 1 review "turn errored" >/dev/null
  done
  broker dump
  [[ "$output" == *'"review_attempts":2'* ]]
  [[ "$output" == *'"status":"queued"'* ]]
  # The third review failure is the one that exhausts it.
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET not_before=0 WHERE status='queued'\"); c.commit(); c.close()"
  broker claim w1 >/dev/null
  broker fail 1 w1 1 review "turn errored" >/dev/null
  broker dump
  [[ "$output" == *'"status":"dead"'* ]]
  [[ "$output" == *'"review_attempts":3'* ]]
}

@test "budgets: a lease expiry spends the review budget, not the transport one" {
  broker enqueue "$REPO" 1730 "$(sha 1)" "$REQ_UID"
  broker claim w1 >/dev/null
  python3 -c "
import sqlite3,os
c=sqlite3.connect(os.environ['QA_QUEUE_DB'])
c.execute(\"UPDATE jobs SET last_heartbeat_at=0, lease_until=0 WHERE id=1\"); c.commit(); c.close()"
  broker reap >/dev/null
  broker dump
  [[ "$output" == *'"review_attempts":1'* ]]
  [[ "$output" == *'"transport_attempts":0'* ]]
}

@test "heartbeat: a scoped renewal does not revive another job owned by the same id" {
  # A container restarted in the same pod can reuse `<hostname>-<pid>`. If the
  # replacement claims a different PR and heartbeats unscoped, the ABANDONED
  # row's lease keeps advancing and the reaper never requeues it: the PR sits
  # running with no worker behind it.
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  # `broker` wraps `run`, so it captures output instead of printing it: read the
  # claimed ids back from the database.
  broker claim w1 >/dev/null
  broker claim w1 >/dev/null
  local a b
  a="$(python3 -c "
import sqlite3,sys
c=sqlite3.connect('$QA_QUEUE_DB')
print(c.execute(\"SELECT id FROM jobs WHERE pr=1\").fetchone()[0])")"
  b="$(python3 -c "
import sqlite3,sys
c=sqlite3.connect('$QA_QUEUE_DB')
print(c.execute(\"SELECT id FROM jobs WHERE pr=2\").fetchone()[0])")"
  [ "$a" != "$b" ]
  # Age both rows so a renewal is observable.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET last_heartbeat_at = last_heartbeat_at - 600")
c.commit()
PY
  # Renew ONLY job b, as the restarted worker would.
  broker heartbeat w1 --job-id "$b" >/dev/null
  python3 - "$QA_QUEUE_DB" "$a" "$b" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
rows = dict(c.execute("SELECT id, last_heartbeat_at FROM jobs").fetchall())
a, b = int(sys.argv[2]), int(sys.argv[3])
assert rows[b] > rows[a], rows
c.close()
PY
  # The abandoned row is now reapable; the renewed one is not.
  export QA_BROKER_HEARTBEAT_STALE_S=300
  broker reap >/dev/null
  python3 - "$QA_QUEUE_DB" "$a" "$b" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
rows = dict(c.execute("SELECT id, status FROM jobs").fetchall())
a, b = int(sys.argv[2]), int(sys.argv[3])
assert rows[a] == "queued", rows
assert rows[b] == "running", rows
c.close()
PY
}

@test "heartbeat: an unscoped renewal still renews every row (compatibility)" {
  broker enqueue "$REPO" 1 "$(sha 1)" "$REQ_UID" >/dev/null
  broker enqueue "$REPO" 2 "$(sha 2)" "$REQ_UID" >/dev/null
  broker claim w1 >/dev/null
  broker claim w1 >/dev/null
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET last_heartbeat_at = last_heartbeat_at - 600")
c.commit()
PY
  broker heartbeat w1 >/dev/null
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
now = int(time.time())
rows = [r[0] for r in c.execute("SELECT last_heartbeat_at FROM jobs").fetchall()]
assert all(r > now - 60 for r in rows), rows
c.close()
PY
}
