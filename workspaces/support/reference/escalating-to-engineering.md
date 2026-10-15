# Handing a data problem to the engineering lane

**Canonical protocol: `docs/AGENT_BRIDGE_PROTOCOL.md` in `Muso-AI/platform-data-processing`.**
Read it before filing anything. Skill: `agent-bridge-request`. This page is a pointer, not a
copy: where it and the protocol disagree, the protocol wins.

**Core rule: CS and Ops agents REQUEST; they never fix the data lane.** No DAG edits, no
writes to analytics stores, no cube or serving-table mutation, no pipeline re-runs, no "let me
just re-sync it". The owning lane fixes, verifies, and reports back. Your own gated admin-API
actions (claim approvals, credit verification, merges, refunds, ticketing) are unchanged and
remain yours. The line is *product operations* (yours) vs *data-layer repair* (a request).
**If you cannot tell which side an action sits on, it is a request.**

Where requests go:

- **Durable mailbox: GitHub `platform-data-processing` issue #2405.** The system of record,
  and the default for every request type. **Internal ref – never quote to a customer**
  (see "What the customer is told" below).
- **Real-time lane: Centrifugo `agent:pdp`.** LIVE as of 2026-08-26. It is a notification
  accelerator for escalations only; anything sent there must ALSO exist as a #2405 comment.
  Never publish to `ticker:*`.

Two rules that are easy to get wrong:

- **A request with no reply is OPEN, never "done".** Your own send is not evidence of a fix.
  Do not close it, do not tell a customer it is resolved, and do not re-file a duplicate:
  wait for the owning lane's reply on #2405.
- Report the **symptom, not a diagnosis**. Never tell a customer a root cause you have not had
  confirmed. "I've asked the team" is always available.

## What the customer is told

**Never name or link an internal thread, issue or repo to a customer.** Not #2405, not
`platform-data-processing`, not a GitHub link, not "it's open on our side with the team".
Nick's decision, 2026-10-08: #2405 had been quoted to customers as the place
credit-verification requests are handled, and nobody answers it, so quoting it promised
something we do not keep.

What you say instead, and nothing beyond it:

> "We're looking at it and will come back to you."

If you can name a channel that has a human on it, name that channel instead. Quote the
normal SLA once (2 business days) and never an engineering ETA.

A `scripts/intercom-ops-write.sh reply --customer-facing` body is refused outright if it
carries an issue link or number (`scripts/intercom-ops-write.sh:203`). That refusal is the
floor, not the rule: the rule above covers every channel, including the ones with no
wrapper in front of them.

Current platform state (what is stale, what is frozen, what is known-broken) lives in the
shared-reference digest `AGENT_CURRENT_TRUTH.md` (your SOUL.md has the path). Read it before
you conclude something is new. Customer-visible incidents already known to us are in
`active-incidents.md` beside this file.

_Created 2026-08-26. The bridge is interim and will be replaced when development moves to
cloud sessions._
