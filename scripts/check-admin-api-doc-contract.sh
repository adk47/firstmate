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
# gate fails CI if a dead payload reappears in any skill doc.
#
# The real fix for the class is upstream of this gate: the analytics-source
# payloads now live in muso-cli's typed `tracks sources` verbs (golden-tested,
# so the body key cannot drift), and the skill documents those verbs instead of
# hand-rolled curl bodies. This gate therefore anchors on the skill pointing at
# the CLI, and keeps failing on the dead field names a hand-rolled body would
# reach for.

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

# --- negative check: fromTrackId is a phantom field --------------------------
# moveAnalyticsLink.js validates the body against {id?, linkId?} and reads only
# {link, linkId}. fromTrackId was documented for the PATCH but has never been
# read by the handler — a doc that teaches it teaches a silent no-op, so an
# operator "moves" a source and nothing happens.
# Matched as a quoted JSON key so prose that names the field to warn against it
# (in backticks) stays legal — only a payload carrying it fails.
#
# Scanned exactly like the {"url": ...} check above: the same SKILL.md
# enumeration, the same newline flattening, and the same fail-CLOSED handling of
# grep's exit status. A `2>/dev/null || true` here would turn an unreadable
# subtree or a grep I/O error into an empty result and let a phantom payload
# through — the guard must never pass vacuously.
phantom=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -r "$f" ] || {
    echo "Unreadable skill doc $f — refusing to pass vacuously." >&2
    exit 2
  }
  flat=$(tr '\n' ' ' < "$f") || {
    echo "tr failed reading $f — refusing to pass vacuously." >&2
    exit 2
  }
  rc=0
  grep -qE -- '"fromTrackId"[[:space:]]*:' <<< "$flat" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "grep failed (exit $rc) scanning $f for fromTrackId — refusing to pass vacuously." >&2
    exit 2
  fi
  if [ "$rc" -eq 0 ]; then
    lines=$(grep -nE -- '"fromTrackId"[[:space:]]*:' "$f" | cut -d: -f1 | paste -sd, - || true)
    phantom+="$f (\"fromTrackId\" key at line(s): ${lines:-spanning a line break})"$'\n'
  fi
done <<< "$skill_docs"
if [ -n "$phantom" ]; then
  echo "FAIL: phantom admin-API field fromTrackId found in:" >&2
  echo "$phantom" >&2
  echo "      moveAnalyticsLink.js never reads it; the PATCH body is {id?, linkId?} and the" >&2
  echo "      path track is the DESTINATION. Document \`muso tracks sources move\` instead." >&2
  fail=1
fi

# --- negative check: no remove-then-re-add recovery advice --------------------
# `tracks sources move` is the only non-destructive way to reassign a source: the
# remove verb is bulk-gated and destroys the captured counters. The skill said so
# in the reassignment block and then contradicted itself in Common Issues, which
# is the shape that sends an operator down the destructive path anyway — one
# authoritative line is not enforcement while a stale one survives elsewhere.
#
# Scanned per LINE rather than flattened, because the negation that makes a
# mention legal ("do NOT remove-then-add") lives on the same line as the mention.
# Flattening would merge a prohibition on one line with an instruction on the
# next and either miss the instruction or fire on the prohibition.
rc=0
mentions=$(grep -nEi -- 'remove[^.]*re-?add|re-?add[^.]*remove' "$TRACKS_SKILL") || rc=$?
if [ "$rc" -ge 2 ]; then
  echo "grep failed (exit $rc) scanning $TRACKS_SKILL for remove-then-re-add — refusing to pass vacuously." >&2
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  rc=0
  # Drop the lines that name the destructive path in order to FORBID it.
  destructive=$(grep -vEi -- '\b(not|never|instead of|rather than)\b' <<< "$mentions") || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "grep failed (exit $rc) filtering remove-then-re-add mentions — refusing to pass vacuously." >&2
    exit 2
  fi
  if [ -n "$destructive" ]; then
    echo "FAIL: ${TRACKS_SKILL#"$ROOT"/}: remove-then-re-add is documented as a recovery:" >&2
    echo "$destructive" >&2
    echo "      The remove verb is bulk-gated and destroys the captured counters." >&2
    echo "      Document \`muso tracks sources move <destination_track_id> --link-id ...\` instead," >&2
    echo "      or phrase the mention as a prohibition." >&2
    fail=1
  fi
fi

# --- positive anchor: the bulk-gate override names the CLI's own flag --------
# The two surfaces spell the approval artifact differently: muso-admin-api.sh
# takes --approval-msg-id, muso-cli takes --approval-ref. Now that the documented
# commands are CLI commands, the bulk-destructive recovery instruction has to
# name --approval-ref, or an operator who trips the threshold cannot get past it.
#
# Anchored to the OPERATIONAL form — both flags on one line, as an operator would
# actually type them. A bare '--approval-ref' match would also be satisfied by the
# explanatory note that merely contrasts the two spellings, so deleting the real
# recovery instruction while keeping the note would still pass.
if ! grep -qE -- '--confirmed-by[^`]*--approval-ref' "$TRACKS_SKILL"; then
  echo "FAIL: ${TRACKS_SKILL#"$ROOT"/}: the bulk-destructive override no longer gives the" >&2
  echo "      operational '--confirmed-by <approver> --approval-ref <slack-ts>' form." >&2
  echo "      The documented commands are muso-cli commands; --approval-msg-id is the" >&2
  echo "      muso-admin-api.sh spelling and does not exist on the CLI." >&2
  fail=1
fi

# --- positive anchor: the skill must route through the typed CLI -------------
# Bounded to the add-link block: the --link flag must sit within the documented
# `tracks sources add` invocation, so an unrelated mention elsewhere in the file
# cannot satisfy the guard.
if ! grep -A2 -F -- 'tracks sources add <track_id>' "$TRACKS_SKILL" \
  | grep -qF -- '--link '; then
  echo "FAIL: ${TRACKS_SKILL#"$ROOT"/}: the analytics-sources add example no longer documents" >&2
  echo "      \`muso tracks sources add <track_id> --link ...\`." >&2
  echo "      That verb is where the {\"link\": ...} contract is enforced (typed body + golden)." >&2
  echo "      Hand-rolled muso-admin-api.sh bodies are what caused incident 2026-07-15." >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Admin-API doc contract has regressed. Context: scripts/check-admin-api-doc-contract.sh header + PR #696." >&2
  exit 1
fi

echo "OK: admin-API doc contract intact (analytics-sources documented via \`muso tracks sources\`; no {\"url\": ...} or \"fromTrackId\" payload anywhere)."
