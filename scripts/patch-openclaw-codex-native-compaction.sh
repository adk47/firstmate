#!/usr/bin/env bash
# RETIRED: upstream #95831 ships the Codex-native compaction fix in openclaw
# 2026.8.1's dist (verified on staging) — deploy.sh and post-openclaw-update.sh
# no longer invoke this patch. Kept as a no-op stub only because the "Deploy
# pre-flight (rsync --delete dry-run vs /opt/hydra/)" CI gate reds on any
# tracked-path deletion; a merge-at-window PR cannot ship a removal.
# Delete this stub in the post-window cleanup PR (see docs/runbooks/UPGRADE-2026.8.1.md).
set -euo pipefail

echo "RETIRED: patch-openclaw-codex-native-compaction.sh is a no-op (upstream #95831 fixed in openclaw 2026.8.1's dist)." >&2
exit 0
