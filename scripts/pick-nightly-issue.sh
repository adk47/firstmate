#!/usr/bin/env bash
set -euo pipefail

# pick-nightly-issue.sh — deterministic issue picker for the nightly CTO
# automation on Muso-AI/hydra.
# ===========================================================================
# Two modes:
#   pick-nightly-issue.sh                       select one eligible issue
#   pick-nightly-issue.sh --take <n> [--journey-url <url>]   claim an issue
#
# Pick mode: self-heals stale `cto-working` labels, then walks OPEN issues
# labeled bug/chore (excluding cto-working/cto-blocked/wontfix), ordered by
# priority label (P0..P3, unlabeled last) then oldest createdAt first, and
# emits the first one with no OPEN linked PR as one JSON object on stdout.
#
# Exit codes: 0 picked/took | 2 usage | 3 no eligible issue (pick mode only)
#             1 gh/jq failure (fail loud — never emit a partial/empty pick).
#
# Env (mainly for tests): GH=gh override; PICK_NIGHTLY_NOW=epoch-seconds
# override for "now" (self-heal staleness check).

REPO="Muso-AI/hydra"
STALE_HOURS=24
GH="${GH:-gh}"
# Audit trail (SOUL "Write Activity Logging"): every GitHub WRITE this script
# performs (label add/remove, issue comment) appends a row here FIRST — the
# same fail-closed contract as cto-codex-coding's code-change audit. The
# nightly skill's own audit row covers the code/PR writes; this covers the
# picker's issue writes, which happen earlier in the turn.
AUDIT_DIR="${PICK_NIGHTLY_AUDIT_DIR:-$HOME/.openclaw/workspace/api-logs/cto}"

die() { echo "pick-nightly-issue: $2" >&2; exit "$1"; }

# audit_append <action> <target>: append one audit row. Returns nonzero if the
# row cannot be written — callers must NOT perform the write in that case.
audit_append() {
  local action="$1" target="$2"
  mkdir -p "$AUDIT_DIR" 2>/dev/null || return 1
  jq -nc --arg action "$action" --arg target "$target" \
    '{ts:(now|todateiso8601), agent:"cto", action:$action, target:$target,
      requester:"cron:cto-nightly",
      authorization:"standing nightly-issue-fixer authorization (Nick U0AL36NADEY)"}' \
    >> "$AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl" 2>/dev/null
}

now_epoch() {
  if [ -n "${PICK_NIGHTLY_NOW:-}" ]; then
    printf '%s\n' "$PICK_NIGHTLY_NOW"
  else
    date -u +%s
  fi
}

# ISO-8601 -> epoch: shared helper (GNU/BSD portable, nonzero if unparseable).
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/epoch.sh
source "$_SELF_DIR/lib/epoch.sh"
to_epoch() { iso_to_epoch "$1"; }

# Prints one PR state per line for issue $1's linked closing PRs.
# Returns nonzero (and prints the raw gh/jq failure to stderr) on any
# transport or parse failure — callers must NOT treat that as "no open PR".
fetch_linked_pr_states() {
  local n="$1" out
  out=$("$GH" api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){closedByPullRequestsReferences(first:10,includeClosedPrs:false){nodes{number state}}}}}' \
    -f o=Muso-AI -f r=hydra -F n="$n" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s' "$out" | jq -e '.data.repository.issue.closedByPullRequestsReferences.nodes' >/dev/null 2>&1 \
    || { echo "pick-nightly-issue: unparseable graphql response for #$n: $out" >&2; return 1; }
  printf '%s' "$out" | jq -r '.data.repository.issue.closedByPullRequestsReferences.nodes[].state'
}

# Return code convention (NOT a plain boolean — 3 outcomes matter to callers):
#   0 = has an OPEN linked PR (issue is taken)
#   1 = no OPEN linked PR (issue is free)
#   2 = the lookup itself failed (transport/parse) — callers must not guess
has_open_linked_pr() {
  local n="$1" states
  states="$(fetch_linked_pr_states "$n")" || return 2
  printf '%s\n' "$states" | grep -qx 'OPEN'
}

# Self-heal: clear `cto-working` labels that were left behind by a run that
# died before finishing (or where the linked PR closed without merging).
# Staleness proxy: the issue's `updatedAt` (a `gh issue edit --add-label` is
# itself an update, so updatedAt is a reasonable proxy for "when the label
# was applied" without a second per-issue timeline/GraphQL call). Best
# effort throughout: a self-heal failure is logged to stderr and MUST NOT
# abort the pick.
self_heal_stale_cto_working() {
  local out
  out=$("$GH" issue list --repo "$REPO" --state open --label cto-working \
    --json number,updatedAt,labels 2>&1) || {
    echo "pick-nightly-issue: self-heal: gh issue list failed: $out" >&2
    return 0
  }
  jq -e 'type=="array"' >/dev/null 2>&1 <<<"$out" || {
    echo "pick-nightly-issue: self-heal: unparseable gh issue list output: $out" >&2
    return 0
  }

  local cutoff now
  now=$(now_epoch)
  cutoff=$(( now - STALE_HOURS * 3600 ))

  local count i
  count=$(jq 'length' <<<"$out")
  i=0
  while [ "$i" -lt "$count" ]; do
    local n updated_at updated_epoch
    n=$(jq -r ".[$i].number" <<<"$out")
    updated_at=$(jq -r ".[$i].updatedAt" <<<"$out")
    i=$((i + 1))

    updated_epoch=$(to_epoch "$updated_at") || {
      echo "pick-nightly-issue: self-heal: unparseable updatedAt '$updated_at' for #$n, skipping" >&2
      continue
    }
    [ "$updated_epoch" -lt "$cutoff" ] || continue  # not stale by the proxy

    local rc=0
    has_open_linked_pr "$n" || rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "pick-nightly-issue: self-heal: graphql lookup failed for #$n, leaving label" >&2
      continue
    elif [ "$rc" -eq 0 ]; then
      continue  # still has an open linked PR — not actually stale
    fi

    if ! audit_append "issue-label-remove" "$REPO#$n"; then
      echo "pick-nightly-issue: self-heal: audit append failed for #$n, leaving label (no unaudited write)" >&2
      continue
    fi
    if "$GH" issue edit "$n" --repo "$REPO" --remove-label cto-working >/dev/null 2>&1; then
      echo "cleared stale cto-working from #$n" >&2
    else
      echo "pick-nightly-issue: self-heal: failed to remove cto-working from #$n" >&2
    fi
  done
}

cmd_pick() {
  self_heal_stale_cto_working || true

  local out
  # --limit 500: gh returns newest-first, so a tighter limit would truncate
  # exactly the OLDEST issues this picker is designed to prefer.
  out=$("$GH" issue list --repo "$REPO" --state open \
    --json number,title,labels,createdAt --limit 500 2>&1) \
    || die 1 "gh issue list failed: $out"
  jq -e 'type=="array"' >/dev/null 2>&1 <<<"$out" \
    || die 1 "unparseable gh issue list output: $out"

  local candidates
  candidates=$(jq -c '
      map(select(
        (([.labels[].name] // []) | any(. == "bug" or . == "chore"))
        and ((([.labels[].name] // []) | any(. == "cto-working" or . == "cto-blocked" or . == "wontfix")) | not)
      ))
      | map(. + {
          _prio: (
            (([.labels[].name] // []) | map(select(test("^P[0-3]$"))) | first) as $p
            | if $p == null then 4
              elif $p == "P0" then 0
              elif $p == "P1" then 1
              elif $p == "P2" then 2
              elif $p == "P3" then 3
              else 4 end
          )
        })
      | sort_by([._prio, .createdAt])
    ' <<<"$out") || die 1 "jq filter/sort of issue list failed"

  local count i
  count=$(jq 'length' <<<"$candidates")
  i=0
  while [ "$i" -lt "$count" ]; do
    local cand n
    cand=$(jq -c ".[$i]" <<<"$candidates")
    n=$(jq -r '.number' <<<"$cand")
    i=$((i + 1))

    local rc=0
    has_open_linked_pr "$n" || rc=$?
    if [ "$rc" -eq 2 ]; then
      die 1 "graphql linked-PR lookup failed for issue #$n"
    elif [ "$rc" -eq 0 ]; then
      continue  # taken by an open PR
    fi

    jq -c '{number, title, labels: [.labels[].name], createdAt}' <<<"$cand"
    return 0
  done

  echo "NO_ELIGIBLE_ISSUE" >&2
  return 3
}

cmd_take() {
  local number="$1" journey_url="$2"
  [[ "$number" =~ ^[0-9]+$ ]] || die 2 "issue number must be numeric, got '$number'"

  # Audit BEFORE any write, fail closed (SOUL Write Activity Logging).
  audit_append "issue-take" "$REPO#$number" \
    || die 1 "audit append failed — refusing to make any GitHub write for #$number"

  "$GH" issue edit "$number" --repo "$REPO" --add-label cto-working \
    || die 1 "gh issue edit --add-label cto-working failed for #$number"

  local journey="${journey_url:-posted in #cto-nightly}"
  local body="🤖 CTO nightly run is taking this issue. Journey: ${journey}"
  if ! "$GH" issue comment "$number" --repo "$REPO" --body "$body"; then
    # Roll the claim back: a labeled-but-uncommented issue would stay excluded
    # from picks until the 24h stale healer, silently parking the issue.
    # Report the rollback's REAL outcome — claiming success on a failed
    # rollback would hide a parked issue.
    if "$GH" issue edit "$number" --repo "$REPO" --remove-label cto-working >/dev/null 2>&1; then
      die 1 "gh issue comment failed for #$number — rolled back the cto-working label"
    else
      die 1 "gh issue comment failed for #$number — AND the label rollback failed; remove cto-working from #$number manually (or the 24h self-heal will)"
    fi
  fi

  echo "TOOK #$number" >&2
  return 0
}

main() {
  if [ "$#" -eq 0 ]; then
    cmd_pick
    return $?
  fi

  case "$1" in
    --take)
      shift
      [ "$#" -ge 1 ] || die 2 "usage: pick-nightly-issue.sh --take <number> [--journey-url <url>]"
      local number="$1"
      shift
      local journey_url=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --journey-url)
            shift
            [ "$#" -ge 1 ] || die 2 "--journey-url requires a value"
            journey_url="$1"
            shift
            ;;
          *)
            die 2 "unknown argument: $1"
            ;;
        esac
      done
      cmd_take "$number" "$journey_url"
      return $?
      ;;
    *)
      die 2 "unknown argument: $1"
      ;;
  esac
}

main "$@"
