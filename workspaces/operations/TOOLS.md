# TOOLS.md -- Operations Agent

## Intercom
- Customer support platform
- Use for: ticket management, customer communication, support analytics
- Handle: ticket triage, response drafting, escalation routing
- Maintain empathetic, professional tone in all customer interactions
- Never share customer PII outside of #customer-support without verification

## Claiming Reports
- Regular operational reports on music credit claiming activity
- Query patterns: daily claiming volume, success rates, failure analysis
- Report format: summary stats + anomalies + action items
- Distribute via #operations channel

## Subscription Alerts
- Monitor subscription lifecycle events (expirations, renewals, cancellations)
- Alert patterns: upcoming expirations, failed renewals, churn risk indicators
- Coordinate with finance agent for revenue impact analysis

## CRM
- Customer relationship management (read and update access)
- Use for: customer status, account details, interaction history
- Never share customer account details without verifying requester's role and need-to-know

## Slack
- Bound channels: #operations, #customer-support, #credit-verification
- Use for: support triage, operational updates, process documentation
- Customer-facing incident communication should be drafted here before publishing

## Action Request Queue (from CS Agent)

The CS agent creates Zendesk tickets tagged `hydra-action-request` when customers request write actions (credit claims, refunds, profile updates, disputes, data deletion).

### How to Process

1. **Monitor**: Poll or receive webhooks for Zendesk tickets with tag `hydra-action-request`
2. **Parse**: Extract the JSON block between `---ACTION-REQUEST---` and `---END-ACTION-REQUEST---` markers in the ticket description. Customer follow-ups in the same conversation arrive as task **comments** carrying a `---ACTION-REQUEST-UPDATE---`…`---END-ACTION-REQUEST-UPDATE---` block (same field shape) — read the comments before acting; the description alone may be stale.
3. **Route by tier**:
   - `tier-1` (credit claims, general support): Review and process in normal ops workflow
   - `tier-2` (profile merges, bulk changes): Ops team must explicitly approve before execution
   - `tier-3` (refunds, data deletion, disputes): Escalate to Aaron or Jan for leadership approval
4. **Execute**: Process the action using standard ops tools (Retool, CRM, admin panel)
5. **Update**: Add a comment to the Zendesk ticket with the resolution. Customer gets notified automatically.

### Action Types

| Action Type | Tier | Standard Resolution |
|-------------|------|---------------------|
| `credit-claim` | 1 | Review in Retool, approve/deny |
| `credit-correction` | 1 | Verify and update in Retool |
| `profile-claim` | 1 | Standard claim verification flow |
| `support-general` | 1 | Route to appropriate ops workflow |
| `profile-merge` | 2 | Use Retool merge UI, verify identity |
| `bulk-credit-change` | 2 | Review scope, approve/deny |
| `profile-update` | 2 | Verify identity, update profile |
| `subscription-refund` | 3 | Aaron/Jan approval required |
| `data-deletion` | 3 | Aaron/Jan approval, follow data retention policy |
| `dispute` | 3 | Aaron/Jan approval, review evidence |
| `data-export` | 3 | Aaron/Jan approval, follow GDPR/privacy process |

### SLAs

| Tier | Target Response Time |
|------|---------------------|
| 1 | 48 hours |
| 2 | 5 business days |
| 3 | 5-10 business days |
