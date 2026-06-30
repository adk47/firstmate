#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Rename-merge SHADOW precision sweep
#
# The autonomous rename-merge lane (muso-cli profiles_consolidate, a
# name-mismatched dup folded in on a shared streaming id + strong track overlap
# + small id cluster) ships SHADOW-first: in shadow mode the gate records what
# it WOULD have merged ("shadow_would_merge") but still routes the customer to a
# human. This sweep measures that lane's precision against the humans' REAL merge
# decisions, so we only graduate shadow -> live on evidence (0 false-merges).
#
# It is READ-ONLY: it joins two existing muso-ops logs and prints a confusion
# matrix. No new relay is needed — the shadow decisions already land in the
# muso-cli capability audit that is mirrored to /var/log/muso-ops/tier2-audit.jsonl
# (the same log caroline-behavior-digest.py reads), and real merges are in
# /var/log/muso-ops/recent-merges.jsonl (the merge-landing-watchdog's source).
#
# For each shadow_would_merge {survivor, dup}:
#   true-merge   — a human later merged the SAME direction (mergeInto==survivor,
#                  dup in profilesIds) and it was not reversed.
#   false-merge  — a human merged the OPPOSITE direction (mergeInto==dup), i.e.
#                  the rule picked the wrong survivor. (A wrong merge a human had
#                  to INVERT — the "Invert wrong … profile merge" ClickUp class —
#                  is the other false-merge signal; that one is a manual cross-
#                  check against the Catalog board, noted but not auto-joined here.)
#   pending      — no confirmable human outcome yet.
#
# Graduation bar (ratify with Jan before flipping MUSO_RENAME_MERGE_MODE=live):
#   >= RENAME_MERGE_GRAD_MIN_DECISIONS confirmed-outcome would-merges,
#   over >= RENAME_MERGE_GRAD_MIN_DAYS of real traffic, with ZERO false-merges.
#
# Env overrides (all optional; defaults are the node-8 paths):
#   RENAME_MERGE_AUDIT_LOG   muso-cli capability audit (shadow lines live here)
#   RENAME_MERGE_MERGES_LOG  recent-merges.jsonl (real merges)
#   RENAME_MERGE_WINDOW_DAYS look-back window for shadow decisions (default 30)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

AUDIT_LOG="${RENAME_MERGE_AUDIT_LOG:-/var/log/muso-ops/tier2-audit.jsonl}"
MERGES_LOG="${RENAME_MERGE_MERGES_LOG:-/var/log/muso-ops/recent-merges.jsonl}"
WINDOW_DAYS="${RENAME_MERGE_WINDOW_DAYS:-30}"
GRAD_MIN_DECISIONS="${RENAME_MERGE_GRAD_MIN_DECISIONS:-50}"
GRAD_MIN_DAYS="${RENAME_MERGE_GRAD_MIN_DAYS:-14}"

report() {
  python3 - "$AUDIT_LOG" "$MERGES_LOG" "$WINDOW_DAYS" "$GRAD_MIN_DECISIONS" "$GRAD_MIN_DAYS" <<'PY'
import json, sys, datetime

audit_path, merges_path = sys.argv[1], sys.argv[2]
window_days, grad_n, grad_days = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None

def load(path):
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return out

now = datetime.datetime.now(datetime.timezone.utc)
lo = now - datetime.timedelta(days=window_days)

# Shadow "would merge" decisions in-window, DEDUPED by (survivor, dup): the same
# pair can be logged repeatedly (a customer retries, a conversation re-runs), but
# that is ONE merge opportunity, not N — counting each row would inflate the
# confirmed-decision count and make the graduation bar look ready without 50
# distinct opportunities. Keep the latest row per pair.
would_by_pair = {}
for r in load(audit_path):
    if r.get("decision") != "shadow_would_merge":
        continue
    ts = parse_ts(r.get("ts"))
    if ts is None or ts < lo:
        continue
    p = r.get("params") or {}
    survivor, dup = p.get("survivor"), p.get("dup")
    if survivor and dup:
        key = (survivor, dup)
        prev = would_by_pair.get(key)
        if prev is None or ts > prev["ts"]:
            would_by_pair[key] = {"survivor": survivor, "dup": dup, "ts": ts}
would = list(would_by_pair.values())

# Real merges: forward index (survivor -> losers) and reverse index (loser-as-survivor).
fwd, rev = {}, {}
for m in load(merges_path):
    mi = m.get("mergeInto")
    ids = m.get("profilesIds") or []
    if not mi:
        continue
    for pid in ids:
        fwd.setdefault((mi, pid), True)   # human merged pid INTO mi
        rev.setdefault((pid, mi), True)   # i.e. from the (mi=loser) perspective

true_merge = false_merge = pending = 0
false_pairs = []
for w in would:
    s, d = w["survivor"], w["dup"]
    if (d, s) in fwd:          # human merged survivor INTO dup -> wrong survivor picked
        false_merge += 1
        false_pairs.append(f"{s} (wanted survivor) was folded INTO {d}")
    elif (s, d) in fwd:        # human merged dup INTO survivor -> same call
        true_merge += 1
    else:
        pending += 1

confirmed = true_merge + false_merge
precision = (true_merge / confirmed) if confirmed else None
oldest = min((w["ts"] for w in would), default=None)
span_days = (now - oldest).days if oldest else 0

print("Rename-merge SHADOW precision")
print(f"  window:               last {window_days}d  (audit={audit_path})")
print(f"  shadow would-merges:  {len(would)}  (span {span_days}d)")
print(f"  TRUE-merge:           {true_merge}  (human merged the same direction)")
print(f"  FALSE-merge:          {false_merge}  (human picked the OTHER survivor)")
print(f"  pending:              {pending}  (no confirmable human outcome yet)")
print(f"  precision (confirmed):{(f'{precision:.3f}' if precision is not None else 'n/a')}  "
      f"({true_merge}/{confirmed})")
for fp in false_pairs:
    print(f"    ! false-merge: {fp}")

ready = (confirmed >= grad_n and span_days >= grad_days and false_merge == 0)
print()
print("Graduation bar (shadow -> live, ratify with Jan):")
print(f"  >= {grad_n} confirmed decisions : {confirmed}  {'OK' if confirmed >= grad_n else 'not yet'}")
print(f"  >= {grad_days}d of traffic       : {span_days}d {'OK' if span_days >= grad_days else 'not yet'}")
print(f"  ZERO false-merges          : {false_merge}  {'OK' if false_merge == 0 else 'BLOCKED'}")
print(f"  => {'READY for review (still a human flips MUSO_RENAME_MERGE_MODE=live)' if ready else 'NOT ready — keep collecting'}")
PY
}

selftest() {
  local dir; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' RETURN
  local now; now="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())')"
  # 3 DISTINCT would-merges (s1->d1 logged TWICE to prove dedup): one the human
  # confirmed (s1->d1), one the human REVERSED (would s2->d2 but human merged
  # mergeInto=d2 with s2 inside), one pending (s3->d3).
  cat > "$dir/audit.jsonl" <<EOF
{"ts":"$now","tool":"profiles_consolidate","decision":"shadow_would_merge","params":{"survivor":"s1","dup":"d1"}}
{"ts":"$now","tool":"profiles_consolidate","decision":"shadow_would_merge","params":{"survivor":"s1","dup":"d1"}}
{"ts":"$now","tool":"profiles_consolidate","decision":"shadow_would_merge","params":{"survivor":"s2","dup":"d2"}}
{"ts":"$now","tool":"profiles_consolidate","decision":"shadow_would_merge","params":{"survivor":"s3","dup":"d3"}}
{"ts":"$now","tool":"profiles_consolidate","decision":"shadow_would_refuse","params":{"survivor":"s4","dup":"d4"}}
EOF
  cat > "$dir/merges.jsonl" <<EOF
{"mergeInto":"s1","profilesIds":["d1"],"at":"$now"}
{"mergeInto":"d2","profilesIds":["s2"],"at":"$now"}
EOF
  # Override the already-resolved paths directly (the RENAME_MERGE_* env is read
  # once at script load, before this runs). Assertions are space-insensitive.
  local out
  out="$(AUDIT_LOG="$dir/audit.jsonl" MERGES_LOG="$dir/merges.jsonl" report)"
  echo "$out" | grep -Eq "shadow would-merges: +3\b" || { echo "FAIL: the duplicate (s1,d1) row must collapse -> 3 distinct"; echo "$out"; return 1; }
  echo "$out" | grep -Eq "TRUE-merge: +1\b"  || { echo "FAIL: expected 1 true-merge"; echo "$out"; return 1; }
  echo "$out" | grep -Eq "FALSE-merge: +1\b" || { echo "FAIL: expected 1 false-merge"; echo "$out"; return 1; }
  echo "$out" | grep -Eq "pending: +1\b"     || { echo "FAIL: expected 1 pending"; echo "$out"; return 1; }
  echo "$out" | grep -Eq "ZERO false-merges +: +1 +BLOCKED" || { echo "FAIL: a false-merge must BLOCK graduation"; echo "$out"; return 1; }
  echo "self-test ok"
}

case "${1:-}" in
  --self-test) selftest ;;
  *) report ;;
esac
