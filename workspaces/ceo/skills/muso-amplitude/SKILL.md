---
name: muso-amplitude
description: |
  Amplitude product analytics - READ ONLY. Query user behavior, events, cohorts, and metrics.
  CRITICAL: This skill is READ-ONLY. Never modify data.

  Use when: looking up user activity, searching users, viewing events, checking cohorts,
  exporting chart data, analyzing product usage, retention, or funnels.

  Triggers: "amplitude", "user activity", "events", "cohorts", "product analytics",
  "retention", "funnel", "user behavior"
allowed-tools:
  - Bash
compatibility: |
  Requires MUSOAI_AMPLITUDE_TOKEN and MUSOAI_AMPLITUDE_SECRET_KEY env vars.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Amplitude Skill (READ-ONLY)

Query Muso.AI product analytics data from Amplitude.

## CRITICAL: READ-ONLY ACCESS

**ONLY USE GET REQUESTS. NO POST, PUT, PATCH, OR DELETE.**

## Authentication

Amplitude's Dashboard REST API uses HTTP Basic Auth with **two credentials**: an API Key and a Secret Key.

**Env vars:** `$MUSOAI_AMPLITUDE_TOKEN` (API Key) and `$MUSOAI_AMPLITUDE_SECRET_KEY` (Secret Key)

```bash
curl -s -u "$MUSOAI_AMPLITUDE_TOKEN:$MUSOAI_AMPLITUDE_SECRET_KEY" \
  "https://amplitude.com/api/2/..."
```

All subsequent curl commands use the same auth.

> Both keys are found in Amplitude under Settings > Projects > \<project\> > General.

## Base URLs

| API | Base URL |
|-----|----------|
| Dashboard/Export API | `https://amplitude.com/api/2/` |
| Behavioral Cohorts | `https://amplitude.com/api/3/` |
| User Profile API | `https://profile-api.amplitude.com/v1/` |

## Allowed Operations (Read-Only)

### Search Users
```bash
# Search for a user by Amplitude user ID
curl -s "https://amplitude.com/api/2/usersearch?user=USER_ID" | jq

# Search by email or other identifier
curl -s "https://amplitude.com/api/2/usersearch?user=user@example.com" | jq
```

### User Activity
```bash
# Get user activity (events timeline)
curl -s "https://amplitude.com/api/2/useractivity?user=AMPLITUDE_ID" | jq

# Get user activity with offset for pagination
curl -s "https://amplitude.com/api/2/useractivity?user=AMPLITUDE_ID&offset=0&limit=100" | jq
```

### User Profile (Profile API)
```bash
# Get real-time user profile/properties
curl -s "https://profile-api.amplitude.com/v1/userprofile?user_id=USER_ID" | jq
```

### Event Segmentation (Chart Data)
```bash
# Get event counts for a date range
curl -s "https://amplitude.com/api/2/events/segmentation?e=%7B%22event_type%22:%22Page%20View%22%7D&start=20260101&end=20260215" | jq

# Breakdown: encode the event JSON in the 'e' parameter
# e={"event_type":"EVENT_NAME"}
# Dates are YYYYMMDD format
```

### Active & New Users
```bash
# Get active user counts
curl -s "https://amplitude.com/api/2/users?start=20260101&end=20260215" | jq

# Get new user counts
curl -s "https://amplitude.com/api/2/new_users?start=20260101&end=20260215" | jq
```

### Sessions
```bash
# Get average session length
curl -s "https://amplitude.com/api/2/sessions/average?start=20260101&end=20260215" | jq
```

### Cohorts
```bash
# List all cohorts
curl -s "https://amplitude.com/api/3/cohorts" | jq

# Get cohort details
curl -s "https://amplitude.com/api/3/cohorts/COHORT_ID" | jq
```

### Retention
```bash
# Get retention data
curl -s "https://amplitude.com/api/2/retention?se=%7B%22event_type%22:%22Sign%20Up%22%7D&re=%7B%22event_type%22:%22Page%20View%22%7D&start=20260101&end=20260215" | jq

# se = start event (JSON encoded), re = return event (JSON encoded)
```

### Funnel Analysis
```bash
# Get funnel conversion data
curl -s "https://amplitude.com/api/2/funnels?e=%5B%7B%22event_type%22:%22Sign%20Up%22%7D,%7B%22event_type%22:%22Complete%20Profile%22%7D%5D&start=20260101&end=20260215" | jq

# e = array of event objects (JSON encoded)
```

## Common Workflows

### Look Up a User's Recent Activity
```bash
# 1. Find the user
curl -s "https://amplitude.com/api/2/usersearch?user=user@example.com" | \
  jq '.matches[] | {amplitude_id, user_id, last_seen}'

# 2. Get their activity (use amplitude_id from step 1)
curl -s "https://amplitude.com/api/2/useractivity?user=AMPLITUDE_ID" | \
  jq '.events[:10] | .[] | {event_type, event_time, event_properties}'
```

### Get Daily Active Users for Last 30 Days
```bash
curl -s "https://amplitude.com/api/2/users?start=20260117&end=20260216&m=active" | \
  jq '.data.series[]'
```

## Tips

- **READ-ONLY ONLY** - Never modify data
- Date format is `YYYYMMDD` (no dashes)
- Event parameters must be URL-encoded JSON
- Use `| jq` to parse and filter JSON responses
- Always use `-s` (silent) flag with curl to suppress progress output
- Rate limit: varies by plan, typically 360 requests/hour for Dashboard API
- The `usersearch` endpoint accepts email, user_id, or amplitude_id
- For large exports, use the Export API (separate authentication may be required)

## Documentation

- Amplitude API Docs: https://www.docs.developers.amplitude.com/analytics/apis/
- Dashboard REST API: https://www.docs.developers.amplitude.com/analytics/apis/dashboard-rest-api/
- User Profile API: https://www.docs.developers.amplitude.com/analytics/apis/user-profile-api/
