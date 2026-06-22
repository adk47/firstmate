---
name: muso-read
description: |
  READ-ONLY access to Muso's own data through the `muso` CLI — for research and
  lookups, never writes. Look up profiles, tracks, albums, users, teams, and the
  claiming queue, hit any admin-API GET route, and run SELECT-only Trino queries
  over the data lake (catalog, streaming stats, growth DB).

  Use when: "look up this profile/track/artist in Muso", "how many ... in our
  data", "what does Muso know about ...", "query the data lake", "Muso analytics",
  "check this user/team", "pull stats for ...".
  Triggers: "muso data", "look up profile", "muso analytics", "data lake",
  "trino", "how many profiles/tracks/streams", "what's in our database".
compatibility: |
  Main gateway on node-8 only (NOT edge/Caroline). Uses the host shell (`exec`)
  to call scripts/muso-read.sh, an allowlist wrapper around the deployed `muso`
  binary (/usr/local/bin/muso). Auth is the gateway's existing MUSO_ADMIN_* env —
  no new credential. The wrapper is reject-by-default: only read commands reach
  `muso`; every write/merge/non-GET/non-SELECT is refused before `muso` runs.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-read

The sanctioned **read-only** path into Muso's own data. This wrapper only ever
lets read commands through to `muso`; it refuses writes, merges, status changes,
deletes, non-GET `api` calls, and non-SELECT Trino queries before the binary is
invoked. **Never try to write to Muso — route any Muso write (merge, status
change, credit/profile mutation, delete) to @Ops.** Do not call the raw `muso`
binary or the `muso-cli` skill to get around this.

## How to call it

```bash
SKILL_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-read"
R="bash $SKILL_DIR/scripts/muso-read.sh"

# Typed lookups (JSON):
$R profiles search "Billie Eilish" --json     # {items, count}
$R profiles get <profileId> --json
$R tracks search "title" --json
$R users search "email-or-name" --json
$R teams get <teamId> --json
$R claiming list --json

# Any admin-API GET route (the generic read escape hatch):
$R api GET '/admin/profile/<id>/credits' --json
$R api --list-routes                          # discover available routes

# Trino SELECT analytics (CSV by default; --format json for NDJSON rows):
$R query "SELECT COUNT(*) FROM postgresql_core.public.users"
$R query - --format json <<'SQL'
SELECT artist_name, monthly_listeners
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE artist_name ILIKE '%example%'
LIMIT 25
SQL

# Self-describing manual for command/flag/route details:
$R agent-docs
```

## What you can read

- **Typed:** `profiles search|get`, `tracks search|get`, `albums get`,
  `users search`, `teams get`, `claiming list|get`, `health`, `auth status`.
- **Admin API (GET only):** any `/admin/...` GET route via `api GET <route>`
  (≈139 read routes — `api --list-routes` to discover; `agent-docs` for the map).
- **Trino SELECT** via `query` — the big data-lake tables for research:
  `matvw_catalog_profile` (~29M profiles), `matvw_catalog_track` (~190M tracks),
  `matvw_stats_track_daily` (~3.3B streaming rows), `postgresql_core.public.users`
  / `subscriptions` / `claiming`. See the **muso-query-writer** skill for table
  schemas, the modern catalog.schema names, and cost-aware query patterns.

## What is refused (route to @Ops)

`api` with POST/PUT/PATCH/DELETE · `profiles/tracks merge|unmerge|update|delete` ·
credit-request status changes · subscription/VIP writes · any `query` that is not
a single SELECT/WITH/SHOW/DESCRIBE/EXPLAIN/VALUES statement (DELETE/INSERT/UPDATE/
DROP/etc. and multi-statement queries are blocked). On a refusal the wrapper exits
3 with a one-line reason and `muso` is never called.

## After it returns

Treat Muso data like any other source: cite what you pulled (the query or route),
don't extrapolate beyond the rows, and flag staleness if a matview lag matters.
If a read fails (`auth_required`, etc.), report it — don't answer from memory.

## Note on enforcement

This wrapper is the sanctioned, accident-safe read surface; it is not a hard
security boundary (an agent with full exec could call `muso` directly). The
ironclad version is a scoped read-only Muso credential — a tracked follow-up.
