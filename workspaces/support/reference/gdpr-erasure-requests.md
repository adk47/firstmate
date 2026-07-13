# GDPR / Data Erasure Requests

How to handle "delete my data" requests that invoke GDPR, UK GDPR, the "right to be
forgotten", or erasure of personal data – as distinct from a plain subscription cancel
or a simple account-deletion request (common-issues Row #10 covers the disambiguation).

**Why this is its own flow:** Muso deletes account data on request, but factual music
credits on published works go through a formal legal review on our side and are often
retained. The written legal response ALWAYS comes from the team, never from Caroline.
The team is on a statutory clock (one month from the day the request arrives), so file
the handoff immediately – the same conversation the request is made in.

## Recognize it

Treat the request as a GDPR erasure request when the customer:

- uses words like "GDPR", "right to be forgotten", "erasure", "data protection",
  "DSAR", "delete my personal data", or
- asks for their credits / their name / "everything about me" to be removed (not just
  the account), or
- is in the EU or UK and asks for deletion of anything beyond the account itself.

If they ONLY want to stop being charged, or only want the account login gone, that's
Row #1 / Row #10 – not this flow.

## Hard rules (never break these)

1. **Never promise that credits will be removed**, and never say "all your data will
   be deleted". Account data can be deleted; credit records go through a formal review
   and the outcome is the team's call, not yours.
2. **Never state or argue Muso's legal position.** No legal article numbers, no "the
   law allows us to keep it", and NEVER "it's public information anyway" – that framing
   is explicitly banned. If they push on the legal side, say the team's written
   response will cover it.
3. **Never confirm or list what data Muso holds** for a requester whose identity hasn't
   been verified by the team. Acknowledge and escalate; don't enumerate.
4. **Never send anything that reads like a formal or legal response.** Your reply is a
   plain acknowledgment; the formal written response comes from the team.

## Resolution path

1. Acknowledge plainly. Safe framing you MAY use: "Account data – your login, email and
   personal details – can be deleted on request. Credit records on published works go
   through a formal review on our side, and our team will send you a written response."
2. File the handoff via the `action-request` skill with `actionType: data-deletion`
   (Tier 3). In `summary`/`details`, note:
   - that this is a GDPR / erasure request (quote their own wording),
   - the date the request was received (the team's one-month statutory clock starts
     then),
   - exactly what they asked to have deleted (account only, credits, profile,
     everything),
   - any escalation trigger below that is present.
3. Reply with the Tier 3 template from the skill and quote the returned SLA once.

## Escalation triggers – flag these loudly

If ANY of the following applies, still file the same `data-deletion` request, but name
the trigger in the `titleGist` AND at the top of the `summary`, keeping the customer's
own wording verbatim – the team routes these to legal counsel, and they must not read
like a routine deletion in the queue. The customer:

- claims the credits are inaccurate or fraudulent,
- is or may be a minor,
- raises safety concerns (stalking, harassment, protected identity),
- mentions sensitive personal data (health, orientation, beliefs, and the like),
- is represented by a lawyer, or references a data-protection authority / regulator.

## Easy cases that are NOT legal reviews

- **"The credit is wrong"** – that's a correction, not erasure. Follow the normal
  credits flow (common-issues Row #4). If they call the wrong credit fraudulent,
  that's an escalation trigger above.
- **"Take my profile down, I don't mind the credits staying"** – profile deactivation /
  unlink plus account deletion. Route per Row #10; no legal review implied.
