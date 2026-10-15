#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# check-rebase-integrity.sh — advisory analyzer for "the rebase clobbered code"
# =============================================================================
# Companion to pr-validate.yml's rebase-staleness gate: that gate forces a
# rebase when a PR is behind base AND overlaps files; THIS script inspects what
# a rebase actually PRODUCED and flags signals that it silently reverted or
# dropped work:
#
#   stale-blob-regression     a PR file is byte-identical to a version OLDER
#                             than the merge-base (classic mis-resolved conflict)
#   erased-recent-base-work   the PR deletes lines that landed on base recently
#   large-deletion            deletion volume disproportionate to additions
#   dropped-commits           commits present before the last force-push that
#                             are absent afterward and never landed on base
#   rewritten-commits (info)  same subject survived the force-push, patch changed
#   reintroduced-removed-lines the PR re-adds lines base recently removed
#   duplicate-patch-id        the same patch appears twice on the PR branch
#   already-merged (info)     PR commits patch-identical to commits on base
#
# ADVISORY BY DESIGN: signals NEVER exit non-zero — humans (and the QA agent)
# decide. Only an internal analyzer error exits non-zero, and even then the
# state file is written with status=ERROR so qa-pr-approve.sh Guard 8 can fail
# closed on "rebase state unverified". Run inside a full (non-shallow) clone
# with an `origin` remote.
#
# Usage: check-rebase-integrity.sh <pr-number> <head-sha>
#
# Env:
#   BASE_REF  (default main)         REPO (default Muso-AI/hydra, owner/name)
#   GH        (default gh; tests)    RI_SKIP_FETCH=1 (tests: no network)
#   RI_STATE_DIR (default /var/lib/hydra-qa/rebase-integrity; empty ⇒ no state
#                 file — the machine-readable hand-off to the QA agent/Guard 8)
# Thresholds (integers; tune here, not in consumers):
#   RI_DEL_ABS=300  RI_DEL_RATIO=3     large-deletion fires only if BOTH hold
#   RI_RECENT_DAYS=14                  "recent base work" window
#   RI_INTERSECT_MIN_LINES=3           per-file matched-line floor (noise cut)
#   RI_MIN_LINE_LEN=8                  normalization drops shorter lines
#   RI_BLOB_HISTORY=50                 per-file depth for the stale-blob scan
#   RI_MAX_FILES=400 RI_MAX_COMMITS=200  degrade caps for big PRs (skip + note)
#   RI_MAX_FORCE_PUSHES=20             most-recent force-push events analyzed
#
# Exit codes: 0 analysis ran (CLEAN or WARN — read the report/state file)
#             2 usage | 3 internal error (state file has status=ERROR)

GH="${GH:-gh}"
BASE_REF="${BASE_REF:-main}"
REPO="${REPO:-Muso-AI/hydra}"
RI_STATE_DIR="${RI_STATE_DIR-/var/lib/hydra-qa/rebase-integrity}"

RI_DEL_ABS="${RI_DEL_ABS:-300}"
RI_DEL_RATIO="${RI_DEL_RATIO:-3}"
RI_RECENT_DAYS="${RI_RECENT_DAYS:-14}"
RI_INTERSECT_MIN_LINES="${RI_INTERSECT_MIN_LINES:-3}"
RI_MIN_LINE_LEN="${RI_MIN_LINE_LEN:-8}"
RI_BLOB_HISTORY="${RI_BLOB_HISTORY:-50}"
RI_MAX_FILES="${RI_MAX_FILES:-400}"
RI_MAX_COMMITS="${RI_MAX_COMMITS:-200}"

[ "$#" -eq 2 ] || { echo "usage: check-rebase-integrity.sh <pr-number> <head-sha>" >&2; exit 2; }
PR="$1"
head_sha="$2"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "check-rebase-integrity: pr-number must be numeric, got '$PR'" >&2; exit 2; }
# Full 40-hex only: the state file is keyed by this value and Guard 8 looks it
# up by headRefOid — a short sha or ref name would "succeed" into a file nobody
# ever reads (and a name with '/' would break the path).
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "check-rebase-integrity: head-sha must be a full 40-hex oid, got '$head_sha'" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-rebase-integrity.XXXXXX")"
: > "$WORK/signals.ndjson"
: > "$WORK/skipped"

# Generated/vendored paths drown the line-level signals (a plugin rebuild or
# lockfile churn is legitimate mass change). Blob/patch-id signals are exact,
# but we exclude these everywhere for one consistent definition of "the code".
EXCLUDES=(
  ':(glob,exclude)**/pnpm-lock.yaml'
  ':(glob,exclude)**/package-lock.json'
  ':(glob,exclude)**/node_modules/**'
  ':(glob,exclude)**/dist/**'
)

note_skip() {
  printf '%s\n' "$1" >> "$WORK/skipped"
  echo "note: skipped — $1"
}

# add_signal <id> <severity> <summary> <files-newline-list> <commits-newline-list> [identity]
# Built with jq --arg ONLY: paths and commit subjects are PR-author-controlled.
#
# `identity` is the material whose byte-equality means "the SAME finding", hashed
# into .digest and rolled up into the report's warn_digest. qa-pr-approve.sh
# Guard 8 carries a human's REBASE WARNING ack forward to a new head only when
# that digest matches, so identity MUST be what the human actually judged — the
# affected content — never the summary: the line-window summaries carry only a
# COUNT ("deletes 10 line(s) in F"), so two unrelated 10-line deletions in one
# file render identically and a summary-keyed carryover would inherit an ack
# across different content.
#
# The id+files+commits+summary fallback is NOT content-sensitive in general, so
# a `warn` signal that omits `identity` is marked NON-CARRYABLE rather than
# hashed into the rollup. It still reports exactly as before; it only voids the
# report's warn_digest, so Guard 8 falls back to per-head re-filing. Fail-closed
# is the default because the failure mode is a signal author FORGETTING to pass
# identity — which must not silently produce a carryable-but-unsound digest.
# `info` signals never reach the rollup, so they keep the plain fallback.
add_signal() {
  local id="$1" severity="$2" summary="$3" files="$4" commits="$5" identity="${6:-}"
  local carryable=true
  if [ -z "$identity" ]; then
    [ "$severity" != warn ] || carryable=false
    identity="$(printf '%s\n%s\n%s\n%s' "$id" "$files" "$commits" "$summary")"
  fi
  local digest
  digest="$(printf '%s' "$identity" | sha256sum | awk '{print $1}')"
  jq -cn --arg id "$id" --arg severity "$severity" --arg summary "$summary" \
    --arg files "$files" --arg commits "$commits" --arg digest "$digest" \
    --argjson carryable "$carryable" \
    '{id:$id, severity:$severity, summary:$summary, digest:$digest,
      carryable:$carryable,
      files:   ($files   | split("\n") | map(select(length>0))),
      commits: ($commits | split("\n") | map(select(length>0)))}' \
    >> "$WORK/signals.ndjson"
}

# Normalize diff-body lines for cross-diff intersection: collapse whitespace,
# drop short / non-alphanumeric lines (braces, blanks) that would match by
# coincidence. stdin → sorted unique normalized lines.
normalize_lines() {
  sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | awk -v m="$RI_MIN_LINE_LEN" 'length($0) >= m && $0 ~ /[[:alnum:]]/' \
    | sort -u
}

# hunks_containing <set-file> <+|-> <ref-file> — stdin: a unified diff of ONE
# file; stdout: the hunks whose <side> lines include a member of <set-file>,
# each prefixed with a stable occurrence ordinal.
#
# This exists because the detection sets (normalize_lines) are sorted, deduped
# and whitespace-collapsed, so they carry neither MULTIPLICITY nor LOCATION: a
# file holding the same normalized lines in two blocks renders "deleted block A"
# and "deleted block B" identically, and an ack for one would carry onto the
# other. Detection still wants that fuzziness; identity must not have it.
#
# Emitted hunks keep raw bodies (order + duplicates intact) and their context
# lines. Context alone is NOT sufficient: two byte-identical blocks with
# byte-identical surrounding context still collide. So each hunk also carries
# `occurrence N` — how many times this hunk's own <side>-plus-context slice
# already appears in <ref-file> BEFORE this hunk's start. Deleting the first
# duplicate gives 0, the second gives 1.
#
# The raw `@@ -a,b +c,d @@` numbers are deliberately NOT used: absolute positions
# shift whenever anything earlier in the file changes, churning the digest
# without the finding differing — and a digest that churns never carries an ack,
# which ships the feature inert. The ordinal survives that: inserting lines above
# moves the block without changing how many identical blocks precede it.
#
# <ref-file> is the revision the <side> lines live in — the merge-base image for
# `-` (deletions), the head image for `+` (additions).
#
# <set-file> may be the literal `--all`, meaning "every hunk that touches <side>
# qualifies" — used by large-deletion, which is a volume signal with no
# line-membership test but the same need for a location-bearing identity.
hunks_containing() {
  awk -v setfile="$1" -v side="$2" -v reffile="$3" -v minlen="$RI_MIN_LINE_LEN" '
    function norm(s) {
      gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s
    }
    # How many times sideln[1..ns] occurs in ref[] starting strictly before hstart.
    function ordinal(   p, j, ok, c) {
      c = 0
      for (p = 1; p < hstart && p + ns - 1 <= M; p++) {
        ok = 1
        for (j = 1; j <= ns; j++) if (ref[p + j - 1] != sideln[j]) { ok = 0; break }
        if (ok) c++
      }
      return c
    }
    function emit(   i) {
      if (nb > 0 && hit) {
        printf "@@ occurrence %d\n", ordinal()
        for (i = 1; i <= nb; i++) printf "%s\n", body[i]
      }
      nb = 0; ns = 0; hit = 0
    }
    BEGIN {
      matchall = (setfile == "--all")
      if (!matchall) while ((getline l < setfile) > 0) want[l] = 1
      while ((getline l < reffile) > 0) ref[++M] = l
    }
    /^@@/ {
      emit()
      o = $2; sub(/^-/, "", o); sub(/,.*/, "", o)
      n = $3; sub(/^\+/, "", n); sub(/,.*/, "", n)
      hstart = (side == "-") ? o + 0 : n + 0
      inhunk = 1
      next
    }
    # File headers only ever precede the first @@ (single-file diff), but the
    # trailing space keeps a deleted "---" body line (rendered "----") out of this.
    /^(diff |index |--- |\+\+\+ )/ { next }
    # "\ No newline at end of file" is diff metadata, not file content.
    /^\\/ { next }
    inhunk {
      body[++nb] = $0
      c1 = substr($0, 1, 1)
      if (c1 == " " || c1 == side) sideln[++ns] = substr($0, 2)
      if (c1 == side) {
        if (matchall) hit = 1
        else {
          b = norm(substr($0, 2))
          if (length(b) >= minlen && b ~ /[[:alnum:]]/ && (b in want)) hit = 1
        }
      }
    }
    END { emit() }
  '
}

# diff_side <+|-> <git-diff-args...> → body lines of that side, markers stripped
# Header match is anchored to the a/ b/ /dev/null prefixes so a BODY line that
# happens to start "-- " or "++ " (SQL/Lua comments) is not swallowed as a header.
diff_side() {
  local side="$1"; shift
  git diff "$@" | awk -v s="$side" '
    /^(\+\+\+|---) (a\/|b\/|\/dev\/null)/ { next }
    substr($0, 1, 1) == s { print substr($0, 2) }'
}

# --- state file (the machine hand-off Guard 8 / the QA skill consume) --------
write_state() { # <status>
  [ -n "$RI_STATE_DIR" ] || return 0
  mkdir -p "$RI_STATE_DIR" || return 1
  local out tmp signals_json skipped_json
  out="$RI_STATE_DIR/${REPO//\//__}-pr-${PR}-${head_sha}.json"
  tmp="$(mktemp "$RI_STATE_DIR/.ri-tmp.XXXXXX")" || return 1
  signals_json="$(jq -cs '.' "$WORK/signals.ndjson" 2>/dev/null || echo '[]')"
  skipped_json="$(jq -cRs 'split("\n") | map(select(length>0))' "$WORK/skipped" 2>/dev/null || echo '[]')"
  jq -n \
    --arg repo "$REPO" --argjson pr "$PR" --arg head_sha "$head_sha" \
    --arg base_ref "$BASE_REF" --arg merge_base "${merge_base:-}" \
    --arg base_tip "${base_tip:-}" --arg generated_at "$(date -u +%FT%TZ)" \
    --arg status "$1" --argjson signals "$signals_json" --argjson skipped "$skipped_json" \
    --arg warn_digest "${warn_digest:-}" \
    '{version: 1, repo: $repo, pr: $pr, head_sha: $head_sha, base_ref: $base_ref,
      merge_base: $merge_base, base_tip: $base_tip, generated_at: $generated_at,
      status: $status, warn_digest: $warn_digest, skipped: $skipped,
      signals: $signals}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$out"
  # keep the state dir bounded — reports are per-head and go stale fast
  find "$RI_STATE_DIR" -maxdepth 1 -name '*.json' -mtime +30 -delete 2>/dev/null || true
}

# Fail-loud reporting: any unexpected failure still writes status=ERROR (Guard 8
# fails closed on it) and exits 3. Usage errors exit 2 BEFORE this trap is
# installed, so no rc is exempted here — grep/sort/jq hard errors exit 2 too,
# and exempting it would skip the ERROR write exactly when it matters.
ANALYSIS_DONE=0
STAGE="init"
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ANALYSIS_DONE" -ne 1 ]; then
    note_skip "internal error at stage: $STAGE" || true
    write_state ERROR || true
    rm -rf "$WORK"
    exit 3
  fi
  rm -rf "$WORK"
}
trap on_exit EXIT

# --- prologue: refs ----------------------------------------------------------
STAGE="fetch"
if [ "${RI_SKIP_FETCH:-0}" != 1 ]; then
  # The staleness step's `--depth=200` fetch can leave the PERSISTENT runner
  # clone shallow; rev-list/patch-id walks silently truncate on shallow repos.
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    git fetch --unshallow origin --quiet || git fetch origin --quiet || true
  fi
  git fetch origin "$BASE_REF" --quiet
fi

STAGE="resolve-refs"
git rev-parse -q --verify "${head_sha}^{commit}" >/dev/null \
  || { echo "check-rebase-integrity: cannot resolve head sha '$head_sha'" >&2; exit 3; }
base_tip="$(git rev-parse "origin/${BASE_REF}")"
merge_base="$(git merge-base "$head_sha" "$base_tip")"

# Early fail-closed sentinel: if this process dies mid-analysis in a way the EXIT
# trap can't catch (SIGKILL/OOM/runner cancel), a status=ERROR file must already
# exist — otherwise Guard 8's missing-file=pass would silently read the death as
# clean. Overwritten with the real status at the end.
write_state ERROR

# Anchor for the "recent base work" window: newest merge-base ancestor older
# than the window. Empty (repo younger than the window) ⇒ everything counts as
# recent, via the empty tree.
recent_anchor="$(git rev-list -1 --before="${RI_RECENT_DAYS} days ago" "$merge_base" || true)"
recent_from="${recent_anchor:-$(git hash-object -t tree /dev/null)}"

STAGE="pr-files"
# core.quotepath=false everywhere paths are consumed programmatically: the
# default quotes/escapes non-ASCII names, which would make every per-file
# rev-parse/pathspec silently miss those files.
git -c core.quotepath=false diff --name-only "$merge_base" "$head_sha" -- "${EXCLUDES[@]}" | sort -u > "$WORK/pr_files"
pr_file_count="$(grep -c . "$WORK/pr_files" || true)"

# --- S1a stale-blob-regression ------------------------------------------------
STAGE="stale-blob-regression"
if [ "$pr_file_count" -gt "$RI_MAX_FILES" ]; then
  note_skip "stale-blob-regression/erased-recent-base-work/reintroduced-removed-lines: PR touches $pr_file_count files (> RI_MAX_FILES=$RI_MAX_FILES)"
else
  while IFS= read -r F; do
    head_blob="$(git rev-parse -q --verify "$head_sha:$F" 2>/dev/null || true)"
    [ -n "$head_blob" ] || continue                          # deleted at head
    base_blob="$(git rev-parse -q --verify "$base_tip:$F" 2>/dev/null || true)"
    [ "$head_blob" = "$base_blob" ] && continue              # matches current base
    mb_blob="$(git rev-parse -q --verify "$merge_base:$F" 2>/dev/null || true)"
    [ "$head_blob" = "$mb_blob" ] && continue                # mode-only change
    match=""
    while IFS= read -r c; do
      old_blob="$(git rev-parse -q --verify "$c:$F" 2>/dev/null || true)"
      if [ -n "$old_blob" ] && [ "$old_blob" = "$head_blob" ]; then match="$c"; break; fi
    done < <(git rev-list --max-count="$RI_BLOB_HISTORY" "$merge_base" -- "$F")
    if [ -n "$match" ]; then
      add_signal stale-blob-regression warn \
        "$F at the PR head is byte-identical to its pre-merge-base version from commit $(git log -1 --format='%h (%ad)' --date=short "$match") — a rebase may have reverted this file to a prior implementation" \
        "$F" "$(git log -1 --format='%h %s' "$match")"
    fi
  done < "$WORK/pr_files"
fi

# --- S1b erased-recent-base-work ----------------------------------------------
STAGE="erased-recent-base-work"
if [ "$pr_file_count" -le "$RI_MAX_FILES" ]; then
  git -c core.quotepath=false diff --name-only "$recent_from" "$merge_base" -- "${EXCLUDES[@]}" | sort -u > "$WORK/recent_files"
  comm -12 "$WORK/pr_files" "$WORK/recent_files" > "$WORK/s1b_candidates"
  while IFS= read -r F; do
    diff_side + "$recent_from" "$merge_base" -- "$F" | normalize_lines > "$WORK/recent_added"
    diff_side - "$merge_base" "$head_sha" -- "$F"    | normalize_lines > "$WORK/pr_deleted"
    diff_side + "$merge_base" "$head_sha" -- "$F"    | normalize_lines > "$WORK/pr_added"
    # erased = (recently added on base ∩ deleted by PR) minus lines the PR
    # re-adds elsewhere in the file (a move is not an erasure)
    comm -12 "$WORK/recent_added" "$WORK/pr_deleted" | comm -23 - "$WORK/pr_added" > "$WORK/erased"
    n="$(grep -c . "$WORK/erased" || true)"
    if [ "$n" -ge "$RI_INTERSECT_MIN_LINES" ]; then
      # identity = the erasure IN PLACE, not the summary and not the erased set.
      # The summary's "$n line(s) in $F" is identical for any two erasures of the
      # same size in one file; the erased set is deduped and unordered, so it is
      # identical for two deletions of the same text at different locations.
      # hunks_containing keeps the raw bodies and their context. Commit subjects
      # are excluded on purpose — the 14d window slides, so they churn without
      # the finding changing.
      add_signal erased-recent-base-work warn \
        "PR deletes $n line(s) that landed in $F on $BASE_REF within the last ${RI_RECENT_DAYS}d — possible clobber of recently-merged work" \
        "$F" "$(git log --since="${RI_RECENT_DAYS} days ago" --format='%h %s' "$merge_base" -- "$F" | head -5)" \
        "$(printf 'erased-recent-base-work\n%s\n' "$F"
           git show "$merge_base:$F" > "$WORK/refimg" 2>/dev/null || : > "$WORK/refimg"
           git -c core.quotepath=false diff --unified=3 "$merge_base" "$head_sha" -- "$F" \
             | hunks_containing "$WORK/erased" - "$WORK/refimg")"
    fi
  done < "$WORK/s1b_candidates"
fi

# --- S4 reintroduced-removed-lines ---------------------------------------------
STAGE="reintroduced-removed-lines"
if [ "$pr_file_count" -le "$RI_MAX_FILES" ]; then
  # Window runs to base_tip (not merge_base) so it also catches "base removed it
  # after this PR diverged" — the pre-merge-detectable half of the behind case.
  git -c core.quotepath=false diff --name-only "$recent_from" "$base_tip" -- "${EXCLUDES[@]}" | sort -u > "$WORK/base_window_files"
  comm -12 "$WORK/pr_files" "$WORK/base_window_files" > "$WORK/s4_candidates"
  while IFS= read -r F; do
    diff_side - "$recent_from" "$base_tip" -- "$F"  | normalize_lines > "$WORK/base_removed"
    diff_side + "$merge_base" "$head_sha" -- "$F"   | normalize_lines > "$WORK/pr_added"
    diff_side - "$merge_base" "$head_sha" -- "$F"   | normalize_lines > "$WORK/pr_deleted"
    # reintroduced = (removed on base ∩ added by PR) minus lines the PR also
    # deletes (a move within the PR is not a reintroduction)
    comm -12 "$WORK/base_removed" "$WORK/pr_added" | comm -23 - "$WORK/pr_deleted" > "$WORK/reintroduced"
    n="$(grep -c . "$WORK/reintroduced" || true)"
    if [ "$n" -ge "$RI_INTERSECT_MIN_LINES" ]; then
      # Same location/multiplicity argument as erased-recent-base-work above,
      # mirrored onto the + side: re-adding the same text at a different place is
      # a different finding, and the deduped set cannot tell those apart.
      add_signal reintroduced-removed-lines warn \
        "PR re-adds $n line(s) that were removed from $F on $BASE_REF within the last ${RI_RECENT_DAYS}d — possible reintroduction of fixed/reverted code" \
        "$F" "$(git log --since="${RI_RECENT_DAYS} days ago" --format='%h %s' "$base_tip" -- "$F" | head -5)" \
        "$(printf 'reintroduced-removed-lines\n%s\n' "$F"
           git show "$head_sha:$F" > "$WORK/refimg" 2>/dev/null || : > "$WORK/refimg"
           git -c core.quotepath=false diff --unified=3 "$merge_base" "$head_sha" -- "$F" \
             | hunks_containing "$WORK/reintroduced" + "$WORK/refimg")"
    fi
  done < "$WORK/s4_candidates"
fi

# --- S2 large-deletion ---------------------------------------------------------
STAGE="large-deletion"
git -c core.quotepath=false diff --numstat "$merge_base" "$head_sha" -- "${EXCLUDES[@]}" > "$WORK/numstat"
read -r adds dels <<<"$(awk -F'\t' '$1 != "-" {a += $1; d += $2} END {printf "%d %d", a, d}' "$WORK/numstat")"
if [ "$dels" -ge "$RI_DEL_ABS" ] && [ "$dels" -ge $(( RI_DEL_RATIO * (adds + 1) )) ]; then
  # Identity is the deleted BODY IN PLACE, not the totals: the summary carries
  # only counts and `files` only the top-10 by volume, so two heads deleting
  # entirely different content with equal totals from the same files would
  # otherwise hash alike and let an ack carry onto a deletion nobody judged.
  #
  # Built per-file through hunks_containing --all so every hunk carries the same
  # occurrence ordinal the line-window signals use. A flat projection of the
  # deleted lines is NOT enough: byte-identical duplicate blocks deleted at two
  # different locations in one file render identically without it. The explicit
  # path line keeps a block moving between files distinct too.
  : > "$WORK/large_del_body"
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    git show "$merge_base:$F" > "$WORK/refimg" 2>/dev/null || : > "$WORK/refimg"
    { printf '+++ %s\n' "$F"
      git -c core.quotepath=false diff --unified=3 "$merge_base" "$head_sha" -- "$F" \
        | hunks_containing --all - "$WORK/refimg"
    } >> "$WORK/large_del_body"
  done < <(awk -F'\t' '$1 != "-" && $2 > 0 {print $3}' "$WORK/numstat" | sort -u)
  add_signal large-deletion warn \
    "PR deletes $dels line(s) vs $adds added — deletion volume disproportionate to additions (RI_DEL_ABS=$RI_DEL_ABS, RI_DEL_RATIO=$RI_DEL_RATIO)" \
    "$(awk -F'\t' '$2 != "-"' "$WORK/numstat" | sort -t"$(printf '\t')" -k2,2nr | head -10 | cut -f3)" \
    "" \
    "$(printf 'large-deletion\n'; cat "$WORK/large_del_body")"
fi

# --- S5 duplicate-patch-id / already-merged (patch-id over the PR range) --------
# Patch-ids use FULL diffs (no excludes): commit identity should not depend on
# which paths we consider noisy. Known blind spot: commits whose patch is empty
# or binary-only produce NO patch-id line, so they are invisible to the
# duplicate and dropped-commit signals.
STAGE="patch-ids"
new_count="$(git rev-list --count --no-merges "$merge_base..$head_sha")"
if [ "$new_count" -gt "$RI_MAX_COMMITS" ]; then
  note_skip "duplicate-patch-id/dropped-commits: PR has $new_count commits (> RI_MAX_COMMITS=$RI_MAX_COMMITS)"
  : > "$WORK/new_pids"
  skip_patch_ids=1
else
  git log --no-merges -p "$merge_base..$head_sha" | git patch-id --stable > "$WORK/new_pids"
  skip_patch_ids=0
fi

STAGE="duplicate-patch-id"
if [ "$skip_patch_ids" -eq 0 ]; then
  dup_shas=""
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    while IFS= read -r sha; do
      dup_shas+="$(git log -1 --format='%h %s' "$sha")"$'\n'
    done < <(awk -v p="$pid" '$1 == p {print $2}' "$WORK/new_pids")
  done < <(awk '{print $1}' "$WORK/new_pids" | sort | uniq -d)
  if [ -n "$dup_shas" ]; then
    add_signal duplicate-patch-id warn \
      "the PR branch contains commits with identical patch content — a sign the rebase replayed the same change twice" \
      "" "$dup_shas"
  fi

  # already-merged replays: benign at merge time, but worth a note (info)
  merged_shas=""
  while IFS= read -r sha; do
    merged_shas+="$(git log -1 --format='%h %s' "$sha")"$'\n'
  done < <(git cherry "$base_tip" "$head_sha" | awk '$1 == "-" {print $2}' | head -10)
  if [ -n "$merged_shas" ]; then
    add_signal already-merged info \
      "PR commit(s) are patch-identical to commits already on $BASE_REF (replayed after a merge) — usually benign at merge time" \
      "" "$merged_shas"
  fi
fi

# --- S3 dropped-commits (force-push analysis via the GitHub timeline) ----------
# There is no reflog at CI time; HeadRefForcePushedEvent is the stateless
# substitute. ALL force-push events are analyzed (up to RI_MAX_FORCE_PUSHES),
# not just the latest: a commit dropped two pushes ago is absent from the last
# event's before/after pair, so a latest-only comparison would read CLEAN and a
# follow-up push could erase a prior WARN. Union of every pre-push head's
# commits vs (current head ∪ base) keeps each head's report self-contained.
# Degrades to a skipped note on any API/fetch issue.
STAGE="dropped-commits"
RI_MAX_FORCE_PUSHES="${RI_MAX_FORCE_PUSHES:-20}"
if [ "$skip_patch_ids" -eq 0 ]; then
  owner="${REPO%%/*}"
  name="${REPO#*/}"
  gql='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        timelineItems(itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT], first:100){
          pageInfo{ hasNextPage }
          nodes{ ... on HeadRefForcePushedEvent { beforeCommit { oid } } }
        }
      }
    }
  }'
  ev_json="$("$GH" api graphql -f owner="$owner" -f name="$name" -F pr="$PR" -f query="$gql" 2>/dev/null)" \
    || { note_skip "dropped-commits: could not query force-push events (gh failed)"; ev_json=""; }
  befores=""
  if [ -n "$ev_json" ]; then
    nodes_len="$(jq -r '.data.repository.pullRequest.timelineItems.nodes | length' <<<"$ev_json" 2>/dev/null || echo 0)"
    # zero nodes = never force-pushed = nothing to compare (normal; no note)
    if [ "$nodes_len" != "0" ]; then
      befores="$(jq -r '.data.repository.pullRequest.timelineItems.nodes[]? | .beforeCommit.oid // empty' <<<"$ev_json" 2>/dev/null | awk '!seen[$0]++' || true)"
      before_count="$(printf '%s' "$befores" | grep -c . || true)"
      [ "$before_count" -eq "$nodes_len" ] || note_skip "dropped-commits: $(( nodes_len - before_count )) force-push event(s) have no beforeCommit (object gone on GitHub)"
      if [ "$(jq -r '.data.repository.pullRequest.timelineItems.pageInfo.hasNextPage' <<<"$ev_json" 2>/dev/null)" = "true" ]; then
        note_skip "dropped-commits: more than 100 force-push events; analyzed the first 100"
      fi
      if [ "$before_count" -gt "$RI_MAX_FORCE_PUSHES" ]; then
        note_skip "dropped-commits: $before_count force-push events; analyzed the most recent $RI_MAX_FORCE_PUSHES"
        befores="$(printf '%s\n' "$befores" | tail -n "$RI_MAX_FORCE_PUSHES")"
      fi
    fi
  fi
  if [ -n "$befores" ]; then
    : > "$WORK/old_pids"
    for before in $befores; do
      if ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
        # GitHub keeps force-pushed-away commits fetchable by SHA (usually)
        if [ "${RI_SKIP_FETCH:-0}" = 1 ] || ! git fetch origin "$before" --quiet 2>/dev/null; then
          note_skip "dropped-commits: pre-rebase commit ${before:0:7} not fetchable"
          continue
        fi
      fi
      old_mb="$(git merge-base "$before" "$base_tip" 2>/dev/null || true)"
      if [ -z "$old_mb" ]; then
        note_skip "dropped-commits: no merge-base between pre-rebase head ${before:0:7} and $BASE_REF"
        continue
      fi
      if [ "$(git rev-list --count --no-merges "$old_mb..$before")" -gt "$RI_MAX_COMMITS" ] \
        || [ "$(git rev-list --count --no-merges "$old_mb..$base_tip")" -gt "$RI_MAX_COMMITS" ]; then
        note_skip "dropped-commits: range for pre-rebase head ${before:0:7} exceeds RI_MAX_COMMITS=$RI_MAX_COMMITS"
        continue
      fi
      git log --no-merges -p "$old_mb..$before" | git patch-id --stable >> "$WORK/old_pids"
      # base-side sets accumulate per event (old_mb can differ across events;
      # overlaps dedupe via sort -u below)
      git log --no-merges -p "$old_mb..$base_tip" | git patch-id --stable >> "$WORK/base_pids_acc"
      git log --no-merges --format='%s' "$old_mb..$base_tip" >> "$WORK/base_subjects_acc"
    done
    if [ -s "$WORK/old_pids" ]; then
      awk '{print $1}' "$WORK/new_pids" "$WORK/base_pids_acc" 2>/dev/null | sort -u > "$WORK/known_pids"
      awk '{print $1}' "$WORK/old_pids" | sort -u > "$WORK/old_pid_set"
      { git log --no-merges --format='%s' "$merge_base..$head_sha"
        cat "$WORK/base_subjects_acc" 2>/dev/null || true; } | sort -u > "$WORK/known_subjects"
      dropped_list=""
      rewritten_list=""
      while IFS= read -r pid; do
        sha="$(awk -v p="$pid" '$1 == p {print $2; exit}' "$WORK/old_pids")"
        line="$(git log -1 --format='%h %s' "$sha")"
        if grep -Fxq -- "${line#* }" "$WORK/known_subjects"; then
          rewritten_list+="$line"$'\n'
        else
          dropped_list+="$line"$'\n'
        fi
      done < <(comm -23 "$WORK/old_pid_set" "$WORK/known_pids")
      if [ -n "$dropped_list" ]; then
        add_signal dropped-commits warn \
          "commit(s) present on a previous head of this PR are absent from the current branch and never landed on $BASE_REF — a force-push may have dropped them" \
          "" "$dropped_list"
      fi
      if [ -n "$rewritten_list" ]; then
        add_signal rewritten-commits info \
          "commit(s) were rewritten across force-pushes (same subject, different patch) — normal for amends, listed for context" \
          "" "$rewritten_list"
      fi
    fi
  fi
fi

# --- report + state ------------------------------------------------------------
STAGE="report"
sha7="${head_sha:0:7}"
warn_count="$(jq -rs '[.[] | select(.severity == "warn")] | length' "$WORK/signals.ndjson")"
status=CLEAN
if [ "$warn_count" -gt 0 ]; then
  status=WARN
  # One value covering the WHOLE warn set (sorted, so signal order can't perturb
  # it). Guard 8's carryover compares this: gaining or losing any warn signal
  # changes it, so an ack can never carry onto a head that grew a new finding.
  #
  # A single non-carryable warn signal voids the rollup for the whole report —
  # the digest must mean "every warn finding here is content-identified", and a
  # partial rollup would carry an ack while one finding's content went unchecked.
  # Left unset in that case (and on CLEAN); write_state's `${warn_digest:-}`
  # covers it under set -u, the same way it covers merge_base/base_tip on the
  # early-ERROR path, and Guard 8's 64-hex test rejects the empty value.
  noncarryable="$(jq -rs '[.[] | select(.severity == "warn" and .carryable == false)] | length' \
    "$WORK/signals.ndjson")"
  if [ "$noncarryable" -eq 0 ]; then
    warn_digest="$(jq -rs '[.[] | select(.severity == "warn") | .digest] | sort | join("\n")' \
      "$WORK/signals.ndjson" | sha256sum | awk '{print $1}')"
  fi
fi

echo
echo "Rebase integrity for PR #$PR @ $sha7 (base $BASE_REF, merge-base ${merge_base:0:7}): $status"
if [ -s "$WORK/signals.ndjson" ]; then
  jq -r '"  [\(.severity)] \(.id): \(.summary)"
         + (if (.files   | length) > 0 then "\n" + (.files   | map("      file:   " + .) | join("\n")) else "" end)
         + (if (.commits | length) > 0 then "\n" + (.commits | map("      commit: " + .) | join("\n")) else "" end)' \
    "$WORK/signals.ndjson"
fi

# one ::warning:: per warn-severity signal — the advisory CI surface
jq -r --arg sha7 "$sha7" \
  'select(.severity == "warn") | "::warning::REBASE WARNING [\($sha7)] \(.id): \(.summary)"' \
  "$WORK/signals.ndjson"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Rebase integrity — $status"
    echo
    if [ "$status" = WARN ]; then
      echo "Signals below suggest the rebase may have reverted or clobbered existing work."
      echo "This is advisory: it does not block CI, but QA auto-approval is held until a"
      echo "human resolves the REBASE WARNING thread on the PR."
      echo
    fi
    # fenced: summaries embed PR-author-controlled paths/subjects — a fence
    # keeps crafted names from injecting markdown into the summary
    echo '```text'
    jq -r '"[\(.severity)] \(.id): \(.summary)"' "$WORK/signals.ndjson"
    if [ -s "$WORK/skipped" ]; then
      echo
      echo "Skipped (no data, not clean-by-proof):"
      sed 's/^/- /' "$WORK/skipped"
    fi
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

STAGE="write-state"
# Fail LOUD if the hand-off can't be written: exiting 0 without a state file
# would read as "no data → pass" to Guard 8, silently disabling the check.
write_state "$status" || { echo "check-rebase-integrity: cannot write state file under RI_STATE_DIR=$RI_STATE_DIR" >&2; exit 3; }

ANALYSIS_DONE=1
exit 0
