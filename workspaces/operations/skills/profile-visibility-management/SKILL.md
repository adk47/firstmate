---
name: "profile-visibility-management"
description: "Hide profiles through the soft-delete endpoint with dual read-back verification."
---

# Profile Visibility Management

Use this procedure when an authorized operations requester says to hide, remove from public view, or soft-delete a Muso profile.

1. Resolve the supplied profile ID with `GET /admin/profile/:profileId`; record the exact ID, display name, current `deleted` value, merge state, claim state, and relevant counts. Stop if the resolved entity does not match the request.
2. Record the pending write in the mandatory admin audit log before execution, including requester identity, request-message timestamp, reason, endpoint, target ID and display name, and pre-state.
3. Dry-run `DELETE /admin/profile/:profileId` through the gated Muso admin CLI, carrying the human requester and the request-message timestamp as the approval reference. Confirm the dry-run targets production and the exact profile ID.
4. Execute the same DELETE once. Treat an error or timeout as an unknown end state: read back before deciding whether any retry is safe.
5. Verify through both authoritative views:
   - `GET /admin/profile?includeDeleted=true&limit=1&ids=:profileId` returns exactly that profile with a populated `deleted` object.
   - `GET /admin/profile/:profileId` returns `not_found`, proving the profile is absent from the active view.
6. Append the write result and final verification to the audit log. Report completion only when both read-back signals agree; the DELETE endpoint's successful empty response is not proof by itself.
