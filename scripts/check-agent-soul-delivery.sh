#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Agent SOUL-delivery guard (MUS-6635, recurrence guard for MUS-6600)
#
# Fails loud when a live agent's most recent codex session did not give the
# MODEL its AGENT_SOUL / <available_skills> (and, on cron turns, the cron-mode
# text). MUS-6600: codex's catalog collaboration template replaced OpenClaw's
# turn instructions, every gpt-6 agent ran soul-less for ~3h, 74 cron turns ran
# without cron-mode, and the only acceptance check ("answers PONG, no fallback")
# passes perfectly on an agent with no SOUL.
#
# What it reads, and why:
#   Verdict  = the FIRST response_item with payload.role == "developer" in the
#              newest assertable rollout: the message the model actually saw.
#              NEVER turn_context.collaboration_mode.settings.developer_instructions
#              — that is the client-side record and stays intact WHILE the defect
#              is active, which is exactly why MUS-6600 was invisible.
#   Class    = cron-ness comes from the client side (a `[cron:<id> …]` user
#              message, or the cron marker in turn_context). Classification only,
#              never the verdict.
#
# Agent list: the live openclaw.json agents.list of each profile, NOT `ls agents/`
# (design/main/ops/openclaw dirs are stale leftovers with no live config).
#
# By-design exemption (and only it): a lightweight-context cron turn
# (shouldInjectCodexOpenClawPromptContext(), bootstrapContextMode=lightweight &&
# runKind=cron) deliberately omits SOUL/memory/skills but still delivers the cron
# marker. Recognised from the session itself: cron turn + marker present
# model-visible + neither SOUL nor skills + the "Lightweight bootstrap context"
# line in session_meta.base_instructions. A cron turn that lost the marker too
# (the MUS-6600 signature) is NOT exempt. An exempt session is skipped, not
# counted as evidence: the agent is judged on its newest NON-exempt session, so
# a nightly lightweight cron can never mask a stripped interactive session.
#
# Staleness: an agent whose newest assertable session is older than
# AGENT_SOUL_MAX_AGE_HOURS (default 48) is SKIPped, it cannot be asserted on.
# Vacuity guard: if zero agents were asserted the run FAILS.
#
# Exit: 0 all asserted agents PASS · 1 any FAIL / zero asserted / bad config
#       2 usage error.
#
# --alert  (cron mode): also page #clio_devops on FAIL; the identical failing
#          set is re-paged at most every AGENT_SOUL_REPAGE_SECS (default 6h);
#          stands down in a maintenance window; node-8 host-guarded; flock'd.
#          Scheduled every 15 min by /etc/cron.d/agent-soul-delivery-guard
#          (scripts/install-aux-units.sh). Not a deploy step: right after a
#          gateway restart there is no post-deploy session per agent.
#
# Env knobs (tests): AGENT_SOUL_PROFILE_DIRS (default both live profiles),
#   AGENT_SOUL_MAX_AGE_HOURS,
#   AGENT_SOUL_STATE_FILE, AGENT_SOUL_LOCKFILE, AGENT_SOUL_REPAGE_SECS,
#   AGENT_SOUL_SLACK_CHANNEL, AGENT_SOUL_SKIP_HOST_GUARD=1.
# ──────────────────────────────────────────────────────────────
set -uo pipefail

LOGPREFIX="[agent-soul-delivery-guard $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
PROFILE_DIRS="${AGENT_SOUL_PROFILE_DIRS:-/root/.openclaw-main /root/.openclaw-edge}"
MAX_AGE_HOURS="${AGENT_SOUL_MAX_AGE_HOURS:-48}"
STATE_FILE="${AGENT_SOUL_STATE_FILE:-/var/lib/agent-soul-delivery-guard/state}"
LOCKFILE="${AGENT_SOUL_LOCKFILE:-/var/run/agent-soul-delivery-guard.lock}"
REPAGE_SECS="${AGENT_SOUL_REPAGE_SECS:-21600}"
SKIP_HOST_GUARD="${AGENT_SOUL_SKIP_HOST_GUARD:-0}"
export SLACK_CHANNEL="${AGENT_SOUL_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops
ALERT=0

for arg in "$@"; do
  case "$arg" in
    --alert) ALERT=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

CRON_MARKER='OpenClaw cron automation turn'

# classify <rollout> → "<cron 0|1> <soul 0|1> <skills 0|1> <marker 0|1> <has_dev 0|1> <lightweight 0|1>"
# lightweight = session_meta.base_instructions carries the bootstrap-mode line a lightweight run
# gets (absent from full-context runs): independent evidence, so a full cron that merely lost
# SOUL+skills cannot pass as the by-design exemption.
# Reads only the head of the file (lazy `limit`), so MB-sized rollouts are cheap.
classify() {
  jq -nr --arg m "$CRON_MARKER" '
    def txt: if (.payload.content|type) == "array"
             then [.payload.content[] | (.text? // "")] | join("\n")
             else (.payload.content // "" | tostring) end;
    [limit(16; inputs | select(
        (.type == "response_item" and (.payload.role == "user" or .payload.role == "developer"))
        or .type == "turn_context" or .type == "session_meta"))] as $h
    | ($h | map(select(.type == "response_item" and .payload.role == "developer")) | first) as $dev
    | ($dev // null | if . == null then "" else txt end) as $d
    | ($h | map(select(.type == "response_item" and .payload.role == "user") | txt)
         | any(.[]; startswith("[cron:"))) as $cron_user
    | ($h | map(select(.type == "turn_context")
          | (.payload.collaboration_mode.settings.developer_instructions // "" | tostring))
         | any(.[]; contains($m))) as $cron_ctx
    | ($h | map(select(.type == "session_meta") | (.payload.base_instructions // "" | tostring))
         | any(.[]; contains("Lightweight bootstrap context"))) as $lw
    | [ (if ($cron_user or $cron_ctx) then 1 else 0 end),
        (if ($d | contains("AGENT_SOUL")) then 1 else 0 end),
        (if ($d | contains("<available_skills>")) then 1 else 0 end),
        (if ($d | contains($m)) then 1 else 0 end),
        (if $dev == null then 0 else 1 end),
        (if $lw then 1 else 0 end) ] | map(tostring) | join(" ")
  ' "$1" 2>/dev/null
}

# rollouts_newest_first <agent-dir> → paths, newest filename (timestamped) first
# Uncapped on purpose: the caller stops at the MAX_AGE_HOURS boundary, and a count cap could
# hide a stripped interactive session behind N lightweight crons.
rollouts_newest_first() {
  find "$1" -path '*codex-home/sessions/*' -name 'rollout-*.jsonl' -type f 2>/dev/null \
    | awk -F/ '{print $NF "\t" $0}' | sort -r | cut -f2-
}

failures=()   # "agent: reason"
passed=0; skipped=0
report=()

check_agent() {
  local profile="$1" agent="$2" adir="$1/agents/$2" f c cron soul skills marker hasdev lw miss exempt_seen=0 stale_seen=0
  if [ ! -d "$adir" ]; then
    report+=("SKIP $agent ($profile): no agent directory"); skipped=$((skipped+1)); return
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -z "$(find "$f" -mmin "-$((MAX_AGE_HOURS*60))" 2>/dev/null)" ]; then
      stale_seen=1; break   # newest-first: everything after is older still
    fi
    if ! c="$(classify "$f")"; then
      # unparsable newest rollout: cannot be verified, so never fall back to an older PASS
      report+=("FAIL $agent ($profile): unparsable rollout $(basename "$f"), cannot verify")
      failures+=("$agent")
      return
    fi
    # shellcheck disable=SC2086
    set -- $c
    cron="${1:-0}"; soul="${2:-0}"; skills="${3:-0}"; marker="${4:-0}"; hasdev="${5:-0}"; lw="${6:-0}"
    if [ "$hasdev" != 1 ]; then continue; fi          # no developer message yet (aborted start): not evidence
    if [ "$cron" = 1 ] && [ "$marker" = 1 ] && [ "$lw" = 1 ] && [ "$soul" = 0 ] && [ "$skills" = 0 ]; then
      exempt_seen=1; continue                          # by-design lightweight cron
    fi
    miss=()
    [ "$soul" = 1 ] || miss+=("AGENT_SOUL")
    [ "$skills" = 1 ] || miss+=("<available_skills>")
    if [ "$cron" = 1 ] && [ "$marker" = 0 ]; then miss+=("$CRON_MARKER"); fi
    if [ "${#miss[@]}" -eq 0 ]; then
      report+=("PASS $agent ($profile): $(basename "$f")"); passed=$((passed+1)); return
    fi
    report+=("FAIL $agent ($profile): model-visible developer message lacks ${miss[*]} in $(basename "$f")")
    failures+=("$agent")
    return
  done < <(rollouts_newest_first "$adir")
  if [ "$stale_seen" = 1 ] || [ "$exempt_seen" = 0 ]; then
    report+=("SKIP $agent ($profile): no session within ${MAX_AGE_HOURS}h to assert on")
  else
    report+=("SKIP $agent ($profile): only lightweight-cron sessions (exempt by design)")
  fi
  skipped=$((skipped+1))
}

run_check() {
  local profile cfg ids id
  for profile in $PROFILE_DIRS; do
    cfg="$profile/openclaw.json"
    if ! ids="$(jq -er '.agents.list[].id' "$cfg" 2>/dev/null)" || [ -z "$ids" ]; then
      report+=("FAIL config: cannot read agents.list from $cfg"); failures+=("config:$profile")
      continue
    fi
    while IFS= read -r id; do check_agent "$profile" "$id"; done <<< "$ids"
  done
  if [ "$passed" -eq 0 ] && [ "${#failures[@]}" -eq 0 ]; then
    report+=("FAIL asserted 0 agents: every configured agent was skipped, so this run proves nothing")
    failures+=("asserted-0")
  fi
}

run_check
printf '%s\n' "${report[@]}"
echo "$LOGPREFIX passed=$passed failed=${#failures[@]} skipped=$skipped"

[ "$ALERT" -eq 1 ] || { [ "${#failures[@]}" -eq 0 ]; exit $?; }

# ── --alert: cron mode ───────────────────────────────────────
# shellcheck source=lib/maintenance-flag.sh
source "$_DIR/lib/maintenance-flag.sh"
# shellcheck source=lib/slack-notify.sh
source "$_DIR/lib/slack-notify.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - not paging"
  [ "${#failures[@]}" -eq 0 ]; exit $?
fi
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  echo "$LOGPREFIX SKIP: hostname is not ovh-node-8 ($(hostname))"; exit 0
fi
if [ "${#failures[@]}" -eq 0 ]; then
  rm -f "$STATE_FILE"; exit 0
fi

sig="$(printf '%s\n' "${failures[@]}" | sort | tr '\n' ',')"
now="$(date -u +%s)"
if [ -f "$STATE_FILE" ]; then
  read -r last_sig last_ts < "$STATE_FILE" || true
  if [ "${last_sig:-}" = "$sig" ] && [ $((now - ${last_ts:-0})) -lt "$REPAGE_SECS" ]; then
    echo "$LOGPREFIX same failing set already paged; not re-paging"; exit 1
  fi
fi
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
exec 9>"$LOCKFILE"
flock -n 9 || { echo "$LOGPREFIX SKIP: another run holds $LOCKFILE"; exit 1; }
msg=":rotating_light: *Agent SOUL not delivered to the model* (MUS-6600 shape). Failing: ${sig%,}
$(printf '%s\n' "${report[@]}" | grep '^FAIL' | head -12)
The agent's newest session's developer message lacks SOUL/skills/cron-mode. Check patch-openclaw-soul-delivery.sh on the profile (MUS-6632) and the codex install."
# Status-aware post: advance the dedupe state ONLY on a confirmed delivery, so a
# failed page (token, bot not in channel, muso missing) is retried next tick.
pf="$(mktemp)"
jq -n --arg channel "$SLACK_CHANNEL" --arg text "$msg" \
  '{channel: $channel, text: $text}' > "$pf"
if slack_notify_payload_file_status "$pf"; then
  printf '%s %s\n' "$sig" "$now" > "$STATE_FILE"
else
  echo "$LOGPREFIX page NOT delivered; leaving dedupe state so the next run retries"
fi
rm -f "$pf"
exit 1
