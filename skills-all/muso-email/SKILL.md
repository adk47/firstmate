---
name: muso-email
description: |
  Muso email on OUR stack (send-gateway + preferences + Listmonk, history in
  ClickHouse messaging.email_events), the replacement for Klaviyo reads. READ ONLY.

  Use when: "did this user get email X", bounce / unsubscribe / suppression status,
  consent state, flow progress (dunning, welcome, cancel intent), campaign and list
  stats, email engagement (opens, clicks), daily/EOD email reporting.

  Triggers: "email", "klaviyo", "did they get the email", "bounced", "unsubscribed",
  "suppressed", "consent", "campaign", "flow", "dunning email", "open rate", "listmonk"
allowed-tools:
  - exec
compatibility: |
  Runs /opt/hydra/scripts/muso-stack-read.sh on node-8 (kubectl to the OVH cluster).
  Falls back to the muso-klaviyo skill (vendor) per channel until that channel cuts over.
metadata:
  version: "1.0"
  replaces: muso-klaviyo reads (stack-swap lane 8, 2026-10)
---

# Muso Email (our stack, READ ONLY)

Where email lives once it is off Klaviyo:

| Question | Our stack | Store |
|---|---|---|
| Was an email sent / delivered / opened / clicked / bounced? | send log + provider webhooks, plus the imported Klaviyo history (`source='klaviyo'`) | ClickHouse `messaging.email_events` |
| One message's status and gate decision | send-gateway | Postgres `preferences` db, `send.messages` |
| Where is this person in a flow (dunning, welcome, cancel intent, suspension)? | send-gateway flow engine | `send.flow_enrollments` |
| Consent, unsubscribe, bounce / complaint suppressions, topic opt-outs | preferences | `prefs.contacts`, `prefs.email_consent`, `prefs.suppressions`, `prefs.topic_optouts` |
| Marketing campaigns, lists, audience sizes | Listmonk | Postgres `listmonk` db: `campaigns`, `lists`, `subscribers`, `subscriber_lists` |

**Sending is not an agent action.** Nothing here sends, suppresses, unsubscribes or
erases. Those go through the product (core-backend, the preference page, admin tools).

## Step 0: which side is live? (always, once per task)

```bash
bash /opt/hydra/scripts/muso-stack-read.sh coverage
```

Klaviyo and our stack overlap until each stream cuts over (auth first, then receipts,
dunning, notifications, marketing on Listmonk). Decide **per stream and per time
window**, never for the whole answer. `coverage` lists `messaging.email_events` per
`source` x `class` with a `kind`, `live_from`, `shadow_rows` and `min/max_event_time`:

- `kind = live`: our stack really sends that class (`auth`, `receipt`, `notify`,
  `digest`, `marketing`) **from `live_from` on** (its first provider-accepted `sent` or
  provider-webhook row). Read those windows from our stack, even when no Klaviyo history
  is imported.
- `kind = shadow-only`: our stack only *recorded* what it would send (`would_send`,
  `skipped`). Nothing was delivered by us; Klaviyo did the real send, so every delivery
  fact for that class comes from Klaviyo. The same holds for a `live` class **before**
  its `live_from` (its earlier rows are shadow rows).
- `kind = history` (`source='klaviyo'`): the imported Klaviyo history, covering up to its
  `max_event_time` (the archive's t0, 6 Oct 2026).
- **Everything else** comes from Klaviyo (`muso-klaviyo`, read-only): a class with no rows
  of ours, the gap between the history's `max_event_time` and a class's `live_from`, or
  every email if `email_events` does not exist yet. Example: a password reset sent today
  after `auth` went live -> our stack; a dunning email from last week while `receipt` was
  shadow-only -> Klaviyo.
- Consent/suppressions: `preferences: -` or `contacts` near 0 → still Klaviyo's. Listmonk
  with a handful of subscribers → test data; marketing still runs in Klaviyo.

Name the source of every fact (`our stack` / `Klaviyo`). When both hold the same window,
prefer ours and do not count a send twice.

## Lookups

Addresses are stored lowercased and trimmed. Quote values as SQL literals (no user text
straight into SQL without checking it is an email or a numeric id).

```bash
# Everything that happened to one address, newest first (both sources)
bash /opt/hydra/scripts/muso-stack-read.sh ch "
SELECT event_time, event_type, source, template_key, subject, campaign_name, provider, reason
FROM messaging.email_events
WHERE email = 'user@example.com' AND event_time >= now() - INTERVAL 90 DAY
ORDER BY event_time DESC LIMIT 100"

# Did they ever receive template K? (welcome / dunning filters read exactly this)
bash /opt/hydra/scripts/muso-stack-read.sh ch "
SELECT event_type, count() AS n, max(event_time) AS last
FROM messaging.email_events FINAL
WHERE email = 'user@example.com' AND template_key = 'failed_payment_dunning__dunning_1_payment_failed'
GROUP BY event_type"

# Consent + suppressions for an address
bash /opt/hydra/scripts/muso-stack-read.sh pg preferences "
SELECT c.email, c.muso_user_id, e.state AS consent, e.consent_at,
       s.reason AS suppression, s.active, s.permanent, s.last_at,
       (SELECT string_agg(topic, ',') FROM prefs.topic_optouts t WHERE t.contact_id = c.id) AS topic_optouts
FROM prefs.contacts c
LEFT JOIN prefs.email_consent e ON e.contact_id = c.id
LEFT JOIN prefs.suppressions s ON s.contact_id = c.id
WHERE c.email = 'user@example.com'"

# Flow progress (dunning, welcome, ...)
bash /opt/hydra/scripts/muso-stack-read.sh pg preferences "
SELECT flow, status, step, started_at, next_at, reason
FROM send.flow_enrollments WHERE email = 'user@example.com' ORDER BY started_at DESC LIMIT 20"

# Last messages and the gate's decision (shadow mode records would_send, not sent)
bash /opt/hydra/scripts/muso-stack-read.sh pg preferences "
SELECT created_at, template_key, class, status, gate, reason, provider, sent_at
FROM send.messages WHERE email = 'user@example.com' ORDER BY created_at DESC LIMIT 20"
```

## Reporting (EOD, campaign performance)

```bash
# Last 24 h by event type and template (both sources)
bash /opt/hydra/scripts/muso-stack-read.sh ch "
SELECT source, event_type, template_key, uniqExact(email) AS people, count() AS events
FROM messaging.email_events
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY source, event_type, template_key ORDER BY events DESC LIMIT 50"

# Bounce and complaint rates per stream, last 7 days (alert bars: bounce > 2 %, complaint > 0.1 %)
bash /opt/hydra/scripts/muso-stack-read.sh ch "
SELECT class,
       countIf(event_type = 'sent') AS sent,
       round(100 * countIf(event_type = 'bounced') / greatest(sent, 1), 2) AS bounce_pct,
       round(100 * countIf(event_type = 'complained') / greatest(sent, 1), 3) AS complaint_pct
FROM messaging.email_events
WHERE source != 'klaviyo' AND event_time >= now() - INTERVAL 7 DAY
GROUP BY class ORDER BY sent DESC"

# Listmonk campaigns and lists
bash /opt/hydra/scripts/muso-stack-read.sh pg listmonk "
SELECT c.name, c.status, c.sent, c.to_send, c.started_at, c.updated_at
FROM campaigns c ORDER BY c.updated_at DESC LIMIT 20"
bash /opt/hydra/scripts/muso-stack-read.sh pg listmonk "
SELECT l.name, l.type, count(sl.subscriber_id) FILTER (WHERE sl.status <> 'unsubscribed') AS members
FROM lists l LEFT JOIN subscriber_lists sl ON sl.list_id = l.id GROUP BY l.id, l.name, l.type ORDER BY members DESC"
```

`messaging.email_events.event_type` values: `received, opened, clicked, bounced, dropped,
complained, unsubscribed, skipped, would_send, sent, failed, unconfirmed, delivered,
deferred, rejected, push_received, push_opened, push_bounced`. Klaviyo history uses the
Klaviyo meanings (`received` = Klaviyo "Received Email"); our sends use `sent` then the
provider's `delivered` / `bounced`. `would_send` = shadow mode (not delivered to anyone).
Use `FINAL` or `count(DISTINCT event_id)` when the number must be exact.

## Rules

- READ ONLY, one statement per call; Postgres reads go to the replica only.
- Email addresses are PII: answer about the person asked about; never dump lists of
  addresses into Slack. Audience exports for a campaign are a human task.
- Anything that would send, suppress, unsubscribe or erase: stop and route to a human
  (marketing: Aaron / Nick; GDPR erasure: the product's account deletion).
- Helper exit codes: `2` = refused, `3` = cannot reach the stack (fall back to Klaviyo
  while it is live and say so), `1` = query error (e.g. table not created yet).
