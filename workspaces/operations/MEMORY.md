# MEMORY.md — OPERATIONS Agent

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned
_(none yet — agent will populate during operation)_

## Key Context
_(initialized 2026-03-22)_

## Migrated from Clio (2026-03-23)

### Credit Request Approval Audit Trail
- Flow: User submits credit claim → core-backend API creates claim record → Admin reviews in Retool → approve/reject.
- Data source: Athena `platform-core-backend-export-prod.public_claiming` + `public_teams`.
- As of Feb 28: 231 rejections in 7 days, 72% approval rate.
- **160/231 rejections have NO reason logged** — ops process gap. Every rejection should have a reason.
- Daily claiming report in HEARTBEAT: 72% approval rate baseline.

### Retool Replacement — Ops Skills Context
- Retool is the current admin tool for: credit claim review, profile merging, audit operations, dispute management.
- 94 admin endpoints documented under `/w/admin/*`.
- Retool replacement should preserve: credit claims workflow, profile merge workflow, audit batch processing.
- Audit batches: processed in numbered batches (batch_0 through batch_39+), each validated separately.
- Intercom ops: ~50-60% of conversations automatable. Easy: FAQ, subscription lookups. Hard: actual merges, identity verification.

### 4-Tier Permission System
- **Tier 1 (Read-only)**: View data, run reports, search. No auth needed beyond login.
- **Tier 2 (Ops write)**: Credit claim approve/reject, profile edits, audit operations. Requires ops role.
- **Tier 3 (Admin write)**: Subscription changes, refunds, merge operations. Requires admin role.
- **Tier 4 (Super admin)**: Credential access, DNS changes, production deployments, security-file changes. Aaron only (U7RP6HKUZ). Agent policy-file changes take EITHER owner (Nick U0AL36NADEY or Aaron).

### "Why Protocol" for Write Operations
- Every write operation that modifies production data must have a documented reason.
- Credit rejections MUST log a reason (160/231 missing reasons = unacceptable).
- Refunds must be logged to `api-logs/stripe/YYYY-MM-DD.jsonl` BEFORE execution.
- Profile merges must document which profiles were merged and why.
- This protocol exists because of past incidents where actions were taken without audit trail.

### Jan's Name Correction
- **Jan is NOT Jay.** These are different people.
- Jay = U038BM16T7W (QA Lead).
- Always verify Slack user IDs from message metadata before attributing statements.
