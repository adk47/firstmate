---
name: muso-analytics
description: |
  Muso product analytics on OUR stack (event router query API + ClickHouse
  product_events), the replacement for Amplitude reads. READ ONLY.

  Use when: looking up a user's product activity (support, refunds, disputes,
  fraud), active/new users, event counts, breakdowns by country/os/plan, realtime
  traffic, or any "what did this user do in the app" question.

  Triggers: "user activity", "last active", "active users", "DAU", "events",
  "product analytics", "amplitude", "usage before refund", "what did they do"
allowed-tools:
  - exec
compatibility: |
  Runs /opt/hydra/scripts/muso-stack-read.sh on node-8 (kubectl to the OVH cluster).
  Router credential: MUSOAI_EVENT_ROUTER_QUERY or Secret hydra/hydra-event-router-query.
  Falls back to the muso-amplitude skill (vendor) until Amplitude's cutover.
metadata:
  version: "1.0"
  replaces: muso-amplitude (stack-swap lane 8, 2026-10)
---

# Muso Analytics (our stack, READ ONLY)

Every product event (web, iOS, Android, backend) lands in our own ClickHouse,
`product_events` on the `product-analytics` cluster: the full Amplitude history
(loaded from the vendor archive) plus everything the event router
(`events.muso.ai`) receives. The router answers the **same paths, parameters and
JSON shapes as Amplitude's Dashboard API**, so Amplitude habits carry over.

There is no write path. The helper refuses anything but reads.

## Step 0: is the window covered? (always, once per task)

```bash
bash /opt/hydra/scripts/muso-stack-read.sh coverage
```

Read `events_view_covered_to` and `cutover_at`:

- The question's window ends **at or before** `events_view_covered_to` → answer from
  our stack (Steps 1-3).
- The window ends **after** it, or the user is not found here, and Amplitude is still
  live → also ask Amplitude via the `muso-amplitude` skill, and say which source answered
  each number. Until `cutover_at` is set, the view serves the history load only, so recent
  days usually come from Amplitude.
- After the cutover (a `cutover_at` value) our stack is the source of truth; Amplitude is
  for spot checks only, and is gone after its downgrade.

`events_view_covered_to` is the server-side upload high-water mark. Never use
`max(event_time)` as coverage: event times are client clocks, and a few hundred history
rows are dated in the 22nd century (`future_dated_rows_ignored`). Exclude
`event_time > now()` from your own SQL aggregates too.

Never present a number without its source (`our stack` / `Amplitude`) and window.

## Step 1: find the user

The query API takes a **Muso user id** (or an Amplitude id). It does **not** search by
email: resolve email → user id first (muso-ops-users Step 1/2: admin API or
`muso query` on `postgresql_core.public.users`).

```bash
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/usersearch?user=<user_id>'
# {"matches":[{"user_id","amplitude_id","last_seen","platform","country"}], ...}
```

`matches: []` = no product events for that id in our stack (check Step 0's window, then
Amplitude while it is live).

## Step 2: activity timeline

```bash
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/useractivity?user=<user_id>&limit=200&offset=0'
# {"userData":{"user_id","properties":{...},"num_events"},"events":[{event_type,event_time,platform,country,device_type,version_name,event_properties}]}
```

Newest first, `limit` max 1000. For counts over a long window, use SQL (Step 3) instead
of paging.

## Step 3: aggregates

Same as Amplitude's Dashboard API. Dates `YYYYMMDD`; `i` = 1 (day), 7 (week, Monday
start), 30 (month); days are cut in America/New_York (the Amplitude project's zone).
URL-encode JSON (`{` `%7B`, `"` `%22`, `:` `%3A`, space `%20`).

```bash
# Active users per day (m=new for new users); g= breaks down by country, os,
# device_type, platform, version, or gp:<user property> (e.g. gp:subscription_plan)
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/users?start=20261001&end=20261007&m=active&i=1&g=country'

# One event type: totals or uniques
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/events/segmentation?e=%7B%22event_type%22%3A%22login%22%7D&start=20261001&end=20261007&m=uniques'

# Realtime (5-minute buckets, last 24 h)
bash /opt/hydra/scripts/muso-stack-read.sh router '/api/2/realtime'
```

Anything the API does not cover (retention, funnels, session length, custom filters):
one read query on ClickHouse.

```bash
bash /opt/hydra/scripts/muso-stack-read.sh ch "
SELECT event_type, count() AS n, max(event_time) AS last
FROM product_events.events
WHERE user_id = '<user_id>' AND event_time >= now() - INTERVAL 30 DAY AND is_bot = 0
GROUP BY event_type ORDER BY n DESC LIMIT 20"
```

`product_events.events` columns: `event_type, event_time (UTC), user_id, device_id,
session_id, insert_id, platform, os_name, os_version, device_family, device_type,
country, region, city, language, library, version_name, event_properties (JSON string),
user_properties (JSON string), is_bot, origin`. Always filter on `event_time` (the
table is huge) and exclude `is_bot = 1` unless bots are the question. JSON fields:
`JSONExtractString(event_properties, 'key')`.

The Trino lake table `"platform-industry-amplitude-bi-prod".events` (saved queries in
`muso-query-writer`) is meant to keep working: at the cutover the router's lake sink takes over the
same files. If a lake result looks short, check its latest partition before trusting it.

## Rules

- READ ONLY. The helper runs ClickHouse with `readonly=1` and accepts one
  SELECT/WITH/SHOW/DESCRIBE/EXPLAIN per call.
- Treat event and user properties as PII: summarize (counts, last seen, top actions);
  never paste raw property blobs or other users' data into Slack.
- Numbers differ slightly from Amplitude's: a "user" here is the Muso user id, else the
  device; Amplitude merged both into its own id.
- Helper exit codes: `2` = refused (fix the call), `3` = cannot reach the stack or no
  credential (fall back to Amplitude and say so; tell devops if it persists), `1` =
  query/HTTP error.
