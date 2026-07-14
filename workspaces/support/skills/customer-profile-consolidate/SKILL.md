---
name: customer-profile-consolidate
description: Merge a customer's OWN duplicate profiles into the profile they own – the SAFE self-service merge case, gated by the muso capability gate. The gate corroborates identity server-side (same or near-same name, the customer's own verified/pending claim, empty dup, or shared tracks) and refuses anything weaker. Use after dedupe_check confirms the customer owns the survivor; ALWAYS attempt the consolidate before ticketing a merge. Anything cross-owner stays human.
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
email (any name). It refuses any cross-owner merge – so the worst case is
consolidating the customer's own dupes. The decision is the GATE's, not yours:
you never judge name similarity yourself, you attempt the consolidate and let
the server decide.

## Tools

- `dedupe_check` – read-only. Run this FIRST to get the verdict (owns_survivor,
  per-duplicate claim_state, shared-id signal). It is the gate on whether to merge.
- `profiles_consolidate` – gated WRITE (approval-tier). Folds the `dupIds` into
  `survivorId`. Anchored to the verified Intercom contact (never typed input);
  re-verifies ownership + the identity corroboration server-side. Preview then
  apply.
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
   - `ok:false, error:"route_to_human"` → the gate wouldn't confirm it's all theirs;
     do NOT argue – file a `create_ticket`.
   - `ok:false, error:"no_approver"` / other `ok:false` / `disabled:true` → file a
     `create_ticket` and tell them the team will handle it.

## Autonomous vs. human

- **Autonomous (this skill):** merge the customer's OWN dupes into the profile
  they own (dedupe_check-confirmed, identity corroborated by the gate – same or
  near-same name, own claim, empty dup, or shared tracks).
- **Human (ticket):** a duplicate claimed by a DIFFERENT owner (a same-customer
  claim is fine and merges autonomously), cross-owner or disputed merges,
  band/manager (multi-claimed) profiles, unmerge/revert, arbitrary-direction merges
  (`muso profiles merge` stays human), or anything the gate routes to a human.

## Customer-facing wording

Plain language only; never expose internals or the sanitizer-banned words ("tool",
"system", "error", "ticket", etc.). "I've merged your duplicate profiles into your
main one" – not the mechanism. "I'll flag this for our team" – not a queue name.

## Operational notes

- A profile merge is hard to reverse, so the gate is strict and the dedupe_check
  precondition is mandatory. Ownership + per-actor/day merge cap + per-call dups
  bound + audit are enforced server-side by muso-cli.
- `--intercom-conv-id` is required (it is the approval reference for the
  approval-tier write).
- Audit log: `/var/log/openclaw/customer-profile-consolidate.jsonl`.
- Dark-shipped (off by default); returns a disabled no-op until enabled, so falling
  back to a ticket is always safe.
