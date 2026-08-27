# Coordinator — Fast Lane immediate profile reprocess runbook

> Moved out of `MEMORY.md` on 2026-08-26, **unchanged**. It left because `MEMORY.md` is
> injected at agent bootstrap under a combined size cap, past which the middle is silently
> dropped — and a multi-page procedure is the wrong thing to be spending that budget on
> when authority rules are competing for it. This is a runbook: read it when you are about
> to perform the operation, not on every boot. The AUTHORITY lines that used to sit inside
> it stayed behind in `MEMORY.md`, because who may ask for this is not a lookup.
> Current platform state: `AGENT_CURRENT_TRUTH.md` in shared-reference.

### "Fast Lane" — Immediate Profile Reprocess (Aaron directive 2026-05-15, expanded 2026-05-22)
- When Aaron (or an authorized requester) says "fast lane" + a user name or profile name/URL, that means: immediately reprocess that profile with **brand new data capture** (full fresh pull from sources) — NOT a recalculation of existing data.
- Treat "fast lane" as a priority signal: jump the queue, capture fresh stats end-to-end.
- Route to whoever owns the reprocess pipeline (likely @CTO / @DevOps for the data pipeline, @Ops for profile-side ops). Confirm with Aaron which team currently owns the trigger if unclear.
- Log every fast-lane request (who asked, profile id/name, timestamp, who ran it) and DM Aaron the result when complete.

#### Admin Fastlane API (training from Aaron 2026-05-22)
All endpoints require admin role (`Acl.allow(['admin'])`). Base: `/api/w/v3/`.

**1. Single profile** — `POST /admin/analytics/:profileId/fast-lane`
- Body: `{ workspaceId?, triggerSource? (default "admin_fast_lane") }`
- Use for: VIP triage, manual refresh after data fix, single-profile testing.
- Does: creates PASH row (clears "Analytics Initializing" gate), calls `publishProfileFastLane` (routes mega/express/standard by size + workspaceId), invalidates Redis caches for `/profile/:id`.
- Returns: `{ profileId, bootstrapped, triggerSource, workspaceId }`.

**2. User fan-out** — `POST /admin/user/:userId/fast-lane-analytics`
- Body: `{ triggerSource? (default "admin_fast_lane_user") }`
- Use for: "my analytics is broken across all my profiles", post-claim/seat-add sweep, onboarding workspace admin.
- Resolves union of `user.neptuneProfessionalId` + `claiming.profileId WHERE userId` + `roster_seats.seatId WHERE teamId` (default team). Caps at 200 profiles. Bootstraps + publishes parallel (concurrency=8, 15s timeout each).
- Returns: `{ userId, profileIds, bootstrapped, published, publishFailed, skipped }`.

**3. Recent-paid bulk** — `POST /admin/analytics/fast-lane-recent-paid` (new 2026-05-22)
- Body: `{ since? (default "4w", format <N><d|w|m|y>, max 2y), limit? (default+cap 5000), triggerSource? (default "admin_recent_paid"), dryRun? }`
- Use for: refresh everything added in last N weeks, post-bugfix re-process, periodic narrower-than-CLI backfill.
- Queries union of `roster_seats.createdAt` + `claiming.createdAt` within window, filtered to teams with `subscriptions.status IN ('active','trial')`. Phase 1 bootstrap (concurrency=8) → Phase 2 publish (concurrency=16, 15s timeout). `publishProfileFastLane` handles mega routing, hard ceiling skip (catalog-org entities), standard pool routing.
- dryRun=true returns `profileIds` without firing.

**Pool routing:**
- `>25K credits` → skipped (catalog-org, batch-owned)
- ~~Mega → `industry-proc-fastlane-mega-prod-v1` (replicas scaled to 0)~~ · ~~Standard → `industry-proc-fastlane-prod-v2` (500 replicas)~~
- **Measured live 2026-08-26:** mega = `industry-proc-fastlane-mega`, **running, 7 replicas** ("scaled to 0" is retired); standard = `industry-proc-fastlane-v2`, ~400, KEDA 230-280; **`industry-proc-fastlane-priority`, 50 — a fourth pool no memory mentioned**; admin fires = `industry-proc-fastlane-admin`, 4, KEDA 4-47. Counts are KEDA-driven: read the deployment before quoting one.
- Ad-hoc admin fires that shouldn't compete with bulk → dedicated topic `industry-proc-fastlane-admin-prod-v1` via direct `rpk produce` (NOT these endpoints)

**triggerSource labels (logged + searchable):**
`admin_fast_lane`, `admin_fast_lane_user`, `admin_recent_paid`, `credit_admin_add`, `credit_admin_track_add`, `credit_request_approved`, `workspace_claim_seat_approved`, `profile_claimed`, `credit_submitted`, `profile_merge`, `credit_csv_import`, `auto_view_summary`, `auto_view_tracks`, `auto_view_chart`, `backfill_all_paid`. Always set a meaningful one.

**Operational notes:**
- Fire-and-forget — endpoint returns on Kafka enqueue, NOT cube refresh completion.
- Cube refresh ~130s/profile (post PR #1152 parallelization). Drain progress: `industry-proc-fastlane-v2` consumer lag in Grafana.
- Retries idempotent — `GREATEST` on metrics, `COALESCE` on metadata, no destructive duplicates.
- Ceiling `FASTLANE_MAX_TRACK_CEILING` default 25000 credits → silently skipped (publishers/labels).

**Routing for me (Clio):** these are admin-only endpoints. Profile/user/single-name asks → endpoints #1 or #2 (route to @Ops or @CTO with the right body). Bulk "refresh recent" asks → endpoint #3 (route to @CTO/@DevOps). Ad-hoc non-competing admin fires → direct `rpk produce` to `industry-proc-fastlane-admin-prod-v1` via @DevOps.

**Authorized requesters (Aaron directive 2026-05-22):**
- Aaron (U7RP6HKUZ) — unlimited
- Jan Delmo (U038BM16T7W) — can send multiple profile IDs/names; fire them one by one through endpoint #1 (or #2 if user id). Use same admin JWT as other admin API calls. Log each fire + DM Aaron summary.

**Workflow when Jan/Aaron says "fastlane <name or profile id>":**
1. If UUID → use directly. If name → `profile_lookup` to resolve, confirm with requester if ambiguous.
2. `POST /api/w/v3/admin/analytics/:profileId/fast-lane` body `{ "triggerSource": "admin_fast_lane" }`. Admin JWT in same secret store as other admin calls.
3. Log: requester, profile id+name, timestamp, triggerSource, response (bootstrapped flag).
4. DM Aaron with batch summary when set is complete.
5. For multi-profile batches from Jan: serial fires (each is fire-and-forget so it's fast), aggregate response, post one summary.
