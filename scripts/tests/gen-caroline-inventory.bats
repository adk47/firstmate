#!/usr/bin/env bats
# Tests for scripts/gen-caroline-inventory.sh and scripts/check-caroline-inventory.sh
# (docs/designs/2026-09-22-jev-caroline-router.md, section A). Runs against
# the real repo tree (the generator reads plugins/support-tools/src/tools/*.ts,
# workspaces/support/TOOLS.md, workspaces/support/skills/*/SKILL.md and
# support-action-router.ts -- there is nothing to fake), writing into a
# throwaway --out-dir per test so it never touches the checked-in files.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GEN="$HYDRA_REPO/scripts/gen-caroline-inventory.sh"
CHECK="$HYDRA_REPO/scripts/check-caroline-inventory.sh"
CHECKED_IN_DIR="$HYDRA_REPO/plugins/intercom/src"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "generator is deterministic: two runs produce byte-identical files" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run1"
  [ "$status" -eq 0 ]
  run "$GEN" --out-dir "$TEST_TMPDIR/run2"
  [ "$status" -eq 0 ]

  diff "$TEST_TMPDIR/run1/caroline-inventory.json" "$TEST_TMPDIR/run2/caroline-inventory.json"
  diff "$TEST_TMPDIR/run1/caroline-questions.json" "$TEST_TMPDIR/run2/caroline-questions.json"
}

@test "check script passes against the real checked-in files" {
  run "$CHECK"
  [ "$status" -eq 0 ]
}

@test "check script fails on a mutated copy of caroline-inventory.json" {
  mutated_dir="$TEST_TMPDIR/mutated"
  mkdir -p "$mutated_dir"
  cp "$CHECKED_IN_DIR/caroline-inventory.json" "$mutated_dir/caroline-inventory.json"
  cp "$CHECKED_IN_DIR/caroline-questions.json" "$mutated_dir/caroline-questions.json"
  python3 -c "
import json
p = '$mutated_dir/caroline-inventory.json'
d = json.load(open(p))
d['tools'][0]['resolves'] = 'MUTATED-FOR-TEST'
json.dump(d, open(p, 'w'), indent=2, sort_keys=True)
"

  # Point the check at the mutated dir by copying the real check script's
  # logic inline: run gen into a fresh temp dir and diff it against the
  # mutated checked-in-style dir, since check-caroline-inventory.sh always
  # diffs against the real plugins/intercom/src -- this exercises the same
  # diff-fails-loud behavior the real script relies on.
  run "$GEN" --out-dir "$TEST_TMPDIR/regen"
  [ "$status" -eq 0 ]
  run diff "$mutated_dir/caroline-inventory.json" "$TEST_TMPDIR/regen/caroline-inventory.json"
  [ "$status" -ne 0 ]
}

@test "check script fails when the real checked-in file is mutated in place" {
  backup="$TEST_TMPDIR/caroline-inventory.json.bak"
  cp "$CHECKED_IN_DIR/caroline-inventory.json" "$backup"
  python3 -c "
import json
p = '$CHECKED_IN_DIR/caroline-inventory.json'
d = json.load(open(p))
d['tools'][0]['resolves'] = 'MUTATED-FOR-TEST'
json.dump(d, open(p, 'w'), indent=2, sort_keys=True)
"
  run "$CHECK"
  status_seen="$status"

  cp "$backup" "$CHECKED_IN_DIR/caroline-inventory.json"

  [ "$status_seen" -eq 1 ]
  [[ "$output" == *"run scripts/gen-caroline-inventory.sh and commit"* ]]
}

@test "every registered tool name appears exactly once in the inventory" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  code_names="$TEST_TMPDIR/code-tool-names.txt"
  : > "$code_names"
  for f in "$HYDRA_REPO"/plugins/support-tools/src/tools/*.ts; do
    base="$(basename "$f")"
    [ "$base" = "ticket-format.ts" ] && continue
    [[ "$base" == *.test.ts ]] && continue
    grep -oE 'name:\s*"[a-zA-Z_]+"' "$f" | grep -oE '"[a-zA-Z_]+"' | tr -d '"' >> "$code_names"
  done
  sort -u "$code_names" > "$TEST_TMPDIR/code-tool-names.sorted.txt"

  inv_names="$TEST_TMPDIR/inv-tool-names.txt"
  python3 -c "
import json
d = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
for t in d['tools']:
    print(t['name'])
" | sort > "$inv_names"

  diff "$TEST_TMPDIR/code-tool-names.sorted.txt" "$inv_names"

  # exactly-once: no name appears twice in the inventory array
  dupe_count="$(python3 -c "
import json
d = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
names = [t['name'] for t in d['tools']]
print(len(names) - len(set(names)))
")"
  [ "$dupe_count" -eq 0 ]
}

@test "every included skill dir appears in the inventory" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  inv_skills="$(python3 -c "
import json
d = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
print('\n'.join(sorted(s['name'] for s in d['skills'])))
")"

  expected="action-request
milestone-badge-purchase
order-fulfillment
refund-retention
verification-handoff"

  [ "$inv_skills" = "$expected" ]

  # input-sanitizer / output-sanitizer are deliberately excluded (pipeline
  # skills, not customer-request skills) -- assert they never leak in.
  [[ "$inv_skills" != *"input-sanitizer"* ]]
  [[ "$inv_skills" != *"output-sanitizer"* ]]
}

@test "the 12 intents appear with an explicit first_read_tool (possibly empty)" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  run python3 -c "
import json, sys
d = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
intents = d['intents']
assert len(intents) == 12, f'expected 12 intents, got {len(intents)}'
for i in intents:
    assert 'first_read_tool' in i, f\"{i['intent']} missing first_read_tool key\"
    assert isinstance(i['first_read_tool'], str), f\"{i['intent']} first_read_tool not a string\"
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "caroline-questions.json has exactly the six question ids" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  run python3 -c "
import json
d = json.load(open('$TEST_TMPDIR/run/caroline-questions.json'))
expected = {'resolution_path', 'intent', 'first_tool', 'skill', 'off_topic_or_bad_faith', 'frustration'}
assert set(d.keys()) == expected, sorted(d.keys())
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "first_tool criteria keys equal every read tool plus create_ticket plus none" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  run python3 -c "
import json
inv = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
q = json.load(open('$TEST_TMPDIR/run/caroline-questions.json'))
expected = {t['name'] for t in inv['tools'] if t['kind'] == 'read'} | {'create_ticket', 'none'}
actual = set(q['first_tool']['criteria'].keys())
assert actual == expected, (sorted(actual - expected), sorted(expected - actual))
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "skill criteria keys equal every skill plus none" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  run python3 -c "
import json
inv = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
q = json.load(open('$TEST_TMPDIR/run/caroline-questions.json'))
expected = {s['name'] for s in inv['skills']} | {'none'}
actual = set(q['skill']['criteria'].keys())
assert actual == expected, (sorted(actual - expected), sorted(expected - actual))
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "intent criteria keys equal the 12 intents plus other" {
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  run python3 -c "
import json
inv = json.load(open('$TEST_TMPDIR/run/caroline-inventory.json'))
q = json.load(open('$TEST_TMPDIR/run/caroline-questions.json'))
expected = {i['intent'] for i in inv['intents']} | {'other'}
actual = set(q['intent']['criteria'].keys())
assert len(expected) == 13, len(expected)
assert actual == expected, (sorted(actual - expected), sorted(expected - actual))
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "verification and merge WRITE tools never appear in first_tool criteria; only the two own-row reads do (captain 2026-10-28, narrowed 2026-11-12)" {
  # The write, merge, dedupe and any-profile tools are not in TOOLS.md (nor the edge allowlist);
  # the router must never suggest them, whatever the plugin still registers. The 2026-11-12
  # narrowing (ai-support-quality-v1) lets exactly two read-only tools back in: they fail closed
  # without a signed-in contact and return that customer's own rows only.
  run "$GEN" --out-dir "$TEST_TMPDIR/run"
  [ "$status" -eq 0 ]

  run python3 -c "
import json
q = json.load(open('$TEST_TMPDIR/run/caroline-questions.json'))
for name in ('credits_verify', 'remove_credits', 'profiles_consolidate',
             'profiles_claim_self', 'dedupe_check', 'profile_credits_status'):
    assert name not in q['first_tool']['criteria'], name
own_row_reads = ('credit_verification_check', 'profile_claim_status')
for name in own_row_reads:
    assert name in q['first_tool']['criteria'], name
assert 'create_ticket' in q['first_tool']['criteria']
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
