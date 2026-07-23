#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the admin-API payload contract documented in skills.
#
# Incident 2026-07-15: the operations agent sent 16x
#   POST /admin/track/<id>/analytics-sources '{"url":"..."}'
# and got 16x HTTP 400 "Invalid link", because the skill documented the stale
# {"url": ...} field while the live API expects {"link": ...}. PR #696 fixed the
# one line in skills-all/muso-ops-tracks/SKILL.md, but nothing stops a revert or
# a stale copy from resurrecting the dead field. Prose != enforcement, so this
# gate fails CI if the dead payload reappears in any skill doc, or if the
# corrected canonical example is silently removed.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

TRACKS_SKILL="${TRACKS_SKILL_FILE:-$ROOT/skills-all/muso-ops-tracks/SKILL.md}"

[ -f "$TRACKS_SKILL" ] || {
  echo "Missing $TRACKS_SKILL (run from repo root, or set TRACKS_SKILL_FILE)." >&2
  exit 2
}
for d in "$ROOT/skills-all" "$ROOT/workspaces"; do
  [ -d "$d" ] || {
    echo "Missing directory $d — cannot scan skill docs (run from repo root, or set REPO_ROOT)." >&2
    exit 2
  }
done

fail=0

# --- negative check: the dead {"url": ...} payload must not reappear ---------
# The admin API has no "url" field on any documented payload; the only place it
# ever appeared was the pre-#696 analytics-sources add example. Each file is
# scanned with newlines flattened to spaces, so compact ({"url":), spaced
# ({ "url": ...) and multi-line pretty-printed forms are all caught.
skill_docs=$(find "$ROOT/skills-all" "$ROOT/workspaces" -type f -name 'SKILL.md') || {
  echo "find failed while enumerating skill docs — refusing to pass vacuously." >&2
  exit 2
}
stale=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -r "$f" ] || {
    echo "Unreadable skill doc $f — refusing to pass vacuously." >&2
    exit 2
  }
  # Flatten to a variable first: grep never shares a live pipe with tr, so a
  # POSIX grep -q that exits at first match can never SIGPIPE the producer
  # (observed GNU grep drains the pipe, but the contract must not rely on it).
  flat=$(tr '\n' ' ' < "$f") || {
    echo "tr failed reading $f — refusing to pass vacuously." >&2
    exit 2
  }
  rc=0
  grep -qE -- '\{[[:space:]]*"url"[[:space:]]*:' <<< "$flat" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "grep failed (exit $rc) scanning $f — refusing to pass vacuously." >&2
    exit 2
  fi
  if [ "$rc" -eq 0 ]; then
    lines=$(grep -nE -- '"url"[[:space:]]*:' "$f" | cut -d: -f1 | paste -sd, - || true)
    stale+="$f (\"url\" key at line(s): ${lines:-spanning a line break})"$'\n'
  fi
done <<< "$skill_docs"
if [ -n "$stale" ]; then
  echo "FAIL: dead admin-API payload field {\"url\": ...} found in skill docs:" >&2
  echo "$stale" >&2
  echo "      The admin API expects {\"link\": ...} (HTTP 400 \"Invalid link\" otherwise; see PR #696)." >&2
  fail=1
fi

# --- positive anchor: the corrected canonical example must survive -----------
# Bounded to the add-link block: the {"link": ...} payload must sit right under
# the analytics-sources POST line, so an unrelated "link" payload elsewhere in
# the file cannot satisfy the guard.
if ! grep -A2 -F -- 'call POST "/admin/track/<track_id>/analytics-sources"' "$TRACKS_SKILL" \
  | grep -qF -- '{"link":'; then
  echo "FAIL: ${TRACKS_SKILL#"$ROOT"/}: the analytics-sources add-link example with the {\"link\": ...} payload is missing." >&2
  echo "      This is the #696 correction; restore the documented example." >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Admin-API doc contract has regressed. Context: scripts/check-admin-api-doc-contract.sh header + PR #696." >&2
  exit 1
fi

echo "OK: admin-API doc contract intact (analytics-sources payload documents {\"link\": ...}, no {\"url\": ...} anywhere)."
