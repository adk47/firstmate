---
name: muso-ops-fastlane
description: |
  Profile analytics "fastlane" — bootstraps/refreshes a profile's analytics
  dashboard so streams, tracks, and credit counts show up. Triggered by
  @mention in #credit-verification or #operations matching "fastlane" /
  "fast lane" / "fast-lane" plus one or more profile UUIDs/URLs.

  Covers BOTH the plain lane (POST /admin/analytics/<profileId>/fast-lane —
  recompute cubes from existing catalog) and the fastlane+ superset (POST
  .../fast-lane-plus and per-user POST /admin/user/<userId>/fast-lane-plus —
  ALSO re-discover the catalog and force-rescrape every source). Use plain when
  numbers look stale; use fastlane+ when tracks/credits are MISSING.

  THIS IS NOT CREDIT VERIFICATION. Fastlane (plain or +) does NOT approve
  credits and must NEVER be routed to muso-ops-credit-verification /
  dispatch-cv-batch.sh / "run credit verification".

  Triggers: @mention matching the "Trigger phrases" below.
depends-on:
  - muso-ops-admin
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Fastlane (profile analytics bootstrap)

Jan (and Aaron) post `@Ops fastlane <profile>` when a profile's dashboard is
stuck on "Analytics Initializing" or its streams/tracks/credits are not showing.
"Fastlane" is a **profile analytics bootstrap**: it creates a
`profile_analytics_stats_history` row, enqueues `publishProfileFastLane` work,
and invalidates the `/profile/:id` cache so fresh data renders. It is
fire-and-forget and idempotent.

**The agent's job is dispatch only**: confirm the message is a fastlane request,
extract the profile UUID(s), exec the wrapper once, and post its stdout verbatim
into the thread. Do not improvise API calls, do not run credit verification, do
not post emoji reactions or acknowledgements before the wrapper returns.

## ⚠️ Fastlane is NOT credit verification

This is the single most important rule of this skill. Jan has repeatedly been
given a credit-verification run when he asked for fastlane (e.g. 2026-06-07:
"i said fast lane, not credit verifiation"). The two are unrelated:

| Request                          | Skill / endpoint                                   |
|----------------------------------|----------------------------------------------------|
| `fastlane <profile>`             | **this skill** → `POST /admin/analytics/<id>/fast-lane` |
| `verify profile <uuid>` etc.     | muso-ops-credit-verification → lobster pipeline    |

If the word **fastlane / fast lane / fast-lane** appears, it is THIS skill —
even if the message also mentions credits, analytics, streams, or "verify".
NEVER call `dispatch-cv-batch.sh` or "run credit verification" for a fastlane
request.

## Plain vs plus — which lane

There are two lanes. Pick by **what the complaint is**, not who asked:

| Complaint                                                                   | Lane                          | Why |
|-----------------------------------------------------------------------------|-------------------------------|-----|
| Numbers look **stale** but the catalog is complete (cube lag, post-fix)     | **plain** (`fast-lane`)       | Cheap recompute of cubes from data we already have. |
| Tracks/credits are **MISSING** — a credit on a never-scraped release, empty/thin profile, "my song isn't showing", post-claim heal, wrong-source counts | **fastlane+** (`fast-lane-plus`) | Plain recompute can't heal this — there's nothing in catalog to recompute. Plus re-discovers + rescrapes. |
| **Every profile a user owns** needs the full treatment (account escalation) | **fastlane+ user** (`/admin/user/<id>/fast-lane-plus`) | Fans out the full treatment over all owned profiles (cap 200). |

**Rule of thumb:** complaint is "numbers wrong" → try **plain** first (it's
cheap). Complaint is "things **missing**" → go straight to **fastlane+**.
fastlane+ burns real scrape capacity, so don't reach for it when plain suffices.

## What fastlane+ does

One `fast-lane-plus` call runs the same pipeline pro-activation fires on a paid
signup — "trigger the paid-signup treatment on demand":

1. **Bootstrap** the `profile_analytics_stats_history` row (idempotent per
   profile+day) → the dashboard's "Analytics Initializing" gate clears at once.
2. **`discover_profile_catalog`** (catalog-HIGH lane) → fans out artist-page
   catalog scrapes on every platform for the profile's raw identities. This is
   what lands **never-scraped tracks**.
3. **`refresh_analytics_profile_full` with `force_rescrape=true`**
   (catalog-admin priority lane) → re-dispatches fresh high-priority stats
   scrapes for every existing analytics link on all sources (bounded per profile
   by `FASTLANE_RESCRAPE_PER_PROFILE_CAP`), then re-links and recomputes all
   fastlane cubes.

Net: **catalog rescrape → link → all-source stats rescrape → cube recompute.**

### Response & verify (fastlane+)

The wrapper reports the response fields `discovered` / `refreshed`:

- Either **`discovered=false` or `refreshed=false`** = that queue send failed
  (logged + Sentry backend-side). It's **idempotent — just re-fire** the same
  call.
- **Timing:** the "initializing" gate clears instantly; new catalog/tracks land
  in **minutes to tens of minutes** (scrape-dependent); cubes recompute after
  the refresh message processes (~1–5 min normally). Verify by checking the
  profile page shows the missing tracks, then that stats populate.

### Caveats (current, 2026-07-09)

1. The refresh leg rides the `industry-proc-catalog-admin` consumer. If a
   partition of that group is **wedged** (p2 is, right now), calls whose profile
   hashes to it queue until it clears — the response says `refreshed=true` but
   cubes don't move. Check the group's consumed offsets before assuming the call
   failed.
2. Discovery only covers platforms we have **raw identities** for. An empty
   `muso:`-only shell has nothing to discover — attach a DSP identity first
   (claim-link ingestion / `enrichByUrl`).
3. **Tidal** scraping runs through the session-pool path with its own pacing;
   Tidal results can lag other sources.

### Safety & cost

Idempotent (findOrCreate bootstrap, insert-only links, cube upserts) and bounded
(per-profile IDP rescrape cap; 200-profile cap on the user variant). But it
**costs real scrape capacity** — each call burns proxy/capture budget across all
sources. Fine for support cases and dozens/day; **never loop it over a large
cohort** — that's what paced backfill jobs are for.

## Trigger phrases (case-insensitive, whitespace tolerant)

Strip the leading `@Ops` / `<@bot_id>` mention first. Match when the body
contains `fast` followed by optional space/hyphen then `lane`
(`fastlane`, `fast lane`, `fast-lane`), optionally followed by `:` / `-`, plus
at least one profile UUID or `credits.muso.ai/profile/<uuid>` URL anywhere in
the message (or visible in an attached image).

Examples (all valid):
- `@Ops fastlane https://credits.muso.ai/profile/060a7ad2-f0cb-4911-aa1a-6ba89ee650a3`
- `@Ops fastlane 0850258e-4dcf-4131-8bee-37ffebe6b26a`
- `@Ops fast lane 00b866e6-66c3-46d9-8282-9e3c54b06961`
- `@Ops fastlane: f8ac87f7-... b9687dc4-...` (multiple profiles → all fastlaned)
- `@Ops fastlane <profile-url> credits analytics are not showing` (extra prose ok)

### No-match / can't-resolve behaviour

- If the message says fastlane but contains **no resolvable UUID** (e.g. only a
  profile *name* like "Rollo"/"Spreckley"), reply in-thread asking Jan for the
  profile URL or UUID. Do NOT guess a UUID and do NOT fall back to credit
  verification.
- If the message is clearly not a fastlane request, this skill does not apply.

## UUID extraction

UUID regex (case-insensitive):

```
[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}
```

Scan, in priority order: (1) the message text, (2) any
`credits.muso.ai/profile/<uuid>` URL, (3) an attached image (read the UUID/URL
off the screenshot with vision). Pass **all** distinct UUIDs found — the wrapper
lowercases and de-dupes them and fastlanes each one. Order is preserved.

## Authorization

Fastlane is non-destructive and idempotent. The god-mode trio —
Aaron (`U7RP6HKUZ`), Jan (`U038BM16T7W`), Nick (`U0AL36NADEY`) — is
self-authorized; run immediately, no Aaron sign-off (Jan's standing grant from
Aaron, 2026-05-22). For anyone else, queue for Aaron review per the default
"Write Operations — Approval Required" rule and do not fire.

This holds for fastlane+ too — the same trio, fire immediately. Just prefer
**plain** first when the complaint is only "numbers wrong" (fastlane+ costs
scrape capacity; see "Plain vs plus").

Pass the requesting user's Slack ID as `<REQUESTER>` so it lands in the admin
audit trail.

## How to dispatch

One `exec` call to the wrapper. Pass every distinct UUID in a single
space-separated string as the ids arg.

```
tool: exec
action: shell
args:
  shell: bash /opt/hydra/workspaces/operations/skills/muso-ops-fastlane/scripts/fastlane.sh [--lane plus] [--scope user] "<IDS>" "<TS>" <REQUESTER> <MODE>
  timeout: 300
  yieldMs: 300000
```

Optional **leading flags** (omit both for plain fastlane — the existing
default):

| Flag                | Default   | Notes                                                                 |
|---------------------|-----------|-----------------------------------------------------------------------|
| `--lane plain\|plus`| `plain`   | `plus` = recalc + full rescrape/rediscovery (see "Plain vs plus").     |
| `--scope profile\|user` | `profile` | `user` treats each id as a **userId**; only valid with `--lane plus`. |

Positional args (unchanged — flags go before them):

| Pos | Name           | Default        | Notes                                                          |
|-----|----------------|----------------|----------------------------------------------------------------|
| 1   | `<IDS>`        | —              | Space/comma-separated UUIDs and/or profile URLs. REQUIRED. Profile UUIDs for profile scope; **user** UUIDs for `--scope user`. |
| 2   | `<TS>`         | `""`           | Slack `thread_ts` for context. Empty if no thread.             |
| 3   | `<REQUESTER>`  | —              | Requesting user's Slack ID (e.g. `U038BM16T7W`). REQUIRED.     |
| 4   | `<MODE>`       | `real`         | `real` (default — actually fires) or `dry` (no write, logged). |
| 5   | trigger_source | lane/scope-aware | Optional backend label. Default is `admin_fast_lane_jan_batch` (plain), `admin_fast_lane_plus` (plus), or `admin_fast_lane_plus_user` (plus/user). Pass a meaningful label like `intercom-<ticket>-<operator>` when the request traces to a ticket — it's the observability breadcrumb. |

Examples:
- Plain, one profile:  `bash fastlane.sh "060a7ad2-f0cb-4911-aa1a-6ba89ee650a3" "<TS>" U038BM16T7W real`
- Plain, multiple:     `bash fastlane.sh "f8ac87f7-... b9687dc4-..." "<TS>" U038BM16T7W real`
- **fastlane+**, one profile (missing tracks): `bash fastlane.sh --lane plus "060a7ad2-..." "<TS>" U038BM16T7W real`
- **fastlane+ user** (whole account): `bash fastlane.sh --lane plus --scope user "<USER_ID>" "<TS>" U038BM16T7W real`
- Dry preview (plus):  `bash fastlane.sh --lane plus "060a7ad2-..." "<TS>" U038BM16T7W dry`

`timeout: 300` is generous: each POST is fire-and-forget (the scrape + cube
refresh happen async in the backend, not in this call).

## What the wrapper does

For each distinct id, `fastlane.sh`:

1. `POST <endpoint>` via `muso-ops-admin`'s `muso-admin-api.sh --requester
   <REQUESTER>` with body `{"triggerSource":"<trigger>"}`, where `<endpoint>` is
   resolved from the flags: `/admin/analytics/<id>/fast-lane` (plain),
   `/admin/analytics/<id>/fast-lane-plus` (plus), or
   `/admin/user/<id>/fast-lane-plus` (plus/user). (No credit-approve gate applies
   to analytics paths; `dry` mode sets `OPS_DRY_RUN=1` so the write is logged,
   not sent.)
2. For profile scope, reads current stream/track counts from the live OLAP cube
   `postgresql_olap.public.cube_analytics_profile_view` (`ce_streams` @ `period='all'`,
   best-effort) so the report answers "what's the stream count after the fastlane?".
   (Replaces the dead `profile_v3_lifetime`, frozen 2026-06-06.) User scope skips
   this readback (we don't hold the fanned-out profile ids).
3. Appends a JSONL audit line (including `lane`/`scope`/`endpoint` and, for plus,
   `discovered`/`refreshed`) to `/var/log/openclaw/fastlane-apply.jsonl`.

It prints one Slack-ready report. **Post that stdout verbatim** into the thread —
it is the entire response. For fastlane+ the report surfaces `discovered` /
`refreshed`; either being `false` = a queue send failed → re-fire (idempotent).

When posting, use the channel ID and `thread_ts` **verbatim from the triggering
message's metadata** — Slack IDs are case-sensitive, and a retyped/lowercased
channel ID (e.g. `c0apb2cmm7c` for `C0APB2CMM7C`) makes the post fail
(2026-07-23 incident). Never reconstruct an ID from memory.

## Notes / limits (already handled by the backend)

- Profiles over ~25K credits (catalog orgs — publishers/labels) are silently
  skipped by the backend; they are not user dashboards.
- Fastlane is idempotent: re-firing the same profile is safe (`GREATEST`/
  `COALESCE` merge), so "do the fastlane again after the tracks are updated" is
  fine to run.

## Out of scope (do not improvise these here)

fastlane+ (`fast-lane-plus`, both the profile and per-user variants) is now IN
scope — fire it via `--lane plus` / `--scope user`. Still out of scope:

- `recalculate` + cache-clear escalation for "tracks still showing zero after
  fastlane+" — that is a separate, documented follow-up, not this skill.
- The recent-paid batch sweep (`/admin/analytics/fast-lane-recent-paid`) and the
  older user-wide `/admin/user/<id>/fast-lane-analytics` endpoint (distinct from
  `fast-lane-plus`).
- **Cohort looping**: never loop fastlane+ over a large set of profiles/users —
  it burns real scrape capacity; that's what paced backfill jobs are for.

## Pre-flight assertions

If any fail, post a thread reply with the specific reason and stop.

1. At least one valid profile UUID was extracted.
2. The requester is the god-mode trio (else queue for Aaron, don't fire).
3. `/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh`
   exists (this skill `depends-on: muso-ops-admin`).
