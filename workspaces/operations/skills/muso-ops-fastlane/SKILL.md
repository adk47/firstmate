---
name: muso-ops-fastlane
description: |
  Profile analytics "fastlane" — bootstraps/refreshes a profile's analytics
  dashboard so streams, tracks, and credit counts show up. Triggered by
  @mention in #credit-verification or #operations matching "fastlane" /
  "fast lane" / "fast-lane" plus one or more profile UUIDs/URLs.

  THIS IS NOT CREDIT VERIFICATION. Fastlane fires
  POST /admin/analytics/<profileId>/fast-lane. It does NOT approve credits and
  must NEVER be routed to muso-ops-credit-verification / dispatch-cv-batch.sh /
  "run credit verification".

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

Pass the requesting user's Slack ID as `<REQUESTER>` so it lands in the admin
audit trail.

## How to dispatch

One `exec` call to the wrapper. Pass every distinct UUID in a single
space-separated string as arg 1.

```
tool: exec
action: shell
args:
  shell: bash /opt/hydra/workspaces/operations/skills/muso-ops-fastlane/scripts/fastlane.sh "<PROFILE_IDS>" "<TS>" <REQUESTER> <MODE>
  timeout: 300
  yieldMs: 300000
```

Positional args:

| Pos | Name           | Default                   | Notes                                                          |
|-----|----------------|---------------------------|----------------------------------------------------------------|
| 1   | `<PROFILE_IDS>`| —                         | Space/comma-separated UUIDs and/or profile URLs. REQUIRED.     |
| 2   | `<TS>`         | `""`                      | Slack `thread_ts` for context. Empty if no thread.             |
| 3   | `<REQUESTER>`  | —                         | Requesting user's Slack ID (e.g. `U038BM16T7W`). REQUIRED.     |
| 4   | `<MODE>`       | `real`                    | `real` (default — actually fires) or `dry` (no write, logged). |
| 5   | trigger_source | `admin_fast_lane_jan_batch` | Optional backend label. Leave default unless Jan specifies. |

Examples:
- One profile, real: `bash fastlane.sh "060a7ad2-f0cb-4911-aa1a-6ba89ee650a3" "<TS>" U038BM16T7W real`
- Multiple, real:    `bash fastlane.sh "f8ac87f7-... b9687dc4-..." "<TS>" U038BM16T7W real`
- Dry preview:       `bash fastlane.sh "060a7ad2-..." "<TS>" U038BM16T7W dry`

`timeout: 300` is generous: each fastlane POST is fire-and-forget (the ~130s
cube refresh happens async in the backend, not in this call).

## What the wrapper does

For each distinct profile UUID, `fastlane.sh`:

1. `POST /admin/analytics/<id>/fast-lane` via `muso-ops-admin`'s
   `muso-admin-api.sh --requester <REQUESTER>` with body
   `{"triggerSource":"<trigger>"}`. (No credit-approve gate applies to analytics
   paths; `dry` mode sets `OPS_DRY_RUN=1` so the write is logged, not sent.)
2. Reads current stream/track counts from
   `postgresql_core.public.profile_v3_lifetime` (best-effort) so the report
   answers "what's the stream count after the fastlane?".
3. Appends a JSONL audit line to `/var/log/openclaw/fastlane-apply.jsonl`.

It prints one Slack-ready report. **Post that stdout verbatim** into the thread —
it is the entire response. The report is clearly labelled "profile analytics
bootstrap (not credit verification)" and notes the async ~130s refresh.

## Notes / limits (already handled by the backend)

- Profiles over ~25K credits (catalog orgs — publishers/labels) are silently
  skipped by the backend; they are not user dashboards.
- Fastlane is idempotent: re-firing the same profile is safe (`GREATEST`/
  `COALESCE` merge), so "do the fastlane again after the tracks are updated" is
  fine to run.

## Out of scope (do not improvise these here)

- `recalculate` + cache-clear escalation for "tracks still showing zero after
  fastlane" — that is a separate, documented follow-up, not this skill.
- User-wide (`/admin/user/<id>/fast-lane-analytics`) and recent-paid batch
  sweeps (`/admin/analytics/fast-lane-recent-paid`).

## Pre-flight assertions

If any fail, post a thread reply with the specific reason and stop.

1. At least one valid profile UUID was extracted.
2. The requester is the god-mode trio (else queue for Aaron, don't fire).
3. `/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh`
   exists (this skill `depends-on: muso-ops-admin`).
