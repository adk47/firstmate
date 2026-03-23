---
name: gateway-self-heal
description: |
  Self-healing health check for the OpenClaw gateway process.
  Checks if the gateway is running, detects active LLM timeouts (FailoverError/lane task error
  within the last 12 minutes), and restarts via launchd if stuck.
  Silent unless action is taken.

  Use when: gateway is unresponsive, Clio stops replying, LLM timeouts are suspected,
  or on a scheduled health-check interval.

  Triggers: "heal gateway", "check gateway", "gateway health", "self-heal"
---

# Gateway Self-Heal

Silent health check and auto-restart for the OpenClaw gateway. Produces no output unless action is taken.

## Step 1 — Verify gateway is running

```bash
launchctl list ai.openclaw.gateway
```

- If output contains a `PID` field → gateway is up, continue to Step 2.
- If no `PID` field → gateway is down. Bootstrap it:
  ```bash
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
  ```
  Log: "Gateway was down — bootstrapped via launchd."

## Step 2 — Check for active stuck LLM threads

```bash
grep "FailoverError\|lane task error" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log 2>/dev/null \
  | awk -F'"time":"' '{print $2}' | tr -d '"' | sort | tail -3
```

- Parse the timestamps from output.
- Compare each to current epoch (`date +%s`).
- If any timestamp is within the last 12 minutes → gateway has an active stuck thread.
- If stuck:
  ```bash
  kill -TERM $(pgrep -f "openclaw.*gateway" | head -1)
  sleep 8
  tail -4 /Users/admin/.openclaw/logs/gateway.log
  ```
  Log: "Gateway restarted — active FailoverError within 12-min window. Last error: <timestamp>."

## Step 3 — Verify cron self-heal job exists

Use the CronList tool. If no job exists whose prompt contains "gateway-self-heal skill", recreate it:

- Schedule: `3,13,23,33,43,53 * * * *`
- Recurring: true
- Prompt:
  ```
  Run the gateway-self-heal skill. Check gateway health, restart if stuck, verify cron still exists.
  ```

This handles the 3-day session-only auto-expiry.

## Step 4 — Check session context size

```bash
SESSION_FILE=$(ls -t /Users/admin/.claude-proxy/projects/-Users-admin--openclaw/*.jsonl 2>/dev/null | head -1)
SIZE_MB=$([ -n "$SESSION_FILE" ] && du -m "$SESSION_FILE" | cut -f1 || echo 0)
echo "$SIZE_MB"
```

- If SIZE_MB < 20 → no action.
- If SIZE_MB ≥ 20 → session context is too large and must be compacted:
  - Log: "Session context is large (${SIZE_MB}MB) — compacting now."
  - Use the `/compact` built-in command to compress the session. In skill context this means: output the log line above, then immediately stop further output so OpenClaw triggers compaction on the next interaction.

## Output

- **No issues**: produce no output.
- **Action taken**: post a one-line summary of what was done.
