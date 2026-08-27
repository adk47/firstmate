---
name: muso-devops-set-env
description: |
  DevOps agent only. Set an environment variable through a guarded, audited,
  rollback-able wrapper. PROD (`--env prod`, the default) is autonomous within a
  blocklist: secret-shaped keys (passwords, tokens, keys, DB/connection URLs) are
  refused and routed to a human for a green-light; only allow-listed targets and
  authorized requesters are accepted; a window rate-cap bounds bursts.
  DEV (`--env dev`) is intentionally broad: an authorized dev requester (Artem;
  Serhii LEFT the company 2026-08-26) may set ANY dev env var — secret-shaped included — with NO green-light;
  the secret VALUE is still redacted in the audit and the set is logged +
  rollback-hinted, contained to the muso-dev scope.
  Use when an authorized human asks to change a runtime config value
  (e.g. "set LOG_LEVEL=debug on core-backend", "bump a feature flag",
  "set TUWUNEL_REGISTRATION_TOKEN on dev core-backend").
  Triggers: "set env var", "environment variable on prod", "set env on dev",
  "dev env var", "change config on", "set LOG_LEVEL", "feature flag", "update env".
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

## PROD vs DEV (`--env`)

`--env` selects the whole rule-set and defaults to **`prod`** (fail-safe — an
omitted flag never applies dev's looser rules to a prod target).

- **`--env prod`** (default): the gates below. Secret-shaped keys need a human
  green-light; requesters = `config/envset-requesters.txt` (narrow); targets =
  `config/target-allowlist.txt` (exact match).
- **`--env dev`**: intentionally broad per Nick's directive (2026-07-17). A dev
  requester (`config/dev-envset-requesters.txt` — Artem, Nick, Aaron; Serhii
  removed 2026-08-26 on leaving the company)
  may set ANY dev env var — **secret-shaped included, with NO green-light**.
  Targets = `config/dev-target-allowlist.txt` (glob, `muso-dev/*`). The secret
  VALUE is still redacted in the audit (`dev_self_serve:true`), the rate-cap still
  bounds bursts (a dev requester can self-ack), and the write is contained to the
  `muso-dev` scope by the backend. **Prod is unaffected — it stays fully gated.**

## What is autonomous vs. human-routed (PROD)

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

# Set a non-secret PROD config value (autonomous if allowed)
bash "$SKILL_DIR/scripts/devops-set-env.sh" --requester <slack_id|email> \
  set --target core-backend --key LOG_LEVEL --value debug \
  --reason "investigating elevated 5xx in #infra-alerts"

# Set a DEV env var (secret-shaped is self-serve for a dev requester — no green-light):
bash "$SKILL_DIR/scripts/devops-set-env.sh" --requester U02N2NP3H7F --env dev \
  set --target muso-dev/core-backend-config --key TUWUNEL_REGISTRATION_TOKEN \
  --value "$(openssl rand -hex 24)" --reason "dev tuwunel registration token"

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

PROD:
- `config/protected-env-keys.txt` — the secret-shaped blocklist (glob, case-insensitive).
  Shared by both envs for *classification* (drives redaction); it only *blocks* in prod.
- `config/target-allowlist.txt` — allowed prod targets (exact match). **Placeholder until
  Phase-0 pins the real deployment/app/path identifiers.**
- `config/envset-requesters.txt` — authorized prod humans (also the rate-cap approver list).
- `config/blocklist-override-approvers.txt` — who can green-light a prod secret.

DEV (`--env dev`):
- `config/dev-envset-requesters.txt` — authorized dev humans (Artem, Nick, Aaron; Serhii removed 2026-08-26);
  also the dev rate-cap self-ack list.
- `config/dev-target-allowlist.txt` — allowed dev targets (glob, e.g. `muso-dev/*`).
- Dev Vault backend env (set at deploy, NOT in repo): `DEVOPS_ENVSET_BACKEND=vault`,
  `DEVOPS_DEV_VAULT_ADDR`, `DEVOPS_DEV_VAULT_TOKEN` (see Status → DEV go-live).

Widening any of these (removing a blocklist entry, adding a target or requester) is a
**policy change** — for prod, the same scrutiny as widening prod write access; for dev,
it grants broad dev authority (still audited + muso-dev-scoped).

## Status / what's left (do not skip)

- **DEV backend is WIRED (fail-closed without creds); PROD is still Phase-0.**
  `DEVOPS_ENVSET_BACKEND` defaults to refuse; `stub` is for tests. `vault` + `--env dev`
  runs the real KV v2 merge-patch (below); `vault` + prod and `kubectl` stay NOT_PINNED.
- **DEV mechanism (verified on node-8, 2026-07-17):** dev env lives in Vault KV v2 at
  `secret/data/k8s/<ns>/<name>` (e.g. `.../k8s/muso-dev/core-backend-config`), ESO-synced
  (30s, `ClusterSecretStore vault-backend`) to the k8s Secret, with `stakater/reloader`
  auto-restarting the consuming pods. A `kubectl patch secret` is NON-durable (ESO
  reverts it). So the wrapper does a Vault merge-patch (`backend=vault`, `--env dev`),
  hard-scoped to `secret/data/k8s/muso-dev/*` — a change propagates to the pods on its own.
- **DEV go-live — one infra step remains (Artem/Aaron, via H-DevOps):** node-8's host has
  NO `vault` CLI, NO `VAULT_*` creds, and Vault's in-cluster address
  (`vault.vault.svc.cluster.local:8200`) is NOT host-reachable. Provision, in the DevOps
  agent's env: `DEVOPS_DEV_VAULT_ADDR` (a node-8-reachable Vault endpoint) +
  `DEVOPS_DEV_VAULT_TOKEN` (a token/AppRole with `read`+`patch` — the wrapper now reads the
  prior value before writing so the audit/rollback prev-value is trustworthy, so `read` is
  required, not optional — on **both** dev namespaces the allowlist permits:
  `secret/data/k8s/muso-dev/*` AND `secret/data/k8s/muso-chat-dev/*`; a broad dev scope is
  fine per Nick's directive), and set `DEVOPS_ENVSET_BACKEND=vault`. Vault policy sketch —
  grant BOTH prefixes, or `muso-chat-dev/*` targets 403 even though the wrapper advertises
  them (`config/dev-target-allowlist.txt` + the backend scope guard both allow chat-dev):
  `path "secret/data/k8s/muso-dev/*"      { capabilities = ["read","patch","create","update"] }`
  `path "secret/data/k8s/muso-chat-dev/*" { capabilities = ["read","patch","create","update"] }`.
  Then prove on a throwaway dev key with rollback before anyone's real token.
- **There is exactly ONE Artem** as of 2026-07-30: Artem (Mobile Developer),
  `U02N2NP3H7F` / `artem@muso.ai`, mapped in `resolve_slack_to_email()`. Artem D
  (Dolobanko, `U0ACHTYUULT`, ex-DevOps Lead) **left the company and was revoked** from
  `dev-envset-requesters.txt` and the UID map — do not re-add him. Older docs describing
  "two Artems" are historical; the allowlist is the authority. Still verify requesters by
  Slack UID, never by display name.
