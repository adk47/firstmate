# Analytics Worker Gotchas

## ⚠️ CRITICAL: Spotify API Changes (February 2026)

**Effective Dates:**
- **February 11, 2026**: All NEW Development Mode Client IDs
- **March 9, 2026**: All EXISTING Development Mode Client IDs

**New Restrictions:**
1. **Spotify Premium Required**: Development Mode now requires a Spotify Premium account
2. **One Client ID Limit**: Developers limited to one Development Mode Client ID
3. **Five User Limit**: Each Client ID limited to five authorized users
4. **Limited Endpoints**: API access restricted to a smaller set of supported endpoints

**Impact on Muso.AI:**

Muso currently uses **470+ Spotify Client IDs** with credential rotation to handle rate limits. This approach will NO LONGER WORK after March 9, 2026.

**Required Actions:**
1. **Migrate to Extended Quota Mode** (requires Spotify approval)
   - Application review process
   - Terms of Service agreement
   - Quota limits based on use case
2. **Alternative**: Use unauthenticated methods (partner API token extraction)
   - See `spotify-data-flow.md` for current implementation
   - Extract token from `https://open.spotify.com/embed/` pages
   - Limited to publicly available data

**References:**
- [Spotify Blog: Developer Access Update](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security)
- [API Changes Documentation](https://developer.spotify.com/documentation/web-api/references/changes/february-2026)

**Status as of February 2026:**
- Current implementation: 470 rotating credentials (works until March 9)
- Recommended path: Apply for Extended Quota Mode OR migrate to unauthenticated partner API

## Platform Rate Limits

Each platform has different rate limits:

| Platform | Limit | Notes |
|----------|-------|-------|
| Spotify | 100 req/min | Authenticated endpoint |
| YouTube | 10,000 units/day | Each request = 1-100 units |
| TikTok | Varies | Use session cookies |
| Shazam | 500 req/min | Unofficial API |

Always implement rate limiting per platform.

## Spotify Token Refresh

Spotify tokens expire after 1 hour:

```python
# WRONG - token expires during long batch
client = spotipy.Spotify(auth=token)
for item in large_batch:  # Takes 2 hours
    client.artist(item)  # Fails after 1 hour

# CORRECT - use SpotifyClientCredentials (auto-refresh)
client = spotipy.Spotify(
    auth_manager=SpotifyClientCredentials(
        client_id=os.environ['SPOTIFY_CLIENT_ID'],
        client_secret=os.environ['SPOTIFY_CLIENT_SECRET'],
    )
)
```

## YouTube API Quota

YouTube API has daily quota limits:
- Read operations: 1 unit
- Search: 100 units
- List with multiple parts: varies

```python
# WRONG - fetches all parts (expensive)
youtube.channels().list(
    part='snippet,contentDetails,statistics,status,topicDetails',
    id=channel_id,
)  # 5+ units

# CORRECT - fetch only needed parts
youtube.channels().list(
    part='statistics',
    id=channel_id,
)  # 1 unit
```

## TikTok Authentication

TikTok doesn't have a public API. Use session cookies:

```python
# Session cookie expires frequently
# Need to refresh from browser periodically
TIKTOK_SESSION_COOKIE = os.environ['TIKTOK_SESSION_COOKIE']

# Handle auth failures
try:
    response = fetch_tiktok_data()
except AuthError:
    alert("TikTok session expired - refresh cookie")
```

## S3 Path Conflicts

Multiple workers might write to the same S3 path:

```python
# WRONG - collision if same entity processed twice
key = f"capture/spotify/stats/{entity_id}.json"

# CORRECT - include timestamp or run_id
key = f"capture/spotify/stats/{date}/{entity_id}_{run_id}.json"

# Or use S3 versioning
```

## Message Visibility Timeout

Long-running tasks need visibility extensions:

```python
# Default visibility is 30 seconds
# If processing takes longer, message reappears

# Set appropriate visibility
response = sqs.receive_message(
    QueueUrl=queue_url,
    VisibilityTimeout=300,  # 5 minutes
)

# Or extend dynamically
sqs.change_message_visibility(
    QueueUrl=queue_url,
    ReceiptHandle=receipt_handle,
    VisibilityTimeout=600,
)
```

## Empty Response Handling

Platforms may return empty data for valid entities:

```python
# WRONG - assumes data always exists
stats = response['statistics']
followers = stats['followers']  # KeyError if private

# CORRECT - handle missing data
stats = response.get('statistics', {})
followers = stats.get('followers', 0)
```

## Timezone Consistency

Always store UTC, convert for display:

```python
# WRONG - local timezone
captured_at = datetime.now().isoformat()

# CORRECT - UTC
captured_at = datetime.utcnow().isoformat() + 'Z'

# Or use timezone-aware
from datetime import timezone
captured_at = datetime.now(timezone.utc).isoformat()
```

## Memory Leaks in Long-Running Workers

```python
# WRONG - unbounded list growth
all_results = []
while True:
    result = process_message()
    all_results.append(result)  # Memory leak!

# CORRECT - process and discard
while True:
    result = process_message()
    send_result(result)
    # result goes out of scope
```

## Graceful Shutdown

Workers need to handle SIGTERM for Kubernetes:

```python
# WRONG - abrupt termination loses in-flight messages
while True:
    process_message()

# CORRECT - graceful shutdown
running = True

def shutdown(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, shutdown)

while running:
    process_message()
    
# Finish current message before exiting
```

## Duplicate Message Processing

SQS has at-least-once delivery:

```python
# WRONG - creates duplicates
def process(message):
    save_stats(message['entity_id'], message['data'])

# CORRECT - idempotent operations
def process(message):
    # Use entity_id + captured_at as natural key
    upsert_stats(
        entity_id=message['entity_id'],
        captured_at=message['captured_at'],
        data=message['data'],
    )
```
