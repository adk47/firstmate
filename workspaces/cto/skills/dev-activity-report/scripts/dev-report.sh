#!/bin/bash
# Daily Dev Activity Report — fetches commits + stats for a GitHub user across Muso-AI repos
# Usage: dev-report.sh <github_username> [hours_back]
set -euo pipefail

USER="${1:?Usage: dev-report.sh <github_username> [hours_back]}"
HOURS="${2:-24}"

if [[ "$(uname)" == "Darwin" ]]; then
  SINCE=$(date -u -v-${HOURS}H +"%Y-%m-%dT%H:%M:%SZ")
else
  SINCE=$(date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ")
fi

REPOS="core-backend web-credits platform-data-processing industry-data-processing analytics-worker analytics-scheduler devops mobile muso-skills clio-workspace"

TOTAL_ADDS=0
TOTAL_DELS=0
TOTAL_COMMITS=0
FIRST_TS=""
LAST_TS=""

for repo in $REPOS; do
  COMMITS=$(gh api "repos/Muso-AI/$repo/commits?author=$USER&since=$SINCE&per_page=100" \
    --jq '.[] | .sha' 2>/dev/null || true)
  
  [ -z "$COMMITS" ] && continue

  echo "=== REPO:$repo ==="
  
  for sha in $COMMITS; do
    DATA=$(gh api "repos/Muso-AI/$repo/commits/$sha" \
      --jq '"\(.sha[:7])|\(.stats.additions)|\(.stats.deletions)|\(.commit.message | split("\n")[0])|\(.commit.author.date)"' \
      2>/dev/null || true)
    
    if [ -n "$DATA" ]; then
      echo "COMMIT:$DATA"
      ADDS=$(echo "$DATA" | cut -d'|' -f2)
      DELS=$(echo "$DATA" | cut -d'|' -f3)
      TS=$(echo "$DATA" | cut -d'|' -f5)
      TOTAL_ADDS=$((TOTAL_ADDS + ${ADDS:-0}))
      TOTAL_DELS=$((TOTAL_DELS + ${DELS:-0}))
      TOTAL_COMMITS=$((TOTAL_COMMITS + 1))
      if [ -z "$FIRST_TS" ] || [[ "$TS" < "$FIRST_TS" ]]; then FIRST_TS="$TS"; fi
      if [ -z "$LAST_TS" ] || [[ "$TS" > "$LAST_TS" ]]; then LAST_TS="$TS"; fi
    fi
  done
done

echo "=== SUMMARY ==="
echo "TOTAL_COMMITS:$TOTAL_COMMITS"
echo "TOTAL_ADDITIONS:$TOTAL_ADDS"
echo "TOTAL_DELETIONS:$TOTAL_DELS"
echo "FIRST_COMMIT:$FIRST_TS"
echo "LAST_COMMIT:$LAST_TS"
echo "HOURS_BACK:$HOURS"
echo "USER:$USER"
