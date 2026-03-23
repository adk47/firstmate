# Industry Data API Reference

## FastAPI Application

The API runs on port 8000 and serves catalog lookups and stats queries.

```python
# api/main.py
from fastapi import FastAPI

app = FastAPI(
    title="Industry Data API",
    version="1.0.0",
)

# Include routers
app.include_router(profiles_router, prefix="/api/v1")
app.include_router(tracks_router, prefix="/api/v1")
app.include_router(albums_router, prefix="/api/v1")
app.include_router(search_router, prefix="/api/v1")
app.include_router(stats_router, prefix="/api/v1")
```

## Profile Endpoints

```python
# GET /api/v1/profile/{id}
@router.get("/profile/{profile_id}")
async def get_profile(profile_id: str) -> ProfileResponse:
    """Get profile by ID with credits and stats."""
    profile = await catalog_profiles.find_one({"_id": profile_id})
    if not profile:
        raise HTTPException(404, "Profile not found")
    return ProfileResponse.from_mongo(profile)

# GET /api/v1/profile/{id}/credits
@router.get("/profile/{profile_id}/credits")
async def get_profile_credits(
    profile_id: str,
    role: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
) -> CreditsResponse:
    """Get credits for a profile."""
    ...
```

## Search Endpoints

```python
# GET /api/v1/search
@router.get("/search")
async def search(
    q: str,
    type: Literal["profile", "track", "album"] = "profile",
    limit: int = 20,
    offset: int = 0,
) -> SearchResponse:
    """Search across catalog entities."""
    ...
```

## Stats Endpoints

```python
# GET /api/v1/stats/profile/{id}
@router.get("/stats/profile/{profile_id}")
async def get_profile_stats(
    profile_id: str,
    sources: Optional[List[str]] = None,
    date_from: Optional[date] = None,
    date_to: Optional[date] = None,
) -> StatsResponse:
    """Get streaming stats for a profile."""
    ...
```

## Catalog Message Actions

Source: KT 2026-01-20 (Oleg Mamchich)

Full list of actions the catalog worker processes:

| Action | Purpose | Common Use |
|--------|---------|------------|
| `sync` | Sync raw entity to catalog | **Most common** — triggered after every raw update |
| `upsert` | Create/update raw entity | Admin changes, deletion marking |
| `delete` | Mark entity deleted | Via upsert with `is_deleted: true` |
| `link` | Associate raw ID with catalog ID | Manual linking in Retool |
| `unlink` | Remove raw ID from catalog entity | Undo bad links |
| `merge` | Combine two catalog entities | Duplicate profile cleanup |
| `add_analytics_link` | Associate analytics source | Link external analytics |
| `aggregate` | Trigger stats aggregation | Recompute derived fields |
| `add_member` | Add credit to entity | Manual credit addition |
| `update_member` | Update existing credit | Change role, etc. |
| `delete_member` | Remove credit from entity | Manual credit removal |

### Sync Action Details

The `sync` action is the workhorse of catalog processing:

```python
# Catalog message interface
{
    "action": "sync",           # Required
    "entity_type": "profile",   # profile, track, album
    "raw_id": "spotify:artist:123",
    "origin": "spotify"         # Source that triggered sync
}
```

Sync performs:
1. Find matching catalog entity (by raw ID, IPI, external link)
2. If not found and source is allowed → create new
3. Sort all raw sources by priority
4. Merge fields from highest priority sources
5. Save catalog entity

---

## SQS Message Formats

### Raw Queue Message

```json
{
  "source": "spotify",
  "action": "sync",
  "entity_type": "artist",
  "entity_id": "spotify:artist:123",
  "data": {
    "name": "Artist Name",
    "spotify_id": "123",
    "popularity": 85
  }
}
```

### Catalog Queue Message

```json
{
  "action": "merge",
  "source_id": "raw_spotify_artist_123",
  "target_id": "catalog_profile_456",
  "merge_fields": ["name", "image_url"]
}
```

### Analytics Queue Message

```json
{
  "profile_id": "catalog_profile_456",
  "source": "spotify",
  "stats": {
    "monthly_listeners": 1500000,
    "followers": 250000,
    "captured_at": "2024-01-15T00:00:00Z"
  }
}
```

## Response Models

```python
from pydantic import BaseModel

class ProfileResponse(BaseModel):
    id: str
    name: str
    image_url: Optional[str]
    source_ids: Dict[str, str]  # {spotify: "123", genius: "456"}
    credit_count: int
    total_streams: Optional[int]
    
class CreditsResponse(BaseModel):
    items: List[Credit]
    total: int
    limit: int
    offset: int
    
class Credit(BaseModel):
    track_id: str
    track_name: str
    role: str
    album_name: Optional[str]
    release_date: Optional[date]
```
