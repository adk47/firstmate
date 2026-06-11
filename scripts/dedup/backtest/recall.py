#!/usr/bin/env python3
"""Recall backtest — does the detector flag the dupes humans actually merged?

For each merge in action_log older than --skip-days (matvw lag boundary,
default 7), reconstruct pre-merge state and apply detector verdict logic.
Emit per-merge JSONL on stdout + confusion-bucket summary on stderr.

Pre-merge reconstruction:
  L (loser) row in matvw_catalog_profile is preserved as-of merge time:
  is_deleted=true, raw_profile_ids unchanged. S (survivor) absorbed L's
  raw_profile_ids AND ipis (verified 2026-05-20 against pre-propagation
  Mike Gaydusek merge: loser had IPI 519560836, survivor had empty).
  We therefore subtract L's IDs and IPIs symmetrically from S to
  reconstruct the survivor's pre-merge state.

Structural limitation (HARD recall lower bound):
  If pre-merge S and L INDEPENDENTLY shared a raw_profile_id or IPI
  (real hard signal), the merge's union behavior produces a state
  identical to the artifact case (only L had it, S absorbed). Subtraction
  cannot distinguish, so this method underestimates hard-signal recall.
  The reported hard_dupe count is therefore a LOWER BOUND. Soft-signal
  recall (name match) is reliably measured — matvw doesn't union names.

Verdict logic mirrors lib/score-pair.sh:
  hard_dupe        shared raw_profile_id (non-muso) or IPI after subtraction
  candidate_dupe   name_lev <= 2 AND (min_credits <= 2 AND max_credits >= 5)
                     — arm (b) of score-pair.sh, the "auto-stub" pattern
  soft_partial     name_lev <= 2 but no credit asymmetry — would need
                     shared_tracks >= 3 to graduate; this backtest doesn't
                     query matvw_catalog_track (1 query/pair = 258 queries).
                     Soft_partial is a LOWER BOUND on real candidate_dupe.
  no_match         neither

Exit codes:
  0  backtest ran (may have skipped rows — count in summary)
  1  trino failure or arg error
"""
import argparse, json, os, re, subprocess, sys, unicodedata

MUSO = os.environ.get("MUSO_BIN", "muso")


def run_trino(sql):
    # muso query --format json emits NDJSON (one object per row, values as
    # strings); SQL goes via stdin to dodge shell-arg escaping.
    proc = subprocess.run([MUSO, "query", "--format", "json", "-"],
                          input=sql, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        print(f"recall: trino failed: {proc.stderr[:800]}", file=sys.stderr)
        sys.exit(1)
    return proc.stdout


def split_pipe(s):
    return [x for x in (s or "").split("|") if x]


def external_ids(ids):
    return set(i for i in ids if not i.startswith("muso:"))


def lev(a, b):
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i]
        for j, cb in enumerate(b, 1):
            curr.append(min(curr[-1] + 1, prev[j] + 1, prev[j-1] + (ca != cb)))
        prev = curr
    return prev[-1]


def normalize_name(s):
    s = (s or "").lower()
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode('ascii')
    s = re.sub(r'\s+', ' ', s).strip()
    return s


def classify(row):
    s_ext = external_ids(split_pipe(row["s_raw_ids"]))
    l_ext = external_ids(split_pipe(row["l_raw_ids"]))
    s_ipi = set(split_pipe(row["s_ipis"]))
    l_ipi = set(split_pipe(row["l_ipis"]))
    s_pre_ext = s_ext - l_ext
    s_pre_ipi = s_ipi - l_ipi
    hard_ids = sorted(l_ext & s_pre_ext)
    hard_ipis = sorted(l_ipi & s_pre_ipi)
    if hard_ids or hard_ipis:
        return "hard_dupe", hard_ids, hard_ipis, None
    s_norm = normalize_name(row["s_name"])
    l_norm = normalize_name(row["l_name"])
    if not s_norm or not l_norm:
        return "no_match", [], [], None
    edit = lev(s_norm, l_norm)
    if edit > 2:
        return "no_match", [], [], edit
    try:
        s_cc = int(row["s_credits"] or 0)
        l_cc = int(row["l_credits"] or 0)
    except ValueError:
        s_cc = l_cc = 0
    min_cc, max_cc = min(s_cc, l_cc), max(s_cc, l_cc)
    if min_cc <= 2 and max_cc >= 5:
        return "candidate_dupe", [], [], edit
    return "soft_partial", [], [], edit


SQL = """WITH merges AS (
  SELECT
    json_extract_scalar(requestdata, '$.body.mergeInto') AS survivor_id,
    cast(json_extract(requestdata, '$.body.profilesIds') AS array(varchar)) AS loser_ids,
    createdat AS merge_at
  FROM postgresql_core.public.action_log
  WHERE route = '/api/v3/admin/profiles/merge'
    AND createdat < date_add('day', -{skip}, current_date)
    AND createdat >= date_add('day', -{look_back}, current_date)
)
SELECT
  m.survivor_id,
  t.loser_id,
  cast(m.merge_at AS varchar) AS merge_at,
  s.name AS s_name,
  l.name AS l_name,
  s.credits_count AS s_credits,
  l.credits_count AS l_credits,
  array_join(s.raw_profile_ids, '|') AS s_raw_ids,
  array_join(l.raw_profile_ids, '|') AS l_raw_ids,
  array_join(s.ipis, '|') AS s_ipis,
  array_join(l.ipis, '|') AS l_ipis,
  cast(l.is_deleted AS varchar) AS l_is_deleted,
  coalesce(l.merged_to_id, '') AS l_merged_to_id
FROM merges m
CROSS JOIN UNNEST(m.loser_ids) AS t(loser_id)
LEFT JOIN hive."platform-industry-bi-prod".matvw_catalog_profile s ON s._id = m.survivor_id
LEFT JOIN hive."platform-industry-bi-prod".matvw_catalog_profile l ON l._id = t.loser_id
ORDER BY m.merge_at DESC
LIMIT {limit}
"""


COLS = ["survivor_id", "loser_id", "merge_at", "s_name", "l_name",
        "s_credits", "l_credits", "s_raw_ids", "l_raw_ids",
        "s_ipis", "l_ipis", "l_is_deleted", "l_merged_to_id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-days", type=int, default=7,
                    help="ignore merges newer than N days — matvw lag (default 7)")
    ap.add_argument("--look-back-days", type=int, default=90,
                    help="look-back window in days (default 90)")
    ap.add_argument("--limit", type=int, default=2000,
                    help="cap on rows scored (default 2000)")
    ap.add_argument("--show-fn", action="store_true",
                    help="extra: print only no_match (FN) rows on stdout, not all rows")
    args = ap.parse_args()

    sql = SQL.format(skip=args.skip_days, look_back=args.look_back_days, limit=args.limit)
    out = run_trino(sql)
    rows = [json.loads(l) for l in out.splitlines() if l.strip()]
    if not rows:
        print("recall: no merges in window", file=sys.stderr)
        sys.exit(0)

    counts = {"hard_dupe": 0, "candidate_dupe": 0, "soft_partial": 0, "no_match": 0,
              "matvw_lag_skip": 0, "missing_row": 0, "chained_merge_skip": 0}

    for raw_row in rows:
        # NULL columns may arrive as JSON null (or be omitted entirely);
        # the old CSV path rendered them as "" — keep that contract.
        row = {c: (raw_row.get(c) or "") for c in COLS}
        if not row["l_name"] and not row["l_raw_ids"]:
            counts["missing_row"] += 1
            continue
        if row["l_is_deleted"].lower() != "true":
            counts["matvw_lag_skip"] += 1
            continue
        if row["l_merged_to_id"] and row["l_merged_to_id"] != row["survivor_id"]:
            counts["chained_merge_skip"] += 1
            continue

        verdict, hard_ids, hard_ipis, name_lev = classify(row)
        counts[verdict] += 1

        if args.show_fn and verdict != "no_match":
            continue

        print(json.dumps({
            "merge_at": row["merge_at"],
            "survivor_id": row["survivor_id"],
            "loser_id": row["loser_id"],
            "s_name": row["s_name"],
            "l_name": row["l_name"],
            "verdict": verdict,
            "hard_overlap_ids": hard_ids,
            "hard_overlap_ipis": hard_ipis,
            "name_lev": name_lev,
            "s_credits": row["s_credits"],
            "l_credits": row["l_credits"],
        }))

    scored = counts["hard_dupe"] + counts["candidate_dupe"] + counts["soft_partial"] + counts["no_match"]
    print("", file=sys.stderr)
    print(f"recall backtest summary ({scored} merges scored, window: "
          f"{args.look_back_days}d back, skipping <{args.skip_days}d):",
          file=sys.stderr)
    for k in ("hard_dupe", "candidate_dupe", "soft_partial", "no_match"):
        pct = (counts[k] / scored * 100) if scored else 0
        print(f"  {k:18s} {counts[k]:5d}  ({pct:5.1f}%)", file=sys.stderr)
    print(f"  -- skipped --", file=sys.stderr)
    print(f"  matvw_lag_skip     {counts['matvw_lag_skip']:5d}  (loser not yet is_deleted=true in matvw)",
          file=sys.stderr)
    print(f"  chained_merge_skip {counts['chained_merge_skip']:5d}  (loser was re-merged into a different survivor)",
          file=sys.stderr)
    print(f"  missing_row        {counts['missing_row']:5d}  (no matvw row found at all)",
          file=sys.stderr)

    if scored:
        recall_hard = counts["hard_dupe"] / scored * 100
        recall_any = (counts["hard_dupe"] + counts["candidate_dupe"]) / scored * 100
        print("", file=sys.stderr)
        print(f"recall (hard_dupe only, LOWER BOUND): {recall_hard:5.1f}%",
              file=sys.stderr)
        print(f"recall (hard_dupe OR candidate_dupe): {recall_any:5.1f}%",
              file=sys.stderr)
        print("", file=sys.stderr)
        print("note: hard_dupe is a LOWER BOUND. Merge unions IDs+IPIs on the",
              file=sys.stderr)
        print("survivor; subtraction recovers most pre-merge state but can't",
              file=sys.stderr)
        print("distinguish a real pre-merge shared ID from a post-merge artifact.",
              file=sys.stderr)
        print("Soft-signal recall (name) is reliably measured.", file=sys.stderr)


if __name__ == "__main__":
    main()
