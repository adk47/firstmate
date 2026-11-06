#!/usr/bin/env bash
# check-credit-status-writes.sh — CI guard: hydra never writes a credit status outside core's PUT, and never moves
# one silently (Fable GO 2026-10-31, [key=decided-not-told-531]).
#
# WHY. 538 users had credit requests core DECIDED and never told them about. Most were validator approvals that
# landed under a notify:false re-drive marker (10-23 / 10-26); a few were direct SQL writes that bypassed the PUT
# entirely (a reclass, a p-line label approve, three rejections). Core's PUT always sends the decision notice, and
# with core #11088/#11089 a re-drive owes exactly one notice — so the class closes if hydra code can do neither.
#
# Fails when any tracked code file under scripts/ or workspaces/ (tests and fixtures excluded) contains:
#   1. a direct SQL write:   UPDATE [public.]credit_requests   (any quoting, any case)
#      or a Sequelize write: CreditRequests.update(
#      or a Mongo write on a credit-requests collection: updateOne / updateMany / findOneAndUpdate / replaceOne /
#      bulkWrite (or the pymongo snake_case forms) on a line that names credit_requests / creditRequests
#   2. a silent move body:   "notify": false  |  'notify': False  |  notify: false (JS key)  |  notify=False
# unless the file is listed in policies/credit-status-write-allowlist.txt (one repo-relative path per line, '#'
# comments; each entry needs a reason and r5's review). The allowlist is EMPTY today: the only sanctioned silent
# path is core's own re-drive marker, which hydra reaches through the ordinary PUT.
#
# Usage: check-credit-status-writes.sh [--root DIR]
# Exit:  0 clean, 1 violation, 2 unreadable input.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--root" ]]; then
  ROOT="$(cd "${2:?--root needs a directory}" && pwd)"
fi
ALLOW="${CREDIT_STATUS_WRITE_ALLOWLIST:-$ROOT/policies/credit-status-write-allowlist.txt}"
[[ -r "$ALLOW" ]] || { echo "ERROR: allowlist $ALLOW unreadable" >&2; exit 2; }

# The scanner lives in scripts/lib/credit_status_write_gate.py — NOT a line grep, because a per-line scan cannot keep
# this promise (QA #1578): `UPDATE\n credit_requests`, `UPDATE "public"."credit_requests"`, a `.updateMany(` on the
# line after its collection, and `"notify":` with `false` underneath are all valid writes that a line match returns
# OK for. It normalises identifier quoting, matches across newlines, and skips the files that name the patterns.

SCANNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/credit_status_write_gate.py"  # ships WITH the guard, not with --root
[[ -r "$SCANNER" ]] || { echo "ERROR: scanner $SCANNER unreadable" >&2; exit 2; }

declare -A allowed=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [[ -n "$line" ]] && allowed["$line"]=1
done < "$ALLOW"

cd "$ROOT"
# qa-review #1578 (r18) Critical: `mapfile -t files < <(git ls-files ...)` succeeds even when `git ls-files` FAILS, so
# a corrupt or unreadable index made the required CI gate exit 0 with "0 tracked files scanned" - green while scanning
# nothing. The listing is captured first and its exit status checked: a discovery failure is exit 2 (unreadable
# input), never a pass.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! listing="$(git ls-files -- scripts workspaces)"; then
    echo "ERROR: git ls-files failed, so the file list cannot be trusted; refusing to report a clean gate" >&2
    exit 2
  fi
else
  if ! listing="$(find scripts workspaces -type f 2>/dev/null | sort)"; then
    echo "ERROR: find failed, so the file list cannot be trusted; refusing to report a clean gate" >&2
    exit 2
  fi
fi
mapfile -t files <<< "$listing"
# an EMPTY listing is not a clean tree: a repo with no scripts/ is a broken checkout, not a passing gate
if (( ${#files[@]} == 0 )) || [[ -z "${files[0]}" ]]; then
  echo "ERROR: the file discovery returned nothing; refusing to report a clean gate" >&2
  exit 2
fi

scanned=0
in_scope=()
for f in "${files[@]}"; do
  case "$f" in
    */tests/*|*/test/*|*.bats|*/fixtures/*) continue ;;
    scripts/check-credit-status-writes.sh|scripts/lib/credit_status_write_gate.py) continue ;;  # they name the patterns
    *.py|*.sh|*.bash|*.js|*.mjs|*.cjs|*.ts|*.sql|*.lobster) ;;
    *) continue ;;
  esac
  [[ -f "$f" ]] || continue
  [[ -n "${allowed[$f]:-}" ]] && continue
  in_scope+=("$f")
  scanned=$((scanned + 1))
done

if (( scanned )); then
  printf '%s\n' "${in_scope[@]}" | python3 "$SCANNER" --root "$ROOT" --allow "$ALLOW" && bad=0 || bad=$?
  (( bad == 2 )) && exit 2
  (( bad == 0 )) || bad=1
else
  bad=0
fi

if (( bad )); then
  echo "credit-status-write guard FAILED (allowlist: $ALLOW; an entry needs a reason + r5 review)" >&2
  exit 1
fi
echo "OK: no direct or silent credit-status write in scripts/ or workspaces/ ($scanned tracked files scanned)"
