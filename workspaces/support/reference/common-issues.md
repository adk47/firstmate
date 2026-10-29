# Common Issues – Troubleshooting Guide
<!-- Reviewed baseline: deploy overwrites the live copy of this file. The live edits of 2026-10-15/16 (section 8b sign-out workaround; plaque ordering) are folded in here together with PR #1224, so overwriting loses nothing. Drop this line once the next release has shipped (MUS-13058). -->

Decision-tree reference for the 10 most frequent customer scenarios, based on real conversation data.

---

## 1. Managing a subscription (upgrade / downgrade / cancel)

**Customer says:** "I want to upgrade / downgrade / cancel my plan."

**Resolution path:**
1. Confirm the action they want
   - If upgrading: direct to Settings > subscription > select new plan. Takes effect immediately.
   - **If cancelling (they want out, not just asking how)**: the `refund-retention` skill takes precedence – run its retention flow (50% save, free-plan fallback), and if they still want out Caroline cancels in-chat via `cancel_subscription` (period end; access continues until the billing period ends; credits and profile data are never deleted). Handle via Row #9's flow.
   - If asking how to cancel (informational): direct to Settings > subscription > cancel. Access continues until billing period ends.
   - If downgrading (Pro to Lite): same as cancel – access to paid features ends at period end.
   - **If they also mention wanting a refund** ("cancel and refund it", "cancel and get my money back"): the `refund-retention` skill takes precedence. Handle via Row #9, not here.
2. If they can't find the setting in the app:
   - Walk them through Settings > Billing or Subscription section, or – if they've clearly asked to cancel – run the Row #9 flow and cancel for them.
3. **Escalate:** If they're unable to make the change after following the steps (and it isn't a cancel Caroline can do herself), create a ticket with category "Billing – Self-Service Failure". SLA: 1 business day.

---

## 2. Profile claim or verification stuck

**Customer says:** "I tried to claim my profile but nothing is happening" / "My claim was rejected."

**Resolution path:**
0. **Ground first**: call `profile_claim_status` with the profile URL, then branch on `own_claim_state`: `pending` with `route_selfserve_claim` → the `customer-profile-claim` skill can verify it now (take the returned `claim_id`); `rejected` → explain the returned reason and the resubmission path below; `processed` → the claim is already approved, this is an access question; `reverted` / `multiple` / any conflict or suspicion flag → file the `profile-claim` packet the tool suggests, never argue ownership. If it fails closed (identity unverified) continue below without asserting claim state.
1. **Pending:** tell them plainly the claim is pending, in the app's own words for that state ("We are verifying your claim and will notify you when it has been processed"). Quote no timeframe and never say a person will review it: claims are decided under written rules, not by a human review queue. If we already sent them a message asking for a code, the code goes exactly where that message says; never invent a code, a surface, or a check of your own.
2. **Rejected:** explain the reason the tool returned. The claim form asks for a link or two they control (their own website, streaming artist page, or social account); claiming again with such a link is the resubmission path. There is no ID upload in the claim flow, so never ask for a government ID.
3. **Stuck, contested, or anything the tool routes:** file the `profile-claim` packet it suggests (account email, profile URL, date of submission or rejection reason). `create_ticket` returns no timeframe for claims; quote none.
4. Claim notifications from the app (the bell and the claim email) go out on their own; your reply in this conversation is separate from them.
5. If the customer says the profile belongs to someone else they represent (a client, an artist on their roster), STOP – this is not a self-claim. Switch to row 2b below.

---

## 2b. Claiming a profile on behalf of an artist (manager / publisher / label)

**Customer says:** "I manage this artist and need to claim their profile" / "The artist has no social media so they can't claim it" / "We have a contract that gives us the right to administer their catalog."

This is an **on-behalf claim**, NOT a self-claim. The standard claim flow (the artist's own links) does not apply. It is decided by the claim lane on the organization path: the strongest proof is a confirmed Muso account email on the official domain of the label, management company or publisher shown on the artist's streaming page or website (no free-mail address). `profile_claim_status` can still supply the facts for the packet (existing claims on the profile, conflicts).

**Resolution path:**
1. NEVER tell the customer the artist must claim the profile themselves. If they have already explained the artist cannot complete self-claim (no social media, deceased, unreachable, contractual delegation), repeating the self-claim instructions is the single worst response – it is exactly what frustrated customers quote back at us.
2. Collect the on-behalf evidence (any they can provide; screenshots accepted):
   - Publishing / rights-management / management contract naming the artist
   - A letter of authorization (LOA) from the artist or rights holder
   - The customer's own account email and the exact profile URL or name they need access to
3. Create ONE ticket with `actionType: "profile-claim"` and put `"on_behalf": true`, the representative's relationship (manager / publisher / label), the domain of their account email, and the documentation summary in `details`. Set `details.escalation_reason: "on_behalf_claim_manual_review"` (the tag name is historical; it routes the ticket to the claim lane's organization path, not to a person).
4. Quote no timeframe and do not say it needs a manual review: `create_ticket` returns no timeframe for claims. Do not promise a reply here either: the claim decision reaches them as an app notification and email.
5. On any follow-up about the same request, follow the SLA-breach rules (see SOUL.md "Repeat follow-ups") – do not file fresh tickets and do not re-promise turnarounds.

---

## 3. Duplicate profiles – merge request

**Customer says:** "I show up twice / under different names. Can you merge them?"

There is **no self-service merge UI** in app.muso.ai yet. Do NOT direct customers to "Settings > Profile > Merge Request", "My profiles > Merge" or any similar in-app flow until this file says it is live. Merges are claim-first (captain rule 2026-10-23): a merge happens only when EVERY profile involved has a processed claim by this customer and is in their workspace.

**Resolution path:**
1. Ask the customer for the link to the profile they want to keep as their **main** profile (e.g., `https://credits.muso.ai/profile/<id>` or `https://app.muso.ai/profile/<id>`).
2. Ask for the link(s) to the **duplicate** profile(s) to merge into the main.
3. Run `dedupe_check` (security routing first, as in `customer-profile-dedupe`), then answer from what it says about each profile:
   - **Every profile already claimed by this customer** (`owns_survivor: true` and every duplicate `claim_state: "claimed_same_owner"`): nothing more is needed from them. Never tell them their claims need review or ask them to claim again.
   - **A duplicate not claimed by them yet** (`claim_state: "unclaimed"`; check `profile_claim_status` for a pending or rejected claim of theirs): name exactly which one, and tell them to claim it through the app first, then ask us to merge (claim-first rule above).
   - **`claimed_different_user`, `unresolved`, or a security flag:** never discuss the other account and promise no outcome; route it per `customer-profile-dedupe`.
4. Create an action-request ticket with `actionType: "profile-merge"`. Include in `details`:
   - `main_profile_url` – the URL the customer wants kept
   - `duplicate_profile_urls` – array of duplicate profile URLs to merge in
5. Promise no date: `create_ticket` returns no timeframe for merges. When the merge is done (or needs something from them), the result is posted as a reply in this conversation. Never say "I can merge them" or ask them to confirm a merge unless `profiles_consolidate` returned a successful preview this turn, and never say a merge is done unless a tool result says so.

**Notes:**
- Never share an internal team member's email or assign a specific reviewer by name – the operations team triages from the ticket queue.
- Never reference internal tools or URLs (e.g., admin dashboards, retool). Customer-facing URLs only.
- If the customer can't provide URLs and only knows profile names, run `profile_lookup` to confirm matches before opening the ticket – include the resolved profile IDs in `details` instead of (or alongside) URLs. `profile_credits_status` also surfaces same-name duplicate CANDIDATES (claim state + credit counts) when the customer can't name the duplicates yet – candidates only, never confirmed duplicates.
- **Known cause (2026-08-26, internal; do not quote the mechanism to customers):**
  a claim can mint an EMPTY twin of the profile rather than attaching to the
  populated one. The signature is a duplicate with the right name and few or zero
  credits, created around the time they claimed. That is our defect (IDP #1538), not
  customer error, so never imply they created it or claimed the wrong profile. File
  the `profile-merge` ticket as normal and note "empty twin, likely claim-mint" in
  `details` so ops can batch them.

---

## 4. Credits missing or wrong

**Customer says:** "My credit isn't showing" / "The credit is wrong."

**Resolution path:**
0. **Ground first**: call `profile_credits_status` with the profile and the track/role in question, then branch on its diagnosis: `on_this_profile` → the credit is already visible, show them where; `pending_verification` → it's in review, not missing (Row #5 flow); `awaiting_review` → answer from status: "N credits are waiting for our team to review", taking N from the diagnosis (it says "more than N" when the queue is truncated; never quote an exact capped count) (no proof ask, no date promise, and do NOT continue to step 1); `on_other_profile` → wrong-profile correction, file the handoff packet it returns; `not_found` → continue below.
1. Is the credit missing or incorrect?
   - If **missing**: first check the track is on Spotify – if it isn't (YouTube/Instagram-only release, live session video), we cannot add the track or its credits for now; say so plainly instead of promising a review. Otherwise ask if they've tried adding it themselves. If not, walk them through it for where they are – web: own profile > Summary panel > Add Credits > search or paste Spotify link > specify role > submit; app: track/album > Add Missing Credits > specify role > submit. Our team reviews submitted credits; review times vary, so don't promise a set time – the customer doesn't need to do anything while it waits for review.
   - If **incorrect**: continue to step 2.
2. Is the credit sourced from Muso or an external platform?
   - Ask: does the incorrect credit appear on Spotify, Apple Music, or their distributor in the same wrong form?
   - If **yes (external source)**: explain that Muso reflects what the source reports. They need to contact their distributor or that platform to correct the metadata. Once fixed at the source, Muso updates automatically.
   - If **no (Muso source or unsure)**: they can request a correction through their account. If that doesn't work, escalate.
3. **Escalate:** Create a ticket with category "Credit Error – Muso Source" or "Credit Error – Source Discrepancy". Include: account email, track/album URL, the incorrect credit detail, what the correct credit should be. `create_ticket` returns no timeframe for credit requests; quote none.

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
   - A public link where the credit is listed – Tidal, Genius, Discogs,
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
   When it's unclear whether the credit is pending at all, `profile_credits_status`
   reads the pending queue (`credit.pending`, `pending_verification` state) and the
   awaiting-review queue (`credit.awaiting_review`, `awaiting_review` state) before
   you enter the proof flow. Awaiting-review credits need no proof from the customer.
7. **Status first:** if they have already sent documentation, look up the real state with `credit_verification_check` / `profile_credits_status` and tell them what it says (on the profile, waiting for review, or exactly what is still missing). Never ask again for proof they already sent. If the state cannot be read, file `credit-verify` with the details; quote no timeframe.

**Notes:**
- **Before asking for more proof:** a credit sitting in `user_verification_needed` is
  usually NOT under suspicion. Most holds today are transient pipeline states
  (commonly the track still being captured) surfaced as if they were risk decisions
  (internal ref IDP #1537). Never tell a customer their credit was flagged, doubted,
  or held for review of their honesty. If they have already sent proof once, do not
  ask again; file the follow-up and reply per "Document received" in the
  `customer-credit-verification` skill. _(added 2026-08-26)_

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

0. **Entry condition – how-to or complaint?** If the customer is asking **where** something is, **how** to switch it on, or **how** to find it (e.g. "where is the live counter," "how do I turn on Live updates") – a how-to, not a complaint that a number is wrong – or says the live counter is not moving, go to section 7b and do NOT file an analytics follow-up. A how-to is never answered with a data complaint. Only continue below when the customer says their data is wrong, missing or stale.

1. Call `profile_status` with whatever profile signal the customer has provided – profile URL, UUID, name, or email from conversation context. Never echo the email back. Acknowledge what you see, e.g. *"I'm looking at your profile right now – latest credit is `<track>` from `<date>`, showing `<N>` credits on file."*

2. Check the basics: analytics need an active Pro or Business plan with a seat assigned to the profile (see `faq.md`). If a subscription or seat is the issue, guide them to fix it in Settings.

3. Call `profile_analytics_status` for the resolved profile. Use its structured status to decide the next move:
   - `fresh`: answer from the profile/subscription/status evidence and ask for the exact track/platform/count if the customer's complaint is more specific than the profile-level status.
   - `delayed` or `initializing`: explain that data is still processing. Do not quote exact refresh timing.
   - `warming` (or any result with `metrics.measured: false`): the analytics cache was cold, so no numbers were read. The tool already retried once. Do NOT file a ticket and do NOT quote the metrics, they are `null` rather than `0` for exactly this reason. Tell the customer their numbers are still loading and re-run the check before concluding anything.
   - `missing`, `stale`, or `inconsistent`: file `create_ticket` with `actionType: analytics-followup`.

4. If subscription and seat are fine and the data still looks off or stale, treat it like any data-integrity issue: file `create_ticket` with `actionType: analytics-followup`, then tell the customer plainly you've flagged it and quote the SLA once (2 business days). New story, simple and honest: *"Analytics are running on our upgraded platform now. If yours still looks off, tell me what you're seeing and I'll take a closer look and flag it for our team."* Your reply uses escalation language, so the ticket call is atomic with it – see Rule 1.

   Collect enough detail for the team in the same turn whenever the customer has
   it: Muso profile link, affected track or release links, source platform links,
   screenshots of the source counts, the counts they see in Muso, and whether
   the mismatch affects one track, one platform, or the lifetime total. Do not
   promise a per-account fix date.

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

If the tool call did not succeed, do not say you escalated. Either retry the tool call or tell the customer you could not get this to the team right now and ask them to try again in a few minutes. Never imply an escalation happened when it did not.

---

## 7b. "Where is the live counter / live updates?"

**Customer says:** "How do I see the live counter?", "Where do I turn on Live updates?", "My number isn't moving," "I heard there's a live streams number."

This is a how-to. Steps first. Do NOT call `create_ticket` and do NOT use `actionType: analytics-followup` unless the escalation condition at the end of this section holds, or step 1 outcome 3 applies (`support-general` only). Standing rules from section 7 apply: no apologies, no promised timing, no rewards or credits, never tell the customer to email an address. Never explain how the number is computed and never quote a refresh cadence. Describe it only as: *"Live estimate – projected in real time from the latest verified totals, and refined as new data syncs."*

**Resolution path:**

1. **Check eligibility with existing reads, do not guess:**
   - `founding_status` → founder active / lapsed / never, plus since-year. This is the rollout-audience clause.
   - `subscription_status` → is there an active Pro or Business subscription.
   - `profile_analytics_status` → `analytics.entitled: true` means the profile is on their workspace with a seat. A deny `reason` of `no_active_seat` or `profile_not_in_workspace` fails this clause.

   Sort the result into exactly one of three outcomes. A read that could not answer is NOT a "no". If one clause is a confirmed NO and another read is inconclusive, the confirmed NO wins (outcome 2).
   1. **All three answered and good:** tell them they have it and give the steps.
   2. **Any clause answered NO** (confirmed negative only): `founding_status` with `ok: true` and `founder_active: false` (lapsed or never); `subscription_status` with `ok: true` and no active Pro or Business plan; `profile_analytics_status` with `analytics.entitled: false` and a deny `reason` of `no_active_seat` or `profile_not_in_workspace`. The Display button is not drawn for them. Say it as a staged rollout: *"Live updates are rolling out in stages and aren't on every account yet."* No date, and do not say which stage is next. If the failing clause is the subscription or the seat, guide them to fix it in Settings as in section 7.
   3. **Any read NOT conclusive:** `founding_status` or `subscription_status` returning `ok: false` (any `reason`, including `lookup_unavailable`, `owner_undetermined`, `rate_limited`, `ambiguous_workspace`), or `profile_analytics_status` returning `found: false` (`no_match`, `multiple_matches`, `lookup_unavailable`) or a `human_review` deny (`owner_undetermined`, `account_not_resolved`, `check_unavailable`). The eligibility question is unanswered. Do NOT say the Display button is not drawn and do NOT use the staged-rollout line, because the account may be eligible. Take the existing human-review path in SOUL.md (Analytics handling, the `human_review` row): reply *"I can't verify your account details right now, but our team can help – let me flag this for them and someone will be in touch soon."* and file `create_ticket` with `actionType: support-general` in the same turn (Rule 1). Give no steps for the Display button and no figures.
      - **Exception, a plain how-to with no profile named:** if the only unanswered read is `profile_analytics_status` returning `found: false` with `reason: missing_input` (the customer gave no profile, as in "Where is the live counter?"), and the other two reads are good, this is not a handoff. Do not file a ticket. Give the web steps from step 2 without saying they have the feature, and add: *"If you don't see the Display button, send me the link to the profile you're viewing and I'll check."*

2. **Web steps, and lead with "it's already on":** *"It's already on by default. Go to Analytics, open the Summary card, and select Display at the top right next to the period selector. You'll see a Live updates switch and a Number format choice."*

3. **If the number does not move, walk the reasons in this order:**
   1. Period is not Lifetime: *"The live number only runs on the Lifetime view. Set the period selector to Lifetime."*
   2. Number format is Compact: *"Compact rounds to a short figure like 93.4B, so small movements don't show. Pick Full to see every digit move."*
   3. Live updates was switched off in this browser: *"Switch Live updates back on. It's remembered per browser, so check the one you're using."*
   4. The profile is not on their workspace: re-check the third eligibility clause.

4. **In the iOS and Android apps there is no switch.** *"In the app there's nothing to turn on. It shows by itself on the Lifetime view of Analytics."* Never name an app version and never say "update your app".

**Escalate only when all five hold:** (a) eligible on all three clauses, (b) Lifetime selected, (c) Live updates on, (d) Full format, and (e) the number is still static or clearly wrong. Anything short of all five is a how-to answer, not an escalation. In the iOS and Android apps there is no switch or format choice, so the app test is three conditions: (a) eligible on all three clauses, (b) the Lifetime view is open, and (e) the number is still static or clearly wrong. When the applicable conditions hold, file `create_ticket` with `actionType: analytics-followup` and continue at section 7 step 4 (the ticket and the one-time SLA quote) and its tone rules. Step 0 of section 7 does not apply to an escalation from 7b. If the reply uses escalation language, the `create_ticket` call happens in the same turn (Rule 1).

---

## 8. Can't log in

**Customer says:** "I can't access my account."

**Resolution path:**
1. Ask: do they remember which email they signed up with?
   - If no: check if they have any old emails from Muso.AI to find the correct address.
2. Direct them to use "Forgot Password" on the login page.
3. If they signed up via social login (Google, Apple, etc.): try that login method instead of email/password.
4. If they did not receive a password reset or verification email:
   - Ask them to check spam/promotions and confirm the email address they tried.
   - If they used Apple or Google login, have them try that login method instead of waiting for an email link.
   - Do not tell them to email support or move channels. If the email still is not arriving, file the login ticket below.
5. If they reset the password and still can't log in:
   - Check if they're using the right email – common issue is having multiple email addresses.
6. If still unable to log in after all steps:
   - **Escalate:** Create a ticket with category "Login – Account Access". Include: account email (or emails they've tried), login method (email/social), error message if any. SLA: 1 business day.

---

## 8b. App stuck on "Error occurred. Try to reload" (iPhone or Android)

**Customer says:** "The app won't load / it only works in the browser", "it keeps showing
Error occurred. Try to reload", "reloading or restarting my phone doesn't help". The website
(app.muso.ai) works for them.

**Cause (known, 2026-10-16):** their saved login in the app has expired, and the current app
version cannot sign itself out of an expired login, so it stays on the error screen. Reloading,
restarting the phone or reinstalling over the top does not clear it. Signing out and back in
does. A permanent app fix is in progress.

**Resolution path:**
1. Tell them the fix: on the error screen, tap the **sign-out icon at the top right**, then sign
   back in with the same method they normally use (Google, Apple or email).
   Saved reply: "Thanks for reporting this. Your app is holding on to an expired login, which it
   can't recover from on its own yet. To fix it, tap the sign-out icon at the top right of the
   error screen, then sign back in the way you usually do (Google, Apple or email). Everything
   will be there. We're also releasing an app update so this can't get stuck again."
2. If they cannot sign in again, follow section 8 (Can't log in).
3. If the error screen comes back right after a fresh sign-in, that is a different problem:
   create a ticket with category "App – startup error" and include the device, the app version,
   and a screenshot of the error screen.

Do NOT tell them to reinstall the app, wait, or update as the fix: none of those clears an
expired login. (The freeze on "Add Missing Credits" on iOS 17 is a different issue, fixed by
updating the app.)

---

## 9. Refund or cancellation request

**Customer says:** "I want a refund." / "Cancel my subscription." (or any exit signal – "money back", "cancel and refund it", "this isn't worth what I paid")

The `refund-retention` skill governs this ENTIRE flow – run it FIRST (SOUL.md wires it in as mandatory). Do NOT just ask "why?" once and escalate: that skips the retention gates and the saves. A refund ticket or a cancel is the LAST step, not the first.

**Resolution path:**
1. Run the `refund-retention` 3-gate flow (`skills/refund-retention/SKILL.md`), keeping a visible exit in every message:
   - **Diagnose** – ask what's not working and categorize the reason.
   - **Help (reason-matched)** – the primary save is the **50% retention offer** (the same one the in-app cancel flow gives): run `retention_offer_check` and, if eligible, offer it with the returned wording; apply on acceptance via `retention_offer_apply`. The fallback is the **free Lite plan**: "you'd keep everything you've built – credits, profile, the works – you'd just lose the analytics and audit tools." Offer a save as soon as the reason is clear; don't hold it for the last gate.
   - **Last alternative** – one final save (whichever hasn't been offered) before the exit.
2. If the customer still wants out, ASK which exit they want:
   - **Cancel only** – Caroline cancels in-chat via `cancel_subscription` (period end: access runs to the end of the paid period, no money moves). Quote the returned `access_until` date. No ticket.
   - **Refund** – run `billing_status` (`customer_request: "refund"`) and hand off to the `action-request` skill with `subscription-refund` (Tier 3), including its `handoff_packet` (charge/refund facts pre-filled) and the `retention_context` block. Quote the SLA the ticket response returns (per the skill's handoff) – do NOT promise a fixed turnaround here. Operations reviews, and handles the cancel together with the refund.
3. There is no self-service refund path, and Caroline never processes the refund herself – Operations reviews and executes it.

**Billing-issue exception:** charged twice / wrong amount / charged after cancel is NOT a retention case – it follows the `billing-issue` path inside the skill (Gate 2 files a Tier-2 billing ticket), not the refund gates.

---

## 10. Account deletion

**Customer says:** "I want to delete my account."

**Resolution path:**
1. Confirm what they want deleted:
   - Just their subscription (cancel without deleting the account)?
   - Full account and data deletion?
2. If they only want to stop being charged: direct them to Settings > cancel subscription. Account stays intact.
3. **GDPR / erasure check:** if they invoke GDPR, the "right to be forgotten", or erasure of personal data, or want their credits / their name removed (not just the account), the `gdpr-erasure-requests` reference governs that ENTIRE flow – follow it. Do not promise anything about credit records here.
4. If they want plain account deletion:
   - There is no self-service account deletion.
   - Do NOT promise that "all data will be removed" – account data (login, email, personal details) is deleted on request, but credit records on published works are handled separately (see `gdpr-erasure-requests`).
   - **Escalate:** file via the `action-request` skill with `actionType: data-deletion` (Tier 3). Include: account email, confirmation they want the account permanently deleted. Quote the SLA the ticket response returns – do not promise a fixed turnaround.

---

## 11. Developer / API access request

**Customer says:** "How do I get API access?" / "I want an API key." / "Can I pull credits/data for the whole catalog?"

There are **two different products** here with completely different pricing and delivery. Work out which one the customer needs before answering. Full doctrine lives in `api-access.md`; what Muso Platform is lives in `platform.md`, and its current pricing in `platform-api.md`.

**Resolution path:**
1. Ask whether they need **workspace-level** access (only their own workspace's data) or **full-catalog** access (all profiles/tracks/credits across the whole catalog). Don't quote pricing or setup until you know which.
2. **Workspace-level access** is **self-service** and **included free on Pro and Business**:
   - Confirm their plan first with `subscription_status`. If on Lite/Free, they'd need to upgrade to Pro or Business in Settings.
   - If eligible, point them to **Settings → API access → request your key** (keys are issued on request, not auto-created for every account).
   - This is a newer feature still rolling out. If they're eligible but can't find the option or the key request isn't going through, **escalate:** create a ticket with category "API Access – Workspace Key" (actionType `support-general`). Include: account email, plan, what they're seeing. Don't promise a date.
3. **Full-catalog access** is **Muso Platform** at **platform.muso.ai**:
   - It is **live and self-service**. Point them there: they sign up, add a card and generate their own key. No access request, no waiting list, no sales call for the standard plans. Say this plainly -- many customers still expect the old apply-and-wait developer programme.
   - For pricing, retrieve `platform-api.md` and quote from it. Those figures track the public pricing page, so they match what the customer sees themselves.
   - **Only** for enterprise, negotiated volume, licensing, or a custom quote, **escalate:** create a ticket with category "API Access – Catalog/Enterprise" (actionType `support-general`). Include: account email, what data they want and roughly what volume. Do NOT negotiate pricing or commit terms yourself.
