# OpenClaw Environment Setup

## Critical: Environment Variables for CLI Tools

**OpenClaw runs as a launchd service with its own isolated environment.**

CLI tools (Stripe, AWS, etc.) need their credentials accessible to the OpenClaw gateway process, not just your user shell.

### Adding Environment Variables to OpenClaw

**File:** `~/Library/LaunchAgents/ai.openclaw.gateway.plist`

Add variables to the `EnvironmentVariables` dict:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>HOME</key>
  <string>/Users/admin</string>
  <key>PATH</key>
  <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>

  <!-- Add your variables here -->
  <key>STRIPE_API_KEY</key>
  <string>rk_live_xxxxx</string>

  <key>AWS_PROFILE</key>
  <string>muso-flagship-readonly</string>

  <key>AWS_REGION</key>
  <string>us-west-2</string>
</dict>
```

**After editing, reload the service:**

```bash
launchctl unload ~/Library/LaunchAgents/ai.openclaw.gateway.plist
launchctl load ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

## Why This Matters

❌ **Won't work:** Setting variables in `~/.zshrc` or `~/.bashrc`
❌ **Won't work:** Running `export VAR=value` in your terminal
❌ **Won't work:** CLI tool config files in `~/.config/` (unless the tool supports env vars)

✅ **Will work:** Adding to the launchd plist `EnvironmentVariables` section

## Current Configuration

The OpenClaw gateway is configured with:

- `STRIPE_API_KEY` - Muso restricted Stripe key (rk_live_*)
- `HOME` - User home directory
- `PATH` - Standard binary paths
- `OPENCLAW_*` - Gateway configuration variables

## Troubleshooting

**Symptom:** CLI tool works in terminal but fails when Clio runs it

**Cause:** Tool needs credentials/config that's only in your user environment

**Solution:**
1. Identify what environment variable or config the tool needs
2. Add it to the plist `EnvironmentVariables` section
3. Reload the launchd service
4. Test in Slack

**Example - Stripe CLI:**
- Tool: `stripe`
- Needs: `STRIPE_API_KEY` environment variable OR `~/.config/stripe/config.toml`
- Fix: Added `STRIPE_API_KEY` to plist
- Result: `stripe refunds list` works in Slack

## Reference

- Launchd plist location: `~/Library/LaunchAgents/ai.openclaw.gateway.plist`
- Gateway logs: `$OPENCLAW_HOME/logs/gateway.log` (default `$HOME/.openclaw`)
- Reload command: `launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway`
