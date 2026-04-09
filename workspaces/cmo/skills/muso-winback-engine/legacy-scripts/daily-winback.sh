#!/bin/bash
# Daily Win-Back Engine
# Usage: daily-winback.sh [batch_size] [dry_run]
# Default: 120 emails/day, live mode
# dry_run: pass "dry" as second arg to generate drafts without sending

BATCH_SIZE=${1:-120}
DRY_RUN=${2:-""}
WORKSPACE="$HOME/.openclaw/workspace"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Muso Win-Back Daily Engine ==="
echo "Batch size: $BATCH_SIZE"
echo "Mode: $([ "$DRY_RUN" = "dry" ] && echo 'DRY RUN' || echo 'LIVE')"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# Run the Python engine
python3 "$SCRIPT_DIR/winback_engine.py" \
  --batch-size "$BATCH_SIZE" \
  $([ "$DRY_RUN" = "dry" ] && echo '--dry-run') \
  2>&1
