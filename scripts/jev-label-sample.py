#!/usr/bin/env python3
"""Draw a blinded Caroline labelling sheet from the Jev shadow log (MUS-5253).

Usage: jev-label-sample.py [LOG] --out-dir DIR [--n 200] [--seed 20261008]

Reads one local JSONL file (default /var/lib/hydra-jev/shadow/caroline.jsonl)
and writes, into DIR:
  sample.csv  turn_id, message, + four EMPTY label columns. No Jev answer, no
              probability, no model name: the labeller must not be anchored.
  key.jsonl   the same turn_ids with both versions' answers, for the join
              after labelling.

Both files hold raw customer text / answers, so they are written 0600 and DIR
must not be inside a git work tree (including this repo). No network, nothing
is written under /var/lib/hydra-jev.

Turn = same (surface, item_id), a v1 row and a v2 row with ts within 5.0 s
(MUS-1541). Eligible = paired, rc 0 on both, v1 `state` non-null, v1 `intent`
has a usable top probability. Strata = the report's BUCKETS on that v1 intent
top probability, allocated proportionally (largest remainder). A stratum
smaller than its quota is taken whole and reported on stderr; it is never
topped up from another stratum.
"""
import argparse
import csv
import io
import json
import math
import os
import random
import subprocess
import sys
from datetime import datetime, timezone

DEFAULT_LOG = "/var/lib/hydra-jev/shadow/caroline.jsonl"
PAIR_WINDOW_S = 5.0
LABEL_COLS = ["intent", "first_tool", "resolution_path", "needs_reply"]
STRATUM_QUESTION = "intent"
# Same edges as scripts/jev-shadow-report.sh BUCKETS.
BUCKETS = [(0.0, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.0001)]
BUCKET_LABELS = ["0.0-0.5", "0.5-0.6", "0.6-0.7", "0.7-0.8", "0.8-0.9", "0.9-1.0"]
REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def parse_ts(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except Exception:
        return None


def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def top_prob(ans):
    """Top-answer probability, same rules as the report's top_answer()."""
    if not isinstance(ans, dict):
        return None
    t = ans.get("type")
    if t == "noul":
        p = ans.get("noul")
        return (p if p >= 0.5 else 1 - p) if _num(p) and 0 <= p <= 1 else None
    probs = ans.get("probabilities")
    if t == "choice":
        p = probs.get(ans.get("choice")) if isinstance(probs, dict) else None
        return p if _num(p) and 0 <= p <= 1 else None
    if t == "score" and isinstance(probs, dict):
        vals = [v for v in probs.values() if _num(v) and 0 <= v <= 1]
        return max(vals) if vals else None
    return None


def bucket_of(p):
    for i, (lo, hi) in enumerate(BUCKETS):
        if lo <= p < hi:
            return i
    return None


def inside_git_tree(path):
    p = os.path.realpath(path)
    if p == REPO or p.startswith(REPO + os.sep):
        return True
    probe = p
    while not os.path.isdir(probe):
        probe = os.path.dirname(probe)
    r = subprocess.run(["git", "-C", probe, "rev-parse", "--is-inside-work-tree"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def load_turns(path):
    """Stream the log; return (candidate v1 turns, exclusion counts)."""
    v1s, v2s = {}, {}
    ex = {"malformed": 0, "unpaired": 0, "rc_nonzero": 0, "state_null": 0, "no_intent_prob": 0}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                row = json.loads(line)
                if row["surface"] is None or row["item_id"] is None:
                    raise ValueError
            except Exception:
                ex["malformed"] += 1
                continue
            t = parse_ts(row.get("ts") or "")
            ver = row.get("questions_version")
            if t is None or ver not in ("v1", "v2"):
                continue
            key = (str(row["surface"]), str(row["item_id"]))
            if ver == "v1":
                v1s.setdefault(key, []).append((t, row))
            else:
                v2s.setdefault(key, []).append((t, row))
    turns = []
    for key, v1_rows in v1s.items():
        used = set()
        for t1, r1 in sorted(v1_rows, key=lambda x: x[0]):
            best = None
            for j, (t2, _) in enumerate(v2s.get(key, [])):
                d = abs(t2 - t1)
                if j not in used and d <= PAIR_WINDOW_S and (best is None or d < best[0]):
                    best = (d, j)
            if best is None:
                ex["unpaired"] += 1
                continue
            used.add(best[1])
            r2 = v2s[key][best[1]][1]
            if r1.get("rc") != 0 or r2.get("rc") != 0:
                ex["rc_nonzero"] += 1
                continue
            state = r1.get("state")
            msg = state.get("message") if isinstance(state, dict) else None
            if not isinstance(msg, str) or not msg.strip():
                ex["state_null"] += 1
                continue
            a1, a2 = r1.get("answers"), r2.get("answers")
            p = top_prob(a1.get(STRATUM_QUESTION)) if isinstance(a1, dict) else None
            b = bucket_of(p) if p is not None else None
            if b is None or not isinstance(a2, dict):
                ex["no_intent_prob"] += 1
                continue
            turns.append({"turn_id": f"{key[0]}|{key[1]}|{r1['ts']}", "message": msg,
                          "bucket": b, "v1": a1, "v2": a2})
    return turns, ex


def quotas(sizes, n):
    """Proportional allocation, largest remainder; sums to n; only valid for n <= sum(sizes)."""
    total = sum(sizes)
    exact = [n * s / total for s in sizes]
    q = [math.floor(e) for e in exact]
    order = sorted(range(len(sizes)), key=lambda i: (-(exact[i] - q[i]), i))
    for i in order[: n - sum(q)]:
        q[i] += 1
    return q


def csv_safe(text):
    """Defuse spreadsheet formulas: customer text is attacker-controlled."""
    return "'" + text if text[:1] in ("=", "+", "-", "@", "\t", "\r", "\n") else text


def write_private(path, text):
    """Write 0600 via an exclusive temp file + atomic replace: a pre-existing
    symlink at `path` is replaced, never followed."""
    tmp = f"{path}.tmp.{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            os.fchmod(fh.fileno(), 0o600)
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log", nargs="?", default=DEFAULT_LOG)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261008)
    a = ap.parse_args()

    if inside_git_tree(a.out_dir):
        print(f"refusing: --out-dir {a.out_dir} is inside a git work tree; the sheet holds customer text", file=sys.stderr)
        return 2
    if a.n < 1:
        print("--n must be >= 1", file=sys.stderr)
        return 2

    turns, ex = load_turns(a.log)
    if not turns:
        print("no eligible turns", file=sys.stderr)
        return 1
    strata = [sorted((t for t in turns if t["bucket"] == i), key=lambda t: t["turn_id"]) for i in range(len(BUCKETS))]
    rng = random.Random(a.seed)

    # Proportional quota over the eligible population. When n exceeds it, the
    # quota is n*size/total (> size): the stratum is taken whole and reported.
    total = len(turns)
    if a.n <= total:
        qs = quotas([len(s) for s in strata], a.n)
    else:
        qs = [math.ceil(a.n * len(s) / total) for s in strata]
    picked = []
    for label, s, q in zip(BUCKET_LABELS, strata, qs):
        take = min(q, len(s))
        picked += rng.sample(s, take) if take else []
        print(f"{label} eligible={len(s)} quota={q} take={take}", file=sys.stderr)
        if len(s) < q:
            print(f"shortfall {label}: quota={q} eligible={len(s)}", file=sys.stderr)
    rng.shuffle(picked)  # row order must not leak the stratum

    print(f"eligible={total} selected={len(picked)} requested={a.n}", file=sys.stderr)
    print("excluded " + " ".join(f"{k}={v}" for k, v in ex.items()), file=sys.stderr)

    os.makedirs(a.out_dir, mode=0o700, exist_ok=True)
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["turn_id", "message"] + LABEL_COLS)
    for t in picked:
        w.writerow([t["turn_id"], csv_safe(t["message"])] + [""] * len(LABEL_COLS))
    write_private(os.path.join(a.out_dir, "sample.csv"), buf.getvalue())
    write_private(os.path.join(a.out_dir, "key.jsonl"),
                  "".join(json.dumps({"turn_id": t["turn_id"], "v1": t["v1"], "v2": t["v2"]}, sort_keys=True) + "\n" for t in picked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
