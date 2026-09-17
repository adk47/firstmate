#!/usr/bin/env bash
# fm-fable-runway-check.sh - the registered watcher check that turns the
# Fable-runway monitor into a `check:` wake only when firstmate should act.
#
# Usage:
#   fm-fable-runway-check.sh [check]   run the poll (silent unless it should wake)
#   fm-fable-runway-check.sh arm       write state/fable-runway.check.sh and bind it
#   fm-fable-runway-check.sh disarm    remove the shim, its trust binding, and the record
#   fm-fable-runway-check.sh --help    print this help
#
# `check` runs bin/fm-fable-runway.sh and prints one line, and only one, when
# one of these is true:
#
#   - either runway state changed since the last printed poll (including the
#     first poll, which is a change from unknown);
#   - the overall state is RED and the last RED report is older than
#     FM_FABLE_RUNWAY_REALERT_SECS (default 3600, 0 disables the repeat). RED is
#     urgent, so it re-surfaces, but the repeat is throttled so a persistent RED
#     cannot storm the wake queue every poll;
# Only a state transition is printable. The pool's membership churns on its own
# - an account crosses 100 percent on some window, a new account is added - and
# none of that is news while both runway states hold, so a change to the capable
# or tracked name set alone never wakes firstmate.
#
# A poll that prints while the pool has just regained a Fable-capable account
# also carries the fail-back label, which names the account and reads `GREEN
# again account=<names>` when the pool is GREEN, or `capacity back
# account=<names>` otherwise. A regain means an account that was Fable-tracked
# but not Fable-capable as of the last printed poll is capable now; an account
# that is merely new to the pool never earns that label, because nothing came
# back.
#
# The membership the label is measured against is therefore the last one
# reported, not the last one observed. A window that resets while the gateway's
# routable count still lags is a normal sequence, and it lands on a silent poll;
# holding the name sets until a line prints is what keeps that regain from being
# consumed without ever being attributed to an account.
#
# The wake therefore always carries both runway states, so firstmate can tell
# whether the Fable credential, the account pool, or both went RED.
#
# The check never switches anything. The failover to Grok and the fail-back to
# Fable are firstmate actions; see docs/runbooks/supervisor-failover-grok.md.
#
# The record state/.fable-runway holds the last printed states, the last RED
# report time, and the Fable-tracked and Fable-capable name sets as of that same
# printed poll, so a silent poll stays silent and a regain is distinguishable
# from an addition.
# `arm` writes a byte-static shim
# that the watcher validates with bin/fm-check-register.sh before it ever
# dispatches it; `disarm` removes the shim, its trust binding, and the record.
# Retire an armed check with `disarm`, never a hand-composed rm.
#
# Test seams: FM_STATE_OVERRIDE selects the state directory and
# FM_FABLE_RUNWAY_NOW freezes the clock. The monitor's own seams pass through.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

CHECK_ID='fable-runway'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.fable-runway"
RECORD_SCHEMA=fm-fable-runway-check-v2
MONITOR="$SCRIPT_DIR/fm-fable-runway.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

now_epoch() {
  case "${FM_FABLE_RUNWAY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FABLE_RUNWAY_NOW" ;;
  esac
}

realert_secs() {
  local n=${FM_FABLE_RUNWAY_REALERT_SECS:-3600}
  case "$n" in
    ''|*[!0-9]*) printf '3600\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# field <name> <line>: print the first `<name>=<token>` value, or nothing.
field() {
  printf '%s\n' "$2" | sed -n "s/.* $1=\\([^ ]*\\).*/\\1/p" | head -n 1
}

record_get() {
  local key=$1
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$RECORD"
}

record_write() {
  local overall=$1 fable=$2 pool=$3 capable=$4 tracked=$5 red_at=$6 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  tmp=$(umask 077; mktemp "$STATE/.fm-fable-runway.XXXXXX" 2>/dev/null) || return 0
  if ! printf 'schema=%s\noverall=%s\nfable_state=%s\npool_state=%s\ncapable=%s\ntracked=%s\nred_at=%s\n' \
    "$RECORD_SCHEMA" "$overall" "$fable" "$pool" "$capable" "$tracked" "$red_at" > "$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  chmod 0600 "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$RECORD" 2>/dev/null || rm -f -- "$tmp"
}

# regained <current-capable> <previous-tracked> <previous-capable>: names that
# the pool tracked but could not use as of the last printed poll and can use
# now, space-separated. An account the pool did not track then is new, not
# recovered, so it is never named here.
regained() {
  local cur=$1 prev_tracked=$2 prev_capable=$3 name out='' IFS=','
  [ "$cur" = none ] && return 0
  [ "$prev_tracked" = none ] && return 0
  for name in $cur; do
    [ -n "$name" ] || continue
    case ",$prev_tracked," in
      *",$name,"*) ;;
      *) continue ;;
    esac
    case ",$prev_capable," in
      *",$name,"*) ;;
      *) out="$out $name" ;;
    esac
  done
  printf '%s\n' "${out# }"
}

action_check() {
  local line='' overall fable pool capable tracked
  line=$("$MONITOR" 2>/dev/null) || true
  if [ -z "$line" ]; then
    line="fable-runway: overall=RED fable_state=RED pool_state=UNKNOWN fable_remaining=unknown% fable_burn=unknownx fable_exhaustion=unknown(unknown) pool_routable=unknown/unknown pool_exhausted=unknown pool_capable=none pool_tracked=none pool_exhaustion=unknown fable_reason=monitor_produced_no_line pool_reason=monitor_unavailable"
  fi
  overall=$(field overall "$line")
  fable=$(field fable_state "$line")
  pool=$(field pool_state "$line")
  capable=$(field pool_capable "$line")
  tracked=$(field pool_tracked "$line")
  case "$overall" in GREEN|YELLOW|RED) ;; *) overall=RED ;; esac
  case "$fable" in GREEN|YELLOW|RED|UNKNOWN) ;; *) fable=RED ;; esac
  case "$pool" in GREEN|YELLOW|RED|UNKNOWN) ;; *) pool=UNKNOWN ;; esac
  [ -n "$capable" ] || capable=none
  [ -n "$tracked" ] || tracked=none

  local last_present=0 last_overall='' last_fable='' last_pool='' last_capable='' last_tracked='' last_red=''
  if record_get schema >/dev/null 2>&1; then
    last_present=1
    last_overall=$(record_get overall)
    last_fable=$(record_get fable_state)
    last_pool=$(record_get pool_state)
    last_capable=$(record_get capable)
    last_tracked=$(record_get tracked)
    last_red=$(record_get red_at)
  fi

  local now changed=0 recovered='' label=''
  now=$(now_epoch)
  # Membership alone is not a transition: only the two runway states and the
  # overall verdict can make a poll printable.
  if [ "$last_present" -eq 0 ] \
    || [ "$overall" != "$last_overall" ] \
    || [ "$fable" != "$last_fable" ] \
    || [ "$pool" != "$last_pool" ]; then
    changed=1
  fi
  if [ "$last_present" -eq 1 ]; then
    [ -n "$last_capable" ] || last_capable=none
    [ -n "$last_tracked" ] || last_tracked=none
    recovered=$(regained "$capable" "$last_tracked" "$last_capable")
  fi
  # A first poll has no prior sets, so nothing can have come back; a recovery
  # label belongs only to a real regain.
  if [ "$last_present" -eq 1 ] && [ -n "$recovered" ]; then
    if [ "$pool" = GREEN ]; then
      label="GREEN again account=$(printf '%s' "$recovered" | tr ' ' ',')"
    else
      label="capacity back account=$(printf '%s' "$recovered" | tr ' ' ',')"
    fi
  fi

  local print=0 last_red_n='' realert=''
  realert=$(realert_secs)
  case "$last_red" in ''|*[!0-9]*) last_red_n='' ;; *) last_red_n=$last_red ;; esac
  if [ "$changed" -eq 1 ]; then
    print=1
  elif [ "$overall" = RED ]; then
    if [ -z "$last_red_n" ]; then
      print=1
    elif [ "$realert" -gt 0 ] && [ "$((now - last_red_n))" -ge "$realert" ]; then
      print=1
    fi
  fi

  local body red_at
  body=${line#fable-runway: }
  if [ "$print" -eq 1 ]; then
    if [ -n "$label" ]; then
      printf 'fable-runway: %s %s\n' "$label" "$body"
    else
      printf '%s\n' "$line"
    fi
  fi
  red_at=$last_red_n
  if [ "$overall" = RED ] && [ "$print" -eq 1 ]; then
    red_at=$now
  elif [ "$overall" != RED ]; then
    red_at=0
  fi
  if [ "$print" -eq 0 ] && [ "$last_present" -eq 1 ]; then
    capable=$last_capable
    tracked=$last_tracked
  fi
  record_write "$overall" "$fable" "$pool" "$capable" "$tracked" "$red_at"
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-fable-runway-check.sh - Fable runway poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-fable-runway-check.sh") check"
}

SHIM_WRITE_TMP=
ARM_BACKUP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-fable-runway-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-fable-runway-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So after a failed or
# interrupted arm the home never holds a shim without a matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-fable-runway-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-fable-runway-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-fable-runway-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-fable-runway-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-fable-runway-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
