#!/usr/bin/env bash
# fm-lane-model-switch.sh - switch ONE live lane's model in place, safely.
#
# WHY THIS IS NOT A BROADCAST: `fm-send` types into whatever the composer
# already holds, so appending `/model <spec>` to unsubmitted text and pressing
# Enter would submit that text instead. A lane was once holding a destructive
# authorization when a fleet-wide switch was composed. This script therefore
# handles exactly one lane, captures what the composer holds before it touches
# anything, and REFUSES rather than forcing when the composer cannot be proven
# empty.
#
# THE PROCEDURE (the composer-safe shape proven on the 2026-09-05 Opus 5
# switch, generalized to any model spec):
#   1. read the lane's screen and save whatever the composer holds
#   2. clear the composer only when it is not proven empty
#   3. VERIFY EMPTY - never send `/model` without this
#   4. send `/model <spec>` through the target backend's verified submit core
#   5. verify the switch landed on the rendered screen
#   6. kick the lane back to work
# A lane whose composer will not verify empty is refused, not forced. Step 2 is
# skipped when step 1 already proved the composer empty, because a Ctrl-C
# against a lane mid-turn would cancel live work for no reason.
#
# WHY IN PLACE: `/loop`, `CronCreate`, and the fleet's other scheduled
# surfaces live in Claude Code's own session memory. Relaunching a lane on a
# different runtime silently loses its schedule, so a lane that owns ticks is
# switched inside its running session instead.
#
# --gateway: records a durable repoint of the lane at the second local
# Anthropic-compatible gateway (bin/fm-deepseek-gateway.sh), which is what
# serves DeepSeek V4.1 Flash under the model id Claude Code discovers. Claude
# Code reads its endpoint from the environment at startup, so the repoint
# takes effect on that lane's NEXT launch; a lane already pointed at the
# gateway needs no relaunch. The one record of that repoint is
# state/<id>.gateway.env (mode 0600), the exact exports whoever launches that
# lane next sources; state/<id>.meta carries only the `model_switch_gateway=`
# audit line. That gateway is loopback-only, so its port is the gateway
# script's own default (FM_DEEPSEEK_GATEWAY_PORT, default 8799) and there is
# nothing to point at a different host. A plain switch with no --gateway never
# touches state/<id>.gateway.env: it changes the model, not the endpoint.
# The live session's `/model` step still runs and still has to verify, so a
# lane whose current endpoint cannot serve the gateway model fails loudly
# instead of silently reporting success.
#
# TICKS: a model switch can skip the next scheduled tick, so after a verified
# switch this prints the lane's next expected tick when the home records one -
# either `cron=<expr>` lines in state/<id>.meta or one expression per line in
# data/<id>/crons - and says so explicitly when it records none. Verify the
# tick actually fires; that is the one thing the switch itself cannot prove.
#
# Usage:
#   fm-lane-model-switch.sh <task-id> <model-spec> [options]
#
#   <model-spec>   what to send after /model: `opus`, `opus[1m]`, a gateway
#                  model id, or the literal `gateway` for the model the second
#                  gateway advertises.
#
# Options:
#   --gateway           also repoint the lane at the second gateway on
#                       http://127.0.0.1:$FM_DEEPSEEK_GATEWAY_PORT (8799)
#   --verify <regex>    screen regex that confirms the switch landed
#                       (default: the model spec, or `Opus` for opus specs)
#   --kick <text>       resume text sent after a verified switch
#   --no-kick           do not send resume text
#   --tick-file <path>  tick registry to read (default data/<id>/crons)
#   --now <ISO8601Z>    reference time for next-tick output (testing)
#   --dry-run           perform every check and print the plan, send nothing
#   --json              print one machine-readable summary line as well
#
# Exit codes: 0 switched and verified (or a clean --dry-run); 1 the switch
# could not be completed or verified, or the gateway is not healthy; 2 a
# refusal that sent nothing - a non-Claude lane, a remote lane, an unreadable
# screen, or a composer that would not verify empty.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Fail closed before touching a live lane: this script types into a running
# crewmate's pane and records into that lane's metadata, which is exactly the
# fleet-lifecycle authority a no-mistakes gate agent must never have
# (bin/fm-gate-refuse-lib.sh owns the contract and both signals).
fm_refuse_if_gate_agent

GATEWAY_SH="$SCRIPT_DIR/fm-deepseek-gateway.sh"
DEFAULT_GATEWAY_PORT="${FM_DEEPSEEK_GATEWAY_PORT:-8799}"
DEFAULT_GATEWAY_URL="http://127.0.0.1:$DEFAULT_GATEWAY_PORT"
SAVE_ROOT="$DATA/lane-model-switch"
SEND_RETRIES="${FM_LANE_SWITCH_RETRIES:-3}"
SEND_SLEEP="${FM_LANE_SWITCH_SLEEP:-0.4}"
SLASH_SETTLE="${FM_LANE_SWITCH_SETTLE:-1.2}"
# Pause after an interrupt or a /model submit so the lane has redrawn before the
# next read. Tests shorten it; a real lane needs the redraw.
SWITCH_PAUSE="${FM_LANE_SWITCH_PAUSE:-2}"
BASELINE_SCREEN=''

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {  # <message>
  printf 'fm-lane-model-switch: %s\n' "$1" >&2
  exit 1
}

refuse() {  # <message>
  printf 'fm-lane-model-switch: %s\n' "$1" >&2
  exit 2
}

utc_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

validate_id() {  # <task-id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) refuse "task id must be a non-empty slug: ${1:-<empty>}" ;;
  esac
}

# --- gateway ----------------------------------------------------------------

gateway_model() {
  "$GATEWAY_SH" model 2>/dev/null || fail "could not read the gateway's advertised model id"
}

require_gateway_healthy() {  # <port>
  [ -x "$GATEWAY_SH" ] || fail "gateway lifecycle script is missing: $GATEWAY_SH"
  "$GATEWAY_SH" health --port "$1" >/dev/null 2>&1 \
    || fail "the second gateway is not healthy on port $1; start it with '$GATEWAY_SH start' before repointing a lane at it"
}

# --- lane resolution --------------------------------------------------------

resolve_lane() {  # sets LANE_META LANE_TARGET LANE_BACKEND LANE_LABEL LANE_HARNESS
  local id=$1 meta="$STATE/$1.meta" remote=''
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "no task metadata for $id at $meta"
  remote=$(fm_meta_get "$meta" remote_host)
  [ -z "$remote" ] \
    || refuse "$id is a remote secondmate on $remote; an in-place model switch cannot reach that endpoint from this home"
  LANE_HARNESS=$(fm_meta_get "$meta" harness)
  case "$LANE_HARNESS" in
    claude|claude-*) ;;
    *) refuse "$id runs harness '${LANE_HARNESS:-unknown}'; only a Claude Code lane accepts a /model switch" ;;
  esac
  LANE_BACKEND=$(fm_backend_of_meta "$meta")
  LANE_TARGET=$(fm_backend_target_of_meta "$meta")
  [ -n "$LANE_TARGET" ] || fail "no backend endpoint recorded in $meta"
  fm_backend_validate "$LANE_BACKEND" || fail "backend '$LANE_BACKEND' is not available on this host"
  LANE_LABEL=$(fm_backend_expected_label_of_selector "$id" "$STATE")
  LANE_META=$meta
}

lane_model_now() {  # <meta>
  local model
  model=$(fm_meta_get "$1" model)
  printf '%s' "${model:--}"
}

# --- screen capture and composer safety -------------------------------------

save_capture() {  # <kind> <text>
  local kind=$1 text=$2 dir file
  dir="$SAVE_ROOT/$kind"
  (umask 077; mkdir -p "$dir") || fail "cannot create $dir"
  file="$dir/$LANE_ID-$(utc_stamp).txt"
  printf '%s\n' "$text" > "$file" || fail "cannot write $file"
  printf '%s' "$file"
}

composer_verdict() {  # prints empty|pending|pending-unproven|unknown
  fm_backend_composer_state "$LANE_BACKEND" "$LANE_TARGET" "$LANE_LABEL" 2>/dev/null || printf 'unknown'
}

send_typed() {  # <text> <settle>; prints the submit verdict
  fm_backend_send_text_submit "$LANE_BACKEND" "$LANE_TARGET" "$1" "$SEND_RETRIES" "$SEND_SLEEP" "$2" "$LANE_LABEL" 2>/dev/null \
    || printf 'send-failed'
}

send_key() {  # <key>
  fm_backend_send_key "$LANE_BACKEND" "$LANE_TARGET" "$1" "$LANE_LABEL" >/dev/null 2>&1
}

# --- verification -----------------------------------------------------------

# Claude Code renders the `/model <spec>` this script just typed straight back
# into its transcript, so the post-submit screen always contains the model name
# whether or not the client accepted it. A confirmation is therefore only
# believed on a line that BOTH is new since the pre-submit capture and is not
# that echo - the script's own input can never satisfy its own proof.
confirmation_lines() {  # <screen>; prints the lines a confirmation may come from
  local screen=$1 lines
  lines=$screen
  if [ -n "$BASELINE_SCREEN" ]; then
    lines=$(printf '%s\n' "$lines" | grep -vxF -- "$BASELINE_SCREEN" || true)
  fi
  printf '%s\n' "$lines" | grep -vF -- "/model $MODEL_SPEC" || true
}

screen_confirms() {  # <screen>; 0 when the switch is confirmed on screen
  local screen candidates base marker
  candidates=$(confirmation_lines "$1")
  screen=$candidates
  if [ -n "$VERIFY_REGEX" ]; then
    printf '%s\n' "$screen" | grep -qiE -- "$VERIFY_REGEX"
    return
  fi
  base=${MODEL_SPEC%%\[*}
  if printf '%s\n' "$screen" | grep -qiF -- "$base"; then
    # A spec carrying the 1M marker is only half-confirmed by the model name:
    # the window marker is the other half, and either spelling is accepted.
    case "$MODEL_SPEC" in
      *'[1m]'*)
        marker=${MODEL_SPEC##*\[}
        marker=${marker%%\]*}
        printf '%s\n' "$screen" | grep -qiE -- "1 ?M|1 million|\[${marker}\]" && return 0
        printf 'fm-lane-model-switch: the model name is on screen but no 1M window marker is; treat the switch as unconfirmed\n' >&2
        return 1
        ;;
    esac
    return 0
  fi
  return 1
}

# --- meta recording ---------------------------------------------------------

record_meta() {  # <before> <after> <gateway>
  local before=$1 after=$2 gateway=$3
  local lock tmp line
  lock=$(fm_meta_lock_path "$LANE_META") || fail "cannot resolve the metadata lock for $LANE_ID"
  fm_lock_acquire_wait "$lock"
  tmp=$(umask 077; mktemp "$STATE/.fm-lane-model-switch-meta.XXXXXX") \
    || { fm_lock_release "$lock"; fail "cannot stage the metadata update"; }
  if ! {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        model=*|model_switch_*) ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$LANE_META"
    {
      printf 'model=%s\n' "$after"
      printf 'model_switch_at=%s\n' "$(utc_stamp)"
      printf 'model_switch_from=%s\n' "$before"
      printf 'model_switch_to=%s\n' "$after"
      printf 'model_switch_gateway=%s\n' "${gateway:--}"
    } >> "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$LANE_META"
  }; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    fail "could not record the switch in $LANE_META"
  fi
  fm_lock_release "$lock"
}

write_gateway_env() {  # <port>; prints the env file path
  local port=$1 file
  file="$STATE/$LANE_ID.gateway.env"
  (umask 077; "$GATEWAY_SH" env --port "$port" > "$file") \
    || fail "could not write $file"
  chmod 0600 "$file" 2>/dev/null || true
  printf '%s' "$file"
}

# --- ticks ------------------------------------------------------------------

tick_lines() {  # prints one cron expression per line, if the home records any
  local meta=$1 registry=$2
  grep '^cron=' "$meta" 2>/dev/null | cut -d= -f2- || true
  if [ -f "$registry" ] && [ ! -L "$registry" ]; then
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$registry"
  fi
}

next_tick() {  # <cron-expression> <now-iso>; prints "<ISO>|<minutes>" or a reason
  python3 - "$1" "$2" <<'PY'
import datetime, sys

def field_set(spec, lo, hi):
    out = set()
    for part in spec.split(','):
        if not part:
            raise ValueError('empty field')
        step = 1
        if '/' in part:
            part, _, step_text = part.partition('/')
            step = int(step_text)
            if step <= 0:
                raise ValueError('bad step')
        if part == '*':
            first, last = lo, hi
        elif '-' in part:
            first_text, _, last_text = part.partition('-')
            first, last = int(first_text), int(last_text)
        else:
            first = last = int(part)
        if first > last or first < lo or last > hi:
            raise ValueError('out of range')
        for value in range(first, last + 1, step):
            out.add(value)
    return out

expr = sys.argv[1].split()
if len(expr) != 5:
    print('unparsable cron expression (expected 5 fields): %s' % sys.argv[1])
    sys.exit(0)
try:
    minutes = field_set(expr[0], 0, 59)
    hours = field_set(expr[1], 0, 23)
    days = field_set(expr[2], 1, 31)
    months = field_set(expr[3], 1, 12)
    weekdays = set(v % 7 for v in field_set(expr[4], 0, 7))
except ValueError as exc:
    print('unparsable cron expression (%s): %s' % (exc, sys.argv[1]))
    sys.exit(0)
day_restricted = expr[2] != '*'
weekday_restricted = expr[4] != '*'

now = datetime.datetime.strptime(sys.argv[2], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
cursor = (now + datetime.timedelta(minutes=1)).replace(second=0, microsecond=0)
limit = cursor + datetime.timedelta(days=366)
while cursor < limit:
    day_ok = cursor.day in days and cursor.month in months
    weekday_ok = (cursor.weekday() + 1) % 7 in weekdays
    if day_restricted and weekday_restricted:
        # Standard cron: with both day fields restricted, either one matching
        # is enough; otherwise the two are combined.
        day_ok = day_ok or weekday_ok
    else:
        day_ok = day_ok and weekday_ok
    if not day_ok:
        cursor = (cursor + datetime.timedelta(days=1)).replace(hour=0, minute=0)
        continue
    if cursor.hour not in hours:
        cursor = (cursor + datetime.timedelta(hours=1)).replace(minute=0)
        continue
    if cursor.minute not in minutes:
        cursor = cursor + datetime.timedelta(minutes=1)
        continue
    print('%s|%d' % (cursor.strftime('%Y-%m-%dT%H:%M:%SZ'), int((cursor - now).total_seconds() // 60)))
    sys.exit(0)
print('no fire time within a year')
PY
}

report_next_tick() {  # <registry>
  local registry=$1 lines line when minutes count=0
  local now=${FM_LANE_SWITCH_NOW:-$(utc_stamp)}
  lines=$(tick_lines "$LANE_META" "$registry")
  if [ -z "$lines" ]; then
    printf 'next-tick: no tick source recorded for %s; add cron=<expr> lines to %s or a %s file, then verify the lane actually fires (a model switch can skip the next tick)\n' \
      "$LANE_ID" "$LANE_META" "$registry"
    NEXT_TICK=''
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    when=$(next_tick "$line" "$now")
    count=$((count + 1))
    case "$when" in
      *'|'*)
        minutes=${when##*|}
        when=${when%%|*}
        if [ "$count" = 1 ]; then NEXT_TICK=$when; fi
        printf 'next-tick: %s -> %s (in %s min) - verify it fires\n' "$line" "$when" "$minutes"
        ;;
      *)
        if [ "$count" = 1 ]; then NEXT_TICK=''; fi
        printf 'next-tick: %s -> %s\n' "$line" "$when"
        ;;
    esac
  done <<EOF
$lines
EOF
}

# --- the switch -------------------------------------------------------------

main() {
  local id='' spec='' gateway='' verify='' kick='' no_kick=0 registry='' dry=0 json=0
  local port='' gateway_env='' before='' after='' screen='' verdict='' saved='' kick_text=''
  local switched=0 kicked=0

  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$1
  spec=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gateway) gateway=$DEFAULT_GATEWAY_URL ;;
      --gateway=*) refuse "--gateway takes no value; the second gateway is loopback-only on $DEFAULT_GATEWAY_URL - set FM_DEEPSEEK_GATEWAY_PORT to change its port" ;;
      --verify) shift; verify=${1:-} ;;
      --verify=*) verify=${1#--verify=} ;;
      --kick) shift; kick=${1:-} ;;
      --kick=*) kick=${1#--kick=} ;;
      --no-kick) no_kick=1 ;;
      --tick-file) shift; registry=${1:-} ;;
      --tick-file=*) registry=${1#--tick-file=} ;;
      --now) shift; FM_LANE_SWITCH_NOW=${1:-} ;;
      --now=*) FM_LANE_SWITCH_NOW=${1#--now=} ;;
      --dry-run) dry=1 ;;
      --json) json=1 ;;
      -h|--help|help) usage; return 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$spec" ] || refuse "a model spec is required (for example: opus[1m], or 'gateway')"
  case "$spec" in
    *' '*) refuse "the model spec must not contain spaces: $spec" ;;
  esac
  validate_id "$id"
  LANE_ID=$id
  MODEL_SPEC=$spec
  VERIFY_REGEX=$verify
  [ -n "$registry" ] || registry="$DATA/$id/crons"

  resolve_lane "$id"
  before=$(lane_model_now "$LANE_META")

  if [ -n "$gateway" ]; then
    port=$DEFAULT_GATEWAY_PORT
    require_gateway_healthy "$port"
    if [ "$spec" = gateway ]; then
      MODEL_SPEC=$(gateway_model)
      spec=$MODEL_SPEC
    fi
  fi
  [ "$spec" != gateway ] || refuse "the literal 'gateway' spec needs --gateway so the advertised model id can be resolved"

  # 1. capture, so nothing typed is ever lost.
  if ! screen=$(fm_backend_capture "$LANE_BACKEND" "$LANE_TARGET" 200 "$LANE_LABEL" 2>/dev/null); then
    refuse "the screen of $id is unreadable on $LANE_BACKEND; nothing was sent"
  fi
  if [ -z "$screen" ]; then
    refuse "the screen of $id came back empty on $LANE_BACKEND; nothing was sent"
  fi
  BASELINE_SCREEN=$screen

  # 3. the composer must verify empty before anything is typed.
  verdict=$(composer_verdict)
  if [ "$verdict" != empty ]; then
    if [ "$dry" = 1 ]; then
      # A dry run inspects and reports; it writes no capture and sends nothing.
      printf 'dry-run: composer verdict is %s; would save it, interrupt, re-verify, then refuse if still not empty\n' "$verdict"
    else
      saved=$(save_capture pending-composer "$screen")
      printf 'pending composer saved: %s\n' "$saved"
      # 2. clear it, then re-verify. Ctrl-C only ever fires when the composer is
      # not already proven empty, so an idle lane mid-turn is never cancelled.
      send_key C-c || true
      sleep "$SWITCH_PAUSE"
      verdict=$(composer_verdict)
    fi
    if [ "$verdict" != empty ]; then
      refuse "the composer of $id still does not verify empty (verdict=$verdict); /model was NOT sent - whatever was typed is saved at ${saved:-<nothing saved, dry run>}"
    fi
  fi

  if [ "$dry" = 1 ]; then
    printf 'dry-run: %s on %s would switch %s -> %s\n' "$id" "$LANE_BACKEND" "$before" "$spec"
    [ -z "$gateway" ] || printf 'dry-run: would also record the gateway binding %s\n' "$gateway"
    report_next_tick "$registry"
    return 0
  fi

  # 4. send the switch through the backend's verified submit core.
  verdict=$(send_typed "/model $spec" "$SLASH_SETTLE")
  if [ "$verdict" != empty ]; then
    fail "/model $spec was not confirmed as submitted to $id (verdict=$verdict); do not retype it blindly - read the lane first"
  fi
  sleep "$SWITCH_PAUSE"

  # 5. verify on the rendered screen.
  screen=$(fm_backend_capture "$LANE_BACKEND" "$LANE_TARGET" 200 "$LANE_LABEL" 2>/dev/null || true)
  if ! screen_confirms "$screen"; then
    saved=$(save_capture unconfirmed "$screen")
    fail "/model $spec was submitted to $id but the screen does not confirm it; no resume text was sent. Read the saved screen: $saved"
  fi
  switched=1
  after=$spec
  printf 'switched: %s %s -> %s (verified on screen)\n' "$id" "$before" "$after"

  if [ -n "$gateway" ]; then
    gateway_env=$(write_gateway_env "$port")
    printf 'gateway: recorded %s for %s in %s\n' "$gateway" "$id" "$gateway_env"
    printf 'gateway: this takes effect at the lane''s next launch; a running Claude Code session keeps its current endpoint\n'
  elif [ -f "$STATE/$id.gateway.env" ]; then
    # A model switch is not an endpoint switch: the lane's recorded repoint is
    # left exactly as it was, and an operator is told so rather than guessing.
    printf 'gateway: left %s untouched; this switch changed the model, not the endpoint\n' "$STATE/$id.gateway.env"
  fi
  record_meta "$before" "$after" "$gateway"

  # 6. kick it back to work.
  if [ "$no_kick" = 0 ]; then
    if [ -n "$kick" ]; then
      kick_text=$kick
    else
      kick_text="MODEL SWITCH: this lane is now on $after. Resume your standing goal without waiting for a human, and re-check that your scheduled ticks are still armed - a model switch can skip the next one. Report it if anything looks wrong after the switch."
    fi
    verdict=$(send_typed "$kick_text" 0.3)
    if [ "$verdict" != empty ]; then
      fail "the model switch is recorded and verified, but the resume text was not confirmed as submitted (verdict=$verdict); check the lane and re-send it"
    fi
    kicked=1
    printf 'kicked: resume text sent to %s\n' "$id"
  fi

  report_next_tick "$registry"

  if [ "$json" = 1 ]; then
    python3 - "$id" "$LANE_BACKEND" "$before" "$after" "$gateway" "$switched" "$kicked" "${NEXT_TICK:-}" <<'PY'
import json, sys
task, backend, before, after, gateway, switched, kicked, next_tick = sys.argv[1:9]
print(json.dumps({
    "task": task, "backend": backend, "before": before, "after": after,
    "gateway": gateway or None, "switched": switched == "1", "kicked": kicked == "1",
    "next_tick": next_tick or None,
}, sort_keys=True))
PY
  fi
}

main "$@"
