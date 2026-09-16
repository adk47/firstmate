#!/usr/bin/env bash
# deploy-mutation-marker.sh: atomic, owner-aware claim of the deploy mutation
# marker <deploy-path>/.deploy-mutating. SOURCED by deploy.sh for local
# deploys; for remote deploys deploy.sh streams this file over ssh and runs
# it as `bash -s -- claim <marker> <token> [takeover]` on node-8, so the
# claim is atomic ON THE SERVER either way.
#
# Why (QA Critical, PR #948 round 3): the deploy lock (lib/deploy-lock.sh)
# is per source host. A laptop deploy A and the node-8 runner's scheduled
# deploy B never share it, both can pass Step 0 against the same
# .deployed-sha, and a plain `printf > marker` in B would overwrite A's
# owner token. B's failure handler would then see B's own token and run
# rollback.sh underneath A's live rsync. The marker therefore has to be
# CLAIMED like a lock: created with O_EXCL (bash noclobber), and an
# existing marker owned by someone else is a refusal, not an overwrite.
#
# Contract (self-contained: no dependency on deploy.sh's log/fail):
#   claim_mutation_marker <marker-path> <token> [takeover]
#     -> 0 claimed (file created with <token>), or already ours (same token)
#     -> 0 with takeover=<owner-token>: compare-and-swapped that dead owner's
#          marker for ours under a per-marker mkdir lock (single-winner)
#     -> 1 could not create the marker for a non-EEXIST reason (ENOSPC, EROFS,
#          missing parent dir, ...)
#     -> 2 another owner holds the marker (its token on stderr); REFUSED
#     -> 3 usage (missing marker path or token)
#     -> 4 the marker exists but cannot be read: owner unknown; REFUSED
#   Tokens are single-line, whitespace-free strings (the callers mint
#   gha-<run_id>-<attempt> or manual-<host>-<pid>-<ts>).
#   Unit-tested, including a real concurrent-claim race:
#   scripts/tests/deploy-mutation-marker.bats.

claim_mutation_marker() {
  local marker="${1:-}" token="${2:-}" takeover="${3:-}"
  if [ -z "$marker" ] || [ -z "$token" ]; then
    echo "claim_mutation_marker: usage: claim_mutation_marker <marker-path> <token> [takeover]" >&2
    return 3
  fi
  # Atomic create-if-absent. noclobber makes the redirection O_EXCL, and the
  # subshell scopes the option so the caller's shell is untouched. The
  # failing status is captured with `|| rc=$?` so `set -e` in a caller cannot
  # abort before the ownership check below (same trap as deploy-lock.sh).
  local rc=0
  ( set -o noclobber; printf '%s\n' "$token" > "$marker" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "claim_mutation_marker: claimed $marker for $token" >&2
    return 0
  fi
  if [ ! -e "$marker" ]; then
    echo "claim_mutation_marker: could not create $marker (not an existing-marker collision; check the directory, permissions and free space)" >&2
    return 1
  fi
  local owner read_rc=0
  # pipefail is scoped to the substitution's subshell so a failing head is
  # visible without changing the caller's shell options.
  owner="$( set -o pipefail; head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]' )" || read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    echo "claim_mutation_marker: $marker exists but cannot be read (rc=$read_rc); owner unknown, refusing to claim. Inspect it by hand." >&2
    return 4
  fi
  if [ "$owner" = "$token" ]; then
    echo "claim_mutation_marker: $marker already owned by this run ($token)" >&2
    return 0
  fi
  if [ -n "$takeover" ]; then
    # Takeover is a COMPARE-AND-SWAP on the owner the operator observed:
    # the takeover value must be the dead owner's token (not a bare 1), a
    # per-marker mkdir lock serialises concurrent takeovers, and the owner
    # is re-read under the lock. A taker whose expected owner no longer
    # matches (because another takeover already won) is refused. This is
    # what makes takeover single-winner: without the expected owner a late
    # taker would replace the WINNER's live marker (QA Important, PR #948
    # round 5, and my own remove-then-create attempt failed the same test).
    if [ "$takeover" = "1" ]; then
      echo "claim_mutation_marker: takeover needs the dead owner's token, not 1: set HYDRA_TAKEOVER_MUTATION_MARKER='${owner:-<owner>}' (the owner printed above) and rerun" >&2
      return 2
    fi
    if [ "$takeover" != "$owner" ]; then
      echo "claim_mutation_marker: takeover expected owner '$takeover' but $marker is owned by '${owner:-<empty>}'; refusing (another takeover may have won, or the owner changed)" >&2
      return 2
    fi
    local lockdir="$marker.takeover.d"
    if ! mkdir "$lockdir" 2>/dev/null; then
      echo "claim_mutation_marker: takeover of $marker LOST (another takeover holds $lockdir; if it is a crash leftover, rmdir it by hand)" >&2
      return 2
    fi
    local cur
    cur="$( set -o pipefail; head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]' )" || cur=""
    if [ "$cur" != "$takeover" ]; then
      rmdir "$lockdir" 2>/dev/null || true
      echo "claim_mutation_marker: takeover of $marker LOST to '${cur:-<unknown>}' (owner changed before the lock); refusing to claim for $token" >&2
      return 2
    fi
    # Replace by RENAME, never remove-then-create: an rm would open a window
    # in which a concurrent NORMAL claim sees no marker and wins it (the
    # takeover race test caught exactly that as a flake). rename(2) is
    # atomic on the same filesystem, so the marker is never absent.
    local tmp="$lockdir/new"
    rc=0
    { printf '%s\n' "$token" > "$tmp" && mv -f "$tmp" "$marker"; } 2>/dev/null || rc=$?
    rm -f "$tmp" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
      echo "claim_mutation_marker: takeover of $marker could not replace the marker (rc=$rc)" >&2
      return 1
    fi
    echo "claim_mutation_marker: TAKEOVER of $marker from '$takeover' by $token (HYDRA_TAKEOVER_MUTATION_MARKER); only valid when that deploy is known dead" >&2
    return 0
  fi
  echo "claim_mutation_marker: $marker is held by another deploy ('${owner:-<empty>}'), refusing to claim for $token. If that deploy is dead, remove the marker on the server or rerun with HYDRA_TAKEOVER_MUTATION_MARKER=1." >&2
  return 2
}

# clear_mutation_marker <marker-path>
#   -> 0 the marker is absent afterwards (removed, or was never there)
#   -> 1 it is still present after one retry: the caller must surface this,
#        because a leftover marker makes every later deploy refuse to claim
#        it (QA Important, PR #948 round 4: a cleanup failure swallowed with
#        `|| true` after the success notification wedged daily deploys).
#   -> 3 usage
clear_mutation_marker() {
  local marker="${1:-}" attempt
  if [ -z "$marker" ]; then
    echo "clear_mutation_marker: usage: clear_mutation_marker <marker-path>" >&2
    return 3
  fi
  for attempt in 1 2; do
    rm -f "$marker" 2>/dev/null || true
    if [ ! -e "$marker" ]; then
      echo "clear_mutation_marker: $marker cleared" >&2
      return 0
    fi
    [ "$attempt" -eq 1 ] && sleep 1
  done
  echo "clear_mutation_marker: $marker STILL PRESENT after 2 attempts; every later deploy will refuse to claim it until it is removed by hand" >&2
  return 1
}

# Executable entry point for the ssh path: `bash -s -- claim <marker> <token> [takeover]`
# or `bash -s -- clear <marker>`. The takeover argument is the OBSERVED dead
# owner's token (HYDRA_TAKEOVER_MUTATION_MARKER=<token>), never a bare 1.
# When sourced (BASH_SOURCE[0] names this file and differs from $0), nothing runs.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    claim) shift; claim_mutation_marker "$@"; exit $? ;;
    clear) shift; clear_mutation_marker "$@"; exit $? ;;
    *) echo "usage: deploy-mutation-marker.sh claim <marker-path> <token> [takeover] | clear <marker-path>" >&2; exit 3 ;;
  esac
fi
