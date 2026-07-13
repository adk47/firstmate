---
name: customer-profile-claim
description: Verify (approve) a customer's OWN pending profile claim so they become the verified owner – gated self-service via the muso capability gate. Use when a verified customer asks to claim/verify their profile and a pending claim exists on it.
triggers:
  - "claim my profile"
  - "verify my profile"
  - "claim my artist profile"
  - "my profile claim is pending"
  - "how do i claim my profile"
  - "i want to claim my profile"
---

# Customer Profile Claim (self-service)

## Purpose

When a customer asks to claim/verify a profile that is theirs and a **pending
claim** already exists on it, you can approve that claim yourself instead of
handing off. Ownership is anchored to the verified contact and re-checked
server-side, so the worst case is verifying the customer's OWN claim – which is
exactly what they asked for. Verifying a claim is idempotent (re-running an
already-verified claim does nothing).

## Tools

- `profiles_claim_self` – gated WRITE. Approves the customer's own pending claim
  by `claimId`. The verified contact email is the anchor (derived from the
  conversation, never from what the customer types); the gate refuses a claim
  that belongs to a different account. Always preview first (`apply:false`), tell
  the customer what will happen, then `apply:true`.
- `profile_claim_status` – read-only claim diagnosis. Run it FIRST: it resolves
  the profile, returns the customer's own claim(s) with the `claim_id`, flags
  competing claims and suspicion signals, and tells you whether self-serve is
  appropriate (`support_action: route_selfserve_claim`) or a human packet is
  (`create_handoff_ticket`). It fails closed when identity can't be verified.
- Other reads (`profile_status`, `credit_verification_check`, `dedupe_check`)
  for surrounding profile context.
- `create_ticket` – fall back to this for anything you cannot resolve here.

## Flow

1. **Bail out** if the customer is asking for a human, is frustrated, or this is
   going in circles – hand off with `create_ticket`.
2. **Identify the pending claim.** Call `profile_claim_status` with the profile
   URL/id: take the `claim_id` from `own_claims` when it returns
   `route_selfserve_claim`. If it returns anything else (conflict, suspicion
   flags, rejected/reverted/multiple, fail-closed), do not guess and do not
   proceed here – follow its `support_action` (answer from status, or file the
   `profile-claim` packet it suggests).
3. **Preview** – call `profiles_claim_self` with `apply:false`. Tell the customer
   plainly what you're about to verify (e.g. "I can confirm your profile claim
   now"). Get a clear yes.
4. **Apply** – call `profiles_claim_self` with `apply:true`.
5. **Report back** from the result:
   - `status:"applied"` → tell them it's done and they're now the verified owner.
   - `status:"noop"` → it was already verified; reassure them it's set.
   - `ok:false, error:"route_to_human"` → the claim isn't confirmable as theirs;
     do NOT argue ownership – file a `create_ticket` for the team to check.
   - `ok:false, disabled:true` → self-service isn't on for this case; file a
     `create_ticket` as usual.
   - any other `ok:false` → file a `create_ticket` and tell them the team will
     take it from here.

## Autonomous vs. human

- **Autonomous (this skill):** verify the customer's OWN pending claim.
- **Human (file a ticket):** rejecting/reverting a claim, claims that don't
  resolve to the verified contact, cross-account or disputed ownership, anything
  the gate routes to a human.

## Customer-facing wording

Speak plainly and never expose internals. Don't use the words the outbound
sanitizer redacts (e.g. "tool", "system", "error", "ticket"). Say "I'll flag this
for our team" rather than naming a queue, and "I've confirmed your profile" rather
than describing the mechanism.

## Operational notes

- Ownership + per-actor caps + audit are enforced server-side by the muso
  capability gate (`muso profiles claim-self --actor-identity <verified-email>`);
  the wrapper is a thin boundary that adds an audit line and a dry-run preview.
- Audit log: `/var/log/openclaw/customer-profile-claim.jsonl`.
- The verb is dark-shipped (off by default); it returns a disabled no-op until
  enabled per the rollout, so falling back to a ticket is always safe.
