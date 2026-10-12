#!/usr/bin/env bash
# Fail loud when the host's /dev/null is not a character device.
#
# On 2026-10-09 node-8's /dev/null became a regular root-owned file and PR
# Validation went red for hours as 5 unrelated-looking bats failures. This
# names the host problem in the first second of every job.
#
# $1 is the path to check (default /dev/null) so the bats suite can exercise
# both outcomes without touching the real device.
#
# NO REPAIR PATH, deliberately: a PR-triggered workflow may not write a device
# node on the prod host, and the file's content is the only forensic record of
# what wrote to it. Restore is MUS-6760 and needs Nick.
set -euo pipefail

NULL_PATH="${1:-/dev/null}"

if [ -c "$NULL_PATH" ]; then
  echo "✓ $NULL_PATH is a char device"
  exit 0
fi

echo "::error::node-8 $NULL_PATH is not a char device — host problem, not this PR"
ls -ld "$NULL_PATH" 2>/dev/null || echo "$NULL_PATH: absent"
echo "Restore is tracked in MUS-6760 and needs Nick. This check never repairs it."
exit 1
