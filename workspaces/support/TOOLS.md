# TOOLS.md -- support

## Allowed Tools (EXACTLY 5)

This agent has the most restricted tool set in HYDRA. Only these 5 tools are permitted.

All tools are implemented as plugin-registered tools (via the `support-tools` OpenClaw plugin). The agent calls them by name -- the plugin handles all HTTP, auth, and response filtering internally. The agent never sees API keys or raw HTTP responses.

## Authentication (CRITICAL -- shared across tools 1, 2, 5)

`profile_lookup`, `credits_search`, and `profile_status` all use `MusoAdminClient` to call `api.muso.ai/api/v3/admin/*` with a JWT bearer token obtained via admin login (`MUSO_ADMIN_EMAIL` + `MUSO_ADMIN_PASSWORD` env vars). The client is GET-only and regex-allowlisted to exactly three paths (`profile/search`, `profile/<id>`, `profile/<id>/credits`). The JWT is never returned to the agent and never logged. `create_ticket` uses a separate ClickUp API key. `subscription_status` makes no upstream calls (stub).

This is a stopgap -- the original design assumed `MUSO_CUSTOMER_API_KEY` for `/api/c/*` endpoints, but that key was never provisioned. Replace with a dedicated read-only Caroline credential when one is available. See `project_caroline_admin_creds_followup.md` in memory.

### 1. profile_lookup

- **Wraps**: `GET /api/v3/admin/profile/search?keyword=<q>`
- **Returns**: Public data ONLY -- name, role, verified status, credits count
- **Auth**: Muso admin JWT bearer (handled by plugin via MusoAdminClient; GET-only and path-allowlisted)
- **Rate limit**: 10/min per session
- **PII filter**: Email, phone, address, payment details are NEVER returned

### 2. credits_search

- **Wraps**: `GET /api/v3/admin/profile/{profileId}/credits?limit=<L>&offset=<O>`
- **Returns**: Public credit data -- credit role, track name, release name, release date. Note: `totalCount` is computed from `items.length` as a fallback (not returned by upstream).
- **Auth**: Muso admin JWT bearer (same client as profile_lookup; GET-only, allowlisted)
- **Rate limit**: 10/min per session
- **Parameters**: `profileId` (required), `keyword` (optional text filter), `creditRole` (optional role filter), `limit`, `offset`

### 3. subscription_status

- **Returns**: Structured JSON. Always returns `{ ok: false, reason: "not_implemented", suggest_followup: true }` until the endpoint is wired up. Caroline should follow up via create_ticket.
- **Would wrap**: Subscription status endpoint (TBD)
- **Auth**: TBD -- requires user's authenticated session token
- **Privacy**: Only returns data for the authenticated user -- no cross-account lookups

### 4. create_ticket

- **Wraps**: ClickUp task creation in list 901000600160
- **Returns**: Structured JSON. On success: `{ submitted: true, ticket_id, sla, action_type, tier }`. On failure: `{ submitted: false, reason: "rate_limited" | "queue_busy" | "invalid_input" }`. Caroline composes the customer-facing reply from these fields; never says "ticket" / "ClickUp" verbatim.
- **Auth**: ClickUp API key (handled by plugin, never visible to agent)
- **Rate limit**: 2 per session (60-minute window)
- **Required fields**: `actionType`, `customerEmail`, `summary`, `conversationSummary`
- **Optional fields**: `customerProfileId`, `details` (action-specific key-value pairs)
- **Auto-derived**: subject (`Action Request: {actionType}`), priority (from tier), tags (`hydra-action-request`, `tier-N`)

### 5. profile_status

- **Bundles**: `GET /api/v3/admin/profile/search?keyword=<q>&limit=5` for resolution, `GET /api/v3/admin/profile/{id}` for direct UUID, `GET /api/v3/admin/profile/{id}/credits?limit=20&offset=0` for credits.
- **Returns**: Structured JSON. On success: `{ found: true, profile: { id, name, verified, primary_role, credits_count }, latest_credits: [top 3 sorted by release_date desc], latest_credit_date }`. On failure: `{ found: false, reason: "no_match" | "multiple_matches" | "lookup_unavailable" | "missing_input" | "rate_limited", ... }`.
- **Auth**: Muso admin JWT bearer (MusoAdminClient; GET-only, regex-allowlisted to the 3 profile endpoints).
- **Rate limit**: 10/min per session
- **Parameters** (one of, precedence top-to-bottom): `profile_id` (UUID), `profile_url` (full credits.muso.ai URL), `email` (used for lookup, never echoed back), `name` (display name)
- **PII filter**: email, phone, address, payment details are NEVER returned

## Action Request Pattern

For customer write actions (credit claims, refunds, profile updates, disputes), use `create_ticket` with structured formatting. See `skills/action-request/SKILL.md` for the full ticket format.

**Key points**:
- Tasks are created in the designated ClickUp list (901000600160) with `hydra-action-request` tag and the approval tier (`tier-1`, `tier-2`, `tier-3`)
- Include a machine-readable JSON block in the task description (between `---ACTION-REQUEST---` and `---END-ACTION-REQUEST---` markers)
- This does NOT add a new tool -- it uses `create_ticket` with structured content
- The Operations agent picks up tasks tagged `hydra-action-request` for review and execution

## Denied Tools (EVERYTHING ELSE)

The following are explicitly denied -- this is the longest deny list in HYDRA:

- `exec` -- no shell execution
- `browser` -- no web browsing
- `http_request` -- no raw HTTP calls
- `github_push`, `github_pr`, `github_read` -- no code access
- `kubectl`, `helm`, `docker` -- no infrastructure access
- `quickbooks`, `payroll` -- no financial systems
- `crm_read`, `crm_write` -- no CRM access
- `slack_dm`, `slack_admin` -- no Slack administration
- `vault_read`, `vault_write` -- no secret management
- `db_read`, `db_write` -- no direct database access
- `file_write`, `file_delete` -- no file system access
- `secrets_read` -- no credential access
- `sessions_send` -- no cross-agent communication (COMPLETE ISOLATION)
