# OpenClaw Slack Streaming Fix

## Problem

OpenClaw processes Slack messages (eyes emoji appears and is removed) but **no reply is posted**. The gateway logs show:

```
slack-stream: failed to stop stream: Error: An API error occurred: missing_recipient_team_id
```

or after partial fix:

```
slack-stream: failed to stop stream: Error: An API error occurred: missing_recipient_user_id
```

## Root Cause

OpenClaw uses Slack's streaming API (`chat.startStream` / `chat.appendStream` / `chat.stopStream`) for real-time reply delivery. These APIs require `recipient_team_id` and `recipient_user_id` parameters for non-DM channels, but OpenClaw does not pass them.

The bug is in the `startSlackStream()` function across 5 dist files. The `client.chatStream()` call only passes `channel` and `thread_ts`, missing the two required recipient fields.

## Affected Files

All 5 files contain identical copies of the bug:

```
/opt/homebrew/lib/node_modules/openclaw/dist/reply-oSe13ewW.js
/opt/homebrew/lib/node_modules/openclaw/dist/subagent-registry-DN6TUJw4.js
/opt/homebrew/lib/node_modules/openclaw/dist/pi-embedded-_crSbDV9.js
/opt/homebrew/lib/node_modules/openclaw/dist/pi-embedded-BxoxxVJz.js
/opt/homebrew/lib/node_modules/openclaw/dist/plugin-sdk/reply-BKdTPI2b.js
```

**Note:** Filenames include content hashes and will change between OpenClaw versions. Use `grep -rl "client.chatStream" /opt/homebrew/lib/node_modules/openclaw/dist/` to find them.

## Fix

Two changes per file:

### 1. Patch the function definition

Find `startSlackStream` and add recipient params to the `chatStream()` call:

**Before:**
```javascript
const streamer = client.chatStream({
    channel,
    thread_ts: threadTs
});
```

**After:**
```javascript
const streamer = client.chatStream({
    channel,
    thread_ts: threadTs,
    recipient_team_id: "T7SAJ638C",
    recipient_user_id: params.recipientUserId || undefined
});
```

### 2. Patch the call site

Find where `startSlackStream({` is called and pass the user ID:

**Before:**
```javascript
streamSession = await startSlackStream({
    client: ctx.app.client,
    channel: message.channel,
    threadTs: streamThreadTs,
    text
});
```

**After:**
```javascript
streamSession = await startSlackStream({
    client: ctx.app.client,
    channel: message.channel,
    threadTs: streamThreadTs,
    text,
    recipientUserId: message.user
});
```

## Automated Patch Script

Run this after any OpenClaw update to re-apply the fix:

```bash
python3 -c "
import glob

# Find all files with the bug
files = glob.glob('/opt/homebrew/lib/node_modules/openclaw/dist/**/*.js', recursive=True)
targets = [f for f in files if open(f).read().count('client.chatStream(') > 0]

TEAM_ID = 'T7SAJ638C'

# Patch 1: function definition
old_def = '''	const streamer = client.chatStream({
		channel,
		thread_ts: threadTs
	});'''
new_def = '''	const streamer = client.chatStream({
		channel,
		thread_ts: threadTs,
		recipient_team_id: \"''' + TEAM_ID + '''\",
		recipient_user_id: params.recipientUserId || undefined
	});'''

# Patch 2: call site
old_call = '''			streamSession = await startSlackStream({
					client: ctx.app.client,
					channel: message.channel,
					threadTs: streamThreadTs,
					text
				});'''
new_call = '''			streamSession = await startSlackStream({
					client: ctx.app.client,
					channel: message.channel,
					threadTs: streamThreadTs,
					text,
					recipientUserId: message.user
				});'''

for f in targets:
    content = open(f).read()
    changed = False
    if old_def in content:
        content = content.replace(old_def, new_def)
        changed = True
    if old_call in content:
        content = content.replace(old_call, new_call)
        changed = True
    if changed:
        open(f, 'w').write(content)
        print(f'Patched: {f}')
    else:
        print(f'Skipped (already patched or different format): {f}')

print('Done. Restart gateway: openclaw gateway stop && openclaw gateway install')
"
```

## After Patching

```bash
openclaw gateway stop
sleep 2
kill -9 $(pgrep -f openclaw-gateway) 2>/dev/null
sleep 1
openclaw gateway install
```

## Key Values

| Value | Source | Notes |
|-------|--------|-------|
| `T7SAJ638C` | Muso Slack workspace team ID | From `curl -s https://slack.com/api/auth.test -H "Authorization: Bearer $BOT_TOKEN"` |
| `message.user` | Slack event payload | The user who sent the message; passed dynamically |

## Verification

1. Send a message to Clio in `#clio_analyst`
2. Eyes emoji should appear, then be removed
3. A reply should stream in within a few seconds
4. Check logs for errors: `openclaw logs 2>&1 | grep "slack-stream"`

## When to Re-apply

This patch must be re-applied after every `npm install -g openclaw` or OpenClaw version update, as it modifies files inside `node_modules`. The dist filenames will change between versions but the patch script uses glob matching to find them automatically.

## Related Issues

- **Auth profiles**: If you see `No API key found for provider "anthropic"`, check `$OPENCLAW_HOME/agents/main/agent/auth-profiles.json` and `auth.json`. Run `openclaw configure` to re-set credentials.
- **Stale gateway**: Always use `kill -9 $(pgrep -f openclaw-gateway)` between stop/start — the process sometimes survives `openclaw gateway stop`.
