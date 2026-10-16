#!/bin/bash
# ──────────────────────────────────────────────────────────────
# jev-shadow-report.sh — reads the shadow JSONL written by scripts/lib/jev.sh
# and prints a plain-text calibration table per (surface, question id):
# probability bucket, n, agreement %, plus a footer per (surface,
# questions_version) -- total lines, rc != 0 count and rate, p50/p95 latency_ms.
# Rows with no questions_version are labelled v1-legacy, never folded into v1.
#
# Usage:
#   jev-shadow-report.sh [--surface <name>] [--window-hours <N>] \
#     [--shadow-dir <dir>] [--outcomes <path>] [--pair-versions] [--router-agreement]
#
# Without --outcomes the agreement column is omitted: row["actual"] is the
# action Jev's own router took, so scoring against it is Jev vs itself and
# only ever reads as a product signal by mistake. --router-agreement brings
# that column back for debugging the logger; it is not accuracy.
#
# --pair-versions replaces the per-version tables with a v1-vs-v2 report: per
# (surface, item_id) a v1 row is paired with the nearest unused v2 row within
# 5.0 s (the turn definition measured in MUS-1541), and per question we print
# the share of pairs whose top option differs, bucketed on v1's probability,
# plus the most common v1_option -> v2_option transitions. Rows that cannot
# pair (rc != 0, unversioned v1-legacy, partner missing or outside 5 s) are
# counted in the footer, never dropped silently.
#
# --outcomes joins each shadow row to a ground-truth sidecar JSONL (one
# record per conversation turn, keyed by surface/item_id/ts -- see
# scripts/jev-outcomes-collect.py for the writer) and scores agreement
# against that instead of the router's own action in row["actual"]. Absent,
# the report is unchanged from before this flag existed.
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
outcomes_path=""
pair_versions=0
router_agreement=0

while [ $# -gt 0 ]; do
  case "$1" in
    --surface) surface="$2"; shift 2 ;;
    --window-hours) window_hours="$2"; shift 2 ;;
    --shadow-dir) shadow_dir="$2"; shift 2 ;;
    --outcomes) outcomes_path="$2"; shift 2 ;;
    --pair-versions) pair_versions=1; shift ;;
    --router-agreement) router_agreement=1; shift ;;
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

python3 - "$shadow_dir" "$surface" "$window_hours" "$outcomes_path" "$pair_versions" "$router_agreement" <<'PY'
import glob
import json
import math
import os
import sys
from datetime import datetime, timezone

shadow_dir, surface, window_hours, outcomes_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pair_versions = sys.argv[5] == "1"
show_agreement = bool(outcomes_path) or sys.argv[6] == "1"
PAIR_WINDOW_S = 5.0

if surface:
    paths = [os.path.join(shadow_dir, f"{surface}.jsonl")]
    paths = [p for p in paths if os.path.isfile(p)]
else:
    paths = sorted(glob.glob(os.path.join(shadow_dir, "*.jsonl")))
    # Outcomes sidecars (<name>.outcomes.jsonl) are ground truth, not shadow
    # logs, but the producer writes them into this same directory. Drop them
    # by name so an alternate --outcomes path elsewhere cannot leave the
    # default sidecar to be parsed as shadow rows; also drop the selected
    # file by realpath (it may have any name). realpath both sides so ./x, an
    # absolute join and a symlinked shadow dir all resolve to the same file.
    paths = [p for p in paths if not p.endswith(".outcomes.jsonl")]
    if outcomes_path:
        outcomes_real = os.path.realpath(outcomes_path)
        paths = [p for p in paths if os.path.realpath(p) != outcomes_real]

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


def parse_ts_precise(ts):
    # The live writer stamps new Date().toISOString() (milliseconds); parse_ts
    # above is whole-second only, which is too coarse for a 5 s pairing window.
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
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


def outcome_row_ok(row):
    # Whole-row shape check for a ground-truth sidecar record, mirroring
    # row_ok's discipline: validate the whole shape before any field is
    # used, so one bad record can never abort the read.
    if not isinstance(row, dict):
        return False
    surface = row.get("surface")
    if not isinstance(surface, str) or not surface:
        return False
    item_id = row.get("item_id")
    if not isinstance(item_id, str) or not item_id:
        return False
    row_ts = row.get("row_ts")
    if not isinstance(row_ts, list) or not row_ts or not all(isinstance(t, str) for t in row_ts):
        return False
    truth = row.get("truth")
    if not isinstance(truth, dict):
        return False
    return True


undated = 0  # rows dropped from a windowed report for a missing/unparseable ts
malformed = 0  # rows that parsed as JSON but failed row_ok, or blew up while being processed
pair_rows = []  # (surface, item_id, version, precise ts or None, row) -- only filled under --pair-versions
surfaces = {}  # (surface, questions_version) -> {"lines": [...], "questions": {qid: [ (bucket_idx, answer, actual) ]}}

# outcomes_truth[(surface, item_id, ts)] -> truth dict. Absent key means "no
# matching outcome record" (never scored); a present record whose truth omits
# a qid means "unlabelled for that question" -- both must yield actual_q=None
# but the footer's outcomes_matched distinguishes the two by counting only
# the former as unmatched.
outcomes_truth = {}
outcomes_rows_by_surface = {}    # surface -> count of valid outcome records (pre row_ts expansion)
outcomes_matched_by_bucket = {}  # (surface, questions_version) -> count of shadow rows whose join found a truth record

if outcomes_path:
    with open(outcomes_path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                orow = json.loads(raw_line)
            except Exception:
                malformed += 1
                continue
            if not outcome_row_ok(orow):
                malformed += 1
                continue
            try:
                osurf = orow["surface"]
                oitem = orow["item_id"]
                otruth = orow["truth"]
                outcomes_rows_by_surface[osurf] = outcomes_rows_by_surface.get(osurf, 0) + 1
                for ts in orow["row_ts"]:
                    outcomes_truth[(osurf, oitem, ts)] = otruth
            except Exception:
                malformed += 1
                continue

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
                # pair mode keeps the live writer's milliseconds (parse_ts is
                # whole-second and would drop every fresh row from a window)
                t = (parse_ts_precise(ts) if pair_versions else parse_ts(ts)) if ts else None
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
                # Live (v1) and shadow (v2) calls share one surface file; a row
                # with no questions_version predates the field and is kept
                # apart as v1-legacy so it cannot inflate v1's failure rate.
                ver = row.get("questions_version")
                ver = ver if isinstance(ver, str) and ver else "v1-legacy"
                entry = surfaces.setdefault((surf, ver), {"lines": [], "questions": {}})
                entry["lines"].append(row)
                if pair_versions:
                    pair_rows.append((surf, row.get("item_id"), ver, parse_ts_precise(ts) if ts else None, row))

                truth_rec = None
                if outcomes_path:
                    truth_rec = outcomes_truth.get((surf, row.get("item_id"), row.get("ts")))
                    if truth_rec is not None:
                        outcomes_matched_by_bucket[(surf, ver)] = outcomes_matched_by_bucket.get((surf, ver), 0) + 1

                answers = row.get("answers")
                # actual is the router's own action, not ground truth -- with
                # --outcomes it must never enter the comparison, so it is not
                # even read in that mode (see truth_rec above).
                actual = None if outcomes_path else row.get("actual")
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
                        if outcomes_path:
                            # No fallback to row["actual"] -- a qid absent
                            # from the matched (or unmatched) truth record is
                            # unlabelled, never silently scored.
                            actual_q = truth_rec.get(qid) if truth_rec is not None else None
                        else:
                            # actual is one string for every question, or an object keyed by question id
                            actual_q = actual.get(qid) if isinstance(actual, dict) else actual
                        entry["questions"].setdefault(qid, []).append((bucket_idx, answer, actual_q))
            except Exception:
                malformed += 1
                continue

if not surfaces:
    print("no shadow lines")
    sys.exit(0)

def report_pairs():
    by_surf = {}
    for surf, item, ver, t, row in pair_rows:
        by_surf.setdefault(surf, []).append((item, ver, t, row))
    for surf in sorted(by_surf):
        print(f"== {surf} ==")
        rc_nonzero = v1_legacy = other_version = 0
        groups = {}
        for item, ver, t, row in by_surf[surf]:
            if row.get("rc") not in (0, None):
                rc_nonzero += 1
            elif ver == "v1-legacy":
                v1_legacy += 1
            elif ver not in ("v1", "v2"):
                other_version += 1
            elif not isinstance(row.get("answers"), dict) or t is None or not isinstance(item, str):
                # a usable pair row needs answers, a parseable ts and an item_id
                groups.setdefault(None, []).append((ver, t, row))
            else:
                groups.setdefault(item, []).append((ver, t, row))
        candidates = sum(len(v) for v in groups.values())
        paired = 0
        q_not_compared = 0
        stats = {}  # qid -> {bucket_idx: [n, disagree]}
        trans = {}  # qid -> {(v1_opt, v2_opt): n}
        for item, members in groups.items():
            if item is None:
                continue
            v1s = sorted((m for m in members if m[0] == "v1"), key=lambda m: m[1])
            v2s = [m for m in members if m[0] == "v2"]
            used = set()
            for _, t1, r1 in v1s:
                best = None
                for j, (_, t2, _r2) in enumerate(v2s):
                    if j in used:
                        continue
                    gap = abs(t2 - t1)
                    if gap <= PAIR_WINDOW_S and (best is None or gap < best[0]):
                        best = (gap, j)
                if best is None:
                    continue
                used.add(best[1])
                paired += 1
                a2 = v2s[best[1]][2]["answers"]
                for qid, ans1 in r1["answers"].items():
                    try:
                        o1, p1 = top_answer(ans1)
                        o2, _p2 = top_answer(a2.get(qid))
                    except TypeError:
                        # e.g. an unhashable nested choice: count it, never abort
                        q_not_compared += 1
                        continue
                    if p1 is None or o2 is None:
                        q_not_compared += 1
                        continue
                    bi = next((i for i, (lo, hi) in enumerate(BUCKETS) if lo <= p1 < hi), None)
                    if bi is None:
                        q_not_compared += 1
                        continue
                    cell = stats.setdefault(qid, {}).setdefault(bi, [0, 0])
                    cell[0] += 1
                    cell[1] += 1 if o1 != o2 else 0
                    tk = trans.setdefault(qid, {})
                    tk[(o1, o2)] = tk.get((o1, o2), 0) + 1
        for qid in sorted(stats):
            print(f"  question: {qid}")
            print("    bucket(v1)  n_paired   disagree%")
            for i, label in enumerate(BUCKET_LABELS):
                if i in stats[qid]:
                    n, d = stats[qid][i]
                    print(f"    {label}   {n}   {round(100 * d / n, 1)}%")
            print("    v1 -> v2 transitions:")
            for (o1, o2), n in sorted(trans[qid].items(), key=lambda kv: (-kv[1], str(kv[0])))[:10]:
                print(f"      {o1} -> {o2}   {n}")
        unpaired = candidates - 2 * paired
        print(f"  -- pairing footer: paired={paired} unpaired={unpaired} rc_nonzero={rc_nonzero} v1_legacy={v1_legacy} other_version={other_version} q_not_compared={q_not_compared} window_s={PAIR_WINDOW_S} malformed_rows={malformed}")
        print()


if pair_versions:
    report_pairs()
    sys.exit(0)

last_surf = None
for surf, ver in sorted(surfaces):
    data = surfaces[(surf, ver)]
    if surf != last_surf:
        print(f"== {surf} ==")
        last_surf = surf
    print(f"  --- questions_version: {ver} ---")
    for qid in sorted(data["questions"]):
        print(f"  question: {qid}")
        print("    bucket      n   agreement" if show_agreement else "    bucket      n")
        rows = data["questions"][qid]
        for i, label in enumerate(BUCKET_LABELS):
            in_bucket = [r for r in rows if r[0] == i]
            n = len(in_bucket)
            if n == 0:
                continue
            judged = [r for r in in_bucket if r[2] is not None]
            if not show_agreement:
                print(f"    {label}   {n}")
                continue
            if not judged:
                agreement = "n/a"
            else:
                matched = sum(1 for r in judged if r[1] == r[2])
                agreement = f"{round(100 * matched / len(judged), 1)}%"
            print(f"    {label}   {n}   {agreement}")
        if outcomes_path:
            labelled = sum(1 for r in rows if r[2] is not None)
            unlabelled = len(rows) - labelled
            print(f"    -- labelled={labelled} unlabelled={unlabelled}")

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
    if outcomes_path:
        # outcomes_rows is surface-scoped by construction: a sidecar record
        # carries no questions_version, so it cannot be split per bucket and
        # the same count is correct under every version footer. outcomes_matched
        # counts shadow rows, and each shadow row belongs to exactly one
        # (surface, questions_version) bucket, so it IS bucket-scoped -- keying
        # it by surface would print the surface-wide total under every version
        # footer and reinstate the live/shadow pooling this script now splits.
        tail += (
            f" outcomes_rows={outcomes_rows_by_surface.get(surf, 0)}"
            f" outcomes_matched={outcomes_matched_by_bucket.get((surf, ver), 0)}"
        )
    rate = f"{round(100 * rc_nonzero / total, 2)}%" if total else "n/a"
    print(f"  -- footer [{ver}]: total={total} rc_nonzero={rc_nonzero} p50_ms={p50_s} p95_ms={p95_s} failure_rate={rate}{tail} malformed_rows={malformed}")
    # Failure breakdown: rc collapses timeout/network/http_*; rows written
    # before `reason` existed count as "unknown".
    reasons = {}
    for r in lines:
        if r.get("rc") not in (0, None):
            key = r.get("reason")
            key = key if isinstance(key, str) and key else "unknown"
            reasons[key] = reasons.get(key, 0) + 1
    if reasons:
        print(f"  -- failures by reason [{ver}]: " + " ".join(f"{k}={v}" for k, v in sorted(reasons.items())))
    print()
if not show_agreement:
    print("agreement omitted: it needs outcome ground truth (--outcomes, hydra#1041), not row[actual], which is the action Jev's own router took")
PY
