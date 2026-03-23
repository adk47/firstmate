# External Integrations

## Payment Providers

| Service | Purpose |
|---------|---------|
| **Stripe** | Primary payment processor, subscriptions, checkout |
| **PayPal** | Alternative subscription payments |
| **Apple IAP** | iOS in-app purchases, subscriptions |
| **Google Play** | Android in-app purchases |

## Music Platforms

| Service | Purpose |
|---------|---------|
| **Spotify** | Artist search, playlist management, OAuth, streaming stats |
| **YouTube / YouTube Music** | Video stats, music catalog |
| **SoundCloud** | Streaming stats, catalog |
| **TikTok** | Social stats, sound usage |
| **Shazam** | Discovery stats, chart positions |
| **Tidal** | Catalog data |
| **Audiomack** | Streaming stats |
| **Anghami** | Streaming stats |
| **Qobuz** | Catalog data |

## Industry Data Sources

| Service | Purpose |
|---------|---------|
| **MLC (Mechanical Licensing Collective)** | Work-rights shares, recordings, ISRC/ISWC matching |
| **Jaxsta** | Professional credits database |
| **Genius** | Lyrics, annotations, artist info |
| **Music Story** | Credit data partner (outbound) |
| **Catalog API** | Internal industry API for profiles, tracks, stats |

## Social/OAuth

| Service | Purpose |
|---------|---------|
| **Auth0** | Identity management |
| **Facebook** | OAuth login |
| **Apple Sign-In** | Apple OAuth |
| **Google Sign-In** | Google OAuth |
| **Instagram** | OAuth connection, social stats |
| **X (Twitter)** | OAuth connection |

## Marketing & Analytics

| Service | Purpose |
|---------|---------|
| **Amplitude** | Product analytics, A/B experiments |
| **Segment** | Event tracking, customer data platform |
| **Klaviyo** | Email marketing automation |
| **Facebook Pixel** | Conversion tracking |
| **TikTok Pixel** | Conversion tracking |
| **Branch.io** | Deep linking, attribution |
| **Intercom** | Customer support chat |
| **ProfitWell** | Subscription analytics |
| **Rewardful** | Referral program |
| **ChartMogul** | Revenue data |
| **Microsoft Clarity** | Session recording (mobile) |

## Notifications

| Service | Purpose |
|---------|---------|
| **Knock** | In-app/push notifications |
| **AWS SNS** | Mobile push notifications |
| **AWS SES** | Transactional email |
| **Firebase Cloud Messaging** | Mobile push (Flutter) |

## Other Services

| Service | Purpose |
|---------|---------|
| **Prodigi** | Print-on-demand poster/plaque fulfillment |
| **GetStream** | Activity feed infrastructure |
| **IP2Location** | Geolocation services |
| **reCAPTCHA v3** | Bot protection |
| **Sentry** | Error monitoring |
| **Retool** | Internal admin tooling |
| **Zyte** | Web scraping partner (see below) |

### Zyte Scraping Partner

[Zyte](https://www.zyte.com/) (formerly Scrapinghub) is an external scraping partner that collects **analytics/streaming data** (NOT catalog or metadata).

**Operational Model**:
1. Muso provides: Base URL template + desired data elements
2. Zyte scrapes: High volume across many entities
3. Zyte delivers: Daily S3 dump of results

**Daily vs Runtime Scraping**:

| Mode | Service | Trigger | Purpose |
|------|---------|---------|---------|
| **Daily batch** | Zyte | Scheduled (once/day) | Bulk analytics collection across ~1M+ entities |
| **Runtime** | Analytics Worker | User-triggered / priority queue | On-demand scraping for high-priority or user-facing requests |

Zyte handles the daily baseline; analytics-worker handles real-time/priority requests. Both feed into the same downstream analytics pipeline.

**Coverage — What Muso Actually Uses from Zyte**:

| Source | Data Zyte Provides | Data Muso Handles Internally | Notes |
|--------|-------------------|------------------------------|-------|
| Spotify | **Analytics only**: stream counts, popularity | Catalog (metadata, albums, tracks, credits) + runtime analytics | Zyte does NOT provide Spotify catalog/metadata |
| Instagram | **Video links + streams + video data** | — | Muso has no internal Instagram scraping; 100% Zyte |
| TikTok | Planned | Currently internal | Negotiating handoff due to blocking issues |

> **Key distinction**: For Spotify, Zyte and Muso's analytics-worker scrape **different data types**. Zyte provides daily stream counts and popularity scores. Muso's own scraping provides catalog data (artist profiles, albums, tracks, credits) plus runtime analytics for priority items. They are not interchangeable.

**Analytics Deduplication (Spotify)**:

When both Muso and Zyte capture analytics for the same Spotify entity:
- Primary key = `source_id + entity_id`
- Pipeline takes the **larger number** (more streams wins)
- No duplication risk due to upsert logic
- This applies to **analytics metrics only** — catalog data comes exclusively from Muso's own scraping

**Pipeline Integration**:
- Zyte dumps to designated S3 bucket
- Airflow DAG processes daily dumps
- Data flows into `analytics-capture-*` SQS queues (analytics path, not catalog)

## Background Jobs & Workers

### SQS-Based Worker Tasks (Core Backend)

| Task | Description |
|------|-------------|
| `createPlaylist` | Create Spotify playlist for profile |
| `regeneratePlaylist` | Regenerate profile playlist |
| `deletePlaylists` | Remove playlists |
| `profileExport` | Generate profile data exports |
| `handleMergedProfile` | Process merged profiles |
| `handleCompletedCalculation` | Handle analytics calculations |
| `processMilestonesNotifications` | Send milestone notifications |
| `processProfileNewCreditsNotifications` | Notify about new credits |
| `processWeeklyRecapEmail` | Send weekly analytics summary |
| `processSendTemplateNotifications` | Send templated notifications |
| `updateProfileCreditRequest` | Update credit requests |
| `importProfileCreditsCsv` | Bulk import credits via CSV |
| `submitProfileSources` | Submit profile source links |
| `addProfileSourcesToRetool` | Sync to Retool |

### Scheduled Processes

| Script | Schedule | Description |
|--------|----------|-------------|
| `playlists-update` | Periodic | Update user playlists |
| `user-analytics-weekly-summary` | Weekly | Trigger weekly recap emails |
| `subscriptions` | Daily | Cancel expired PayPal subscriptions |
| `profile-new-credits-notifications` | Periodic | Notify about new credits |
| `update-pro-user-analytics` | Periodic | Update pro user analytics |
| `remove-action-logs` | Periodic | Clean up old action logs |
| `poster-orders-service` | Continuous | Process poster orders |

## SQS Queues

| Queue | Purpose |
|-------|---------|
| `industry-proc-catalog-{env}` | Catalog updates |
| `industry-proc-raw-{env}` | Raw entity updates |
| `industry-proc-analytics-{env}` | Analytics updates |
| `data-capture-{env}` | Data capture requests |
| `analytics-controller-interface-{env}` | Analytics capture |
| `core-backend-{env}-main-worker-*` | Backend workers |

## Integration Architecture

```text
Core Backend
  Express.js API
    - Payments: Stripe, PayPal, Apple IAP, Google Play
    - Identity: Auth0, Facebook, Google, Apple
    - Music platforms: Spotify (OAuth/search)

  Background workers
    - Analytics/marketing: Amplitude, Segment, Klaviyo, Knock
```
