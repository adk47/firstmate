---
name: "bulk-credit-transfer"
description: "Transfer exact credit sets between profiles with fail-closed verification."
---

# Bulk Credit Transfer

Transfer an exact, evidence-backed set of track credits between two distinct profiles without merging them.

## Procedure

1. Resolve and name both profiles, then confirm the source and target direction from the customer evidence. When the customer identifies the same-name profiles as different artists, preserve them as separate profiles and use a targeted credit transfer rather than a merge. Stop if either identity or direction is ambiguous.
2. Normalize submitted track URLs to UUIDs and deduplicate repeated links before counting the requested set. Freeze a manifest containing each exact track UUID, title, artists, source roles, target roles, and missing target roles. Record a whole-file hash and a sorted-ID-set hash; completion requires unique IDs and zero unmatched or ambiguous evidence rows.
3. When the request also includes the causal raw source, inventory that source before any write: identify its raw ID, profile type, deletion state, all contributed tracks/roles, and current catalog attachment. Confirm the supported path can attach it to the destination. If the raw row is deleted or the admin surface only supports unlinking, file the bounded catalog/data-lane recovery request and wait for an owner-confirmed path before moving credits; do not create a destination or unlink the source into an unattached state. Also verify the create-profile endpoint preserves the requested profile type—stop if read-back normalizes it to another type.
4. Read both profiles through paginated `GET /admin/profile/:profileId/credits?limit=500&page=N`, deduplicating by track UUID. Do not use cached `creditCount` as proof.
5. Compare live state with the frozen manifest. Stop on missing source IDs, source-role drift, duplicate IDs, or an unapproved overlap. Log the intended writes before execution and anchor bulk destructive calls to the approving message. When the bulk-delete threshold pauses the batch, re-read the manifest tracks to identify exactly which deletions landed, then continue only the remaining rows with both `--confirmed-by <allowlisted-handle>` and `--approval-msg-id <message-ts>`; `--requester` and approval-author metadata do not replace the explicit bulk-gate confirmation fields.
6. Immediately before each add, re-read the source by exact track UUID and confirm its live roles still exactly match the manifest; add only missing roles with `POST /admin/track/:trackId/profile/:profileId/credits` and body `{"credits":["Role", ...]}`. The live handler requires the `credits` array; do not use a singular `role` field.
7. Re-read the target and require every frozen source role on every manifest track before deleting anything from the source. Stop unless parity is complete. Immediately before each delete, re-read the target for that track to confirm parity still holds, then re-read the source again by exact UUID and require the same exact role set; stop that row on any drift or identifier mismatch rather than substituting a title or retrying blindly.
8. Delete one source-track canary through `DELETE /admin/track/:trackId/profile/:profileId/credits` with body `{"credits":["Role", ...]}`; keep the path in track-first order. Then read both profiles and continue only when the canary is absent from the source and complete on the target.
9. Delete only the remaining manifest IDs through that same per-track endpoint and role-specific body. Reconcile the live source count periodically; stop on the first mismatch rather than replaying the batch.
10. After any write error, timeout, or HTTP success that disagrees with read-back, treat the outcome as unknown until an authoritative read. Retry only the exact row proven not to have landed.
11. If a delete is refused because the source row includes `Primary Artist`, re-read the exact track and confirm the row is still in the approved manifest and the target already carries every role that must be preserved. Call the same per-track delete once with `?force=true`, then re-read: the force call may remove only `Primary Artist` and expose a residual non-primary role rather than removing the association. If a residual role remains, copy it to the target when missing, verify it there, call the ordinary per-track delete once, and re-read after a short settle window. Never treat the force call's HTTP success as row removal.
12. Finish only after every manifest ID is absent from the source and every frozen role remains on the target. Recompute the complete live source/target track intersection before rebuilding collaborators; if a newly materialized shared row falls outside the approved manifest, preserve it and obtain an explicit manifest extension instead of silently widening the write. Rebuild collaborators for both profiles, read both collaborator lists, and update the customer only when the requested collaborator separation is verified.

## Stop conditions

- Manifest hashes or row count changed.
- Live source roles differ from the frozen source roles before deletion.
- Target parity is incomplete.
- A checkpoint count differs from expected.
- Any write outcome cannot be established by read-back.
- Final source absence or target role coverage is incomplete.
