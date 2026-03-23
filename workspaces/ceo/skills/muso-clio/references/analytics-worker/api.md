# Analytics Worker API & Messages

## Input Message Format

```json
{
  "action": "stats",
  "source": "spotify",
  "entity_type": "artist",
  "entity_id": "spotify:artist:123abc",
  "priority": "high",
  "metadata": {
    "profile_id": "muso_profile_456",
    "requested_by": "core-backend"
  }
}
```

## Action Types

### Stats Action
Capture streaming metrics for an entity:

```json
{
  "action": "stats",
  "source": "spotify",
  "entity_type": "artist",
  "entity_id": "123abc",
  "metadata": {
    "profile_id": "muso_456"
  }
}
```

### Catalog Action
Fetch metadata for an entity:

```json
{
  "action": "catalog",
  "source": "spotify",
  "entity_type": "artist",
  "entity_id": "123abc"
}
```

### Search Action
Search for entity across platform:

```json
{
  "action": "search",
  "source": "spotify",
  "entity_type": "artist",
  "query": "Artist Name",
  "filters": {
    "isrc": "USRC12345678"
  }
}
```

## Output Message Format

Results go to `QUEUE_RESULTS` or `QUEUE_RESULTS_CATALOG`:

```json
{
  "source": "spotify",
  "action": "stats",
  "entity_id": "123abc",
  "success": true,
  "data": {
    "monthly_listeners": 1500000,
    "followers": 250000,
    "popularity": 85
  },
  "s3_path": "s3://bucket/capture/spotify/stats/2024/01/15/123abc.json",
  "captured_at": "2024-01-15T12:00:00Z"
}
```

## Platform-Specific Data

### Spotify Stats
```json
{
  "monthly_listeners": 1500000,
  "followers": 250000,
  "popularity": 85,
  "top_cities": [
    {"city": "Los Angeles", "listeners": 50000},
    {"city": "New York", "listeners": 45000}
  ]
}
```

### YouTube Stats
```json
{
  "subscribers": 500000,
  "total_views": 100000000,
  "video_count": 150,
  "recent_videos": [
    {"title": "Video 1", "views": 1000000}
  ]
}
```

### TikTok Stats
```json
{
  "followers": 2000000,
  "likes": 50000000,
  "video_count": 200,
  "sounds_used": 15000
}
```

### Shazam Stats
```json
{
  "shazams": 5000000,
  "top_countries": [
    {"country": "US", "shazams": 1000000}
  ]
}
```

## S3 Storage Path Convention

```
s3://{bucket}/capture/{source}/{action}/{year}/{month}/{day}/{entity_id}.json
```

Example:
```
s3://muso-analytics/capture/spotify/stats/2024/01/15/123abc.json
```

## Error Response

```json
{
  "source": "spotify",
  "action": "stats",
  "entity_id": "123abc",
  "success": false,
  "error": {
    "code": "RATE_LIMITED",
    "message": "Too many requests",
    "retry_after": 60
  }
}
```
