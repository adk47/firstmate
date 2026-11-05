#!/usr/bin/env bash
# ops-intake daily red-team replay + register digest.
#
#   1. replays plugins/ops-intake/redteam/*.json against the DEPLOYED code
#      (scripts/ops_intake/redteam.py imports the same router the plugin calls),
#   2. posts the register digest (asks by class / answered-by-code / escalated /
#      held / quarantined / refused / open-past-due),
#   3. writes today's record to $STATE_DIR/<date>.json.
#
# PAGES #clio_devops (slack_notify_critical) on ANY failing case, on a replayer
# that could not run, or on FEWER passing cases than the previous recorded day -
# a missing case must not read as a green day. Read-only: the red-team cases use
# stub backends (no Trino, no Intercom, no ClickUp, no model) and the digest only
# reads the register.
#
# The DO NOT POST seat is a positional flag (`--no-post`), never an env switch:
# the test seam is the flag plus `--state-dir` / `--db`, the same shape as
# caroline-safety-daily.sh.
#
# Systemd: ops-intake-redteam.timer (scripts/install-aux-units.sh, 06:40 UTC).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATE_DIR="/var/lib/hydra/ops-intake-redteam"
DB="/var/lib/hydra/ops-intake/asks.sqlite"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --no-post) NO_POST=1; shift ;;
    *) echo "ops-intake-redteam-daily: unknown argument $1" >&2; exit 2 ;;
  esac
done
NO_POST="${NO_POST:-0}"

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
today="$(date -u +%F)"
out="$STATE_DIR/$today.json"

rt="$(python3 "$ROOT/scripts/ops_intake/redteam.py" 2>&1)"; rt_rc=$?
dg="$(OPS_INTAKE_DB="$DB" python3 "$ROOT/scripts/ops_intake/router.py" digest 2>&1)"; dg_rc=$?

asjson() { printf '%s' "$1" | jq -c . 2>/dev/null || jq -cn --arg s "$1" '$s'; }
jq -n --arg day "$today" --argjson rt_rc "$rt_rc" --argjson dg_rc "$dg_rc" \
  --argjson redteam "$(asjson "$rt")" --argjson digest "$(asjson "$dg")" \
  '{day: $day, redteam: $redteam, redteam_rc: $rt_rc, digest: $digest, digest_rc: $dg_rc}' \
  > "$out.tmp" && mv "$out.tmp" "$out" && chmod 600 "$out"
record_rc=$?

cases=$(jq -r '.redteam.cases // 0' "$out" 2>/dev/null || echo 0)
passed=$(jq -r '((.redteam.cases // 0) - (.redteam.failed // 0))' "$out" 2>/dev/null || echo 0)
prev=""
for f in "$STATE_DIR"/*.json; do
  [ -f "$f" ] && [ "$f" != "$out" ] && prev="$f"
done
prev_passed=""
[ -n "$prev" ] && prev_passed=$(jq -r '((.redteam.cases // 0) - (.redteam.failed // 0))' "$prev" 2>/dev/null || echo "")

line="ops-intake redteam $(date -u +%F): ${passed}/${cases} cases passed"
[ -n "$prev_passed" ] && line="$line (previous day ${prev_passed})"
digest_line=$(jq -r '.digest | if type == "object" then (.line // ((.by_class // {}) | to_entries | map("\(.key)=\(.value)") | join(", ") | "asks by class: " + .)) else "digest unavailable" end' "$out" 2>/dev/null || echo "digest unavailable")
line="$line; $digest_line"

problem=""
if [ "$rt_rc" -ne 0 ]; then
  problem="red-team replay FAILED (rc=$rt_rc)"
elif [ "$record_rc" -ne 0 ]; then
  problem="the day's record could not be written"
elif [ -n "$prev_passed" ] && [ "$passed" -lt "$prev_passed" ]; then
  problem="fewer passing cases than the previous day (${passed} < ${prev_passed})"
fi

echo "$line"
if [ -n "$problem" ]; then
  echo "ops-intake-redteam-daily: $problem" >&2
  if [ "$NO_POST" != "1" ]; then
    # shellcheck source=/dev/null
    source "$ROOT/scripts/lib/slack-notify.sh"
    slack_notify_critical "ops-intake red-team: $problem — $line
Failing cases:
$(jq -r '.redteam.outcomes[]? | select(.ok == false) | "  - \(.id): \(.problems | join("; "))"' "$out" 2>/dev/null | head -20)"
  fi
  exit 1
fi
if [ "$NO_POST" != "1" ]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/lib/slack-notify.sh"
  slack_notify "$line"
fi
exit 0
