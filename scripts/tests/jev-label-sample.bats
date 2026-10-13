#!/usr/bin/env bats
# Tests for scripts/jev-label-sample.py against a fixture shadow log built in
# the test's own tmpdir. Fixture: 20 paired, eligible turns spread over the
# report's BUCKETS by v1 `intent` top probability (see gen_fixture) plus one
# case of each exclusion reason.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/jev-label-sample.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  LOG="$TEST_TMPDIR/caroline.jsonl"
  OUT="$TEST_TMPDIR/out"
  python3 - "$LOG" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone

T0 = datetime(2026, 10, 1, tzinfo=timezone.utc)
def ts(sec):
    return (T0 + timedelta(seconds=sec)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

def ans(p):
    return {"intent": {"type": "choice", "choice": "billing", "probabilities": {"billing": p, "other": round(1 - p, 4)}},
            "needs_reply": {"type": "noul", "noul": 0.77}}

def row(item, sec, ver, p, rc=0, state="ok", model=None):
    return {"ts": ts(sec), "surface": "caroline", "item_id": item, "model": model or ("jev-1.13.0" if ver == "v1" else "jev-2.0.0"),
            "state": {"message": f"customer text {item}", "turn_count": 1} if state == "ok" else None,
            "answers": ans(p) if rc == 0 else None, "rc": rc, "http": 200, "questions_version": ver}

# stratum -> (v1 intent top prob, count): 0.0-0.5:2, 0.5-0.6:2, 0.6-0.7:4, 0.7-0.8:4, 0.8-0.9:4, 0.9-1.0:4
dist = [(0.45, 2), (0.55, 2), (0.65, 4), (0.75, 4), (0.85, 4), (0.95, 4)]
rows, k = [], 0
for p, n in dist:
    for _ in range(n):
        k += 1
        rows.append(row(f"c{k:02d}", k * 100, "v1", p))
        rows.append(row(f"c{k:02d}", k * 100 + 2.35, "v2", p - 0.01))
# exclusions
rows.append(row("x-rc2", 5000, "v1", 0.9, rc=2)); rows.append(row("x-rc2", 5002, "v2", 0.9))
rows.append(row("x-nostate", 5100, "v1", 0.9, state=None)); rows.append(row("x-nostate", 5102, "v2", 0.9))
rows.append(row("x-unpaired", 5200, "v1", 0.9)); rows.append(row("x-unpaired", 5206, "v2", 0.9))
rows.append(row("x-nov2", 5300, "v1", 0.9))
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "fixed seed -> byte-identical sample.csv across two runs" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$TEST_TMPDIR/a" --n 10 --seed 7
  [ "$status" -eq 0 ]
  run python3 "$SCRIPT" "$LOG" --out-dir "$TEST_TMPDIR/b" --n 10 --seed 7
  [ "$status" -eq 0 ]
  cmp "$TEST_TMPDIR/a/sample.csv" "$TEST_TMPDIR/b/sample.csv"
  cmp "$TEST_TMPDIR/a/key.jsonl" "$TEST_TMPDIR/b/key.jsonl"
}

@test "sample.csv is blinded: header and rows carry no probability, answer or model" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 20
  [ "$status" -eq 0 ]
  [ "$(head -1 "$OUT/sample.csv")" = "turn_id,message,intent,first_tool,resolution_path,needs_reply" ]
  [ "$(wc -l < "$OUT/sample.csv")" -eq 21 ]
  run grep -E 'billing|other|jev-|(^|[^0-9])0\.(45|55|65|75|85|95|44|54|64|74|84|94|77)|noul|probabilit|answers' "$OUT/sample.csv"
  [ "$status" -eq 1 ]
  # the label columns are empty on every row
  python3 - "$OUT/sample.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
assert all(r[c] == "" for r in rows for c in ("intent", "first_tool", "resolution_path", "needs_reply"))
assert all(r["message"].startswith("customer text ") for r in rows)
PY
}

@test "key.jsonl holds both versions' answers for the same turn_ids" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 20
  [ "$status" -eq 0 ]
  python3 - "$OUT" <<'PY'
import csv, json, sys
ids = [r["turn_id"] for r in csv.DictReader(open(sys.argv[1] + "/sample.csv"))]
keys = [json.loads(l) for l in open(sys.argv[1] + "/key.jsonl")]
assert sorted(ids) == sorted(k["turn_id"] for k in keys)
k = keys[0]
assert set(k["v1"]) == {"intent", "needs_reply"} and set(k["v2"]) == {"intent", "needs_reply"}
assert k["turn_id"].startswith("caroline|c") and k["turn_id"].count("|") == 2
PY
}

@test "strata are proportional to the eligible population" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 10
  [ "$status" -eq 0 ]
  # 20 eligible: 2/2/4/4/4/4 -> quota at n=10: 1/1/2/2/2/2
  [[ "$output" == *"0.0-0.5 eligible=2 quota=1 take=1"* ]]
  [[ "$output" == *"0.5-0.6 eligible=2 quota=1 take=1"* ]]
  [[ "$output" == *"0.9-1.0 eligible=4 quota=2 take=2"* ]]
  [ "$(wc -l < "$OUT/sample.csv")" -eq 11 ]
}

@test "output files are mode 0600" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 10
  [ "$status" -eq 0 ]
  for f in sample.csv key.jsonl; do
    [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$OUT/$f")" = "0o600" ]
  done
}

@test "rc!=0, state:null and unpaired turns are excluded; state:null is counted" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 200
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc_nonzero=1"* ]]
  [[ "$output" == *"state_null=1"* ]]
  [[ "$output" == *"unpaired=2"* ]]
  [[ "$output" == *"eligible=20"* ]]
  run grep -E 'x-rc2|x-nostate|x-unpaired|x-nov2' "$OUT/key.jsonl"
  [ "$status" -eq 1 ]
}

@test "--out-dir inside the repo exits non-zero and writes nothing" {
  d="$HYDRA_REPO/scripts/tests/.label-sample-should-not-exist"
  run python3 "$SCRIPT" "$LOG" --out-dir "$d" --n 10
  [ "$status" -ne 0 ]
  [ ! -e "$d" ]
}

@test "a short stratum is reported, never topped up from another stratum" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 40
  [ "$status" -eq 0 ]
  # n=40 > 20 eligible: every stratum quota is 2x its size; take all, report shortfall
  [[ "$output" == *"shortfall 0.0-0.5: quota=4 eligible=2"* ]]
  [[ "$output" == *"shortfall 0.9-1.0: quota=8 eligible=4"* ]]
  [ "$(wc -l < "$OUT/sample.csv")" -eq 21 ]
}

@test "--out-dir inside a different git work tree is refused and nothing is written" {
  git init -q "$TEST_TMPDIR/other-clone"
  run python3 "$SCRIPT" "$LOG" --out-dir "$TEST_TMPDIR/other-clone/sheet" --n 10
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/other-clone/sheet" ]
}

@test "spreadsheet formula text in a message is neutralised in sample.csv" {
  python3 - "$LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
msgs = {"c01": "=1+1", "c02": "+1 refund please", "c03": "-2", "c04": "@SUM(1)", "c05": "\tTAB", "c06": ""}
for r in rows:
    if r["item_id"] in msgs and r["state"]:
        r["state"]["message"] = msgs[r["item_id"]]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 200
  [ "$status" -eq 0 ]
  # c06 has a blank message: not emitted, counted with state_null
  [[ "$output" == *"state_null=2"* ]]
  python3 - "$OUT/sample.csv" <<'PY'
import csv, sys
rows = {r["turn_id"].split("|")[1]: r["message"] for r in csv.DictReader(open(sys.argv[1]))}
assert "c06" not in rows
for k, orig in (("c01", "=1+1"), ("c02", "+1 refund please"), ("c03", "-2"), ("c04", "@SUM(1)"), ("c05", "\tTAB")):
    assert rows[k][0] not in "=+-@\t\r\n", (k, rows[k])
    assert rows[k].lstrip("' ") == orig, (k, rows[k])
PY
}

@test "different seeds draw different samples" {
  run python3 "$SCRIPT" "$LOG" --out-dir "$TEST_TMPDIR/a" --n 10 --seed 1
  [ "$status" -eq 0 ]
  run python3 "$SCRIPT" "$LOG" --out-dir "$TEST_TMPDIR/b" --n 10 --seed 2
  [ "$status" -eq 0 ]
  [ -s "$TEST_TMPDIR/a/sample.csv" ]
  [ -s "$TEST_TMPDIR/b/sample.csv" ]
  run cmp -s "$TEST_TMPDIR/a/sample.csv" "$TEST_TMPDIR/b/sample.csv"
  [ "$status" -ne 0 ]
}

@test "pre-existing symlinks in out-dir are replaced, never followed" {
  mkdir -p "$OUT"
  echo precious > "$TEST_TMPDIR/victim1"
  echo precious > "$TEST_TMPDIR/victim2"
  ln -s "$TEST_TMPDIR/victim1" "$OUT/sample.csv"
  ln -s "$TEST_TMPDIR/victim2" "$OUT/key.jsonl"
  run python3 "$SCRIPT" "$LOG" --out-dir "$OUT" --n 10
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/victim1")" = "precious" ]
  [ "$(cat "$TEST_TMPDIR/victim2")" = "precious" ]
  [ ! -L "$OUT/sample.csv" ]
  [ ! -L "$OUT/key.jsonl" ]
  [ -s "$OUT/sample.csv" ]
}
