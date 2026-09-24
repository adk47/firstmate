---
name: "customer-data-resolution"
description: "Resolve data-backed support cases and update customers without claiming an unverified fix."
---

# Customer data resolution

## Safety rules (non-negotiable)

These bind every case, including every playbook under `references/`, and win over any playbook text. Keep them in this file; put new case learning in the matching `references/` file.

- Disputed merge: inspect the deleted-inclusive list; require loser `mergedToId` = survivor plus deletion. Preserve distinct external album-artist/raw identities and route distributor remap.
- Profile merge: separate entity types and labels. Require a processed-claim survivor and complete claim list proving every loser is in its workspace. Revert all loser claims; verify `reverted`, losers unclaimed, survivor claimed. Dry-run and submit loser → survivor, then poll status to `verified`; require forward direction, absorbed identity, credit floor, and loser lookup resolving to survivor. Explicitly map multiple losers; never infer by name/count. Exclude unrelated/group profiles. If status is missing, do not retry—prove `mergedToId`, loser deletion, survivor activity, and absorbed raw identities from the live deleted-inclusive list. When one case contains both a true duplicate and a same-name different artist, merge only the customer-confirmed duplicate and remove only the exact misassigned rows while preserving legitimate releases.
- Album-role dispute: compare roles and `addedBy`; use an exact profile+track+role manifest, never whole-profile removal. After a lost response, recover the audit correlation and read every track before retry or customer contact; require disputed roles absent and protected provenance unchanged.
- “0 claimed” or absent from app/Add Credits: compare claim, workspace links, roster seats, same-name candidates, and tracks; never infer duplicates. A processed claim missing workspace/roster linkage is a mismatch. If unresolved, file one profile `data_verification`; advise no reclaim/merge before verdict.
- Missing accepted-credit metadata: route track, field, and non-pending source once; never resubmit/capture; require field read-back.
- Artwork dispute: compare public Muso/Spotify images and primary/merged Spotify IDs. For a pending source or empty artwork/release fields, record source ID/link, pending state, observed time, and empty fields; route one track-pinned verification immediately. Never remove/re-add, capture, or treat capture acceptance as proof. Resolve only after public image, backend attachment, and filtered-page read-back.
- Login reset loop: treat a stated email as a lookup clue only. Resolve IDs, confirmation/claim state, and credit count through the supported read-only owner; zero credits is not proof of loss. Follow-through: `references/intake-cases.md`.

## Procedure

Playbooks live in `/opt/hydra/workspaces/operations/skills/customer-data-resolution/references/`. Read the named file there before acting on a matching case.

1. Re-read the authoritative customer conversation and resolve the current profile, playlist, track, or other entity by both ID and display name; finish when the reported symptom and latest customer expectation are explicit.
2. Record live UTC state and a measurable pass condition. If Intercom IDs differ, use the owned populated profile; never infer a merge. Then follow the matching case in `references/intake-cases.md`.
3. For credit cleanup, resolve each profile by ID, name, claim, workspace, and entity type; enumerate profile-role-track tuples and raw identities. Keep removal, raw unlinking, merge, and deletion separate. Before any credit removal, raw unlink, merge, or delete, read `references/credit-cleanup.md` and follow its matching case.
4. Route the existing request ID, entity ID/name, delta, and pass condition; “underway” is not a fix. If customer screenshots contradict a prior “fixed” update and the request has no verdict, OCR and corroborate them, append one follow-up under the same request ID, avoid repeating verified mutations, correct the internal note, apologize, and keep the case open. Send peer work once with completion watching; after one follow-up, await the event and re-read once. Treat failed reads as unknown and finish with live proof or explicit open owner/status.
5. If no gated remediation exists, create or ID-update one ticket with entity IDs, evidence, outcome, read-back condition, and SLA. Require the returned ID to match the known ID; otherwise report a duplicate end-state mismatch.
6. Send customer updates only when explicitly requested. Re-read authenticated plaintext and answer the latest unmet question with confirmed facts; use the standard two-business-day update window, not an engineering date. For unclaimed cleanup, preserve the profile, direct the customer to claim it, request exact credits, and treat whole-profile deletion separately after ownership verification. Send through the approved wrapper and require a part ID; after interruption, match the exact outbound body before resending, because an unmatched audit row is unknown. For a legal/stage-name consolidation or a mobile freeze, follow `references/customer-updates.md`.
7. Re-read the live customer-visible surface after the workflow. For an internal summary-and-resolution request, post an Intercom internal note addressed to the requester—not a customer reply—with the symptom, measured state, action taken, proof, and open/closed disposition. When the fix is verified and the customer’s latest message is only thanks or confirmation, state that no further customer reply or catalog action is needed and recommend closing the conversation; do not broaden the resolution into a merge or reopen older requests without separate evidence. Close only when the pass condition is met; otherwise report the exact mismatch (for example, 0/1 corrected), keep the case open, and escalate the unresolved end state with the ticket and conversation evidence.

## Verification

A completed resolution includes either live proof that the requested state landed or an explicit open status with a concrete owner, ticket ID, SLA, customer-reply ID, and failed read-back count. A successful API response or created ticket alone is never proof that customer-visible data changed.
