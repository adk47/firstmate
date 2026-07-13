# Industry Data Patterns

## Raw Worker Pattern

```python
# process_raw.py
import boto3
from mongoengine import connect

class RawProcessor:
    def __init__(self, config):
        self.sqs = boto3.client('sqs')
        self.queue_url = config['sqs_raw_queue']
        connect(host=config['mongodb_uri'])
    
    def run(self):
        while True:
            messages = self.sqs.receive_message(
                QueueUrl=self.queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
            ).get('Messages', [])
            
            for message in messages:
                try:
                    self.process_message(message)
                    self.sqs.delete_message(
                        QueueUrl=self.queue_url,
                        ReceiptHandle=message['ReceiptHandle'],
                    )
                except Exception as e:
                    logger.error(f"Failed to process: {e}")
    
    def process_message(self, message):
        body = json.loads(message['Body'])
        source = body['source']
        action = body['action']
        
        processor = self.get_processor(source)
        processor.process(action, body['data'])
```

## MongoDB Document Pattern

```python
# models/raw_profile.py
from mongoengine import Document, StringField, DictField, DateTimeField

class RawSpotifyArtist(Document):
    meta = {
        'collection': 'raw_spotify_artists',
        'indexes': [
            'spotify_id',
            'updated_at',
        ]
    }
    
    spotify_id = StringField(required=True, unique=True)
    name = StringField(required=True)
    data = DictField()  # Full raw response
    updated_at = DateTimeField()
    created_at = DateTimeField()
```

## Catalog Merge Pattern

```python
# processors/catalog_processor.py
class CatalogProcessor:
    def merge_profiles(self, source_id: str, target_id: str, merge_fields: List[str]):
        """Merge source profile into target."""
        source = RawProfile.objects.get(id=source_id)
        target = CatalogProfile.objects.get(id=target_id)
        
        # Update fields
        for field in merge_fields:
            if hasattr(source, field) and getattr(source, field):
                setattr(target, field, getattr(source, field))
        
        # Track the merge
        target.source_ids[source.source] = source.source_id
        target.merged_from.append(source_id)
        target.save()
        
        # Mark source as merged
        source.merged_to_id = target_id
        source.save()
```

## Soft Delete Pattern

**Source**: `industry-data-processing/db/collections/base.py` +
`db/collections/common/deleted.py` / `action_by.py`

All documents (raw_* and catalog_*) carry deletion state in the `deleted`
**embedded subdoc** — never as top-level fields:

```python
class ActionBy(EmbeddedDocument):
    id = StringField()        # ops email / admin user id / raw source
    type = EnumField(Type)    # "operations" | "user" | "raw"
    sub_type = StringField()  # e.g. "retool", "clio", "backend"

class Deleted(EmbeddedDocument):
    is_deleted = BooleanField(default=False)
    deleted_timestamp = DateTimeField(default=None)
    deleted_by = EmbeddedDocumentField(ActionBy)

class BaseCollection(Document):
    # ... fields ...
    deleted = EmbeddedDocumentField(Deleted, default=Deleted)
```

Query via the subdoc paths (`deleted.is_deleted`, `deleted.deleted_timestamp`,
`deleted.deleted_by.*`):

```python
# non-deleted documents
CatalogProfile.objects(deleted__is_deleted__ne=True)

# raw pymongo
db.catalog_profile.find({"deleted.is_deleted": {"$ne": True}})
```

Top-level `is_deleted` / `deleted_timestamp` / `deleted_by` reads return
null for every doc and mis-classify deleted profiles as active
(task #200 false-resurrection RCA, 2026-07).

## Source Priority Resolution

**Source**: `industry-data-processing/db/collections/common/source_type.py`

When the same entity exists in multiple raw sources, fields are merged using source priority.
**Higher value = higher priority** (last wins in ascending sort).

```python
# db/collections/common/source_type.py
class SourcePriority(Enum):
    muso = 6      # Highest - internal/verified data always wins
    spotify = 5   # Primary catalog source
    mlc = 4       # Composition/work data
    tidal = 3     # Secondary streaming data
    jaxsta = 2    # Credits database
    genius = 1    # Lyrics/annotations (lowest)
```

| Priority | Source  | Value | Notes                              |
|----------|---------|-------|------------------------------------|
| 1st      | Muso    | 6     | Internal/verified data always wins |
| 2nd      | Spotify | 5     | Primary catalog source             |
| 3rd      | MLC     | 4     | Composition/work data              |
| 4th      | Tidal   | 3     | Secondary streaming data           |
| 5th      | Jaxsta  | 2     | Credits database                   |
| 6th      | Genius  | 1     | Lyrics/annotations (lowest)        |

### Merge Sort Logic

**Source**: `processors/catalog/sync_processor.py` → `_get_default_score()`

During catalog sync, entities are sorted ascending (so **last wins**):

```python
sort_expression = (
    is_main_entity,           # Main entities prioritized
    source_priority,          # Higher value wins
    is_deleted == False,      # Non-deleted wins
    type_priority,            # Entity type weight
    popularity,               # Higher popularity wins
    is_release_date_present,  # Having release date wins
    days_since_release,       # Earlier release = higher priority
    non_compilation,          # Non-compilations preferred
    id                        # Tie-breaker
)
```

### Credit-Specific Priority

For credits, there's an additional layer:

1. **Manually verified credits** (highest)
2. **Credits from credit sources** (Tidal, Jaxsta)
3. **Spotify credits**
4. **Other sources** (lowest)

### Example

If Spotify says a track's name is "Blinding Lights" but Muso has it as "Blinding Lights (Remix)",
**Muso wins** because priority 6 > 5.

## Stats Aggregation Pattern

```python
# process_analytics.py
from sqlalchemy import text

def update_profile_stats(profile_id: str, source: str, stats: Dict):
    """Upsert profile stats."""
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO stats.profile_stats 
                (profile_id, source, metric, value, captured_at)
            VALUES 
                (:profile_id, :source, :metric, :value, :captured_at)
            ON CONFLICT (profile_id, source, metric, captured_at)
            DO UPDATE SET value = EXCLUDED.value
        """), [
            {
                'profile_id': profile_id,
                'source': source,
                'metric': metric,
                'value': value,
                'captured_at': stats['captured_at'],
            }
            for metric, value in stats.items()
            if metric != 'captured_at'
        ])
```

## FastAPI Dependency Pattern

```python
# api/dependencies.py
from functools import lru_cache
from motor.motor_asyncio import AsyncIOMotorClient

@lru_cache()
def get_mongo_client() -> AsyncIOMotorClient:
    return AsyncIOMotorClient(settings.MONGO_URI)

async def get_catalog_db():
    client = get_mongo_client()
    return client[settings.MONGO_DATABASE]

# Usage in routes
@router.get("/profile/{id}")
async def get_profile(
    id: str,
    db = Depends(get_catalog_db),
):
    profile = await db.catalog_profiles.find_one({"_id": id})
    ...
```

## Batch Processing Pattern

```python
def process_batch(messages: List[Dict], batch_size: int = 100):
    """Process messages in batches for efficiency."""
    for i in range(0, len(messages), batch_size):
        batch = messages[i:i + batch_size]

        # Bulk operations are faster
        operations = [
            UpdateOne(
                {"_id": msg["id"]},
                {"$set": msg["data"]},
                upsert=True,
            )
            for msg in batch
        ]

        collection.bulk_write(operations, ordered=False)
```

## MongoDB Index Strategy for Sorting

Source: KT meeting 2026-01-28

### Composite Index Pattern
For sorted queries (e.g., credits by release date), indices must include:
1. Filter fields (profile_id, deleted.is_deleted)
2. Sort field (release_date)
3. **ID as final field** (ensures consistent ordering)

```python
meta = {
    'indexes': [
        # CORRECT - ID at end for consistent ordering
        [('profile_id', 1), ('deleted.is_deleted', 1), ('release_date', -1), ('_id', 1)],
    ]
}
```

Without ID at the end, results with identical sort values may return in inconsistent order across queries.

## Recursive Capture Pattern

When processing raw entities, discover and capture related entities:

```python
def process_raw_artist(artist):
    for album_id in artist.album_ids:
        if not is_capture_pending(album_id):
            send_capture_request(album_id, priority='medium')
            mark_capture_pending(album_id, ttl_hours=1)
```

### Capture Request Collection

MongoDB collection with TTL index prevents duplicate capture requests:

```python
# Check before sending
if capture_requests.find_one({"entity_id": f"{source}:{entity_id}"}):
    return  # Already pending

# Insert with TTL
capture_requests.insert_one({
    "entity_id": f"{source}:{entity_id}",
    "requested_at": datetime.utcnow(),  # TTL: ~1 hour
})
send_capture_request(entity_id)
```
