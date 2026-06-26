---
name: billion-streams-club
description: |
  Find AND post the artists who just crossed a 1 BILLION or 10 BILLION
  lifetime-streams milestone, using Muso's own data via the `muso` CLI. Posts each
  profile at most once per tier (it remembers who it has already congratulated), not
  everyone currently over the line, and only records a crossing after Slack confirms
  the post. Backs the daily `billion-streams-club-daily` cron.

  Use when: "who just hit 1 billion streams", "any artists cross 10B streams
  recently", "billion streams club", "new streaming milestones", "who reached a
  billion / ten billion streams".
  Triggers: "billion streams", "10 billion streams", "streams milestone",
  "streams club", "who crossed 1B/10B".
compatibility: |
  Main gateway on node-8 only (Trino is reachable only there; off-host the
  underlying `muso query` fails with "trino unavailable on this host"). Read-only
  against Muso (SELECT-only Trino); the writes are the skill's own state files and the
  Slack post. Slack delivery uses BILLION_STREAMS_SLACK_TOKEN or, by default,
  MUSO_SLACK_BOT_TOKEN_CMO (present in the main-gateway env), posting as @cmo. No new
  credential. CMO already has `muso` access.
metadata:
  version: "0.2"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# billion-streams-club

Posts the artists who **just crossed** a 1B or 10B lifetime-streams milestone.

## The metric and how a crossing is detected

- **Milestone number** = `postgresql_core.public.profile_v3_lifetime.streams` — the
  canonical lifetime total shown on the muso.ai profile (~3.9k profiles ≥1B,
  ~900 ≥10B at time of writing).
- That table has **no history**, and the daily-history table that exists
  (`track_daily`) lives on a hot-standby replica that **cancels any multi-minute
  query** (a full or candidate-scoped crossing diff was killed at 7–15 minutes by
  transaction / recovery-conflict timeouts). Reading the canonical club is ~1 second.
- So the skill keeps a persistent **per-tier "already-announced" set** and, each run:
  1. reads the current ≥1B club (one fast filtered read; 10B is a subset of 1B),
  2. for every profile that is ≥1B / ≥10B and **not yet in that tier's announced
     set**, builds the message and **posts it to Slack** (`--channel`), then
  3. records the announced ids **only after Slack returns `ok:true`**, atomically.
  The **first run seeds** the set from the whole current club and posts nothing.
  Because the commit is gated on a confirmed post, a delivery failure leaves the
  entrants un-recorded and the **next run retries** them (at-least-once) — rather than
  the cron's best-effort relay silently dropping the milestone. And because membership
  is "announced at most once per tier," it is immune to threshold flap and to a
  missed/extra run.

> Why not `muso db`? v0.7.0's `muso db` only reaches the **core** and **industry**
> Postgres — and the canonical read this skill uses is on `core`, reached fine
> through the existing `muso query` Trino path.

## How to call it

```bash
SKILL_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/billion-streams-club"
S="bash $SKILL_DIR/scripts/streams-milestones.sh"

# Production: post new crossings to a channel; commit only on a confirmed post.
# Prints a short status, or NO_REPLY when nobody new crossed / on the seed run.
$S --channel C0A5LLS93V3

# Preview WITHOUT posting or touching state (no --channel → print the message):
$S

# Inspect candidates as raw rows (never posts, never commits):
$S --format tsv                      # tier <tab> profileid <tab> streams <tab> name

# Never post / never commit, even with a channel:
$S --channel C0A5LLS93V3 --dry-run

# Isolate state entirely (won't touch the cron's real sets):
$S --state-dir /tmp/bsc-test
```

## Output & delivery

The skill **posts the milestone message to `--channel` itself** (Slack `mrkdwn`: a
`:tada:` header, a `10 BILLION` section and a `1 BILLION` section, each
`• *Name* — *X.YYB* lifetime streams` with a `https://muso.ai/profile/<id>` link).
Its stdout is a short status (`posted N new crossing(s)…`) or exactly **`NO_REPLY`**
when nothing new crossed. The cron runs with `delivery.mode: none` — the script is the
poster, not the cron relay, so delivery success is observable before state changes.

## State and seeding

State lives at `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/billion-streams-club-state/`
(override with `--state-dir` or `BILLION_STREAMS_STATE_DIR`): `announced-1b.txt` and
`announced-10b.txt` (one profileid per line). They survive deploys because they sit
outside the rsync-managed skills dir, and are written atomically (temp + rename).

**The cron self-seeds:** its first run records the baseline and posts nothing; real
crossings appear from the next run on. So the go-live is simply *deploy → flip
`enabled:true`* — no manual seed step. Invoke the script only through the agent/cron,
which sets `OPENCLAW_STATE_DIR` to the gateway state dir; a plain SSH shell leaves it
unset, so the `$S` path above resolves to a non-existent dir and fails fast rather than
seeding the wrong place.

## Caveats

- **Most days are empty.** Crossing a billion in a day is rare, so `NO_REPLY` is the
  common, healthy result.
- **New-membership artifact.** A profile that *first appears* in
  `profile_v3_lifetime` already above a tier (a fresh claim, a data backfill, or a
  profile **merge** that consolidates totals) is posted once, because the state can't
  tell "grew into the club" from "appeared already in the club." It is then remembered
  and never repeats.
- **Safety cap.** If more than `--max-announce` (default 50) profiles would post in one
  run — the tell-tale of a lost/corrupt state file — the skill refuses, posts nothing,
  leaves state unchanged, and logs loudly to stderr to investigate.
- Read-only against Muso, but not a hard security boundary — route any Muso *write*
  to @Ops, never to this skill.
