# TOOLS.md -- support

## Allowed Tools (EXACTLY 9)

This agent has the most restricted tool set in HYDRA. Only these 9 tools are permitted, split into two groups:

- **Action tools (1-7)** -- write or read customer-facing state. Implemented as plugin-registered tools via the `support-tools` OpenClaw plugin. The agent calls them by name; the plugin handles all HTTP, auth, and response filtering internally. The agent never sees API keys or raw HTTP responses.
- **Reference tools (8-9)** -- read-only semantic + BM25 retrieval against `workspaces/support/reference/*.md`, provided by openclaw's bundled memory-core via the per-agent `memorySearch` config (enabled on both edge and main profiles, indexing the read-only `reference/` subdirectory only). No writes; no customer-data persistence; no auto-recall.

## Authentication (CRITICAL -- shared across tools 1, 2, 5, 6, 7)

`profile_lookup`, `credits_search`, and `profile_status` all use `MusoAdminClient` to call `api.muso.ai/api/v3/admin/*` with a JWT bearer token obtained via admin login (`MUSO_ADMIN_EMAIL` + `MUSO_ADMIN_PASSWORD` env vars). The client is GET-only and regex-allowlisted to exactly three paths (`profile/search`, `profile/<id>`, `profile/<id>/credits`). The JWT is never returned to the agent and never logged.

`remove_credits` (tool 6) also depends on the same Muso admin auth -- it inherits via the JWT cache maintained by `muso-admin-api.sh`. Rotating `MUSO_ADMIN_EMAIL` / `MUSO_ADMIN_PASSWORD` breaks the bash wrapper too; flush `~/.cache/muso-admin-token.json` (or whatever `$TOKEN_CACHE` points to) after a rotation.

`create_ticket` uses a separate ClickUp API key. `subscription_status` makes no upstream calls (stub).

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
- **Returns**: Structured JSON. On success: `{ found: true, profile: { id, name, verified, isClaimed, primary_role, credits_count, workspaces: [{email, isClaimed}], knownAsNames: [] }, latest_credits: [top 3 sorted by release_date desc], latest_credit_date }`. On failure: `{ found: false, reason: "no_match" | "multiple_matches" | "lookup_unavailable" | "missing_input" | "rate_limited", ... }`. The `isClaimed`, `workspaces`, and `knownAsNames` fields are used by the `customer-credit-removal` skill for Step-2 ownership pre-check; the bash wrapper independently re-verifies these as the security boundary.
- **Auth**: Muso admin JWT bearer (MusoAdminClient; GET-only, regex-allowlisted to the 3 profile endpoints).
- **Rate limit**: 10/min per session
- **Parameters** (one of, precedence top-to-bottom): `profile_id` (UUID), `profile_url` (full credits.muso.ai URL), `email` (used for lookup, never echoed back), `name` (display name)
- **PII filter**: email, phone, address, payment details are NEVER returned

### 6. remove_credits

- **Wraps**: `DELETE /api/v3/admin/track/{trackId}/profile/{profileId}/credits` via the bash wrapper at `workspaces/support/skills/customer-credit-removal/scripts/remove-credits.sh`. The TS tool is a typed dispatcher only – all ownership-check, title-resolution, cap-enforcement, and audit-log logic lives in the wrapper script (single source of truth).
- **Returns**: Structured JSON. On success: `{ ok: true, mode: "apply" | "dry-run", profile_id, owner_email, ownership_check: "passed", results: [...], summary: {requested, removed, already_removed, not_found, ambiguous, errors} }`. On refusal: `{ ok: false, error: <key>, detail }`. See `skills/customer-credit-removal/SKILL.md` for the per-error customer-facing reply mapping.
- **Auth**: The wrapper uses `muso-admin-api.sh`'s JWT cache (same Muso admin JWT as the other admin-API tools). The agent never sees the token.
- **Rate limit**: 10 per session (60-minute window). Plus hard caps inside the wrapper: 50 tracks per call, 100 per customer per day.
- **Required fields**: `profileId` (UUID), `requesterEmail` (Intercom-verified), `tracks[]` (max 50 "Artist - Title" strings).
- **Conditionally-required**: `intercomConvId` – required whenever `apply: true`. The tool fast-refuses `intercom_conv_id_required` without ever exec'ing the wrapper if missing. Strongly recommended on dry-run too (the dry-run audit row is keyed by it, and the wrapper does the Intercom-email cross-check whenever a conv-id is present).
- **Optional fields**: `apply` (default false = dry-run).
- **Safety model**: ownership re-verified inside the wrapper, independent of whatever the LLM passes. Three mechanical refusals beyond ownership:
  - `intercom_email_mismatch` – the wrapper fetches `source.author.email` from Intercom for the conversation and refuses if it doesn't match `requesterEmail`. Closes the message-text-injection vector.
  - `dry_run_required` – every track applied must have a matching `would_remove` audit row from the same `(profile_id, requester_email)` within the last 15 minutes. Forces the dry-run-then-confirm-then-apply pattern mechanically; no SKILL prose required.
  - `intercom_conv_id_required` – apply-without-conv-id refuses at the TS-tool layer before exec.
- **Idempotency**: re-running the same input is safe – already-removed credits return 404 from the API and are tagged `already_removed` in the response.

### 7. dedupe_check

- **Wraps**: read-only verification for a customer profile-merge request. Issues `GET /api/v3/admin/profile/{id}` (+ `/credits`) for the survivor and each duplicate via `MusoAdminClient`, and a read-only Intercom `GET /conversations/{id}` to fetch the contact's real `source.author.email`. No writes, no merge, no tier-2 endpoint, no `exec`.
- **Returns**: PII-safe structured verdict -- `{ verified, owner_undetermined, impersonation_flag, owns_survivor, survivor_claimed_workspace_count, cluster_size_check: "not_performed", duplicates: [{ profile_id, claim_state, credit_count, shared_external_id: "none"|"weak", shared_track_count }], notes: [] }`. Emits ONLY enums/booleans/UUIDs/counts -- never a third-party workspace email.
- **conv-id**: derived in-plugin from `ctx.sessionId` (NOT an agent parameter), so the anti-spoof anchor can't be pointed at another conversation.
- **Auth**: Muso admin JWT (same `MusoAdminClient`, GET-only) + `MUSOAI_INTERCOM_TOKEN` (read from env). Token absent / conv-id underivable / no contact email -> **fails closed** (`owner_undetermined`).
- **Rate limit**: 10 per session (60-minute window); caps duplicates at 5 per call.
- **Used by**: the `customer-profile-dedupe` skill. The tool produces evidence ONLY -- Caroline files a `profile-merge` ticket via `create_ticket`; Operations executes the irreversible merge.

### 8. memory_search

- **Wraps**: openclaw's bundled memory-core hybrid retrieval (vector + BM25) against the per-agent qmd index built from `workspaces/support/reference/*.md`.
- **Returns**: Ranked chunks with file path, line range, and similarity score.
- **Auth**: None at agent level (the embedding provider auth – OpenRouter-proxied OpenAI `text-embedding-3-small` – is resolved by openclaw runtime from `hydra-secrets`/`/OPENROUTER_API_KEY`; never visible to the agent).
- **Indexed scope**: `reference/` subdirectory only. CI invariant pins `extraPaths == ["reference"]` on both edge and main profiles. Customer-session transcripts, tickets, and api-logs are explicitly NOT indexed.
- **Rate limit**: governed by openclaw memory runtime; no application-level cap.
- **PII filter**: not needed – the indexed corpus is read-only doctrine, no customer data.
- **When to use**: "is there an active incident affecting this topic?", "what's the doctrine for X?", and anywhere the answer isn't already in loaded context (SOUL.md / TOOLS.md / common-issues row #N).

### 9. memory_get

- **Wraps**: openclaw's bundled memory-core point-lookup by note id.
- **Returns**: The full text of a single indexed chunk by id (typically followed up from a `memory_search` hit).
- **Auth**: same as `memory_search`.
- **When to use**: when a `memory_search` result snippet is truncated and you need the full chunk before responding.

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
