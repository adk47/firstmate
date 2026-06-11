---
name: muso-cli
description: |
  Main-gateway agents. The `muso` host binary: one authenticated, policy-gated,
  audited path to the core-backend admin API (prod + dev), Trino SQL, and a
  health probe. SOAK PHASE: opt-in alternative to muso-ops-admin's
  muso-admin-api.sh wrapper — the wrapper remains the documented path for the
  muso-ops-* playbooks (and the ONLY path for credit-request approvals) until
  the post-soak cutover PR.
  Use when: calling admin API endpoints, looking up profiles/tracks/users/
  teams, processing claiming or identity queues, or running Trino SQL — and the
  task is not a credit-request approval.
  Triggers: "muso cli", "muso api", "admin api", "profile lookup", "merge
  profiles", "trino query".
compatibility: |
  Main gateway on node-8 only (NOT edge/Caroline). Binary at
  /usr/local/bin/muso, version-pinned by deploy.sh (MUSO_CLI_VERSION).
  Needs in /etc/openclaw/main.env: MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD
  (auto-login), MUSO_ENV=prod, MUSO_NONINTERACTIVE=1,
  MUSO_STATE_DIR=/var/log/muso-ops (shared guard state with the bash
  wrapper and merge-landing-watchdog). Policy config rendered by deploy.sh
  into /root/.config/muso/ (approvers.txt, bulk-exclude.txt, config.json →
  prewrite_hook = scripts/muso-prewrite-hook.sh, the codex-health gate).
  Output is redaction-aware (no tokens/JWTs) — safe for Slack.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-cli

`muso` is the admin CLI for the Muso.AI platform, built agent-first. It
centralizes what the per-skill bash wrappers each reimplement: JWT auth +
caching, the tier gates (second-human approval, merge reverse-direction guard,
bulk-DELETE cap), the codex-health pre-write gate, requester attribution, and
a fail-closed audit log.

**Read `muso agent-docs` first** — it is the complete self-describing manual:
every command and flag, the exit-code contract, JSON shapes, the verified
admin route map (also: `muso api --list-routes`), the legacy→modern Trino
name table, and the incident-grade warnings.

## Soak-phase boundaries (read this before using)

1. **Credit-request approvals stay on muso-admin-api.sh.** Its browser-evidence
   gate (incidents 2026-04-16/20/22) inspects the openclaw session log and is
   NOT ported. `muso credit-requests set-status --status approved|rejected`
   demands second-human approval artifacts for every call — correct but not
   the autonomous-approval workflow. Keep using the wrapper per muso-ops-credits.
2. **Cutover is batched — follow each playbook's own commands.** Migrated to
   muso (batch 1): muso-audit-profile-credits, muso-query-writer,
   muso-ops-claiming. The remaining muso-ops-* playbooks still document the
   wrapper until their batch lands; use muso for ad-hoc admin calls, lookups,
   and new work.
3. **Reads are unrestricted**; every write goes through the policy gates below.

## Quick reference

```bash
muso health                                  # exit 0 = API healthy
muso profiles search "name" --json           # {items, count}
muso profiles get <id> --json
muso tracks search "title" --json
muso users search "email-or-name" --json     # there is NO get-user-by-id route
muso teams get <teamId> --json
muso claiming list --json
muso api GET '/admin/claiming?status=pending&limit=20' --json   # generic escape hatch
muso query "SELECT ... FROM postgresql_core.public.users LIMIT 5"   # Trino (CSV)
muso query - <<'SQL'                         # stdin for SQL with quotes/parens
SELECT 1
SQL
```

Output: stdout is data only. `--json` always emits exactly ONE top-level JSON
object (lists are `{items, count}`; `muso api` wraps the response as
`{"data": ...}`); `muso query --format json` emits NDJSON rows. Errors are a
single stderr line `{"error":{"code","message","hint"}}` — the hint names the
fix. Exit codes: 0 ok · 1 error · 2 cancelled · 3 not found · 4 auth required
· 5 policy refused.

## Policy gates (what to expect on writes)

| Tier | Trigger | What you must pass |
|---|---|---|
| write | any non-GET | `--requester <email>` |
| dangerous | DELETE; merge/unmerge/reset-password/cancel/revoke paths | + `--yes` |
| approval | profile/track merge+unmerge, impersonate, credit-request status, VIP subscription create, over-cap DELETEs | + `--confirmed-by <approver>` + `--approval-ref <slack-msg-ts>` |

- **Requester is attribution, not authorization** — pass the requesting
  human's **email**. To map a Slack ID to an email, call the wrapper's
  resolver (the one canonical map — do not hand-maintain a copy):
  `bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh resolve-email <SLACK_ID>`
  (e.g. `resolve-email U7RP6HKUZ` → `aaron@muso.ai`). Never set
  MUSO_REQUESTER in a static env file.
- `--confirmed-by` must be an approver from /root/.config/muso/approvers.txt
  (rendered each deploy from the ops workspace tier2-approvers.txt — the
  same list muso-admin-api.sh enforces; read the file for the current
  roster, don't assume it) and `--approval-ref` the Slack ts of their
  in-thread approval. `--yes` does NOT satisfy this tier; neither does requester
  identity. Same doctrine as the wrapper: it runs below the agent — you
  cannot talk your way past it.
- Merges take **named flags only**: `muso profiles merge --into <survivor>
  --from <loser>...` — the confirmation echoes the direction. A merge whose
  IDs overlap one from the last 5 minutes is refused (incident 2026-04-29).
- Every write is audited to `$MUSO_STATE_DIR/audit.jsonl` (fail-closed) and
  echoes the resolved environment on stderr (`>> PROD <<`).
- `--dry-run` prints the redacted request instead of sending — use it to
  preview any write.

## Expected stderr notices (not errors)

- `>> PROD << env: prod (...)` on every write — the environment signal.
- `warning: MUSO_STATE_DIR overrides the default state dir` on DELETE-grade
  ops — deliberate: /var/log/muso-ops is the canonical shared guard state on
  this host.

## Migrating a snippet from muso-admin-api.sh

| wrapper | muso |
|---|---|
| `bash muso-admin-api.sh call GET /admin/x` | `muso api GET /admin/x` |
| `... call POST /admin/x '<json>'` | `muso api POST /admin/x --data '<json>'` |
| `... upload /admin/x /tmp/f.jpg` | `muso api POST /admin/x --file /tmp/f.jpg` |
| `--approval-msg-id <ts>` | `--approval-ref <ts>` |
| `--requester U7RP6HKUZ` | `--requester aaron@muso.ai` (resolve via `resolve-email`, above) |
| output `{http_status, body}` , always exit 0 | `{"data": ...}` on stdout, status via exit code |
| `jq -r '.body.items'` | `jq -r '.data.items'` |
| `bash trino-query.sh "<SQL>"` | `muso query "<SQL>"` (no legacy Athena name rewrites — errors carry the modern-name hint; see agent-docs table) |

## Troubleshooting

- exit 4 / `auth_required`: MUSO_ADMIN_* missing from the gateway env, or the
  cached token died — `muso auth status --check --json` to diagnose.
- exit 5 / `policy_refused`: the message names the missing artifact
  (requester / `--yes` / approval pair) or the tripped gate (bulk cap, merge
  overlap, prewrite hook). The prewrite hook refusing means codex model
  health is degraded — do NOT retry around it; defer to a human.
- `non-JSON response (HTTP 403)`: Cloudflare WAF — you are not on node-8.
