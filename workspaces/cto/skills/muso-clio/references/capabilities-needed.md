# Clio Capabilities Needed

Tracking real requests that inform what tools/automation to build.

## Status Legend
- `[ ]` Not started
- `[~]` In progress / partially solved
- `[x]` Implemented

---

## MCP Tools (In Design)

**Documentation**: `mcp-tools/ (in this repo)`

| Tool | Purpose | Status |
|------|---------|--------|
| `clio_sql_query` | Read-only SQL against Postgres | `[~]` Schema designed |
| `clio_mongo_query` | Read-only MongoDB queries | `[~]` Schema designed |
| `clio_export_csv` | Export results to CSV | `[~]` Schema designed |
| `clio_saved_queries` | Run pre-approved templates | `[~]` Schema designed |
| `clio_schema_info` | Get table/collection schemas | `[~]` Schema designed |

---

## Data Extraction & Analytics

### Business Analyst Queries (Marketing/Fede)
- [~] Ad-hoc data queries for marketing insights → **clio_sql_query**
- [~] Profile growth metrics → **clio_saved_queries**
- [~] Engagement analytics → **clio_saved_queries**
- [~] Cohort analysis → **clio_saved_queries** (marketing_user_cohort template)

**Pattern**: SQL-like queries against core/analytics DBs
**Access needed**: Read-only analytics DB, possibly stats DB
**MCP Tool**: `clio_sql_query`, `clio_saved_queries`

---

## Profile Operations

### Profile Role Updates
- [ ] Change profile roles (e.g., "Producer Collective, Artist")
- [ ] Example: https://credits.muso.ai/profile/874be37f-8a58-4303-9f5d-e0f7fe3ff56a

**Pattern**: Admin profile edits via API or direct DB
**Access needed**: Core backend admin API

### IPI Linking
- [ ] Link IPIs to publisher profiles
- [ ] Self-service during onboarding (future)

**Pattern**: Profile metadata update
**Access needed**: Profile write access

### Profile Merging
- [ ] Merge duplicate profiles
- [ ] Consolidate credits and stats

**Pattern**: Catalog merge operation
**Access needed**: Industry data processing

---

## Export Capabilities

### Custom Credit Exports
- [~] Configurable columns: Title, Artist(s), Release Date, Streams, ISRC → **clio_export_csv**
- [~] Filter by credit type (songwriting/composer only) → **clio_saved_queries** (profile_credits_export)
- [~] Include applicable credits per song → **clio_saved_queries** (profile_credits_export)
- [ ] Example profiles:
  - https://credits.muso.ai/profile/5759b964-8368-4e68-92ab-5b565219e5d0
  - https://credits.muso.ai/profile/6f02bef5-ca5d-429f-8d41-1041a08c23df

**Pattern**: Profile credits → CSV with joins to stats
**Access needed**: Catalog DB + stats DB
**MCP Tool**: `clio_export_csv`, `clio_saved_queries`
**Saved Query Template**: `profile_credits_export.yaml`

### Bulk Audit Exports
- [ ] Company-wide catalog exports
- [ ] "Export all" button (may be in ClickUp already)

**Pattern**: Batch export with progress tracking
**Access needed**: Catalog DB read

---

## Automation

### Studio Credit Automation
- [ ] Auto-add credits attributed to staff to studio page
- [ ] Future: prompt studio to accept/reject before adding

**Pattern**: Trigger on new credit → check staff association → queue for approval
**Access needed**: Credit write, notification system (Knock)

---

## Request Log

| Date | Requester | Request | Status |
|------|-----------|---------|--------|
| 2025-01-16 | Fede | Business analyst data extraction | `[ ]` |
| 2025-01-16 | Biz user | Custom credit export (Lyric Noel) | `[ ]` |
| 2025-01-16 | Internal | Profile role update (Bazs Hitters) | `[ ]` |
| 2025-01-16 | Internal | IPI linking to publishers | `[ ]` |
| 2025-01-16 | Internal | Studio credit automation | `[ ]` |
| 2025-01-16 | Internal | Bulk audit exports | `[ ]` |
