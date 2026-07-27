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
  image tool (ID document analysis), Trino (pattern queries).
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
   - Profile name + known aliases (Trino)
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

1. **Web research** using multiple sources:
   - AllMusic: `allmusic.com/search/all/[name]` — check for artist profile with credits
   - Discogs: `discogs.com/search/?q=[name]&type=artist` — check for discography
   - DuckDuckGo HTML: `duckduckgo.com/html/?q="[name]"+[role]+engineer|producer|mixing` — broad search
   - Professional website: check if email domain has a website (e.g., `marshmastering@gmail.com` → try `marshmastering.com`)
   - LinkedIn: look for music industry career history

2. **Cross-reference analysis:**
   - Do claimed roles match their verified career? (mastering engineer claiming mastering = expected)
   - Is the number of credits in one batch reasonable? (8 mastering credits on same album = normal; 8 scattered high-pop tracks = flag)
   - Does email type indicate legitimacy? (.edu = strong signal; professional domain = good; disposable = red flag)
   - Specialized roles (Immersive Mixing, Dolby Atmos) suggest real technical knowledge

3. **Verdict categories:**
   - ✅ *VERIFIED LEGIT* — Confirmed via web presence (studio site, AllMusic/Discogs credits, LinkedIn career)
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
FROM postgresql_core.public.claiming c
JOIN postgresql_core.public.users u ON c.userid = u.id
GROUP BY c.userid, u.email
HAVING COUNT(*) > 3 OR COUNT(CASE WHEN c.status IN ('rejected','reverted') THEN 1 END) > 1
ORDER BY claim_count DESC
```

```sql
-- Recently created profiles with high credits (potential padding)
SELECT _id, name, profile_type, credits_count, common_credits,
       popularity, rank
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE credits_count > 50
  AND common_credits < 5
  AND is_deleted = false
ORDER BY credits_count DESC
LIMIT 50
```

### Credit Fleet Fraud (user-level, "graduation")

The 2026-06 KSJ Beats / "T L A" incident (profile `9703c867`, userid 162720) exposed a class of
abuse the per-credit scans miss: **one submitter sprays high-volume creative-credit claims across
unrelated superstar catalogs to manufacture chart rank.** Score the *submitter as a running
transaction*, not each credit alone.

**The "graduation" mechanism (how seeded trust cascades — verified in IDP code):**
The IDP verifier (`UserCreditValidator`) has auto-approve rules that **short-circuit the risk
score** — once they fire, popularity/role penalties never apply:
- `approve_common_collaborator` — **≥2 credits with an artist ⇒ every future track by that artist
  auto-approves.** Seed 2 Olivia Rodrigo credits → all her tracks auto-approve.
- `approve_credit_exists` — a credit that already exists (incl. a prior *user-added* one) auto-approves.
- `approve_owning_track` — profile is/seems an artist on the track.
So a fraudster (or a manual ops/Retool approval) only needs to land a *seed*; the rest cascades.
**When investigating, check the claim/credit timeline for a small seed followed by a cascade.**

**The strongest signatures (creative roles only — NOT mastering/mixing, which are legit-high-volume):**
- High `credit_requests` volume + many distinct **primary artists** (spraying unrelated catalogs)
- Many **approved Producer/Writer/Composer/Manager** credits on **pop ≥ 70** tracks
- `status='approved'` while `verificationData.is_approved=false` (admin/ops override of the verifier)
- **Free / $0-LTV / unclaimed** account (labels & real engineers pay; fraudsters don't)
- Duplicate-profile / alias sprawl (the incident had 3+ "hannah baker" userids + an `offical.BVC.music`)
- muso-only (not source-confirmed) credits — combine with `potential_fraud_accounts_muso_only_credits`

**Proactive scan:** run the saved query
`muso-query-writer/saved-queries/misc/credit_fleet_fraud_user_scan.sql` (user-level, free-account
filtered, creative-roles only). It is **high-recall / advisory** — every row needs analyst review
(source-confirm % + name-match) before any action. Do **not** auto-revoke. A free *indie/regional*
producer with a coherent catalog can clear the gate; that's why a human confirms.

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
