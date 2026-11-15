# GDPR / Data Erasure Requests

How to handle "delete my data" requests that invoke GDPR, UK GDPR, the "right to be
forgotten", or erasure of personal data – as distinct from a plain subscription cancel
or a simple account-deletion request (common-issues Row #10 covers the disambiguation).

**Why this is its own flow:** an account is closed and taken out of use on request, but
factual music credits on published works go through a formal legal review on our side and
are often retained. Nothing is promised as deleted: what was deleted is stated only in the
team's written confirmation. The written legal response ALWAYS comes from the team, never from Caroline.
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
   be deleted" or that anything gets deleted. An account is closed and taken
   out of use; credit records go through a formal review and the outcome is the team's
   call, not yours.
2. **Never state or argue Muso's legal position.** No legal article numbers, no "the
   law allows us to keep it", and NEVER "it's public information anyway" – that framing
   is explicitly banned. If they push on the legal side, say the team's written
   response will cover it.
3. **Never confirm or list what data Muso holds** for a requester whose identity hasn't
   been verified by the team. Acknowledge and escalate; don't enumerate.
4. **Never send anything that reads like a formal or legal response.** Your reply is a
   plain acknowledgment; the formal written response comes from the team.

## Resolution path

1. **Approved acknowledgement** (first reply, same conversation, always; GDPR acknowledgement v2, ruled 2026-11-01, replaces the 10-29 text). Send it verbatim, with {date} = the day the request arrived. Pick the fixed slots below; never edit a sentence.

   <!-- approved: gdpr-ack-v2-1101 -->
   > Thank you, we have your request to remove your personal data from Muso, received {date}. Here is how it works.
   >
   > **1. Confirm it's you.** The quickest way: open the page in the Muso app and claim it, that proves it on the spot. Or reply from the email address on your Muso account, if you have one. If neither applies, send the link to the page and your name as it appears on your ID. If you are writing for someone else, send their written authorisation.
   >
   > **2. We hide the page.** As soon as we've confirmed it's you, the page comes out of Muso search and public view. If your request raises a legal matter, we hide it immediately.
   >
   > **3. Written confirmation on this thread**, within one month of today, listing exactly what was done. Any account you hold is closed and taken out of use on request; what has been deleted is stated in that confirmation.
   >
   > Credit records on published works go through a separate formal review, and the written response covers them.

   Fixed slots (pick, never edit):
   - **No Muso page link in their message:** append
     > To get started, reply with the link to the Muso page.
   - **A link is present and the page's name is the sender's own name** (the name they sign with or their email name): step 1 reads instead. It is a condition, never a promise: whether the name confirms them is the team's call (path C below: unclaimed pages only; claimed, big-name or high-credit pages go to a person).
     > **1. Confirm it's you.** The quickest way: open the page in the Muso app and claim it. Otherwise, reply with your name as it appears on your ID; if the page is unclaimed and carries that name, the team can confirm it from that.
   - **Legal words** (lawyer, solicitor, attorney, regulator, data-protection authority, CNIL, ICO, formal notice): the text above unchanged, and put `legal_threat` first in the ticket's `titleGist` and `summary` (and `details.legal_threat: true`). The team hides the page the same day without waiting for identity.

   **A claim is NOT required for GDPR.** Claiming is the quickest way to confirm it's them, so it leads the list, but it is one way among several. Claim-first is the rule for copyright / takedown requests only. Never tell a GDPR requester they must claim the page first.

   How the team confirms identity (for the ticket; never quote this table to the customer):

   | path | what proves it |
   |---|---|
   | A. claim | their account holds a processed claim on the page that carries verification links and was processed after it was made (ruling 2026-11-13), or they claim it now and the claim carries such a link; a claim filed and processed in the same instant with no links does not confirm a hide (see `docs/support/gdpr-pipeline.md`) |
   | B. account email | they write from the email of a Muso account whose name matches the page |
   | C. their name on an unclaimed page | the page is unclaimed and its name is the legal name they give; big-name or high-credit pages go to a person |
   | D. official domain | they write from the artist's or label's own domain |
   | E. representative | written authorisation from the person the page is about |
   | legal_threat | the page is hidden first, identity after |

2. File `create_ticket` with `actionType: data-deletion`. In `summary`/`details`, note:
   - that this is a GDPR / erasure request (quote their own wording),
   - the date the request was received (the one-month clock starts then),
   - the links they gave and exactly what they asked to have removed,
   - any escalation trigger below, named FIRST in the summary.
3. That is the whole reply. `create_ticket` returns no timeframe for this kind: the only
   timing is the acknowledgement's "within one month of today" for the written confirmation
   (the statutory month). Never a day count for the hide. Never a business-day number, never "deleted" or "we will
   delete", never "your profile may be recreated", never the legal position,
   never what data we hold, never the playbook letter. The written confirmation comes from
   the process, not from you; never say a page was deleted or hidden.
4. **"My profile was hidden, will it come back?"**: "No, once a page is hidden it stays
   hidden; our written confirmation covers what was done." Then the honesty line: "I have recorded
   this and will update you here as soon as there is news."

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
