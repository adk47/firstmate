#!/usr/bin/env bash
# The landing police: something other than the worker runs each ship task's
# acceptance probe and records the result, so a worker saying "done" never
# counts as landed on its own. No model is involved anywhere in this loop.
#
# Usage:
#   fm-landing-police.sh tick   one bounded pass; prints one line per finding
#   fm-landing-police.sh arm    write state/landing-police.check.sh and register
#                               it through bin/fm-check-register.sh
#
# tick, for every ship task in this home:
#   - a newest status line of `done:` registers a claim row through
#     `bin/fm-change-watch.sh claim` (once per distinct done line), binding the
#     task's acceptance probe (bin/fm-dod-lib.sh owns the probe and its binding);
#     a done: with no probe, or a probe whose bytes no longer match, is reported.
#   - every open claim with a reading due (claim time, +15m, +1h, +6h) has its
#     probe re-verified and run from / with a clean environment and a timeout,
#     and the exit code is recorded with `bin/fm-change-watch.sh acceptance`;
#     an edited probe records exit 125 and is never run.
#   - an open claim past its deadline is reported as claimed but not landed,
#     at most once an hour; a claim that just read absent is reported once.
# It prints nothing when there is nothing to report, so as a registered check
# it wakes firstmate only on a finding. At most FM_POLICE_MAX_RUNS probes
# (default 2) run per tick, each bounded by FM_POLICE_PROBE_TIMEOUT seconds
# (default 8), so a tick stays inside the watcher's check timeout.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CW="${FM_POLICE_CW:-$SCRIPT_DIR/fm-change-watch.sh}"
MAX_RUNS=${FM_POLICE_MAX_RUNS:-2}
PROBE_TIMEOUT=${FM_POLICE_PROBE_TIMEOUT:-8}
NOW=${FM_CW_NOW:-$(date +%s)}
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
cw() { FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CW" "$@"; }
mark() { printf '%s\n' "$2" > "$(fm_acceptance_dir "$STATE")/.police-$1"; }
bounded() {
  if command -v timeout >/dev/null 2>&1; then timeout "$PROBE_TIMEOUT" "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' "$PROBE_TIMEOUT" "$@"; fi
}
marked() { [ "$(cat "$(fm_acceptance_dir "$STATE")/.police-$1" 2>/dev/null)" = "$2" ]; }

register_claims() {
  local meta id line key probe rc url
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(sed -n 's/^kind=//p' "$meta" | tail -1)" = ship ] || continue
    line=$(last_status_line "$STATE/$id.status" 2>/dev/null)
    [ "$(status_line_verb "$line")" = done ] || continue
    key=$(printf '%s' "$line" | cksum | cut -d' ' -f1)
    marked "claim-$id" "$key" && continue
    probe=$(fm_acceptance_verify "$STATE" "$id"); rc=$?
    case $rc in
      1) echo "landing-police: DONE WITHOUT ACCEPTANCE PROBE $id: $line" ;;
      2) echo "landing-police: ACCEPTANCE PROBE EDITED $id: $(fm_acceptance_path "$STATE" "$id") no longer matches its binding; not claimed" ;;
      *) url=$(printf '%s\n' "$line" | grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' | head -1)
         cw claim "$id" "$probe" ${url:+"$url"} >/dev/null || { echo "landing-police: could not register the claim for $id"; continue; } ;;
    esac
    mark "claim-$id" "$key"
  done
}

run_due() {
  local id task claimed probe sha due last deadline runs=0 rc out hour
  while IFS=$'\t' read -r id task claimed probe sha due last deadline; do
    [ -n "$id" ] || continue
    if [ "$due" != - ] && [ "$runs" -lt "$MAX_RUNS" ]; then
      runs=$((runs + 1))
      if [ "$(fm_acceptance_verify "$STATE" "$task")" = "$probe" ] && [ "$(sed -n 2p "$(fm_acceptance_trust_path "$STATE" "$task")")" = "$sha" ]; then
        (cd / && bounded env -i HOME="${HOME:-/}" PATH="$PATH" "$probe" >/dev/null 2>&1); rc=$?
      else
        rc=125
      fi
      out=$(cw acceptance "$id" "$due" "$rc" 2>&1)
      case "$out" in *" absent: "*) echo "landing-police: CLAIMED DONE BUT ABSENT $task: ${out#*absent: }"; continue ;; esac
      last=$rc
    fi
    if [ "$NOW" -ge "$deadline" ] && [ "$last" != 0 ]; then
      hour=$((NOW / 3600))
      marked "late-$id" "$hour" && continue
      echo "landing-police: CLAIMED DONE BUT NOT LANDED $((( NOW - claimed ) / 60))m $task: the acceptance probe last exited $last"
      mark "late-$id" "$hour"
    fi
  done <<EOF
$(cw claims)
EOF
}

case "${1:-}" in
  tick)
    mkdir -p "$(fm_acceptance_dir "$STATE")" && chmod 0700 "$(fm_acceptance_dir "$STATE")"
    register_claims
    run_due ;;
  arm)
    check="$STATE/landing-police.check.sh"
    printf '#!/usr/bin/env bash\nFM_HOME=%q FM_STATE_OVERRIDE=%q exec %q tick\n' "$FM_HOME" "$STATE" "$SCRIPT_DIR/fm-landing-police.sh" > "$check.tmp" \
      && chmod 0700 "$check.tmp" && mv -f "$check.tmp" "$check" \
      && FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" landing-police ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
