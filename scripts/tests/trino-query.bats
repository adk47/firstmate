#!/usr/bin/env bats
# Tests for scripts/trino-query.sh — the legacy Athena-DB-name → Trino
# catalog.schema rewrite layer. Exercised via TRINO_REWRITE_ONLY=1 (the
# dry-run hook), which prints the rewritten SQL and exits BEFORE any kubectl
# call. kubectl is PATH-shadowed to fail loud, so a regression in the dry-run
# guard can never reach a real cluster (see
# memory/feedback_bats_must_stub_openclaw.md — same discipline as
# scripts/tests/drift-check.bats shadowing ssh).
#
# Why these cases: the rewrites were silently breaking real queries —
#   1. legacy `platform-stats-export-prod` had no rule → "Catalog must be
#      specified" (operations fraud-investigation noise, 2026-05-28).
#   2. an already-`hive.`-qualified name got `hive.` re-prepended →
#      "Too many dots in table name: hive.hive.…".
# Each test pins the intent, not just the byte output.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
TQ="$HYDRA_REPO/scripts/trino-query.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"
  # Refuse any kubectl call loudly: the dry-run hook MUST exit before here.
  cat > "$TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/bin/bash
echo "test stub: kubectl call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/kubectl"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export TRINO_REWRITE_ONLY=1
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# rewrites <input-sql> <expected-rewritten-sql>
rewrites() {
  run bash "$TQ" "$1"
  [ "$status" -eq 0 ]
  [ "$output" = "$2" ]
}

# ── The two bugs this change fixes ──────────────────────────────────────

@test "stats: legacy name + public_ prefix rewrites to postgresql_stats (stripped)" {
  # Regression: this exact query produced "Catalog must be specified".
  rewrites 'DESCRIBE "platform-stats-export-prod".public_track_daily' \
           'DESCRIBE postgresql_stats.public.track_daily'
}

@test "stats: legacy name without public_ prefix also rewrites" {
  rewrites 'SELECT date FROM "platform-stats-export-prod".track_daily' \
           'SELECT date FROM postgresql_stats.public.track_daily'
}

@test "idempotency: an already-hive-qualified name is left untouched (no hive.hive.)" {
  # Regression: produced "Too many dots: hive.hive.platform-industry-bi-prod…".
  rewrites 'DESCRIBE hive."platform-industry-bi-prod".matvw_catalog_track' \
           'DESCRIBE hive."platform-industry-bi-prod".matvw_catalog_track'
}

@test "idempotency: explicit hive form of an export name is the escape hatch (untouched)" {
  rewrites 'SELECT 1 FROM hive."platform-stats-export-prod".public_track_daily' \
           'SELECT 1 FROM hive."platform-stats-export-prod".public_track_daily'
}

@test "idempotency: an already-postgresql-qualified name is left untouched" {
  rewrites 'SELECT 1 FROM postgresql_stats.public.track_daily' \
           'SELECT 1 FROM postgresql_stats.public.track_daily'
}

# ── Existing mappings must keep working (no regression) ─────────────────

@test "core: legacy export name + public_ table → postgresql_core.public (stripped)" {
  rewrites 'SELECT id FROM "platform-core-backend-export-prod".public_users' \
           'SELECT id FROM postgresql_core.public.users'
}

@test "bi: bare bi. prefix → postgresql_analytics.public" {
  rewrites 'SELECT 1 FROM bi.marketing_weekly' \
           'SELECT 1 FROM postgresql_analytics.public.marketing_weekly'
}

@test "industry-bi: bare legacy name → hive.\"…\" (single prefix)" {
  rewrites 'SELECT 1 FROM "platform-industry-bi-prod".matvw_catalog_track' \
           'SELECT 1 FROM hive."platform-industry-bi-prod".matvw_catalog_track'
}

@test "audit: bare audit-prod → hive.audit (schema rename preserved)" {
  rewrites 'SELECT 1 FROM "audit-prod".audit_track' \
           'SELECT 1 FROM hive.audit.audit_track'
}

@test "mlc: bare legacy name → hive.\"platform-industry-mlc-bi-prod\"" {
  rewrites 'SELECT 1 FROM "platform-industry-mlc-bi-prod".matvw_x' \
           'SELECT 1 FROM hive."platform-industry-mlc-bi-prod".matvw_x'
}

@test "data-merging: bare legacy name → hive.\"platform-data-merging-catalog-prod\"" {
  rewrites 'SELECT 1 FROM "platform-data-merging-catalog-prod".matvw_x' \
           'SELECT 1 FROM hive."platform-data-merging-catalog-prod".matvw_x'
}

@test "mlc shorthand: hive.mlc.<t> → hive.\"platform-industry-mlc-bi-prod\".<t> (broken saved queries)" {
  rewrites 'SELECT 1 FROM hive.mlc.works JOIN hive.mlc.parties USING(x)' \
           'SELECT 1 FROM hive."platform-industry-mlc-bi-prod".works JOIN hive."platform-industry-mlc-bi-prod".parties USING(x)'
}

# ── New export-name mappings (comprehensive sweep) ──────────────────────

@test "feed: legacy export name → postgresql_feed.public" {
  rewrites 'SELECT 1 FROM "platform-feed-export-prod".activity' \
           'SELECT 1 FROM postgresql_feed.public.activity'
}

@test "catalog: legacy export name + public_ → postgresql_catalog.public (stripped)" {
  rewrites 'SELECT 1 FROM "platform-catalog-export-prod".public_catalog_member' \
           'SELECT 1 FROM postgresql_catalog.public.catalog_member'
}

@test "industry-calc: legacy export name → postgresql_industry.public" {
  rewrites 'SELECT 1 FROM "platform-industry-calculations-export-prod".credit_score_charts' \
           'SELECT 1 FROM postgresql_industry.public.credit_score_charts'
}

# ── Guard: dry-run hook must short-circuit before kubectl ───────────────

@test "dry-run hook exits 0 without touching kubectl" {
  run bash "$TQ" "SHOW CATALOGS"
  [ "$status" -eq 0 ]
  [ "$output" = "SHOW CATALOGS" ]
  # if the guard regressed, the kubectl stub would have emitted its refusal
  ! echo "$output" | grep -q "kubectl call refused"
}
