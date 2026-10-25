#!/usr/bin/env bats
# Tests for scripts/jev-eval-run.sh, the Jev eval replay/scorer. Hermetic:
# fake state-builder (JEV_EVAL_STATE_CLI_CMD) and fake jev.sh
# (JEV_EVAL_JEV_SH_CMD) shadowed in via env-var seams (never touches the
# real plugins/intercom/dist build or scripts/lib/jev.sh), synthetic gold
# fixtures, no network, no real API key.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/jev-eval-run.sh"
FIXTURES="$HYDRA_REPO/scripts/tests/fixtures/jev-eval"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  export QUESTIONS_FILE="$FIXTURES/caroline-questions.json"

  # Fake state-builder: ignores its input, prints a fixed state object.
  cat > "$TEST_TMPDIR/bin/fake-state-cli.sh" <<'STUB'
#!/bin/bash
cat > /dev/null
echo '{"message":"test","last_parts":[],"turn_count":1}'
STUB
  chmod +x "$TEST_TMPDIR/bin/fake-state-cli.sh"
  export JEV_EVAL_STATE_CLI_CMD="$TEST_TMPDIR/bin/fake-state-cli.sh"

  # Fake jev.sh: reads JEV_ROW_BEHAVIOR_FILE, a newline list of "ok" or
  # "fail" (one per call, consumed in order via JEV_ROW_CALL_COUNTER) so
  # each test controls exactly which rows measure and which don't. "ok"
  # always answers resolution_path=ask_customer at probability 0.9 (so the
  # threshold sweep and confusion matrix have a deterministic prediction).
  cat > "$TEST_TMPDIR/bin/fake-jev.sh" <<'STUB'
#!/bin/bash
n=$(( $(cat "$JEV_ROW_CALL_COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$JEV_ROW_CALL_COUNTER"
behavior=$(sed -n "${n}p" "$JEV_ROW_BEHAVIOR_FILE" 2>/dev/null || echo ok)
if [ "$behavior" = "fail" ]; then
  echo "jev.sh: simulated failure" >&2
  exit 3
fi
if [ "$behavior" = "die" ]; then
  # Kills run_row's own subshell (our direct parent) with SIGKILL before it
  # can write anything -- a genuinely lost worker, not a jev.sh failure the
  # subshell handles and reports (QA re-review finding 6). No result file
  # for this row's index is ever created.
  kill -9 "$PPID"
  sleep 5
  exit 137
fi
if [ "$behavior" = "malformed" ]; then
  # Well-formed JSON object, but resolution_path's .choice is missing --
  # exercises the per-question typed-answer validation (QA finding 1).
  cat <<JSON
{"resolution_path":{"type":"choice","probabilities":{"ask_customer":0.9}},"intent":{"type":"choice","choice":"credits_missing","probabilities":{"credits_missing":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"frustration":{"type":"score","score":0,"probabilities":{"0":0.9,"1":0.1}}}
JSON
  exit 0
fi
if [ "$behavior" = "choice-prob-missing" ]; then
  # resolution_path picks a choice but carries no probability for it, so the
  # threshold and customer-harm sweeps could not place it.
  cat <<JSON
{"resolution_path":{"type":"choice","choice":"no_reply","probabilities":{}},"intent":{"type":"choice","choice":"credits_missing","probabilities":{"credits_missing":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"frustration":{"type":"score","score":0,"probabilities":{"0":0.9,"1":0.1}}}
JSON
  exit 0
fi
if [ "$behavior" = "choice-prob-nonnumeric" ]; then
  cat <<JSON
{"resolution_path":{"type":"choice","choice":"no_reply","probabilities":{"no_reply":"high"}},"intent":{"type":"choice","choice":"credits_missing","probabilities":{"credits_missing":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"frustration":{"type":"score","score":0,"probabilities":{"0":0.9,"1":0.1}}}
JSON
  exit 0
fi
if [ "$behavior" = "no-type" ]; then
  # resolution_path.choice is well-formed, but the answer omits its
  # declared `type` -- passes an unqualified ".choice present" check but
  # score.py's top_choice() reads .get("type") first and returns (None,
  # None) for it, so it must be caught here as unmeasured (QA re-review
  # finding 1, carried forward from #1021).
  cat <<JSON
{"resolution_path":{"choice":"ask_customer","probabilities":{"ask_customer":0.9}},"intent":{"type":"choice","choice":"credits_missing","probabilities":{"credits_missing":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"frustration":{"type":"score","score":0,"probabilities":{"0":0.9,"1":0.1}}}
JSON
  exit 0
fi
if [ "$behavior" = "unreadable-score" ]; then
  # frustration's type/.score are both well-formed, but it carries no
  # .probabilities -- score.py's top_choice() for a "score" question reads
  # ONLY .probabilities (see its docstring), so this answer is well-typed
  # yet top_choice() still can't read it. Must be unmeasured, not silently
  # scored with pred=None (QA re-review finding 1).
  cat <<JSON
{"resolution_path":{"type":"choice","choice":"ask_customer","probabilities":{"ask_customer":0.9}},"intent":{"type":"choice","choice":"credits_missing","probabilities":{"credits_missing":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"frustration":{"type":"score","score":0}}
JSON
  exit 0
fi
cat <<JSON
{"resolution_path":{"type":"choice","choice":"ask_customer","probabilities":{"ask_customer":0.9,"caroline_tool":0.1}},"intent":{"type":"choice","choice":"credits_missing","probabilities":{"credits_missing":0.8}},"first_tool":{"type":"choice","choice":"none","probabilities":{"none":0.7}},"frustration":{"type":"score","score":0,"probabilities":{"0":0.9,"1":0.1}}}
JSON
STUB
  chmod +x "$TEST_TMPDIR/bin/fake-jev.sh"
  export JEV_EVAL_JEV_SH_CMD="$TEST_TMPDIR/bin/fake-jev.sh"
  export JEV_ROW_CALL_COUNTER="$TEST_TMPDIR/jev-call-count"
  : > "$JEV_ROW_CALL_COUNTER"
  export JEV_ROW_BEHAVIOR_FILE="$TEST_TMPDIR/jev-behavior.txt"
  printf 'ok\nok\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"

  make_gold_row() {
    local conv="$1" turn="$2" split="$3" needs_reply="$4"
    jq -nc --arg conv "$conv" --argjson turn "$turn" --arg split "$split" --argjson needs_reply "$needs_reply" \
      '{conv_id:$conv, turn_index:$turn, stratum:"other",
        thread_so_far:{parts:[{author:"user",body:"hi"}], turn_index:0},
        label:{path:"ask_customer", intent:"credits_missing", first_tool:"none",
               needs_reply:$needs_reply, supplying_requested_info:false, bad_faith:false,
               frustration_level:0, rationale:"fixture"},
        caroline_action:{replied:true, escalated:false, has_ticket:false, first_tool:null},
        split:$split}'
  }
  export -f make_gold_row

  {
    make_gold_row 3001 0 tune true
    make_gold_row 3002 0 tune false
    make_gold_row 3003 0 holdout true
    make_gold_row 3004 0 holdout false
  } > "$TEST_TMPDIR/gold.jsonl"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "rejects an unknown --split" {
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --split nope
  [ "$status" -eq 2 ]
}

@test "rejects a non-numeric --concurrency" {
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency abc
  [ "$status" -eq 2 ]
}

@test "fails with exit 3 on an empty gold file" {
  : > "$TEST_TMPDIR/empty.jsonl"
  run "$SCRIPT" --gold "$TEST_TMPDIR/empty.jsonl" --questions "$QUESTIONS_FILE" --variant v1
  [ "$status" -eq 3 ]
}

@test "--split filters rows to only that split" {
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --split tune --concurrency 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=2"* ]]
}

@test "all four rows measure and produce a per-question accuracy line when jev.sh always succeeds" {
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"measured=4"* ]]
  [[ "$output" == *"unmeasured=0"* ]]
  [[ "$output" == *"resolution_path: n=4 accuracy=100.0%"* ]]
}

@test "a jev.sh failure is counted as unmeasured, never dropped from the total" {
  printf 'ok\nfail\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"measured=3"* ]]
  [[ "$output" == *"unmeasured=1"* ]]
}

@test "a well-formed answers object with an invalid per-question value is counted as unmeasured, not scored" {
  printf 'ok\nmalformed\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"measured=3"* ]]
  [[ "$output" == *"unmeasured=1"* ]]
}

@test "a choice answer with no numeric probability for its chosen option is unmeasured, never dropped from the sweeps" {
  for b in choice-prob-missing choice-prob-nonnumeric; do
    : > "$JEV_ROW_CALL_COUNTER"
    printf 'ok\n%s\nok\nok\n' "$b" > "$JEV_ROW_BEHAVIOR_FILE"
    run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50
    [ "$status" -eq 0 ]
    [[ "$output" == *"total=4"* ]]
    [[ "$output" == *"measured=3"* ]]
    [[ "$output" == *"unmeasured=1"* ]]
  done
}

@test "an answer missing its declared type is unmeasured, never false-green measured (QA re-review finding 1)" {
  printf 'ok\nno-type\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"measured=3"* ]]
  [[ "$output" == *"unmeasured=1"* ]]
}

@test "an answer top_choice() can't read despite a matching type/typed-field is unmeasured, never skipped (QA re-review finding 1)" {
  printf 'ok\nunreadable-score\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"measured=3"* ]]
  [[ "$output" == *"unmeasured=1"* ]]
}

@test "a worker killed before writing its result file is counted as unmeasured with reason worker-lost, never dropped from the total (QA re-review finding 6)" {
  printf 'ok\ndie\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"total=4"* ]]
  [[ "$output" == *"measured=3"* ]]
  [[ "$output" == *"unmeasured=1"* ]]
  [[ "$output" == *"worker-lost"* ]]
}

@test "a gold row with a null label measures fine but is counted+gated as unlabelled, never silently skipped" {
  make_gold_row_unlabelled() {
    local conv="$1" turn="$2" split="$3"
    jq -nc --arg conv "$conv" --argjson turn "$turn" --arg split "$split" \
      '{conv_id:$conv, turn_index:$turn, stratum:"other",
        thread_so_far:{parts:[{author:"user",body:"hi"}], turn_index:0},
        label:null,
        caroline_action:{replied:true, escalated:false, has_ticket:false, first_tool:null},
        split:$split}'
  }
  {
    make_gold_row 3001 0 tune true
    make_gold_row 3002 0 tune false
    make_gold_row 3003 0 holdout true
    make_gold_row 3004 0 holdout false
    make_gold_row_unlabelled 3005 0 tune
  } > "$TEST_TMPDIR/gold-with-unlabelled.jsonl"
  printf 'ok\nok\nok\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"

  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-with-unlabelled.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 50 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.total == 5 and .measured == 5 and .unmeasured == 0 and .unlabelled == 1' >/dev/null
  echo "$output" | jq -e '.unlabelled_rows == [{"conv_id":"3005","turn_index":0}]' >/dev/null
  # resolution_path's n stays 4 (the unlabelled row contributes to neither
  # numerator nor denominator of the per-question accuracy).
  echo "$output" | jq -e '.questions.resolution_path.n == 4' >/dev/null

  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-with-unlabelled.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 15
  [ "$status" -eq 7 ]
}

@test "the unmeasured gate exits non-zero (7) when the unmeasured rate exceeds --max-unmeasured" {
  printf 'fail\nfail\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 2
  [ "$status" -eq 7 ]
}

@test "the same unmeasured rate passes when --max-unmeasured is raised above it" {
  printf 'fail\nfail\nok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --max-unmeasured 60
  [ "$status" -eq 0 ]
}

@test "--json emits a parseable report with the expected top-level keys" {
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.measured == 4 and .unmeasured == 0 and (.threshold_sweep | length) == 50' >/dev/null
}

@test "a gold-labelled path with no v1 schema match is still counted, and reported separately from the excl-gap accuracy" {
  jq -nc '{conv_id:"3005", turn_index:0, stratum:"other",
    thread_so_far:{parts:[{author:"user",body:"hi"}], turn_index:0},
    label:{path:"answer_from_knowledge", intent:"credits_missing", first_tool:"none",
           needs_reply:true, supplying_requested_info:false, bad_faith:false,
           frustration_level:0, rationale:"fixture"},
    caroline_action:{replied:true, escalated:false, has_ticket:false, first_tool:null},
    split:"tune"}' > "$TEST_TMPDIR/gold-gap.jsonl"
  printf 'ok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-gap.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"measured=1"* ]]
  # v1 can never predict answer_from_knowledge (not in its enum) -- this row
  # is scored as a miss in the plain accuracy line, but excluded from the
  # "excl_v1_path_gap" line, and the discrepancy between the two lines is
  # the evidence the gap was applied, not silently absorbed.
  [[ "$output" == *"resolution_path: n=1 accuracy=0.0% accuracy_excl_v1_path_gap=n/a"* ]]
}

@test "an acknowledge-labelled path is a v1 gap too, never silently absorbed" {
  jq -nc '{conv_id:"3006", turn_index:0, stratum:"other",
    thread_so_far:{parts:[{author:"user",body:"thanks!"}], turn_index:0},
    label:{path:"acknowledge", intent:"other", first_tool:"none",
           needs_reply:true, supplying_requested_info:false, bad_faith:false,
           frustration_level:0, rationale:"fixture"},
    caroline_action:{replied:true, escalated:false, has_ticket:false, first_tool:null},
    split:"tune"}' > "$TEST_TMPDIR/gold-ack.jsonl"
  printf 'ok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-ack.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolution_path: n=1 accuracy=0.0% accuracy_excl_v1_path_gap=n/a"* ]]
}

@test "per-question accuracy is split by known_facts_missing, and a state-parity line reports how many rows lack it (QA re-review finding 3)" {
  # jev-eval-build.sh's known_facts_missing is a per-row flag: the harness
  # has no read-only way to reproduce production's live admin-API +
  # prior-conversations lookups, so every built row is missing known_facts
  # today. The runner must never claim exact parity for those rows --
  # accuracy has to be reported split by the flag (so a future row that
  # DOES carry known_facts is visibly distinguishable from one that
  # doesn't), and the report must say in plain terms how many rows were
  # actually state-faithful.
  jq -nc '{conv_id:"3007", turn_index:0, stratum:"other",
    thread_so_far:{parts:[{author:"user",body:"hi"}], turn_index:0, known_facts_missing:true},
    label:{path:"ask_customer", intent:"credits_missing", first_tool:"none",
           needs_reply:true, supplying_requested_info:false, bad_faith:false,
           frustration_level:0, rationale:"fixture"},
    caroline_action:{replied:true, escalated:false, has_ticket:false, first_tool:null},
    split:"tune"}' > "$TEST_TMPDIR/gold-kf.jsonl"
  jq -nc '{conv_id:"3008", turn_index:0, stratum:"other",
    thread_so_far:{parts:[{author:"user",body:"hi"}], turn_index:0, known_facts_missing:false},
    label:{path:"ask_customer", intent:"credits_missing", first_tool:"none",
           needs_reply:true, supplying_requested_info:false, bad_faith:false,
           frustration_level:0, rationale:"fixture"},
    caroline_action:{replied:true, escalated:false, has_ticket:false, first_tool:null},
    split:"tune"}' >> "$TEST_TMPDIR/gold-kf.jsonl"
  printf 'ok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-kf.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolution_path: n=2 accuracy=100.0%"* ]]
  [[ "$output" == *"known_facts_missing: n=1 accuracy=100.0%"* ]]
  [[ "$output" == *"known_facts_present: n=1 accuracy=100.0%"* ]]
  [[ "$output" == *"state parity: known_facts not reproduced for 1/2 rows"* ]]
}

@test "guard: isolation holds -- the real jev.sh and its shadow/env paths are never touched" {
  # CI runs bats as root on node-8's real filesystem (docs/lessons/
  # working-in-hydra.md "ci-writes-prod"). This suite relies entirely on
  # JEV_EVAL_JEV_SH_CMD/JEV_EVAL_STATE_CLI_CMD replacing the real jev.sh
  # and state-cli invocations; if that seam were ever bypassed, a run
  # would shell out to the real scripts/lib/jev.sh, which reads
  # JEV_ENV_FILE (default /etc/hydra/jev.env) and writes
  # JEV_SHADOW_DIR (default /var/lib/hydra-jev/shadow). This proves the
  # seam actually held for a full run: neither real path gains any new
  # file, and JEV_ENV_FILE/JEV_SHADOW_DIR are deliberately left unset here
  # (not pre-isolated by this setup()) so a broken seam would touch the
  # real host paths rather than a decoy.
  unset JEV_ENV_FILE JEV_SHADOW_DIR
  real_env_file="/etc/hydra/jev.env"
  real_shadow_dir="/var/lib/hydra-jev/shadow"
  marker="$TEST_TMPDIR/.guard-marker"
  : > "$marker"
  env_before=""
  [ -e "$real_env_file" ] && env_before=$(stat -c '%Y' "$real_env_file" 2>/dev/null || stat -f '%m' "$real_env_file" 2>/dev/null)

  run "$SCRIPT" --gold "$TEST_TMPDIR/gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1
  [ "$status" -eq 0 ]

  if [ -e "$real_env_file" ]; then
    env_after=$(stat -c '%Y' "$real_env_file" 2>/dev/null || stat -f '%m' "$real_env_file" 2>/dev/null)
    [ "$env_after" = "$env_before" ]
  fi
  if [ -d "$real_shadow_dir" ]; then
    # Only this run's own surface file (jev-eval.jsonl + its .lock). The real
    # dir is the LIVE production shadow log: on node-8 other surfaces' writers
    # append to it at any moment, so watching the whole dir fails whenever a
    # production row lands mid-run, which says nothing about this seam.
    new_files=$(find "$real_shadow_dir" -type f -name 'jev-eval.jsonl*' -newer "$marker" 2>/dev/null || true)
    [ -z "$new_files" ]
  else
    [ ! -e "$real_shadow_dir" ]
  fi
}

@test "a gold row larger than the kernel's single-argument limit is still measured" {
  # A long conversation's gold row (thread + full_thread) can pass Linux's
  # 128 KiB per-argument limit; 1.1 MB also passes macOS's total ARG_MAX,
  # so this goes red on either host if the row ever travels as argv again.
  python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); r["full_thread"]={"parts":[{"author":"user","body":"x"*1100000}]}; print(json.dumps(r))' \
    "$TEST_TMPDIR/gold.jsonl" > "$TEST_TMPDIR/big-gold.jsonl"
  run "$SCRIPT" --gold "$TEST_TMPDIR/big-gold.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.measured == 1 and .unmeasured == 0' >/dev/null
}

@test "a mid-burst turn is excluded and counted; --include-mid-burst keeps it; --rows-out writes per-row results" {
  jq -nc '{conv_id:"3101", turn_index:0, stratum:"other",
    thread_so_far:{parts:[{author:"user",body:"hi"}], turn_index:0},
    full_thread:{parts:[{author:"user",body:"hi"},{author:"user",body:"my credits are wrong"},{author:"bot",body:"which track?"}], turn_index:0},
    label:{path:"no_reply", intent:"other", first_tool:"none", needs_reply:false, supplying_requested_info:false,
           bad_faith:false, frustration_level:0, rationale:"fixture"},
    caroline_action:{replied:false, escalated:false, conv_has_ticket:false, first_tool:null}, split:"tune"}' > "$TEST_TMPDIR/gold-burst.jsonl"
  jq -nc '{conv_id:"3101", turn_index:1, stratum:"other",
    thread_so_far:{parts:[{author:"user",body:"hi"},{author:"user",body:"my credits are wrong"}], turn_index:1},
    full_thread:{parts:[{author:"user",body:"hi"},{author:"user",body:"my credits are wrong"},{author:"bot",body:"which track?"}], turn_index:1},
    label:{path:"ask_customer", intent:"other", first_tool:"none", needs_reply:true, supplying_requested_info:false,
           bad_faith:false, frustration_level:0, rationale:"fixture"},
    caroline_action:{replied:true, escalated:false, conv_has_ticket:false, first_tool:null}, split:"tune"}' >> "$TEST_TMPDIR/gold-burst.jsonl"
  printf 'ok\nok\n' > "$JEV_ROW_BEHAVIOR_FILE"
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-burst.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --json --rows-out "$TEST_TMPDIR/rows.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"excluded 1 mid-burst turn"* ]]
  echo "$output" | grep '^{' | jq -e '.total == 1' >/dev/null
  [ "$(grep -c . "$TEST_TMPDIR/rows.jsonl")" -eq 1 ]
  jq -e '.row.turn_index == 1' "$TEST_TMPDIR/rows.jsonl" >/dev/null
  run "$SCRIPT" --gold "$TEST_TMPDIR/gold-burst.jsonl" --questions "$QUESTIONS_FILE" --variant v1 --concurrency 1 --json --include-mid-burst
  [ "$status" -eq 0 ]
  echo "$output" | grep '^{' | jq -e '.total == 2' >/dev/null
}
