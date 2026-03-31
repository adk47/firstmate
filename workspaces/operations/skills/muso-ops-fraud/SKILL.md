---
name: muso-ops-fraud
description: |
  Cross-cutting fraud detection and investigation for Muso.AI operations.
  Surfaces suspicious patterns across claiming, credit requests, identity resolution,
  and user behavior. Incorporates web search, ID verification, and pattern analysis.
  
  Use when: investigating suspicious activity, verifying user identity documents,
  checking for fraud patterns, bulk fraud analysis, proactive fraud alerts.

  Triggers: "fraud", "suspicious", "verify identity", "ID check", "impersonation",
  "fake profile", "suspicious claim", "fraud investigation", "bad actor"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-verify-profile
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-verify-profile (authenticity scoring), web_search (external verification),
  image tool (ID document analysis), Athena (pattern queries).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Muso Ops — Fraud Detection

Proactive and reactive fraud investigation across all ops functions.

## Fraud Signal Categories

### 1. Claiming Fraud
- Same user claiming multiple unrelated profiles
- Profile claimed → reverted → re-claimed (cycling)
- Verification links that don't match profile identity
- Recently created profiles with suspiciously high credit counts
- Claiming high-profile artists with weak verification
- Multiple failed claims from same email domain

### 2. Credit Fraud
- Bulk credit self-additions (>20 credits/day)
- Adding credits to high-popularity tracks by unknown profiles
- Credits across genres with no logical career path
- Credit additions immediately after profile claim
- Same credit submitted under multiple profile aliases

### 3. Identity Fraud
- User account linked to profile that doesn't match their verified identity
- Multiple user accounts claiming the same profile
- Identity links to profiles with commercial value (high streams)
- Suspicious email patterns (disposable domains, sequential addresses)

### 4. Subscription Fraud
- Multiple refund requests across linked accounts
- Account creation → immediate pro upgrade → claim → cancel pattern
- Shared payment methods across multiple accounts
- Rapid subscription cycling (subscribe → cancel → subscribe)

## Investigation Workflows

### ID Document Verification

When ops uploads a government ID (photo/scan) to Slack:

1. **Use `image` tool** to analyze the document
2. **Extract:** Full name, document type, issuing country
3. **Cross-reference** against:
   - Profile name + known aliases (Athena)
   - Claiming applicant name
   - Workspace owner name
   - Web search: "[name on ID]" + "[city/country]" + music
4. **Flag mismatches:**
   - Name doesn't match profile ← RED FLAG
   - ID appears edited/modified ← RED FLAG
   - Country doesn't match profile country ← YELLOW FLAG
5. **Report verdict:**
   ```
   🪪 *ID Verification: [Name on ID]*
   
   • Document: [Type] — [Country]
   • Name on ID: [Name]
   • Name on profile: [Name]
   • Match: ✅ Exact / ⚠️ Partial (alias) / ❌ No match
   
   Cross-references:
   • Web: [found/not found matching music professional]
   • IPI: [match/no match]
   • Profile credits: [consistent/inconsistent with claimed identity]
   ```

⚠️ **NEVER store ID images or extracted PII.** Process in-session only.
After verification, the image should not be referenced again.

### Web-Enhanced Claim Verification

For every claim, run these web checks:

```python
# Search patterns for web verification
searches = [
    f'"{claimant_name}" music producer songwriter credits',
    f'"{claimant_name}" "{profile_name}" music',
    f'"{claimant_name}" allmusic OR discogs OR genius',
    f'site:linkedin.com "{claimant_name}" music',
]
```

Check results for:
- Do they appear as a real music professional?
- Are they associated with the tracks/albums on this profile?
- Do industry databases (AllMusic, Discogs, Genius) list them?
- Does their LinkedIn show music industry experience?

### Daily Credit Request Fraud Scan (Heartbeat Task)

**Purpose:** Identify potentially fraudulent credit self-additions on high-popularity tracks.

**Query:** Approved `credit_requests` from last 24h where the associated track has Spotify popularity ≥ 50.

**MANDATORY per-person web verification (never flag on popularity alone):**

For every person in the scan results:

1. **Web research** using tiered sources (always check Tier 1; check Tier 2/3 as indicated):

   **Tier 1 — Always check:**
   - Spotify "Show Credits": check track credits tab for claimed name+role
   - MusicBrainz: `musicbrainz.org/search?query=[name]&type=artist` — recording-level credits; look for specific track+role match
   - Discogs: `discogs.com/search/?q=[name]&type=artist` — discography and credits
   - AllMusic: `allmusic.com/search/all/[name]` — artist profile with credits

   **Tier 2 — Check for writing/publishing roles (songwriter, composer, lyricist, publisher):**
   - ASCAP: `ascap.com/repertory` — search by writer name
   - BMI: `repertoire.bmi.com/` — search by writer name
   - SESAC: `sesac.com` — affiliated writer search

   **Tier 3 — Check if Tier 1 is inconclusive (no Tier 1 source confirms the claimed name+role):**
   - TIDAL: search for track/artist credits (usually most detailed streaming credits)
   - Apple Music: check album credits page
   - Jaxsta: `jaxsta.com` — dedicated music credits database
   - LinkedIn: music industry career history
   - Professional website: check email domain
   - DuckDuckGo: `"[name]"+[role]+engineer|producer|mixing`

   **Investigation failure:** If more than 2 **Tier 1** sources fail (429, blocked,
   timeout), mark that person's investigation as INCOMPLETE and classify as
   UNVERIFIABLE — NEEDS REVIEW. Note which sources failed in the report.

2. **Cross-reference analysis:**
   - Do claimed roles match their verified career? (mastering engineer claiming mastering = expected)
   - Is the number of credits in one batch reasonable? (8 mastering credits on same album = normal; 8 scattered high-pop tracks = flag)
   - Does email type indicate legitimacy? (.edu = strong signal; professional domain = good; disposable = red flag)
   - Specialized roles (Immersive Mixing, Dolby Atmos) suggest real technical knowledge

3. **Verdict categories:**
   - ✅ *VERIFIED LEGIT* — Confirmed via web presence (any of: Spotify credits, MusicBrainz, Discogs, AllMusic, Jaxsta, ASCAP/BMI/SESAC, LinkedIn career, studio site)
   - 🔍 *UNVERIFIABLE — LOW CONCERN* — No web presence but consistent pattern (single technical role, professional email)
   - 🔍 *UNVERIFIABLE — NEEDS REVIEW* — No web presence AND risk signals (very high pop ≥90, creative roles, many credits, mononym)
   - 🔴 *SUSPICIOUS* — Active red flags (identity mismatch, web contradicts claims, bulk self-additions, disposable email)

4. **Output format:** Group by verdict. Per person: name, pop, credit count + roles, email, profile link, 1-2 sentence reasoning.

5. **End with:** Summary counts. Only flag items warranting ops attention.

**Key principle:** Most credit requests on high-pop tracks are from legitimate professionals (mastering engineers, mixing engineers). The scan exists to find the exceptions, not to cry wolf.

### Proactive Fraud Scan (Periodic)

Run as part of daily ops:

```sql
-- Claiming patterns: users with multiple claims
SELECT c.userid, u.email, COUNT(*) as claim_count,
       COUNT(CASE WHEN c.status = 'rejected' THEN 1 END) as rejected,
       COUNT(CASE WHEN c.status = 'reverted' THEN 1 END) as reverted
FROM "platform-core-backend-export-prod".public_claiming c
JOIN "platform-core-backend-export-prod".public_users u ON c.userid = u.id
GROUP BY c.userid, u.email
HAVING COUNT(*) > 3 OR COUNT(CASE WHEN c.status IN ('rejected','reverted') THEN 1 END) > 1
ORDER BY claim_count DESC
```

```sql
-- Recently created profiles with high credits (potential padding)
SELECT _id, name, profile_type, credits_count, common_credits,
       popularity, rank
FROM "platform-industry-bi-prod".matvw_catalog_profile
WHERE credits_count > 50
  AND common_credits < 5
  AND is_deleted = false
ORDER BY credits_count DESC
LIMIT 50
```

### Fraud Investigation Report

When investigating a specific user/profile:

```
🚨 *Fraud Investigation Report*

*Subject:* [Name] (user_id / profile_id)
*Trigger:* [What raised the flag]

*Claiming History:*
• [N] claims submitted, [N] approved, [N] rejected, [N] reverted
• Pattern: [normal / concerning / clearly fraudulent]

*Credit Analysis:*
• Total credits: [N]
• Industry-captured: [N] ([%])
• User-added: [N] ([%])
• Pattern: [normal / excessive self-addition / suspicious]

*Identity Verification:*
• ID provided: [yes/no]
• Name match: [exact / partial / no match]
• Web presence: [strong / weak / none]
• IPI registration: [yes/no]

*Behavioral Signals:*
• Account age: [X months]
• Subscription history: [details]
• Refund history: [details]
• Support ticket history: [details]

*Verdict:* [🟢 CLEAN / 🟡 SUSPICIOUS / 🔴 FRAUDULENT]
*Recommendation:* [approve / investigate further / block / escalate to Aaron]
*Evidence:* [summary of key evidence points]
```

## Escalation Rules

**Always escalate to Aaron when:**
- Confirmed fraud affecting high-profile artists (>100K streams)
- Multiple linked fraudulent accounts (organized fraud)
- Legal threats from investigated users
- Fraud involving VIP/enterprise subscribers
- When you're genuinely uncertain

## Aaron Override System

Aaron can override any fraud flag:
- "Override fraud flag for user X — reason: [reason]"
- Override is logged with reason in audit trail
- Only Aaron (U7RP6HKUZ) can authorize overrides
