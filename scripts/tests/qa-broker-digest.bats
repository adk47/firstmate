#!/usr/bin/env bats
# Tests for scripts/qa-broker-digest.sh — the hourly QA queue line.
#
# The digest is the only thing that makes "no PR waits an hour for QA" a
# checkable claim, so the tests pin the two properties that matter:
#   1. the line carries every number the claim depends on
#   2. the page fires on the conditions that mean the claim is false
#
# Slack is never contacted: slack-notify.sh is sourced, and its bats fence
# refuses the installed muso binary. The tests assert on --dry-run output.

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DIGEST="$HYDRA_REPO/scripts/qa-broker-digest.sh"
BROKER="$HYDRA_REPO/scripts/lib/qa_broker.py"

setup() {
  TMPD="$(mktemp -d)"
  export QA_QUEUE_DB="$TMPD/queue.sqlite"
  export QA_BROKER_URL=cli
  export QA_DIGEST_STATE="$TMPD/digest-state.json"
  export QA_DIGEST_P95_S=900
  export QA_DIGEST_DEPTH=20
  export QA_DIGEST_OLDEST_S=300
  export QA_DIGEST_P95_STREAK=2
  export QA_BROKER_DEDUPE_DONE=go-only
  export QA_BROKER_MAX_REVIEWS_PER_KEY=2
  export QA_BROKER_PER_REPO_INFLIGHT_CAP=0
  export QA_BROKER_MAX_RUNNING=0
}

teardown() {
  rm -rf "$TMPD"
}

sha() { printf '%040d' "$1"; }
enqueue() { python3 "$BROKER" --db "$QA_QUEUE_DB" enqueue "$@" >/dev/null; }

@test "digest: an empty queue renders a line with every metric" {
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"QA queue"* ]]
  [[ "$output" == *"depth 0"* ]]
  [[ "$output" == *"wait p50"* ]]
  [[ "$output" == *"p95"* ]]
  [[ "$output" == *"verdicts/h"* ]]
  [[ "$output" == *"dead 0"* ]]
  [[ "$output" == *"lost 0"* ]]
}

@test "digest: a queued job shows up in depth and oldest age" {
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth 1"* ]]
}

@test "digest: verdicts are broken out by kind" {
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  enqueue Muso-AI/hydra 2 "$(sha 2)" U123ABC
  python3 "$BROKER" --db "$QA_QUEUE_DB" claim w1 >/dev/null
  python3 "$BROKER" --db "$QA_QUEUE_DB" finish 1 w1 go >/dev/null
  python3 "$BROKER" --db "$QA_QUEUE_DB" claim w2 >/dev/null
  python3 "$BROKER" --db "$QA_QUEUE_DB" finish 2 w2 no_go >/dev/null
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"go 1"* ]]
  [[ "$output" == *"no-go 1"* ]]
}

@test "digest: a lost job pages" {
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  enqueue Muso-AI/hydra 2 "$(sha 2)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOST"* ]]
}

@test "digest: depth above the limit pages" {
  export QA_DIGEST_DEPTH=2
  for i in 1 2 3; do enqueue Muso-AI/hydra "$i" "$(sha "$i")" U123ABC; done
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs attention"* ]]
  [[ "$output" == *"depth 3 > 2"* ]]
}

@test "digest: a dead job pages" {
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET status='dead', last_error='exhausted'")
c.commit()
PY
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dead job"* ]]
}

@test "digest: p95 pages only on the second consecutive hour" {
  # A single slow hour is a burst; two is a trend. The streak is persisted.
  export QA_DIGEST_P95_S=0
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  # Backdate the arrival so the measured wait is deterministically non-zero: a
  # claim+finish inside the same second records wait 0 and would never cross a
  # p95 limit of 0.
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 120, queued_at = queued_at - 120")
c.commit()
PY
  python3 "$BROKER" --db "$QA_QUEUE_DB" claim w1 >/dev/null
  python3 "$BROKER" --db "$QA_QUEUE_DB" finish 1 w1 go >/dev/null
  # First hour: no page yet.
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"consecutive hours"* ]]
  # Second hour: page.
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"consecutive hours"* ]]
}

@test "digest: an unreachable broker says UNKNOWN, never empty" {
  export QA_BROKER_URL=http://127.0.0.1:1
  run "$DIGEST" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" != *"depth 0"* ]]
}

@test "digest: a loss older than the window still pages, once" {
  # lost_window only sees arrivals inside the window, so a row enqueued more
  # than an hour ago that disappears NOW is invisible to it: lost_total goes to
  # 1 while lost_window stays 0, and because the arrival is outside every future
  # window it would never page at all.
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  enqueue Muso-AI/hydra 2 "$(sha 2)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Age the arrival past the window, then lose it.
# Age BOTH the job and its arrival event: lost_window counts arrivals from
# the append-only events log, so ageing only the job leaves the arrival inside
# the window and the test would pass for the wrong reason.
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 7200 WHERE pr=2")
c.execute("UPDATE events SET at = at - 7200 WHERE kind='enqueue'")
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOST"* ]]
  [[ "$output" == *"in total"* ]]
}

@test "digest: the same aged loss does not page twice" {
  # lost_total never decreases, so paging on it unconditionally would page
  # forever after one incident and train people to ignore the channel.
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  enqueue Muso-AI/hydra 2 "$(sha 2)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Age BOTH the job and its arrival event: lost_window counts arrivals from
# the append-only events log, so ageing only the job leaves the arrival inside
# the window and the test would pass for the wrong reason.
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 7200 WHERE pr=2")
c.execute("UPDATE events SET at = at - 7200 WHERE kind='enqueue'")
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOST"* ]]
  # A dry run must NOT acknowledge: it delivered nothing, so the loss is still
  # news. Seed the acknowledgement the way a successful post would, then the
  # same loss is no longer news.
  python3 - "$QA_DIGEST_STATE" <<'PY'
import json, sys
path = sys.argv[1]
st = json.load(open(path))
st["lost_paged_total"] = 1
json.dump(st, open(path, "w"))
PY
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"in total"* ]]
}

@test "digest: a failed Slack send exits non-zero and does not acknowledge the loss" {
  # The digest is the only thing watching the queue, so a silently dropped post
  # is indistinguishable from a healthy queue. slack_notify cannot report
  # failure (it ends in `|| true`), so the digest uses the checked primitive.
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  enqueue Muso-AI/hydra 2 "$(sha 2)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 7200 WHERE pr=2")
c.execute("UPDATE events SET at = at - 7200 WHERE kind='enqueue'")
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  # No Slack credentials in the test environment, so delivery fails.
  run "$DIGEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED to post"* ]]
  # The loss must still be news on the next run.
  python3 - "$QA_DIGEST_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
assert int(st.get("lost_paged_total") or 0) == 0, st
PY
}

@test "digest: a NEW aged loss pages again after an earlier one was paged" {
  enqueue Muso-AI/hydra 1 "$(sha 1)" U123ABC
  enqueue Muso-AI/hydra 2 "$(sha 2)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Age BOTH the job and its arrival event: lost_window counts arrivals from
# the append-only events log, so ageing only the job leaves the arrival inside
# the window and the test would pass for the wrong reason.
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 7200 WHERE pr=2")
c.execute("UPDATE events SET at = at - 7200 WHERE kind='enqueue'")
c.execute("DELETE FROM jobs WHERE pr=2")
c.commit()
PY
  run "$DIGEST" --dry-run
  [[ "$output" == *"LOST"* ]]
  # A second, separate loss must still be news.
  enqueue Muso-AI/hydra 3 "$(sha 3)" U123ABC
  python3 - "$QA_QUEUE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Age BOTH the job and its arrival event: lost_window counts arrivals from
# the append-only events log, so ageing only the job leaves the arrival inside
# the window and the test would pass for the wrong reason.
c.execute("UPDATE jobs SET enqueued_at = enqueued_at - 7200 WHERE pr=3")
c.execute("UPDATE events SET at = at - 7200 WHERE kind='enqueue'")
c.execute("DELETE FROM jobs WHERE pr=3")
c.commit()
PY
  run "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOST"* ]]
}
