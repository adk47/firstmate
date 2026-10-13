#!/bin/bash
# ──────────────────────────────────────────────────────────────
# qa-review-clone.sh — cheap, self-deleting checkout of a PR for QA test runs
#
# Usage: qa-review-clone.sh <owner/repo> <pr-number> -- <command> [args...]
#
# Runs <command> with cwd = a checkout of the PR head, then deletes the
# checkout whatever happened (success, failure, SIGTERM/INT/HUP via trap).
# Exit code is the command's. SIGKILL cannot be trapped; the sweeper's qa-tmp
# lane (sweep-workspace-clones.sh, 2d TTL) is the backstop for that.
#
# Why: every review used to leave a 1.4-2.1G full clone in workspaces/qa/tmp
# that nothing removed (MUS-5557). Now the objects live ONCE in a shared bare
# mirror per repo and each review is `git clone --reference <mirror>`: the
# per-review cost is the working tree + refs. If the mirror cannot be created
# or refreshed, fall back to a blobless shallow clone via `qa-gh.sh pr checkout`.
#
# The command runs in its own process group (set -m), and SIGTERM/INT/HUP kill
# the whole group, so a timed-out `pnpm test` leaves no workers behind.
# Mirrors are keyed by owner__name so two owners' same-named repos never share.
#
# The mirror is NEVER removed here: reviews depend on its objects via
# alternates. It lives in workspaces/qa/tmp-mirrors (matches deploy.sh's
# `workspaces/*/*tmp*` rsync exclude; not a sweep lane).
#
# Env (defaults target node-8; tests override):
#   QA_REVIEW_TMP_ROOT     default /opt/hydra/workspaces/qa/tmp
#   QA_REVIEW_MIRROR_ROOT  default /opt/hydra/workspaces/qa/tmp-mirrors
#   QA_GH_SH               default <this dir>/qa-gh.sh
# ──────────────────────────────────────────────────────────────
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="${QA_REVIEW_TMP_ROOT:-/opt/hydra/workspaces/qa/tmp}"
MIRROR_ROOT="${QA_REVIEW_MIRROR_ROOT:-/opt/hydra/workspaces/qa/tmp-mirrors}"
QA_GH_SH="${QA_GH_SH:-$_here/qa-gh.sh}"

die() { echo "qa-review-clone: $2" >&2; exit "$1"; }

[ "$#" -ge 4 ] || die 2 "usage: qa-review-clone.sh <owner/repo> <pr> -- <command> [args...]"
repo="$1"; pr="$2"; shift 2
[ "$1" = "--" ] || die 2 "usage: qa-review-clone.sh <owner/repo> <pr> -- <command> [args...]"
shift
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be owner/name, got '$repo'"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr must be a number, got '$pr'"
name="${repo#*/}"
key="${repo/\//__}"

mkdir -p "$TMP_ROOT" || die 1 "cannot create $TMP_ROOT"
CLONE_DIR="$(mktemp -d "$TMP_ROOT/$name-$pr-review-XXXXXX")" || die 1 "mktemp failed under $TMP_ROOT"
child=""

# Only ever delete a directory we made, by the shape the sweeper also trusts.
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  case "$CLONE_DIR" in
    "$TMP_ROOT"/*-[0-9]*-review-??????) rm -rf "$CLONE_DIR" ;;
  esac
}
# shellcheck disable=SC2329  # invoked via trap
terminate() { # <exit code>
  [ -n "$child" ] && kill -TERM -- "-$child" 2>/dev/null && wait "$child" 2>/dev/null
  exit "$1"
}
trap cleanup EXIT
trap 'terminate 143' TERM
trap 'terminate 130' INT
trap 'terminate 129' HUP

WORK="$CLONE_DIR/repo"
MIRROR="$MIRROR_ROOT/$key.git"

mirror_clone() {
  mkdir -p "$MIRROR_ROOT" || return 1
  (
    if command -v flock >/dev/null 2>&1; then
      flock 9 || exit 1
    else
      echo "qa-review-clone: flock missing — mirror refresh is unlocked" >&2
    fi
    if [ ! -d "$MIRROR" ]; then
      part="$MIRROR.part.$$"
      rm -rf "$part"
      "$QA_GH_SH" --repo "$repo" repo clone "$repo" "$part" -- --bare --quiet || { rm -rf "$part"; exit 1; }
      mv "$part" "$MIRROR" || exit 1
    fi
    git -C "$MIRROR" fetch --quiet origin \
      '+refs/heads/*:refs/heads/*' "+refs/pull/$pr/head:refs/pull/$pr/head"
  ) 9>"$MIRROR_ROOT/$key.lock" || return 1
  [ -d "$MIRROR" ] || return 1
  git clone --quiet --no-local --reference "$MIRROR" --no-checkout "$MIRROR" "$WORK" || return 1
  git -C "$WORK" fetch --quiet origin "refs/pull/$pr/head" || return 1
  git -C "$WORK" checkout --quiet --detach FETCH_HEAD || return 1
  # Point origin back at the real remote so the PR's own tooling sees it.
  real="$(git -C "$MIRROR" remote get-url origin 2>/dev/null)" && git -C "$WORK" remote set-url origin "$real"
  return 0
}

fallback_clone() {
  rm -rf "$WORK"
  "$QA_GH_SH" --repo "$repo" repo clone "$repo" "$WORK" -- --filter=blob:none --depth=50 --quiet || return 1
  (cd "$WORK" && "$QA_GH_SH" --repo "$repo" pr checkout "$pr")
}

if ! mirror_clone; then
  echo "qa-review-clone: mirror path failed — falling back to blobless shallow clone" >&2
  fallback_clone || die 1 "could not check out $repo#$pr"
fi

cd "$WORK" || die 1 "cannot enter $WORK"
export QA_REVIEW_CLONE_DIR="$CLONE_DIR"
set -m  # own process group for the command, so terminate() can signal all of it
"$@" &
child=$!
wait "$child"
rc=$?
child=""
exit "$rc"
