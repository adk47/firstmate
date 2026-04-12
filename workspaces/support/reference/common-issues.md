# Common Issues — Troubleshooting Guide

Decision-tree reference for the 10 most frequent customer scenarios, based on real conversation data.

---

## 1. Managing a subscription (upgrade / downgrade / cancel)

**Customer says:** "I want to upgrade / downgrade / cancel my plan."

**Resolution path:**
1. Confirm the action they want
   - If upgrading: direct to Settings > subscription > select new plan. Takes effect immediately.
   - If cancelling: direct to Settings > subscription > cancel. Access continues until billing period ends. Credits and profile data are never deleted.
   - If downgrading (Pro to Lite): same as cancel — access to paid features ends at period end.
2. If they can't find the setting in the app:
   - Walk them through Settings > Billing or Subscription section
3. **Escalate:** If they're unable to make the change after following the steps, create a ticket with category "Billing — Self-Service Failure". SLA: 1 business day.

---

## 2. Profile claim or verification stuck

**Customer says:** "I tried to claim my profile but nothing is happening" / "My claim was rejected."

**Resolution path:**
1. Ask: did they receive any email about the claim status?
   - If rejected: check the rejection reason in the email. Common reasons: name mismatch, unrecognised social account, insufficient documentation. Ask them to resubmit with a government-issued ID.
   - If no email at all: ask how long ago they submitted.
2. If submitted less than 5 business days ago: let them know it's within normal review time and to wait.
3. If more than 5 business days with no update:
   - **Escalate:** Create a ticket with category "Profile Claim — Pending Review". Include: account email, profile URL they tried to claim, date of submission. SLA: 2 business days.
4. If claim was rejected and resubmission also rejected:
   - **Escalate:** Create a ticket with category "Profile Claim — Rejected". Include: account email, profile URL, documentation provided. SLA: 2 business days.

---

## 3. Duplicate profiles — merge request

**Customer says:** "I show up twice / under different names. Can you merge them?"

**Resolution path:**
1. Confirm they have an account at app.muso.ai and are logged in.
2. Direct them to: profile settings > merge request > identify duplicates > submit.
3. Set expectation: the team reviews and merges within 5 business days. The primary profile name is kept (they can specify preference in the request).
4. If they've already submitted a merge request:
   - Ask how long ago.
   - If less than 5 business days: it's within normal time, wait.
   - If more than 5 business days:
     - **Escalate:** Create a ticket with category "Profile Merge — Pending". Include: account email, profile URLs involved, date of merge request submission. SLA: 2 business days.

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
3. **Escalate:** Create a ticket with category "Credit Error — Muso Source" or "Credit Error — Source Discrepancy". Include: account email, track/album URL, the incorrect credit detail, what the correct credit should be. SLA: 2 business days.

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
5. **Escalate:** If they've submitted documentation and the claim has been open more than 5 business days with no update, create a ticket with category "Credit Claim — Documentation Submitted". SLA: 2 business days.

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
   - **Escalate:** Create a ticket with category "Billing — Charged but Inactive". Include: account email, payment confirmation or receipt, amount and date charged. SLA: 1 business day.

---

## 7. Analytics not showing

**Customer says:** "I'm on Pro but I can't see any streaming data."

**Resolution path:**
1. Confirm they have an active Pro or Business subscription (not Lite).
2. Confirm their profile has a seat assigned. They can check in account settings under their subscription.
3. If they just upgraded: analytics populate after the next daily refresh at 4PM EST. Ask if it's been at least 24 hours.
4. If subscription is active, seat is assigned, and 24+ hours have passed:
   - **Escalate:** Create a ticket with category "Analytics — Missing Data". Include: account email, profile URL, subscription plan, when they upgraded. SLA: 1 business day.

---

## 8. Can't log in

**Customer says:** "I can't access my account."

**Resolution path:**
1. Ask: do they remember which email they signed up with?
   - If no: check if they have any old emails from Muso.AI to find the correct address.
2. Direct them to use "Forgot Password" on the login page.
3. If they signed up via social login (Google, Apple, etc.): try that login method instead of email/password.
4. If they reset the password and still can't log in:
   - Check if they're using the right email — common issue is having multiple email addresses.
5. If still unable to log in after all steps:
   - **Escalate:** Create a ticket with category "Login — Account Access". Include: account email (or emails they've tried), login method (email/social), error message if any. SLA: 1 business day.

---

## 9. Refund request

**Customer says:** "I want a refund."

**Resolution path:**
1. Ask why they're requesting the refund — this helps route the ticket correctly:
   - Charged in error (duplicate charge, charged after cancel)
   - Didn't use the subscription / not what they expected
   - Technical issue prevented them from using the product
2. There is no self-service refund path — all refund requests go to the support team.
3. Let the customer know refund requests are reviewed by the team and they'll receive a response by email.
4. **Escalate:** Create a ticket with category "Billing — Refund Request". Include: account email, reason for refund, amount and charge date, any relevant context. SLA: 2 business days.

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
   - **Escalate:** Create a ticket with category "Account — Deletion Request". Include: account email, confirmation that they understand deletion is permanent and all data will be removed. SLA: 3 business days.
