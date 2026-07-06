#!/usr/bin/env bash
# cto-push-audit-guard.sh — git pre-push hook for the CTO agent's repo clones.
#
# Refuses a push unless BOTH CTO rails a git hook can enforce hold:
#   1. a recent CTO audit row exists for the target repo (SOUL "Write Activity
#      Logging" — the row `cto-codex-coding` writes BEFORE any git write); and
#   2. the pushed branch is a `cto/<slug>` branch, never a default branch
#      (main/master/develop) and never a `fix/…`/other branch.
# Together these enforce, at the git boundary, the rails that doctrine alone
# cannot: a push that skipped the audit step OR uses the wrong branch — e.g.
# because the agent entered the standalone `fix`/`ship` skill instead of
# `cto-codex-coding` — is blocked here, regardless of which skill initiated it.
# (The QA-handoff rail is a Slack action a git hook can't perform, so it stays
# doctrine; its failure mode is a stalled PR, not an unsafe merge.)
# (`fix` and `ship` are globally auto-discovered and their triggers overlap CTO
# code work; openclaw has no per-agent skill exclude, so this hook is the
# mechanical backstop behind the prose guard.)
#
# Installed into <clone>/.git/hooks/pre-push by cto-codex-coding's clone setup.
# It is scoped to CTO's own clones under /opt/hydra/workspaces/repos/, so it
# never affects any other agent or a human's checkout.
#
# git invokes a pre-push hook as: hook <remote-name> <remote-url>, with the refs
# being pushed on stdin. We only need the remote URL (to resolve the repo); stdin
# is ignored.
#
# Fail-closed by design: an unverifiable environment blocks the push — a god-mode
# push with no checkable audit trail must not proceed — with an actionable
# message naming exactly what to do.
#
# Knobs (env):
#   CTO_AUDIT_DIR                audit-log dir (default ~/.openclaw/workspace/api-logs/cto)
#   CTO_PUSH_GUARD_WINDOW_HOURS  recency window in hours (default 6)
#   CTO_PUSH_GUARD_NOW           fixed "now" epoch seconds (tests only; default real now)

set -uo pipefail

guard_dir="${CTO_AUDIT_DIR:-$HOME/.openclaw/workspace/api-logs/cto}"
window_hours="${CTO_PUSH_GUARD_WINDOW_HOURS:-6}"
remote_url="${2:-$(git remote get-url origin 2>/dev/null || true)}"

block() {
  {
    echo "🚫 cto-push-audit-guard: $1"
    echo "   Every CTO push must be preceded by the audit row that the \`cto-codex-coding\`"
    echo "   skill writes (SOUL \"Write Activity Logging\") BEFORE any git write. If you"
    echo "   reached a push via the standalone \`fix\`/\`ship\` skill, STOP and route the"
    echo "   change through \`cto-codex-coding\` (audit row + push-access check first),"
    echo "   then retry the push."
  } >&2
  exit 1
}

# --- Branch-shape rails (from the pushed refs on stdin) ---
# CTO code pushes always target a fresh `cto/<slug>-<ts>` branch — never a default
# branch, never a `fix/…` (or any other) branch. Enforcing that here means a stray
# `fix`/`ship` push is rejected even if it first wrote an audit row. git feeds the
# hook one "<local-ref> <local-oid> <remote-ref> <remote-oid>" line per pushed ref.
while read -r _ _ remote_ref _; do
  case "$remote_ref" in
    refs/heads/*) branch="${remote_ref#refs/heads/}" ;;
    *) continue ;;   # tags/notes/etc — CTO doesn't push these
  esac
  case "$branch" in
    main|master|develop)
      block "refusing push to default branch '$branch' — CTO never pushes a default branch" ;;
    cto/*) : ;;
    *)
      block "refusing push to '$branch' — CTO code pushes use a cto/<slug> branch; a non-cto/ branch means the cto-codex-coding rails (audit row, cto/ branch, QA handoff) were skipped" ;;
  esac
done

command -v jq >/dev/null 2>&1 || block "jq not found — cannot verify the audit trail"

# Resolve the target as owner/repo from the remote URL (https or ssh form),
# matching the `target` field cto-codex-coding writes (e.g. "Muso-AI/core-backend").
repo="$(printf '%s' "$remote_url" | sed -E 's#\.git/?$##; s#^.*[/:]([^/:]+/[^/]+)$#\1#')"
[ -n "$repo" ] && [ "$repo" != "$remote_url" ] \
  || block "could not resolve the target repo from origin (${remote_url:-<none>})"

# Portable ISO8601 -> epoch (GNU date first, then BSD/macOS date).
ts_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

now="${CTO_PUSH_GUARD_NOW:-$(date -u +%s)}"
cutoff=$(( now - window_hours * 3600 ))

# UTC date string for an epoch (GNU date first, then BSD/macOS date).
epoch_to_date() {
  date -u -d "@$1" +%Y-%m-%d 2>/dev/null || date -u -r "$1" +%Y-%m-%d 2>/dev/null
}
today="$(epoch_to_date "$now")"
yesterday="$(epoch_to_date "$(( now - 86400 ))")"

# A push is authorized iff some audit row for THIS repo, in today's or
# yesterday's log (yesterday covers a push that crosses UTC midnight), has a
# timestamp within the recency window.
found=0
for d in "$today" "$yesterday"; do
  [ -n "$d" ] || continue
  f="$guard_dir/$d.jsonl"
  [ -f "$f" ] || continue
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    e="$(ts_to_epoch "$ts")"
    [ -n "$e" ] || continue
    if [ "$e" -ge "$cutoff" ]; then found=1; break; fi
  done < <(jq -r --arg repo "$repo" 'select(.target == $repo) | .ts' "$f" 2>/dev/null)
  [ "$found" = 1 ] && break
done

[ "$found" = 1 ] || block "no CTO audit row for $repo in the last ${window_hours}h"
exit 0
