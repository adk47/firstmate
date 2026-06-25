# TOOLS.md -- support

## Allowed Tools (EXACTLY 15)

This agent has the most restricted tool set in HYDRA. Only these 15 tools are permitted, split into three groups:

- **Action tools (1-10)** -- write or read customer-facing state. Implemented as plugin-registered tools via the `support-tools` OpenClaw plugin. The agent calls them by name; the plugin handles all HTTP, auth, and response filtering internally. The agent never sees API keys or raw HTTP responses.
- **Reference tools (11-12)** -- read-only semantic + BM25 retrieval against `workspaces/support/reference/*.md`, provided by openclaw's bundled memory-core via the per-agent `memorySearch` config (enabled on both edge and main profiles, indexing the read-only `reference/` subdirectory only). No writes; no customer-data persistence; no auto-recall.
- **Gated self-serve write tools (13-15)** -- `profiles_claim_self`, `credits_verify`, `profiles_consolidate`. Each shells `muso <verb> --actor-identity <verified-email>` through a thin bash wrapper; muso-cli's capability gate is the ownership/caps/audit boundary. Dark-shipped OFF by default (per-account rollout).

## Authentication (CRITICAL -- shared across tools 1, 2, 5, 6, 7, 8, 9)

`profile_lookup`, `credits_search`, `profile_status`, and `order_lookup` all use `MusoAdminClient` to call `api.muso.ai/api/v3/admin/*` with a JWT bearer token obtained via admin login (`MUSO_ADMIN_EMAIL` + `MUSO_ADMIN_PASSWORD` env vars). The client is GET-only and regex-allowlisted to exactly five paths (`profile/search`, `profile/<id>`, `profile/<id>/credits`, the `credit-requests` LIST endpoint -- never `credit-requests/<id>`, the item path the gated approve PUT lives under -- and the single-order read `orders/<id>`, never the `orders/<id>/...` write sub-paths or the bare `orders` list). The JWT is never returned to the agent and never logged.

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
- **Returns**: Structured JSON. On success: `{ submitted: true, ticket_id, sla, action_type, tier }`, plus `updated_existing: true` when the request was appended as a comment to an existing ticket from this conversation instead of opening a duplicate. On failure: `{ submitted: false, reason: "rate_limited" | "queue_busy" | "invalid_input" }`. Caroline composes the customer-facing reply from these fields; never says "ticket" / "ClickUp" verbatim.
- **Dedupe**: a repeat call with the same `actionType` in the same conversation (or matching an open ticket for the same customer email + action from the last 7 days) appends a follow-up comment to the existing ticket. Follow-ups have their own budget (5 per session) and do NOT consume the 2-per-session create allowance.
- **Auth**: ClickUp API key (handled by plugin, never visible to agent)
- **Rate limit**: 2 ticket creations per session (60-minute window); 5 follow-up appends per session
- **Required fields**: `actionType`, `customerEmail`, `summary`, `conversationSummary`
- **Optional fields**: `titleGist` (≤60-char concrete gist for the title; falls back to `summary`), `customerProfileId`, `details` (action-specific key-value pairs)
- **Auto-derived**: title (`[{action}] {gist} – {email}`), priority (from tier), due date (from tier SLA in business days), tags (`hydra-action-request`, `tier-N`, `action:{type}`, `team:growth|catalog`, `escalation:*` when `details.escalation_reason` is set)

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

### 8. credit_verification_check

- **Wraps**: read-only lookup of a customer's `user_verification_needed` (UVN) credits. Anchors ownership to the contact's real `source.author.email` via a read-only Intercom `GET /conversations/{id}`, confirms ownership against `GET /api/v3/admin/profile/{id}` (search-by-email when no profile is named), then `GET /api/v3/admin/credit-requests?profilesIds=<id>&status=user_verification_needed`. No writes, no approve/reject, no tier-2 endpoint, no `exec`. The `MusoAdminClient` is GET-only, so it cannot reach the gated `PUT /admin/credit-requests` approve path that shares the prefix.
- **Returns**: PII-safe structured verdict -- `{ verified_owner, owner_undetermined, impersonation_flag, profile_id, uvn_credits: [{ cr_id, role, track_title, artist, isrc }], count, notes: [] }`. Track/artist strings are injection-stripped and length-capped. When the feature flag is off: `{ disabled: true, note }` (fall back to a normal ticket). `impersonation_flag` is only meaningful when `requesterEmail` was passed -- when it wasn't, the verdict carries a "no impersonation cross-check performed" note so `false` is never read as "identity cross-check passed".
- **conv-id**: derived in-plugin from `ctx.sessionId` (NOT an agent parameter), so the anti-spoof anchor can't be pointed at another conversation. A profile a customer names is ALWAYS re-verified for ownership before any pending credit is surfaced.
- **Auth**: Muso admin JWT (`MusoAdminClient`, GET-only) + `MUSOAI_INTERCOM_TOKEN` (env). Token absent / conv-id underivable / no contact email / not-owner / typed-email mismatch (`impersonation_flag`) / shared profile (multiple claimed workspaces -- the sole-claimed-workspace ownership rule, same as `dedupe_check`) -> **fails closed** (`owner_undetermined`, empty list).
- **Rate limit**: 10 per session (60-minute window).
- **Used by**: the `customer-credit-verification` skill. The tool produces evidence ONLY -- Caroline asks the customer for proof and, when warranted, files a `credit-verify` recommend-approve ticket via `create_ticket`; a human executes the gated approval. This read tool itself never approves or rejects -- the autonomous approve path is the separate gated `credits_verify` (#14), used ONLY for the catalog-corroborated case; everything else stays a human decision and Caroline never rejects.

### 9. order_lookup

- **Wraps**: `GET /api/v3/admin/orders/{ref}` via `MusoAdminClient` (GET-only, allowlisted). `ref` is any of: the internal order UUID (Prodigi merchantReference), the order number, or Prodigi's own order id — the backend resolves all three.
- **Returns**: PII-scoped structured JSON. On success: `{ found: true, order: { id, orderNumber, prodigiOrderId, status, createdAt, items: [...], shipment: { address, phoneNumber, trackingNumber, trackingUrl } } }`. On failure: `{ found: false, reason: "missing_input" | "not_found" | "rate_limited" | "lookup_unavailable" }`.
- **Scope**: surfaces the fulfilment-relevant fields ONLY. The shipping address + recipient phone ARE the working data (this tool exists to confirm/correct them for Prodigi). **Payment data is never returned.**
- **Auth**: Muso admin JWT bearer (same client as the profile tools; GET-only, allowlisted to the single-order read path).
- **Rate limit**: 10/min per session.
- **Used by**: the `order-fulfillment` skill (vendor-lane Prodigi address requests + customer order/shipping questions). See `reference/orders-and-fulfillment.md`.

### 10. order_address_update

- **Wraps**: `PUT /api/v3/admin/orders/{id}` via the bash wrapper at `workspaces/support/skills/order-fulfillment/scripts/update-order-address.sh` (NOT `MusoAdminClient` — same wrapper-as-boundary model as `remove_credits`). The TS tool is a typed dispatcher; the wrapper is the ownership + audit boundary.
- **Returns**: Structured JSON. Dry-run: `{ ok: true, mode: "dry-run", applied: false, order_id, order_status, current_address, proposed, editable }`. Apply: `{ ok: true, mode: "apply", applied: true, order_id, http_status: 200, applied_recipient }`. Refusal: `{ ok: false, error: <key> }` where `<key>` ∈ `address_invalid` | `intercom_conv_id_required` | `owner_mismatch` | `owner_undetermined` | `intercom_email_mismatch` | `order_lookup_failed` | `dry_run_required` | `cap_exceeded_per_day` | `apply_failed` | `rate_limited`.
- **Auth**: the wrapper uses `muso-admin-api.sh`'s JWT cache (same Muso admin auth as `remove_credits`). The agent never sees the token.
- **Safety model (in the wrapper, independent of the LLM)**: resolves the order, then requires the requester email to equal the order's owner email AND to match the Intercom contact's `source.author.email`; validates the address (≤40-char lines + required fields); dry-run-then-apply (apply needs a matching `would_update` audit row from the last 15 min); audit log at `/var/log/openclaw/order-fulfillment.jsonl`; per-customer-per-day cap. Fails closed and routes to a ticket on any gate failure.
- **Required fields**: `order_ref` (UUID / order number / Prodigi id), `customer_email` (the verified owner), `recipient` ({ name, phone, line1, line2?, city, state?, postcode, country, email? }). `intercomConvId` required when `apply: true`.
- **Rate limit**: 5 per session (60-minute window).
- **Used by**: the `order-fulfillment` skill (customer lane only — never on a vendor's say-so). See `reference/orders-and-fulfillment.md`.

### 11. memory_search

- **Wraps**: openclaw's bundled memory-core hybrid retrieval (vector + BM25) against the per-agent qmd index built from `workspaces/support/reference/*.md`.
- **Returns**: Ranked chunks with file path, line range, and similarity score.
- **Auth**: None at agent level (the embedding provider auth – OpenRouter-proxied OpenAI `text-embedding-3-small` – is resolved by openclaw runtime from `hydra-secrets`/`/OPENROUTER_API_KEY`; never visible to the agent).
- **Indexed scope**: `reference/` subdirectory only. CI invariant pins `extraPaths == ["reference"]` on both edge and main profiles. Customer-session transcripts, tickets, and api-logs are explicitly NOT indexed.
- **Rate limit**: governed by openclaw memory runtime; no application-level cap.
- **PII filter**: not needed – the indexed corpus is read-only doctrine, no customer data.
- **When to use**: "is there an active incident affecting this topic?", "what's the doctrine for X?", and anywhere the answer isn't already in loaded context (SOUL.md / TOOLS.md / common-issues row #N).

### 12. memory_get

- **Wraps**: openclaw's bundled memory-core point-lookup by note id.
- **Returns**: The full text of a single indexed chunk by id (typically followed up from a `memory_search` hit).
- **Auth**: same as `memory_search`.
- **When to use**: when a `memory_search` result snippet is truncated and you need the full chunk before responding.

### 13. profiles_claim_self

- **Wraps**: `muso profiles claim-self --actor-identity <verified-email>` via the bash wrapper at `workspaces/support/skills/customer-profile-claim/scripts/claim-self.sh` (the muso capability gate is the ownership/caps/audit boundary; the wrapper is thin). Gated WRITE counterpart of the read-only checks.
- **Returns**: `{ok, mode, claim_id, profile_id, status}` (status applied|dry_run|noop) or `{ok:false, error}` (`route_to_human` on a non-owner claim, `disabled` until enabled).
- **Auth**: muso uses the host login (`MUSO_ADMIN_*`, `MUSO_STATE_DIR`); the `--actor-identity` is the ctx-derived verified Intercom author email (`deriveConvId`+`getAuthorEmail`), NEVER a model arg. Per-actor caps + ownership re-verify are server-side in muso-cli.
- **When to use**: via the `customer-profile-claim` skill, to verify a customer's OWN pending profile claim. Preview (`apply:false`) then apply.

### 14. credits_verify

- **Wraps**: `muso credits verify --actor-identity <verified-email>` (APPROVAL-tier PUT: also `--yes --confirmed-by <MUSO_CAPABILITY_APPROVER> --approval-ref <conv-id>`) via `workspaces/support/skills/customer-credit-verification/scripts/verify-credit.sh`. The WRITE counterpart of `credit_verification_check` (#8).
- **Returns**: `{ok, mode, request_id, profile_id, status}` or `{ok:false, error}` (`route_to_human` when corroboration/ownership fails, `no_approver` if the approver env is unset, `disabled`).
- **Auth**: same muso host auth + ctx-derived `--actor-identity` as #13; `--intercom-conv-id` is REQUIRED (it is the approval-ref). muso re-verifies ownership + deterministic catalog corroboration server-side and refuses without it; per-actor/day approval cap.
- **When to use**: via the `customer-credit-verification` skill, AFTER the read-only check + the customer's proof, to approve their OWN corroborated pending credit. Preview then apply.

### 15. profiles_consolidate

- **Wraps**: `muso profiles consolidate --actor-identity <verified-email>` (APPROVAL-tier: `--yes --confirmed-by <MUSO_CAPABILITY_APPROVER> --approval-ref <conv-id>`) via `workspaces/support/skills/customer-profile-consolidate/scripts/consolidate.sh`. The WRITE counterpart of `dedupe_check` (#7).
- **Returns**: `{ok, mode, survivor, dup_ids, status}` or `{ok:false, error}` (`route_to_human` on a cross-owner/claimed-dup merge, `no_approver` if the approver env is unset, `disabled`).
- **Auth**: same muso host auth + ctx-derived `--actor-identity` as #13; `--intercom-conv-id` is REQUIRED (it is the approval-ref). muso re-verifies the survivor is the customer's and every duplicate is unclaimed + same-name; per-actor/day merge cap + per-call dups bound.
- **When to use**: via the `customer-profile-consolidate` skill, to merge a customer's OWN unclaimed same-name duplicates into their profile. Preview then apply.

## Action Request Pattern

For customer write actions (credit claims, refunds, profile updates, disputes, **plaque/poster order fulfillment**), use `create_ticket` with structured formatting. See `skills/action-request/SKILL.md` for the full ticket format.

**Key points**:
- Tasks are created in the designated ClickUp list (901000600160) with `hydra-action-request` tag and the approval tier (`tier-1`, `tier-2`, `tier-3`)
- Include a machine-readable JSON block in the task description (between `---ACTION-REQUEST---` and `---END-ACTION-REQUEST---` markers)
- This does NOT add a new tool -- it uses `create_ticket` with structured content
- The Operations agent picks up tasks tagged `hydra-action-request` for review and execution

### Order fulfillment (Prodigi plaques/posters)

The `order-fulfillment` action type (Tier 1) is filed by the `order-fulfillment`
skill for Prodigi address-confirmation requests and customer order/shipping
questions. When `details.proposed_corrected_address` is present, `create_ticket`
stamps a deterministic Prodigi-rules `address_validation` block (≤40-char lines +
required fields) onto the ticket — non-blocking, ops-facing. No new tool; uses
`create_ticket`. Doctrine: `reference/orders-and-fulfillment.md`.

Caroline can look an order up herself with the **`order_lookup`** tool (#9 above) —
by internal id, order number, or Prodigi id — to read its status + shipping address.
For the **verified order owner**, she can also correct the shipping recipient with
**`order_address_update`** (#10): always a dry-run preview first, explicit customer
confirmation, then apply with `intercomConvId`. The wrapper refuses if the requester
isn't the owner — on any refusal, fall back to filing an `order-fulfillment` request
for the team. Never edit on a vendor's (Prodigi's) say-so — the corrected address must
come from the customer. If `order_lookup` returns `lookup_unavailable`, file the
request with whatever the message already contains.

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
