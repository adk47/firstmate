---
name: muso-streams-lookup
description: |
  Look up per-artist LIFETIME stream totals from Muso's own data and answer
  "find streams" questions: how many streams an artist has, the top artists by
  streams, or who has crossed 1B / 10B. Reads the LIVE source the muso.ai profile
  page uses — NOT the dead profile_v3 tables — so the numbers match the site.

  Use when: "how many streams does <artist> have", "stream count for <artist>",
  "find streams / who has the most streams", "show me N people who reached 1 billion
  streams", "list the billion-streams club", "top artists by lifetime streams",
  "is <artist> over 1B/10B", "streams leaderboard".
  Triggers: "how many streams", "stream count", "lifetime streams", "streams on muso",
  "top artists by streams", "streams leaderboard", "who reached 1B/10B", "billion streams".

  This is the on-demand READ / lookup + leaderboard tool. For the DAILY auto-post of who
  JUST crossed a new milestone, that is the `billion-streams-club` skill (cron-only; it
  announces deltas and returns NO_REPLY for list questions — it cannot answer "show me N").
compatibility: |
  Main gateway on node-8 only (Trino is reachable only there; off-host the underlying
  `muso query` fails with "trino unavailable on this host"). Read-only (SELECT-only Trino
  against postgresql_olap). No state, no credential, no Slack post — it prints to stdout
  for the agent to relay. Every agent has `muso` access.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-streams-lookup

Answers "find streams" questions with the **right query to the right table**.

## Data source (read this — it's the whole point)

- **Live source** = `postgresql_olap.public.cube_analytics_profile_view`, column
  **`ce_streams`** at **`period='all'`** — the per-artist **lifetime** total the muso.ai
  profile page **Streams** headline shows (recomputed continuously from `track_daily`;
  native `bigint`; ~1s; one row per profile).
- **NEVER `profile_v3_lifetime` or `profile_v3_tracks`** — those are **DEAD** (frozen
  2026-06-06). Anything matching `*v3*` is stale; do not read it. This skill exists so
  agents stop hand-writing SQL against the dead tables.
- `profile_type` ∈ {`artist`, `organization` (labels/publishers — Kobalt, Sony, …),
  `professional`}. The leaderboard defaults to `artist` (drops the ~235 organizations);
  widen with `--type`.

## How to call it

```bash
S="bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-streams-lookup/scripts/streams-lookup.sh"

# Leaderboard — top 10 ARTISTS over 1B lifetime streams (the default):
$S --top 10

# "Show me 10 people who reached a billion streams" (same thing):
$S --top 10 --min 1B

# Over 10B, including labels/publishers and everyone else:
$S --top 20 --min 10B --type all

# How many streams does one artist have (by name; exact then fuzzy):
$S --artist "Drake"
$S --artist "taylor sw" --limit 3        # fuzzy, show up to 3 matches

# Exact, unambiguous lookup by profile id:
$S --id e979669b-d99b-46be-91d6-bf1f1e2f44bf

# With the Spotify / YouTube split, or as raw rows:
$S --artist "Drake" --platforms
$S --top 50 --format tsv                  # id <tab> streams <tab> name <tab> type
$S --top 50 --format json                 # raw cube rows (NDJSON)
```

## Output & behavior

- Default `--format slack` (mrkdwn): a `:bar_chart:` header then
  `• *Name* — *X.YYB* lifetime streams  <https://muso.ai/profile/<id>|view>` (T/B/M
  formatted). `--format tsv` and `--format json` for machine use.
- **Prints to stdout — does not post to Slack.** The calling agent relays the result in
  its own reply (so report it in plain words; don't emit a bare NO_REPLY).
- **Fail-soft:** a no-match lookup exits 0 with a readable message (not an error); a bad
  flag exits 2; a query failure exits 1 with `ERROR:` on stderr.
- **Name lookups** match exact first, then fuzzy `LIKE`, ranked by `ce_streams` (so the
  most-streamed match for a homonym wins — e.g. the real "Drake" over "Seth Drake"); if
  more profiles match than shown, it prints a hint to use `--id` or `--limit`.

## Caveats

- The leaderboard is "all credit roles" — top entries include mixing/mastering engineers
  and producers (e.g. Serban Ghenea), not only performing artists, because `ce_streams`
  sums every credited track. That's the same metric the profile page shows. There is no
  performing-artist-only cut (it would need per-track role analysis).
- `--type all` lets labels/publishers (`organization`) dominate the top (Kobalt ~5T) — keep
  the default `artist` unless you specifically want them.
- Read-only against Muso, but not a hard security boundary — route any Muso *write* to
  @Ops, never to this skill.
