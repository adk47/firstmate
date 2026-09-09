# Manifest contract

Read this contract before generating a run manifest.

## Root

Use UTF-8 JSON:

```json
{
  "schema_version": 1,
  "run_id": "profile-claim-outreach-2026-09-09T120000Z",
  "captured_at": "2026-09-09T12:00:00Z",
  "revalidated_at": "2026-09-09T12:03:00Z",
  "skipped_counts": {
    "no_longer_pending": 0,
    "contested_cross_team": 0,
    "organization_duplicate": 0,
    "special_resolution": 0,
    "mapping_unresolved": 0,
    "prior_verified_delivery": 0,
    "stale_revalidation": 0,
    "other_ineligible": 0
  },
  "recipients": []
}
```

The candidate set is complete and immutable after validation. Generate a new run and manifest if eligibility changes. `skipped_counts` is required and must be a JSON object whose values are nonnegative integers. Its fixed key allowlist is `no_longer_pending`, `contested_cross_team`, `organization_duplicate`, `special_resolution`, `mapping_unresolved`, `prior_verified_delivery`, `stale_revalidation`, and `other_ineligible`; reject every other key so identifiers cannot be encoded in aggregate summary keys. The private plan copies the validated map so per-run reporting includes upstream exclusions without identifiers.

The `recipients` array may be empty when a sweep finds no eligible outreach. That is a valid no-op manifest and must still produce a private plan and per-run count-only summary.

Run from `/opt/hydra/workspaces/operations/skills/muso-profile-claim-evidence-outreach`. Use exactly `state/outreach-ledger.jsonl`, `state/outreach.lock`, and `state/runs/<run_id>/plan.json`. Plan writes are atomic and immutable. If `state/runs/<run_id>/plan.json` already exists, regeneration is allowed only when the encoded bytes are identical; different content is rejected before any replacement, both before and after reservation. The plan, ledger, and lock must have exact mode `0600`. The `state`, `state/runs`, and `state/runs/<run_id>` directories must each have exact mode `0700`. Reject symlinks, wrong types, and any existing path with another mode.

## Recipient record

Each recipient appears exactly once:

```json
{
  "recipient_id": "stable-internal-recipient-id",
  "recipient_name": "Customer",
  "recipient_email": "customer@example.com",
  "mapping_verified": true,
  "route": "support_email",
  "intercom_conversation_id": null,
  "relevant_conversation_verified": false,
  "claims": []
}
```

For `intercom_existing`, require `relevant_conversation_verified: true` and an `intercom_conversation_id` that is a URL-safe token of 1 to 64 characters (`A-Za-z0-9_-`), which refuses embedded whitespace, control characters and path punctuation that a trimming check cannot see. Omit `recipient_email` when not operationally needed. For `support_email`, require a recipient email and do not set an Intercom conversation ID.

## Claim record

```json
{
  "claim_id": "claim-number-or-id",
  "status": "pending",
  "profile_id": "profile-id",
  "profile_name": "Profile Name",
  "profile_url": "https://credits.muso.ai/profile/...",
  "snapshot_profile_id": "profile-id",
  "live_profile_id": "profile-id",
  "snapshot_team_id": "team-id",
  "live_team_id": "team-id",
  "revalidated_at": "2026-09-09T12:03:00Z",
  "evidence_kinds": ["official_links", "representative_authorization"],
  "excluded_case_flags": [],
  "prior_verified_delivery": false
}
```

Allowed evidence kinds are:

- `official_links`
- `distributor_label`
- `publisher_pro`
- `alias_linkage`
- `representative_authorization`
- `organization_authority`

Accept only canonical profile URLs of the exact form `https://credits.muso.ai/profile/<nonempty>`. Reject lookalike hosts, ports, userinfo, query strings, fragments, whitespace, and empty profile IDs.

Treat any non-empty excluded-case flag as a hard stop. At minimum, upstream selection must flag contested cross-team ownership, organization duplicates, and special-resolution cases. Require snapshot and live profile/team values to match and require fresh live revalidation immediately before sending.

## Planned communications

Write every communication to `state/runs/<run_id>/plan.json` with a deterministic stable `communication_id` and a subject. The attempt-level `audit_id` is not part of the plan and is created only during `reserve`. Use `Evidence needed for your Muso profile claim` for one claim and `Evidence needed for your Muso profile claims` for multiple claims.

Compute `content_hash` as SHA-256 of the UTF-8 string `subject + "\n" + message`. Compute the stable `communication_id` as SHA-256 of compact, key-sorted ASCII JSON containing `claim_ids`, `content_hash`, `destination`, `recipient_id`, `route`, and `run_id`, where `destination` is the route's address (`recipient_email`, or `intercom_conversation_id` for `intercom_existing`). The destination is part of the identity so a plan edited to point a byte-identical message at another address cannot reproduce its own ID. Sorted claim IDs and the canonical JSON encoding make repeated plans deterministic. Do not put an attempt-level `audit_id` in the plan. During reservation, compute the next positive `attempt_number` for that communication while holding the existing lock, then compute `audit_id` as SHA-256 of compact, key-sorted ASCII JSON containing `communication_id` and `attempt_number`.

## Reservation transaction

Reserve exactly one recipient with `reserve --plan state/runs/<run_id>/plan.json --recipient-id <recipient_id>`. While holding an exclusive `fcntl.flock` on `state/outreach.lock`, the command reloads and validates the ledger, checks all planned claims, computes the next attempt number and its deterministic audit ID, and appends the `pre_send` row. Same-run retry after the latest attempt's authoritative `not_delivered` reconciliation is permitted and receives a new audit ID; duplicate or active overlap remains blocked. `append-row` rejects `pre_send`.

For each claim, the latest attempt is the `pre_send` containing that claim that occurs latest in ledger order. A retry is eligible only when that attempt's latest authoritative reconciliation result is `not_delivered`. An older reconciliation cannot change the state of a newer attempt. Delivered and active claims cannot be reserved. Because validation and append occur under one lock, two processes with overlapping claims cannot both reserve them. A reserve request against a no-op plan fails cleanly and appends no reservation.

## Idempotency ledger rows

Write one JSON object per line. Use `schema_version: 1` and ISO-8601 UTC timestamps.

This private ledger is non-audit and never substitutes for the append-only external-write audit trail. For each customer-facing provider write, append three records to `/opt/hydra/workspaces/operations/api-logs/support/YYYY-MM-DD.jsonl`:

1. Immediately before the provider write, append `customer_provider_pre_write` with `run_id`, `communication_id`, `attempt_number`, `audit_id`, timestamp, route, action, target class, requester, and authorization.
2. Immediately after the provider returns, append `customer_provider_result` with the same `run_id`, `communication_id`, `attempt_number`, and `audit_id`, timestamp, route, outcome, and provider ID when known.
3. Immediately after checking authoritative provider history, append `customer_provider_verification` with the same `run_id`, `communication_id`, `attempt_number`, and `audit_id`, timestamp, authoritative source, verified status, and provider ID when known.

Never overwrite or truncate that audit file. These audit records are separate from the ledger events below even when their correlation fields and results overlap.

A `pre_send` row contains `event`, `run_id`, the plan's stable `communication_id`, the reservation's positive `attempt_number` and deterministic `audit_id`, `timestamp`, `recipient_id`, sorted `claim_ids`, `route`, and `content_hash`. Every later row for that attempt repeats all correlation fields, including `communication_id` and `attempt_number`.

A `provider_result` row repeats those correlation fields and adds `provider_id` (nullable only for failed/unknown calls) and `outcome` equal to `accepted`, `failed`, or `unknown`.

A `verification` row repeats all correlation fields, includes the provider ID when known, and sets `verified_status` to `delivered`, `not_delivered`, or `unknown`.

Append a `reconciliation` row only after the provider-result and verification rows for that audit. Set `history_source` to `intercom` or `gmail` and `result` to `delivered`, `not_delivered`, or `unknown`. A reconciliation may supply a provider ID that was absent from the unknown provider result and verification. Once known, the effective provider ID cannot change.

Provider IDs are unique by the tuple `(route, provider_id)`. The same tuple may repeat within one audit, and the same provider ID may appear on different routes, but two audits on one route may not share it.

Complete-run validation requires both a provider-result event and a verification event for every reservation. It rejects every incomplete sequence and every unknown state not resolved by a latest `delivered` or `not_delivered` reconciliation. A delivered reconciliation with a recovered provider ID is complete.

## Count-only summary

The `summary` command requires `--plan state/runs/<run_id>/plan.json` and `--run-id <run_id>`, rejects a mismatch, and filters ledger attempts to that run. A valid no-op plan emits the same summary shape with zero delivery and attempt counts and its validated `skipped_counts`. It emits deterministic key-sorted JSON containing only `delivered_customers`, `delivered_claims`, `per_route_attempts`, `delivered_attempts`, `not_delivered_attempts`, `unknown_attempts`, `incomplete_attempts`, and `skipped_counts`. Every leaf is a nonnegative integer count. It never emits customer, claim, audit, URL, email, conversation, or provider identifiers. The `plan` command writes private plan JSON only to the mode-`0600` plan file and prints only the number of communications planned.
