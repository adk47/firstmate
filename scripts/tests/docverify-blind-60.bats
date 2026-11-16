#!/usr/bin/env bats

# docverify-blind-60-r1: the blind sample of 60, the independent judge and the scoring.
#
# Pins three things the measurement rests on:
#   1. the judge is never given the reader's output (an allow-list of claim facts, refused otherwise);
#   2. the sample is stratified over the record types and its counts sum to 60;
#   3. the confusion matrix sums to the sample size, and fewer than 10 supportable claims is
#      NOT MEASURED, never a rate.
# Nothing here reaches a network, node-8 or the model: the judge's request is built, never sent.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DVB="$REPO/data/docverify-blind-60-r1"
  export TOOLS="$DVB/tools"
}

_load='import importlib.util, json, os, sys
def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.environ["TOOLS"], name + ".py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
POISON = {"outcome": "POISON_OUTCOME", "reason": "POISON_REASON", "h3": "POISON_H3",
          "extraction": {"doc_type": "POISON_DOCTYPE", "support": "POISON_SUPPORT"},
          "gate": "POISON_GATE", "reader": "POISON_READER", "blockers": ["POISON_BLOCKER"],
          "production_at_cutoff": "POISON_PRODUCTION"}
CASE = {"case": "D99", "proof_id": "ab" * 32, "stratum": "contract", "bytes": "D99.pdf",
        "mime": "application/pdf",
        "claim": dict({"names": ["Ada Writer", "A. Writer"], "role": "Songwriter", "title": "Song",
                       "artists": ["Band"], "request_id": "POISON_REQUEST"}, **POISON)}
CASE.update(POISON)'

@test "judge: the tools compile" {
  run python3 -m py_compile "$TOOLS/judge.py" "$TOOLS/score.py" "$TOOLS/draw_sample.py"
  [ "$status" -eq 0 ]
}

@test "judge: the claim it sees is the allow-list and nothing else" {
  run python3 -c "$_load
j = load('judge')
print(sorted(j.judge_claim(CASE)) == sorted(j.CLAIM_FIELDS))
print(j.CLAIM_FIELDS)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "True" ]
  [ "${lines[1]}" = "('name', 'other_names', 'role', 'track', 'artists')" ]
}

@test "judge: a case carrying the reader's output puts none of it in the request" {
  run python3 -c "$_load
j = load('judge')
body = j.build_request(None, 'text/plain', 'some document text', j.judge_claim(CASE))
s = json.dumps(body)
print(s.count('POISON'))
print('Ada Writer' in s)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "True" ]
}

@test "judge: a claim with any key outside the allow-list is refused" {
  run python3 -c "$_load
j = load('judge')
claim = dict(j.judge_claim(CASE), outcome='verified')
j.build_request(None, 'text/plain', 'x', claim)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"judge refuses claim fields outside the allow-list"* ]]
}

@test "judge: its instructions name no reader verdict" {
  run python3 -c "$_load
j = load('judge')
s = j.SYSTEM.lower()
print(sum(w in s for w in ('unverifiable', 'verified', 'doc-verify', 'h3', 'reader')))"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "judge: main reads only the cases, the documents and its own output" {
  run python3 -c "$_load
import ast
tree = ast.parse(open(os.path.join(os.environ['TOOLS'], 'judge.py')).read())
opts = sorted(n.args[0].value for n in ast.walk(tree) if isinstance(n, ast.Call)
              and getattr(n.func, 'attr', '') == 'add_argument')
print(opts)"
  [ "$status" -eq 0 ]
  [ "$output" = "['--cases', '--docs', '--model', '--out']" ]
}

@test "judge: the answer parser accepts only yes, no or cannot_tell" {
  run python3 -c "$_load
j = load('judge')
print(j.parse('{\"verdict\": \"cannot tell\", \"reason\": \"blurred\"}')[0], flush=True)
j.parse('{\"verdict\": \"verified\", \"reason\": \"x\"}')"
  [ "$status" -ne 0 ]
  [ "${lines[0]}" = "cannot_tell" ]
  [[ "$output" == *"judge verdict not one of"* ]]
}

@test "sample: sample.md lists 60 documents" {
  run python3 -c "$_load
rows = [l for l in open(os.path.join(os.environ['DVB'], 'sample.md')) if l.startswith('| ') and l.split('|')[1].strip().isdigit()]
print(len(rows))
print(len({r.split('|')[2].strip() for r in rows}))"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "60" ]
  [ "${lines[1]}" = "60" ]
}

@test "sample: each stratum's draw is the proportional allocation of the population table" {
  run python3 -c "$_load
import collections
d = load('draw_sample')
md = open(os.path.join(os.environ['DVB'], 'sample.md')).read().splitlines()
pop = {l.split('|')[1].strip().strip('\`'): int(l.split('|')[3]) for l in md
       if l.startswith('| \`') and len(l.split('|')) == 7}
drawn = collections.Counter(l.split('|')[4].strip().strip('\`') for l in md
                            if l.startswith('| ') and l.split('|')[1].strip().isdigit())
print(sum(pop.values()))
print(len(pop))
print(dict(drawn) == d.allocate(pop, 60))
print(sum(drawn.values()))"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "980" ]
  [ "${lines[1]}" = "6" ]
  [ "${lines[2]}" = "True" ]
  [ "${lines[3]}" = "60" ]
}

@test "sample: every row's document type is its stratum" {
  run python3 -c "$_load
md = open(os.path.join(os.environ['DVB'], 'sample.md')).read().splitlines()
rows = [l.split('|') for l in md if l.startswith('| ') and l.split('|')[1].strip().isdigit()]
print(sum(r[3].strip() != r[4].strip() for r in rows))"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "sample: allocation sums to n and never exceeds a stratum" {
  run python3 -c "$_load
d = load('draw_sample')
a = d.allocate({'a': 3, 'b': 500, 'c': 40}, 60)
print(sum(a.values()))
print(a['a'] <= 3)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "60" ]
  [ "${lines[1]}" = "True" ]
}

@test "score: the confusion matrix sums to the sample size" {
  run python3 -c "$_load
s = load('score')
rows = json.load(open(os.path.join(os.environ['DVB'], 'labels.json')))['rows']
print(len(rows))
print(s.total(s.matrix(rows)))"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "60" ]
  [ "${lines[1]}" = "60" ]
}

@test "score: the labels are the 60 sampled documents, in their strata" {
  run python3 -c "$_load
md = open(os.path.join(os.environ['DVB'], 'sample.md')).read().splitlines()
sample = {l.split('|')[2].strip().strip('\`'): l.split('|')[4].strip().strip('\`') for l in md
          if l.startswith('| ') and l.split('|')[1].strip().isdigit()}
rows = json.load(open(os.path.join(os.environ['DVB'], 'labels.json')))['rows']
print(sum(sample.get(r['id']) == r['stratum'] for r in rows))"
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
}

@test "score: a verdict outside the matrix is refused, not dropped" {
  run python3 -c "$_load
s = load('score')
s.matrix([{'case': 'D1', 'reader': 'approved', 'judge': 'yes'}])"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verdict outside the matrix"* ]]
}

@test "score: fewer than 10 supportable claims is NOT MEASURED with the count, never a rate" {
  run python3 -c "$_load
s = load('score')
rows = [{'case': f'D{i}', 'reader': 'verified', 'judge': 'yes'} for i in range(9)]
print(s.bar(rows)['verdict'])"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT MEASURED: 9 supportable claims, the bar needs 10" ]
}

@test "score: 8 of 10 supportable verified passes and 7 of 10 fails" {
  run python3 -c "$_load
s = load('score')
mk = lambda ok: [{'case': f'D{i}', 'reader': 'verified' if i < ok else 'unverifiable', 'judge': 'yes'} for i in range(10)]
print(s.bar(mk(8))['verdict'])
print(s.bar(mk(7))['verdict'])"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "PASS" ]
  [ "${lines[1]}" = "FAIL" ]
}

@test "score: the committed result is NOT MEASURED on 4 supportable" {
  run python3 -c "$_load
s = load('score')
rows = json.load(open(os.path.join(os.environ['DVB'], 'labels.json')))['rows']
print(s.bar(rows)['verdict'])"
  [ "$status" -eq 0 ]
  [ "$output" = "NOT MEASURED: 4 supportable claims, the bar needs 10" ]
}
