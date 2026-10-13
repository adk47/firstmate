# Platform Features

> "Platform" here means **the Muso app** and what a subscription includes. If the
> customer is asking about **platform.muso.ai**, the self-service developer
> platform for API access to the whole catalog, that is a different product --
> see `platform.md`.

## Analytics

Turn your credits into daily stats. Available on Pro and Business plans.

### Streaming Data
- Lifetime data across 7 platforms
- Filter by track, album, role, and collaborator

### Supported Platforms
Spotify, YouTube, YouTube Music, Shazam, TikTok, SoundCloud, and Instagram (7 total).

### Milestones
Track career achievements at streaming thresholds:
- 10K streams
- 100K streams
- 1M streams
- 10M streams
- 100M streams
- 1B streams

### Charts
Track chart positions and movement over time.

### Live updates (the live counter)
A live estimate of the Lifetime total on the Summary card. Instruction for Caroline: describe it only in the product's own words, *"Live estimate – projected in real time from the latest verified totals, and refined as new data syncs."* Never explain how it is computed and never quote a refresh cadence.

**Where it is (web):** Analytics → the **Summary** card → the **Display** button (top-right of the card, next to the period selector) → a **Live updates** switch and a **Number format** choice of **Full** or **Compact**.

**It is already on.** Live updates defaults to on, per browser, and the choice is kept in that browser only. Turning it on is the fix only for someone who switched it off, or who is on a different browser or device from the one where they switched it off.

**Why an eligible customer sees no movement, in this order (the first is by far the most common):**
1. **The period is not Lifetime.** The live counter only runs on the Lifetime view. On any shorter period the Display button is still there and the switch still reads on, but the number is a fixed total and does not move. Fix: set the period selector to Lifetime.
2. **Number format is Compact.** Compact rounds to a short figure such as 93.4B, so small movements do not show. Full shows every digit, so the movement is visible. Default is Full. Fix: pick Full.
3. **Live updates was switched off in this browser.** Fix: switch it back on.
4. **They are looking at a profile that is not on their workspace.** See who has it, below.

**Who has it today.** Live updates are rolling out in stages and aren't on every account yet. Do not promise a date and do not say which stage is next. All of these must hold; if any fails, the Display button is simply not drawn, with no message and no empty state:
- the customer's workspace is a founding-member workspace (today's rollout audience),
- that workspace has an active Pro or Business subscription,
- the profile they are viewing is on that workspace's roster with a seat (or they are a Muso admin).

Caroline confirms these with existing reads, see `common-issues.md` section 7b.

**In the apps (iOS and Android) there is no switch.** The live counter and the LIVE badge appear by themselves on the Analytics **Lifetime** view when the workspace has the feature and the subscription is active. In the app there is nothing to turn on. Never name an app version and never say "update your app".

### Discovery
Find new and rising artists with data-driven insights. Available on Business plans. Filter songwriters by stream count, genre, and independence status.

---

## Catalog Audits

Find missing royalties. Available on Pro and Business plans.

### MLC Gap Detection
Identify missing works and unmatched recordings at the Mechanical Licensing Collective (MLC).

### ISRC-to-ISWC Matching
Detect mismatches between recording identifiers (ISRC) and composition identifiers (ISWC).

### Weekly Refresh
Audits update weekly with the latest MLC data.

### Stream Impact
See exactly how many streams are affected by each issue, with clear categorization of critical vs. partial issues.

---

## Discography Playlists

AI-curated Spotify playlist of your work. Available on Pro and Business plans.

Share your discography playlist on resumes, social media, and portfolios to showcase your body of work as a producer, songwriter, or engineer.

### If your playlist is missing or stale

If your Muso-generated Spotify discography playlist is missing, expired, or
stale, first confirm the tracks appear in your Muso discography. Then send your
Muso profile link, the generated playlist link if available, and one example
track that is missing so support can check the playlist mapping.

---

## App Language

On iPhone, open Settings > Apps > Muso > Preferred Language, choose your
language, and reopen Muso. On older iOS versions, use Settings > Muso >
Language. If a screen remains in another language, send a screenshot and your
device version to support.

---

## Business Workspaces

Multi-user collaboration for teams. Available on Business plans.

### Catalog Performance
Track streams, TikTok views, Shazams, playlists, and charts across your entire catalog.

### Aggregate Analytics
View total stats as a studio, label, or publisher -- not just individual profiles.

### Roster Performance
Daily updates on songwriters, producers, engineers, and students in your roster.

### Multi-User Access
Team collaboration with role-based access. Multiple team members can view and manage the workspace.

### List Analytics
Track custom lists of profiles for monitoring specific groups of talent.

### Client Self-Service
Enable clients to access their own analytics through your workspace.

---

## Credit and Catalog CSV Requests

If a customer asks for a CSV of their own credits or workspace catalog, ask
for their Muso profile link, which roles or part of the catalog they need,
their account email, and how they plan to use the file. Check what export
options are available for their plan and workspace before promising a download.
If no matching self-service option is available, send the request for manual
review and share a delivery estimate only after the team confirms one.
Full-catalog or bulk-data requests need review before any export is promised.

---

## Competitive Differentiation

| Differentiator | Description |
|----------------|-------------|
| **Verified Credits** | Identity verification through trusted third party |
| **AI/ML Powered** | Automated merging and cleaning of metadata |
| **Industry Partnerships** | Credits shared with Music Story, Airgigs, Campsite |
| **Complete Platform** | Credits + Analytics + Audits in one place |
| **Behind-the-Scenes Focus** | Built for producers, engineers, songwriters -- not just artists |
| **Community-Driven** | Richer credit data from global community contributions |

---

## The Problem Muso Solves

Over 50 million songs streaming right now are missing the majority of songwriter, producer, engineer, musician, management, and other behind-the-scenes credits.

- 95% of music collaborators are not properly credited on digital platforms
- 85% of songwriters globally have critical issues in their catalog (missing royalties)
- Millions of recordings are unlinked or unregistered at the MLC

---

## Data Validation

Muso.AI uses a multi-layer validation approach:
1. **Base Catalog**: Representation of what's on streaming services
2. **Profile Verification**: Legal identity verification via ID card scan (third-party, privacy-preserving)
3. **Artist Verification**: Social media account login proving access to artist page
4. **Album Admin System**: Verified artists control credits shown for their albums/tracks

---

## Industry Partners

Credits edited through Muso.AI are shared with:
- Music Story
- Airgigs
- Campsite
- Additional partners (expanding)

---

## Developer API

Build your own applications with verified credit data.

| Endpoint | Description |
|----------|-------------|
| Search | Find profiles, artists, tracks, albums |
| Profile Credits | Access verified credit data |
| Collaborators | View collaboration networks |
| Track Details | Get metadata for tracks |

Documentation: https://developer.muso.ai
