---
name: muso-ops-admin
description: |
  Core admin API gateway for Muso.AI operations. Handles authentication,
  admin endpoint calls, and provides the shared API wrapper used by all
  muso-ops-* skills. This is the foundation layer — other ops skills depend on it.

  Use when: ops needs to call any admin API endpoint directly, or when
  troubleshooting admin API auth issues.

  Triggers: "admin api", "admin login", "admin token", "retool replacement",
  "ops api", "admin endpoint"
depends-on:
  - muso-slack-formatter
  - muso-ops-audit
compatibility: |
  Requires: MUSO_API_URL (https://api.muso.ai/api/v3), MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD env vars.
  Requires: muso-ops-audit for all write operations.
  Auth: retool@muso.ai service account → JWT Bearer token (cached 23h).
  Requester header: Slack ID auto-resolved to muso.ai email by wrapper script.
  Service header: "clio" (identifies changes came through this agent).
  WRITE APPROVAL: ALL write operations require Aaron's explicit approval until hardened.
metadata:
  version: "2.0"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops Admin — Core API Gateway

The shared admin API layer for all Muso operations skills. Handles JWT auth,
token caching, and provides the `muso-admin-api.sh` wrapper.

## Architecture Overview

```
Ops User (Slack)
    │
    ▼
Clio (this skill)
    │
    ├─── Trino (read-only data)       ← existing, no changes
    ├─── Stripe CLI (payments)         ← existing, no changes
    ├─── Admin API (core-backend)      ← NEW: replaces Retool
    │        └── JWT auth, /admin/* endpoints
    ├─── Web Search (verification)     ← NEW: fraud/claiming checks
    └─── Audit Log (api-logs/)         ← NEW: mandatory logging
```

## Access Control (MANDATORY — check FIRST)

### Permission Tiers

Every ops user has a tier. Check `sender_id` before ANY operation.

**Tier 1 — Full Admin (override authority):**
- `U7RP6HKUZ` (Aaron) — all operations, override authority, can approve escalated ops

**Tier 2 — Senior Ops (most operations):**
- Define additional users here as Aaron approves them

**Tier 3 — Ops (standard operations):**
- Define additional users here as Aaron approves them
- Can: approve/reject claims, process credit requests, user lookup
- Cannot: delete profiles, merge profiles, create VIP subscriptions, bulk operations

**Tier 4 — Read Only:**
- Anyone else with channel access
- Can: lookup users, view claims, view credit requests
- Cannot: any write operation

**Aaron-only operations (always escalate):**
- Delete user accounts
- Create VIP/free subscriptions
- Override fraud flags
- Bulk operations (>10 items)
- Profile deletions
- Any operation flagged as "escalate" below

### Channel Scope

Ops commands are processed in **every channel and every DM** the agent is
in. There is no per-channel narrowing — `#operations`, `#clio_analyst`,
`#customer-support`, project channels, and DMs all accept the full ops
surface. The Write Approval Gate below (and the credit-verification batch
allowlist in SOUL.md) remain the actual access controls; channel ID is
not a gate.

## ⚠️ WRITE APPROVAL GATE (MANDATORY until hardened)

**ALL write operations (POST, PUT, PATCH, DELETE) require Aaron's explicit approval.**

Before executing ANY write:
1. Show Aaron exactly what will be called: method, path, body
2. Explain what it will change and why
3. Wait for explicit "go", "do it", "approved" confirmation
4. Log to audit trail before execution
5. Execute and confirm result

Read operations (GET) are always allowed without approval.

This gate will be relaxed per-operation as we validate each endpoint in production.

## 🛑 BULK DESTRUCTIVE GATE (enforced in muso-admin-api.sh — incident 2026-05-26)

A deterministic gate in `muso-admin-api.sh` caps the blast radius of mass
deletions. After **10 destructive `DELETE` calls within 15 minutes**, every
further destructive `DELETE` is **refused** until an explicit human decision
**naming the rows being deleted** is supplied. This runs in bash below the agent
— you cannot talk your way past it.

That decision does not have to come from a *second* human: when the person who
asked is on the approver list and enumerated the targets, their own request is
the decision (see the two cases below).

**Scope:** the `DELETE` verb (e.g. `DELETE /admin/track/:id/analytics-sources`,
`DELETE /admin/track/:id/profile/:pid/credits`, `DELETE /admin/profile/:id/member`).
`DELETE /admin/profile/:id/cache` is exempt (regenerable). POSTs are NOT counted.

**This gate is NOT bypassed by requester identity** (and, on the operations
agent, not by god-mode either). Being Aaron, Jan, or Nick — or stamping
`--requester` with one of them — does not lift it. It exists because on
2026-05-26 the agent deleted 285 analytics-source links off a single vague
"sources aren't capturing, fix it", collapsing a profile's stream count. A
vague request is never authorization to delete in bulk.

What lifts it is an explicit human decision passed as `--confirmed-by` +
`--approval-msg-id`. That decision is often **already in the thread** — read on
before escalating.

**When you hit `MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED`:**

1. STOP. Do not loop, and do not split the work across calls to dodge the counter.
2. Decide which case you are in. This is the whole judgment:

   **(a) The request already IS the decision.** The person who asked is on the
   tier-2 approver list (`config/tier2-approvers.txt` — currently Aaron, Jan,
   Nick) **and** they enumerated the exact targets. Their message is the explicit
   human decision the gate is asking for. **Do not page anyone.** Re-issue with
   their handle and the timestamp of *their* message — e.g. `--confirmed-by jan
   --approval-msg-id <ts-of-their-request>`. Pass the **handle** (`jan`), not the
   raw Slack id: `resolve_slack_to_email` is applied only to `--requester`, so
   `U038BM16T7W` fails the allowlist match with
   `MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID`.

   Also pass `--approval-author-id <Uxxx>` and `--approval-channel <Cxxx>` for
   the message you are citing. They are optional and never block the call, but
   they are what makes a cited approval checkable afterwards — without them the
   audit row records only a handle you typed, which is indistinguishable from
   one you inferred.

   **(b) Anything else** — the requester is not on that list, or the request did
   not name what to delete. Post the running count and exactly what you propose
   to delete (which tracks/links, how many) to the thread, and get an explicit
   "yes, delete those N" before continuing.

That one decision covers the target set it enumerated, and **only** that set.
Finishing an approved batch is not a new decision; a *different* set of rows is,
even from the same person in the same thread.

**"Enumerated" has a hard meaning.** The request names the specific rows: a list
of ids or titles, a screenshot you have transcribed into the thread as text, or
"all N of X" where you have already read and posted those N. It is NOT enumerated
if you inferred the set from a symptom. That distinction is the entire lesson of
2026-05-26 — "sources aren't capturing, fix it" is a symptom, and reading it as
authorization to delete 285 links collapsed a profile's stream count. Volume was
never the problem. Vagueness was.

**This reasoning does not generalize to the other gates.** It applies here
because a wrongly-removed credit is recoverable (`POST` the credit back — see
`muso-ops-tracks` § Add/Remove Credits). The credit reject gate below is a
genuine one-way door with no inverse transition, so an enumerated request from an
allowlisted requester still does **not** make rejection autonomous. If you cannot
name the operation that undoes an action, treat it as irreversible.

If a delete *looks* like cleanup of "broken" rows, remember the incident: the
"broken-looking" `in_progress=true, name=null` stubs carried the real stream
data. Confirm what a row holds before deleting it.

## 🛑 CREDIT REJECT GATE (enforced in muso-admin-api.sh — incident 2026-07-22)

Rejecting a credit request is **never autonomous**. Any `PUT`/`PATCH` to
`/admin/credit-requests*` whose body sets `status:"rejected"` is refused
(`MUSO_CREDIT_REJECT_APPROVAL_REQUIRED`) unless `--confirmed-by
<jan|aaron|nick>` AND `--approval-msg-id <slack_ts>` point at an explicit
in-thread human decision. Requester identity does NOT bypass it, there is no
env off-switch, and it fires even in dry-run. Approved rejections are audited
to `/var/log/muso-ops/credit-reject-audit.jsonl`.

Why: rejection is a one-way door — core-backend's `updateStatus.js` transition
matrix has no `rejected → user_verification_needed` path (the only exit from
`rejected` is `approved`). On 2026-07-22 the agent rejected 28 UVN requests
during a ClickUp sweep and the "move them back to verification needed"
correction silently no-oped with a 200. When proof is insufficient, keep the
request in `user_verification_needed` and ask for more evidence, or escalate
the recommended reject to Jan (`<@U038BM16T7W>`) — same doctrine as the
customer-facing rule (Caroline never rejects). See `muso-ops-credits` for the
full transition matrix and the mandatory post-write readback.

## Environment Setup

Required env vars — **CONFIGURED AND WORKING:**
- `MUSO_API_URL` = `https://api.muso.ai/api/v3`
- `MUSO_ADMIN_EMAIL` = `retool@muso.ai` (service account)
- `MUSO_ADMIN_PASSWORD` = set (not shown)

**Location on hydra:** `/etc/openclaw/main.env` (loaded as a systemd
`EnvironmentFile` by `openclaw-gateway-main.service`). These are NOT in
`~/.zshrc` — the gateway runs as a daemon and does not source an
interactive shell. If you see "admin API credentials are not configured"
from the ops agent, check that both vars are present in that file and
restart the unit with `systemctl restart openclaw-gateway-main`.

## API Authentication

The admin API uses JWT Bearer tokens from `/admin/user/login`.

### Requester Attribution (MANDATORY — every API call)

Every admin API call MUST include `Requester` and `Service` headers so the backend
knows which human initiated the change. This mirrors Retool's pattern:

- `Requester: <user's muso email>` — the human who asked for the operation
- `Service: clio` — identifies that the change came through Clio

**The wrapper script auto-resolves Slack IDs to emails.** The map holds exactly
the people `shared-reference/reference/slack-people.json` lists as current staff
(enforced by `scripts/tests/muso-admin-api-slack-resolve.bats`). Do not
hand-write an address from memory — ask the script:

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  resolve-email U7RP6HKUZ    # -> aaron@muso.ai
```

An unknown or departed UID is echoed back unchanged with exit 1 — it is never
silently turned into someone else's address.

Pass Slack ID OR email via `--requester` flag:
```bash
# Using Slack ID (auto-resolved to email)
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester U7RP6HKUZ call GET "/admin/claiming?limit=20"

# Using email directly
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester aaron@muso.ai call POST "/admin/claiming/12345/verify" '{}'
```

**Never make a write call without `--requester`.** This is the backend's audit trail.

### Token Management

```bash
# Login and cache token (23h TTL)
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh login
```

Token is cached for 23 hours at `scripts/.admin-token-cache`.

### Making API Calls

```bash
# Generic admin API call (always include --requester for writes)
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester <slack_id|email> call <METHOD> <path> [json-body]

# Read (GET) — always allowed
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester U7RP6HKUZ call GET "/admin/claiming?status=pending&limit=20"

# Write (POST/PUT/DELETE) — requires Aaron approval first
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester U7RP6HKUZ call POST "/admin/claiming/12345/verify" '{}'

# File upload
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester U7RP6HKUZ upload "/admin/profile/abc123/image" /path/to/file.jpg

# Resolve Slack ID to email
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh resolve-email U7RP6HKUZ
```

## Admin API Route Map (139 verified routes)

_Source: `core-backend/src/apis/index.w.js` verified 2026-04-28_
_Base: `https://api.muso.ai/api/v3` — all routes use `/admin/*` prefix (NO `/w/` prefix)_
Full route map: `references/admin-api-routes.md`

### Query Parameter Notes (from source code)
- **Profile search**: uses `keyword=` (NOT `q=` or `search=`), also `limit=`, `page=`
- **User search**: uses `keyword=` for fullName/email iLike search, also `limit=`, `page=`, `emailConfirmed=`, `sortField=`, `sortType=`, `teamId=`, `seatId=`
- **Claiming list**: uses `status=`, `limit=`, `offset=`

### Users (`/admin/user/*`)
- `POST /admin/user/login` — admin login (no auth required)
- `GET /admin/user` — list/search users (keyword= for name/email search)
- `POST /admin/user` — create user
- `PUT /admin/user/:id` — update user
- `DELETE /admin/user/:id` — ⚠️ AARON ONLY
- `POST /admin/user/:id/impersonate` — get impersonate URL ⚠️ ESCALATE
- `PUT /admin/user/:id/image` — upload user image (multipart)
- `POST /admin/user/:id/reset-password` — reset password
- `POST /admin/user/:id/email-confirmed` — confirm email
- `POST /admin/user/:id/resend-email-confirmation` — resend confirmation
- `POST /admin/user/:userId/events` — track events
- `POST /admin/user/:userId/backfill-profile` — backfill profile

### Claiming (`/admin/claiming/*`)
- `GET /admin/claiming` — list claims (params: status, limit, offset)
- `GET /admin/claiming/:id` — get claim details
- `POST /admin/claiming/:id/reject` — reject claim
- `POST /admin/claiming/:id/verify` — verify/approve claim
- `POST /admin/claiming/:id/revert` — revert claim

### Credit Requests (`/admin/credit-requests/*`)
- `GET /admin/credit-requests` — list credit requests
- `PUT /admin/credit-requests` — bulk update status (body: `{requestIds[], status}` or `{profileId, status}`; `profileId` selects `unverified` rows only) 🛑 `status:"rejected"` is reject-gated (see Credit Reject Gate)
- `PUT /admin/credit-requests/:requestId` — updates `credits` field ONLY; ignores `status`. Use the collection endpoint above for any status change.
- `GET /admin/credit-requests/counts` — counts by status
- `GET /admin/credit-requests/profiles` — profiles with pending requests

### Profile Management (`/admin/profile/*`)
- `GET /admin/profile/search` — search artists + professionals
- `GET /admin/profile` — list profiles
- `POST /admin/profile` — create profile
- `GET /admin/profile/:profileId` — get profile details
- `PUT /admin/profile/:profileId` — update profile
- `PUT /admin/profile/:professionalId/image` — upload avatar (multipart)
- `GET /admin/profile/:profileId/credits` — list credits
- `POST /admin/profile/:profileId/credits` — add credits
- `PUT /admin/profile/:profileId/credits` — update credits
- `DELETE /admin/profile/:profileId/credits` — delete credits
- `POST /admin/profiles/merge` — merge profiles ⚠️ AARON APPROVAL — see `muso-ops-profiles/SKILL.md` "Merge Profiles" for the mandatory pre-state capture, post-merge verification, and STOP-rule (incident 2026-04-29). Run with `OPS_DRY_RUN=1` first.
- `POST /admin/profiles/unmerge` — unmerge profiles ⚠️ AARON APPROVAL — same checklist applies; see `muso-ops-profiles/SKILL.md` "Unmerge Profile".
- `POST /admin/profile/:profileId/link-external` — link external IDs
- `POST /admin/profile/:profileId/unlink-external` — unlink external IDs
- `POST /admin/profile/:profileId/unlink` — unlink profile
- `DELETE /admin/profile/:profileId/cache` — clear profile cache
- `GET /admin/profile/:profileId/collaborators` — list collaborators
- `POST /admin/profile/:profileId/collaborators/rebuild` — force-rebuild collaborators from current tracks (cache clear / recalculate / fast-lane do NOT touch collaborators — this verb is the ONLY refresh path; run it AFTER verifying the credit edit landed; idempotent; on 404 the verb isn't deployed yet — escalate to data-platform instead; see `docs/lessons/muso-domain.md` "Collaborators are pipeline-owned")
- `GET /admin/profile/:profileId/member` — get members
- `POST /admin/profile/:profileId/member` — add member
- `PUT /admin/profile/:profileId/member` — update member
- `DELETE /admin/profile/:profileId/member` — remove member
- `GET /admin/profile/:profileId/membership` — get memberships
- `GET /admin/profile/:profileId/charts` — get profile charts
- `POST /admin/profile/:profileId/encore-assets/generate` — generate encore assets
- `PUT /admin/profile/:profileId/playlist/:status` — update playlist status
- `POST /admin/profile/:profileId/playlist/regenerate` — regenerate playlist
- `POST /admin/profile/enrichByUrl` — enrich from URL
- `POST /admin/artist/:spotifyId/enrich` — enrich from Spotify
- `GET /admin/professional/:professionalId/credits/export` — export credits
- `POST /admin/profile/:profileId/audit/generate` — generate audit
- `GET /admin/profile/:profileId/audit` — get audit status
- `GET /admin/profile-member-actions` — list member actions
- `POST /admin/profile-member-actions/:id/approve` — approve
- `POST /admin/profile-member-actions/:id/revert` — revert

### Track Management (`/admin/track/*`)
- `GET /admin/tracks/search` — search tracks
- `GET /admin/track` — list tracks
- `GET /admin/track/:trackId` — get track
- `DELETE /admin/track/:trackId` — ⚠️ AARON ONLY
- `GET /admin/track/:trackId/sources` — get sources
- `GET /admin/track/:trackId/analytics-sources` — get analytics links
- `POST /admin/track/:trackId/analytics-sources` — add analytics link
- `PATCH /admin/track/:trackId/analytics-sources` — move analytics link
- `DELETE /admin/track/:trackId/analytics-sources` — remove analytics link 🛑 bulk-gated (see Bulk Destructive Gate)
- `GET /admin/track/:trackId/raw-credits` — get raw credits
- `POST /admin/track/:trackId/profile/:profileId/credits` — add track-profile credits
- `DELETE /admin/track/:trackId/profile/:profileId/credits` — remove credits
- `POST /admin/tracks/merge` — merge tracks ⚠️ AARON APPROVAL
- `POST /admin/tracks/unmerge` — unmerge tracks ⚠️ AARON APPROVAL
- `POST /admin/track/enrichByUrl` — enrich from URL
- `POST /admin/track/capture/:trackId` — trigger capture

### Album Management (`/admin/album/*`)
- `GET /admin/album/:albumId` — get album (also `/credits`, `/sources`)
- `POST /admin/album/enrichByUrl` | `POST /admin/album/capture/:albumId`

### Team/Workspace (`/admin/team/*`) — full CRUD
- `GET/POST /admin/team` — list/create teams
- `PUT /admin/team/:id` — update | `GET/POST/PUT/DELETE` for users, seats, lists, roster, entities, image
- `POST /admin/team/:id/subscription-sync` | `POST .../subscription/checkout`
- `POST/DELETE /admin/workspace/:workspaceId/key` — API keys

### Subscriptions (`/admin/subscription/*`)
- `GET/POST /admin/subscription` — list/create (⚠️ create = AARON ONLY)
- `PUT/GET /admin/subscription/:id` | `POST .../cancel`
- `GET /admin/subscription-info` | `GET /admin/payments/apple/lookup`

### Identity Resolution — `GET/PUT /admin/identity-resolution` (list, get by user, confirm, reject)

### Ads — delegated to `muso-ads-manager`: `POST/PUT /admin/ads`, `GET /admin/ads/targeting-debug`

### Analytics — `POST /admin/analytics/:profileId/recalculate`, `PUT /admin/analytics/recalculate`, `PUT .../lists/:listId/high-queue`

### Other — Articles (full CRUD), Orders/Encore (CRUD + complete-for-free), Marketplace Products, Settings (get/set), Media upload, Roles, Org search, Spotify search, Platform ingestion, Feed populate, OAuth clients, Worker processes

## Mandatory Audit Logging

**EVERY write operation through this API MUST be logged BEFORE execution.**

Log format: `api-logs/admin/YYYY-MM-DD.jsonl`

```json
{
  "timestamp": "2026-03-07T17:30:00Z",
  "operator": {"slack_id": "U7RP6HKUZ", "name": "Aaron Kaufman"},
  "operation": "claiming_approve",
  "endpoint": "POST /admin/claiming/12345/verify",
  "target": {"claiming_id": 12345, "profile_id": "abc-123"},
  "reason": "Verified via Spotify credits + IPI match",
  "request_body": {},
  "response_status": 200,
  "response_summary": "Claim approved successfully",
  "channel": "C0ADREBPNQ2",
  "thread_ts": "1772932016.021999"
}
```

Fields:
- `operator` — who requested it (from Slack sender_id)
- `operation` — human-readable operation name
- `endpoint` — exact API path called
- `target` — the entity being modified (IDs)
- `reason` — WHY this operation was performed (ask if not provided)
- `request_body` — what was sent
- `response_status` — HTTP status code
- `response_summary` — brief result

## Conversational Workflow

### The "Why" Protocol (MANDATORY for all write ops)

Before executing ANY write operation, Clio MUST:

1. **Confirm the action** — "I'm about to [action]. This will [effect]."
2. **Ask for reason** — "What's the reason for this?" (unless already stated)
3. **Show context** — Pull relevant data (user history, profile details, claim evidence)
4. **Suggest alternatives** — If there's a better path, mention it
5. **Get explicit confirmation** — "Confirm? (yes/no)"
6. **Log with reason** — Include the stated reason in the audit log

**Example:** "Approve claim 12345" → Clio pulls details, shows verification links + cross-checks → asks for reason → gets "Verified via Spotify page match" → confirms action → executes + logs → "✅ Claim 12345 approved."

## Error Handling

- If admin API returns 401 → re-authenticate (token expired)
- If admin API returns 403 → user doesn't have permission, escalate
- If admin API returns 404 → entity not found, inform operator
- If admin API returns 500 → log error, inform operator, suggest retry
- Never retry write operations automatically — always ask operator

## Dependencies

This skill is the foundation. Other ops skills depend on it:
- `muso-ops-claiming` — uses admin API for claim operations
- `muso-ops-credits` — uses admin API for credit request operations
- `muso-ops-profiles` — uses admin API for profile management
- `muso-ops-tracks` — uses admin API for track management
- `muso-ops-identity` — uses admin API for identity resolution
- `muso-ops-users` — uses admin API for user management
- `muso-ops-workspaces` — uses admin API for workspace operations
- `muso-ops-fraud` — cross-cutting fraud detection
- `muso-ops-audit` — logging and audit trail
