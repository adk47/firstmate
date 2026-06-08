# muso-credit-investigator

## Purpose
Deep-dive credit authenticity investigation for Ops team. Given a user ID, profile ID, or credit request ID, produce a structured investigation report and a clear **GRANT / DENY / ESCALATE** recommendation.

Designed to catch the pattern Aaron flagged: users claiming non-creative or peripheral credits (Editorial, Album Cover, Publisher, A&R) on many small tracks, accumulating large stream counts fraudulently — like the Javon editorial credits scam.

## Trigger
Use when:
- Ops team asks "should we approve this credit request?"
- A profile is flagged by the Daily Fraud Scan and needs deeper investigation
- Someone asks "is this profile legit?" or "investigate user [X]"
- Pattern: same user submitting credits across many tracks within a short window

Triggers: "investigate credit", "should we approve", "is this legit", "credit request investigation", "fraud check", "authenticity check", "credit authenticity"

## Authorization
- **All ops team members** can trigger investigations (read-only analysis)
- **No write operations** — this skill only reads and reports
- Results posted to the invoking channel or thread

## Investigation Checklist

### Step 1: Resolve the entity
If given a credit request ID → look up in `public_credit_requests` to get userid, profileid, credits, trackid, spotifypopularity
If given a userid → pull all recent credit requests for that user
If given a profileid → pull credit_requests WHERE profileid = X

### Step 2: Profile baseline
Query `platform-industry-db-industry-prod`.catalog_profile WHERE _id = profileid:
- Profile name, type (individual/organization)
- common_credits — what roles is this person known for?
- credits_count, credits_count_1y
- years_active
- top_collaborators — are they real known artists?
- is_high_risk flag

Query `platform-industry-calc-prod`.profile_track_full WHERE profile_id = profileid:
- Total streams (SUM of streams)
- Number of tracks (COUNT)
- Breakdown by credit type (what roles dominate)

### Step 3: Credit request history
Query `public_credit_requests` WHERE userid = X:
- Total approved credits (all time, last 30 days, last 7 days, last 24h)
- Role distribution — are they claiming one role type repeatedly?
- Track popularity distribution — are they targeting high-pop tracks?
- Velocity — how many submissions per day recently?
- Multiple profileids? Red flag if same user has a "Publisher profile" AND a "creative profile"

### Step 4: Social/web verification (for high-risk cases)
Use `web_search` to verify:
- Does the person exist? Search "[profile name] [role] music"
- Does the track credit match public sources? Search "[track name] [artist] credits"
- Does their Muso profile appear on their socials? (Aaron's concern — using Muso to fake credentials)

### Step 5: Stream inflation calculation
Calculate:
- **Pre-credits streams**: approximate what their stream count was BEFORE the flagged credits (harder — use proxy: total streams minus streams from tracks in the flagged batch)
- **Post-credits stream gain**: SUM of streams on tracks where the flagged role was claimed
- **Non-musical stream %**: what % of total profile streams come from non-creative roles

### Step 6: Risk scoring

| Signal | Risk Points |
|--------|------------|
| Non-creative role (Editorial, Album Cover, A&R, Marketing, Publisher, Management) on pop >= 70 | +3 |
| Creative role (Producer/Writer/Composer/Lyricist/Manager) on pop >= 70 where profile name ≠ track's primary artist | +3 |
| `status='approved'` but `verificationData.is_approved=false` (verifier was overridden by ops/admin) | +3 |
| "Graduation": profile got ≥2 seed credits with an artist, after which many of that artist's tracks auto-approved (`approve_common_collaborator`) | +3 |
| Sprayed across many unrelated primary artists (≥8 distinct) at high volume | +2 |
| Same role claimed on 5+ tracks in 7 days | +2 |
| Flagged on prior fraud scans | +3 |
| New account (< 30 days) | +2 |
| Multiple profiles, one dedicated to one role type | +3 |
| Claimed role inconsistent with all other credits | +2 |
| Profile not findable via web search | +2 |
| Top collaborators are all very high-profile artists (no mid-tier) | +1 |
| Legit: role matches verified public credit sources | -3 |
| Legit: years active > 2, diverse roles, real collaborators | -2 |
| Legit: credit count consistent with career pace | -1 |

**Total score:**
- ≤ 0: ✅ GRANT — looks legitimate
- 1–4: 🟠 WATCH — grant with caution, flag for monitoring
- 5–8: 🔴 DENY — recommend rejection
- 9+: 🚨 ESCALATE — potential bad actor, flag for account review

## Output Format

```
🔍 *Credit Investigation Report*
*Profile:* [Name] — <https://credits.muso.ai/profile/{profileid}|View Profile>
*User:* [email] (ID: [userid])
*Request:* [role] on "[track]" (pop [N])

*Profile Overview*
• Total streams: [X]B across [N] tracks
• Primary role (catalog): [role]
• Years active: [N]
• Credits (all time / last 30d / last 7d): [N] / [N] / [N]

*Submission Pattern*
• [N] credits submitted in last 24h | [N] in last 7d
• Role distribution: [role: count, role: count]
• Pop distribution of claimed tracks: [breakdown]
• Stream gain from flagged credits: ~[X]M

*Fraud Signals*
• [signal 1]
• [signal 2]
...

*Legitimacy Signals*
• [signal 1]
...

*Web Verification*
• [search result or "no public presence found"]

*Stream Inflation*
• Streams before flagged credits: ~[X]
• Streams attributed to flagged role: ~[X]
• [role] as % of total profile streams: [X]%

*Risk Score: [N]* → *[GRANT ✅ / WATCH 🟠 / DENY 🔴 / ESCALATE 🚨]*
*Recommendation: [one sentence].*
```

## Data Sources

### Athena Queries (workgroup: clio-agent, region: us-west-2)

**Credit request history (with docs + metadata):**
```sql
SELECT id, profileid, credits, spotifytracktitle, spotifypopularity,
  spotifytrackid, spotifytrackartists, status, createdat,
  verificationdata, metadata
FROM postgresql_core.public.credit_requests
WHERE userid = {userid}
ORDER BY createdat DESC
LIMIT 200
```
- `verificationdata` contains automated risk scoring (rule_risk_percent fields)
- `metadata` contains ISRC, label name, source (spclient/industry), playcount, releaseDate
- `spotifytrackartists` is JSON array of {id, name} — the actual artist(s) on the track
- No `source`, `sourcelink`, or `spotifyalbumtitle` columns exist

**Profile catalog:** (note: uses `_id` not `id`)
```sql
SELECT _id, name, profile_type, common_credits, credits_count, credits_count_1y,
  years_active, top_collaborators, is_high_risk, primary_genre
FROM "platform-industry-db-industry-prod".catalog_profile
WHERE _id = '{profileid}'
```
- `credits_count` and similar are nested `{$numberlong, $numberint}` — extract `$numberlong`
- `top_collaborators` is JSON array — empty = red flag for established roles

**Profile stream total:**
```sql
SELECT SUM(streams) as total_streams, COUNT(*) as num_tracks
FROM "platform-industry-calc-prod".profile_track_full
WHERE profile_id = '{profileid}'
```

**Credit role breakdown:**
```sql
SELECT credits, COUNT(*) as cnt, SUM(streams) as streams_attributed
FROM "platform-industry-calc-prod".profile_track_full
WHERE profile_id = '{profileid}'
GROUP BY credits
ORDER BY streams_attributed DESC
```

**User lookup:**
```sql
SELECT id, email, firstname, lastname, createdat
FROM postgresql_core.public.users
WHERE id = {userid}
```

**User's multiple profiles:**
```sql
SELECT DISTINCT profileid, COUNT(*) as credit_count
FROM postgresql_core.public.credit_requests
WHERE userid = {userid} AND status = 'approved'
GROUP BY profileid
```

## Notes
- Profile URL format: `https://credits.muso.ai/profile/{UUID}` — always use `profileid` (UUID), never numeric `userid`
- Non-creative roles to treat as inflation risk: Album Cover, Editorial, Photography, Art, Design, A&R, Marketing, Management, Publisher (when not legit label entity)
- "Javon pattern": claiming Editorial/non-musical roles on many small tracks to accumulate streams; red flag is velocity + role consistency + no external verification
- "KSJ Beats / fleet-fraud pattern" (the mirror of Javon): **creative** roles (Producer/Writer/Composer) injected onto **superstar** catalogs for **chart** rank, via a free account, exploiting the IDP "graduation" auto-approve rules. When investigating a profile, check the timeline for a small seed followed by a cascade, and check for `approved`-but-`is_approved=false` rows. For the user-level proactive scan, see `muso-query-writer/saved-queries/misc/credit_fleet_fraud_user_scan.sql` and the "Credit Fleet Fraud" section of `muso-ops-fraud`.
- For escalation cases, reference the `muso-ops-fraud` skill for account-level actions
