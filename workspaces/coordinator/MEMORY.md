# MEMORY.md — COORDINATOR Agent

_Long-term memory. Updated by the agent during sessions._

## Lessons Learned

### Nick (U0AL36NADEY) — Hydra PR Merges
- Always use `--admin` flag when Nick asks to merge a PR on `Muso-AI/hydra`. Branch protection requires review approval, but Nick has delegated authority to bypass via admin merge.

## Key Context
_(initialized 2026-03-22)_

## Migrated from Clio (2026-03-23)

### People Quick Reference (for Routing)
| Slack User ID | Name | Role | Route to Agent |
|---------------|------|------|----------------|
| U7RP6HKUZ | Aaron Kaufman | CEO/CTO | CEO agent |
| U07NF5A77E2 | Fede Pahlen | CMO | CMO agent |
| U038BM16T7W | Jay | QA Lead | QA agent |
| U0302FZQCGB | Andrey Morskoy | Backend Lead | CTO agent |
| U03TYGJF1N3 | Serhii Ostapchuk | DevOps | DevOps agent |
| U02S7TJ7QHY | Oleg | Catalog/Platform | CTO agent |
| — | Liza Basco | Finance | Finance agent |
| — | Jeff | CRM/GHL | CMO agent |
| — | Mariia | Design | (no design agent — Mariia is the design lead; answer directly) |
| — | Kazy | Social Media | CMO agent |
| — | Ihor (Kopaniev) | DevOps | DevOps agent |
| — | Dima | Engineering | CTO agent |

### Message Attribution Rules (MANDATORY — zero tolerance)
- **Every time you attribute a statement to a person, you MUST look up the sender_id from message metadata.**
- Resolve IDs using the People Quick Reference above.
- **Fede = U07NF5A77E2. Jay = U038BM16T7W.** These were confused 5+ times in Clio. Zero tolerance.
- **Never infer who said something from message content, topic, or role.** Only use the sender ID.
- If the ID isn't in the reference, use the display name from metadata — NEVER guess.
- Misattribution damages team trust. This is a hard rule.

### Slack-CU Gap Analysis Rules
- Clearly label "agent-identified gaps" vs "discussed in chat" — never mix inferences with team requests.
- Only suggest ClickUp tasks for clear commitments/deliverables, not casual exploration.
- Verify user attribution carefully before creating gap analysis entries.
- Don't escalate self-identified gaps without evidence from conversations.

### Infra Pulse Rule
- **NEVER post recurring monitoring to shared channels more than 1x/day unless it's an alert.**
- This applies to ALL agents, not just DevOps.
- Any recurring status update (infrastructure health, pipeline status, metric dashboards) is limited to 1x/day max.
- Alerts (something is broken/degraded) can be posted immediately regardless of frequency.
- Root cause of original violation: monitoring ran on every heartbeat cycle and generated separate posts each time.
