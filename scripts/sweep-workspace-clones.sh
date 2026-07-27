#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Stale agent-clone sweeper (node-8)
#
# Agents (CTO, DevOps, coordinator, …) clone repos for triage/PR
# work into /opt/hydra/workspaces/repos/ and workspaces/*/tmp/,
# and nothing ever cleans them: both paths are RSYNC_EXCLUDES in
# deploy.sh, so deploys never touch them. Survey 2026-07-23: 90
# clones / 26GB under repos/, 296 dirs / ~9GB under */tmp — many
# frozen at revisions from before merged fixes (they were the
# false-positive wall in the PR #737 deploy verification).
#
# Policy — delete a candidate ONLY if ALL hold:
#   • past TTL: repos/ 14d, */tmp + */.tmp 7d, where age = newest
#     mtime of anything in the tree EXCLUDING .git/ (git probes and
#     fetches bump .git internals; only worktree writes mean "in use")
#   • not on the keep-list (exact basename match, repos/ lane only)
#   • git-clean AND fully pushed: status --porcelain empty,
#     `git log --all --not --remotes` empty (--all covers detached
#     HEAD, tags, and the newest stash), `git stash list` empty,
#     every local branch has a same-named remote ref, and every
#     local tag exists on origin (ls-remote; ref NAMES and annotated
#     tag objects are data too, not just commits)
#
# Everything else lands in a fail-closed HELD lane (reported, never
# deleted): dirty/unpushed/stashed, git-probe-failed (a git error is
# never treated as "clean" — includes any future safe.directory
# refusal; today all clones are root-owned and we run as root),
# .git-is-a-file (linked worktree/submodule), nested inner repo,
# no-remote scratch repos, mountpoint-under-candidate.
# A TTL-expired dir with NO .git at all is plain junk: deleted by
# mtime alone (covers rsync'd non-git trees and half-deleted wrecks).
#
# Probes run with GIT_OPTIONAL_LOCKS=0 so `git status` never writes
# .git/index. Pre-rm recheck refuses in-progress operations
# (index.lock / MERGE_HEAD / rebase-*) and any write inside the
# fresh-window. rm is contained: symlink candidates are unlinked
# (never followed), a candidate whose path type or stat identity
# (device|inode|mtime|ctime|size, ns resolution) changed since it was
# classified is refused (no silent upgrade to a recursive delete, and no
# deleting a replacement object the guards never saw — ctime defeats inode
# reuse). Removal is quarantine-first: once the cheap staleness gates pass,
# the candidate is atomically renamed into an exclusive mktemp -d sibling,
# and size, policy audit and rm ALL run on that private name — so the object
# deleted is provably the object audited. The clone policy audit exists in
# exactly ONE place (clone_policy_audit) and runs ONCE, last, immediately
# before the rm; an earlier audit-then-weaker-re-audit shape let the two
# copies drift. A refusal restores the object to its original name (mv -n,
# never clobbering) or reports it left quarantined. Mountpoints are skipped
# (including a swept ROOT that is itself a mount), --one-file-system. The two
# swept roots must be the exact production paths unless the host guard is
# waived.
#
# Invoked weekly with --apply by scripts/weekly-cleanup.sh
# (hydra-weekly-cleanup.timer, Mon 04:30 UTC); also human-runnable.
# Posts a Block Kit summary to #clio_devops on apply runs.
#
# Exit contract (mirrors weekly-cleanup.sh):
#   0  normal run — per-entry rm errors are counted + reported
#   1  structural refusal (root missing/symlinked/suspicious)
#   2  usage error / missing dependency
#
# Flags:
#   --apply     actually delete (default is a full dry-run walk)
#   --dry-run   explicit no-op mode (the default)
#
# Env knobs (mainly for tests — defaults target production):
#   SWEEP_REPOS_ROOT        default /opt/hydra/workspaces/repos
#   SWEEP_WS_ROOT           default /opt/hydra/workspaces
#   SWEEP_REPOS_TTL_DAYS    default 14
#   SWEEP_TMP_TTL_DAYS      default 7
#   SWEEP_KEEP_LIST         space-separated basenames under repos/;
#                           REPLACES the default list when set
#   SWEEP_FRESH_WINDOW_SECS default 3600 (pre-rm recheck window)
#   SWEEP_LOCKFILE          single-run lock (apply mode)
#   SWEEP_SLACK_CHANNEL     default C0ADV2W76G4 (#clio_devops)
#   SWEEP_SKIP_HOST_GUARD   1 = skip the ovh-node-8 guard AND the fixed
#                           production-topology check on the two roots (tests)
#   SWEEP_MOUNTS_FILE       mount table to consult (default /proc/self/mounts)
#   SWEEP_PROC_DIR          proc tree for the live-handle scan (default /proc)
#                           — dependency injection for tests, NOT a bypass:
#                           a missing/unreadable tree still fails closed
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[sweep-clones $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
REPOS_ROOT="${SWEEP_REPOS_ROOT:-/opt/hydra/workspaces/repos}"
WS_ROOT="${SWEEP_WS_ROOT:-/opt/hydra/workspaces}"
REPOS_TTL_DAYS="${SWEEP_REPOS_TTL_DAYS:-14}"
TMP_TTL_DAYS="${SWEEP_TMP_TTL_DAYS:-7}"
FRESH_WINDOW_SECS="${SWEEP_FRESH_WINDOW_SECS:-3600}"
LOCKFILE="${SWEEP_LOCKFILE:-/var/run/hydra-sweep-clones.lock}"
SKIP_HOST_GUARD="${SWEEP_SKIP_HOST_GUARD:-0}"
APPLY=0

# Canonical long-lived working clones agents reuse across tasks
# (cto-codex-coding, cto-nightly-issue-fixer, devops SOUL).
if [ -n "${SWEEP_KEEP_LIST:-}" ]; then
  read -r -a KEEP_LIST <<< "$SWEEP_KEEP_LIST"
else
  KEEP_LIST=(
    hydra core-backend H-DevOps muso-cli web-credits
    industry-data-processing platform-data-processing
    analytics-worker hydra-nightly tests-web-e2e
  )
fi

export SLACK_CHANNEL="${SWEEP_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Garbage TTLs must fail loud, not silently sweep nothing (or everything):
# bash arithmetic treats a non-numeric var as 0 → cutoff = now → no-op.
for ttl_var in REPOS_TTL_DAYS TMP_TTL_DAYS FRESH_WINDOW_SECS; do
  case "${!ttl_var}" in
    ''|*[!0-9]*) echo "invalid $ttl_var='${!ttl_var}' — must be a non-negative integer" >&2; exit 2 ;;
  esac
done

_SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_SWEEP_DIR/lib/slack-notify.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required"; exit 2; }
command -v git >/dev/null 2>&1 || { log "ERROR: git required"; exit 2; }

NOW_EPOCH="$(date +%s)"

swept=0; freed_kb=0; junk_deleted=0; active=0; kept=0; rm_errors=0
enum_failed=0   # a root we could not fully enumerate = structural failure
held_dirty=0; held_probe=0; held_gitfile=0; held_nested=0
held_noremote=0; held_mount=0; held_inuse=0

# Prefix of the private sibling DIRECTORY a candidate is renamed into for the
# final re-audit (created with mktemp -d, so the name is exclusive). A run
# killed between the rename and the rm leaves one behind; the sweep HOLDS
# those (never re-sweeps them) — the prefix has already destroyed the
# keep-list basename match, so treating debris as an ordinary candidate could
# delete a keep-listed clone that was merely mid-quarantine. Because debris is
# retained indefinitely, the quarantine target can never be a name that might
# recur (a PID, a timestamp) — see remove_entry.
QUARANTINE_PREFIX=".sweep-quarantine."

HELD_FILE="$(mktemp)"
ERRORS_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$HELD_FILE" "$ERRORS_FILE" "$PAYLOAD_FILE"' EXIT

# ── guards lifted from weekly-cleanup.sh (normalization hardened) ────
# Strip ALL trailing slashes ('' if the input was only slashes) so forms
# like '//' cannot dodge the broad-root refusal below.
normalize_root() {
  local root="$1"
  while [ "$root" != "${root%/}" ]; do root="${root%/}"; done
  printf '%s' "$root"
}

guard_root() {
  local root="$1"
  if [ -z "$root" ] || [ "$root" = "/" ]; then
    log "FATAL: refusing to run with root='$root'"; exit 1
  fi
  if [ -L "$root" ]; then
    log "FATAL: swept root is a symlink: $root"; exit 1
  fi
  if [ ! -d "$root" ]; then
    log "FATAL: swept root is not a directory: $root"; exit 1
  fi
  local rp
  rp="$(realpath -- "$root" 2>/dev/null)" || { log "FATAL: realpath failed for $root"; exit 1; }
  if [ "$rp" != "$root" ]; then
    log "FATAL: swept root resolves elsewhere ($root -> $rp)"; exit 1
  fi
}

# guard_root's checks pass for ANY real directory, so a stale or mistyped
# SWEEP_REPOS_ROOT / SWEEP_WS_ROOT (say /opt, /var, or /opt/hydra) would hand
# this script — run weekly as root with --apply, inheriting the unit's
# environment — an unrelated tree to age out and rm -rf. The production
# topology is fixed, so require it exactly; arbitrary sandbox roots are legal
# only under the same explicit test-only override that waives the host guard.
PROD_WS_ROOT="/opt/hydra/workspaces"
PROD_REPOS_ROOT="$PROD_WS_ROOT/repos"
guard_prod_topology() {
  if [ "$WS_ROOT" != "$PROD_WS_ROOT" ] || [ "$REPOS_ROOT" != "$PROD_REPOS_ROOT" ]; then
    log "FATAL: out-of-scope roots (repos='$REPOS_ROOT' ws='$WS_ROOT') — production sweeps only $PROD_REPOS_ROOT and $PROD_WS_ROOT (set SWEEP_SKIP_HOST_GUARD=1 for sandbox roots)"
    exit 1
  fi
}

# True if $1 IS a mountpoint or any mountpoint lives under it. The exact-match
# case matters: rm --one-file-system treats a command-line argument that is
# itself a mountpoint as that filesystem's root and would wipe its contents.
# SWEEP_MOUNTS_FILE overrides the mounts table for hermetic tests.
MOUNTS_FILE="${SWEEP_MOUNTS_FILE:-/proc/self/mounts}"
mount_hazard() {
  # Cannot inspect the mount table → cannot prove absence of a mount → hazard.
  [ -r "$MOUNTS_FILE" ] || return 0
  # The kernel octal-escapes whitespace in mount paths (' ' → \040): decode
  # before comparing, or a mount named "old clone" is invisible to the guard.
  # The candidate path rides in via ENVIRON — awk -v would itself interpret
  # backslash escapes, corrupting a path that literally contains one.
  MH_P="$1" awk '
    {
      m = $2
      gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m)
      gsub(/\\012/, "\n", m); gsub(/\\134/, "\\", m)
      if (m == ENVIRON["MH_P"]) found = 1
      if (index(m, ENVIRON["MH_P"] "/") == 1) found = 1
    }
    END { exit found ? 0 : 1 }' "$MOUNTS_FILE"
}

# True only if $1 IS ITSELF a mountpoint — EXACT match, no "or under".
# A sweep ROOT needs this narrower form: mount_hazard's "anything beneath"
# reading would refuse an entire lane the moment one candidate is a mount,
# instead of holding just that candidate. An unreadable table returns false
# here on purpose — the per-candidate mount_hazard is already fail-closed and
# holds everything in that case, so this rail must not additionally convert
# it into a whole-run structural abort.
is_mountpoint() {
  [ -r "$MOUNTS_FILE" ] || return 1
  MP_P="$1" awk '
    {
      m = $2
      gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m)
      gsub(/\\012/, "\n", m); gsub(/\\134/, "\\", m)
      if (m == ENVIRON["MP_P"]) found = 1
    }
    END { exit found ? 0 : 1 }' "$MOUNTS_FILE"
}

entry_kb() {
  local kb
  kb="$(du -skx -- "$1" 2>/dev/null | awk '{print $1}' || true)"
  echo "${kb:-0}"
}

# GNU rm has --one-file-system (prod / CI); BSD rm (dev laptops) does not.
# The has_mount_under skip is the primary rail either way — this is backstop.
RM_ONEFS=()
if rm --one-file-system -rf "$(mktemp -d)" 2>/dev/null; then
  RM_ONEFS=(--one-file-system)
fi

is_kept() {
  local name="$1" k
  for k in "${KEEP_LIST[@]}"; do
    [ "$name" = "$k" ] && return 0
  done
  return 1
}

hold() {  # hold <lane> <path> <detail>
  echo "$1 $2 — $3" >> "$HELD_FILE"
  log "held ($1): $2 — $3"
}

# Reference files carrying the cutoff mtimes: `find -newer <ref>` is portable
# (GNU find's -newermt "@epoch" is not), and a ref file can't be mis-parsed.
epoch_to_stamp() {  # <epoch> -> touch -t stamp
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S
}
make_ref() {  # <epoch> -> path of a file whose mtime is that epoch
  local f
  f="$(mktemp)"
  touch -t "$(epoch_to_stamp "$1")" "$f"
  echo "$f"
}

# Any write in the tree (excluding .git/) newer than the ref file?
# A failed find is treated as FRESH — the age rail must fail safe, not open.
tree_fresh_since() {  # <dir> <ref-file>
  local out rc=0
  out="$(find "$1" -xdev -path "$1/.git" -prune -o -newer "$2" -print -quit 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] && return 0
  [ -n "$out" ]
}

# Portable mtime epoch (GNU stat -c, BSD stat -f); unknown → now (fail-safe).
mtime_epoch() {
  stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo "$NOW_EPOCH"
}

# Full identity of a path WITHOUT dereferencing symlinks (GNU stat -c, BSD
# stat -f): device, inode, mtime, ctime, size. Empty when it cannot be read,
# which the removal gate treats as a mismatch.
#
# device:inode ALONE is not enough — unlink+create in the same directory
# hands the new object the just-freed inode number on ext4, so a replacement
# compares equal (demonstrated by the file→file regression failing on the
# Linux CI runner while passing on APFS). ctime is what closes it: it is set
# by the kernel on every inode change and is settable by NO userspace API —
# not touch, not utimensat — so a replacement object cannot carry the stale
# one's ctime. mtime and size are cheap corroboration in the same call.
# NANOSECOND forms deliberately: GNU %Y/%Z and BSD %m/%c are whole SECONDS, so
# a replacement created in the same second as the original's last status change
# compares equal when the inode is reused and size/mtime are forged. GNU's
# human-readable %y/%z and BSD's %Fm/%Fc carry the full ns timestamp
# (verified on ovh-node-8/ext4: %z -> '2026-07-27 11:57:33.770505722 +0000').
# '|' separates the fields: the ns timestamps contain both ':' and ' '.
path_id() {
  stat -c '%d|%i|%y|%z|%s' -- "$1" 2>/dev/null \
    || stat -f '%d|%i|%Fm|%Fc|%z' -- "$1" 2>/dev/null \
    || true
}

# The rename-INVARIANT subset of a path_id: device, inode, mtime, size.
# rename(2) bumps ctime (measured on ovh-node-8: .770505722 -> .776505699
# across a mv), so the post-quarantine re-audit must drop that field while
# the pre-quarantine check keeps it.
id_stable() {  # <path_id>
  local dev ino mtime ctime size
  # shellcheck disable=SC2034  # ctime is parsed precisely so it can be DROPPED
  IFS='|' read -r dev ino mtime ctime size <<< "$1"
  printf '%s|%s|%s|%s' "$dev" "$ino" "$mtime" "$size"
}

# ── post-quarantine re-audits ────────────────────────────────
# The moved ROOT's device/inode/mtime/size proves the root entry was not
# swapped, and nothing more. rename(2) does NOT disturb an open descriptor or
# a process whose cwd is inside the tree: such a writer keeps writing through
# its existing handles, and overwriting an ALREADY-TRACKED file (or a git ref)
# changes that file — never the root directory entry. So each lane re-runs its
# full policy against the quarantined object, immediately before the rm.
# Each sets REAUDIT_REASON and returns 1 to refuse.
REAUDIT_REASON=""

# Entry lane: the candidate IS a single file or symlink, so any write through
# a surviving handle moves its own mtime/size — already covered by the
# identity comparison. Nothing further to prove.
reaudit_entry() { REAUDIT_REASON=""; return 0; }

reaudit_junk() {  # <quarantined-path> <cutoff-ref-file>
  local q="$1" cutoff_ref="$2" inner rc=0
  inner="$(find "$q" -xdev -name .git -print -quit 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$inner" ]; then
    REAUDIT_REASON="repo appeared inside the tree before removal"; return 1
  fi
  if tree_fresh_since "$q" "$cutoff_ref"; then
    REAUDIT_REASON="tree written to before removal"; return 1
  fi
  return 0
}


# ── quarantine primitives ────────────────────────────────────
QPATH=""; QDIR=""; QUARANTINE_ERROR=""

# True if ANY live process holds the tree open — cwd or an open descriptor.
# This is the other half of the no-writers guarantee: the quarantine rename
# means no process can acquire a NEW handle (nothing can look the object up
# by a name it does not know), and this catches the handles that already
# existed. Without it, a process cwd'd inside can still create an allow-empty
# commit or update a ref after the audit and before/while rm traverses, and
# .git-only writes never move the worktree-freshness rail.
#
# Called immediately AFTER the rename on purpose: from that moment the set of
# holders can only shrink, so one scan is sound. Scanning per candidate before
# quarantine would be both slower and racy.
#
# Cannot enumerate → cannot prove absence → hazard. SWEEP_PROC_DIR is
# dependency injection for tests (same role SWEEP_MOUNTS_FILE plays for the
# mount table), NOT a bypass: a missing or unreadable tree still fails closed.
PROC_DIR="${SWEEP_PROC_DIR:-/proc}"

# GNU find capability, probed ONCE and separately from any runtime error.
# Conflating the two is what made the first version of this fail open: on a
# real /proc, plain `find` exits 1 as a matter of course (processes vanish
# mid-scan — measured on node-8), so "nonzero => fall back" meant the fallback
# was the normal path in production, not the dev-laptop exception.
FIND_GNU=0
_probe_dir="$(mktemp -d)"
if find "$_probe_dir" -maxdepth 0 -ignore_readdir_race -printf '' >/dev/null 2>&1; then
  FIND_GNU=1
fi
rmdir "$_probe_dir" 2>/dev/null || true

# Every link target under the proc tree, one per line. Returns NONZERO if the
# enumeration could not be completed — the caller treats that as a hazard.
proc_link_targets() {
  local l t
  if [ "$FIND_GNU" -eq 1 ]; then
    # -ignore_readdir_race: a process disappearing mid-scan is expected here
    # and is NOT a failure (a dead process holds nothing). Any OTHER error
    # still surfaces as a nonzero exit, which is exactly what we want.
    # ~208ms on node-8 (725 processes / 11k links) in a single pass.
    find "$PROC_DIR" -ignore_readdir_race -mindepth 2 -maxdepth 3 \
      \( -name cwd -o -path "$PROC_DIR/[0-9]*/fd/*" \) -printf '%l\n' 2>/dev/null
    return
  fi
  # BSD find (dev laptops) has neither flag. Fixture trees are tiny, so the
  # fork-per-link walk is fine — but it must FAIL CLOSED: a link that exists
  # and cannot be read means we cannot prove absence of a writer.
  for l in "$PROC_DIR"/[0-9]*/cwd "$PROC_DIR"/[0-9]*/fd/*; do
    [ -L "$l" ] || continue
    if ! t="$(readlink -- "$l" 2>/dev/null)"; then
      # Vanished since the glob = benign; still present = unreadable = hazard.
      if [ -L "$l" ]; then return 1; fi
      continue
    fi
    printf '%s\n' "$t"
  done
}

has_live_handles() {  # <path>
  local p="$1" targets rc=0
  [ -d "$PROC_DIR" ] || return 0
  targets="$(proc_link_targets)" || rc=$?
  [ "$rc" -eq 0 ] || return 0
  printf '%s\n' "$targets" | HP_P="$p" awk '
    $0 == ENVIRON["HP_P"] { found = 1 }
    index($0, ENVIRON["HP_P"] "/") == 1 { found = 1 }
    END { exit found ? 0 : 1 }'
}

# Take the candidate OUT of the namespace, atomically. The target must be
# GUARANTEED-private, not merely unlikely to collide: leftovers are retained
# forever by design, so a recurring name (a PID, a timestamp) could already
# exist and mv would then overwrite a held file or nest inside a held
# directory. mktemp -d creates the sibling exclusively, in the same directory
# and therefore the same filesystem — no cross-device copy fallback, which a
# deletion path must never do.
quarantine_candidate() {  # <path> <id-at-classification>
  local p="$1" id="$2" qdir q err
  QPATH=""; QDIR=""; QUARANTINE_ERROR=""
  qdir="$(mktemp -d "$(dirname -- "$p")/${QUARANTINE_PREFIX}XXXXXX" 2>/dev/null)" || {
    QUARANTINE_ERROR="could not create a private sibling directory"
    return 1
  }
  q="$qdir/$(basename -- "$p")"
  err="$(mv -- "$p" "$q" 2>&1)" || {
    QUARANTINE_ERROR="quarantine rename failed: ${err:0:120}"
    rmdir "$qdir" 2>/dev/null || true
    return 1
  }
  # Explicit move verification — never infer the outcome from mv's exit status
  # alone. -e is false for a dangling symlink, so -L is its companion.
  if { [ ! -e "$q" ] && [ ! -L "$q" ]; } || [ -e "$p" ] || [ -L "$p" ]; then
    QUARANTINE_ERROR="quarantine rename did not land at $q"
    rmdir "$qdir" 2>/dev/null || true
    return 1
  fi
  # rename(2) bumps ctime, so compare the rename-invariant subset.
  if [ -z "$id" ] || [ "$(id_stable "$(path_id "$q")")" != "$(id_stable "$id")" ]; then
    QUARANTINE_ERROR="object replaced before removal"
    restore_quarantine "$q" "$p" "$qdir" || true
    return 1
  fi
  # No new handle can be acquired from here (the name is private), so this one
  # scan settles it: if nobody holds the tree open now, nobody will.
  if has_live_handles "$q"; then
    QUARANTINE_ERROR="live process holds the tree open (cwd or open fd)"
    restore_quarantine "$q" "$p" "$qdir" || true
    return 1
  fi
  QPATH="$q"; QDIR="$qdir"
  return 0
}

# Put it back, NEVER clobbering a name another writer has retaken. GNU mv -n
# exits 0 when it declines, so the move is proven rather than assumed.
restore_quarantine() {  # <quarantined> <original> <qdir>
  if mv -n -- "$1" "$2" 2>/dev/null && [ ! -e "$1" ] && [ ! -L "$1" ]; then
    rmdir "$3" 2>/dev/null || true
    log "restored from quarantine: $2"
    return 0
  fi
  rm_errors=$((rm_errors + 1))
  echo "quarantine restore blocked (name retaken): object left at $1" >> "$ERRORS_FILE"
  hold "in-use" "$1" "restore blocked — LEFT QUARANTINED, needs human review"
  return 1
}

delete_quarantined() {  # <quarantined> <qdir> <label> <original> <kb> <is-tree>
  local q="$1" qdir="$2" label="$3" p="$4" kb="$5" is_tree="$6" err rm_cmd
  rm_cmd=(rm -f --)
  if [ "$is_tree" -eq 1 ]; then
    # ${arr[@]+...}: safe under set -u with an empty array on bash 3.2 (macOS dev).
    rm_cmd=(rm -rf ${RM_ONEFS[@]+"${RM_ONEFS[@]}"} --)
  fi
  err="$("${rm_cmd[@]}" "$q" 2>&1)" || {
    rm_errors=$((rm_errors + 1))
    echo "rm failed: $q (quarantined from $p): ${err:0:200}" >> "$ERRORS_FILE"
    return 1
  }
  rmdir "$qdir" 2>/dev/null || true
  log "deleted $label $p (${kb} KB)"
}

remove_entry() {  # <path> <kb> <label> <expect:entry|tree> <id> <reaudit-fn> [reaudit-args...]
  local p="$1" kb="$2" label="$3" expect="$4" id="$5" reaudit="$6"
  shift 6
  local reaudit_args=("$@")
  local err rm_cmd is_tree=0 now_id
  if [ "$APPLY" -eq 0 ]; then
    log "DRY-RUN: would delete $label $p (${kb} KB)"
    return 0
  fi
  if [ ! -L "$p" ] && [ -d "$p" ]; then is_tree=1; fi
  # The caller classified this path BEFORE the du seam. If another process
  # swapped it since (a stale symlink or file replaced by a fresh directory,
  # or vice versa), the type no longer matches what the guards ran against:
  # recursing into that tree would delete something the freshness /
  # nested-repo / mount rails never saw. Refuse the transition — the next
  # run re-classifies from scratch.
  if [ "$expect" = "entry" ] && [ "$is_tree" -eq 1 ]; then
    held_inuse=$((held_inuse + 1))
    hold "in-use" "$p" "entry became a directory between classification and removal"
    return 1
  fi
  if [ "$expect" = "tree" ] && [ "$is_tree" -eq 0 ]; then
    held_inuse=$((held_inuse + 1))
    hold "in-use" "$p" "directory became a file/symlink between classification and removal"
    return 1
  fi
  # Type parity is not identity. A stale symlink can be unlinked and a FRESH
  # symlink created at the same name, or a guarded directory swapped for a
  # different directory, during the du seam: same type, different object, and
  # none of the guards ever saw the new one. Compare the full stat identity
  # captured at classification — an unreadable one on either side is a mismatch.
  now_id="$(path_id "$p")"
  if [ -z "$id" ] || [ -z "$now_id" ] || [ "$id" != "$now_id" ]; then
    held_inuse=$((held_inuse + 1))
    hold "in-use" "$p" "path identity changed between classification and removal (${id:-unreadable} -> ${now_id:-unreadable})"
    return 1
  fi
  rm_cmd=(rm -f --)
  if [ "$is_tree" -eq 1 ]; then
    # ${arr[@]+...}: safe under set -u with an empty array on bash 3.2 (macOS dev).
    rm_cmd=(rm -rf ${RM_ONEFS[@]+"${RM_ONEFS[@]}"} --)
  fi

  # Every check above is still check-then-act ON A PATHNAME: a swap in the
  # window between the last stat and the rm would delete an object no guard
  # ever saw, recursively and as root. Close it by taking the candidate OUT
  # of the namespace first. rename(2) is atomic, and a sibling name in the
  # SAME directory is same-filesystem by construction (no cross-device
  # fallback to a copy, which a deletion-safety path must never do). After
  # the rename, $q is provably whatever occupied $p at that instant, under a
  # name no other writer knows — so the object re-audited is the object
  # removed.
  #
  # The target must be GUARANTEED-private, not merely unlikely to collide. A
  # PID-derived name is neither: leftovers are retained forever by design, so
  # after PID reuse the name can already exist — and then `mv` would silently
  # overwrite a held file, or treat a held directory as a destination and nest
  # the candidate INSIDE it, destroying the very object the hold promised to
  # preserve and breaking restore. mktemp -d creates the sibling atomically
  # and exclusively, so the leaf inside it cannot pre-exist.
  local qdir q
  qdir="$(mktemp -d "$(dirname -- "$p")/${QUARANTINE_PREFIX}XXXXXX" 2>/dev/null)" || {
    rm_errors=$((rm_errors + 1))
    echo "quarantine failed: $p: could not create a private sibling directory" >> "$ERRORS_FILE"
    return 1
  }
  q="$qdir/$(basename -- "$p")"
  err="$(mv -- "$p" "$q" 2>&1)" || {
    rm_errors=$((rm_errors + 1))
    echo "quarantine failed: $p: ${err:0:200}" >> "$ERRORS_FILE"
    rmdir "$qdir" 2>/dev/null || true
    return 1
  }
  # Explicit move verification — never infer the outcome from mv's exit status
  # alone. -e is false for a dangling symlink, so -L is its companion.
  if { [ ! -e "$q" ] && [ ! -L "$q" ]; } || [ -e "$p" ] || [ -L "$p" ]; then
    rm_errors=$((rm_errors + 1))
    echo "quarantine failed: $p: rename did not land at $q" >> "$ERRORS_FILE"
    rmdir "$qdir" 2>/dev/null || true
    return 1
  fi
  local refuse=""
  if [ "$(id_stable "$(path_id "$q")")" != "$(id_stable "$id")" ]; then
    refuse="object replaced before removal"
  elif ! "$reaudit" "$q" ${reaudit_args[@]+"${reaudit_args[@]}"}; then
    refuse="$REAUDIT_REASON"
  fi
  if [ -n "$refuse" ]; then
    held_inuse=$((held_inuse + 1))
    # Restore, but NEVER clobber: another writer may already own the name
    # again. GNU mv -n exits 0 when it declines, so prove the move happened.
    if mv -n -- "$q" "$p" 2>/dev/null && [ ! -e "$q" ] && [ ! -L "$q" ]; then
      hold "in-use" "$p" "$refuse — restored from quarantine"
      rmdir "$qdir" 2>/dev/null || true
    else
      rm_errors=$((rm_errors + 1))
      echo "quarantine restore blocked (name retaken): object left at $q" >> "$ERRORS_FILE"
      hold "in-use" "$q" "$refuse — LEFT QUARANTINED, restore blocked"
    fi
    return 1
  fi
  err="$("${rm_cmd[@]}" "$q" 2>&1)" || {
    rm_errors=$((rm_errors + 1))
    echo "rm failed: $q (quarantined from $p): ${err:0:200}" >> "$ERRORS_FILE"
    return 1
  }
  rmdir "$qdir" 2>/dev/null || true
  log "deleted $label $p (${kb} KB)"
}

# ── the clone policy audit — the ONLY copy ───────────────────
# Runs ONCE, against <audit-path>, and reports against <report-path> (the
# original name, which is what an operator recognises). It used to exist
# twice — a pre-quarantine audit and a weaker post-quarantine re-audit — and
# the two drifted: the second trusted mutable cached refs/remotes/* and
# skipped live reachability, so a writer that kept its cwd across the rename
# could park a commit where only the dropped checks would have seen it.
# Returns 0 = safe to delete. A refusal has ALREADY held and counted itself.
clone_policy_audit() {  # <audit-path> <report-path>
  local ap="$1" rp="$2" probe_out rc
  # Git probes — a failed probe is NEVER "clean" (fail closed).
  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" remote 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "git remote: ${probe_out:0:120}"; return 1
  fi
  if [ -z "$probe_out" ]; then
    held_noremote=$((held_noremote + 1)); hold "no-remote" "$rp" "no remotes configured"; return 1
  fi

  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" status --porcelain 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "git status: ${probe_out:0:120}"; return 1
  fi
  if [ -n "$probe_out" ]; then
    held_dirty=$((held_dirty + 1)); hold "dirty" "$rp" "$(echo "$probe_out" | wc -l | tr -d ' ') dirty path(s)"; return 1
  fi

  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" log --all --not --remotes --oneline 2>&1 | head -5)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "git log: ${probe_out:0:120}"; return 1
  fi
  if [ -n "$probe_out" ]; then
    held_dirty=$((held_dirty + 1)); hold "unpushed" "$rp" "commits not on any remote"; return 1
  fi

  rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" stash list 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "git stash: ${probe_out:0:120}"; return 1
  fi
  if [ -n "$probe_out" ]; then
    held_dirty=$((held_dirty + 1)); hold "stash" "$rp" "stash entries present"; return 1
  fi

  # Ref parity, by NAME and OBJECT, against the LIVE server: commit
  # reachability (above) is not ref safety — a local branch or tag whose
  # exact (name, object-id) pair is not on the server right now still loses
  # its pointer (and an annotated tag its message object) on deletion.
  # Cached refs/remotes/* are NOT proof: a branch deleted server-side after
  # the clone's last fetch leaves a stale tracking ref that vouches for
  # itself. One ls-remote snapshot covers heads and tags; it is network, but
  # only candidates that survived every other gate reach this, and any
  # failure holds — never passes.
  local live_refs local_refs bad_ref refsha refname live_sha live_unreachable
  rc=0; live_refs="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" ls-remote origin 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "git ls-remote: ${live_refs:0:120}"; return 1
  fi
  rc=0; local_refs="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" for-each-ref refs/heads refs/tags --format='%(objectname) %(refname)' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "git for-each-ref: ${local_refs:0:120}"; return 1
  fi
  # Tags: exact (sha, refname) live match — tags are immutable by
  # convention, and an annotated tag OBJECT differing from origin's is data.
  # Branches: BOTH conditions —
  #   (a) a cached same-named refs/remotes/*/<name> at the SAME sha (a
  #       diverged local pointer whose tip is merely reachable elsewhere
  #       must hold), and
  #   (b) the name exists on the LIVE server (a branch deleted server-side
  #       after the last fetch leaves a stale tracking ref vouching for
  #       itself — cached refs alone are not proof).
  # Live exact-sha parity for branches would hold every stale clone forever
  # (a stale local main is always behind the live main); (a)+(b) keeps the
  # pointer-safety contract without reducing the sweeper to a no-op.
  bad_ref=""
  while IFS=' ' read -r refsha refname; do
    [ -n "$refname" ] || continue
    case "$refname" in
      refs/tags/*)
        if ! printf '%s\n' "$live_refs" \
            | awk -v s="$refsha" -v r="$refname" '$1 == s && $2 == r { found = 1 } END { exit found ? 0 : 1 }'; then
          bad_ref="$refname"; break
        fi ;;
      *)
        # ORIGIN specifically, not refs/remotes/*/: the live check below only
        # ever queries origin, so a wildcard lets a stale ref from ANOTHER
        # remote vouch for the local pointer. With cached upstream/x == local
        # x@A and live origin/x @B, both gates passed while no live remote
        # preserved x@A — and deleting the clone lost that branch pointer even
        # though commit A stayed reachable. Ref NAMES are data too.
        if ! GIT_OPTIONAL_LOCKS=0 git -C "$ap" for-each-ref "refs/remotes/origin/${refname#refs/heads/}" --format='%(objectname)' 2>/dev/null \
            | grep -qxF -- "$refsha"; then
          bad_ref="$refname"; break
        fi
        live_sha="$(printf '%s\n' "$live_refs" | awk -v r="$refname" '$2 == r { print $1; exit }')"
        if [ -z "$live_sha" ]; then
          bad_ref="$refname"; break
        fi ;;
    esac
  done <<< "$local_refs"

  # Live reachability for EVERY locally retained commit — HEAD included, so
  # a detached HEAD backed only by a stale cached tracking ref (its server
  # branch force-pushed or deleted) can never be lost. One namespace fetch
  # of all live heads, then any commit reachable from --all (HEAD, branches,
  # tags, stash tip, cached remotes) but not from the live snapshot holds.
  live_unreachable=""
  if [ -z "$bad_ref" ]; then
    # A sweep killed after fetching leaves stale refs/sweep-live/* that the
    # --glob check below would trust as live proof: clear the namespace
    # BEFORE fetching, fail-closed, and fetch with pruning as the belt.
    if ! GIT_OPTIONAL_LOCKS=0 git -C "$ap" for-each-ref refs/sweep-live --format='%(refname)' 2>/dev/null \
        | while IFS= read -r stale_ref; do
            git -C "$ap" update-ref -d "$stale_ref" || exit 1
          done; then
      live_unreachable="probe-failed: could not clear stale sweep-live refs"
    elif ! GIT_OPTIONAL_LOCKS=0 git -C "$ap" fetch --quiet --prune origin '+refs/heads/*:refs/sweep-live/heads/*' 2>/dev/null; then
      live_unreachable="fetch-failed"
    else
      rc=0; probe_out="$(GIT_OPTIONAL_LOCKS=0 git -C "$ap" log --all --not --glob='refs/sweep-live' --oneline 2>&1 | head -3)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        live_unreachable="probe-failed: ${probe_out:0:100}"
      elif [ -n "$probe_out" ]; then
        live_unreachable="commits not reachable from live origin"
      fi
    fi
  fi
  # Drop the isolated-namespace refs whatever the outcome (a held clone must
  # not accumulate sweep artifacts; fetched objects are unreferenced and gc-able).
  GIT_OPTIONAL_LOCKS=0 git -C "$ap" for-each-ref refs/sweep-live --format='%(refname)' 2>/dev/null \
    | while IFS= read -r stale_ref; do
        git -C "$ap" update-ref -d "$stale_ref" 2>/dev/null || true
      done
  if [ -n "$bad_ref" ]; then
    held_dirty=$((held_dirty + 1))
    case "$bad_ref" in
      refs/tags/*) hold "local-tag" "$rp" "'${bad_ref#refs/tags/}' is absent from origin or at a different object" ;;
      *) hold "local-branch" "$rp" "'${bad_ref#refs/heads/}' diverges from its tracking ref or is gone from origin (live)" ;;
    esac
    return 1
  fi
  if [ -n "$live_unreachable" ]; then
    case "$live_unreachable" in
      fetch-failed|probe-failed*)
        held_probe=$((held_probe + 1)); hold "probe-fail" "$rp" "live-reachability: $live_unreachable" ;;
      *)
        held_dirty=$((held_dirty + 1)); hold "unpushed-live" "$rp" "$live_unreachable" ;;
    esac
    return 1
  fi

  # Pre-rm recheck: in-progress operations and last-minute writes.
  if [ -e "$ap/.git/index.lock" ] || [ -e "$ap/.git/MERGE_HEAD" ] \
     || [ -e "$ap/.git/rebase-merge" ] || [ -e "$ap/.git/rebase-apply" ]; then
    held_inuse=$((held_inuse + 1)); hold "in-use" "$rp" "git operation in progress"; return 1
  fi
  if tree_fresh_since "$ap" "$WINDOW_REF"; then
    active=$((active + 1)); return 1
  fi
  return 0
}
# ── per-candidate policy ─────────────────────────────────────
sweep_candidate() {  # <path> <cutoff-epoch> <cutoff-ref-file> <lane:repos|tmp>
  local d="$1" cutoff="$2" ref="$3" lane="$4"
  local name kb head_sha probe_out rc cand_id
  name="$(basename "$d")"

  # A depth-1 .git means the swept ROOT is itself a clone worktree — never
  # treat its metadata (or, by extension, this root) as junk.
  if [ "$name" = ".git" ]; then
    held_gitfile=$((held_gitfile + 1))
    hold "clone-root" "$d" "swept root itself looks like a git clone"
    return 0
  fi

  # Quarantine debris from a killed prior run: report it, never sweep it.
  case "$name" in
    "$QUARANTINE_PREFIX"*)
      held_inuse=$((held_inuse + 1))
      hold "in-use" "$d" "quarantine leftover from an interrupted run — needs human review"
      return 0 ;;
  esac

  # Identity of the object every guard below is about to be run against.
  # Everything that reaches a removal must still BE this object.
  cand_id="$(path_id "$d")"

  # Symlinks and plain files: never followed; junk-aged by own mtime.
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    if [ "$(mtime_epoch "$d")" -lt "$cutoff" ]; then
      kb="$(entry_kb "$d")"
      if remove_entry "$d" "$kb" "entry" entry "$cand_id" reaudit_entry; then
        junk_deleted=$((junk_deleted + 1)); freed_kb=$((freed_kb + kb))
      fi
    else
      active=$((active + 1))
    fi
    return 0
  fi

  if [ "$lane" = "repos" ] && is_kept "$name"; then
    kept=$((kept + 1))
    log "kept (keep-list): $d"
    return 0
  fi

  if [ -f "$d/.git" ]; then
    held_gitfile=$((held_gitfile + 1))
    hold "gitfile" "$d" ".git is a file (linked worktree/submodule)"
    return 0
  fi

  # No .git at all → plain junk, mtime-only policy on the whole tree —
  # UNLESS a repo hides anywhere inside (tmp/build/checkout/.git): a nested
  # clone with unique work must never ride out on the junk lane. A failed
  # scan holds too (cannot prove absence → cannot delete).
  if [ ! -e "$d/.git" ]; then
    local inner rc_inner=0
    inner="$(find "$d" -xdev -name .git -print -quit 2>/dev/null)" || rc_inner=$?
    if [ "$rc_inner" -ne 0 ] || [ -n "$inner" ]; then
      held_nested=$((held_nested + 1))
      hold "nested" "$d" "${inner:+repo at $inner inside a non-git tree}${inner:-nested-repo scan failed}"
      return 0
    fi
    if tree_fresh_since "$d" "$ref"; then
      active=$((active + 1)); return 0
    fi
    if mount_hazard "$d"; then
      held_mount=$((held_mount + 1)); hold "mount" "$d" "mountpoint at or under candidate"; return 0
    fi
    # du over a large tree takes time — re-run every junk-lane guard right
    # before removal so nothing created during the size scan is deleted.
    kb="$(entry_kb "$d")"
    rc_inner=0
    inner="$(find "$d" -xdev -name .git -print -quit 2>/dev/null)" || rc_inner=$?
    if [ "$rc_inner" -ne 0 ] || [ -n "$inner" ]; then
      held_nested=$((held_nested + 1)); hold "nested" "$d" "repo appeared during size scan"; return 0
    fi
    if tree_fresh_since "$d" "$ref"; then
      active=$((active + 1)); return 0
    fi
    if mount_hazard "$d"; then
      held_mount=$((held_mount + 1)); hold "mount" "$d" "mountpoint at or under candidate"; return 0
    fi
    if remove_entry "$d" "$kb" "junk" tree "$cand_id" reaudit_junk "$ref"; then
      junk_deleted=$((junk_deleted + 1)); freed_kb=$((freed_kb + kb))
    fi
    return 0
  fi

  # Git clone lanes. The cheap staleness gates run on the LIVE path: they only
  # decide whether this is a candidate at all, and quarantining a clone that is
  # merely fresh would rename a directory somebody is actively working in.
  if tree_fresh_since "$d" "$ref"; then
    active=$((active + 1)); return 0
  fi
  if mount_hazard "$d"; then
    held_mount=$((held_mount + 1)); hold "mount" "$d" "mountpoint at or under candidate"; return 0
  fi
  # Same fail-closed contract as the plain-junk lane: a scan that ERRORS has
  # not ruled out an inner repo, and a command substitution alone discards
  # find's exit status — capture it, and hold on any nonzero.
  rc=0; probe_out="$(find "$d" -xdev -mindepth 2 -name .git -print -quit 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$probe_out" ]; then
    held_nested=$((held_nested + 1))
    hold "nested" "$d" "${probe_out:+inner repo present}${probe_out:-nested-repo scan failed}"
    return 0
  fi

  # From here the object leaves the namespace FIRST, and size, policy audit and
  # removal all run on the private name. That is what makes the audit
  # authoritative: nothing can be substituted after it passes, and there is no
  # second copy of the policy to drift out of sync with this one.
  local audit_path="$d" qpath="" qdir=""
  if [ "$APPLY" -eq 1 ]; then
    if ! quarantine_candidate "$d" "$cand_id"; then
      held_inuse=$((held_inuse + 1))
      hold "in-use" "$d" "$QUARANTINE_ERROR"
      return 0
    fi
    qpath="$QPATH"; qdir="$QDIR"; audit_path="$qpath"
  fi

  # du BEFORE the audit, deliberately: the audit must be the LAST thing that
  # happens before the rm, with no seam in between for anything to change.
  head_sha="$(GIT_OPTIONAL_LOCKS=0 git -C "$audit_path" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  kb="$(entry_kb "$audit_path")"

  if ! clone_policy_audit "$audit_path" "$d"; then
    if [ -n "$qpath" ]; then restore_quarantine "$qpath" "$d" "$qdir"; fi
    return 0
  fi

  if [ "$APPLY" -eq 0 ]; then
    log "DRY-RUN: would delete clone (HEAD $head_sha) $d (${kb} KB)"
    swept=$((swept + 1)); freed_kb=$((freed_kb + kb))
    return 0
  fi
  if delete_quarantined "$qpath" "$qdir" "clone (HEAD $head_sha)" "$d" "$kb" 1; then
    swept=$((swept + 1)); freed_kb=$((freed_kb + kb))
  fi

}

sweep_root_depth1() {  # <root> <cutoff-epoch> <cutoff-ref-file> <lane>
  local root="$1" cutoff="$2" ref="$3" lane="$4" p listing
  # find in a process substitution DISCARDS its exit status: an I/O error or
  # a root that vanishes mid-scan would just end the loop, and the run would
  # report a clean sweep of a category it only partially enumerated. Land the
  # listing first, check the status, and only then iterate.
  listing="$(mktemp)"
  if ! find "$root" -mindepth 1 -maxdepth 1 -print0 > "$listing" 2>/dev/null; then
    rm -f "$listing"
    log "FATAL: could not enumerate $root (scan failed) — refusing to report a partial sweep"
    # Record, do NOT return nonzero: under set -e a failing call here would
    # abort before print_summary, suppressing the very report that explains
    # the failure. enum_failed drives the exit status after the summary.
    enum_failed=1
    return 0
  fi
  while IFS= read -r -d '' p; do
    sweep_candidate "$p" "$cutoff" "$ref" "$lane"
  done < "$listing"
  rm -f "$listing"
}

print_summary() {
  log "swept_clones=$swept junk=$junk_deleted freed_kb=$freed_kb"
  log "active_skipped=$active kept=$kept rm_errors=$rm_errors"
  log "held: dirty/unpushed/stash=$held_dirty probe-fail=$held_probe gitfile=$held_gitfile nested=$held_nested no-remote=$held_noremote mount=$held_mount in-use=$held_inuse"
}

build_payload() {
  SWEPT="$swept" JUNK="$junk_deleted" FREED_KB="$freed_kb" ACTIVE="$active" \
  KEPT="$kept" RM_ERRORS="$rm_errors" HELD_DIRTY="$held_dirty" \
  HELD_PROBE="$held_probe" HELD_GITFILE="$held_gitfile" HELD_NESTED="$held_nested" \
  HELD_NOREMOTE="$held_noremote" HELD_MOUNT="$held_mount" HELD_INUSE="$held_inuse" \
  HELD_FILE="$HELD_FILE" ERRORS_FILE="$ERRORS_FILE" PAYLOAD_OUT="$PAYLOAD_FILE" \
  REPOS_TTL="$REPOS_TTL_DAYS" TMP_TTL="$TMP_TTL_DAYS" \
  SLACK_CHANNEL="$SLACK_CHANNEL" python3 - <<'PYEOF'
import json, os

e = os.environ
ints = {k: int(e[k]) for k in (
    "SWEPT", "JUNK", "FREED_KB", "ACTIVE", "KEPT", "RM_ERRORS", "HELD_DIRTY",
    "HELD_PROBE", "HELD_GITFILE", "HELD_NESTED", "HELD_NOREMOTE", "HELD_MOUNT",
    "HELD_INUSE")}
held_total = sum(ints[k] for k in ints if k.startswith("HELD_"))

def human(kb):
    if kb >= 1024 * 1024:
        return f"{kb / 1024 / 1024:.1f} GB"
    if kb >= 1024:
        return f"{kb / 1024:.1f} MB"
    return f"{kb} KB"

text = (
    f":broom: clone-sweep node-8 — freed {human(ints['FREED_KB'])} | "
    f"clones={ints['SWEPT']} junk={ints['JUNK']} | held={held_total} | "
    f"errors={ints['RM_ERRORS']}"
)

blocks = [
    {"type": "header", "text": {"type": "plain_text", "text": "workspace clone sweep — node-8"}},
    {"type": "section", "fields": [
        {"type": "mrkdwn", "text": f"*Freed:*\n{human(ints['FREED_KB'])}"},
        {"type": "mrkdwn", "text": f"*Deleted:*\n{ints['SWEPT']} clones · {ints['JUNK']} junk (repos >{e['REPOS_TTL']}d, tmp >{e['TMP_TTL']}d)"},
        {"type": "mrkdwn", "text": f"*Skipped:*\n{ints['ACTIVE']} active · {ints['KEPT']} keep-list"},
        {"type": "mrkdwn", "text": f"*Held (never deleted):*\n{held_total} — dirty/unpushed {ints['HELD_DIRTY']}, probe-fail {ints['HELD_PROBE']}, worktree {ints['HELD_GITFILE']}, nested {ints['HELD_NESTED']}, no-remote {ints['HELD_NOREMOTE']}, mount {ints['HELD_MOUNT']}, in-use {ints['HELD_INUSE']}"},
    ]},
]

if held_total:
    try:
        with open(e["HELD_FILE"]) as f:
            lines = [l.rstrip() for l in f if l.strip()][:10]
    except Exception:
        lines = []
    detail = "\n".join(f"• {l}" for l in lines) or "(no detail captured)"
    more = held_total - len(lines)
    if more > 0:
        detail += f"\n… and {more} more (see /var/log/hydra-weekly-cleanup.log)"
    blocks.append({"type": "section", "text": {
        "type": "mrkdwn", "text": f":file_folder: held for human review:\n{detail}"}})

if ints["RM_ERRORS"]:
    try:
        with open(e["ERRORS_FILE"]) as f:
            lines = [l.rstrip() for l in f if l.strip()][:10]
    except Exception:
        lines = []
    detail = "\n".join(f"• {l}" for l in lines) or "(no detail captured)"
    blocks.append({"type": "section", "text": {
        "type": "mrkdwn", "text": f":warning: {ints['RM_ERRORS']} rm error(s):\n{detail}"}})

with open(e["PAYLOAD_OUT"], "w") as f:
    json.dump({"channel": e["SLACK_CHANNEL"], "text": text, "blocks": blocks}, f)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

# Normalize BEFORE guarding, and sweep the normalized values — the guard's
# checks must apply to the exact strings the sweep will use.
REPOS_ROOT="$(normalize_root "$REPOS_ROOT")"
WS_ROOT="$(normalize_root "$WS_ROOT")"
guard_root "$REPOS_ROOT"
guard_root "$WS_ROOT"
[ "$SKIP_HOST_GUARD" = "1" ] || guard_prod_topology

if [ "$APPLY" -eq 1 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another sweep run holds $LOCKFILE"; exit 0; }
fi

REPOS_CUTOFF=$(( NOW_EPOCH - REPOS_TTL_DAYS * 86400 ))
TMP_CUTOFF=$(( NOW_EPOCH - TMP_TTL_DAYS * 86400 ))
REPOS_REF="$(make_ref "$REPOS_CUTOFF")"
TMP_REF="$(make_ref "$TMP_CUTOFF")"
WINDOW_REF="$(make_ref "$(( NOW_EPOCH - FRESH_WINDOW_SECS ))")"
trap 'rm -f "$HELD_FILE" "$ERRORS_FILE" "$PAYLOAD_FILE" "$REPOS_REF" "$TMP_REF" "$WINDOW_REF"' EXIT

# A swept root that is ITSELF a clone (someone ran `git clone repo .` in it)
# must be skipped whole: its depth-1 entries are that clone's worktree files.
root_is_clone() { [ -e "$1/.git" ]; }

if root_is_clone "$REPOS_ROOT"; then
  log "FATAL: $REPOS_ROOT is itself a git clone — refusing to sweep it"; exit 1
fi

# A sweep root that IS a mountpoint hides its own hazard: the per-candidate
# guard only sees mounts at or under a CHILD, and rm --one-file-system is no
# protection because every child already lives inside that filesystem. So a
# bind-mounted root would have its children recursively deleted.
if is_mountpoint "$REPOS_ROOT"; then
  log "FATAL: $REPOS_ROOT is itself a mountpoint — refusing to sweep it"; exit 1
fi

sweep_root_depth1 "$REPOS_ROOT" "$REPOS_CUTOFF" "$REPOS_REF" "repos"
for ws_tmp in "$WS_ROOT"/*/tmp "$WS_ROOT"/*/.tmp; do
  [ -d "$ws_tmp" ] || continue
  [ -L "$ws_tmp" ] && continue
  # A symlinked intermediate (workspaces/x -> elsewhere) must not pull an
  # out-of-scope tree into the sweep: the resolved path stays under WS_ROOT.
  ws_tmp_real="$(realpath -- "$ws_tmp" 2>/dev/null)" || continue
  case "$ws_tmp_real" in "$WS_ROOT"/*) ;; *) continue ;; esac
  # repos/ is a sibling of the agent workspaces; never double-sweep it.
  case "$ws_tmp" in "$REPOS_ROOT"/*) continue ;; esac
  if root_is_clone "$ws_tmp"; then
    hold "clone-root" "$ws_tmp" "tmp root is itself a git clone — skipped whole"
    held_gitfile=$((held_gitfile + 1))
    continue
  fi
  if is_mountpoint "$ws_tmp"; then
    hold "mount" "$ws_tmp" "tmp root is itself a mountpoint — skipped whole"
    held_mount=$((held_mount + 1))
    continue
  fi
  sweep_root_depth1 "$ws_tmp" "$TMP_CUTOFF" "$TMP_REF" "tmp"
done

print_summary

if [ "$APPLY" -eq 0 ]; then
  log "DRY-RUN: no deletions, no Slack post."
  [ "$enum_failed" -eq 0 ] || exit 1
  exit 0
fi

build_payload
log "Posting summary to ${SLACK_CHANNEL}."
slack_notify_payload_file "$PAYLOAD_FILE"

# Reported first, then surfaced: a partial enumeration must not read as a
# clean sweep to systemd (weekly-cleanup.sh propagates this).
[ "$enum_failed" -eq 0 ] || exit 1
