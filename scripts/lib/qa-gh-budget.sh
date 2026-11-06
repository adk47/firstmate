#!/usr/bin/env bash
# qa-gh-budget.sh — shared GitHub REST budget guard for the QA reviewers.
#
# Every QA review spends GitHub REST calls (statuses, PR metadata, comments)
# under ONE App installation, so the budget is shared by every worker pod and
# by the reconciler. Scaling the reviewers to N pods multiplies the burn rate
# without multiplying the budget, so the workers must stop before the budget is
# gone rather than discover it mid-review (a 403 mid-review turns into a
# CANNOT REVIEW verdict, which is a false negative on a real PR).
#
# Design:
#   * `gh api rate_limit` is FREE (it does not count against the limit), so the
#     probe is cheap. It is still cached for QA_GH_BUDGET_TTL_S (default 300s)
#     in a shared file so 24 pods do not each poll it.
#   * The file is written atomically (tmp + mv) so a reader never sees a
#     half-written JSON.
#   * The floor is QA_GH_BUDGET_FLOOR (default 800). Below it, `ok` returns 1
#     and the worker stops claiming new jobs (it finishes the one it has).
#   * A probe failure is NOT "budget fine": an unreadable budget returns 2
#     (unknown) and the caller decides. The worker treats unknown as "keep
#     going" only while the cached value is fresh; a stale unknown is a stop.
#   * A cached reading is trusted for at most QA_GH_BUDGET_MAX_STALE_S (default
#     1800s) even when the probe keeps failing. Without that bound a probe that
#     fails FOREVER (revoked token, DNS, a proxy answering 500) keeps serving
#     the last good reading, and a stale `ok:5000` authorizes claims
#     indefinitely while the real budget drains to zero. Past the bound the
#     answer is `unknown`: fail closed, never fail open.
#
# Usage:
#   qa-gh-budget.sh check            # 0 ok, 1 below floor, 2 unknown
#   qa-gh-budget.sh show             # human-readable one line
#   qa-gh-budget.sh refresh          # force a probe, ignore the cache
#
# Env:
#   QA_GH_BUDGET_FILE   default /var/lib/hydra-qa/gh-budget.json
#   QA_GH_BUDGET_TTL_S  default 300
#   QA_GH_BUDGET_FLOOR  default 800
#   QA_GH_BUDGET_MAX_STALE_S  default 1800 (how long a cached reading is
#                             trusted while the probe keeps failing)
#   QA_GH_BUDGET_REPO   the repo whose identity the probe should use. Defaults
#                       to the first entry of policies/qa-approval-policy.json
#                       .identity.app_repos, else empty (host identity).
#   QA_GH               default <repo>/scripts/qa-gh.sh
#
# WHY THE PROBE IS SCOPED. `qa-gh.sh` only picks the GitHub App installation
# when it is given `--repo` (or QA_GH_IDENTITY=app); an unscoped call uses the
# ambient HOST account. So an unscoped `api rate_limit` measures the host's
# quota, not the installation's. In App mode those are different budgets: the
# host can read 5000 remaining while the installation the reviews actually
# spend is exhausted, the gate says `ok`, and every review then 403s mid-turn
# into a CANNOT REVIEW verdict on a real PR. The probe must measure the budget
# the reviews spend, so it is scoped to a repo in the installation.
#
# One installation is assumed: an App installation's quota is shared across all
# of its repos, so any repo in `app_repos` answers for all of them. If we ever
# run two installations this file must become per-scope (the cache already
# records its scope, so a mismatch is a miss rather than a wrong answer).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_GH="${QA_GH:-$HERE/../qa-gh.sh}"
BUDGET_FILE="${QA_GH_BUDGET_FILE:-/var/lib/hydra-qa/gh-budget.json}"
TTL="${QA_GH_BUDGET_TTL_S:-300}"
FLOOR="${QA_GH_BUDGET_FLOOR:-800}"
MAX_STALE="${QA_GH_BUDGET_MAX_STALE_S:-1800}"
POLICY="${QA_APPROVAL_POLICY:-$HERE/../../policies/qa-approval-policy.json}"

# The identity scope the probe measures. See the header: an unscoped probe
# measures the host account, which in App mode is the wrong budget entirely.
budget_repo() {
  if [ -n "${QA_GH_BUDGET_REPO:-}" ]; then
    printf '%s' "$QA_GH_BUDGET_REPO"
    return 0
  fi
  [ -r "$POLICY" ] || return 0
  jq -r '(.identity.app_repos // [])[0] // ""' "$POLICY" 2>/dev/null || true
}
SCOPE="$(budget_repo)"

now() { date -u +%s; }

# A malformed numeric setting must never be read as "no limit". `[ "$x" -lt bad ]`
# prints "integer expression expected" to stderr and evaluates FALSE, so a typo in
# QA_GH_BUDGET_FLOOR made the gate answer `ok:0` against an exhausted budget and
# every worker claimed reviews it could not finish. Same class as the broker's
# caps: a config error is a stop, not a permission slip.
#
# Validated up front, once, so every subcommand inherits the answer.
bad_setting=""
for budget_var in QA_GH_BUDGET_FLOOR QA_GH_BUDGET_TTL_S QA_GH_BUDGET_MAX_STALE_S; do
  case "$budget_var" in
    QA_GH_BUDGET_FLOOR) budget_val="$FLOOR" ;;
    QA_GH_BUDGET_TTL_S) budget_val="$TTL" ;;
    *) budget_val="$MAX_STALE" ;;
  esac
  case "$budget_val" in
    ''|*[!0-9]*) bad_setting="$budget_var=$budget_val" ;;
  esac
  [ -n "$bad_setting" ] && break
done
unset budget_var budget_val
if [ -n "$bad_setting" ]; then
  echo "qa-gh-budget: $bad_setting is not a nonnegative integer; refusing to guess" >&2
  echo "unknown"
  exit 2
fi

# Read a field from the cached file. Prints nothing when absent/unreadable.
cached() {
  [ -r "$BUDGET_FILE" ] || return 1
  python3 - "$BUDGET_FILE" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
v = d.get(sys.argv[2])
if v is None:
    sys.exit(1)
print(v)
PY
}

# Probe GitHub and rewrite the cache. Returns 0 on success.
refresh() {
  local out remaining reset at
  # Scoped when we know the installation, so the reading is the budget the
  # reviews spend rather than the host account's.
  if [ -n "$SCOPE" ]; then
    out="$("$QA_GH" --repo "$SCOPE" api rate_limit 2>/dev/null)" || return 1
  else
    out="$("$QA_GH" api rate_limit 2>/dev/null)" || return 1
  fi
  remaining="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(d["resources"]["core"]["remaining"]))
except Exception:
    sys.exit(1)
' 2>/dev/null)" || return 1
  reset="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(d["resources"]["core"]["reset"]))
except Exception:
    sys.exit(1)
' 2>/dev/null)" || return 1
  at="$(now)"
  mkdir -p "$(dirname "$BUDGET_FILE")" 2>/dev/null || true
  local tmp
  tmp="$(mktemp "${BUDGET_FILE}.XXXXXX" 2>/dev/null)" || return 1
  printf '{"remaining":%s,"reset":%s,"at":%s,"scope":"%s"}\n' \
    "$remaining" "$reset" "$at" "$SCOPE" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# Ensure the cache is fresh enough, then report.
check() {
  local at remaining age scope
  at="$(cached at)" || at=""
  # A reading taken under a DIFFERENT identity is not an answer to this
  # question: a host-identity `ok:5000` must never authorize an App-mode
  # review. Treat a scope mismatch as a miss and probe again.
  scope="$(cached scope)" || scope=""
  if [ -n "$at" ] && [ "$scope" != "$SCOPE" ]; then
    at=""
  fi
  if [ -z "$at" ]; then
    refresh || { echo "unknown"; return 2; }
    at="$(cached at)" || { echo "unknown"; return 2; }
  fi
  age=$(( $(now) - at ))
  if [ "$age" -ge "$TTL" ]; then
    # Stale: try to refresh, but fall back to the stale value rather than
    # declaring the budget unknown on a transient probe failure.
    refresh || true
    at="$(cached at)" || at=""
    [ -n "$at" ] || { echo "unknown"; return 2; }
    age=$(( $(now) - at ))
  fi
  # ...but only for a bounded time. See the header: an unbounded fallback turns
  # a permanently failing probe into a permanently trusted stale reading.
  if [ "$age" -ge "$MAX_STALE" ]; then
    echo "unknown"
    return 2
  fi
  remaining="$(cached remaining)" || { echo "unknown"; return 2; }
  if [ "$remaining" -lt "$FLOOR" ]; then
    echo "low:$remaining"
    return 1
  fi
  echo "ok:$remaining"
  return 0
}

case "${1:-check}" in
  check)
    check
    exit $?
    ;;
  refresh)
    refresh || { echo "unknown"; exit 2; }
    echo "ok:$(cached remaining)"
    ;;
  show)
    check >/dev/null 2>&1
    rc=$?
    remaining="$(cached remaining)" || remaining="?"
    at="$(cached at)" || at="?"
    reset="$(cached reset)" || reset="?"
    age=$(( $(now) - ${at:-0} ))
    echo "gh_rest_remaining=${remaining} floor=${FLOOR} age=${age}s reset=${reset} state=$(
      case $rc in 0) echo ok ;; 1) echo low ;; *) echo unknown ;; esac
    )"
    exit $rc
    ;;
  *)
    echo "usage: qa-gh-budget.sh [check|refresh|show]" >&2
    exit 2
    ;;
esac
