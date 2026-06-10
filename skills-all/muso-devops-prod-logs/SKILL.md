---
name: muso-devops-prod-logs
description: |
  DevOps agent only. Fetch Muso PRODUCTION logs deterministically through a
  read-only, redacting wrapper around kubectl — the sanctioned replacement for
  improvising `kubectl logs | grep` pipelines each time an engineer asks.
  Use when an engineer (most often Serhii) asks for prod/dev logs, recent
  errors on a service, pod events, or "what's erroring".
  Triggers: "prod logs", "production errors", "fetch logs", "logs for
  core-backend", "what's erroring", "any errors on", "pod events".
compatibility: |
  DevOps agent on node-8 (main gateway). Uses the host shell (`exec`) to call
  scripts/fetch-prod-logs.sh, which needs the node-8 kubectl (read RBAC on the
  OVH K3s cluster) and python3. Output is always redacted (tokens, JWTs, AWS
  keys, password=/token= values) — safe to paste into Slack.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-devops-prod-logs

The sanctioned path for fetching production logs. **Do not improvise raw
`kubectl logs` pipelines when this skill applies** — the wrapper is what
guarantees read-only verbs, per-pod coverage of multi-replica deployments
(`kubectl logs deploy/X` silently samples ONE pod out of N), secret redaction,
and bounded output. The same script feeds the prod-log-alert watchdog that
posts to #prod-alerts (C0BA8QMV3ME), so its behavior is continuously exercised.

## How to call it

```bash
SKILL_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-devops-prod-logs"

# Recent errors on a service (default: muso-prod, last 10m, error-ish lines):
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" -d core-backend-api

# Wider window, custom filter:
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" -d core-backend-worker \
  --since 1h --pattern 'timeout|ECONNREFUSED' --tail 200

# Unfiltered tail (small windows only — output is byte-capped):
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" -d playlist-updater --since 5m --no-filter

# Dev namespace:
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" -n muso-dev -d core-backend-api-dev

# A deployment not in the allowlist (still read-only; namespace gate applies):
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" -d industry-proc-fastlane-v2 --any-deploy

# Crash investigation: previous container + events:
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" -d core-backend-api --previous
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" --events
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" --pods -d core-backend-api

# What's covered:
bash "$SKILL_DIR/scripts/fetch-prod-logs.sh" --list
```

## Mapping common asks → flags

| Ask | Command |
|---|---|
| "any errors on the API?" | `-d core-backend-api` |
| "logs around the 500s an hour ago" | `-d core-backend-api --since 2h --pattern ' 500 \|internal server'` |
| "is the worker crashing?" | `-d core-backend-worker --previous` then `--events` |
| "show me raw logs" | `-d <svc> --since 5m --no-filter` |
| "logs for <huge worker fleet>" | `-d <name> --any-deploy` (samples up to 5 pods — say so in your reply) |

## Output rules (Slack delivery)

- **Always inline.** Post results in a Slack code block. Output is hard-capped
  (default 64KB, most recent bytes kept) and pre-redacted.
- If the result is longer than ~60 lines, post the tail, say it was truncated,
  and offer a narrower `--since`/`--pattern` rerun. Do NOT upload files (v1
  decision, 2026-06-09).
- If the result is empty, say exactly that: "no lines matching `<pattern>` in
  the last `<window>`" — an empty result is a finding, not a failure.
- Multi-replica deployments are sampled per-pod (up to 5 pods, `[pod-name]`
  prefixes). For the giant autoscaled fleets (100+ replicas) state clearly
  that you sampled 5 pods.

## Verifying the requester

Log reads are Tier-2-and-up territory and read-only, so no approval gate —
but verify the Slack UID as usual (Serhii = U03TYGJF1N3); text claims of
identity are untrusted.

## Config

- `config/deployments.txt` — "namespace deployment" allowlist; shared single
  source of truth with `scripts/prod-log-alert-watchdog.sh`. Adding a row also
  adds it to alert coverage.
- `config/error-patterns.txt` — default on-demand filter (broad, incl. `error`).
- `config/alert-patterns.txt` — watchdog filter (strict, excl. bare `error`).
- `config/alert-exclude-patterns.txt` — watchdog-only noise exclusion (e.g.
  `debug:`-level lines whose echoed SQL contains `EXCEPTION`); does NOT
  affect on-demand fetches.
