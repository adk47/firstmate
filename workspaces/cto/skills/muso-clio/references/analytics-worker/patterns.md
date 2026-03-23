# Analytics Worker Patterns

## Base Processor Pattern

```python
# processors/base.py
from abc import ABC, abstractmethod
import boto3
import json

class BaseProcessor(ABC):
    def __init__(self, config):
        self.sqs = boto3.client('sqs')
        self.s3 = boto3.client('s3')
        self.config = config
    
    @abstractmethod
    def process(self, message: dict) -> dict:
        """Process a single message. Must be implemented by subclass."""
        pass
    
    def save_to_s3(self, data: dict, source: str, action: str, entity_id: str):
        """Save captured data to S3 data lake."""
        from datetime import datetime
        now = datetime.utcnow()
        
        key = f"capture/{source}/{action}/{now.year}/{now.month:02d}/{now.day:02d}/{entity_id}.json"
        
        self.s3.put_object(
            Bucket=self.config['s3_bucket'],
            Key=key,
            Body=json.dumps(data),
            ContentType='application/json',
        )
        
        return f"s3://{self.config['s3_bucket']}/{key}"
    
    def send_result(self, result: dict, queue_url: str):
        """Send processing result to output queue."""
        self.sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(result),
        )
    
    def validate_message(self, message: dict) -> bool:
        """Validate incoming message has required fields."""
        required = ['action', 'source', 'entity_id']
        return all(k in message for k in required)
```

## Platform Processor Pattern

```python
# processors/spotify.py
import spotipy
from spotipy.oauth2 import SpotifyClientCredentials

class SpotifyProcessor(BaseProcessor):
    def __init__(self, config):
        super().__init__(config)
        self.client = spotipy.Spotify(
            auth_manager=SpotifyClientCredentials(
                client_id=config['spotify_client_id'],
                client_secret=config['spotify_client_secret'],
            )
        )
    
    def process(self, message: dict) -> dict:
        action = message['action']
        
        if action == 'stats':
            return self.capture_stats(message)
        elif action == 'catalog':
            return self.capture_catalog(message)
        elif action == 'search':
            return self.search(message)
        else:
            raise ValueError(f"Unknown action: {action}")
    
    def capture_stats(self, message: dict) -> dict:
        entity_id = message['entity_id']
        entity_type = message.get('entity_type', 'artist')
        
        if entity_type == 'artist':
            artist = self.client.artist(entity_id)
            data = {
                'followers': artist['followers']['total'],
                'popularity': artist['popularity'],
                'genres': artist['genres'],
                'captured_at': datetime.utcnow().isoformat(),
            }
        elif entity_type == 'track':
            track = self.client.track(entity_id)
            data = {
                'popularity': track['popularity'],
                'duration_ms': track['duration_ms'],
                'captured_at': datetime.utcnow().isoformat(),
            }
        
        # Save to S3
        s3_path = self.save_to_s3(data, 'spotify', 'stats', entity_id)
        
        return {
            'source': 'spotify',
            'action': 'stats',
            'entity_id': entity_id,
            'success': True,
            'data': data,
            's3_path': s3_path,
        }
```

## Worker Loop Pattern

```python
# workers/main.py
import signal
import sys

class Worker:
    def __init__(self, processor, queue_url):
        self.processor = processor
        self.queue_url = queue_url
        self.running = True
        
        # Handle graceful shutdown
        signal.signal(signal.SIGTERM, self.shutdown)
        signal.signal(signal.SIGINT, self.shutdown)
    
    def shutdown(self, signum, frame):
        self.running = False
    
    def run(self):
        sqs = boto3.client('sqs')
        
        while self.running:
            try:
                response = sqs.receive_message(
                    QueueUrl=self.queue_url,
                    MaxNumberOfMessages=10,
                    WaitTimeSeconds=20,
                    VisibilityTimeout=300,
                )
                
                for message in response.get('Messages', []):
                    self.process_message(sqs, message)
                    
            except Exception as e:
                logger.error(f"Worker error: {e}")
                time.sleep(5)
    
    def process_message(self, sqs, message):
        try:
            body = json.loads(message['Body'])
            result = self.processor.process(body)
            
            # Send result
            self.processor.send_result(
                result,
                os.environ['QUEUE_RESULTS'],
            )
            
            # Delete message on success
            sqs.delete_message(
                QueueUrl=self.queue_url,
                ReceiptHandle=message['ReceiptHandle'],
            )
            
        except Exception as e:
            logger.error(f"Failed to process: {e}")
            # Message will become visible again after visibility timeout
```

## Rate Limiting Pattern

```python
# utils/rate_limiter.py
import time
from collections import deque

class RateLimiter:
    def __init__(self, max_requests: int, window_seconds: int):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.requests = deque()
    
    def acquire(self):
        """Block until a request slot is available."""
        now = time.time()
        
        # Remove old requests outside window
        while self.requests and self.requests[0] < now - self.window_seconds:
            self.requests.popleft()
        
        # Wait if at limit
        if len(self.requests) >= self.max_requests:
            sleep_time = self.requests[0] + self.window_seconds - now
            if sleep_time > 0:
                time.sleep(sleep_time)
            self.requests.popleft()
        
        self.requests.append(time.time())

# Usage
rate_limiter = RateLimiter(max_requests=100, window_seconds=60)

def make_api_call():
    rate_limiter.acquire()
    return client.get(...)
```

## Retry Pattern

```python
# utils/retry.py
import time
from functools import wraps

def retry(max_attempts=3, backoff_factor=2, exceptions=(Exception,)):
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(max_attempts):
                try:
                    return func(*args, **kwargs)
                except exceptions as e:
                    if attempt == max_attempts - 1:
                        raise
                    sleep_time = backoff_factor ** attempt
                    logger.warning(f"Attempt {attempt + 1} failed: {e}. Retrying in {sleep_time}s")
                    time.sleep(sleep_time)
        return wrapper
    return decorator

# Usage
@retry(max_attempts=3, exceptions=(RequestException,))
def fetch_spotify_stats(artist_id):
    return client.artist(artist_id)
```

## Scraping Implementation Pattern

### Internal API vs HTML Scraping

Most sources use **reverse-engineered internal APIs** rather than HTML scraping:

| Approach | Sources | Description |
|----------|---------|-------------|
| Internal API | Spotify, YouTube, TikTok, SoundCloud, Tidal | Inspect network requests, find internal JSON endpoints |
| HTML Scraping | Genius, Shazam | Parse HTML response with regex |

**Why internal APIs?**
- Structured JSON responses
- More stable than HTML structure changes
- Better performance (smaller payloads)

### Finding Internal APIs

Process for reverse-engineering a new source:

1. Open browser DevTools → Network tab
2. Navigate the site, interact with features
3. Look for XHR/Fetch requests returning JSON
4. Identify required headers, cookies, parameters
5. Replicate in Python requests

```python
# Example: Found internal API endpoint
def get_artist_stats(self, artist_id: str) -> dict:
    url = f"https://api.soundcloud.com/users/{artist_id}"
    params = {
        'client_id': self.client_id,
        'app_version': '1234567890',
    }
    headers = self.get_random_headers()

    response = self.request_wrapper.get(url, params=params, headers=headers)
    return response.json()
```

### HTML Scraping Pattern (Genius, Shazam)

For sources without usable internal APIs:

```python
# processors/genius/parser.py
import re

def get_artist_id_from_html(self, url: str) -> str:
    response = self.request_wrapper.get(url, headers=self.get_headers())
    html = response.text

    # Find artist ID in page source
    # Pattern: "artist_id":12345 or similar
    match = re.search(r'"artist_id"[:\s]+(\d+)', html)
    if match:
        return match.group(1)
    raise ValueError("Can't find artist ID in HTML")
```

### User Agent Rotation

All requests rotate user agents to avoid detection:

```python
# utils/headers.py
import random

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36...",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36...",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36...",
    # ... 50+ user agents
]

def get_random_headers() -> dict:
    return {
        'User-Agent': random.choice(USER_AGENTS),
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Connection': 'keep-alive',
    }
```

**Note**: User agent list can become stale over time. Consider periodic updates.

### Request Wrapper Pattern

Centralizes HTTP requests with proxy rotation and error handling:

```python
# utils/request_wrapper.py
class RequestWrapper:
    def __init__(self, proxy_rotator, source: str):
        self.proxy_rotator = proxy_rotator
        self.source = source

    def get(self, url: str, **kwargs) -> requests.Response:
        proxy = self.proxy_rotator.get_proxy(self.source)
        kwargs['proxies'] = {'http': proxy, 'https': proxy}
        kwargs['headers'] = kwargs.get('headers', {}) | get_random_headers()

        try:
            response = requests.get(url, **kwargs)
            response.raise_for_status()
            return response
        except requests.RequestException as e:
            self.proxy_rotator.mark_failed(proxy, self.source)
            raise
```

### Processor/Parser Separation

Each source has two main files:

| File | Responsibility |
|------|---------------|
| `processor.py` | Message routing, orchestration, result handling |
| `parser.py` | API calls, data extraction, response parsing |

```python
# processors/soundcloud/processor.py
class SoundCloudProcessor(BaseProcessor):
    def process(self, message: dict) -> dict:
        action = message['action']
        entity_type = message['entity_type']

        if action == 'stats':
            if entity_type == 'track':
                return self.parser.get_track_stats(message['entity_id'])
            elif entity_type == 'artist':
                return self.parser.get_artist_stats(message['entity_id'])
        elif action == 'track_redirect':
            # SoundCloud-specific: resolve URL to internal ID
            return self.parser.get_track_id_from_redirect(message['url'])

        # ... validation, S3 storage, SQS send
```

```python
# processors/soundcloud/parser.py
class SoundCloudParser:
    def get_track_stats(self, track_id: str) -> dict:
        # Actual API call logic
        ...

    def get_track_id_from_redirect(self, url: str) -> dict:
        # Resolve SoundCloud URL to internal ID
        response = self.request_wrapper.get(
            'https://api.soundcloud.com/resolve',
            params={'url': url, 'client_id': self.client_id}
        )
        return {'track_id': response.json()['id']}
```
