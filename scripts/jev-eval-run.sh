#!/bin/bash
# ──────────────────────────────────────────────────────────────
# jev-eval-run.sh — replays a gold set (scripts/jev-eval-build.sh's output)
# through a Jev state-builder --variant and scripts/lib/jev.sh, and scores
# the answers against the human/model gold labels.
#
# Usage:
#   jev-eval-run.sh --gold <gold.jsonl> --questions <questions.json> \
#     --variant <v> [--split holdout|tune|all] [--concurrency N] \
#     [--max-unmeasured 2] [--json] [--surface <name>] [--model <model>]
#     [--rows-out <file>] [--include-mid-burst]
#
# For each gold row (filtered by --split, default "all"):
#   1. builds the exact `state` object via
#      `node dist/jev-state-cli.js --variant <v>` (plugins/intercom) from
#      the row's thread_so_far -- the SAME code path production runs, never
#      a reimplementation.
#   2. calls `scripts/lib/jev.sh --no-shadow` with that state + --questions
#      (this run's own eval traffic never pollutes the shadow log).
#   3. compares each answer to the row's label, per question.
#
# A question id present in --questions but absent from the gold label
# schema (LABEL_KEYS in jev-eval-build.sh's lib.py) is reported as
# "not scored", never silently 0-scored. v1 state has no
# `answer_from_knowledge` path option (caroline-questions.json's
# resolution_path enum is ask_customer|caroline_tool|human_required|
# no_reply) -- rows gold-labelled `answer_from_knowledge` are scored as a
# miss for v1 (v1 structurally cannot answer them), AND reported a second
# time in an "excluding answer_from_knowledge" accuracy line, so the number
# a human reads is never silently inflated by a schema gap nobody chose.
#
# Output: accuracy per question, confusion matrix for path/intent/
# first_tool, precision+recall over thresholds 0.50..0.99 step 0.01 for the
# `resolution_path` == no_reply / needs_reply classification, a
# customer-harm count (no_reply predicted while needs_reply=true) per
# threshold, latency p50/p95, mean input_tokens, total cost,
# "measured=<n> unmeasured=<n> total=<n>". Exits non-zero when
# unmeasured/total exceeds --max-unmeasured (percent, default 2).
#
# Exit codes: 0 ok; 2 bad usage; 3 gold file unreadable/empty for the
#   requested split; 4 CLI/jev.sh setup failure (state builder or jev.sh not
#   found/executable); 7 unmeasured rate exceeded --max-unmeasured.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

USAGE="Usage: jev-eval-run.sh --gold <gold.jsonl> --questions <questions.json> --variant <v> [--split holdout|tune|all] [--concurrency N] [--max-unmeasured 2] [--json] [--surface <name>] [--model <model>]"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# JEV_EVAL_JEV_SH_CMD lets tests point at a fake jev.sh without touching the
# real one in-tree (mirrors JEV_EVAL_STATE_CLI_CMD below).
JEV_LIB="${JEV_EVAL_JEV_SH_CMD:-$REPO_ROOT/scripts/lib/jev.sh}"
STATE_CLI="$REPO_ROOT/plugins/intercom/dist/jev-state-cli.js"

_er_die() {
  echo "jev-eval-run.sh: $2" >&2
  exit "$1"
}

gold_file=""
questions_file=""
variant=""
split="all"
concurrency=4
max_unmeasured_pct=2
json_out=0
surface="jev-eval"
model=""
rows_out=""
include_mid_burst=0

while [ $# -gt 0 ]; do
  case "$1" in
    --gold) gold_file="$2"; shift 2 ;;
    --questions) questions_file="$2"; shift 2 ;;
    --variant) variant="$2"; shift 2 ;;
    --split) split="$2"; shift 2 ;;
    --concurrency) concurrency="$2"; shift 2 ;;
    --max-unmeasured) max_unmeasured_pct="$2"; shift 2 ;;
    --json) json_out=1; shift ;;
    --surface) surface="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --rows-out) rows_out="$2"; shift 2 ;;
    --include-mid-burst) include_mid_burst=1; shift ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "$USAGE" >&2; _er_die 2 "unknown argument: $1" ;;
  esac
done

[ -n "$gold_file" ] || _er_die 2 "--gold is required"
[ -n "$questions_file" ] || _er_die 2 "--questions is required"
[ -n "$variant" ] || _er_die 2 "--variant is required"
case "$split" in holdout|tune|all) ;; *) _er_die 2 "--split must be holdout|tune|all (got: $split)" ;; esac
case "$concurrency" in ''|*[!0-9]*|0) _er_die 2 "--concurrency must be a positive integer (got: $concurrency)" ;; esac
case "$max_unmeasured_pct" in ''|*[!0-9]*) _er_die 2 "--max-unmeasured must be a non-negative integer percent (got: $max_unmeasured_pct)" ;; esac

[ -r "$gold_file" ] || _er_die 3 "--gold file not readable: $gold_file"
[ -s "$gold_file" ] || _er_die 3 "--gold file is empty: $gold_file"
[ -r "$questions_file" ] || _er_die 2 "--questions file not readable: $questions_file"

[ -x "$JEV_LIB" ] || _er_die 4 "scripts/lib/jev.sh not found or not executable: $JEV_LIB"

STATE_CLI_CMD=""
if [ -n "${JEV_EVAL_STATE_CLI_CMD:-}" ]; then
  STATE_CLI_CMD="$JEV_EVAL_STATE_CLI_CMD"
elif [ -f "$STATE_CLI" ]; then
  STATE_CLI_CMD="node $STATE_CLI"
else
  _er_die 4 "state-parity CLI not built: $STATE_CLI (run 'pnpm --dir plugins/intercom build', or set JEV_EVAL_STATE_CLI_CMD for tests)"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/jev-eval-run.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Filter by split.
filtered_gold="$work_dir/gold-filtered.jsonl"
if [ "$split" = "all" ]; then
  cp "$gold_file" "$filtered_gold"
else
  jq -c --arg split "$split" 'select(.split == $split)' "$gold_file" > "$filtered_gold" 2>/dev/null || : > "$filtered_gold"
fi
[ -s "$filtered_gold" ] || _er_die 3 "no rows in $gold_file for --split $split"

# Drop mid-burst turns: a customer message followed directly by another
# customer message in the same thread. Production coalesces a burst and asks
# Jev once, about its LAST message, so a mid-burst turn is never a decision
# point; scoring it would grade Jev on a question it is never asked. The
# count is printed, so the exclusion is visible, never silent.
n_mid_burst=0
if [ "$include_mid_burst" -eq 0 ]; then
  burst_kept="$work_dir/gold-no-mid-burst.jsonl"
  jq -c 'select(
      (.full_thread.parts // null) as $p
      | if $p == null then true
        else ((.turn_index + 1) >= ($p | length)) or ($p[.turn_index + 1].author != "user")
        end)' "$filtered_gold" > "$burst_kept"
  n_mid_burst=$(( $(grep -c . "$filtered_gold") - $(grep -c . "$burst_kept" || true) ))
  mv "$burst_kept" "$filtered_gold"
  if [ "$n_mid_burst" -gt 0 ]; then
    echo "jev-eval-run.sh: excluded $n_mid_burst mid-burst turn(s) (not decision points; --include-mid-burst keeps them)" >&2
  fi
  [ -s "$filtered_gold" ] || _er_die 3 "no rows left after excluding mid-burst turns"
fi

# ── per-row worker ──────────────────────────────────────────────
# Writes one result JSON line to its own output file; run under xargs -P
# for --concurrency. Never lets a single row's failure abort the sweep --
# a row that cannot be measured (state-build error, jev.sh non-zero,
# unparseable answers) is written with measured=false and the reason, so
# the caller can count it without dropping it.
run_row() {
  local row_json="$1" out_file="$2"
  local row_file thread_file state_file answers_file
  row_file="$(mktemp "${TMPDIR:-/tmp}/jev-eval-row.XXXXXX")"
  thread_file="$(mktemp "${TMPDIR:-/tmp}/jev-eval-row-thread.XXXXXX")"
  state_file="$(mktemp "${TMPDIR:-/tmp}/jev-eval-row-state.XXXXXX")"
  answers_file="$(mktemp "${TMPDIR:-/tmp}/jev-eval-row-answers.XXXXXX")"
  trap 'rm -f "$row_file" "$thread_file" "$state_file" "$answers_file"' RETURN

  # The row carries the whole conversation, which can pass Linux's 128 KiB
  # per-argument limit, so jq reads it from a file (--slurpfile), never argv.
  printf '%s' "$row_json" > "$row_file"
  jq -c '.thread_so_far' "$row_file" > "$thread_file"

  local state_rc=0
  $STATE_CLI_CMD --variant "$variant" < "$thread_file" > "$state_file" 2>"$state_file.err" || state_rc=$?
  if [ "$state_rc" -ne 0 ]; then
    jq -nc --slurpfile row "$row_file" --arg reason "state-build failed: $(cat "$state_file.err" 2>/dev/null | tr '\n' ' ')" \
      '{row:$row[0], measured:false, reason:$reason}' > "$out_file"
    rm -f "$state_file.err"
    return 0
  fi
  rm -f "$state_file.err"

  local conv_id turn_index item_id
  conv_id=$(jq -r '.conv_id' "$row_file")
  turn_index=$(jq -r '.turn_index' "$row_file")
  item_id="${conv_id}-${turn_index}"

  local jev_args=(--surface "$surface" --item-id "$item_id" --state-file "$state_file" \
    --questions-file "$questions_file" --no-shadow)
  [ -n "$model" ] && jev_args+=(--model "$model")

  local t0 t1 latency_ms jev_rc
  t0=$(python3 -c 'import time;print(int(time.time()*1000))')
  jev_rc=0
  "$JEV_LIB" "${jev_args[@]}" > "$answers_file" 2>"$answers_file.err" || jev_rc=$?
  t1=$(python3 -c 'import time;print(int(time.time()*1000))')
  latency_ms=$((t1 - t0))

  if [ "$jev_rc" -ne 0 ]; then
    jq -nc --slurpfile row "$row_file" --arg reason "jev.sh exit $jev_rc: $(cat "$answers_file.err" 2>/dev/null | tr '\n' ' ')" \
      '{row:$row[0], measured:false, reason:$reason}' > "$out_file"
    rm -f "$answers_file.err"
    return 0
  fi
  rm -f "$answers_file.err"

  if ! jq -e 'type == "object"' "$answers_file" >/dev/null 2>&1; then
    jq -nc --slurpfile row "$row_file" --arg reason "jev.sh answers not a JSON object" \
      '{row:$row[0], measured:false, reason:$reason}' > "$out_file"
    return 0
  fi

  # An object with the right top-level shape can still carry an unusable
  # answer per-question (missing question, a value that doesn't match its
  # declared type, or a `type` field that's simply absent/mismatched) --
  # score.py's per-question accuracy loop has no sensible fallback for
  # those, so they must be caught here as unmeasured rather than silently
  # counted as measured with a garbage prediction. `top_choice()` (mirrored
  # below -- keep in sync with score.py's copy) is the actual reader
  # score.py uses, so an answer it can't read is unmeasured too, even when
  # every per-field shape check above passed (QA re-review finding 1: a
  # `type`-less `{"choice":"x"}` used to pass the old .choice-only check,
  # then top_choice() silently returned (None, None) and the question was
  # dropped from `n` instead of failing the row).
  local answer_problem
  answer_problem="$(python3 - "$questions_file" "$answers_file" <<'PYEOF'
import json, sys

questions_file, answers_file = sys.argv[1], sys.argv[2]
with open(questions_file) as f:
    questions = json.load(f)
with open(answers_file) as f:
    answers = json.load(f)

def is_unit_prob(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= 1

# Mirrors the top_choice() function in score.py exactly (an unpaired
# apostrophe anywhere in this heredoc trips a real bash-below-4
# command-substitution parser bug on macOS system bash, so every comment in
# here must stay apostrophe-free) -- an answer this function cannot
# extract a prediction from must never be counted as measured.
def top_choice(ans):
    if not isinstance(ans, dict):
        return None, None
    t = ans.get("type")
    if t == "choice":
        return ans.get("choice"), ans.get("probabilities", {}).get(ans.get("choice"))
    if t == "noul":
        noul = ans.get("noul")
        if not isinstance(noul, (int, float)) or isinstance(noul, bool):
            return None, None
        return ("true" if noul >= 0.5 else "false"), (noul if noul >= 0.5 else 1 - noul)
    if t == "score":
        probs = ans.get("probabilities")
        if not isinstance(probs, dict) or not probs:
            return None, None
        try:
            keys = sorted(probs.keys(), key=float)
        except (TypeError, ValueError):
            return None, None
        best_k, best_p = None, None
        for k in keys:
            p = probs.get(k)
            if not isinstance(p, (int, float)) or isinstance(p, bool):
                continue
            if best_p is None or p > best_p:
                best_k, best_p = k, p
        return best_k, best_p
    return None, None

for qid, qdef in questions.items():
    qtype = qdef.get("type") if isinstance(qdef, dict) else None
    a = answers.get(qid)
    if not isinstance(a, dict):
        print(f"question '{qid}' missing from answers")
        break
    if a.get("type") != qtype:
        print(f"question '{qid}' has type {a.get('type')!r}, expected {qtype!r}")
        break
    if qtype == "choice":
        if not isinstance(a.get("choice"), str) or not a["choice"]:
            print(f"question '{qid}' (choice) missing/invalid .choice")
            break
        # The threshold and customer-harm sweeps read the probability of the
        # chosen option; without a numeric one the row would count toward
        # accuracy but silently drop out of those sweeps.
        probs = a.get("probabilities")
        if not isinstance(probs, dict) or not is_unit_prob(probs.get(a["choice"])):
            print(f"question '{qid}' (choice) has no numeric probability in [0,1] for its choice")
            break
    elif qtype == "noul":
        if not is_unit_prob(a.get("noul")):
            print(f"question '{qid}' (noul) missing/invalid numeric .noul in [0,1]")
            break
    elif qtype == "score":
        v = a.get("score")
        if not isinstance(v, (int, float)) or isinstance(v, bool):
            print(f"question '{qid}' (score) missing/invalid numeric .score")
            break
    # unknown/undeclared qtype: nothing type-specific to enforce here, but
    # top_choice() below still must be able to read it if the schema is
    # ever extended with a new type this validator does not know about yet.
    if qtype in ("choice", "noul", "score"):
        pred, _ = top_choice(a)
        if pred is None:
            print(f"question '{qid}' ({qtype}) answer unreadable by top_choice()")
            break
PYEOF
)"
  if [ -n "$answer_problem" ]; then
    jq -nc --slurpfile row "$row_file" --arg reason "jev.sh answers invalid: $answer_problem" \
      '{row:$row[0], measured:false, reason:$reason}' > "$out_file"
    return 0
  fi

  jq -nc --slurpfile row "$row_file" --slurpfile answers "$answers_file" --argjson latency_ms "$latency_ms" \
    '{row:$row[0], measured:true, answers:$answers[0], latency_ms:$latency_ms}' > "$out_file"
}
export -f run_row
export STATE_CLI_CMD variant JEV_LIB questions_file surface model

# ── run the sweep ──────────────────────────────────────────────
results_dir="$work_dir/results"
mkdir -p "$results_dir"

n=0
: > "$work_dir/rows.tsv"
while IFS= read -r row_json; do
  [ -n "$row_json" ] || continue
  n=$((n + 1))
  printf '%s\t%s\n' "$n" "$row_json" >> "$work_dir/rows.tsv"
done < "$filtered_gold"

while IFS=$'\t' read -r idx row_json; do
  [ -n "$idx" ] || continue
  (run_row "$row_json" "$results_dir/${idx}.json") &
  while [ "$(jobs -r | wc -l)" -ge "$concurrency" ]; do wait -n 2>/dev/null || wait; done
done < "$work_dir/rows.tsv"
wait

# A backgrounded run_row can be lost outright (OOM-killed, SIGKILLed by a
# crashed child) before it ever writes its result file -- that must count
# as unmeasured with a distinguishable reason, never silently shrink `n`
# by leaving a gap in $results_dir (QA re-review finding 6).
while IFS=$'\t' read -r idx row_json; do
  [ -n "$idx" ] || continue
  f="$results_dir/${idx}.json"
  if [ -s "$f" ] && jq -e 'type == "object" and has("measured")' "$f" >/dev/null 2>&1; then
    continue
  fi
  row_tmp="$(mktemp "${TMPDIR:-/tmp}/jev-eval-lost-row.XXXXXX")"
  printf '%s' "$row_json" > "$row_tmp"
  jq -nc --slurpfile row "$row_tmp" '{row:$row[0], measured:false, reason:"worker-lost"}' > "$f"
  rm -f "$row_tmp"
done < "$work_dir/rows.tsv"

results_file="$work_dir/results.jsonl"
: > "$results_file"
for f in "$results_dir"/*.json; do
  [ -e "$f" ] || continue
  cat "$f" >> "$results_file"
  echo >> "$results_file"
done

# Per-row predictions, for reading the misses (holds customer text: 0600).
if [ -n "$rows_out" ]; then
  ( umask 077; cp "$results_file" "$rows_out" )
fi

# ── score (embedded python -- percentile/threshold-sweep/confusion-matrix
# computation belongs there, not jq, same rationale as jev-shadow-report.sh) ──
SCORE_PY="$work_dir/score.py"
cat > "$SCORE_PY" <<'PYEOF'
import json
import math
import sys

results_path, questions_path, variant, max_unmeasured_pct, json_out = sys.argv[1:6]
max_unmeasured_pct = float(max_unmeasured_pct)
json_out = json_out == "1"

with open(questions_path, "r", encoding="utf-8") as fh:
    questions = json.load(fh)
question_ids = list(questions.keys()) if isinstance(questions, dict) else \
    [q.get("id") for q in questions if isinstance(q, dict) and q.get("id")]

# v1's resolution_path enum has no answer_from_knowledge option (confirmed
# against plugins/intercom/src/caroline-questions.json) -- rows gold-labelled
# with it are a structural miss for v1, scored honestly rather than dropped.
V1_MISSING_PATH_OPTIONS = {"answer_from_knowledge", "acknowledge"}

rows = []
with open(results_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

measured = [r for r in rows if r.get("measured")]
unmeasured = [r for r in rows if not r.get("measured")]
total = len(rows)

# A row can measure fine (Jev answered) but carry no gold label at all
# (label: null -- an unparseable/failed labeller run in jev-eval-build.sh).
# The per-question loop below silently `continue`s past those, since
# `label_key not in {}` is true for every key -- that made them vanish from
# both the numerator AND the denominator instead of being surfaced. Split
# them out here so they're counted, printed, and gated on, never dropped.
unlabelled = [r for r in measured if r["row"].get("label") is None]
measured_labelled = [r for r in measured if r["row"].get("label") is not None]

report = {"variant": variant, "total": total, "measured": len(measured), "unmeasured": len(unmeasured),
          "unlabelled": len(unlabelled), "unmeasured_reasons": [], "unlabelled_rows": [],
          "questions": {}, "latency_ms": {}, "input_tokens_mean": None,
          "total_cost": None, "not_scored_questions": []}

for r in unmeasured:
    reason = r.get("reason", "unknown")
    report["unmeasured_reasons"].append({
        "conv_id": r["row"].get("conv_id"), "turn_index": r["row"].get("turn_index"), "reason": reason})

for r in unlabelled:
    report["unlabelled_rows"].append({
        "conv_id": r["row"].get("conv_id"), "turn_index": r["row"].get("turn_index")})

# --- per-question accuracy + confusion matrices ---
def top_choice(ans):
    if not isinstance(ans, dict):
        return None, None
    t = ans.get("type")
    if t == "choice":
        return ans.get("choice"), ans.get("probabilities", {}).get(ans.get("choice"))
    if t == "noul":
        noul = ans.get("noul")
        if not isinstance(noul, (int, float)) or isinstance(noul, bool):
            return None, None
        return ("true" if noul >= 0.5 else "false"), (noul if noul >= 0.5 else 1 - noul)
    if t == "score":
        probs = ans.get("probabilities")
        if not isinstance(probs, dict) or not probs:
            return None, None
        try:
            keys = sorted(probs.keys(), key=float)
        except (TypeError, ValueError):
            return None, None
        best_k, best_p = None, None
        for k in keys:
            p = probs.get(k)
            if not isinstance(p, (int, float)) or isinstance(p, bool):
                continue
            if best_p is None or p > best_p:
                best_k, best_p = k, p
        return best_k, best_p
    return None, None


LABEL_KEYS = {"path", "intent", "first_tool", "needs_reply", "supplying_requested_info",
              "bad_faith", "frustration_level", "rationale"}
QID_TO_LABEL_KEY = {"resolution_path": "path", "intent": "intent", "first_tool": "first_tool",
                     "frustration": "frustration_level"}

for qid in question_ids:
    label_key = QID_TO_LABEL_KEY.get(qid)
    if label_key is None or label_key not in LABEL_KEYS:
        report["not_scored_questions"].append(qid)
        continue

    total_q = 0
    correct_q = 0
    correct_excl_gap = 0
    total_excl_gap = 0
    confusion = {}
    for r in measured:
        label = (r["row"].get("label") or {})
        if label_key not in label or label.get(label_key) is None:
            continue
        gold = label[label_key]
        if label_key == "frustration_level":
            gold = str(gold)
        ans = (r.get("answers") or {}).get(qid)
        pred, _ = top_choice(ans)
        if pred is None:
            continue
        total_q += 1
        gold_s = str(gold)
        confusion.setdefault(gold_s, {}).setdefault(str(pred), 0)
        confusion[gold_s][str(pred)] += 1
        is_correct = str(pred) == gold_s
        if is_correct:
            correct_q += 1
        is_gap_row = label_key == "path" and gold_s in V1_MISSING_PATH_OPTIONS and variant == "v1"
        if not is_gap_row:
            total_excl_gap += 1
            if is_correct:
                correct_excl_gap += 1

    # known_facts (founding/plan/prior_chats) is not reproducible read-only
    # (jev-eval-build.sh's cmd_enumerate marks every row known_facts_missing
    # today, since faithful reproduction needs live admin-API + prior-
    # conversations calls this harness deliberately never fakes) -- so a
    # bare accuracy figure silently claims state parity it does not have.
    # Splitting by the flag keeps that gap visible per question rather than
    # asserting a fact the harness cannot measure (QA re-review finding 3).
    kf_buckets = {"missing": {"total": 0, "correct": 0}, "present": {"total": 0, "correct": 0}}
    for r in measured:
        label = (r["row"].get("label") or {})
        if label_key not in label or label.get(label_key) is None:
            continue
        gold = label[label_key]
        if label_key == "frustration_level":
            gold = str(gold)
        ans = (r.get("answers") or {}).get(qid)
        pred, _ = top_choice(ans)
        if pred is None:
            continue
        bucket = "missing" if (r["row"].get("thread_so_far") or {}).get("known_facts_missing") else "present"
        kf_buckets[bucket]["total"] += 1
        if str(pred) == str(gold):
            kf_buckets[bucket]["correct"] += 1

    report["questions"][qid] = {
        "n": total_q,
        "accuracy": (correct_q / total_q) if total_q else None,
        "accuracy_excluding_v1_path_gap": (correct_excl_gap / total_excl_gap) if total_excl_gap else None,
        "confusion_matrix": confusion,
        "known_facts_missing_split": {
            "missing": {"n": kf_buckets["missing"]["total"],
                        "accuracy": (kf_buckets["missing"]["correct"] / kf_buckets["missing"]["total"])
                        if kf_buckets["missing"]["total"] else None},
            "present": {"n": kf_buckets["present"]["total"],
                        "accuracy": (kf_buckets["present"]["correct"] / kf_buckets["present"]["total"])
                        if kf_buckets["present"]["total"] else None},
        },
    }

# --- precision/recall threshold sweep for no_reply vs needs_reply ---
sweep = []
harm_counts = []
pairs = []  # (needs_reply_gold, predicted_path, predicted_prob)
for r in measured:
    label = (r["row"].get("label") or {})
    if "needs_reply" not in label or label["needs_reply"] is None:
        continue
    ans = (r.get("answers") or {}).get("resolution_path")
    pred, prob = top_choice(ans)
    if pred is None or prob is None:
        continue
    pairs.append((bool(label["needs_reply"]), pred, float(prob)))

thresholds = [round(0.50 + 0.01 * i, 2) for i in range(50)]
for thr in thresholds:
    tp = fp = fn = tn = 0
    harm = 0
    for needs_reply, pred, prob in pairs:
        if prob < thr:
            continue  # below threshold: treated as "not confident enough to act", excluded from PR at this cut
        predicted_no_reply = pred == "no_reply"
        if predicted_no_reply and needs_reply:
            harm += 1
        # Positive class = "no_reply is the correct call" i.e. NOT needs_reply.
        actual_positive = not needs_reply
        predicted_positive = predicted_no_reply
        if predicted_positive and actual_positive:
            tp += 1
        elif predicted_positive and not actual_positive:
            fp += 1
        elif not predicted_positive and actual_positive:
            fn += 1
        else:
            tn += 1
    precision = tp / (tp + fp) if (tp + fp) else None
    recall = tp / (tp + fn) if (tp + fn) else None
    sweep.append({"threshold": thr, "precision": precision, "recall": recall,
                  "n_above_threshold": tp + fp + fn + tn})
    harm_counts.append({"threshold": thr, "no_reply_on_needs_reply_true": harm})

report["threshold_sweep"] = sweep
report["customer_harm_no_reply_on_needs_reply_true"] = harm_counts

# --- latency / tokens / cost ---
latencies = sorted(r["latency_ms"] for r in measured if isinstance(r.get("latency_ms"), (int, float)))


def pctile(vals, p):
    if not vals:
        return None
    idx = max(0, math.ceil(p * len(vals)) - 1)
    return vals[idx]


report["latency_ms"] = {"p50": pctile(latencies, 0.5), "p95": pctile(latencies, 0.95)}

token_vals = [r["answers"].get("_input_tokens") for r in measured
              if isinstance(r.get("answers"), dict) and isinstance(r["answers"].get("_input_tokens"), (int, float))]
report["input_tokens_mean"] = (sum(token_vals) / len(token_vals)) if token_vals else None

cost_vals = [r["answers"].get("_cost") for r in measured
             if isinstance(r.get("answers"), dict) and isinstance(r["answers"].get("_cost"), (int, float))]
report["total_cost"] = sum(cost_vals) if cost_vals else None

unmeasured_pct = (100.0 * len(unmeasured) / total) if total else 0.0
report["unmeasured_pct"] = unmeasured_pct
report["max_unmeasured_pct"] = max_unmeasured_pct
# An unlabelled row is just as unusable for scoring as an unmeasured one --
# both leave a decision point with no verified accuracy number behind it --
# so the gate must fail on either, not just on jev.sh/state-build failures.
unlabelled_pct = (100.0 * len(unlabelled) / total) if total else 0.0
report["unlabelled_pct"] = unlabelled_pct
report["gate_failed"] = (unmeasured_pct + unlabelled_pct) > max_unmeasured_pct

# State parity is a property of how the row was BUILT (jev-eval-build.sh),
# not of whether it measured -- count over every row in the sweep, never
# just the measured subset, so this line stays accurate even when
# unmeasured/unlabelled rows are dropped from the scoring loops above.
known_facts_missing_rows = sum(
    1 for r in rows if (r["row"].get("thread_so_far") or {}).get("known_facts_missing"))
report["known_facts_missing_rows"] = known_facts_missing_rows

if json_out:
    print(json.dumps(report))
else:
    print(f"variant={variant} total={total} measured={len(measured)} unmeasured={len(unmeasured)} "
          f"unlabelled={len(unlabelled)} "
          f"unmeasured_pct={unmeasured_pct:.1f}% unlabelled_pct={unlabelled_pct:.1f}% "
          f"(max combined {max_unmeasured_pct:.1f}%)")
    if report["not_scored_questions"]:
        print(f"not scored (no gold label schema match): {', '.join(report['not_scored_questions'])}")
    for qid, q in report["questions"].items():
        acc = "n/a" if q["accuracy"] is None else f"{100*q['accuracy']:.1f}%"
        acc2 = "n/a" if q["accuracy_excluding_v1_path_gap"] is None else f"{100*q['accuracy_excluding_v1_path_gap']:.1f}%"
        print(f"  {qid}: n={q['n']} accuracy={acc} accuracy_excl_v1_path_gap={acc2}")
        for gold, preds in sorted(q["confusion_matrix"].items()):
            print(f"    gold={gold}: " + ", ".join(f"{p}={n}" for p, n in sorted(preds.items())))
        kf = q["known_facts_missing_split"]
        kf_missing_acc = "n/a" if kf["missing"]["accuracy"] is None else f"{100*kf['missing']['accuracy']:.1f}%"
        kf_present_acc = "n/a" if kf["present"]["accuracy"] is None else f"{100*kf['present']['accuracy']:.1f}%"
        print(f"    known_facts_missing: n={kf['missing']['n']} accuracy={kf_missing_acc}")
        print(f"    known_facts_present: n={kf['present']['n']} accuracy={kf_present_acc}")
    print(f"state parity: known_facts not reproduced for {report['known_facts_missing_rows']}/{total} rows")
    print("threshold sweep (resolution_path no_reply vs needs_reply):")
    for s, h in zip(report["threshold_sweep"], report["customer_harm_no_reply_on_needs_reply_true"]):
        p = "n/a" if s["precision"] is None else f"{100*s['precision']:.1f}%"
        r_ = "n/a" if s["recall"] is None else f"{100*s['recall']:.1f}%"
        print(f"  thr={s['threshold']:.2f} precision={p} recall={r_} n={s['n_above_threshold']} "
              f"customer_harm(no_reply_on_needs_reply_true)={h['no_reply_on_needs_reply_true']}")
    lat = report["latency_ms"]
    print(f"latency_ms: p50={lat['p50']} p95={lat['p95']}")
    print(f"input_tokens_mean={report['input_tokens_mean']}")
    print(f"total_cost={report['total_cost']}")
    if report["unmeasured_reasons"]:
        print("unmeasured rows:")
        for u in report["unmeasured_reasons"]:
            print(f"  conv={u['conv_id']} turn={u['turn_index']}: {u['reason']}")
    if report["unlabelled_rows"]:
        print("unlabelled rows (measured, but gold label is null):")
        for u in report["unlabelled_rows"]:
            print(f"  conv={u['conv_id']} turn={u['turn_index']}")

sys.exit(1 if report["gate_failed"] else 0)
PYEOF

set +e
python3 "$SCORE_PY" "$results_file" "$questions_file" "$variant" "$max_unmeasured_pct" "$json_out"
score_rc=$?
set -e
if [ "$score_rc" -ne 0 ]; then
  _er_die 7 "unmeasured rate exceeded --max-unmeasured ($max_unmeasured_pct%)"
fi
