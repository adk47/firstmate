---
name: muso-verify-profile
description: |
  Verify the legitimacy of a Muso.AI profile. Determines where credits come from
  (industry data vs self-claimed), cross-references external sources, and produces
  an authenticity/validation score.

  Use when: verifying a profile, checking if credits are legit, investigating
  suspicious profiles, or auditing credit sources.

  Triggers: "verify", "verify profile", "is this legit", "where do credits come from",
  "credit source", "profile investigation", "authenticity"
compatibility: |
  Requires: AWS CLI (Athena), web_fetch for external lookups. Slack formatter for output.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
depends-on:
  - muso-slack-formatter
  - muso-query-writer
---

# Profile Verification Skill

Investigate a Muso.AI profile and determine the legitimacy/authenticity of their credits.

## Usage

```
verify <profile_url_or_id>
```

Example:
```
verify https://credits.muso.ai/profile/af2153d9-2836-402c-a94e-c4fd6e4348d0
verify af2153d9-2836-402c-a94e-c4fd6e4348d0
```

## Investigation Steps

Run ALL of these checks, then combine into a single verdict.

### Step 1: Profile Basics (Athena)

```sql
SELECT _id, name, profile_type, profile_sub_type, roles, common_credits,
       credits_count, credits_count_1y, collaborations_count,
       popularity, rank, country, ipis, about, years_active,
       genres, primary_genre, decades, known_as_names, legal_name
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE _id = '<PROFILE_ID>'
  AND is_deleted = false
```

Key signals:
- `ipis` — IPI numbers from performing rights orgs (ASCAP/BMI/SESAC/PRS). Having IPIs is a STRONG legitimacy signal — these are assigned by real PROs.
- `credits_count` vs `credits_count_1y` — long history = organic. All credits in last year = suspicious.
- `collaborations_count` — high collab count with known artists = legit.
- `popularity` / `rank` — system-calculated from streaming data, not user-editable.
- `known_as_names` / `legal_name` — aliases suggest industry presence.

### Step 2: Claiming Check (Athena)

```sql
SELECT id, status, reason, profiletype, verificationlinks,
       createdat, updatedat, teamid, userid, extraprofileids
FROM postgresql_core.public.claiming
WHERE profileid = '<PROFILE_ID>'
```

Interpretation:
- **No rows** → Profile was NEVER claimed through Muso's claiming system. Credits come entirely from industry data feeds (label metadata, publishing databases, distributor feeds). This is the STRONGEST signal of legitimacy.
- **status = 'processed'** → Claimed and approved by Muso ops team. Moderate legitimacy.
- **status = 'pending'** → Claim in progress, not yet verified.
- **status = 'rejected'** → Claim was rejected. Red flag for this specific claim, but underlying credits may still be valid from industry feeds.
- **status = 'reverted'** → Previously approved claim was reversed. Significant red flag.

If claimed, also check the team/user:
```sql
SELECT t.name, t.email, t.createdat, t.stripecustomerid
FROM postgresql_core.public.teams t
WHERE t.id = '<TEAM_ID>'
```

### Step 3: Credit Source Analysis (Athena)

Get the profile's top tracks and analyze credit patterns:

```sql
-- Use TRANSFORM + filter to avoid full scan
SELECT t._id as track_id, t.title, t.popularity, t.default_release_label,
       t.release_timestamp
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
WHERE contains(TRANSFORM(t.profiles, x -> x.profile_id), '<PROFILE_ID>')
  AND t.is_deleted = false
ORDER BY t.popularity DESC
LIMIT 30
```

Credit source signals:
- **Major label releases** (default_release_label contains Universal, Sony, Warner, Atlantic, Interscope, Def Jam, etc.) → Credits came from label metadata. Very high legitimacy.
- **Known distributor labels** (DistroKid, TuneCore, CDBaby, AWAL) → Self-distributed but still verified by distributor.
- **No label / blank** → May be user-added. Lower confidence.
- **Release timestamps spanning years** → Organic career. High legitimacy.
- **All releases in last 6 months** → Could be spam/padding. Investigate further.

### Step 4: IPI Cross-Reference (Athena)

If profile has IPI numbers, check for duplicates/conflicts:

```sql
-- Check if multiple profiles share the same IPIs (potential merge candidates or fraud)
SELECT _id, name, profile_type, common_credits, credits_count, ipis
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE (contains(ipis, <IPI_1>) OR contains(ipis, <IPI_2>))
  AND is_deleted = false
```

- **Only this profile** → Clean, unique identity.
- **Multiple profiles, same person** → Merge candidates (common for aliases). Not fraud.
- **Multiple profiles, different people** → IPI collision (rare but happens with common names). Flag for review.

### Step 5: External Verification (Web Lookup)

Cross-reference the person's name + credits against public sources:

1. **Wikipedia** — Search for the person or their notable tracks. Wikipedia songwriter credits are independently sourced.
2. **AllMusic** — Professional music database with credits.
3. **Discogs** — Community-maintained discography database.
4. **ASCAP/BMI/SESAC** — Performing rights organizations (IPI lookup).
5. **Spotify** — Check if they appear as credited artist/writer on the tracks.

Web lookup queries:
```
"<PERSON_NAME>" songwriter producer credits music
"<PERSON_NAME>" <NOTABLE_TRACK_TITLE> credits
```

For tracks: check Wikipedia pages for the top tracks and see if this person is listed in songwriter/producer credits.

### Step 6: Collaborator Quality Check

If tracks include known major artists (pulled from Step 3 artist names), that's independent validation — major labels don't let random people onto credits for JAY-Z tracks.

## Scoring System

### Authenticity Score (0-100)

Calculate based on weighted signals:

| Signal | Weight | Score |
|--------|--------|-------|
| Has IPI numbers (from PRO) | 20 | 0 or 20 |
| No claiming record (pure industry data) | 15 | 0-15 |
| Major label releases | 15 | 0-15 based on % |
| Wikipedia/external confirmation | 15 | 0-15 |
| Credits span multiple years | 10 | 0-10 |
| High collaborator count | 10 | 0-10 |
| Popularity/rank (system-calculated) | 10 | 0-10 |
| Consistent name across sources | 5 | 0-5 |

### Credit Source Breakdown

For the report, categorize credits by source:

- *Industry-captured:* Credits that came from label metadata, publishing databases, distributor feeds, or MLC data. These were NEVER touched by a user. Identified by: no claiming record + appears in industry feeds (major labels, known distributors).
- *Claimed (verified):* Profile was claimed through Muso's verification process and approved by ops. Credits may include user-added ones post-claim.
- *User-added:* Credits added by a user after claiming. Check the credit edit history if available.
- *Unknown:* Can't determine source with available data.

### Verdict Categories

- 🟢 *VERIFIED (80-100):* Multiple independent sources confirm this person and their credits. High confidence.
- 🟡 *LIKELY LEGIT (60-79):* Strong signals but some gaps in external verification. Moderate-high confidence.
- 🟠 *INCONCLUSIVE (40-59):* Mixed signals. Some credits check out, others can't be verified. Needs manual review.
- 🔴 *SUSPICIOUS (0-39):* Red flags present. Credits may be inflated, self-added, or misattributed.

## Output Format (Slack)

Use Slack mrkdwn. NO markdown tables. Structure:

```
🔍 *Profile Verification: <NAME>*
<profile_url>

*Verdict:* 🟢 VERIFIED (score/100)

*Profile Summary*
• Type: <type> | Credits: <count> | Collaborations: <count>
• IPIs: <list> (registered with <PRO>)
• Known as: <aliases>
• Active: <years/decades>

*Credit Sources*
• Industry-captured: <count> (<percentage>%)
• Claimed/verified: <count> (<percentage>%)
• User-added: <count> (<percentage>%)

*Key Evidence*
• ✅ <evidence point 1>
• ✅ <evidence point 2>
• ⚠️ <any concerns>

*Top Verified Credits*
• "<track>" — <artist> (<label>, <year>) — confirmed via <source>
• "<track>" — <artist> (<label>, <year>) — confirmed via <source>

*External Cross-References*
• Wikipedia: <found/not found> — <details>
• AllMusic: <found/not found>
• ASCAP/BMI: IPI <number> — <details>
```

## Edge Cases

- **Common names** (e.g., "John Smith"): Extra caution. Cross-reference IPI + specific track credits, not just name.
- **Aliases**: Musicians often work under multiple names. Check `known_as_names` and web results for stage names.
- **Merged profiles**: If IPI check returns multiple profiles for same person, note it as merge candidates, not fraud.
- **Ghost producers**: Some legitimate producers work uncredited on streaming platforms but appear in publishing data. IPIs validate them.

## Cost Notes

- Profile lookup: negligible (29M rows, ~2GB table)
- Claiming check: negligible (small table)
- Track lookup with TRANSFORM filter: can hit scan limit on 190M row table. Use LIMIT and ORDER BY popularity.
- IPI cross-reference: negligible (small scan on indexed column)
- Stats queries: AVOID unless specifically needed — 3.3B rows, expensive.
