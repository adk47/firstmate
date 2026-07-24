---
name: muso-ops-credits
description: |
  Credit request processing for Muso.AI ops team. Review and approve
  user-submitted credit additions/changes with source verification; requests
  with insufficient proof stay in Verification Needed (rejection is human-only).
  
  Replaces: Retool credit request management
  
  Use when: processing credit requests, reviewing pending credits, checking credit
  sources, managing user-added credits.

  Triggers: "credit request", "pending credits", "approve credit", "reject credit",
  "credit queue", "user credits", "credit source"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-ops-admin (API gateway), Trino (credit analysis).
metadata:
  version: "1.1"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — Credit Requests

Process user-submitted credit additions and changes.

## Access Control

Check sender_id tier from `muso-ops-admin`:
- Tier 1-3: full credit request operations
- Tier 4: read-only

## Workflows

### List Pending Credit Requests

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?status=pending&limit=20"
```

Also get pending counts:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests/counts"
```

### Review Credit Request

**Step 1: Pull request details**

There is no single-credit-request GET endpoint. Filter the list by profile or track instead:

```bash
# By profile
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?profilesIds=<profile_id>&limit=20"

# By track
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?trackId=<track_id>&limit=20"
```

**Step 2: Verify credit legitimacy**
For the track being credited:
```sql
-- Check existing credits on the track
SELECT t._id, t.title, t.popularity, t.default_release_label
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
WHERE t._id = '<track_id>'
  AND t.is_deleted = false
```

**Step 3: Cross-reference**
- Does this person appear in industry data for this track?
- Is the role plausible given the track's genre/era/label?
- Web search: "[person name]" "[track title]" credits

**Step 4: Present verdict with recommendation**

### Resolve a Credit Request: Approve, or Keep in Verification Needed

**Never reject autonomously.** This mirrors the customer-facing rule (Caroline
never rejects): when proof is insufficient, the request stays in
`user_verification_needed` and more evidence is requested — a hard reject is a
human decision. Two reasons, both load-bearing:

1. **Rejection is a one-way door.** The backend transition matrix (below) has
   NO `rejected → user_verification_needed` path — the only exit from
   `rejected` is `approved`. On 2026-07-22 the agent rejected 28 UVN requests
   during a ClickUp sweep; Jan's "move them back to verification needed"
   correction silently no-oped (28/28 stayed rejected).
2. **The reject gate enforces it.** `muso-admin-api.sh` refuses any
   `status:"rejected"` write unless `--confirmed-by <jan|aaron|nick>
   --approval-msg-id <slack_ts>` point at an explicit in-thread human decision
   (`MUSO_CREDIT_REJECT_APPROVAL_REQUIRED` otherwise).

Status changes use the **collection** endpoint (`PUT /admin/credit-requests`) — NOT
`PUT /admin/credit-requests/:requestId`, which only consumes a `credits` field
and ignores `status`.

Backend handler: `core-backend/src/apis/_admin/credit-requests/updateStatus.js`
Body: `{ requestIds: [<id>, ...], status: <status> }` (or `profileId` instead of
`requestIds` to bulk-update for a profile — **but the `profileId` selector
matches ONLY `unverified` rows**; UVN/rejected/processing rows are silently
skipped, so always use explicit `requestIds` for anything past `unverified`).
Valid statuses: `pending`, `processing`, `approved`, `rejected`, `unverified`,
`user_verification_needed`.

**Transition matrix** (hard-coded per-branch in the handler — any transition
not listed here **silently no-ops and still returns 200**):

| Target status              | Allowed prior statuses                                    |
|----------------------------|-----------------------------------------------------------|
| `approved`                 | `unverified`, `user_verification_needed`, `rejected`, `processing` |
| `rejected` (human-only)    | `unverified`, `user_verification_needed`, `approved`, `processing` |
| `user_verification_needed` | `unverified` ONLY                                         |
| `unverified`               | `approved` ONLY                                           |
| `processing`               | `unverified`, `processing`, `user_verification_needed`    |

**Approve:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/credit-requests" '{"requestIds":["<id>"],"status":"approved"}'
```

**Insufficient proof:** if the request is already `user_verification_needed`,
leave it there — no API call — and record what evidence is missing in the
ClickUp ticket / conversation so the customer can be asked for it. If it is
still `unverified`, move it to Verification Needed:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/credit-requests" '{"requestIds":["<id>"],"status":"user_verification_needed"}'
```

**Reject (human-only):** only after Jan, Aaron, or Nick explicitly decides
in-thread — pass the approval evidence or the gate refuses:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --confirmed-by jan --approval-msg-id <slack_ts_of_decision> \
  call PUT "/admin/credit-requests" '{"requestIds":["<id>"],"status":"rejected"}'
```

The handler does NOT read a `reason` field — track the rationale in the audit
log only, not in the request body.

**Mandatory readback:** after ANY status PUT, re-fetch and confirm the ids
actually landed. HTTP 200 means batch *acceptance*, not success — partial
failures and disallowed transitions surface only on re-fetch:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?profilesIds=<profile_id>&limit=50"
```
Verify each id now shows the target status. If a transition no-oped, say so
honestly (check the matrix above for why) — never report a status change you
have not read back.

Standard escalation rationales when recommending a reject to Jan (record in
the audit log / escalation thread, not the request body):
- "No matching credits found in industry data sources"
- "Credit already exists from verified industry feed"
- "Track metadata doesn't support this credit role"
- "Duplicate request — previously processed"

### Profiles with Pending Requests

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests/profiles"
```

Useful for: identifying high-volume submitters, potential spam, or workspaces
that need cleansing.

## Fraud Signals

- 🚩 User submitting credits to tracks they have no industry connection to
- 🚩 Bulk credit submissions (>20 in one day)
- 🚩 Credits to high-popularity tracks by unknown profiles
- 🚩 Same user adding themselves to tracks across multiple unrelated genres
- 🚩 Credit additions right after profile claiming (padding credits)

## Alternatives to Suggest

When asking for more proof (request stays in Verification Needed):
- "If you produced this track, ask your distributor to update the metadata"
- "Credits from industry sources (labels, distributors) are automatically reflected"
- "For live/session credits, provide documentation (session sheets, contracts)"
