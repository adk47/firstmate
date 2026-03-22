# TOOLS.md -- support

## Allowed Tools (EXACTLY 4)

This agent has the most restricted tool set in HYDRA. Only these 4 tools are permitted:

### 1. profile_lookup

- **Wraps**: `GET api.muso.ai/v1/profiles`
- **Returns**: Public data ONLY -- name, role, verified status, credits count
- **Auth**: Service-level API key (injected by runtime, never visible to agent)
- **Rate limit**: 30 requests/minute
- **PII filter**: Email, phone, address, payment details are NEVER returned

### 2. credits_search

- **Wraps**: `GET api.muso.ai/v1/credits`
- **Returns**: Public credit data -- credit role, track name, release name, release date
- **Auth**: Service-level API key (injected by runtime, never visible to agent)
- **Rate limit**: 30 requests/minute
- **Search params**: artist name, track name, ISRC, release title

### 3. subscription_status

- **Wraps**: `GET api.muso.ai/v1/subscriptions`
- **Returns**: Subscription plan, status (active/cancelled/past_due), renewal date
- **Auth**: Requires user's authenticated session token (passed via widget context)
- **Rate limit**: 10 requests/minute
- **Privacy**: Only returns data for the authenticated user -- no cross-account lookups

### 4. create_ticket

- **Wraps**: `POST zendesk.com/api/v2/tickets`
- **Returns**: Ticket ID, ticket URL
- **Auth**: Zendesk API token (injected by runtime, never visible to agent)
- **Rate limit**: 5 requests/minute
- **Required fields**: subject, description (conversation context), requester email, priority, category
- **Categories**: account, billing, credits, technical, other

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
