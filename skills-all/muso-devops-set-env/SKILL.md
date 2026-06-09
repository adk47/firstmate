---
name: muso-devops-set-env
description: |
  DevOps agent only. Set a NON-SECRET production environment variable through a
  guarded, audited, rollback-able wrapper. Autonomous within a blocklist:
  secret-shaped keys (passwords, tokens, keys, DB/connection URLs) are refused
  and routed to a human; only allow-listed targets and authorized requesters
  are accepted; a window rate-cap bounds bursts.
  Use when an authorized human asks to change a prod runtime config value
  (e.g. "set LOG_LEVEL=debug on core-backend", "bump a feature flag",
  "raise a timeout").
  Triggers: "set env var", "environment variable on prod", "change config on",
  "set LOG_LEVEL", "feature flag on prod", "update env".
compatibility: |
  DevOps agent on node-8 (main gateway). Uses the host shell (`exec`) to call
  scripts/devops-set-env.sh. The REAL prod-write backend (kubectl/vault) is
  fail-closed until Phase-0 verification pins the exact write command AND
  Artem/Aaron provision the scoped Vault policy / K8s Role it authenticates as.
  Until then the wrapper runs in `stub`/`OPS_DRY_RUN` only. Requires jq.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-devops-set-env

The only sanctioned path for the DevOps agent to set a production env variable.
Every gate runs **in bash, below you** — you cannot talk past them, and you must
**never bypass the wrapper** by calling `kubectl`/`vault` directly. The blocklist
is enforced under you precisely so that "set a non-secret config var" is safe to
do without a second human approval.

## ⚠️ The blocklist is only half the wall (read this)

You run with `exec security=full, ask=off` and hold a raw Vault AppRole + SSH +
kubectl. A bash blocklist alone cannot stop a determined bypass. Real containment
is a **scoped credential** — a Vault policy / K8s Role that can write ONLY the
allow-listed non-secret keys — which the wrapper authenticates as. That credential
is provisioned by Artem/Aaron, not by this repo. Until it exists and the backend
is Phase-0-pinned, the real write path is fail-closed (`stub`/dry-run only).

## What is autonomous vs. human-routed

- **Autonomous (no second approval):** a non-secret config key, on an allow-listed
  target, requested by an authorized human — e.g. `LOG_LEVEL`, `FEATURE_X_ENABLED`,
  `REQUEST_TIMEOUT_MS`, `RATE_LIMIT_RPS`.
- **Needs an explicit green light (NOT autonomous, NOT a dead-end):**
  - **Secret-shaped keys** (`config/protected-env-keys.txt`): `*SECRET*`, `*PASSWORD*`,
    `*TOKEN*`, `*_KEY` forms, `*CRED*`, and — conservatively — `*_URL`/`*_URI`/DB
    prefixes (URLs embed creds and repointing a service is an exfil vector). When you
    hit `DEVOPS_ENVSET_KEY_BLOCKED`, do **not** route around it: **ask an approver
    (`config/blocklist-override-approvers.txt` — Nick/Aaron) for a green light, WAIT
    for it, then re-run with `--confirmed-by <approver> --approval-msg-id <slack_ts>`.**
    No green light → no set.
- **Always refused (no override):**
  - **Targets not in `config/target-allowlist.txt`**.
- **Bursts**: once the rate threshold trips, a set needs `--confirmed-by` (in the
  requester allowlist) + `--approval-msg-id` from a human.

## How to call it

```bash
SKILL_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-devops-set-env"

# Set a non-secret config value (autonomous if allowed)
bash "$SKILL_DIR/scripts/devops-set-env.sh" --requester <slack_id|email> \
  set --target core-backend --key LOG_LEVEL --value debug \
  --reason "investigating elevated 5xx in #infra-alerts"

# Dry-run first (runs every gate + audit, performs NO write):
OPS_DRY_RUN=1 bash "$SKILL_DIR/scripts/devops-set-env.sh" --requester <id> \
  set --target core-backend --key LOG_LEVEL --value debug

# Show the rollback command for the last change to a key:
bash "$SKILL_DIR/scripts/devops-set-env.sh" --requester <id> \
  rollback --target core-backend --key LOG_LEVEL
```

### When a request hits a blocklisted (secret-shaped) key

Do not refuse and stop. Escalate for a green light:
1. Post to an approver (Nick/Aaron) exactly what's requested — target, key, why.
2. WAIT for an explicit approval message; note its Slack `ts`.
3. Re-run with the green light:
   ```bash
   bash "$SKILL_DIR/scripts/devops-set-env.sh" --requester <driver_id> \
     set --target core-backend --key SOME_SECRET --value '...' \
     --confirmed-by nick --approval-msg-id <slack_ts_of_the_green_light>
   ```
The set is audited with `blocklist_override:true` and the approver. (Secret-class
writes still depend on the Phase-0 backend + scoped credential — see Status.)

The wrapper prints a `↩ rollback:` line after every set — capture it in the Slack
thread so any change is one command to revert.

## Gate order (what the wrapper enforces)

1. **Requester authorized** — resolved email must be in `envset-requesters.txt`
   (fail-closed). This is the "DevOps only" gate. (exit 3)
2. **Key not blocklisted** — secret-shaped → refuse UNLESS a green light is supplied
   (`--confirmed-by` an override-approver + `--approval-msg-id`); fail-closed (a missing
   blocklist treats every key as protected; a missing approver file refuses every
   override). (exit 4)
3. **Target allow-listed** — exact match (fail-closed). (exit 5)
4. **Rate cap** — ≥ threshold sets in the window → require `--confirmed-by` (in
   the requester allowlist) + `--approval-msg-id`. (exit 6)
5. **Audit BEFORE write** — append JSONL (requester, target, key, **prev value for
   rollback**, new value, reason) to the audit log; abort if unwritable. (exit 7)
6. **Record toward the rate window** — fail-closed (an unwritable counter must not
   silently disable the gate). (exit 7)
7. **Backend write** — authenticates as the scoped credential, performs the set.
   Fail-closed until Phase-0-pinned. (exit 8)

## Config (all fail-closed if missing)

- `config/protected-env-keys.txt` — the secret-shaped blocklist (glob, case-insensitive).
- `config/target-allowlist.txt` — allowed targets (exact match). **Placeholder until
  Phase-0 pins the real deployment/app/path identifiers.**
- `config/envset-requesters.txt` — authorized humans (also the rate-cap approver list).

Widening any of these (removing a blocklist entry, adding a target or requester) is a
**policy change** — same scrutiny as widening prod write access.

## Status / what's left (do not skip)

- **Backend is NOT wired to prod.** `DEVOPS_ENVSET_BACKEND` defaults to refuse;
  `kubectl`/`vault` are fail-closed pending Phase-0. `stub` is for tests/demos.
- **Go-live needs:** (a) Phase-0 confirms where prod *non-secret* env actually lives
  (K8s ConfigMap vs `kubectl set env` vs Coolify vs Vault) and pins the write command;
  (b) Artem/Aaron provision the scoped credential; (c) `target-allowlist.txt` gets the
  real identifiers. Only then flip the backend on, and first prove it on a low-stakes
  var (`LOG_LEVEL`) with rollback.
