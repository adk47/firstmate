---
name: "profile-visibility-management"
description: "Hide profiles through the soft-delete endpoint with dual read-back verification."
---

# Profile Visibility Management

Use this procedure when an authorized operations requester says to hide, remove from public view, or soft-delete a Muso profile.

1. Resolve the supplied profile ID with `GET /admin/profile/:profileId`; record the exact ID, display name, current `deleted` value, merge state, claim state, and relevant counts. If this detail endpoint returns 404, immediately query `GET /admin/profile?includeDeleted=true&limit=1&ids=:profileId`: hidden profiles are excluded from the detail route but remain in the live catalog with a populated `deleted` object. When that tombstone exists, make no duplicate write; verify active-list exclusion and the public URL/API 404 checks from step 6, then report that the named profile is already hidden. Stop if neither read resolves the requested entity or if the resolved entity does not match the request.
2. When the requester also says to hide every track inside the profile, remove only that profile's track-credit associations before hiding the profile:
   - Read `GET /admin/profile/:profileId/credits?limit=200` across EVERY page until a short page ends it, twice, sort by track ID, and require identical counts and snapshots before writing. A page-1-only snapshot silently truncates at 200 associations and would partially delete a larger profile; freeze the complete set before the canary or any batch, and abort if the two reads disagree.
   - Record the exact track-ID set and pending batch in the audit log. Remove one association through `DELETE /admin/track/:trackId/profile/:profileId/credits?force=true`, carrying the requester and request-message approval reference, then require read-back to show that ID absent and the total reduced by one.
   - Remove the remaining snapshotted associations with the same gated endpoint and approval reference. Stop on the first error or non-200; read back instead of blindly retrying.
   - Require the authoritative profile-credit list to return `total: 0` and no items. Then run `POST /admin/profile/:profileId/collaborators/rebuild` with `{}` and require both the rebuild result and collaborator-list read-back to report zero visible collaborators.
3. Record the pending profile write in the mandatory admin audit log before execution, including requester identity, request-message timestamp, reason, endpoint, target ID and display name, and pre-state.
4. Dry-run the soft-hide through the gated Muso admin CLI, carrying the human requester and request-message timestamp. Use `muso --env prod --json --dry-run --requester <email> --confirmed-by <authorized-requester> --approval-ref <message-ts> --yes api DELETE /admin/profile/<profileId>`, then confirm the rendered request targets production and the exact profile ID. A profile-only hide preserves its track-credit associations, standalone tracks, and pending claim; change any of those only when the requester explicitly includes them.
5. Execute the identical command without `--dry-run` once. Treat an error or timeout as an unknown end state: read back before deciding whether any retry is safe.
6. Verify the final state through independent views:
   - `GET /admin/profile?includeDeleted=true&limit=1&ids=:profileId` returns exactly that profile with a populated `deleted` object.
   - The same list call without `includeDeleted=true` returns no active item for the ID.
   - The exact public profile API `GET https://api.muso.ai/api/w/v3/profile/:profileId` and canonical public URL `GET https://muso.ai/profile/:profileId` both return 404; use the `/w/v3/profile/` route rather than guessing `/api/v3/profile` or `/api/v3/profiles`.
   - If the API is 404 but the canonical URL still returns 200, inspect the response cache headers and load a cache-busted URL. A canonical `cf-cache-status: HIT` serving profile content while the cache-busted URL returns 404 proves a stale CDN object, not a failed soft-delete.
   - In that stale-CDN state, call `DELETE /admin/profile/:profileId/cache` once through the same dry-run, audit, and requester gates, then recheck the canonical URL. Treat `deletedKeys: []` plus a continued CDN HIT as unresolved: route the exact URL and cache evidence for a CDN purge, and do not report completion until the canonical URL no longer serves the profile.
7. Append the write results and final verification to the audit log. Report completion only when the requested track cleanup (when applicable), live catalog tombstone, active-list exclusion, and canonical public-page checks all agree; successful empty write responses and a cache-busted 404 are not proof that the canonical page is hidden.
