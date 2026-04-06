---
name: muso-ops-audit
description: |
  Mandatory audit logging for all Muso ops operations. Every write operation
  through any muso-ops-* skill MUST be logged here before execution.
  
  Also provides: audit trail querying, ops activity reports, per-operator metrics,
  and compliance reporting.
  
  Use when: checking audit logs, reviewing ops activity, generating compliance
  reports, investigating what happened to a specific entity.

  Triggers: "audit log", "ops activity", "who changed", "operation history",
  "audit trail", "ops report", "compliance"
depends-on:
  - muso-slack-formatter
compatibility: |
  Required by ALL muso-ops-* skills. No external dependencies.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Muso Ops — Audit Trail

Mandatory logging layer for all ops operations. If it's not logged, it didn't happen.

## Log Format

All ops write operations are logged to: `api-logs/admin/YYYY-MM-DD.jsonl`

Each line is a JSON object:

```json
{
  "timestamp": "2026-03-07T17:30:00Z",
  "operator": {
    "slack_id": "U7RP6HKUZ",
    "name": "Aaron Kaufman",
    "tier": 1
  },
  "operation": "claiming_approve",
  "category": "claiming",
  "endpoint": "PUT /w/admin/claiming/12345",
  "target": {
    "type": "claiming",
    "id": "12345",
    "profile_id": "abc-123",
    "profile_name": "John Producer"
  },
  "reason": "Verified via Spotify credits + IPI match",
  "context": {
    "authenticity_score": 82,
    "fraud_flags": [],
    "alternatives_offered": false
  },
  "request_body": {"status": "processed"},
  "response": {
    "http_status": 200,
    "success": true,
    "summary": "Claim approved"
  },
  "channel": "C0ADREBPNQ2",
  "thread_ts": "1772932016.021999",
  "session_id": "main"
}
```

## Required Fields

Every audit entry MUST include:
- `timestamp` — ISO 8601 UTC
- `operator` — who requested it (from Slack sender_id, resolved to name)
- `operation` — human-readable operation name
- `category` — claiming | credits | profiles | tracks | users | identity | workspaces | subscriptions
- `endpoint` — exact HTTP method + path
- `target` — what entity was modified (type + IDs)
- `reason` — WHY this was done (asked from operator if not stated)
- `response` — what happened (status + success + summary)

## Operation Categories

| Category | Operations |
|----------|-----------|
| `claiming` | approve, reject, revert |
| `credits` | approve_request, reject_request, add_credit, remove_credit |
| `profiles` | merge, unmerge, link_external, unlink_external, update, enrich, create, delete, avatar_upload |
| `tracks` | merge, unmerge, add_link, remove_link, move_link, add_credit, remove_credit, enrich, capture |
| `users` | reset_password, confirm_email, update, delete, impersonate, image_upload |
| `identity` | confirm, reject |
| `workspaces` | create, add_member, remove_member, add_roster, remove_roster, update_seat |
| `subscriptions` | create_vip, update, cancel |
| `fraud` | flag, override, block |

## Logging Implementation

Before EVERY write operation in any muso-ops-* skill:

```bash
# Create log dir
mkdir -p ~/".openclaw/workspace/api-logs/admin"

# Append log entry BEFORE executing the operation
echo '{"timestamp":"...","operator":{...},...}' >> \
  ~/".openclaw/workspace/api-logs/admin/$(date +%Y-%m-%d).jsonl"
```

After execution, append the response:
```bash
# Read back, update response field, write back
# (or log pre + post as separate entries with correlation ID)
```

## Query Audit Trail

### By Operator
```bash
cat api-logs/admin/2026-03-07.jsonl | \
  python3 -c "
import sys, json
for line in sys.stdin:
    entry = json.loads(line)
    if entry['operator']['slack_id'] == 'U7RP6HKUZ':
        print(f\"{entry['timestamp']} | {entry['operation']} | {entry['target'].get('id','')} | {entry['reason']}\")
"
```

### By Entity
```bash
# Find all operations on a specific profile
grep '"profile_id":"abc-123"' api-logs/admin/2026-03-*.jsonl
```

### By Category
```bash
grep '"category":"claiming"' api-logs/admin/2026-03-07.jsonl | python3 -m json.tool
```

## Daily Ops Activity Report

Generated as part of the daily write activity report (HEARTBEAT.md):

```
📋 *Ops Activity Report — 2026-03-07*

*By Operator:*
• Aaron: 3 operations (2 claim approvals, 1 profile merge)
• Jan: 8 operations (5 claim approvals, 2 rejections, 1 password reset)

*By Category:*
• Claiming: 9 (7 approved, 2 rejected)
• Users: 1 (password reset)
• Profiles: 1 (merge)

*Fraud Flags:* 0 triggered today
*Escalations:* 0

*Notable:*
• Claim #12345 rejected — suspicious verification links
• Profile merge: [Name A] ← [Name B] (duplicate cleanup)
```

## Retention

- Daily logs kept for 90 days locally
- Committed to git (clio-workspace) for permanent archive
- Never delete audit logs — compress old ones if space is needed

## Compliance

The audit trail exists so Aaron can:
1. **Review any ops decision** — who did what, when, and why
2. **Identify patterns** — is someone approving too many claims too fast?
3. **Train ops** — "you rejected this but should have investigated X"
4. **Legal/compliance** — prove that profile changes were authorized
5. **Fraud forensics** — trace how a bad actor got through

## Aaron Override Logging

When Aaron overrides any decision:
```json
{
  "operation": "aaron_override",
  "override_target": {
    "original_operation": "fraud_flag",
    "original_timestamp": "2026-03-07T10:00:00Z",
    "original_decision": "block"
  },
  "override_reason": "Known VIP client, verified offline"
}
```
