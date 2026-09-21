#!/bin/bash
# ──────────────────────────────────────────────────────────────
# jev-shadow-report.sh — reads the shadow JSONL written by scripts/lib/jev.sh
# and prints a plain-text calibration table per (surface, question id):
# probability bucket, n, agreement %, plus a per-surface footer (total lines,
# rc != 0 count, p50/p95 latency_ms).
#
# Usage:
#   jev-shadow-report.sh [--surface <name>] [--window-hours <N>] \
#     [--shadow-dir <dir>]
#
# Aggregation is implemented in an embedded python3 script (not jq): it needs
# per-answer-type dispatch (noul/choice/score), a percentile calc, and
# per-line malformed-row skipping without aborting the whole read -- that
# combination turned into an unreadable, hard-to-debug jq program (nested
# def/object-construction collided with jq's parser). python3 is present on
# node-8 and in CI (scripts/customer_outcome.py already depends on it), and
# embedding it here (rather than a sibling .py file) keeps one script, one
# file, per the "one language per concern" rule.
#
# Every row is validated as a whole and processed under a guard; a malformed
# row is counted, never fatal.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

: "${JEV_SHADOW_DIR:=/var/lib/hydra-jev/shadow}"

surface=""
window_hours=""
shadow_dir="$JEV_SHADOW_DIR"

while [ $# -gt 0 ]; do
  case "$1" in
    --surface) surface="$2"; shift 2 ;;
    --window-hours) window_hours="$2"; shift 2 ;;
    --shadow-dir) shadow_dir="$2"; shift 2 ;;
    *) echo "jev-shadow-report.sh: unknown argument: $1" >&2; exit 5 ;;
  esac
done

# --surface becomes a path component ($shadow_dir/<surface>.jsonl), so it
# must have the same shape jev.sh enforces on write: no slash, whitespace,
# or leading dot (path traversal / escaping the shadow dir).
if [ -n "$surface" ]; then
  case "$surface" in
    [A-Za-z0-9]*) ;;
    *) echo "jev-shadow-report.sh: invalid --surface" >&2; exit 2 ;;
  esac
  case "$surface" in
    *[!A-Za-z0-9._-]*) echo "jev-shadow-report.sh: invalid --surface" >&2; exit 2 ;;
  esac
fi

python3 - "$shadow_dir" "$surface" "$window_hours" <<'PY'
import glob
import json
import math
import os
import sys
from datetime import datetime, timezone

shadow_dir, surface, window_hours = sys.argv[1], sys.argv[2], sys.argv[3]

if surface:
    paths = [os.path.join(shadow_dir, f"{surface}.jsonl")]
    paths = [p for p in paths if os.path.isfile(p)]
else:
    paths = sorted(glob.glob(os.path.join(shadow_dir, "*.jsonl")))

cutoff = None
if window_hours:
    cutoff = datetime.now(timezone.utc).timestamp() - float(window_hours) * 3600

# The 0.0-0.5 bucket exists because a multi-way choice/score winner (e.g. an
# 11-way router intent) can legitimately have a top probability below 0.5 by
# construction -- unlike noul, whose top probability is always >= 0.5
# (max(p, 1-p)). Without this bucket those valid answers landed nowhere and
# were silently dropped from the shadow-week data.
BUCKETS = [(0.0, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.0001)]
BUCKET_LABELS = ["0.0-0.5", "0.5-0.6", "0.6-0.7", "0.7-0.8", "0.8-0.9", "0.9-1.0"]


def parse_ts(ts):
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None


def _prob_ok(p):
    # A usable probability is a real number (not bool), finite, in [0, 1].
    # Anything else -- a string "0.9" from vendor drift, NaN, 1.7 -- is a
    # malformed answer and must never reach the bucket comparison.
    return isinstance(p, (int, float)) and not isinstance(p, bool) and math.isfinite(p) and 0.0 <= p <= 1.0


def top_answer(ans):
    # Returns (answer_str, probability) or (None, None) if the shape is
    # unrecognized (never raises -- a malformed answer just contributes
    # nothing to the bucket table).
    if not isinstance(ans, dict):
        return None, None
    t = ans.get("type")
    if t == "noul":
        noul = ans.get("noul")
        if not _prob_ok(noul):
            return None, None
        return ("true" if noul >= 0.5 else "false"), (noul if noul >= 0.5 else 1 - noul)
    if t == "choice":
        choice = ans.get("choice")
        probabilities = ans.get("probabilities")
        prob = probabilities.get(choice) if isinstance(probabilities, dict) else None
        if choice is None or not _prob_ok(prob):
            return None, None
        return choice, prob
    if t == "score":
        score = ans.get("score")
        if not isinstance(score, (int, float)) or isinstance(score, bool) or not math.isfinite(score):
            return None, None
        # TypeSafe defines `score` as the probability-weighted MEAN
        # (docs.typesafe.ai/primitives/score), not the mode -- a shape like
        # {score: 1.0, probabilities: {"0": 0.5, "1": 0.0, "2": 0.5}} is
        # valid, and round(score) would pick level "1" at probability 0.
        # "Top answer" means the level carrying the most probability mass,
        # so select by argmax over probabilities instead; on an exact tie,
        # pick the lowest numeric key (deterministic).
        probabilities = ans.get("probabilities")
        if not isinstance(probabilities, dict) or not probabilities:
            return None, None
        try:
            candidate_keys = sorted(probabilities.keys(), key=float)
        except (TypeError, ValueError):
            return None, None
        key = None
        prob = None
        for k in candidate_keys:
            p = probabilities.get(k)
            if not _prob_ok(p):
                continue
            if prob is None or p > prob:
                key = k
                prob = p
        if key is None:
            return None, None
        legend = ans.get("legend")
        label = legend.get(key, key) if isinstance(legend, dict) else key
        return label, prob
    return None, None


def pctile(sorted_vals, p):
    if not sorted_vals:
        return None
    # Nearest-rank, includes the upper tail on small samples (a floor-based
    # int(p * (n - 1)) index hides the worst value entirely on n<=~10).
    idx = max(0, math.ceil(p * len(sorted_vals)) - 1)
    return sorted_vals[idx]


def row_ok(row):
    # Whole-row shape check, run once per row before any field is used. A
    # row that fails this is malformed and must never reach the bucketing
    # logic below -- checking fields one at a time as crashes are reported
    # is the bug class this closes (an unhashable `surface` was the latest
    # instance; the next one would just be a different field).
    if not isinstance(row, dict):
        return False
    surface = row.get("surface")
    if not isinstance(surface, str) or not surface:
        return False
    ts = row.get("ts")
    if ts is not None and not isinstance(ts, str):
        return False
    answers = row.get("answers")
    if answers is not None and not isinstance(answers, dict):
        return False
    actual = row.get("actual")
    if actual is not None and not isinstance(actual, (str, dict)):
        return False
    latency_ms = row.get("latency_ms")
    if latency_ms is not None and (not isinstance(latency_ms, (int, float)) or isinstance(latency_ms, bool)):
        return False
    rc = row.get("rc")
    if rc is not None and (not isinstance(rc, int) or isinstance(rc, bool)):
        return False
    return True


undated = 0  # rows dropped from a windowed report for a missing/unparseable ts
malformed = 0  # rows that parsed as JSON but failed row_ok, or blew up while being processed
surfaces = {}  # surface -> {"lines": [...], "questions": {qid: [ (bucket_idx, answer, actual) ]}}

for path in paths:
    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                row = json.loads(raw_line)
            except Exception:
                malformed += 1
                continue
            if not row_ok(row):
                malformed += 1
                continue

            # Every row that passes row_ok is still processed under a guard:
            # row_ok only checks the row's own shape, not every shape a
            # nested answer/actual value can take, so this is the backstop
            # that keeps a still-unanticipated shape from aborting the report.
            try:
                ts = row.get("ts")
                t = parse_ts(ts) if ts else None
                if cutoff is not None:
                    # A windowed report must not keep undated or unparseable
                    # rows forever: with no usable ts the row cannot be placed
                    # inside the window, so it is excluded (and counted).
                    if t is None:
                        undated += 1
                        continue
                    if t < cutoff:
                        continue

                surf = row["surface"]
                entry = surfaces.setdefault(surf, {"lines": [], "questions": {}})
                entry["lines"].append(row)

                answers = row.get("answers")
                actual = row.get("actual")
                if isinstance(answers, dict):
                    for qid, ans in answers.items():
                        if not isinstance(ans, dict):
                            continue
                        answer, prob = top_answer(ans)
                        if prob is None:
                            continue
                        bucket_idx = None
                        for i, (lo, hi) in enumerate(BUCKETS):
                            if lo <= prob < hi:
                                bucket_idx = i
                                break
                        if bucket_idx is None:
                            # Unreachable for a valid probability now that the
                            # 0.0-0.5 bucket covers [0, 1] end to end; kept as a
                            # defensive skip in case a future bucket edit reopens
                            # a gap.
                            continue
                        # actual is one string for every question, or an object keyed by question id
                        actual_q = actual.get(qid) if isinstance(actual, dict) else actual
                        entry["questions"].setdefault(qid, []).append((bucket_idx, answer, actual_q))
            except Exception:
                malformed += 1
                continue

if not surfaces:
    print("no shadow lines")
    sys.exit(0)

for surf in sorted(surfaces):
    data = surfaces[surf]
    print(f"== {surf} ==")
    for qid in sorted(data["questions"]):
        print(f"  question: {qid}")
        print("    bucket      n   agreement")
        rows = data["questions"][qid]
        for i, label in enumerate(BUCKET_LABELS):
            in_bucket = [r for r in rows if r[0] == i]
            n = len(in_bucket)
            if n == 0:
                continue
            judged = [r for r in in_bucket if r[2] is not None]
            if not judged:
                agreement = "n/a"
            else:
                matched = sum(1 for r in judged if r[1] == r[2])
                agreement = f"{round(100 * matched / len(judged), 1)}%"
            print(f"    {label}   {n}   {agreement}")

    lines = data["lines"]
    total = len(lines)
    rc_nonzero = sum(1 for r in lines if r.get("rc") not in (0, None))
    latencies = sorted(
        r["latency_ms"] for r in lines
        if isinstance(r.get("latency_ms"), (int, float))
    )
    p50 = pctile(latencies, 0.5)
    p95 = pctile(latencies, 0.95)
    p50_s = "n/a" if p50 is None else str(p50)
    p95_s = "n/a" if p95 is None else str(p95)
    tail = f" undated_excluded={undated}" if cutoff is not None else ""
    print(f"  -- footer: total={total} rc_nonzero={rc_nonzero} p50_ms={p50_s} p95_ms={p95_s}{tail} malformed_rows={malformed}")
    print()
PY
