#!/usr/bin/env bats
# Tests for scripts/jev-shadow-report.sh against a hand-built fixture JSONL
# covering two surfaces, noul/choice/score answer types, a null `actual`,
# an rc=2 (failed call) line, and one malformed line. Agreement numbers below
# are computed by hand in the comments next to each fixture line so the
# assertions are auditable, not just copied from a first run.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REPORT="$HYDRA_REPO/scripts/jev-shadow-report.sh"
FIXTURE_DIR="$HYDRA_REPO/scripts/tests/fixtures/jev"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "two-surface fixture: buckets, agreement, footer" {
  run "$REPORT" --router-agreement --shadow-dir "$FIXTURE_DIR"
  [ "$status" -eq 0 ]

  # refund-gate / is_eligible:
  #   a1 noul=0.92 -> "true", actual "true"  -> bucket 0.9-1.0, match
  #   a2 noul=0.55 -> "true", actual "false" -> bucket 0.5-0.6, mismatch
  #   a3 noul=0.97 -> "true", actual null    -> bucket 0.9-1.0, unjudged
  #   a4 rc=2, answers null -> contributes nothing to buckets
  #   => bucket 0.5-0.6: n=1 agreement 0/1=0.0%
  #      bucket 0.9-1.0: n=2 agreement 1/1=100.0% (only a1 judged)
  #   footer: total=4 rc_nonzero=1 (a4) latencies [100,150,120,1600] sorted
  #     [100,120,150,1600], n=4, nearest-rank idx=ceil(p*n)-1:
  #     p50 idx=ceil(0.5*4)-1=1 -> 120, p95 idx=ceil(0.95*4)-1=3 -> 1600
  [[ "$output" == *"== refund-gate =="* ]]
  [[ "$output" == *"question: is_eligible"* ]]
  [[ "$output" == *"0.5-0.6   1   0.0%"* ]]
  [[ "$output" == *"0.9-1.0   2   100.0%"* ]]
  [[ "$output" == *"total=4 rc_nonzero=1 p50_ms=120 p95_ms=1600"* ]]

  # ticket-triage / category:
  #   b1 choice=billing prob=0.81 actual "billing" -> bucket 0.8-0.9, match
  #   b2 choice=account prob=0.75 actual "billing"  -> bucket 0.7-0.8, mismatch
  #   ticket-triage / urgency:
  #   b3 score=2 -> legend "high" prob=0.92 actual "high" -> bucket 0.9-1.0, match
  #   footer: total=3 rc_nonzero=0 latencies [90,110,200], n=3,
  #     nearest-rank idx=ceil(p*n)-1: p50 idx=ceil(0.5*3)-1=1 -> 110,
  #     p95 idx=ceil(0.95*3)-1=2 -> 200
  [[ "$output" == *"== ticket-triage =="* ]]
  [[ "$output" == *"question: category"* ]]
  [[ "$output" == *"0.7-0.8   1   0.0%"* ]]
  [[ "$output" == *"0.8-0.9   1   100.0%"* ]]
  [[ "$output" == *"question: urgency"* ]]
  [[ "$output" == *"0.9-1.0   1   100.0%"* ]]
  [[ "$output" == *"total=3 rc_nonzero=0 p50_ms=110 p95_ms=200"* ]]
}

@test "--surface filters to one surface only" {
  run "$REPORT" --shadow-dir "$FIXTURE_DIR" --surface ticket-triage
  [ "$status" -eq 0 ]
  [[ "$output" == *"== ticket-triage =="* ]]
  [[ "$output" != *"== refund-gate =="* ]]
}

@test "malformed line is counted and skipped, never crashes" {
  # The fixture file itself contains one non-JSON line; a clean rc 0 and the
  # rest of the surface's numbers rendering correctly IS the assertion that
  # it was skipped rather than aborting the read.
  run "$REPORT" --shadow-dir "$FIXTURE_DIR" --surface refund-gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"malformed_rows=1"* ]]
}

@test "empty shadow dir: no shadow lines, rc 0" {
  mkdir -p "$TEST_TMPDIR/empty"
  run "$REPORT" --shadow-dir "$TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no shadow lines"* ]]
}

@test "--window-hours excludes rows outside the window" {
  cat > "$TEST_TMPDIR/windowed.jsonl" <<EOF
{"ts":"2020-01-01T00:00:00Z","surface":"windowed","item_id":"old","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.9}},"usage":null,"latency_ms":50,"actual":"true","rc":0,"http":200}
EOF
  run "$REPORT" --router-agreement --shadow-dir "$TEST_TMPDIR" --surface windowed --window-hours 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no shadow lines"* ]]
}

@test "actual as an object is compared per question, not as one string" {
  local d; d="$(mktemp -d)"
  # one call, two questions; actual carries a per-question label:
  #   a noul=0.92 -> "true", actual.a "true"      -> 0.9-1.0 match
  #   b choice=x prob=0.85, actual.b "y"          -> 0.8-0.9 mismatch
  cat > "$d/multi.jsonl" <<'J'
{"ts":"2026-09-17T00:00:00Z","surface":"multi","item_id":"m1","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"a":{"type":"noul","noul":0.92},"b":{"type":"choice","choice":"x","confidence":0.8,"probabilities":{"x":0.85,"y":0.15}}},"usage":null,"latency_ms":50,"actual":{"a":"true","b":"y"},"rc":0,"http":200}
J
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface multi
  [ "$status" -eq 0 ]
  [[ "$output" == *"question: a"* ]]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" =~ 0\.8-0\.9[[:space:]]+1[[:space:]]+0\.0% ]]
  rm -rf "$d"
}

@test "windowed report excludes rows with a missing or unparseable ts; unwindowed keeps them" {
  local d; d="$(mktemp -d)"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$d/undated.jsonl" <<J
{"ts":"$now","surface":"undated","item_id":"fresh","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.9}},"usage":null,"latency_ms":50,"actual":"true","rc":0,"http":200}
{"ts":null,"surface":"undated","item_id":"nots","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.9}},"usage":null,"latency_ms":50,"actual":"false","rc":0,"http":200}
{"ts":"not-a-time","surface":"undated","item_id":"badts","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.9}},"usage":null,"latency_ms":50,"actual":"false","rc":0,"http":200}
J
  # windowed: only the fresh row counts -> n=1, 100% agreement, 2 excluded
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface undated --window-hours 1
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"total=1"* ]]
  [[ "$output" == *"undated_excluded=2"* ]]
  # unwindowed: all three rows are valid data -> n=3, 1 of 3 agree
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface undated
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+3[[:space:]]+33\.3% ]]
  [[ "$output" == *"total=3"* ]]
  [[ "$output" != *"undated_excluded"* ]]
  rm -rf "$d"
}

@test "a malformed answer is skipped, never aborts the report" {
  local d; d="$(mktemp -d)"
  # row 1: string probability (vendor drift); row 2: probability out of range;
  # row 3: answer is not an object; row 4: healthy noul -> the only bucketed row
  cat > "$d/bad.jsonl" <<'J'
{"ts":"2026-09-17T00:00:00Z","surface":"bad","item_id":"s1","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"choice","choice":"x","confidence":0.8,"probabilities":{"x":"0.9"}}},"usage":null,"latency_ms":50,"actual":"x","rc":0,"http":200}
{"ts":"2026-09-17T00:00:00Z","surface":"bad","item_id":"s2","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":1.7}},"usage":null,"latency_ms":50,"actual":"true","rc":0,"http":200}
{"ts":"2026-09-17T00:00:00Z","surface":"bad","item_id":"s3","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":"not-an-object"},"usage":null,"latency_ms":50,"actual":"true","rc":0,"http":200}
{"ts":"2026-09-17T00:00:00Z","surface":"bad","item_id":"s4","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.92}},"usage":null,"latency_ms":50,"actual":"true","rc":0,"http":200}
J
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface bad
  [ "$status" -eq 0 ]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"total=4"* ]]
  rm -rf "$d"
}

@test "--surface path traversal: rc 2, invalid message" {
  run "$REPORT" --shadow-dir "$FIXTURE_DIR" --surface ../x
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --surface"* ]]
}

@test "multi-class choice/score winners below 0.5 land in the 0.0-0.5 bucket" {
  local d; d="$(mktemp -d)"
  # 11-way router intent, question "intent":
  #   c1 winner prob=0.30 actual == winner -> match,    bucket 0.0-0.5
  #   c2 winner prob=0.45 actual != winner -> mismatch, bucket 0.0-0.5
  #   c3 winner prob=0.62 actual == winner -> match,     bucket 0.6-0.7
  #   => 0.0-0.5: n=2, agreement 1/2=50.0%
  #      0.6-0.7: n=1, agreement 1/1=100.0%
  # plus a Score row whose top probability is 0.40 (multi-outcome score),
  # actual == legend["1"] -> match, bucket 0.0-0.5, 100%
  cat > "$d/multiclass.jsonl" <<'J'
{"ts":"2026-09-17T00:00:00Z","surface":"multiclass","item_id":"c1","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"intent":{"type":"choice","choice":"opt1","probabilities":{"opt1":0.30,"opt2":0.15,"opt3":0.10,"opt4":0.09,"opt5":0.08,"opt6":0.07,"opt7":0.06,"opt8":0.05,"opt9":0.04,"opt10":0.03,"opt11":0.03}}},"usage":null,"latency_ms":50,"actual":"opt1","rc":0,"http":200}
{"ts":"2026-09-17T00:05:00Z","surface":"multiclass","item_id":"c2","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"intent":{"type":"choice","choice":"opt1","probabilities":{"opt1":0.45,"opt2":0.20,"opt3":0.08,"opt4":0.07,"opt5":0.06,"opt6":0.05,"opt7":0.03,"opt8":0.02,"opt9":0.02,"opt10":0.01,"opt11":0.01}}},"usage":null,"latency_ms":50,"actual":"opt2","rc":0,"http":200}
{"ts":"2026-09-17T00:10:00Z","surface":"multiclass","item_id":"c3","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"intent":{"type":"choice","choice":"opt1","probabilities":{"opt1":0.62,"opt2":0.10,"opt3":0.06,"opt4":0.05,"opt5":0.04,"opt6":0.04,"opt7":0.03,"opt8":0.02,"opt9":0.02,"opt10":0.01,"opt11":0.01}}},"usage":null,"latency_ms":50,"actual":"opt1","rc":0,"http":200}
{"ts":"2026-09-17T00:15:00Z","surface":"multiclass","item_id":"c4","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"scoreq":{"type":"score","score":1.1,"legend":{"0":"low","1":"medium","2":"high"},"probabilities":{"0":0.35,"1":0.40,"2":0.25}}},"usage":null,"latency_ms":50,"actual":"medium","rc":0,"http":200}
J
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface multiclass
  [ "$status" -eq 0 ]
  [[ "$output" == *"question: intent"* ]]
  [[ "$output" =~ 0\.0-0\.5[[:space:]]+2[[:space:]]+50\.0% ]]
  [[ "$output" =~ 0\.6-0\.7[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"question: scoreq"* ]]
  [[ "$output" =~ 0\.0-0\.5[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"total=4"* ]]
  rm -rf "$d"
}

@test "malformed-but-valid-JSON rows are counted and skipped, later rows still render" {
  local d; d="$(mktemp -d)"
  # Each row below is valid JSON but fails row_ok on a different field --
  # the same bug class as the unhashable-list `surface` the QA bot found,
  # generalized instead of patched one field at a time. Only the final
  # healthy row should reach the bucket table.
  cat > "$d/guard.jsonl" <<'J'
{"surface":[],"ts":"2026-09-21T00:00:00Z","rc":0}
{"surface":"guard","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.9}},"actual":"true","rc":0,"latency_ms":"50"}
{"surface":"guard","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.9}},"actual":"true","rc":"0","latency_ms":50}
{"surface":"guard","ts":"2026-09-21T00:00:00Z","answers":[],"actual":"true","rc":0,"latency_ms":50}
{"surface":"guard","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.9}},"actual":7,"rc":0,"latency_ms":50}
{"surface":"","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.9}},"actual":"true","rc":0,"latency_ms":50}
{"surface":"guard","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.92}},"actual":"true","rc":0,"latency_ms":50}
J
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface guard
  [ "$status" -eq 0 ]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"total=1"* ]]
  [[ "$output" == *"malformed_rows=6"* ]]
  rm -rf "$d"
}

@test "score top answer is argmax(probabilities), not round(score)" {
  local d; d="$(mktemp -d)"
  # TypeSafe's `score` is the probability-weighted MEAN, so a bimodal
  # distribution can carry a rounded score with ZERO probability at that
  # level -- round(score) must never be used to pick the top answer.
  #   d1: score=1.0, probabilities {"0":0.5,"1":0.0,"2":0.5} -- round(1.0)="1"
  #       would pick legend["1"]="medium" at probability 0. Argmax ties at
  #       0.5 between "0" and "2"; tie-break picks the lower key "0" ->
  #       legend["0"]="low". actual=legend["1"]="medium" -> mismatch,
  #       bucket 0.5-0.6 (prob 0.5).
  #   d2: score=0.9, probabilities {"0":0.2,"1":0.7,"2":0.1} -- round(0.9)="1"
  #       agrees with argmax here (key "1", prob 0.7) -> legend["1"]="medium",
  #       actual="medium" -> match, bucket 0.7-0.8.
  cat > "$d/scoreargmax.jsonl" <<'J'
{"ts":"2026-09-17T00:00:00Z","surface":"scoreargmax","item_id":"d1","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"scoreq":{"type":"score","score":1.0,"legend":{"0":"low","1":"medium","2":"high"},"probabilities":{"0":0.5,"1":0.0,"2":0.5}}},"usage":null,"latency_ms":50,"actual":"medium","rc":0,"http":200}
{"ts":"2026-09-17T00:05:00Z","surface":"scoreargmax","item_id":"d2","state_sha256":"x","questions_sha256":"y","model":"jev-1.13.0","answers":{"scoreq":{"type":"score","score":0.9,"legend":{"0":"low","1":"medium","2":"high"},"probabilities":{"0":0.2,"1":0.7,"2":0.1}}},"usage":null,"latency_ms":50,"actual":"medium","rc":0,"http":200}
J
  run "$REPORT" --router-agreement --shadow-dir "$d" --surface scoreargmax
  [ "$status" -eq 0 ]
  [[ "$output" == *"question: scoreq"* ]]
  [[ "$output" =~ 0\.5-0\.6[[:space:]]+1[[:space:]]+0\.0% ]]
  [[ "$output" =~ 0\.7-0\.8[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"total=2"* ]]
  rm -rf "$d"
}

@test "--surface refund-gate still works against the fixture dir" {
  run "$REPORT" --shadow-dir "$FIXTURE_DIR" --surface refund-gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"== refund-gate =="* ]]
  [[ "$output" != *"== ticket-triage =="* ]]
}

@test "pctile nearest-rank: single-row surface, p50 and p95 both equal that row's latency" {
  local d; d="$(mktemp -d)"
  cat > "$d/solo.jsonl" <<'J'
{"surface":"solo","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.92}},"actual":"true","rc":0,"latency_ms":77}
J
  run "$REPORT" --shadow-dir "$d" --surface solo
  [ "$status" -eq 0 ]
  # n=1: p50 idx=ceil(0.5*1)-1=0, p95 idx=ceil(0.95*1)-1=0 -> both sorted[0]=77
  [[ "$output" == *"total=1 rc_nonzero=0 p50_ms=77 p95_ms=77"* ]]
  rm -rf "$d"
}

@test "pctile nearest-rank: two-row surface, p95 picks the upper-tail row" {
  local d; d="$(mktemp -d)"
  cat > "$d/pair.jsonl" <<'J'
{"surface":"pair","ts":"2026-09-21T00:00:00Z","answers":{"q":{"type":"noul","noul":0.92}},"actual":"true","rc":0,"latency_ms":10}
{"surface":"pair","ts":"2026-09-21T00:05:00Z","answers":{"q":{"type":"noul","noul":0.92}},"actual":"true","rc":0,"latency_ms":1000}
J
  run "$REPORT" --shadow-dir "$d" --surface pair
  [ "$status" -eq 0 ]
  # sorted [10,1000], n=2: p50 idx=ceil(0.5*2)-1=0 -> 10,
  # p95 idx=ceil(0.95*2)-1=ceil(1.9)-1=1 -> 1000
  [[ "$output" == *"total=2 rc_nonzero=0 p50_ms=10 p95_ms=1000"* ]]
  rm -rf "$d"
}

@test "footer breaks failures down by reason, counting rows with no reason as unknown (MUS-3191)" {
  cat > "$TEST_TMPDIR/caroline.jsonl" <<'J'
{"ts":"2026-10-05T08:00:00Z","surface":"caroline","item_id":"a","answers":null,"latency_ms":1500,"actual":"none","rc":2,"http":null,"reason":"timeout"}
{"ts":"2026-10-05T08:01:00Z","surface":"caroline","item_id":"b","answers":null,"latency_ms":1500,"actual":"none","rc":2,"http":null,"reason":"timeout"}
{"ts":"2026-10-05T08:02:00Z","surface":"caroline","item_id":"c","answers":null,"latency_ms":20,"actual":"none","rc":3,"http":200,"reason":"shape"}
{"ts":"2026-10-05T08:03:00Z","surface":"caroline","item_id":"d","answers":null,"latency_ms":20,"actual":"none","rc":2,"http":null}
J
  run "$REPORT" --shadow-dir "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failures by reason [v1-legacy]: shape=1 timeout=2 unknown=1"* ]]
}

@test "footer is split per questions_version; unversioned rows are v1-legacy, never pooled into v1 (MUS-3193)" {
  cat > "$TEST_TMPDIR/caroline.jsonl" <<'J'
{"ts":"2026-10-05T08:00:00Z","surface":"caroline","answers":{"q":{"type":"noul","noul":0.9}},"latency_ms":100,"actual":"true","rc":0,"questions_version":"v1"}
{"ts":"2026-10-05T08:01:00Z","surface":"caroline","answers":null,"latency_ms":200,"actual":"none","rc":2,"reason":"timeout","questions_version":"v1"}
{"ts":"2026-10-05T08:02:00Z","surface":"caroline","answers":{"q":{"type":"noul","noul":0.9}},"latency_ms":100,"actual":"true","rc":0,"questions_version":"v2"}
{"ts":"2026-10-05T08:03:00Z","surface":"caroline","answers":null,"latency_ms":300,"actual":"none","rc":2,"reason":"timeout","questions_version":"v2"}
{"ts":"2026-10-05T08:04:00Z","surface":"caroline","answers":null,"latency_ms":300,"actual":"none","rc":3,"questions_version":"v2"}
{"ts":"2026-10-05T08:05:00Z","surface":"caroline","answers":null,"latency_ms":50,"actual":"none","rc":3}
J
  run "$REPORT" --shadow-dir "$TEST_TMPDIR" --surface caroline
  [ "$status" -eq 0 ]
  # v1: 2 rows, 1 failure; v2: 3 rows, 2 failures; unversioned: 1 row, 1 failure
  [[ "$output" == *"footer [v1]: total=2 rc_nonzero=1 "* ]]
  [[ "$output" == *"footer [v2]: total=3 rc_nonzero=2 "* ]]
  [[ "$output" == *"footer [v1-legacy]: total=1 rc_nonzero=1 "* ]]
  # per-version failure rate and reason breakdown (missing reason -> unknown)
  [[ "$output" == *"[v1]: total=2 rc_nonzero=1 "*"failure_rate=50.0%"* ]]
  [[ "$output" == *"failures by reason [v2]: timeout=1 unknown=1"* ]]
  [[ "$output" == *"failures by reason [v1-legacy]: unknown=1"* ]]
}

# ─── --outcomes: join real ground truth instead of the router's own action ───
# These fixtures are built inline (never under scripts/tests/fixtures/jev/,
# per MUS-1542's diff-scope constraint) using the sidecar shape from the
# MUS-1481 shared contract: {surface, item_id, row_ts:[...], truth:{qid:val}}.

@test "outcomes: matching truth agrees 100%, mismatching truth is 0%" {
  local d; d="$(mktemp -d)"
  # e1 first_tool choice=profile_status prob=0.90 -> bucket 0.9-1.0;
  #    outcome truth.first_tool="profile_status" -> match, 100.0%
  # e2 first_tool choice=profile_status prob=0.85 -> bucket 0.8-0.9;
  #    outcome truth.first_tool="other_tool" -> mismatch, 0.0%
  # both rows join a truth record -> outcomes_rows=2 outcomes_matched=2
  cat > "$d/outc1.jsonl" <<'J'
{"ts":"T1","surface":"outc1","item_id":"i1","answers":{"first_tool":{"type":"choice","choice":"profile_status","probabilities":{"profile_status":0.90,"other":0.10}}},"actual":"route","rc":0,"latency_ms":100}
{"ts":"T2","surface":"outc1","item_id":"i2","answers":{"first_tool":{"type":"choice","choice":"profile_status","probabilities":{"profile_status":0.85,"other":0.15}}},"actual":"route","rc":0,"latency_ms":100}
J
  cat > "$d/outcomes.jsonl" <<'J'
{"v":1,"surface":"outc1","item_id":"i1","row_ts":["T1"],"truth":{"first_tool":"profile_status"}}
{"v":1,"surface":"outc1","item_id":"i2","row_ts":["T2"],"truth":{"first_tool":"other_tool"}}
J
  run "$REPORT" --shadow-dir "$d" --surface outc1 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"question: first_tool"* ]]
  [[ "$output" =~ 0\.8-0\.9[[:space:]]+1[[:space:]]+0\.0% ]]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"labelled=2 unlabelled=0"* ]]
  [[ "$output" == *"total=2"* ]]
  [[ "$output" == *"outcomes_rows=2 outcomes_matched=2"* ]]
  rm -rf "$d"
}

@test "outcomes: two shadow rows sharing one turn both pick up the same truth (v1/v2 pair)" {
  local d; d="$(mktemp -d)"
  # one outcome record's row_ts lists both Ta (v1) and Tb (v2) -- the common
  # production case of a live call and its shadow twin firing on one turn.
  # both choices agree with truth -> both 100.0%, but 1 outcome record joins
  # 2 shadow rows -> outcomes_rows=1 outcomes_matched=2 (not 2 and 2).
  cat > "$d/outc2.jsonl" <<'J'
{"ts":"Ta","surface":"outc2","item_id":"iX","answers":{"first_tool":{"type":"choice","choice":"ticket_open","probabilities":{"ticket_open":0.95,"other":0.05}}},"actual":"route","rc":0,"latency_ms":100}
{"ts":"Tb","surface":"outc2","item_id":"iX","answers":{"first_tool":{"type":"choice","choice":"ticket_open","probabilities":{"ticket_open":0.72,"other":0.28}}},"actual":"decline","rc":0,"latency_ms":100}
J
  cat > "$d/outcomes.jsonl" <<'J'
{"v":1,"surface":"outc2","item_id":"iX","row_ts":["Ta","Tb"],"truth":{"first_tool":"ticket_open"}}
J
  run "$REPORT" --shadow-dir "$d" --surface outc2 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.7-0\.8[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"labelled=2 unlabelled=0"* ]]
  [[ "$output" == *"total=2"* ]]
  [[ "$output" == *"outcomes_rows=1 outcomes_matched=2"* ]]
  rm -rf "$d"
}

@test "outcomes: a row with no matching outcome record is unlabelled, excluded from agreement" {
  local d; d="$(mktemp -d)"
  # outcomes.jsonl has no record for (outc3, iY, Tc) at all -> no join ->
  # judged=[] -> agreement "n/a", labelled=0 unlabelled=1, outcomes_matched=0
  cat > "$d/outc3.jsonl" <<'J'
{"ts":"Tc","surface":"outc3","item_id":"iY","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.65,"b":0.35}}},"actual":"a","rc":0,"latency_ms":100}
J
  : > "$d/outcomes.jsonl"
  run "$REPORT" --shadow-dir "$d" --surface outc3 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.6-0\.7[[:space:]]+1[[:space:]]+n/a ]]
  [[ "$output" == *"labelled=0 unlabelled=1"* ]]
  [[ "$output" == *"total=1"* ]]
  [[ "$output" == *"outcomes_rows=0 outcomes_matched=0"* ]]
  rm -rf "$d"
}

@test "outcomes: an outcome record whose truth omits the question is unlabelled" {
  local d; d="$(mktemp -d)"
  # the record joins (matched=1) but truth has no "q1" key -> actual_q=None,
  # same unlabelled outcome as no-record-at-all, but outcomes_matched=1 this
  # time since a truth record WAS found for (surface, item_id, ts).
  cat > "$d/outc4.jsonl" <<'J'
{"ts":"Td","surface":"outc4","item_id":"iZ","answers":{"q1":{"type":"choice","choice":"a","probabilities":{"a":0.65,"b":0.35}}},"actual":"a","rc":0,"latency_ms":100}
J
  cat > "$d/outcomes.jsonl" <<'J'
{"v":1,"surface":"outc4","item_id":"iZ","row_ts":["Td"],"truth":{"other_question":"x"}}
J
  run "$REPORT" --shadow-dir "$d" --surface outc4 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.6-0\.7[[:space:]]+1[[:space:]]+n/a ]]
  [[ "$output" == *"labelled=0 unlabelled=1"* ]]
  [[ "$output" == *"outcomes_rows=1 outcomes_matched=1"* ]]
  rm -rf "$d"
}

@test "outcomes: actual is ignored completely -- agreement computed only against outcomes truth" {
  local d; d="$(mktemp -d)"
  # This is the regression test for the bug MUS-1542 fixes: row["actual"] is
  # the router's own action ("route") and shares no vocabulary with the
  # question's answers. If the report ever fell back to it, "profile_status"
  # (the choice) vs "route" (actual) would mismatch -> 0.0%. With the fix,
  # comparison is choice "profile_status" vs truth.first_tool "profile_status"
  # -> match, 100.0%, and "route" never appears in the output.
  cat > "$d/outc5.jsonl" <<'J'
{"ts":"Te","surface":"outc5","item_id":"iW","answers":{"first_tool":{"type":"choice","choice":"profile_status","probabilities":{"profile_status":0.88,"route":0.12}}},"actual":"route","rc":0,"latency_ms":100}
J
  cat > "$d/outcomes.jsonl" <<'J'
{"v":1,"surface":"outc5","item_id":"iW","row_ts":["Te"],"truth":{"first_tool":"profile_status"}}
J
  run "$REPORT" --shadow-dir "$d" --surface outc5 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.8-0\.9[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"labelled=1 unlabelled=0"* ]]
  [[ "$output" != *"route"* ]]
  rm -rf "$d"
}

@test "outcomes: a genuine v1/v2 pair splits outcomes_matched per questions_version (MUS-3193)" {
  local d; d="$(mktemp -d)"
  # One turn, two calls: the live v1 call and its v2 shadow twin, joined by one
  # outcome record. Each row lands in its OWN (surface, questions_version)
  # bucket, so each bucket's footer matched exactly ONE row -- not two. A
  # surface-keyed counter prints outcomes_matched=2 under BOTH footers, which is
  # precisely the live/shadow pooling this card exists to remove. The existing
  # "(v1/v2 pair)" test cannot catch this: its fixture rows carry no
  # questions_version at all, so both land in v1-legacy and its assertion is
  # vacuous.
  cat > "$d/outc3.jsonl" <<'J'
{"ts":"Ta","surface":"outc3","item_id":"iX","questions_version":"v1","answers":{"first_tool":{"type":"choice","choice":"ticket_open","probabilities":{"ticket_open":0.95,"other":0.05}}},"actual":"route","rc":0,"latency_ms":100}
{"ts":"Tb","surface":"outc3","item_id":"iX","questions_version":"v2","answers":{"first_tool":{"type":"choice","choice":"ticket_open","probabilities":{"ticket_open":0.72,"other":0.28}}},"actual":"decline","rc":0,"latency_ms":100}
J
  cat > "$d/outcomes.jsonl" <<'J'
{"v":1,"surface":"outc3","item_id":"iX","row_ts":["Ta","Tb"],"truth":{"first_tool":"ticket_open"}}
J
  run "$REPORT" --shadow-dir "$d" --surface outc3 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  # one shadow row per version bucket
  [[ "$output" == *"footer [v1]: total=1 "* ]]
  [[ "$output" == *"footer [v2]: total=1 "* ]]
  # outcomes_matched is bucket-scoped: exactly 1 under each of the two footers, never 2
  [[ "$output" != *"outcomes_matched=2"* ]]
  [ "$(grep -c 'outcomes_matched=1' <<<"$output")" -eq 2 ]
  # outcomes_rows stays surface-scoped on purpose -- the sidecar record carries
  # no questions_version, so the same 1 is correct under both footers
  [ "$(grep -c 'outcomes_rows=1' <<<"$output")" -eq 2 ]
  rm -rf "$d"
}

@test "outcomes: a malformed outcomes line is counted, report still exits 0" {
  local d; d="$(mktemp -d)"
  cat > "$d/outc6.jsonl" <<'J'
{"ts":"Tf","surface":"outc6","item_id":"iV","answers":{"q":{"type":"noul","noul":0.9}},"actual":"true","rc":0,"latency_ms":50}
J
  # line 1: not JSON at all
  # line 2: valid JSON, valid outcome_row_ok fields except "truth" is missing
  #         entirely -- fails outcome_row_ok, counted malformed
  # line 3: well-formed, matches the shadow row -> truth.q="true" agrees with
  #         noul=0.9 -> "true" (100.0%, bucket 0.9-1.0)
  cat > "$d/outcomes.jsonl" <<'J'
this is not json
{"v":1,"surface":"outc6","item_id":"iV","row_ts":["x"]}
{"v":1,"surface":"outc6","item_id":"iV","row_ts":["Tf"],"truth":{"q":"true"}}
J
  run "$REPORT" --shadow-dir "$d" --surface outc6 --outcomes "$d/outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" =~ 0\.9-1\.0[[:space:]]+1[[:space:]]+100\.0% ]]
  [[ "$output" == *"total=1"* ]]
  [[ "$output" == *"malformed_rows=2"* ]]
  [[ "$output" == *"outcomes_rows=1 outcomes_matched=1"* ]]
  rm -rf "$d"
}

@test "no --outcomes: output is unchanged, no labelled/unlabelled or outcomes_* fields" {
  # Re-runs the primary two-surface fixture without --outcomes and checks the
  # same pre-existing numbers from the first test in this file still hold,
  # plus that none of the new --outcomes-only output appears.
  run "$REPORT" --router-agreement --shadow-dir "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.9-1.0   2   100.0%"* ]]
  [[ "$output" == *"total=4 rc_nonzero=1 p50_ms=120 p95_ms=1600"* ]]
  [[ "$output" != *"labelled="* ]]
  [[ "$output" != *"unlabelled="* ]]
  [[ "$output" != *"outcomes_rows="* ]]
  [[ "$output" != *"outcomes_matched="* ]]
}

# ─── sidecar inside the shadow dir must not be read as a shadow log ───
# jev-outcomes-collect.py writes caroline.outcomes.jsonl INTO the shadow dir,
# and the all-surface glob is *.jsonl, so without an explicit exclusion the
# truth file is ingested a second time as shadow rows. It carries `surface`,
# so row_ok accepts it: no crash, just an inflated total.

_outcomes_in_shadow_dir_fixture() {
  d="$(mktemp -d)"
  cat > "$d/caroline.jsonl" <<'J'
{"ts":"T1","surface":"outc1","item_id":"i1","answers":{"first_tool":{"type":"choice","choice":"profile_status","probabilities":{"profile_status":0.90,"other":0.10}}},"actual":"route","rc":0,"latency_ms":100}
{"ts":"T2","surface":"outc1","item_id":"i2","answers":{"first_tool":{"type":"choice","choice":"profile_status","probabilities":{"profile_status":0.85,"other":0.15}}},"actual":"route","rc":0,"latency_ms":100}
J
  cat > "$d/caroline.outcomes.jsonl" <<'J'
{"v":1,"surface":"outc1","item_id":"i1","row_ts":["T1"],"truth":{"first_tool":"profile_status"}}
{"v":1,"surface":"outc1","item_id":"i2","row_ts":["T2"],"truth":{"first_tool":"other_tool"}}
J
}

@test "outcomes inside shadow dir, no --surface: total counts shadow rows only" {
  local d; _outcomes_in_shadow_dir_fixture
  run "$REPORT" --shadow-dir "$d" --outcomes "$d/caroline.outcomes.jsonl"
  [ "$status" -eq 0 ]
  # 2 shadow rows; the 2 sidecar records must not be added (would be total=4).
  [[ "$output" == *"total=2 "* ]]
  [[ "$output" == *"outcomes_rows=2 outcomes_matched=2"* ]]
  [[ "$output" == *"labelled=2 unlabelled=0"* ]]
  rm -rf "$d"
}

@test "outcomes inside shadow dir given as a relative path is still excluded" {
  local d; _outcomes_in_shadow_dir_fixture
  cd "$d"
  run "$REPORT" --shadow-dir "$d" --outcomes "./caroline.outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=2 "* ]]
  [[ "$output" == *"outcomes_matched=2"* ]]
  rm -rf "$d"
}

@test "outcomes inside shadow dir via a symlinked shadow dir is still excluded" {
  local d; _outcomes_in_shadow_dir_fixture
  ln -s "$d" "$d.link"
  run "$REPORT" --shadow-dir "$d.link" --outcomes "$d/caroline.outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=2 "* ]]
  rm -rf "$d" "$d.link"
}

@test "outcomes outside shadow dir, no --surface: unchanged" {
  local d o; _outcomes_in_shadow_dir_fixture
  o="$(mktemp -d)"; mv "$d/caroline.outcomes.jsonl" "$o/"
  run "$REPORT" --shadow-dir "$d" --outcomes "$o/caroline.outcomes.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=2 "* ]]
  [[ "$output" == *"outcomes_rows=2 outcomes_matched=2"* ]]
  rm -rf "$d" "$o"
}

# The default sidecar stays in the shadow dir while --outcomes points at an
# alternate file elsewhere: the default one must still not be read as shadow.
@test "alternate --outcomes path: default sidecar in shadow dir is still excluded" {
  local d o; _outcomes_in_shadow_dir_fixture
  o="$(mktemp -d)"; cp "$d/caroline.outcomes.jsonl" "$o/backfill.jsonl"
  run "$REPORT" --shadow-dir "$d" --outcomes "$o/backfill.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=2 "* ]]
  [[ "$output" == *"outcomes_rows=2 outcomes_matched=2"* ]]
  rm -rf "$d" "$o"
}

@test "no --outcomes flag: sidecar in shadow dir is not counted as shadow rows" {
  local d; _outcomes_in_shadow_dir_fixture
  run "$REPORT" --shadow-dir "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=2 "* ]]
  rm -rf "$d"
}

# ── MUS-5251: --pair-versions, and no self-agreement in the default mode ──
# Row builder: _row <ts> <item_id> <version|-> <choice> <prob> [rc]
# `-` writes no questions_version (v1-legacy). One question, "intent".
_row() {
  local ts="$1" item="$2" ver="$3" choice="$4" prob="$5" rc="${6:-0}"
  local verjson='' answers
  [ "$ver" = "-" ] || verjson="\"questions_version\":\"$ver\","
  if [ "$rc" = "0" ]; then
    answers="{\"intent\":{\"type\":\"choice\",\"choice\":\"$choice\",\"probabilities\":{\"$choice\":$prob}}}"
  else
    answers=null
  fi
  printf '{"ts":"%s","surface":"pairs","item_id":"%s",%s"answers":%s,"latency_ms":100,"actual":"route","rc":%s}\n' \
    "$ts" "$item" "$verjson" "$answers" "$rc"
}

_pair_dir() {
  PAIR_DIR="$TEST_TMPDIR/pair"
  mkdir -p "$PAIR_DIR"
  : > "$PAIR_DIR/pairs.jsonl"
}

@test "pair-versions: a v1/v2 pair 2s apart with different top options is 100% disagreement in v1's bucket" {
  _pair_dir
  { _row 2026-10-01T10:00:00.000Z t1 v1 route 0.85
    _row 2026-10-01T10:00:02.000Z t1 v2 decline 0.6; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" =~ 0\.8-0\.9[[:space:]]+1[[:space:]]+100\.0% ]]
  # v2's own probability (0.6) must not pick the bucket
  [[ "$output" != *"0.6-0.7"* ]]
  [[ "$output" == *"route -> decline"*"1"* ]]
}

@test "pair-versions: the same pair 6s apart does not pair and is counted as unpaired" {
  _pair_dir
  { _row 2026-10-01T10:00:00.000Z t1 v1 route 0.85
    _row 2026-10-01T10:00:06.000Z t1 v2 decline 0.6; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" != *"disagree%"* ]]
  [[ "$output" != *"route -> decline"* ]]
  [[ "$output" == *"paired=0"* ]]
  [[ "$output" == *"unpaired=2"* ]]
}

@test "pair-versions: a question present only in the v1 row is in neither numerator nor denominator" {
  _pair_dir
  { printf '{"ts":"2026-10-01T10:00:00Z","surface":"pairs","item_id":"t1","questions_version":"v1","answers":{"intent":{"type":"choice","choice":"route","probabilities":{"route":0.85}},"only_v1":{"type":"noul","noul":0.9}},"rc":0}\n'
    printf '{"ts":"2026-10-01T10:00:01Z","surface":"pairs","item_id":"t1","questions_version":"v2","answers":{"intent":{"type":"choice","choice":"route","probabilities":{"route":0.7}}},"rc":0}\n'
  } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"question: intent"* ]]
  [[ "$output" != *"only_v1"* ]]
  [[ "$output" =~ 0\.8-0\.9[[:space:]]+1[[:space:]]+0\.0% ]]
}

@test "default mode prints no agreement column and says why" {
  run "$REPORT" --shadow-dir "$FIXTURE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"agreement"*"%"* ]]
  [[ "$output" != *"0.5-0.6   1   0.0%"* ]]
  [[ "$output" == *"0.5-0.6   1"* ]]
  [[ "$output" == *"it needs outcome ground truth (--outcomes, hydra#1041)"* ]]
}

@test "pair-versions: an rc=2 row never pairs and is counted" {
  _pair_dir
  { _row 2026-10-01T10:00:00.000Z t1 v1 route 0.85
    _row 2026-10-01T10:00:01.000Z t1 v2 decline 0.6 2; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"paired=0"* ]]
  [[ "$output" == *"rc_nonzero=1"* ]]
  [[ "$output" != *"route -> decline"* ]]
}

@test "pair-versions: a v1-legacy (unversioned) row never pairs and is counted" {
  _pair_dir
  { _row 2026-10-01T10:00:00.000Z t1 - route 0.85
    _row 2026-10-01T10:00:01.000Z t1 v2 decline 0.6; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"paired=0"* ]]
  [[ "$output" == *"v1_legacy=1"* ]]
  [[ "$output" != *"route -> decline"* ]]
}

@test "pair-versions: one v2 row pairs at most once" {
  _pair_dir
  { _row 2026-10-01T10:00:00.000Z t1 v1 route 0.85
    _row 2026-10-01T10:00:01.000Z t1 v1 route 0.85
    _row 2026-10-01T10:00:01.500Z t1 v2 route 0.9; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"paired=1"* ]]
  [[ "$output" == *"unpaired=1"* ]]
}

@test "pair-versions: --window-hours keeps fresh millisecond-stamped rows and still pairs them" {
  _pair_dir
  local now; now="$(date -u +%Y-%m-%dT%H:%M)"
  { _row "${now}:00.123Z" t1 v1 route 0.85
    _row "${now}:01.456Z" t1 v2 decline 0.6; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions --window-hours 1
  [ "$status" -eq 0 ]
  [[ "$output" != *"no shadow lines"* ]]
  [[ "$output" == *"paired=1"* ]]
}

@test "pair-versions: a paired row with an unhashable choice is counted, not fatal" {
  _pair_dir
  { printf '%s\n' '{"ts":"2026-10-01T10:00:00.000Z","surface":"pairs","item_id":"t1","questions_version":"v1","answers":{"intent":{"type":"choice","choice":["a"],"probabilities":{"a":0.85}}},"latency_ms":1,"rc":0}'
    _row 2026-10-01T10:00:01.000Z t1 v2 decline 0.6
    _row 2026-10-01T10:01:00.000Z t2 v1 route 0.85
    _row 2026-10-01T10:01:01.000Z t2 v2 decline 0.6; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"paired=2"* ]]
  [[ "$output" == *"q_not_compared=1"* ]]
  [[ "$output" =~ 0\.8-0\.9[[:space:]]+1[[:space:]]+100\.0% ]]
}

@test "pair-versions: a question only the v2 row answers is counted in q_not_compared" {
  _pair_dir
  { printf '%s\n' '{"ts":"2026-10-01T10:00:00.000Z","surface":"pairs","item_id":"t1","questions_version":"v1","answers":{"intent":{"type":"noul","noul":0.9}},"latency_ms":1,"rc":0}'
    printf '%s\n' '{"ts":"2026-10-01T10:00:01.000Z","surface":"pairs","item_id":"t1","questions_version":"v2","answers":{"intent":{"type":"noul","noul":0.9},"new_question":{"type":"noul","noul":0.9}},"latency_ms":1,"rc":0}'; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"paired=1"* ]]
  [[ "$output" == *"q_not_compared=1"* ]]
}

@test "pair-versions: a score answer with a nested legend label is counted, not fatal" {
  _pair_dir
  { printf '%s\n' '{"ts":"2026-10-01T10:00:00.000Z","surface":"pairs","item_id":"t1","questions_version":"v1","answers":{"intent":{"type":"score","score":0,"probabilities":{"0":0.9,"1":0.1},"legend":{"0":["nested"]}}},"latency_ms":1,"rc":0}'
    printf '%s\n' '{"ts":"2026-10-01T10:00:01.000Z","surface":"pairs","item_id":"t1","questions_version":"v2","answers":{"intent":{"type":"noul","noul":0.9}},"latency_ms":1,"rc":0}'; } >> "$PAIR_DIR/pairs.jsonl"
  run "$REPORT" --shadow-dir "$PAIR_DIR" --pair-versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"paired=1"* ]]
  [[ "$output" == *"q_not_compared=1"* ]]
}
