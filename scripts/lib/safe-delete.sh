#!/usr/bin/env bash
# safe-delete.sh — sourceable guarded-removal primitives for anything that
# deletes on a prod host. Extracted from sweep-workspace-clones.sh so every
# deleter shares ONE implementation (weekly-cleanup.sh's clean_tmp used a bare
# rm -rf with no open-handle check).
#
#   safe_delete_has_open_handle <path>   0 = held (or could not tell), 1 = free
#   safe_delete_path <path>              guarded removal; echoes freed KB
#
# Lower-level pieces (path_id, id_stable, mount_hazard, is_mountpoint,
# quarantine, restore, rm_quarantined) are public so sweep-workspace-clones.sh
# can run its clone policy audit between quarantine and rm.
#
# Fail closed everywhere: a probe that errors is "held", never "free".
# No side effects at source time beyond one rm --one-file-system probe.
#
# Seams (read at call time, for hermetic tests):
#   SAFE_DELETE_MOUNTS_FILE        default /proc/self/mounts
#   SAFE_DELETE_QUARANTINE_PREFIX  default .safe-delete-quarantine.
#   SAFE_DELETE_HANDLE_CHECK       function used for the post-quarantine handle
#                                  scan; default safe_delete_has_open_handle
#   safe_delete_on_restored        optional hook <original-path>, after a restore
#   safe_delete_on_restore_blocked optional hook <quarantined-path>, called
#                                  when a restore is refused (name retaken)
# Out-vars: SD_QPATH SD_QDIR (quarantine), SD_ERROR (last refusal reason).

# GNU rm has --one-file-system (prod / CI); BSD rm (dev laptops) does not.
# mount_hazard is the primary rail either way — this is the backstop.
SAFE_DELETE_RM_ONEFS=()
if rm --one-file-system -rf "$(mktemp -d)" 2>/dev/null; then
  SAFE_DELETE_RM_ONEFS=(--one-file-system)
fi

# True if $1 IS a mountpoint or any mountpoint lives under it. The exact-match
# case matters: rm --one-file-system treats a command-line argument that is
# itself a mountpoint as that filesystem's root and would wipe its contents.
safe_delete_mount_hazard() {
  local mounts="${SAFE_DELETE_MOUNTS_FILE:-/proc/self/mounts}"
  # Cannot inspect the mount table → cannot prove absence of a mount → hazard.
  [ -r "$mounts" ] || return 0
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
    END { exit found ? 0 : 1 }' "$mounts"
}

# True only if $1 IS ITSELF a mountpoint — EXACT match, no "or under". A swept
# ROOT needs this narrower form: mount_hazard's "anything beneath" reading
# would refuse a whole lane the moment one candidate is a mount. An unreadable
# table returns false here on purpose — the per-candidate mount_hazard is
# already fail-closed, so this rail must not also abort the run.
safe_delete_is_mountpoint() {
  local mounts="${SAFE_DELETE_MOUNTS_FILE:-/proc/self/mounts}"
  [ -r "$mounts" ] || return 1
  MP_P="$1" awk '
    {
      m = $2
      gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m)
      gsub(/\\012/, "\n", m); gsub(/\\134/, "\\", m)
      if (m == ENVIRON["MP_P"]) found = 1
    }
    END { exit found ? 0 : 1 }' "$mounts"
}

# Full identity of a path WITHOUT dereferencing symlinks (GNU stat -c, BSD
# stat -f): device, inode, mtime, ctime, size. Empty when it cannot be read,
# which the removal gate treats as a mismatch.
#
# device:inode ALONE is not enough — unlink+create in the same directory
# hands the new object the just-freed inode number on ext4, so a replacement
# compares equal. ctime closes it: the kernel sets it on every inode change
# and NO userspace API can set it, so a replacement cannot carry the stale
# one's ctime. mtime and size are cheap corroboration in the same call.
# NANOSECOND forms deliberately: GNU %Y/%Z and BSD %m/%c are whole SECONDS, so
# a replacement created in the same second compares equal when the inode is
# reused. GNU %y/%z and BSD %Fm/%Fc carry the full ns timestamp. '|' separates
# the fields: the ns timestamps contain both ':' and ' '.
safe_delete_path_id() {
  stat -c '%d|%i|%y|%z|%s' -- "$1" 2>/dev/null \
    || stat -f '%d|%i|%Fm|%Fc|%z' -- "$1" 2>/dev/null \
    || true
}

# The rename-INVARIANT subset of a path_id: device, inode, mtime, size.
# rename(2) bumps ctime, so the post-quarantine check must drop that field
# while the pre-quarantine check keeps it.
safe_delete_id_stable() {  # <path_id>
  local dev ino mtime ctime size
  # shellcheck disable=SC2034  # ctime is parsed precisely so it can be DROPPED
  IFS='|' read -r dev ino mtime ctime size <<< "$1"
  printf '%s|%s|%s|%s' "$dev" "$ino" "$mtime" "$size"
}

# 0 if any process holds a handle on <path> or anything under it, or has its
# cwd there. An lsof error or a missing lsof is "held": we cannot prove
# absence of a writer. One whole-system lsof pass filtered by prefix, rather
# than +D, which stats every file in the candidate tree.
safe_delete_has_open_handle() {  # <path>
  local p="$1" dir out
  command -v lsof >/dev/null 2>&1 || return 0
  # lsof prints physical paths: resolve the parent so /tmp -> /private/tmp
  # style aliases cannot hide a handle. The leaf is never dereferenced.
  dir="$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd)" || return 0
  p="${dir%/}/$(basename -- "$p")"
  out="$(lsof -n -P -w -F n 2>/dev/null)" || return 0
  printf '%s\n' "$out" | HP_P="$p" awk '
    substr($0, 1, 1) == "n" {
      n = substr($0, 2)
      if (n == ENVIRON["HP_P"] || index(n, ENVIRON["HP_P"] "/") == 1) found = 1
    }
    END { exit found ? 0 : 1 }'
}

# Put it back, NEVER clobbering a name another writer has retaken. GNU mv -n
# exits 0 when it declines, so the move is proven rather than assumed.
# Nonzero = left quarantined: reported on stderr and in SD_ERROR; the optional
# hook lets the caller account it too.
safe_delete_restore() {  # <quarantined> <original> <qdir>
  local want
  want="$(safe_delete_id_stable "$(safe_delete_path_id "$1")")"
  # mv -n onto a retaken DIRECTORY name nests the object inside it and exits 0,
  # so a taken name is refused up front. A writer can still win the race between
  # that check and the mv, so the landed object's identity is verified and a
  # nested one is moved back out rather than reported as restored.
  if [ ! -e "$2" ] && [ ! -L "$2" ] && mv -n -- "$1" "$2" 2>/dev/null && [ ! -e "$1" ] && [ ! -L "$1" ]; then
    if [ "$(safe_delete_id_stable "$(safe_delete_path_id "$2")")" = "$want" ]; then
      rmdir "$3" 2>/dev/null || true
      if declare -F safe_delete_on_restored >/dev/null; then safe_delete_on_restored "$2"; fi
      return 0
    fi
    # A mismatch alone is not a nest (a live writer can touch the tree's mtime):
    # only undo when the child at the nested path really is the object.
    local nested; nested="$2/$(basename -- "$1")"
    if [ -e "$nested" ] && [ "$(safe_delete_id_stable "$(safe_delete_path_id "$nested")")" = "$want" ]; then
      if ! mv -n -- "$nested" "$1" 2>/dev/null; then
        SD_ERROR="${SD_ERROR:+$SD_ERROR; }restore blocked, object nested at $nested"
        echo "safe-delete: $SD_ERROR" >&2
        return 1
      fi
    else
      rmdir "$3" 2>/dev/null || true
      if declare -F safe_delete_on_restored >/dev/null; then safe_delete_on_restored "$2"; fi
      return 0
    fi
  fi
  # Never silent: the object now sits under a random name nobody was told about.
  SD_ERROR="${SD_ERROR:+$SD_ERROR; }restore blocked, object left quarantined at $1"
  echo "safe-delete: $SD_ERROR" >&2
  if declare -F safe_delete_on_restore_blocked >/dev/null; then
    safe_delete_on_restore_blocked "$1"
  fi
  return 1
}

# Take the candidate OUT of the namespace, atomically. The target must be
# GUARANTEED-private, not merely unlikely to collide: leftovers are retained
# forever by design, so a recurring name (a PID, a timestamp) could already
# exist and mv would then overwrite a held file or nest inside a held
# directory. mktemp -d creates the sibling exclusively, in the same directory
# and therefore the same filesystem — no cross-device copy fallback, which a
# deletion path must never do.
safe_delete_quarantine() {  # <path> <id-at-classification>
  local p="$1" id="$2" qdir q err
  local handle_check="${SAFE_DELETE_HANDLE_CHECK:-safe_delete_has_open_handle}"
  SD_QPATH=""; SD_QDIR=""; SD_ERROR=""
  qdir="$(mktemp -d "$(dirname -- "$p")/${SAFE_DELETE_QUARANTINE_PREFIX:-.safe-delete-quarantine.}XXXXXX" 2>/dev/null)" || {
    SD_ERROR="could not create a private sibling directory"
    return 1
  }
  q="$qdir/$(basename -- "$p")"
  err="$(mv -- "$p" "$q" 2>&1)" || {
    SD_ERROR="quarantine rename failed: ${err:0:120}"
    rmdir "$qdir" 2>/dev/null || true
    return 1
  }
  # Explicit move verification — never infer the outcome from mv's exit status
  # alone. -e is false for a dangling symlink, so -L is its companion.
  if { [ ! -e "$q" ] && [ ! -L "$q" ]; } || [ -e "$p" ] || [ -L "$p" ]; then
    SD_ERROR="quarantine rename did not land at $q"
    rmdir "$qdir" 2>/dev/null || true
    return 1
  fi
  # rename(2) bumps ctime, so compare the rename-invariant subset.
  if [ -z "$id" ] || [ "$(safe_delete_id_stable "$(safe_delete_path_id "$q")")" != "$(safe_delete_id_stable "$id")" ]; then
    SD_ERROR="object replaced before removal"
    safe_delete_restore "$q" "$p" "$qdir" || true
    return 1
  fi
  # No new handle can be acquired from here (the name is private), so this one
  # scan settles it: if nobody holds the tree open now, nobody will.
  if "$handle_check" "$q"; then
    SD_ERROR="live process holds the tree open (cwd or open fd)"
    safe_delete_restore "$q" "$p" "$qdir" || true
    return 1
  fi
  # A bind mount shares st_dev, so --one-file-system would cross it: re-read
  # the mount table now that the name is private and nothing can add one.
  if safe_delete_mount_hazard "$q"; then
    SD_ERROR="mount appeared under the path after quarantine"
    safe_delete_restore "$q" "$p" "$qdir" || true
    return 1
  fi
  SD_QPATH="$q"; SD_QDIR="$qdir"
  return 0
}

# rm the private name and its quarantine directory. Nonzero = rm failed
# (SD_ERROR carries the message); the object stays quarantined.
safe_delete_rm_quarantined() {  # <quarantined> <qdir> <is-tree>
  local q="$1" qdir="$2" is_tree="$3" err rm_cmd
  SD_ERROR=""
  rm_cmd=(rm -f --)
  if [ "$is_tree" -eq 1 ]; then
    # ${arr[@]+...}: safe under set -u with an empty array on bash 3.2 (macOS dev).
    rm_cmd=(rm -rf ${SAFE_DELETE_RM_ONEFS[@]+"${SAFE_DELETE_RM_ONEFS[@]}"} --)
  fi
  err="$("${rm_cmd[@]}" "$q" 2>&1)" || {
    SD_ERROR="rm failed: ${err:0:200}"
    return 1
  }
  rmdir "$qdir" 2>/dev/null || true
}

# Full guarded removal of <path>. Echoes freed KB on success. On refusal
# nothing is deleted, the reason goes to stderr (and SD_ERROR), return 1.
safe_delete_path() {  # <path>
  local p="$1" id now_id kb is_tree=0
  SD_ERROR=""
  while [ -n "$p" ] && [ "$p" != "${p%/}" ]; do p="${p%/}"; done
  if [ -z "$p" ]; then
    SD_ERROR="refusing empty or root path"
  elif [ ! -e "$p" ] && [ ! -L "$p" ]; then
    SD_ERROR="no such path"
  fi
  if [ -n "$SD_ERROR" ]; then echo "safe-delete: refused '$1': $SD_ERROR" >&2; return 1; fi

  # A symlink is unlinked, never followed.
  if [ -L "$p" ]; then
    if rm -f -- "$p"; then echo 0; return 0; fi
    SD_ERROR="could not unlink symlink"
    echo "safe-delete: refused '$p': $SD_ERROR" >&2; return 1
  fi

  if safe_delete_mount_hazard "$p"; then
    SD_ERROR="mountpoint at or under the path (or mount table unreadable)"
  elif safe_delete_has_open_handle "$p"; then
    SD_ERROR="open handle (or the handle probe failed)"
  else
    id="$(safe_delete_path_id "$p")"
    [ -n "$id" ] || SD_ERROR="could not stat the path"
  fi
  if [ -z "$SD_ERROR" ]; then
    if [ -d "$p" ]; then is_tree=1; fi
    kb="$(du -skx -- "$p" 2>/dev/null | awk '{print $1}' || true)"
    kb="${kb:-0}"
    # The object may have been swapped during the du pass: same name, but
    # none of the guards above ever saw the new one.
    now_id="$(safe_delete_path_id "$p")"
    if [ -z "$now_id" ] || [ "$id" != "$now_id" ]; then
      SD_ERROR="path identity changed since classification"
    fi
  fi
  if [ -z "$SD_ERROR" ]; then
    safe_delete_quarantine "$p" "$id" || true
  fi
  if [ -z "$SD_ERROR" ]; then
    safe_delete_rm_quarantined "$SD_QPATH" "$SD_QDIR" "$is_tree" || true
  fi
  if [ -n "$SD_ERROR" ]; then
    echo "safe-delete: refused '$p': $SD_ERROR" >&2
    return 1
  fi
  echo "$kb"
}
