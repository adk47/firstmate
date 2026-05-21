---
name: muso-ops-credit-verification
description: |
  Deterministic credit verification via the Lobster pipeline. Triggered by
  @mention in #credit-verification (C0APB2CMM7C). Three selectors — the
  unverified queue, a specific profile, or a single credit-request. Real
  apply is the default in all modes; pass the `dry` keyword to force a
  no-write summary instead.

  Triggers: @mention in #credit-verification matching one of the regex
  patterns in "Trigger phrases" below.
depends-on:
  - muso-ops-admin
metadata:
  version: "2.1"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Credit Verification (Lobster)

The entire credit-verification flow is owned by a Lobster pipeline. The
agent's job is **dispatch only**: classify the @-mention, extract any
UUID, exec the wrapper, return. Do NOT improvise, do NOT call Tier-0 /
Tier-1 helpers directly, do NOT post emoji reactions, do NOT
acknowledge before the wrapper returns. The pipeline posts its own
Slack thread reply — that IS the entire response.

## Three modes

| Mode    | Selector              | What it processes                                  |
|---------|-----------------------|----------------------------------------------------|
| queue   | none                  | Up to N unverified credits from the global queue   |
| profile | profile UUID          | All unverified credits on that profile (cap 500)   |
| credit  | credit-request UUID   | The one specified credit-request                   |

In every mode, real apply is the default — the pipeline bulk-PUTs
`would_approve` credits to `status="approved"` via the admin API. Pass
the `dry` keyword to force a no-write summary instead.

## Trigger phrases (case-insensitive, whitespace tolerant)

Strip the leading `@Ops` / `<@bot_id>` mention before matching.

### Queue mode

```
^run credit verification(?:\s+(dry))?(?:\s*\((\d+)\))?$
```

| Phrase                                            | Mode      | Batch |
|---------------------------------------------------|-----------|-------|
| `@Ops run credit verification`                    | **real**  | 500   |
| `@Ops run credit verification (N)`                | **real**  | N     |
| `@Ops run credit verification dry`                | dry       | 500   |
| `@Ops run credit verification dry (N)`            | dry       | N     |

### Profile mode

Match if the message body contains the word `profile` AND a credit-side
UUID (either bare, in a `credits.muso.ai/profile/<uuid>` URL, in
free-form prose, or visible in an attached image — extract from
whichever source). Optional `dry` keyword.

Examples (all valid):
- `@Ops verify profile 8b3859c5-7930-4a48-8078-7262b2bb8dc6`
- `@Ops verify profile https://credits.muso.ai/profile/8b3859c5-7930-4a48-8078-7262b2bb8dc6`
- `@Ops can you check this profile https://credits.muso.ai/profile/8b3859c5-7930-4a48-8078-7262b2bb8dc6 please`
- `@Ops verify this profile <image with the UUID visible>`
- `@Ops verify profile dry 8b3859c5-...` → dry mode

### Credit mode

Match if the message body contains the word `credit` (and NOT the word
`profile`) plus a credit-request UUID, OR a `credits.muso.ai/credit-request/<uuid>`
URL. Same image-attachment rule.

Examples:
- `@Ops verify credit b490eaad-7575-4ff9-9f08-804e37ce51e3`
- `@Ops verify credit https://credits.muso.ai/credit-request/b490eaad-...`
- `@Ops verify credit dry b490eaad-...`

### No-match behaviour

If the message does not cleanly classify into one of the three modes,
post a thread reply with the usage table above and stop. Do not guess.

## UUID extraction

UUID regex (case-insensitive):

```
[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}
```

Sources to scan, in priority order:

1. The message text.
2. A `credits.muso.ai/profile/<uuid>` or `credits.muso.ai/credit-request/<uuid>` URL anywhere in the text.
3. Any attached image — use vision to read a visible UUID or URL off the screenshot.

If multiple UUIDs are present, use the first one in document order. If
the user mixed a profile keyword with a credit-request URL or vice
versa, ask for clarification in a thread reply — don't pick.

## How to dispatch

One `exec` call. **Do NOT call the `lobster` tool directly** — the
gateway lobster-tool schema advertises `flowId` and
`flowExpectedRevision`, which schema-driven completion fills in, after
which Lobster's `run` handler throws
`"run action does not accept flowId or flowExpectedRevision"`. The
wrapper bypasses that.

```
tool: exec
action: shell
args:
  shell: bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/dispatch-cv-batch.sh <N> "<TS>" <MODE> <KIND> "<ID>"
  timeout: 800
  yieldMs: 800000
```

Positional args (all defaulted; pass empty string `""` for "not set"):

| Pos | Name           | Default  | Notes                                                              |
|-----|----------------|----------|--------------------------------------------------------------------|
| 1   | `<N>`          | `500`    | Batch size cap. Ignored in `credit` mode (always 1).               |
| 2   | `<TS>`         | `""`     | Slack `thread_ts` (or parent `ts`). Empty if no thread context.    |
| 3   | `<MODE>`       | `real`   | `real` or `dry`.                                                   |
| 4   | `<KIND>`       | `queue`  | `queue`, `profile`, or `credit`.                                   |
| 5   | `<ID>`         | `""`     | Required UUID for `profile`/`credit`; ignored in `queue`.          |

Examples:
- Queue, real, 500: `bash dispatch-cv-batch.sh 500 "<TS>" real`
- Queue, dry, 5:    `bash dispatch-cv-batch.sh 5 "<TS>" dry`
- Profile, real:    `bash dispatch-cv-batch.sh 500 "<TS>" real profile 8b3859c5-...`
- Credit, real:     `bash dispatch-cv-batch.sh 1 "<TS>" real credit b490eaad-...`
- Credit, dry:      `bash dispatch-cv-batch.sh 1 "<TS>" dry credit b490eaad-...`

`timeout: 800` (seconds) and `yieldMs: 800000` (ms) are sized for up to
500 credits in chunked apply mode (10 PUT chunks × ~30s each + fetch/
score/verdict overhead ≈ ~3 min typical, generous headroom for
chunk-level retries). Do NOT shrink — under-timeout SIGKILLs the
wrapper, Lobster aborts, user sees nothing.

## What the pipeline does

The wrapper invokes the `verify-credit-batch-mvp.lobster` pipeline:

1. `pick-credits.sh ${batch_size} ${selector_kind} ${selector_id}` —
   routes to `fetch-queue.sh`, `fetch-by-profile.sh`, or
   `fetch-by-credit.sh` depending on the mode.
2. `score-backend-signals.sh` — partitions into
   `signal_approve` / `signal_review` / `signal_uvn` based on the
   credit's `verificationData` payload alone.
3. `verdict-engine.sh` — `signal_approve` → `would_approve`; everything
   else (`signal_review` ∪ `signal_uvn`) → `would_uvn`.
4. `apply-verdicts.sh ${dry_run}` — when `dry_run=false`, chunked bulk
   PUTs to the admin API: `would_approve` → `status="approved"`,
   `would_uvn` → `status="user_verification_needed"`. Chunk size 50
   (configurable via `CV_APPLY_CHUNK_SIZE`) keeps each request under
   Cloudflare's 100s origin timeout. Audit log:
   `/var/log/openclaw/lobster-apply.jsonl`. Refuses to claim "landed"
   if any response carries `dryRun:true`.
5. `render-dry-run-summary.sh` — posts the Slack summary. With a non-empty
   `THREAD_TS` (the @-mention path) it replies in the user's thread; with an
   empty `THREAD_TS` (the autonomous 4h cron path) the pipeline sets
   `POST_PARENT_TO_CHANNEL=1` and it posts as a top-level parent in
   `#credit-verification` instead. Either way the rich summary lands in
   Slack from the pipeline itself — the agent's final-reply text is no
   longer on the user-facing delivery path (see hydra#305).

(MusicBrainz lookup was removed 2026-05-18: it contributed 0 confirmed
approvals on real data while consuming ~73% of pipeline wall-clock. The
scripts remain on disk for ad-hoc debugging but are no longer wired into
the pipeline.)

## Verdict policy (owned by the pipeline)

Two outcomes, single backend-signal rule, no external lookups.

- **approved** = `signal_approve` only
  - `verificationData.rule_risk_percent.approve_owning_track == 100`
    AND `verificationData.total_risk_percent < 80`.
  - Backtested at 99.34% precision over 90 days / 200k credits.
- **user_verification_needed** = everything else
  - `signal_review`: no strong approve signal, but no hard-reject either.
    Operator decides.
  - `signal_uvn`: `track_pending_capture` set, hard-reject flags fired,
    or empty `verificationData`. Backend already says not auto-approvable.

The summary reports both `approved.landed` and `uvn.landed` counts.

## Pre-flight assertions

If any fail, post a thread reply with the specific reason and stop.

1. `/root/.openclaw-main/openclaw.json` readable, `.gateway.auth.token`
   non-empty.
2. `/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/pipelines/verify-credit-batch-mvp.lobster`
   exists.
3. `openclaw plugins list --profile main` shows `lobster` enabled.
