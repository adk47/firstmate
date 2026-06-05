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

# SQL is read from a single argument OR from stdin (when no args are given).
# Stdin is the ROBUST path for SQL containing quotes/parens (e.g.
# `lower(coalesce(plan,''))`): passing such SQL as a shell argument forces the
# caller to escape parens/quotes, which an LLM-driven cron payload routinely
# gets wrong (daily-churned-campaign-refresh failed exactly this way). A quoted
# heredoc needs no escaping:
#   trino-query.sh <<'SQL'
#   SELECT ... WHERE lower(coalesce(plan,'')) LIKE '%pro%' ...
#   SQL
if [ "$#" -gt 0 ]; then
  SQL="$*"
elif [ ! -t 0 ]; then
  SQL="$(cat)"
else
  cat >&2 <<EOF
Usage: $0 "<SQL>"        (single argument)
   or: $0 <<'SQL' ...    (pipe SQL on stdin — preferred when SQL has parens/quotes)

Examples:
  $0 "SHOW CATALOGS"
  $0 'SELECT * FROM "platform-industry-bi-prod".matvw_catalog_profile LIMIT 5'
  $0 <<'SQL'
  SELECT status, plan, count(*) FROM postgresql_core.public.subscriptions
  WHERE lower(coalesce(plan,'')) LIKE '%pro%' GROUP BY 1,2
  SQL
EOF
  exit 1
fi

# Empty SQL (e.g. no arg and empty stdin) is a usage error, never a cluster call.
if [ -z "${SQL//[[:space:]]/}" ]; then
  echo "ERROR: empty SQL (no argument and nothing on stdin)" >&2
  exit 1
fi

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
# Each quoted-name rule is anchored with `(^|[^.])` so it fires ONLY when the
# legacy name sits at a token boundary, NOT when it is already
# catalog-qualified. That makes the rewrite idempotent and gives an escape
# hatch:
#   - `hive."platform-industry-bi-prod"` is left alone instead of becoming
#     `hive.hive."…"` (Trino: "Too many dots in table name").
#   - `hive."platform-stats-export-prod"` stays on the S3/HMS export (the
#     legacy names ALSO exist as hive schemas), while the BARE form maps to
#     the live `postgresql_*` catalog (fresher, no export delay — same choice
#     the platform-core-backend-export-prod rule already makes).
# `\1` re-emits the consumed boundary char. Order matters: `.public_`
# variants precede the bare `.` variant so the Glue `public_` prefix is
# stripped during rewrite.
# The `hive.mlc.` rule fixes a half-migrated shorthand in saved queries:
# the schema is `hive."platform-industry-mlc-bi-prod"` (parties/works/…);
# bare `hive.mlc` (Athena's old DB name) does not exist in Trino.
SQL=$(echo "$SQL" | sed -E '
  s/(^|[^.])"platform-industry-bi-prod"\./\1hive."platform-industry-bi-prod"./g
  s/(^|[^.])"platform-industry-mlc-bi-prod"\./\1hive."platform-industry-mlc-bi-prod"./g
  s/(^|[^[:alnum:]_])hive\.mlc\./\1hive."platform-industry-mlc-bi-prod"./g
  s/(^|[^.])"platform-data-merging-catalog-prod"\./\1hive."platform-data-merging-catalog-prod"./g
  s/(^|[^.])"audit-prod"\./\1hive.audit./g
  s/(^|[^.])"platform-core-backend-export-prod"\.public_/\1postgresql_core.public./g
  s/(^|[^.])"platform-core-backend-export-prod"\./\1postgresql_core.public./g
  s/(^|[^.])"platform-stats-export-prod"\.public_/\1postgresql_stats.public./g
  s/(^|[^.])"platform-stats-export-prod"\./\1postgresql_stats.public./g
  s/(^|[^.])"platform-feed-export-prod"\.public_/\1postgresql_feed.public./g
  s/(^|[^.])"platform-feed-export-prod"\./\1postgresql_feed.public./g
  s/(^|[^.])"platform-catalog-export-prod"\.public_/\1postgresql_catalog.public./g
  s/(^|[^.])"platform-catalog-export-prod"\./\1postgresql_catalog.public./g
  s/(^|[^.])"platform-industry-calculations-export-prod"\.public_/\1postgresql_industry.public./g
  s/(^|[^.])"platform-industry-calculations-export-prod"\./\1postgresql_industry.public./g
  s/"bi"\./postgresql_analytics.public./g
  s/(^|[[:space:]])bi\./\1postgresql_analytics.public./g
')

# ── Strip the Glue `public_` table-name prefix when targeting raw PG ──
# Athena's Glue catalog mirrored Postgres tables with a `public_` prefix
# (so `platform-core-backend-export-prod`.public_users matched the public
# schema's `users` table). Raw PG via the Trino postgresql connector
# exposes the bare table name (`users`, not `public_users`). After the
# schema rewrite above, fix up the table prefix too — but only on the
# rewritten live-PG catalogs (don't touch hive.* tables whose names
# legitimately start with public_).
SQL=$(echo "$SQL" | sed -E 's/(postgresql_(core|stats|feed|catalog|industry)\.public\.)public_/\1/g')

# ── Dry-run hook: print the rewritten SQL and stop (no cluster needed) ──
# Used by scripts/tests/trino-query.bats to assert the rewrite layer without
# a live trino-coordinator, and handy for debugging a rewrite by hand:
#   TRINO_REWRITE_ONLY=1 trino-query.sh '<SQL>'
if [ "${TRINO_REWRITE_ONLY:-}" = "1" ]; then
  echo "$SQL"
  exit 0
fi

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
