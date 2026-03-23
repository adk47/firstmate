# Skill: Add Anthropic Account to CLIProxyAPI

> **Trigger**: Aaron asks to add an API key / account to CLIProxyAPI
> **Auth**: Aaron (U7RP6HKUZ) ONLY — reject all others
> **Where**: Node 8 (10.0.0.8), Docker container `cliproxyapi`

## Workflow

This is a **URL exchange** workflow. You cannot SSH yourself. You provide commands, Aaron runs them.

### Step 1: Send the Console URL

Send Aaron this message:

> Create a new API key here:
> https://console.anthropic.com/settings/keys
>
> Send me back the key (starts with `sk-ant-`). I'll store it in Vault and update the config.

Wait for Aaron to reply with the key.

### Step 2: Receive the Key

Aaron sends back a key like `sk-ant-api03-...`. **Do NOT echo the key back in any channel.** Confirm only:

> Got it. I'll store this in Vault and update CLIProxyAPI. Run these commands on node-1 (Vault is on node-1):

### Step 3: Send Vault Commands

Provide these commands for Aaron to run:

```bash
# SSH to node-1 (where Vault runs)
ssh root@10.0.0.1

# Export Vault credentials
export VAULT_ADDR=https://vault.ak.muso.ai
export VAULT_TOKEN=<your-root-token>

# Read current secret to see existing keys
vault kv get secret/muso-prod/hydra-claude-api

# Add the new key alongside the existing one
# ANTHROPIC_API_KEY = primary key (keep existing)
# ANTHROPIC_API_KEY_2 = new account key
vault kv patch secret/muso-prod/hydra-claude-api \
  ANTHROPIC_API_KEY_2="<the-key-aaron-sent>"
```

Wait for Aaron to confirm Vault is updated.

### Step 4: Send CLIProxyAPI Config Update

Provide these commands for Aaron to run on Node 8:

```bash
# SSH to node-8
ssh root@10.0.0.8

# Edit CLIProxyAPI config to add multi-key support
# The config is at /opt/hydra/cliproxyapi.conf (or wherever deployed)
# Add under [auth]:
#   api_key_env_2 = ANTHROPIC_API_KEY_2
#   key_strategy = round-robin    # or "failover"

# Restart the CLIProxyAPI container
docker restart cliproxyapi

# Verify it's healthy
curl -s http://localhost:8317/health
```

Wait for Aaron to confirm the health check passes.

### Step 5: Verify ESO Sync

Provide this for Aaron to run on any node with kubectl:

```bash
# Force ESO to re-sync the secret
kubectl annotate externalsecret hydra-claude-api -n hydra \
  force-sync=$(date +%s) --overwrite

# Verify the new key appears in the K8s secret
kubectl get secret hydra-claude-api -n hydra -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); print([k for k in d.keys()])"

# If running as K8s pod (not Docker), restart the pod
kubectl rollout restart deployment openclaw-gateway -n hydra
```

### Step 6: Confirm

> New Anthropic account added to CLIProxyAPI. Both keys are active.
> - Primary: ANTHROPIC_API_KEY (existing)
> - Secondary: ANTHROPIC_API_KEY_2 (new)
> - Strategy: [round-robin / failover]
> - Health check: passing

## Key Rotation Variant

If Aaron wants to **replace** the existing key (not add a second):

```bash
# On node-1 (Vault)
vault kv put secret/muso-prod/hydra-claude-api \
  ANTHROPIC_API_KEY="<new-key>"

# On node-8 (restart)
docker restart cliproxyapi
```

## Security Rules

- **NEVER log, echo, or display the API key** in any channel, thread, or message
- **NEVER store the key in MEMORY.md** or any workspace file
- Only store in Vault via the commands above
- If the key accidentally appears in a message, immediately alert Aaron and request key rotation
- This skill is Aaron-only (Tier 0) — reject requests from any other user
