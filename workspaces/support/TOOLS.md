# TOOLS.md -- support

## Allowed Tools (EXACTLY 19)

This agent has the most restricted tool set in HYDRA. Only these 19 tools are permitted, split into five groups:

- **Action tools (1-8, 11-12, 14, 17)** -- write or read customer-facing state. Implemented as plugin-registered tools via the `support-tools` OpenClaw plugin. The agent calls them by name; the plugin handles all HTTP, auth, and response filtering internally. The agent never sees API keys or raw HTTP responses.
- **Reference tools (9-10)** -- read-only semantic + BM25 retrieval against `workspaces/support/reference/*.md`, provided by openclaw's bundled memory-core via the per-agent `memorySearch` config (indexing the read-only `reference/` subdirectory only). No writes; no customer-data persistence; no auto-recall.
- **Gated self-serve write tools (15-16)** -- `retention_offer_apply`, `cancel_subscription`. Each shells a `muso` verb anchored to the verified Intercom identity; muso-cli's capability gate is the ownership/caps/audit boundary.
- **Routing tool (13)** -- `support_action_router`, a read-only in-plugin registry that maps support intent + state to the router-suggested next step.

- **Own-request reads (18-19)** -- `credit_verification_check`, `profile_claim_status`. Read-only, fail closed without a signed-in contact, return that customer's own rows only, and are used only as the `verification-handoff` skill's "one read" (2026-11-12).

**Not Caroline's (captain 2026-10-28 12:1xZ / 12:3xZ):** credit verification, credit removal, documents, claims and merges. `remove_credits`, `dedupe_check`, `profile_credits_status`, `profiles_claim_self`, `credits_verify` and `profiles_consolidate` are denied on edge (`profile_credits_status` because it looks up any profile typed in the conversation and scans for duplicates); those questions go through `create_ticket` per the `verification-handoff` skill.

## Authentication (CRITICAL -- shared across the admin read tools)

`profile_lookup`, `credits_search`, `profile_status`, `profile_analytics_status` and `order_lookup` use `MusoAdminClient` to call `api.muso.ai/api/v3/admin/*` with a JWT bearer token obtained via admin login (`MUSO_ADMIN_EMAIL` + `MUSO_ADMIN_PASSWORD` env vars). The client is GET-only and regex-allowlisted to exactly eight read paths (`profile/search`, `profile/<id>`, `profile/<id>/analytics-status`, `profile/<id>/credits`, the `credit-requests` LIST endpoint -- never `credit-requests/<id>`, the item path the gated approve PUT lives under -- the single-order read `orders/<id>`, never the `orders/<id>/...` write sub-paths or the bare `orders` list, and the claiming reads `claiming` LIST + `claiming/<id>` -- never the `claiming/<id>/verify|reject|revert` write sub-paths). The JWT is never returned to the agent and never logged.

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
- **Returns**: Structured JSON. On success: `{ submitted: true, ticket_id, sla, action_type, tier }` (`sla` null + `customer_timing` for credit/claim/merge kinds: quote no timeframe), plus `updated_existing: true` when appended to an existing ticket. On failure: `{ submitted: false, reason: "rate_limited" | "queue_busy" | "invalid_input" }`. Caroline composes the customer-facing reply from these fields; never says "ticket" / "ClickUp" verbatim.
- **Dedupe**: a repeat call with the same `actionType` in the same conversation (or matching an open ticket for the same customer email + action from the last 7 days) appends a follow-up comment to the existing ticket. Follow-ups have their own budget (5 per session) and do NOT consume the 2-per-session create allowance.
- **Auth**: ClickUp API key (handled by plugin, never visible to agent)
- **Rate limit**: 2 ticket creations per session (60-minute window); 5 follow-up appends per session
- **Required fields**: `actionType`, `customerEmail`, `summary`, `conversationSummary`
- **Optional fields**: `titleGist` (≤60-char concrete gist for the title; falls back to `summary`), `customerProfileId`, `details` (action-specific key-value pairs)
- **Auto-derived**: title (`[{action}] {gist} – {email}`), priority (from tier), due date (from tier SLA in business days), tags (`hydra-action-request`, `tier-N`, `action:{type}`, `team:growth|catalog`, `escalation:*` when `details.escalation_reason` is set)

### 5. profile_status

- **Bundles**: admin `profile/search` (resolution), `profile/{id}`, `profile/{id}/credits?limit=20`.
- **Returns**: Structured JSON. On success: `{ found: true, profile: { id, name, verified, isClaimed, primary_role, credits_count, workspaces: [{isClaimed, matchesVerifiedContact}], claimed_workspace_count, owner_matches_verified_contact: true|false|null, owner_check, knownAsNames: [] }, latest_credits: [top 3 sorted by release_date desc], latest_credit_date }`. On failure: `{ found: false, reason: "no_match" | "multiple_matches" | "lookup_unavailable" | "missing_input" | "rate_limited", ... }`. No workspace email is returned, only booleans against the verified Intercom contact; `owner_matches_verified_contact: null` = contact unverified (`owner_check`), treat as not theirs. The removal wrapper re-verifies ownership.
- **Auth**: Muso admin JWT bearer (MusoAdminClient; GET-only, regex-allowlisted to the 3 profile endpoints).
- **Rate limit**: 10/min per session
- **Parameters** (one of, precedence top-to-bottom): `profile_id` (UUID), `profile_url` (full credits.muso.ai URL), `email` (used for lookup, never echoed back), `name` (display name)
- **PII filter**: email, phone, address, payment details are NEVER returned

### 6. profile_analytics_status

- **Bundles**: `GET /api/v3/admin/profile/search?keyword=<q>&limit=5` for resolution, `GET /api/v3/admin/profile/{id}` for direct UUID profile context, and `GET /api/v3/admin/profile/{id}/analytics-status` for the read-only analytics diagnosis.
- **Returns**: Structured JSON. On success: `{ found: true, profile: { id, name, verified, primary_role }, analytics: { entitled: true, grant, status, initialized, ready, diagnosis, support_action, freshness, processing, cube_status, metrics }, customer_provided_context }`. Status is one of `fresh`, `delayed`, `initializing`, `missing`, `stale`, `inconsistent`, `warming`, or `unknown`. `support_action` tells you whether to answer from status, explain a delay, create `analytics-followup`, retry after the cache warms, or route to human review.
- **`data_freshness` is the data-freshness read**: `{ source, is_current, is_current_basis, last_updated_at, age_hours, stale_after_hours, last_run: { date, updated_at, tracks_in_progress, tracks_updated, tracks_total }, known_issue: { measured: false, reason } }`. It answers "is my data up to date" and "when did it last update" with dates only, never a stream figure, and names its `source`. `is_current` is the backend's own threshold, and `null` means not measured. `known_issue.measured` is `false` today: no known-issue source is reachable, so never tell a customer there is or is not a known issue.
- **On deny** the same call returns `analytics: { entitled: false, reason, route_to_human, support_action, diagnosis }` and no status or metrics at all. `support_action` is then `explain_pro_requirement` (`no_active_seat`, `profile_not_in_workspace`) or `human_review` (`owner_undetermined`, `account_not_resolved`, `check_unavailable`).
- **`metrics` is entitlement-gated output, not general context.** This read answers whether analytics are healthy; it does not decide whether the customer may be told the numbers. Diagnose freshness from `status` / `support_action` / `measured` freely – but do not put any value from `metrics` in a reply until `analytics.entitled` is `true`.
- **`measured` is the field that matters most.** The analytics metrics are served from a cached cube read. When that cache is cold nothing is read, and the tool reports `metrics.measured: false` with every metric and `ready` set to `null` rather than `0`/`false`. A null is not a zero: it means nobody looked. The tool already retried once before telling you this, so treat `warming` as "ask again in a moment", never as "this customer has no data". Reporting an unmeasured cube as zeros is what caused a false escalation on 2026-08-18.
- **Auth**: Muso admin JWT bearer (MusoAdminClient; GET-only, regex-allowlisted to the profile analytics-status read path).
- **Rate limit**: 10/min per session.
- **Parameters** (one of, precedence top-to-bottom): `profile_id`, `profile_url`, `email` (used for lookup, never echoed back), `name`. Optional: `source_platform`, `track_title`, `release_title` for the support packet.
- **When to use**: AFTER `profile_status` and, when plan/seat could explain the issue, `subscription_status`. Use it for analytics, streams, stale numbers, or missing-data complaints before deciding whether to close or file `analytics-followup`.
- **Safety model**: read-only only. It never triggers refreshes, reprocessing, linking, or any database mutation. Never quote exact refresh cadence to the customer from this tool.

### 7. order_lookup

- **Wraps**: `GET /api/v3/admin/orders/{ref}` via `MusoAdminClient` (GET-only, allowlisted). `ref` is any of: the internal order UUID (Prodigi merchantReference), the order number, or Prodigi's own order id – the backend resolves all three.
- **Today: `{ owner_verified: false, owner_check, order: { status, hold } }` for EVERY caller** (Intercom Identity Verification is off). Give no address/phone/tracking/items; a human confirms addresses. Once IV is on: full order only to the order's own verified contact.
- **Returns**: PII-scoped structured JSON. For the verified owner: `{ found: true, owner_verified: true, order: { id, orderNumber, prodigiOrderId, status, createdAt, items: [...], shipment: { address, phoneNumber, trackingNumber, trackingUrl }, taxId: { present, type }, hold } }`. On failure: `{ found: false, reason: "missing_input" | "not_found" | "rate_limited" | "lookup_unavailable" }`.
- **`hold`**: non-null ONLY on `NEEDS_TAX_ID` / `NEEDS_CONTACT_INFO`, as `{ status, missing: ["taxId"|"phone"], taxIdLabel, countryCode }`. The admin API carries no hold reason, so this is DERIVED -- from the hold STATUS, never from `shipment.phoneNumber`, which is the Prodigi recipient's phone and is null on every held order (never sent to Prodigi) whatever we hold in `details.shipping.phone`. An empty `missing` means the reason is not visible here, so file a ticket rather than guess. `taxIdLabel` is the destination's own name for the id ("RFC or CURP", "CPF or CNPJ", "RNC").
- **Scope**: fulfilment fields only (address + phone, for the owner, to confirm/correct for Prodigi). **Never payment data.**
- **Auth**: Muso admin JWT bearer (same client as the profile tools; GET-only, allowlisted to the single-order read path).
- **Rate limit**: 10/min per session.
- **Used by**: the `order-fulfillment` skill (vendor-lane Prodigi address requests + customer order/shipping questions). See `reference/orders-and-fulfillment.md`.

### 8. order_address_update

- **Wraps**: `PUT /api/v3/admin/orders/{id}` via the bash wrapper at `workspaces/support/skills/order-fulfillment/scripts/update-order-address.sh` (NOT `MusoAdminClient`; the wrapper is the boundary). The TS tool is a typed dispatcher; the wrapper is the ownership + audit boundary.
- **Returns**: Structured JSON. Dry-run: `{ ok: true, mode: "dry-run", applied: false, order_id, order_status, current_address, proposed, editable }`. Apply: `{ ok: true, mode: "apply", applied: true, order_id, http_status: 200, applied_recipient }`. Refusal: `{ ok: false, error: <key> }` where `<key>` ∈ `address_invalid` | `intercom_conv_id_required` | `owner_mismatch` | `owner_undetermined` | `intercom_email_mismatch` | `order_lookup_failed` | `dry_run_required` | `cap_exceeded_per_day` | `apply_failed` | `rate_limited`.
- **Auth**: the wrapper uses `muso-admin-api.sh`'s JWT cache (the same Muso admin auth). The agent never sees the token.
- **Safety model (in the wrapper, independent of the LLM)**: resolves the order, then requires the requester email to equal the order's owner email AND to match the Intercom contact's `source.author.email`; validates the address (≤40-char lines + required fields); dry-run-then-apply (apply needs a matching `would_update` audit row from the last 15 min); audit log at `/var/log/openclaw/order-fulfillment.jsonl`; per-customer-per-day cap. Fails closed and routes to a ticket on any gate failure.
- **Owner gate (in the tool, before the wrapper)**: like #7, the tool refuses `owner_undetermined` (`identity_verification_off`) to every caller until Intercom IV, and `owner_mismatch` when `customer_email` is not the verified contact. It shows no order detail on a refusal, so file the `order-fulfillment` request.
- **Required fields**: `order_ref` (UUID / order number / Prodigi id), `customer_email` (the verified owner), `recipient` ({ name, phone, line1, line2?, city, state?, postcode, country, email?, tax_id?, tax_id_type? }). `intercomConvId` required when `apply: true`.
- **Phone**: shape-checked to at least 7 digits (the backend refuses an undialable number and holds the order as `NEEDS_CONTACT_INFO`), reported as `address_invalid` with field `Phone number` -- present-but-too-short is distinct from absent.
- **`tax_id`**: the customs id for MX, BR, CL, AR, PE, CO, EC and DO. Shape-checked against the DESTINATION country before the wrapper runs (the backend validates the same way and 400s on a mismatch), so an id valid for another country is refused with `tax_id_invalid`. Supplying it releases a `NEEDS_TAX_ID` hold on save.
- **Rate limit**: 5 per session (60-minute window).
- **Used by**: the `order-fulfillment` skill (customer lane only – never on a vendor's say-so). See `reference/orders-and-fulfillment.md`.

### 9. memory_search

- **Wraps**: openclaw's bundled memory-core hybrid retrieval (vector + BM25) against the per-agent qmd index built from `workspaces/support/reference/*.md`.
- **Returns**: Ranked chunks with file path, line range, and similarity score.
- **Auth**: None at agent level (the embedding provider auth is resolved by the openclaw runtime from `hydra-secrets`; never visible to the agent).
- **Indexed scope**: `reference/` subdirectory only. CI invariant pins `extraPaths == ["reference"]` on both edge and main profiles. Customer-session transcripts, tickets, and api-logs are explicitly NOT indexed.
- **Rate limit**: governed by openclaw memory runtime; no application-level cap.
- **PII filter**: not needed – the indexed corpus is read-only doctrine, no customer data.
- **When to use**: "is there an active incident affecting this topic?", "what's the doctrine for X?", and anywhere the answer isn't already in loaded context (SOUL.md / TOOLS.md / common-issues row #N).

### 10. memory_get

- **Wraps**: openclaw's bundled memory-core point-lookup by note id.
- **Returns**: The full text of a single indexed chunk by id (typically followed up from a `memory_search` hit).
- **Auth**: same as `memory_search`.
- **When to use**: when a `memory_search` result snippet is truncated and you need the full chunk before responding.

### 11. founding_status

- **Wraps**: `muso founding status --email <verified-email> --env prod --json` (GET /admin/team; the founder envelope lives on the list items). Same plugin/execFile transport and anti-spoof anchor as `subscription_status` (#3).
- **Returns**: `{ ok: true, founder_active, ever_founder, since_year, lapsed_at, workspace_id, plan, sub_status }` or `{ ok: false, reason }`. `ever_founder: true` + `founder_active: false` = a LAPSED founder (buy-back candidate); `ever_founder: false` = never in the program.
- **Identity (anti-spoof)**: verified Intercom contact email only (`deriveConvId` -> `getAuthorEmail`); the CLI exact-matches the workspace email server-side and refuses ambiguity. Read-only.
- **Rate limit**: 10 calls / 60 min per session.
- **When to use**: BEFORE discussing founding perks, lapse, or buy-back. Doctrine: `reference/founding-member.md`.

### 12. founding_buyback_link

- **Wraps**: `muso founding buyback-checkout --email <verified-email> --requester <verified-email> --env prod --json` (POST /admin/founding/buyback/checkout). Mints ONE ~24h Stripe Checkout URL bundling a Pro-annual subscription + the one-off arrears back to the 2026-06-30 program anchor; payment reinstates (or late-buys-in) automatically via the Stripe webhook.
- **Returns**: `{ ok: true, url, workspace_id, arrears_months, arrears_cents, since_year, seats, expires_note }` or `{ ok: false, reason: "not_confirmed" | "already_founder" | "not_found" | "ambiguous_workspace" | "no_owner" | "rate_limited" | "owner_undetermined" | "lookup_unavailable" }`, or the `{ ok: false, disabled: true }` sentinel while the `foundingBuybackEnabled` dark-ship flag is off (fall back to flagging for the team). The returned URL is pinned to the `https://checkout.stripe.com/` origin in-plugin. Quote ONLY the returned figures.
- **Identity (anti-spoof)**: verified Intercom contact email only -- there is no target parameter, so the link can never be minted for another account. Requires the explicit `confirm: true` parameter (only after the customer asks to join/rejoin). The CLI's policy gate audits the write and enforces a per-actor/day mint cap; the mint itself changes no account state.
- **Rate limit**: 3 calls / 60 min per session.
- **When to use**: via the founding-member buy-back path in `reference/founding-member.md`. Free/comp reinstates are NOT this tool -- those stay a flag for the team (ops runs the approval-tier `muso founding reinstate`).

### 13. support_action_router

- **Wraps**: a deterministic read-only registry inside `support-tools`. No upstream API call, no shell, no customer-data lookup, and no write.
- **Parameters**: `intent` plus optional `state`. Supported intents: `analytics_data_complaint`, `credit_verification`, `profile_claim`, `profile_duplicates`, `remove_wrong_credits`, `remove_own_credit`, `order_fulfillment`, `founding_member`, `billing_cancel_refund`, `catalog_metadata_repair`, `login_email_verification`, `account_profile_change`. Supported states: `new_request`, `read_ok`, `missing_info`, `preview_ok`, `customer_confirmed`, `applied_ok`, `tool_refused`, `tool_disabled`, `loop_detected`.
- **Returns**: `{ ok, intent, state, availability, next, live_tools, planned_tools, human_gated_writes, denied_tools, sequence, close_when, handoff_when, missing_info, tags, guardrails }`.
- **When to use**: before choosing a lane for multi-step support requests, especially when the customer asks for an action (credits, profile, billing, orders, founding, metadata, login). Use the returned `next` to decide whether to call a read tool, run a skill, ask for precise missing info, preview/apply a safe write, close, or file a structured handoff.
- **Safety model**: this tool does NOT authorize anything by itself. The actual read/write tool remains the security boundary. A clean successful write resolves the case; do not also file a ticket. Any `disabled`, refusal, cross-owner, ambiguity, or `route_to_human` result becomes a structured handoff.

### 14. retention_offer_check

- **Wraps**: `muso subscription retention-offer --email <verified-email> --env prod --json` (read-only). Same plugin/execFile transport and anti-spoof anchor as `subscription_status` (#3).
- **Returns**: `{ ok: true, eligible, offer: { id, description, percent_off, duration_months } | null }` -- `offer: null` means ineligible (no active Stripe sub, or already discounted); fall back to the free Lite plan. On failure: `{ ok: false, reason: "no_offer" | "past_due_billing" | "vip_manual" | "not_stripe" | "no_active_subscription" | "ambiguous_workspace" | "not_found" | "rate_limited" | "owner_undetermined" | "lookup_unavailable", route_to_human? }`.
- **Identity (anti-spoof)**: verified Intercom contact email only (`deriveConvId` -> `getAuthorEmail`); the CLI exact-matches the workspace email server-side and refuses ambiguity.
- **Rate limit**: 10 calls / 60 min per session.
- **When to use**: via the `refund-retention` skill, once cancel/refund intent is clear and BEFORE offering the 50% save. Quote ONLY the returned `offer.description`, never a figure you computed.

### 15. retention_offer_apply

- **Wraps**: `muso subscription apply-retention-offer --email <verified-email> --requester <verified-email> --env prod --json` (gated WRITE). The coupon is resolved SERVER-SIDE from the same eligibility check `retention_offer_check` reads -- neither the model nor the plugin can choose one. muso-cli's policy gate audits the write.
- **Returns**: `{ ok: true, applied: true, offer: { description, ... } }` -- confirm with EXACTLY the returned description. On failure: same reason vocabulary as #20 plus `not_confirmed` and `apply_unverified` (success without the offer envelope routes to a human rather than inviting an invented figure), or `{ ok: false, disabled: true }` while `retentionOfferEnabled` is off (offer the free Lite plan and flag for the team).
- **Identity (anti-spoof)**: verified Intercom contact email only; requires the explicit `confirm: true` parameter, ONLY after the customer explicitly accepts the offer in this conversation.
- **Rate limit**: 3 calls / 60 min per session.
- **When to use**: via the `refund-retention` skill, after explicit customer acceptance of the quoted offer. Never apply speculatively.

### 16. cancel_subscription

- **Wraps**: `muso subscription cancel --email <verified-email> --requester <verified-email> --reason "Customer request via support (Caroline)" --yes --env prod --json` (gated dangerous-tier WRITE, audited server-side). Active subs cancel at PERIOD END (reversible until then); `past_due` cancels immediately server-side. NO money moves -- refunds stay on the gated Operations path.
- **Returns**: `{ ok: true, cancelled: true, mode: "period_end" | "immediate", access_until }` -- tell the customer the `access_until` date when present. On failure: same reason vocabulary as #20 plus `not_confirmed`, or `{ ok: false, disabled: true }` while `cancelSubscriptionEnabled` is off (guide to Settings > Billing or flag for the team).
- **Identity (anti-spoof)**: verified Intercom contact email only; requires the explicit `confirm: true` parameter, ONLY after the customer explicitly asked to cancel AND declined the retention saves.
- **Rate limit**: 3 calls / 60 min per session.
- **When to use**: via the `refund-retention` skill, as the cancel-only exit after the save hierarchy is exhausted. NEVER on the refund branch -- Operations executes cancel+refund together there (`subscription-refund` ticket instead).

## Action Request Pattern

For customer write actions (credit claims, refunds, profile updates, disputes, **plaque/poster order fulfillment**), use `create_ticket` with structured formatting. See `skills/action-request/SKILL.md` for the full ticket format.

**Key points**:
- Tasks are created in the designated ClickUp list (901000600160) with `hydra-action-request` tag and the approval tier (`tier-1`, `tier-2`, `tier-3`)
- Include a machine-readable JSON block in the task description (between `---ACTION-REQUEST---` and `---END-ACTION-REQUEST---` markers)
- This does NOT add a new tool -- it uses `create_ticket` with structured content
- The Operations agent picks up tasks tagged `hydra-action-request` for review and execution

### 17. billing_status

- **Wraps**: `muso subscription billing-summary --email <verified-email> --env prod --json` (read-only; muso-cli >=0.10.0 -> `GET /admin/team/:id/billing-summary`). Same plugin/execFile transport and anti-spoof anchor as `subscription_status` (#3); on an older CLI the unknown verb degrades to `lookup_unavailable` -> human.
- **Returns**: `{ ok: true, billing_state, subscription: { plan, status, period, cancel_at_period_end, current_period_end, canceled_at } | null, last_charge: { exists, date, amount_minor, currency, status }, refunds: { exists, count, last_date, last_amount_minor }, charge_data_available, recent_charge_within_14d, refund_already_issued, workspace_id, support_action, notes, handoff_packet? }`. `charge_data_available` is `false` when the account's charge/refund data could not be read (a non-standard billing arrangement); then `last_charge.exists`/`refunds.exists` `false` are UNKNOWN, NOT authoritative, `support_action` is forced to `create_handoff_ticket`, and the same flag + a `data_caveat` travel inside `handoff_packet` so Operations does not read them as confirmed. `billing_state` ∈ `active | canceling_at_period_end | canceled | past_due | needs_review | no_subscription` (`needs_review` = a non-active/unrecognized processor status such as `unpaid`/`incomplete`/`paused` -- `active` is an explicit allowlist, never a fall-through, so an unknown status always hands off instead of being answered from status); `support_action` ∈ `answer_from_status | run_retention_flow | create_handoff_ticket` (the `handoff_packet` is present exactly when it is `create_handoff_ticket`). File the ticket with the packet's OWN `action_type`: a `refund` request carries `subscription-refund` (Tier 3, the refund workflow); a `charge_issue` or a non-active billing state carries `billing-issue` (Tier 2, billing review -- NOT the refund queue). Charge/refund signals cover the LAST 10 CHARGES only (an existence read, not accounting history); amounts are minor units (cents). On failure: `{ ok: false, reason: "rate_limited" | "owner_undetermined" | "ambiguous_workspace" | "not_found" | "vip_manual" | "not_stripe" | "lookup_unavailable", route_to_human? }`.
- **Identity (anti-spoof, FAIL-CLOSED)**: verified Intercom contact email only (`deriveConvId` -> `getAuthorEmail`); the tool has NO email/team parameter at all, and billing data is private, so an unverifiable anchor fails closed. The CLI exact-matches the workspace email server-side and refuses ambiguity.
- **Auth**: muso-cli execFile (read tier by method; no `--requester`, no `--yes`) -- NOT MusoAdminClient.
- **Rate limit**: 10 calls / 60 min per session.
- **When to use**: via the `refund-retention` skill, BEFORE any refund decision, charge/duplicate-charge complaint, or "was I charged after cancelling" question. Pass `customer_request` (`refund | cancel | charge_issue | billing_question`, default `billing_question`) to steer the recommended `support_action`: a duplicate/unexpected-charge or charged-after-cancel complaint passes `charge_issue`, which ALWAYS returns a `create_handoff_ticket` packet (never a self-serve answer). Every refund request ends in a handoff packet (`support_action: create_handoff_ticket`) -- refund EXECUTION stays the human Operations path; cancel intent routes back through the retention flow (`run_retention_flow`).
- **Safety model**: read-only only -- no refund/cancel capability exists in this tool, structurally (the CLI verb is a GET and the argv carries no write flags). `no_subscription` + a claimed charge still hands off: a charge could exist under another email/workspace, so never assert the customer was not charged.
- **Privacy**: the packet is whitelist-copied field by field, so processor identifiers (charge/invoice/customer/subscription ids) never enter the conversation. Say "your payment" to the customer; never name the payment processor or quote raw processor statuses.

### 18. credit_verification_check

- **Wraps**: `GET /api/v3/admin/credit-requests` (LIST only) for the signed-in customer's own profile(s), plus the proof-on-file read.
- **Returns**: counts and dates of the customer's own open credit requests, whether a document is on file, `open_request` (`true` / `false` / `null` = not measured), and a `note` saying what may be stated.
- **Identity (anti-spoof, FAIL-CLOSED)**: the conversation's signed-in Intercom contact only (role user, external id, contact older than 24 hours). A profile link from the conversation is used only when that contact owns the profile; anything else fails closed with no data.
- **Auth**: Muso admin JWT bearer via MusoAdminClient (GET-only, path-allowlisted).
- **When to use**: the `verification-handoff` skill's one read, for a credit request or a document. It writes nothing and decides nothing.
- **Safety model**: read-only. `null` is never "no request". The approved status paragraph may be sent only after this returns `open_request: true` in the same turn; the output guard enforces that in code.

### 19. profile_claim_status

- **Wraps**: `GET /api/v3/admin/claiming` (LIST only) for one profile.
- **Returns**: the signed-in customer's OWN claim rows on that profile (state and the day submitted) and a `note`. Other accounts' claims are dropped: not counted, not described.
- **Identity (anti-spoof, FAIL-CLOSED)**: same signed-in contact anchor as #18. A profile link or name from the conversation chooses which profile is looked at, never whose claim rows come back. There is no claim-id parameter.
- **Auth**: Muso admin JWT bearer via MusoAdminClient (GET-only, path-allowlisted).
- **When to use**: the `verification-handoff` skill's one read, for a profile claim.
- **Safety model**: read-only; never a claim write, never a statement about anyone else's claim.

### Order fulfillment (Prodigi plaques/posters)

The `order-fulfillment` action type (Tier 1) is filed by the `order-fulfillment`
skill for Prodigi address-confirmation requests and customer order/shipping
questions. When `details.proposed_corrected_address` is present, `create_ticket`
stamps a deterministic Prodigi-rules `address_validation` block (≤40-char lines +
required fields) onto the ticket – non-blocking, ops-facing. No new tool; uses
`create_ticket`. Doctrine: `reference/orders-and-fulfillment.md`.

Caroline can look an order up herself with the **`order_lookup`** tool (#7 above) –
by internal id, order number, or Prodigi id – for its status and hold only (#7: no
address/phone/tracking until Intercom IV; never confirm one).
For the **verified order owner**, she can also correct the shipping recipient with
**`order_address_update`** (#8): always a dry-run preview first, explicit customer
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
