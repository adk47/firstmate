#!/usr/bin/env bats
# Firstmate 017 (2026-10-30): Caroline ignored the shipped merge doctrine in 4 of 5 merge asks.
# This replays those real conversations (plugins/intercom/tests/fixtures/caroline-merge-transcripts-1030.json)
# through the outbound merge-reply guard the way channel.ts runs it, and proves it CAN fail.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  EVAL="$ROOT/scripts/caroline-merge-guard-eval.mjs"
  FX="$ROOT/plugins/intercom/tests/fixtures/caroline-merge-transcripts-1030.json"
  # No skip: a missing runtime must fail loudly, never pass (scripts/ci/arc-toolchain.sh bats
  # installs node >= 22 for this job).
  node --experimental-strip-types --no-warnings -e '0' \
    || { echo "node with --experimental-strip-types is required (node >= 22.6)" >&2; return 1; }
}

run_eval() { run node --experimental-strip-types --no-warnings "$EVAL" "$@"; }

@test "the 4 failing conversations + the good one: §2.4 exactly once, no judgement; controls untouched" {
  run_eval "$FX"
  [ "$status" -eq 0 ]
  for c in 215476571311441 215476626852900 215476625749758 215476627008983 \
           qa-1530-accounts-and-tracks qa-1530-altered-paragraph qa-1530-model-repeats; do
    [[ "$output" == *"ok $c: §2.4 exactly once, no judgement"* ]]
  done
  # 215476625525975 is the one good reply: it already carried §2.4 on turn 2, in the copy approved
  # on 2026-10-30. That paragraph was rewritten on 2026-11-15 (Aaron order #2: no "verification
  # team", no "I'll pass those on"), so the transcript's text is no longer §2.4 and the expected
  # count is 0 - the customer has had the merge explanation, in older words, and must not get it
  # twice. Asserting "exactly once" here would demand the guard repeat itself.
  [[ "$output" == *"ok 215476625525975: §2.4 not sent (no merge ask), no judgement"* ]]
  [[ "$output" == *"ok control untouched: not a profile merge: duplicate TRACKS"* ]]
}

@test "CAN FAIL: without the guard (identity), the same transcripts fail" {
  stub="$BATS_TEST_TMPDIR/noop-guard.ts"
  cat > "$stub" <<'TS'
export { MERGE_PARAGRAPH, findJudgements } from "GUARD";
export function applyMergeReplyGuard(i: { reply: string }) {
  return { body: i.reply, mergeIntent: false, mergeIntentThisTurn: false, actions: [], droppedJudgements: [], paragraphSent: false };
}
export function prepareMergeReply(_s: unknown, _c: string, reply: string) {
  return { body: reply, result: applyMergeReplyGuard({ reply }), commit: () => false };
}
TS
  sed -i.bak "s#GUARD#$ROOT/plugins/intercom/src/merge-reply-guard.ts#" "$stub"
  MERGE_GUARD_SRC="$stub" run_eval "$FX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL 215476625749758"* ]]
  [[ "$output" == *"FAIL 215476571311441 turn 1: judgement left in reply"* ]]
}

@test "CAN FAIL: a new judgement phrasing in a transcript is caught" {
  fx="$BATS_TEST_TMPDIR/fx.json"
  python3 - "$FX" "$fx" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["conversations"][2]["turns"][0]["reply"] += " These profiles cannot be merged."
json.dump(d, open(sys.argv[2], "w"))
PY
  run_eval "$fx"
  [ "$status" -eq 0 ]
  # dropped by the guard, so the run still passes; the reply no longer carries it
  MERGE_GUARD_VERBOSE=1 run_eval "$fx"
  [[ "$output" != *"cannot be merged"* ]]
}

@test "a broken fixture path is a harness error (exit 2), never a pass" {
  run_eval "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
}

@test "CAN FAIL: a guard that accepts a prefix-only variant of §2.4 is caught" {
  stub="$BATS_TEST_TMPDIR/prefix-guard.ts"
  cat > "$stub" <<'TS'
export { MERGE_PARAGRAPH, findJudgements } from "GUARD";
import { MERGE_PARAGRAPH } from "GUARD";
export function prepareMergeReply(_s: unknown, _c: string, reply: string) {
  const body = reply.includes("Merges work like this") ? reply : reply + "\n\n" + MERGE_PARAGRAPH;
  return { body, result: { body, actions: [], droppedJudgements: [], paragraphSent: true, mergeIntent: true, mergeIntentThisTurn: true }, commit: () => false };
}
export const applyMergeReplyGuard = (i: { reply: string }) => prepareMergeReply(0, "", i.reply).result;
TS
  sed -i.bak "s#GUARD#$ROOT/plugins/intercom/src/merge-reply-guard.ts#g" "$stub"
  MERGE_GUARD_SRC="$stub" run_eval "$FX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL qa-1530-altered-paragraph turn 0: a non-exact §2.4 variant was delivered"* ]]
}
