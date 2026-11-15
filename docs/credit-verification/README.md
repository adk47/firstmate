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
| AI credit reviewer + approval auditor (2026-10-11) | [`ai-credit-reviewer.md`](./ai-credit-reviewer.md): hourly read-only audit of every approval (trusted sources, identity, velocity, approver), model + web search behind a flag, pre-approval reviewer in shadow |
| Supporting-document forensics, shadow (2026-10-15) | [`proof-forensics.md`](./proof-forensics.md): every proof from Intercom (and email once verify@ exists), matched by account, analysed in a no-network sandbox (provenance/C2PA, PDF revisions and signatures, overlays, OCR content checks, cross-account reuse) to a deterministic verdict; store only, no writes, no sends. **Stage 2 shadow** (2026-10-19): the decider's proof-on-file holds judged from those documents (what it would approve), recorded only |
| Verifier eval, shadow (2026-10-28) | [`verifier-eval.md`](./verifier-eval.md): frozen labelled credits / claims / merges sets + a runner that replays any verifier (or recorded shadow log) and scores precision, recall and must-be-zero false-approve / guard violations per class, paid first; nightly on node-8, board line in `/var/lib/hydra/verifier-eval/latest/` |
| The proof path (2026-11-13) | [`proof-path.md`](./proof-path.md): file, read, decide, mark, review, tell - the one job that owns each stage of a customer's document, the feeder's saved-as-it-goes window, the marker that sets `proof_tagged_at` from the documents on file, what retires with its replacement, and what is not armed |
| Doc-verify, shadow (2026-10-26) | [`doc-verify.md`](./doc-verify.md): every returned document's claims (issuer, signatory, sender domain, tracks, roles, dates) extracted by deepseek-v4.1-flash-1017 and checked against sources the user does not control (Spotify/Tidal raw credits, MusicBrainz, Deezer, the issuer's independently found official domain + MX, the signatory on its site) on top of H3 forensics: verified / contradicted / forged / unverifiable; UNKNOWN never approves; no issuer emails, no customer copy |
| DSP evidence verifier, shadow (2026-10-28) | [`dsp-evidence-verifier.md`](./dsp-evidence-verifier.md): per pending request, a verdict (APPROVE / DECLINE / WAIT / DUPLICATE) from same-run Spotify AND Tidal fresh captures read by linked contributor id (never a name), one-person-role contradictions on both DSPs, the account gate, big/common/flagged guards and the org label-string lane; logged with evidence to its own append-only store; never writes to core; runs as its own job, never inside Caroline |
| Profile-merge verifier, shadow (2026-10-28) | [`merge-verify.md`](./merge-verify.md): one verdict per open `action:profile-merge` ticket (m1's 235-ticket re-read order + core's merge guards + owner thread, paid seat, big/common/flagged guard, Spotify/Tidal same-person anchor), the exact merge command for a named human or the self-serve call; audit store only, never merges, tags or messages; UNKNOWN never approves |
| ClickUp queue drainer, shipped SHADOW (2026-11-03) | [`bulk-credit-change-drainer.md`](./bulk-credit-change-drainer.md): `action:bulk-credit-change` tickets executed as bounded batches off `details.bulk_rows` (3 tickets/run, 25 rows each, 100 credit writes per UTC day shared with the credit-correction executor, one lock over the whole drain surface); every row validated before any write and read back after, `complete` only when every row verified, `partial` + ONE internal comment naming the rows that did not land otherwise (never a close, never a customer message), removals refused. The cron ships unarmed (`--apply` absent, `enabled:false`) |
| Coded proof review (2026-11-04) | [`proof-review-coded.md`](./proof-review-coded.md): a "review the proof" ask answered by code, not an agent turn — one verdict per request from H3 + doc-verify + the DSP anchor + the fraud lens, one coded next step and one reply card; approves nothing (sufficient asks wait as `waiting_route`, per `policies/proof-review-route.json`) and builds no customer message |
| Batch fraud detector (spec) | [`fraud-detection-spec.md`](./fraud-detection-spec.md) — profile-level multi-factor detector that downgrades a backend approve to UVN (`CV_FRAUD_MODE` off/shadow/enforce; batch pipeline only) |
| Credit removal: hide / not-me (H1, 2026-11-04) | [`credit-removal.md`](./credit-removal.md): one ticket kind with two intents (the app modal's *this is me, hide it* / *this isn't me*), Caroline's one approved question, a drainer that hides (owner's right) or files a claim on the removal gate, proof follow-ups graded by Codex on node-8, and every write on an append-only ledger with an inverse |
| Facts re-read: scoped, age-stamped, never silent (2026-11-11) | [`facts-re-read.md`](./facts-re-read.md): the pre-send replica re-read asks only about this page's users (chunked, never the whole open-request table), a read timeout falls back to the list's own facts while they are inside `FACTS_STALE_MAX_MIN` and says `facts stale Nm`, the replica-independent checks (header digest, holds, sent asks) still refuse on that path, and `NOTHING sent` now alerts + pages instead of leaving one quiet log line |
| The send gate's per-person replica read (2026-11-13) | [`gate-replica-read.md`](./gate-replica-read.md): the gate asks the replica once per person instead of 5-6 times (a `trino-query.sh` call costs ~2 s whatever it asks), and `core_notice.py` / `comm_state.py` run unchanged behind `replica-serve.sh`, which answers a statement only on its exact text and reads live otherwise. Measured on node-8: 11.87 s -> 7.16 s per person, 6 -> 0 calls at the 20 s read timeout, unmeasured 5/5 -> 0/5. The bar and the timeout did not move |
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
