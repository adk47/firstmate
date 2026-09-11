---
name: "bulk-credit-transfer"
description: "Transfer exact credit sets between profiles with fail-closed verification."
---

# Bulk Credit Transfer

Transfer an exact, evidence-backed set of track credits between two distinct profiles without merging them.

## Procedure

1. Resolve and name both profiles, then confirm the source and target direction from the customer evidence. Stop if either identity or direction is ambiguous.
2. Freeze a manifest containing each exact track UUID, title, artists, source roles, target roles, and missing target roles. Record a whole-file hash and a sorted-ID-set hash; completion requires unique IDs and zero unmatched or ambiguous evidence rows.
3. Read both profiles through paginated `GET /admin/profile/:profileId/credits?limit=500&page=N`, deduplicating by track UUID. Do not use cached `creditCount` as proof.
4. Compare live state with the frozen manifest. Stop on missing source IDs, source-role drift, duplicate IDs, or an unapproved overlap. Log the intended writes before execution and anchor bulk destructive calls to the approving message.
5. Add only missing roles with `POST /admin/track/:trackId/profile/:profileId/credits` and body `{"credits":["Role", ...]}`. The live handler requires the `credits` array; do not use a singular `role` field.
6. Re-read the target and require every frozen source role on every manifest track before deleting anything from the source. Stop unless parity is complete.
7. Delete one source-track canary, then read both profiles. Continue only when the canary is absent from the source and complete on the target.
8. Delete only the remaining manifest IDs. Reconcile the live source count periodically; stop on the first mismatch rather than replaying the batch.
9. After any write error, timeout, or HTTP success that disagrees with read-back, treat the outcome as unknown until an authoritative read. Retry only the exact row proven not to have landed.
10. If a delete exposes a residual source role, copy that live residual role to the target, verify it there, retry only that track, and re-read after a short settle window.
11. Finish only after every manifest ID is absent from the source and every frozen role remains on the target. Rebuild collaborators for both profiles, read both collaborator lists, then update the customer with the verified result.

## Stop conditions

- Manifest hashes or row count changed.
- Live source roles differ from the frozen source roles before deletion.
- Target parity is incomplete.
- A checkpoint count differs from expected.
- Any write outcome cannot be established by read-back.
- Final source absence or target role coverage is incomplete.
