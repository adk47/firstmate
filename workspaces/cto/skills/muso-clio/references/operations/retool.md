# Retool - Internal Admin Panel

Main internal admin panel for Muso.AI. All teams can add widgets/pages for Operations and Sales teams to use.

Source: [Retool (Notion)](https://www.notion.so/af5412b08fc9409e81cdce6a017c8fdf)

## Overview

| Attribute | Value |
|-----------|-------|
| **URL** | [https://musoai.retool.com/](https://musoai.retool.com/) |
| **Cost** | ~$200/month |
| **Responsible** | Oleg Mamchich |
| **Teams** | Growth, Catalog, Operations, Sales |
| **Tags** | Admin, Operations |

---

## Key Retool Apps

| App | URL | Purpose |
|-----|-----|---------|
| **Claimings** | [Customer/Claimings](https://musoai.retool.com/apps/d506838a-10ed-11ee-90dc-d3ff437fbe64/Customer/Claimings) | Filter by user email and professional ID for claim requests |
| **OAuth Clients** | [Growth/OAuth Clients](https://musoai.retool.com/apps/61848680-5d82-11f0-923d-5fd32162fc75/Growth/OAuth%20Clients/page1) | SSO client management for partners |
| **Encore Shareables** | [Growth/Encore-share-abels](https://musoai.retool.com/apps/d43a2540-ae41-11ef-ba57-0fa3308b464b/Growth/Encore-share-abels) | Pre-sale and influencer plaque management |
| **Credits Lookup** | Catalog → Credits | Look up profiles by Spotify ID |
| **Merging/Linking** | Growth → Support → Merging → Linking | Link Spotify profiles to Muso profiles |

---

## Environment Switching

To switch to the **staging/dev environment**, append this to the Retool URL:

```
?_environment=staging
```

---

## Key Concepts

| Term | Definition |
|------|------------|
| **Workspace** | (Formerly "Team") - Organization unit for B2B clients |
| **Roster** | Collection of Profiles within a Workspace |
| **Profile** | Artist/music professional entity |
| **User** | Person with access to a Roster |
| **Seat Active** | Flag indicating analytics gathering is enabled |
| **Claiming Status** | Whether a profile has been claimed by its owner |
| **Cleansing** | Process of merging duplicate profiles and keeping correct ones |

---

## Workspace Creation Workflow

Sales team creates workspaces, then Catalog team cleanses them.

### Steps

1. **Create ACCOUNT**
   - Need one email (main contact)
   - Can be changed later

2. **Add LOGO**
   - Preferably JPG format

3. **Add USERS**
   - First check if user already exists
   - If existing: add them to workspace
   - If new: create user with **Name & Email**
   - Default password format: `name+muso`
   - **Warning**: Once password is created, it can't be fixed - must delete and recreate user
   - After creating, search and add them (not automatic)

4. **Add PROFILES**
   - Search in Muso, use the **profile ID**
   - **Seat Active** = Analytics gathering enabled (if paused, no analytics)
   - **Claiming Status** = Whether profile owner has claimed it
   - If artist not found, try their legal name

5. **CLEANSING**
   - Notify Catalog team in **#b2b-onboarding**: "NameWorkspace needs to be cleansed"
   - Catalog team merges profiles and keeps correct ones
   - Catalog team notifies back when done

6. **REVIEW Analytics**
   - Check analytics are ready before delivering workspace
   - Add workspace to demo account for easy review

7. **Send USER LOGINS**
   - Use Klaviyo for bulk sends (20+ users)

---

## User Lookup

**Path**: Retool → Users → List

1. Search using name or email
2. Copy the user ID
3. Paste ID in Amplitude (remove any commas)

---

## Artist Lookup by Spotify ID

**Path**: Retool → Catalog → Credits → Spotify ID

If artist **not found**:
1. Go to: Retool → Growth → Support → Merging → Linking
2. Add the Spotify link
3. Check again in ~1 hour

---

## SSO Client Setup (OAuth)

For setting up new SSO clients (e.g., BeatStars, Enginears):

### Steps

1. **Create client in Auth0**
   - Determine if client needs dev access (most use prod only)

2. **Adjust Auth0 settings**:
   - Set "cors enabled"
   - Set "idle token lifetime" to disabled
   - Set "Rotation overlap period" to 1296000 (or smaller, set to 60 in Retool)
   - Note: Some clients have "require refresh token rotation" as false

3. **Set client as "first party"** via API:
   ```
   PATCH https://musoai.us.auth0.com/api/v2/clients/xxx
   "is_first_party": true
   ```

4. **Add to musobackend db** (`clients` table):
   - Handles user consent to clients
   - Serves as backup for migration
   - Stores image references

5. **Upload images** to S3:
   - Bucket: `assets`
   - Folder: `oauth-clients/`
   - Save URL to clients table

**Management App**: [Growth/OAuth Clients](https://musoai.retool.com/apps/61848680-5d82-11f0-923d-5fd32162fc75/Growth/OAuth%20Clients/page1)

---

## Analytics Track Issues

**Path**: Retool → Ops Hub → Analytics Track Issues

**Important**: A source can only be assigned to a single track.

If you see error: "Link is already assigned to a different track: (Track ID)":
1. Go to the Track ID in the error message
2. Check if incorrectly added there
3. If so, remove from incorrect track
4. Add to correct Retool entry

---

## Encore Plaques (Pre-Sale/Influencer)

**App**: [Growth/Encore-share-abels](https://musoai.retool.com/apps/d43a2540-ae41-11ef-ba57-0fa3308b464b/Growth/Encore-share-abels)

**Requirements**:
- Needs workspace (create one for non-registered influencers)
- Sends email to workspace owner
- Each influencer needs workspace where they are the ONLY owner
- Can override email from Retool

**Data Sources**:
- [Influencers (Typeform)](https://admin.typeform.com/form/tQVXQMxp/results#responses)
- [Pre-Sales (Typeform)](https://admin.typeform.com/form/vF3Y2jRB/results#responses)

---

## Slack Channel

**#b2b-onboarding** - Used for workspace cleansing requests and notifications

---

## Related Notion Pages

- [Retool (internal admin panel)](https://www.notion.so/af5412b08fc9409e81cdce6a017c8fdf)
- [Retool - Sales Requests](https://www.notion.so/3eb715b78f07489c952a4f95afffc6e7)
- [SSO New Client flow](https://www.notion.so/22a0aeed21ad80069175c05affdf922c)

---

## Profile Unmerging Workflow

When profiles are incorrectly merged, follow this procedure.

**Retool Path**: Growth → Support → Merging → Credits

### Pre-Unmerge Checklist
1. **Verify `merged_to_id`** — In MongoDB `catalog_profile`, ensure it points to the actual main profile (Retool shows this as "merged into")
2. **Check credit intersection** in Retool:
   - Select the secondary profile → view its tracks
   - Insert main profile ID in the "collaborator" filter field
   - This shows tracks where BOTH profiles have credits
   - If shared tracks exist, move them to the main profile first using the "Move" button

### Unmerge Steps
1. Navigate to the merged profile in Retool (Growth → Support → Merging)
2. Click "Unmerge" button on the profile
3. This clears `merged_to_id` and sets `is_deleted = false`
4. The profile's raw IDs are preserved and it becomes a standalone entity

### Post-Unmerge Verification
1. Re-check credit intersection (should be zero or intentional collaborations only)
2. Verify profile appears in search/API
3. Check that credits display correctly on the newly unmerged profile

### Merge Prevention Rules (Invariant)
Profiles will NOT auto-merge if ANY of these conditions are true:
- Track similarity < 50% (shared tracks / total tracks)
- Name similarity < 80% (Levenshtein similarity score)
- **Claimed profiles are NEVER merged automatically** (critical invariant)

### Disambiguation Enhancement (Requested)
Display real relationship between profiles (direct vs through third party) in Retool. Requested by Iman but not yet implemented. This would show whether profiles share credits directly or through a third-party collaborator.

Source: KT 2026-02-02

---

## Known Issues

Source: KT 2026-02-03, 2026-02-04

### Source Link Removal Error

**Bug**: Clicking "Remove" button on a source link shows "no URL protocol specified error"

**Status**: Under investigation (assigned to Serhii)

**Workaround**: Manually reassign the source link in database to the correct track, or have engineering fix directly.

### Unmerge Timing

After unmerging a profile, only the **release date** field updates in real-time. Other changes (credits, stats) require pipeline processing and may take up to 24 hours.

### Source Link Assignment

A source (YouTube, Spotify, etc.) can only be assigned to a **single track**. If you see "Link is already assigned to a different track":

1. Go to the Track ID in the error message
2. Check if the link was incorrectly added there
3. Remove from incorrect track first
4. Then add to correct track

---

Last updated: 2026-02-04
