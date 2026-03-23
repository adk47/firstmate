---
name: muso-data-expert
description: |
  Muso.AI data model and database schema expert. Entity relationships,
  database structures, and data architecture guidance.
  Triggers: "data model", "schema", "entity", "database", "aurora", "mongodb"
compatibility: |
  Works in any agent. Optional: DB access (Aurora/MongoDB) and/or Admin UI access for write operations.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# muso-data-expert

Muso.AI data model and database schema expert. Provides comprehensive knowledge of entity relationships, database structures, and data architecture.

## When to Use

- Understanding entity relationships (Profile, Track, Credit, Album, Release)
- Querying production databases (Aurora, MongoDB)
- Working with the data lake and analytics tables
- Understanding data capture and processing pipelines
- Debugging data integrity issues
- **When users ask to UPDATE or change data** - guide them to the correct source system

## Triggers

- "data model", "schema", "entity", "database"
- "profile", "track", "credit", "album", "release"
- "aurora", "mongodb", "analytics"
- "capture", "raw entity", "catalog entity"
- "update", "change", "modify", "edit"

## Source of Truth - Where Data Lives

**Athena is READ-ONLY.** When users ask to UPDATE data:

| Entity | Source of Truth | How to Update |
|--------|-----------------|---------------|
| Profile metadata (name, bio, image, `profile_type`) | MongoDB `catalog_profile` | [Admin UI](https://admin-production.muso.ai/) or direct MongoDB |
| Profile claimed status | PostgreSQL `core_backend.profiles` | [Admin UI](https://admin-production.muso.ai/) or Aurora |
| User data (email, auth) | PostgreSQL `core_backend.users` | [Admin UI](https://admin-production.muso.ai/) or Aurora |
| Track/Album data | MongoDB `catalog_track`/`catalog_release` | Automated pipelines (rarely manual) |
| Streaming stats | PostgreSQL `platform_stats.track_daily` | Automated pipelines only |
| **Credits** | MongoDB `catalog_track.profiles[]` | User API, CSV import, or MongoDB → re-materialize (see Credit Update Guide below) |

**Key Resource URLs (always cite in responses):**

| Resource | URL |
|----------|-----|
| Admin Panel (Prod) | https://admin-production.muso.ai/ |
| Admin Panel (Dev) | https://admin-nonproduction.muso.ai/ |
| DB Tunneling | https://www.notion.so/1e30aeed21ad80d08d62fc7f9757fd19 |
| MongoDB Access | https://www.notion.so/adb0059a507743bd8120be793a6648df |
| Retool (Internal Admin) | https://www.notion.so/af5412b08fc9409e81cdce6a017c8fdf |

**MongoDB Access:** SSH tunneling via bastion hosts. Credentials in Keybase (`musoai.infra`).

For complete entity → backend mapping, install the `muso-clio` skill and see `references/data-model/source-map.md`.

## Reference

See [reference.md](./reference.md) for complete documentation including:
- Entity definitions and relationships
- Database schema details
- Data pipeline architecture
- Query patterns and examples

## Known Gaps

The following areas have limited coverage from knowledge transfer sessions:
- **Roster Seat** - Entity mentioned in bootstrap but not found in extracted items
- **Claiming Request** - Entity mentioned in bootstrap but not found in extracted items

These may require additional investigation or documentation.
