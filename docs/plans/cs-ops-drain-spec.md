# Ops-drain design spec (Phase 2.1 of the autonomous-CS plan)

**Status:** DESIGN SPEC, not shipped. No prod changes. Sign-off required before any `--apply`.
**Parent:** `docs/plans/autonomous-cs-machine.md`. **Owner:** implementer, once approved.

## Problem
The five live sweepers only close conversations that are ALREADY resolved (ticket flipped, merge
landed, fix shipped). They do not RESOLVE anything. Caroline resolves, but only reactively, when a
customer messages in. That leaves a gap: **open conversations where the customer asked for something,
went silent, and the resolution is now mechanically available and server-verifiable, but nobody has
executed it.** These sit open until the customer pings again or a human works them. The ops-drain
closes that gap by resolving that specific bucket autonomously on the main / operations gateway,
then letting the existing `resolve-notify` -> `close-resolved` chain notify + bury them.

## The target bucket: "resolvable-now, no customer input needed"
An open Intercom conversation qualifies ONLY if ALL hold:
1. It is OPEN and NOT already owned by any sibling sweeper's state (see De-confliction).
2. The customer's request maps to a resolution that muso-cli can execute where the SERVER fully
   re-verifies eligibility and NO customer confirmation/attestation is required. Initial allowed set:
   - **Catalog-corroborated pending credit** -> `muso credits verify` (server re-verifies ownership
     AND catalog match; the ONLY autonomously-approvable credit case per
     `workspaces/support/skills/customer-credit-verification/SKILL.md:144-155`).
   - **Customer's own now-processable profile claim** -> `muso profiles claim-self` (identity
     corroborated, server re-verifies).
   - **Same / normalized-name own-duplicate consolidation** -> `muso profiles consolidate`, ONLY the
     no-attestation path (survivor is customer's own claimed profile; every dup unclaimed or
     same-customer-claimed; same/near name). Name-MISMATCH dups require customer attestation ->
     EXCLUDED (stays a ticket).
3. Identity is corroboration-able: the resolution's `--actor-identity` is the Intercom conversation's
   verified contact email (server-derived, exactly as Caroline's gated writes work). If the contact
   email is absent or unverifiable -> EXCLUDED.

Everything else stays out of scope: refunds (Phase 4, parked), cross-owner merge, unmerge, credit
REJECTION, anything needing customer confirmation, anything needing human judgment. When in doubt,
EXCLUDE and let it fall to the needs-human digest.

## De-confliction (THE load-bearing invariant)
The ops-drain MUST NOT touch a conversation another component owns, or we double-act / double-message
a customer. **De-conflict by CONVERSATION ID, never by contact email.** Every sibling source below
records the conversation id, so id-matching is sufficient; email-matching against these append-only,
never-pruned logs would permanently exclude a RETURNING customer's brand-new, unrelated conversation
(their email lingers in `close-resolved-shadow.jsonl` forever after any single past close, which
would silently hide their next real issue). Contact email is used ONLY for dup-candidate detection
among currently-open conversations (a live, self-bounded signal), never as a historical-ownership
key. Before acting on any conversation, exclude it if its id appears in:
- `/var/log/close-resolved-shadow.jsonl` (already closed)
- `/var/lib/resolve-notify/notified.json` (already notified)
- `/var/lib/resolution-matcher/` state + `resolution-matcher-shadow.jsonl` (fix-reconcile owns it)
- `/var/lib/overdue-verification-notifier/notified.json`
- the merge-landing / dedup close path (`close-merged-tickets` + dedup-shadow)
- the ops-drain's OWN shadow log + state (idempotency: never act twice on one conversation)

Write the ops-drain's own state to `/var/lib/cs-ops-drain/` (acted.json) and shadow-log every action
to `/var/log/cs-ops-drain-shadow.jsonl` (epoch-seconds `acted_at`, matching close-resolved format).

## Mechanism (per the extension decision tree)
Selection needs light classification (which open convo is resolvable-now); the ACTION must be
deterministic + gated. So: an **openclaw cron** (`cron-jobs.json`, `sessionTarget` operations, model
on the allowlist or it silently fails, isolated turn - the proven `credit-verification-batch-4h`
shape) that invokes a **new canonical skill** `skills-all/cs-ops-drain/SKILL.md`. The skill:
1. Pulls open Intercom conversations (bounded window + `--limit`).
2. Filters to the target bucket + runs the de-confliction exclusion.
3. For each survivor, RE-VERIFIES resolvability with muso-cli READ tools (deterministic), then
   executes the single muso-cli WRITE with `--requester <ops-bot> --actor-identity <customer-email>`
   and, for approval-tier verbs, `--confirmed-by`/`--approval-ref` per the muso-cli contract.
4. Relies on the existing `resolve-notify` -> `close-resolved` chain for customer notification +
   close. The ops-drain itself does NOT message the customer and does NOT close the conversation
   (keeps notify/close authority in the deterministic sweepers; keeps the "customer still waiting is
   never closed" invariant intact).

Do NOT give Caroline (edge) any of this. Do NOT dispatch Caroline per-conversation (edge lane-wedge
risk; mitigations #616/#668 stay load-bearing). The ops-drain lives entirely on main / operations.

## Gates and safety (non-negotiable)
- **Dry-run default**, `--apply` to write, `--limit N` ramp (start 5). Host guard (node-8 only).
- **Codex-health pre-write gate** (`scripts/lib/codex-health-gate.sh`): if the model is degraded onto
  a weak fallback, refuse ALL writes (money/admin-write doctrine). Fail CLOSED.
- **Per-run + per-customer/day caps** (reuse muso-cli's existing caps; add a conservative per-run
  ceiling, e.g. <=25 writes/run at first).
- **Audit log** (muso-cli's fail-closed `audit.jsonl`) + the ops-drain shadow log. Every action
  reversible/traceable.
- **Async-mutation verification:** for consolidate, a 200 is enqueue-only. Do NOT re-fetch admin API
  to confirm (it lags). Either verify via Trino `matvw_catalog_profile`, or (simpler) do not treat
  the write as "resolved" in-run; let `close-merged-tickets` / merge-landing-watchdog confirm the
  landing and close downstream. Record only "enqueued" in the shadow log.
- **Idempotency:** never act on a conversation already in the ops-drain state.

## Rollout
1. Ship dry-run only. Run for >=1 week; Jan/Nick review `cs-ops-drain-shadow.jsonl` candidates.
2. `--apply --limit 5`, watch reopen-rate (the honesty check) and any customer confusion in #cs_chats.
3. Ramp `--limit` as reopen-rate stays ~0.
**Sign-off before `--apply`: Nick (+ Aaron if the customer-visible effect via resolve-notify wording
changes).**

## Metrics
- ops-drain writes/run and /week, by verb.
- Net new AI-resolved conversations attributable to ops-drain (dedup against sibling closes).
- **Reopen-rate** on ops-drain-touched conversations (must stay ~0; a spike means we acted on things
  the customer did not actually want resolved).

## Open questions (resolve before implementation)
1. Does muso-cli expose a clean "pending credit is catalog-corroborated for actor X" READ that the
   skill can gate on without guessing? (Confirm against `skills-all/muso-cli/SKILL.md` verbs.)
2. Intercom API access on the MAIN gateway: which token, and can we list open conversations with
   contact email server-side (the same identity path Caroline uses)? Confirm before building.
3. Is acting-on-behalf-without-a-fresh-customer-confirmation acceptable for the claim/verify cases,
   given the customer explicitly asked earlier in the thread? (Recommended: yes for server-fully-
   verified cases; the customer asked and the server re-verifies. Aaron to confirm the principle.)
4. Should ops-drain post its per-run summary to #cs_chats or #credit-verification? (Match the
   credit-verification-batch precedent: self-post to a low-noise ops channel.)
