# Operations — relocated procedures

> Moved out of `MEMORY.md` on 2026-08-26, **unchanged**. `MEMORY.md` is injected at agent
> bootstrap under a combined size cap, past which the MIDDLE is silently dropped — so a
> procedure sitting there can push an authority rule out of the agent's context. Procedures
> are read when you are about to perform them, not on every boot. Authority lines stayed in
> `MEMORY.md`. Current platform state: `AGENT_CURRENT_TRUTH.md` in shared-reference.

### Hiding / Force-Cancelling an Apple App Store Subscription (2026-04-23)

**Use case:** User has an active Apple App Store subscription but their payment method is no longer supported. They want to resubscribe via Stripe. Jan requests the Apple sub be "hidden" (force-cancelled in our system) so the user can switch.

**Authorization:** Jan (U038BM16T7W) has God Access to the admin API — no separate Aaron approval needed for subscription operations when Jan requests them.

**Step-by-step:**
1. Look up the user: `GET /admin/user?keyword=<email>` → get `userId`
2. Find the subscription UUID: `GET /admin/subscription?keyword=<email>&limit=20` → the `keyword=` param does email search and returns the internal UUID (the generic list endpoint ignores all other filters like `userId`, `teamId`, `service`)
3. Force-cancel: `POST /admin/subscription/<uuid>/force-cancel` with empty body `{}`
4. Verify: re-run step 2 and confirm `status: cancelled`

**Key gotcha:** `GET /admin/subscription` ignores `userId`, `teamId`, `service`, `externalSubId` filters — it just returns a global paginated list. The only filter that works is `keyword=<email>`. Always use that to find a specific user's subscription UUID.

**Audit log:** `api-logs/admin/YYYY-MM-DD.jsonl` — log before execution, update with result after.

### Add Credits to Organization Profile by IPI (confirmed 2026-06-04)

When asked to add credits to an organization profile using an IPI, do not rely on `POST /admin/profile/:profileId/link-external` as the only path. That route can reject organization profiles with `Cannot link organization profile`.

Working fallback:
1. Look up the IPI in Trino/MLC and identify the existing source profile/raw MLC-backed profile.
2. Fetch source profile credits and target profile credits through admin API.
3. Diff by track ID to avoid duplicates.
4. Add only missing credits with `POST /admin/track/:trackId/profile/:profileId/credits` using body `{"credits":["Publisher"]}` or the source role(s).
5. Read back target profile credits and confirm the new tracks are visible.

Example: Jan requested Carbonara (`6392f692-df48-465a-a406-a7eaf57e3aed`) + IPI `1236786917`. IPI mapped to `EDITION CARBONARA X SIDE` (`869efc2f-ff6c-4f5d-8067-33b944cd08f7`) with 41 Publisher credits. Carbonara already had 20; added the 21 missing Publisher track credits explicitly. Readback showed Carbonara 63 → 84 credits.

### Profile Merge Landing Verification (corrected by Aaron, 2026-07-03)

For the async catalog fold after `POST /admin/profiles/merge`, HTTP 200 means queued, not done. Do not use `loser.merged_to`, `merged_to_id`, `survivor.merged_profile_ids`, or the continued existence of the loser profile document as landing signals on this path; they can stay empty/None forever and the soft-deleted loser doc normally remains.

A merge has landed only when all three predicates are true:
1. `loser.deleted.is_deleted == true`
2. `loser.raw_profile_ids` is a subset of `survivor.raw_profile_ids`
3. `count(catalog_track where profiles.profile_id == loser and not deleted) == 0`

Classify profile merge follow-up in three states:
- `LANDED`: all three predicates pass. No action.
- `PENDING`: predicate fails and `industry-proc-catalog-admin-prod` consumer group lag is greater than 0. Do not escalate; re-check after lag drains.
- `DROPPED`: predicate fails, consumer lag is 0, and at least 1 hour has passed since the API call. Escalate as "verify + re-fire", not "manual merge"; never advise a blind manual re-merge without running the predicate first because partially landed state can damage the survivor.
