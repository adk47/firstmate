# Credits and Profiles

## How Music Credits Work on Muso.AI

Muso.AI organizes music data using an entity model with two parallel hierarchies:

### Publishing Side (Royalties)
- **Work (ISWC)**: The underlying composition -- melody, lyrics, harmony. What songwriters create. Earns publishing/songwriter royalties via PROs (ASCAP, BMI, etc.). One work can have 300+ recordings (covers, remixes, different artists).

### Master Side (Recordings)
- **Album**: A grouping of related releases (e.g., standard + deluxe + Japan edition of the same album).
- **Release (UPC)**: A distributed product -- the actual thing on Spotify/CD. Has a release date that cannot change. Any change to the recording list = new release with new UPC.
- **Recording (ISRC)**: The actual audio file -- the master. Any change to the audio = new recording with new ISRC. Earns master royalties (distinct from publishing royalties).
- **Track**: Muso's deduplication layer. Groups equivalent recordings of the same song across different platforms. Credits and aggregated stats live at the Track level.

### Quick Reference

| Entity | Identifier | What it is | Key Point |
|--------|------------|-----------|-----------|
| Work | ISWC | The underlying composition | Earns publishing royalties |
| Album | Muso ID | A grouping of related releases | Standard + deluxe + regional = one album |
| Release | UPC | A distributed product | The actual thing on Spotify -- fixed date |
| Recording | ISRC | A specific audio file | The master -- any change = new ISRC |
| Track | Muso ID | A grouping of equivalent recordings | Deduplication layer across sources |

### Why Track Exists

Different platforms often have different ISRCs or metadata for the same song. Track is Muso's normalization layer to deduplicate and aggregate.

---

## Profile Types

A profile represents a music professional or entity in the Muso.AI database:
- Artist (performer)
- Producer
- Writer/Songwriter
- Engineer
- Label
- Publisher

---

## Credit Roles

A credit links a profile to a track or album:

| Category | Roles |
|----------|-------|
| **Primary** | Artist, Featured Artist |
| **Production** | Producer, Executive Producer, Co-Producer |
| **Writing** | Writer, Composer, Lyricist |
| **Engineering** | Mixing Engineer, Mastering Engineer, Recording Engineer |
| **Other** | A&R, Creative Director, etc. |

---

## Claiming and Verification

### Profile Claiming
1. Request claim on a profile
2. Provide verification (ID card scan or social media login)
3. Admin review
4. Claim approved or denied

### Verification Types
- **Profile Verification**: Legal identity verification via ID card scan (third-party, privacy-preserving)
- **Artist Verification**: Social media account login proving access to artist page
- **Album Admin**: Verified artists control credits shown for their albums/tracks

### Profile Merging
Combining duplicate profiles when the same person appears in different sources:
- Consolidates credits and stats
- Maintains source tracking

---

## Industry Identifiers

| Code | Full Name | Identifies |
|------|-----------|-----------|
| **ISRC** | International Standard Recording Code | A specific recording (audio file) |
| **ISWC** | International Standard Musical Work Code | A musical composition (the underlying work) |
| **UPC** | Universal Product Code | A release/album product |

### MLC (Mechanical Licensing Collective)
US organization that collects mechanical royalties for streaming. Muso.AI integrates with MLC data for gap detection in Catalog Audits.

---

## Credits from External Sources

Muso acts as a mirror of what exists in the music industry. If incorrect credits come from an external platform like Spotify:
- The correction must be made on that platform first
- Once fixed there, Muso will reflect the change automatically

---

## Workspaces and Teams

| Concept | Description |
|---------|-------------|
| **Workspace** | Organization unit for team collaboration |
| **Seats** | Profile slots in a subscription (Pro: 1, Business: 5+) |
| **Members** | User accounts with access to the workspace |
| **Roster** | A workspace-managed set of profiles (e.g., an artist roster for a manager or label) |

---

## Analytics Terms

### Milestones
Streaming achievement thresholds: 10K, 100K, 1M, 10M, 100M, 1B streams.

### Platform Stats
Per-platform metrics:
- **Spotify**: Monthly listeners, followers, popularity
- **YouTube**: Views, subscribers
- **TikTok**: Creates, sounds used
- **Shazam**: Shazams by region
