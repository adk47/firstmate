#!/bin/sh
# Lane guard: the copy of the work that outlives a worker's context.
#
# A lane can die with the only copy of real work sitting uncommitted in its
# worktree, and a context-exhausted worker cannot be trusted to save it or to
# stop when told. This script is the artifact that does not live in any worker's
# context: it publishes the lane's current work to a remote ref, and it reports
# the lane that has been reading tokens without ever committing.
#
# Usage: fm-lane-guard.sh <worktree> <base-sha> <budget-minutes>
#
# <lane> is the last path component of <worktree>.
#
# Permissions, and they are the only ones this script has:
#   1. No origin remote: print "REFUSE <lane>: no remote" and exit 2.
#   2. Snapshot the lane's uncommitted work, untracked files included, without
#      touching the worker's branch, index, or HEAD: build a tree through a
#      temporary index (GIT_INDEX_FILE inside a mktemp directory) seeded from
#      HEAD, carry tracked modifications and deletions, add the untracked files
#      the publish allowlist below admits, commit the tree with commit-tree
#      -p HEAD, push the commit with push -qf, and only then point
#      refs/wip/<lane> at it.
#
# The publish allowlist is a policy this script owns:
#   - Paths that .gitignore, .git/info/exclude, or a global excludes file
#     already excludes are never added, and no exception is made for them.
#   - An untracked file is publishable only when its extension is one of the
#     source, test, documentation, or config extensions listed below, or when
#     it is executable and its content is text: sh bash py js jsx ts tsx go rs
#     rb java kt kts c h cc cpp hpp m swift php lua pl pm sql md rst txt json
#     yaml yml toml ini cfg conf css scss html vue svelte. Everything else
#     untracked stays out.
#   - Content must be valid UTF-8 text; binary and non-UTF-8 files are skipped.
#   - Credential-shaped paths are never published: a path component of .ssh,
#     .aws, .kube, .gnupg, secrets, or .secrets; a basename of .env or .env.*,
#     *.env, *.pem, *.key, *.p12, *.pfx, *.crt, *.kdbx, *.token, credentials*,
#     secrets*, .netrc, .npmrc, or .pgpass; or a basename starting id_rsa,
#     id_dsa, id_ecdsa, or id_ed25519.
#   - A single publishable untracked file over 1 MiB, or the publishable
#     untracked set over 5 MiB, publishes nothing at all: the run refuses with
#     an error naming the lane and the reason, writes no ref, and pushes
#     nothing.
#   - A lane with nothing publishable publishes nothing and prints nothing on
#     the healthy path. Silence there is correct, not a failure.
#   3. If the snapshot tree equals HEAD's tree there is nothing to save, and if
#      it equals what refs/wip/<lane> already holds it is already saved, so no
#      new commit and no push happens.
#   4. Record the lane's first-seen time in git config (lane.<lane>.seen). Trip
#      when commits ahead of <base-sha> are zero and <budget-minutes> have
#      elapsed since that first sighting: print the TRIP line and exit 3.
#   5. Otherwise exit 0 and print nothing at all. Silence is the healthy path.
#
# Constraints: POSIX sh with set -eu. Every git call goes through git -C "$wt".
# The script never cds, never checks out, stashes, or resets, and never writes
# the worker's real index or HEAD. It deletes nothing but its own scratch index
# directory, which it created. The only forced operation is the explicit
# push -qf of the wip ref.
#
# Exit: 0 healthy, 1 a snapshot could not be published, 2 refused or invalid
# request, 3 tripped. A push that fails is a real error and surfaces as its own
# nonzero status rather than a false claim that the work is saved; the trip
# report is still printed when both happen.
set -eu

usage() {
  printf 'usage: fm-lane-guard.sh <worktree> <base-sha> <budget-minutes>\n' >&2
}

MAX_FILE_BYTES=1048576
MAX_TOTAL_BYTES=5242880

is_text_file() {
  python3 -c 'import sys
try:
    text = open(sys.argv[1], "rb").read().decode("utf-8")
except (OSError, UnicodeDecodeError):
    sys.exit(1)
sys.exit(1 if "\0" in text else 0)' "$1"
}

credential_path() {
  _cred_rest=$1
  _cred_base=${1##*/}
  while :; do
    _cred_comp=${_cred_rest%%/*}
    case $_cred_comp in
      .ssh | .aws | .kube | .gnupg | secrets | .secrets) return 0 ;;
    esac
    [ "$_cred_comp" = "$_cred_rest" ] && break
    _cred_rest=${_cred_rest#*/}
  done
  case $_cred_base in
    .env | .env.* | *.env | *.pem | *.key | *.p12 | *.pfx | *.crt | *.kdbx | *.token | .netrc | .npmrc | .pgpass)
      return 0
      ;;
    id_rsa* | id_dsa* | id_ecdsa* | id_ed25519* | credentials* | secrets*) return 0 ;;
  esac
  return 1
}

publishable_extension() {
  case $1 in
    sh | bash | py | js | jsx | ts | tsx | go | rs | rb | java | kt | kts | c | h | cc | cpp | hpp | m | swift | php | lua | pl | pm | sql | md | rst | txt | json | yaml | yml | toml | ini | cfg | conf | css | scss | html | vue | svelte)
      return 0
      ;;
  esac
  return 1
}

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi

wt=$1
base=$2
budget=$3

case $budget in
  '' | *[!0-9]* | 0?*)
    printf 'error: budget-minutes must be a decimal integer with no leading zeros\n' >&2
    exit 2
    ;;
esac
if [ -z "$base" ]; then
  printf 'error: base-sha is required\n' >&2
  exit 2
fi

top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || {
  printf 'error: not a git worktree: %s\n' "$wt" >&2
  exit 2
}
wt=$top
lane=${wt##*/}

# Permission 1: a lane with no remote has nowhere to save work, so say so
# instead of producing a snapshot no one else can see.
if ! git -C "$wt" remote get-url origin >/dev/null 2>&1; then
  printf 'REFUSE %s: no remote\n' "$lane"
  exit 2
fi

git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null || {
  printf 'error: %s has no commit to snapshot against\n' "$lane" >&2
  exit 2
}
base_sha=$(git -C "$wt" rev-parse --verify --quiet "$base^{commit}") || {
  printf 'error: base-sha is not a commit in %s: %s\n' "$lane" "$base" >&2
  exit 2
}

# Permission 2: snapshot through a scratch index. GIT_INDEX_FILE is set for both
# calls, so the worker's own index file is never opened, let alone rewritten.
idx_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lane-guard.XXXXXXXX") || {
  printf 'error: could not create a scratch index directory\n' >&2
  exit 2
}
# The only thing this script removes is its own scratch directory.
trap 'rm -rf "$idx_dir"' EXIT INT HUP TERM
idx_file=$idx_dir/index

GIT_INDEX_FILE=$idx_file git -C "$wt" read-tree HEAD
GIT_INDEX_FILE=$idx_file git -C "$wt" add -u

save_state=none
save_reason=
publish_list=$idx_dir/publish
: > "$publish_list"
git -C "$wt" ls-files --others --exclude-standard -z > "$idx_dir/others.z"
tr '\0' '\n' < "$idx_dir/others.z" > "$idx_dir/others.txt"
untracked_total=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if credential_path "$rel"; then
    continue
  fi
  file=$wt/$rel
  [ -f "$file" ] || continue
  base=${rel##*/}
  ext=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  ext=${ext##*.}
  if publishable_extension "$ext"; then
    :
  elif [ ! -x "$file" ]; then
    continue
  fi
  size=$(wc -c < "$file")
  size=$(printf '%s' "$size" | tr -d '[:space:]')
  case $size in
    '' | *[!0-9]*) continue ;;
  esac
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    save_state=refused
    save_reason="untracked file $rel is $size bytes, over the 1 MiB publish cap"
    break
  fi
  is_text_file "$file" || continue
  untracked_total=$((untracked_total + size))
  if [ "$untracked_total" -gt "$MAX_TOTAL_BYTES" ]; then
    save_state=refused
    save_reason="publishable untracked files exceed the 5 MiB publish cap"
    break
  fi
  printf '%s\n' "$rel" >> "$publish_list"
done < "$idx_dir/others.txt"

if [ "$save_state" = refused ]; then
  printf 'error: %s: %s; publishing nothing\n' "$lane" "$save_reason" >&2
else
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    GIT_INDEX_FILE=$idx_file git -C "$wt" add -- "$rel"
  done < "$publish_list"
  tree=$(GIT_INDEX_FILE=$idx_file git -C "$wt" write-tree)
fi

# Permission 3: an unchanged tree is not a snapshot, and a tree already held by
# refs/wip/<lane> is already saved. Refusing to rebuild the same tree keeps a
# dirty-but-idle lane from forcing an identical ref update on every run.
if [ "$save_state" = none ]; then
  head_tree=$(git -C "$wt" rev-parse 'HEAD^{tree}')
  if [ "$tree" != "$head_tree" ]; then
    saved_tree=$(git -C "$wt" rev-parse --verify --quiet "refs/wip/$lane^{tree}" || true)
    if [ "${saved_tree:-}" = "$tree" ]; then
      save_state=saved
    else
      commit=$(printf 'lane-guard: wip snapshot of %s\n' "$lane" |
        git -C "$wt" \
          -c user.name='fm-lane-guard' \
          -c user.email='fm-lane-guard@localhost' \
          commit-tree "$tree" -p HEAD)
      # The one forced operation: this ref is a rolling snapshot, never a
      # fast-forwardable history, so a diverged remote copy is replaced by design.
      # The local ref only moves once the remote actually has the commit, so a
      # failed push is retried instead of being mistaken for saved work.
      if git -C "$wt" push -qf origin "$commit:refs/wip/$lane"; then
        git -C "$wt" update-ref "refs/wip/$lane" "$commit"
        save_state=saved
      else
        printf 'error: could not publish refs/wip/%s for %s\n' "$lane" "$lane" >&2
        save_state=failed
      fi
    fi
  fi
fi

# Permission 4: first sighting, then the zero-commit budget.
now=$(date -u +%s)
seen=$(git -C "$wt" config --get "lane.$lane.seen" 2>/dev/null || true)
case ${seen:-} in
  '' | *[!0-9]*)
    git -C "$wt" config "lane.$lane.seen" "$now"
    seen=$now
    ;;
esac

ahead=$(git -C "$wt" rev-list --count "$base_sha..HEAD")
elapsed=$((now - seen))
# A clock that moved backwards must not turn into a trip.
if [ "$elapsed" -lt 0 ]; then
  elapsed=0
fi

if [ "$ahead" -eq 0 ] && [ "$elapsed" -ge $((budget * 60)) ]; then
  case $save_state in
    saved) where="work saved at refs/wip/$lane" ;;
    failed) where="work NOT saved: push of refs/wip/$lane failed" ;;
    refused) where="work NOT saved: $save_reason" ;;
    *) where="nothing to save, the worktree matches HEAD" ;;
  esac
  printf 'TRIP %s: 0 commits in %sm; %s; kill and re-brief as one commit\n' \
    "$lane" "$((elapsed / 60))" "$where"
  if [ "$save_state" = failed ]; then
    exit 1
  fi
  exit 3
fi

if [ "$save_state" = failed ]; then
  exit 1
fi

if [ "$save_state" = refused ]; then
  exit 2
fi

# Permission 5: silence.
exit 0
