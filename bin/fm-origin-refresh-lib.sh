# shellcheck shell=bash
# fm-origin-refresh-lib.sh - the one bounded refresh of a home's own
# refs/remotes/origin/main, the reference the running-chair drift check compares
# HEAD against.
# Usage: . bin/fm-origin-refresh-lib.sh
#
# Fleet sync fetches project clones, not the home's own checkout, so without this
# the chair's origin/main stays frozen at the last /updatefirstmate and the drift
# check compares against a stale reference.
#
# fm_chair_origin_refresh <root> fetches only the default branch into
# refs/remotes/origin/main. It is best-effort and bounded: a root that is not a
# git checkout, a missing origin remote, and a failed or timed-out fetch all
# leave the previous ref in place and return success, so a network blip can never
# read as drift or turn into a wake.
set -u

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

fm_chair_origin_refresh() {  # <root>
  local root=${1:-}
  [ -n "$root" ] || return 0
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  fm_run_timed 10 git -C "$root" fetch --quiet --no-tags origin \
    '+refs/heads/main:refs/remotes/origin/main' >/dev/null 2>&1 || true
}
