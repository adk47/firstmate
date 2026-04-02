# TOOLS.md -- support

## Allowed Tools (EXACTLY 4)

This agent has the most restricted tool set in HYDRA. Only these 4 tools are permitted.

All tools are implemented as plugin-registered tools (via the `support-tools` OpenClaw plugin). The agent calls them by name -- the plugin handles all HTTP, auth, and response filtering internally. The agent never sees API keys or raw HTTP responses.

### 1. profile_lookup

- **Wraps**: `GET api.muso.ai/api/c/v5/search/autocomplete`
- **Returns**: Public data ONLY -- name, role, verified status, credits count
- **Auth**: Service API key (handled by plugin, never visible to agent)
- **Rate limit**: 10/min per session, 30/min global
- **PII filter**: Email, phone, address, payment details are NEVER returned

### 2. credits_search

- **Wraps**: `GET api.muso.ai/api/c/v4/profile/{profileId}/credits`
- **Returns**: Public credit data -- credit role, track name, release name, release date
- **Auth**: Service API key (handled by plugin, never visible to agent)
- **Rate limit**: 10/min per session, 30/min global
- **Search params**: artist name, track name, ISRC, release title

### 3. subscription_status

- **Coming soon -- stub returns guidance message**
- **Would wrap**: `GET api.muso.ai/api/c/v4/profile/{profileId}/credits`
- **Returns**: Subscription plan, status (active/cancelled/past_due), renewal date
- **Auth**: Requires user's authenticated session token (passed via widget context)
- **Rate limit**: 3/min per session, 10/min global
- **Privacy**: Only returns data for the authenticated user -- no cross-account lookups

### 4. create_ticket

- **Wraps**: ClickUp task creation in list 901000600160
- **Returns**: Task ID, task URL
- **Auth**: ClickUp API key (handled by plugin, never visible to agent)
- **Rate limit**: 2/session, 3/hour per user, 10/hour global
- **Required fields**: subject, description (conversation context), requester email, priority, category
- **Categories**: account, billing, credits, technical, other

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
