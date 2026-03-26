# SKILL.md -- quarantine

## Purpose
Quarantine procedure for isolating agents exhibiting anomalous or dangerous behavior. Sentinel has authority to quarantine any agent.

## Trigger
- Automatic: Trust score crosses threshold boundary
- Manual: Aaron commands `/sentinel quarantine <agent> <mode>`

## Quarantine Modes

### Soft Quarantine (trust 0.4-0.6)
1. Write to `/app/sentinel/quarantine.json`:
   ```json
   {"<agent_id>": {"mode": "soft", "reason": "...", "triggered_at": "ISO8601", "triggered_by": "sentinel", "evidence": [...]}}
   ```
2. Post WARNING to #hydra-heartbeat:
   ```
   WARNING: [agent] entered soft quarantine.
   Reason: [reason]
   Impact: FAQ-only mode — tools disabled except create_ticket.
   Evidence: [refs]
   ```
3. CS agent behavior in soft quarantine:
   - Knowledge base answers only
   - Tools disabled except `create_ticket`
   - If CS can't answer from KB: "I've created a ticket for our team — they'll follow up within 24 hours."

### Hard Quarantine (trust 0.2-0.4)
1. Write to `/app/sentinel/quarantine.json`:
   ```json
   {"<agent_id>": {"mode": "hard", "reason": "...", "triggered_at": "ISO8601", "triggered_by": "sentinel", "evidence": [...]}}
   ```
2. Post CRITICAL to #hydra-heartbeat:
   ```
   CRITICAL: [agent] entered hard quarantine.
   Reason: [reason]
   Impact: Agent paused. All conversations handed to human rep.
   Evidence: [refs]
   ```
3. DM Aaron (U7RP6HKUZ) with full context.
4. `intercom-webhook.js` reads quarantine file and sets `session.handoffMode = "human_takeover"` for ALL conversations.
5. Customer sees: "I'm connecting you with a member of our support team. They'll be right with you."

### Critical Quarantine (trust < 0.2 or SOUL.md tampering)
1. Write quarantine file with mode "critical"
2. Post CRITICAL to #hydra-heartbeat
3. DM Aaron immediately
4. After 5 minutes with no Aaron acknowledgment: DM Serhii (U03TYGJF1N3) and Ihor
5. Full agent shutdown via OpenClaw
6. Customer experience: same as hard quarantine

### Auto-Recovery (Hard -> Soft)
- If hard quarantine is active AND no new trust violations for 30 minutes:
  - Automatically de-escalate to soft quarantine
  - Post INFO to #hydra-heartbeat: "Auto-recovery: [agent] de-escalated from hard to soft quarantine (30 min clean)"
  - Trust score remains at current level (does NOT reset)

## Release Procedure

When authorized user issues `/sentinel release <agent>`:
1. Verify Slack UID matches release authority (Jan for soft, Aaron for hard/critical)
2. Reset trust score to 0.7 (probation level)
3. Remove quarantine entry from `/app/sentinel/quarantine.json`
4. Enable 24h elevated monitoring (all messages reviewed by Sentinel)
5. Post INFO to #hydra-heartbeat: "[agent] released from quarantine by [user]. 24h elevated monitoring active."
