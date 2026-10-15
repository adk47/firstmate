---
name: muso-klaviyo
description: |
  Klaviyo (LEGACY, being replaced): email/SMS marketing analytics and management. Query metrics, profiles, campaigns, flows, lists, segments.
  For READS use the muso-email skill FIRST (our stack); use Klaviyo for a stream that has not cut over yet
  (see `muso-stack-read.sh coverage`), and name Klaviyo as the source.
  WRITE ACCESS: Aaron (U7RP6HKUZ) and Nick (U0AL36NADEY) only. All other users are READ-ONLY.

  Use when: checking email campaign performance, SMS metrics, subscriber profiles, list/segment sizes,
  flow performance, event history, marketing analytics, or managing campaigns/flows/lists.

  Triggers: "klaviyo", "email marketing", "email campaigns", "sms campaigns", "email metrics",
  "subscriber", "flow", "campaign performance", "open rate", "click rate"
allowed-tools:
  - Bash
compatibility: |
  Requires MUSOAI_KLAVIYO_TOKEN env var.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Klaviyo Skill (LEGACY, being replaced)

> **Stack swap (Oct 2026):** email moves to our own stack (send-gateway, preferences, Listmonk;
> history in ClickHouse `messaging.email_events`), stream by stream. For reads start with the
> `muso-email` skill; use Klaviyo for whatever `muso-stack-read.sh coverage` shows is not on our
> stack yet, and label those facts "Klaviyo". Do not start new Klaviyo flows, templates or
> lists without Aaron's or Nick's explicit word: anything built here has to be rebuilt.

Query and manage Muso.AI email/SMS marketing data from Klaviyo.

## Access Control

- **Aaron (U7RP6HKUZ):** Full read/write access
- **Nick (U0AL36NADEY):** Full read/write access
- **All other users:** READ-ONLY. Only GET requests (and POST for search/aggregate endpoints). Never create, update, or delete data.

Always check `sender_id` before executing any write operation.

## Authentication

The private API key is available as `$MUSOAI_KLAVIYO_TOKEN` in the environment.

Klaviyo uses a custom Authorization header and requires a `revision` header for API versioning:

```bash
curl -s \
  -H "Authorization: Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN" \
  -H "revision: 2025-01-15" \
  "https://a.klaviyo.com/api/metrics/"
```

All subsequent curl commands use the same auth headers.

> **Important:** Always include the `revision` header. Use `2025-01-15` (latest stable).

## Base URL

`https://a.klaviyo.com/api/`

## Allowed Operations (Read-Only)

### Metrics (Event Types)
```bash
# List all metrics (event types like "Placed Order", "Opened Email", etc.)
curl -s \
  "https://a.klaviyo.com/api/metrics/" | jq '.data[] | {id, name: .attributes.name}'
```

### Metric Aggregates (Analytics — POST but read-only)
```bash
# Query aggregated metric data (e.g., total revenue from "Placed Order" events)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "metric-aggregate",
      "attributes": {
        "metric_id": "METRIC_ID",
        "measurements": ["count", "sum_value"],
        "interval": "day",
        "filter": ["greater-or-equal(datetime,2026-01-01T00:00:00)","less-than(datetime,2026-02-01T00:00:00)"]
      }
    }
  }' \
  "https://a.klaviyo.com/api/metric-aggregates/" | jq
```

> **Measurements:** `count`, `sum_value`, `unique` (count of unique profiles)
> **Intervals:** `day`, `week`, `month`
> **Filters:** Use Klaviyo filter syntax: `greater-or-equal(datetime,...)`, `less-than(datetime,...)`

### Events (Individual Event Records)
```bash
# List recent events
curl -s \
  "https://a.klaviyo.com/api/events/?sort=-datetime" | jq '.data[:5] | .[] | {type: .attributes.metric_id, email: .attributes.profile_id, time: .attributes.datetime}'

# Filter events by metric
curl -s \
  "https://a.klaviyo.com/api/events/?filter=equals(metric_id,\"METRIC_ID\")&sort=-datetime" | jq
```

### Profiles (Subscribers)
```bash
# List profiles
curl -s \
  "https://a.klaviyo.com/api/profiles/" | jq '.data[:5] | .[] | {id, email: .attributes.email, name: "\(.attributes.first_name) \(.attributes.last_name)"}'

# Get a specific profile
curl -s \
  "https://a.klaviyo.com/api/profiles/PROFILE_ID/" | jq '.data.attributes'

# Filter profiles by email
curl -s \
  "https://a.klaviyo.com/api/profiles/?filter=equals(email,\"user@example.com\")" | jq
```

### Lists
```bash
# List all lists
curl -s \
  "https://a.klaviyo.com/api/lists/" | jq '.data[] | {id, name: .attributes.name}'

# Get profiles in a list
curl -s \
  "https://a.klaviyo.com/api/lists/LIST_ID/profiles/" | jq '.data[] | {id, email: .attributes.email}'
```

### Segments
```bash
# List all segments
curl -s \
  "https://a.klaviyo.com/api/segments/" | jq '.data[] | {id, name: .attributes.name}'

# Get profiles in a segment
curl -s \
  "https://a.klaviyo.com/api/segments/SEGMENT_ID/profiles/" | jq '.data[] | {id, email: .attributes.email}'
```

### Campaigns
```bash
# List all campaigns
curl -s \
  "https://a.klaviyo.com/api/campaigns/?filter=equals(messages.channel,\"email\")" | \
  jq '.data[] | {id, name: .attributes.name, status: .attributes.status}'

# Get campaign details
curl -s \
  "https://a.klaviyo.com/api/campaigns/CAMPAIGN_ID/" | jq '.data.attributes'
```

### Flows
```bash
# List all flows
curl -s \
  "https://a.klaviyo.com/api/flows/" | jq '.data[] | {id, name: .attributes.name, status: .attributes.status}'

# Get flow details
curl -s \
  "https://a.klaviyo.com/api/flows/FLOW_ID/" | jq '.data.attributes'
```

### Tags
```bash
# List all tags
curl -s \
  "https://a.klaviyo.com/api/tags/" | jq '.data[] | {id, name: .attributes.name}'
```

## Pagination

Klaviyo uses cursor-based pagination. Check `links.next` in the response:

```bash
# First page
RESPONSE=$(curl -s \
  "https://a.klaviyo.com/api/profiles/?page[size]=20")

echo "$RESPONSE" | jq '.data | length'  # items on this page

# Get next page URL
NEXT=$(echo "$RESPONSE" | jq -r '.links.next // empty')
if [ -n "$NEXT" ]; then
  curl -s \
    "$NEXT" | jq '.data | length'
fi
```

## Sparse Fieldsets

Reduce payload size by requesting only specific fields:

```bash
# Get only email and name from profiles
curl -s \
  "https://a.klaviyo.com/api/profiles/?fields[profile]=email,first_name,last_name" | jq
```

## Common Workflows

### Email Campaign Performance Summary
```bash
# 1. List recent email campaigns
curl -s \
  "https://a.klaviyo.com/api/campaigns/?filter=equals(messages.channel,\"email\")&sort=-send_time" | \
  jq '.data[:5] | .[] | {name: .attributes.name, status: .attributes.status, send_time: .attributes.send_strategy.datetime}'
```

### Find a Subscriber by Email
```bash
curl -s \
  "https://a.klaviyo.com/api/profiles/?filter=equals(email,\"user@example.com\")" | \
  jq '.data[] | .attributes'
```

### Count Events in a Date Range
```bash
# First get the metric_id for the event you want (e.g., "Placed Order")
METRIC_ID=$(curl -s \
  "https://a.klaviyo.com/api/metrics/" | \
  jq -r '.data[] | select(.attributes.name == "Placed Order") | .id')

# Then query aggregates
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"type\": \"metric-aggregate\",
      \"attributes\": {
        \"metric_id\": \"$METRIC_ID\",
        \"measurements\": [\"count\", \"sum_value\", \"unique\"],
        \"interval\": \"month\",
        \"filter\": [\"greater-or-equal(datetime,2025-01-01T00:00:00)\",\"less-than(datetime,2026-02-01T00:00:00)\"]
      }
    }
  }" \
  "https://a.klaviyo.com/api/metric-aggregates/" | jq
```

## Tips

- **Write access:** Aaron (U7RP6HKUZ) and Nick (U0AL36NADEY) only. All others read-only.
- Always include the `revision: 2025-01-15` header (API versioning is mandatory)
- Response format follows JSON:API spec: `{"data": [...], "links": {...}}`
- Use `| jq` to parse and filter JSON responses
- Always use `-s` (silent) flag with curl to suppress progress output
- Rate limits: Burst 10/s, Steady 150/m per endpoint — check response headers
- Use sparse fieldsets (`?fields[type]=field1,field2`) to reduce response size
- Pagination: max 200 items per page, use `page[size]` param and `links.next` for next page
- Filter syntax: `equals(field,"value")`, `greater-or-equal(field,value)`, `less-than(field,value)`
- POST to `/api/metric-aggregates/` is read-only (queries data, does not create anything)

## Documentation

- Klaviyo API Overview: https://developers.klaviyo.com/en/reference/api_overview
- Metrics API: https://developers.klaviyo.com/en/reference/metrics_api_overview
- Profiles API: https://developers.klaviyo.com/en/reference/profiles_api_overview
- Segments API: https://developers.klaviyo.com/en/reference/segments_api_overview
- Events API: https://developers.klaviyo.com/en/reference/events_api_overview
