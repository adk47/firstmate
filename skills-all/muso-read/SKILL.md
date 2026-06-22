---
name: muso-read
description: |
  READ-ONLY access to Muso's own data through the `muso` CLI — for research and
  lookups, never writes. Look up profiles, tracks, albums, users, teams, and the
  claiming queue, hit any admin-API GET route, run SELECT-only Trino queries over
  the data lake (catalog, streaming stats, growth DB), and read the marketing
  B2B-ADS-intelligence NocoDB base (companies/contacts).

  Use when: "look up this profile/track/artist in Muso", "how many ... in our
  data", "what does Muso know about ...", "query the data lake", "Muso analytics",
  "check this user/team", "pull stats for ...", "look up this company/contact in
  the B2B ads intelligence base".
  Triggers: "muso data", "look up profile", "muso analytics", "data lake",
  "trino", "how many profiles/tracks/streams", "what's in our database",
  "nocodb", "B2B ads intelligence", "marketing CRM base".
compatibility: |
  Main gateway on node-8 only (NOT edge/Caroline). Uses the host shell (`exec`)
  to call scripts/muso-read.sh, an allowlist wrapper around the deployed `muso`
  binary (/usr/local/bin/muso). Auth is the gateway's existing MUSO_ADMIN_* env —
  no new credential. NocoDB reads ride NOCODB_API_TOKEN/NOCODB_BASE_ID (also
  already in /etc/openclaw/main.env, from company-finder; needs `muso` v0.3.0+,
  which is the pinned binary). The wrapper is reject-by-default: only read commands
  reach `muso`; every write/merge/non-GET/non-SELECT/nocodb-write is refused before
  `muso` runs.
metadata:
  version: "0.2"
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

# NocoDB reads — the marketing B2B-ADS-intelligence base (companies/contacts):
$R nocodb whoami                              # identity + scope sanity
$R nocodb tables list --json                  # tables in the default base
$R nocodb tables get --table <m…>             # full column list for a table
$R nocodb records list --table <m…> --where '(Status,eq,Follow Up 2)' --json
$R nocodb records count --table <m…> --where '(…)'   # exact, server-side
$R nocodb raw GET /api/v2/meta/bases/p11hvpwapu4hv0x  # base detail (GET-only)

# Self-describing manual for command/flag/route details:
$R agent-docs
```

> ⚠️ NocoDB Cloud silently clamps a single `records list` to 100 rows. To read or
> aggregate a whole table, paginate (`--limit 100 --offset <n>`) until
> `pageInfo.isLastPage` — see the **muso-nocodb** skill's `nocodb_fetch_all`.

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
- **NocoDB (B2B-ADS-intelligence base):** `nocodb whoami`, `nocodb tables
  list|get`, `nocodb records list|get|count`, and `nocodb raw GET <path>`
  (GET-only). The marketing companies/contacts CRM base — reads only. For schema
  detail, table IDs, where-clause syntax, and the long tail, see the
  **muso-nocodb** skill (which also carries the write path, for @CMO/@Ops).

## What is refused (route to @Ops; NocoDB writes to @CMO)

`api` with POST/PUT/PATCH/DELETE · `profiles/tracks merge|unmerge|update|delete` ·
credit-request status changes · subscription/VIP writes · any `query` that is not
a single SELECT/WITH/SHOW/DESCRIBE/EXPLAIN/VALUES statement (DELETE/INSERT/UPDATE/
DROP/etc. and multi-statement queries are blocked) · `nocodb records
create|update|delete` · `nocodb tables create|delete` · non-GET `nocodb raw`
(NocoDB writes route to @CMO/@Ops). On a refusal the wrapper exits 3 with a
one-line reason and `muso` is never called.

## After it returns

Treat Muso data like any other source: cite what you pulled (the query or route),
don't extrapolate beyond the rows, and flag staleness if a matview lag matters.
If a read fails (`auth_required`, etc.), report it — don't answer from memory.

## Note on enforcement

This wrapper is the sanctioned, accident-safe read surface; it is not a hard
security boundary (an agent with full exec could call `muso` directly). The
ironclad version is a scoped read-only Muso credential — a tracked follow-up.
