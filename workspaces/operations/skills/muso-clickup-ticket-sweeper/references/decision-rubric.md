# Decision Rubric

Use this after reading ClickUp, Intercom, and admin readbacks.

## Close as resolved

Close only when one of these is true:

- The exact requested credit/profile/track state already reads back correctly.
- You made an exact safe write, the API returned success, and readback confirms it.
- The ticket is a duplicate or stale review item and a canonical newer ticket remains open.
- The user asked a source/origin question and you answered it from raw credits / analytics sources.
- An async repair was previously queued and a later readback confirms it materialized.

## Keep open

Keep open when any of these are true:

- Broad bulk cleanup such as "200 wrong credits" or "half my catalog is missing".
- Same-name catalog contamination without an exact wrong-track list or proven survivor/source split.
- Artist credits mirrored from Spotify/Tidal/raw source where the customer disputes the source metadata.
- Missing target profile, missing track URL, no Intercom contact, or unresolved ownership.
- Proof supports only part of the requested roles. Apply the supported part if safe, then leave open for the rest.
- A removal tool refuses with ownership/email mismatch.
- The customer asks for profile deletion, old-profile removal, or profile merge without enough identity/canonical-survivor evidence.

## Safe credit write patterns

- Exact add: customer-owned profile, exact track ID, exact role, proof or prior accepted state, then readback.
- Exact remove: customer-owned profile, exact track ID, customer disputes an ops-added manual role, then readback.
- Preserve non-disputed roles. If an endpoint deletes a profile-track credit group, restore the non-disputed roles immediately and read back.
- For user-submitted proof, add only the role the proof directly supports.

## Unsafe credit write patterns

- Do not remove all tracks from a profile because the customer says "many are wrong".
- Do not delete or remove source-backed artist credits unless the task is explicitly a profile split/merge cleanup and the survivor is proven.
- Do not pick a track survivor from title alone.
- Do not add a credit to an unverified or guessed profile just because the name matches.
- Do not treat an HTTP 200 from capture/enrich as proof the data materialized; it means queued.
- If you only queued async capture/enrich in this pass, leave the ticket open or in a waiting/recheck state with the recheck time in the ClickUp comment.

## ClickUp comment shape

Use one compact paragraph:

```text
Ops scan YYYY-MM-DD: <what was checked>. <what was done or why no write was safe>. <readback or blocker>. <resolved/left open reason>.
```

Good examples:

- `Ops scan 2026-07-14: Restored the deleted accepted Producer credit for Lester Jones on 503leander - WIDE OPEN. Admin write returned 200 and readback now shows WIDE OPEN / Producer on the Lester Jones profile. Marking resolved.`
- `Ops scan 2026-07-14: Profile Cave has 295 credits and raw sources include the provided Spotify artist plus other Cave/Cave 110 sources. This is a broad same-name contamination request, not safe for automated removal without an exact wrong-track list and source split plan. Left open for catalog bulk review.`

## Customer notification rubric

Notify only after the operational state is complete:

- Resolved + readback confirmed: draft a short personalized resolution note and send through Caroline only when notification was requested and the approved send path is available.
- Partial fix: draft a non-final update that names the fixed part and the remaining blocker; do not mark the ticket resolved.
- Async queued only: do not tell the customer it is resolved. Say it is being rechecked if a customer update is requested.
- Left open / needs proof / broad cleanup: no resolved notification. If needed, draft a request for exact tracks, profile URL, role, proof, or source evidence.

Customer message shape:

```text
Hi <name> - we checked <specific request>. <Specific fix/readback result>. <What they should see now or honest remaining limitation>. Thanks for your patience.
```

Avoid generic "your ticket has been resolved" messages without the actual fix. Never mention internal tools, ClickUp, admin endpoints, subagents, or audit logs to the customer.
