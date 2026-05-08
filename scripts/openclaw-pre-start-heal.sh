#!/bin/bash
# ──────────────────────────────────────────────────────────────
# openclaw-pre-start-heal.sh — wired into ExecStartPre for
# every openclaw-gateway-<profile>.service via the systemd
# drop-in installed by scripts/install-aux-units.sh.
#
# Goal: turn a schema-invalid openclaw.json into a 0-impact
# event instead of a crash-loop outage. Two levels of self-heal:
#
#   1. Validate. If clean, exit 0 — gateway starts normally.
#   2. Walk /root/.openclaw-<profile>/openclaw.json.bak-*
#      newest-first. For each, atomic-swap into openclaw.json
#      and validate. First one that passes wins. Preserve the
#      corrupt original at openclaw.json.broken-<ts> for
#      forensics.
#
# Why we DON'T try `openclaw doctor --fix` here: in 2026.4.27,
# every openclaw subcommand (including doctor) loads + validates
# the config BEFORE running, so against a schema-invalid file
# doctor exits with the same validation error before it can
# strip any keys. Verified empirically against the 2026-05-05
# `subagents`-key case; doctor returned non-zero with `Invalid
# config at /root/.openclaw-<p>/openclaw.json: <root>:
# Unrecognized key: "subagents"` and made no changes. Bak-walk
# is the only recovery that works for this class. Upstream
# tracking: https://github.com/openclaw/openclaw/issues/25595.
#
# If both layers fail, exit 1 loudly. Combined with
# StartLimitBurst=5/IntervalSec=120 in the gateway drop-in,
# systemd halts restart attempts after 5 failed starts and the
# watchdog cron (every 2 min) Slack-alerts. Better: a clear
# `failed` state than an indefinite crash-loop.
#
# Background: 2026-05-05 main-gateway outage. An out-of-band
# write added schema-invalid keys, openclaw rejected the file,
# the bare `Restart=always` unit crash-looped for 30 min until
# manual intervention. This script is the boot-path defensive fix.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "usage: $0 <profile>  (e.g. main, edge, dev)" >&2
  exit 2
fi

PROFILE="$1"
CONFIG_DIR="/root/.openclaw-${PROFILE}"
CONFIG="${CONFIG_DIR}/openclaw.json"
LOGPREFIX="[openclaw-pre-start-heal:${PROFILE} $(date -u +%Y-%m-%dT%H:%M:%SZ)]"

log() { echo "$LOGPREFIX $1"; }

# Source the shared Slack helper. Use the *target* profile's config
# as the token source if it's readable, otherwise fall back to the
# main profile (which holds the canonical devops bot account). This
# matters because the very file we may be trying to repair could be
# unparseable, in which case slack-notify.sh's token read raises and
# returns silently — that's intentional, so this script keeps trying
# the other recovery layers instead of dying on a notification path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$CONFIG" ]; then
  SLACK_NOTIFY_CONFIG="$CONFIG"
else
  SLACK_NOTIFY_CONFIG="/root/.openclaw-main/openclaw.json"
fi
export SLACK_NOTIFY_CONFIG
# shellcheck source=lib/slack-notify.sh
source "$SCRIPT_DIR/lib/slack-notify.sh"

is_valid() {
  # Returns 0 if `openclaw --profile <p> config validate` reports clean.
  # The CLI prints "Config valid: <path>" on stdout when ok and a multi-
  # line "Invalid config at ...:\n- <key>: ..." chain on stderr otherwise.
  local out
  out=$(openclaw --profile "$PROFILE" config validate 2>&1 || true)
  echo "$out" | grep -q "Config valid"
}

last_validate_output() {
  openclaw --profile "$PROFILE" config validate 2>&1 || true
}

# ─── Layer 1: validate ───────────────────────────────────────
if is_valid; then
  log "Config valid — proceeding to start."
  exit 0
fi

INITIAL_ERR=$(last_validate_output)
log "Config INVALID on entry: ${INITIAL_ERR}"

# ─── Layer 2: bak-walk ───────────────────────────────────────
# Walk the gateway's own periodic .bak-* snapshots newest-first,
# atomic-swap each into openclaw.json, and validate. First valid
# one wins. The original (still-corrupt) file is preserved as
# openclaw.json.broken-<ts> for forensics — never deleted.
TS=$(date -u +%Y%m%dT%H%M%SZ)
BROKEN_PATH="${CONFIG}.broken-${TS}"
cp -p "$CONFIG" "$BROKEN_PATH" || true
log "Preserved current corrupt config at ${BROKEN_PATH}; walking .bak-* newest-first…"

# `ls -t` would honor mtime; we want the lexicographic timestamp suffix
# for files like openclaw.json.bak-20260504T075405Z-pre-ops-medium AND
# the numeric-epoch form openclaw.json.bak-1777321520, so combine: list
# all .bak* (excluding our just-created .broken-* and the .last-good
# pointer), sort by mtime descending, and try in order.
mapfile -t CANDIDATES < <(
  find "$CONFIG_DIR" -maxdepth 1 -type f \
    \( -name 'openclaw.json.bak*' -o -name 'openclaw.json.last-good' \) \
    -not -name '*.broken-*' \
    -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn \
  | awk '{print $2}'
)

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  log "FATAL: no .bak-* snapshots available to restore from."
  slack_notify ":rotating_light: *${PROFILE} gateway* CANNOT START — config invalid AND no .bak-* snapshots available to restore from. Original error: \`${INITIAL_ERR}\`. Manual intervention required: \`ssh node-8 && openclaw --profile ${PROFILE} doctor --fix\` or restore openclaw.json from git."
  exit 1
fi

for cand in "${CANDIDATES[@]}"; do
  log "Trying candidate: $(basename "$cand") (mtime: $(stat -c %y "$cand" 2>/dev/null || echo unknown))"
  # Atomic swap: write candidate to a sibling temp first so a partial
  # read by some other process can't see a half-overwritten file. Then
  # rename into place.
  tmp="${CONFIG}.candidate-${TS}"
  cp -p "$cand" "$tmp"
  # Announce the legitimate atomic-rename write so
  # openclaw-config-write-audit.sh can match path+sha256 and
  # suppress its "out-of-band" Slack alert. Best-effort — if the
  # helper is missing we fall through to today's behavior.
  if [ -x "$SCRIPT_DIR/lib/announce-legit-write.sh" ]; then
    ANNOUNCE_SHA=$(sha256sum "$tmp" | awk '{print $1}') \
      "$SCRIPT_DIR/lib/announce-legit-write.sh" pre-start-heal "$CONFIG" || true
  fi
  mv "$tmp" "$CONFIG"
  if is_valid; then
    log "RECOVERED from $(basename "$cand"). Original corrupt file at ${BROKEN_PATH}."
    slack_notify ":white_check_mark: *${PROFILE} gateway* config auto-recovered at boot from \`$(basename "$cand")\`. Corrupt original preserved at \`${BROKEN_PATH}\`. Original error: \`${INITIAL_ERR}\`. Check writer logs at \`/var/log/openclaw-config-writes.log\` to identify what wrote the bad config."
    exit 0
  fi
  log "  candidate also invalid: $(last_validate_output)"
done

# Nothing in the bak chain validates — restore the original corrupt
# file so the operator at least sees what they expect, log loudly,
# and exit. systemd's StartLimitBurst will halt restart attempts.
cp -p "$BROKEN_PATH" "$CONFIG" 2>/dev/null || true
log "FATAL: exhausted ${#CANDIDATES[@]} .bak-* candidates, none valid. Giving up."
slack_notify ":rotating_light: *${PROFILE} gateway* CANNOT START — config invalid and ALL ${#CANDIDATES[@]} .bak-* snapshots are also invalid (likely a schema upgrade outpaced the snapshot rotation window). Original error: \`${INITIAL_ERR}\`. Restore openclaw.json from git: \`scp openclaw-${PROFILE}.json node-8:/root/.openclaw-${PROFILE}/openclaw.json && systemctl reset-failed openclaw-gateway-${PROFILE} && systemctl start openclaw-gateway-${PROFILE}\`."
exit 1
