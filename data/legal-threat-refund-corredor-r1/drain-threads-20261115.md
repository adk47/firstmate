# Two drained Intercom threads handed to this lane — decisions, 2026-11-15

Inbox `legal-threat-refund-corredor-r1/016` (2026-11-15T11:47:45Z) handed two open Caroline threads here from
`data/caroline-unanswered-drain-u1/handoff-20261115.md` (section 1). Both are open, assigned to Caroline (5763097),
and the customer spoke last. This file is the decision under the ladder. **Nothing was sent, closed, refunded or
written to a register.** The customers' words stay on node-8; only conversation ids are here.

Ladder, as firstmate stated it: a refund inside the caps is AI-decided; a legal threat is Aaron's until he confirms;
anything above the caps is Aaron's.

## 1. `215473956059331` — legal-shaped by pattern, not a legal threat

- **What it is.** Waited 211 days, no account resolves. The thread asks whether Muso has a bug bounty or security
  program, then asks for "human support". The drain's shape is a pattern match on the words, and firstmate read it:
  there is no threat, no claim, no letter, nothing addressed to Muso as a legal matter.
- **Decision: not a legal-threat case, so it does not join this lane's refund corridor either.** It is a
  security-program question plus a request for a person, with no account behind it.
- **Disposition:** a human answers it. There is no approved `answer-bank.ts` line for a bug-bounty question, and a
  hand-composed answer about a security program is exactly the kind of sentence that should not be improvised -
  it promises a policy. So: escalation to the team queue with the reason "security-program question, no account, no
  approved line", and **not** a refund, credit or erasure action. Nothing here is in `erasure_requests`.
- **What would change this decision:** a message from the same thread that names a lawyer, a claim, a regulator or a
  deadline. Then it is Aaron's, in one line, and the corridor's wall applies.

## 2. `215475880107645` — a real refund request, decided on the money ladder

- **What it is.** Waited 65 days, account resolves, paying customer. In Spanish: they paid for the annual plan by
  mistake and wanted the monthly one. That is a genuine, specific refund request, and it is the *plan-mismatch*
  class, not a serviced-failure class: the service worked, the customer chose wrongly (as they describe it).
- **Decision: in scope of the money ladder, and it stays a money decision with a bound.** Reading it as "AI decides
  refunds under ~$150" would be too quick for two reasons:
  1. **The amount is unread.** No charge was read from Stripe by the drain, and an annual plan is not obviously under
     $150. Until the charge is read, the cap test cannot be applied at all, and a cap test that has not been run is
     not "inside the caps".
  2. **A full refund may not be the right remedy even inside the caps.** If the annual payment is recent and the
     customer wants the monthly plan, prorating the difference or switching the plan is a fairer answer than $X
     handed back, and it is commercially a different decision from the twice-billed service failure this corridor
     was built for.
- **Disposition:** hold, escalate to a human with the reason "refund inside the ladder but the charge is unread and the
  remedy is a plan change, not a service-failure refund". **Nothing is refunded by this lane**, and this thread is
  not a legal-threat case, so it does not touch the corridor's wall either.
- **Next step that would decide it** (a named human's, not this lane's): read the annual charge for the account on
  node-8 read-only, then either refund or prorate inside the caps with the customer's own words quoted, or send it to
  Aaron if the charge is above $150. Whatever is chosen, the answer has to be in Spanish and has to name the number.

## Why neither came to a machine write

The machine path is not armed (`/etc/hydra/refund-machine-approvals/` does not exist), and as of head `4795a648b` a
record is an approval only when the reviewer key signs it — a key that is not on node-8. So there was no path on
which either thread could have been refunded tonight even if the ladder had said yes, and it did not say yes.

## What would make the first thread a corridor case

A legal threat in the thread, or an account that resolves with a serviced-failure-shaped complaint. Then it joins
this lane's rule rather than the team queue.
