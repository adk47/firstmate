# Common Issues – Troubleshooting Guide

Decision-tree reference for the 10 most frequent customer scenarios, based on real conversation data.

---

## 1. Managing a subscription (upgrade / downgrade / cancel)

**Customer says:** "I want to upgrade / downgrade / cancel my plan."

**Resolution path:**
1. Confirm the action they want
   - If upgrading: direct to Settings > subscription > select new plan. Takes effect immediately.
   - If cancelling: direct to Settings > subscription > cancel. Access continues until billing period ends. Credits and profile data are never deleted.
   - If downgrading (Pro to Lite): same as cancel – access to paid features ends at period end.
2. If they can't find the setting in the app:
   - Walk them through Settings > Billing or Subscription section
3. **Escalate:** If they're unable to make the change after following the steps, create a ticket with category "Billing – Self-Service Failure". SLA: 1 business day.

---

## 2. Profile claim or verification stuck

**Customer says:** "I tried to claim my profile but nothing is happening" / "My claim was rejected."

**Resolution path:**
1. Ask: did they receive any email about the claim status?
   - If rejected: check the rejection reason in the email. Common reasons: name mismatch, unrecognised social account, insufficient documentation. Ask them to resubmit with a government-issued ID.
   - If no email at all: ask how long ago they submitted.
2. If submitted less than 5 business days ago: let them know it's within normal review time and to wait.
3. If more than 5 business days with no update:
   - **Escalate:** Create a ticket with category "Profile Claim – Pending Review". Include: account email, profile URL they tried to claim, date of submission. SLA: 2 business days.
4. If claim was rejected and resubmission also rejected:
   - **Escalate:** Create a ticket with category "Profile Claim – Rejected". Include: account email, profile URL, documentation provided. SLA: 2 business days.
5. If the customer says the profile belongs to someone else they represent (a client, an artist on their roster), STOP – this is not a self-claim. Switch to row 2b below.

---

## 2b. Claiming a profile on behalf of an artist (manager / publisher / label)

**Customer says:** "I manage this artist and need to claim their profile" / "The artist has no social media so they can't claim it" / "We have a contract that gives us the right to administer their catalog."

This is an **on-behalf claim**, NOT a self-claim. The standard claim flow (the artist's own ID scan or social-media login) does not apply, and there is no self-service path for it. It always requires a manual admin review.

**Resolution path:**
1. NEVER tell the customer the artist must claim the profile themselves. If they have already explained the artist cannot complete self-claim (no social media, deceased, unreachable, contractual delegation), repeating the self-claim instructions is the single worst response – it is exactly what frustrated customers quote back at us.
2. Collect the on-behalf evidence (any they can provide; screenshots accepted):
   - Publishing / rights-management / management contract naming the artist
   - A letter of authorization (LOA) from the artist or rights holder
   - The customer's own account email and the exact profile URL or name they need access to
3. Create ONE ticket with `actionType: "profile-claim"` and put `"on_behalf": true`, the representative's relationship (manager / publisher / label), and the documentation summary in `details`. Set `details.escalation_reason: "on_behalf_claim_manual_review"` so the ticket is tagged for human review.
4. Set the expectation honestly: this is a **manual review by our team with no fixed turnaround** – do NOT quote the standard profile-claim SLA. Say something like: "This kind of access needs a manual review on our side. I've sent the team everything you provided – they'll reach out if anything else is needed."
5. On any follow-up about the same request, follow the SLA-breach rules (see SOUL.md "Repeat follow-ups") – do not file fresh tickets and do not re-promise turnarounds.

---

## 3. Duplicate profiles – merge request

**Customer says:** "I show up twice / under different names. Can you merge them?"

There is **no self-service merge UI** in app.muso.ai. Do NOT direct customers to "Settings > Profile > Merge Request" or any similar in-app flow – it does not exist. Profile merges are handled by the operations team via support ticket.

**Resolution path:**
1. Ask the customer for the link to the profile they want to keep as their **main** profile (e.g., `https://credits.muso.ai/profile/<id>` or `https://app.muso.ai/profile/<id>`).
2. Ask for the link(s) to the **duplicate** profile(s) to merge into the main.
3. Once both are provided, create an action-request ticket with `actionType: "profile-merge"` (Tier 2). Include in `details`:
   - `main_profile_url` – the URL the customer wants kept
   - `duplicate_profile_urls` – array of duplicate profile URLs to merge in
4. Set expectation: "Our team will review and merge typically within 5 business days. You'll get a confirmation once it's done."

**Notes:**
- Never share an internal team member's email or assign a specific reviewer by name – the operations team triages from the ticket queue.
- Never reference internal tools or URLs (e.g., admin dashboards, retool). Customer-facing URLs only.
- If the customer can't provide URLs and only knows profile names, run `profile_lookup` to confirm matches before opening the ticket – include the resolved profile IDs in `details` instead of (or alongside) URLs.

---

## 4. Credits missing or wrong

**Customer says:** "My credit isn't showing" / "The credit is wrong."

**Resolution path:**
1. Is the credit missing or incorrect?
   - If **missing**: ask if they've tried "Add Missing Credits" in the app. If not, walk them through it (log in > navigate to track/album > Add Missing Credits > specify role > submit). Reviews within 48 hours.
   - If **incorrect**: continue to step 2.
2. Is the credit sourced from Muso or an external platform?
   - Ask: does the incorrect credit appear on Spotify, Apple Music, or their distributor in the same wrong form?
   - If **yes (external source)**: explain that Muso reflects what the source reports. They need to contact their distributor or that platform to correct the metadata. Once fixed at the source, Muso updates automatically.
   - If **no (Muso source or unsure)**: they can request a correction through their account. If that doesn't work, escalate.
3. **Escalate:** Create a ticket with category "Credit Error – Muso Source" or "Credit Error – Source Discrepancy". Include: account email, track/album URL, the incorrect credit detail, what the correct credit should be. SLA: 2 business days.

---

## 5. Documentation needed for pending credits

**Customer says:** "What do I need to send to verify my credit?"

**Resolution path:**
1. **Where to send it and what to include:** Proof goes here in the in-app
   support chat. There is nowhere else to upload it. Ask the customer to include
   their Muso profile link, the track title, the artist name, their role on the
   track, and a release link, along with the proof itself. For multiple tracks,
   have them list each track with their role on it so the team can match each
   piece of proof cleanly.
2. Accepted forms of proof (screenshots are accepted for all of these):
   - A public link where the credit is listed – Tidal, Genius, Jaxsta, Discogs,
     AllMusic, ASCAP, or BMI
   - Documentation of the work – a project/session file, communication with the
     artist, a contract, session agreement, release form, or split sheet showing
     the role
   - A production receipt or invoice, or an official credit listing on a label or
     distributor portal
   - Confirmation from a credited collaborator, the artist, or the rights holder
     (forwarded by the customer)
3. For songwriter/composer credits: PRO registration (ASCAP, BMI, SESAC, etc.) is strong supporting evidence.
4. If the customer isn't sure which document applies:
   - Ask what role they're claiming (producer, writer, engineer, etc.) and guide them toward the most relevant doc type above.
5. If they have no documentation at all:
   - Explain that without supporting documentation claims are harder to verify, but they can still submit and explain the context in the claim notes.
6. If the credit is in "user verification needed", the `customer-credit-verification`
   skill governs the full flow (ownership check, proof intake, routing to the team).
7. **Escalate:** If they've submitted documentation and the claim has been open more than 5 business days with no update, create a ticket with category "Credit Claim – Documentation Submitted". SLA: 2 business days.

---

## 6. Charged but subscription inactive

**Customer says:** "I paid but my account still shows Lite / no analytics."

**Resolution path:**
1. Ask them to check:
   - Is the charge showing as settled (not pending) on their bank statement?
   - Is the email on their Muso account the same one that received the payment receipt?
2. If charge is still pending: it can take 1-2 business days to process. Ask them to wait and check again.
3. If charge is settled and email matches but account still shows inactive:
   - Wait up to 24 hours from payment settlement before escalating.
4. If 24+ hours have passed and subscription is still inactive:
   - **Escalate:** Create a ticket with category "Billing – Charged but Inactive". Include: account email, payment confirmation or receipt, amount and date charged. SLA: 1 business day.

---

## 7. Analytics not showing / streams not updating

**Customer says:** "My analytics aren't updating," "I just upgraded but no
streams," "My Spotify shows X streams but Muso shows Y," "I'm on Pro but I
see nothing."

Analytics and stream counts now run on our upgraded platform. Caroline does
NOT know the exact refresh cadence and MUST NOT quote specific timing (no "24
hours," "48–96 hours," "Friday 4PM EST," etc.). Treat analytics like any other
data complaint: ground in the customer's profile first, help with the basics,
and if their data genuinely looks off, flag it for the team like any other
data-integrity issue.

**Tone (read this before responding):**

- Do NOT apologize. No "sorry for the delay," no "I understand your
  frustration."
- Be direct and confident, not defensive.
- Never promise rewards, credits, free months, or specific timing.

**Resolution path:**

1. Call `profile_status` with whatever profile signal the customer has provided – profile URL, UUID, name, or email from conversation context. Never echo the email back. Acknowledge what you see, e.g. *"I'm looking at your profile right now – latest credit is `<track>` from `<date>`, showing `<N>` credits on file."*

2. Check the basics: analytics need an active Pro or Business plan with a seat assigned to the profile (see `faq.md`). If a subscription or seat is the issue, guide them to fix it in Settings.

3. If subscription and seat are fine and the data still looks off or stale, treat it like any data-integrity issue: file `create_ticket` with `actionType: analytics-followup`, then tell the customer plainly you've flagged it and quote the SLA once (2 business days). New story, simple and honest: *"Analytics are running on our upgraded platform now. If yours still looks off, tell me what you're seeing and I'll take a closer look and flag it for our team."* Your reply uses escalation language, so the ticket call is atomic with it – see Rule 1.

4. If the customer accepts ("thanks", "ok", "got it"): close out warmly.

5. **If the customer mentions a refund at any point** – even tangentially ("I want my money back", "I'll cancel", "this isn't worth what I paid") – the `refund-retention` skill takes precedence. Run the existing 3-gate retention flow first.

6. **Never tell the customer to email any address.** No `support@muso.ai`, no `jan@muso.ai`, no implication that the conversation needs to move channels. The ticket flow in step 3 is the path.

**Never promise:**
   - Specific timing for fixes, refreshes, or data backfills.
   - Rewards, credits, free months, or compensation of any kind.
   - Apple Music data (we don't have it yet – see FAQ).
   - Feature parity with Spotify-for-Artists or any other platform.

**Forbidden phrasing (verbatim from human-agent scripts; do NOT use):**

- "Please allow 48–96 hours…"
- "Please allow 72–120 hours…"
- "Milestones refresh every Friday at 4 PM EST."
- "Sorry for the inconvenience."
- "Once subscribed, please be patient as it takes time to populate."

**Rule 1 – Escalation language and the ticket call are atomic.**

This applies to every category, analytics included. Anywhere `create_ticket` is a legitimate action – credit changes, refunds, profile merges, claim disputes, login issues, analytics follow-ups – if your reply contains any of the following phrases (or close variants), you MUST call `create_ticket` in the same turn – not the next turn, the same turn:

- "I'll flag this"
- "I'll escalate this"
- "I'll send this to the team"
- "I'll get this in front of engineering"
- "I'll route this for review"
- "I've sent this to a person"
- "I've flagged your profile"
- "this needs review on our side"
- "this is being looked at"

If the tool call did not succeed, do not say you escalated. Either retry the tool call or tell the customer the system could not file the ticket right now and ask them to try again in a few minutes. Never imply an escalation happened when it did not.

---

## 8. Can't log in

**Customer says:** "I can't access my account."

**Resolution path:**
1. Ask: do they remember which email they signed up with?
   - If no: check if they have any old emails from Muso.AI to find the correct address.
2. Direct them to use "Forgot Password" on the login page.
3. If they signed up via social login (Google, Apple, etc.): try that login method instead of email/password.
4. If they reset the password and still can't log in:
   - Check if they're using the right email – common issue is having multiple email addresses.
5. If still unable to log in after all steps:
   - **Escalate:** Create a ticket with category "Login – Account Access". Include: account email (or emails they've tried), login method (email/social), error message if any. SLA: 1 business day.

---

## 9. Refund request

**Customer says:** "I want a refund."

**Resolution path:**
1. Ask why they're requesting the refund – this helps route the ticket correctly:
   - Charged in error (duplicate charge, charged after cancel)
   - Didn't use the subscription / not what they expected
   - Technical issue prevented them from using the product
2. There is no self-service refund path – all refund requests go to the support team.
3. Let the customer know refund requests are reviewed by the team and they'll receive a response by email.
4. **Escalate:** Create a ticket with category "Billing – Refund Request". Include: account email, reason for refund, amount and charge date, any relevant context. SLA: 2 business days.

---

## 10. Account deletion

**Customer says:** "I want to delete my account."

**Resolution path:**
1. Confirm what they want deleted:
   - Just their subscription (cancel without deleting the account)?
   - Full account and data deletion?
2. If they only want to stop being charged: direct them to Settings > cancel subscription. Account stays intact.
3. If they want full deletion:
   - There is no self-service account deletion.
   - **Escalate:** Create a ticket with category "Account – Deletion Request". Include: account email, confirmation that they understand deletion is permanent and all data will be removed. SLA: 3 business days.
