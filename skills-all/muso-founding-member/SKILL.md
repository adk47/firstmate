---
name: muso-founding-member
description: |
  Founding-member program operations: read a workspace's founder status,
  calculate + generate the PAID buy-back subscription (one Stripe Checkout
  link bundling a Pro-annual resubscribe + arrears back to the 2026-06-30
  anchor), and — with second-human approval — comp-reinstate a lapsed founder
  for free. Wraps the typed `muso founding` verbs (core-backend
  /admin/founding/*, shipped b83bcf04b).

  Use when: a customer wants to rejoin / buy back founding-member status, a
  lapsed founder disputes their lapse, ops needs the buy-back amount or a
  payment link, or a goodwill (free) reinstate has been approved.

  Triggers: "founding member", "founder status", "buy back", "buyback",
  "reinstate founder", "founding lapsed", "founder badge"
compatibility: |
  Main gateway on node-8 only (NOT edge/Caroline — she has her own
  founding_status / founding_buyback_link plugin tools, anchored to the
  verified Intercom email). Binary at /usr/local/bin/muso with the same env
  as the muso-cli skill (MUSO_ENV=prod, auto-login, audit state).
  Tiers: buyback-checkout = write (needs --requester); reinstate = APPROVAL
  (needs --requester, --yes, --confirmed-by + --approval-ref — a second
  human, refund-override class); grant/revoke = dangerous, not part of this
  playbook.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
  verified-against: "core-backend b83bcf04b (src/apis/_admin/founding/)"
allowed-tools:
  - exec
---

# Muso Founding Member — status, paid buy-back, comp reinstate

The founding-member program recognizes paid-plan backers (open enrollment
closed 2026-06-30). Status is tied to CONTINUOUS paid coverage: a lapse
(failed payment past the 7-day grace, voluntary cancel past period end,
downgrade to Lite) latches the workspace as a lapsed founder. Two ways back:

1. **Paid buy-back** (the normal case) — the customer pays the arrears since
   the anchor and resubscribes on Pro-annual, in ONE Stripe Checkout link.
2. **Comp reinstate** (goodwill exception) — free restore, approval tier.

All verbs take `--team <workspace-id>` or `--email <workspace-email>` (the
email resolves exactly, case-insensitive; ambiguity refuses — disambiguate
with `--team`). The id is the WORKSPACE id, never a user id.

## 1. Read status first

```
muso founding status --email <customer-email> --json
```

Answers `{teamId, name, email, founder, subscription}` where `founder` is
`{active, sinceYear, lapsedAt}` — `null` = never in the program, `active:
false` + `lapsedAt` = lapsed founder (buy-back / reinstate candidate).
`sinceYear` drives the "Founder since 'YY" badge and is preserved across
lapse and reinstate.

## 2. Paid buy-back — calculate + generate the subscription link

```
muso founding buyback-checkout --email <customer-email> --requester <your-email> --json
```

Answers the CALCULATION and the LINK in one call:

```json
{
  "teamId": "…", "url": "https://checkout.stripe.com/…", "sessionId": "cs_…",
  "arrearsMonths": 3, "arrearsCents": 2997, "sinceYear": 2026, "seats": 1,
  "note": "…"
}
```

- The link bundles a REAL Pro-annual subscription + a one-off arrears charge
  (coverage owed back to the 2026-06-30 anchor). Talking points:
  `arrearsMonths` x the monthly rate = `arrearsCents`; going forward they are
  on a live subscription, so it will not lapse silently again.
- The link lives **~24h**. Send it to the customer (via Caroline / Intercom
  reply, or email in Aaron's voice if he sends it); if it expires, mint a new
  one — minting is idempotent-safe, nothing changes until payment.
- On payment, founding status reinstates (or late-buys-in for a
  never-founder) **automatically** via the Stripe webhook
  (`founding_buyback_sub`). No further action.
- Quote ONLY the returned figures; never estimate an amount.
- 400 errors: "already an active founder" = they are not lapsed, nothing to
  do; "not found" / "no owner" = bad workspace id, re-check the resolution.

## 3. Comp reinstate — free, approval tier

Only when the team has decided to give status back for free (billing mistake
on our side, goodwill). Treated like a refund override: second human signs
off.

```
muso founding reinstate --team <workspace-id> \
  --reason "<why — REQUIRED, lands in the founding audit log>" \
  --requester <your-email> --yes --confirmed-by <approver> --approval-ref <slack-ts>
```

- Only valid for a LAPSED workspace (else 400 "Team is not in a lapsed
  state"). Clears the latch immediately, no payment, `sinceYear` preserved.
- A never-lapsed "reinstate" request means the customer's premise is wrong —
  check `founding status` and explain instead.

## Boundaries

- **Never quote a credit amount** for the monthly AI-credit perk (the number
  is intentionally unpublished — see Caroline's founding-member KB).
- **Grant/revoke** (`/admin/founding/grant|revoke`) are cohort-management
  endpoints outside this playbook (no typed `muso founding` verb; raw
  `muso api` only): dangerous tier, escalate to Aaron.
- Caroline's customer-facing rules live in
  `workspaces/support/reference/founding-member.md`; this skill is the ops
  side of the same doctrine.
