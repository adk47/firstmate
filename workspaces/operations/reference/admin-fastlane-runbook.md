# Operations — Admin Fastlane API runbook

> Moved out of `MEMORY.md` on 2026-08-26, **unchanged**. It left because `MEMORY.md` is
> injected at agent bootstrap under a combined size cap, past which the middle is silently
> dropped — and a multi-page procedure is the wrong thing to be spending that budget on
> when authority rules are competing for it. This is a runbook: read it when you are about
> to perform the operation, not on every boot. The AUTHORITY lines that used to sit inside
> it stayed behind in `MEMORY.md`, because who may ask for this is not a lookup.
> Current platform state: `AGENT_CURRENT_TRUTH.md` in shared-reference.

### Admin Fastlane API Runbook (trained by Aaron, 2026-05-22)

**Status:** Live admin API reference provided by Aaron. All endpoints require admin role (`Acl.allow(['admin'])`) and return JSON. Treat calls as admin writes: Aaron, Jan, and Nick are self-authorized; other requesters require Aaron review/approval before execution.

**Purpose:** Fastlane clears a profile analytics dashboard out of “Analytics Initializing” by creating a `profile_analytics_stats_history` (PASH) row, then enqueues `publishProfileFastLane` work. It is fire-and-forget: endpoint success means Kafka enqueue succeeded, not that cube refresh has completed. Duplicate per-profile fires are idempotent/non-destructive (`GREATEST` on metrics, `COALESCE` on metadata).

**Endpoint 1 — single profile (most common admin tool):**
`POST /api/w/v3/admin/analytics/{profileId}/fast-lane`
- Body: `{ workspaceId?: "uuid-or-null", triggerSource?: "admin_fast_lane" }`
- Use for VIP triage/unblock, manual refresh after fixing data, or testing fastlane on a specific profile.
- `workspaceId` is optional; when set, routes via express lane.
- Response: `{ profileId, bootstrapped, triggerSource, workspaceId }`, where `bootstrapped` means a PASH row was created (`false` = already existed).
- What it does: creates the PASH row, calls `publishProfileFastLane` with mega/express/standard routing, and invalidates Redis caches for `/profile/:id` so the UI fetch shows fresh data.

**Endpoint 2 — user fan-out:**
`POST /api/w/v3/admin/user/{userId}/fast-lane-analytics`
- Body: `{ triggerSource?: "admin_fast_lane_user" }`
- Use when a user reports analytics broken across all profiles, for post-claim/post-seat-add sweeps for one user, or onboarding a workspace admin.
- Resolves union of `user.neptuneProfessionalId`, processed `claiming.profileId WHERE userId`, and `roster_seats.seatId WHERE teamId` on the user's default team.
- Caps at 200 profiles per call; bootstraps and publishes each in parallel with concurrency=8 and 15s timeout per publish.
- Response: `{ userId, profileIds, bootstrapped, published, publishFailed, skipped }`.

**Endpoint 3 — recent paid bulk sweep (new 2026-05-22):**
`POST /api/w/v3/admin/analytics/fast-lane-recent-paid`
- Body: `{ since?: "4w", limit?: 5000, triggerSource?: "admin_recent_paid", dryRun?: false }`
- Use for “refresh everything added in the last N weeks,” post-bugfix re-processing of recent additions, or periodic backfill sweeps narrower than the `fastLaneAllPaidProfiles` CLI.
- `since` format: `<N><d|w|m|y>`, max 2 years. `limit` default/hard cap is 5000. Use `dryRun: true` to return IDs without firing.
- Query source: recent `roster_seats.createdAt` and `claiming.createdAt` filtered to teams with `subscriptions.status IN ('active','trial')`.
- Work phases: bootstrap PASH rows at concurrency=8, then publish at concurrency=16 with 15s timeout per profile.
- Response when live: `{ since, limit, triggerSource, count, bootstrapped, published, publishFailed }`; dry run returns `{ since, limit, triggerSource, dryRun, count, profileIds }`.

**Pool routing / drain notes:**
- Profiles over `FASTLANE_MAX_TRACK_CEILING` (default 25K credits) are silently skipped; these are catalog-org entities (publishers/labels) and are not user dashboards.
- ~~Mega profiles below the ceiling route to `industry-proc-fastlane-mega-prod-v1`, but that pool is currently scaled down.~~
- ~~Standard profiles route to `industry-proc-fastlane-prod-v2`, with ~500 pool replicas and ~130s cube-refresh wall time per profile after PR #1152 parallelization.~~
- **Measured live 2026-08-26** (`kubectl get deploy -n muso-prod`) — the two struck lines
  named deployments that do not exist under those names and called the mega pool
  unavailable when it is running:
  - Mega -> `industry-proc-fastlane-mega`, **RUNNING with 7 replicas** (not scaled down).
  - Standard -> `industry-proc-fastlane-v2`, ~400 replicas, KEDA-scaled 230-280.
  - Priority -> `industry-proc-fastlane-priority`, 50 replicas — a fourth pool no memory
    mentioned at all.
  - Admin fires -> `industry-proc-fastlane-admin`, 4 replicas, KEDA 4-47.
  Replica counts are KEDA-driven and move continuously: read the deployment before quoting
  a number to anyone.
- Watch `industry-proc-fastlane-v2` consumer lag in Grafana to estimate drain progress.
- For ad-hoc admin fires that must not compete with bulk traffic, use the dedicated admin topic `industry-proc-fastlane-admin-prod-v1` via direct `rpk produce` rather than these endpoints. This is an exception to the old “do not direct-produce” note and should be used carefully.

**Jan multi-profile fastlane workflow (authorized by Aaron, 2026-05-22):**
- Jan (`U038BM16T7W`) has explicit permission to send one or multiple profile names, profile IDs, or profile URLs for fastlane. Treat “fastlane <name or profile id>” from Jan as a self-authorized admin request; do not require separate Aaron approval.
- Use the same admin JWT/admin API path used for other admin calls. Do not ask Jan for credentials.
- For profile IDs/URLs from Jan: extract UUIDs from profile URLs if needed, validate UUID shape, dedupe, and call Endpoint 1 once per profile: `POST /api/w/v3/admin/analytics/{profileId}/fast-lane`.
- For profile names from Jan: resolve via admin profile search, pick the exact/high-confidence match (name match + relevant popularity/credits/collaborators); if ambiguous, ask Jan to choose rather than guessing. Then call Endpoint 1 once per resolved profile.
- Use a meaningful batch triggerSource such as `admin_fast_lane_jan_batch` unless Jan provides a more specific label. Include `workspaceId` only when supplied/known for the specific profile.
- Log before execution in `api-logs/admin/YYYY-MM-DD.jsonl` with requester `U038BM16T7W`, action `fast_lane_multi_profile`, reason, count, and profile IDs. Update the row/result summary after completion.
- Efficient execution pattern: bounded parallelism (5-8 concurrent profile POSTs), per-call timeout ~15-30s, collect `{ profileId, ok/status, bootstrapped, publishFailed/error }`, then summarize successes/failures in-thread.
- If Jan gives a user ID/all profiles for one user, prefer Endpoint 2. If Jan asks for a recent paid cohort/window, prefer Endpoint 3 and dry-run first unless she explicitly requests live fire.

**Common `triggerSource` labels:**
- Manual/admin: `admin_fast_lane`, `admin_fast_lane_user`, `admin_recent_paid`, `admin_fast_lane_jan_batch`
- Credit ops: `credit_admin_add`, `credit_admin_track_add`, `credit_request_approved`, `credit_submitted`, `credit_csv_import`
- Claims/workspace: `workspace_claim_seat_approved`, `profile_claimed`
- Profile ops: `profile_merge`
- Auto page-view fires: `auto_view_summary`, `auto_view_tracks`, `auto_view_chart`
- Batch sweep: `backfill_all_paid`
Always set a meaningful `triggerSource`; it is logged and searchable when debugging why a profile fired.

**Operational cautions:**
- Fastlane is not a scraper backlog bypass; it clears/init queues analytics work, then actual completion depends on consumer lag and profile size.
- Do not reset prod consumer offsets without explicit approval.
- For bulk operations, use `dryRun` first when available and avoid broad sweeps unless Aaron/Jan/Nick requested them.

**Implementation refs:** `Muso-AI/core-backend` — `src/apis/_admin/analytics/fastLane.js`, `src/apis/_admin/analytics/fastLaneForUser.js`, recent-paid endpoint, and `src/utils/publishProfileFastLane.js`.

**Stack notes:** core-backend Node 22/Flow/Sequelize/Express. Prod OVH K3s `muso-prod`/`core-backend-api`. Redpanda `redpanda-{0,1,2}.redpanda.queuing.svc.cluster.local:9093`. PG17 `db-pool.databases.svc.cluster.local:6432`, db `core`. Logs via kubectl from node-1 (`ssh ubuntu@135.148.169.37`), not CloudWatch.
