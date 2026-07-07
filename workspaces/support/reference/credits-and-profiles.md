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

This flow assumes the claimant IS the artist. When a manager, publisher, or label needs access on an artist's behalf (e.g. the artist has no social media), this self-claim flow does NOT apply – see `common-issues.md` row 2b (on-behalf claims, manual admin review).

### Verification Types
- **Profile Verification**: Legal identity verification via ID card scan (third-party, privacy-preserving)
- **Artist Verification**: Social media account login proving access to artist page
- **Album Admin**: Verified artists control credits shown for their albums/tracks

### Pending Credit Verification Proof
When a credit is waiting on extra proof, ask the customer to upload it directly
in chat. Helpful proof includes official streaming-platform or label credits,
distributor metadata, PRO registrations, split sheets, session screenshots,
invoices, contracts, or a clear collaborator confirmation. Ask for the Muso
profile, track title, artist, requested role, release link when available, and
proof that connects the person to that role.

WhatsApp, email, or social messages can help if they clearly show the track and
role, but official metadata is stronger. Do not promise approval or a fixed
approval date.

### Profile Merging
Combining duplicate profiles when the same person appears in different sources:
- Consolidates credits and stats
- Maintains source tracking

For duplicate profile merge requests, collect every Muso profile link, which
profile should remain as the main profile, and any naming context such as artist
name versus legal name. Merges involving claimed profiles, company or label
profiles, subscription questions, or large catalogs need manual review before
credits and analytics are consolidated.

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

### Adding a Missing Credit
To add a missing credit, ask the customer to search for the track or release in
the Muso app, open the track, choose Add Missing Credits when available, select
the role, and submit supporting proof. If the button is missing, the profile
cannot be edited, the track cannot be found, or the customer is trying to edit an
already claimed profile, collect the profile link, track or release link,
requested role, and screenshots so the team can review manually.

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
