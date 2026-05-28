---
name: muso-ops-claiming
description: |
  Claiming operations for Muso.AI ops team. Review, approve, reject, and revert
  profile claims with integrated fraud detection, web verification, and ID checking.
  
  Replaces: Retool "Customer/Claimings" app
  
  Use when: reviewing claims, approving/rejecting claims, checking claim status,
  investigating suspicious claims, processing claim queues.

  Triggers: "claim", "claiming", "approve claim", "reject claim", "revert claim",
  "pending claims", "claim queue", "verify claim", "claiming fraud"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-ops-fraud
  - muso-verify-profile
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-ops-admin (API gateway), muso-verify-profile (authenticity scoring),
  web_search (external verification), Athena (claim history).
metadata:
  version: "1.1"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — Claiming

End-to-end claiming workflow: review → investigate → verify → decide → execute → log.

## Access Control

Check sender_id tier from `muso-ops-admin` SKILL.md before ANY operation.
- Tier 1-3: full claiming operations
- Tier 4: read-only (view claims, no approve/reject)

## Workflows

### List Pending Claims

```bash
# Via admin API
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/claiming?status=pending&limit=20&offset=0"

# Supplement with Athena for richer context
SELECT id, status, reason, profileid, profiletype, userid, teamid,
       verificationlinks, createdat, updatedat
FROM postgresql_core.public.claiming
WHERE status = 'pending'
ORDER BY createdat DESC
LIMIT 20
```

Present as:
```
📋 *Pending Claims* (X total)

1. *#12345* — John Producer (Producer profile)
   • Submitted: 2026-03-05 • Links: spotify.com/artist/..., instagram.com/...
   • Team: john@example.com

2. *#12346* — Sarah Songwriter (Songwriter profile)
   ...
```

### Review a Claim (Deep Investigation)

When ops says "review claim 12345" or "check claim 12345":

**Step 1: Pull claim details**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/claiming/<id>"
```
Note: Claims list = `GET /admin/claiming`, single claim = `GET /admin/claiming/:id`

**Step 2: Pull profile data (Athena)**
```sql
SELECT _id, name, profile_type, credits_count, common_credits,
       collaborations_count, popularity, rank, ipis, country,
       genres, primary_genre, years_active
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE _id = '<profile_id>' AND is_deleted = false
```

**Step 3: Check claim history (repeat claimers)**
```sql
SELECT id, status, reason, createdat, userid, teamid
FROM postgresql_core.public.claiming
WHERE profileid = '<profile_id>'
ORDER BY createdat DESC
```

**Step 4: Run profile verification** (delegate to `muso-verify-profile`)
- IPI cross-reference
- Credit source analysis (industry vs user-added)
- Collaborator quality check
- External web verification

**Step 5: Web verification of submitted links**
For each verification link the claimant submitted:
- `web_fetch` the link
- Check if the name matches the profile
- Check if music/credits match the claimed profile
- Flag mismatches

**Step 6: ID Document Verification** (if uploaded)
When ops uploads a photo ID to Slack for verification:
- Use `image` tool to read the document
- Extract: name, photo
- Cross-reference name against profile name + known aliases
- Flag if name doesn't match
- ⚠️ NEVER store the ID image or its contents — verify in-session only

**Step 7: Synthesize verdict**

Present a structured report:

```
🔍 *Claim Review: #12345*

*Claimant:* John Producer (john@example.com)
*Profile:* Producer — 247 credits, 89 collaborations
*Submitted:* 2026-03-05

*Verification Links:*
• ✅ spotify.com/artist/... — name matches, 15 tracks credited
• ✅ instagram.com/johnproducer — bio mentions production credits
• ⚠️ linkedin.com/in/john — generic name, can't confirm same person

*Authenticity Score:* 🟢 82/100
• Has IPI numbers (ASCAP) ✅
• Major label credits (Universal, Atlantic) ✅
• Credits span 2015-2026 ✅
• No prior claims on this profile ✅

*Claim History:*
• First claim on this profile ✅
• Claimant has 0 other claims ✅

*Recommendation:* APPROVE
*Reason:* Strong IPI match, major label credits verified via industry data,
Spotify page confirms identity.

Approve? (yes / reject with reason / investigate further)
```

### Approve Claim

After investigation + confirmation:

```bash
# Log BEFORE executing
# ... (audit log entry)

# Approve = verify
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/claiming/<id>/verify"
```

Post confirmation:
```
✅ Claim #12345 approved for John Producer.
Reason: [stated reason]
Logged to audit trail.
```

### Reject Claim

ALWAYS require a reason:

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/claiming/<id>/reject" '{"reason":"[reason]"}'
```

Standard rejection reasons:
- "Verification links don't match profile identity"
- "Suspected impersonation — name mismatch with external sources"
- "Previously rejected claim for same profile — no new evidence"
- "Insufficient verification — no matching credits in industry data"

### Revert Claim

When a previously approved claim needs to be undone:

⚠️ This is a significant action — always ask WHY and confirm.

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/claiming/<id>/revert"
```

### Batch Review

When ops says "show me today's claims" or "process the queue":

1. Pull all pending claims
2. For each, run automated checks (Steps 2-5 above)
3. Pre-sort into: likely approve / needs review / likely reject
4. Present summary with recommendations
5. Process one-by-one with confirmation

**NEVER batch-approve without individual confirmation.** Even if all look clean,
confirm each one. Speed < accuracy for claiming.

## Fraud Signals (Auto-Flag)

During any claim review, automatically flag if:

- 🚩 Profile has been claimed + reverted before
- 🚩 Same user has 3+ pending claims simultaneously
- 🚩 Verification links are dead or don't contain the claimed name
- 🚩 Profile has 0 industry-captured credits (all user-added)
- 🚩 Claimant email domain doesn't match any known workspace
- 🚩 Name on profile vs name on verification links mismatch
- 🚩 Profile was recently created (< 30 days) with high credit count

When 2+ flags trigger, escalate to Aaron regardless of tier.

## Alternatives to Suggest

When rejecting, suggest alternatives:
- "If you believe these credits are yours, update them on Spotify/your distributor first — we mirror industry data."
- "You can submit a new claim with stronger verification links."
- "If you're the manager/label, consider claiming via a workspace instead."

## Metrics

Track in `memory/ops-metrics.json`:
```json
{
  "claiming": {
    "2026-03-07": {
      "reviewed": 15,
      "approved": 10,
      "rejected": 3,
      "escalated": 2,
      "avg_review_time_min": 3.2
    }
  }
}
```
