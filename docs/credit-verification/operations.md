# Credit Verification — Operations

> **Version**: 1.0 | **Date**: 2026-05-06
>
> Runbook for operating the credit-verification system. Read this if you're triggering a batch, debugging a stuck run, or responding to an incident. For *why* the system is shaped this way, see [design.md](./design.md).

## Table of contents

1. [Triggers](#1-triggers)
2. [Environment variables](#2-environment-variables)
3. [Scripts and their entry points](#3-scripts-and-their-entry-points)
4. [Where data lives](#4-where-data-lives)
5. [How to run a dry-run](#5-how-to-run-a-dry-run)
6. [How to run a real-mode batch](#6-how-to-run-a-real-mode-batch)
7. [Configuring Tier-2](#7-configuring-tier-2)
8. [Troubleshooting](#8-troubleshooting)
9. [Known issues](#9-known-issues)
10. [Emergency: rollback](#10-emergency-rollback)

---

## 1. Triggers

### Reactive (Slack @-mention)

In `#credit-verification` (channel `C0APB2CMM7C`):

```
@Ops run credit verification batch
@Ops run credit verification batch (dry-run)
@Ops verify unverified credits of profile <UUID>
```

Authorized senders for the on-demand batch: Aaron (`U7RP6HKUZ`), Jan (`U038BM16T7W`), Nick (`U0AL36NADEY`). Other senders fall through to the standard SOUL.md "Write Operations — Approval Required" flow.

### Cron

Task `credit-verification-batch-4h`: schedule `0 */4 * * *` UTC, six runs/day at 0/4/8/12/16/20.

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 "openclaw --profile main cron list | grep credit-verification"
```

### Dry-run mode

Adding `(dry-run)`, `[dry-run]`, `dry run`, or `dryrun` (case-insensitive) to the trigger message sets `OPS_DRY_RUN=1` for that run. Effects:

- Slack output routed to the dry-run channel (`OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID`)
- All non-GET admin-API writes intercepted with synthetic `{http_status:200, dryRun:true, body:null, wouldHaveExecuted:true}`
- Audit JSONL appended to `${OPS_DRY_RUN_AUDIT_PATH:-/tmp/ops-dry-run-audit.jsonl}`
- Jan-paging on escalations is skipped
- The `[DRY RUN]` prefix is prepended to all Slack posts

## 2. Environment variables

Set in `/etc/openclaw/main.env` (also `/etc/openclaw/shared.env`). Gateway reads these via systemd `EnvironmentFile=` directives.

### Tier-0 controls

| Var | Default | Purpose |
|---|---|---|
| `OPS_TIER0_ENABLED` | (unset) | Set to `1` to enable Tier-0 audit. Without this, `profile-audit.sh` exits 2 (disabled) — fail-closed. |
| `CV_TIER0_MIN_BATCH` | 20 | G0: minimum unverified count to even audit |
| `CV_TIER0_MIN_CC` | 100 | G1: `profile.creditCount` floor |
| `CV_TIER0_MIN_POP` | 50 | G2: `profile.popularity` floor |
| `CV_TIER0_MIN_INDUSTRY` | 0.70 | G3: industry-source fraction floor |
| `CV_TIER0_MIN_ONLY_VEL` | 0.70 | G4: only-velocity-flag fraction floor |
| `CV_TIER0_MIN_ARTIST_OVERLAP` | 0.40 | G7: artist co-occurrence floor |
| `CV_TIER0_MIN_LABEL_OVERLAP` | 0.30 | G8: label overlap floor |
| `CV_TIER0_POP_TOLERANCE_FRAC` | 0.05 | Gate's receipt-vs-live `pop` cross-check tolerance |

### Batch flow

| Var | Default | Purpose |
|---|---|---|
| `OPS_BATCH_FETCH_SIZE` | 10 (default) — set to 500 in prod | Credits fetched per batch |
| `OPS_BATCH_LOCK_PATH` | `/var/run/credit-batch-main.lock` | Single-run-at-a-time mutex |
| `OPS_RUNLOG_DIR` | `/var/log/openclaw/credit-batch-runs` | Where JSONL runlogs live |
| `OPS_RUN_ID` | (set by `runlog.sh init`) | Batch run identifier |
| `OPS_BATCH_ENABLED` | `true` | Master enable for cron batches |
| `OPS_VERIFICATION_FALLBACK_TO_ESCALATE` | `1` | Route INCONCLUSIVE verdicts to per-credit Slack escalation (vs UVN) |

### Dry-run

| Var | Default | Purpose |
|---|---|---|
| `OPS_DRY_RUN` | 0 | `1` enables dry-run interception |
| `OPS_DRY_RUN_AUDIT_PATH` | `/tmp/ops-dry-run-audit.jsonl` | Where would-have-executed writes are logged |
| `OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID` | `C0APB2CMM7C` | Slack channel for dry-run posts (currently same as prod; consider splitting) |

### Tier-1 API auth (when present)

| Var | Default | Purpose |
|---|---|---|
| `MUSO_API_URL` | `https://api.muso.ai/api/v3` | Muso admin API base |
| `MUSO_ADMIN_EMAIL` / `MUSO_ADMIN_PASSWORD` | (set) | Admin API auth credentials |
| `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` | **NOT SET** | Spotify Web API OAuth (blocking Tier-1 Spotify path; in k8s secrets, needs propagation) |
| `DISCOGS_TOKEN` | **NOT SET** | Discogs API token (blocking Tier-1 Discogs path; sign up at https://www.discogs.com/settings/developers, 30s, free) |

## 3. Scripts and their entry points

All under `workspaces/operations/skills/muso-ops-credit-verification/scripts/` unless noted:

| Script | Entry point | Purpose |
|---|---|---|
| `profile-audit.sh` | `profile-audit.sh <profile_id>` | Tier-0 8-gate auditor; emits receipt or skips |
| `batch-verify-profile.sh` | `batch-verify-profile.sh --tier0 --profile-id <pid>` | Tier-0 dispatcher: runs audit, captures receipt, calls admin API |
| `batch-verify-profile.sh` | `batch-verify-profile.sh --decision approve\|flag --ids ... --evidence-excerpt ...` | Per-credit dispatcher (B2 path); pre-flights browser-evidence quorum |
| `musicbrainz-isrc-lookup.sh` | `musicbrainz-isrc-lookup.sh <ISRC> [--credited-name N --role R]` | Tier-1 MB by ISRC |
| `spotify-track-lookup.sh` | `spotify-track-lookup.sh <spotify_track_id> [--credited-name N --role R]` | Tier-1 Spotify by trackId (awaits creds) |
| `runlog.sh` | `runlog.sh init` / `runlog.sh event <run_id> <name> <json>` | JSONL event writer; freeze-after-fail |
| `preflight-verify.sh` | `preflight-verify.sh <run_id>` | Browser probe (Björk MB page); B0d gate |
| `count-approvals.sh` | `count-approvals.sh` | Daily approval count (matches `operator==clio AND requester==clio AND status==approved`) |
| `compute-run-summary.sh` | `compute-run-summary.sh --final <run_id>` | Emits `run_finished` event from runlog + results.jsonl reconciliation |
| `post-batch-summary.sh` | `post-batch-summary.sh <run_id>` | Posts the Slack summary message; refuses on failure shapes |
| `browser-evidence-audit.sh` | `browser-evidence-audit.sh --runlog <path>` | Independent audit of decision events; checks Tier-1 anchors OR Tier-0 anchors |
| (admin skill) `muso-admin-api.sh` | `muso-admin-api.sh [global flags] call <METHOD> <path> [body]` | All Muso admin API calls; runs `enforce_credit_approve_gate` for approve PUTs |

Global flags on `muso-admin-api.sh`:
- `--evidence-excerpt <str>` — required for autonomous credit approves
- `--profile-audit-id <pid>` — required for `profile_audit:` evidence path
- `--requester <email-or-known-synthetic>` — `clio` (the bot) is recognized; `jan@muso.ai` / `aaron@muso.ai` bypass the gate (manual override)
- `--confirmed-by <email>`, `--approval-msg-id <ts>` — Tier-2 approval gate (incident 2026-04-29)

## 4. Where data lives

| Path | Contents |
|---|---|
| `/var/log/openclaw/credit-batch-runs/YYYY-MM-DD/<run_id>.jsonl` | Per-batch event runlog (truth floor for B6 summary) |
| `/var/log/openclaw/credit-batch-runs/YYYY-MM-DD/<run_id>.results.jsonl` | Per-batch results from each `muso-admin-api.sh call PUT /admin/credit-requests` (used for reconciliation) |
| `/root/.openclaw-main/agents/operations/sessions/<sess_id>.jsonl` | Bot's per-session message+toolCall transcript |
| `/root/.openclaw-main/agents/operations/sessions/<sess_id>.trajectory.jsonl` | Trace metadata for the same session (model info, fallbacks, timing) |
| `/etc/openclaw/main.env` | Gateway environment (loaded at systemd start) |
| `/var/log/openclaw/credit-batch-runs/latest.txt` | Pointer to the most recent runlog (used by gate for run-window scoping) |
| `/tmp/ops-dry-run-audit.jsonl` | Default dry-run audit (every would-have-executed write logged here) |
| `journalctl -u openclaw-gateway-main` | Gateway logs: tool calls, model fallbacks, reload events |

## 5. How to run a dry-run

In Slack:

```
@Ops run credit verification batch (dry-run)
```

What you should see:

1. Bot reacts with `:eyes:` emoji on your message
2. Bot posts opening line: "Starting credit verification batch — Run ID: `<RUN_ID>`, Queue depth: <N>, This run: <M> credits across <K> profile groups"
3. Bot iterates Tier-0 deterministically (visible in runlog)
4. Bot posts per-profile progress ticks (currently buggy; see [§9 Known issues](#9-known-issues))
5. Bot posts the closing summary

To watch in real time from your laptop:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "today=/var/log/openclaw/credit-batch-runs/\$(date -u +%Y-%m-%d);
   while true; do
     latest=\$(ls -t \$today/*.jsonl 2>/dev/null | grep -v results | head -1);
     [ -n \"\$latest\" ] && tail -F \"\$latest\" 2>/dev/null;
     sleep 5;
   done | jq -rc 'select(.event|test(\"tier0|run_finished|action_attempted\"))
                 | [(.ts // \"-\")[11:19], .event, (.profile_id // \"-\")[0:8],
                    (.reason // .receipt // .action // \"\")[:80]]
                 | @tsv'"
```

Manual smoke test of one profile (no Slack involvement):

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "set -a; . /etc/openclaw/main.env; set +a;
   export OPS_TIER0_ENABLED=1 OPS_DRY_RUN=1 OPS_RUN_ID=manual-\$(date +%s)
   export OPS_RUNLOG_DIR=/tmp/cv-manual OPS_DRY_RUN_AUDIT_PATH=/tmp/cv-manual-audit.jsonl
   mkdir -p \$OPS_RUNLOG_DIR/\$(date -u +%Y-%m-%d)
   bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/batch-verify-profile.sh \
     --tier0 --profile-id <PROFILE_UUID>"
```

## 6. How to run a real-mode batch

Same as dry-run but without the `(dry-run)` suffix:

```
@Ops run credit verification batch
```

⚠️ **Pre-flight checklist**:
- [ ] Has Aaron / Jan signed off on the canary cohort?
- [ ] Are there spot-check eyes available (someone watching the audit log live)?
- [ ] Does `journalctl -u openclaw-gateway-main` show the gateway healthy?
- [ ] Is the daily approval cap (500/UTC-day per `count-approvals.sh`) far enough below ceiling that a 200-500-credit batch won't push us over?
- [ ] Is `cron-jobs.json` task `credit-verification-batch-4h` currently in `skipped` status? If so, why? Investigate before triggering.

## 7. Configuring Tier-2

OpenRouter web search via `extra_body` (no extra API keys; native search included in model API cost on supporting models):

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "openclaw --profile main config set 'agents.list[6].params.extra_body' \
     '{\"plugins\":[{\"id\":\"web\",\"engine\":\"native\",\"max_results\":5}]}' \
     --strict-json"
```

Index 6 is the operations agent; verify with:

```bash
openclaw --profile main config get 'agents.list' \
  | jq 'to_entries | map(select(.value.id=="operations")) | .[0].key'
```

OpenRouter accepts `engine: "native" | "exa" | "firecrawl" | "parallel"`. **Don't use `"auto"`** — OpenRouter rejects it with `400 plugins.0.engine: Invalid option`.

After the config set, the gateway hot-reloads (`[reload] config hot reload applied (agents.list)` in journal). No restart needed.

To see citations from a request:

```bash
# Run a benign probe and check the model output for inline Markdown URLs
@Ops Quick test — search the web for any recent music release. Cite source URLs.
```

If citations don't appear, see [§9 Known issues / OpenRouter local-tool collision](#openrouter-local-web_search-tool-collision).

## 8. Troubleshooting

### Bot says "browser tool unavailable"

Browser is almost certainly *available*; the timeouts come from Cloudflare Turnstile blocking headless Chromium on the Tier-1 hosts (musicbrainz/apple/discogs/allmusic). Verify directly:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 "openclaw --profile main browser doctor"
```

If `browser doctor` returns OK, the issue is anti-bot blocking, not the browser plugin. Long-term fix: drop the browser path entirely (see [design.md § Why drop browser at all](./design.md#why-drop-browser-at-all)).

### Bot stalls in B2 / no Slack summary posts

Cause: bot did Tier-0 successfully but B2 (per-credit Tier-1 browser path) hit Cloudflare or timed out. `compute-run-summary.sh` and `post-batch-summary.sh` refuse to post when the run is incomplete (`queue_depth > 0` AND uncovered profiles exist).

Force the summary manually:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "set -a; . /etc/openclaw/main.env; set +a;
   export OPS_RUN_ID=<run_id> OPS_DRY_RUN=<0_or_1> OPS_BATCH_TERMINAL=1 CV_SESSION_MAX_AGE_MIN=120
   bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/compute-run-summary.sh --final \$OPS_RUN_ID"
```

That emits the `run_finished` event. The summary post may still refuse if `browser-evidence-audit.sh` blocks; that's the deeper fix (see [§9 Known issues](#9-known-issues)).

### `Argument list too long` on jq

Symptom in the runlog: a tier0 audit on a high-volume profile errors with `/usr/bin/jq: Argument list too long`. Root cause is `--argjson` of a large JSON array exceeding Linux `ARG_MAX` (~128 KB).

This was fixed in `profile-audit.sh` and `muso-admin-api.sh` on 2026-05-06 (use derived facts objects instead of raw items). If you see it again, the regression is in a script that re-introduced `--argjson <large_var>`. Search for `--argjson [a-z_]+ "\$[A-Z_]*ITEMS"` patterns and convert to derived-facts.

### `--requester clio` exits silently

Fixed 2026-05-06. If you see it again, regression is in `muso-admin-api.sh`'s arg parser. The fix:

```bash
--requester)
    REQUESTER_EMAIL=$(resolve_slack_to_email "$2") || REQUESTER_EMAIL="$2"
    shift 2
```

The `|| REQUESTER_EMAIL="$2"` defense-in-depth prevents `set -e` from exiting silently when `resolve_slack_to_email` returns 1 for unknown synthetics.

## 9. Known issues

### Browser-evidence audit blocks Tier-0-only summary posts

When Tier-0 succeeds but B2 leaves uncovered profiles, `browser-evidence-audit.sh` refuses (correctly — the run is incomplete). But there's no "Tier-0 OK, B2 incomplete" partial-summary mode. Workaround: manual force per [§8 Troubleshooting](#bot-stalls-in-b2--no-slack-summary-posts).

Long-term fix: add `--allow-partial` to `post-batch-summary.sh` + an EXIT trap on the B0-B1 bash blob. Tracked in [lessons.md § Outstanding work](./lessons.md#outstanding-work).

### OpenRouter local web_search tool collision

`agents.list[6].params.extra_body.plugins` is set with `engine:"native"` but the model preferentially calls openclaw's local `web_search` tool (which has no provider configured) before reaching for the OpenRouter plugin path. Result: `web_search disabled` errors and the model improvises with `exec curl`.

Fix: drop `web_search` from the operations agent's tool list:

```bash
openclaw --profile main config set 'agents.list[6].tools.deny' '["web_search"]' --strict-json
```

Untested as of 2026-05-06; ship as part of the browser-removal iteration.

### Cron task `credit-verification-batch-4h` shows `skipped`

The autonomous 4-hourly cron shows `skipped` in `openclaw cron list` for several recent runs. Pre-existing issue, root cause not yet investigated. Reactive `@Ops` triggers work fine; only the autonomous schedule is affected. Suspect a watchdog disable or scheduler-state issue. Investigate before relying on cron for autonomous operation.

### Spotify Web API helper is deployed but creds are missing

`spotify-track-lookup.sh` returns exit 4 (`credentials missing`) until `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` are propagated from k8s secrets into `/etc/openclaw/main.env`. Helper, tests, and integration are otherwise complete. Estimated 10 min for someone with k8s access.

### Discogs not yet integrated

No token. Sign up at https://www.discogs.com/settings/developers (30s, free), set `DISCOGS_TOKEN` in `/etc/openclaw/main.env`, and a future helper script `discogs-isrc-lookup.sh` can be added (currently stub-only). High value for engineer/mastering credits which dominate the unverified queue.

## 10. Emergency: rollback

If Tier-0 produces bad approves in production:

### Disable Tier-0 immediately

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "sed -i.bak '/^OPS_TIER0_ENABLED=/d' /etc/openclaw/main.env;
   systemctl restart openclaw-gateway-main"
```

`profile-audit.sh` will exit 2 (disabled) on next call. Runs continue with the existing per-credit B2 path only. Reactive triggers and cron continue to work; just the new tier doesn't fire.

### Reverse a bad approve batch

The bot sets `requester=clio` on its approves. Find them:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "grep '\"requester\":\"clio\"' /var/log/openclaw/credit-batch-runs/\$(date -u +%Y-%m-%d)/<run_id>.results.jsonl"
```

Bulk-revert via admin API (Jan or Aaron must do this with their own `--requester`):

```bash
muso-admin-api.sh --requester jan@muso.ai \
  call PUT /admin/credit-requests \
  '{"requestIds":[<bad_ids>...], "status":"unverified", "reason":"reverting tier0 misfire"}'
```

### Restore previous gate version

The gate file is backed up automatically on every deploy:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "ls -t /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh.bak.* | head -3"
```

Pick the timestamp before the change and:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "cp /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh.bak.<TS> \
       /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh;
   chmod +x /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
```

No gateway restart needed — bash scripts are read on each invocation.
