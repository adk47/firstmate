---
name: "muso-profile-claim-evidence-outreach"
description: "Outreach for evidence-blocked pending profile claims with live revalidation, grouped messaging, delivery reconciliation, and aggregate reporting."
---

# Profile Claim Evidence Outreach

Operate only from the applied skill directory `/opt/hydra/workspaces/operations/skills/muso-profile-claim-evidence-outreach`; use exactly `state/outreach-ledger.jsonl`, `state/outreach.lock`, and `state/runs/<run_id>/plan.json` for the idempotency ledger, lock, and private plan. These paths are private operational state, not the external-write audit trail.

Use a stable manifest for every run. Read [references/manifest-contract.md](references/manifest-contract.md) before preparing it. Treat the manifest as the complete candidate set for the run; do not add ad hoc claims after validation.

## Prepare

1. Create a unique run ID and snapshot all evidence-blocked pending profile claims selected by the review or sweep.
2. Exclude ineligible claims and record each aggregate reason as a nonnegative integer in the root `skipped_counts` map. The only allowed keys are `no_longer_pending`, `contested_cross_team`, `organization_duplicate`, `special_resolution`, `mapping_unresolved`, `prior_verified_delivery`, `stale_revalidation`, and `other_ineligible`; reject every other key so identifiers cannot be encoded in summary keys.
3. Resolve each claim to exactly one recipient. Put all claims for the same recipient in one recipient record so the person receives one combined message.
4. Live-revalidate immediately before outreach:
   - Confirm every claim is still pending.
   - Confirm its current profile and team match the snapshot.
   - Confirm the recipient-to-claim mapping.
   - Confirm no excluded-case flag appeared.
5. Choose one route per recipient:
   - Use an existing Intercom conversation only when its relevance to these claims is explicitly verified.
   - Otherwise use the approved support-email workflow from `support@muso.ai`.
   - Never create or initiate an unsupported Intercom conversation.
6. Run `scripts/render_validate.py plan` with the manifest, exact ledger path, and [templates/profile-claim-evidence.txt](templates/profile-claim-evidence.txt). Stop on any validation error.
7. Write the plan atomically to `state/runs/<run_id>/plan.json` with exact mode `0600`. A run plan is immutable: if that path already exists, accept regeneration only when the newly encoded plan is byte-identical; never replace different content, whether or not a reservation already exists. Byte-identical regeneration remains valid after a same-run reservation; same-run ledger rows are ignored only for this regeneration comparison, while overlap from every other run remains enforced. Require `state`, `state/runs`, and `state/runs/<run_id>` to have exact mode `0700`, and require the ledger and lock to have exact mode `0600`. Fail closed if any private state directory, plan, ledger, or lock is a symlink. Reject any existing path with a different type or mode. Serialize plan and ledger writes with `state/outreach.lock`. A sweep with zero eligible recipients is valid: write a private plan with an empty `communications` array and continue to the per-run count-only summary.

## Reserve

Before every send, run `scripts/render_validate.py reserve --plan state/runs/<run_id>/plan.json --recipient-id <recipient_id>`. Reserve re-applies the freshness window the plan step enforced on the manifest, and refuses a plan whose live revalidation has since gone stale, so a claim resolved or reassigned between planning and sending is never contacted. The plan records the `--max-revalidation-age-seconds` it was validated with and that value is the ceiling: a reserve-time value may narrow the window but never widen it, so the gate cannot be disabled by passing a larger number. Freshness is measured from the oldest revalidation in the plan, across the manifest root and every claim, so a claim that was already near the limit when planning succeeded cannot be sent past it later. A plan missing any of these fields is refused. The command must hold an exclusive `fcntl.flock` on `state/outreach.lock` while it reloads and validates `state/outreach-ledger.jsonl`, evaluates every claim against its latest `pre_send` attempt in ledger order, computes the next positive attempt number for the plan's stable communication identity, derives a distinct deterministic `audit_id` from that `communication_id` plus attempt number, and appends the new `pre_send` reservation. It must reject delivered or active claims and allow a retry only when the latest attempt has an authoritative `reconciliation` result of `not_delivered`. Same-run retries therefore retain one communication identity while receiving a new attempt/audit identity. Overlapping reservations must be mutually exclusive. A reserve request against a valid no-op plan must fail cleanly without appending a ledger reservation.

Never append `pre_send` with `append-row`; that command is only for post-reservation provider, verification, and reconciliation events.

## Communicate

Use Caroline's customer-facing voice. Every user-supplied string the manifest copies into the plan or the customer-facing message must be in canonical form: present, non-empty, and free of surrounding whitespace. Destinations must additionally satisfy the grammar the provider will accept: an SMTP-valid address for `support_email` (dot-atom local part, LDH domain labels, alphabetic TLD, RFC 5321 length limits) or a URL-safe token for `intercom_existing`, because anything that reaches a reservation and is then bounced strands the claim behind an active attempt. Any argument that bounds a guard is rejected at parse time unless it is a positive integer, so a typo cannot write a plan that later loads as invalid. The plan loader applies the same rule, so padding is refused where it enters rather than discovered at provider time. The destination is part of the communication identity and is revalidated when the plan is loaded, so a plan edited to point a byte-identical message at another address is refused rather than sent. Each planned communication must include a deterministic stable `communication_id` and the singular or plural email subject defined in the manifest contract. Each reserved send attempt receives a positive `attempt_number` and a distinct deterministic `audit_id`; use the values returned by `reserve` for every provider and audit record in that attempt. Include each claim number, profile name, and exact Muso profile URL. Ask only for applicable evidence: official artist or company links; distributor, label, publisher, or PRO evidence; alias linkage; representative authorization; or organization role and authority proof. State that unrelated sensitive details may be redacted and that the claim stays pending while evidence is reviewed.

Do not reject, mutate, approve, or otherwise change a claim. Do not impose an automatic no-response deadline.

For each recipient:

1. Atomically reserve the recipient from the private plan. Send only after the reserve command reports one successful reservation.
2. Immediately before the customer-facing provider write, append a `customer_provider_pre_write` record to `/opt/hydra/workspaces/operations/api-logs/support/YYYY-MM-DD.jsonl`. Include `run_id`, `communication_id`, `attempt_number`, `audit_id`, route, timestamp, action, target class, requester, and authorization. This append-only record is mandatory after reservation and before the provider call.
3. Delegate support email through Clio; do not call Gmail directly. Require sending from `support@muso.ai`.
4. For an explicitly relevant existing Intercom conversation, use only the approved muso-intercom customer-facing reply path as Caroline and the authorized support workflow. Do not bypass its write policy or post as a human admin.
5. Immediately after the provider returns, append a `customer_provider_result` record to the same dated audit file with the same `run_id`, `communication_id`, `attempt_number`, and `audit_id`, the result timestamp, route, outcome, and provider ID when known. Append the provider-result row to the private idempotency ledger.
6. Check authoritative Intercom or Gmail history. Immediately after that check, append a `customer_provider_verification` record to the same dated audit file with the same `run_id`, `communication_id`, `attempt_number`, and `audit_id`, verification timestamp, authoritative source, verified status, and provider ID when known. Then append the ledger verification row.
7. Count a communication complete only when the provider ID is present, unique, correlated to the run and audit, and delivery is authoritatively verified.

If a provider call times out or returns an unknown result, mark it unknown. Reconcile it against authoritative Intercom or Gmail history before any retry and append a reconciliation row. A reconciliation may recover a previously absent provider ID. Never blind-retry. Retry only when the latest attempt for every claim has an authoritative `not_delivered` reconciliation; an older reconciliation never clears a newer attempt.

## Idempotency ledger and audit trail

Store the private JSONL idempotency ledger at `state/outreach-ledger.jsonl` with exact mode `0600`; use the exact-mode-`0600` `state/outreach.lock` for serialization and `state/runs/<run_id>/plan.json` for each atomic plan write. Record run ID, stable communication ID, attempt number, audit ID, claim IDs, content hash, route, provider ID when known, timestamps, provider result, and verification status. Store only operationally necessary PII. Never write customer data to MEMORY.md.

The idempotency ledger is explicitly non-audit. It prevents duplicate outreach and reconciles delivery state, but it never substitutes for the separate append-only external-write records in `/opt/hydra/workspaces/operations/api-logs/support/YYYY-MM-DD.jsonl`. Every provider write requires exactly the three correlated audit records described above: one immediately before the write, one after its result, and one after authoritative verification. All three carry `run_id`, `communication_id`, `attempt_number`, and `audit_id`; the pre-write record additionally carries requester and authorization.

Use `scripts/render_validate.py reserve` for every `pre_send`, `append-row` only for later events, and `validate-ledger --require-complete-run` before reporting completion. Provider IDs are unique by `(route, provider_id)`: repeated use in one audit is valid, and the same ID may appear on different routes, but two audits on one route may not share it. Complete-run validation rejects missing provider-result or verification events and every unresolved unknown or incomplete attempt; a delivered reconciliation with a recovered provider ID is complete.

## Report

Generate deterministic per-run count-only JSON with `scripts/render_validate.py summary --plan state/runs/<run_id>/plan.json --run-id <run_id>`. The command requires both the private plan and its run ID, rejects a mismatch, filters ledger attempts to that run, and emits exactly these count leaves:

- `delivered_customers`
- `delivered_claims`
- `per_route_attempts`
- `delivered_attempts`
- `not_delivered_attempts`
- `unknown_attempts`
- `incomplete_attempts`
- `skipped_counts`

Every leaf is a nonnegative integer count. Do not include names, email addresses, claim IDs, audit IDs, profile URLs, conversation IDs, provider IDs, or other customer data. The plan command writes only the private mode-`0600` plan file and prints counts, never plan JSON. For a valid no-op plan, the summary still emits the same count-only shape with zero delivery and attempt counts plus the validated aggregate `skipped_counts`.

## Command examples

Run from the exact applied skill directory. These commands only prepare private state, reserve an attempt, append already-observed result rows, validate, and summarize. They do not authorize or perform a provider send; use the separately authorized customer-facing workflow and mandatory audit records for any actual send.

```bash
cd /opt/hydra/workspaces/operations/skills/muso-profile-claim-evidence-outreach

PYTHONDONTWRITEBYTECODE=1 python3 scripts/render_validate.py plan \
  --manifest /secure/private/profile-claim-outreach-2026-09-09T120000Z.json \
  --ledger state/outreach-ledger.jsonl \
  --template templates/profile-claim-evidence.txt \
  --output state/runs/profile-claim-outreach-2026-09-09T120000Z/plan.json \
  --now 2026-09-09T12:03:00Z

PYTHONDONTWRITEBYTECODE=1 python3 scripts/render_validate.py reserve \
  --plan state/runs/profile-claim-outreach-2026-09-09T120000Z/plan.json \
  --recipient-id stable-internal-recipient-id \
  --ledger state/outreach-ledger.jsonl \
  --now 2026-09-09T12:04:00Z

# Populate this JSON only from the reserved private plan and the observed provider result.
PROVIDER_RESULT_ROW_JSON='{"schema_version":1,"event":"provider_result","run_id":"profile-claim-outreach-2026-09-09T120000Z","communication_id":"0000000000000000000000000000000000000000000000000000000000000000","attempt_number":1,"audit_id":"0000000000000000000000000000000000000000000000000000000000000000","timestamp":"2026-09-09T12:05:00Z","recipient_id":"stable-internal-recipient-id","claim_ids":["claim-id"],"route":"support_email","content_hash":"0000000000000000000000000000000000000000000000000000000000000000","provider_id":"observed-provider-id","outcome":"accepted"}'
PYTHONDONTWRITEBYTECODE=1 python3 scripts/render_validate.py append-row \
  --ledger state/outreach-ledger.jsonl \
  --row-json "$PROVIDER_RESULT_ROW_JSON"

# Populate this JSON only after authoritative provider-history verification.
VERIFICATION_ROW_JSON='{"schema_version":1,"event":"verification","run_id":"profile-claim-outreach-2026-09-09T120000Z","communication_id":"0000000000000000000000000000000000000000000000000000000000000000","attempt_number":1,"audit_id":"0000000000000000000000000000000000000000000000000000000000000000","timestamp":"2026-09-09T12:06:00Z","recipient_id":"stable-internal-recipient-id","claim_ids":["claim-id"],"route":"support_email","content_hash":"0000000000000000000000000000000000000000000000000000000000000000","provider_id":"observed-provider-id","verified_status":"delivered"}'
PYTHONDONTWRITEBYTECODE=1 python3 scripts/render_validate.py append-row \
  --ledger state/outreach-ledger.jsonl \
  --row-json "$VERIFICATION_ROW_JSON"

PYTHONDONTWRITEBYTECODE=1 python3 scripts/render_validate.py validate-ledger \
  --ledger state/outreach-ledger.jsonl \
  --require-complete-run profile-claim-outreach-2026-09-09T120000Z

PYTHONDONTWRITEBYTECODE=1 python3 scripts/render_validate.py summary \
  --plan state/runs/profile-claim-outreach-2026-09-09T120000Z/plan.json \
  --run-id profile-claim-outreach-2026-09-09T120000Z \
  --ledger state/outreach-ledger.jsonl
```

## Cron readiness

Do not create a cron in this skill. A later cron must supply:

- cadence and timezone
- eligibility window and evidence-blocked definition
- source review or sweep identifier
- complete stable candidate manifest
- run ID and snapshot timestamp
- live-revalidation data and timestamp
- root `skipped_counts` map
- applied skill directory `/opt/hydra/workspaces/operations/skills/muso-profile-claim-evidence-outreach` and the exact relative state paths defined above
- final aggregate Slack destination

Run the same validation, separate append-only audit, delivery verification, reconciliation, and per-run aggregate-only reporting flow on every recurrence.
