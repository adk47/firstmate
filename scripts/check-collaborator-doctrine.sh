#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the collaborator "derived table" doctrine.
#
# On 2026-07-29 a customer asked (via Jan) to remove ~24 named collaborators from a
# profile. The @Ops agent resolved the identities well, then proposed an UNSUPPORTED
# 32-row direct production DELETE against catalog_profile_collaboration and escalated it
# to Aaron for approval. That table is DERIVED from track co-credits: every rebuild
# recomputes the profile's rows from current master tracks and deletes anything not in
# the keep-list (profile_collaboration_writer.py:239-263). A rebuild of that same profile
# then reported rowsDeleted: 0 — every row the plan wanted to delete was live and
# credit-backed, so all 32 would have come straight back.
#
# Prose != enforcement, so this guard does two things:
#   (1) POSITIVE: fails CI if the load-bearing anchors of muso-ops-collaborators are
#       silently removed (the derived-table framing and the red line).
#   (2) NEGATIVE: fails CI if ANY skill doc anywhere starts handing agents write-SQL
#       against the collaboration/aggregation serving tables. This is the part that
#       catches the failure recurring in a skill nobody thought to look at.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SKILL="${COLLAB_SKILL_FILE:-$ROOT/skills-all/muso-ops-collaborators/SKILL.md}"

[ -f "$SKILL" ] || {
  echo "Missing $SKILL (run from repo root, or set COLLAB_SKILL_FILE)." >&2
  exit 2
}

for d in "$ROOT/skills-all" "$ROOT/workspaces"; do
  [ -d "$d" ] || {
    echo "Missing directory $d — cannot scan skill docs (run from repo root, or set REPO_ROOT)." >&2
    exit 2
  }
done

fail=0

# require <file> <label> <fixed-substring>
# Fails loudly (does not exit) so every missing anchor is reported in one pass.
require() {
  local file="$1" label="$2" pat="$3"
  if ! grep -qF -- "$pat" "$file" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    fail=1
  fi
}

# --- positive anchors: muso-ops-collaborators doctrine ----------------------
require "$SKILL" "the derived-table framing (the whole reason hand-deletes fail)" \
  "The collaborators list is derived"
require "$SKILL" "the serving table name the red line protects" \
  "catalog_profile_collaboration"
require "$SKILL" "the RED LINE heading" \
  "RED LINE — never write SQL against these tables"
require "$SKILL" "the mechanism-as-deterrent rule (not merely 'forbidden')" \
  "because it does not work"
require "$SKILL" "the one-directional rebuild warning" \
  "It does not touch the other direction"
require "$SKILL" "the no-pair-suppression statement" \
  "DOES NOT EXIST"
require "$SKILL" "the ambiguous-name STOP gate" \
  "STOP and ask the requester for the exact"
require "$SKILL" "the never-claim-removed rule" \
  'Never say "removed" until you have re-read the list'

# --- negative scan: no write-SQL against the serving tables, anywhere -------
# Each file is flattened to a single line so multi-line SQL blocks
# (DELETE FROM\n  catalog_profile_collaboration) are caught too.
skill_docs=$(find "$ROOT/skills-all" "$ROOT/workspaces" -type f -name 'SKILL.md') || {
  echo "find failed while enumerating skill docs — refusing to pass vacuously." >&2
  exit 2
}

[ -n "$skill_docs" ] || {
  echo "No SKILL.md files found — refusing to pass vacuously." >&2
  exit 2
}

# The serving tables that are rebuilt from source and must never be hand-written.
SERVING_TABLES='catalog_profile_collaboration|catalog_profile_aggregations'
# Two patterns, because the table sits on opposite sides of the verb:
#   <verb> ... <table>       -> table AFTER the verb (most mutations)
#   UPDATE <table> SET ...   -> table BETWEEN the verb and SET
# UPDATE is anchored to its SET so ordinary prose ("the offline job will update
# catalog_profile_aggregations later") does not trip the gate.
#
# Matched CASE-INSENSITIVELY (grep -qiE below). SQL keywords are case-insensitive
# to the engine, and agents write `delete from ...` in lowercase at least as often
# as they shout it. An uppercase-only guard let the most common spelling straight
# through while still claiming to reject any direct write — the exact false-green
# this file exists to prevent.
#
# VERB COVERAGE. The guard claims to reject *any* direct write, so the verb list
# has to mean it. DELETE/INSERT/UPDATE alone left TRUNCATE and Postgres 15's
# MERGE INTO — both fully destructive against a rebuilt serving table — passing
# while CI reported the doctrine intact. DROP/ALTER TABLE are here for the same
# reason: they are writes, and a skill has no business emitting them either.
#
# COPY is included too, but ANCHORED. Plain `COPY <table> FROM` would fire on
# ordinary prose ("copy catalog_profile_collaboration rows from Trino"), which is
# why it was left out at first. The fix is to require a real COPY *source* after
# the table — STDIN, PROGRAM, or a quoted path — which no English sentence about
# these tables carries. That gets the true positive (an executable bulk load
# straight into a rebuilt serving table) without the prose false positive.
WRITE_SQL_AFTER="(DELETE[[:space:]]+FROM|INSERT[[:space:]]+INTO|MERGE[[:space:]]+INTO|TRUNCATE([[:space:]]+TABLE)?|DROP[[:space:]]+TABLE|ALTER[[:space:]]+TABLE)[[:space:]][^;]*(${SERVING_TABLES})"
# COPY <table> ... FROM {STDIN|PROGRAM|'path'} — the anchored bulk-load form.
# Schema qualification (public.catalog_profile_collaboration) is covered by the
# [^;]* either side.
WRITE_SQL_COPY="COPY[[:space:]][^;]*(${SERVING_TABLES})[^;]*[[:space:]]FROM[[:space:]]+('|STDIN|PROGRAM)"
WRITE_SQL_UPDATE="UPDATE[[:space:]]+[^;]*(${SERVING_TABLES})[^;]*[[:space:]]SET[[:space:]]"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -r "$f" ] || {
    echo "Unreadable skill doc $f — refusing to pass vacuously." >&2
    exit 2
  }

  # The doctrine skill quotes the writer's DELETE predicate on purpose — that
  # quotation IS the deterrent, so it alone must not trip the gate.
  #
  # Redact ONLY that one sanctioned block; do NOT skip the file. Exempting the
  # whole path would leave the very skill that owns collaborator-removal
  # requests outside the negative guard: a later edit could keep every positive
  # anchor intact and still add a fresh INSERT/TRUNCATE/DELETE against a serving
  # table with CI green. Same reasoning for any sanctioned divergent workspace
  # copy, which is why the match is on PATH SHAPE rather than one literal path.
  #
  # The redaction is an EXACT literal match on the whole sanctioned quotation,
  # NOT a line-range delete. A range (`/opener/,/terminator/d`) removes every
  # line BETWEEN its anchors too, so a forbidden INSERT/TRUNCATE parked inside
  # the quoted block would be erased before the scan and CI would stay green —
  # a bypass sitting in the one file this exemption exists for.
  #
  # Exact matching also fails CLOSED on reformatting: change so much as a space
  # and the substring stops matching, so the quotation itself trips the guard
  # and the exemption has to be updated deliberately. The %s placeholders are
  # what make this text a quotation of the writer's code rather than anything
  # an agent could run.
  SANCTIONED_QUOTE='DELETE FROM catalog_profile_collaboration WHERE bucket = %s AND profile_id = %s AND NOT (collaborator_id = ANY(%s))'

  flat=$(tr '\n' ' ' < "$f") || {
    echo "tr failed reading $f — refusing to pass vacuously." >&2
    exit 2
  }

  case "$f" in
    */muso-ops-collaborators/SKILL.md)
      # Literal (quoted) pattern — no globbing. Removes only this exact run of
      # text; everything else in the file, including anything inserted between
      # the DELETE and its WHERE, stays in the scan.
      flat=${flat//"$SANCTIONED_QUOTE"/[SANCTIONED_QUOTE_REDACTED]}
      ;;
  esac

  hit=1
  for pat in "$WRITE_SQL_AFTER" "$WRITE_SQL_UPDATE" "$WRITE_SQL_COPY"; do
    rc=0
    grep -qiE -- "$pat" <<< "$flat" || rc=$?
    if [ "$rc" -ge 2 ]; then
      echo "grep failed (exit $rc) scanning $f — refusing to pass vacuously." >&2
      exit 2
    fi
    [ "$rc" -eq 0 ] && hit=0
  done
  if [ "$hit" -eq 0 ]; then
    echo "FAIL: ${f#"$ROOT"/}: hands agents write-SQL against a DERIVED serving table" >&2
    echo "      (catalog_profile_collaboration / catalog_profile_aggregations are rebuilt" >&2
    echo "       from track co-credits; hand-writes are silently reverted — see" >&2
    echo "       skills-all/muso-ops-collaborators/SKILL.md § RED LINE)" >&2
    fail=1
  fi
done <<< "$skill_docs"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Collaborator derived-table doctrine has regressed. Restore the anchors / drop the write-SQL above." >&2
  echo "Context: scripts/check-collaborator-doctrine.sh header (2026-07-29 Ops 32-row DELETE proposal)." >&2
  exit 1
fi

echo "OK: collaborator derived-table doctrine intact (muso-ops-collaborators anchors + no write-SQL in any skill doc)."
