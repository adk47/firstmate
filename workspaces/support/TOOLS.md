# TOOLS.md -- support

## Allowed Tools (EXACTLY 19)

This agent has the most restricted tool set in HYDRA. Only these 19 tools are permitted, split into four groups:

- **Action tools (1-11, 17-18)** -- write or read customer-facing state. Implemented as plugin-registered tools via the `support-tools` OpenClaw plugin. The agent calls them by name; the plugin handles all HTTP, auth, and response filtering internally. The agent never sees API keys or raw HTTP responses.
- **Reference tools (12-13)** -- read-only semantic + BM25 retrieval against `workspaces/support/reference/*.md`, provided by openclaw's bundled memory-core via the per-agent `memorySearch` config (enabled on both edge and main profiles, indexing the read-only `reference/` subdirectory only). No writes; no customer-data persistence; no auto-recall.
- **Gated self-serve write tools (14-16)** -- `profiles_claim_self`, `credits_verify`, `profiles_consolidate`. Each shells `muso <verb> --actor-identity <verified-email>` through a thin bash wrapper; muso-cli's capability gate is the ownership/caps/audit boundary. Live on edge (the `*Enabled` flags in openclaw-edge.json are true); if a call returns `{disabled:true}`, fall back to a ticket.
- **Routing tool (19)** -- `support_action_router`, a read-only in-plugin registry that maps support intent + state to the router-suggested next step: close, ask for exact missing info, preview/apply a safe tool, or create a structured handoff.

## Authentication (CRITICAL -- shared across the admin read tools)

`profile_lookup`, `credits_search`, `profile_status`, `profile_analytics_status`, `dedupe_check`, `credit_verification_check`, and `order_lookup` use `MusoAdminClient` to call `api.muso.ai/api/v3/admin/*` with a JWT bearer token obtained via admin login (`MUSO_ADMIN_EMAIL` + `MUSO_ADMIN_PASSWORD` env vars). The client is GET-only and regex-allowlisted to exactly six read paths (`profile/search`, `profile/<id>`, `profile/<id>/analytics-status`, `profile/<id>/credits`, the `credit-requests` LIST endpoint -- never `credit-requests/<id>`, the item path the gated approve PUT lives under -- and the single-order read `orders/<id>`, never the `orders/<id>/...` write sub-paths or the bare `orders` list). The JWT is never returned to the agent and never logged.

`remove_credits` (tool 6) also depends on the same Muso admin auth -- it inherits via the JWT cache maintained by `muso-admin-api.sh`. Rotating `MUSO_ADMIN_EMAIL` / `MUSO_ADMIN_PASSWORD` breaks the bash wrapper too; flush `~/.cache/muso-admin-token.json` (or whatever `$TOKEN_CACHE` points to) after a rotation.

`create_ticket` uses a separate ClickUp API key. `subscription_status` reads the workspace subscription via the `muso` CLI (`teams list --email`), anchored to the verified Intercom contact email (not MusoAdminClient: the GET allowlist does not cover the team endpoints, and an account email does not resolve through the profile-search index).

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

- **Wraps**: `muso teams list --email <verified-email> --env prod --json` (GET /admin/team), which returns each workspace's `subscription` (`{plan, status, period, usersLimit}`) inline. Muso plans are workspace/team level, so the customer's email resolves to their workspace and its subscription.
- **Returns**: Structured JSON. On success: `{ ok: true, has_subscription, plan, status, period, seats_limit, workspace_id }` (`has_subscription: false` with `plan: null, status: "none"` for a workspace on no paid plan). On failure: `{ ok: false, reason: "rate_limited" | "owner_undetermined" | "not_found" | "lookup_unavailable", route_to_human? }`. Caroline reads the plan/status back to the customer, then points to Settings > Billing for changes; on a non-ok result she routes to a human or self-service.
- **Identity (anti-spoof)**: the lookup email is the verified Intercom contact (`deriveConvId` -> `getAuthorEmail`), NEVER an email the customer types. The server-side `--email` substring filter is re-narrowed to an exact (case-insensitive) email match inside the tool, so a customer can only ever see their OWN subscription.
- **Auth**: the `muso` CLI on edge (its own gated admin credential); the gateway never handles a token. Read-only (`teams list`), no approval flags.
- **Privacy**: only the subscription fields plus the workspace UUID are returned. Member emails/names and the workspace name from the team payload are NEVER echoed.
- **Rate limit**: 10 calls / 60 min per session.

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

### 6. profile_analytics_status

- **Bundles**: `GET /api/v3/admin/profile/search?keyword=<q>&limit=5` for resolution, `GET /api/v3/admin/profile/{id}` for direct UUID profile context, and `GET /api/v3/admin/profile/{id}/analytics-status` for the read-only analytics diagnosis.
- **Returns**: Structured JSON. On success: `{ found: true, profile: { id, name, verified, primary_role }, analytics: { status, initialized, ready, diagnosis, support_action, freshness, processing, metrics }, customer_provided_context }`. Status is one of `fresh`, `delayed`, `initializing`, `missing`, `stale`, `inconsistent`, or `unknown`. `support_action` tells you whether to answer from status, explain a delay, create `analytics-followup`, or route to human review.
- **Auth**: Muso admin JWT bearer (MusoAdminClient; GET-only, regex-allowlisted to the profile analytics-status read path).
- **Rate limit**: 10/min per session.
- **Parameters** (one of, precedence top-to-bottom): `profile_id`, `profile_url`, `email` (used for lookup, never echoed back), `name`. Optional: `source_platform`, `track_title`, `release_title` for the support packet.
- **When to use**: AFTER `profile_status` and, when plan/seat could explain the issue, `subscription_status`. Use it for analytics, streams, stale numbers, or missing-data complaints before deciding whether to close or file `analytics-followup`.
- **Safety model**: read-only only. It never triggers refreshes, reprocessing, linking, or any database mutation. Never quote exact refresh cadence to the customer from this tool.

### 7. remove_credits

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

### 8. dedupe_check

- **Wraps**: read-only verification for a customer profile-merge request. Issues `GET /api/v3/admin/profile/{id}` (+ `/credits`) for the survivor and each duplicate via `MusoAdminClient`, and a read-only Intercom `GET /conversations/{id}` to fetch the contact's real `source.author.email`. No writes, no merge, no tier-2 endpoint, no `exec`.
- **Returns**: PII-safe structured verdict -- `{ verified, owner_undetermined, impersonation_flag, owns_survivor, survivor_claimed_workspace_count, cluster_size_check: "not_performed", duplicates: [{ profile_id, claim_state, credit_count, shared_external_id: "none"|"weak", matched_external_id_sources: [], shared_track_count, compared_track_count, shared_track_ratio }], notes: [], verified_at }`. Emits ONLY enums/booleans/UUIDs/counts and external-id PLATFORM names (never a raw id) -- never a third-party workspace email.
- **conv-id**: derived in-plugin from `ctx.sessionId` (NOT an agent parameter), so the anti-spoof anchor can't be pointed at another conversation.
- **Auth**: Muso admin JWT (same `MusoAdminClient`, GET-only) + `MUSOAI_INTERCOM_TOKEN` (read from env). Token absent / conv-id underivable / no contact email -> **fails closed** (`owner_undetermined`).
- **Rate limit**: 10 per session (60-minute window); caps duplicates at 5 per call.
- **Used by**: the `customer-profile-dedupe` skill. The tool produces evidence ONLY -- Caroline files a `profile-merge` ticket via `create_ticket`; Operations executes the irreversible merge.

### 9. credit_verification_check

- **Wraps**: read-only lookup of a customer's `user_verification_needed` (UVN) credits. Anchors ownership to the contact's real `source.author.email` via a read-only Intercom `GET /conversations/{id}`, confirms ownership against `GET /api/v3/admin/profile/{id}` (search-by-email when no profile is named), then `GET /api/v3/admin/credit-requests?profilesIds=<id>&status=user_verification_needed`. No writes, no approve/reject, no tier-2 endpoint, no `exec`. The `MusoAdminClient` is GET-only, so it cannot reach the gated `PUT /admin/credit-requests` approve path that shares the prefix.
- **Returns**: PII-safe structured verdict -- `{ verified_owner, owner_undetermined, impersonation_flag, profile_id, uvn_credits: [{ cr_id, role, track_title, artist, isrc }], count, notes: [] }`. Track/artist strings are injection-stripped and length-capped. When the feature flag is off: `{ disabled: true, note }` (fall back to a normal ticket). `impersonation_flag` is only meaningful when `requesterEmail` was passed -- when it wasn't, the verdict carries a "no impersonation cross-check performed" note so `false` is never read as "identity cross-check passed".
- **conv-id**: derived in-plugin from `ctx.sessionId` (NOT an agent parameter), so the anti-spoof anchor can't be pointed at another conversation. A profile a customer names is ALWAYS re-verified for ownership before any pending credit is surfaced.
- **Auth**: Muso admin JWT (`MusoAdminClient`, GET-only) + `MUSOAI_INTERCOM_TOKEN` (env). Token absent / conv-id underivable / no contact email / not-owner / typed-email mismatch (`impersonation_flag`) / shared profile (multiple claimed workspaces -- the sole-claimed-workspace ownership rule, same as `dedupe_check`) -> **fails closed** (`owner_undetermined`, empty list).
- **Rate limit**: 10 per session (60-minute window).
- **Used by**: the `customer-credit-verification` skill. The tool produces evidence ONLY -- Caroline asks the customer for proof and, when warranted, files a `credit-verify` recommend-approve ticket via `create_ticket`; a human executes the gated approval. This read tool itself never approves or rejects -- the autonomous approve path is the separate gated `credits_verify` (#14), used ONLY for the catalog-corroborated case; everything else stays a human decision and Caroline never rejects.

### 10. order_lookup

- **Wraps**: `GET /api/v3/admin/orders/{ref}` via `MusoAdminClient` (GET-only, allowlisted). `ref` is any of: the internal order UUID (Prodigi merchantReference), the order number, or Prodigi's own order id – the backend resolves all three.
- **Returns**: PII-scoped structured JSON. On success: `{ found: true, order: { id, orderNumber, prodigiOrderId, status, createdAt, items: [...], shipment: { address, phoneNumber, trackingNumber, trackingUrl } } }`. On failure: `{ found: false, reason: "missing_input" | "not_found" | "rate_limited" | "lookup_unavailable" }`.
- **Scope**: surfaces the fulfilment-relevant fields ONLY. The shipping address + recipient phone ARE the working data (this tool exists to confirm/correct them for Prodigi). **Payment data is never returned.**
- **Auth**: Muso admin JWT bearer (same client as the profile tools; GET-only, allowlisted to the single-order read path).
- **Rate limit**: 10/min per session.
- **Used by**: the `order-fulfillment` skill (vendor-lane Prodigi address requests + customer order/shipping questions). See `reference/orders-and-fulfillment.md`.

### 11. order_address_update

- **Wraps**: `PUT /api/v3/admin/orders/{id}` via the bash wrapper at `workspaces/support/skills/order-fulfillment/scripts/update-order-address.sh` (NOT `MusoAdminClient` – same wrapper-as-boundary model as `remove_credits`). The TS tool is a typed dispatcher; the wrapper is the ownership + audit boundary.
- **Returns**: Structured JSON. Dry-run: `{ ok: true, mode: "dry-run", applied: false, order_id, order_status, current_address, proposed, editable }`. Apply: `{ ok: true, mode: "apply", applied: true, order_id, http_status: 200, applied_recipient }`. Refusal: `{ ok: false, error: <key> }` where `<key>` ∈ `address_invalid` | `intercom_conv_id_required` | `owner_mismatch` | `owner_undetermined` | `intercom_email_mismatch` | `order_lookup_failed` | `dry_run_required` | `cap_exceeded_per_day` | `apply_failed` | `rate_limited`.
- **Auth**: the wrapper uses `muso-admin-api.sh`'s JWT cache (same Muso admin auth as `remove_credits`). The agent never sees the token.
- **Safety model (in the wrapper, independent of the LLM)**: resolves the order, then requires the requester email to equal the order's owner email AND to match the Intercom contact's `source.author.email`; validates the address (≤40-char lines + required fields); dry-run-then-apply (apply needs a matching `would_update` audit row from the last 15 min); audit log at `/var/log/openclaw/order-fulfillment.jsonl`; per-customer-per-day cap. Fails closed and routes to a ticket on any gate failure.
- **Required fields**: `order_ref` (UUID / order number / Prodigi id), `customer_email` (the verified owner), `recipient` ({ name, phone, line1, line2?, city, state?, postcode, country, email? }). `intercomConvId` required when `apply: true`.
- **Rate limit**: 5 per session (60-minute window).
- **Used by**: the `order-fulfillment` skill (customer lane only – never on a vendor's say-so). See `reference/orders-and-fulfillment.md`.

### 12. memory_search

- **Wraps**: openclaw's bundled memory-core hybrid retrieval (vector + BM25) against the per-agent qmd index built from `workspaces/support/reference/*.md`.
- **Returns**: Ranked chunks with file path, line range, and similarity score.
- **Auth**: None at agent level (the embedding provider auth – OpenRouter-proxied OpenAI `text-embedding-3-small` – is resolved by openclaw runtime from `hydra-secrets`/`/OPENROUTER_API_KEY`; never visible to the agent).
- **Indexed scope**: `reference/` subdirectory only. CI invariant pins `extraPaths == ["reference"]` on both edge and main profiles. Customer-session transcripts, tickets, and api-logs are explicitly NOT indexed.
- **Rate limit**: governed by openclaw memory runtime; no application-level cap.
- **PII filter**: not needed – the indexed corpus is read-only doctrine, no customer data.
- **When to use**: "is there an active incident affecting this topic?", "what's the doctrine for X?", and anywhere the answer isn't already in loaded context (SOUL.md / TOOLS.md / common-issues row #N).

### 13. memory_get

- **Wraps**: openclaw's bundled memory-core point-lookup by note id.
- **Returns**: The full text of a single indexed chunk by id (typically followed up from a `memory_search` hit).
- **Auth**: same as `memory_search`.
- **When to use**: when a `memory_search` result snippet is truncated and you need the full chunk before responding.

### 14. profiles_claim_self

- **Wraps**: `muso profiles claim-self --actor-identity <verified-email>` via the bash wrapper at `workspaces/support/skills/customer-profile-claim/scripts/claim-self.sh` (the muso capability gate is the ownership/caps/audit boundary; the wrapper is thin). Gated WRITE counterpart of the read-only checks.
- **Returns**: `{ok, mode, claim_id, profile_id, status}` (status applied|dry_run|noop) or `{ok:false, error}` (`route_to_human` on a non-owner claim, `disabled` until enabled).
- **Auth**: muso uses the host login (`MUSO_ADMIN_*`, `MUSO_STATE_DIR`); the `--actor-identity` is the ctx-derived verified Intercom author email (`deriveConvId`+`getAuthorEmail`), NEVER a model arg. Per-actor caps + ownership re-verify are server-side in muso-cli.
- **When to use**: via the `customer-profile-claim` skill, to verify a customer's OWN pending profile claim. Preview (`apply:false`) then apply.

### 15. credits_verify

- **Wraps**: `muso credits verify --actor-identity <verified-email>` (APPROVAL-tier PUT: also `--yes --confirmed-by <MUSO_CAPABILITY_APPROVER> --approval-ref <conv-id>`) via `workspaces/support/skills/customer-credit-verification/scripts/verify-credit.sh`. The WRITE counterpart of `credit_verification_check` (#8).
- **Returns**: `{ok, mode, request_id, profile_id, status}` or `{ok:false, error}` (`route_to_human` when corroboration/ownership fails, `no_approver` if the approver env is unset, `disabled`).
- **Auth**: same muso host auth + ctx-derived `--actor-identity` as #13; `--intercom-conv-id` is REQUIRED (it is the approval-ref). muso re-verifies ownership + deterministic catalog corroboration server-side and refuses without it; per-actor/day approval cap.
- **When to use**: via the `customer-credit-verification` skill, AFTER the read-only check + the customer's proof, to approve their OWN corroborated pending credit. Preview then apply.

### 16. profiles_consolidate

- **Wraps**: `muso profiles consolidate --actor-identity <verified-email>` (APPROVAL-tier: `--yes --confirmed-by <MUSO_CAPABILITY_APPROVER> --approval-ref <conv-id>`) via `workspaces/support/skills/customer-profile-consolidate/scripts/consolidate.sh`. The WRITE counterpart of `dedupe_check` (#7).
- **Returns**: `{ok, mode, survivor, dup_ids, status}` or `{ok:false, error}` (`route_to_human` on a cross-owner/claimed-dup merge, `no_approver` if the approver env is unset, `disabled`).
- **Auth**: same muso host auth + ctx-derived `--actor-identity` as #13; `--intercom-conv-id` is REQUIRED (it is the approval-ref). muso re-verifies the survivor is the customer's and every duplicate is unclaimed + same-name; per-actor/day merge cap + per-call dups bound.
- **When to use**: via the `customer-profile-consolidate` skill, to merge a customer's OWN unclaimed same-name duplicates into their profile. Preview then apply.

### 17. founding_status

- **Wraps**: `muso founding status --email <verified-email> --env prod --json` (GET /admin/team; the founder envelope lives on the list items). Same plugin/execFile transport and anti-spoof anchor as `subscription_status` (#3).
- **Returns**: `{ ok: true, founder_active, ever_founder, since_year, lapsed_at, workspace_id, plan, sub_status }` or `{ ok: false, reason }`. `ever_founder: true` + `founder_active: false` = a LAPSED founder (buy-back candidate); `ever_founder: false` = never in the program.
- **Identity (anti-spoof)**: verified Intercom contact email only (`deriveConvId` -> `getAuthorEmail`); the CLI exact-matches the workspace email server-side and refuses ambiguity. Read-only.
- **Rate limit**: 10 calls / 60 min per session.
- **When to use**: BEFORE discussing founding perks, lapse, or buy-back. Doctrine: `reference/founding-member.md`.

### 18. founding_buyback_link

- **Wraps**: `muso founding buyback-checkout --email <verified-email> --requester <verified-email> --env prod --json` (POST /admin/founding/buyback/checkout). Mints ONE ~24h Stripe Checkout URL bundling a Pro-annual subscription + the one-off arrears back to the 2026-06-30 program anchor; payment reinstates (or late-buys-in) automatically via the Stripe webhook.
- **Returns**: `{ ok: true, url, workspace_id, arrears_months, arrears_cents, since_year, seats, expires_note }` or `{ ok: false, reason: "not_confirmed" | "already_founder" | "not_found" | "ambiguous_workspace" | "no_owner" | "rate_limited" | "owner_undetermined" | "lookup_unavailable" }`, or the `{ ok: false, disabled: true }` sentinel while the `foundingBuybackEnabled` dark-ship flag is off (fall back to flagging for the team). The returned URL is pinned to the `https://checkout.stripe.com/` origin in-plugin. Quote ONLY the returned figures.
- **Identity (anti-spoof)**: verified Intercom contact email only -- there is no target parameter, so the link can never be minted for another account. Requires the explicit `confirm: true` parameter (only after the customer asks to join/rejoin). The CLI's policy gate audits the write and enforces a per-actor/day mint cap; the mint itself changes no account state.
- **Rate limit**: 3 calls / 60 min per session.
- **When to use**: via the founding-member buy-back path in `reference/founding-member.md`. Free/comp reinstates are NOT this tool -- those stay a flag for the team (ops runs the approval-tier `muso founding reinstate`).

### 19. support_action_router

- **Wraps**: a deterministic read-only registry inside `support-tools`. No upstream API call, no shell, no customer-data lookup, and no write.
- **Parameters**: `intent` plus optional `state`. Supported intents: `analytics_data_complaint`, `credit_verification`, `profile_claim`, `profile_duplicates`, `remove_wrong_credits`, `order_fulfillment`, `founding_member`, `billing_cancel_refund`, `catalog_metadata_repair`, `login_email_verification`, `account_profile_change`. Supported states: `new_request`, `read_ok`, `missing_info`, `preview_ok`, `customer_confirmed`, `applied_ok`, `tool_refused`, `tool_disabled`, `loop_detected`.
- **Returns**: `{ ok, intent, state, availability, next, live_tools, planned_tools, human_gated_writes, denied_tools, sequence, close_when, handoff_when, missing_info, tags, guardrails }`.
- **When to use**: before choosing a lane for multi-step support requests, especially when the customer asks for an action (credits, profile, billing, orders, founding, metadata, login). Use the returned `next` to decide whether to call a read tool, run a skill, ask for precise missing info, preview/apply a safe write, close, or file a structured handoff.
- **Safety model**: this tool does NOT authorize anything by itself. The actual read/write tool remains the security boundary. A clean successful write resolves the case; do not also file a ticket. Any `disabled`, refusal, cross-owner, ambiguity, or `route_to_human` result becomes a structured handoff.

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
required fields) onto the ticket – non-blocking, ops-facing. No new tool; uses
`create_ticket`. Doctrine: `reference/orders-and-fulfillment.md`.

Caroline can look an order up herself with the **`order_lookup`** tool (#9 above) –
by internal id, order number, or Prodigi id – to read its status + shipping address.
For the **verified order owner**, she can also correct the shipping recipient with
**`order_address_update`** (#10): always a dry-run preview first, explicit customer
confirmation, then apply with `intercomConvId`. The wrapper refuses if the requester
isn't the owner – on any refusal, fall back to filing an `order-fulfillment` request
for the team. Never edit on a vendor's (Prodigi's) say-so – the corrected address must
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
