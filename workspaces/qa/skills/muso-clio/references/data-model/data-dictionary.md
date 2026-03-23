# Data Dictionary

UI-facing field definitions derived from `All Data Entities` documentation.

## Entities Overview

| Entity | Description | Primary Source |
|--------|-------------|----------------|
| **Profile** | Music professional (producer, writer, engineer) | User/Source + Calculation |
| **Artist** | Spotify artist entity | Spotify |
| **Track** | Song/recording | Spotify + Calculation |
| **Album** | Release/collection | Spotify + Calculation |
| **Role** | Credit role (parent/child) | Internal mapping |
| **User** | App user account | Internal |

---

## Album Entity

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| Album Art | Spotify | Album Details, Artist Albums, Artist Tracks, Profile Credits, Track Details | 640px, 300px, 64px sizes. URLs point to Spotify CDN. |
| Album Count | Calculation | Artist Details | Unique albums by artist (excludes featured-only) |
| Album ID | Internal | Artist Albums | Muso internal album ID |
| Album Name | Spotify | Album Details | Immutable from Spotify |
| Album Title | Spotify | Artist Albums | Immutable from Spotify |
| Album Type | Spotify + Calculation | Artist Albums | Values: Original, Featured, Single, EP, Compilation, Remix, Live Album |
| Artist | Spotify | Album Details | Album owner(s), can be multiple |
| Copyrights | Spotify | Album Details | C-line and P-line |
| Popularity | Spotify | Album Details, Artist Albums | 0-100, changes daily |
| Rank | Calculation | Album Details, Artist Albums | Rank 1-5 based on popularity percentile |
| Release Date | Spotify | Album Details, Artist Albums | **Quirk**: Year-only → defaults to Jan 1 |
| Spotify Album URL | Spotify | Album Details, Artist Albums | Link to Spotify |

### Rank Tiers (applies to Album, Artist, Track, Profile)

| Rank | Percentile | Description |
|------|------------|-------------|
| 1 | Top 0.01% | Elite |
| 2 | Top 1% | Very High |
| 3 | Top 10% | High |
| 4 | Top 30% | Medium |
| 5 | Top 60% | Standard |

---

## Artist Entity

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| Artist | Spotify | Track Details | All artists on track |
| Artist ID | Internal | Artist Tracks, Profile Credits | Muso internal ID |
| Artist IDs | Internal | Album Details | IDs for navigation |
| Artist Name | Spotify | Artist Details, Artist Tracks, Profile Credits | Immutable |
| Artist Picture | Spotify | Artist Details | 640px, 300px, 64px on Spotify CDN |
| Biography | User/Source | Artist Details | Long text, may contain entity links |
| Claimed Status | Claiming | Artist Details | Boolean - true if claimed by member |
| Location | User/Source | Artist Details | City and Country |
| Popularity | Spotify | Artist Details | 0-100, changes daily |
| Rank | Calculation | Artist Details | Rank 1-5 based on popularity |
| Social Links | User/Source | Artist Details | Spotify, Instagram, Twitter, Facebook, website, Fiverr |
| Spotify Artist URL | Spotify | Artist Collaborators, Profile Collaborators | Link to Spotify |

---

## Profile Entity

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| profile_type | Source/Automation | Profile Details | See profile_type values below |
| Biography | User/Source | Profile Details | Long text with possible entity links |
| Discography Playlist Image | Internal Service | Profile Details | Generated from top 4 popular albums |
| Discography Playlist URL | Internal Service | Profile Details | Spotify playlist URL |
| Location | User/Source | Profile Details | City and Country |
| Popularity | Calculation | Profile Details | **Calculated** - not from Spotify directly |
| Profile Name | User/Source | Profile Details | Professional name |
| Profile Picture | User/Source | Profile Details | From mobile upload, Tidal, or Jaxsta. **Should be stored on Muso servers** |
| Rank | Calculation | Profile Details | Rank 1-5 based on calculated popularity |
| Social Links | User/Source | Profile Details | Instagram, Twitter, Facebook, website |
| Artist Associations | Claiming/Source | Profile Details | Links professional to artist via claim |
| Credit Count | Calculation | Profile Details | Unique tracks worked on |

### profile_type Values

**Core types** (set by source data or Admin UI):

| Value | Description | Example |
|-------|-------------|---------|
| `artist` | Performing artist - solo or group | Drake, Coldplay |
| `professional` | Behind-the-scenes music professional | Producers, engineers, songwriters |
| `organization` | Business entity | Record labels, publishers, studios |
| `person` | Individual human (generic) | Used when role is ambiguous |
| `band` | Music group/collective | Alternative to `artist` for groups |

**Automation-assigned types** (set by pipeline, cannot be set via Admin UI):

| Value | Description | Trigger |
|-------|-------------|---------|
| `compilation_profile` | Compilation/Various Artists profile | >50% of tracks match compilation patterns AND >100 tracks |
| `non_music_profile` | Non-music content (audiobooks, podcasts) | >50% of tracks match non-music patterns AND >100 tracks |

**To update `profile_type`:**
- **Admin UI**: https://admin-production.muso.ai/
- **MongoDB**: `db.catalog_profile.updateOne({_id: 'UUID'}, {$set: {profile_type: 'professional'}})`
- **Access Guide**: https://www.notion.so/adb0059a507743bd8120be793a6648df

---

## Track Entity

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| Copyrights | Spotify | Track Details | C-line and P-line |
| Credit Count | Calculation | Profile Details | Tracks professional worked on |
| Credit(s) | User/Source | Profile Credits | Child credits on track |
| Duration | Spotify | Track Details | Minutes:Seconds format |
| Key | Spotify | Track Details | Number mapped to letter (internal mapping) |
| Popularity | Spotify | Artist Tracks, Profile Credits, Track Details | 0-100, changes daily |
| Preview URL | Spotify | Artist Tracks, Profile Credits | 30-second MP3 on Spotify CDN |
| Rank | Calculation | Artist Tracks, Profile Credits, Track Details | Rank 1-5 |
| Release Date | Spotify | Artist Tracks, Profile Credits, Track Details | **Quirk**: Year-only → Jan 1 |
| Spotify Track URL | Spotify | Artist Tracks, Profile Credits, Track Details | Link to Spotify |
| Tempo | Spotify | Track Details | BPM (< 300) |
| Track Count | Calculation | Album Details, Artist Details | Unique tracks |
| Track ID | Internal | Artist Tracks, Profile Credits, Track Credits | Muso internal ID |
| Track Title | Spotify | Artist Tracks, Profile Credits, Track Details | Immutable |

---

## Collaborator Entity (Artist/Profile)

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| Collaborator Count | Calculation | Album Details, Artist Details | Unique collaborators worked with |
| Collaborator ID | Internal | Various | Internal Profile/Artist ID |
| Collaborator Name | User/Source | Artist/Profile Collaborators | From Spotify (artist) or user upload (profile) |
| Collaborator Picture | User/Source | Album Credits, Track Credits | Spotify CDN or user upload |
| Collaborator Title | User/Source | Album Credits, Track Credits | Role title |
| Collaborator Type | Internal | Collaborators | "Profile" or "Artist" |
| Collabs | Calculation | Artist/Profile Collaborators | Unique tracks worked on together |
| Last Collab Date | Calculation | Collaborators | Most recent release date together |

---

## Credit/Role Entity

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| Common Credit | Calculation | Artist/Profile Details, Collaborators | "Artist" (if artist page) + 3 most used child credits |
| Credit(s) | Calculation | Artist Tracks | Child credits on track (primary/featured/remix artist only) |
| Credit(s) | Various | Album/Track Credits | Parent + child credits aggregated |

### Parent Credit Categories

- Songwriter
- Producer
- Musician
- Engineer
- Visual
- Management
- Organization
- Other

Child credits mapped via: [Credit Category Mapping Sheet](https://docs.google.com/spreadsheets/d/1cOithm35BV2R1MjbdeCZ6_vq_E-KiWEEAz5t96J_558/edit#gid=62218281)

---

## User Entity

| Field | Source | Pages Used | Notes |
|-------|--------|------------|-------|
| Subscription Status | Internal Service | Profile Details | Values: null, trial, pro, cancelled |
| Verification Status | Admin | Profile Details | Boolean - true if ID verified by super-admin |

---

## Known Data Quirks

1. **Release dates**: Spotify sometimes returns year only → system defaults to January 1st
2. **Profile popularity**: Must be calculated internally (not from Spotify)
3. **Profile pictures**: Should be downloaded and stored on Muso servers (not linked to external CDN)
4. **Artist pictures**: Currently stored as URLs to Spotify CDN
5. **Rank calculation**: Must be computed for all entities based on popularity percentiles
6. **Credits inside tracks**: In MongoDB `catalog_track`, credits are stored as nested `profiles` array for query efficiency
