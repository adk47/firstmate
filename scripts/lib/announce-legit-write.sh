#!/bin/bash
# ──────────────────────────────────────────────────────────────
# announce-legit-write.sh <writer-name> <target-path>
#
# Called by known-legitimate writers (deploy.sh, pre-start-heal.sh)
# *immediately before* an atomic-rename write to a path that
# openclaw-config-write-audit.sh watches. Appends a single line to
# /var/log/openclaw-legitimate-writes.log so the audit script can
# distinguish in-band atomic-rename writes from out-of-band ones
# without losing forensic visibility.
#
# Why this exists: lsof on the post-rename inode finds nothing —
# the writer never opened that inode by path — so the audit
# script's "who wrote this?" probe comes up empty. Without an
# announce log, every deploy and every pre-start-heal recovery
# fires a Slack-paging false positive (2026-05-08 incident).
#
# The on-disk hash of the bytes being written is recorded in the
# announce line so a stale entry can't shadow a hostile write to
# the same path within the freshness window.
#
# Caller contract: pass ANNOUNCE_SHA in the env if you have it
# (the hash of the *tmp* about to be renamed in). Otherwise the
# script falls back to hashing the current on-disk file, which
# loses the race-protection benefit.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

WRITER="${1:?writer name required}"
TARGET_RAW="${2:?target path required}"
TARGET=$(realpath "$TARGET_RAW" 2>/dev/null || echo "$TARGET_RAW")

LOG="${OPENCLAW_LEGIT_LOG:-/var/log/openclaw-legitimate-writes.log}"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"

EPOCH=$(date -u +%s)
ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

SHA="${ANNOUNCE_SHA:-}"
if [ -z "$SHA" ]; then
  SHA=$(sha256sum "$TARGET_RAW" 2>/dev/null | awk '{print $1}')
fi
SHA="${SHA:-unknown}"

PPID_=$(awk '/^PPid:/ {print $2}' "/proc/$$/status" 2>/dev/null || echo '?')

printf '%s %s %s pid=%s ppid=%s sha256=%s %s\n' \
  "$EPOCH" "$ISO" "$WRITER" "$$" "$PPID_" "$SHA" "$TARGET" >> "$LOG"

# In-place trim: keep last 1000 lines once we reach 2000. At ~120
# bytes/line that caps the log around 240 KB; deploy rate is
# 3 lines/deploy × handful per day, so trimming is rare.
if [ "$(wc -l < "$LOG")" -gt 2000 ]; then
  tmp="${LOG}.trim.$$"
  tail -n 1000 "$LOG" > "$tmp" && mv "$tmp" "$LOG"
  chmod 600 "$LOG"
fi
