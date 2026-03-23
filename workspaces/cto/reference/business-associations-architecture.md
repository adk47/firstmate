# Business & Product Associations — Architecture Proposal

**Date:** 2026-02-17
**Author:** Clio
**Status:** Draft for Review

---

## The Problem

Companies in the music industry aren't just labels or publishers — they're gear makers (Dutch & Dutch), studios (SING Mastering), software companies (iZotope), distributors (DistroKid), and more. They want presence on Muso with relationships to the professionals who use their products/services.

This is fundamentally different from credits. A credit says "this person contributed creatively to this recording." A business association says "this person/track has a relationship with this company's product or service."

### Key Use Cases

1. **Dutch & Dutch** wants to show which engineers/producers use their monitors
2. **SING Mastering** wants to show all tracks mastered through their studio
3. **iZotope** wants to show producers who use their plugins
4. **A producer** wants to show (or hide) that they use certain gear on their profile
5. **A track page** should only show business associations relevant to the viewer's profile

---

## Core Design Principles

### 1. Associations Are Bilateral — Both Parties Must Consent

A company can claim "Producer X uses our monitors." Producer X must confirm. Until confirmed, the association exists but is not publicly visible.

This mirrors how credits work — but with an important addition: either party can suppress visibility on their own pages.

### 2. Associations Have Time Boundaries

Every association has:
- `start_date` — when the relationship began (nullable = "ongoing since unknown")
- `end_date` — when it ended (nullable = "still active")

Dutch & Dutch endorsement deals expire. Studios close. Engineers switch gear. Time boundaries prevent stale data from accumulating.

### 3. Per-Profile Visibility Control on Tracks

This is the hard one. Aaron's right to flag it.

**The scenario:** A track has 5 credited collaborators. The producer wants to show "Mixed on Dutch & Dutch 8c monitors" on the track. The vocalist doesn't care and doesn't want gear clutter on their view of the track.

**Solution: Profile-scoped visibility on track associations.**

When you navigate to a track page *from* a profile, you see that profile's version of reality:
- From the producer's profile → you see their business associations on the track
- From the vocalist's profile → you don't see associations they've hidden/not opted into
- Direct link to track (no profile context) → show only associations where ALL credited profiles have approved, OR show none (configurable)

This means track-level business associations need a visibility matrix, not a single boolean.

### 4. Separate From Credits — Always

Business associations never pollute the credits array. Different data structure, different UI section, different API endpoints. The day these get mixed is the day the data model becomes unmaintainable.

---

## Data Model

### New: `business_association` (MongoDB — catalog layer)

```
business_association: {
    _id: ObjectId,

    // The company
    company_profile_id: ObjectId,       // Must be profile_type: 'organization'
    company_name: String,               // Denormalized for display

    // The associated entity (polymorphic)
    entity_type: 'profile' | 'track' | 'album',
    entity_id: ObjectId,

    // What kind of relationship
    association_type: String,           // 'endorsement', 'service', 'equipment', 'software', 'distribution'
    association_subtype: String,        // 'studio_monitors', 'mastering', 'plugin', etc.
    description: String,               // Free text: "Primary mixing monitors"

    // Time boundaries
    start_date: Date | null,
    end_date: Date | null,

    // Who initiated it
    initiated_by: 'company' | 'individual',
    initiator_profile_id: ObjectId,

    // Consent & visibility
    status: 'pending' | 'confirmed' | 'rejected' | 'withdrawn',
    company_visible: Boolean,           // Company wants this shown on their page
    entity_visible: Boolean,            // Individual/track owner wants this shown on their page

    // For track associations: per-collaborator visibility
    // Only relevant when entity_type = 'track'
    collaborator_visibility: [
        {
            profile_id: ObjectId,       // A credited collaborator on the track
            visible: Boolean,           // Does this collaborator want this shown?
            decided_at: Date | null     // null = hasn't decided yet (default: hidden)
        }
    ],

    // Metadata
    source: 'user_added' | 'company_added' | 'derived',
    verified: Boolean,
    created_at: Date,
    updated_at: Date,
    deleted_timestamp: Date | null      // Soft delete (matches existing pattern)
}
```

### New: `association_type` Dictionary (MongoDB — dict layer)

```
dict_association_type: {
    _id: ObjectId,
    key: String,                        // 'studio_monitors', 'mastering_service', 'plugin'
    category: String,                   // 'equipment', 'service', 'software', 'distribution'
    display_name: String,               // 'Studio Monitors'
    parent_key: String | null,          // For hierarchy: 'monitors' -> 'equipment'
    icon: String | null,
    sort_order: Number
}
```

### Extended: `catalog_member` (existing)

For company ↔ person membership (employees, roster, endorsees):

```
catalog_member (existing fields):
    profile_id: ObjectId,              // The company
    member_id: ObjectId,               // The person
    membership_type: String            // Existing: 'record_label', 'manager', 'publisher'

New membership_type values:
    'service_provider'                 // Person works at/for the company
    'endorsee'                         // Person is endorsed by / uses the company's products
    'affiliate'                        // Looser business relationship

New fields:
    service_type: String | null,       // 'mastering_engineer', 'monitor_user', etc.
    start_date: Date | null,
    end_date: Date | null,
    status: 'active' | 'pending' | 'expired'
```

---

## Visibility Logic

### The Track Page Problem

```
Track: "Midnight Train"
Credits: [Producer A, Vocalist B, Engineer C, Mixer D]

Business associations on this track:
  - Dutch & Dutch (monitors) — added by Mixer D
  - iZotope RX (software) — added by Engineer C
  - SING Mastering (service) — added by Engineer C

Scenario 1: User arrives at track from Mixer D's profile
  → Show: Dutch & Dutch (Mixer D approved)
  → Hide: iZotope, SING (not Mixer D's associations)

Scenario 2: User arrives at track from Engineer C's profile
  → Show: iZotope, SING (Engineer C approved)
  → Hide: Dutch & Dutch (not Engineer C's association)

Scenario 3: User arrives at track directly (no profile context)
  → Option A: Show nothing (cleanest)
  → Option B: Show associations where ALL collaborators approved
  → Option C: Show all confirmed associations grouped by who added them
  → Recommendation: Option A for now. Add C later when UI is ready.

Scenario 4: User arrives from Dutch & Dutch's company profile
  → Show: Dutch & Dutch association (they're the company)
  → Hide: Others (not their associations)
```

### Implementation: Profile Context Parameter

The track page API already receives a `profile_id` context in some views. Extend this:

```
GET /api/v1/track/{id}?profile_context={profile_id}

Response includes:
{
    ...track data...,
    business_associations: [
        // Only associations visible in this profile's context
        // Empty array if no profile_context provided (Scenario 3)
    ]
}
```

This keeps the existing track page clean while enabling the new feature progressively.

### Profile Page Visibility

```
GET /api/v1/profile/{id}

For a company profile (Dutch & Dutch):
{
    ...profile data...,
    associations: {
        endorsees: [...profiles using their products...],
        tracks: [...tracks associated with their products...],
        // Only includes status: 'confirmed' where company_visible: true
    }
}

For a person profile (Mixer D):
{
    ...profile data...,
    business_associations: [
        // Only where entity_visible: true AND status: 'confirmed'
        { company: "Dutch & Dutch", type: "Studio Monitors", since: "2024-03" }
    ]
}
```

---

## Consent Flow

### Company Claims Individual

```
Dutch & Dutch adds association → status: 'pending'
  → Notification to individual (in-app + email)
  → Individual confirms → status: 'confirmed', entity_visible: true
  → Individual rejects → status: 'rejected'

Until confirmed:
  - NOT visible on individual's profile
  - NOT visible on track pages
  - Visible to Dutch & Dutch in their admin as "pending"
```

### Individual Claims Company

```
Producer adds "I use Dutch & Dutch 8c" → status: 'pending'
  → If Dutch & Dutch has a claimed workspace: notification to workspace admin
  → If unclaimed: auto-confirm (individual is the source of truth for their own gear)
  → Company confirms → status: 'confirmed', company_visible: true

Special case — unclaimed companies:
  Many gear/service companies won't have Muso profiles initially.
  When an individual adds an association to an unclaimed company:
  - Auto-create organization profile if needed
  - Auto-confirm the association
  - When company eventually claims their profile, they can review existing associations
```

### Withdrawal

Either party can withdraw at any time:
- Company withdraws → association hidden everywhere
- Individual withdraws → association hidden from their profile/tracks
- Neither deletes the record — soft state change for audit trail

---

## Derived Associations (Phase 2)

The "show me all tracks my people worked on" use case from the earlier discussion:

```
Company: SING Mastering
Members (via catalog_member): [Colin Leonard, Engineer B]
Colin's credits: [Track 1, Track 2, Track 3]
Engineer B's credits: [Track 4, Track 5]

Derived track list for SING Mastering: [Track 1-5]
Source: 'derived' (not user_added)
```

These derived associations:
- Don't require individual consent (they're computed from existing public credits)
- Are marked `source: 'derived'` to distinguish from explicit associations
- Can be overridden: if Colin removes himself from SING's roster, derived associations update
- Don't appear on track pages (only on the company profile page as "tracks our team worked on")

---

## API Endpoints

### Core Backend (new routes)

```
# Company-facing
POST   /api/v4/profile/{company_id}/associations          — Create association
GET    /api/v4/profile/{company_id}/associations          — List company's associations
PATCH  /api/v4/profile/{company_id}/associations/{id}     — Update (visibility, dates)
DELETE /api/v4/profile/{company_id}/associations/{id}     — Withdraw

# Individual-facing
GET    /api/v4/profile/{profile_id}/business-associations  — My business associations
POST   /api/v4/profile/{profile_id}/business-associations  — Add association (I use X)
PATCH  /api/v4/associations/{id}/respond                   — Confirm/reject pending
PATCH  /api/v4/associations/{id}/visibility                — Toggle visibility

# Track-level (extends existing)
GET    /api/v1/track/{id}/business-associations?profile_context={id}
```

### Industry Data Processing (catalog worker)

New SQS message types:
- `business_association.sync` — process new/updated associations
- `business_association.derive` — recompute derived associations when membership changes

---

## Migration & Rollout Plan

### Phase 1: Foundation (4-6 weeks)

- Add `business_association` collection to MongoDB
- Add `dict_association_type` with initial taxonomy
- Extend `catalog_member` with new membership types + date fields
- Build core API endpoints (CRUD + consent flow)
- No UI changes — API only, testable via admin tools/Retool

### Phase 2: Company Profiles (3-4 weeks)

- Company profile page shows associations (endorsees, team tracks)
- Organization profiles get "Associations" tab
- Workspace admin can manage associations
- Individual profile shows "Products & Services" section (if any confirmed)

### Phase 3: Track-Level Display (4-6 weeks)

- Track page gets "Services & Business" section
- Profile-context-aware visibility logic
- Per-collaborator opt-in/out UI
- Notification system for consent requests

### Phase 4: Derived Associations (2-3 weeks)

- Catalog worker computes derived track lists from membership + credits
- Company pages show "Tracks by our team" section
- Auto-refresh when membership or credits change

---

## Open Questions

1. **Default visibility for unclaimed companies.** If a producer says "I use Dutch & Dutch" and Dutch & Dutch isn't on Muso yet — is it visible on the producer's profile immediately? (Recommendation: yes, since the individual is asserting their own usage.)

2. **Association taxonomy depth.** How granular? Just "equipment" and "service"? Or down to "studio monitors > nearfield > Dutch & Dutch 8c"? (Recommendation: start with 2 levels — category + subtype. Don't over-engineer the taxonomy early.)

3. **Track page without profile context.** What shows? Nothing? Everything confirmed? (Recommendation: nothing for now. Cleaner UX, simpler logic, add later.)

4. **Can companies associate directly with tracks without going through a person?** Example: "This track was mastered at SING Mastering" without specifying which engineer. (Recommendation: yes, in Phase 3. Requires track owner consent.)

5. **Verification level.** Is mutual consent enough, or do some associations need additional proof? (Recommendation: mutual consent for now. Add verification badges later for sponsored/official endorsements.)

6. **Rate limiting.** Can a company spam-associate with 10,000 profiles? (Recommendation: yes, needs rate limits + bulk consent UI for individuals. Cap pending associations per company at something reasonable like 100/day.)

---

## Why Not Credits?

Just to be explicit about why this is a separate system:

```
Credits:                              Business Associations:
─────────────────────────────         ─────────────────────────────
Creative contribution to a recording  Business/product relationship
Per-track, always visible             Per-track with visibility control
Industry standard (liner notes)       No industry standard
Verified via metadata sources         Verified via mutual consent
No time boundaries                    Time-bounded (deals expire)
One view for all visitors             Different view per profile context
Deeply embedded in all systems        New, isolated system
```

Mixing these would mean every track page shows gear endorsements alongside songwriter credits. That's not what anyone wants.

---

## Summary

```
              ┌─────────────────┐
              │  Company Profile │
              │  (organization)  │
              └────────┬────────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
          ▼            ▼            ▼
    ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ Members  │ │ Profile  │ │  Track   │
    │ (roster) │ │ Assoc.   │ │ Assoc.   │
    │          │ │          │ │          │
    │ catalog_ │ │ business_│ │ business_│
    │ member   │ │ assoc.   │ │ assoc.   │
    └──────────┘ └──────────┘ └──────────┘
         │            │            │
         │            │            ▼
         │            │     ┌──────────────┐
         │            │     │ Collaborator │
         │            │     │ Visibility   │
         │            │     │ Matrix       │
         │            │     └──────────────┘
         │            │
         ▼            ▼
    ┌────────────────────┐
    │  Derived Tracks    │
    │  (member credits   │
    │   → company page)  │
    └────────────────────┘
```

Three relationship paths, one clean system. Credits stay untouched.
