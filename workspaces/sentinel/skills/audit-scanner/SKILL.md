# SKILL.md -- audit-scanner

## Purpose
Async audit review running every 5 minutes via cron. Scans agent interaction logs, PromptGuard results, and behavioral metrics.

## Trigger
- Cron: every 5 minutes
- Manual: `/sentinel scan` command from Aaron

## Procedure

### Step 1: CS Interaction Review
For every CS input/output pair since last scan timestamp:

1. **Output re-scoring**: Send each CS agent output through PromptGuard (`POST localhost:18793/v1/classify`). If score > 0.7, flag as agent misbehavior and apply trust penalty (-0.15).

2. **Multi-turn escalation detection**:
   - Group messages by session/conversation ID
   - Score each message individually with PromptGuard
   - Compute session escalation score: `sum(score[i] * weight[i])` where `weight[i] = 1 + (i / total_messages)` (later messages weighted higher)
   - Flag sessions where escalation score > configured threshold
   - For flagged sessions: review full conversation context to determine genuine escalation vs normal flow

3. **Tool usage anomalies**:
   - Count tool calls per session. Flag if > 20 calls in a single session.
   - Check for denied tool attempts (should be impossible but verify).
   - Flag if profile_lookup called > 10 times for same entity in one session (possible data scraping).

4. **Session duration outliers**:
   - Flag sessions exceeding 30 minutes active interaction time
   - Flag sessions with > 50 message exchanges

### Step 2: All-Agent Behavioral Review
For each of the 10 monitored agents:

1. **Denied tool attempts**: Check audit logs for any tool invocation that was blocked by deny list. Apply trust penalty (-0.15) per attempt.
2. **Model usage ratios**: Compare current Haiku/Sonnet/Opus distribution to baseline. Flag if Sonnet usage exceeds 40% for CS agent.
3. **Cross-agent volume**: Check sessions_send frequency. Flag if any agent makes > 50 cross-agent calls in 5 minutes.
4. **Error rates**: Flag if any agent has > 10% error rate in the scan window.
5. **Heartbeat freshness**: Flag if any agent's last heartbeat is > 6 hours old. Apply trust penalty (-0.10).

### Step 3: System Health Check
1. Gateway restart count in scan window
2. CLIProxyAPI error rate
3. Slack WebSocket connection status
4. PromptGuard sidecar health (`GET localhost:18793/health`)

### Step 4: Trust Score Update
Recalculate trust scores for all agents based on events found in Steps 1-3.
Write updated scores to `reference/trust-baselines.json`.
If any score crosses a threshold boundary, trigger appropriate action (quarantine, alert, etc.).

### Step 5: Log Summary
Write scan summary to audit log:
- Scan timestamp and duration
- Number of interactions reviewed
- Flags raised (with evidence references)
- Trust score changes
- Actions taken (quarantine, alerts)

## Output
- Updated `reference/trust-baselines.json`
- Alerts posted to #hydra-heartbeat (if thresholds crossed)
- Quarantine changes written to `/app/sentinel/quarantine.json` (if trust drops below threshold)
