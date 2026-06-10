# Credit Verification

> **Status**: in active development | **Last touched**: 2026-05-06
>
> Documentation for the autonomous credit-verification system that auto-approves Muso credit requests by combining profile-level pattern matching, deterministic API lookups, and LLM-driven web search.

This folder is the source-of-truth documentation for credit verification. Read it in this order if you're new:

1. **[design.md](./design.md)** — what the system does, the 4-tier architecture, the Tier-0 algorithm in detail, and *why* it's shaped this way.
2. **[operations.md](./operations.md)** — env vars, scripts, how to run things, what to do when X breaks.
3. **[lessons.md](./lessons.md)** — bugs caught while building this, engineering principles surfaced, and a changelog of significant shifts. Read before re-touching the gate or jq pipelines.

## tl;dr

The credit-verification bot processes user-submitted credit claims (e.g., "I mastered this Bram Fidder track") and decides between auto-approve, move-to-UVN, or escalate-to-human. Until 2026-05-06 the bot relied almost entirely on browser-driven scraping of `musicbrainz.org` / `music.apple.com` / `discogs.com` / `allmusic.com`. That path is broken (Cloudflare anti-bot), so production approve rate had collapsed to ~3.4% over a 14-day window.

The redesigned system has four tiers:

| Tier | Decision driver | Coverage | Cost | Status |
|---|---|---|---|---|
| **0** | Profile audit (8 gates against profile's own approved corpus → bulk-approve trusted profiles) | ~25% of queue | 1 API call per profile | **shipped 2026-05-06** |
| **1** | Deterministic API (MusicBrainz, Spotify, Discogs by ISRC) | ~10–20% additional | free | partially shipped (helpers ready, awaits Spotify creds + Discogs token) |
| **2** | LLM + native web search (OpenRouter `web` plugin) | ~10–15% additional | included in model API | config live, blocked on local-tool collision |
| **3** | UVN with structured ask (user replies → corpus grows) | residual | none | future work |

Tier-0 is the load-bearing piece that moved the needle from 3.4% to a measured 25%+ on the eligible queue. The other tiers are incremental.

## What lives where

| Component | Path |
|---|---|
| Tier-0 audit script | [`workspaces/operations/skills/muso-ops-credit-verification/scripts/profile-audit.sh`](../../workspaces/operations/skills/muso-ops-credit-verification/scripts/profile-audit.sh) |
| Dispatcher (Tier-0 mode) | [`workspaces/operations/skills/muso-ops-credit-verification/scripts/batch-verify-profile.sh`](../../workspaces/operations/skills/muso-ops-credit-verification/scripts/batch-verify-profile.sh) — invoked as `--tier0 --profile-id <pid>` |
| Approve gate (with Tier-0 evidence path) | [`workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh`](../../workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh) — see `_tier0_audit_recompute_gate` |
| Tier-1 helpers | `scripts/musicbrainz-isrc-lookup.sh`, `scripts/spotify-track-lookup.sh`, `scripts/discogs-isrc-lookup.sh` (same dir) |
| Skill prose (drives the LLM) | [`workspaces/operations/skills/muso-ops-credit-verification/SKILL.md`](../../workspaces/operations/skills/muso-ops-credit-verification/SKILL.md) — see §B1.6 |
| Tests | `scripts/tests/*.bats` in each skill's scripts dir |
| Batch fraud detector (spec) | [`fraud-detection-spec.md`](./fraud-detection-spec.md) — profile-level multi-factor detector that downgrades a backend approve to UVN (`CV_FRAUD_MODE` off/shadow/enforce; batch pipeline only) |
| Live env | `/etc/openclaw/main.env` (sources `OPS_TIER0_ENABLED=1` etc.) |

## Quick smoke test

To verify Tier-0 works end-to-end on hydra in dry-run mode:

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 \
  "set -a; . /etc/openclaw/main.env; set +a;
   export OPS_TIER0_ENABLED=1 OPS_DRY_RUN=1 OPS_RUN_ID=smoke-\$(date +%s)
   export OPS_RUNLOG_DIR=/tmp/cv-smoke OPS_DRY_RUN_AUDIT_PATH=/tmp/cv-smoke-audit.jsonl
   mkdir -p \$OPS_RUNLOG_DIR/\$(date -u +%Y-%m-%d)
   bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/batch-verify-profile.sh \
     --tier0 --profile-id 5be65d80-044f-4161-8ea2-7bb4bba3175e | tail -1"
```

Expected output ends with: `[batch-verify-profile.sh] tier0: approved <N> credits for profile 5be65d80-... (profile_audit:cc=694,...)`. The dry-run interceptor catches the actual PUT.

If Alpha Mastering's queue has been drained, swap in any other established profile UUID.

## Open issues

See [operations.md § Known issues](./operations.md#known-issues) for the current open list. Highlights:

- Browser path still drives B2 (per-credit Tier-1) and is broken; `docs/credit-verification/lessons.md` § "Browser removal proposal" has the path forward.
- OpenRouter native web search is configured but blocked by an openclaw local-tool naming collision.
- `post-batch-summary.sh` refuses to post when B2 leaves uncovered profiles even though Tier-0 succeeded; needs an "allow partial" mode.
