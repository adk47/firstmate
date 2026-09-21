#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}

# --- arming a self-registered check -----------------------------------------
#
# The half of the lifecycle that puts a shim in place. Both self-arming checks
# call these rather than carrying their own copy, because the invariant they
# exist to hold is security-relevant: bin/fm-watch.sh dispatches only a shim
# whose bytes the trust binding covers, and a shim without one is not inert -
# the watcher rejects it every cycle and wakes firstmate about unauthenticated
# state checks. One copy is one place to correct.

FM_CUSTOM_CHECK_SHIM_TMP=
FM_CUSTOM_CHECK_ARM_BACKUP=
FM_CUSTOM_CHECK_ARM_STATE=
FM_CUSTOM_CHECK_ARM_ID=
FM_CUSTOM_CHECK_ARM_LABEL=

# The watcher runs the shim from its own working directory, so a relative home
# would send the check to a different home, or to none at all.
fm_custom_check_resolve_home() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) CDPATH='' cd -- "$1" 2>/dev/null && pwd -P ;;
  esac
}

# The guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
fm_custom_check_shim_write() {
  local state=$1 id=$2 prefix=$3 want=$4 shim device tmp
  shim="$state/$id.check.sh"
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || return 1
  if [ -e "$shim" ] && [ "$(fm_pr_file_mode "$shim")" = 700 ] \
    && [ "$(cat "$shim" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$state/$prefix.XXXXXX" 2>/dev/null) || return 1
  FM_CUSTOM_CHECK_SHIM_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    FM_CUSTOM_CHECK_SHIM_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$shim" "$device" \
    || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    FM_CUSTOM_CHECK_SHIM_TMP=
    return 1
  fi
  FM_CUSTOM_CHECK_SHIM_TMP=
  fm_pr_private_file_valid "$shim" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
fm_custom_check_shim_backup() {
  local state=$1 id=$2 prefix=$3 device tmp
  device=$(fm_pr_file_device "$state") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$state/$prefix.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$state/$id.check.sh" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# The one rule after a failed or interrupted arm is that the home never holds a
# shim without a matching trust binding. The shim a working home had is put back
# and kept only when it is still bound; otherwise the shim goes, so the home is
# plainly not armed and the failure is the only thing the operator has to act on.
fm_custom_check_arm_rollback() {
  local state=$1 id=$2
  [ -z "$FM_CUSTOM_CHECK_SHIM_TMP" ] || rm -f -- "$FM_CUSTOM_CHECK_SHIM_TMP"
  FM_CUSTOM_CHECK_SHIM_TMP=
  if [ -n "$FM_CUSTOM_CHECK_ARM_BACKUP" ]; then
    mv -f -- "$FM_CUSTOM_CHECK_ARM_BACKUP" "$state/$id.check.sh" 2>/dev/null \
      || rm -f -- "$FM_CUSTOM_CHECK_ARM_BACKUP"
    FM_CUSTOM_CHECK_ARM_BACKUP=
    if fm_custom_check_registered "$state" "$id"; then
      return 0
    fi
  fi
  rm -f -- "$state/$id.check.sh"
}

# shellcheck disable=SC2329  # Registered by fm_custom_check_arm's signal trap.
fm_custom_check_arm_interrupted() {
  fm_custom_check_arm_rollback "$FM_CUSTOM_CHECK_ARM_STATE" "$FM_CUSTOM_CHECK_ARM_ID"
  printf '%s: arming was interrupted, so state/%s.check.sh is not armed\n' \
    "$FM_CUSTOM_CHECK_ARM_LABEL" "$FM_CUSTOM_CHECK_ARM_ID" >&2
  exit 1
}

# Write the shim and bind its bytes, or leave the home exactly as armed or
# unarmed as it already was. Callers own their own preconditions and their own
# shim bytes; everything after that is the same for every self-arming check.
fm_custom_check_arm() {
  local state=$1 id=$2 prefix=$3 label=$4 register=$5 home=$6 want=$7 shim
  shim="$state/$id.check.sh"
  FM_CUSTOM_CHECK_ARM_STATE=$state
  FM_CUSTOM_CHECK_ARM_ID=$id
  FM_CUSTOM_CHECK_ARM_LABEL=$label
  FM_CUSTOM_CHECK_ARM_BACKUP=
  if [ -f "$shim" ] && [ ! -L "$shim" ]; then
    FM_CUSTOM_CHECK_ARM_BACKUP=$(fm_custom_check_shim_backup "$state" "$id" "$prefix") || {
      printf '%s: could not save the existing %s\n' "$label" "$shim" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap fm_custom_check_arm_interrupted HUP INT TERM
  if ! fm_custom_check_shim_write "$state" "$id" "$prefix" "$want"; then
    trap - HUP INT TERM
    fm_custom_check_arm_rollback "$state" "$id"
    printf '%s: could not write %s\n' "$label" "$shim" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$register" "$id" >/dev/null; then
    trap - HUP INT TERM
    fm_custom_check_arm_rollback "$state" "$id"
    printf '%s: could not register %s\n' "$label" "$shim" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$FM_CUSTOM_CHECK_ARM_BACKUP" ] || rm -f -- "$FM_CUSTOM_CHECK_ARM_BACKUP"
  FM_CUSTOM_CHECK_ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$id"
  return 0
}

# Retire an armed check: the shim, its trust binding, and whatever record the
# check kept. This is the sanctioned retirement path, never a hand-composed rm.
fm_custom_check_disarm() {
  local state=$1 id=$2
  shift 2
  rm -f -- "$state/$id.check.sh" "$state/$id.check-trust" "$@"
  printf 'disarmed: state/%s.check.sh\n' "$id"
  return 0
}
