# Upgrade runbook: openclaw 2026.8.2 → 2026.8.35 (MUS-5079, folds MUS-3411)

**Target is 2026.8.35, not 2026.9.x.** 2026.9.x needs Node `>=24.16 <25`; node-8 runs
v22.23.1. 2026.8.35 declares `engines.node >=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0`
(`npm view openclaw@2026.8.35 engines`) so no Node change. Do not bump Node here.

## What the PR changes (read off npm, 8 Oct)
| Pin | From | To | Where |
|---|---|---|---|
| `openclaw` | 2026.8.2 | 2026.8.35 | `scripts/deploy.sh` `OPENCLAW_VERSION` |
| `@openclaw/slack` | = runtime | = runtime | follows `OPENCLAW_VERSION` |
| `@openclaw/codex` | 2026.8.2 | 2026.8.35 | `scripts/lib/codex-version.sh` |
| `@openai/codex` (bundled) | 0.151.0 | 0.156.1 | `npm view @openclaw/codex@2026.8.35 dependencies` |
| plugin lockfiles | openclaw@2026.8.2 | openclaw@2026.8.35 | `plugins/*/pnpm-lock.yaml` |

The codex ladder is runtime-aware: runtime `>= 2026.8.35` → codex 2026.8.35; runtime
`2026.8.x` below that stays on codex 2026.8.2, so the ExecStartPre healer cannot put the
new plugin on the old core during the merge→deploy window
(`scripts/tests/codex-version-ladder.bats`).

## Model note (do not act on it in this PR)
At codex 0.156.1 the backend model list has `gpt-6-luna`, `gpt-6-sol`, `gpt-6-astra` but
not `gpt-6.1-sol` (first listed at 0.159.3). Whether 0.156.1 accepts the unlisted slug is
UNVERIFIED and is probed on node-8 under MUS-5092. No model string changes in this PR.

## Per-bump checks (CLAUDE.md list) — who runs what
| Check | Static (this PR) | On the box (MUS-5092 / deploy) |
|---|---|---|
| version pin | `codex-version-ladder.bats`, `ensure-codex-version-pinned.bats` | `ensure-codex-version-pinned.sh --check` exit 0 on main+edge |
| refresh-lock convergence | `codex-refresh-lock-shared.bats` (sandboxed `CODEX_LOCK_ROOT`) | after deploy, one lock dir per profile |
| codex auth invariants | `codex-auth-invariants.bats` | `codex-auth-invariants.sh` clean; auth store shape unchanged |
| `OPENCLAW_STATE_DIR` per-profile pin | unchanged by this PR | unit files still carry it |
| `account/rateLimits/read` name | — | grep the 8.35 codex dist for the name |
| `gpt-5.6-*` still serves | — | live turn on main and edge after deploy |

Auth storage shape: this PR does not touch it; confirm on the box that 8.35 does not
migrate `openclaw.sqlite` (fleet-wide risk if it does).

## Rollback
`scripts/downgrade-openclaw-runtime.sh --to 2026.8.2` (8.x → 8.x needs no archive).

## Deploy ordering on 8.35 (added after Deploy HYDRA run 37791745129, 8 Oct)

- 8.35 refuses `plugins install` while a gateway owns the state dir (first contact migrates the 8.2-schema state DB, fenced by `withStateSchemaFence`). `deploy.sh` `stop_gateway_for_plugin_pin` stops the profile's unit before the Step 4d.5 install and forces the Step 6 restart (`HYDRA_FORCE_RESTART=1`). Cost: that gateway is down from the stop until Step 6 brings it back.
- `deploy.sh` records the pre-swap runtime (line 1) and each state DB's `user_version` (line 2) in `/opt/hydra/.pre-deploy-openclaw-version`; Step 4d.5 stops a gateway for the plugin install only when that record exists (the fence fires whenever the binary's version differs from the DB's stamped `app_version`, in 8.2 as in 8.35). `rollback.sh` Step 1c reinstalls the runtime before restarting gateways, but only while every `user_version` is unchanged; otherwise it installs nothing, warns on Slack, keeps the record and still restarts. Step 6 clears the record when it finishes. Never wired to `downgrade-openclaw-runtime.sh` (MUS-5212).
- `openclaw-*.json` openrouter `cost` objects carry all four fields (`cacheRead`, `cacheWrite` required by 8.35).
