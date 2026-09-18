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
# surfaces live in Claude Code's own session memory. Relaunching a lane
# silently loses its schedule, so a lane that owns ticks is switched inside its
# running session instead - and, because --gateway can only take effect at a
# relaunch, a lane that owns ticks is REFUSED a gateway repoint outright.
#
# --gateway: records a durable repoint of the lane at the second local
# Anthropic-compatible gateway (bin/fm-deepseek-gateway.sh), which is what
# serves DeepSeek V4.1 Flash under the model id Claude Code discovers. Claude
# Code reads its endpoint from the environment at startup, so the repoint
# takes effect on that lane's NEXT launch. The repoint is therefore written
# FIRST, once the gateway proves healthy, and never depends on the running
# session: state/<id>.gateway.env (mode 0600) holds the exact exports whoever
# launches that lane next sources, and state/<id>.meta carries only the
# `model_switch_gateway=` audit line.
#
# WHICH LANES --gateway APPLIES TO: only lanes that own no ticks. A repoint
# reaches a running session only through a relaunch, and a relaunch drops the
# /loop wakeups and CronCreate ticks that live in that session's memory, so
# --gateway REFUSES a lane that owns any - by the home's loop registry
# ($LOOP_REGISTRY, matching the lane's terminal= against a registry entry's
# term/term_old/term_prior_reboot with a non-empty expected list) or by this
# script's own tick convention (cron= lines in state/<id>.meta, or
# data/<id>/crons). Such a lane stays on the shared account pool until it is
# intentionally rotated; nothing is written and nothing is typed into it.
#
# For a lane that IS in scope, the in-place `/model` is attempted only when it
# ALREADY has a recorded state/<id>.gateway.env, because that file is the only
# durable evidence its session may already be on the gateway. A lane without
# one gets its repoint recorded, is told the exact relaunch step, and is left
# untyped-into: a session pointed at another endpoint cannot accept this
# gateway's model id, so there is nothing to send it. A plain switch with no
# --gateway never touches
# state/<id>.gateway.env: it changes the model, not the endpoint. That gateway
# is loopback-only, so its port is the gateway script's own default
# (FM_DEEPSEEK_GATEWAY_PORT, default 8799).
#
# TICKS: a model switch can skip the next scheduled tick, so this prints the
# cron expressions the home records for the lane - `cron=<expr>` lines in
# state/<id>.meta and one expression per line in data/<id>/crons - verbatim,
# against the time it read them, and says so explicitly when it records none.
# No fire time is computed: verify the tick actually fires, which is the one
# thing the switch itself cannot prove.
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
#   --dry-run           perform every check and print the plan, send nothing
#
# Exit codes: 0 switched and verified, a repoint recorded for a lane that must
# be relaunched to take it, or a clean --dry-run; 1 the switch
# could not be completed or verified, or the gateway is not healthy; 2 a
# refusal that sent nothing - a non-Claude lane, a remote lane, a tick-owning
# lane asked to take a gateway repoint, an unreadable screen, or a composer
# that would not verify empty.
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
# The home's loop registry. Entries carry the terminal a lane runs in (`term`,
# and `term_old`/`term_prior_reboot` for a lane that has been moved or has
# survived a reboot) and the `expected` list of /loop wakeups it owns. A
# non-empty `expected` for this lane's terminal is what makes the lane
# unrotatable here. Read-only, and a missing or unreadable registry is simply
# no evidence.
LOOP_REGISTRY="${FM_LANE_SWITCH_LOOP_REGISTRY:-$DATA/cmux-takeover/expected-loops.json}"
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
  (umask 077; printf '%s\n' "$text" > "$file") || fail "cannot write $file"
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

# WHY DIFF AND NOT AN ANCHOR: the reviewed remedy was to anchor on the
# pre-submit capture's last non-empty line and take only what follows it. That
# line is the composer glyph - a Claude Code pane is bottom-anchored - and it
# reappears at the bottom of every post-submit capture, so "strictly after the
# anchor" is empty on every real capture and would fail every genuine switch.
# The diff alignment below is what was accepted in its place: added lines are
# the candidates, and a carried-over transcript line - including this script's
# own earlier kick text, which names the model - stays in the common
# subsequence and can never be mistaken for evidence.
#
# Claude Code renders the `/model <spec>` this script just typed straight back
# into its transcript, so the post-submit screen always contains the model name
# whether or not the client accepted it. Candidates are therefore the lines
# `diff` reports as ADDED between the pre-submit capture and the post-submit
# one, minus that echo.
#
# A Claude Code pane is bottom-anchored: the composer stays at the bottom, new
# output is inserted above it, and a full pane scrolls its top away. So neither
# "appended at the end" nor "differs at this index" describes a new line - a
# pane that scrolled by k lines makes every index differ and would turn the
# whole transcript, including this script's own stale kick text, into evidence.
# An alignment is what distinguishes them, and diff is exactly that: content
# carried over from the baseline is common however far it moved, only genuinely
# new lines are added, and a capture that yields no added line at all confirms
# nothing and fails closed.
confirmation_lines() {  # <screen>; prints the lines a confirmation may come from
  local screen=$1
  diff -- <(printf '%s\n' "$BASELINE_SCREEN") <(printf '%s\n' "$screen") \
    | sed -n 's/^> //p' \
    | grep -vF -- "/model $MODEL_SPEC" || true
}

# Claude Code's own refusal of a model id QUOTES that id, so it satisfies any
# check that merely looks for the model name. These renderings are therefore a
# positive unconfirmed verdict, not a missing one.
REJECTION_RE="There'?s an issue with the selected model|is(n'?t| not) described by this version|may not exist or you may not have access"

screen_confirms() {  # <screen>; 0 when the switch is confirmed on screen
  local screen base marker
  screen=$(confirmation_lines "$1")
  if printf '%s\n' "$screen" | grep -qiE -- "$REJECTION_RE"; then
    printf 'fm-lane-model-switch: the lane rendered a model rejection for %s; treat the switch as unconfirmed\n' "$MODEL_SPEC" >&2
    return 1
  fi
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

# Staged and moved into place, never written onto the destination: a half-way
# failure here would otherwise leave an empty file, and an empty file is read
# as "already repointed" by the next run and sourced as a no-op relaunch by an
# operator - the two things the record-first design exists to prevent.
write_gateway_env() {  # <port>; prints the env file path
  local port=$1 file tmp
  file="$STATE/$LANE_ID.gateway.env"
  tmp=$(umask 077; mktemp "$STATE/.fm-lane-model-switch-env.XXXXXX") \
    || fail "cannot stage the gateway exports for $LANE_ID"
  if ! (umask 077; "$GATEWAY_SH" env --port "$port" > "$tmp") || [ ! -s "$tmp" ]; then
    rm -f -- "$tmp"
    fail "could not write $file"
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; fail "could not write $file"; }
  printf '%s' "$file"
}

# An env file exists AND is non-empty: a truncated one records no endpoint, so
# the lane is still on whatever it launched with.
lane_is_repointed() {  # <task-id>
  [ -s "$STATE/$1.gateway.env" ]
}

# --- ticks ------------------------------------------------------------------

tick_lines() {  # prints one cron expression per line, if the home records any
  local meta=$1 registry=$2
  grep '^cron=' "$meta" 2>/dev/null | cut -d= -f2- || true
  if [ -f "$registry" ] && [ ! -L "$registry" ]; then
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$registry"
  fi
}

# The expressions are printed verbatim against the time they were read, and
# nothing is computed from them: the operator watches the real fire, which is
# the only thing that proves the schedule survived the switch.
report_ticks() {  # <registry>
  local registry=$1 lines line
  lines=$(tick_lines "$LANE_META" "$registry")
  if [ -z "$lines" ]; then
    printf 'ticks: no tick source recorded for %s; add cron=<expr> lines to %s or a %s file, then verify the lane actually fires (a model switch can skip the next tick)\n' \
      "$LANE_ID" "$LANE_META" "$registry"
    return 0
  fi
  printf 'ticks: as of %s, %s records these cron expressions - watch the next one actually fire\n' \
    "$(utc_stamp)" "$LANE_ID"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'ticks:   %s\n' "$line"
  done <<EOF
$lines
EOF
}

# --- tick ownership ---------------------------------------------------------
#
# The gateway repoint only takes effect at a relaunch, and a relaunch drops the
# /loop wakeups and CronCreate ticks that live in Claude Code's session memory.
# A lane that owns ticks therefore cannot be moved to the gateway by this
# script at all - it stays on the shared pool until it is intentionally
# rotated - so --gateway refuses it rather than recording a repoint whose only
# way to take effect is the thing that breaks the lane.

lane_loop_count() {  # <terminal>; prints how many /loop wakeups the home records
  [ -n "${1:-}" ] || return 0
  [ -f "$LOOP_REGISTRY" ] && [ ! -L "$LOOP_REGISTRY" ] || return 0
  python3 - "$LOOP_REGISTRY" "$1" <<'PY'
import json, sys

path, terminal = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(0)
if isinstance(doc, list):
    entries = doc
elif isinstance(doc, dict):
    entries = list(doc.values())
else:
    entries = []
for entry in entries:
    if not isinstance(entry, dict):
        continue
    terms = [entry.get(key) for key in ("term", "term_old", "term_prior_reboot")]
    if terminal not in [t for t in terms if isinstance(t, str) and t]:
        continue
    expected = entry.get("expected")
    if isinstance(expected, list) and expected:
        print(len(expected))
        sys.exit(0)
PY
}

refuse_if_lane_owns_ticks() {  # <task-id> <tick-registry>
  local id=$1 registry=$2 terminal loops
  terminal=$(fm_meta_get "$LANE_META" terminal)
  loops=$(lane_loop_count "$terminal")
  if [ -n "$loops" ]; then
    refuse "$id owns $loops /loop wakeup(s) recorded in $LOOP_REGISTRY for terminal ${terminal:-<none>}; the gateway repoint only takes effect at a relaunch and a relaunch drops them, so $id stays on the shared account pool until it is intentionally rotated"
  fi
  if [ -n "$(tick_lines "$LANE_META" "$registry")" ]; then
    refuse "$id owns recorded cron ticks (cron= lines in $LANE_META or $registry); the gateway repoint only takes effect at a relaunch and a relaunch drops them, so $id stays on the shared account pool until it is intentionally rotated"
  fi
}

# --- the switch -------------------------------------------------------------

main() {
  local id='' spec='' gateway='' verify='' kick='' no_kick=0 registry='' dry=0
  local port='' gateway_env='' before='' after='' screen='' verdict='' saved='' kick_text=''
  local already_pointed=0

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
      --dry-run) dry=1 ;;
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
    refuse_if_lane_owns_ticks "$id" "$registry"
    port=$DEFAULT_GATEWAY_PORT
    require_gateway_healthy "$port"
    if [ "$spec" = gateway ]; then
      MODEL_SPEC=$(gateway_model)
      spec=$MODEL_SPEC
    fi
    # The recorded env file is the only durable evidence that this lane's
    # endpoint may already be the gateway. Read it BEFORE writing one.
    ! lane_is_repointed "$id" || already_pointed=1
  fi
  [ "$spec" != gateway ] || refuse "the literal 'gateway' spec needs --gateway so the advertised model id can be resolved"

  # The repoint is the durable half of --gateway and it takes effect at the
  # lane's next launch, so it is recorded first and unconditionally. A lane
  # whose running session is still on another endpoint cannot accept the
  # gateway's model in place, so no /model is attempted for it at all. A dry
  # run takes the same branch and reports the same plan, writing nothing.
  if [ -n "$gateway" ]; then
    if [ "$dry" = 1 ]; then
      gateway_env="$STATE/$id.gateway.env"
      printf 'dry-run: would record the gateway binding %s for %s in %s\n' "$gateway" "$id" "$gateway_env"
    else
      gateway_env=$(write_gateway_env "$port")
      printf 'gateway: recorded %s for %s in %s\n' "$gateway" "$id" "$gateway_env"
    fi
    printf 'gateway: the repoint takes effect at the lane%ss next launch; a running Claude Code session keeps its current endpoint\n' "'"
    if [ "$already_pointed" = 0 ]; then
      printf 'gateway: %s has no recorded repoint, so its running session is not on this gateway and no /model is sent to it\n' "$id"
      printf 'gateway: relaunch that lane with the recorded endpoint, then select the model in it:\n'
      printf 'gateway:   set -a; . %s; set +a\n' "$gateway_env"
      printf 'gateway:   /model %s\n' "$spec"
      report_ticks "$registry"
      return 0
    fi
  fi

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
    report_ticks "$registry"
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
  after=$spec
  printf 'switched: %s %s -> %s (verified on screen)\n' "$id" "$before" "$after"

  if [ -z "$gateway" ] && lane_is_repointed "$id"; then
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
    printf 'kicked: resume text sent to %s\n' "$id"
  fi

  report_ticks "$registry"
}

main "$@"
