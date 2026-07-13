# Industry Data Gotchas

## MongoDB ObjectId vs String ID

```python
# WRONG - comparing string to ObjectId
profile = collection.find_one({"_id": "507f1f77bcf86cd799439011"})  # None!

# CORRECT - use ObjectId
from bson import ObjectId
profile = collection.find_one({"_id": ObjectId("507f1f77bcf86cd799439011")})

# Or store IDs as strings consistently
profile = collection.find_one({"profile_id": "507f1f77bcf86cd799439011"})
```

## MongoEngine vs PyMongo

The codebase uses both:
- **MongoEngine**: For workers (ORM-style)
- **Motor (async PyMongo)**: For FastAPI (async)

```python
# MongoEngine (sync, workers)
profile = RawProfile.objects.get(id=profile_id)

# Motor (async, API)
profile = await collection.find_one({"_id": profile_id})
```

Don't mix them in the same code path.

## SQS Message Visibility

Messages become visible again after visibility timeout:

```python
# WRONG - processing takes longer than visibility timeout
def process_message(message):
    result = very_long_operation()  # Takes 10 minutes
    # Message already visible to other workers!

# CORRECT - extend visibility for long operations
def process_message(message, sqs, queue_url):
    # Extend visibility every 60 seconds during processing
    def extend_visibility():
        while processing:
            sqs.change_message_visibility(
                QueueUrl=queue_url,
                ReceiptHandle=message['ReceiptHandle'],
                VisibilityTimeout=120,
            )
            time.sleep(60)
    
    thread = threading.Thread(target=extend_visibility)
    thread.start()
    ...
```

## Soft Delete Queries

Always filter out soft-deleted documents. Deletion state lives under the
`deleted` EMBEDDED SUBDOC (`db/collections/base.py` →
`deleted = EmbeddedDocumentField(Deleted)`), **not** at the top level —
top-level `is_deleted` / `deleted_timestamp` / `deleted_by` are always
null/missing (that read produced the task #200 false "resurrection" alarm):

```python
# WRONG - includes deleted profiles
profiles = CatalogProfile.objects.all()

# WRONG - top-level field does not exist; matches EVERY doc
profiles = CatalogProfile.objects(deleted_timestamp=None)

# CORRECT - exclude deleted via the deleted.* subdoc
profiles = CatalogProfile.objects(deleted__is_deleted__ne=True)

# CORRECT - raw pymongo predicate
db.catalog_profile.find({"deleted.is_deleted": {"$ne": True}})
```

## Merge Tracking

When profiles are merged, the source has `merged_to_id`:

```python
# Always check if profile was merged
profile = RawProfile.objects.get(id=profile_id)
if profile.merged_to_id:
    # Redirect to the merged target
    profile = CatalogProfile.objects.get(id=profile.merged_to_id)
```

## Source Priority Conflicts

When the same profile exists in multiple sources:

```python
# WRONG - arbitrary source wins
name = sources['spotify']['name'] or sources['genius']['name']

# CORRECT - use priority resolution
name = resolve_field('name', sources)  # Uses SOURCE_PRIORITY
```

## PostgreSQL Connection Pooling

```python
# WRONG - new connection per request
def get_stats(profile_id):
    engine = create_engine(DATABASE_URL)  # New connection!
    ...

# CORRECT - use connection pool
engine = create_engine(
    DATABASE_URL,
    pool_size=5,
    max_overflow=10,
    pool_pre_ping=True,
)

# Or use async with proper pool
async_engine = create_async_engine(DATABASE_URL, pool_size=5)
```

## Duplicate Message Handling

SQS can deliver the same message multiple times:

```python
# WRONG - creates duplicates
def process_message(message):
    profile = CatalogProfile(data=message['data'])
    profile.save()  # Might create duplicate!

# CORRECT - idempotent upsert
def process_message(message):
    CatalogProfile.objects(
        source=message['source'],
        source_id=message['source_id'],
    ).update_one(
        set__data=message['data'],
        set__updated_at=datetime.utcnow(),
        upsert=True,
    )
```

## Test Database Isolation

Tests use real MongoDB test DB, not mocks:

```python
# Tests connect to test database
# config_test.ini
[mongodb]
database = industry_db_test

# Always clean up after tests
@pytest.fixture(autouse=True)
def cleanup():
    yield
    RawProfile.drop_collection()
    CatalogProfile.drop_collection()
```

## KEDA Scaling Delays

KEDA scales based on SQS queue depth, but there's delay:

- Scale-up: ~30 seconds after queue depth increases
- Scale-down: ~5 minutes after queue empties (cooldown)

Don't expect instant scaling.

## High vs Medium Priority Queues

Use high-priority queues for:
- User-triggered operations
- Time-sensitive updates

Use medium-priority queues for:
- Batch processing
- Background sync

```python
# User requested profile update -> high priority
sqs.send_message(
    QueueUrl=HIGH_PRIORITY_QUEUE,
    MessageBody=json.dumps(message),
)

# Scheduled batch sync -> medium priority
sqs.send_message(
    QueueUrl=MEDIUM_PRIORITY_QUEUE,
    MessageBody=json.dumps(message),
)
```

## Spotify Credential Management

Source: KT meeting 2026-01-28

### Current State
- ~490 unique Spotify developer accounts (non-music-associated profiles to avoid blocking)
- Spotify has **blocked creation of new applications**, limiting scaling
- Some previously blocked credentials periodically start working again

### Big Artist Problem
When a "big artist" (Taylor Swift, Drake, etc.) enters the queue:
- High volume of API calls for their albums
- Can exhaust a single credential's rate limit quickly

**Mitigation**: Branch exists to randomize credentials for large artist requests.

### Queue Priority Issues
- **High-priority queue**: User/operations requests (should stay near zero)
- **Medium-priority queue**: Related entities (artist's albums), batch processing
- Currently: medium queue may fail due to Spotify rate limits
- Workers can be reallocated (reduce medium to 0, increase high)

### Monitoring Capture Queue Health
- Primary goal: keep credit request queue at zero
- Large reprocessing jobs (e.g., 9k missing credits) can unbalance queues
- Many credits auto-reverify after initial capture, so batch size matters less than processing rate

## Entity Creation Guardrails

Source: KT 2026-01-20 (Oleg Mamchich)

### Profile Types That Block Auto-Creation

```python
no_sync_profile_types = ['compilation_profile', 'non_music_profile']
```

If profile has these types, sync will NOT create a new catalog entity.

### Source-Specific Entity Creation Rules

| Source | Can Create Entity? | Condition |
|--------|-------------------|-----------|
| Spotify | Yes | Always (for artist type) |
| Muso | Yes | Always |
| Music | Yes | Always |
| Tidal | **Conditional** | Only if `type='professional'` |
| MLC | Organizations only | Cannot create profiles |
| Genius, Jaxsta | No | Credit data only, links to existing |

### Why Tidal Has a Special Rule

Tidal returns two profile types:
- `artist` — DO NOT create (would duplicate Spotify artist)
- `professional` — Safe to create (behind-the-scenes credits only)

This prevents duplicate profiles for the same person.

### Profile Sync Fallback Chain

When syncing a raw profile, the system tries to match in this order:

1. **By Muso raw ID** — Direct match to existing catalog profile
2. **By any raw ID** — Check if raw ID exists in any catalog profile's `raw_profile_ids`
3. **By IPI code** — MLC industry identifier (only MLC has this)
4. **By external link** — Genius sometimes provides Spotify IDs
5. **Create new** — If all above fail and source is allowed to create

### Recursive Merge Limits

APIs follow max 3-5 redirects for merged profiles. Avoid deep merge chains:

```
BAD:  A → B → C → D → E  (5 hops, may fail)
GOOD: A → Z, B → Z, C → Z  (all merge to single target)
```

---

## Sync Guard: `is_sync_enabled`

Never send incomplete entities to catalog sync:

```python
# WRONG - album from artist response is incomplete
if album_in_artist_response:
    send_to_catalog_queue(album)  # Corrupts data!

# CORRECT
if entity.is_sync_enabled:
    send_to_catalog_queue(entity)
```

Incomplete entities in catalog = corrupted product data.

---

## Zyte Pipeline (Analytics Data Collection)

Zyte (formerly "Zyte IG" — originally Instagram-focused) is an external scraping partner that collects **analytics/streaming data** from various platforms. For Spotify, this means stream counts and popularity only (NOT catalog or metadata). For Instagram, this includes video links, streams, and video data.

### Key Resources
| Resource | Location |
|----------|----------|
| **Zyte database** | Athena: `zyte_ig.*` (legacy naming) |
| **Input DAG** | MWAA: `export_zyte_input` |
| **Raw sender DAG** | MWAA: `run_zyte_industry_raw_sender` |
| **Output queue** | SQS: `analytics-capture-*` queues |
| **Onboarding** | Andre creates Athena tables from Zyte S3 dumps |

### Pipeline Flow
1. **Source onboarding**: Andre creates Athena table from Zyte's S3 data dump
2. **Input generation**: `export_zyte_input` DAG runs daily, produces ~3M entities:
   - Prioritizes by: popularity score, release recency (<30 days = higher), last capture date
   - Outputs to S3 for Zyte to process
3. **Data ingestion**: `run_zyte_industry_raw_sender` converts Zyte results to analytics queue messages
4. **Downstream**: Messages flow to `analytics-capture-*` SQS → Analytics Worker (analytics data only, not catalog)

### Monitoring
- Check MWAA DAG runs in Airflow UI (dev/prod)
- Zyte coverage: Spotify analytics only (stream counts/popularity — no catalog), Instagram (100% Zyte — video links, streams, video data)
- Analytics deduplication: Track ID granularity, system takes larger number on conflicts

### TikTok Scraping Challenges
**Status**: Unreliable (as of 2026-02)

| Issue | Details |
|-------|---------|
| **Root cause** | TikTok actively blocks scraping IPs |
| **Behavior** | Works briefly after monthly proxy refresh, then blocks |
| **Mitigation** | Aron contacted Zyte about taking over TikTok scraping |
| **Detection** | User reports of stale TikTok stats; CloudWatch errors in analytics worker |
| **Fallback** | None currently — data goes stale until proxy refresh |

**Owner**: Catalog team (escalate TikTok issues to Aron)

Source: KT 2026-02-02

---

## Label Disambiguation

Source: KT 2026-02-03

### The Problem

Spotify does not provide a label ID — only a **lowercase string name**. When two different labels share the same name (e.g., "Allison Records"), Muso cannot distinguish them.

### Symptoms

- Artists from unrelated labels appear under wrong label profile
- User requests to "remove collaborators from label"

### Temporary Fix

1. Create a new profile for one of the labels
2. Manually move incorrect credits to the new profile
3. **Caveat**: New tracks by moved artists will still assign to original profile (retains Spotify raw ID)

### Permanent Solution (TODO)

Implement custom rules for artist-to-label mapping in industry processing:

- Define which artists belong to which label profile
- Only assign credits if artist matches the mapping
- Task created: "labels disambiguation" (high priority)

---

## Stream Merging Logic

Source: KT 2026-02-04

### Current Rules

Tracks are merged if:

- Stream count > **1,000** (changed from 10,000 as of 2026-02-04)
- Stream difference within **30%**

### Why This Matters

Tracks released as single, then on album, may show duplicate streams. Merging deduplicates.

### Investigating Stream Count Changes

If users report sudden stream count decreases, check for merged tracks. Use the merged tracks query in `operations/data-access.md`.

---

## MLC Profile Auto-Linking

Source: KT 2026-02-04

### Problem

MLC profiles **without an IPI** (Industry Standard Profile Identifier) may be auto-linked to wrong profiles by name similarity alone.

### Symptoms

- Songwriter/lyricist credits appearing on wrong artist profile
- User reports "these lyricist credits aren't mine"

### Fix Procedure

1. Identify the MLC profile ID causing incorrect credits
2. **Unlink** the MLC profile from the wrong catalog profile
3. **Link** it to the correct profile (e.g., "Tyler Hicks" → "Tyler Jeffrey Hicks")
4. Manually remove incorrect credits from main profile (overrides raw source)
5. If MLC profile has no IPI, it won't auto-create a new profile

### Root Cause

The platform auto-links MLC profiles to catalog profiles based on name similarity when no IPI is present. This can incorrectly merge two different people with similar names.

---

## Profile Merging Decisions

Source: KT 2026-02-04

### When to Merge Artists with Professional Profiles

Single artists are sometimes merged with their professional profiles for simplification:

- **Example**: Taylor Swift (artist) merged with Taylor Swift (professional profile)

### When NOT to Merge

Merging may not be appropriate when:

- Artist has separate professional identity (e.g., Skrillex vs Sonny Moore)
- Legal/business reasons require separation
- Different credit types should remain distinct

### Automatic Merge Prevention

Profiles will NOT auto-merge if:

- Track similarity < 50%
- Name similarity < 80%
- **Claimed profiles are NEVER merged automatically**
