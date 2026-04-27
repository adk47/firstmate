#!/usr/bin/env bash
# trino-query.sh — Backward-compatible wrapper around Trino on OVH.
#
# Usage:
#   trino-query.sh "SELECT * FROM hive.default.matvw_catalog_profile LIMIT 10"
#   trino-query.sh 'SELECT * FROM "platform-industry-bi-prod".matvw_catalog_track LIMIT 5'
#                  ↑ legacy Athena DB names auto-rewritten to Trino catalog.schema
#
# Output: CSV (matches `aws athena get-query-results` shape)
#
# What this does:
#   1. Auto-rewrites legacy Athena DB names to their OVH Trino equivalents
#   2. Locates a running trino-coordinator pod via kubectl
#   3. Executes via `kubectl exec -- trino --execute "$SQL" --output-format CSV`
#   4. Streams stdout
#
# Exit codes:
#   0 — query executed successfully
#   1 — usage error
#   2 — no trino-coordinator pod found
#   non-zero — Trino's own exit (query failed, syntax error, etc.)
#
# Migration history:
#   2026-04-25  AWS Athena retired in favor of OVH Trino. This wrapper
#               keeps existing skills/scripts working with no changes
#               (legacy DB names are sed-rewritten before execution).
set -euo pipefail

if [ $# -eq 0 ]; then
  cat >&2 <<EOF
Usage: $0 "<SQL>"

Examples:
  $0 "SHOW CATALOGS"
  $0 "SELECT count(*) FROM hive.default.matvw_catalog_track WHERE is_deleted=false"
  $0 'SELECT * FROM "platform-industry-bi-prod".matvw_catalog_profile LIMIT 5'
EOF
  exit 1
fi

SQL="$*"

# ── Step 1: rewrite legacy Athena DB names → Trino catalog.schema ──
# IMPORTANT: OVH Hive Metastore preserved the original Athena schema
# names verbatim (lift-and-shift from AWS Glue catalog), so the
# matvw_* tables still live in `hive."platform-industry-bi-prod"`,
# NOT in `hive.default`. Rewrites just prepend the `hive.` catalog
# prefix and keep the quoted schema name intact.
#
# Live PG tables (users, teams, subscriptions, etc.) are accessible
# via the postgresql_* catalogs (faster than going through HMS, no
# export delay).
SQL=$(echo "$SQL" | sed -E '
  s/"platform-industry-bi-prod"\./hive."platform-industry-bi-prod"./g
  s/"audit-prod"\./hive.audit./g
  s/"platform-industry-mlc-bi-prod"\./hive."platform-industry-mlc-bi-prod"./g
  s/"platform-data-merging-catalog-prod"\./hive."platform-data-merging-catalog-prod"./g
  s/"platform-core-backend-export-prod"\./postgresql_core.public./g
  s/"bi"\./postgresql_analytics.public./g
  s/(^|[[:space:]])bi\./\1postgresql_analytics.public./g
')

# ── Step 2: locate trino-coordinator pod ──
TRINO_NS="${TRINO_NS:-data-processing}"
TRINO_POD=$(kubectl get pods -n "$TRINO_NS" -l app=trino,component=coordinator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$TRINO_POD" ]; then
  # Fallback: prefix match
  TRINO_POD=$(kubectl get pods -n "$TRINO_NS" -o jsonpath='{.items[?(@.metadata.name)].metadata.name}' 2>/dev/null \
              | tr ' ' '\n' | grep '^trino-coordinator-' | head -1 || true)
fi

if [ -z "$TRINO_POD" ]; then
  echo "ERROR: no trino-coordinator pod found in namespace=$TRINO_NS" >&2
  echo "       Try: kubectl get pods -n $TRINO_NS | grep trino" >&2
  exit 2
fi

# ── Step 3: execute via kubectl exec ──
exec kubectl exec -n "$TRINO_NS" "$TRINO_POD" -- trino \
  --execute "$SQL" \
  --output-format CSV
