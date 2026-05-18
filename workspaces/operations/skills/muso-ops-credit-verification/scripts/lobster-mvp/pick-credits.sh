#!/usr/bin/env bash
# pick-credits.sh — router for the Lobster pipeline's first step.
#
# Dispatches to the right fetcher based on selector_kind:
#   queue    → fetch-queue.sh <batch_size>
#   profile  → fetch-by-profile.sh <selector_id> <batch_size>
#   credit   → fetch-by-credit.sh <selector_id>
#
# Usage:
#   pick-credits.sh <batch_size> <selector_kind> [<selector_id>]
#
# Argument order matters: batch_size is ALWAYS non-empty, so we put it
# first. selector_id is OFTEN empty (queue mode), and putting it last
# means an empty interpolation in the Lobster pipeline command doesn't
# shift the positional args.

set -euo pipefail

BATCH_SIZE="${1:-500}"
KIND="${2:-queue}"
ID="${3:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
QUEUE_SH="$HERE/../fetch-queue.sh"
PROFILE_SH="$HERE/fetch-by-profile.sh"
CREDIT_SH="$HERE/fetch-by-credit.sh"

case "$KIND" in
  queue)
    bash "$QUEUE_SH" "$BATCH_SIZE"
    ;;
  profile)
    if [[ -z "$ID" ]]; then
      echo "ERROR: selector_kind=profile requires selector_id (UUID)" >&2
      exit 2
    fi
    bash "$PROFILE_SH" "$ID" "$BATCH_SIZE"
    ;;
  credit)
    if [[ -z "$ID" ]]; then
      echo "ERROR: selector_kind=credit requires selector_id (UUID)" >&2
      exit 2
    fi
    bash "$CREDIT_SH" "$ID"
    ;;
  *)
    echo "ERROR: selector_kind must be queue|profile|credit (got: '$KIND')" >&2
    exit 2
    ;;
esac
