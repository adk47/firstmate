> ⚠️ **HISTORICAL — a March-2026 planning artefact. Do not act on this document.**
> Its blockers, timeline and "what I need from Aaron" list describe March 2026, not today:
> HOLE 1 (admin API credentials) has been closed since ~2026-04 and must not be re-requested,
> and Athena is retired — Trino via `/opt/hydra/scripts/trino-query.sh` is the default query
> path. The operator/authority tiers shown below are illustrative examples only;
> `MEMORY.md` + `shared-reference/reference/slack-people.json` win over them, as does
> `/opt/hydra/shared-reference/AGENT_CURRENT_TRUTH.md` for current state.
> Retained for history only. Verified stale 2026-08-26.

# Retool Replacement — Master Plan & Gap Analysis

_Created: 2026-03-07 by Clio_

## Skills Created (10 total)

| Skill | Replaces | Status |
|-------|----------|--------|
| `muso-ops-admin` | Core API gateway + auth | ✅ Created — needs API credentials |
| `muso-ops-claiming` | Retool "Customer/Claimings" | ✅ Created — needs admin API access |
| `muso-ops-credits` | Retool credit request management | ✅ Created — needs admin API access |
| `muso-ops-profiles` | Retool "Growth > Support > Merging" | ✅ Created — needs admin API access |
| `muso-ops-tracks` | Retool "Ops Hub > Analytics Track Issues" | ✅ Created — needs admin API access |
| `muso-ops-identity` | Retool identity resolution | ✅ Created — needs admin API access |
| `muso-ops-users` | Retool "Users > List" | ✅ Created — needs admin API access |
| `muso-ops-workspaces` | Retool workspace creation/B2B onboarding | ✅ Created — needs admin API access |
| `muso-ops-fraud` | NEW (Retool had nothing like this) | ✅ Created — ready now |
| `muso-ops-audit` | NEW (Retool had no audit trail) | ✅ Created — ready now |

### Already Existed (no changes needed)
| Skill | Covers |
|-------|--------|
| `muso-refund-processor` | Refund investigation + execution |
| `muso-stripe` | All Stripe operations |
| `muso-stripe-disputes` | Dispute handling |
| `muso-ads-manager` | Ad creation + management |
| `muso-verify-profile` | Profile authenticity verification |
| `muso-amplitude` | User activity lookup |
| `muso-intercom` | Support ticket lookup |
| `muso-clickup` | Task management |

---

## 🔴 HOLES — What's Needed to Make This Work

### HOLE 1: Admin API Credentials — **CLOSED**
Admin API credentials are in place and the ops write skills are live. Audited admin
writes have run continuously since ~2026-04; see `api-logs/admin/YYYY-MM-DD.jsonl`.
**Do not re-request credentials.**

Historical record of why this was ever a blocker:

~~**What:** I need `MUSO_API_URL`, `MUSO_ADMIN_EMAIL`, `MUSO_ADMIN_PASSWORD` set in `~/.zshrc`~~
~~**Why:** Every ops skill calls core-backend's `/w/admin/*` endpoints via JWT auth~~
~~**Status:** ⏳ Waiting for Aaron to DM credentials~~
~~**Impact:** ALL write ops skills are blocked without this~~

**Corrected 2026-08-26:** the credentials landed ~2026-04; the "BLOCKER" heading and the
"waiting for Aaron" status are both obsolete.

### HOLE 2: Admin API Route Verification (HIGH)
**What:** I mapped 156 endpoints from memory + Retool docs, but haven't verified all routes exist in the current codebase
**Why:** Routes may have changed, some may be deprecated, new ones may exist
**Fix:** Once I have credentials, I'll hit each route and build a verified route map
**Risk:** Some operations may fail if routes changed. I'll fail gracefully and report.

### HOLE 3: Exact Admin API Request/Response Schemas (MEDIUM)
**What:** I know the routes but not every request body field and response shape for all 156 endpoints
**Why:** Retool apps had the schemas hardcoded. I need to discover them.
**Fix:** Two options:
  - **(A)** Aaron gives me Retool API access → I pull the saved queries/endpoints from Retool
  - **(B)** I read the core-backend source via `gh api` to map exact schemas from code
  - **(C)** I call endpoints and learn the schemas empirically (slower but works)
**Recommendation:** Option B is fastest and most reliable. Let me read the admin route files.

### HOLE 4: Ops User Registry (MEDIUM)
**What:** I need to know which ops team members get which permission tier
**Why:** Access control is tier-based. Currently only Aaron is defined (Tier 1).
**Fix:** Aaron provides a list: {Slack ID → Name → Tier}
**Example:**
```
U7RP6HKUZ  → Aaron Kaufman → Tier 1 (full admin)
UXXXXXXXX  → Jan Delmo     → Tier 3 (standard ops)
UXXXXXXXX  → Kevin         → Tier 3 (standard ops)
```

### HOLE 5: Workspace API Endpoints (MEDIUM)
**What:** Workspace creation, member management, and roster management endpoints need verification
**Why:** The Retool docs describe the workflow but the exact admin API endpoints for workspace CRUD aren't fully documented in my references
**Fix:** Read core-backend source: `gh api repos/Muso-AI/core-backend/contents/src/routes/admin`

### HOLE 6: Image Upload from Slack (LOW)
**What:** When ops uploads an ID photo or avatar to Slack, I need to download it and forward to admin API
**Why:** Slack → download → multipart POST to core-backend
**Fix:** Already have the pattern from Slack file upload skill. Need to test the round-trip.
**Status:** Mostly solved — the `muso-admin-api.sh upload` command handles multipart. Just need to wire Slack download.

### HOLE 7: SSO/OAuth Client Management (LOW)
**What:** Retool has an "OAuth Clients" app for partner SSO setup
**Why:** This involves Auth0 API calls + core-backend + S3 image upload — multi-system workflow
**Fix:** This is a relatively rare operation. Build a dedicated skill only if ops needs it frequently.
**Recommendation:** Defer. Handle manually with Aaron for now.

### HOLE 8: Encore Shareable Management (LOW)
**What:** Pre-sale and influencer plaque management
**Why:** Niche workflow involving workspace creation + plaque system
**Fix:** Build when needed. Low frequency operation.

---

## 🟢 What's BETTER Than Retool (already)

### 1. Cross-System Intelligence
Retool shows you one database table at a time. I pull Athena + Stripe + Amplitude + Intercom + web search in one response.

### 2. Fraud Detection
Retool has zero fraud detection. I proactively flag suspicious patterns during every claim review.

### 3. Web Verification
Retool can't search the web. I cross-reference every claim against AllMusic, Discogs, Wikipedia, LinkedIn, and social media.

### 4. ID Document Verification
Retool can't analyze images. I can read uploaded ID documents and cross-reference names.

### 5. Audit Trail
Retool logs nothing useful. Every operation I execute is logged with: who, what, when, why, and context.

### 6. Permission Tiers
Retool: anyone with login clicks any button. Me: per-operator, per-operation access control.

### 7. Natural Language
Retool: navigate → search → click → fill form → submit. Me: "approve claim 12345, verified via Spotify."

### 8. Proactive Intelligence
"3 claims pending >48h" / "This user was rejected 4 times" / "Credit request from recently merged profile"

### 9. Alternative Suggestions
When rejecting a claim, I suggest what the user should do instead. Retool just shows a rejection form.

### 10. Reason Capture
Every ops action requires a reason. This creates institutional knowledge about decision-making patterns.

---

## Ops Interaction Logging Architecture

Aaron specifically asked for: "explicit logs for each ops user talking to you about stuff like this"

### Per-Operator Session Tracking

Every ops interaction in #clio_analyst or #operations is logged:

```
api-logs/admin/YYYY-MM-DD.jsonl     ← write operations (audit trail)
memory/ops-sessions/YYYY-MM-DD.jsonl ← all ops conversations (read + write)
memory/ops-metrics.json              ← aggregated metrics
```

### Ops Session Log Format
```json
{
  "timestamp": "2026-03-07T17:30:00Z",
  "operator": {"slack_id": "UXXXX", "name": "Jan Delmo"},
  "channel": "C0ADREBPNQ2",
  "thread_ts": "172793...",
  "action_type": "claim_review",
  "query": "approve claim 12345",
  "investigation_summary": "Ran profile verification, authenticity score 82/100",
  "decision": "approved",
  "reason": "Verified via Spotify + IPI match",
  "alternatives_offered": ["none needed — clear approve"],
  "fraud_flags": [],
  "escalated": false,
  "duration_seconds": 45
}
```

### Why-Capture Protocol

For every write operation, the flow is:
1. Operator requests action
2. Clio investigates + presents findings
3. Clio asks "What's the reason?"
4. Operator states reason
5. Clio suggests alternatives if applicable
6. Operator confirms
7. Clio executes + logs everything

This captures the *decision-making context* — not just what was done, but WHY.

### Fraud Surfacing

When fraud signals are detected during routine ops:
1. Flag is logged in audit trail
2. Summary posted to thread
3. If 2+ signals: escalated to Aaron
4. Aaron can override with reason (logged)

---

## Retool API Access Plan

Aaron mentioned Retool API access. Here's what I'd use it for:

### From Retool API:
- Pull saved queries → verify my endpoint mapping is complete
- Pull app configurations → understand exact data flows
- Export any custom logic embedded in Retool apps
- This is a one-time migration exercise, not ongoing dependency

### After Migration:
- Retool becomes backup-only (or decommissioned)
- Saves ~$200/month

---

## Implementation Timeline

### Phase 0 — NOW (today)
- ✅ Skills created (10 new, 8 existing)
- ✅ API wrapper script built
- ✅ Audit logging framework defined
- ⏳ Waiting for admin API credentials from Aaron

### Phase 1 — Credentials + Validation (Day 1-2 after credentials)
- Verify all admin API endpoints against live system
- Map exact request/response schemas
- Build verified route map
- Test auth flow end-to-end
- Define ops user registry (Aaron provides tier assignments)

### Phase 2 — Core Ops (Day 3-5)
- Claiming workflow live (approve/reject/revert with full investigation)
- User lookup live (cross-system comprehensive view)
- Credit request processing live
- Audit logging active

### Phase 3 — Advanced Ops (Day 6-10)
- Profile merge/unmerge live
- Track management (analytics links, credits)
- Identity resolution
- Workspace creation flow
- Image upload pipeline (Slack → admin API)

### Phase 4 — Fraud + Intelligence (Day 11-15)
- Proactive fraud scanning (daily)
- Web verification integrated into all claim reviews
- ID document verification workflow
- Fraud pattern detection queries
- Aaron override system

### Phase 5 — Parallel Run (Week 3-4)
- Run alongside Retool for 1-2 weeks
- Compare speed and accuracy
- Ops team provides feedback
- Iterate on workflows based on real usage

### Phase 6 — Retool Sunset
- Full migration complete
- Retool access retained as emergency backup
- Cancel Retool subscription ($200/mo saved)

---

## What I Need From Aaron (Summary)

1. **Admin API credentials** → DM me: MUSO_API_URL, MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD
2. **Ops user tier list** → Who gets what access level
3. **Retool API key** (optional) → For one-time migration validation
4. **Pick 5 test workflows** → For parallel run validation
5. **Confirm channel scope** → Which Slack channels accept ops commands

---

_This document lives at `~/.openclaw/workspace/reference/retool-replacement-plan.md` and will be updated as we progress._
