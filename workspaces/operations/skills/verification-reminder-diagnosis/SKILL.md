---
name: "verification-reminder-diagnosis"
description: "Resolve verification emails when Needed Verification is empty."
---

# Verification Reminder Diagnosis

Use this procedure when a customer receives “Verification Needed” / “Additional Information Required” emails but their Needed Verification screen is empty.

1. Inspect the customer’s screenshot or email and record the quoted credit count, profile name, and deadline; finish when the notice is identified without inferring a track.
2. Resolve the customer’s verified Muso profile from the verified contact identity; finish when the profile UUID and display name are known.
3. Query `GET /admin/credit-requests` with `profilesIds=<profile_uuid>` (plural, not `profileId`) and run separate reads for `status=user_verification_needed`, `status=unverified`, and `status=processing`; finish when all three live sets are counted. Treat `profileId=` on this list endpoint as invalid because it may be ignored and return unrelated global rows.
4. If the actionable sets are empty and a processing request remains, inspect that row’s track, role, timestamps, and `metadata.infoNeededCancellationKeys`; finish when the reminder can be tied to one request or the mismatch is documented as unresolved.
5. Read `GET /admin/profile/:profileId/credits` for the named track and, when needed, the track detail/raw credits; finish when you know whether the requested credit is already materialized.
6. Do not change request status merely to stop reminders when the row is processing or the credit is already materialized. File a data-verification request describing the symptom and counts, then finish when the durable request link is returned.
7. Tell the customer they do not need to upload proof only when both actionable sets are empty and the credit is already visible; say the repeated reminder is under review, not fixed. Finish when the customer reply matches the verified state.
8. Add an internal note containing the profile, request, track, live status counts, reminder-key count, whether the credit is visible, and the durable request link; finish when Intercom read-back confirms both note and customer reply.
