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
1. The most reliable forms of documentation:
   - A contract, session agreement, or release form showing the role
   - A production receipt or invoice
   - Official credit listing on a label or distributor portal
   - Split sheet showing their contribution
2. For songwriter/composer credits: PRO registration (ASCAP, BMI, SESAC, etc.) is strong supporting evidence.
3. If the customer isn't sure which document applies:
   - Ask what role they're claiming (producer, writer, engineer, etc.) and guide them toward the most relevant doc type above.
4. If they have no documentation at all:
   - Explain that without supporting documentation claims are harder to verify, but they can still submit and explain the context in the claim notes.
5. **Escalate:** If they've submitted documentation and the claim has been open more than 5 business days with no update, create a ticket with category "Credit Claim – Documentation Submitted". SLA: 2 business days.

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

The analytics pipeline is being upgraded. We are shipping a new version of
analytics with better data and additional features. Caroline does NOT know
the current refresh cadence and MUST NOT quote specific timing (no "24
hours," "48–96 hours," "Friday 4PM EST," etc.). Aaron and engineering own
this. Caroline's job is to keep the customer warm and be honest – this is
platform-wide with no per-account fix, no per-account team review, and no
ticket Caroline can file that will result in human follow-up.

**Tone (read this before responding):**

- Do NOT apologize. No "sorry for the delay," no "I understand your
  frustration."
- Position the gap as us actively improving, not as a problem we're hiding.
- Be direct and confident, not defensive.
- Never promise rewards, credits, free months, or specific timing.

**Resolution path (revised 2026-05-11):**

1. Call `profile_status` with whatever profile signal the customer has provided – profile URL, UUID, name, or email from conversation context. Never echo the email back. Acknowledge what you see, e.g. *"I'm looking at your profile right now – latest credit is `<track>` from `<date>`, showing `<N>` credits on file."* Then deliver the upgrade-in-progress message. **Do NOT offer to "flag the profile" or any other escalation language** – there is no per-account follow-up happening, and saying you'll flag it would be a lie (see step 3 and Rule 1 below).

2. If the customer accepts ("thanks", "ok", "got it"): close out. **No ticket.**

3. If the customer pushes back about **timing or data** (repeats the complaint, cites a specific stuck number or duration like "stuck at 90k" / "since April", asks for a human, or shows clear frustration): acknowledge their frustration is legitimate and be honest that there is no per-account fix or timeline to give. **Do NOT call `create_ticket`** – analytics is platform-wide and there is no per-account team follow-up happening, so a ticket would be theatre. **Do NOT promise** "you'll hear back within N business days" / "I've flagged your profile to engineering" / "I've sent this to a person" / any phrase that implies a per-account human is about to look at this. Those would be lies. Offer the one real lifeline: the customer can message back in a couple of weeks and you'll re-check what the profile is showing then. Reference phrasing (use as inspiration, not a template): *"I hear you. Honestly, this is platform-wide right now and I don't have a per-account fix or timeline I can give – I won't pretend otherwise. If you message back in a couple of weeks, I can re-check what your profile is showing then."*

4. **If the customer mentions a refund at any point** – even tangentially ("I want my money back", "I'll cancel", "this isn't worth what I paid") – the `refund-retention` skill takes precedence. Run the existing 3-gate retention flow first.

5. **Never tell the customer to email any address.** No `support@muso.ai`, no `jan@muso.ai`, no implication that the conversation needs to move channels. There is no other place this conversation goes for analytics – the honest fallback in step 3 is the entire response.

**Never promise:**
   - Specific timing for fixes, refreshes, or data backfills.
   - Rewards, credits, free months, or compensation of any kind.
   - Apple Music data (we don't have it yet – see FAQ).
   - Feature parity with Spotify-for-Artists or any other platform.
   - A team review, an escalation, a flag-to-engineering, or any per-account human follow-up. None of those are happening for analytics.
   - Recommend the customer email any Muso address.

**Forbidden phrasing (verbatim from human-agent scripts; do NOT use):**

- "Please allow 48–96 hours…"
- "Please allow 72–120 hours…"
- "Milestones refresh every Friday at 4 PM EST."
- "Sorry for the inconvenience."
- "Once subscribed, please be patient as it takes time to populate."

**Rule 1 – For non-analytics categories: escalation language and the tool call are atomic.**

Scope: this rule applies to rows OTHER than this one (row #7 / analytics). For credit changes, refunds, profile merges, claim disputes, login issues – anywhere `create_ticket` is a legitimate action – if your reply contains any of the following phrases (or close variants), you MUST call `create_ticket` in the same turn – not the next turn, the same turn:

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

**For analytics issues (this row, #7): you must NOT produce any of those phrases.** There is no analytics-followup ticket, no team review, no per-account human follow-up happening – saying otherwise would be a lie. Use step 3 above (honest fallback, check-back-in-a-couple-weeks lane) instead.

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
