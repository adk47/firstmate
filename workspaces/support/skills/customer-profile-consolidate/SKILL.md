---
name: customer-profile-consolidate
description: Merge a customer's OWN duplicate profiles into the profile they own – the SAFE self-service merge case, gated by the muso capability gate. The gate corroborates identity server-side (same or near-same name, the customer's own verified/pending claim, empty dup, or shared tracks) and refuses anything weaker; for an unclaimed name-mismatched duplicate, the customer's own confirmation can authorise the merge. Use after dedupe_check confirms the customer owns the survivor; ALWAYS attempt the consolidate before ticketing a merge. Anything cross-owner stays human.
triggers:
  - "merge my profiles"
  - "i have duplicate profiles"
  - "i have two profiles"
  - "combine my profiles"
  - "consolidate my profile"
  - "duplicate profile"
---

# Customer Profile Consolidate (self-service)

## Purpose

When a customer has duplicate profiles – their real (claimed) profile plus
duplicates that fragment their credits – you can fold the duplicates into the
profile they own. This is the SAME safe sub-case `dedupe_check` already
verifies; `profiles_consolidate` is its WRITE counterpart. The muso capability
gate re-verifies, server-side, that the survivor is the customer's and that
every duplicate is unclaimed (or the customer's own) AND identity-corroborated:
the same name (exact or a normalized variant – accents, spacing, punctuation),
a near-name (one name contains the other, e.g. "Pincky DJ" vs "Pincky") backed
by an independent signal (empty duplicate, shared tracks, or the customer's own
pending claim on it), or a duplicate verified-claimed by the customer's own
email (any name). For an UNCLAIMED duplicate whose name matches none of these
(a stage name vs a legal name, a transliteration), the customer's own explicit
confirmation that it is them can authorise the merge – you ask, they say yes in
their own words, and the gate re-verifies that confirmation server-side before
merging a small, unclaimed, reversible fold. It refuses any cross-owner merge –
so the worst case is consolidating the customer's own dupes. The decision is the
GATE's, not yours: you never judge name similarity yourself, you attempt the
consolidate and let the server decide.

## Tools

- `dedupe_check` – read-only. Run this FIRST to get the verdict (owns_survivor,
  per-duplicate claim_state, shared-id signal). It is the gate on whether to merge.
- `profiles_consolidate` – gated WRITE (approval-tier). Folds the `dupIds` into
  `survivorId`. Anchored to the verified Intercom contact (never typed input);
  re-verifies ownership + the identity corroboration server-side. Preview then
  apply. `customerConfirmedSameArtist` (default false): set true ONLY after you
  have explicitly asked the customer whether an unclaimed, name-mismatched
  duplicate is them and received an unambiguous YES in their own reply – it lets
  their confirmation authorise a merge the name alone couldn't. You do not pick
  which message; their confirmation is resolved and re-verified server-side.
- `create_ticket` – fall back for anything not cleanly self-serviceable.

## Flow

1. **Bail out** if the customer wants a human, is frustrated, or it's looping.
2. **dedupe_check first.** Only proceed if it returns `owns_survivor: true` and
   every requested duplicate is `unclaimed` (or claimed by this same customer).
   A duplicate claimed by a DIFFERENT owner, or `owner_undetermined` → do NOT
   merge; file a profile-merge `create_ticket` for Operations. A name mismatch
   is NOT a reason to skip the attempt: the gate accepts corroborated
   near-names and same-owner claims, and refuses (route_to_human) anything it
   cannot corroborate – attempting first is what routes correctly.
3. **Preview** – `profiles_consolidate` with `apply:false`, the verified survivor as
   `survivorId` and the confirmed duplicates as `dupIds`. Show the customer exactly
   which profiles fold into which, and confirm.
4. **Apply** – `profiles_consolidate` with `apply:true`.
5. **Report**:
   - `status:"applied"` → tell them the duplicates were merged into their profile
     and credits will consolidate.
   - `ok:false, error:"route_to_human"` → the gate wouldn't confirm it's all theirs.
     If the block is a NAME MISMATCH on an UNCLAIMED duplicate (dedupe_check showed
     it `unclaimed`, and the names differ – a stage vs legal name, a translation,
     an alias), go to step 6 BEFORE ticketing. Otherwise do NOT argue – file a
     `create_ticket`.
   - `ok:false, error:"no_approver"` / other `ok:false` / `disabled:true` → file a
     `create_ticket` and tell them the team will handle it.
6. **Ask-then-attest (name-mismatch, unclaimed only)** – name the two profiles to the
   customer in plain language and ask ONE clear question: are these both them / the
   same artist? (You may mention one or two track titles from the duplicate to help
   them recognise it.) Only if they reply with an **unambiguous yes in their own words**
   – never on silence, a thank-you, or your own inference – retry `profiles_consolidate`
   with `customerConfirmedSameArtist:true`:
   - **Preview** (`apply:false`): the response echoes `attested: {part_id, snippet}` –
     the exact customer message the merge will rely on. **Verify the snippet IS their
     confirmation.** If it's some other message (they sent something after the yes),
     do NOT proceed on it; re-ask or ticket.
   - **Apply** (`apply:true`): pass that same `part_id` back as `attestedMsgId` – it
     pins the confirmation, so a message arriving in between can never be attested by
     accident. Never invent an `attestedMsgId`; only echo the previewed one.
   If it still returns `route_to_human`, file a `create_ticket` noting the customer
   confirmed. Do this at most once; do not badger for a yes.

## Autonomous vs. human

- **Autonomous (this skill):** merge the customer's OWN dupes into the profile
  they own (dedupe_check-confirmed, identity corroborated by the gate – same or
  near-same name, own claim, empty dup, or shared tracks), plus an UNCLAIMED
  name-mismatched dup once the customer has confirmed it is them
  (`customerConfirmedSameArtist`).
- **Human (ticket):** a duplicate claimed by a DIFFERENT owner (a same-customer
  claim is fine and merges autonomously), cross-owner or disputed merges,
  band/manager (multi-claimed) profiles, unmerge/revert, arbitrary-direction merges
  (`muso profiles merge` stays human), or anything the gate routes to a human
  (including a name-mismatched dup the customer will NOT confirm, or one the gate
  still refuses after confirmation – e.g. a same-name sibling makes it ambiguous).

## Customer-facing wording

Plain language only; never expose internals or the sanitizer-banned words ("tool",
"system", "error", "ticket", etc.). "I've merged your duplicate profiles into your
main one" – not the mechanism. "I'll flag this for our team" – not a queue name.

## Operational notes

- A profile merge is reversible by Operations (`muso profiles unmerge` restores an
  unclaimed fold), but it is still a real write, so the gate stays strict and the
  dedupe_check precondition is mandatory. Ownership + per-actor/day merge cap +
  per-call dups bound + audit are enforced server-side by muso-cli.
- The `customerConfirmedSameArtist` attestation path applies to UNCLAIMED,
  name-mismatched duplicates only; the gate additionally bounds it to a small
  duplicate catalogue and re-verifies the customer's confirmation message
  (author, recency) server-side. A claimed duplicate never rides this path.
- `--intercom-conv-id` is required (it is the approval reference for the
  approval-tier write, and the conversation the attestation is read from).
- Audit log: `/var/log/openclaw/customer-profile-consolidate.jsonl`.
- Dark-shipped (off by default); returns a disabled no-op until enabled, so falling
  back to a ticket is always safe.
