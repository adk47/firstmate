# Muso business-domain lessons

The Muso-specific facts and traps that bite agents working the product surfaces:
the admin API and `muso` CLI, the data lake (Trino / Postgres / the analytics
cubes), Intercom support, the NocoDB and ClickUp trackers, Slack alerting, and the
Caroline support agent. Each lesson is a durable fact plus why it matters plus the
right approach. Versions and dates appear only as examples of the principle, not as
the rule. Re-verify specifics against the live system before relying on them,
especially the People section (the most churn-prone data here).

---

## Admin API & muso-cli

**There is no single-credit GET on the admin API.** `GET /admin/credit-requests/<id>`
404s (HTML body). To read one credit's status, hit the list endpoint with
`?status=&limit=` filters and iterate, or query Trino
`postgresql_core.public.credit_requests`. Working endpoints: `GET /admin/credit-requests?status=&limit=`
(envelope `.body.data.items[]` + `.count`), `GET .../counts`, `PUT /admin/credit-requests`
(bulk), `PATCH /admin/credit-requests/<id>` (single), `GET /admin/track|album/<id>/sources`.

**A bulk PUT 200 does not mean every credit transitioned.** The bulk
`PUT /admin/credit-requests` returns `{result:"ok"}` on batch ACCEPTANCE but does not
surface per-id partial failures; anomalies surface only on re-fetch of the queue. Never
treat 200 as proof an individual credit changed.

**Credit-request status transitions are a hard matrix — anything off it silently
no-ops with a 200.** `core-backend/src/apis/_admin/credit-requests/updateStatus.js`
gates each transition per-branch (`transitionCreditRequest(id, target, allowedFrom)`):
`approved` ← unverified/UVN/rejected/processing; `rejected` ← unverified/UVN/approved/processing;
`user_verification_needed` ← **unverified ONLY**; `unverified` ← approved ONLY;
`processing` ← unverified/processing/UVN. Two consequences that bit on 2026-07-22:
(a) **rejection is a one-way door** — there is no `rejected → user_verification_needed`
path, so 28 wrongly-rejected UVN requests could not be moved back (readback showed 28/28
still rejected after a 200); this is why the credit reject gate in `muso-admin-api.sh`
makes `status:"rejected"` human-only (`--confirmed-by` + `--approval-msg-id`).
(b) The `profileId` selector variant of the bulk PUT matches **`unverified` rows only** —
UVN/rejected/processing rows are silently skipped; use explicit `requestIds` for anything
past `unverified`. Always read the queue back after any status write.

**Profile and credit field shapes.** `GET /admin/profile/{uuid}` wraps under
`body.data`: `isClaimed`, `workspaces[]{email,isClaimed}`, `knownAsNames[]`,
`rawProfiles[]`. Ownership rule: `isClaimed==true` AND exactly one `workspaces[]` entry
with `isClaimed==true` AND that email matches (case-insensitive). `playlist.spotifyAccount.email`
is NOT an ownership field. Credits live at `GET /admin/profile/{uuid}/credits` under
`body.data.items[]` (not a bare array); the per-credit track id is `id` (docs that say
`trackId` are wrong, treat the API as ground truth). Strip `(feat. X)` on both sides when
matching a customer-supplied title.

**Credit delete is one (track, profile) pair per call.** `DELETE /admin/track/:trackId/profile/:profileId/credits`,
empty body, no batch variant. `POST /admin/profiles/unmerge` body `{unmergeFrom, profilesIds:[]}`
(approval-gated).

**Displayed profile credits are materialized — the bulk removal endpoint cannot remove
them.** `DELETE /admin/profile/:id/credits` 200s but only deletes Muso-origin raw role
rows via the raw-ingestion queue; the materialized credits users see survive, even when
zero raw assertions remain (2026-07 La Mano 1.9 / Matt Wright: two 200'd bulk batches,
no visible change after 24h, and an agent triage wrongly concluded per-track deletes
would be equally futile). The per-track DELETE above IS effective: it edits the
materialized rows directly and overrides still-active external raw credits
(tidal/mlc/jaxsta) — canonical ops procedure per the 2026-02-04 KT ("manually remove
incorrect credits (overrides raw source)"). Verify via the credits LIST (materializes
~20s), never via the profile's `creditCount` (lagging cached stat). Whole-raw
`POST /admin/profile/:id/unlink` is only safe for cleanly-wrong raws — sweep the
profile's FULL credit list through `GET /admin/track/:id/raw-credits` first (checking only
the requested tracks misses keep-assertions); raws are often mixed (one tidal raw asserted
16 wrong + 26 correct tracks). More than 10 destructive DELETEs in 15 min trips the tier-2 gate:
escalate for second-human approval (`--confirmed-by`/`--approval-msg-id` on the admin
wrapper; muso-cli: `--approval-ref`), don't pace under it. Full playbook:
`skills-all/muso-ops-tracks/SKILL.md` → Removal Requests.

**`OPS_DRY_RUN=1` silently fakes success.** With it set in env, the admin-api wrapper
short-circuits EVERY non-GET with a synthetic `{"http_status":200,"dryRun":true,"wouldHaveExecuted":true}`.
A consumer that reads only `.http_status` reports success while nothing changed. Two
defenses for any destructive consumer: refuse early if the var is set, AND per-call check
`.dryRun==true` (real writes never carry that key). Also guard the empty-`http_status`
case (curl transport failure yields invalid JSON) with a `// 0` fallback.

**Profile merge 200 means enqueued, not merged.** `POST /admin/profiles/merge` returns
200 but only enqueues an async catalog job; it does not set `merged_to_id`. Verify landing
through the batched admin profile-list read with `includeDeleted=true`; it proxies the
current Mongo catalog and exposes `merged.mergedToId` plus `deleted`. A requested-direction
landing requires both `loser.merged.mergedToId == survivor` and a loser deletion record;
the exact inverse covers a direction flip. Do not use a BI materialized view for this
operational check, and do not re-issue a 200'd merge blindly. Check the pair's current state
and worker retry/dead-letter evidence first.

**`api.muso.ai` (prod) serves core-backend `master`, not `develop`.** `develop` is the
repo DEFAULT branch (new PRs base off it), but only `master` deploys to prod. Any
core-backend change that must reach prod for hydra/Caroline has to land on `master`.

**The local core-backend checkout is often stale.** Cross-repo contract reviews
(hydra vs core-backend) produce false "route/field missing" findings off a not-pulled
working tree. Verify against the LIVE API or `git -C core-backend show origin/master:<file>`,
never the local tree.

**`muso` CLI output and behavior gotchas.** `muso query` sets no Trino session catalog,
so two-part `"db".table` fails "Catalog must be specified" (qualify `hive."db".table`).
`--format json` yields NDJSON with values as STRINGS and empty result as empty stdout +
exit 0. With no env, `muso` targets api-dev. Starting in v0.11, credentials are
environment-scoped: `MUSO_DEV_ADMIN_*` for dev and `MUSO_PROD_ADMIN_*` for prod;
the legacy generic `MUSO_ADMIN_*` pair becomes a production-only fallback. Do not
run dev auth with v0.10, which still reads the generic pair. For ad-hoc SSH, load
`/etc/openclaw/main.env` through `systemd-run --setenv=HOME=/root -p EnvironmentFile=...`;
never source a systemd EnvironmentFile as shell code. Trino lowercases unquoted SQL aliases (use
snake_case). Cron PATH (`/usr/bin:/bin`) misses `/usr/local/bin`, so bare `muso` exits 127
under cron (use an absolute path; systemd units DO include it). The prewrite hook fires for
EVERY provider write including `slack send` (branch on `MUSO_HOOK_PROVIDER`). `--text`
escapes a literal `\n` (pass real newlines). StateDir/audit are fail-closed (a HOME-less
unit refuses to send). All of this is invisible to CI, which stubs `muso` on PATH.

**Capability-write wrapper traps.** A verb's TIER (plain-write vs approval-tier) is
documented in its `*Long` help text, NOT its flag list (the approval flags
`--yes/--confirmed-by/--approval-ref` are global persistent flags). Approval-tier verbs
(e.g. `credits verify`, `profiles consolidate`) fail closed without them; plain writes
(`credits remove`, `profiles claim-self`) need only `--requester`. Separately, `--dry-run --json`
emits a `dryRunResult` envelope (`{dryRun:true,method,url,body,note}`), NOT the result
struct, so branch on `.dryRun==true` and surface `.note`/`.body` as the preview.

**`muso-read.sh` is the canonical read-only wrapper; extend it.** A reject-by-default
allowlist around `muso` on the main gateway. To give an agent read-only access to a new
surface, add a verb-position-gated `case` branch HERE rather than creating a new skill or
calling raw `muso`. Non-SQL surfaces gate by verb POSITION (do not keyword-scan flag values;
a `--where '%delete%'` filter is a read); only the SQL `query` path scans the statement. It
is accident-safe, not a crypto boundary (a real boundary needs a scoped read-only credential).

**The `muso` CLI ships a `caroline` MCP role.** A hard REGISTRATION allowlist (forbidden
tools are simply not registered): 3 reads + 11 capability-gated writes built for autonomous
support resolution. Every write re-verifies ownership server-side against an out-of-band
actor identity (`--actor-identity` / `X-Muso-Actor` header), never a model-supplied email,
and the close path re-derives `RESOLVED` server-side (the caller cannot assert it). Per-call
caps (credits 50/call, 100/day) are advisory under concurrency.

## Data, Trino & analytics

**Trino catalog name mapping.** A query wrapper rewrites legacy Athena DB names to Trino
`catalog.schema`. Key facts: `platform-core-backend-export-prod` to `postgresql_core.public`
(live PG); `platform-stats-export-prod` to `postgresql_stats.public` (track_daily, readable);
`cube_analytics_*` live in `postgresql_olap` (sharded, query the view), NOT `postgresql_analytics`;
`hive.mlc` does not exist (the real schema is `hive."platform-industry-mlc-bi-prod"`);
`bi` to `postgresql_analytics.public`. `postgresql_industry` SELECT is permission-denied for
the Trino PG role (SHOW TABLES works, SELECT fails).

**`postgresql_stats` is a hot-standby replica that kills long queries.** Multi-minute scans
die with `canceling statement due to conflict with recovery` or an idle-in-transaction
timeout. Use only point lookups and indexed filters; for any per-profile-over-time metric,
snapshot a cheap canonical read yourself and diff your snapshots rather than aggregating the
history tables live.

**Live per-artist lifetime streams source.** The muso.ai profile "Streams" headline is
`postgresql_olap.public.cube_analytics_industry_stat_profile_view.stream_stats` (a JSON array
of cumulative snapshots); lifetime total = the LAST element. One row per profile_id, fresh
for the paid/active set, on-view refresh for the cold long tail. Runner-up for batch reads:
`cube_analytics_profile_view.ce_streams WHERE period='all'` (native bigint, no json_parse, all
rows fresh, but covers only paid profiles). `profile_type` is one of {artist, organization,
professional}; `organization` = labels/publishers (filter to `artist` to exclude them), and
`artist` still includes engineers/producers. The `profile_v3*` tables are DEAD (Aaron's
directive); anything `*v3*` is deprecated in favor of the cube. Do not read them.

**Do not confabulate Muso stats.** An optional lookup skill or SOP does not force a model to
query; agents have answered stream-count questions by citing an external tracker with ZERO
tool calls. Pull every Muso figure (streams, credits, counts) via the data tool. Always-loaded
SOUL/AGENTS doctrine fires far more reliably than an un-invoked skill, but it is still prose,
not a hard guarantee.

**Seven active analytics scrape platforms.** Spotify, YouTube, YouTube Music, Shazam, TikTok,
SoundCloud, Instagram (Aaron, 2026-05-08). NOT Audiomack or Qobuz (a common stale "named 7").
Apple Music is explicitly not in the active list ("no committed date"). Several customer-facing
reference files quote this list; keep them in lockstep when the set changes.

**"fastlane" is an analytics bootstrap, NOT credit verification.** "@Ops fastlane <profile>"
means `POST /admin/analytics/{profileId}/fast-lane` (a profile analytics bootstrap/refresh,
fire-and-forget, idempotent, no credit-approve gate). It is repeatedly misrouted to the
credit-verification pipeline. Never treat a fast-lane call as a credit-edit fix signal.
A **fastlane+ superset** (`POST /admin/analytics/{profileId}/fast-lane-plus`, and per-user
`POST /admin/user/{userId}/fast-lane-plus`) ALSO re-discovers the catalog and force-rescrapes
every source — use it when tracks/credits are *missing* (plain only recomputes existing data).
Both lanes are owned by the same `muso-ops-fastlane` skill (`--lane plus` / `--scope user`);
the operational detail (decision table, caveats, cost model) lives there, not here.

**Collaborators are pipeline-owned; the classic refresh verbs don't touch them.** The profile
"Collaborators" list is served from `postgresql_catalog.public.catalog_profile_collaboration`
(hash-partitioned `_0.._29`, bucket = sum(profile_id bytes) % 30, no timestamps) +
`catalog_profile_aggregations`, rebuilt only by data-platform machinery — the offline
`platform-data-processing` Spark job ("Catalog Profile Collaboration" formula) and the
industry-api rebuild path below. The classic remediation verbs are the wrong tool here:
cache clear / `analytics recalculate` / fast-lane refresh the analytics cube, not this table —
re-running them changes nothing — and hydra's DB paths are read-only, so don't attempt Trino
writes either. The ONE admin-API write path for collaborators is the dedicated rebuild verb:
When collaborators are stale, use `POST /admin/profile/:profileId/collaborators/rebuild`
(added 2026-07-02 in core-backend + industry-api; verify it's deployed — 404 means not yet):
it rewrites the profile's collaboration rows from current tracks, deletes stale rows, re-syncs
`collaborations_count`, and clears the profile cache. Run it only AFTER verifying the credit
edit has landed (the credits list reflects it) — the rebuild reads current catalog state, and
it's idempotent, so re-run if in doubt. If the route 404s or fails, escalate to the
data-platform owners with the profile id; the offline recompute can silently skip a profile
for months (Drizzy c512e5d5, 2026-07-02: a 2026-02 credit never ingested and removed-track
collaborators from 2025-08 still showing, a week after credits were corrected — root cause:
the online collaboration writer is gated behind `FASTLANE_OWNS_STATS`, default off, and the
offline Spark rebuild is manual-trigger-only since 2026-05-19).

**Prod core writes go through the app, not the DB.** hydra's own core access is READ-ONLY
(`hydra_ro` via the DSN and the Trino `postgresql_core` catalog). The only read-write channel
is `kubectl exec` into a `core-backend-api` pod in `muso-prod` and running the app's own
Sequelize models (correct RW user, camelCase columns, soft-delete for free). Global admin is a
`user_to_role` row with `roleid 1`; no API or CLI grants it, and the user must log out/in to
mint a JWT carrying `admin`.

**`credit_requests.verificationData` shape varies by which backend rules fired at submit.**
Roughly 58% are velocity-only (`reject_high_velocity_profile:100`, NO `approve_*` keys, total
pegged at 100 artificially); ~33% are rich Band-A (`approve_owning_track` etc., the
auto-approvable bucket); ~3.6% are `track_pending_capture` (track not in catalog, unevaluable).
`is_approved` is false across the whole unverified queue. Do not use `total_risk_percent` as a
hard cutoff without a corroborating signal, since the velocity flag short-circuits the other
rules and inflates the score.

**Muso profile UUIDs do not appear in external music-database URLs.** External catalog sites
(Apple Music, MusicBrainz, Discogs, AllMusic, and the like) use their own IDs;
`URL.contains(muso_uuid)` only matches the internal `muso.ai/profile/<uuid>` page. To bind
external-source activity to a specific profile, use the "anchor + post-anchor" rule (a successful
`muso.ai/profile/<uuid>` load earlier in the run), not a literal-UUID match. (Which external
sources are in-scope for credit-verification Tier-1 is a separate question; see
`working-in-hydra.md` content rules.)

**Perplexity Sonar via OpenRouter.** Search is built in (do NOT add `tools`, a `plugins` web
block, or a `:online` suffix). `response_format` must be `json_schema` (`json_object` 400s).
Citations land at `choices[0].message.annotations[].url_citation.{url,title}`, NOT a top-level
`.citations[]`, and the model cannot fabricate them, so cross-checking model-claimed domains
against annotation hosts is a sound anti-hallucination gate. Perplexity knobs
(`web_search_options.search_context_size`, `search_domain_filter`, `search_recency_filter`) go
as top-level request params.

## Intercom

**Intercom collapses all channels into `source.type="conversation"`.** Messenger, IG, FB,
WhatsApp, SMS, X, and TikTok all arrive identical; the only reliable channel signal is the
workflow-applied `tags`. Per-account `blockedChannelTags` (case-insensitive) hard-skips the
agent on any conv carrying a matching tag, before live-check and dispatch. The tag is applied by
an Intercom workflow rule, not the channel bridge, so it is fragile but it is all Intercom
exposes.

**Intentional silence must be a sentinel chunk, never empty output.** Zero customer-facing
chunks on a still-replyable conv trips the silent_dispatch alarm (pages the supervision
channel). To deliberately not reply, the agent emits a `[[NO_REPLY]]` sentinel as its ENTIRE
reply; the channel code posts nothing, but because a chunk was produced no alarm fires (the read
receipt reaction stays). Anyone changing reply/silence behavior must preserve this invariant.

**Edge `silent_dispatch` is usually a false-positive timing alarm.** It fires (~50/day) when a
dispatch returns 0 buffered chunks at the instant the detector checks, but the reply flushes a
beat later or a sibling dispatch delivers. "Caroline not responding" P0s are almost always this.
Verify before alarming: for each affected conv, confirm the LAST event is a delivered reply.

**`dispatch_to_agent` count far exceeding `replied` count is mostly debouncing, not failures.**
The plugin SDK coalesces rapid-fire user messages into one reply, so three dispatches map to one
reply legitimately. To find real strands, count per-conv-id (dispatched but never replied), not
totals.

**A closer's shadow log must NOT be a de-confliction source for the needs-human digest.**
Wiring one in looks obviously right and is actively harmful. The digest queries only OPEN
conversations, so a closed conversation cannot appear in it anyway — the sole runtime effect
of excluding an append-only close log is to hide a conversation the customer **reopened** by
replying after the silent close. That is precisely the cohort that must resurface (reply-to-
reopen is the advertised recovery path for every silent close), and the append-only log never
prunes, so the conversation is buried forever. Exclusion is the safe direction only for the
other CLOSERS and the ops-drain, where over-exclusion just means "leave it alone". Found
building `close-stale-conversations.py` (PR #746); the `close-resolved` and `close-duplicate`
shadows already wired into `cs-needs-human-digest.py`'s `default_state_paths()` carry the same
latent bug — pre-existing and unfixed.

**A scan-then-mutate sweep over thousands of records must re-verify LIVE immediately before
each mutation.** The candidate list is a snapshot; a ramped drain reaches row 500 many minutes
later, and in that window the world moves. Two independent things must be re-read per item, not
once per run: (a) the record itself — a customer reply that lands before the close would never
reopen an already-closed conversation, so closing on the stale snapshot silently buries a
now-waiting customer (`still_eligible_live` re-fetches and re-runs the WHOLE gate, not just
"is it still open"); and (b) sibling ownership — another sweeper can claim the id mid-drain,
so `owned_ids_by_source(default_state_paths())` is re-read before every close, with corrupt
sibling state mid-drain stopping the remaining drain fail-closed. QA caught (b) after (a) was
fixed: re-fetching the record but judging it against the scan-time ownership set is a
half-fix that still races.

**Write the intent row BEFORE the mutation, the outcome row after — "can't record" must mean
"don't do it".** An audit row written only after a successful call loses exactly the cases you
most need: a mutation that lands remotely but whose response read fails leaves no trace, and a
log-write failure after the call crashes with the action already taken. `close-stale`
fsyncs an `{"kind":"attempt"}` row first, then `{"kind":"closed"}` / `{"kind":"close_failed"}`.
Its own idempotency reader honors only `closed` rows so an ambiguous attempt is retried — safe
precisely because of the live re-verify above (an already-closed record is skipped, never
re-mutated), while sibling consumers read every row (over-exclusion, their safe direction).

**The outbound email sanitizer rewrites every non-allowlisted email to `support@muso.ai`.** So
a leaked-reasoning line naming a customer's real email becomes a FALSE "support@muso.ai is tied
to X" in the shipped reply. When you see that string in a reply, suspect the redaction artifact
first, not a hallucinated identity.

**The Intercom token lives in three live spots plus the repo, and needs "Write tags".** It sits
in the edge gateway inline config, `edge.env`, and `main.env` (rotate together and restart the
right gateway). A token with only conversation-write can reply/assign/close but `addTag`
(`POST /tags`) 401s, so read working is not write working; verify a rotation with a `POST /tags`.
The token is also committed plaintext in the repo and re-synced on deploy, so a live-only swap is
reverted on the next deploy (prefer a secret-ref).

**Intercom API quirks for review and search.** The token can attach existing tags but cannot
CREATE them (`POST /tags` 401; create in the UI first), and tagging requires a valid `admin_id`.
`conversation_rating.rating` is not a searchable field. `state=open` does not mean unresolved
(~95% of convs are open; the team rarely closes in Intercom), so prioritize by severity or by
"customer spoke last" (`waiting_since`, or `last_contact_reply_at` > `last_admin_reply_at`).
`POST /conversations/search` from a non-curl client (urllib) needs `Accept: application/json`
or it 406s, and its results already carry `source.body`/`source.author`/tags.

**Conversation deep-link form.** The only working form is workspace-scoped:
`https://app.intercom.com/a/inbox/<workspaceId>/inbox/conversation/<conversationId>`. The legacy
`https://app.intercom.com/a/inboxes/all/conversations/<id>` 404s. Copy from a canonical producer
in the repo; grep for `inboxes/all/conversations` and treat any hit as a bug.

**Instagram kill-switch.** When the agent misbehaves on IG DMs specifically, toggle off "Allow
Access to Messages" in the Instagram business app (Settings, Privacy, Messages, Connected Tools).
That stops IG DMs reaching Intercom at all. Other channels need a different mitigation.

**Reading fleet and CS health from gateway logs.** Current gateway journald has no per-run
success marker. Main-agent activity = distinct `run=<uuid>`; failures = `outcome=error` lines
(so you can report activity and failures, not a success rate). The edge/CS agent (Caroline) logs
0 `run=` turns because it is Intercom-event-driven: measure via `[intercom]` event lines and the
canonical outbound marker `[intercom:default] replied conv=<id> partId=<id>` (count DISTINCT
`conv=`; do NOT use `sessionKey=agent:support:`, which undercounts ~100x). 0 `[intercom]` events
in 24h is a silent CS outage.

**Debug "why did Caroline do X" via the session trajectory JSONL, not the chat.** The chat text
can be confabulated; the `.trajectory.jsonl` under the support agent's sessions is ground truth.
Parse `type=="tool.call"` events (grepping tool names over-counts, since the tool definitions
repeat inside every `context.compiled`). Cross-reference the gated write-action audit logs under
`/var/log/openclaw/*.jsonl`. `create_ticket` has no dedicated audit log, so confirm a claimed
ticket actually exists with a ClickUp GET.

**The Intercom plugin's tests are not typechecked.** Its tsconfig excludes `tests/` and the test
runner is transpile-only, so a "tsc will fail on the test stub" review finding is a false positive
there, and type drift in tests is invisible to CI (the implementing classes are the only
compile-time enforcement of the interface).

## NocoDB & ClickUp

**NocoDB is the canonical B2B-Ads intelligence store, reached via REST, not MCP.** Base
`p11hvpwapu4hv0x`; tables Contacts Intelligence `m9vsbijhrr9ddeu` and Company Intelligence
`mvr6nmzcv7albxt`. There is NO NocoDB MCP server registered, so any doctrine saying "use the MCP
NocoDB connection" is stale. The subcommand is `records.ls` / `records.count` (NOT `records.list`).
Domain values are dirty (e.g. `apogeedigital.com (updated)`), so never trust an exact `(Domain,eq,...)`;
normalize domain and name identically on both sides before deduping.

**NocoDB Cloud silently clamps `records.ls --limit` to 100.** A "short page means done"
pagination loop truncates to ~100 rows. Terminate only on the boolean `pageInfo.isLastPage` or an
empty page, and advance offset by the actual number of rows returned.

**NocoDB Cloud assigns two different base IDs.** The `<ncId>` in the MCP URL (`/mcp/<ncId>`) is
NOT the admin base id (`p...`). The admin endpoints `/api/v2/meta/bases/{baseId}` resolve only the
`p...` id; translate via the MCP `getBaseInfo` tool. The docs claim they are the same, and they are
wrong on Cloud.

**NocoDB PATs carry their own scope, independent of the user's role.** A narrow-scope token 403s
`ERR_FORBIDDEN "API token does not have permission to <op>"` even when the issuing user is
workspace-owner. Inspect `api_token_meta.scope` in `/api/v1/auth/user/me`; fix by regenerating the
token with all resources plus every scope as Read+Write.

**The ClickUp action-request board resolves into done-type statuses.** On list `901000600160`,
`date_closed` is effectively always null and `date_done` carries the resolution timestamp, so any
"how many closed?" metric keyed only on `date_closed` is a silent permanent zero (use `date_done`,
or both for robustness). Task date fields are ms-epoch STRINGS (`| tonumber` before comparing), and
the default list fetch excludes closed tasks unless `include_closed=true`.

**The profile-merge list has two distinct closed statuses.** Same list `901000600160` carries
`resolved` (ops executed the merge, the canonical close status) and `user updated` (customer added
info), both `status_type=closed`, plus `impossible`. A sweep script hardcoding `resolved` on apply
is correct, not a bug.

**Credit and analytics action-request tickets have NO Intercom thread.** These tickets (board
`901000600160`) are not created from Intercom (empty Intercom Link field, no deeplink), so an
in-app resolve-notify cannot reach the customer; the only contact point on file is the customer
email. To probe "is this credit ticket fixed?": resolve the entity via the ticket Profile ID when
present, else `email` to `users.id` to the `claiming` table to `profileid` (credits live on the
CLAIMED profile, NOT keyed by `credit_requests.userid`); fix signals are post-ticket admin credit
edits in `action_log` plus the current `credit_requests` status. `credit_requests` has no approval
timestamp (only `createdat`).

## Slack rendering

**A Block Kit `header` is `plain_text`, so a mention there does not ping.** `<@U...>`,
`<!channel>`, and `<url|label>` render as dead literal text in a header. Put the live ping in an
mrkdwn `section` block (the only place mentions and links are parsed). Other limits: <=50
blocks/message, section mrkdwn text <=3000 chars (an over-limit element makes `chat.postMessage`
reject the WHOLE message, so clamp untrusted text).

**Escape untrusted text at the Slack output boundary.** ClickUp task names are customer-derived
and not Slack-safe (the title builder collapses whitespace but does not strip `& < >`). Any sink
rendering a `.name` into mrkdwn is an injection vector: a crafted title can `<!channel>`
broadcast-ping, `<@U>` ping users, or inject a misleading `<url|label>` link. Escape at the OUTPUT
boundary (`&` to `&amp;` FIRST, then `<` and `>`), not at the ClickUp source (which would corrupt
the ticket display). Leave your own composed link markup unescaped.

**Block Kit action buttons are single-use without an interactivity handler.** A url-button is
consumed for the whole channel on the first click ("selected by @user") when the posting app has
interactivity enabled but never ACKs. For a perpetual multi-user navigation link, use a mrkdwn link
`<url|label>` in a section/context block (it emits no interaction payload). Do not run a
system-generated deeplink through the mrkdwn escaper (it mangles `&` in query strings); only
customer-controlled text needs escaping.

**Slack threads bypass require-mention once the bot has participated.** `requireMention:true` only
gates top-level channel messages; a reply in a thread the bot already joined counts as an implicit
mention. Fix = `channels.slack.thread.requireExplicitMention:true`. Trade-off: users must re-@ the
bot on every thread follow-up, and a silent bot in a thread is by design.

## Caroline (support agent) domain

**The outbound sanitizer bans a fixed word list; grep the FULL list.** Caroline's reply sanitizer
redacts these words from customer-facing text: tool, lookup, error, unavailable, system, API,
ticket, ClickUp, openclaw, HYDRA. When authoring or reviewing any customer-facing KB answer or
reply text, grep the COMPLETE list (a partial grep once missed "system" and "error", which the
sanitizer would redact mid-sentence into a garbled reply). Use the approved alternatives ("flag for
our team" not "ticket", "payment/billing issue" not "error"/"system error"). The ban applies to
what she says to customers, not to internal guidance prose.

**Time-bound copy is tagged `EXPIRES YYYY-MM-DD`.** The date is the first day the surrounding copy
goes stale. Two forms: bold markdown (visible doctrine Caroline reads in context) and an HTML
comment (customer-facing FAQ, kept out of her reply but greppable). Whenever you add date- or
window-specific support copy, add a marker with a one-line note; sweep with `grep -rn "EXPIRES <date>"`.

**`analytics-followup` carve-out — RETIRED 2026-06-30 (analytics migration complete).** History:
during the 2026-04 analytics platform migration, support doctrine forbade analytics tickets entirely
— the migration was platform-wide with NO per-account fix, so a ticket / SLA / follow-up promise
would have been a lie — even though the action-type taxonomy tiers `analytics-followup` as Tier 1.
The two proactive notifiers (`resolve-notify.py`, `overdue-verification-notifier.py`) excluded it
from their ALLOWLIST and a bats test pinned the exclusion. The migration is now done: analytics runs
on the upgraded platform and is handled per-account like any other Tier-1 follow-up (file the ticket,
quote a 2-business-day SLA, normal escalation language). The exclusion was removed and the test
flipped to assert eligibility. Do NOT re-add the exclusion unless analytics regresses to a
platform-wide, no-per-account-fix state. See `workspaces/support/SOUL.md` "Analytics handling" and
`reference/common-issues.md` row #7.

**RAG is search-tools-only, tightly scoped, with CI-pinned invariants.** Caroline's memory search
indexes only the read-only `reference/` directory (`extraPaths:["reference"]`, never sessions,
tickets, or transcripts), search-on-demand with no auto-injection. CI-blocking invariants:
`plugins.allow` must exclude `memory-lancedb` and `active-memory`; dreaming disabled;
`session.dmScope` stays `per-channel-peer` for per-conversation isolation. The reason is that a
customer-facing agent must never leak customer A's transcript into customer B's session. Embeddings
route through OpenRouter, since the on-box `OPENAI_API_KEY` is a placeholder that 401s against real
OpenAI endpoints.

**`/admin/team` envelope and the founder cohort.** The live row carries more than the test fixtures
documented: `{id, email, name, createdAt, isClaimed, founder:{active,sinceYear,lapsedAt},
subscription:{period,status,plan}, ...}`. Default personal workspaces are auto-named "<Person>'s
Workspace", so use `team.name` as a recognition hook only when it is a real label/org name, else
greet by first name. Founder `sinceYear` is the true tenure; a separate `createdAt`-derived
"customer since" field is inert (every sampled active founder had `sinceYear == createdYear == 2023`).
Inspect the live API before plumbing any new account field, since the fixtures under-spec it.

**`/admin/founding/*` -- founder buy-back and comp reinstate (shipped 2026-07).** Two admin
endpoints recover founder status; both take `teamId` = the Muso **workspace id** (not a user
id/email). Resolve email -> workspace via `muso teams list --email <e>` or the support
`subscription_status` tool (returns `workspace_id` even for a cancelled/lapsed sub).
- **Paid buy-back:** `POST /admin/founding/buyback/checkout {teamId}` -> a Stripe Checkout
  URL (`{url, session_id, arrears_months, arrears_cents, since_year, seats}`) bundling a
  Pro-annual subscription + a one-off arrears charge; link lives ~24h. On payment, status
  reinstates automatically via the Stripe webhook (`founding_buyback_sub` branch) -- no
  further action. Serves both lapsed reinstatement AND never-founder late buy-in (arrears
  computed back to the 2026-06-30 anchor; the never-founder path is inferred from spec §2 +
  the error set -- verify against the live endpoint before relying on it). Errors (all 400):
  already an active founder (not
  lapsed, nothing to do) / not found / no owner (bad teamId or workspace has no owner).
- **Comp reinstate (free goodwill):** `POST /admin/founding/reinstate {teamId, reason}` ->
  clears the lapse latch and restores status immediately, no Stripe. `reason` is mandatory
  (non-empty) and written to the founding audit log. Only works on a **lapsed** workspace
  ("Team is not in a lapsed state" otherwise). Treat like a refund override (money-adjacent
  goodwill): team discretion, not customer-advertised.
- `since_year` is preserved from the original founding record (drives the "Founder since 'YY"
  badge). Hydra wrappers: the typed `muso founding status|buyback-checkout|reinstate` verbs
  (ops via `skills-all/muso-founding-member`, main gateway) and Caroline's
  `founding_status`/`founding_buyback_link` plugin tools (edge, verified-email-anchored) --
  she mints the paid buy-back link herself; only comp (free) reinstate stays an ops-executed
  action-request. The old `buybackQuote` + `buybackPaymentLink`
  two-step flow is **retired** -- don't build against it. Underlying policy: founder status is
  a derived property (continuous paid coverage since the anchor; 7-day grace on a failed
  payment; voluntary cancel drops at period end); customer-facing version lives in
  `workspaces/support/reference/founding-member.md`.

## People & roles

This is the most churn-prone data in this doc. Treat the tables below as a starting point and
re-verify against the live source of truth (the `resolve_slack_to_email()` map in the ops admin-api
script, and the in-product team directory) before relying on a value. Do not guess an email or ID
from a display name. When a member is added or removed, update both the roster and the resolver in
the same change.

**Contact roster (as refreshed 2026-05-07).**

| Name | Slack ID | Email | Role |
|---|---|---|---|
| Aaron Kaufman | `U7RP6HKUZ` | `aaron@muso.ai` | CEO / founder / override authority |
| Jan Roland Delmo | `U038BM16T7W` | `jan@muso.ai` | Head of Operations |
| Liza Basco | `U0A8CCTTAAG` | `liza@muso.ai` | Accountant |
| Mariia Bubley | `U03LP8YHLPK` | `mariia@muso.ai` | UI/UX designer + junior front-end dev |
| Nicholas Sollazzo (Nick) | `U0AL36NADEY` | `nick@muso.ai` | Chief Agent Officer |
| Serhii Ostapchuk | `U03TYGJF1N3` | `serhii@muso.ai` | CTO |
| Artem | `U02N2NP3H7F` | `artem@muso.ai` | Mobile developer |
| Faith Undie | `U0AV9C7CFRQ` | `faith@muso.ai` | Community & Social / Designer |
| McLaren Amberti | `U02S7C96CGN` | `f@muso.ai` | Sales Operations |

**Email-pattern rules (the pattern is not universal).** The `<first>@muso.ai` pattern holds for
most people, but capture the exceptions, do not extrapolate: Jan is `jan@muso.ai` (NOT `jay@`, even
if Slack display shows "jay"); McLaren Amberti is `f@muso.ai` (a single letter `f`, NOT `mclaren@`).
McLaren is a distinct person and is NOT Mariia.

**Authority and approval map (as stated 2026-06-24).** Aaron has full authority; policy and
security-file changes are Aaron-only. Nick is the top-tier owner of everything AI plus most dev.
Serhii owns most dev alongside Nick. Jan is the customer-support / operations captain. Mariia is
junior (UI/UX plus newbie front-end) and must NOT hold elevated or auto-approve authority. Artem owns
mobile. When an executable allowlist disagrees with this policy, TIGHTEN the wrapper to match the
policy, do not loosen the policy to match the wrapper.

**Intercom admin IDs are separate from Slack IDs.** App `id_code` `dwjzhcge`. Caroline admin
`5763097` (`operations@muso.ai`); Nick `10206197`; Aaron `5201828`; the Operator/bot `4359478`.
Note that `jandelmo89@gmail.com` (admin id `5465657`) is Jan's Intercom ADMIN account, not a
customer; exclude it and all `@muso.ai` addresses from customer-complaint analysis.
