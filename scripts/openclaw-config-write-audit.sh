#!/bin/bash
# ──────────────────────────────────────────────────────────────
# openclaw-config-write-audit.sh — invoked by
# openclaw-config-write-audit@<profile>.service when the matching
# @<profile>.path unit detects a write to
# /root/.openclaw-<profile>/openclaw.json. The .service passes the
# watched path as $1.
#
# Goal: capture *what* wrote to the config, so out-of-band edits
# (which leave no trace in openclaw's own config-audit.jsonl —
# see reference_openclaw_config_audit_gap.md) become visible.
#
# Strategy:
#   1. Note the current writer-set via lsof. If the only writer
#      is the gateway itself, this is an in-band write — log it
#      at info level, no Slack notify.
#   2. Otherwise, snapshot every non-gateway process that has
#      the file open for write, plus any recent SSH session(s)
#      seen in journald that overlap this timestamp. Dump
#      /proc/<pid>/cmdline, /proc/<pid>/exe (resolved), the
#      effective UID, and the parent chain into the log.
#   3. Slack-alert the operator with a concise summary so they
#      can fix the *source* of the bad write, not just clean up
#      the symptom.
#
# Caveats:
#   - lsof on a file that's been written-then-closed will not
#     show the writer anymore. The .path unit fires on the
#     IN_CLOSE_WRITE side of the inotify event, so we may miss
#     fast writers (jq | sponge style atomic-rename writers
#     specifically — they rename a sibling tmp file, which the
#     .path unit catches as a write to the watched path; lsof
#     on the new inode after rename returns nothing because the
#     writer never had the *new* path open).
#   - For the rename-style case we fall back to:
#       a) the SSH session log overlap (last 10 sec)
#       b) `auditctl -w` if auditd is installed (records syscalls)
#     These are best-effort. The Slack alert documents which
#     evidence pathways succeeded so the operator knows what to
#     trust.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

WATCHED="${1:-}"
if [ -z "$WATCHED" ]; then
  # Fallback: scan both profiles. The systemd template in
  # install-aux-units.sh passes the specific path, but a manual
  # invocation should still produce useful output.
  for p in /root/.openclaw-main/openclaw.json /root/.openclaw-edge/openclaw.json; do
    [ -f "$p" ] && "$0" "$p"
  done
  exit 0
fi

LOGFILE="${OPENCLAW_AUDIT_LOG:-/var/log/openclaw-config-writes.log}"
LEGIT_LOG="${OPENCLAW_LEGIT_LOG:-/var/log/openclaw-legitimate-writes.log}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOGPREFIX="[openclaw-config-write-audit ${TS}] ${WATCHED}:"

log() { echo "$LOGPREFIX $*" >> "$LOGFILE"; }

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 600 "$LOGFILE"

# Source slack helper. Not fatal if the config it reads from is
# the very file just written — the helper degrades silently.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLACK_NOTIFY_CONFIG="/root/.openclaw-main/openclaw.json"
export SLACK_NOTIFY_CONFIG
# shellcheck source=lib/slack-notify.sh
source "$SCRIPT_DIR/lib/slack-notify.sh"

# Identify gateway PIDs across all three profiles. Any of them
# writing to *its own* openclaw.json is normal (the gateway
# persists state via the config-io module on every observation).
GATEWAY_PIDS=$(pgrep -f 'openclaw/dist/index.js --profile (main|edge) gateway' || true)

# Try to find a current writer via lsof. lsof prints space-
# delimited rows; column 2 is PID, column 4 is FD (we want
# write-mode descriptors, marked with `w` or `u`).
WRITERS=$(lsof -t -F p -- "$WATCHED" 2>/dev/null | tr -d 'p' | sort -u || true)

NON_GATEWAY_WRITERS=""
for pid in $WRITERS; do
  if ! echo "$GATEWAY_PIDS" | grep -qx "$pid"; then
    NON_GATEWAY_WRITERS="${NON_GATEWAY_WRITERS}${pid} "
  fi
done

if [ -z "$WRITERS" ]; then
  # Atomic-rename writer is gone — lsof has nothing. Before
  # falling through to the alarming "out-of-band" path, check
  # the legit-writes log: known-good callers (deploy.sh,
  # pre-start-heal.sh) announce themselves before each atomic
  # rename. Match on path AND sha256 so a stale legit entry
  # can't shadow a hostile write to the same path within the
  # freshness window. See scripts/lib/announce-legit-write.sh.
  WATCHED_REAL=$(realpath "$WATCHED" 2>/dev/null || echo "$WATCHED")
  ON_DISK_SHA=$(sha256sum "$WATCHED" 2>/dev/null | awk '{print $1}')
  CUTOFF=$(( $(date -u +%s) - 120 ))
  LEGIT=""
  if [ -f "$LEGIT_LOG" ] && [ -n "$ON_DISK_SHA" ]; then
    LEGIT=$(awk -v c="$CUTOFF" -v t="$WATCHED_REAL" -v h="$ON_DISK_SHA" '
      $1 >= c && $NF == t {
        s=""
        for (i=1; i<=NF; i++) if ($i ~ /^sha256=/) { split($i, a, "="); s=a[2] }
        if (s == h) print
      }' "$LEGIT_LOG" 2>/dev/null | tail -1)
  fi
  if [ -n "$LEGIT" ]; then
    log "[legit] in-band atomic-rename write — no alert: $LEGIT"
    exit 0
  fi
  # Gateway-startup suppression: openclaw's config-io module re-persists
  # the config on startup via atomic-rename (close fd before rename), so
  # lsof on the watched path turns up nothing and the legit-log has no
  # entry (the gateway doesn't announce). Without this branch, every
  # `systemctl restart openclaw-gateway-<profile>` during a deploy fires
  # a spurious Slack alert. Bounded to a 15s window after the gateway
  # entered active state, keyed on a systemd-owned timestamp the script
  # can't be tricked into setting. Glob match so the bats tests'
  # sandboxed $WATCHED (which lives under TEST_TMPDIR/.openclaw-main/...)
  # exercises this branch too.
  profile=""
  case "$WATCHED" in
    */.openclaw-main/openclaw.json) profile=main ;;
    */.openclaw-edge/openclaw.json) profile=edge ;;
  esac
  if [ -n "$profile" ]; then
    active_iso=$(systemctl show -p ActiveEnterTimestamp --value "openclaw-gateway-${profile}.service" 2>/dev/null || true)
    if [ -n "$active_iso" ]; then
      active_epoch=$(date -d "$active_iso" +%s 2>/dev/null || echo 0)
      now_epoch=$(date -u +%s)
      if [ "$active_epoch" -gt 0 ] && [ $((now_epoch - active_epoch)) -lt 15 ]; then
        log "[legit] openclaw-gateway-${profile} entered active state $((now_epoch - active_epoch))s ago — startup config persist, no alert"
        exit 0
      fi
    fi
  fi
  log "no current writer (atomic-rename or fast-close); falling back to journald correlation"
  source_evidence="rename-style write (no live writer); see SSH session log below"
elif [ -z "$NON_GATEWAY_WRITERS" ]; then
  # Pure in-band write by the gateway itself. Log at info level,
  # don't alert.
  log "in-band write by gateway PID(s) $WRITERS — no alert"
  exit 0
else
  log "non-gateway writer(s): $NON_GATEWAY_WRITERS"
  source_evidence="lsof: PID(s) $NON_GATEWAY_WRITERS"
fi

# Snapshot evidence for every non-gateway writer we caught.
EVIDENCE=""
for pid in $NON_GATEWAY_WRITERS; do
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "<gone>")
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo "<gone>")
  ppid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "?")
  uid=$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "?")
  log "  pid=$pid uid=$uid ppid=$ppid exe=$exe cmdline=[$cmdline]"
  EVIDENCE="${EVIDENCE}pid=$pid uid=$uid ppid=$ppid cmdline=$cmdline\n"
done

# Cross-reference with recent SSH session opens (last 10 sec).
# 2026-05-05 incident: corrupting writes correlated to a heavy
# SSH-from-laptop pattern — the journald `Accepted publickey ...
# from <IP>` line ties the timestamp to a source we can ban or
# disable at the source.
SSH_RECENT=$(journalctl _SYSTEMD_UNIT=ssh.service --since '10 sec ago' --no-pager 2>/dev/null \
  | grep -E 'Accepted publickey|session opened' \
  | tail -5 || true)
if [ -n "$SSH_RECENT" ]; then
  log "  recent SSH activity (10s window):"
  while IFS= read -r line; do log "    $line"; done <<<"$SSH_RECENT"
fi

# Slack-notify: keep it terse. The full evidence is in the log
# file the alert points to. Truncate cmdlines beyond 200 chars.
TRIMMED=$(printf "%s" "$EVIDENCE" | head -c 800)
slack_notify ":mag: *Out-of-band write* to \`$WATCHED\` detected at $TS. Source: ${source_evidence}. Evidence:\n\`\`\`${TRIMMED}\`\`\`Full log: \`/var/log/openclaw-config-writes.log\`. If recovery is needed, the gateway's ExecStartPre will self-heal on next restart."
