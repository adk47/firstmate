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
#     REALERT_SECS (3600). RED is urgent, so it re-surfaces, but the repeat is
#     throttled so a persistent RED cannot storm the wake queue every poll. That
#     interval is a fixed constant rather than a knob, because the only thing an
#     override could do is stop a sustained RED from ever being mentioned again;
#   - an account entered pool_needs_auth since the last printed poll. That one
#     is not a runway state at all, and it is printable anyway because it is the
#     failure the captain can simply fix: re-authenticating an account takes a
#     minute and gives the pool a member back, long before any threshold is
#     near. The same transition also posts a macOS notification naming the
#     account, because a wake the supervisor reads on its next turn is not fast
#     enough for something only a human can do.
# Otherwise only a state transition is printable. The pool's membership churns
# on its own - an account crosses 100 percent on some window, a new account is
# added - and none of that is news while both runway states hold, so a change to
# the capable or tracked name set alone never wakes firstmate.
#
# A poll that prints while the pool has just regained a Fable-capable account
# also carries the fail-back label, `capacity back account=<names>`, which names
# the account. There is one spelling of it, because the same line already
# carries pool_state= verbatim. A regain means an account that was Fable-tracked
# but not Fable-capable as of the last printed poll is capable now; an account
# that is merely new to the pool never earns that label, because nothing came
# back.
#
# The membership the label is measured against is therefore the last one
# reported, not the last one observed. A window that resets while the gateway's
# routable count still lags is a normal sequence, and it lands on a silent poll;
# holding the name sets until a line prints is what keeps that regain from being
# consumed without ever being attributed to an account. A poll whose pool is
# UNKNOWN holds them too, even though it prints: an unreadable pool observed no
# membership at all, and reading its `none` as an empty pool would consume a
# pending regain the same way.
#
# The wake therefore always carries both runway states, so firstmate can tell
# whether the Fable credential, the account pool, or both went RED.
#
# The check never switches anything. The failover to Grok and the fail-back to
# Fable are firstmate actions; see docs/runbooks/supervisor-failover-grok.md.
#
# There is one exception, and it is the case where waiting for a model turn
# costs the most: an overall RED with no Fable-capable account left. The seat
# has to move, and the runway that would have paid for the turn that noticed is
# the one that ran out. So the check hands that episode to
# bin/fm-fable-runway-alert.sh, which is plain bash - a durable handoff note, a
# doorbell to the Grok terminal, a desktop notification, once per episode. It
# still prints its line; the helper is what happens without waiting for it.
#
# The record state/.fable-runway holds the last printed states, the last RED
# report time, and the Fable-tracked, Fable-capable and needs-authentication
# name sets as of that same printed poll, so a silent poll stays silent, a
# regain is distinguishable from an addition, and an account that already wanted
# a login does not ask again every poll. It is stamped with its schema, and a
# record carrying any other stamp is treated as no record at all rather than
# read under the wrong field layout.
#
# `arm` writes a byte-static shim that the watcher validates with
# bin/fm-check-register.sh before it ever dispatches it; `disarm` removes the
# shim, its trust binding, and the record. Both go through the shared lifecycle
# in bin/fm-check-lib.sh, so the rule that a home never holds a shim without a
# matching trust binding has one implementation. Retire an armed check with
# `disarm`, never a hand-composed rm.
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
RECORD="$STATE/.fable-runway"
RECORD_SCHEMA=fm-fable-runway-check-v3
REALERT_SECS=3600
MONITOR="$SCRIPT_DIR/fm-fable-runway.sh"
ALERT="$SCRIPT_DIR/fm-fable-runway-alert.sh"
HANDOFF_MARKER="$STATE/.fable-runway-handoff"
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
  local overall=$1 fable=$2 pool=$3 capable=$4 tracked=$5 needs_auth=$6 red_at=$7 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  tmp=$(umask 077; mktemp "$STATE/.fm-fable-runway.XXXXXX" 2>/dev/null) || return 0
  if ! printf 'schema=%s\noverall=%s\nfable_state=%s\npool_state=%s\ncapable=%s\ntracked=%s\nneeds_auth=%s\nred_at=%s\n' \
    "$RECORD_SCHEMA" "$overall" "$fable" "$pool" "$capable" "$tracked" "$needs_auth" "$red_at" > "$tmp"; then
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

# entered <current> <previous>: comma-list members of current that the previous
# set did not hold, space-separated.
entered() {
  local cur=$1 prev=$2 name out='' IFS=','
  [ "$cur" = none ] && return 0
  for name in $cur; do
    [ -n "$name" ] || continue
    case ",$prev," in
      *",$name,"*) ;;
      *) out="$out $name" ;;
    esac
  done
  printf '%s\n' "${out# }"
}

# The helper owns everything that leaves this process, and nothing it does may
# decide whether the check reports: a missing orca, a missing osascript or an
# unwritable note costs its own step and never the poll.
alert() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$ALERT" "$@" >/dev/null 2>&1 || true
}

action_check() {
  local line='' overall fable pool capable tracked needs_auth
  line=$("$MONITOR" 2>/dev/null) || true
  if [ -z "$line" ]; then
    line="fable-runway: overall=RED fable_state=RED pool_state=UNKNOWN fable_remaining=unknown% fable_burn=unknownx fable_exhaustion=unknown(unknown) pool_routable=unknown/unknown pool_exhausted=unknown pool_capable=none pool_tracked=none pool_unprojected=none pool_needs_auth=none pool_exhaustion=unknown fable_reason=monitor_produced_no_line pool_reason=monitor_unavailable"
  fi
  overall=$(field overall "$line")
  fable=$(field fable_state "$line")
  pool=$(field pool_state "$line")
  capable=$(field pool_capable "$line")
  tracked=$(field pool_tracked "$line")
  needs_auth=$(field pool_needs_auth "$line")
  case "$overall" in GREEN|YELLOW|RED) ;; *) overall=RED ;; esac
  case "$fable" in GREEN|YELLOW|RED|UNKNOWN) ;; *) fable=RED ;; esac
  case "$pool" in GREEN|YELLOW|RED|UNKNOWN) ;; *) pool=UNKNOWN ;; esac
  [ -n "$capable" ] || capable=none
  [ -n "$tracked" ] || tracked=none
  [ -n "$needs_auth" ] || needs_auth=none

  local last_present=0 last_overall='' last_fable='' last_pool='' last_capable='' last_tracked='' last_auth='' last_red=''
  if [ "$(record_get schema 2>/dev/null)" = "$RECORD_SCHEMA" ]; then
    last_present=1
    last_overall=$(record_get overall)
    last_fable=$(record_get fable_state)
    last_pool=$(record_get pool_state)
    last_capable=$(record_get capable)
    last_tracked=$(record_get tracked)
    last_auth=$(record_get needs_auth)
    last_red=$(record_get red_at)
  fi

  local now changed=0 recovered='' label='' wants_auth=''
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
    [ -n "$last_auth" ] || last_auth=none
    recovered=$(regained "$capable" "$last_tracked" "$last_capable")
    # An unreadable pool named no account at all, so it has observed no
    # transition into needing a login either.
    if [ "$pool" != UNKNOWN ]; then
      wants_auth=$(entered "$needs_auth" "$last_auth")
    fi
  fi
  [ -z "$wants_auth" ] || changed=1
  # A first poll has no prior sets, so nothing can have come back; a recovery
  # label belongs only to a real regain.
  if [ "$last_present" -eq 1 ] && [ -n "$recovered" ]; then
    label="capacity back account=$(printf '%s' "$recovered" | tr ' ' ',')"
  fi

  local print=0 last_red_n=''
  case "$last_red" in ''|*[!0-9]*) last_red_n='' ;; *) last_red_n=$last_red ;; esac
  if [ "$changed" -eq 1 ]; then
    print=1
  elif [ "$overall" = RED ]; then
    if [ -z "$last_red_n" ]; then
      print=1
    elif [ "$((now - last_red_n))" -ge "$REALERT_SECS" ]; then
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
  if [ "$last_present" -eq 1 ] && { [ "$print" -eq 0 ] || [ "$pool" = UNKNOWN ]; }; then
    capable=$last_capable
    tracked=$last_tracked
    needs_auth=$last_auth
  fi
  record_write "$overall" "$fable" "$pool" "$capable" "$tracked" "$needs_auth" "$red_at"
  # The seat cannot wait for a model turn to notice that there is nothing left
  # to serve Fable from, so the episode is handed to the plain-bash helper here
  # and closed again the first poll the condition lifts.
  if [ "$overall" = RED ] && [ "$(field pool_capable "$line")" = none ]; then
    alert handoff "$line"
  else
    alert resolve
  fi
  [ -z "$wants_auth" ] || alert needs-auth "$(printf '%s' "$wants_auth" | tr ' ' ',')" "$line"
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

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-fable-runway-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-fable-runway-check \
    fm-fable-runway-check "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD" "$HANDOFF_MARKER"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
