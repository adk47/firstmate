#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop against stale Trino SQL shipping in skills-all/.
#
# Five ops escalations trace back to SQL in skills-all/ that no longer
# compiles against live Trino (schema drift: dropped columns, retyped
# columns, changed UNNEST alias arity, dead catalogs/tables). A sweep found
# 99 of 169 SQL statements fail. PR #794 fixed the worst by hand; this gate
# stops regression, the same "prose != enforcement, add a mechanical gate"
# doctrine as scripts/check-dead-infra-refs.sh.
#
# Two layers:
#   Layer A (this file, offline grep) — the historically top-recurring dead
#     references (awsdatacatalog., raw_ids, profile_permissions,
#     profile_v3_(lifetime|tracks)), modeled on check-dead-infra-refs.sh's
#     PAT[] table. Catches these even if Trino is unreachable.
#   Layer B (scripts/lib/trino_sql_gate.py) — live `EXPLAIN (TYPE VALIDATE)`
#     compilation of every extracted statement, ratcheted against
#     .trino-sql-baseline.txt (99 known-failing statements at gate
#     inception) so the gate blocks NEW regressions without instantly
#     reddening every PR on pre-existing debt.
#
# THE SAFETY INVARIANT: the Trino CLI splits `--execute` input on ';' and
# only the FIRST statement keeps an EXPLAIN prefix — the rest EXECUTE for
# real. skills-all/ has ~19 multi-statement fences and ~14 deliberate
# `-- BAD: ...` anti-example queries (some ran 150-450s on the prod
# coordinator when this was gotten wrong once already). Layer B therefore
# NEVER joins statements with ';' and sends exactly one EXPLAIN-prefixed
# statement per `kubectl exec` — enforced structurally in
# trino_sql_gate.py's single choke-point sender, not just by convention
# here. See scripts/lib/trino_sql_gate.py's module docstring for the full
# invariant.
#
# Scoping: PR runs (the default) scan only files changed vs origin/main, so
# a PR touching unrelated files isn't reddened by pre-existing SQL debt this
# gate hasn't looked at yet. Set TRINO_SQL_FULL_SCAN=1 for the full sweep
# (also enables the stale-baseline / stale-substitution-entry checks, which
# only make sense against the whole tree).
#
# Exit codes: 0 clean / 1 finding (new failure, stale baseline/substitution
# entry, undeclared placeholder) / 2 cannot-run (Trino unreachable,
# malformed allowlist/substitutions/baseline file, safety violation).

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

LAYER_A_ALLOWLIST="${TRINO_SQL_LAYER_A_ALLOWLIST:-$ROOT/.trino-sql-layer-a-allowlist.txt}"
SUBSTITUTIONS="${TRINO_SQL_SUBSTITUTIONS:-$ROOT/.trino-sql-substitutions.txt}"
BASELINE="${TRINO_SQL_BASELINE:-$ROOT/.trino-sql-baseline.txt}"
GATE_PY="$ROOT/scripts/lib/trino_sql_gate.py"

# Out-of-scope tree — 258 saved-query files on bare legacy Athena names,
# tracked separately, excluded from BOTH layers (also hard-excluded in
# scripts/lib/trino_sql_extract.py's EXCLUDED_DIRS for Layer B).
EXCLUDE_PREFIX="skills-all/muso-query-writer/saved-queries/"

if [ ! -d "$ROOT/skills-all" ]; then
  echo "Missing skills-all/ under $ROOT (run from repo root, or set REPO_ROOT)." >&2
  exit 2
fi
if [ ! -f "$LAYER_A_ALLOWLIST" ]; then
  echo "Missing allowlist $LAYER_A_ALLOWLIST (set TRINO_SQL_LAYER_A_ALLOWLIST to override)." >&2
  exit 2
fi

FULL_SCAN=0
if [ "${TRINO_SQL_FULL_SCAN:-0}" = "1" ]; then
  FULL_SCAN=1
fi

# ------------------------------------------------------------- file scope --
# Changed-file discovery FAILS CLOSED. If origin/main is unavailable or the
# `git diff` errors, an empty scope would sail straight through the "nothing to
# check" early return below and report a PR full of stale SQL as clean — the
# exact false green this gate exists to prevent. The status has to be captured
# here because mapfile cannot see a failure inside its process substitution,
# and a trailing `|| true` would swallow it outright.
if [ "$FULL_SCAN" = "1" ]; then
  RAW_SCOPE="$(find skills-all -type f \( -name '*.md' -o -name '*.sh' \) | LC_ALL=C sort)"
else
  diff_rc=0
  RAW_SCOPE="$(git diff --name-only origin/main...HEAD -- 'skills-all/*.md' 'skills-all/*.sh' | LC_ALL=C sort)" || diff_rc=$?
  if [ "$diff_rc" -ne 0 ]; then
    echo "Cannot determine changed files vs origin/main (git diff exited $diff_rc)." >&2
    echo "Refusing to report 'nothing to check' — stale SQL would ship unchecked." >&2
    exit 2
  fi
fi

mapfile -t SCOPE_FILES < <(
  printf '%s\n' "$RAW_SCOPE" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      "$EXCLUDE_PREFIX"*) ;;
      *) [ -f "$ROOT/$f" ] && echo "$f" ;;
    esac
  done
)

# ------------------------------------------- baseline ratchet (shrink-only) --
# The baseline freezes PRE-EXISTING debt; it must never absorb NEW debt. Without
# this check a single PR can add a stale query AND its normalized hash to the
# baseline, and Layer B then counts that brand-new failure as "baselined" and
# exits 0 — shipping behind a green check the exact regression the gate exists
# to block. write_baseline()'s header already documents "the file can only
# shrink"; this is what makes it enforcement rather than prose.
#
# Bootstrap: when the baseline does not exist at the merge base, this is the PR
# introducing the gate, so every entry is legitimately "added" and enforcement
# starts from the next PR. That is not a bypass — deleting and re-adding the
# file in a later PR still compares against the merge base, which retains it.
# Skipped on a full scan: that mode is the operator sweep / baseline-regeneration
# path, not a PR, and has no meaningful merge base.
if [ "$FULL_SCAN" != "1" ]; then
  mb_rc=0
  MERGE_BASE="$(git merge-base origin/main HEAD)" || mb_rc=$?
  if [ "$mb_rc" -ne 0 ]; then
    echo "Cannot resolve the merge base with origin/main (git merge-base exited $mb_rc)." >&2
    exit 2
  fi

  # awk, not `grep -v`: a comment-only baseline makes grep exit 1, and under
  # `set -o pipefail` that would kill the script before its own empty-file case.
  baseline_hashes() { awk '!/^[[:space:]]*(#|$)/ {print $1}' | LC_ALL=C sort -u; }

  BASELINE_REL="${BASELINE#"$ROOT/"}"
  if git cat-file -e "$MERGE_BASE:$BASELINE_REL" 2>/dev/null; then
    CUR_HASHES=""
    if [ -f "$BASELINE" ]; then
      CUR_HASHES="$(baseline_hashes <"$BASELINE")"
    fi
    ADDED="$(comm -13 \
      <(git show "$MERGE_BASE:$BASELINE_REL" | baseline_hashes) \
      <(printf '%s\n' "$CUR_HASHES"))"
    if [ -n "$ADDED" ]; then
      echo "FAIL: $BASELINE_REL gained entries relative to the merge base:" >&2
      printf '%s\n' "$ADDED" | sed 's/^/  /' >&2
      echo "" >&2
      echo "The baseline can only SHRINK. A newly-failing statement must be FIXED, not" >&2
      echo "baselined — otherwise this gate greenlights the regression it exists to block." >&2
      exit 1
    fi
  fi
fi

if [ "$FULL_SCAN" != "1" ] && [ "${#SCOPE_FILES[@]}" -eq 0 ]; then
  echo "No changed skills-all/ .md or .sh files vs origin/main — nothing to check."
  exit 0
fi

# --------------------------------------------------------------- Layer A --
declare -A PAT
PAT[awsdatacatalog]='awsdatacatalog\.'
PAT[rawids]='\braw_ids\b'
PAT[profilepermissions]='\bprofile_permissions\b'
PAT[v3]='profile_v3_(lifetime|tracks)'
PAT_KEYS=(awsdatacatalog rawids profilepermissions v3)

AL_PATHS=() AL_KEYS=()
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  case "$raw" in ''|'#'*) continue ;; esac
  case "$raw" in
    *' -- '*' -- '*) ;;
    *)
      echo "Malformed Layer A allowlist line $lineno (need '<path> -- <keys> -- <reason>'): $raw" >&2
      exit 2
      ;;
  esac
  path="${raw%% -- *}"
  rest="${raw#* -- }"
  keys="${rest%% -- *}"
  keys="${keys// /}"
  reason="${rest#* -- }"
  if [ -z "$path" ] || [ -z "$keys" ] || [ -z "$reason" ]; then
    echo "Malformed Layer A allowlist line $lineno: $raw" >&2
    exit 2
  fi
  for k in ${keys//,/ }; do
    if [ -z "${PAT[$k]:-}" ]; then
      echo "Unknown Layer A pattern key '$k' on line $lineno (valid: ${PAT_KEYS[*]})." >&2
      exit 2
    fi
  done
  AL_PATHS+=("$path")
  AL_KEYS+=("$keys")
done <"$LAYER_A_ALLOWLIST"

allow_idx() {
  local file="$1" key="$2" i
  for i in "${!AL_PATHS[@]}"; do
    case ",${AL_KEYS[$i]}," in *",$key,"*) ;; *) continue ;; esac
    case "${AL_PATHS[$i]}" in
      */) [[ "$file" == "${AL_PATHS[$i]}"* ]] && { echo "$i"; return 0; } ;;
      *)  [ "$file" = "${AL_PATHS[$i]}" ] && { echo "$i"; return 0; } ;;
    esac
  done
  return 1
}

declare -A ENTRY_USED
fail=0

if [ "${#SCOPE_FILES[@]}" -gt 0 ]; then
  echo "::group::Layer A — offline dead-reference grep"
  for key in "${PAT_KEYS[@]}"; do
    rc=0
    hits="$(grep -nIHE -e "${PAT[$key]}" -- "${SCOPE_FILES[@]}")" || rc=$?
    if [ "$rc" -ge 2 ]; then
      echo "grep failed (rc=$rc) while scanning Layer A pattern key '$key'." >&2
      exit 2
    fi
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
      file="${hit%%:*}"; rest="${hit#*:}"
      line="${rest%%:*}"; text="${rest#*:}"
      if idx="$(allow_idx "$file" "$key")"; then
        ENTRY_USED[$idx]=1
        continue
      fi
      echo "FAIL: $file:$line: [$key/layerA] ${text#"${text%%[![:space:]]*}"}" >&2
      fail=1
    done <<<"$hits"
  done
  echo "::endgroup::"
fi

if [ "$FULL_SCAN" = "1" ]; then
  for i in "${!AL_PATHS[@]}"; do
    p="${AL_PATHS[$i]}"
    if [ ! -e "$p" ]; then
      echo "FAIL: Layer A allowlist entry '$p' points at a nonexistent path — remove it." >&2
      fail=1
    elif [ -z "${ENTRY_USED[$i]:-}" ]; then
      echo "FAIL: Layer A allowlist entry '$p' (keys: ${AL_KEYS[$i]}) no longer matches anything — remove it." >&2
      fail=1
    fi
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Layer A: dead-reference hits (or stale allowlist entries) in Trino SQL." >&2
  echo "Fix the query, or add a '<path> -- <keys> -- <reason>' entry to $LAYER_A_ALLOWLIST" >&2
  echo "for genuinely historical/migration content (NEVER-use warnings, migration tables)." >&2
  exit 1
fi
echo "OK: Layer A clean (${#SCOPE_FILES[@]} file(s) scanned)."

# --------------------------------------------------------------- Layer B --
GATE_ARGS=(
  "$GATE_PY"
  --root "$ROOT"
  --baseline "$BASELINE"
  --substitutions "$SUBSTITUTIONS"
)
if [ "$FULL_SCAN" = "1" ]; then
  GATE_ARGS+=(--full)
else
  GATE_ARGS+=("${SCOPE_FILES[@]}")
fi

echo "::group::Layer B — live EXPLAIN (TYPE VALIDATE)"
gate_rc=0
python3 "${GATE_ARGS[@]}" || gate_rc=$?
echo "::endgroup::"

exit "$gate_rc"
