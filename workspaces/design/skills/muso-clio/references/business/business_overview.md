# Muso.AI Business Overview

## LLM Priming (Business Context)

### Company at a Glance
- Verified music credits platform for creators and industry teams
- Core value: correct metadata -> better recognition + analytics + royalties

### Product Surface (User-Facing)
- Credits Management (free)
- Analytics (pro)
- Catalog Audits (pro)
- Business/Enterprise workspaces
- Developer API

### Data Backbone (Internal)
- Industry data processing pipeline (raw -> catalog -> analytics)
- Airflow/Spark data platform + S3 data lake
- Core backend API + workers (credits, subscriptions, notifications)

### Sources of Truth
- `skills/muso-clio/references/cheatsheet.md` for a compact, cross-system summary
- `architecture/overview.md` for the high-level system overview
- `architecture/infrastructure.md` and `architecture/*.md` for repo-specific architecture
- This document for positioning and customer value
- `industry-data-processing` for catalog pipeline details
- `mobile` for mobile app status and stack
- Last updated: 2026-01-15

### Deep Dives (Repo Docs)
- Core backend: `core-backend/README.md`
- Web credits: `web-credits/README.md`
- Mobile app: `mobile/README.md`
- Industry data processing: `industry-data-processing/README.md`
- Platform data processing: `platform-data-processing/README.md`

## Company Summary

**Muso.AI** is the world's first verified music credits platform, founded in 2017 at NRG Recording Studios in Los Angeles. The platform helps music professionals clean up their credits, correct metadata, and share updates with industry platforms.

**Founders:**
- Jay Baumgardner (CEO, Award-Winning Producer & Mix Engineer)
- Kyran de Keijzer (Producer, Engineer, Artist)
- Aaron Kaufman (Musician, Engineer)

**Headquarters:** Los Angeles, CA and Amsterdam, Netherlands

**Database:** 4M+ music professional profiles

---

## Mission

To reinvent how musical contributors are credited, we capture rich music metadata and deliver an innovative end-user experience.

**Our Mission is to empower music professionals through innovative technology, rich metadata and credit analytics.**

---

## Vision

A world where each creative contributor gets the credit they deserve and innovation can thrive with the help of verified credit data.

**To establish Muso.AI as the one true source for verified music metadata and analytics.**

---

## Values

- **Focus on the customer:** We don't build features that we think are important - we ask customers what kind of tools they need most and leverage that information to create new, useful technology.

- **Innovation:** We are pioneers in a new market and a digital music industry. We are always working to maintain our position as leaders in music metadata management. We must ensure a high quality product and that can dynamically adapt to an ever-changing landscape so that organisation and individuals continue to recognise Muso.AI as the best platform for credit data.

- **Data Driven Decisions:** We make choices based on collected data from internal platform use or industry data points. Everyone in the company must understand the "why" behind each project and enhancement, which always comes down to the needs and requests of our users.

- **Customer Commitment:** We develop relationships that make a positive difference in our customers' lives.

- **Growth Mindset:** We are currently in a growth cycle and onboarding new team members regularly. Clear communication about the company's roadmap and vision from the leadership team is key. We operate with a hire fast, fire fast mentally by department heads but will always provide guidance and feedback to every team member about pace and performance.

- **Transparency:** We promise to maintain transparency with customers, employees, partners, investors and stakeholders. All departments in the company and each individual member will have access to the reports and metrics we use to define success. Interdepartmental communication is encouraged throughout the organisation, not just between department heads.

- **Quality:** Data is at the core of everything we do, and we want to make sure it's correct—our livelihood depends on it! Because we manage data for tens of thousands of people and hundreds of partners, we treat data inconsistencies with highest priority.

- **Teamwork:** From across the world and with various professional backgrounds, we come together each day to meet the needs of our customers and to elevate our platform.

- **Respect for People:** We value our people, encourage their development and reward their performance.

- **Ownership:** We are personally accountable for delivering on our commitments. Parts of the business processes will be owned by specific members of our teams. They will drive improvement, be responsible for metrics and will actively look for ways on to improve their impact.

---

## The Problem

> "Over 50 million songs streaming right now are missing the majority of songwriter, producer, engineer, musician, management, and other behind-the-scenes credits."

- **95% of music collaborators** are not properly credited on digital platforms
- Decades after streaming replaced physical media, outdated systems persist
- Email chains and pen-and-paper logs still drive crediting procedures
- Musicians, songwriters, producers, and contributors don't get recognized or paid
- **85% of songwriters globally** have critical issues in their catalog (missing royalties)
- Millions of recordings are unlinked or unregistered at the MLC (Mechanical Licensing Collective)

---

## Products & Value Propositions

### 1. Credits Management (Free)

**"Your Validated Discography"**

| Feature | Description |
|---------|-------------|
| **Profile Claiming** | Find and claim one or more profiles from millions in the database |
| **Profile Merging** | Combine naming variations across industry datasets into one cohesive profile |
| **Add Missing Credits** | Add legacy credits that were never properly captured |
| **Correct Legacy Credits** | Remove incorrect credits and fix errors |
| **Album Admin** | Become an admin on your catalog with complete control over credits |
| **Discography Playlist** | AI-curated Spotify playlist of your work to share on resumes |

**Value:** Fix your credits once, and updates are automatically shared with industry partners (Music Story, Airgigs, Campsite, and more).

---

### 2. Analytics (Pro)

**"Turn Your Credits Into Daily Stats"**

| Feature | Description |
|---------|-------------|
| **Lifetime Streaming Data** | View all-time total streams across 11 platforms |
| **Daily Updates** | Track credit performance with daily refresh (4PM EST) |
| **Multi-Platform** | Spotify, SoundCloud, YouTube, TikTok, Shazam, and more |
| **Filter by Role** | Sort stats by track, album, role, and collaborator |
| **Milestones & Charts** | Track career achievements and chart positions |
| **Discovery** | Find new and rising artists with data-driven insights |

**Platforms Tracked:**
- Spotify
- YouTube / YouTube Music
- SoundCloud
- TikTok
- Shazam
- And more (11 total)

**Value:** Artists aren't the only ones who deserve the spotlight. Behind-the-scenes creators can showcase their progress and set career goals.

---

### 3. Catalog Audits (Pro)

**"Find Missing Royalties"**

| Feature | Description |
|---------|-------------|
| **MLC Gap Detection** | Identify missing works and unmatched recordings at the MLC |
| **ISRC-to-ISWC Matching** | Detect mismatches between recording and composition identifiers |
| **Weekly Refresh** | Audits update weekly with latest MLC data |
| **Stream Impact** | See exactly how many streams are affected by issues |
| **Issue Categorization** | Critical vs. partial issues clearly identified |
| **Mobile Access** | Audit your catalog from anywhere |

**Value:** Recover mechanical royalties you're owed by identifying unlinked recordings and unregistered works.

---

### 4. Business (Enterprise)

**"Music Business Transparency. Simplified."**

**Target Customers:**
- Record Labels
- Publishers
- Management Companies
- Studios
- Music Schools

**Trusted by:** Napster, SoundExchange, AAM, Rimas Publishing, Netflix, Neon16

| Feature | Description |
|---------|-------------|
| **Catalog Performance** | Track streams, TikTok views, Shazams, playlists, charts |
| **Aggregate Analytics** | View total stats as a studio, label, or publisher |
| **Roster Performance** | Daily updates on songwriters, producers, engineers, students |
| **Multi-User Workspace** | Team collaboration with role-based access |
| **List Analytics** | Track custom lists of profiles |
| **Discovery Tools** | Find songwriters by stream count, genre, independence status |
| **Client Self-Service** | Enable super-charged client access |

**Value:** Uncover opportunities for missing royalties and win new clients with comprehensive roster insights.

---

### 5. Developer API

**"Build Your Own App with Our Credits"**

| Endpoint | Description |
|----------|-------------|
| Search | Find profiles, artists, tracks, albums |
| Profile Credits | Access verified credit data |
| Collaborators | View collaboration networks |
| Track Details | Get metadata for tracks |

**Documentation:** [developer.muso.ai](https://developer.muso.ai)

**Value:** Leverage the largest verified credits database in your own applications.

---

## Platform & Data Systems (Internal)

### Industry Data Processing (industry-data-processing repo)

- **Repo:** `industry-data-processing`
- **Purpose:** SQS-based Raw -> Catalog -> Analytics pipeline that ingests streaming and industry sources into the unified catalog.
- **Sources:** Spotify, MLC, Muso, Tidal, Genius, Jaxsta, YouTube Music
- **Data Stores:** MongoDB Atlas (raw/catalog), Aurora/PostgreSQL (stats/catalog/olap)
- **API:** FastAPI `/api/v1` for profiles, tracks, albums, search, and stats
- **Deployment:** EKS + Helm + KEDA autoscaling; Jenkins pipeline versioned via `.version`

### Mobile App (Flutter, in progress)

- **Repo:** `mobile`
- **Stack:** Flutter 3.35.7 / Dart 3.9, BLoC, auto_route, Dio (via `network_utils`), Freezed
- **Shared packages:** `muso_ui_kit`, `muso_assets_kit`, `domain_models`, `muso_common`, `network_utils`, `muso_notify`
- **Product surface:** Feed, credits, insights/analytics, roster, audits, plaques, subscriptions

---

## Pricing

### Lite (Free Forever)
- Manage Credits
- Update Profile Page
- Access Company Page
- Notifications

### Pro ($10-12.50/month)
- Everything in Lite
- Profile Analytics
- Catalog Audits
- Discography Playlists
- Milestones & Charts
- 1 Pro Seat included
- Additional seats: $7.50/month each

### Business ($24-30/month starting)
- Everything in Pro
- Company Analytics
- List Analytics
- Multi-User Workspace
- 5 Pro Seats included
- 3 Users included

**Pricing scales by roster size:**

| Profiles | Monthly (Annual) |
|----------|------------------|
| 1-5 | $24 |
| 6-10 | $40 |
| 11-50 | $104 |
| 51-100 | $176 |
| 101-250 | $384 |
| 251-500 | $640 |
| 501+ | $16/profile |

---

## Target Users

| Segment | Use Cases |
|---------|-----------|
| **Producers** | Track credits, view analytics, showcase work |
| **Songwriters** | Audit royalties, fix MLC gaps, manage catalog |
| **Engineers** | Claim credits, merge profiles, share discography |
| **Artists** | Become album admin, control credit display |
| **Visual Artists** | Document contributions |
| **Managers** | Monitor roster performance, discover talent |
| **Record Labels** | Aggregate analytics, catalog management |
| **Publishers** | Royalty audits, ISRC/ISWC matching |
| **Music Schools** | Track student performance and placements |

---

## Competitive Differentiation

> "Unlike a mix of disconnected point solutions, Muso.AI brings everything you need to manage your credits, showcase your discography, and support your music career in one simple, integrated platform."

| Differentiator | Description |
|----------------|-------------|
| **Verified Credits** | Identity verification through trusted third party |
| **AI/ML Powered** | Automated merging and cleaning of metadata |
| **Industry Partnerships** | Credits shared with Music Story, Airgigs, Campsite |
| **Complete Platform** | Credits + Analytics + Audits in one place |
| **Behind-the-Scenes Focus** | Built for producers, engineers, songwriters - not just artists |
| **Community-Driven** | Richer credit data from global community contributions |

---

## Data Validation

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

## Testimonials

> "Muso is the future of music crediting. I believe that the more people know about the process of how a good record is made, the more they will respect it."
> 
> **- Leo The Kind**, Composer / Artist / Producer

> "Muso is the most cutting edge and easy to navigate app I've had the pleasure to use, and an essential tool for every aspect of the music industry."
> 
> **- Matt Pinfield**, American Music Personality

> "Love using Muso as it allows me to track all my music streams all in one spot. Not only for my songs as an artist but as a song contributor (producer or writer) as well which is amazing."
> 
> **- EGZOD**, Producer / Songwriter / Artist

> "Muso.AI had already changed the game with their groundbreaking music credits platform, and now this new development empowers us to proactively detect missing ISRCs and resolve ISRC-to-ISWC mismatches across our catalog."
> 
> **- Rimas Publishing**

---

## Platform Availability

- **Web:** [credits.muso.ai](https://credits.muso.ai)
- **iOS:** [App Store](https://apps.apple.com/us/app/muso-ai/id1380264939) (Flutter app in progress at `mobile`)
- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.muso.ai.musoai) (Flutter app in progress at `mobile`)

---

## Contact

- **Website:** [muso.ai](https://muso.ai)
- **Support:** support@muso.ai
- **Knowledge Base:** [help.muso.ai](https://help.muso.ai)
- **Developer Docs:** [developer.muso.ai](https://developer.muso.ai)

**Social:**
- [Instagram](https://www.instagram.com/muso.ai/)
- [Facebook](https://www.facebook.com/MusoAIapp)
- [Twitter/X](https://twitter.com/ai_muso)
- [LinkedIn](https://www.linkedin.com/company/muso-ai)
