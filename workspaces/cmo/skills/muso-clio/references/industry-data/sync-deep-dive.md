# Catalog Sync Deep Dive

Source: KT meeting 2026-01-28 (Industry Processing 1)

## Entity Terminology Mapping

| Raw (Source) | Catalog (Unified) | Relationship |
|--------------|-------------------|--------------|
| Artist | Profile | 1:many (multiple raw artists can merge to one profile) |
| Recording | Track | 1:many (Track is abstraction over multiple recordings/ISRCs) |
| Release | Album | 1:many (Album groups related releases) |

Track is the deduplication layer - merges recordings from Spotify, Tidal, etc. into a single entity for unified analytics.

## Sync Workflow

```
Raw Entity → is_sync_enabled check → Catalog Queue → Find/Create Catalog Entity → Merge → Update Embedded
```

### `is_sync_enabled` Guard

**Critical**: Only send entities to catalog queue when fully captured.

```python
# WRONG - sends incomplete album from artist response
if album_in_response:
    send_to_catalog_queue(album)  # Corrupts product data!

# CORRECT - check sync eligibility
if album.is_sync_enabled:
    send_to_catalog_queue(album)
```

An album discovered in an artist response is incomplete. Sending it to catalog sync before full capture results in corrupted data showing in the product.

### Normal Sync vs Forceful Resync

| Type | Trigger | Behavior |
|------|---------|----------|
| Normal sync | Automatic after raw processing | "Cheap" - updates changed fields only |
| Forceful resync | Manual or data quality checks | Full re-merge from all raw IDs |

Forceful resync is expensive but necessary when:
- Data quality checks detect inconsistencies
- Manual merge operations
- Source priority changes

## Profile Sync Logic

### Finding Existing Profiles

Order of matching criteria:
1. **Raw profile ID** - direct match
2. **Muso profile ID** - internal reference
3. **IPI** - industry identifier
4. **External link** - social/streaming URLs

```python
def find_catalog_profile(raw_profile):
    # Try each criteria in priority order
    if match := find_by_raw_id(raw_profile.id):
        return match
    if raw_profile.muso_id and (match := find_by_muso_id(raw_profile.muso_id)):
        append_raw_id(match, raw_profile.id)
        return match
    if raw_profile.ipi and (match := find_by_ipi(raw_profile.ipi)):
        append_raw_id(match, raw_profile.id)
        return match
    # ... external link matching
    return None  # Will create new profile
```

### Scoring and Merge Order

Profiles are sorted **ascending** by score, so **last wins**:

```python
sort_key = (
    source_priority,      # Higher = more trusted
    is_deleted == False,  # Non-deleted wins
    popularity,           # More popular = wins
    has_release_date,     # Having date wins
    id                    # Tie-breaker for consistency
)
```

### Field Handling During Sync

| Field Type | Behavior | Example |
|------------|----------|---------|
| **Overwrite** | Higher priority source replaces | first_name, last_name, contacts |
| **Extend** | Values are merged/appended | IPIs, ISRCs, UPCs |
| **User-only** | Only from Muso source | about/bio (legal protection) |

```python
# Identifiers are extended to preserve all references
profile.ipis = list(set(profile.ipis + raw_profile.ipis))
profile.isrcs = list(set(profile.isrcs + raw_profile.isrcs))

# Basic fields are overwritten
profile.first_name = raw_profile.first_name  # Last (highest priority) wins
```

## Embedded Updates

Artist info is **denormalized** into Track and Release documents for query performance.

```python
def update_embedded_artist(profile_id):
    """When profile changes, update all embedded references."""
    profile = CatalogProfile.get(profile_id)

    # Update in all tracks where this artist appears
    Track.objects(
        artist_ids__contains=profile_id
    ).update(
        set__embedded_artists__S__name=profile.name,
        set__embedded_artists__S__image=profile.image,
    )

    # Same for releases
    Release.objects(artist_ids__contains=profile_id).update(...)
```

**Trade-off**: Faster reads, but profile updates must cascade to millions of tracks.

## Recursive Capture

When processing a raw entity, related entities may need capture:

```python
def process_raw_artist(artist):
    # Artist response includes album IDs
    for album_id in artist.albums:
        if not already_captured(album_id):
            # Send to data-capture service
            send_capture_request(album_id, source='spotify')
```

### Capture Request Collection (TTL)

To prevent duplicate capture requests while processing is in-flight:

```python
# MongoDB collection with TTL index
capture_requests = {
    "entity_id": "spotify:album:123",
    "requested_at": datetime,  # TTL: ~1 hour
}
```

If an entity is already in `capture_requests`, don't send another request.

## Aurora Migration (In Progress)

### Why Aurora?
MongoDB I/O limitations with 80M+ daily record updates. Aurora provides better write performance for high-volume stat updates.

### Current Challenges
1. **Real-time lag**: Aurora table updated daily via snapshot, so new credits may not appear until next day
2. **Missing sort capability**: No sort-by-artist-ID support yet (may need schema change)
3. **Client-side logic**: May need changes to handle delayed credit visibility

## Catalog Action Types

| Action | Purpose | Frequency |
|--------|---------|-----------|
| **sync** | Merge raw → catalog | Most common |
| **update** | Update existing catalog entity | Common |
| **aggregations** | Compute derived stats | Periodic |
| **operations** | Manual admin actions | Rare |
