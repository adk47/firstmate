#!/bin/sh
# Lane guard: the copy of the work that outlives a worker's context.
#
# A lane can die with the only copy of real work sitting uncommitted in its
# worktree, and a context-exhausted worker cannot be trusted to save it or to
# stop when told. This script is the artifact that does not live in any worker's
# context: it writes the lane's current work to a durable local store outside
# the worktree, publishes the same snapshot to a remote ref when the lane has an
# origin, and reports the lane that has been reading tokens without ever
# committing.
#
# Usage: fm-lane-guard.sh <worktree> <base-sha> <budget-minutes>
#
# <lane> is the last path component of <worktree>. The local store root is
# ${FM_LANE_GUARD_STORE:-${XDG_STATE_HOME:-$HOME/.local/state}/fm-lane-guard},
# with one directory per lane and one directory per snapshot tree sha. A
# snapshot directory holds the publishable paths at their worktree-relative
# locations plus a MANIFEST. The store is append-only: an existing snapshot
# directory is never rewritten, truncated, or deleted.
#
# Permissions, and they are the only ones this script has:
#   1. Write the snapshot to the local store first, for every lane, whether or
#      not the lane has an origin remote. A missing origin is a normal case, not
#      an error.
#   2. When the lane has an origin, also publish the snapshot: build a tree
#      through a temporary index (GIT_INDEX_FILE inside a mktemp directory)
#      seeded from HEAD. Candidates come from three read-only enumerations:
#      tracked worktree modifications and deletions, paths in the worker's real
#      index whose staged blob differs from HEAD, and untracked non-ignored
#      files. Every candidate file passes the publish policy below before it is
#      staged; tracked deletions are carried without content. Commit the tree
#      with commit-tree -p HEAD, push the commit with push -qf, and only then
#      point refs/wip/<lane> at it.
#
# The publish policy is a policy this script owns:
#   - Paths that .gitignore, .git/info/exclude, or a global excludes file
#     already excludes are never listed, and no exception is made for them.
#   - A candidate file is publishable only when its extension is one of the
#     source, test, documentation, or config extensions listed below, or when
#     it is executable and its content is text: sh bash py js jsx ts tsx go rs
#     rb java kt kts c h cc cpp hpp m swift php lua pl pm sql md rst txt json
#     yaml yml toml ini cfg conf css scss html vue svelte. Everything else
#     stays out.
#   - Content must be valid UTF-8 text; binary and non-UTF-8 files are skipped.
#   - Credential-shaped paths are never published, matched case-insensitively:
#     a path component of .ssh, .aws, .kube, .gnupg, secrets, or .secrets; a
#     basename of .env or .env.*, *.env, *.pem, *.key, *.p12, *.pfx, *.crt,
#     *.kdbx, *.token, credentials*, secrets*, .netrc, .npmrc, or .pgpass; or a
#     basename starting id_rsa, id_dsa, id_ecdsa, or id_ed25519.
#   - A single publishable file over 1 MiB, or the publishable candidates over
#     5 MiB, publishes nothing at all: the run refuses with an error naming the
#     lane and the reason, writes no snapshot, ref, or push.
#   - A lane with nothing publishable saves nothing and prints nothing on the
#     healthy path. Silence there is correct, not a failure, and a trip never
#     claims excluded work was saved or that a non-clean worktree matches HEAD.
#   3. If the snapshot tree equals HEAD's tree there is nothing to save, and if
#      it equals what refs/wip/<lane> already holds it is already on the remote,
#      so no new commit and no push happens. A tree already in the local store
#      is likewise not written again.
#   4. Record the lane's first-seen time in git config (lane.<lane>.seen). Trip
#      when commits ahead of <base-sha> are zero and <budget-minutes> have
#      elapsed since that first sighting: print the TRIP line and exit 3.
#   5. A successful save prints one SAVED line naming the local snapshot and, if
#      it was also pushed, the remote ref. The healthy path is otherwise silent.
#
# Constraints: POSIX sh with set -eu. Every git call goes through git -C "$wt".
# The script never cds, never checks out, stashes, or resets, and never writes
# the worker's real index or HEAD. It deletes nothing but its own scratch index
# directory and its own incomplete temporary snapshot, which it created. The
# only forced operation is the explicit push -qf of the wip ref.
#
# Exit: 0 healthy or saved, 1 the local snapshot or the remote push failed, 2
# refused or invalid request, 3 tripped. A push that fails never claims the
# remote ref was saved and never suppresses the trip report; the local snapshot,
# which is written first, still stands.
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
  _cred_rest=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  _cred_base=${_cred_rest##*/}
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

git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null || {
  printf 'error: %s has no commit to snapshot against\n' "$lane" >&2
  exit 2
}
base_sha=$(git -C "$wt" rev-parse --verify --quiet "$base^{commit}") || {
  printf 'error: base-sha is not a commit in %s: %s\n' "$lane" "$base" >&2
  exit 2
}

has_remote=0
if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
  has_remote=1
fi

# Permission 2: snapshot through a scratch index. GIT_INDEX_FILE is set for
# every scratch-index call, so the worker's own index is only ever read.
idx_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lane-guard.XXXXXXXX") || {
  printf 'error: could not create a scratch index directory\n' >&2
  exit 2
}
# The only things this script removes are its own scratch directory and its own
# incomplete temporary snapshot.
trap 'rm -rf "$idx_dir"' EXIT INT HUP TERM
idx_file=$idx_dir/index

GIT_INDEX_FILE=$idx_file git -C "$wt" read-tree HEAD

save_state=none
save_reason=
skip_allowlist=0
skip_credentials=0
remote_saved=0
local_dir=

git -C "$wt" diff --name-only -z HEAD | tr '\0' '\n' |
  awk '{printf "tracked\t%s\n", $0}' > "$idx_dir/tracked"
git -C "$wt" diff-index --cached --name-only -z HEAD | tr '\0' '\n' |
  awk '{printf "staged\t%s\n", $0}' > "$idx_dir/staged"
git -C "$wt" ls-files --others --exclude-standard -z | tr '\0' '\n' |
  awk '{printf "untracked\t%s\n", $0}' > "$idx_dir/untracked"
cat "$idx_dir/tracked" "$idx_dir/staged" "$idx_dir/untracked" > "$idx_dir/all"
awk -F '\t' '!seen[$2]++' "$idx_dir/all" > "$idx_dir/candidates"

publish_list=$idx_dir/publish
published=$idx_dir/published
skipped=$idx_dir/skipped
: > "$publish_list"
: > "$published"
: > "$skipped"
total=0
while IFS='	' read -r source rel; do
  [ -n "$rel" ] || continue
  file=$wt/$rel
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    if GIT_INDEX_FILE=$idx_file git -C "$wt" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      if ! GIT_INDEX_FILE=$idx_file git -C "$wt" update-index --force-remove -- "$rel"; then
        save_state=failed
        save_reason="could not stage the deletion of $rel"
        break
      fi
    fi
    continue
  fi
  if credential_path "$rel"; then
    skip_credentials=1
    printf '%s\t%s\n' "$rel" "credential-shaped path" >> "$skipped"
    continue
  fi
  if [ ! -f "$file" ]; then
    skip_allowlist=1
    printf '%s\t%s\n' "$rel" "not a regular file" >> "$skipped"
    continue
  fi
  base=${rel##*/}
  ext=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  ext=${ext##*.}
  if publishable_extension "$ext"; then
    :
  elif [ ! -x "$file" ]; then
    skip_allowlist=1
    printf '%s\t%s\n' "$rel" "outside the publish allowlist" >> "$skipped"
    continue
  fi
  # The size probe runs before the text probe so an oversized file is refused
  # without being read in full.
  size=$(wc -c < "$file" 2>/dev/null) || {
    skip_allowlist=1
    printf '%s\t%s\n' "$rel" "could not read the file size" >> "$skipped"
    continue
  }
  size=$(printf '%s' "$size" | tr -d '[:space:]')
  case $size in
    '' | *[!0-9]*)
      skip_allowlist=1
      printf '%s\t%s\n' "$rel" "unparseable file size" >> "$skipped"
      continue
      ;;
  esac
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    save_state=refused
    save_reason="file $rel is $size bytes, over the 1 MiB publish cap"
    break
  fi
  if ! is_text_file "$file"; then
    skip_allowlist=1
    printf '%s\t%s\n' "$rel" "binary or non-UTF-8 content" >> "$skipped"
    continue
  fi
  total=$((total + size))
  if [ "$total" -gt "$MAX_TOTAL_BYTES" ]; then
    save_state=refused
    save_reason="publishable files exceed the 5 MiB publish cap"
    break
  fi
  printf '%s\t%s\n' "$source" "$rel" >> "$published"
  printf '%s\n' "$rel" >> "$publish_list"
done < "$idx_dir/candidates"

if [ "$save_state" = refused ] || [ "$save_state" = failed ]; then
  printf 'error: %s: %s; publishing nothing\n' "$lane" "$save_reason" >&2
else
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -e "$wt/$rel" ] && [ ! -L "$wt/$rel" ]; then
      continue
    fi
    if ! GIT_INDEX_FILE=$idx_file git -C "$wt" add -- "$rel"; then
      save_state=failed
      save_reason="could not stage $rel for the snapshot"
      break
    fi
  done < "$publish_list"
  if [ "$save_state" = none ]; then
    if ! tree=$(GIT_INDEX_FILE=$idx_file git -C "$wt" write-tree); then
      save_state=failed
      save_reason="could not write the snapshot tree"
    fi
  fi
  if [ "$save_state" = failed ]; then
    printf 'error: %s: %s; publishing nothing\n' "$lane" "$save_reason" >&2
  fi
fi

write_local_snapshot() {
  store=${FM_LANE_GUARD_STORE:-${XDG_STATE_HOME:-$HOME/.local/state}/fm-lane-guard}
  lane_store=$store/$lane
  local_dir=$lane_store/$tree
  if [ -e "$local_dir" ]; then
    return 0
  fi
  mkdir -p "$lane_store" || return 1
  tmp_store=$lane_store/.tmp.$$
  rm -rf "$tmp_store" 2>/dev/null || true
  mkdir -p "$tmp_store" || return 1
  : > "$tmp_store/.stored"
  while IFS='	' read -r _source _rel; do
    [ -n "$_rel" ] || continue
    git -C "$wt" cat-file -e "$tree:$_rel" 2>/dev/null || continue
    _dest=$tmp_store/$_rel
    mkdir -p "${_dest%/*}" || {
      rm -rf "$tmp_store" 2>/dev/null || true
      return 1
    }
    if ! git -C "$wt" cat-file blob "$tree:$_rel" > "$_dest"; then
      rm -rf "$tmp_store" 2>/dev/null || true
      return 1
    fi
    printf '%s\t%s\n' "$_source" "$_rel" >> "$tmp_store/.stored"
  done < "$published"
  {
    printf 'lane: %s\n' "$lane"
    printf 'worktree: %s\n' "$wt"
    printf 'head: %s\n' "$(git -C "$wt" rev-parse HEAD)"
    printf 'tree: %s\n' "$tree"
    printf 'base: %s\n' "$base_sha"
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    awk -F '\t' '{printf "source %s\t%s\n", $1, $2}' "$tmp_store/.stored"
    awk -F '\t' '{printf "skipped %s\t%s\n", $1, $2}' "$skipped"
  } > "$tmp_store/MANIFEST" || {
    rm -rf "$tmp_store" 2>/dev/null || true
    return 1
  }
  rm -f "$tmp_store/.stored"
  if [ -e "$local_dir" ]; then
    rm -rf "$tmp_store" 2>/dev/null || true
  elif ! mv "$tmp_store" "$local_dir"; then
    rm -rf "$tmp_store" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Permission 1: the local artifact is written first, for every lane.
if [ "$save_state" = none ]; then
  head_tree=$(git -C "$wt" rev-parse 'HEAD^{tree}')
  if [ "$tree" != "$head_tree" ]; then
    if write_local_snapshot; then
      save_state=local
    else
      save_state=failed
      save_reason="could not write the local snapshot under $lane_store"
      printf 'error: %s: %s; publishing nothing\n' "$lane" "$save_reason" >&2
    fi
  fi
fi

# Permission 2, remote half: the same snapshot, when the lane has an origin.
if [ "$save_state" = local ]; then
  if [ "$has_remote" = 1 ]; then
    saved_tree=$(git -C "$wt" rev-parse --verify --quiet "refs/wip/$lane^{tree}" || true)
    if [ "${saved_tree:-}" = "$tree" ]; then
      remote_saved=1
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
        remote_saved=1
        save_state=saved
      else
        printf 'error: could not publish refs/wip/%s for %s\n' "$lane" "$lane" >&2
        save_reason="could not publish refs/wip/$lane"
        save_state=partial
      fi
    fi
  else
    save_state=saved
  fi
fi

if [ "$save_state" = saved ] || [ "$save_state" = partial ]; then
  if [ "$remote_saved" = 1 ]; then
    printf 'SAVED %s: local %s remote refs/wip/%s\n' "$lane" "$local_dir" "$lane"
  else
    printf 'SAVED %s: local %s\n' "$lane" "$local_dir"
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
  excluded=
  if [ "$skip_credentials" = 1 ]; then
    excluded="credential-shaped paths excluded"
  fi
  if [ "$skip_allowlist" = 1 ]; then
    if [ -n "$excluded" ]; then
      excluded="$excluded and paths outside the publish allowlist excluded"
    else
      excluded="paths outside the publish allowlist excluded"
    fi
  fi
  case $save_state in
    saved)
      if [ "$remote_saved" = 1 ]; then
        where="work saved at refs/wip/$lane and locally at $local_dir"
      else
        where="work saved locally at $local_dir"
      fi
      [ -z "$excluded" ] || where="$where ($excluded)"
      ;;
    partial) where="work saved locally at $local_dir; work NOT saved: $save_reason" ;;
    failed) where="work NOT saved: ${save_reason:-the snapshot could not be published}" ;;
    refused) where="work NOT saved: $save_reason" ;;
    *)
      if [ -n "$excluded" ]; then
        where="work NOT saved: $excluded"
      else
        where="nothing to save, the worktree matches HEAD"
      fi
      ;;
  esac
  printf 'TRIP %s: 0 commits in %sm; %s; kill and re-brief as one commit\n' \
    "$lane" "$((elapsed / 60))" "$where"
  if [ "$save_state" = failed ] || [ "$save_state" = partial ]; then
    exit 1
  fi
  exit 3
fi

if [ "$save_state" = failed ] || [ "$save_state" = partial ]; then
  exit 1
fi

if [ "$save_state" = refused ]; then
  exit 2
fi

# Permission 5: silence when there was nothing to save and no trip.
exit 0
