#!/bin/bash
# ──────────────────────────────────────────────────────────────
# announce-skill-hot-patch.sh <writer-name> <abs-target-path>
#
# Called by a human operator (or automation) on node-8
# *immediately before* hot-patching a file under /opt/hydra/skills-all/
# directly on the server. Appends a single line to
# /var/log/hydra-skill-hot-patches.log so deploy.sh's Step 4a
# pre-flight drift check can recognise the imminent edit as an
# operator-coordinated divergence rather than an accidental
# overwrite-foot-gun, and proceed quietly.
#
# Why this exists: deploy run 26443889421 on 2026-05-26 halted
# at Step 4a because a preview hot-patch on skills-all/gog/SKILL.md
# had byte-diverged from the final merged-PR content. The halt
# was correct (server bytes ≠ HEAD bytes), but the operator
# already knew the merge would overwrite the preview — there
# was no in-band channel to say "I expect rsync to overwrite
# this; don't halt". This script is that channel.
#
# What this is NOT: a way to ship server-side edits without
# committing them. The next deploy still overwrites the server
# bytes with the repo's HEAD bytes. The announce only suppresses
# the halt; it does not change what rsync does. If you want the
# server edits to be preserved, run scripts/sync-from-server.sh
# and commit them first.
#
# Caller contract:
#   - Pass ANNOUNCE_SHA in the env (the sha256 of the bytes
#     you are about to write). 64-hex characters, required.
#   - target-path must be under /opt/hydra/skills-all/ (we reject
#     anything else to keep the contract narrow — workspaces/
#     hot-patches are out of scope today).
#
# Usage:
#   sha=$(sha256sum new-content.md | awk '{print $1}')
#   ANNOUNCE_SHA="$sha" announce-skill-hot-patch.sh nick \
#     /opt/hydra/skills-all/gog/SKILL.md
#   install -m 644 new-content.md /opt/hydra/skills-all/gog/SKILL.md
# ──────────────────────────────────────────────────────────────
set -euo pipefail

WRITER="${1:?writer name required}"
TARGET_RAW="${2:?target path required}"
TARGET=$(realpath "$TARGET_RAW" 2>/dev/null || echo "$TARGET_RAW")

# The consumer (scripts/lib/acknowledge-hot-patch-drift.sh) parses
# log lines positionally via awk-field equality on $6 (sha256) and
# $7 (path). Any whitespace in WRITER or TARGET would shift the
# field count and make the entry unmatchable — fail-quiet, which
# Rule 13 (Fail Loud) forbids. Reject at write time so the writer
# gets an immediate error instead of a silently-ignored announce.
case "$WRITER" in
  *[[:space:]]*)
    echo "announce-skill-hot-patch: refused — writer name must not contain whitespace (got: $WRITER)" >&2
    exit 4
    ;;
esac
case "$TARGET" in
  *[[:space:]]*)
    echo "announce-skill-hot-patch: refused — target path must not contain whitespace (got: $TARGET)" >&2
    exit 5
    ;;
esac

LOG="${HYDRA_HOTPATCH_LOG:-/var/log/hydra-skill-hot-patches.log}"

# Path-allowlist. The default deploy root is /opt/hydra (see
# DEPLOY_PATH in scripts/deploy.sh:21). Tests override via
# HYDRA_HOTPATCH_ALLOWED_PREFIX so they can stage paths under
# $TEST_TMPDIR without weakening the production guard.
#
# Canonicalise both sides so the comparison survives symlinks
# (notably macOS /tmp → /private/tmp in tests). Trailing slash
# is restored after realpath strips it.
ALLOWED_PREFIX_RAW="${HYDRA_HOTPATCH_ALLOWED_PREFIX:-/opt/hydra/skills-all/}"
ALLOWED_PREFIX=$(realpath "$ALLOWED_PREFIX_RAW" 2>/dev/null || echo "$ALLOWED_PREFIX_RAW")
ALLOWED_PREFIX="${ALLOWED_PREFIX%/}/"
case "$TARGET" in
  "$ALLOWED_PREFIX"*) ;;
  *)
    echo "announce-skill-hot-patch: refused — target must be under $ALLOWED_PREFIX (got: $TARGET)" >&2
    exit 2
    ;;
esac

SHA="${ANNOUNCE_SHA:?ANNOUNCE_SHA env var required (sha256 of the bytes you are about to write)}"
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *)
    echo "announce-skill-hot-patch: refused — ANNOUNCE_SHA must be 64 lowercase hex characters (got: $SHA)" >&2
    exit 3
    ;;
esac

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"

EPOCH=$(date -u +%s)
ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

PPID_=$(awk '/^PPid:/ {print $2}' "/proc/$$/status" 2>/dev/null || echo '?')

printf '%s %s %s pid=%s ppid=%s sha256=%s %s\n' \
  "$EPOCH" "$ISO" "$WRITER" "$$" "$PPID_" "$SHA" "$TARGET" >> "$LOG"

# In-place trim: keep last 1000 lines once we reach 2000. Matches
# announce-legit-write.sh; hot-patch rate is far lower than deploy
# rate, so trimming is rare.
if [ "$(wc -l < "$LOG")" -gt 2000 ]; then
  tmp="${LOG}.trim.$$"
  tail -n 1000 "$LOG" > "$tmp" && mv "$tmp" "$LOG"
  chmod 600 "$LOG"
fi
