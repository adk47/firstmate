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

**Transition matrix.** The canonical list lives in ONE place in the backend —
`core-backend/src/services/credit-requests/statusTransitions.js` — and both the
handler's legality check and its guarded `UPDATE` read it, so the table below
cannot drift from one half of the enforcement:

| Target status              | Allowed prior statuses                                    |
|----------------------------|-----------------------------------------------------------|
| `approved`                 | `unverified`, `user_verification_needed`, `rejected`, `processing` |
| `rejected` (human-only)    | `unverified`, `user_verification_needed`, `approved`, `processing` |
| `user_verification_needed` | `unverified`, `rejected`                                  |
| `unverified`               | `approved` ONLY                                           |
| `processing`               | `unverified`, `processing`, `user_verification_needed`    |

`pending` is accepted by validation but is in no allowed-from list, so a
`pending` row never transitions.

**`approved → user_verification_needed` is refused, deliberately.** Approved
rows exit via `unverified` (or `rejected`), the edges that publish the catalog
delete; sending one straight to the verification screen would leave its credits
live on the track. A sweep that tries it gets the row back as
`illegal_transition` — it is not a bug to fix by widening the matrix.

**`rejected → user_verification_needed` DOES work** (shipped 2026-07-27, PRs
#9222/#9226 develop, #9227 master). The 2026-07-23 incident, where 28 rows
reported success while zero moved, is closed.

**Reading the response.** A status PUT reports what actually persisted:

```json
{ "updated": 2, "updatedIds": ["<id>", "<id>"],
  "skippedIds": ["<id>"],
  "skipped": [{"id": "<id>", "reason": "illegal_transition"}],
  "failedIds": [] }
```

`reason` is one of `not_found`, `illegal_transition`, `lost_race`,
`seed_refused`. **A 409 is a PARTIAL SUCCESS, not a total failure**: it means at
least one row was refused because its catalog seed could not be published, and
it carries the same report — the ids in `updatedIds` really did move and must
not be re-attempted. Only `failedIds` needs retrying, after the spotify metadata
is repaired. Never infer per-row outcomes from the status code alone.

**Even so: never claim success from the response alone. Always read back.**
After every status PUT, verify with the tested readback script (do not
compose ad-hoc jq):

```bash
bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/verify-credit-request-status.sh \
  --expected <target_status> --ids "<id1>,<id2>,..."
```

Exit 0 = all ids verified at the target status; exit 1 = at least one row did
not transition (stdout lists `{id, actual}`); exit 3 = readback could not run
(treat the write as UNVERIFIED — say so, never claim success). For
UVN flagging specifically, prefer `batch-flag-credits.sh`, which now runs
this readback automatically.

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

**Mandatory readback:** after ANY status PUT, confirm the ids actually landed
using the `verify-credit-request-status.sh` readback documented above — HTTP 200
means batch *acceptance*, not success; partial failures and disallowed
transitions surface only on re-fetch. Do NOT use the
`GET /admin/credit-requests?profilesIds=` list endpoint for this: it has no id
filter, so it cannot answer "did THESE ids transition" without an unbounded
scan-and-hope. If a transition no-oped, say so honestly (check the matrix above
for why) — never report a status change you have not read back.

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
