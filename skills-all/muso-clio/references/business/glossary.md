# Muso.AI Glossary

## Core Data Entities

Understanding Muso's entity model is **critical**. There are two parallel hierarchies:

```
PUBLISHING SIDE (Royalties)          MASTER SIDE (Recordings)
───────────────────────────          ────────────────────────

┌─────────────┐                      ┌─────────────┐
│    WORK     │                      │   ALBUM     │
│   (ISWC)    │                      │ (Muso ID)   │
└──────┬──────┘                      └──────┬──────┘
       │                                    │
       │ 1:many                             │ 1:many
       │ (one work can have                 │
       │  300+ recordings)                  ▼
       │                             ┌─────────────┐
       │                             │  RELEASE    │
       │                             │   (UPC)     │
       │                             └──────┬──────┘
       │                                    │
       │                                    │ 1:many
       ▼                                    ▼
┌─────────────────────────────────────────────────┐
│                  RECORDING                       │
│                   (ISRC)                         │
└─────────────────────────┬───────────────────────┘
                          │
                          │ many:1
                          ▼
                   ┌─────────────┐
                   │   TRACK     │
                   │ (Muso ID)   │  ← Deduplication layer
                   └─────────────┘
```

### Work (ISWC)
**The underlying composition** — melody, lyrics, harmony. What songwriters create.

- Identified by ISWC (International Standard Musical Work Code)
- Earns **publishing/songwriter royalties** via PROs (ASCAP, BMI, etc.)
- One work can have 300+ recordings (covers, remixes, different artists)
- Tracked via MLC data in Muso

### Album (Muso ID)
**A grouping of related releases.** Internal Muso identifier.

- Groups releases with same name/content (standard + deluxe + Japan edition)
- Allows viewing aggregate stats across all versions
- Example: "Midnights" album = standard, 3am edition, deluxe, vinyl editions

### Release (UPC)
**A distributed product** — the actual thing on Spotify/CD. Identified by UPC.

- Has a **release date that cannot change**
- Any change to the recording list = **new release with new UPC**
- Examples: CD, streaming album, single, EP
- Contains metadata: title, artwork, label, distributor

### Recording (ISRC)
**The actual audio file** — the master. Identified by ISRC.

- Any change to the audio = **new recording with new ISRC**
- Examples requiring new ISRC: different mix, radio edit, explicit vs clean
- Earns **master royalties** (distinct from publishing royalties)
- Links to Work (composition) on the publishing side

### Track (Muso ID)
**A grouping of equivalent recordings.** Internal Muso identifier. **Deduplication layer.**

- Groups recordings that are the same song across different sources
- When "Shape of You" appears on Spotify, Tidal, Apple Music with slightly different ISRCs → Muso groups them into one Track
- Usually 1 recording per track, but can be many
- Credits and aggregated stats live at the Track level

**Why Track exists**: Different platforms often have different ISRCs or metadata for the same song. Track is Muso's normalization layer to deduplicate and aggregate.

### Quick Reference Table

| Entity    | Identifier | What it is                              | Key Point                                    |
|-----------|------------|-----------------------------------------|----------------------------------------------|
| Work      | ISWC       | The underlying composition              | Earns publishing royalties                   |
| Album     | Muso ID    | A grouping of related releases          | Standard + deluxe + regional = one album     |
| Release   | UPC        | A distributed product                   | The actual thing on Spotify — fixed date     |
| Recording | ISRC       | A specific audio file                   | The master — any change = new ISRC           |
| Track     | Muso ID    | A grouping of equivalent recordings     | Deduplication layer across sources           |

---

## Profile & Credits

### Profile
A music professional or entity in the Muso.AI database. Can be:
- Artist (performer)
- Producer
- Writer/Songwriter
- Engineer
- Label
- Publisher

### Credit
A role assignment linking a profile to a track or album:
- **Primary roles**: Artist, Featured Artist
- **Production roles**: Producer, Executive Producer, Co-Producer
- **Writing roles**: Writer, Composer, Lyricist
- **Engineering roles**: Mixing Engineer, Mastering Engineer, Recording Engineer
- **Other roles**: A&R, Creative Director, etc.

---

## Identity Concepts

The model works like YouTube: the Google account is the login and is never shown, everything you do you do *as a channel*, every account gets a personal channel at creation (viewers included), a Brand Account channel has several managers who post as it, and the channel switcher is global. Canonical: `muso-docs/adr/2026-09-11-identity-model-accounts-channels-workspaces.md` (proposed 2026-09-11).

### Account
The human's login (`users` row: email, plan, OAuth ids). Never a node on the social graph, never shown to other users. YouTube: the Google account.

### Identity
A catalog profile an account may act as. Every social edge (follow, connection, chat room, post, view) is identity-to-identity, never account-to-account.
- **Personal identity**: the auto-profile minted at signup (`users.neptuneProfessionalId`), self-claimed on the default workspace. Every account has one, listeners included (consumer roles such as `Audiophile`). Claiming your own person profile folds the shell into it, so one person has one primary identity. YouTube: the personal channel.
- **Managed identity**: a claimed profile the account holds write rights on through a workspace (`canUserRepresentProfile`). YouTube: a Brand Account channel.
- **Worn identity ("appear as")**: `users.representationProfileId`, ONE global column. YouTube: the channel switcher. There is no standalone workspace switch: the one switcher shows the personal identity on top and one collapsed group per workspace; the user picks an identity *inside* a workspace, so the active (identity, workspace) pair is always explicit. Each group remembers its last pick; a group with nothing to wear is entered as the personal identity.
- Two identities of one account are never auto-linked: aliases are private.

### Manager
A workspace member with write rights on an identity. Managers are members of every chat room of that identity, get its notifications and act as it; the counterpart sees only the identity. Read rights grant none of this.

## Organization Concepts

### Workspace/Team
Management container, not an identity scope (YouTube has no equivalent; Meta Business Portfolio is the closest):
- Seats (profile slots)
- Members (user accounts) with per-profile rights (write/read)
- Billing/subscription and connect quota
- Roster (managed profiles) — the Your-work subject, remembered per workspace
- Grants the right to wear an identity; never decides which one is worn — the user does, by picking an identity inside the workspace's group in the switcher
- The workspace inbox is a filter over the account's identities, not a scope: rooms are keyed on profile pairs and carry no workspace

### Roster
A workspace-managed set of profiles:
- Typically artist rosters for managers/labels
- Enables bulk analytics viewing
- Shared across team members

## Industry Terms

### Catalog
The unified industry dataset built from multiple sources:
- Raw data ingested from sources
- Merged and deduplicated
- Normalized for consistency

### Raw
Source-specific data before processing:
- `raw_spotify_*` - Spotify data
- `raw_mlc_*` - MLC data
- Etc.

### Neptune Professional ID
Internal identifier linking a profile to the industry catalog. Used to fetch enriched data from the industry-data-processing API.

### ISRC
International Standard Recording Code - unique identifier for a recording (track).

### ISWC
International Standard Musical Work Code - unique identifier for a musical composition (underlying work).

### UPC
Universal Product Code - unique identifier for a release/album.

### MLC
Mechanical Licensing Collective - US organization that collects mechanical royalties for streaming. Muso.AI integrates with MLC for gap detection.

## Analytics Terms

### Milestone
Streaming achievement thresholds:
- 10K streams
- 100K streams
- 1M streams
- 10M streams
- 100M streams
- 1B streams

### Trend
Change in metrics over time:
- Daily/weekly/monthly views
- Growth rate calculations
- Comparisons to previous periods

### Platform Stats
Per-platform metrics:
- **Spotify**: Monthly listeners, followers, popularity
- **YouTube**: Views, subscribers
- **TikTok**: Creates, sounds used
- **Shazam**: Shazams by region

## Technical Terms

### Claiming
Process where a user verifies ownership of a profile:
1. Request claim
2. Provide verification (ID/social login)
3. Admin review
4. Claim approved/denied

A processed claiming (personal `userId`, or a workspace `teamId` plus member rights) is what makes a profile an identity the account may act as. The personal identity's claiming is created at signup/backfill, not by this review flow.

### Merging
Combining duplicate profiles:
- Identifies same person in different sources
- Consolidates credits and stats
- Maintains source tracking

### Soft Delete
Marking records as deleted without removing:
- `deleted` embedded subdoc: `deleted.is_deleted`, `deleted.deleted_timestamp`, `deleted.deleted_by` (never top-level fields)
- Preserves data integrity
- Enables recovery

## Subscription Terms

### Seat
A profile slot in a workspace/subscription:
- Pro: 1 seat
- Pro+: 3 seats
- Business: 5 seats (expandable)

### Profile Limit
Maximum profiles a subscription can track analytics for.

### User Limit
Maximum team members who can access a workspace.
